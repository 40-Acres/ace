// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FairnessHarness} from "./FairnessHarness.sol";
import {DeleverageStopped} from "../../src/ace/hub/Deleverage.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";

/// @title FairnessP14StopZone
/// @notice Audit run 2026-11-15-f3aae2, phase 14: the band-on faces of #933 whose baseline is NOT a seizure inside the term.
/// @notice S1: a loan resting between its trigger and the stop is neither cranked nor finalized; it settles at need at expiry, the ruling's residual.
/// @notice So a repay that lifts it over the stop trades that settlement for a crank, and no change to the in-term take reaches the baseline.
/// @notice S2: the ruled take is capped at the coverage line, so under `price / k` a distressed loan's book settlement stays the cheap door.
/// @dev S1 runs both legs on the code as it stands. S2 runs both legs on the capped take as built; only the uncapped take it is compared with is modelled.
/// @dev The PoC rows assert the inversion and stay green; the property rows assert the declared direction and run once the flag is true.
contract FairnessP14StopZoneTest is FairnessHarness {
    bool internal constant FIXED_P14_STOPZONE = false; // #944: a repay over the stop no longer costs the borrower its book close
    bool internal constant FIXED_P14_CAPPED = false; // #945: the capped in-term take leaves no low-trigger face standing

    uint256 internal constant THETA = 6500; // the fixture trigger, in bps of par
    uint256 internal constant REST = 7000; // the print: over the trigger, under the stop level at 7222

    /// @dev A band-on loan at 65% of par under a flat print at 70%: stopped and not distressed, so the baseline reaches expiry untouched.
    function _fromTheStopZone(Act act, uint256 repayBps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(Kind.BandOn, THETA, _dropTo(REST, 4));
        Run memory rb = _baseRun(Kind.BandOn, THETA, _dropTo(REST, 4));
        (rb.act, rb.actAt, rb.actAmount) = (act, 1, D * repayBps / 10000);
        (a, b) = _pairOf(ra, rb);
    }

    function _assertFixture(Outcome memory a, Outcome memory b) internal pure {
        assertTrue(!a.finalized && a.sold == 0, "fixture: the baseline is neither seized nor cranked inside the term");
        assertTrue(!b.finalized && b.sold > 0, "fixture: the repaid loan is cranked and never seized inside the term");
    }

    /* ================================ S1 the stop zone, measured ================================ */

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

    /// @notice F2.1 from the stop zone: a stranger's partial repay never leaves the borrower worse off.
    function test_F2_1_StrangerRepay_BandOn_StopZone_BorrowerNeverWorse() public {
        if (!FIXED_P14_STOPZONE) return;
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _fromTheStopZone(Act.StrangerRepay, 400 + 400 * i);
            assertGe(_wealth(b), _wealth(a), "F2.1: the stranger's repay left the borrower worse off");
        }
    }

    /// @notice S1 as the code stands: a stranger GIVES the borrower 4%, 8% or 12% of its debt, and the borrower ends poorer.
    /// @notice The repay lifts the loan over the stop, the crank sells at the record, and the expiry settlement at the price is lost on the melt.
    function test_P14_S1_StopZone_AStrangersRepayMovesTheLoanFromItsExpirySettlementIntoTheCrank() public {
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _fromTheStopZone(Act.StrangerRepay, 400 + 400 * i);
            _assertFixture(a, b);
            assertLt(_wealth(b), _wealth(a), "S1: the stranger's repay leaves the borrower worse off");
            emit log_named_decimal_uint("S1 stop zone: the borrower's loss to a stranger's repay", _wealth(a) - _wealth(b), 6);
        }
    }

    /// @notice F1.3 from the stop zone: a repay never costs the borrower more than its face.
    function test_F1_3_Repay_BandOn_StopZone_BorrowerPaysAtMostItsFace() public {
        if (!FIXED_P14_STOPZONE) return;
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _fromTheStopZone(Act.Repay, 400 + 400 * i);
            assertGe(_wealth(b) + b.spent, _wealth(a), "F1.3: the repay cost the borrower more than its face");
        }
    }

    /// @notice S1 for the borrower's own protective repay: it costs the face and then the gap between the crank and the expiry settlement.
    function test_P14_S1_StopZone_TheBorrowersRepayOverTheStopCostsMoreThanItsFace() public {
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _fromTheStopZone(Act.Repay, 400 + 400 * i);
            _assertFixture(a, b);
            assertLt(_wealth(b) + b.spent, _wealth(a), "S1: the repay over the stop costs the borrower more than its face");
            emit log_named_decimal_uint("S1 stop zone: the borrower's loss beyond its repay", _wealth(a) - _wealth(b) - b.spent, 6);
        }
    }

    /// @notice S1 in the market lender's hands: it repays a slice of its own stopped loan, takes the crank's par, and nets a gain the borrower pays.
    /// @dev No grant, no extension and no distress: the lever is `repay`, which anyone may call, and the gain is largest at the smallest slice.
    function test_P14_S1_StopZone_TheLenderProfitsFromRepayingItsOwnStoppedLoan() public {
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _fromTheStopZone(Act.LenderRepay, 400 + 400 * i);
            _assertFixture(a, b);
            assertGt(_lenderWealth(b), _lenderWealth(a), "S1: the lender profits from repaying its own stopped loan");
            assertLt(_wealth(b), _wealth(a), "S1: and the borrower pays for it");
            emit log_named_decimal_uint("S1 stop zone: the lender's net gain from its own repay", _lenderWealth(b) - _lenderWealth(a), 6);
            emit log_named_decimal_uint("S1 stop zone: the borrower's loss to the lender's repay", _wealth(a) - _wealth(b), 6);
        }
    }

    /// @notice F3 across the stop: a higher print never leaves the borrower worse off.
    function test_F3_HigherPath_BandOn_AcrossTheStop_BorrowerNeverWorse() public {
        if (!FIXED_P14_STOPZONE) return;
        for (uint256 i; i < 2; ++i) {
            (Outcome memory a, Outcome memory b) = _stopOrBand(i == 0 ? 7300 : 7500);
            assertGe(_wealth(b), _wealth(a), "F3: the higher print left the borrower worse off");
        }
    }

    /// @notice S1 as price monotonicity: a print under the stop settles at need at expiry, a higher one in the band is cranked, and the borrower is poorer.
    function test_P14_S1_StopZone_AHigherPrintOverTheStopLeavesTheBorrowerPoorer() public {
        for (uint256 i; i < 2; ++i) {
            (Outcome memory a, Outcome memory b) = _stopOrBand(i == 0 ? 7300 : 7500);
            _assertFixture(a, b);
            assertLt(_wealth(b), _wealth(a), "S1: the higher print leaves the borrower poorer");
            emit log_named_decimal_uint("S1 stop zone: the borrower's loss to a higher print", _wealth(a) - _wealth(b), 6);
        }
    }

    /// @dev The same loan and print, the second run pledging 18% more: its trigger falls to 55% of par, which the 70% print leaves in the band.
    function _pledgedOverTheStop() internal returns (Outcome memory a, Outcome memory b, uint256 lotA, uint256 lotB) {
        Run memory ra = _baseRun(Kind.BandOn, THETA, _dropTo(REST, 4));
        Run memory rb = _baseRun(Kind.BandOn, THETA, _dropTo(REST, 4));
        rb.pledgeBps = 11818;
        (a, b) = _pairOf(ra, rb);
        lotA = _units(D, THETA);
        lotB = FullMath.mulDiv(lotA, rb.pledgeBps, 10000);
    }

    /// @dev The borrower's wealth less its own lot at the path's last price: what the loan left it, whatever it pledged.
    function _net(Outcome memory o, uint256 lot) internal pure returns (uint256) {
        return _wealth(o) - _valueAt(lot, o.endPx);
    }

    /// @notice F1.1 for the borrower across the stop: a bigger pledge never leaves the borrower with less than the smaller one did.
    function test_F1_1_PledgeMore_BandOn_AcrossTheStop_BorrowerNeverWorse() public {
        if (!FIXED_P14_STOPZONE) return;
        (Outcome memory a, Outcome memory b, uint256 lotA, uint256 lotB) = _pledgedOverTheStop();
        assertGe(_net(b, lotB), _net(a, lotA), "F1.1: the bigger pledge left the borrower worse off");
    }

    /// @notice S1 as the pledge: the bigger pledge lowers the trigger, the same print now sits in the band, and the crank sells what expiry would not take.
    /// @notice The lender is better off for it, so F1.1 holds for the lender in this pair; the value comes from the borrower who pledged more.
    function test_P14_S1_StopZone_PledgingMoreMovesTheLoanIntoTheBandAndCostsTheBorrower() public {
        (Outcome memory a, Outcome memory b, uint256 lotA, uint256 lotB) = _pledgedOverTheStop();
        _assertFixture(a, b);
        assertLt(_net(b, lotB), _net(a, lotA), "S1: the bigger pledge leaves the borrower worse off");
        assertGt(_lenderWealth(b), _lenderWealth(a), "S1: and the lender better off");
        emit log_named_decimal_uint("S1 stop zone: the borrower's loss to its own bigger pledge", _net(a, lotA) - _net(b, lotB), 6);
        emit log_named_decimal_uint("S1 stop zone: the lender's gain from the bigger pledge", _lenderWealth(b) - _lenderWealth(a), 6);
    }

    /// @dev A band-on loan at 65% of par: a print at 70% rests under the stop, one at `highBps` sits in the band over it.
    function _stopOrBand(uint256 highBps) internal returns (Outcome memory a, Outcome memory b) {
        (a, b) = _pairOf(_baseRun(Kind.BandOn, THETA, _dropTo(REST, 4)), _baseRun(Kind.BandOn, THETA, _dropTo(highBps, 4)));
    }

    /* ================================ #944 FA-1 a stranger's add into the stop zone ================================ */

    /// @dev The stop-zone loan, a stranger adding `addBps` of its lot after the 70% print: the trigger falls far enough that the print clears the stop.
    function _strangerAddFromTheStopZone(uint256 addBps) internal returns (Outcome memory a, Outcome memory b) {
        Run memory ra = _baseRun(Kind.BandOn, THETA, _dropTo(REST, 4));
        Run memory rb = _baseRun(Kind.BandOn, THETA, _dropTo(REST, 4));
        (rb.act, rb.actAt, rb.actAmount) = (Act.StrangerAdd, 1, FullMath.mulDiv(_units(D, THETA), addBps, 10000));
        (a, b) = _pairOf(ra, rb);
    }

    /// @notice F2.13 from the stop zone: a stranger's add never leaves the borrower worse off, counting the units it gave.
    function test_F2_13_StrangerAdd_BandOn_StopZone_BorrowerNeverWorse() public {
        if (!FIXED_P14_STOPZONE) return;
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _strangerAddFromTheStopZone(400 + 200 * i);
            assertGe(_wealth(b), _wealth(a), "F2.13: the stranger's add left the borrower worse off");
        }
    }

    /// @notice #944 FA-1 as the code stands: a stranger GIVES the borrower 4%, 6% or 8% of its lot, and the borrower ends poorer, the gift counted.
    /// @notice The add lowers the trigger until the 70% print clears the stop: the crank then sells at the record what expiry would have settled at need.
    /// @dev `addCollateral` is one of #944's three routes, beside a small repay and a higher print; the ruling keeps the verb open and pins the route here.
    function test_KnownViolation_944_AStrangersAddMovesTheLoanFromItsExpirySettlementIntoTheCrank() public {
        for (uint256 i; i < 3; ++i) {
            (Outcome memory a, Outcome memory b) = _strangerAddFromTheStopZone(400 + 200 * i);
            _assertFixture(a, b);
            assertLt(_wealth(b), _wealth(a), "#944 FA-1: the stranger's add leaves the borrower worse off");
            emit log_named_decimal_uint("#944 FA-1: the borrower's loss to a stranger's add, the gift counted", _wealth(a) - _wealth(b), 6);
        }
    }

    /* ================================ S2 the capped take, measured ================================ */

    struct Model {
        uint256 capped; // the baseline's pot under the ruled take: max(need, min(ceil(lot / k), coverage line))
        uint256 uncapped; // the same without the cap: max(need, ceil(lot / k))
    }

    /// @dev A band-on loan at `thetaBps`, the print one point under it: distress for the baseline, which is seized at book; `act` lands first in the other run.
    function _fromDistress(uint256 thetaBps, Act act, uint256 repayBps) internal returns (Outcome memory a, Outcome memory b, Model memory m) {
        Run memory ra = _baseRun(Kind.BandOn, thetaBps, _dropTo(thetaBps - 100, 4));
        Run memory rb = _baseRun(Kind.BandOn, thetaBps, _dropTo(thetaBps - 100, 4));
        (rb.act, rb.actAt, rb.actAmount) = (act, 1, D * repayBps / 10000);
        (a, b) = _pairOf(ra, rb);
        assertTrue(a.finalized && !b.finalized && b.sold > 0, "fixture: the baseline is seized inside the term and the repaid loan is cranked");
        m = _ruledPot(a, _units(D, thetaBps));
    }

    /// @dev The ruled in-term take on the baseline's own lot and debt; the measured pot must BE the capped take, so `capped` rows read the real seizure.
    function _ruledPot(Outcome memory a, uint256 lot) internal view returns (Model memory m) {
        uint256 need = FullMath.mulDivRoundingUp(D, S, par);
        uint256 atTrigger = FullMath.mulDivRoundingUp(lot, 1e18, K);
        uint256 line = FullMath.mulDivRoundingUp(K * D, S, par * 1e18) + 1;
        m.uncapped = atTrigger > need ? atTrigger : need;
        uint256 inner = atTrigger < line ? atTrigger : line;
        m.capped = inner > need ? inner : need;
        assertEq(a.pot, m.capped, "the baseline's measured pot is the ruled capped take");
    }

    /// @dev The baseline borrower's wealth were its seizure to take `pot`: the extra units leave its residual at the path's last price.
    function _borrowerAt(Outcome memory a, uint256 pot) internal pure returns (uint256) {
        return _wealth(a) - _valueAt(pot - a.pot, a.endPx);
    }

    /// @dev The baseline lender's wealth were its seizure to take `pot`.
    function _lenderAt(Outcome memory a, uint256 pot) internal pure returns (uint256) {
        return _lenderWealth(a) + _valueAt(pot - a.pot, a.endPx);
    }

    /// @notice F1.3 under the capped take, at a low trigger: a repay never costs the borrower more than its face.
    function test_F1_3_Repay_BandOn_LowTrigger_UnderTheCappedTake() public {
        if (!FIXED_P14_CAPPED) return;
        (Outcome memory a, Outcome memory b, Model memory m) = _fromDistress(4500, Act.Repay, 1500);
        assertGe(_wealth(b) + b.spent, _borrowerAt(a, m.capped), "F1.3: the repay cost the borrower more than its face");
    }

    /// @notice S2: at a 45% trigger the borrower's repay into the band still costs more than its face once the baseline takes the CAPPED pot.
    /// @notice The uncapped take would close it; at the suite's 65% trigger the capped take closes it too, which is why the suite predicts a flip.
    function test_P14_S2_CappedTake_TheBorrowersRepayIntoTheBandStillCostsMoreThanItsFaceAtALowTrigger() public {
        (Outcome memory a, Outcome memory b, Model memory m) = _fromDistress(4500, Act.Repay, 1500);
        uint256 route = _wealth(b) + b.spent;
        assertLt(route, _wealth(a), "S2: it survives the capped take, measured");
        assertGe(route, _borrowerAt(a, m.uncapped), "S2: the uncapped take would have closed it");
        emit log_named_decimal_uint("S2 45% trigger: the loss beyond the repay under the capped take", _wealth(a) - route, 6);

        (a, b, m) = _fromDistress(5500, Act.Repay, 1500);
        route = _wealth(b) + b.spent;
        assertLt(route, _wealth(a), "S2: at a 55% trigger it survives the capped take too");
        emit log_named_decimal_uint("S2 55% trigger: the loss beyond the repay under the capped take", _wealth(a) - route, 6);

        (a, b, m) = _fromDistress(6500, Act.Repay, 1500);
        assertGe(_wealth(b) + b.spent, _wealth(a), "S2: at the suite's 65% trigger the capped take closes it");
    }

    /// @notice S2 for a stranger's repay: under the capped take it still leaves a low-trigger borrower worse off.
    function test_P14_S2_CappedTake_AStrangersRepayStillLeavesALowTriggerBorrowerWorseOff() public {
        (Outcome memory a, Outcome memory b, Model memory m) = _fromDistress(4500, Act.StrangerRepay, 1500);
        assertLt(_wealth(b), _wealth(a), "S2: the stranger's repay still leaves the borrower worse off");
        emit log_named_decimal_uint("S2 45% trigger: the borrower's loss to a stranger's repay under the capped take", _wealth(a) - _wealth(b), 6);
    }

    /// @notice S2 for the market lender: under the capped take it still profits from repaying a slice of its own distressed low-trigger loan.
    function test_P14_S2_CappedTake_TheLenderStillProfitsFromRepayingItsOwnDistressedLoanAtALowTrigger() public {
        (Outcome memory a, Outcome memory b, Model memory m) = _fromDistress(4500, Act.LenderRepay, 1500);
        assertGt(_lenderWealth(b), _lenderWealth(a), "S2: the lender still profits under the capped take");
        assertLe(_lenderWealth(b), _lenderAt(a, m.uncapped), "S2: the uncapped take would have closed it");
        emit log_named_decimal_uint("S2 45% trigger: the lender's net gain under the capped take", _lenderWealth(b) - _lenderWealth(a), 6);
    }
}
