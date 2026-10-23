// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace, BelowCallerFloor, LoanMatured as WithdrawMatured} from "../../src/ace/hub/Ace.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {DeleverageDisabled, Distressed, LoanClosed, LoanMatured, NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceDeleverageExpiryGateTest
/// @notice The deleverage expiry gate at its exact second, on both surfaces: the crank and `AceLens.deleverageEligible`.
/// @notice And its place in the crank's refusal order: disabled, closed, matured, the `minDebt` return, distressed, then the band read.
/// @dev Every boundary row reads `expiry` off the loan and moves the clock to it; nothing restates the tenor.
/// @dev The distress and band rows first show the outranked refusal firing alone one second earlier, so each pair has two live sides.
/// @dev The `minDebt` return is `(0, 0)`, not a revert: a loan at or under `minDebt` leaves before the distress and band reads.
/// @dev `test_Order_ClosedOutranksMatured` also pins closed over that return: a repaid loan's zero debt would otherwise return `(0, 0)`.
contract AceDeleverageExpiryGateTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant BAND_BPS = 3000; // the channel opens under a 30% margin
    uint256 internal P; // the healthy record price, $2.00, framed in setUp
    uint256 internal PS_BAND; // $0.70: ~10% over the ~0.63 trigger, inside the band and clear of the 1 bps stop

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        P = AceFixtures.px(2e18, address(usdc), address(vault));
        PS_BAND = AceFixtures.px(0.7e18, address(usdc), address(vault));
        record.setMinPrice(P);

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(BAND_BPS));
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
        _fund(ace, id);
    }

    function _params(uint256 bandBps) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = bandBps == 0 ? 0 : ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = bandBps;
        p.deleverageTargetBps = bandBps == 0 ? 0 : 4000;
        p.deleverageStopBps = bandBps == 0 ? 0 : 1; // channel off: the genesis lie-guard requires eps, target and stop to follow the band to zero
    }

    function _fund(Ace hub, bytes32 mid) internal {
        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 15_000e6);
        hub.deposit(mid, 15_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        loanId = _openOn(ace, positionManager, id);
    }

    function _openOn(Ace hub, PositionManager pm, bytes32 mid) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        loanId = hub.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _expiryOf(uint256 loanId) internal view returns (uint256) {
        return uint256(read.loan(loanId).expiry);
    }

    /// @dev Park the record in the band, derived from the trigger here rather than from the lens under test.
    function _armBand(uint256 loanId) internal {
        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(PS_BAND);
    }

    /* ============================== the boundary, both surfaces ============================== */

    /// @notice One loan, one armed record, two seconds: at `expiry - 1` both surfaces admit, at `expiry` both refuse.
    /// @dev The snapshot keeps the state identical across the two seconds, so the clock is the only thing that moved.
    /// @dev Kills `>=` -> `>` on either surface (the expiry leg) and any gate firing a second early (the live leg).
    function test_Boundary_BothSurfacesAgreeOnEachSideOfTheExpirySecond() public {
        uint256 loanId = _open();
        uint256 expiry = _expiryOf(loanId);
        _armBand(loanId);

        _warpTo(expiry - 1);
        uint256 snap = vm.snapshotState();
        assertTrue(lens.deleverageEligible(loanId), "expiry - 1: the lens admits");
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "expiry - 1: and the real crank sells");
        vm.revertToState(snap);

        _warpTo(expiry);
        assertFalse(lens.deleverageEligible(loanId), "expiry: the lens refuses");
        vm.expectRevert(LoanMatured.selector);
        keeper.crankDeleverage(loanId);
    }

    /// @notice At every second of a tenor and past it, the lens answers `now < expiry` and the crank does exactly what it says.
    /// @dev Half the seeds land within two seconds of expiry, so the edge is hit every run rather than by dictionary luck.
    function testFuzz_Boundary_LensAndCrankAgreeAtEverySecond(uint256 seed) public {
        uint256 loanId = _open();
        uint256 opened = _now();
        uint256 expiry = _expiryOf(loanId);
        _armBand(loanId);

        uint256 t = seed % 2 == 0 ? expiry - 2 + (seed >> 1) % 5 : bound(seed >> 1, opened, expiry + (expiry - opened));
        _warpAtLeastTo(t);
        bool live = t < expiry;

        assertEq(lens.deleverageEligible(loanId), live, "the lens answers the clock: eligible exactly while now < expiry");
        if (live) {
            (uint256 sold,) = keeper.crankDeleverage(loanId);
            assertGt(sold, 0, "a live, in-band loan is admitted and sells");
        } else {
            vm.expectRevert(LoanMatured.selector);
            keeper.crankDeleverage(loanId);
        }
    }

    /// @notice The NatSpec's claim, pinned: deleverage refuses on the same condition, with the same error, as a withdrawal.
    /// @dev Two declarations share one selector, so a keeper decoding either reads the other; a rename of one breaks this row.
    function test_SameGateAsTheCollateralWithdrawal_AtBothSeconds() public {
        assertEq(WithdrawMatured.selector, LoanMatured.selector, "one error name, one selector, across both declarations");
        uint256 loanId = _open();
        uint256 expiry = _expiryOf(loanId);

        _warpTo(expiry - 1);
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, 1, borrower);
        _armBand(loanId);
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "expiry - 1: both verbs are admitted");

        _warpTo(expiry);
        vm.expectRevert(WithdrawMatured.selector);
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, 1, borrower);
        vm.expectRevert(LoanMatured.selector);
        keeper.crankDeleverage(loanId);
    }

    /* ============================== the refusal order ============================== */

    /// @notice A market with the channel off refuses `DeleverageDisabled` even on a matured loan: the band check leads.
    function test_Order_DisabledOutranksMatured() public {
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(0));
        MockDeleverageKeeper k = new MockDeleverageKeeper(d.ace, address(usdc), address(vault), UNIT_SCALE);
        _fund(d.ace, d.id);
        uint256 loanId = _openOn(d.ace, d.positionManager, d.id);

        _warpTo(uint256(d.read.loan(loanId).expiry));
        vm.expectRevert(DeleverageDisabled.selector);
        k.crankDeleverage(loanId);
    }

    /// @notice A closed loan past its expiry refuses `LoanClosed`, never `LoanMatured`: closure outranks the clock.
    /// @dev Closed by a full repay one second before expiry, so it is both closed and matured when the crank arrives.
    function test_Order_ClosedOutranksMatured() public {
        uint256 loanId = _open();
        uint256 expiry = _expiryOf(loanId);
        _armBand(loanId);

        _warpTo(expiry - 1);
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertGt(read.loan(loanId).closedAt, 0, "PREMISE: the repay closed the loan");
        vm.expectRevert(LoanClosed.selector);
        keeper.crankDeleverage(loanId);

        _warpTo(expiry);
        vm.expectRevert(LoanClosed.selector);
        keeper.crankDeleverage(loanId);
    }

    /// @notice A distressed loan past its expiry refuses `LoanMatured`: the clock is read before the record is.
    /// @dev The premise leg shows the distress read firing one second earlier, so the gate is what changed the answer.
    function test_Order_MaturedOutranksDistress() public {
        uint256 loanId = _open();
        uint256 expiry = _expiryOf(loanId);
        record.setBelow(true); // flag mode: persisted below every level, the trigger included

        _warpTo(expiry - 1);
        vm.expectRevert(Distressed.selector);
        keeper.crankDeleverage(loanId);

        _warpTo(expiry);
        vm.expectRevert(LoanMatured.selector);
        keeper.crankDeleverage(loanId);
    }

    /// @notice A healthy loan past its expiry refuses `LoanMatured`, not `NotInBand`: a matured crank never asks the band.
    function test_Order_MaturedOutranksTheBandRead() public {
        uint256 loanId = _open(); // the record sits at P: healthy, out of the band
        uint256 expiry = _expiryOf(loanId);

        _warpTo(expiry - 1);
        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);

        _warpTo(expiry);
        vm.expectRevert(LoanMatured.selector);
        keeper.crankDeleverage(loanId);
    }

    /* ============================== the minDebt return in the order ============================== */

    /// @dev A loan drawn at exactly the market's `minDebt`: no head over the floor, so the crank may melt nothing.
    function _openAtMinDebt(Ace hub, PositionManager pm, bytes32 mid) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        loanId = hub.open(mid, COLL, hub.idToMarketParams(mid).minDebt, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice A market with the channel off refuses `DeleverageDisabled` on a loan at `minDebt`: the band dial outranks the return.
    function test_Order_DisabledOutranksTheMinDebtReturn() public {
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(0));
        MockDeleverageKeeper k = new MockDeleverageKeeper(d.ace, address(usdc), address(vault), UNIT_SCALE);
        _fund(d.ace, d.id);
        uint256 loanId = _openAtMinDebt(d.ace, d.positionManager, d.id);
        vm.expectRevert(DeleverageDisabled.selector);
        k.crankDeleverage(loanId);
    }

    /// @notice A matured loan at `minDebt` refuses `LoanMatured`: the clock outranks the return, and one second earlier the return fires alone.
    function test_Order_MaturedOutranksTheMinDebtReturn() public {
        uint256 loanId = _openAtMinDebt(ace, positionManager, id);
        uint256 expiry = _expiryOf(loanId);

        _warpTo(expiry - 1);
        (uint256 sold, uint256 stableOut) = keeper.crankDeleverage(loanId);
        assertEq(sold + stableOut, 0, "expiry - 1: at minDebt the crank returns (0, 0) rather than reverting");

        _warpTo(expiry);
        vm.expectRevert(LoanMatured.selector);
        keeper.crankDeleverage(loanId);
    }

    /// @notice A DISTRESSED loan at `minDebt` returns `(0, 0)`, not `Distressed`: the return precedes the distress read.
    /// @dev The premise leg is a loan over `minDebt` in the same record state, which does refuse `Distressed`.
    function test_Order_TheMinDebtReturnOutranksDistress() public {
        uint256 over = _open();
        uint256 atFloor = _openAtMinDebt(ace, positionManager, id);
        record.setBelow(true); // flag mode: persisted below every level, the trigger included
        _warpTo(_expiryOf(atFloor) - 1);

        vm.expectRevert(Distressed.selector);
        keeper.crankDeleverage(over);

        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.persistedBelowDistress.selector), 0);
        (uint256 sold, uint256 stableOut) = keeper.crankDeleverage(atFloor);
        assertEq(sold + stableOut, 0, "at minDebt the crank returns (0, 0) before it asks the record about distress");
    }

    /// @notice A HEALTHY loan at `minDebt` returns `(0, 0)`, not `NotInBand`: the return precedes the band read and the price read.
    /// @dev The premise leg is a loan over `minDebt` in the same record state, which does refuse `NotInBand`.
    function test_Order_TheMinDebtReturnOutranksTheBandRead() public {
        uint256 over = _open(); // the record sits at P: healthy, out of the band
        uint256 atFloor = _openAtMinDebt(ace, positionManager, id);
        _warpTo(_expiryOf(atFloor) - 1);

        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(over);

        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.persistedBelowDistress.selector), 0);
        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 0);
        (uint256 sold, uint256 stableOut) = keeper.crankDeleverage(atFloor);
        assertEq(sold + stableOut, 0, "at minDebt the crank returns (0, 0) before it reads the band or the price");
    }

    /// @notice A caller floor above zero turns the `minDebt` return into `BelowCallerFloor`: `Ace` checks `minStableOut` on every return.
    function test_Order_ACallerFloorTurnsTheMinDebtReturnIntoBelowCallerFloor() public {
        uint256 atFloor = _openAtMinDebt(ace, positionManager, id);
        _warpTo(_expiryOf(atFloor) - 1);
        vm.expectRevert(BelowCallerFloor.selector);
        keeper.crankWithFloor(atFloor, 1);
    }
}
