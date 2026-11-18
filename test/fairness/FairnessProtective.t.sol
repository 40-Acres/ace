// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "./FairnessHarness.sol";

/// @title FairnessProtective
/// @notice Family F1, protective actions protect: a bigger pledge, an add to a live loan or a partial repay never raises the lender's shortfall.
/// @notice An add cures distress; a repay never costs the borrower more than its face; a lender's added deposit leaves the other parties untouched.
/// @dev Seizure-marked rows value the seized units at the print that settled them, the lender who sells at seizure; end-marked rows, the one who holds.
/// @dev The #933 seizure rows clamp each trigger to `price / k`: past `k` coverage lines the in-term take is capped there, and that residual is ruled.
contract FairnessProtectiveTest is FairnessHarness {
    /// @dev The pledge grid: (the baseline's trigger, the bigger lot in bps of the baseline's), each crossed by the path before expiry.
    function _pledgeCase(uint256 i) internal pure returns (uint256 thetaBps, uint256 pledgeBps) {
        if (i == 0) return (9000, 15000);
        if (i == 1) return (8000, 12500);
        return (7000, 20000);
    }

    /// @dev The repay grid: (the trigger at open, the partial repay in bps of the debt).
    function _repayCase(uint256 i) internal pure returns (uint256 thetaBps, uint256 repayBps) {
        if (i == 0) return (9000, 2000);
        if (i == 1) return (9000, 4000);
        if (i == 2) return (8000, 2000);
        return (8000, 4000);
    }

    function _pledgePair(Kind k, uint256 thetaBps, uint256 pledgeBps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(k, thetaBps, _glide(10000, 3000, GRID));
        Run memory rb = _baseRun(k, thetaBps, _glide(10000, 3000, GRID));
        rb.pledgeBps = pledgeBps;
        (a, b) = _pairOf(ra, rb);
    }

    function _repayPair(Kind k, uint256 thetaBps, uint256 repayBps, Act act) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(k, thetaBps, _glide(10000, 3000, GRID));
        Run memory rb = _baseRun(k, thetaBps, _glide(10000, 3000, GRID));
        (rb.act, rb.actAt, rb.actAmount) = (act, 0, D * repayBps / 10000);
        (a, b) = _pairOf(ra, rb);
    }

    /* ================================ F1.1 pledge more at open ================================ */

    /// @notice F1.1 at seizure: a bigger lot never raises the selling lender's shortfall, triggers clamped to `max(trigger, price / k)`, the ruled cap.
    function test_F1_1_PledgeMore_Recorded_LenderShortfallAtSeizure() public {
        if (!FIXED_933) return;
        for (uint256 i; i < 3; ++i) {
            (uint256 theta, uint256 pledge) = _pledgeCase(i);
            (Outcome memory a, Outcome memory b) = _pledgePair(Kind.BandOff, theta, pledge);
            assertTrue(a.finalized && b.finalized, "fixture: both runs reach seizure before expiry");
            uint256 tol = _gridTol(D, GRID, theta * 10000 / pledge);
            assertLe(_clampedShortfall(b), _clampedShortfall(a) + tol, "F1.1: the bigger pledge left the selling lender shorter");
        }
    }

    /// @notice F1.1 at seizure on the TRIGGER arm, unclamped: a bigger lot that stays inside `k` lines never leaves the selling lender shorter.
    /// @dev The grid above puts every bigger lot past `k` lines, so the clamp nets each one; here both triggers sit over `price / k`, asserted.
    function test_F1_1_PledgeMoreInsideKLines_Recorded_LenderShortfallAtSeizure_Unclamped() public {
        if (!FIXED_933) return;
        uint256[2] memory thetas = [uint256(9000), 8500];
        uint256[2] memory pledges = [uint256(12000), 11500];
        uint256 clamp = FullMath.mulDiv(par, 1e18, K);
        for (uint256 i; i < 2; ++i) {
            (Outcome memory a, Outcome memory b) = _pledgePair(Kind.BandOff, thetas[i], pledges[i]);
            assertTrue(a.finalized && b.finalized, "fixture: both runs reach seizure before expiry");
            assertGe(FullMath.mulDivRoundingUp(K * b.debtAtClose, S, b.lot * 1e18), clamp, "fixture: the bigger lot's trigger sits over price / k");
            assertGe(FullMath.mulDivRoundingUp(K * a.debtAtClose, S, a.lot * 1e18), clamp, "fixture: and so does the baseline's");
            assertGt(b.pot, a.pot, "the bigger lot's take is bigger: the take follows the trigger");
            uint256 tol = _gridTol(D, GRID, thetas[i] * 10000 / pledges[i]);
            assertLe(_shortfall(b, Mark.Settle), _shortfall(a, Mark.Settle) + tol, "F1.1: the bigger pledge left the selling lender shorter");
        }
    }

    /// @notice F1.1 for the lender who holds what it seized: the bigger pledge never leaves it shorter at the path's end.
    function test_F1_1_PledgeMore_Recorded_HoldingLenderShortfall() public {
        for (uint256 i; i < 3; ++i) {
            (uint256 theta, uint256 pledge) = _pledgeCase(i);
            (Outcome memory a, Outcome memory b) = _pledgePair(Kind.BandOff, theta, pledge);
            assertTrue(a.finalized && b.finalized, "fixture: both runs reach seizure before expiry");
            assertLe(_shortfall(b, Mark.End), _shortfall(a, Mark.End), "F1.1: the bigger pledge left the holding lender shorter");
        }
    }

    /// @notice F1.1 recordless: the market takes the coverage line whatever the lot, so the bigger pledge never leaves the lender shorter.
    function test_F1_1_PledgeMore_Recordless_LenderShortfall() public {
        for (uint256 i; i < 3; ++i) {
            (uint256 theta, uint256 pledge) = _pledgeCase(i);
            (Outcome memory a, Outcome memory b) = _pledgePair(Kind.Recordless, theta, pledge);
            assertLe(_shortfall(b, Mark.End), _shortfall(a, Mark.End), "F1.1: the bigger recordless pledge left the lender shorter");
        }
    }

    /* ================================ F1.1d add collateral to a live loan ================================ */

    /// @dev The F1.1 grid's bigger lot reached by an add after the first print, at par, in place of a bigger pledge at the open.
    function _addPair(Kind k, uint256 thetaBps, uint256 pledgeBps, Act act) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(k, thetaBps, _glide(10000, 3000, GRID));
        Run memory rb = _baseRun(k, thetaBps, _glide(10000, 3000, GRID));
        (rb.act, rb.actAt, rb.actAmount) = (act, 0, FullMath.mulDiv(_units(D, thetaBps), pledgeBps - 10000, 10000));
        (a, b) = _pairOf(ra, rb);
    }

    /// @notice F1.1d at seizure: an add by the holder or a stranger never raises the selling lender's shortfall, triggers clamped to `max(trigger, price / k)`.
    /// @notice The take is the ruled capped take on the lot after the add, so the add's lower trigger is what the lender is whole at, down to `price / k`.
    function test_F1_1d_AddCollateral_Recorded_LenderShortfallAtSeizure() public {
        for (uint256 j; j < 2; ++j) {
            Act act = j == 0 ? Act.AddCollateral : Act.StrangerAdd;
            for (uint256 i; i < 3; ++i) {
                (uint256 theta, uint256 pledge) = _pledgeCase(i);
                (Outcome memory a, Outcome memory b) = _addPair(Kind.BandOff, theta, pledge, act);
                assertTrue(a.finalized && b.finalized, "fixture: both runs reach seizure before expiry");
                assertEq(b.pot, _cappedTake(b.lot, b.debtAtClose), "F1.1d: the take after the add is not the ruled capped take");
                uint256 tol = _gridTol(D, GRID, theta * 10000 / pledge);
                assertLe(_clampedShortfall(b), _clampedShortfall(a) + tol, "F1.1d: the add left the selling lender shorter");
            }
        }
    }

    /// @notice F1.1d inside `k` lines, unclamped: an add that keeps the trigger over `price / k` raises the take with it, and the lender is whole at it.
    function test_F1_1d_AddInsideKLines_Recorded_LenderShortfallAtSeizure_Unclamped() public {
        uint256[2] memory thetas = [uint256(9000), 8500];
        uint256[2] memory pledges = [uint256(12000), 11500];
        uint256 clamp = FullMath.mulDiv(par, 1e18, K);
        for (uint256 j; j < 2; ++j) {
            Act act = j == 0 ? Act.AddCollateral : Act.StrangerAdd;
            for (uint256 i; i < 2; ++i) {
                (Outcome memory a, Outcome memory b) = _addPair(Kind.BandOff, thetas[i], pledges[i], act);
                assertTrue(a.finalized && b.finalized, "fixture: both runs reach seizure before expiry");
                assertGe(FullMath.mulDivRoundingUp(K * b.debtAtClose, S, b.lot * 1e18), clamp, "fixture: the added lot's trigger sits over price / k");
                assertGt(b.pot, a.pot, "F1.1d: the add's lower trigger did not raise the take");
                assertEq(b.pot, _cappedTake(b.lot, b.debtAtClose), "F1.1d: the take after the add is not the ruled capped take");
                uint256 tol = _gridTol(D, GRID, thetas[i] * 10000 / pledges[i]);
                assertLe(_shortfall(b, Mark.Settle), _shortfall(a, Mark.Settle) + tol, "F1.1d: the add left the selling lender shorter");
            }
        }
    }

    /// @notice F1.7: an add cures persisted distress, by the holder or a stranger: the loan leaves the seizure and the borrower keeps more.
    /// @notice The holder's own added units are netted out at the last print; a stranger's are a gift and count.
    /// @dev Band off at 90% of par, the print at 88%: the baseline is seized at book inside the term, and the add drops the trigger under the print first.
    function test_F1_7_AddCollateral_CuresDistress_BorrowerNeverWorse() public {
        for (uint256 j; j < 2; ++j) {
            Act act = j == 0 ? Act.AddCollateral : Act.StrangerAdd;
            for (uint256 i; i < 3; ++i) {
                Run memory ra = _baseRun(Kind.BandOff, 9000, _dropTo(8800, 4));
                Run memory rb = _baseRun(Kind.BandOff, 9000, _dropTo(8800, 4));
                (rb.act, rb.actAt, rb.actAmount) = (act, 1, FullMath.mulDiv(_units(D, 9000), 500 + 500 * i, 10000));
                (Outcome memory a, Outcome memory b) = _pairOf(ra, rb);
                assertTrue(a.finalized && !b.finalized, "fixture: the baseline is seized inside the term and the add cures it");
                assertGe(_wealthNetOfAdds(b), _wealth(a), "F1.7: the cure left the borrower worse off");
            }
        }
    }

    /// @notice F1.8: an add moves none of the lender's quote, and at expiry the take is what it was: the need recorded, the coverage line recordless.
    function test_F1_8_AddCollateral_TheLendersExpiryTakeIsUnchanged() public {
        for (uint256 k; k < 2; ++k) {
            Kind kind = k == 0 ? Kind.BandOff : Kind.Recordless;
            for (uint256 j; j < 2; ++j) {
                Run memory ra = _baseRun(kind, 9000, _flatAt(10000, 4));
                Run memory rb = _baseRun(kind, 9000, _flatAt(10000, 4));
                (rb.act, rb.actAt, rb.actAmount) = (j == 0 ? Act.AddCollateral : Act.StrangerAdd, 0, _units(D, 9000) / 2);
                (Outcome memory a, Outcome memory b) = _pairOf(ra, rb);
                assertTrue(!a.finalized && !b.finalized, "fixture: both runs settle at expiry");
                assertEq(b.pot, a.pot, "F1.8: the add moved the lender's expiry take");
                assertEq(_lenderWealth(b), _lenderWealth(a), "F1.8: the add moved the lender's wealth");
            }
        }
    }

    /* ================================ F1.2 partial repay ================================ */

    /// @notice F1.2 at seizure: a partial repay never raises the selling lender's shortfall, triggers clamped to `max(trigger, price / k)`, the ruled cap.
    function test_F1_2_PartialRepay_Recorded_LenderShortfallAtSeizure() public {
        if (!FIXED_933) return;
        for (uint256 i; i < 4; ++i) {
            (uint256 theta, uint256 repay) = _repayCase(i);
            (Outcome memory a, Outcome memory b) = _repayPair(Kind.BandOff, theta, repay, Act.Repay);
            assertTrue(a.finalized && b.finalized, "fixture: both runs reach seizure before expiry");
            uint256 tol = _gridTol(D, GRID, theta * (10000 - repay) / 10000);
            assertLe(_clampedShortfall(b), _clampedShortfall(a) + tol, "F1.2: the partial repay left the selling lender shorter");
        }
    }

    /// @notice F1.2 for the lender who holds what it seized: a partial repay never leaves it shorter at the path's end.
    function test_F1_2_PartialRepay_Recorded_HoldingLenderShortfall() public {
        for (uint256 i; i < 4; ++i) {
            (uint256 theta, uint256 repay) = _repayCase(i);
            (Outcome memory a, Outcome memory b) = _repayPair(Kind.BandOff, theta, repay, Act.Repay);
            assertLe(_shortfall(b, Mark.End), _shortfall(a, Mark.End), "F1.2: the partial repay left the holding lender shorter");
        }
    }

    /// @notice F1.2 recordless: the repay shrinks the coverage line with the debt, so the lender is never left shorter.
    function test_F1_2_PartialRepay_Recordless_LenderShortfall() public {
        for (uint256 i; i < 4; ++i) {
            (uint256 theta, uint256 repay) = _repayCase(i);
            (Outcome memory a, Outcome memory b) = _repayPair(Kind.Recordless, theta, repay, Act.Repay);
            assertLe(_shortfall(b, Mark.End), _shortfall(a, Mark.End), "F1.2: the recordless partial repay left the lender shorter");
        }
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F1.2 recordless over any trigger, repay and final print.
    function testFuzz_F1_2_PartialRepay_Recordless_LenderShortfall(uint256 thetaBps, uint256 repayBps, uint256 endBps) public {
        thetaBps = bound(thetaBps, 3000, 9500);
        repayBps = bound(repayBps, 100, 8000);
        endBps = bound(endBps, 500, 20000);
        Run memory ra = _baseRun(Kind.Recordless, thetaBps, _dropTo(endBps, 2));
        Run memory rb = _baseRun(Kind.Recordless, thetaBps, _dropTo(endBps, 2));
        (rb.act, rb.actAt, rb.actAmount) = (Act.Repay, 0, D * repayBps / 10000);
        (Outcome memory a, Outcome memory b) = _pairOf(ra, rb);
        assertLe(_shortfall(b, Mark.End), _shortfall(a, Mark.End), "F1.2: the recordless partial repay left the lender shorter");
    }

    /* ================================ F1.3 the borrower's own repay ================================ */

    /// @notice F1.3: a repay never costs the borrower more than its face, so its wealth plus what it paid never falls.
    function test_F1_3_Repay_BorrowerPaysAtMostItsFace() public {
        for (uint256 k; k < 2; ++k) {
            Kind kind = k == 0 ? Kind.BandOff : Kind.Recordless;
            for (uint256 i; i < 4; ++i) {
                (uint256 theta, uint256 repay) = _repayCase(i);
                (Outcome memory a, Outcome memory b) = _repayPair(kind, theta, repay, Act.Repay);
                assertGe(_wealth(b) + b.spent, _wealth(a), "F1.3: the repay cost the borrower more than its face");
            }
        }
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F1.3 band off, over any trigger, repay and two prints.
    function testFuzz_F1_3_Repay_BandOff_BorrowerPaysAtMostItsFace(uint256 thetaBps, uint256 repayBps, uint256 p1, uint256 p2) public {
        thetaBps = bound(thetaBps, 3000, 9500);
        repayBps = bound(repayBps, 100, 8000);
        uint256[] memory path = new uint256[](2);
        (path[0], path[1]) = (bound(p1, 500, 20000), bound(p2, 500, 20000));
        Run memory ra = _baseRun(Kind.BandOff, thetaBps, path);
        Run memory rb = _baseRun(Kind.BandOff, thetaBps, path);
        (rb.act, rb.actAt, rb.actAmount) = (Act.Repay, 0, D * repayBps / 10000);
        (Outcome memory a, Outcome memory b) = _pairOf(ra, rb);
        assertGe(_wealth(b) + b.spent, _wealth(a), "F1.3: the repay cost the borrower more than its face");
    }

    /// @notice F1.3 band on: a repay never costs the borrower more than its face, here on a loan the print has put in distress.
    function test_F1_3_Repay_BandOn_BorrowerPaysAtMostItsFace() public {
        if (!FIXED_933) return;
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _intoTheBand(Act.Repay, 1500 + 500 * i);
            assertGe(_wealth(b) + b.spent, _wealth(a), "F1.3: the repay cost the borrower more than its face");
        }
    }

    /// @dev A band-on loan at 65% of par, the print at 64%: distress for the baseline, which settles at book; the repay lands first in the other run.
    function _intoTheBand(Act act, uint256 repayBps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(Kind.BandOn, 6500, _dropTo(6400, 4));
        Run memory rb = _baseRun(Kind.BandOn, 6500, _dropTo(6400, 4));
        (rb.act, rb.actAt, rb.actAmount) = (act, 1, D * repayBps / 10000);
        (a, b) = _pairOf(ra, rb);
    }

    /* ================================ F1.4 the lender's added deposit ================================ */

    /// @notice F1.4: a lender's added deposit never moves the borrower's or the keeper's outcome, in any class.
    /// @dev It lands at the first print, at par: a deposit is refused while the record sits under the market's price.
    function test_F1_4_LenderDeposit_LeavesTheBorrowerAndKeeperUntouched() public {
        for (uint256 k; k < 3; ++k) {
            Kind kind = k == 0 ? Kind.BandOff : (k == 1 ? Kind.BandOn : Kind.Recordless);
            uint256 theta = kind == Kind.BandOn ? 6500 : 9000;
            Run memory ra = _baseRun(kind, theta, _glide(10000, 3000, 100));
            Run memory rb = _baseRun(kind, theta, _glide(10000, 3000, 100));
            (rb.act, rb.actAt, rb.actAmount) = (Act.Deposit, 0, D);
            (Outcome memory a, Outcome memory b) = _pairOf(ra, rb);
            assertEq(_wealth(b), _wealth(a), "F1.4: the lender's deposit moved the borrower");
            assertEq(b.keeperUnits, a.keeperUnits, "F1.4: the lender's deposit moved the keeper");
            assertEq(_lenderWealth(b), _lenderWealth(a), "F1.4: the deposit is the lender's own money, net of itself");
        }
    }
}
