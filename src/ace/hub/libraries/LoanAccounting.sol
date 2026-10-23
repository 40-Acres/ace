// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Borrower} from "../Borrower.sol";

import {Cfg, LenderCollateral, Loan, LoanBook, Market, Storage} from "../Types.sol";

error NoClaims(); // the loan holds no claim, so there is nothing for a lender credit to ride on
error MeltExceedsClaims(); // the melt asked for more than this loan's claim

/* ========================================================================= */
/*  TABLE OF CONTENTS                                                        */
/*  1. CLAIM     what a loan owes the market, and the melt that pays it down */
/*  2. ESCROW    the origination fee: what the term earned, what it refunds  */
/*  3. CREDIT    what a payout owes a claimant it may not be able to push to */
/* ========================================================================= */

/// @title LoanAccounting
/// @notice What a LOAN owes and to whom: its claim, its fee escrow, and the credits it could not push.
library LoanAccounting {
    /* ========== 1. CLAIM: what the loan owes, and the melt that pays it down ========== */

    /// @dev Credit lender-owed quote against a loan that has a live claim to owe it against.
    /// @dev THE CLAIM CHECK IS THE WHOLE BODY: one lender owns the loan, so nothing is apportioned and the credit is one addition to their pool.
    /// @dev Serves the draw's lender fee AND the fee-escrow earn -- ONE distribution law.
    /// @dev Reverts NoClaims on a retired claim, which is why the fee-escrow earn must precede the melt.
    function creditOverClaims(Market storage M, uint256 loanId, uint256 lenderShare) internal {
        if (_totalClaim(M, loanId) == 0) revert NoClaims();
        Storage.poolOf(M.p).owed += lenderShare;
    }

    /// @dev The lender-share entry. NOTHING FLOORS, so the whole amount lands and no dust needs sweeping.
    function creditLenderShare(Market storage M, uint256 loanId, uint256 amount) internal {
        if (amount == 0) return;
        creditOverClaims(M, loanId, amount);
    }

    /// @dev Loan-scoped melt: retire the loan's one claim by `amount`, exactly and with no remainder.
    /// @dev Repaid principal is the lender's money, never resting cash; only a home migration recycles part of it, below.
    /// @dev NAV-NEUTRAL, and a vault depends on it: `lent` falls by what `owed` rises by, so a repayment moves no share price and is claimable at once.
    function meltLoan(Market storage M, uint256 loanId, uint256 amount) internal {
        meltRecycling(M, loanId, amount, 0);
    }

    /// @dev The melt with `recycle` of the retired claim kept back from `owed`: a home migration funds its successor with it.
    /// @dev The successor's draw then debits `cash` only for its principal less `recycle`, so the lender's pools net to zero.
    /// @dev Until that draw lands the pools read short by `recycle` and the split by the whole melt, mid-body, where the guarded views refuse.
    function meltRecycling(Market storage M, uint256 loanId, uint256 amount, uint256 recycle) internal {
        uint256 cl = M.claim[loanId];
        if (amount > cl) revert MeltExceedsClaims();
        M.claim[loanId] = cl - amount;
        subLent(M, amount);
        Storage.poolOf(M.p).owed += amount - recycle; // the unrecycled repaid principal is the lender's money now, custodied here
    }

    /// @dev Lend `amount` at par: the pool's `lent` and its collateral's split rise at ONE site, so the two cannot drift.
    function addLent(Market storage M, uint256 amount) internal {
        Storage.poolOf(M.p).lent += amount;
        Storage.byCollateralOf(M.p).lent += amount;
    }

    /// @dev Retire `amount` at par from both; the split saturates, being a cap input and never a precondition of any close.
    /// @return x The collateral's split, for the settlement that books its unsold units beside it.
    function subLent(Market storage M, uint256 amount) internal returns (LenderCollateral storage x) {
        Storage.poolOf(M.p).lent -= amount;
        x = Storage.byCollateralOf(M.p);
        x.lent = Math.saturatingSub(x.lent, amount);
    }

    /// @dev The loan's live claim, kept as a NAME: it is the funded test as well as the amount, so no caller reads a bare mapping.
    function _totalClaim(Market storage M, uint256 loanId) private view returns (uint256) {
        return M.claim[loanId];
    }

    /// @dev Collateral units the live claim needs at the market's price. ONE CEIL, on the whole claim.
    /// @dev The ceiling excess it leaves is ONE ATOM, which is the coverage line's epsilon over `requiredAt`.
    /// @dev Read by settlement and the sale's reserve; `Settlement._finalizeLoanFor` and `AceLens.collateralNeeded` repeat this ceil and must match.
    function collateralNeeded(Market storage M, Cfg memory c, uint256 loanId) internal view returns (uint256) {
        uint256 amt = M.claim[loanId];
        if (amt == 0) return 0;
        return FullMath.mulDivRoundingUp(amt, c.unitScale, c.p.price);
    }

    /// @notice One loan's funding floor: the price its claim was funded at, or ZERO once that claim retires.
    /// @dev NOT `c.p.price`, the MARKET's always-live bid: this is one LOAN's funding price, zero the moment that loan has no claim.
    /// @dev USE THIS where zero IS the answer: the sliver, the secured base, the settlement bound and both withdraw gates.
    /// @dev USE `c.p.price` where zero is a bug: anything pricing the MARKET, above all the ask on a settled pot.
    function fundingFloor(Market storage M, Cfg memory c, uint256 id) internal view returns (uint256) {
        return M.claim[id] == 0 ? 0 : c.p.price;
    }

    /// @dev The keeper sliver, IN-KIND and sized off DEBT, never collateral: a title transfer risks no capital.
    /// @dev Converted at the loan's OWN FUNDING FLOOR, so settlement acquires no oracle or staleness branch.
    /// @dev A zero floor (nothing funded) yields a zero sliver rather than a division -- the right answer.
    /// @dev ONE formula for both forceClose branches, so the crank's pay never turns on which one ran.
    /// @dev A PAID settlement takes it off the top before paying claims, so the sale's reserve must carry it too.
    function sliverUnits(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 units) internal view returns (uint256) {
        uint256 floorPrice = fundingFloor(M, c, id);
        /// @dev `debt * bps` stays plain: bps caps at 200, so that pair cannot reach a word on any admissible debt.
        uint256 bty = floorPrice == 0 ? 0 : FullMath.mulDiv(B.loans[id].debt * c.p.settleBountyBps, c.unitScale, 10000 * floorPrice);
        return Math.min(bty, units);
    }

    /* ========== 2. ESCROW: what the term earned, and what it refunds ========== */

    /// @dev The whole protocol fee accrues; there is no carve.
    /// @dev Named rather than inlined despite one `+=`: the solvency identity needs ONE audit point for revenue entering.
    /// @dev NOTHING bypasses it: this `+=` is the only accrual to the pot; the sweep's catch only restores what it cleared.
    function accrueProtocolFee(Market storage M, uint256 amount) internal {
        M.s.protocolRevenue += amount;
    }

    /// @dev The units a disposal may size against: the debt-securing portion, less what settlement must keep.
    /// @dev The CAP stays bare `requiredAt` -- the line's slack secures no debt, and capping on it would sell MORE.
    /// @dev The KEEP is the live claims plus the keeper sliver, which a paid settlement takes off the top before them.
    /// @dev That keep is the RECORD-BACKED shape's: a recordless settlement takes the coverage line, which this would under-reserve.
    /// @dev Genesis refuses a deleverage band with no record, and this function is the decline channel's alone, so the two never meet.
    /// @dev Both keep terms fall with the debt, so today's value bounds every post-sale value and no re-check is owed.
    /// @dev Without it a sequence of cranks walks the position under its own funding floor and settlement comes up short.
    /// @dev A zero floor saturates `req` AND zeroes the keep, since no floor means no live claim: the whole position is then sellable.
    function securedBase(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 units) internal view returns (uint256) {
        uint256 req = Borrower.requiredAt(c, B.loans[id].debt, fundingFloor(M, c, id));
        uint256 keep = collateralNeeded(M, c, id) + sliverUnits(B, M, c, id, units);
        uint256 sellable = Math.saturatingSub(units, keep);
        return Math.min(req, sellable);
    }

    /// @dev Split the fee escrow at a clean close: lenders take the served term, the rest waits for refund.
    /// @dev MUST run BEFORE meltLoan retires the claim, or creditOverClaims reverts NoClaims.
    /// @dev Storage only. The quote has sat in the hub since open, outside `cash` and the lender's pools.
    /// @dev The floor is against the borrower, matching every other fee rounding on this path.
    function earnFeeEscrowProRata(LoanBook storage B, Market storage M, uint256 id) internal {
        uint256 e = B.feeEscrowOf[id];
        if (e == 0) return;
        Loan storage L = B.loans[id];
        uint256 remaining = Math.saturatingSub(L.expiry, block.timestamp);
        uint256 refund = L.tenor == 0 ? 0 : FullMath.mulDiv(e, remaining, L.tenor);
        refund = Math.min(refund, e); // a rolled-free term can never out-refund the pot
        B.feeEscrowOf[id] = refund;
        _earn(M, id, e - refund);
    }

    /// @dev Settlement earns the whole fee escrow: the lender bore the outcome, so none of it is refundable.
    function earnFeeEscrowFully(LoanBook storage B, Market storage M, uint256 id) internal {
        uint256 e = B.feeEscrowOf[id];
        if (e == 0) return;
        B.feeEscrowOf[id] = 0;
        _earn(M, id, e);
    }

    /// @dev Credit an earned slice over the loan's live claim; its one lender takes it whole, so no dust is left.
    function _earn(Market storage M, uint256 id, uint256 earned) private {
        creditLenderShare(M, id, earned);
    }

    /// @dev Credit a closed loan's unearned fee escrow to the borrower; never lender capital.
    /// @dev A pure reclassification between two pots of the identity: no token moves at credit time.
    function refundFeeEscrow(LoanBook storage B, Market storage M, uint256 id, address to) internal {
        uint256 r = B.feeEscrowOf[id];
        if (r > 0) {
            B.feeEscrowOf[id] = 0;
            creditQuote(B, M, id, to, r);
        }
    }

    /* ========== 3. CREDIT: what a payout owes a claimant it cannot push to ========== */

    /// @notice A payout was booked to a claimant rather than pushed; `claimOwed` moves it.
    event OwedCredited(uint256 indexed loanId, address indexed claimant, uint256 units, uint256 amount);

    /// @dev Books collateral units to a claimant; they stay on the loan's retired ledger until claimed.
    function creditUnits(LoanBook storage B, uint256 id, address who, uint256 units) internal {
        if (units == 0) return;
        B.unitsOwed[id][who] += units;
        emit OwedCredited(id, who, units, 0);
    }

    /// @dev Books quote to a claimant; it rests at the hub inside `quoteOwedTotal` until claimed.
    /// @dev The aggregate is the market's, so the solvency identity reads one number per market.
    function creditQuote(LoanBook storage B, Market storage M, uint256 id, address who, uint256 amount) internal {
        if (amount == 0) return;
        B.quoteOwed[id][who] += amount;
        M.s.quoteOwedTotal += amount;
        emit OwedCredited(id, who, 0, amount);
    }
}
