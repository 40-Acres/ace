// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, LoanMatured} from "../../src/ace/hub/Ace.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP12DeleverageFoldFlip
/// @notice Phase 12 (sequences): WRITER `deleverage` (debt, units), READER `forceCloseOrContinue` through `tryContinue`.
/// @notice An ARMED, EXPIRED, in-band loan rolls on `forceClose` alone. A stranger's post-expiry `deleverage` used to SETTLE it.
/// @notice The flip ran through the `minDebt` floor: the melt dropped debt under it, and the roll re-sized the successor at it.
/// @notice The reduced lot could not carry that draw (`TriggerAboveFloor`). Without the floor it still settled: under `minDebt`, `BelowMinDebt` refuses.
/// @notice Ruled twice: `deleverage` refuses from the expiry second with `LoanMatured`, and never melts under `minDebt`.
/// @dev The gate row pins the first: no crank can precede the fold in the same transaction.
/// @dev The measurement pins the second in the last live second, where the gate alone left the flip open: the crank stops at `minDebt` and the fold rolls.
/// @dev The property itself, across sizes, dials and fills, is `AceDeleverageMinDebtCap` and `AceP12FoldFlipSweep`.
contract AceP12DeleverageFoldFlipTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;
    uint256 internal T;
    uint256 internal par; // `T`: the funding floor every draw here lands on, and the record's windowed minimum

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    uint64 internal constant TEN = 7 days;
    uint256 internal constant K = 1.4e18;
    uint256 internal constant S = 1 << 96;
    uint256 internal constant MIN_DEBT = 10e6; // the fixture's admission quantum

    /// @dev One market per dial set. The record answers `par` and sits out of the band until `_enterBand`.
    function _deploy(uint256 band, uint256 target, uint256 stop, uint256 cut) internal {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        T = AceFixtures.priceAt(address(usdc), address(coll), 0);
        par = T;
        record.setMinPrice(par);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = band;
        p.deleverageTargetBps = target;
        p.deleverageStopBps = stop;
        p.deleverageProtocolBps = cut;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(coll), S);
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 100_000e6);
        vm.stopPrank();
    }

    /// @dev A `minDebt` loan whose trigger sits at three quarters of par: 25% margin, inside a 30% band, clear of a 10% stop.
    /// @dev Leaves the clock where the open ran: the loan is live.
    function _openArmedLive() internal returns (uint256 loanId) {
        loanId = _openArmedLiveAt(MIN_DEBT);
    }

    /// @dev The same geometry at any debt: the trigger still sits at three quarters of par.
    function _openArmedLiveAt(uint256 debt) internal returns (uint256 loanId) {
        uint256 units = FullMath.mulDiv(K * debt, S * 100, 75 * par * 1e18);
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        loanId = ace.open(id, units, debt, TEN, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, ProtocolPolicy.MIN_TENOR, 0, 0);
        vm.stopPrank();
    }

    /// @dev The same loan, one second past its expiry.
    function _openArmed() internal returns (uint256 loanId) {
        loanId = _openArmedLive();
        _warpTo(_expiryOf(loanId) + 1);
    }

    function _expiryOf(uint256 loanId) internal view returns (uint256) {
        return uint256(read.loan(loanId).expiry);
    }

    /// @dev The record now proves the band: below-ness holds at the band level and NOT at the trigger (no distress).
    function _enterBand(uint256 loanId, uint256 band) internal {
        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - band * 1e14));
    }

    /* ============================== PREMISES, both legs alone ============================== */

    /// @notice LEG A alone: the armed, expired loan is admissible and the paid crank ROLLS it.
    function test_Premise_TheArmedExpiredLoanRollsOnItsOwn() public {
        _deploy(3000, 5000, 1000, 500); // the playground's band-on yb dials (PocMarkets.ybBtcDemoParams)
        uint256 loanId = _openArmed();
        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "PREMISE: the continuation is admissible at expiry");
        uint256 n = read.loanCount();
        vm.prank(address(keeper));
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "the fold took the ROLL branch");
    }

    /// @notice LEG B alone: from the EXACT expiry second, in band, a stranger's `deleverage` is refused and touches nothing.
    /// @dev The boundary is `>=`, the complement of `forceClose`'s `NotExpired`: on the clock alone, every second admits exactly one of the two.
    function test_Premise_TheCrankAloneIsRefusedFromTheExpirySecond() public {
        _deploy(3000, 5000, 1000, 500); // the playground's band-on yb dials (PocMarkets.ybBtcDemoParams)
        uint256 loanId = _openArmedLive();
        _warpTo(_expiryOf(loanId));
        _enterBand(loanId, 3000);
        uint256 unitsBefore = read.loan(loanId).collateralUnits;
        vm.expectRevert(LoanMatured.selector);
        keeper.crankDeleverage(loanId);
        assertEq(read.debtOf(loanId), MIN_DEBT, "the refused crank melted nothing");
        assertEq(read.loan(loanId).collateralUnits, unitsBefore, "and sold nothing");
        assertEq(read.loan(loanId).closedAt, 0, "the loan is still live");
        (uint64 tenor,,) = read.autoPolicyOf(loanId);
        assertEq(tenor, ProtocolPolicy.MIN_TENOR, "and still armed");
    }

    /* ============================== THE PAIR ============================== */

    /// @notice The pair at the issue's own moment: after expiry the crank is REFUSED, and the armed fold ROLLS as the borrower set it.
    /// @dev What it pins: a POST-EXPIRY crank cannot choose the fold's branch. A last-live-second crank still can; the measurement pins that.
    /// @dev Refused as a collateral withdrawal is, by the same condition and the same error: `block.timestamp >= expiry`, `LoanMatured`.
    function test_TheGate_ACrankAfterExpiryIsRefusedAndTheArmedFoldRolls() public {
        _deploy(3000, 5000, 1000, 500); // the playground's band-on yb dials (PocMarkets.ybBtcDemoParams)
        uint256 loanId = _openArmed();
        _enterBand(loanId, 3000);
        uint256 debtBefore = read.debtOf(loanId);
        uint256 unitsBefore = read.loan(loanId).collateralUnits;

        vm.expectRevert(LoanMatured.selector);
        keeper.crankDeleverage(loanId);
        assertEq(read.debtOf(loanId), debtBefore, "the refused crank melted nothing");
        assertEq(read.loan(loanId).collateralUnits, unitsBefore, "and sold nothing");

        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "the continuation is still admissible");
        uint256 n = read.loanCount();
        vm.prank(address(keeper));
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "and the fold ROLLS: a refused post-expiry crank does not choose the branch");
        assertGt(read.loan(loanId).closedAt, 0, "the old loan closed into its successor");
    }

    /// @notice The pair that USED to flip, in the last live second: the crank now stops at `minDebt`, and the armed fold ROLLS.
    /// @dev 1.05x `minDebt` at a 25% margin: an uncapped sale here melts to ~0.49x, and a successor re-sized at `minDebt` triggered above par.
    /// @dev The cap keeps the debt at `minDebt`, so the successor is sized off a debt/lot ratio the sale only improved.
    function test_Measure_TheCrankStopsAtMinDebtAndTheArmedFoldRolls() public {
        _deploy(3000, 5000, 1000, 500); // the playground's band-on yb dials (PocMarkets.ybBtcDemoParams)
        uint256 loanId = _openArmedLiveAt(MIN_DEBT * 105 / 100);
        _warpTo(_expiryOf(loanId) - 1);
        _enterBand(loanId, 3000);
        uint256 trigBefore = read.triggerPrice(loanId);
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "PREMISE: the crank is admitted one second before expiry, and sells");
        assertEq(read.debtOf(loanId), MIN_DEBT, "and stops exactly at the market's admission quantum");
        assertLt(read.triggerPrice(loanId), trigBefore, "the sale left the live loan healthier");
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 trigAtMinDebt = FullMath.mulDivRoundingUp(K * MIN_DEBT, S, units * 1e18);
        assertLe(trigAtMinDebt, par, "arithmetic: k * minDebt / units' stays under the par floor");
        _warpTo(_expiryOf(loanId) + 1);
        (bool ok, bytes4 reason,) = ace.tryContinue(loanId);
        assertTrue(ok, "the continuation is admissible");
        assertEq(reason, bytes4(0), "with no refusal named");
        uint256 n = read.loanCount();
        vm.prank(address(keeper));
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "so the fold ROLLS: a successor was minted for the loan its borrower armed to roll");
        assertGt(read.loan(loanId).closedAt, 0, "and the old loan closed into it");
    }

    /* ============================== CONTROL: an uncapped crank ============================== */

    /// @notice At a low target and no cut, on a loan well above `minDebt`, the sale restores without reaching the cap and the pair still ROLLS.
    /// @dev 3x `minDebt`: the sale melts ~35% of the debt, so the cap is never the thing that stopped it. The uncapped path keeps the branch too.
    /// @dev Same clock as the measurement: the crank in the last live second, the fold one second past expiry.
    function test_Control_AtALowTargetAndNoCutThePairStillRolls() public {
        _deploy(3000, 4000, 1, 0);
        uint256 loanId = _openArmedLiveAt(3 * MIN_DEBT);
        _warpTo(_expiryOf(loanId) - 1);
        _enterBand(loanId, 3000);
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "PREMISE: the crank fired here too");
        assertGt(read.debtOf(loanId), MIN_DEBT, "PREMISE: and restored without reaching the minDebt cap");
        _warpTo(_expiryOf(loanId) + 1);
        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "the melt left the successor admissible");
        uint256 n = read.loanCount();
        vm.prank(address(keeper));
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "so the fold rolls on the uncapped path as well");
    }
}
