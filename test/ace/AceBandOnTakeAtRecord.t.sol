// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "../fairness/FairnessHarness.sol";
import {DeleverageStopped} from "../../src/ace/hub/Deleverage.sol";
import {NoRecordPrice, RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {HUB_POLICY_GAS} from "../../src/config/Defaults.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PushGasShort} from "../../src/ace/hub/Ace.sol";
import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";
import {IGasShortRefusals} from "../../src/interfaces/IGasShortRefusals.sol";
import {PolicyGasShort, RecordGasShort} from "../../src/ace/hub/libraries/Probe.sol";

/// @title AceBandOnTakeAtRecord
/// @notice THE RULE (#944, #945): a BAND-ON market's title transfer takes the debt at the record, `ceil(claim * unitScale / minPrice)`, at both doors.
/// @notice Never less than the claim's need at the price, never past the lot less the sliver; the crank sizes and fills at that same read.
/// @notice A dark record closes the door: inside the term `finalize` refuses `NoRecordPrice`; from expiry both doors refuse for a grace, then take the need.
/// @notice The read is capped at the hub's policy budget, and a caller who cannot hand the record the whole budget is refused, never priced at the fallback.
/// @dev Band-off and recordless markets are the controls: their takes are unchanged.
contract AceBandOnTakeAtRecordTest is FairnessHarness {
    uint256 internal constant GRACE = 3 days; // the dark-record grace past expiry the build rules
    bytes4 internal constant RECORD_GAS_SHORT = bytes4(keccak256("RecordGasShort()")); // spelled by hash so this suite compiles before the error exists

    /* ================================ helpers ================================ */

    /// @dev A loan of `D` in `mid` for the rig's term, its trigger at `thetaBps` of par, the record at par.
    function _openAt(bytes32 mid, uint256 thetaBps) internal returns (uint256 loanId) {
        _deposit(mid, alice, 2 * D);
        _budget();
        loanId = _openRun(mid, _baseRun(Kind.BandOn, thetaBps, _flatAt(10000, 1)));
    }

    /// @dev `claim` at a record print of `bps` of par, ceiled toward the lender: the take this branch rules.
    function _atRecord(uint256 claim, uint256 bps) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(claim, S, _pxOf(bps));
    }

    function _need(uint256 claim) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(claim, S, par);
    }

    function _sliver(uint256 debt) internal view returns (uint256) {
        return FullMath.mulDiv(debt * BOUNTY, S, 10000 * par);
    }

    /// @dev The coverage line on `debt` at `px`: `requiredAt` plus one atom, as the gates spell it.
    function _lineAt(uint256 debt, uint256 px) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(K * debt, S, px * 1e18) + 1;
    }

    function _assertNoShort(uint256 loanId) internal view {
        (uint256 u, uint256 q) = read.shortfallOf(loanId);
        assertEq(u, 0, "a covered close records no unit shortfall");
        assertEq(q, 0, "and no bad debt");
    }

    /// @dev Every sickness off and the record at par, so a second run in one test opens on a healthy record.
    function _healthyRecord() internal {
        rec.setSick(false);
        rec.setShortAnswer(false);
        rec.setBurns(false);
        rec.setCost(0);
        rec.setNeeds(0);
        _printBps(10000);
    }

    function _forceCloseAt(uint256 loanId) internal {
        vm.prank(keeper);
        ace.forceClose(loanId);
    }

    /* ================================ the take ================================ */

    /// @notice A stopped loan reaching expiry settles at the record: the debt at 70% of par, not the need at the price.
    function test_StopZone_ForceCloseAtExpiry_TakesTheDebtAtTheRecord() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(7000);
        vm.expectRevert(DeleverageStopped.selector);
        ace.deleverage(loanId, 0, "");
        uint256 lot = read.loan(loanId).collateralUnits;
        _warpAtLeastTo(read.loan(loanId).expiry);
        _forceCloseAt(loanId);
        uint256 take = _atRecord(D, 7000);
        assertGt(take, _need(D), "PREMISE: under the price the debt at the record exceeds the need");
        assertEq(read.invPotOf(id, loanId), take, "a band-on close at expiry takes the debt at the record");
        assertEq(read.unitsOwedOf(loanId, borrower), lot - _sliver(D) - take, "the borrower keeps the lot less the sliver and the take");
        _assertNoShort(loanId);
    }

    /// @notice A distressed low-trigger loan seized inside the term takes the debt at the record, past the coverage line #933's take stops at.
    function test_InTermFinalize_LowTrigger_TakesTheDebtAtTheRecordAboveTheCoverageLine() public {
        uint256 loanId = _openAt(id, 4500);
        _warpBy(STEP);
        _printBps(4400);
        uint256 lot = read.loan(loanId).collateralUnits;
        vm.prank(keeper);
        ace.finalize(loanId);
        uint256 take = _atRecord(D, 4400);
        assertGt(take, _lineAt(D, par), "PREMISE: the debt at a 44% record is past the coverage line at the price");
        assertEq(read.invPotOf(id, loanId), take, "an in-term band-on seizure takes the debt at the record");
        assertEq(read.unitsOwedOf(loanId, borrower), lot - _sliver(D) - take, "the borrower keeps the lot less the sliver and the take");
        _assertNoShort(loanId);
    }

    /// @notice A record over the price at expiry: the need binds, so the lender takes no more than the claim at the price.
    function test_RecordAboveThePrice_AtExpiry_TakesTheNeed() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(11000);
        _warpAtLeastTo(read.loan(loanId).expiry);
        _forceCloseAt(loanId);
        assertEq(read.invPotOf(id, loanId), _need(D), "a record over the price takes the need");
        _assertNoShort(loanId);
    }

    /// @notice From expiry both doors are open and give one take: the debt at the record.
    function test_AfterExpiry_FinalizeAndForceCloseTakeTheSame() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(6400);
        _warpAtLeastTo(read.loan(loanId).expiry + 1 days);
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        ace.finalize(loanId);
        uint256 viaFinalize = read.invPotOf(id, loanId);
        vm.revertToState(snap);
        _forceCloseAt(loanId);
        assertEq(read.invPotOf(id, loanId), viaFinalize, "finalize and forceClose take the same after expiry");
        assertEq(viaFinalize, _atRecord(D, 6400), "and it is the debt at the record");
    }

    /// @notice A deep print: the debt at the record passes the lot, so the take is the lot less the sliver, and no bad debt is booked over the need.
    function test_DeepPrint_TheTakeIsTheLotLessTheSliver_NoBadDebtBooked() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(3000);
        uint256 lot = read.loan(loanId).collateralUnits;
        assertGt(_atRecord(D, 3000), lot - _sliver(D), "PREMISE: the debt at a 30% record passes the lot");
        vm.prank(keeper);
        ace.finalize(loanId);
        assertEq(read.invPotOf(id, loanId), lot - _sliver(D), "the take is the lot less the sliver");
        assertEq(read.unitsOwedOf(loanId, borrower), 0, "the borrower keeps nothing");
        _assertNoShort(loanId);
    }

    /// @notice After a crank a lower print settles: the take past the need was never reserved, so the lender gets the lot less the sliver, no bad debt.
    function test_AfterACrank_ALowerSettlementPrint_TakesTheLotLessTheSliver_NoBadDebtBooked() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(8000);
        (uint256 sold,) = ace.deleverage(loanId, 0, "");
        assertGt(sold, 0, "PREMISE: the crank restores");
        _warpBy(STEP);
        _printBps(2000);
        uint256 lot = read.loan(loanId).collateralUnits;
        uint256 debt = read.loan(loanId).debt;
        assertGt(_atRecord(debt, 2000), lot - _sliver(debt), "PREMISE: the debt at a 20% record passes what the crank left");
        vm.prank(keeper);
        ace.finalize(loanId);
        assertEq(read.invPotOf(id, loanId), lot - _sliver(debt), "the take is the lot less the sliver");
        _assertNoShort(loanId);
    }

    /* ================================ the dark record ================================ */

    /// @dev The door at expiry: `finalize` on a loan the print has put in distress, else `forceClose`.
    function _settleDoor(uint256 loanId, bool viaFinalize) internal {
        vm.prank(keeper);
        if (viaFinalize) ace.finalize(loanId);
        else ace.forceClose(loanId);
    }

    /// @dev A loan whose record goes dark by `how`: 0 answers zero, 1 reverts, 2 returns short, 3 burns its budget, 4 costs more than it.
    /// @dev Zero is `NoRecordPrice`, the record ANSWERED; every other way is `RecordUnreadable`, no answer, as `Borrower.recordState` names them.
    /// @dev Via `finalize` the print is under the trigger, so the loan is settleable and only the price is dark; via `forceClose` it rests stopped.
    function _darkAtExpiry(uint256 how, bool viaFinalize) internal {
        _healthyRecord();
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(viaFinalize ? 6400 : 7000);
        if (how == 0) rec.setMinPrice(0);
        if (how == 1) rec.setSick(true);
        if (how == 2) rec.setShortAnswer(true);
        if (how == 3) rec.setBurns(true);
        if (how == 4) rec.setCost(HUB_POLICY_GAS + 50_000);
        bytes4 err = how == 0 ? NoRecordPrice.selector : RecordUnreadable.selector;
        uint256 x = read.loan(loanId).expiry;
        _warpAtLeastTo(x);
        vm.expectRevert(err);
        _settleDoor(loanId, viaFinalize);
        _warpTo(x + GRACE - 1);
        vm.expectRevert(err);
        _settleDoor(loanId, viaFinalize);
        _warpTo(x + GRACE);
        _settleDoor(loanId, viaFinalize);
        assertEq(read.invPotOf(id, loanId), _need(D), "past the grace a dark record settles at the need");
        _assertNoShort(loanId);
    }

    /// @notice A record answering zero at expiry: both doors refuse `NoRecordPrice` for the grace, then the loan settles at the need.
    function test_DarkRecordAtExpiry_AnsweringZero_RefusesForTheGraceThenTakesTheNeed() public {
        _darkAtExpiry(0, false);
        _darkAtExpiry(0, true);
    }

    /// @notice A reverting record at expiry: both doors refuse `RecordUnreadable` for the grace, so no record stops settlement for longer.
    function test_DarkRecordAtExpiry_Reverting_RefusesForTheGraceThenTakesTheNeed() public {
        _darkAtExpiry(1, false);
        _darkAtExpiry(1, true);
    }

    /// @notice A record returning short at expiry: the same, `RecordUnreadable`.
    function test_DarkRecordAtExpiry_ShortAnswer_RefusesForTheGraceThenTakesTheNeed() public {
        _darkAtExpiry(2, false);
        _darkAtExpiry(2, true);
    }

    /// @notice A record burning its whole budget at expiry: the capped read survives it, `RecordUnreadable` at both doors.
    function test_DarkRecordAtExpiry_BurningItsBudget_RefusesForTheGraceThenTakesTheNeed() public {
        _darkAtExpiry(3, false);
        _darkAtExpiry(3, true);
    }

    /// @notice A record whose answer costs more than the budget is dark to settlement: `RecordUnreadable` at both doors.
    function test_DarkRecordAtExpiry_OverBudget_RefusesForTheGraceThenTakesTheNeed() public {
        _darkAtExpiry(4, false);
        _darkAtExpiry(4, true);
    }

    /// @notice ONE PRICE, ONE BUDGET: a record over the budget is dark to the crank as it is to settlement, so the crank refuses rather than sells.
    /// @notice A sale at a price settlement could not read would reopen #944's two prices.
    function test_AnOverBudgetRecord_IsDarkToTheCrankAndToSettlementAlike() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(8000);
        rec.setCost(HUB_POLICY_GAS + 50_000);
        vm.expectRevert(RecordUnreadable.selector);
        ace.deleverage(loanId, 0, "");
        _warpAtLeastTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        vm.expectRevert(RecordUnreadable.selector);
        ace.forceClose(loanId);
        rec.setCost(HUB_POLICY_GAS / 2);
        _forceCloseAt(loanId);
        assertEq(read.invPotOf(id, loanId), _atRecord(D, 8000), "a record inside the budget prices the take");
    }

    /// @notice A record inside the budget is cranked exactly as before: the capped read changes nothing for it.
    function test_ARecordInsideTheBudget_TheCrankStillSells() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(8000);
        rec.setCost(HUB_POLICY_GAS / 2);
        (uint256 sold,) = ace.deleverage(loanId, 0, "");
        assertGt(sold, 0, "a record inside the budget is cranked");
    }

    /// @dev One attempt of `call` at exactly `g` gas, rewound: whether it refused `RecordGasShort`, whether it landed, and its selector.
    function _attemptAt(bytes memory call, uint256 g) internal returns (bool short, bool ok, bytes4 why) {
        uint256 snap = vm.snapshotState();
        bytes memory r;
        (ok, r) = address(ace).call{gas: g}(call);
        vm.revertToState(snap);
        if (r.length >= 4) why = bytes4(r);
        short = !ok && why == RecordGasShort.selector;
    }

    /// @dev The least limit at which `call` no longer refuses `RecordGasShort`, searched up from a limit that does.
    function _floorOf(bytes memory call) internal returns (uint256) {
        (uint256 lo, uint256 hi) = (200_000, 3_000_000);
        (bool shortLo,,) = _attemptAt(call, lo);
        (bool shortHi,,) = _attemptAt(call, hi);
        assertTrue(shortLo && !shortHi, "PREMISE: short at 200k, not short at 3M");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool s,,) = _attemptAt(call, mid);
            if (s) lo = mid;
            else hi = mid;
        }
        return hi;
    }

    /// @dev At the exact floor: one gas under it refuses `RecordGasShort`, and at it the record is handed its WHOLE budget.
    /// @dev The record answers zero unless handed nearly the whole budget, so a floor that forwards less reads dark there, which is the tell.
    function _assertTheFloorHandsOverTheBudget(bytes memory call, string memory door) internal {
        rec.setNeeds(HUB_POLICY_GAS - 1_500); // under EIP-150's 1/64 of the budget (~3.4k): a floor forwarding 63/64 reads dark
        uint256 g = _floorOf(call);
        (bool under,,) = _attemptAt(call, g - 1);
        assertTrue(under, string.concat(door, ": one gas under the floor is not RecordGasShort"));
        (, bool ok, bytes4 why) = _attemptAt(call, g);
        assertTrue(why != NoRecordPrice.selector && why != RecordUnreadable.selector, string.concat(door, ": at the floor the record was short-changed"));
        assertTrue(ok || why == PushGasShort.selector, string.concat(door, ": at the floor the door failed for another reason"));
        emit log_named_uint(string.concat(door, ": least limit past the record floor"), g);
    }

    /// @notice THE FLOOR, EXACTLY, at both doors: one gas under refuses `RecordGasShort`; at it the record gets its whole budget, never the fallback.
    function test_TheRecordFloor_IsExact_AtBothDoors() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(6400);
        _warpAtLeastTo(read.loan(loanId).expiry);
        _assertTheFloorHandsOverTheBudget(abi.encodeCall(ace.forceClose, (loanId)), "forceClose");
        _assertTheFloorHandsOverTheBudget(abi.encodeCall(ace.finalize, (loanId)), "finalize");
    }

    /// @notice Inside the term too: a starved `finalize` refuses `RecordGasShort`, and with gas it seizes at the record.
    function test_AStarvedFinalize_RevertsRecordGasShort() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(6400);
        vm.prank(keeper);
        vm.expectRevert(RECORD_GAS_SHORT);
        ace.finalize{gas: 200_000}(loanId);
        vm.prank(keeper);
        ace.finalize(loanId);
        assertEq(read.invPotOf(id, loanId), _atRecord(D, 6400), "with gas enough the seizure takes the debt at the record");
    }

    /// @notice The lens reads the door as the hub does: `settleable` is false while a band-on price is dark inside the grace, true past it.
    function test_Lens_Settleable_HonoursTheDarkPrice() public {
        AceLens lens = new AceLens(address(ace));
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(6400);
        assertTrue(lens.settleable(loanId), "PREMISE: distressed with a live price, settleable");
        rec.setMinPrice(0);
        assertFalse(lens.settleable(loanId), "inside the term a dark price refuses finalize, so not settleable");
        _warpTo(read.loan(loanId).expiry + GRACE - 1);
        assertFalse(lens.settleable(loanId), "inside the grace still not");
        _warpTo(read.loan(loanId).expiry + GRACE);
        assertTrue(lens.settleable(loanId), "past the grace finalize takes the need, so settleable");
        vm.prank(keeper);
        ace.finalize(loanId);
        assertEq(read.invPotOf(id, loanId), _need(D), "and it does");
    }

    /// @notice The lens's crank mirror reads the crank's budget: an over-budget record is refused `RecordUnreadable` at both.
    function test_Lens_DeleverageEligible_ReadsTheCranksBudget() public {
        AceLens lens = new AceLens(address(ace));
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(8000);
        assertTrue(lens.deleverageEligible(loanId), "PREMISE: in the band with a live price, eligible");
        rec.setCost(HUB_POLICY_GAS + 50_000);
        vm.expectRevert(RecordUnreadable.selector);
        ace.deleverage(loanId, 0, "");
        vm.expectRevert(RecordUnreadable.selector);
        lens.deleverageEligible(loanId);
        rec.setCost(HUB_POLICY_GAS / 2);
        assertTrue(lens.deleverageEligible(loanId), "inside the budget it is eligible again, as the crank sells");
    }

    /// @notice A vault's batch end skips a band-on loan whose record is dark, and ends the rest: one dark loan cannot hold the batch for the grace.
    function test_AVaultBatch_SkipsADarkBandOnLoan_AndEndsTheOthers() public {
        uint256 a = _openAt(bandOff, 6500);
        uint256 b = _openAt(id, 6500);
        uint256 c = _openAt(bandOff, 6500);
        _warpBy(STEP);
        _printBps(7000);
        rec.setMinPrice(0);
        _warpAtLeastTo(read.loan(b).expiry);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
        new EndLoanBatch().endAll(address(ace), ids);
        assertTrue(_closed(a) && _closed(c), "the two band-off loans ended");
        assertFalse(_closed(b), "the dark band-on loan was skipped, not ended and not reverted on");
    }

    /// @notice A caller whose limit cannot hand the record its whole budget is refused by name, never settled at the fallback.
    function test_AStarvedCaller_PastTheGrace_RevertsRecordGasShortRatherThanTakeTheNeed() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(7000);
        _warpTo(read.loan(loanId).expiry + GRACE);
        vm.prank(keeper);
        vm.expectRevert(RECORD_GAS_SHORT);
        ace.forceClose{gas: 200_000}(loanId);
        _forceCloseAt(loanId);
        assertEq(read.invPotOf(id, loanId), _atRecord(D, 7000), "with gas enough the live record prices the take");
    }

    /// @notice Inside the term a record that proves distress but cannot price refuses the seizure: darkness moves no value.
    function test_DarkRecordInsideTheTerm_FinalizeRefusesRatherThanTakeAnotherPrice() public {
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(6400);
        rec.setMinPrice(0);
        vm.prank(keeper);
        vm.expectRevert(NoRecordPrice.selector);
        ace.finalize(loanId);
        rec.setMinPrice(_pxOf(6400));
        vm.prank(keeper);
        ace.finalize(loanId);
        assertEq(read.invPotOf(id, loanId), _atRecord(D, 6400), "once it prices, the seizure takes the debt at the record");
    }

    /* ================================ bounds, fuzzed ================================ */

    /// forge-config: default.fuzz.runs = 64
    /// @notice Inside the term the take is the debt at the record plus at most one ceil atom, and it sits under the withdraw line at that record.
    function testFuzz_InTerm_TheTakeIsTheDebtAtTheRecordAndUnderTheLineThere(uint256 thetaBps, uint256 printBps) public {
        thetaBps = bound(thetaBps, 3000, 9000);
        printBps = bound(printBps, 500, thetaBps - 1);
        uint256 loanId = _openAt(id, thetaBps);
        _warpBy(STEP);
        _printBps(printBps);
        uint256 lot = read.loan(loanId).collateralUnits;
        vm.prank(keeper);
        ace.finalize(loanId);
        uint256 pot = read.invPotOf(id, loanId);
        uint256 ps = _pxOf(printBps);
        uint256 room = lot - _sliver(D);
        if (_atRecord(D, printBps) <= room) {
            assertLe(pot, FullMath.mulDiv(D, S, ps) + 1, "the take is the debt at the record plus at most one atom");
            assertGe(FullMath.mulDiv(pot, ps, S), D, "and it is worth the debt at the record");
            assertLt(FullMath.mulDiv(pot - 1, ps, S), D, "and one unit fewer is not: the take is the least that is");
        } else {
            assertEq(pot, room, "past the lot the take is the lot less the sliver");
        }
        assertLt(pot, _lineAt(D, ps), "the take sits under the withdraw line at the record");
        _assertNoShort(loanId);
    }

    /// @dev One stop-edge run: a band-on loan at 65% under a print exactly at its stop level, `x` repaid by `act`, one crank, settled at expiry.
    function _edgeRun(Kind k, Act act, uint256 x) internal returns (Outcome memory o) {
        o.mid = _mid(k);
        _deposit(o.mid, alice, 2 * D);
        _budget();
        o.loanId = _openRun(o.mid, _baseRun(k, 6500, _flatAt(10000, 1)));
        o.lot = read.loan(o.loanId).collateralUnits;
        _warpBy(STEP);
        uint256 edge = FullMath.mulDivRoundingUp(read.triggerPrice(o.loanId), 1e18, 1e18 - 1000 * 1e14);
        rec.setBandPrice(edge);
        rec.setMinPrice(edge);
        if (x != 0 && act == Act.Repay) {
            vm.prank(borrower);
            ace.repay(o.loanId, x);
            o.spent = x;
        } else if (x != 0) {
            _repayFrom(alice, o.loanId, x);
            o.lenderMinted = x;
        }
        _crank(o);
        o.endPx = edge;
        _closeAtTerm(o);
        _tallyOf(o);
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice At the stop edge, a repay down to one atom costs the borrower at most its face plus the fee bound, and the repaying lender gains nothing.
    function testFuzz_StopEdge_ALiftDownToOneAtom_IsBoundedByTheFee(uint256 x, bool noCut) public {
        x = bound(x, 1, D / 20);
        Kind k = noCut ? Kind.BandOnNoCut : Kind.BandOn;
        uint256 snap = vm.snapshotState();
        Outcome memory a = _edgeRun(k, Act.Repay, 0);
        vm.revertToState(snap);
        Outcome memory b = _edgeRun(k, Act.Repay, x);
        vm.revertToState(snap);
        assertEq(a.sold, 0, "fixture: at the stop edge the baseline is stopped");
        assertGt(b.sold, 0, "fixture: the lift clears the stop and the crank sells");
        uint256 melt = a.debtAtClose - b.debtAtClose - x;
        assertGe(_wealth(b) + x + _feeBound(melt, D, k), _wealth(a), "F1.3: the lift cost the borrower more than its face and the fee bound");
        Outcome memory c = _edgeRun(k, Act.LenderRepay, x);
        vm.revertToState(snap);
        assertLe(_lenderWealth(c), _lenderWealth(a) + 2, "F2.1: the lender profited from repaying its own loan over the stop");
    }

    /// @notice The declarations merged into Ace's ABI carry the very selectors `Probe` raises from assembly, so a decoder reads the real refusal.
    function test_TheAbiDeclaredGasShortErrorsMatchWhatProbeRaises() public pure {
        assertEq(IGasShortRefusals.RecordGasShort.selector, RecordGasShort.selector, "RecordGasShort is not the selector Probe raises");
        assertEq(IGasShortRefusals.PolicyGasShort.selector, PolicyGasShort.selector, "PolicyGasShort is not the selector Probe raises");
        assertEq(RECORD_GAS_SHORT, RecordGasShort.selector, "the suite's hashed spelling matches");
    }

    /* ================================ controls ================================ */

    /// @notice Band off, inside the term: #933's capped take, unchanged.
    function test_Control_BandOff_InTerm_TakesTheCappedTake() public {
        uint256 loanId = _openAt(bandOff, 4500);
        _warpBy(STEP);
        _printBps(4400);
        uint256 lot = read.loan(loanId).collateralUnits;
        vm.prank(keeper);
        ace.finalize(loanId);
        assertEq(read.invPotOf(bandOff, loanId), _cappedTake(lot, D), "band off, the in-term take is the capped claim at the trigger");
    }

    /// @notice Band off, at expiry: the need, unchanged, whatever the record reads.
    function test_Control_BandOff_AtExpiry_TakesTheNeed() public {
        uint256 loanId = _openAt(bandOff, 6500);
        _warpBy(STEP);
        _printBps(7000);
        _warpAtLeastTo(read.loan(loanId).expiry);
        _forceCloseAt(loanId);
        assertEq(read.invPotOf(bandOff, loanId), _need(D), "band off, the expiry take is the need");
    }

    /// @notice Band off, a dark record at expiry: settles at once at the need, as before.
    function test_Control_BandOff_DarkAtExpiry_SettlesAtOnce() public {
        uint256 loanId = _openAt(bandOff, 6500);
        rec.setSick(true);
        _warpAtLeastTo(read.loan(loanId).expiry);
        _forceCloseAt(loanId);
        assertEq(read.invPotOf(bandOff, loanId), _need(D), "band off, a dark record still settles at the need");
    }

    /// @notice Recordless, at expiry: the coverage line, unchanged.
    function test_Control_Recordless_AtExpiry_TakesTheCoverageLine() public {
        uint256 loanId = _openAt(recordless, 6500);
        uint256 lot = read.loan(loanId).collateralUnits;
        _warpAtLeastTo(read.loan(loanId).expiry);
        _forceCloseAt(loanId);
        uint256 line = _lineAt(D, par);
        uint256 room = lot - _sliver(D);
        assertEq(read.invPotOf(recordless, loanId), line < room ? line : room, "recordless, the take is the coverage line");
    }
}

/// @notice A vault batch's end step, alone: `AceVaultFlows.endLoan` over each id, as both collect batches call it.
contract EndLoanBatch {
    function endAll(address ace, uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            AceVaultFlows.endLoan(ace, ids[i]);
        }
    }
}
