// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "../fairness/FairnessHarness.sol";
import {NoRecordPrice, RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {AceVaultFlows} from "../../src/vault/libraries/AceVaultFlows.sol";

/// @title AceBandOnTakeAtRecordHardening
/// @notice Hardening rows for the band-on take at the record (#944, #945): exact ceil bounds, the vault skip by selector, the lens's dark reads.
/// @notice And the lender as its own keeper at the stop edge, its lift fuzzed down to one atom.
contract AceBandOnTakeAtRecordHardeningTest is FairnessHarness {
    uint256 internal constant GRACE = 3 days;
    uint256 internal constant EPS_BPS = 100; // the rig's keeper discount
    uint256 internal constant CUT_BPS = 500; // the rig's protocol cut on a restore

    function _openAt(bytes32 mid, uint256 thetaBps) internal returns (uint256 loanId) {
        _deposit(mid, alice, 2 * D);
        _budget();
        loanId = _openRun(mid, _baseRun(Kind.BandOn, thetaBps, _flatAt(10000, 1)));
    }

    function _sliver(uint256 debt) internal view returns (uint256) {
        return FullMath.mulDiv(debt * BOUNTY, S, 10000 * par);
    }

    function _need(uint256 claim) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(claim, S, par);
    }

    /// @dev The ceil, characterised without the hub's helper: the least `t` with `t * ps >= claim * S`.
    function _assertIsTheCeilAt(uint256 t, uint256 claim, uint256 ps, string memory where) internal pure {
        assertTrue(FullMath.mulDiv(t, ps, S) >= claim, string.concat(where, ": the take is worth less than the debt at the record"));
        assertTrue(FullMath.mulDiv(t - 1, ps, S) < claim, string.concat(where, ": one atom less still covers the debt: the take overshoots"));
    }

    /* ================================ the take, exactly ================================ */

    /// forge-config: default.fuzz.runs = 64
    /// @notice In the term, ps under P: the take is EXACTLY the least lot worth the debt at the record, so a round-down or an extra atom fails.
    /// @notice And it sits strictly under the coverage line at that record.
    function testFuzz_InTerm_TheTakeIsTheExactCeilAtTheRecord(uint256 thetaBps, uint256 printBps) public {
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
        uint256 ceilAt = FullMath.mulDivRoundingUp(D, S, ps);
        if (ceilAt <= room) _assertIsTheCeilAt(pot, D, ps, "in term");
        else assertEq(pot, room, "past the lot the take is the lot less the sliver");
        assertGe(pot, _need(D) < room ? _need(D) : room, "never under the need where the lot allows");
        assertLt(pot, FullMath.mulDivRoundingUp(K * D, S, ps * 1e18) + 1, "strictly under the coverage line at the record");
        assertEq(read.unitsOwedOf(loanId, borrower), lot - _sliver(D) - pot, "the borrower is credited the lot less the sliver and the take");
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice At expiry, any record from 5% to 150% of par: the take is the ceil at the record under P, the need over it, the lot past the sliver at most.
    function testFuzz_AtExpiry_TheTakeIsTheCeilUnderPAndTheNeedOverIt(uint256 printBps) public {
        printBps = bound(printBps, 500, 15000);
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(printBps);
        uint256 lot = read.loan(loanId).collateralUnits;
        _warpAtLeastTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 pot = read.invPotOf(id, loanId);
        uint256 ps = _pxOf(printBps);
        uint256 room = lot - _sliver(D);
        uint256 ceilAt = FullMath.mulDivRoundingUp(D, S, ps);
        if (ps >= par) {
            assertEq(pot, _need(D), "at or over the price the need binds");
        } else if (ceilAt <= room) {
            _assertIsTheCeilAt(pot, D, ps, "at expiry");
            assertGe(pot, _need(D), "under the price the debt at the record is at least the need");
        } else {
            assertEq(pot, room, "past the lot the take is the lot less the sliver");
        }
    }

    /// @notice One atom over the price still takes the need, one atom under takes more: the need floor binds on the right side of P.
    function test_AtExpiry_OneAtomEitherSideOfThePrice() public {
        uint256 loanId = _openAt(id, 6500);
        _warpAtLeastTo(read.loan(loanId).expiry);
        uint256 snap = vm.snapshotState();
        rec.setMinPrice(par + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.invPotOf(id, loanId), _need(D), "one atom over the price takes the need");
        vm.revertToState(snap);
        rec.setMinPrice(par - 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 under = FullMath.mulDivRoundingUp(D, S, par - 1);
        assertEq(read.invPotOf(id, loanId), under, "one atom under the price takes the ceil there");
        assertGe(under, _need(D), "PREMISE: the ceil one atom under is at least the need");
    }

    /* ================================ the lender as its own keeper ================================ */

    struct Kept {
        uint256 lenderWealth;
        uint256 debtAtClose;
        uint256 sold;
        uint256 paid; // what the keeper paid for what it bought
    }

    /// @dev One stop-edge run: a band-on loan at 65% under a print exactly at its stop level, `x` repaid by the lender, one crank, settled at expiry.
    function _keptRun(Kind k, uint256 x) internal returns (Kept memory r, uint256 edge) {
        Outcome memory o;
        o.mid = _mid(k);
        _deposit(o.mid, alice, 2 * D);
        _budget();
        o.loanId = _openRun(o.mid, _baseRun(k, 6500, _flatAt(10000, 1)));
        _warpBy(STEP);
        edge = FullMath.mulDivRoundingUp(read.triggerPrice(o.loanId), 1e18, 1e18 - 1000 * 1e14);
        rec.setBandPrice(edge);
        rec.setMinPrice(edge);
        if (x != 0) {
            _repayFrom(alice, o.loanId, x);
            o.lenderMinted = x;
        }
        try ace.deleverage(o.loanId, 0, "") returns (uint256 u, uint256 out) {
            (r.sold, r.paid) = (u, out);
        } catch {}
        o.endPx = edge;
        if (!_closed(o.loanId)) _closeAtTerm(o);
        _tallyOf(o);
        (r.lenderWealth, r.debtAtClose) = (_lenderWealth(o), o.debtAtClose);
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice The market lender repays `x` of its own stopped loan, down to one atom, and cranks it itself.
    /// @notice Its net, its wealth plus the crank's eps, never passes `M eps / ((1-eps)(1-cut)) - x`: at no cut, `M eps / (1-eps) - x`.
    function testFuzz_StopEdge_LenderAsItsOwnKeeper_NetsAtMostTheEpsLessItsFace(uint256 x, bool noCut) public {
        x = bound(x, 1, D / 20);
        Kind k = noCut ? Kind.BandOnNoCut : Kind.BandOn;
        uint256 snap = vm.snapshotState();
        (Kept memory a,) = _keptRun(k, 0);
        vm.revertToState(snap);
        (Kept memory b, uint256 edge) = _keptRun(k, x);
        vm.revertToState(snap);
        assertEq(a.sold, 0, "fixture: at the stop edge the baseline is stopped");
        assertGt(b.sold, 0, "fixture: the lift, however small, admits the crank");
        uint256 gain = _valueAt(b.sold, edge) - b.paid;
        uint256 melt = a.debtAtClose - b.debtAtClose - x;
        uint256 cutBps = noCut ? 0 : CUT_BPS;
        uint256 epsBound = FullMath.mulDiv(melt, EPS_BPS * 1e8, (10000 - EPS_BPS) * (10000 - cutBps) * 10000) + 2;
        assertLe(gain, epsBound, "the keeper's take passed the eps on the melt");
        assertLe(b.lenderWealth + gain + x, a.lenderWealth + epsBound + 2, "the lender as its own keeper netted more than the eps less its face");
    }

    /* ================================ the vault skip, by selector ================================ */

    /// @notice A vault batch skips a band-on loan whose record REVERTS (`RecordUnreadable`), not only one answering zero.
    function test_AVaultBatch_SkipsAnUnreadableRecord() public {
        uint256 a = _openAt(bandOff, 6500);
        uint256 b = _openAt(id, 6500);
        _warpAtLeastTo(read.loan(b).expiry);
        rec.setSick(true);
        vm.expectRevert(RecordUnreadable.selector);
        ace.forceClose(b);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (b, a);
        new HardeningEndLoanBatch().endAll(address(ace), ids);
        assertTrue(_closed(a), "the band-off loan ended");
        assertFalse(_closed(b), "the unreadable band-on loan was skipped");
    }

    /// @notice A vault batch whose limit starves a band-on loan's price read skips it (`RecordGasShort`) rather than reverting the batch.
    function test_AVaultBatch_SkipsAGasShortRecordRead() public {
        uint256 b = _openAt(id, 6500);
        _warpAtLeastTo(read.loan(b).expiry);
        HardeningEndLoanBatch batch = new HardeningEndLoanBatch();
        uint256[] memory ids = new uint256[](1);
        ids[0] = b;
        bool skipped;
        for (uint256 g = 100_000; g <= 400_000 && !skipped; g += 5_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(batch).call{gas: g}(abi.encodeCall(batch.endAll, (address(ace), ids)));
            skipped = ok && !_closed(b);
            vm.revertToState(snap);
        }
        assertTrue(skipped, "no limit let the batch return with the starved loan skipped: RecordGasShort bubbled");
        batch.endAll(address(ace), ids);
        assertTrue(_closed(b), "with gas enough the same batch ends it at the live record");
    }

    /// @notice The skip is by selector: any other refusal still bubbles, so a loan not yet settleable reverts the batch.
    function test_AVaultBatch_StillBubblesAnUnrelatedRefusal() public {
        uint256 b = _openAt(id, 6500);
        uint256[] memory ids = new uint256[](1);
        ids[0] = b;
        HardeningEndLoanBatch batch = new HardeningEndLoanBatch();
        vm.expectRevert(NotSettleable.selector);
        batch.endAll(address(ace), ids);
    }

    /* ================================ the lens's dark reads ================================ */

    /// @notice A reverting price inside the term: the lens reverts `RecordUnreadable` where `finalize` does, never answers false.
    function test_Lens_Settleable_UnreadableInTheTerm_RevertsAsFinalizeDoes() public {
        AceLens lens = new AceLens(address(ace));
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(6400);
        rec.setSick(true);
        vm.expectRevert(RecordUnreadable.selector);
        lens.settleable(loanId);
        vm.prank(keeper);
        vm.expectRevert(RecordUnreadable.selector);
        ace.finalize(loanId);
    }

    /// @notice A reverting price past the grace: the lens answers true and `finalize` takes the need.
    function test_Lens_Settleable_UnreadablePastTheGrace_IsTrue() public {
        AceLens lens = new AceLens(address(ace));
        uint256 loanId = _openAt(id, 6500);
        _warpBy(STEP);
        _printBps(6400);
        rec.setSick(true);
        _warpTo(read.loan(loanId).expiry + GRACE - 1);
        vm.expectRevert(RecordUnreadable.selector);
        lens.settleable(loanId);
        _warpTo(read.loan(loanId).expiry + GRACE);
        assertTrue(lens.settleable(loanId), "past the grace an unreadable price no longer holds the door");
        vm.prank(keeper);
        ace.finalize(loanId);
        assertEq(read.invPotOf(id, loanId), _need(D), "and finalize takes the need");
    }

    /// @notice Band off, the lens reads no price: an answered zero leaves a distressed loan settleable, and finalize seizes.
    function test_Lens_Settleable_BandOff_IgnoresTheDarkPrice() public {
        AceLens lens = new AceLens(address(ace));
        uint256 loanId = _openAt(bandOff, 6500);
        _warpBy(STEP);
        _printBps(6400);
        rec.setMinPrice(0);
        assertTrue(lens.settleable(loanId), "band off, a dark price does not hold the door");
        uint256 lot = read.loan(loanId).collateralUnits;
        vm.prank(keeper);
        ace.finalize(loanId);
        assertEq(read.invPotOf(bandOff, loanId), _cappedTake(lot, D), "band off, a dark price still seizes at #933's capped take");
    }
}

/// @notice A vault batch's end step, alone: `AceVaultFlows.endLoan` over each id.
contract HardeningEndLoanBatch {
    function endAll(address ace, uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            AceVaultFlows.endLoan(ace, ids[i]);
        }
    }
}
