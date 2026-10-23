// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {CoverageRaised} from "../../src/ace/hub/Borrower.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP7CoverageLeverBase
/// @notice Audit run 2026-09-13-670568 phase 7: the routing keeper's SECOND free settlement dial is `minCoverageWad`.
/// @notice `_compatLeg` compares neither `price` nor `minCoverageWad`; a recordless settlement takes `coverageLine`, which reads both.
/// @notice So a directional price leg (the phase 3 F1 fix shape (a)) leaves the recordless forfeit open AT THE HOME PRICE.
/// @dev A 10% LTV loan, so the coverage lever alone reaches the same `(1 - buffer) * lot` bound the price lever reaches.
abstract contract AceP7CoverageLeverBase is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    address internal rec;
    bytes32 internal home;

    address internal alice = address(0xA11CE); // the home lender
    address internal mallory = address(0xBAD); // the routing keeper, lender of her own destination
    address internal borrower = address(0xB0B);
    address internal borrower2 = address(0xB0B2);

    uint256 internal constant S = 1 << 96;
    uint256 internal constant MAX_K = 20e18; // Constants.MAX_COVERAGE_WAD
    uint256 internal constant DEPOSIT = 1000e6;
    uint256 internal constant PRINCIPAL = 100e6;
    uint256 internal constant COLL = 1000e18; // worth 1,000 USDC at the home price: a 10% LTV loan
    uint16 internal constant BUF = 2000; // the borrower's 20% risk distance
    uint16 internal constant FEE_CAP = 100; // 1% realized-rate ceiling: the routing consent

    function _newRecord() internal virtual returns (address);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = _newRecord();
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = rec;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, home) = (d.ace, d.positionManager, d.read, d.id);
        _rest(home, alice, DEPOSIT);
    }

    function _homeParams() internal view returns (MarketParams memory) {
        return ace.idToMarketParams(home);
    }

    function _homePrice() internal view returns (uint256) {
        return _homeParams().price;
    }

    function _homeK() internal view returns (uint256) {
        return _homeParams().minCoverageWad;
    }

    function _rest(bytes32 m, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    /// @dev A healthy 10% LTV loan armed for routing exactly as `RoutingNeedsBuffer` demands; no clock movement.
    function _armedLoan(address who) internal returns (uint256 loanId) {
        coll.mint(who, COLL);
        vm.startPrank(who);
        coll.approve(address(pm), COLL);
        loanId = ace.open(home, COLL, PRINCIPAL, 0, who, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, read.loan(loanId).tenor, BUF, FEE_CAP);
        vm.stopPrank();
    }

    /// @dev Past the incumbent's exclusive half of the roll window, before expiry.
    function _warpIntoOpenHalf(uint256 loanId) internal {
        uint64 w = MarketInit.autoRefinanceWindow(_homeParams().minTenor);
        _warpTo(uint256(read.loan(loanId).expiry) - w / 4);
    }

    function _successorPrincipal(uint256 loanId) internal view returns (uint256 p) {
        bool ok;
        (ok,, p) = ace.tryContinue(loanId);
        assertTrue(ok, "fixture: the home roll must be admissible, so the derivation is the one a route uses");
    }

    /// @dev The largest coverage the borrower's buffer admits at the HOME price, capped at the genesis ceiling.
    function _kMax(uint256 principal) internal view returns (uint256 k) {
        uint256 trigTarget = FullMath.mulDiv(_homePrice(), 1e18 - uint256(BUF) * 1e14, 1e18) - 1;
        k = FullMath.mulDiv(trigTarget, COLL * 1e18, principal * S);
        if (k > MAX_K) k = MAX_K;
    }

    /// @dev The keeper's market: the home market in every field but `lender` and `minCoverageWad`.
    function _coverageDestParams(uint256 k) internal view returns (MarketParams memory q) {
        q = _homeParams();
        q.lender = mallory;
        q.minCoverageWad = k;
    }

    function _destination(MarketParams memory q, uint256 principal) internal returns (bytes32 dst) {
        dst = ace.createMarket(q);
        _rest(dst, mallory, principal);
    }
}

// The recordless instance is deleted: a recordless market cannot arm (`ArmNeedsRecord`), so no keeper can route its loan.

/// @title AceP7CoverageLeverRecordBackedTest
/// @notice The record-backed class, where settlement takes the claim's need, which reads no coverage: the lever is inert.
/// @dev Every destination reuses home's record, so `RecordMismatch` never answers before the leg a row is about.
contract AceP7CoverageLeverRecordBackedTest is AceP7CoverageLeverBase {
    function _newRecord() internal override returns (address) {
        return address(new MockPersistenceRecord(address(usdc), address(coll)));
    }

    /// @notice SCOPE CONTROL: the same route and starvation in the record-backed class takes only the need at the home price.
    /// @dev So a directional price leg IS sufficient here, and the finding is the recordless class alone.
    function test_Control_RecordBacked_TheCoverageDialDoesNotMoveThePot() public {
        uint256 loanId = _armedLoan(borrower);
        _warpIntoOpenHalf(loanId);
        uint256 p2 = _successorPrincipal(loanId);
        bytes32 dst = _destination(_coverageDestParams(_kMax(p2)), p2);

        /// @dev INVERTED BY THE FIX. The pot this row measured, the need at the home price, is unreachable now.
        /// @dev The coverage leg is NOT scoped to the recordless class, so it refuses this route as well.
        /// @dev That scope is deliberate: a stricter coverage raises the TRIGGER, and the band, target and stop
        /// @dev are bps OF that trigger, so the same route manufactured a sale the home twin could not be made.
        (bool ok, bytes4 why,) = ace.tryContinueTo(loanId, dst);
        assertFalse(ok, "the record-backed class refuses the coverage route too");
        assertEq(why, CoverageRaised.selector, "and the coverage leg is what refuses it, by name");
    }

    /// @notice PREMISE: the destination differs from home ONLY in lender and coverage; its price EQUALS home, and routing admits it.
    /// @dev So a directional `cd.price < cs.price` refusal would admit this route unchanged.
    function test_Premise_OnlyCoverageDiffers_AndTheRouteIsAdmitted() public {
        uint256 loanId = _armedLoan(borrower);
        _warpIntoOpenHalf(loanId);
        uint256 p2 = _successorPrincipal(loanId);
        uint256 k = _kMax(p2);
        MarketParams memory q = _coverageDestParams(k);
        bytes32 dst = _destination(q, p2);

        MarketParams memory h = _homeParams();
        MarketParams memory got = ace.idToMarketParams(dst);
        assertEq(got.price, h.price, "the destination bids at the home price: no price leg of any direction refuses it");
        assertGt(got.minCoverageWad, h.minCoverageWad * 5, "fixture: the keeper's coverage is over 5x the home coverage");
        got.lender = h.lender;
        got.minCoverageWad = h.minCoverageWad;
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(h)), "and it differs from home in nothing else");

        /// @dev INVERTED BY THE FIX. This row's name and its two assertions recorded the DEFECT: the buffer
        /// @dev admitted a 5x stricter coverage at the home price because no compat leg read the dial.
        /// @dev `_compatLeg` now carries a directional coverage leg, so the route is refused BY NAME.
        /// @dev The fixture above is untouched and still proves the destination differs from home in the
        /// @dev coverage dial ALONE, which is what makes the refusal attributable to that leg and no other.
        (bool ok, bytes4 why,) = ace.tryContinueTo(loanId, dst);
        assertFalse(ok, "a 5x stricter coverage is no longer admitted at the home price");
        assertEq(why, CoverageRaised.selector, "and the coverage leg is what refuses it, by name");
    }

    // CLOSED (CoverageRaised), recordless: TheLineAtHerCoverageIsTaken took 800/1,000 COLL, 100.44 USDC debt, k = 7.9649; home line 140.6175, excess 659.38.

    // CLOSED (both legs), recordless: TheCoverageLeverMatchesThePriceLever measured both levers at 799.99999999999997 units, to 1.6e4 atoms of a 1,000 lot.

    /// @notice MEASURE: the keeper's own `minTenor` sets her successor's rescue window; the borrower's fee ceiling is its only bound.
    /// @dev Executes phase 3 F1's reasoned squeeze. Composed with its minDebt lock: a rescuer must also name minDebt 2.
    function test_Measure_TheKeepersMinTenorShrinksTheRescueWindow() public {
        uint256 loanId = _armedLoan(borrower);
        _warpIntoOpenHalf(loanId);
        MarketParams memory q = _coverageDestParams(_homeK());
        q.baseBps = 1; // the genesis floor: the fee leg then admits the shortest minTenor
        q.minTenor = 6700; // 7 days at 1 bps over 6700s is 0.993% realized, under the borrower's 1% ceiling
        q.minDebt = 2;
        bytes32 dst = _destination(q, DEPOSIT);
        vm.prank(mallory);
        uint256 newId = ace.refinanceByPolicyTo(loanId, dst);

        MarketParams memory r = _homeParams();
        r.lender = address(0xCA201);
        r.minDebt = 2; // the only floor the keeper's MinDebtRaised rail lets a rescuer name
        bytes32 rescue = ace.createMarket(r);
        _rest(rescue, r.lender, DEPOSIT);

        uint256 expiry = read.loan(newId).expiry;
        uint64 hold = MarketInit.homeRollHold(q.minTenor);
        uint64 homeHold = MarketInit.homeRollHold(_homeParams().minTenor);
        _warpTo(expiry - hold - 1);
        (bool okEarly, bytes4 whyEarly,) = ace.tryContinueTo(newId, rescue);
        assertFalse(okEarly, "one second before the keeper's hold ends, no rescuer may take the loan");
        assertEq(whyEarly, bytes4(keccak256("HomeRollExclusive()")), "and the refusal is the keeper's own exclusivity");
        _warpTo(expiry - hold);
        (bool okLate,,) = ace.tryContinueTo(newId, rescue);
        assertTrue(okLate, "the rescue opens only here");
        _warpTo(expiry);
        (bool okAtExpiry,,) = ace.tryContinueTo(newId, rescue);
        assertTrue(okAtExpiry, "the paid door stays open at expiry, but the keeper's forceClose lands in the same block");
        emit log_named_uint("rescue window before the successor's expiry (s)", hold);
        emit log_named_uint("the same window on the home market (s)", homeHold);
        assertLt(uint256(hold) * 5, homeHold, "the keeper cut the rescue window to under a fifth of the home market's");
    }
}

/// @title AceP7CoverageLeverBandTest
/// @notice The record-backed tail: coverage also moves the TRIGGER, and the six equal downside dials are all bps OF the trigger.
/// @notice So a stranger's coverage choice drags a healthy loan into the deleverage band; the equality rail compares the ruler, not the length.
contract AceP7CoverageLeverBandTest is AceP7CoverageLeverBase {
    function _newRecord() internal override returns (address) {
        return address(new MockPersistenceRecord(address(usdc), address(coll)));
    }

    function _openIn(bytes32 m, address who) internal returns (uint256 id) {
        coll.mint(who, COLL);
        vm.startPrank(who);
        coll.approve(address(pm), COLL);
        id = ace.open(m, COLL, PRINCIPAL, 0, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice MEASURE: at one record state, the home twin refuses `NotInBand` while its routed sibling is cranked at the window minimum.
    function test_Measure_ACoverageRouteForcesASaleTheHomeTwinCannotBeMade() public {
        MarketParams memory hp = _homeParams();
        hp.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        hp.deleverageBandBps = 3000;
        hp.deleverageTargetBps = 4000;
        hp.deleverageStopBps = 1000;
        bytes32 h = ace.createMarket(hp);
        _rest(h, alice, DEPOSIT);
        uint256 routed = _openIn(h, borrower);
        uint256 twin = _openIn(h, borrower2);
        uint64 tenor = read.loan(routed).tenor;
        vm.prank(borrower);
        ace.setAutoRefinance(routed, tenor, BUF, FEE_CAP);
        _warpTo(uint256(read.loan(routed).expiry) - MarketInit.autoRefinanceWindow(hp.minTenor) / 4);

        (bool ok,, uint256 p2) = ace.tryContinue(routed);
        assertTrue(ok, "fixture: the home roll is admissible");
        MarketParams memory q = hp;
        q.lender = mallory;
        q.minCoverageWad = _kMax(p2);
        bytes32 dst = _destination(q, p2);

        /// @dev INVERTED BY THE FIX. The sale this row manufactured is gone: the route is refused by name.
        /// @dev It measured 27.452843789961540923 units sold out of the routed sibling at one record state.
        /// @dev The keeper paid 27.178388 USDC for collateral worth 27.452916 USDC at that same record price.
        /// @dev The fixture above is untouched: the destination differs from home in lender and coverage alone.
        (bool okDst, bytes4 why,) = ace.tryContinueTo(routed, dst);
        assertFalse(okDst, "the coverage route into the band is refused");
        assertEq(why, CoverageRaised.selector, "and the coverage leg is what refuses it, by name");

        MockPersistenceRecord(rec).setBandPrice(_homePrice()); // the record sits at the lenders' own price
        MockPersistenceRecord(rec).setMinPrice(_homePrice());
        MockDeleverageKeeper k = new MockDeleverageKeeper(ace, address(usdc), address(coll), S);
        vm.expectRevert(bytes4(keccak256("NotInBand()")));
        k.crankDeleverage(twin);
        vm.expectRevert(bytes4(keccak256("NotInBand()")));
        k.crankDeleverage(routed); // and the loan that can no longer be routed stays out of the band with it
    }
}
