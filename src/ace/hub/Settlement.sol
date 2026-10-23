// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Borrower} from "./Borrower.sol";

import {LoanAccounting} from "./libraries/LoanAccounting.sol";
import {Recipients} from "./libraries/Recipients.sol";
import {MarketInit} from "./MarketInit.sol";
import {
    AutoPolicy,
    Cfg,
    LenderCollateral,
    LenderUnresolved,
    Loan,
    LoanBook,
    Market,
    MigrateArgs,
    OpenBounds,
    PreAdmitted,
    RollFrames,
    Shortfall,
    Storage
} from "./Types.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";

error LoanClosed(); // the loan is retired: no settlement verb touches it
error NotExpired(); // the tenor has not run out yet
error NoRecord(); // record-less market: distress is unknowable, so finalize never opens; the loan still settles at tenor
error NotSettleable(); // not YET settleable: callers retry on this one
error RollWindowOpen(); // the unpaid backstop is not open yet: the paid door still owes this loan a roll
error NoClaimLeg(); // both destinations zero: one zero skips a leg, two claim nothing and is a caller bug

/* ========================================================================= */
/*  TABLE OF CONTENTS                                                        */
/*  1. EXPIRY   the tenor ran out: roll the loan forward, or hand it over    */
/*  2. SETTLE   the terminal crank: title moves, claims convert, loan closes */
/* ========================================================================= */

/// @title Settlement
/// @notice Where a loan ENDS: the expiry fold, and the title transfer that closes it for good.
/// @notice Liquidation here is a title transfer, not a trade -- selling against a LIVE loan is `Deleverage`.
/// @dev Every `msg.sender` here is the EXTERNAL caller of the crank, which a periphery sponsor pays against.
library Settlement {
    using SafeERC20 for IERC20;

    /// @dev `collateralUnits` is the lot net of the keeper sliver, which the executor is credited separately.
    event Finalized(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor);
    /// @dev `collateralUnits` is the lot net of the keeper sliver, which the executor is credited separately.
    event ForceClosed(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor);
    event SettledUnpaid(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor);
    /// @dev `sliverUnits` is the in-kind keeper bounty the roll credited, deducted before the successor draws.
    event ExpiryRolled(uint256 indexed oldId, uint256 indexed newId, uint256 sliverUnits, address indexed executor);
    /// @notice A zero destination on either leg means the claimant declined it and its credit is still outstanding.
    /// @dev So `toUnits == 0` and `units == 0` say different things: declined, versus asked and there was nothing.
    event OwedClaimed(uint256 indexed loanId, address indexed claimant, address toUnits, address toQuote, uint256 units, uint256 amount);

    /* ====== 1. EXPIRY: settle, or roll the loan forward on an armed policy ====== */

    /// @notice forceClose with the policy fold: credit the sliver, then continue; settle only if inadmissible.
    /// @dev Guards run BEFORE the policy read; the unarmed path performs one SLOAD and falls through whole.
    /// @dev The sliver is credited on BOTH branches, same formula, so the crank's pay never turns on the branch.
    /// @dev The predicate is TOTAL, so the branch is a function of loan state, bar the under-forwarding case below.
    /// @dev A dependency that BURNS its frame answers not-ok, so the fold settles; with too little gas left the verb reverts instead.
    /// @dev Under-forwarding gas picks the branch only for a read costing over 63 times the settle, which the 1/64 left must fund.
    /// @dev `settleExpired` asks no predicate at all, so it is the backstop no dependency can starve.
    /// @dev IT REPORTS THE BRANCH: a roll closes this loan too, so `closedAt` cannot tell the two apart.
    /// @return settled True when the loan ENDED here; false when it rolled into a successor.
    function forceCloseOrContinue(LoanBook storage B, mapping(bytes32 => Market) storage MM, Cfg memory c, uint256 id) public returns (bool settled) {
        Loan storage L = B.loans[id];
        if (L.closedAt != 0) revert LoanClosed();
        if (block.timestamp < L.expiry) revert NotExpired();
        Market storage M = MM[L.market];
        AutoPolicy memory ap = B.autoPolicyOf[id];
        if (ap.tenor == 0) {
            forceClose(B, M, c, id);
            return true;
        }
        uint256 units = L.collateralUnits;
        uint256 sliver = LoanAccounting.sliverUnits(B, M, c, id, units);
        /// @dev The fold never routes: one cache twice, and the loan's own market as the destination.
        /// @dev A caller-named destination here would let a griefer SETTLE an admissible loan with a bad one.
        (bool ok,, uint256 principal, uint256 cap) = Borrower.tryContinue(B, MM, RollFrames(c, c, L.market), id, units - sliver);
        if (!ok) {
            forceClose(B, M, c, id); // _settle credits its OWN sliver, same size
            return true;
        }
        L.collateralUnits = units - sliver; // effect before the credit
        if (sliver > 0) IPositionManager(c.positionManager).retireCustody(id, sliver);
        LoanAccounting.creditUnits(B, id, msg.sender, sliver); // credited, so a refused crank address cannot stop the roll
        emit ExpiryRolled(id, _roll(B, MM, c, id, principal, ap, cap), sliver, msg.sender);
    }

    /// @dev The roll's migration call, in its own frame: the linked call ABI-encodes its arguments (stack).
    /// @dev `cap` is the predicate's own answer, the max sentinel on this always-home roll, so the open it commits to reads no dependency twice.
    function _roll(LoanBook storage B, mapping(bytes32 => Market) storage MM, Cfg memory c, uint256 id, uint256 principal, AutoPolicy memory ap, uint256 cap)
        private
        returns (uint256)
    {
        /// @dev The zeroes are STRUCTURAL: an expiry roll supplies no caller numbers, so it can shed no collateral.
        /// @dev Any field appended to `MigrateArgs` inherits this silence -- give it a zero that means "the roll declines it".
        bytes32 market = B.loans[id].market;
        MigrateArgs memory a = MigrateArgs(id, market, principal, ap.tenor, OpenBounds(0, uint256(ap.minBufferBps) * 1e14, 0), 0, address(0));
        return Borrower.migrate(B, MM, c, c, a, PreAdmitted(true, market, cap, 0), false);
    }

    /* ====== 2. SETTLE: the terminal crank ====== */

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
        (uint256 bad, uint256 left) = _settle(B, M, c, id, L.borrower, units, true);
        emit Finalized(id, left, bad, msg.sender);
    }

    /// @notice Settle an expired loan by claim conversion; equity above what the market takes is CREDITED to the borrower. Final.
    /// @notice A RECORDLESS market takes the whole coverage line rather than the claims' need, so its borrower may keep nothing.
    /// @dev Consults NO external dependency on the settle branch; the ARMED branch asks the record through the predicate.
    /// @dev The settle branch still BRANCHES on whether a record is WIRED, and that read is what widens the bound.
    /// @dev `settleExpired` is the must-execute backstop: it consults no record, so it is what bounds worst-case at tenor.
    /// @dev The SETTLE branch: the hub dispatches through `forceCloseOrContinue` above.
    function forceClose(LoanBook storage B, Market storage M, Cfg memory c, uint256 id) public {
        Loan storage L = B.loans[id];
        if (L.closedAt != 0) revert LoanClosed();
        if (block.timestamp < L.expiry) revert NotExpired();
        uint256 units = L.collateralUnits;
        L.collateralUnits = 0;
        L.closedAt = uint64(block.timestamp);
        (uint256 bad, uint256 left) = _settle(B, M, c, id, L.borrower, units, true);
        emit ForceClosed(id, left, bad, msg.sender);
    }

    /// @notice Settle an expired loan WITHOUT consulting the record, once the roll window has passed.
    /// @notice Permissionless, and it pays the caller NOTHING: the sliver rides the paid doors alone.
    /// @dev The must-execute path made unconditional: a dependency that cannot answer can DELAY settlement, never block it.
    /// @dev The paid door never SHUTS, so a late roll still succeeds and this only ends a loan someone chose to end.
    /// @dev Three pieces, three jobs: it EXISTS so the brick dies, it PAYS NOTHING so no keeper steers, it is CLOCKED so the borrower's roll survives.
    /// @dev The window is the loan's own, not the market's floor: a longer tenor earns a proportionally longer roll window.
    /// @dev No sweep: the sweep rides the paid crank; the hub's lender push is swallowed, so no quote or lender can fail this door.
    function settleExpired(LoanBook storage B, Market storage M, Cfg memory c, uint256 id) public {
        Loan storage L = B.loans[id];
        if (L.closedAt != 0) revert LoanClosed();
        if (block.timestamp < uint256(L.expiry) + MarketInit.autoRefinanceWindow(L.tenor)) revert RollWindowOpen();
        uint256 units = L.collateralUnits;
        L.collateralUnits = 0;
        L.closedAt = uint64(block.timestamp);
        (uint256 bad, uint256 left) = _settle(B, M, c, id, L.borrower, units, false);
        emit SettledUnpaid(id, left, bad, msg.sender);
    }

    /// @notice The CLEAN close: credit the collateral to the holder, credit the unearned fee escrow.
    /// @dev REPAY is the one caller: a deleverage melt stops at `minDebt`, so it never closes a loan.
    /// @dev The caller splits the fee escrow FIRST; this credits whatever the term did not earn.
    /// @dev CREDITED, not pushed: a holder the collateral or the quote refuses must not brick a repay.
    function closeClean(LoanBook storage B, Market storage M, Cfg memory c, uint256 id) internal {
        Loan storage L = B.loans[id];
        L.closedAt = uint64(block.timestamp);
        Borrower.releaseReserve(B, M, id); // a repaid loan rolls nowhere, so its reserved cash is lendable again
        uint256 units = L.collateralUnits;
        L.collateralUnits = 0;
        if (units > 0) IPositionManager(c.positionManager).retireCustody(id, units);
        LoanAccounting.creditUnits(B, id, L.borrower, units);
        LoanAccounting.refundFeeEscrow(B, M, id, L.borrower);
    }

    /// @dev The shared title-transfer core: the keeper sliver off the top when paid, then the claim.
    /// @dev The claim bears its own write-down; what the market's bound leaves is CREDITED to the borrower.
    /// @dev MAKES NO EXTERNAL COLLATERAL TRANSFER: every leg is a ledger write, so settlement is total.
    /// @dev A short close RECORDS what the claim did not get, post-sliver: per loan, plus the market's total.
    /// @dev `retireCustody` is the ONE external call, and both records are written AFTER it, never before.
    /// @dev `pay` false suppresses the sliver, and those units fall through to the claims and the borrower.
    /// @dev Only the unpaid backstop passes false, so waiting for it costs a keeper the sliver the paid doors credit.
    function _settle(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, address borrower, uint256 units, bool pay)
        private
        returns (uint256 badDebt, uint256 unitsAfterSliver)
    {
        /// @dev FIRST, and before any external call: _finalizeLoanFor zeroes the claims this credits.
        /// @dev Settlement earns the whole fee escrow -- the lender bore the outcome, so none is refundable.
        LoanAccounting.earnFeeEscrowFully(B, M, id);
        Borrower.releaseReserve(B, M, id); // `M` is the loan's own market on every caller, where its reservation sits
        /// @dev ONE custody move, and it moves no token: the whole lot leaves the live ledger at once.
        /// @dev What the hub does next is pure bookkeeping over units the custodian already holds for this loan.
        if (units > 0) IPositionManager(c.positionManager).retireCustody(id, units);
        uint256 sliver = pay ? LoanAccounting.sliverUnits(B, M, c, id, units) : 0;
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
    /// @dev A recordless loan cannot arm, so no refused roll reaches this bound: only its tenor running out does.
    /// @dev A wired record that stops answering closes every judgment-spending door -- draw, roll, withdrawal, deleverage -- and moves no value.
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
