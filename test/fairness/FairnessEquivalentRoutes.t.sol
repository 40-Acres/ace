// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FairnessHarness} from "./FairnessHarness.sol";
import {YesPolicy} from "../utils/RollPolicyMocks.sol";
import {TenorOutOfRange} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";

/// @title FairnessEquivalentRoutes
/// @notice Family F5, equivalent routes cost the same, or the difference is the disclosed one.
/// @notice An extension and a same-market refinance to one end differ by the unexpired term's non-refundable fee; repay-then-reopen IS the refinance.
/// @notice A top-up costs an open of its amount for the term left; a refinance to the same debt re-charges the whole principal; no top-up undercuts `minTenor`.
/// @dev The F5.1-F5.2 routes land three days into a seven-day loan; the top-up routes, on a loan of the longest term, on the band-off market at par.
contract FairnessEquivalentRoutesTest is FairnessHarness {
    uint64 internal constant ELAPSED = 3 days;

    struct End {
        uint256 borrowerQuote; // wallet plus owed on both ids
        uint256 borrowerUnits; // wallet, owed on both ids, and locked in the live loan
        uint256 lenderQuote;
        uint256 debt;
        uint64 expiry;
        uint256 escrow;
    }

    function _start() internal returns (uint256 loanId) {
        _deposit(bandOff, alice, 2 * D);
        _budget();
        _setPolicy(alice, address(new YesPolicy()));
        loanId = _openRun(bandOff, _baseRun(Kind.BandOff, 7000, _flatAt(10000, 1)));
        _warpBy(ELAPSED);
    }

    function _endOf(uint256 oldId, uint256 liveId) internal view returns (End memory e) {
        Loan memory l = read.loan(liveId);
        e.borrowerQuote = usdc.balanceOf(borrower) + read.quoteOwedOf(oldId, borrower) + (liveId == oldId ? 0 : read.quoteOwedOf(liveId, borrower));
        e.borrowerUnits = coll.balanceOf(borrower) + read.unitsOwedOf(oldId, borrower) + l.collateralUnits;
        (uint256 resting, uint256 lent, uint256 owed) = read.lenderPools(alice, address(usdc));
        e.lenderQuote = usdc.balanceOf(alice) + resting + lent + owed;
        (e.debt, e.expiry, e.escrow) = (l.debt, l.expiry, read.feeEscrowOf(liveId));
    }

    /// @dev The same-market refinance at the same debt: repay the new fee first, so the draw retires the old debt, then re-term into the loan's own market.
    function _refinanceInPlace(uint256 loanId) internal returns (uint256 newId) {
        uint256 gap = LoanMath.originationFee(D, TEN7, BASE);
        vm.startPrank(borrower);
        ace.repay(loanId, gap);
        newId = ace.refinanceTo(MigrateArgs(loanId, bandOff, D, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        vm.stopPrank();
    }

    /* ================================ F5.1 extension against refinance ================================ */

    /// @notice F5.1: extending and refinancing in place reach one end, the same debt, expiry and escrow, and the refinance costs exactly more.
    /// @notice The gap is the unexpired term's fee less its refundable escrow: a refinance closes the old loan early, and only the escrow refunds.
    function test_F5_1_ExtensionAndSameMarketRefinance_DifferByTheUnexpiredTermsNonRefundableFee() public {
        uint256 loanId = _start();
        uint256 snap = vm.snapshotState();
        uint256 before = usdc.balanceOf(borrower);
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        uint256 costExtend = before - usdc.balanceOf(borrower);
        End memory ext = _endOf(loanId, loanId);
        vm.revertToState(snap);
        uint256 newId = _refinanceInPlace(loanId);
        uint256 costRefinance = before - usdc.balanceOf(borrower);
        End memory refi = _endOf(loanId, newId);

        assertEq(refi.debt, ext.debt, "F5.1: the routes reach different debts");
        assertEq(refi.expiry, ext.expiry, "F5.1: the routes reach different expiries");
        assertApproxEqAbs(refi.escrow, ext.escrow, 4, "F5.1: the routes leave different refundable escrow");
        uint256 unexpired = LoanMath.originationFee(D, TEN7 - ELAPSED, BASE);
        uint256 nonRefundable = unexpired - LoanMath.escrowCut(unexpired);
        assertGe(costRefinance, costExtend, "F5.1: the refinance came cheaper than the extension");
        assertApproxEqAbs(costRefinance - costExtend, nonRefundable, 4, "F5.1: the gap is not the unexpired term's non-refundable fee");
    }

    /* ================================ F5.2 repay-then-reopen against refinance ================================ */

    /// @notice F5.2: repaying in full and reopening the same lot, principal and term is the same-market refinance, to the atom, for both parties.
    function test_F5_2_RepayThenReopen_CostsWhatTheAtomicRefinanceCosts() public {
        uint256 loanId = _start();
        uint256 snap = vm.snapshotState();
        uint256 units = read.loan(loanId).collateralUnits;
        vm.startPrank(borrower);
        ace.repay(loanId, D);
        ace.claimOwed(loanId, borrower);
        uint256 reopened = ace.open(bandOff, units, D, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        End memory two = _endOf(loanId, reopened);
        vm.revertToState(snap);
        End memory one = _endOf(loanId, _refinanceInPlace(loanId));

        assertEq(one.borrowerQuote, two.borrowerQuote, "F5.2: the borrower's quote differs by route");
        assertEq(one.borrowerUnits, two.borrowerUnits, "F5.2: the borrower's units differ by route");
        assertEq(one.lenderQuote, two.lenderQuote, "F5.2: the lender's quote differs by route");
        assertEq(one.debt, two.debt, "F5.2: the debt differs by route");
        assertEq(one.expiry, two.expiry, "F5.2: the expiry differs by route");
        assertEq(one.escrow, two.escrow, "F5.2: the escrow differs by route");
    }

    /* ================================ F5.4-F5.6 a top-up ================================ */

    struct Split {
        uint256 payout; // quote the borrower took
        uint256 protocolCut; // the market's revenue rise
        uint256 tickCut; // the lender's owed rise, less the old escrow it earned
        uint256 escrowCut; // the escrow's rise, less the old escrow's unearned part
    }

    function _longLoan() internal returns (uint256 loanId) {
        _deposit(bandOff, alice, 4 * D);
        _budget();
        loanId = _openLong(bandOff, D, 5000);
    }

    function _owed() internal view returns (uint256 owed) {
        (,, owed) = read.lenderPools(alice, address(usdc));
    }

    /// @dev A top-up of `amount` on `loanId` now, split three ways; the old escrow earns to now first, and its earned part is the rest of `owed`'s rise.
    function _topUpSplit(uint256 loanId, uint256 amount) internal returns (Split memory s) {
        uint256 e0 = read.feeEscrowOf(loanId);
        uint256 r0 = _unearned(loanId, e0);
        (uint256 bal0, uint256 rev0, uint256 owed0) = (usdc.balanceOf(borrower), read.protocolRevenue(bandOff), _owed());
        vm.prank(borrower);
        ace.drawMore(loanId, amount, OpenBounds(0, 0, 0));
        s.payout = usdc.balanceOf(borrower) - bal0;
        s.protocolCut = read.protocolRevenue(bandOff) - rev0;
        s.tickCut = _owed() - owed0 - (e0 - r0);
        s.escrowCut = read.feeEscrowOf(loanId) - r0;
    }

    /// @dev A fresh open of `amount` for `term` in the same market now, split the same way.
    function _openSplit(uint256 amount, uint64 term) internal returns (Split memory s) {
        uint256 units = _units(amount, 5000);
        coll.mint(borrower, units);
        (uint256 bal0, uint256 rev0, uint256 owed0) = (usdc.balanceOf(borrower), read.protocolRevenue(bandOff), _owed());
        vm.prank(borrower);
        uint256 fresh = ace.open(bandOff, units, amount, term, borrower, OpenBounds(0, 0, 0));
        s.payout = usdc.balanceOf(borrower) - bal0;
        s.protocolCut = read.protocolRevenue(bandOff) - rev0;
        s.tickCut = _owed() - owed0;
        s.escrowCut = read.feeEscrowOf(fresh);
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F5.4: a top-up costs exactly what an open of the same amount for the term left costs, split the same three ways.
    function testFuzz_F5_4_ATopUpCostsAnOpenOfTheSameAmountForTheTermLeft(uint256 amount, uint256 elapsed) public {
        uint256 loanId = _longLoan();
        amount = bound(amount, MIN_PRINCIPAL, D / 4);
        _warpBy(bound(elapsed, 1, MAX_T - TEN7));
        uint64 term = uint64(read.loan(loanId).expiry - _now());
        uint256 snap = vm.snapshotState();
        Split memory top = _topUpSplit(loanId, amount);
        vm.revertToState(snap);
        Split memory fresh = _openSplit(amount, term);
        assertEq(top.payout, fresh.payout, "F5.4: the top-up's payout differs from an open of the same amount for the term left");
        assertEq(top.protocolCut, fresh.protocolCut, "F5.4: the protocol's cut differs");
        assertEq(top.tickCut, fresh.tickCut, "F5.4: the lender's cut differs");
        assertEq(top.escrowCut, fresh.escrowCut, "F5.4: the refundable escrow differs");
    }

    /// @notice F5.5: topping up by `refinanceTo` to the same debt and expiry re-charges the fee on the whole principal; `drawMore` charges the amount's.
    /// @notice The refinance refunds the old escrow's unearned part in cash where the top-up carries it, so the cash gap is the two fees less that refund.
    /// @notice With the refundable escrow counted, the refinance is dearer by exactly the whole principal's non-refundable fee less the amount's.
    function test_F5_5_ARefinanceToTheSameDebtCostsTheFeeOnTheWholePrincipal() public {
        uint256 loanId = _longLoan();
        _setPolicy(alice, address(new YesPolicy()));
        _warpBy(7 days);
        uint64 term = uint64(read.loan(loanId).expiry - _now());
        uint256 amount = D / 4;
        uint256 r0 = _unearned(loanId, read.feeEscrowOf(loanId));
        uint256 bal0 = usdc.balanceOf(borrower);
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        ace.drawMore(loanId, amount, OpenBounds(0, 0, 0));
        (uint256 gotTop, uint256 escTop, Loan memory lt) = (usdc.balanceOf(borrower) - bal0, read.feeEscrowOf(loanId), read.loan(loanId));
        vm.revertToState(snap);
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, bandOff, D + amount, term, OpenBounds(0, 0, 0), 0, address(0)));
        uint256 gotRefi = usdc.balanceOf(borrower) + read.quoteOwedOf(loanId, borrower) - bal0;
        (uint256 escRefi, Loan memory lr) = (read.feeEscrowOf(newId), read.loan(newId));
        assertEq(lr.debt, lt.debt, "F5.5: the routes reach different debts");
        assertEq(lr.expiry, lt.expiry, "F5.5: the routes reach different expiries");
        uint256 whole = LoanMath.originationFee(D + amount, term, BASE);
        uint256 part = LoanMath.originationFee(amount, term, BASE);
        assertEq(gotTop - gotRefi, whole - part - r0, "F5.5: the cash gap is not the whole principal's fee less the amount's and the refund");
        uint256 nonRefundable = (whole - LoanMath.escrowCut(whole)) - (part - LoanMath.escrowCut(part));
        assertEq(gotTop + escTop - gotRefi - escRefi, nonRefundable, "F5.5: with the escrow counted, the gap is not the non-refundable fee's");
    }

    /// forge-config: default.fuzz.runs = 64
    /// @notice F5.6, B-2: no top-up costs less than an open of the same amount for `minTenor`, the cheapest term an open sells; under it a top-up refuses.
    function testFuzz_F5_6_NoTopUpCostsLessThanTheFeeOnMinTenor(uint256 amount, uint256 at) public {
        uint256 loanId = _longLoan();
        amount = bound(amount, MIN_PRINCIPAL, D / 4);
        uint64 x = read.loan(loanId).expiry;
        _warpTo(bound(at, _now() + 1, uint256(x) - 1));
        uint256 floorFee = LoanMath.originationFee(amount, TEN7, BASE);
        vm.prank(borrower);
        if (x - _now() < TEN7) {
            vm.expectRevert(TenorOutOfRange.selector);
            ace.drawMore(loanId, amount, OpenBounds(0, 0, 0));
            return;
        }
        assertGe(ace.drawMore(loanId, amount, OpenBounds(0, 0, 0)), floorFee, "F5.6: a top-up cost less than the fee on minTenor");
    }
}
