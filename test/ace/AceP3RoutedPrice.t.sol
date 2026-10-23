// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MinDebtRaised, PriceLowered} from "../../src/ace/hub/Borrower.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP3RoutedPriceBase
/// @notice Audit run 2026-09-13-670568 phase 3, F1: a keeper-routed roll lets a stranger pick the successor's price, then refuse its roll.
/// @notice `_compatLeg` pins collateral, quote, record, minDebt, borrower and six downside dials; `price` is not among them.
/// @notice Only the borrower's `minBufferBps` bounds the destination price, and sole tenancy makes the next roll that lender's to starve.
/// @dev Controls prove the route and the settle are ordinary verbs; premises pin each step; the RED row is the forfeiture.
abstract contract AceP3RoutedPriceBase is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    address internal rec;
    bytes32 internal home;

    address internal alice = address(0xA11CE); // the home lender, the one the borrower chose
    address internal mallory = address(0xBAD); // a keeper who stands up her own destination market
    address internal borrower = address(0xB0B);

    uint256 internal constant DEPOSIT = 40e6;
    uint256 internal constant PRINCIPAL = 11e6;
    uint256 internal constant COLL = 10_000e18; // worth 10,000 USDC at the home price: a very safe loan
    uint16 internal constant BUF = 2000; // the borrower's risk-distance pre-commit, 20%
    uint16 internal constant FEE_CAP = 100; // 1% realized-rate ceiling; nonzero is the routing consent

    function _newRecord() internal virtual returns (address);

    /// @notice Collateral a settlement of `debt` at `price` hands the market side, by this market class's own rule.
    function _takenAt(uint256 debt, uint256 price) internal view virtual returns (uint256);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = _newRecord();
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(alice, 0));
        (ace, pm, read, home) = (d.ace, d.positionManager, d.read, d.id);
        _rest(home, alice, DEPOSIT);
    }

    function _params(address lender, uint256 price) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = rec;
        p.lender = lender;
        if (price != 0) p.price = price;
    }

    function _rest(bytes32 m, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    function _k() internal view returns (uint256) {
        return ace.idToMarketParams(home).minCoverageWad;
    }

    function _homePrice() internal view returns (uint256) {
        return ace.idToMarketParams(home).price;
    }

    /// @dev A healthy loan armed for routing: a real buffer and a real fee ceiling, exactly as `RoutingNeedsBuffer` demands.
    function _armedLoanInOpenWindow() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(home, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, read.loan(loanId).tenor, BUF, FEE_CAP);
        vm.stopPrank();
        uint64 w = MarketInit.autoRefinanceWindow(ace.idToMarketParams(home).minTenor);
        _warpTo(uint256(read.loan(loanId).expiry) - w / 4); // past the home-exclusive half, before expiry
    }

    /// @dev The successor's principal, read off the home roll's own predicate: derivation reads no price and no lender.
    function _successorPrincipal(uint256 loanId) internal view returns (uint256 p) {
        bool ok;
        (ok,, p) = ace.tryContinue(loanId);
        assertTrue(ok, "fixture: the home roll must be admissible, so the derivation is the one a route uses");
    }

    /// @dev The lowest price whose buffer still clears `BUF` against this lot: ceil(trig / (1 - buffer)).
    function _lowestAdmissiblePrice(uint256 principal) internal view returns (uint256) {
        uint256 trig = LoanMath.triggerPrice(principal, COLL, _k(), 1 << 96);
        return FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - uint256(BUF) * 1e14);
    }

    /// @dev The keeper's own market at `price`, holding exactly one successor's worth, so the route leaves it empty.
    function _destination(uint256 price, uint256 principal) internal returns (bytes32 dst) {
        dst = ace.createMarket(_params(mallory, price));
        _rest(dst, mallory, principal);
    }

    /// @notice CONTROL: routed at the HOME price and starved, the market side takes only the home measure of the debt.
    /// @dev So the magnitude in the premise below is the PRICE the keeper chose, not the starvation alone.
    function test_Control_ARouteAtTheHomePriceTakesOnlyTheHomeMeasure() public {
        uint256 loanId = _armedLoanInOpenWindow();
        uint256 p2 = _successorPrincipal(loanId);
        bytes32 dst = _destination(_homePrice(), p2);
        vm.prank(mallory);
        uint256 newId = ace.refinanceByPolicyTo(loanId, dst);
        uint256 debt = read.debtOf(newId);
        _warpTo(read.loan(newId).expiry);
        vm.prank(mallory);
        ace.forceClose(newId);
        assertEq(read.invPotOf(dst, newId), _takenAt(debt, _homePrice()), "control: the pot is the home measure of the debt");
    }

    /// @notice PREMISE: price is not a compat field. One wei under the buffer bound refuses; at the bound the route is admitted.
    function test_Premise_OnlyTheBorrowersBufferBoundsTheDestinationPrice() public {
        uint256 loanId = _armedLoanInOpenWindow();
        uint256 p2 = _successorPrincipal(loanId);
        uint256 low = _lowestAdmissiblePrice(p2);
        bytes32 under = _destination(low - 1, p2);
        bytes32 at = _destination(low, p2);
        assertLt(low * 100, _homePrice(), "fixture: the buffer alone would admit a price under 1% of the one the borrower chose");
        emit log_named_uint("destination price as ppm of the home price", (low * 1e6) / _homePrice());

        /// @dev INVERTED BY THE FIX. This row's name and its assertions recorded the DEFECT: the borrower's
        /// @dev buffer was the only bound on the destination price, so 1933 ppm of home was admissible.
        /// @dev `_compatLeg` now carries a directional price leg, so BOTH destinations are refused BY NAME.
        /// @dev The fixture above is untouched and still proves these markets differ from home in lender and
        /// @dev price alone, which is what makes the refusal attributable to that leg and to no other.
        (bool okUnder, bytes4 whyUnder,) = ace.tryContinueTo(loanId, under);
        assertFalse(okUnder, "one wei under the old buffer bound is refused");
        assertEq(whyUnder, PriceLowered.selector, "and it is the price leg, not the buffer, that refuses it now");
        (bool okAt, bytes4 whyAt,) = ace.tryContinueTo(loanId, at);
        assertFalse(okAt, "and the buffer bound itself is refused too: the whole sub-home range is closed");
        assertEq(whyAt, PriceLowered.selector, "by the same leg, by name");
    }

    // CLOSED (PriceLowered): AStrangerRoutesThenStarves took 7999 bps of the lot recordless (home line 15.47 units) and 5714 record-backed, on 11.05 USDC debt.

    /// @notice PREMISE: the keeper's own tiny `minDebt` refuses every honest rescue, because the rail only lets a floor fall.
    /// @dev A same-floor rival is admitted in the same block, so it is the directional minDebt rail and nothing else that refuses.
    /// @dev SURVIVES THE FIX, and the fixture moved to the home price to show it: the liveness lever is untouched.
    function test_Premise_TheKeepersMinDebtLocksOutAnHonestRescue() public {
        uint256 loanId = _armedLoanInOpenWindow();
        uint256 p2 = _successorPrincipal(loanId);
        MarketParams memory q = _params(mallory, _homePrice()); // the price leg admits the home price or better
        q.minDebt = 2; // the smallest floor genesis admits: the fee on it must stay under it
        bytes32 dst = ace.createMarket(q);
        /// @dev One successor PLUS slack: an exactly-funded destination cannot back the successor's own roll, so it is born disarmed.
        _rest(dst, mallory, p2 + PRINCIPAL);
        vm.prank(mallory);
        uint256 newId = ace.refinanceByPolicyTo(loanId, dst);

        address carol = address(0xCA201);
        bytes32 rescue = ace.createMarket(_params(carol, _homePrice()));
        MarketParams memory r = _params(carol, _homePrice());
        r.minDebt = 2;
        bytes32 rescueSameFloor = ace.createMarket(r);
        _rest(rescue, carol, DEPOSIT);
        _rest(rescueSameFloor, carol, DEPOSIT);
        uint64 w = MarketInit.autoRefinanceWindow(q.minTenor);
        _warpTo(uint256(read.loan(newId).expiry) - w / 4);

        (bool ok, bytes4 why,) = ace.tryContinueTo(newId, rescue);
        assertFalse(ok, "an honest market at the home price and an ordinary floor cannot take the loan back out");
        assertEq(why, MinDebtRaised.selector, "and the refusal is the minDebt rail");
        (bool okSame,,) = ace.tryContinueTo(newId, rescueSameFloor);
        assertTrue(okSame, "control: the same rescue at the keeper's own floor is admitted");
    }

    /// @notice RED: an armed borrower routed by a stranger never forfeits more than their own market's price takes for that debt.
    /// @dev Fix-agnostic: a refused route passes, and a successor that rolls rather than settles leaves no pot.
    function test_RED_ARoutedBorrowerNeverForfeitsMoreThanTheHomeMeasure() public {
        uint256 loanId = _armedLoanInOpenWindow();
        uint256 p2 = _successorPrincipal(loanId);
        bytes32 dst = _destination(_lowestAdmissiblePrice(p2), p2);
        vm.prank(mallory);
        (bool routed, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.refinanceByPolicyTo, (loanId, dst)));
        if (!routed) return;
        uint256 newId = abi.decode(ret, (uint256));
        uint256 debt = read.debtOf(newId);
        _warpTo(read.loan(newId).expiry);
        vm.prank(mallory);
        ace.forceClose(newId);
        assertLe(read.invPotOf(dst, newId), _takenAt(debt, _homePrice()), "a stranger chose the price and then refused the roll");
    }
}

// The recordless instance is deleted: a recordless market cannot arm (`ArmNeedsRecord`), so no keeper can route its loan.

/// @title AceP3RoutedPriceRecordBacked
/// @notice The record-backed class: settlement takes the claim's need at the funding floor; a record bounds price from ABOVE only.
contract AceP3RoutedPriceRecordBackedTest is AceP3RoutedPriceBase {
    function _newRecord() internal override returns (address) {
        return address(new MockPersistenceRecord(address(usdc), address(coll)));
    }

    function _takenAt(uint256 debt, uint256 price) internal pure override returns (uint256) {
        return FullMath.mulDivRoundingUp(debt, 1 << 96, price);
    }
}
