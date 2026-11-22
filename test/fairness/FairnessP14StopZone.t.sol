// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "./FairnessHarness.sol";
import {DeleverageStopped} from "../../src/ace/hub/Deleverage.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";

/// @title FairnessP14StopZone
/// @notice Audit run 2026-11-15-f3aae2, phase 14: #933's band-on faces whose baseline is NOT a seizure in the term, and the low-trigger ones.
/// @notice S1: a loan resting between its trigger and the stop is neither cranked nor finalized; it reaches expiry untouched and settles there.
/// @notice S2: a distressed band-on loan is seized inside the term; a repay that lifts it into the band trades that seizure for a crank.
/// @notice #944 and #945 are fixed by settling a band-on loan at the record at both doors, the price the crank sells at.
/// @notice Every lift then costs the borrower at most F2.3b's fee bound on the melt it admits, at every cut, and the lender gains nothing by it.
/// @dev The measurement rows assert only the fixture and log the signed difference; the property rows assert the ruled bound.
contract FairnessP14StopZoneTest is FairnessHarness {
    bool internal constant FIXED_944 = true; // #944: a lift over the stop costs the borrower at most the crank's fee bound
    bool internal constant FIXED_945 = true; // #945: a lift out of distress costs at most the fee bound at every trigger

    uint256 internal constant THETA = 6500; // the fixture trigger, in bps of par
    uint256 internal constant REST = 7000; // the print: over the trigger, under the stop level at 7222

    /// @dev The two band-on markets every property row runs on: the rig's, with a 5% cut, and the same with none.
    function _kinds() internal pure returns (Kind[2] memory) {
        return [Kind.BandOn, Kind.BandOnNoCut];
    }

    /// @dev A band-on loan at 65% of par under a flat print at 70%: stopped and not distressed, so the baseline reaches expiry untouched.
    function _fromTheStopZone(Kind k, Act act, uint256 repayBps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(k, THETA, _dropTo(REST, 4));
        Run memory rb = _baseRun(k, THETA, _dropTo(REST, 4));
        (rb.act, rb.actAt, rb.actAmount) = (act, 1, D * repayBps / 10000);
        (a, b) = _pairOf(ra, rb);
    }

    function _assertFixture(Outcome memory a, Outcome memory b) internal pure {
        assertTrue(!a.finalized && a.sold == 0, "fixture: the baseline is neither seized nor cranked inside the term");
        assertTrue(!b.finalized && b.sold > 0, "fixture: the moved loan is cranked and never seized inside the term");
    }

    /// @dev The debt the cranks melted in `b`, the baseline uncranked: the debt gap less what was repaid.
    function _melt(Outcome memory a, Outcome memory b, uint256 repaid) internal pure returns (uint256) {
        return a.debtAtClose - b.debtAtClose - repaid;
    }

    /// @dev Logs `x - y` under the label its sign picks.
    function _signed(string memory xOverY, string memory yOverX, uint256 x, uint256 y) internal {
        if (x >= y) emit log_named_decimal_uint(xOverY, x - y, 6);
        else emit log_named_decimal_uint(yOverX, y - x, 6);
    }

    /* ================================ S1 the stop zone ================================ */

    /// @notice The fixture, proved: at the 70% print the crank refuses by the STOP and the seizure refuses as not settleable; a 4% repay admits the crank.
    function test_P14_S1_Fixture_TheBaselineIsStoppedAndNotDistressed() public {
        _deposit(id, alice, 2 * D);
        _budget();
        uint256 loanId = _openRun(id, _baseRun(Kind.BandOn, THETA, _flatAt(10000, 1)));
        _warpBy(STEP);
        _printBps(REST);
        vm.expectRevert(DeleverageStopped.selector);
        ace.deleverage(loanId, 0, "");
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanId);
        _repayFrom(stranger, loanId, D * 400 / 10000);
        (uint256 sold,) = ace.deleverage(loanId, 0, "");
        assertGt(sold, 0, "fixture: the repay lifts the loan over the stop and the crank sells");
        assertFalse(_closed(loanId), "fixture: the crank restores, it does not close");
    }

    /// @notice F2.1 from the stop zone: a stranger's partial repay costs the borrower at most F2.3b's fee bound on the melt it admits, at every cut.
    function test_F2_1_StrangerRepay_BandOn_StopZone_BorrowerLosesAtMostTheFeeBound() public {
        if (!FIXED_944) return;
        Kind[2] memory ks = _kinds();
        for (uint256 j; j < 2; ++j) {
            for (uint256 i; i < 3; ++i) {
                uint256 bps = 400 + 400 * i;
                (Outcome memory a, Outcome memory b) = _fromTheStopZone(ks[j], Act.StrangerRepay, bps);
                _assertFixture(a, b);
                uint256 bound = _feeBound(_melt(a, b, D * bps / 10000), D, ks[j]);
                assertGe(_wealth(b) + bound, _wealth(a), "F2.1: the stranger's repay cost the borrower more than the fee bound");
            }
        }
    }

    /// @notice F1.3 from the stop zone: a repay costs the borrower at most its face plus F2.3b's fee bound on the melt it admits, at every cut.
    function test_F1_3_Repay_BandOn_StopZone_BorrowerPaysAtMostItsFaceAndTheFeeBound() public {
        if (!FIXED_944) return;
        Kind[2] memory ks = _kinds();
        for (uint256 j; j < 2; ++j) {
            for (uint256 i; i < 3; ++i) {
                uint256 bps = 400 + 400 * i;
                (Outcome memory a, Outcome memory b) = _fromTheStopZone(ks[j], Act.Repay, bps);
                _assertFixture(a, b);
                uint256 bound = _feeBound(_melt(a, b, b.spent), D, ks[j]);
                assertGe(_wealth(b) + b.spent + bound, _wealth(a), "F1.3: the repay cost the borrower more than its face and the fee bound");
            }
        }
    }

    /// @notice F2.1 from the stop zone: the market lender gains nothing by repaying a slice of its own stopped loan, at every cut.
    /// @notice As its own keeper it also takes the eps on what the crank sold, which is the crank's price, never a gain from the repay.
    function test_F2_1_LenderRepay_BandOn_StopZone_LenderGainsNothing() public {
        if (!FIXED_944) return;
        Kind[2] memory ks = _kinds();
        for (uint256 j; j < 2; ++j) {
            for (uint256 i; i < 3; ++i) {
                uint256 bps = 400 + 400 * i;
                (Outcome memory a, Outcome memory b) = _fromTheStopZone(ks[j], Act.LenderRepay, bps);
                _assertFixture(a, b);
                assertLe(_lenderWealth(b), _lenderWealth(a) + 2, "F2.1: the lender profited from repaying its own stopped loan");
                uint256 bound = _feeBound(_melt(a, b, D * bps / 10000), D, ks[j]);
                assertGe(_wealth(b) + bound, _wealth(a), "F2.1: the lender's repay cost the borrower more than the fee bound");
                uint256 eps = _valueAt(b.sold, b.endPx) * 100 / 10000;
                _signed("S1: the lender as its own keeper nets", "S1: the lender as its own keeper loses", _lenderWealth(b) + eps, _lenderWealth(a));
            }
        }
    }

    /// @notice F3 across the stop: a higher print costs the borrower at most the fee bound on what the crank melts, at every cut.
    function test_F3_HigherPath_BandOn_AcrossTheStop_BorrowerLosesAtMostTheFeeBound() public {
        if (!FIXED_944) return;
        Kind[2] memory ks = _kinds();
        for (uint256 j; j < 2; ++j) {
            for (uint256 i; i < 2; ++i) {
                (Outcome memory a, Outcome memory b) = _stopOrBand(ks[j], i == 0 ? 7300 : 7500);
                _assertFixture(a, b);
                uint256 bound = _feeBound(_melt(a, b, 0), D, ks[j]);
                assertGe(_wealth(b) + bound, _wealth(a), "F3: the higher print cost the borrower more than the fee bound");
            }
        }
    }

    /// @dev The same loan and print, the second run pledging 18% more: its trigger falls to 55% of par, which the 70% print leaves in the band.
    function _pledgedOverTheStop(Kind k) internal returns (Outcome memory a, Outcome memory b, uint256 lotA, uint256 lotB) {
        Run memory ra = _baseRun(k, THETA, _dropTo(REST, 4));
        Run memory rb = _baseRun(k, THETA, _dropTo(REST, 4));
        rb.pledgeBps = 11818;
        (a, b) = _pairOf(ra, rb);
        lotA = _units(D, THETA);
        lotB = FullMath.mulDiv(lotA, rb.pledgeBps, 10000);
    }

    /// @dev The borrower's wealth less its own lot at the path's last price: what the loan left it, whatever it pledged.
    function _net(Outcome memory o, uint256 lot) internal pure returns (uint256) {
        return _wealth(o) - _valueAt(lot, o.endPx);
    }

    /// @notice F1.1 for the borrower across the stop: a bigger pledge costs the borrower at most the fee bound on what the crank melts.
    function test_F1_1_PledgeMore_BandOn_AcrossTheStop_BorrowerLosesAtMostTheFeeBound() public {
        if (!FIXED_944) return;
        Kind[2] memory ks = _kinds();
        for (uint256 j; j < 2; ++j) {
            (Outcome memory a, Outcome memory b, uint256 lotA, uint256 lotB) = _pledgedOverTheStop(ks[j]);
            _assertFixture(a, b);
            uint256 bound = _feeBound(_melt(a, b, 0), D, ks[j]);
            assertGe(_net(b, lotB) + bound, _net(a, lotA), "F1.1: the bigger pledge cost the borrower more than the fee bound");
        }
    }

    /// @dev A band-on loan at 65% of par: a print at 70% rests under the stop, one at `highBps` sits in the band over it.
    function _stopOrBand(Kind k, uint256 highBps) internal returns (Outcome memory a, Outcome memory b) {
        (a, b) = _pairOf(_baseRun(k, THETA, _dropTo(REST, 4)), _baseRun(k, THETA, _dropTo(highBps, 4)));
    }

    /// @dev The stop-zone loan, a stranger adding `addBps` of its lot after the 70% print: the trigger falls far enough that the print clears the stop.
    function _strangerAddFromTheStopZone(Kind k, uint256 addBps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(k, THETA, _dropTo(REST, 4));
        Run memory rb = _baseRun(k, THETA, _dropTo(REST, 4));
        (rb.act, rb.actAt, rb.actAmount) = (Act.StrangerAdd, 1, FullMath.mulDiv(_units(D, THETA), addBps, 10000));
        (a, b) = _pairOf(ra, rb);
    }

    /// @notice F2.13 from the stop zone: a stranger's add costs the borrower at most the fee bound on what the crank melts, the units it gave counted.
    function test_F2_13_StrangerAdd_BandOn_StopZone_BorrowerLosesAtMostTheFeeBound() public {
        if (!FIXED_944) return;
        Kind[2] memory ks = _kinds();
        for (uint256 j; j < 2; ++j) {
            for (uint256 i; i < 3; ++i) {
                (Outcome memory a, Outcome memory b) = _strangerAddFromTheStopZone(ks[j], 400 + 200 * i);
                _assertFixture(a, b);
                uint256 bound = _feeBound(_melt(a, b, 0), D, ks[j]);
                assertGe(_wealth(b) + bound, _wealth(a), "F2.13: the stranger's add cost the borrower more than the fee bound");
            }
        }
    }

    /// @notice S1 measured on the rig's 5% cut: a stranger's repay, the borrower's own, the lender's, a higher print, a bigger pledge and a stranger's add.
    function test_Measure_944_TheStopZoneLifts() public {
        for (uint256 i; i < 3; ++i) {
            uint256 bps = 400 + 400 * i;
            (Outcome memory a, Outcome memory b) = _fromTheStopZone(Kind.BandOn, Act.StrangerRepay, bps);
            _assertFixture(a, b);
            _signed("S1 a stranger's repay: the borrower gains", "S1 a stranger's repay: the borrower loses", _wealth(b), _wealth(a));
            (a, b) = _fromTheStopZone(Kind.BandOn, Act.Repay, bps);
            _signed(
                "S1 its own repay: the borrower gains past its face", "S1 its own repay: the borrower loses past its face", _wealth(b) + b.spent, _wealth(a)
            );
            (a, b) = _fromTheStopZone(Kind.BandOn, Act.LenderRepay, bps);
            _signed("S1 the lender's own repay: the lender gains", "S1 the lender's own repay: the lender loses", _lenderWealth(b), _lenderWealth(a));
        }
        (Outcome memory c, Outcome memory d) = _stopOrBand(Kind.BandOn, 7500);
        _assertFixture(c, d);
        _signed("S1 a higher print: the borrower gains", "S1 a higher print: the borrower loses", _wealth(d), _wealth(c));
        (Outcome memory e, Outcome memory f, uint256 lotA, uint256 lotB) = _pledgedOverTheStop(Kind.BandOn);
        _assertFixture(e, f);
        _signed("S1 a bigger pledge: the borrower gains", "S1 a bigger pledge: the borrower loses", _net(f, lotB), _net(e, lotA));
        (Outcome memory g, Outcome memory h) = _strangerAddFromTheStopZone(Kind.BandOn, 400);
        _assertFixture(g, h);
        _signed("S1 a stranger's add: the borrower gains", "S1 a stranger's add: the borrower loses", _wealth(h), _wealth(g));
    }

    /* ================================ the $1,000 example, pinned at both cuts ================================ */

    uint256 internal constant D1K = 1_000e6; // the example's debt: a lot of 2,000 at par, trigger 70%, the record at 75%, under the stop

    /// @dev The path starts at 75%: a print at par would sit exactly on a 70% trigger's band level, which the ceil puts inside the band.
    function _thousand(Kind k, Act act) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(k, 7000, _flatAt(7500, 5));
        Run memory rb = _baseRun(k, 7000, _flatAt(7500, 5));
        (ra.principal, rb.principal) = (D1K, D1K);
        (rb.act, rb.actAt, rb.actAmount) = (act, 1, 40e6);
        (a, b) = _pairOf(ra, rb);
        _assertFixture(a, b);
    }

    /// @notice The $1,000 example: a $40 repay lifting the loan over the stop costs the borrower 4.07 in all at no cut, and 40.56 at the rig's 5%.
    /// @notice The lender gains nothing from repaying $40 of its own loan at either cut.
    function test_Pinned_TheThousandDollarExample() public {
        (Outcome memory a, Outcome memory b) = _thousand(Kind.BandOnNoCut, Act.Repay);
        emit log_named_decimal_uint("$1,000 at no cut: the $40 repay's whole cost to the borrower", _wealth(a) - _wealth(b), 6);
        assertApproxEqAbs(_wealth(a) - _wealth(b), 4.065321e6, 10, "the $40 repay costs the borrower 4.065321 in all at no cut, the plan's 4.06");
        assertGe(_wealth(b) + b.spent + _feeBound(_melt(a, b, b.spent), D1K, Kind.BandOnNoCut), _wealth(a), "F1.3: inside the fee bound at no cut");
        (a, b) = _thousand(Kind.BandOn, Act.Repay);
        emit log_named_decimal_uint("$1,000 at the 5% cut: the $40 repay's whole cost to the borrower", _wealth(a) - _wealth(b), 6);
        assertApproxEqAbs(_wealth(a) - _wealth(b), 40.560219e6, 10, "the $40 repay costs the borrower 40.560219 in all at the 5% cut, the plan's ~40.60");
        assertGe(_wealth(b) + b.spent + _feeBound(_melt(a, b, b.spent), D1K, Kind.BandOn), _wealth(a), "F1.3: inside the fee bound at the 5% cut");
        for (uint256 j; j < 2; ++j) {
            (a, b) = _thousand(_kinds()[j], Act.LenderRepay);
            assertLe(_lenderWealth(b), _lenderWealth(a) + 2, "the lender gains nothing from repaying its own loan");
        }
    }

    /* ================================ S2 from distress, at a low trigger ================================ */

    /// @dev A band-on loan at `thetaBps`, the print a point under it: the baseline is seized inside the term; `act` lands first in the other run.
    function _fromDistress(Kind k, uint256 thetaBps, Act act, uint256 repayBps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(k, thetaBps, _dropTo(thetaBps - 100, 4));
        Run memory rb = _baseRun(k, thetaBps, _dropTo(thetaBps - 100, 4));
        (rb.act, rb.actAt, rb.actAmount) = (act, 1, D * repayBps / 10000);
        (a, b) = _pairOf(ra, rb);
        assertTrue(a.finalized && !b.finalized && b.sold > 0, "fixture: the baseline is seized inside the term and the repaid loan is cranked");
        _recordTake(a, _units(D, thetaBps), thetaBps - 100);
    }

    /// @dev The baseline's measured pot IS the record take: the debt at the record, ceiled, never under the need, never past the lot less the sliver.
    function _recordTake(Outcome memory a, uint256 lot, uint256 printBps) internal view {
        uint256 need = FullMath.mulDivRoundingUp(D, S, par);
        uint256 atRecord = FullMath.mulDivRoundingUp(D, S, _pxOf(printBps));
        uint256 take = atRecord > need ? atRecord : need;
        uint256 room = lot - FullMath.mulDiv(D * BOUNTY, S, 10000 * par);
        assertEq(a.pot, take < room ? take : room, "the baseline's measured pot is the debt at the record");
    }

    /// @notice F1.3 at 45%, 55% and 65% triggers: a repay out of distress costs the borrower at most its face plus the fee bound, at every cut.
    function test_F1_3_Repay_BandOn_LowTrigger_UnderTheRecordTake() public {
        if (!FIXED_945) return;
        Kind[2] memory ks = _kinds();
        for (uint256 j; j < 2; ++j) {
            for (uint256 i; i < 3; ++i) {
                (Outcome memory a, Outcome memory b) = _fromDistress(ks[j], 4500 + 1000 * i, Act.Repay, 1500);
                uint256 bound = _feeBound(_melt(a, b, b.spent), D, ks[j]);
                assertGe(_wealth(b) + b.spent + bound, _wealth(a), "F1.3: the repay cost the borrower more than its face and the fee bound");
            }
        }
    }

    /// @notice F2.1 at 45%, 55% and 65% triggers: a stranger's repay out of distress costs the borrower at most the fee bound, at every cut.
    function test_F2_1_StrangerRepay_BandOn_LowTrigger_UnderTheRecordTake() public {
        if (!FIXED_945) return;
        Kind[2] memory ks = _kinds();
        for (uint256 j; j < 2; ++j) {
            for (uint256 i; i < 3; ++i) {
                (Outcome memory a, Outcome memory b) = _fromDistress(ks[j], 4500 + 1000 * i, Act.StrangerRepay, 1500);
                uint256 bound = _feeBound(_melt(a, b, D * 1500 / 10000), D, ks[j]);
                assertGe(_wealth(b) + bound, _wealth(a), "F2.1: the stranger's repay cost the borrower more than the fee bound");
            }
        }
    }

    /// @notice F2.1 at 45%, 55% and 65% triggers: the market lender never profits from repaying a slice of its own distressed loan, at every cut.
    function test_F2_1_LenderRepay_BandOn_LowTrigger_LenderGainsNothing() public {
        if (!FIXED_945) return;
        Kind[2] memory ks = _kinds();
        for (uint256 j; j < 2; ++j) {
            for (uint256 i; i < 3; ++i) {
                (Outcome memory a, Outcome memory b) = _fromDistress(ks[j], 4500 + 1000 * i, Act.LenderRepay, 1500);
                assertLe(_lenderWealth(b), _lenderWealth(a) + 2, "F2.1: the lender profited from repaying its own distressed loan");
            }
        }
    }

    /// @notice S2 measured on the rig's 5% cut at a 45% and a 55% trigger: the borrower's repay, a stranger's, and the lender's own.
    function test_Measure_945_TheLowTriggerLifts() public {
        for (uint256 i; i < 2; ++i) {
            uint256 theta = 4500 + 1000 * i;
            (Outcome memory a, Outcome memory b) = _fromDistress(Kind.BandOn, theta, Act.Repay, 1500);
            _signed(
                "S2 its own repay: the borrower gains past its face", "S2 its own repay: the borrower loses past its face", _wealth(b) + b.spent, _wealth(a)
            );
            (a, b) = _fromDistress(Kind.BandOn, theta, Act.StrangerRepay, 1500);
            _signed("S2 a stranger's repay: the borrower gains", "S2 a stranger's repay: the borrower loses", _wealth(b), _wealth(a));
            (a, b) = _fromDistress(Kind.BandOn, theta, Act.LenderRepay, 1500);
            _signed("S2 the lender's own repay: the lender gains", "S2 the lender's own repay: the lender loses", _lenderWealth(b), _lenderWealth(a));
        }
    }
}
