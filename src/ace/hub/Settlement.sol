// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Borrower} from "./Borrower.sol";

import {LoanAccounting} from "./libraries/LoanAccounting.sol";
import {Recipients} from "./libraries/Recipients.sol";
import {Cfg, LenderCollateral, LenderUnresolved, Loan, LoanBook, Market, Shortfall, Storage} from "./Types.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";

error LoanClosed(); // the loan is retired: no settlement verb touches it
error NotExpired(); // the tenor has not run out yet
error NoRecord(); // record-less market: distress is unknowable, so finalize never opens; the loan still settles at tenor
error NotSettleable(); // not YET settleable: callers retry on this one
error NoClaimLeg(); // both destinations zero: one zero skips a leg, two claim nothing and is a caller bug

/* ========================================================================= */
/*  TABLE OF CONTENTS                                                        */
/*  1. SETTLE   the terminal crank: title moves, claims convert, loan closes */
/* ========================================================================= */

/// @title Settlement
/// @notice Where a loan ENDS: the title transfer that closes it for good, on distress or at expiry.
/// @notice Liquidation here is a title transfer, not a trade -- selling against a LIVE loan is `Deleverage`.
/// @dev Every `msg.sender` here is the EXTERNAL caller of the crank, which a periphery sponsor pays against.
library Settlement {
    using SafeERC20 for IERC20;

    /// @dev `collateralUnits` is the lot net of the keeper sliver, which the executor is credited separately.
    event Finalized(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor);
    /// @dev `collateralUnits` is the lot net of the keeper sliver, which the executor is credited separately.
    event ForceClosed(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor);
    /// @notice A zero destination on either leg means the claimant declined it and its credit is still outstanding.
    /// @dev So `toUnits == 0` and `units == 0` say different things: declined, versus asked and there was nothing.
    event OwedClaimed(uint256 indexed loanId, address indexed claimant, address toUnits, address toQuote, uint256 units, uint256 amount);

    /* ====== 1. SETTLE: the terminal crank ====== */

    /// @notice Settle a loan whose distress has persisted for the full settle window. Final.
    /// @dev The ONLY precondition is the derived one: a recovery print makes this revert, no verb.
    /// @dev POLICY-BLIND, deliberately: persistent distress is what the lenders' settlement right is for.
    function finalize(LoanBook storage B, Market storage M, Cfg memory c, uint256 id) public {
        Loan storage L = B.loans[id];
        if (L.closedAt != 0) revert LoanClosed();
        if (c.p.record == address(0)) revert NoRecord();
        /// @dev A record that cannot answer is UNREADABLE, never not-yet-settleable: the two are different facts.
        if (!Borrower.persistedBelowSettleOrRevert(c, Borrower.triggerPrice(L, c))) revert NotSettleable();
        uint256 units = L.collateralUnits;
        L.collateralUnits = 0;
        L.closedAt = uint64(block.timestamp);
        (uint256 bad, uint256 left) = _settle(B, M, c, id, L.borrower, units);
        emit Finalized(id, left, bad, msg.sender);
    }

    /// @notice Settle an expired loan by claim conversion; equity above what the market takes is CREDITED to the borrower. Final.
    /// @notice A RECORDLESS market takes the whole coverage line rather than the claims' need, so its borrower may keep nothing.
    /// @notice THE one settle verb at tenor, from the expiry second; it extends nothing, and from that second no extension or refinance lands.
    /// @dev MUST EXECUTE: it asks no roll policy and calls no record; it reads only whether a record is WIRED, which widens the bound.
    /// @dev Its one external call is `retireCustody`, a storage hop; what can stop it is the caller's own limit, an id naming no loan, or the guard.
    function forceClose(LoanBook storage B, Market storage M, Cfg memory c, uint256 id) public {
        Loan storage L = B.loans[id];
        if (L.closedAt != 0) revert LoanClosed();
        if (block.timestamp < L.expiry) revert NotExpired();
        uint256 units = L.collateralUnits;
        L.collateralUnits = 0;
        L.closedAt = uint64(block.timestamp);
        (uint256 bad, uint256 left) = _settle(B, M, c, id, L.borrower, units);
        emit ForceClosed(id, left, bad, msg.sender);
    }

    /// @notice The CLEAN close: credit the collateral to the holder, credit the unearned fee escrow.
    /// @dev Two callers: a closing `repay` and a closing deleverage sale.
    /// @dev The caller split the fee escrow FIRST; this credits whatever the term did not earn.
    /// @dev CREDITED, not pushed: a holder the collateral or the quote refuses must not brick the close.
    function closeClean(LoanBook storage B, Market storage M, Cfg memory c, uint256 id) internal {
        Loan storage L = B.loans[id];
        L.closedAt = uint64(block.timestamp);
        uint256 units = L.collateralUnits;
        L.collateralUnits = 0;
        if (units > 0) IPositionManager(c.positionManager).retireCustody(id, units);
        LoanAccounting.creditUnits(B, id, L.borrower, units);
        LoanAccounting.refundFeeEscrow(B, M, id, L.borrower);
    }

    /// @dev The shared title-transfer core: the keeper sliver off the top, none where the market pays no bounty, then the claim.
    /// @dev The claim bears its own write-down; what the market's bound leaves is CREDITED to the borrower.
    /// @dev MAKES NO EXTERNAL COLLATERAL TRANSFER: every leg is a ledger write, so settlement is total.
    /// @dev A short close RECORDS what the claim did not get, post-sliver: per loan, plus the market's total.
    /// @dev `retireCustody` is the ONE external call, and both records are written AFTER it, never before.
    function _settle(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, address borrower, uint256 units)
        private
        returns (uint256 badDebt, uint256 unitsAfterSliver)
    {
        /// @dev Before any external call: _finalizeLoanFor zeroes the claims this credits.
        /// @dev Settlement earns the whole fee escrow -- the lender bore the outcome, so none is refundable.
        LoanAccounting.earnFeeEscrowFully(B, M, id);
        /// @dev ONE custody move, and it moves no token: the whole lot leaves the live ledger at once.
        /// @dev What the hub does next is pure bookkeeping over units the custodian already holds for this loan.
        if (units > 0) IPositionManager(c.positionManager).retireCustody(id, units);
        uint256 sliver = LoanAccounting.sliverUnits(B, M, c, id, units);
        if (sliver > 0) LoanAccounting.creditUnits(B, id, msg.sender, sliver);
        units -= sliver;

        uint256 need = LoanAccounting.collateralNeeded(M, c, id);
        uint256 toMarket = _marketBound(B, M, c, id, need, units);
        uint256 toClaims = Math.min(toMarket, need);
        LoanAccounting.creditUnits(B, id, borrower, units - toMarket);
        /// @dev BEFORE `_finalizeLoanFor`, which zeroes the claim this spread is conditioned on.
        if (toMarket > toClaims) _spreadCoverage(M, id, toMarket - toClaims);
        badDebt = _finalizeLoanFor(M, c, id, toClaims);
        if (need > toClaims) {
            B.shortfallOf[id] = Shortfall(need - toClaims, badDebt); // sparse: a covered close writes nothing
            M.s.realizedLossAtBook += badDebt; // the market's running total, the per-loan record's aggregate
        }
        unitsAfterSliver = units;
    }

    /// @notice Pull what this loan credited the caller: collateral units, quote, or both.
    /// @notice Pull-based, no deadline, nothing lost -- an absent claimant keeps their money.
    /// @dev `to` is the CALLER'S OWN choice, which is what makes the claim itself unbrickable.
    /// @dev After recipient validation, an empty entry pays zero without moving either asset.
    /// @dev CEI: each entry is zeroed before its asset moves, so a re-entrant claim finds nothing.
    /// @param id The loan the credit sits against.
    /// @param to Where to send it.
    /// @return units Collateral units delivered.
    /// @return amount Quote delivered.
    function claimOwed(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, address to) public returns (uint256 units, uint256 amount) {
        return claimOwed(B, M, c, id, to, to);
    }

    /// @notice The same pull, with a destination per asset: a ZERO destination SKIPS that leg entirely.
    /// @notice A skipped leg moves no token and keeps its credit, so it stays claimable rather than being forfeited.
    /// @notice That is what frees a claimant when one of the two tokens refuses every address the other accepts.
    /// @dev Zero is safe to spend as a sentinel HERE because it means do-not-transfer, never transfer-to-zero.
    /// @dev A caller who passes an uninitialized address therefore skips a leg silently; the return says which.
    /// @dev Both zero is a caller bug rather than a legal no-op, and is refused by name.
    /// @dev Both requested recipients are validated before either leg runs, even when their credits are empty.
    /// @param id The loan the credit sits against.
    /// @param toUnits Where to send the collateral, or zero to leave it credited.
    /// @param toQuote Where to send the quote, or zero to leave it credited.
    /// @return units Collateral units delivered.
    /// @return amount Quote delivered.
    function claimOwed(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, address toUnits, address toQuote)
        public
        returns (uint256 units, uint256 amount)
    {
        if (toUnits == address(0) && toQuote == address(0)) revert NoClaimLeg();
        if (toUnits != address(0)) Recipients.check(toUnits, c.positionManager);
        if (toQuote != address(0) && toQuote != toUnits) Recipients.check(toQuote, c.positionManager); // the single form names one address, checked once
        units = _claimUnitsLeg(B, c, id, toUnits);
        amount = _claimQuoteLeg(B, M, c, id, toQuote);
        emit OwedClaimed(id, msg.sender, toUnits, toQuote, units, amount);
    }

    /// @dev CEI: the entry is zeroed before the token moves, so a re-entrant claim finds nothing.
    /// @dev A zero destination returns zero without reading, so a skipped leg is not a claim at all.
    function _claimUnitsLeg(LoanBook storage B, Cfg memory c, uint256 id, address to) private returns (uint256 units) {
        if (to == address(0)) return 0;
        units = B.unitsOwed[id][msg.sender];
        if (units > 0) {
            B.unitsOwed[id][msg.sender] = 0;
            IPositionManager(c.positionManager).releaseRetired(id, to, units);
        }
    }

    /// @dev The market total falls with the entry, inside the leg, so a skip leaves both untouched together.
    function _claimQuoteLeg(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, address to) private returns (uint256 amount) {
        if (to == address(0)) return 0;
        amount = B.quoteOwed[id][msg.sender];
        if (amount > 0) {
            B.quoteOwed[id][msg.sender] = 0;
            M.s.quoteOwedTotal -= amount;
            IERC20(c.p.quote).safeTransfer(to, amount);
        }
    }

    /// @dev How much of the lot the market side takes: the claims' need, or the whole coverage where there is no record.
    /// @dev CLASS, NEVER LIVENESS: this turns on whether a record was ever WIRED, which genesis fixes and no party can flip.
    /// @dev A RECORDLESS LENDER HAS NO EARLY SEIZURE AT ALL and prices that when they rest; the coverage is what pays for it.
    /// @dev A recordless loan reaches this bound only by its tenor running out: `finalize` refuses `NoRecord` there.
    /// @dev A wired record that stops answering closes every judgment-spending door -- draw, extension, withdrawal, deleverage -- and moves no value.
    /// @dev Some classes keep answering the below-question through silence, so title can still move; that is theirs to rule, not this bound's.
    /// @dev Reading liveness HERE would price a loan off a transient answer whose moment the settling caller picks.
    /// @dev Priced BEFORE `_finalizeLoanFor`, which deletes the funding floor this reads.
    /// @dev A loan with no live claim keeps the narrow bound: there is nothing a coverage could be spread over.
    /// @dev The floor guard is belt-and-braces on an ordering the admission gate already holds, and it errs toward today's rule.
    function _marketBound(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 need, uint256 units) private view returns (uint256) {
        uint256 bound = need;
        if (need > 0 && c.p.record == address(0)) {
            bound = Borrower.coverageLine(c, B.loans[id].debt, LoanAccounting.fundingFloor(M, c, id));
            bound = Math.max(bound, need);
        }
        return Math.min(bound, units);
    }

    /// @dev The forfeited coverage: what the market's bound takes above the claim's need, WHOLE, into the pot.
    /// @dev EXACT rather than approached -- one claim takes all of it, so no divisor, no floor and no residue.
    /// @dev The claim is still whole at its book price when this runs, so this distributes surplus, never principal.
    /// @dev The backed-burn total moves with the pot, which is what the inventory identity requires of any pot credit.
    /// @dev Never touches `lent` or the shortfall: `_finalizeLoanFor` retires the claim at its own book.
    /// @dev Credits the pot in RAW UNITS, because `_finalizeLoanFor` does and the two must sum.
    function _spreadCoverage(Market storage M, uint256 loanId, uint256 excess) private {
        if (M.claim[loanId] == 0) return; // nothing lent: the caller's bound already excludes this
        M.invPotOf[loanId] += excess;
        M.s.cumulativeBackedBurns += excess; // credited by what actually landed, so the identity cannot drift
    }

    /// @dev Title transfer on default: the claim becomes the loan's pot, at the market's price.
    /// @dev ONE CLAIM, so there is no ordering to pick and nothing to accumulate a shortfall across.
    /// @dev The backed burn is credited by what was actually DELIVERED, not by what the claim asked for.
    /// @dev AT BOOK values delivered units at the funding price, so the true loss can exceed the `badDebt` it returns.
    /// @dev The quantization residue goes to the LENDER, never to the borrower whose loan defaulted.
    function _finalizeLoanFor(Market storage M, Cfg memory c, uint256 loanId, uint256 collateralUnits) private returns (uint256 badDebt) {
        uint256 amount = M.claim[loanId];
        if (amount == 0) return 0;
        uint256 price = c.p.price;
        uint256 need = FullMath.mulDivRoundingUp(amount, c.unitScale, price); // CEIL: fewer units cannot pay the claim
        uint256 give = Math.min(need, collateralUnits);

        LenderCollateral storage x = LoanAccounting.subLent(M, amount); // claim settled by title transfer
        uint256 pot = M.invPotOf[loanId] + give; // the coverage spread, when there is one, already landed here
        M.invPotOf[loanId] = pot;
        if (pot != 0) {
            LenderUnresolved storage u = Storage.unresolvedOf(M.p);
            (u.unsoldPots, u.settledPots) = (u.unsoldPots + 1, u.settledPots + 1); // unsold until a buy or redeem empties it; settled for good
            x.unsoldUnits += pot; // the WHOLE pot, spread and give together: a loan settles once
        }
        M.s.cumulativeBackedBurns += give; // backed burn credited by units delivered
        M.claim[loanId] = 0; // and the claim retires, which is also what zeroes this loan's funding floor

        uint256 covered = FullMath.mulDiv(give, price, c.unitScale); // what was DELIVERED is worth; 512-bit, as home refinances grow a claim past cash
        badDebt = Math.saturatingSub(amount, covered);
    }
}
