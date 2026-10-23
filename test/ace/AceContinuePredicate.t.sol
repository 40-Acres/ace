// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace, NoMarket} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {
    AutoPolicyDisarmed,
    AutoTenorUnfundable,
    BufferBelowMin,
    GateRefused,
    LoanClosed,
    OutsideRefinanceWindow,
    NoRecordPrice,
    TenorOutOfRange,
    TriggerAboveFloor,
    ZeroCollateral
} from "../../src/ace/hub/Borrower.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The continuation predicate's surface, declared test-side so this file compiles before it ships.
/// @dev Cast onto `address(ace)`; `Ace` has no fallback, so an absent selector reverts with EMPTY data.
/// @dev THE SIGNATURE IS THE CONTRACT: a shipped mismatch shows up as every test here reporting MISSING.
interface IAceTryContinue {
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
}

/// @notice The armed-continuation doors this suite drives, declared test-side for the same reason.
interface IAceAuto {
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
    function refinanceByPolicy(uint256 id) external returns (uint256 newId);
    function refinanceByPolicies(uint256[] calldata ids) external returns (uint256[] memory newIds);
}

/// @notice `Ace.tryContinue` answers for `refinanceByPolicy`, leg for leg, and the two never disagree.
/// @notice The predicate is the fold's own body, so this suite is what stops the fold and the verb drifting.
/// @dev Every leg test asserts BOTH doors: the view reports a selector and the verb reverts with that selector.
/// @dev The pairing is the point -- a view that agrees with nothing is what issue #189 was written about.
contract AceContinuePredicateTest is Test {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    bytes32 internal id;

    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    IAceTryContinue internal pred;
    IAceAuto internal auto_;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xC0FFEE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days; // exactly two rungs: 7d and 30d
    uint16 internal constant BASE_BPS = 40;

    uint256 internal TOP; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal DEEP; // the depth the draws in this file walk down to
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant TOP_CASH = 400_000e6;
    uint256 internal constant DEEP_CASH = 200_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (TOP, DEEP) = (_price(0), _price(-6000));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        pred = IAceTryContinue(address(ace));
        auto_ = IAceAuto(address(ace));

        _deposit(id, TOP_CASH);
        _deposit(id, DEEP_CASH);
    }

    /* ============================ the happy path ============================ */

    /// @notice An armed loan inside its window: the view admits it and reports the debt the roll writes.
    function test_Continuable_AdmitsAndReportsTheSuccessorsDebt() public {
        uint256 loanId = _armedLoan();
        _intoWindow(loanId);

        (bool ok, bytes4 reason, uint256 principal) = _try(loanId);
        assertTrue(ok, "view refused a roll the verb accepts");
        assertEq(reason, bytes4(0), "an admitted roll carries no reason");
        assertGt(principal, 0, "an admitted roll must report a principal");

        vm.prank(keeper);
        uint256 newId = auto_.refinanceByPolicy(loanId);
        assertEq(read.debtOf(newId), principal, "reported principal is not the successor's debt");
    }

    /* ===================== THE HEADLINE: the window leg ===================== */

    /// @notice THE GAP THIS ISSUE EXISTS FOR: the fold's predicate carried no window leg.
    /// @notice The fold only ever ran post-expiry, where the window is trivially open, so nothing caught it.
    /// @notice Exposed without this leg the view admits a roll the verb refuses -- a filter that lies.
    /// @dev The deterministic RED witness: one loan, far from expiry, no fuzzing and no sequence.
    function test_OutsideWindow_ViewAndVerbBothRefuse() public {
        uint256 loanId = _armedLoan(); // armed at open, so far from expiry

        (bool ok, bytes4 reason, uint256 principal) = _try(loanId);
        assertFalse(ok, "the view admitted a roll outside the refinance window");
        assertEq(reason, OutsideRefinanceWindow.selector, "wrong refusal for a loan far from expiry");
        assertEq(principal, 0, "a refused roll reports no principal");

        vm.prank(keeper);
        vm.expectRevert(OutsideRefinanceWindow.selector);
        auto_.refinanceByPolicy(loanId);
    }

    /* ============================ leg by leg ============================ */

    function test_Leg_Closed() public {
        uint256 loanId = _armedLoan();
        _intoWindow(loanId);
        _repayInFull(loanId);
        _assertBothRefuse(loanId, LoanClosed.selector);
    }

    function test_Leg_Disarmed() public {
        uint256 loanId = _openLoan(P, TEN7);
        _intoWindow(loanId);
        _assertBothRefuse(loanId, AutoPolicyDisarmed.selector);
    }

    /// @notice Leg 4 is a BACKSTOP and is unreachable through this door: nothing zeroes a LIVE loan's collateral.
    /// @notice `withdrawCollateral` refuses the last unit with `ZeroCollateral`, and a loan that closed reports
    /// @notice `LoanClosed` on leg 1 before leg 4 is ever read. It stays as fail-closed defence on immutable code.
    /// @dev The fold reaches it by another route -- it judges `units - sliver`, which CAN be zero. Hence the param.
    function test_Leg_ZeroCollateral_IsAnUnreachableBackstop() public {
        uint256 loanId = _armedLoan();
        _intoWindow(loanId);

        uint256 units = read.loan(loanId).collateralUnits;
        vm.prank(borrower);
        vm.expectRevert(ZeroCollateral.selector);
        ace.withdrawCollateral(loanId, units, borrower);

        (bool ok,,) = _try(loanId);
        assertTrue(ok, "the loan still holds its collateral, so the roll stands");
    }

    /* =================== mitigation 1: no unset reason =================== */

    /// @notice EVERY refusal carries a NONZERO selector, on both doors.
    /// @notice A leg that returns false with an unset reason reverts with four ZERO bytes through the verb --
    /// @notice an undecodable custom error, which is what the re-raise exists to prevent.
    /// @dev Asserting the revert data is four bytes long does NOT catch this: a zero bytes4 is four bytes too.
    /// @dev THE GATE LEG IS NOT HERE, and cannot be: a HOME roll's destination is the loan's own market, whose
    /// @dev named borrower is this loan's borrower, so admission always admits. The routed refusal that CAN
    /// @dev happen carries `GateRefused` and is pinned in `AceCrossMarketRoll`.
    function test_EveryRefusalCarriesANonZeroReason() public {
        _assertReasonIs(_refusalOutsideWindow(), OutsideRefinanceWindow.selector);
        _assertReasonIs(_refusalDisarmed(), AutoPolicyDisarmed.selector);
        _assertReasonIs(_refusalClosed(), LoanClosed.selector);
    }

    /* ==================== mitigation 2: the leg ORDER ==================== */

    /// @notice Returning a reason makes the leg ORDER an observable contract on immutable bytecode.
    /// @notice A loan failing TWO legs reports the FIRST in the documented order, and this pins which.
    /// @dev Closed and disarmed both hold here; `closed` is leg 1 and must win.
    function test_LegOrder_AMultiFailureLoanReportsTheFirstLeg() public {
        uint256 loanId = _openLoan(P, TEN7); // never armed: disarmed holds
        _intoWindow(loanId);
        _repayInFull(loanId); // and now closed holds too

        (, bytes4 reason,) = _try(loanId);
        assertEq(reason, LoanClosed.selector, "leg order moved: closed must be reported before disarmed");
        _assertVerbReverts(loanId, LoanClosed.selector);
    }

    /* ============ the acceptance criterion: the batch filter ============ */

    /// @notice THE WHOLE POINT OF THE ISSUE. `refinanceByPolicies` is ALL-OR-NOTHING, and its own NatSpec
    /// @notice tells a keeper to simulate first -- with nothing to simulate with. One bad id killed a batch.
    /// @dev The filtered set is what the view buys: same keeper, same block, a batch that lands.
    function test_Batch_UnfilteredReverts_FilteredSucceeds() public {
        uint256[] memory all = new uint256[](3);
        all[0] = _armedLoan();
        all[1] = _openLoan(P, TEN7); // never armed: ONE inadmissible id is enough to take the batch with it
        all[2] = _armedLoan();
        for (uint256 i; i < all.length; i++) {
            _intoWindow(all[i]);
        }

        vm.prank(keeper);
        vm.expectRevert(AutoPolicyDisarmed.selector);
        auto_.refinanceByPolicies(all);

        uint256[] memory good = _filter(all);
        assertEq(good.length, 2, "the filter kept the wrong number of ids");

        vm.prank(keeper);
        uint256[] memory newIds = auto_.refinanceByPolicies(good);
        assertEq(newIds.length, 2, "the filtered batch did not land");
        for (uint256 i; i < newIds.length; i++) {
            assertGt(newIds[i], 0, "a filtered roll produced no successor");
        }
    }

    /* ========================== helpers ========================== */

    /// @dev The view, reached raw so an unbuilt door reports itself instead of reverting undecodably.
    function _try(uint256 loanId) internal view returns (bool ok, bytes4 reason, uint256 principal) {
        (bool called, bytes memory ret) = address(ace).staticcall(abi.encodeWithSelector(IAceTryContinue.tryContinue.selector, loanId));
        require(called && ret.length == 96, "Ace.tryContinue(uint256) is MISSING -- build it");
        (ok, reason, principal) = abi.decode(ret, (bool, bytes4, uint256));
    }

    /// @dev The filter a keeper runs before a batch: exactly the call the issue says had nowhere to come from.
    function _filter(uint256[] memory ids) internal view returns (uint256[] memory kept) {
        uint256 n;
        uint256[] memory buf = new uint256[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            (bool ok,,) = _try(ids[i]);
            if (ok) buf[n++] = ids[i];
        }
        kept = new uint256[](n);
        for (uint256 i; i < n; i++) {
            kept[i] = buf[i];
        }
    }

    /// @dev Asserted per case rather than in a build-then-loop, because some refusals mutate SHARED state.
    function _assertReasonIs(uint256 loanId, bytes4 sel) internal view {
        (bool ok, bytes4 reason,) = _try(loanId);
        assertFalse(ok, "expected a refusal");
        assertTrue(reason != bytes4(0), "a refusal reported an UNSET reason: revert(0,4) would be undecodable");
        assertEq(reason, sel, "wrong selector for this refusal");
    }

    function _assertBothRefuse(uint256 loanId, bytes4 sel) internal {
        (bool ok, bytes4 reason, uint256 principal) = _try(loanId);
        assertFalse(ok, "the view admitted a roll the verb refuses");
        assertEq(reason, sel, "the view reported the wrong refusal");
        assertEq(principal, 0, "a refused roll reports no principal");
        _assertVerbReverts(loanId, sel);
    }

    function _assertVerbReverts(uint256 loanId, bytes4 sel) internal {
        vm.prank(keeper);
        vm.expectRevert(sel);
        auto_.refinanceByPolicy(loanId);
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = BASE_BPS;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _openLoan(uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        return _openLoanOn(id, principal, tenor);
    }

    function _openLoanOn(bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        return _openLoanOnWith(mid, COLL, principal, tenor);
    }

    /// @dev The fixture market at a chosen collateral, for the one row that opens fat and trims to a line.
    function _openLoanWith(uint256 units, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        return _openLoanOnWith(id, units, principal, tenor);
    }

    function _openLoanOnWith(bytes32 mid, uint256 units, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(borrower, units);
        usdc.mint(borrower, principal);
        vm.startPrank(borrower);
        vault.approve(address(pm), units);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, units, principal, tenor, borrower, OFF);
        vm.stopPrank();
    }

    function _armedLoan() internal returns (uint256 loanId) {
        loanId = _openLoan(P, TEN7);
        vm.prank(borrower);
        auto_.setAutoRefinance(loanId, TEN7, 0, 0);
    }

    /// @dev Inside the window and still BEFORE expiry, so repay and withdrawCollateral stay reachable.
    /// @dev The window opens at `expiry - autoRefinanceWindow(minTenor)`, so one second short of expiry is in it.
    function _intoWindow(uint256 loanId) internal {
        vm.warp(read.loan(loanId).expiry - 1);
    }

    function _repayInFull(uint256 loanId) internal {
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    function _drainCollateral(uint256 loanId) internal {
        uint256 units = read.loan(loanId).collateralUnits;
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, units, borrower);
    }

    function _refusalOutsideWindow() internal returns (uint256 loanId) {
        loanId = _armedLoan();
    }

    function _refusalDisarmed() internal returns (uint256 loanId) {
        loanId = _openLoan(P, TEN7);
        _intoWindow(loanId);
    }

    function _refusalClosed() internal returns (uint256 loanId) {
        loanId = _armedLoan();
        _intoWindow(loanId);
        _repayInFull(loanId);
    }

    /* ============ the legs the first pass left with no test ============ */

    /// @notice Leg 10. `tryPersistedPrice` reports NOT-ok for a failed CALL and for a zero ANSWER alike.
    /// @notice A record that reverts must read as a refusal at both doors rather than bubbling its own error.
    /// @dev Mocked rather than swapped: the record address is part of the market id, so it decays in place.
    function test_Leg_NoRecordPrice_ARevertingRecordReadsAsRefusal() public {
        uint256 loanId = _armedLoan();
        _intoWindow(loanId);
        vm.mockCallRevert(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), "down");
        _assertBothRefuse(loanId, NoRecordPrice.selector);
    }

    /// @notice Leg 10, the OTHER half of `!s || ret.length < 32`: a record answering too few bytes.
    /// @dev The decode is what try/catch could not have caught, which is why the read is a raw staticcall.
    function test_Leg_NoRecordPrice_ShortReturndataReadsAsRefusal() public {
        uint256 loanId = _armedLoan();
        _intoWindow(loanId);
        vm.mockCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), hex"01");
        _assertBothRefuse(loanId, NoRecordPrice.selector);
    }

    /// @notice THE #270 REPRO. A record answering ZERO is the state `NoRecordPrice` is NAMED for, and the
    /// @notice predicate must say so at BOTH doors rather than blaming cash in a market that is fully funded.
    /// @notice The zero answer and the failed call are ONE state: the record cannot produce a windowed minimum.
    /// @dev RED until `tryPersistedPrice` folds the zero answer into `ok`, exactly as `tryRate` already does.
    /// @dev The fixture market holds 600k of resting cash here, so cash is not the constraint.
    function test_RecordAnsweringZero_ReportsTheRecordSelectorAtBothDoors() public {
        uint256 loanId = _armedLoan();
        _intoWindow(loanId);

        record.setMinPrice(0); // the draw cap collapses, and the record is what collapsed it
        /// @dev ONE READ. It was the same read added to itself -- a vestige of the two-tick fixture this
        /// @dev replaced, where the two terms were different rungs. Summing a market-wide balance with
        /// @dev itself only ever doubled the number it was already asserting against zero.
        assertGt(read.restingOf(id), 0, "the market is funded: cash is not the constraint");
        _assertBothRefuse(loanId, NoRecordPrice.selector);
    }

    /// @notice The DISCRIMINATION twin: a record that answers a real price still refuses on cash alone.
    /// @notice Without this row the test above could pass by collapsing the two states into one selector.
    /// @dev Same market shape as `test_Leg_InsufficientCash`, with the cap asserted LIVE before the refusal.
    function test_LiveRecordWithAnEmptyTick_StillReportsInsufficientCash() public {
        uint256 loanId = _armedThenEmptiedByTheLender();
        bytes32 mid = read.loan(loanId).market;

        assertGt(_windowedMin(mid), 0, "the record still proves a price: this must be a CASH refusal");
        _assertBothRefuse(loanId, InsufficientCash.selector);
    }

    /// @notice Leg 11a. The market cannot fund the successor's fresh remainder.
    /// @dev ARMED MEANS RESERVED, so a stranger can no longer empty the market under an armed loan.
    /// @dev The one party who can is its LENDER, whose withdraw is not held to the reserve: that is the state here.
    function test_Leg_InsufficientCash() public {
        uint256 loanId = _armedThenEmptiedByTheLender();
        _assertBothRefuse(loanId, InsufficientCash.selector);
    }

    /// @dev A side market rested for the draw AND the arming reservation, armed, then emptied by its own lender.
    function _armedThenEmptiedByTheLender() internal returns (uint256 loanId) {
        bytes32 mid = _sideMarket(32, BASE_BPS);
        _deposit(mid, 2 * P); // the draw, and room for the arming reservation beside it
        loanId = _armedLoanOn(mid, 0);
        vm.prank(alice);
        ace.withdraw(mid, type(uint256).max, alice, 0); // the lender's consent: reserved cash leaves with the rest
        assertEq(ace.restingOf(mid), 0, "fixture: the market is empty");
        _intoWindow(loanId);
    }

    /// @notice LEG 11b IS GONE, and it cannot be restated: it pinned `CapacityExceeded`, the refusal a draw
    /// @notice got when the walk wanted more legs than the market's claim-tick cap allowed.
    /// @notice A draw fills from ONE price now, so there are no legs to count and no cap to exceed.
    /// @notice Its sibling leg 11a survives above: a draw the market's cash cannot cover still names
    /// @notice `InsufficientCash`, which is the only capacity refusal a continuation can meet.

    /// @notice Leg 12a. The successor's floor sits BELOW its trigger, so the roll would be liquidatable at birth.
    /// @notice The old loan is healthy at its own floor: the refusal comes from the descent, not from distress.
    /// @dev The first draw empties the top tick, so the continuation has to reach the deep one to fill.
    function test_Leg_TriggerAboveFloor() public {
        bytes32 mid = _sideMarket(32, BASE_BPS);
        _deposit(mid, P);
        _deposit(mid, DEEP_CASH);
        /// @dev OPENED ALMOST EXACTLY ON THE LINE, at 71_400e6 against 100_000 whole units at k = 1.4.
        /// @dev WAS the default `P`, rolling into a market whose SHALLOWER rungs put the successor's floor
        /// @dev under its trigger. Every market bids at ONE price now and this roll's destination is the
        /// @dev market it is already in, so the only thing that can push the trigger past the floor is the
        /// @dev origination fee the roll itself adds to the debt -- which needs the loan to start on the line.
        uint256 loanId = _openLoanOn(mid, 71_400e6, TEN7);
        _rearm(loanId, 0);
        _intoWindow(loanId);

        assertGt(read.fundingFloor(mid, loanId), read.triggerPrice(loanId), "the OLD loan is still inside its own line");
        _assertBothRefuse(loanId, TriggerAboveFloor.selector);
    }

    /// @notice Leg 12b. The buffer the borrower armed is wider than the successor's floor-to-trigger gap.
    /// @dev `setAutoRefinance` refuses only a buffer no loan can meet, so a satisfiable one left unmet is the borrower's own refusal.
    function test_Leg_BufferBelowMin() public {
        uint256 loanId = _armedLoanWithBuffer(5000); // 50 percent, against a real gap near 1.6 percent
        _intoWindow(loanId);
        _assertBothRefuse(loanId, BufferBelowMin.selector);
    }

    /// @notice Leg 12b at its EXACT boundary: one bps under admits, EQUAL admits, one bps over refuses.
    /// @notice The gap is re-derived here from the market's own coverage and scale, never from the predicate.
    /// @dev The equal arm is what pins the comparison DIRECTION, and it needs the gap to land ON the bps grid.
    /// @dev The gap is `floor((floor - trig) * 1e18 / floor)`, which STEPS by `1e18 / floor` per unit of trig,
    /// @dev so most whole-bps values are unreachable at a given rung. The loan is opened fat and TRIMMED to the
    /// @dev collateral whose successor trigger lands on one that IS reachable, which is what makes the arm expressible.
    /// @dev The three asserts before the arms are the construction's own guard -- move a constant and they say so.
    function test_Leg_BufferBelowMin_AtTheBoundary() public {
        uint256 loanId = _openLoanWith(2 * COLL, P_EXACT, TEN7);
        _rearm(loanId, 0);
        _intoWindow(loanId);
        (bool ok,, uint256 principal) = _try(loanId);
        assertTrue(ok, "the unbuffered roll must stand, or the boundary below is measured off a refusal");
        uint256 floor = read.fundingFloor(id, loanId);
        assertEq(floor, TOP, "this boundary is computed against the market price, which the roll funded at");

        uint16 gapBps = _expressibleGapBps(floor, uint16(((floor - _successorTrigger(principal, 2 * COLL)) * 1e18 / floor) / 1e14));
        _trimTo(loanId, _requiredAt(principal, floor - (uint256(gapBps) * floor + 9999) / 10000));

        uint256 gapWad = ((floor - _successorTrigger(principal, read.loan(loanId).collateralUnits)) * 1e18) / floor;
        assertEq(gapWad % 1e14, 0, "the gap is off the bps grid, so no arming can express the equal arm");
        assertEq(gapWad / 1e14, gapBps, "the trim did not land the gap on the bps it was solved for");
        assertGt(gapBps, 1, "the gap rounds to nothing, so the three arms below collapse into one");

        _rearm(loanId, gapBps - 1);
        (bool under,,) = _try(loanId);
        assertTrue(under, "a buffer UNDER the gap was refused");

        _rearm(loanId, gapBps);
        (bool atGap,,) = _try(loanId);
        assertTrue(atGap, "a buffer EQUAL to the gap must admit: the leg refuses on strictly less");

        _rearm(loanId, gapBps + 1);
        _assertBothRefuse(loanId, BufferBelowMin.selector);
    }

    /* ========= legs 5 and 6: backstops nothing can reach through the hub ========= */

    /// @notice Leg 6 is a BACKSTOP. `autoPolicyOf` has exactly two writers and neither can store an out-of-range tenor.
    /// @notice `setAutoRefinance` REFUSES one, at both ends of the grid, where the borrower is present to see it.
    /// @dev Market params are frozen at genesis and hashed into the market id, so a stored tenor cannot fall out of range later.
    /// @dev So leg 6 gets no `_assertBothRefuse` row: nothing reaches it, and these two tests are its whole coverage.
    function test_Leg_TenorOutOfRange_ArmingRefusesItAtBothEnds() public {
        uint256 loanId = _armedLoan();
        vm.startPrank(borrower);
        vm.expectRevert(TenorOutOfRange.selector);
        auto_.setAutoRefinance(loanId, TEN30 + 1, 0, 0);
        vm.expectRevert(TenorOutOfRange.selector);
        auto_.setAutoRefinance(loanId, TEN7 - 1, 0, 0);
        vm.stopPrank();

        (uint64 t,,) = read.autoPolicyOf(loanId);
        assertEq(t, TEN7, "a refused arming still moved the stored policy");
    }

    /// @notice The SECOND writer: a cross-market roll carries the policy and CLAMPS it into the destination grid.
    /// @notice That clamp is what keeps leg 6 unreachable when a loan lands in a market with a narrower grid.
    /// @dev Without it the carried 30-day policy would sit outside a 7-day-only market and the view would report leg 6.
    function test_Leg_TenorOutOfRange_TheCarryClampsIntoTheDestinationGrid() public {
        uint256 loanId = _openLoan(P_MIG, TEN7);
        _rearm(loanId, 0);
        vm.prank(borrower);
        auto_.setAutoRefinance(loanId, TEN30, 0, 0); // legal here: this market's grid runs to 30 days

        bytes32 dst = _sideMarket(32, BASE_BPS, TEN7);
        _depositAt(dst, TOP_CASH); // the destination grid holds one rung, so the horizon must be it
        uint256 newId = _refinanceInto(dst, loanId, TEN7);

        (uint64 t,,) = read.autoPolicyOf(newId);
        assertEq(t, TEN7, "the carry did not clamp the policy into the destination grid");
        _intoWindow(newId);
        (bool ok, bytes4 reason,) = _try(newId);
        assertTrue(reason != TenorOutOfRange.selector, "a carried policy reported an out-of-range tenor");
        assertTrue(ok, "the clamped policy is inadmissible, so the clamp above proves nothing");
    }

    /// @notice Leg 5 is a BACKSTOP too, and the rail that makes it one is at GENESIS, not on the loan.
    /// @notice The SHARE bound caps every armable tenor's fee well under its own draw, so the leg cannot fire.
    /// @dev This is the market the leg would need, and it cannot be created.
    /// @dev The bound at 500 bps over a 7d rung lands at 31.8 days, which no whole day sits on exactly.
    /// @dev It was 127.27 days against the old whole-principal bound; the share ceiling moved it.
    function test_Leg_AutoTenorUnfundable_IsBarredAtGenesis() public {
        MarketParams memory p = _sideParams(32, 500);
        p.minTenor = TEN7;
        p.maxTenor = 32 days; // the FIRST refused rung: 4 * 500 * 32d * 11000 == 6.0826e13, over 6.048e13
        vm.expectRevert(bytes("fee bps too high"));
        ace.createMarket(p);

        // one day inside the bound is admitted, so the rail is a boundary and not a ban
        p.maxTenor = 31 days; // 4 * 500 * 31d * 11000 == 5.8925e13, under it
        assertTrue(ace.createMarket(p) != bytes32(0), "the steepest admissible grid must still build");
    }

    /// @notice And the clamp holds it shut from the other side: a carried policy lands inside the rail too.
    /// @dev The destination runs the STEEPEST fee genesis admits, so the margin here is the smallest one reachable.
    function test_Leg_AutoTenorUnfundable_TheClampKeepsItUnreachable() public {
        uint256 loanId = _openLoan(P_MIG, TEN7);
        vm.prank(borrower);
        auto_.setAutoRefinance(loanId, TEN30, 0, 0);

        bytes32 dst = _sideMarket(32, 500, TEN7);
        _depositAt(dst, TOP_CASH); // the destination grid holds one rung, so the horizon must be it
        uint256 newId = _refinanceInto(dst, loanId, TEN7);

        (uint64 t,,) = read.autoPolicyOf(newId);
        assertEq(t, TEN7, "the carry left a tenor the destination market cannot fund");
        _intoWindow(newId);
        (, bytes4 reason,) = _try(newId);
        assertTrue(reason != AutoTenorUnfundable.selector, "leg 5 fired: baseBps times the carried tenor reached the rail");
    }

    /* ============ the batch filter, with the successors identified ============ */

    /// @notice The filter kept the right ids, not merely the right NUMBER of them.
    /// @notice A filter that dropped an ADMISSIBLE id and kept an inadmissible one has the same length.
    /// @dev Each surviving roll is matched to the principal the view quoted for THAT id, before the batch ran.
    function test_Batch_FilteredIdsAreTheOnesTheViewQuoted() public {
        uint256[] memory all = new uint256[](3);
        all[0] = _armedLoan();
        all[1] = _openLoan(P, TEN7); // never armed
        all[2] = _armedLoan();
        for (uint256 i; i < all.length; i++) {
            _intoWindow(all[i]);
        }

        uint256[] memory good = _filter(all);
        assertEq(good.length, 2, "the filter kept the wrong number of ids");
        assertEq(good[0], all[0], "the filter dropped an admissible id");
        assertEq(good[1], all[2], "the filter kept an inadmissible id");

        uint256[] memory quoted = new uint256[](good.length);
        for (uint256 i; i < good.length; i++) {
            (,, quoted[i]) = _try(good[i]);
        }

        vm.prank(keeper);
        uint256[] memory newIds = auto_.refinanceByPolicies(good);
        for (uint256 i; i < newIds.length; i++) {
            assertEq(read.debtOf(newIds[i]), quoted[i], "a filtered roll wrote a debt the filter did not quote");
        }
        assertFalse(read.loan(all[1]).closedAt != 0, "the id the filter dropped was rolled anyway");
    }

    /// @notice An id that was never opened is refused by BOTH doors, and with the same error.
    /// @notice A filter that answered for a loan with no market would hand a keeper a batch it cannot send.
    /// @dev NOT a reason selector: there is no loan to attribute a leg to, so the market lookup refuses first.
    function test_AnUnknownLoanIsRefusedByBothDoorsAlike() public {
        uint256 ghost = read.loanCount() + 99;

        vm.expectRevert(NoMarket.selector);
        pred.tryContinue(ghost);

        vm.prank(keeper);
        vm.expectRevert(NoMarket.selector);
        auto_.refinanceByPolicy(ghost);
    }

    /* ========================== added helpers ========================== */

    uint256 internal constant P_MIG = 50_000e6; // small enough that a 5 percent destination fee still clears the floor
    uint256 internal constant P_EXACT = 69_990_680_231; // derives a successor of exactly 70_300e6, whose gap lands on the bps grid

    /// @dev A market with its OWN record, so its id differs from the fixture's.
    function _sideParams(uint256 claimTicks, uint256 bps) internal returns (MarketParams memory p) {
        p = _params();
        p.record = address(new MockPersistenceRecord(address(usdc), address(vault)));
        p.baseBps = bps;
    }

    function _sideMarket(uint256 claimTicks, uint256 bps) internal returns (bytes32) {
        return ace.createMarket(_sideParams(claimTicks, bps));
    }

    /// @dev The same market with its whole grid collapsed onto one rung: the clamp's destination.
    function _sideMarket(uint256 claimTicks, uint256 bps, uint64 tenor) internal returns (bytes32) {
        MarketParams memory p = _sideParams(claimTicks, bps);
        p.minTenor = tenor;
        p.maxTenor = tenor;
        return ace.createMarket(p);
    }

    /// @dev `_deposit` at a stated horizon, for a market whose grid does not hold the fixture's 30 days.
    function _depositAt(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _armedLoanOn(bytes32 mid, uint16 buf) internal returns (uint256 loanId) {
        loanId = _openLoanOn(mid, P, TEN7);
        _rearm(loanId, buf);
    }

    function _armedLoanWithBuffer(uint16 buf) internal returns (uint256 loanId) {
        return _armedLoanOfSize(P, buf);
    }

    function _armedLoanOfSize(uint256 principal, uint16 buf) internal returns (uint256 loanId) {
        loanId = _openLoan(principal, TEN7);
        _rearm(loanId, buf);
    }

    function _rearm(uint256 loanId, uint16 buf) internal {
        vm.prank(borrower);
        auto_.setAutoRefinance(loanId, TEN7, buf, 0);
    }

    /// @dev The windowed minimum a market's own record answers: exactly what `persistedPrice` reads.
    function _windowedMin(bytes32 mid) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(mid);
        return IPersistenceRecord(p.record).minPrice(p.quote, p.collateral);
    }

    /// @dev The trigger the successor WOULD carry on `units`, spelled from the market's own coverage and scale.
    function _successorTrigger(uint256 principal, uint256 units) internal view returns (uint256) {
        uint256 cov = ace.idToMarketParams(id).minCoverageWad;
        uint256 num = cov * principal * read.marketState(id).unitScale;
        uint256 den = units * 1e18;
        return (num + den - 1) / den;
    }

    /// @dev Its inverse: the units that put `principal`'s trigger at or under `price`, which is the coverage line.
    function _requiredAt(uint256 principal, uint256 price) internal view returns (uint256) {
        uint256 cov = ace.idToMarketParams(id).minCoverageWad;
        uint256 num = cov * principal * read.marketState(id).unitScale;
        uint256 den = price * 1e18;
        return (num + den - 1) / den;
    }

    /// @dev The largest whole-bps gap at or under `from` that this rung can express EXACTLY.
    /// @dev A gap of `b` bps needs an integer `d` with `floor(d * 1e18 / floorPrice) == b * 1e14`, and the
    /// @dev smallest candidate is `ceil(b * floorPrice / 1e4)`; most `b` have no such `d` and are skipped.
    function _expressibleGapBps(uint256 floorPrice, uint16 from) internal pure returns (uint16) {
        for (uint16 b = from; b > 1; b--) {
            uint256 d = (uint256(b) * floorPrice + 9999) / 10000;
            if ((d * 1e18) / floorPrice == uint256(b) * 1e14) return b;
        }
        revert("no whole-bps gap is expressible at this rung");
    }

    /// @dev Shed collateral down to exactly `units`; the withdrawal gate reads the CURRENT debt, which is smaller.
    function _trimTo(uint256 loanId, uint256 units) internal {
        uint256 held = read.loan(loanId).collateralUnits;
        require(held > units, "fixture: the loan must open fat enough to trim to the line");
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, held - units, borrower);
    }

    /// @dev The manual roll into another market, sized so the fresh draw covers the old debt and its own fee.
    function _refinanceInto(bytes32 dst, uint256 loanId, uint64 tenor) internal returns (uint256 newId) {
        uint256 debt = read.debtOf(loanId);
        uint256 bps = ace.idToMarketParams(dst).baseBps;
        /// @dev the ALL-IN inverse, re-spelled: at `tenor == minTenor` the tenor factor cancels out
        uint256 newPrincipal = (debt * 1e8) / (1e8 - bps * (10000 + Constants.PROTOCOL_SHARE_BPS)) + 2;
        vm.prank(borrower);
        newId = ace.refinanceTo(MigrateArgs(loanId, dst, newPrincipal, tenor, OFF, 0, address(0)));
    }
}
