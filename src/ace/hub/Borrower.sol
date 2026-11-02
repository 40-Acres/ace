// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "./Constants.sol";

import {LoanMath} from "./libraries/LoanMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPersistenceRecord} from "../../interfaces/IPersistenceRecord.sol";
import {LoanAccounting} from "./libraries/LoanAccounting.sol";
import {Probe, PolicyGasShort} from "./libraries/Probe.sol"; // PolicyGasShort is re-exported for importers of this file
import {Extension, IRollPolicy} from "../../interfaces/IRollPolicy.sol";
import {Transfers} from "./libraries/Transfers.sol";
import {Recipients, ZeroWithdrawTo} from "./libraries/Recipients.sol"; // ZeroWithdrawTo is re-exported for importers of this file
import {Settlement} from "./Settlement.sol";
import {PositionTitleNFT} from "../positions/PositionTitleNFT.sol";
import {Cfg, Loan, LoanBook, Market, MigrateArgs, OpenBounds, RecordState, Storage} from "./Types.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";

error LoanClosed(); // the loan is retired: no borrower verb touches it
error OpenExpired(); // the open's own deadline passed before it landed
error ZeroCollateral(); // an unsecured loan is unfinalizable: triggerPrice(0) == 0 clears every gate
error CollateralOutOfRange(); // wider than the trigger's own denominator carries: `units * 1e18` would wrap
error WithdrawalExceedsCollateral(); // the requested withdrawal exceeds the loan's remaining collateral
error ZeroPrincipal(); // a loan securing nothing takes no claim, so it never gets a funding floor
error InsufficientCash(); // the market's resting cash is less than this draw asks, or its price is over the cap on a fresh draw
error BelowMinPrincipal(); // principal under the market's minPrincipal: an open, a fill or a refinance successor
error BelowDebtFloor(); // a repay leaving a live loan under its market's debt floor, half its minPrincipal
error TenorOutOfRange(); // tenor outside the market's min/max
error GateRefused(); // the borrower is not the market's one named borrower, so the new credit is refused; it can never block a settlement
error PayoutBelowMin(); // fees left the borrower less cash than their floor
error TriggerAboveFloor(); // a trigger at or above the funding floor would be liquidatable at birth
error BufferBelowMin(); // the gap between funding floor and trigger is thinner than the borrower asked
error BelowWithdrawLine(); // a withdrawal leg falling under the coverage line: the settlement slack refuses it, not the trigger
error BelowCoverageLine(); // a draw opening under that same line: settlement's own ceiling refuses it at admission
error AlreadyFunded(); // a second draw on a live claim would overwrite it while `lent` adds both; it disarms at the close and is not what keeps ids fresh
error NotBorrower(); // only the loan's own borrower may refinance or extend it; its market lender holding a grant also extends it
error MarketPairMismatch(); // migration destination secures a different collateral: refuse before state moves
error QuoteMismatch(); // migration destination quotes in a different token: one migration, one quote
error DrawBelowDebt(); // the fresh draw plus the old fee refund cannot retire the old debt; repay the gap first
error NoRecordPrice(); // the record cannot produce a windowed minimum: judgment-spending verbs refuse rather than guess
error RecordUnreadable(); // the record gave no usable answer: reverted, returned short, has no code, or a persisted-below word outside {0, 1}
error PolicyRefused(); // the market lender's roll policy did not consent: none set, a revert, or any answer but the selector
error ExtensionAddsNoTime(); // the loan's own tenor from now ends no later than it already does: its open second, or a second extension in one second
error LoanMatured(); // the tenor has run out: the loan repays or settles, and no withdrawal, sale, extension or refinance lands

/* ========================================================================= */
/*  TABLE OF CONTENTS                                                        */
/*  1. OPEN        the draw path, and the funding floor it stamps            */
/*  2. REPAY       paying a loan down, and the clean close at zero           */
/*  3. EXTEND      lengthen a live loan in place, on its lender's policy     */
/*  4. REFINANCE   close a loan and open its successor, atomically           */
/*  5. HEALTH      trigger, rate and the price record                        */
/* ========================================================================= */

/// @title Borrower
/// @notice Every verb whose judgment is the BORROWER's: open, repay, extend, refinance, and the health they turn on.
/// @notice A loan draws exactly once; `extend` lengthens it in place, and any other continuation is a fresh loan, in section 4.
/// @dev Every `msg.sender` here is the EXTERNAL caller, never the hub: the borrower-only gate rests on it.
library Borrower {
    using SafeERC20 for IERC20;

    /// @dev `executor` throughout is the EXTERNAL caller a periphery sponsor pays against.
    /// @dev `netOut` is the borrower's net out, paid in the call by `refinanceTo`.
    event Refinanced(uint256 indexed oldId, uint256 indexed newId, uint256 newPrincipal, uint64 newTenor, uint256 netOut, address indexed executor);
    /// @notice A borrower's withdrawal sent `units` to `to`: by `withdrawCollateral`, or by a `refinanceTo` leg keyed by the successor's id.
    /// @notice It is logged before the release; a deleverage sale also takes units off a live loan, and logs `Deleveraged` instead.
    event CollateralWithdrawn(uint256 indexed id, address indexed to, uint256 units, uint256 unitsLeft, uint256 newTrigger);
    /// @notice A loan re-anchored in place at its own tenor from now, `added` later than it ran, to `newExpiry`, for `fee`, paid in cash by `executor`.
    event Extended(uint256 indexed id, uint64 added, uint64 newExpiry, uint256 fee, address indexed executor);

    /// @notice What a quote reports.
    /// @dev Field order and names mirror `AceLens.quoteOpen`'s flat tuple, so integrator code ports unchanged.
    /// @dev `protocolFee` is APPENDED, never inserted: the five fields before it keep their offsets.
    struct Quote {
        uint256 fee; // the borrower's ALL-IN cost: the lender's fee with ACE's share charged on top
        uint256 payout;
        uint256 postDrawFloor; // the loan's funding floor: the market's price at the draw, raw
        uint256 triggerAtOpen;
        uint256 bufferWad;
        uint256 protocolFee; // ACE's share of `fee`, reported so the split is legible without a second call
    }

    /// @notice open() call args, bundled: every entry point and the refinance build the SAME one value.
    /// @dev The three roles stay SEPARATE because the doors split them; only `open` passes its caller as payer AND payee.
    /// @dev `openWithPermit2` names the hub as payer, having taken the collateral by permit, and pays the caller.
    /// @dev A refinance pays the hub; an order fill pays the maker; both carry, so payer is zero.
    struct OpenArgs {
        bytes32 market;
        address borrower; // title holder and debtor
        address payer; // posts the collateral
        address payee; // receives the stable payout
        uint256 collateralUnits;
        uint256 principal;
        uint64 tenor;
        OpenBounds bnd; // optional borrower open-time bounds; all-zero == off
    }

    /// @dev `market` is indexed because loan ids are GLOBAL: without it no log filter is market-scoped.
    event Opened(uint256 indexed id, bytes32 indexed market, address indexed borrower, uint256 collateralUnits, uint256 principal, uint256 fee, uint64 expiry);
    /// @notice A new loan drew `amount` of principal from its market's resting cash.
    /// @dev `to` is ALWAYS the payee, who took the draw less its fee; on a refinance that is the hub, which nets it.
    /// @dev It equals the executor only on the doors that pay their caller; a keeper or a filler is logged by its own verb's event.
    /// @dev No price field: every draw funds at its market's one price, `idToMarketParams(loanMarket(loanId)).price`.
    event Funded(uint256 indexed loanId, uint256 amount, address indexed to);
    /// @dev `from` is the payer; on a deleverage that is the hub itself, and the keeper is `Deleveraged.executor`.
    event Recash(uint256 indexed loanId, uint256 amount, address indexed from);
    event Repaid(uint256 indexed id, uint256 amount, uint256 remainingDebt);

    /* ====== 1. OPEN: the draw path, and the ONLY one that funds a new loan from scratch ====== */

    uint256 internal constant NO_PREDECESSOR_LOAN = 0; // ids start at one, so zero names no loan: this open pulls from a.payer

    /// @notice Opens a terminal loan against escrowed collateral, funded by the market's resting cash.
    /// @dev borrower holds title and the debt; payer funds the positionManager; payee takes the payout.
    /// @dev They are separate because the doors split them: an operator is paid for another's title, and the permit door's payer is the hub.
    /// @dev Payout sent last (CEI).
    function open(LoanBook storage B, Market storage M, Cfg memory c, OpenArgs memory a) public returns (uint256 id) {
        return _openFrom(B, M, c, a, NO_PREDECESSOR_LOAN, 0);
    }

    /// @notice `open` for a draw whose collateral is ALREADY in this custodian's hands under `fromId`.
    /// @notice The carry's CREDIT half; its debit half ran at the source, before the successor had an id.
    /// @dev A credit order's fill reaches the one open body through here, exactly as a refinance does.
    /// @param B The loan book.
    /// @param M The destination market.
    /// @param c The destination market's config cache.
    /// @param a The open's arguments; `payer` is unread, since the carry moves no token.
    /// @param fromId The id already holding the units: a retiring loan, or a resting order.
    /// @return The new loan id.
    /// @dev A resting order is not an admitted one -- the borrower rule and the record are checked at the FILL, never at the post.
    function openCarried(LoanBook storage B, Market storage M, Cfg memory c, OpenArgs memory a, uint256 fromId) public returns (uint256) {
        return _openFrom(B, M, c, a, fromId, 0);
    }

    /// @notice The one open body; a refinance or an order fill reaches it naming the id whose custody it inherits.
    /// @dev The custody source is its OWN parameter, so no existing field ever carries a second meaning.
    /// @dev Ids start at one, so zero can never name a real predecessor and the constant is sound, not conventional.
    /// @dev A carried open moves no token: the units are already in the pot, credited to the id they are carried from.
    /// @dev `recycle` is the retiring claim an own-market refinance funds its successor with; every other open passes zero.
    function _openFrom(LoanBook storage B, Market storage M, Cfg memory c, OpenArgs memory a, uint256 predecessorLoanId, uint256 recycle)
        private
        returns (uint256 id)
    {
        _preChecks(c, a);
        _gateCheck(c, a);
        uint256 fee = LoanMath.originationFee(a.principal, a.tenor, c.p.baseBps, c.p.minTenor);
        _payoutCheck(c, a, fee);
        id = _record(B, c, a, fee);

        /// @dev Both secondary ledgers land here, before ANY external call: no half-created observer.
        /// @dev For a FRESH id the mint is a leaf: `_mint` runs no receiver hook, and `previousOwner == 0` skips the retitle branch.
        /// @dev A REUSED loan id is refused here: its retitle callback trips the hub's guard, and `_mint` would refuse it next anyway.
        PositionTitleNFT(c.positionTitle).mint(id, a.borrower);
        M.openedLoans.push(id); // append-only: what marketLoans pages, so a keeper finds a market's loans without an indexer

        _splitAndDraw(B, M, c, a, id, fee, recycle);

        if (predecessorLoanId == NO_PREDECESSOR_LOAN) IPositionManager(c.positionManager).pull(id, a.payer, a.collateralUnits);
        else IPositionManager(c.positionManager).carryIn(predecessorLoanId, id, a.collateralUnits);

        /// @dev The PAYEE test, not the predecessor: the skip is sound because the hub would be paying itself.
        /// @dev A migration names the hub, which already holds the draw and nets it; keying on the carry could swallow a real payout.
        if (a.payee != address(this)) IERC20(c.p.quote).safeTransfer(a.payee, a.principal - fee); // send stable LAST (CEI)
        emit Opened(id, a.market, a.borrower, a.collateralUnits, a.principal, fee, B.loans[id].expiry);
    }

    /// @dev The fee split and the draw, in their own frame so `_openFrom` never holds both halves at once (stack).
    /// @dev The fee splits BEFORE the draw, so the lender pool sees the share it actually earns.
    /// @dev The refundable half never reaches the pool, so no share prices revenue the term has not earned.
    /// @dev `Funded` is logged HERE rather than in `_fund`, because this is the frame that holds the payee.
    function _splitAndDraw(LoanBook storage B, Market storage M, Cfg memory c, OpenArgs memory a, uint256 id, uint256 fee, uint256 recycle) private {
        B.feeEscrowOf[id] = LoanMath.escrowCut(fee);
        _fundAndCheck(M, c, B.loans[id], id, a.principal, LoanMath.tickCut(fee), LoanMath.protocolCut(fee), a.bnd.minBufferWad, recycle);
        emit Funded(id, a.principal, a.payee);
    }

    /// @notice The tenor sentinel, ONE spelling for every door that takes a term: zero means the market's `minTenor`.
    function tenorOrMin(uint64 tenor, uint64 minTenor) internal pure returns (uint64) {
        return tenor == 0 ? minTenor : tenor;
    }

    /// @dev The LOCAL pre-draw refusals, shared by `open` and `previewOpen`; the gate rides beside it in `_gateCheck`.
    /// @dev Deadline FIRST: a stale queued open must not execute under drifted state.
    /// @dev ZeroPrincipal BEFORE BelowMinPrincipal: below it the floor rail catches the zero first and it goes dead.
    function _preChecks(Cfg memory c, OpenArgs memory a) private view {
        if (a.bnd.deadline != 0 && block.timestamp > a.bnd.deadline) revert OpenExpired();
        if (a.collateralUnits == 0) revert ZeroCollateral();
        /// @dev EVERY loan's stored units enter through here, so this one bound holds for all of them.
        /// @dev Only `Deleverage`'s refund ever raises a stored figure, and never past the decrement it reverses.
        if (a.collateralUnits > type(uint256).max / 1e18) revert CollateralOutOfRange();
        if (a.principal == 0) revert ZeroPrincipal();
        if (a.principal < c.p.minPrincipal) revert BelowMinPrincipal();
        if (a.tenor < c.p.minTenor || a.tenor > c.p.maxTenor) revert TenorOutOfRange();
    }

    /// @dev The entry check: a market may name one borrower, and zero names everybody.
    /// @dev It refuses the BORROWER, not the caller, so an operator or keeper never launders one.
    /// @dev A migration checks the DESTINATION market's borrower through this same call.
    function _gateCheck(Cfg memory c, OpenArgs memory a) private pure {
        if (!gateAdmits(c.p.borrower, a.borrower)) revert GateRefused();
    }

    /// @dev The payout bound, shared. Returns the payout it validated, so a quote never recomputes it.
    /// @dev ONE branch, so the over-fee refusal binds at every bound, `minPayout == 0` included.
    /// @dev The genesis rails ESTABLISH `fee < principal`; this guard only DEFENDS it, and names the refusal.
    function _payoutCheck(Cfg memory c, OpenArgs memory a, uint256 fee) private pure returns (uint256 payout) {
        c; // threaded for symmetry with the other helpers
        bool ok;
        (ok, payout) = Math.trySub(a.principal, fee); // a fee over the principal is `ok == false`, refused on the same branch
        if (!ok || payout < a.bnd.minPayout) revert PayoutBelowMin();
    }

    /// @dev The trigger and buffer legs, shared. Returns the buffer it priced against.
    /// @dev NOT the whole of admission: the coverage line rides beside it at every site that calls it.
    function _gate(uint256 floor, uint256 trig, uint256 minBufferWad) private pure returns (uint256 bufferWad) {
        if (trig > floor) revert TriggerAboveFloor();
        bufferWad = floor == 0 ? 0 : FullMath.mulDiv(floor - trig, 1e18, floor); // the ratio divides by it
        if (minBufferWad != 0 && (floor == 0 || bufferWad < minBufferWad)) revert BufferBelowMin();
    }

    /// @dev Allocates the loan id and writes the whole loan record; own frame, to shed `open`'s locals.
    function _record(LoanBook storage B, Cfg memory c, OpenArgs memory a, uint256 fee) private returns (uint256 id) {
        id = ++B.count;
        Loan storage L = B.loans[id];
        L.market = a.market;
        L.borrower = a.borrower;
        L.collateralUnits = a.collateralUnits;
        L.debt = a.principal;
        L.openTime = uint64(block.timestamp);
        L.tenor = a.tenor;
        L.expiry = uint64(block.timestamp) + a.tenor;
        L.lastFee = fee; // informational only: nothing on any path reads it to price anything
        B.principalOf[id] = a.principal;
    }

    /// @notice What `open` would do with these arguments. Reverts where `open` reverts, in that order.
    /// @dev Every number comes from code `open` also runs, so nothing here is spelled twice.
    /// @dev Blind to token-side failures (positionManager pull, reserve pull, payout): those turn on balances.
    function previewOpen(Market storage M, Cfg memory c, OpenArgs memory a) public view returns (Quote memory q) {
        _preChecks(c, a);
        _gateCheck(c, a); // the same position `open` runs it in: after every local refusal, before the draw
        q.fee = LoanMath.originationFee(a.principal, a.tenor, c.p.baseBps, c.p.minTenor);
        q.protocolFee = LoanMath.protocolCut(q.fee);
        q.payout = _payoutCheck(c, a, q.fee);

        q.postDrawFloor = _previewFloor(M, c, a.principal);
        q.triggerAtOpen = LoanMath.triggerPrice(a.principal, a.collateralUnits, c.p.minCoverageWad, c.unitScale);
        q.bufferWad = _gate(q.postDrawFloor, q.triggerAtOpen, a.bnd.minBufferWad);
        if (a.collateralUnits < coverageLine(c, a.principal, q.postDrawFloor)) revert BelowCoverageLine();
    }

    /// @dev The floor a draw taking `fresh` of the market's cash is judged at: the market's price, or the record under it.
    /// @dev There is no walk to preview; the only question is whether the market's own cash and cap admit the draw.
    /// @dev A cap BELOW the market's price refuses a FRESH draw -- resting cash the market will not lend from is a stale bid.
    /// @dev A zero-fresh draw, a re-term the old claim recycles whole, is judged at that cap instead, as an extension is.
    /// @dev The cash leg is resting cash against the fresh draw and nothing else, so at zero fresh it cannot refuse.
    function _previewFloor(Market storage M, Cfg memory c, uint256 fresh) private view returns (uint256 floor) {
        (RecordState s, uint256 cap) = recordState(c);
        if (s == RecordState.NoPrice) revert NoRecordPrice();
        floor = c.p.price;
        if (floor > cap) {
            if (fresh != 0) revert InsufficientCash();
            floor = cap;
        }
        if (M.s.cash < fresh) revert InsufficientCash();
    }

    /// @dev Draws against the market, then gates it: trigger, buffer, and the coverage line, in that order.
    /// @dev The line runs LAST so a gross shortfall still refuses under the trigger's own selector.
    function _fundAndCheck(
        Market storage M,
        Cfg memory c,
        Loan storage L,
        uint256 loanId,
        uint256 principal,
        uint256 tickFee,
        uint256 protocolFee,
        uint256 minBufferWad,
        uint256 recycle
    ) private {
        uint256 floor = _fund(M, c, loanId, principal, tickFee, protocolFee, recycle);
        _gate(floor, triggerPrice(L, c), minBufferWad);
        if (L.collateralUnits < coverageLine(c, L.debt, floor)) revert BelowCoverageLine();
    }

    /// @dev Funds from the market's resting cash, at the market's one price.
    /// @dev THE BACKSTOP READS THE CLAIM, not a stored floor: a second draw on a live claim would overwrite it.
    /// @dev A full repay and settlement zero the claim, so it guards a live loan only; a reused id is refused at the title mint.
    /// @dev NO FEE SPLIT: one claim takes the whole lender fee exactly, so no rounding residue reaches `protocolRevenue`.
    /// @dev AN OWN-MARKET REFINANCE'S DRAW IS NET: `recycle` of its principal is the retiring claim, so only the rest leaves cash.
    function _fund(Market storage M, Cfg memory c, uint256 loanId, uint256 principal, uint256 tickFee, uint256 protocolFee, uint256 recycle)
        private
        returns (uint256 floorPrice)
    {
        if (M.claim[loanId] != 0) revert AlreadyFunded(); // a live claim refuses a second draw; ids stay fresh by the counter
        uint256 fresh = principal - recycle; // `_retire` caps the recycle at the principal
        floorPrice = _previewFloor(M, c, fresh);
        /// @dev The SECOND write site for the cash and pooled-resting pair, beside `Lender.debitCash`: inlined, as `Lender` imports this library.
        /// @dev The two must move together: a bound or an assertion added to one belongs at both.
        M.s.cash -= fresh;
        M.claim[loanId] = principal;
        Storage.poolOf(M.p).resting -= fresh;
        LoanAccounting.addLent(M, principal);
        if (tickFee != 0) LoanAccounting.creditLenderShare(M, loanId, tickFee);
        LoanAccounting.accrueProtocolFee(M, protocolFee);
        M.s.drawCount++;
    }

    /* ============================== 2. REPAY ============================== */

    /// @notice Pays debt down, retiring the loan's claim by exactly what was paid. Full repayment closes the loan.
    /// @notice Anyone may pay a loan off or down, but no repay may leave a live loan under its debt floor, half `minPrincipal`.
    /// @notice So a router or relayer repaying for a borrower is floored exactly as the borrower is.
    /// @notice Repay with headroom over the floor, or in full: a stranger's atom repay first can make one sized to the floor revert.
    /// @dev `permit2` empty pulls on the payer's ERC20 allowance; non-empty spends a Permit2 signature.
    /// @dev `Deleverage._closeSale` books a closing crank in this order too, escrow split before the melt: the two must agree.
    function repay(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 amount, bytes calldata permit2) public {
        Loan storage L = B.loans[id];
        if (L.closedAt != 0) revert LoanClosed();
        amount = Math.min(amount, L.debt);
        uint256 left = L.debt - amount;
        if (left != 0 && left < LoanMath.debtFloor(c.p.minPrincipal)) revert BelowDebtFloor();

        L.debt -= amount;
        /// @dev BEFORE the melt: it retires the claim the earned slice is credited over.
        if (left == 0) LoanAccounting.earnFeeEscrowProRata(B, M, id);
        Transfers.pullQuotePermit(c, msg.sender, amount, permit2);
        LoanAccounting.meltLoan(M, id, amount); // retire this loan's claim by exactly what was paid
        emit Recash(id, amount, msg.sender);

        if (left == 0) Settlement.closeClean(B, M, c, id);
        emit Repaid(id, amount, left);
    }

    /// @notice Pulls open collateral to the hub by permit and stages it for the positionManager's pull.
    /// @dev The hub's custody lasts only this call: `open` with `payer = hub` hands it straight on.
    /// @dev The staged approval is consumed exactly, so no allowance outlives the transaction.
    function pullCollateralPermit(Cfg memory c, uint256 units, bytes calldata permit2) public {
        Transfers.pullTokenPermit(c.p.collateral, msg.sender, units, permit2);
        IERC20(c.p.collateral).forceApprove(c.positionManager, units);
    }

    /* ====== 3. EXTEND: lengthen a live loan in place, on its lender's roll policy ====== */

    /// @notice Re-anchor a live loan in place at its own tenor from now: same id, title, funding floor and debt, the fee on the time added.
    /// @notice It lands only strictly inside the term: its open second adds nothing, and from expiry nothing extends.
    /// @notice The caller pays the fee in cash, pulled after every write; resting cash never funds it.
    /// @notice Refuses through `tryExtend`'s predicate, re-raising its selector bare, so the preview and the verb cannot answer differently.
    /// @dev The policy is asked inside the predicate, before every write and before the fee pull.
    /// @dev `permit2` empty pulls on the caller's ERC20 allowance; non-empty spends a Permit2 signature.
    /// @return fee The extension's fee.
    function extend(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 minBufferWad, bytes calldata data, bytes calldata permit2)
        public
        returns (uint256 fee)
    {
        bytes4 reason;
        (reason, fee) = _extendable(B, c, id, minBufferWad, data, msg.sender);
        if (reason != bytes4(0)) {
            assembly ("memory-safe") {
                mstore(0, reason)
                revert(0, 4)
            }
        }
        _applyExtension(B, M, id, fee);
        Transfers.pullQuotePermit(c, msg.sender, fee, permit2); // balance-checked; after every write, as `repay` pulls
    }

    /// @notice Whether `extend` would land for `caller` now, and its fee: the verb's own predicate, asked of a named caller.
    /// @notice Blind to token-side failure, as `previewOpen` is; `PolicyGasShort` is a revert here too, never a reason.
    /// @param caller The address that would call `extend`: the holder, or its market lender holding the holder's grant.
    /// @return ok Whether the extension would land.
    /// @return reason The first failing leg's selector; zero when `ok`.
    /// @return fee The extension's fee; zero when refused.
    function tryExtend(LoanBook storage B, Cfg memory c, uint256 id, uint256 minBufferWad, bytes calldata data, address caller)
        public
        view
        returns (bool ok, bytes4 reason, uint256 fee)
    {
        (reason, fee) = _extendable(B, c, id, minBufferWad, data, caller);
        ok = reason == bytes4(0);
    }

    /// @dev THE PREDICATE, TOTAL: the first failing leg as a zero-arg selector, so `extend` can re-raise it with `revert(0, 4)`.
    /// @dev Legs in order: closed, the caller, matured, no time added, the lot, the borrower rule, the record, admission, the policy.
    /// @dev `caller` is a parameter so the preview names whom it asks for; the verb passes its own `msg.sender`, so both run this one body.
    /// @dev No `minPrincipal` floor and no cash leg: an extension draws nothing, so resting cash is never read.
    /// @dev The fee is on `newExpiry - expiry`, the time actually added, which the no-time leg has already proved positive.
    function _extendable(LoanBook storage B, Cfg memory c, uint256 id, uint256 minBufferWad, bytes calldata data, address caller)
        private
        view
        returns (bytes4 bad, uint256 fee)
    {
        if (B.loans[id].closedAt != 0) return (LoanClosed.selector, 0);
        Extension memory e = _extensionOf(B, c, c, id, caller);
        e.newExpiry = uint64(block.timestamp) + B.loans[id].tenor;
        bad = _extendLegs(B, c, e);
        if (bad != bytes4(0)) return (bad, 0);
        fee = LoanMath.originationFee(e.debt, e.newExpiry - e.expiry, c.p.baseBps, c.p.minTenor);
        bad = _recordLeg(c, e, minBufferWad);
        if (bad != bytes4(0)) return (bad, 0);
        if (!_askPolicy(c, e, data)) return (PolicyRefused.selector, 0);
    }

    /// @dev The caller, matured, no time added, the lot and the borrower rule, read off the extension as the loan stands, in their own frame.
    /// @dev The caller is the holder, or the market lender holding the holder's credit grant; either pays the fee, so neither raises the debt.
    /// @dev The no-time leg compares the two expiries, never the open time, so a broken term word fails closed by name.
    function _extendLegs(LoanBook storage B, Cfg memory c, Extension memory e) private view returns (bytes4) {
        address holder = e.borrower;
        if (e.caller != holder && (e.caller != c.p.lender || !B.creditOperator[holder][e.caller])) return NotBorrower.selector;
        if (block.timestamp >= e.expiry) return LoanMatured.selector;
        if (e.newExpiry <= e.expiry) return ExtensionAddsNoTime.selector;
        if (e.units == 0) return ZeroCollateral.selector; // backstop: nothing zeroes a live loan's lot
        return gateAdmits(c.p.borrower, holder) ? bytes4(0) : GateRefused.selector;
    }

    /// @dev The record and admission legs of `_extendable`, in their own frame: the extended loan as a new one at `min(price, record)`.
    function _recordLeg(Cfg memory c, Extension memory e, uint256 minBufferWad) private view returns (bytes4) {
        (bool read, RecordState s, uint256 cap) = tryRecordState(c);
        if (!read) return RecordUnreadable.selector;
        if (s == RecordState.NoPrice) return NoRecordPrice.selector;
        return _admissibleLeg(c, Math.min(c.p.price, cap), e.newDebt, e.units, minBufferWad);
    }

    /// @dev The extension's writes: earn the escrow and re-anchor the term at now, book the cash fee, bump the draw counter, and log the time added.
    /// @dev The counter moves because the lender's position did, as at a draw: it is a lender contract's change detector.
    function _applyExtension(LoanBook storage B, Market storage M, uint256 id, uint256 fee) private {
        uint64 expiry = B.loans[id].expiry;
        LoanAccounting.respread(B, M, id);
        LoanAccounting.bookExtensionFee(B, M, id, fee);
        M.s.drawCount++;
        uint64 newExpiry = B.loans[id].expiry;
        emit Extended(id, newExpiry - expiry, newExpiry, fee, msg.sender);
    }

    /// @dev The extension as the loan stands, asked for `caller`, the loan unchanged; each asker then sets what it changes.
    function _extensionOf(LoanBook storage B, Cfg memory cs, Cfg memory cd, uint256 id, address caller) private view returns (Extension memory e) {
        Loan storage L = B.loans[id];
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (caller, id, L.borrower, L.collateralUnits, L.debt, L.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (L.expiry, L.expiry, cs.p, cd.p);
    }

    /// @dev Ask the market lender's roll policy, gas-capped and read-only; zero asks nothing and is a no.
    /// @dev The zero test runs BEFORE the encode, so a lender with no policy costs no context.
    function _askPolicy(Cfg memory c, Extension memory e, bytes memory data) private view returns (bool) {
        address policy = Storage.lenders().rollPolicyOf[c.p.lender];
        if (policy == address(0)) return false;
        bytes32 yes = bytes32(IRollPolicy.admitsExtension.selector);
        return Probe.askBool(policy, abi.encodeCall(IRollPolicy.admitsExtension, (e, data)), c.policyGas, yes);
    }

    /* ====== 4. REFINANCE: close a loan and open its successor, atomically, on one shared body ====== */

    /// @notice Close this loan and open a fresh one atomically, in its own market or in another: a new id, a new floor, a fresh term.
    /// @notice The only continuation into a NEW loan; `extend` lengthens one in place.
    /// @notice A non-zero `withdrawUnits` also sheds collateral off the SUCCESSOR, released before any payout; zero skips that leg.
    /// @notice Any units, or any named `withdrawTo`, runs the recipient rule before the pair checks; zero units to no one sheds nothing.
    /// @notice The net out is PAID to the borrower in the call, as `open` pays; a quote that refuses it reverts the refinance.
    /// @notice From the expiry second it refuses `LoanMatured`, before every check but the caller and the close, and before any write.
    /// @dev Borrower-only, because it is a new borrowing decision rather than maintenance.
    /// @dev NO health gate on the old loan: its debt is retired in full, so its lenders take cash at par.
    /// @dev Every admissibility question is `open`'s, asked of the NEW loan against the destination market.
    /// @dev Collateral and quote must match before state moves: the carry moves no token, and one migration nets in ONE token.
    /// @dev Only into its own market does it reuse the retiring claim, and only on its lender's roll policy's yes, asked before any write.
    /// @dev No try/catch anywhere here -- a failed draw gate must revert the whole thing.
    function refinance(LoanBook storage B, mapping(bytes32 => Market) storage MM, Cfg memory cs, Cfg memory cd, MigrateArgs memory a)
        public
        returns (uint256 newId)
    {
        if (msg.sender != B.loans[a.id].borrower) revert NotBorrower();
        if (B.loans[a.id].closedAt != 0) revert LoanClosed();
        if (block.timestamp >= B.loans[a.id].expiry) revert LoanMatured(); // a matured loan repays or settles; it is never re-termed
        if (a.withdrawUnits != 0 || a.withdrawTo != address(0)) Recipients.check(a.withdrawTo, cd.positionManager);
        if (cs.p.collateral != cd.p.collateral) revert MarketPairMismatch();
        if (cs.p.quote != cd.p.quote) revert QuoteMismatch();
        address payee = B.loans[a.id].borrower;
        uint256 debtOld = B.loans[a.id].debt;
        uint256 refundOld;
        {
            bytes32 src = B.loans[a.id].market;
            bool reuse = _reusesClaim(B, cs, a);
            /// @dev Collateral FIRST: the carry-out lands before the melt, which leaves the pools short of `recycle` until `_fund` debits.
            /// @dev In between run only the title mint, a leaf, and the record STATICCALL; every hub view netting the pools refuses there.
            uint256 units = _closeForRefinance(B, cs, a.id);
            uint256 recycle;
            (refundOld, recycle) = _retire(B, MM[src], a.id, reuse, a.newPrincipal);
            newId = _openNew(B, MM[a.dst], cd, a, payee, units, recycle);
        }
        /// @dev Debits, gates and logs the release; MOVES NO TOKEN, so the refusal lands before any transfer.
        _withdrawCheck(B, MM[a.dst], cd, a, newId);
        uint256 out = _net(cd, a, debtOld, refundOld);
        /// @dev The transfers come after every gate and every write, so nothing reads state behind either.
        if (a.withdrawUnits != 0) IPositionManager(cd.positionManager).release(newId, a.withdrawTo, a.withdrawUnits);
        if (out != 0) IERC20(cd.p.quote).safeTransfer(payee, out); // stable LAST, as `open` sends it
        emit Refinanced(a.id, newId, a.newPrincipal, a.newTenor, out, msg.sender);
    }

    /// @dev Admission made total, in its own frame for the stack; zero means admitted.
    /// @dev It carries the coverage line as well as `_gate`'s two legs, so it refuses exactly what `_fundAndCheck` refuses.
    /// @dev LEG ORDER MATCHES `_fundAndCheck`: trigger, buffer, then the line, so both doors name the same reason.
    /// @dev The trigger is derived HERE rather than passed, so the caller never holds it alongside the cap.
    function _admissibleLeg(Cfg memory c, uint256 floor, uint256 principal, uint256 units, uint256 minBufferWad) private pure returns (bytes4) {
        uint256 trig = LoanMath.triggerPrice(principal, units, c.p.minCoverageWad, c.unitScale);
        if (trig > floor) return TriggerAboveFloor.selector;
        if (minBufferWad != 0) {
            if (floor == 0) return BufferBelowMin.selector; // the ratio below divides by it
            if (FullMath.mulDiv(floor - trig, 1e18, floor) < minBufferWad) return BufferBelowMin.selector;
        }
        return units < coverageLine(c, principal, floor) ? BelowCoverageLine.selector : bytes4(0);
    }

    /// @notice THE borrower rule, ONE spelling for every site: a market naming nobody admits any holder, else only the one it names.
    /// @dev `_gateCheck` is its reverting entry form; the extension predicate asks it directly.
    /// @dev TOTAL BY CONSTRUCTION: the extension predicate has nobody to revert to, and a comparison never reverts.
    function gateAdmits(address named, address holder) internal pure returns (bool) {
        return named == address(0) || holder == named;
    }

    /// @dev Whether the borrower's migration may reuse the retiring claim: only into the loan's own market, and on its lender's roll policy's yes.
    /// @dev Anyone may create a market naming any lender, so any other market, the same lender's included, draws its whole principal fresh.
    /// @dev A no, or no policy, reuses nothing either. Every reuse ask hands the policy `dst` equal to `src`.
    /// @dev The context's lot is the successor's after its withdrawal leg, SATURATING, so an over-ask still refuses by name at that leg.
    function _reusesClaim(LoanBook storage B, Cfg memory cs, MigrateArgs memory a) private view returns (bool) {
        if (a.dst != B.loans[a.id].market) return false;
        Extension memory e = _extensionOf(B, cs, cs, a.id, msg.sender);
        (e.units, e.newDebt) = (Math.saturatingSub(e.units, a.withdrawUnits), a.newPrincipal);
        e.newExpiry = uint64(block.timestamp) + a.newTenor;
        return _askPolicy(cs, e, "");
    }

    /// @notice The refinance close: debit the retiring loan's custody, refund left to net.
    /// @dev A sibling rather than two parameters on `Settlement.closeClean`, which every ordinary repay walks.
    /// @dev Makes no assumption about the loan's health: refinance retires the debt in full.
    /// @dev The debit sits HERE, at the close itself, so no observer ever sees a closed loan still credited with live units.
    /// @dev Its credit half runs inside the successor's open, which is the first moment the successor has an id.
    function _closeForRefinance(LoanBook storage B, Cfg memory c, uint256 id) private returns (uint256 units) {
        Loan storage L = B.loans[id];
        L.closedAt = uint64(block.timestamp);
        units = L.collateralUnits;
        L.collateralUnits = 0;
        IPositionManager(c.positionManager).carryOut(id, units);
    }

    /// @dev The draw, in its own frame: it rebuilds the bounds and the open args from the migration args.
    /// @dev It names the retiring loan as the custody source, so the open credits rather than pulls.
    /// @dev The payer field is unread on that branch and is passed zero rather than a misleading address.
    function _openNew(LoanBook storage B, Market storage M, Cfg memory cd, MigrateArgs memory a, address payee, uint256 units, uint256 recycle)
        private
        returns (uint256)
    {
        OpenBounds memory bnd = OpenBounds(0, a.bnd.minBufferWad, a.bnd.deadline);
        return _openFrom(B, M, cd, OpenArgs(a.dst, payee, address(0), address(this), units, a.newPrincipal, a.newTenor, bnd), a.id, recycle);
    }

    /// @dev The refinance's storage-only middle: earn, refund, zero the debt, melt the claim.
    /// @dev It also sizes the successor's draw: `recycle` of the claim on a reuse, which `_fund` debits no cash for.
    /// @dev Its own frame for the stack, and because NO external call may fall between these lines.
    /// @dev The fee-escrow earn MUST precede the melt: it retires the claim creditOverClaims needs.
    /// @return refundOld The unearned fee escrow, which the netting refunds.
    /// @return recycle The retiring claim the successor reuses: at most the new principal, and zero without `reuse`.
    function _retire(LoanBook storage B, Market storage M, uint256 id, bool reuse, uint256 principal) private returns (uint256 refundOld, uint256 recycle) {
        LoanAccounting.earnFeeEscrowProRata(B, M, id);
        refundOld = B.feeEscrowOf[id];
        B.feeEscrowOf[id] = 0;
        B.loans[id].debt = 0;
        uint256 claim = M.claim[id];
        recycle = reuse ? Math.min(claim, principal) : 0;
        LoanAccounting.meltRecycling(M, id, claim, recycle);
    }

    /// @notice Debits the successor's collateral for a withdrawal leg and proves the loan still stands without it.
    /// @notice Zero units returns at once: the leg is optional and every ordinary caller skips it.
    /// @notice The recipient is not asked here: `refinance` checked it first, so a named hub or positionManager never gets this far.
    /// @notice An admitted leg is logged here as `CollateralWithdrawn`, keyed by the successor's id, before the release moves it.
    /// @dev DESTINATION CFG ONLY, by signature: the source market's coverage dial must not reach either gate.
    /// @dev Runs BEFORE any transfer, so both predicates read the post-debit state and no callback sits between them.
    /// @dev The buffer gate is re-run because `_openNew` priced it on PRE-withdraw units and `triggerPrice` rises as they fall.
    /// @dev Both the gate and the line read the live fold of funding floor and record, where a zero-fresh re-term was admitted.
    /// @param cd The DESTINATION market cache.
    /// @param newId The successor loan, already opened and already holding the migrated units.
    function _withdrawCheck(LoanBook storage B, Market storage M, Cfg memory cd, MigrateArgs memory a, uint256 newId) private {
        if (a.withdrawUnits == 0) return; // the common path: a refinance that sheds nothing
        Loan storage L = B.loans[newId];
        if (a.withdrawUnits > L.collateralUnits) revert WithdrawalExceedsCollateral();
        L.collateralUnits -= a.withdrawUnits; // effect first: every predicate below reads the post state
        if (L.collateralUnits == 0) revert ZeroCollateral();
        uint256 fold = persistedPrice(cd);
        fold = Math.min(fold, LoanAccounting.fundingFloor(M, cd, newId));
        if (L.collateralUnits < coverageLine(cd, L.debt, fold)) revert BelowWithdrawLine();
        uint256 trig = triggerPrice(L, cd);
        /// @dev Its trigger leg is UNREACHABLE behind the line, which is strictly tighter; the BUFFER leg is why this runs.
        _gate(fold, trig, a.bnd.minBufferWad);
        emit CollateralWithdrawn(newId, a.withdrawTo, a.withdrawUnits, L.collateralUnits, trig);
    }

    /// @dev One netted amount: the new principal less its fee, plus the old refund, less the old debt.
    /// @dev Split out for the stack; it moves no token and books nothing, as `refinance` pays the net out in the call.
    /// @dev Every term is the SAME token, which `refinance`'s quote rail establishes before any state moves.
    /// @return out The net out, for `refinance` to pay after the release.
    function _net(Cfg memory cd, MigrateArgs memory a, uint256 debtOld, uint256 refundOld) private pure returns (uint256 out) {
        uint256 feeNew = LoanMath.originationFee(a.newPrincipal, a.newTenor, cd.p.baseBps, cd.p.minTenor);
        uint256 credit = a.newPrincipal - feeNew + refundOld; // `_openNew` already ran `_payoutCheck` on this pair, so the fee cannot exceed it
        if (credit < debtOld) revert DrawBelowDebt(); // repay the gap first, then refinance, in one multicall
        out = credit - debtOld;
        if (out < a.bnd.minPayout) revert PayoutBelowMin(); // ONE branch, so the floor binds the net out unconditionally
    }

    /* ====== 5. HEALTH: the borrower's subject, read by every actor acting ON a loan ====== */

    /// @dev Triggerable price, in the market's own price frame; pure debt arithmetic, zero with no collateral.
    function triggerPrice(Loan storage L, Cfg memory c) internal view returns (uint256) {
        return LoanMath.triggerPrice(L.debt, L.collateralUnits, c.p.minCoverageWad, c.unitScale);
    }

    /// @dev The ONE spelling of a below-price read, shared by distress, the band gate and settlement.
    /// @dev A record that cannot answer REVERTS: folded to `false` it would ADMIT the deleverage crank at `inDistress`.
    /// @dev Its own frame, so a caller near the stack limit does not hold the encode buffer (stack).
    /// @dev The twins differ only in the QUESTION encoded; both decode here, so neither can drift on failure handling.
    function _belowOrRevert(Cfg memory c, bytes memory data) private view returns (bool) {
        (bool ok, uint256 word) = Probe.askWord(c.p.record, data);
        if (!ok || word > 1) revert RecordUnreadable(); // a word outside {0, 1} is no answer, never a permissive false
        return word == 1;
    }

    /// @dev The record has held below `level` for its DISTRESS window: the guards' question.
    function persistedBelowOrRevert(Cfg memory c, uint256 level) internal view returns (bool) {
        return _belowOrRevert(c, abi.encodeCall(IPersistenceRecord.persistedBelowDistress, (c.p.quote, c.p.collateral, level)));
    }

    /// @dev The record has held below `level` for its SETTLE window: the question the title transfer asks.
    function persistedBelowSettleOrRevert(Cfg memory c, uint256 level) internal view returns (bool) {
        return _belowOrRevert(c, abi.encodeCall(IPersistenceRecord.persistedBelowSettle, (c.p.quote, c.p.collateral, level)));
    }

    /// @dev Distress: the record has held below this loan's trigger for the guard window.
    function inDistress(Loan storage L, Cfg memory c) internal view returns (bool) {
        if (L.closedAt != 0) return false;
        return persistedBelowOrRevert(c, triggerPrice(L, c));
    }

    /// @dev Windowed-min record price; max sentinel when no record is wired.
    /// @dev The max is a RULING, not a fallback: the lender's resting bid is the only brake.
    /// @dev Refuses a malformed answer BY DESIGN: cranks must refuse; only the try twin absorbs sickness.
    /// @dev A record that cannot answer REVERTS here and is never folded to zero: zero is permissive at the lending door.
    function persistedPrice(Cfg memory c) internal view returns (uint256) {
        if (c.p.record == address(0)) return type(uint256).max;
        bytes memory data = abi.encodeCall(IPersistenceRecord.minPrice, (c.p.quote, c.p.collateral));
        (bool ok, uint256 word) = Probe.askWord(c.p.record, data);
        if (!ok) revert RecordUnreadable();
        return word;
    }

    /// @dev persistedPrice() that reports an unusable record instead of reverting.
    /// @dev Not-ok covers a failed call, a short return AND a zero answer.
    /// @dev Keeps the `record == 0 -> max` ruling; max is non-zero, so None never reads as not-ok.
    /// @dev `Probe.askWord`, not try/catch: try cannot catch a failed DECODE of the answer.
    /// @dev No hub verb reads it: the extension predicate and the deposit ask `tryRecordState`, which keeps unreadable apart from answered-zero.
    function tryPersistedPrice(Cfg memory c) internal view returns (bool ok, uint256 p) {
        if (c.p.record == address(0)) return (true, type(uint256).max);
        bytes memory data = abi.encodeCall(IPersistenceRecord.minPrice, (c.p.quote, c.p.collateral));
        (bool s, uint256 word) = Probe.askWord(c.p.record, data);
        if (!s) return (false, 0);
        return (word != 0, word);
    }

    /// @notice What the record is saying, decoded ONCE so no call site reads a raw sentinel.
    /// @dev `persistedPrice` has three answers and BOTH ends are sentinels, which is how one got missed.
    /// @dev None: no record wired, the price leg is inert and any price is fundable BY RULING.
    /// @dev NoPrice: the record ANSWERED zero -- a ring short of the window, one gone silent, a stale feed; NO answer is `RecordUnreadable`.
    /// @dev Live: `cap` is a real windowed minimum, the price a verb may act at or below.
    /// @dev Every judgment-spending verb fails closed on NoPrice; the deposit alone fails OPEN.
    /// @dev `tryRecordState` is the total twin below and decodes identically; edit one and the other must move with it.
    function recordState(Cfg memory c) internal view returns (RecordState, uint256) {
        if (c.p.record == address(0)) return (RecordState.None, type(uint256).max);
        uint256 cap = persistedPrice(c);
        return cap == 0 ? (RecordState.NoPrice, 0) : (RecordState.Live, cap);
    }

    /// @notice recordState() that reports an unreadable record instead of reverting.
    /// @dev The TOTAL twin, for a predicate that must answer rather than revert.
    /// @dev `tryPersistedPrice` cannot serve: it collapses unreadable and answered-zero, which the doors here diverge on.
    /// @param c The market config cache.
    /// @return ok False only when the record could not be read at all.
    /// @return s What the record is saying, decoded exactly as `recordState` decodes it.
    /// @return cap The windowed minimum a verb may act at or below; zero unless `s` is Live.
    function tryRecordState(Cfg memory c) internal view returns (bool ok, RecordState s, uint256 cap) {
        if (c.p.record == address(0)) return (true, RecordState.None, type(uint256).max);
        bytes memory data = abi.encodeCall(IPersistenceRecord.minPrice, (c.p.quote, c.p.collateral));
        (bool got, uint256 word) = Probe.askWord(c.p.record, data);
        if (!got) return (false, RecordState.NoPrice, 0);
        return word == 0 ? (true, RecordState.NoPrice, 0) : (true, RecordState.Live, word);
    }

    /// @dev Units needed to keep `debt` admissible at `price`, ceiled.
    /// @dev DEBT FIRST: no debt needs no units at any price, and both readers agree only in that order.
    /// @dev The max is the MOST RESTRICTIVE answer here, not the safest one: it is a required QUANTITY.
    /// @dev A plain `price * 1e18` wraps above `max / 1e18`, which is well inside the admissible price band.
    /// @dev Above it the two factors divide in turn: `ceil(ceil(x/a)/b) == ceil(x/(ab))` for positive integers, so no seam.
    function requiredAt(Cfg memory c, uint256 debt, uint256 price) internal pure returns (uint256) {
        return requiredAt(c.p.minCoverageWad, c.unitScale, debt, price);
    }

    /// @notice The same quantity on the two market fields it reads, which is how genesis asks before any `Cfg` exists.
    function requiredAt(uint256 minCoverageWad, uint256 unitScale, uint256 debt, uint256 price) internal pure returns (uint256) {
        if (debt == 0) return 0; // nothing to secure
        if (price == 0) return type(uint256).max; // closed, unfunded, or a record that cannot price: fail closed
        uint256 num = minCoverageWad * debt;
        if (price <= type(uint256).max / 1e18) return FullMath.mulDivRoundingUp(num, unitScale, price * 1e18);
        return FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(num, unitScale, price), 1, 1e18);
    }

    /// @notice The coverage line: the smallest ADMISSIBLE holding, at `minCoverageWad` times settlement's own need.
    /// @notice Read at BOTH doors -- admission may not open under it, and a withdrawal may not fall below it.
    /// @notice `requiredAt` plus ONE atom -- DERIVED off that same rail, never a chosen constant.
    /// @dev The atom IS settlement's ceiling excess: `collateralNeeded` ceils the claim once, and one ceil overshoots by under one atom.
    /// @dev Debt-INDEPENDENT, which is the point -- the proportional coverage margin thins as debt melts and this term does not.
    /// @dev Saturating: `requiredAt` returns the max sentinel at price zero, and adding to it would panic instead of refusing by name.
    /// @param c The market config cache.
    /// @param debt The loan's live debt.
    /// @param price The price to secure at.
    /// @return The smallest admissible holding.
    function coverageLine(Cfg memory c, uint256 debt, uint256 price) internal pure returns (uint256) {
        return coverageLine(c.p.minCoverageWad, c.unitScale, debt, price);
    }

    /// @notice The same line on the two market fields it reads, for genesis's openable-ticket rail.
    function coverageLine(uint256 minCoverageWad, uint256 unitScale, uint256 debt, uint256 price) internal pure returns (uint256) {
        uint256 req = requiredAt(minCoverageWad, unitScale, debt, price);
        return Math.saturatingAdd(req, 1);
    }
}
