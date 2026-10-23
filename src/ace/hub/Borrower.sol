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
import {Probe} from "./libraries/Probe.sol";
import {Transfers} from "./libraries/Transfers.sol";
import {Recipients, ZeroWithdrawTo} from "./libraries/Recipients.sol"; // ZeroWithdrawTo is re-exported for importers of this file
import {Settlement} from "./Settlement.sol";
import {MarketInit} from "./MarketInit.sol";
import {PositionTitleNFT} from "../positions/PositionTitleNFT.sol";
import {AutoPolicy, Cfg, Loan, LoanBook, Market, MarketParams, MigrateArgs, OpenBounds, PreAdmitted, RecordState, RollFrames, Storage} from "./Types.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";

error LoanClosed(); // the loan is retired: no borrower verb touches it
error OpenExpired(); // the open's own deadline passed before it landed
error ZeroCollateral(); // an unsecured loan is unfinalizable: triggerPrice(0) == 0 clears every gate
error CollateralOutOfRange(); // wider than the trigger's own denominator carries: `units * 1e18` would wrap
error WithdrawalExceedsCollateral(); // the requested withdrawal exceeds the loan's remaining collateral
error ZeroPrincipal(); // a loan securing nothing takes no claim, so it never gets a funding floor
error InsufficientCash(); // the market's UNRESERVED resting cash is less than this draw asks, or its price is over the cap on a fresh draw
error BelowMinDebt(); // principal under the market's minDebt, or a third party's repay leaving a live loan under it
error TenorOutOfRange(); // tenor outside the market's min/max
error GateRefused(); // the borrower is not the market's one named borrower, so the new credit is refused; it can never block a settlement
error PayoutBelowMin(); // fees left the borrower less cash than their floor
error TriggerAboveFloor(); // a trigger at or above the funding floor would be liquidatable at birth
error BufferBelowMin(); // the gap between funding floor and trigger is thinner than the borrower asked
error BelowWithdrawLine(); // a withdrawal leg falling under the coverage line: the settlement slack refuses it, not the trigger
error BelowCoverageLine(); // a draw opening under that same line: settlement's own ceiling refuses it at admission
error AlreadyFunded(); // a second draw on a live claim would overwrite it while `lent` adds both; it disarms at the close and is not what keeps ids fresh
error NotBorrower(); // only the loan's own borrower may refinance it
error AutoPolicyDisarmed(); // no auto policy stands on this loan: tenor zero IS disarmed
error OutsideRefinanceWindow(); // the policy is armed, but the window onto this loan's expiry has not opened
error AutoTenorUnfundable(); // an auto tenor whose all-in fee breaks the fee-share ceiling
error MarketPairMismatch(); // migration destination secures a different collateral: refuse before state moves
error QuoteMismatch(); // migration destination quotes in a different token: one migration, one quote
error DrawBelowDebt(); // the fresh draw plus the old fee refund cannot retire the old debt; repay the gap first
error NoRecordPrice(); // the record cannot produce a windowed minimum: judgment-spending verbs refuse rather than guess
error RecordUnreadable(); // the record gave no usable answer: reverted, returned short, has no code, or a persisted-below word outside {0, 1}
error CrossMarketDisarmed(); // a foreign destination was named on a policy carrying no fee ceiling: zero is home-only
error HomeRollExclusive(); // the incumbent's leading share of the roll window has not run out yet
error RecordMismatch(); // destination prices off a different source: a keeper may re-price, never re-anchor
error TermsMismatch(); // destination moves the loss endpoint, or gates a loan that opened ungated
error FeeAboveMax(); // the destination's realized origination rate exceeds the borrower's own ceiling
error MinDebtRaised(); // destination floors draws higher than the source: its floor would inflate the successor
error PriceLowered(); // destination bids under the source: settlement would convert the claim into more collateral
error CoverageRaised(); // destination demands more coverage than the source: its line would take more collateral
error RollUnbacked(); // the market's unreserved cash cannot hold this loan's expiry roll: armed means reserved
error ArmNeedsRecord(); // a recordless market cannot arm: its home roll would be judged at the lender's own price
error BufferOutOfRange(); // the armed auto buffer is the whole floor or more: a live trigger is never zero, so no roll could meet it
error RoutingNeedsBuffer(); // venue consent with no risk distance named: the borrower's pre-commit is incomplete

/* ========================================================================= */
/*  TABLE OF CONTENTS                                                        */
/*  1. OPEN        the draw path, and the funding floor it stamps            */
/*  2. REPAY       paying a loan down, and the clean close at zero           */
/*  3. REFINANCE   close a loan and open its successor, atomically           */
/*  4. HEALTH      trigger, rate and the price record                        */
/* ========================================================================= */

/// @title Borrower
/// @notice Every verb whose judgment is the BORROWER's: open, repay, refinance, and the health they turn on.
/// @notice A loan draws exactly once and NEVER extends -- a continuation is a fresh loan, in section 3.
/// @dev Every `msg.sender` here is the EXTERNAL caller, never the hub: the borrower-only gate rests on it.
library Borrower {
    using SafeERC20 for IERC20;

    /// @dev `executor` throughout is the EXTERNAL caller a periphery sponsor pays against.
    /// @dev `netOut` is the borrower's net out: paid in the call by `refinance`/`refinanceTo`, credited by the policy doors and the fold.
    event Refinanced(uint256 indexed oldId, uint256 indexed newId, uint256 newPrincipal, uint64 newTenor, uint256 netOut, address indexed executor);
    /// @notice A loan's auto policy was set; `tenor == 0` is a disarm, and an indexer reads the tenor before the other two fields.
    /// @notice A disarm through `setAutoRefinance` logs the buffer and ceiling the caller passed; a carry's or a title move's logs zeros.
    event AutoPolicySet(uint256 indexed id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps);
    /// @notice A borrower's withdrawal sent `units` to `to`: by `withdrawCollateral`, or by a `refinanceTo` leg keyed by the successor's id.
    /// @notice It is logged before the release; a deleverage sale also takes units off a live loan, and logs `Deleveraged` instead.
    event CollateralWithdrawn(uint256 indexed id, address indexed to, uint256 units, uint256 unitsLeft, uint256 newTrigger);

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
    /// @dev A refinance, policy continuation or roll pays the hub; an order fill pays the maker; both carry, so payer is zero.
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
    /// @dev `to` is ALWAYS the payee, who took the draw less its fee; on a refinance or a roll that is the hub, which nets it.
    /// @dev It equals the executor only on the doors that pay their caller; a keeper or a filler is logged by its own verb's event.
    /// @dev No price field: every draw funds at its market's one price, `idToMarketParams(loanMarket(loanId)).price`.
    event Funded(uint256 indexed loanId, uint256 amount, address indexed to);
    /// @dev `from` is the payer; on a deleverage that is the hub itself, and the keeper is `Deleveraged.executor`.
    event Recash(uint256 indexed loanId, uint256 amount, address indexed from);
    event Repaid(uint256 indexed id, uint256 amount, uint256 remainingDebt);

    /* ====== 1. OPEN: the draw path, and the ONLY one that funds a new loan from scratch ====== */

    uint256 internal constant NO_PREDECESSOR_LOAN = 0; // ids start at one, so zero names no loan: this open pulls from a.payer

    /// @notice Opens a terminal loan against escrowed collateral, funded by the market's UNRESERVED resting cash.
    /// @dev borrower holds title and the debt; payer funds the positionManager; payee takes the payout.
    /// @dev They are separate because the doors split them: an operator is paid for another's title, and the permit door's payer is the hub.
    /// @dev Payout sent last (CEI).
    function open(LoanBook storage B, Market storage M, Cfg memory c, OpenArgs memory a) public returns (uint256 id) {
        return _openFrom(B, M, c, a, NO_PREDECESSOR_LOAN, PreAdmitted(false, bytes32(0), 0, 0));
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
    /// @dev No pre-admission: a fill asked nothing before it got here, so the open runs the whole gauntlet.
    /// @dev A resting order is not an admitted one -- the borrower rule and the record are checked at the FILL, never at the post.
    function openCarried(LoanBook storage B, Market storage M, Cfg memory c, OpenArgs memory a, uint256 fromId) public returns (uint256) {
        return _openFrom(B, M, c, a, fromId, PreAdmitted(false, bytes32(0), 0, 0));
    }

    /// @notice The one open body; a refinance or an order fill reaches it naming the id whose custody it inherits.
    /// @dev The custody source is its OWN parameter, so no existing field ever carries a second meaning.
    /// @dev Ids start at one, so zero can never name a real predecessor and the constant is sound, not conventional.
    /// @dev A carried open moves no token: the units are already in the pot, credited to the id they are carried from.
    /// @dev A `pre` whose gauntlet ran against ANOTHER market is not this open's answer, and is re-asked rather than trusted.
    function _openFrom(LoanBook storage B, Market storage M, Cfg memory c, OpenArgs memory a, uint256 predecessorLoanId, PreAdmitted memory pre)
        private
        returns (uint256 id)
    {
        /// @dev NORMALIZED here, once: past this line `pre.asked` means "answers for THIS open", market included.
        /// @dev A migration carries a source AND a destination cache, so the market test is the whole safety of the thread.
        pre.asked = pre.asked && pre.market == a.market;
        _preChecks(c, a);
        if (!pre.asked) _gateCheck(c, a);
        uint256 fee = LoanMath.originationFee(a.principal, a.tenor, c.p.baseBps, c.p.minTenor);
        _payoutCheck(c, a, fee);
        id = _record(B, c, a, fee);

        /// @dev Both secondary ledgers land here, before ANY external call: no half-created observer.
        /// @dev For a FRESH id the mint is a leaf: `_mint` runs no receiver hook, and `previousOwner == 0` skips the retitle branch.
        /// @dev A REUSED loan id is refused here: its retitle callback trips the hub's guard, and `_mint` would refuse it next anyway.
        PositionTitleNFT(c.positionTitle).mint(id, a.borrower);
        M.openedLoans.push(id); // append-only: what marketLoans pages, so a keeper finds a market's loans without an indexer

        _splitAndDraw(B, M, c, a, id, fee, pre);

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
    function _splitAndDraw(LoanBook storage B, Market storage M, Cfg memory c, OpenArgs memory a, uint256 id, uint256 fee, PreAdmitted memory pre) private {
        uint256 protocolFee = LoanMath.protocolCut(fee);
        B.feeEscrowOf[id] = LoanMath.escrowCut(fee);
        uint256 tickFee = LoanMath.tickCut(fee);
        _fundAndCheck(M, c, B.loans[id], id, a.principal, tickFee, protocolFee, a.bnd.minBufferWad, pre);
        emit Funded(id, a.principal, a.payee);
    }

    /// @notice The tenor sentinel, ONE spelling for every door that takes a term: zero means the market's `minTenor`.
    /// @dev `setAutoRefinance` is not such a door: there a zero tenor means disarm.
    function tenorOrMin(uint64 tenor, uint64 minTenor) internal pure returns (uint64) {
        return tenor == 0 ? minTenor : tenor;
    }

    /// @dev The LOCAL pre-draw refusals, shared by `open` and `previewOpen`; the gate rides beside it in `_gateCheck`.
    /// @dev Deadline FIRST: a stale queued open must not execute under drifted state.
    /// @dev ZeroPrincipal BEFORE BelowMinDebt: below it the floor rail catches the zero first and it goes dead.
    function _preChecks(Cfg memory c, OpenArgs memory a) private view {
        if (a.bnd.deadline != 0 && block.timestamp > a.bnd.deadline) revert OpenExpired();
        if (a.collateralUnits == 0) revert ZeroCollateral();
        /// @dev EVERY loan's stored units enter through here, so this one bound holds for all of them.
        /// @dev Only `Deleverage`'s refund ever raises a stored figure, and never past the decrement it reverses.
        if (a.collateralUnits > type(uint256).max / 1e18) revert CollateralOutOfRange();
        if (a.principal == 0) revert ZeroPrincipal();
        if (a.principal < c.p.minDebt) revert BelowMinDebt();
        if (a.tenor < c.p.minTenor || a.tenor > c.p.maxTenor) revert TenorOutOfRange();
    }

    /// @dev The entry check: a market may name one borrower, and zero names everybody.
    /// @dev It refuses the BORROWER, not the caller, so an operator or keeper never launders one.
    /// @dev A borrower-initiated migration checks the DESTINATION market's borrower through this same call.
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

        q.postDrawFloor = _previewFloor(M, c, a.principal, PreAdmitted(false, bytes32(0), 0, 0));
        q.triggerAtOpen = LoanMath.triggerPrice(a.principal, a.collateralUnits, c.p.minCoverageWad, c.unitScale);
        q.bufferWad = _gate(q.postDrawFloor, q.triggerAtOpen, a.bnd.minBufferWad);
        if (a.collateralUnits < coverageLine(c, a.principal, q.postDrawFloor)) revert BelowCoverageLine();
    }

    /// @dev The floor a draw taking `fresh` of the market's cash is judged at: the market's price, or the record under it.
    /// @dev There is no walk to preview; the only question is whether the market's own cash and cap admit the draw.
    /// @dev A cap BELOW the market's price refuses a FRESH draw -- resting cash the market will not lend from is a stale bid.
    /// @dev A zero-fresh draw, a home re-term the old debt recycles whole, is judged at that cap instead, as the home roll is.
    /// @dev The cash leg still runs at zero fresh: in a deficit it refuses on OTHER loans' reservations, so it is no clean lender veto.
    /// @dev A home roll threads the max sentinel as its cap: its record leg ran in the predicate, against the successor.
    function _previewFloor(Market storage M, Cfg memory c, uint256 fresh, PreAdmitted memory pre) private view returns (uint256 floor) {
        uint256 cap = pre.drawCap;
        if (!pre.asked) {
            RecordState s;
            (s, cap) = recordState(c);
            if (s == RecordState.NoPrice) revert NoRecordPrice();
        }
        floor = c.p.price;
        if (floor > cap) {
            if (fresh != 0) revert InsufficientCash();
            floor = cap;
        }
        if (!cashAdmits(M, fresh, 0)) revert InsufficientCash();
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
        PreAdmitted memory pre
    ) private {
        uint256 floor = _fund(M, c, loanId, principal, tickFee, protocolFee, pre);
        _gate(floor, triggerPrice(L, c), minBufferWad);
        if (L.collateralUnits < coverageLine(c, L.debt, floor)) revert BelowCoverageLine();
    }

    /// @dev Funds from the market's resting cash, at the market's one price.
    /// @dev THE BACKSTOP READS THE CLAIM, not a stored floor: a second draw on a live claim would overwrite it.
    /// @dev A full repay and settlement zero the claim, so it guards a live loan only; a reused id is refused at the title mint.
    /// @dev NO FEE SPLIT: one claim takes the whole lender fee exactly, so no rounding residue reaches `protocolRevenue`.
    /// @dev A HOME MIGRATION'S DRAW IS NET: `pre.recycle` of its principal is the retiring claim, so only the rest leaves cash.
    function _fund(Market storage M, Cfg memory c, uint256 loanId, uint256 principal, uint256 tickFee, uint256 protocolFee, PreAdmitted memory pre)
        private
        returns (uint256 floorPrice)
    {
        if (M.claim[loanId] != 0) revert AlreadyFunded(); // a live claim refuses a second draw; ids stay fresh by the counter
        uint256 fresh = principal - pre.recycle; // `migrate` caps the recycle at the principal
        floorPrice = _previewFloor(M, c, fresh, pre);
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

    /// @notice Pays debt down, retiring the loan's claim by exactly what was paid.
    /// @notice Full repayment closes the loan.
    /// @notice Anyone may pay a loan off; only its borrower may pay it down into `(0, minDebt)`.
    /// @notice The test is `msg.sender`, so a router or relayer paying for the borrower must pay off or leave at least `minDebt`.
    /// @dev `permit2` empty pulls on the payer's ERC20 allowance; non-empty spends a Permit2 signature.
    /// @dev A partial repay SHRINKS an armed loan's reservation to its roll's new need, floored at `minDebt - 1`, and never grows it.
    /// @dev Under `minDebt` the successor floors at `minDebt`, so the roll's fresh need can outgrow that reservation.
    function repay(LoanBook storage B, Market storage M, Cfg memory c, uint256 id, uint256 amount, bytes calldata permit2) public {
        Loan storage L = B.loans[id];
        if (L.closedAt != 0) revert LoanClosed();
        amount = Math.min(amount, L.debt);
        uint256 left = L.debt - amount;
        if (left != 0 && left < c.p.minDebt && msg.sender != L.borrower) revert BelowMinDebt();

        L.debt -= amount;
        /// @dev BEFORE the melt: it retires the claim the earned slice is credited over.
        if (L.debt == 0) LoanAccounting.earnFeeEscrowProRata(B, M, id);
        else shrinkReserve(B, M, c, id);
        Transfers.pullQuotePermit(c, msg.sender, amount, permit2);
        LoanAccounting.meltLoan(M, id, amount); // retire this loan's claim by exactly what was paid
        emit Recash(id, amount, msg.sender);

        if (L.debt == 0) Settlement.closeClean(B, M, c, id);
        emit Repaid(id, amount, L.debt);
    }

    /// @notice Pulls open collateral to the hub by permit and stages it for the positionManager's pull.
    /// @dev The hub's custody lasts only this call: `open` with `payer = hub` hands it straight on.
    /// @dev The staged approval is consumed exactly, so no allowance outlives the transaction.
    function pullCollateralPermit(Cfg memory c, uint256 units, bytes calldata permit2) public {
        Transfers.pullTokenPermit(c.p.collateral, msg.sender, units, permit2);
        IERC20(c.p.collateral).forceApprove(c.positionManager, units);
    }

    /* ====== 3. REFINANCE: close a loan and open its successor, atomically, on one shared body ====== */

    /// @notice Close this loan and open a fresh one atomically, in its own market or in another.
    /// @notice The only continuation path; a loan never extends.
    /// @notice An ARMED loan refuses `ArmNeedsRecord` into a recordless market, `RollUnbacked` where its roll cannot be re-reserved.
    /// @notice Disarm in the same multicall to go on unarmed.
    /// @dev Borrower-only, because it is a new borrowing decision rather than maintenance.
    /// @dev NO health gate on the old loan: its debt is retired in full, so its lenders take cash at par.
    /// @dev Every admissibility question is `open`'s, asked of the NEW loan against the destination market.
    /// @dev No try/catch anywhere here -- a failed draw gate must revert the whole thing.
    function refinance(LoanBook storage B, mapping(bytes32 => Market) storage MM, Cfg memory cs, Cfg memory cd, MigrateArgs memory a)
        public
        returns (uint256 newId)
    {
        if (msg.sender != B.loans[a.id].borrower) revert NotBorrower();
        if (B.loans[a.id].closedAt != 0) revert LoanClosed();
        /// @dev No pre-admission: this door asked nothing, so the open runs the whole gauntlet against the DESTINATION.
        /// @dev Safe where the fold is not, because a refusal here reverts a caller's own request and commits nothing.
        newId = migrate(B, MM, cs, cd, a, PreAdmitted(false, bytes32(0), 0, 0), true);
    }

    /// @notice Continue an armed loan on the borrower's own stored terms; permissionless inside the window.
    /// @notice `dst` may be another market once the incumbent's leading share of the window has run out.
    /// @dev The caller supplies NO number: tenor, buffer and fee ceiling are the borrower's, the principal is derived.
    /// @dev Refuses through `tryContinue`, so the quote and the verb cannot answer differently.
    /// @dev The re-raise keeps every selector this verb has always thrown; see the rail on `tryContinue`.
    function refinanceByPolicy(LoanBook storage B, mapping(bytes32 => Market) storage MM, RollFrames memory r, uint256 id) public returns (uint256 newId) {
        (uint256 principal, uint256 cap) = _demandContinuable(B, MM, r, id);
        newId = migrate(B, MM, r.cs, r.cd, _policyArgs(B, id, r.dst, principal), PreAdmitted(true, r.dst, cap, 0), false);
    }

    /// @dev The predicate and its re-raise in their own frame, so the verb never holds `ok` and `reason` (stack).
    /// @dev THE RAIL LIVES HERE: `revert(0, 4)` re-raises the selector bare, so every attributable leg is zero-arg.
    function _demandContinuable(LoanBook storage B, mapping(bytes32 => Market) storage MM, RollFrames memory r, uint256 id)
        private
        view
        returns (uint256 principal, uint256 cap)
    {
        bool ok;
        bytes4 reason;
        (ok, reason, principal, cap) = tryContinue(B, MM, r, id, B.loans[id].collateralUnits);
        if (!ok) {
            assembly ("memory-safe") {
                mstore(0, reason)
                revert(0, 4)
            }
        }
    }

    /// @dev The migration args in their own frame: the verb holds three predicate returns already (stack).
    function _policyArgs(LoanBook storage B, uint256 id, bytes32 dst, uint256 principal) private view returns (MigrateArgs memory) {
        AutoPolicy memory ap = B.autoPolicyOf[id];
        /// @dev The zeroes are STRUCTURAL: a policy continuation supplies no caller numbers, so it can shed no collateral.
        /// @dev Any field appended to `MigrateArgs` inherits this silence -- give it a zero that means "the policy declines it".
        return MigrateArgs(id, dst, principal, ap.tenor, OpenBounds(0, uint256(ap.minBufferBps) * 1e14, 0), 0, address(0));
    }

    /// @notice Whether an armed loan may continue right now, and the debt its successor would carry.
    /// @notice TOTAL: every refusal is reported as a selector, so the fold gets an answer and never a throw.
    /// @notice THE ONE ADMISSIBILITY BODY: the expiry fold, `refinanceByPolicy` and the hub view all read it.
    /// @notice `ok` is BLOCK-SCOPED: the cash leg moves with every deposit, withdraw and draw.
    /// @notice Blind to token-side failure, exactly as `previewOpen` is: those turn on balances, not loan state.
    /// @dev `reason` is the FIRST failing leg in the order below, and every attributable error is ZERO-ARG.
    /// @dev THE RAIL: only zero-arg errors may be attributed, because `refinanceByPolicy` re-raises with revert(0,4).
    /// @dev `units` is a parameter because the fold judges `units - sliver` and this door judges the whole lot.
    /// @dev `drawCap` is the cap this predicate ALREADY read, the max sentinel on a home roll, so the roll it admits never re-reads it.
    /// @dev `cs` is the RETIRING market and `cd` the destination; a same-market roll passes the same cache twice.
    /// @dev The window opens at the loan's expiry less a lead sized by the SOURCE market's `minTenor`, and never shuts.
    /// @dev `settleExpired` waits past expiry by a span sized by the loan's OWN tenor, so the open window always covers that wait.
    /// @dev Everything the NEW credit is judged on is the DESTINATION's: fee, tenor grid, principal, gate, record and cash.
    /// @dev It takes the MAPPING and indexes `r.dst` itself: a caller-passed `Market storage` would be a SECOND source for the market this judges.
    function tryContinue(LoanBook storage B, mapping(bytes32 => Market) storage MM, RollFrames memory r, uint256 id, uint256 units)
        internal
        view
        returns (bool ok, bytes4 reason, uint256 principal, uint256 drawCap)
    {
        Loan storage L = B.loans[id];
        if (L.closedAt != 0) return (false, LoanClosed.selector, 0, 0);
        AutoPolicy memory ap = B.autoPolicyOf[id];
        if (ap.tenor == 0) return (false, AutoPolicyDisarmed.selector, 0, 0);
        /// @dev written as an addition so a tenor shorter than the window cannot underflow the bound
        if (block.timestamp + MarketInit.autoRefinanceWindow(r.cs.p.minTenor) < L.expiry) {
            return (false, OutsideRefinanceWindow.selector, 0, 0);
        }
        /// @dev The compat legs are pure struct compares, so they run BEFORE the record read.
        /// @dev A mismatched destination then costs no dependency read, which is what keeps a griefed quote cheap.
        bytes4 bad = _compatLeg(L, r, ap);
        if (bad != bytes4(0)) return (false, bad, 0, 0);
        if (units == 0) return (false, ZeroCollateral.selector, 0, 0); // backstop: nothing zeroes a live loan's lot
        if (!LoanMath.feeFundable(r.cd.p.baseBps, ap.tenor, r.cd.p.minTenor)) {
            return (false, AutoTenorUnfundable.selector, 0, 0);
        }
        if (ap.tenor < r.cd.p.minTenor || ap.tenor > r.cd.p.maxTenor) return (false, TenorOutOfRange.selector, 0, 0);
        principal = derivedPrincipal(B, r.cd, id, ap.tenor); // safe after the rail above; floors at minDebt
        /// @dev The derived principal is floored at minDebt above, so this cannot fire while that floor stands.
        /// @dev The open still carries its own minDebt refusal, and without the floor this is what keeps the fold total.
        if (principal < r.cd.p.minDebt) return (false, BelowMinDebt.selector, 0, 0);
        /// @dev ROUTED ONLY. The ceiling bounds a venue the borrower did not choose; their own market is not one.
        /// @dev At expiry the fold settles on ANY refusal, so a ceiling that bound the home roll would be terminal.
        /// @dev The realized rate carries the protocol share on top, so the market's advertised dial under-sets it.
        if (r.dst != L.market) {
            bad = _feeLeg(r.cd, ap, principal);
            if (bad != bytes4(0)) return (false, bad, 0, 0);
        }
        if (!gateAdmits(r.cd.p.borrower, L.borrower)) {
            return (false, GateRefused.selector, 0, 0); // a named borrower stops the NEW credit, never settlement
        }
        return _continuationLeg(MM, r, L, principal, ap, units);
    }

    /// @dev The borrower's COST pre-commit, on the REALIZED rate rather than any one dial.
    /// @dev Multiplicative, so the fee's own ceil rounding is never divided back out and no second artefact appears.
    /// @dev A zero ceiling is home-only and never reaches here: `_compatLeg` refuses a foreign destination first.
    function _feeLeg(Cfg memory cd, AutoPolicy memory ap, uint256 principal) private pure returns (bytes4) {
        if (ap.maxFeeBps == 0) return bytes4(0);
        uint256 fee = LoanMath.originationFee(principal, ap.tenor, cd.p.baseBps, cd.p.minTenor);
        return fee * 10000 > uint256(ap.maxFeeBps) * principal ? FeeAboveMax.selector : bytes4(0);
    }

    /// @dev Whether this destination may take this loan at all: consent, the clock, and the loss endpoint.
    /// @dev A same-market roll clears every leg trivially, so the home path is unchanged by construction.
    /// @dev KEEPER PATH ALONE: a borrower's own `refinanceTo` never reaches here, so they may migrate into terms these legs refuse a keeper.
    function _compatLeg(Loan storage L, RollFrames memory r, AutoPolicy memory ap) private view returns (bytes4) {
        if (r.dst == L.market) return bytes4(0); // the home roll asks none of this
        if (ap.maxFeeBps == 0) return CrossMarketDisarmed.selector; // no named price means no consent to a named venue
        /// @dev THE PERMANENT REFUSALS COME FIRST, and the ordering is the contract rather than a cost saving.
        /// @dev `HomeRollExclusive` means "retry later", so a destination that can NEVER take this loan must not answer it first.
        if (r.cs.p.collateral != r.cd.p.collateral) return MarketPairMismatch.selector;
        if (r.cs.p.quote != r.cd.p.quote) return QuoteMismatch.selector;
        if (r.cs.p.record != r.cd.p.record) return RecordMismatch.selector;
        /// @dev THE THREE DIRECTIONAL LEGS, each bounding a dial that sizes what SETTLEMENT takes.
        /// @dev Directional and never equality: a destination strictly better for the borrower stays admissible.
        /// @dev THE BUFFER COVERS NEITHER PRICE NOR COVERAGE -- it bounds one OVER the other, so the two trade off along it.
        /// @dev Price and coverage therefore ship TOGETHER; either leg alone is taken back by the other dial.
        /// @dev `derivedPrincipal` FLOORS the successor at the destination's `minDebt`, so a higher one raises the debt.
        /// @dev `maxFeeBps` bounds the RATE and never the NOTIONAL, so without this a keeper names the size of the loan.
        if (r.cd.p.minDebt > r.cs.p.minDebt) return MinDebtRaised.selector;
        /// @dev Settlement converts the claim at the SUCCESSOR's price, so a cheaper destination takes MORE collateral.
        if (r.cd.p.price < r.cs.p.price) return PriceLowered.selector;
        /// @dev The coverage line is `k` times the debt, so a higher `k` takes more at the same price.
        if (r.cd.p.minCoverageWad > r.cs.p.minCoverageWad) return CoverageRaised.selector;
        /// @dev A loan that opened in an OPEN market may not be routed into one that names a borrower.
        /// @dev The destination's named party would otherwise hold a veto over a roll the borrower never chose.
        if (r.cs.p.borrower == address(0) && r.cd.p.borrower != address(0)) return TermsMismatch.selector;
        bytes4 down = _downsideLeg(r.cs, r.cd);
        if (down != bytes4(0)) return down;
        /// @dev The clock runs LAST: it is the only refusal here that time alone can lift.
        /// @dev The incumbent's first refusal, for the inventory hold's reason; but this hold is the STRANGER's tail, counted back from expiry.
        if (block.timestamp + MarketInit.homeRollHold(r.cs.p.minTenor) < L.expiry) return HomeRollExclusive.selector;
        return bytes4(0);
    }

    /// @dev The six dials that fix where a loan ENDS. A keeper may change the price; never the loss endpoint.
    /// @dev Split from `_compatLeg` for the stack, not for meaning: the two are one rule read in one place.
    function _downsideLeg(Cfg memory cs, Cfg memory cd) private pure returns (bytes4) {
        if (cs.p.settleBountyBps != cd.p.settleBountyBps) return TermsMismatch.selector;
        if (cs.p.deleverageBandBps != cd.p.deleverageBandBps) return TermsMismatch.selector;
        if (cs.p.deleverageTargetBps != cd.p.deleverageTargetBps) return TermsMismatch.selector;
        if (cs.p.deleverageStopBps != cd.p.deleverageStopBps) return TermsMismatch.selector;
        if (cs.p.deleverageFloorEpsBps != cd.p.deleverageFloorEpsBps) return TermsMismatch.selector;
        if (cs.p.deleverageProtocolBps != cd.p.deleverageProtocolBps) return TermsMismatch.selector;
        return bytes4(0);
    }

    /// @notice The same question with the loan's WHOLE lot, for a caller that holds only the loan id.
    /// @dev The arity `Ace` links: an internal-only core would inline this whole body into the hub.
    /// @dev Three returns, not four: the cap is for a caller about to ACT on the answer, and a view never does.
    function tryContinue(LoanBook storage B, mapping(bytes32 => Market) storage MM, RollFrames memory r, uint256 id)
        public
        view
        returns (bool ok, bytes4 reason, uint256 principal)
    {
        (ok, reason, principal,) = tryContinue(B, MM, r, id, B.loans[id].collateralUnits);
    }

    /// @dev The fundability and admissibility legs in their own frame, taking `L` and the frames whole, for `tryContinue`'s stack.
    /// @dev TOTAL, and it must stay so: a continuation predicate has nobody to revert to, so it returns the selector the entry door reverts.
    /// @dev The draw cap is the TRY read, so a record with no price is unfundable rather than a revert.
    /// @dev A HOME roll judges the successor at `min(price, record)` and reads no cap: the stale-bid refusal protected nobody.
    /// @dev That record leg is ONE READ, never a persisted-distress test: a record one transaction can dent can flip the roll to settle.
    /// @dev A ROUTED roll keeps the cap, since the keeper chose the venue; it recycles nothing and owns no reservation there.
    /// @dev The cash leg is `cashAdmits`, the draw's own test, with this loan's reservation counted as its own pre-release.
    function _continuationLeg(
        mapping(bytes32 => Market) storage MM,
        RollFrames memory r,
        Loan storage L,
        uint256 principal,
        AutoPolicy memory ap,
        uint256 units
    ) private view returns (bool, bytes4, uint256, uint256) {
        bool home = r.dst == L.market;
        (bool capOk, uint256 cap) = tryPersistedPrice(r.cd);
        if (!capOk) return (false, NoRecordPrice.selector, 0, 0);
        uint256 floor = r.cd.p.price;
        if (home) {
            floor = Math.min(floor, cap);
            cap = type(uint256).max;
        } else if (floor > cap) {
            return (false, InsufficientCash.selector, 0, 0);
        }
        if (!cashAdmits(MM[r.dst], principal - recycled(home, L.debt, principal), home ? ap.reserved : 0)) {
            return (false, InsufficientCash.selector, 0, 0);
        }
        bytes4 bad = _admissibleLeg(r.cd, floor, principal, units, ap.minBufferBps);
        return bad == bytes4(0) ? (true, bytes4(0), principal, cap) : (false, bad, 0, 0);
    }

    /// @dev Admission made total, in its own frame for the stack; zero means admitted.
    /// @dev It carries the coverage line as well as `_gate`'s two legs, so it refuses exactly what `_fundAndCheck` refuses.
    /// @dev LEG ORDER MATCHES `_fundAndCheck`: trigger, buffer, then the line, so both doors name the same reason.
    /// @dev The trigger is derived HERE rather than passed, so the caller never holds it alongside the cap.
    function _admissibleLeg(Cfg memory c, uint256 floor, uint256 principal, uint256 units, uint16 minBufferBps) private pure returns (bytes4) {
        uint256 trig = LoanMath.triggerPrice(principal, units, c.p.minCoverageWad, c.unitScale);
        if (trig > floor) return TriggerAboveFloor.selector;
        uint256 minBufferWad = uint256(minBufferBps) * 1e14;
        if (minBufferWad != 0) {
            if (floor == 0) return BufferBelowMin.selector; // the ratio below divides by it
            if (FullMath.mulDiv(floor - trig, 1e18, floor) < minBufferWad) return BufferBelowMin.selector;
        }
        return units < coverageLine(c, principal, floor) ? BelowCoverageLine.selector : bytes4(0);
    }

    /// @notice THE borrower rule, ONE spelling for every site: a market naming nobody admits any holder, else only the one it names.
    /// @dev `_gateCheck` is its reverting entry form; a continuation, `arm`, `disarmOnRetitle` and `AceLens.armable` ask it directly.
    /// @dev TOTAL BY CONSTRUCTION: a continuation predicate has nobody to revert to, and a comparison never reverts.
    /// @dev On a routed roll `named` is the DESTINATION's borrower; a roll it admits is pre-admitted, so `_gateCheck` never re-asks.
    function gateAdmits(address named, address holder) internal pure returns (bool) {
        return named == address(0) || holder == named;
    }

    /// @notice The refinance close: debit the retiring loan's custody, refund left to net.
    /// @dev A sibling rather than two parameters on `Settlement.closeClean`, which every ordinary repay walks.
    /// @dev Makes no assumption about the loan's health: refinance retires the debt in full.
    /// @dev The debit sits HERE, at the close itself, so no observer ever sees a closed loan still credited with live units.
    /// @dev Its credit half runs inside the successor's open, which is the first moment the successor has an id.
    /// @dev The reservation frees BEFORE the successor draws, so the draw's cash test already sees it returned.
    /// @param M The RETIRING loan's market, which is where its reservation sits.
    function _closeForRefinance(LoanBook storage B, Market storage M, Cfg memory c, uint256 id) private returns (uint256 units) {
        Loan storage L = B.loans[id];
        L.closedAt = uint64(block.timestamp);
        releaseReserve(B, M, id);
        units = L.collateralUnits;
        L.collateralUnits = 0;
        IPositionManager(c.positionManager).carryOut(id, units);
    }

    /// @notice The principal an automatic continuation draws: derived from the live debt, never stored.
    /// @notice `P = ceil((debtOld - refundOld) * D / (D - N))`, `N = baseBps*tenor*(10000 + PROTOCOL_SHARE_BPS)`, `D = 10000*10000*minTenor`.
    /// @notice FLOORED at `minDebt`, the smallest loan the market issues and so the only legal draw.
    /// @dev ROUNDS UP. Down leaves the continuation a wei short of the old debt and every migration reverts.
    /// @dev At the expiry fold `refundOld` is zero and only the borrower's own repay can leave `debt < minDebt`, so only it lets the floor RAISE debt.
    /// @dev Before expiry `refundOld` can pull `debt - refundOld` under `minDebt` after a crank too; a policy roll refused there ends nothing.
    /// @dev Admissibility still governs: the draw gate refuses if the collateral cannot carry `minDebt`.
    function derivedPrincipal(LoanBook storage B, Cfg memory c, uint256 id, uint64 tenor) internal view returns (uint256) {
        // Unreachable via the hub: arming validates and the carry clamps; it holds principalForOwed's no-underflow precondition.
        if (!LoanMath.feeFundable(c.p.baseBps, tenor, c.p.minTenor)) revert AutoTenorUnfundable();
        Loan storage L = B.loans[id];
        uint256 esc = B.feeEscrowOf[id];
        uint256 remaining = Math.saturatingSub(L.expiry, block.timestamp);
        uint256 refundOld = L.tenor == 0 ? 0 : FullMath.mulDiv(esc, remaining, L.tenor);
        refundOld = Math.min(refundOld, esc);
        uint256 owed = Math.saturatingSub(L.debt, refundOld);
        return successorPrincipal(c, owed, tenor);
    }

    /// @notice THE sizing rule, shared by the roll, arming and the carry: the draw whose payout retires `owed`, floored at `minDebt`.
    /// @dev The caller holds `feeFundable` at `tenor`, which is `principalForOwed`'s no-underflow precondition.
    function successorPrincipal(Cfg memory c, uint256 owed, uint64 tenor) internal pure returns (uint256) {
        return successorPrincipal(c.p.baseBps, c.p.minTenor, c.p.minDebt, owed, tenor);
    }

    /// @notice The same rule on the three market fields it reads, for a caller holding no whole `Cfg`.
    function successorPrincipal(uint256 baseBps, uint64 minTenor, uint256 minDebt, uint256 owed, uint64 tenor) internal pure returns (uint256) {
        uint256 p = LoanMath.principalForOwed(owed, tenor, baseBps, minTenor);
        return Math.max(p, minDebt);
    }

    /// @notice What an armed loan of `debt` reserves: the fresh cash its expiry roll draws beside the debt it recycles.
    /// @notice An UPPER BOUND for the loan's life while its debt stays at or over `minDebt`: the need grows with the debt.
    /// @dev At expiry the refund is zero, so this is the fold's own principal less the recycle, to the atom.
    function rollNeed(Cfg memory c, uint256 debt, uint64 tenor) internal pure returns (uint256) {
        return rollNeed(c.p.baseBps, c.p.minTenor, c.p.minDebt, debt, tenor);
    }

    /// @notice The same need on the three market fields it reads, which is how `arm` asks without copying `MarketParams`.
    function rollNeed(uint256 baseBps, uint64 minTenor, uint256 minDebt, uint256 debt, uint64 tenor) internal pure returns (uint256) {
        uint256 p = successorPrincipal(baseBps, minTenor, minDebt, debt, tenor);
        return Math.saturatingSub(p, debt);
    }

    /// @notice The retiring principal a migration funds its successor with: all it can on a HOME migration, none on a routed one.
    /// @dev Routed, the retiring claim is another market's lender's money, so nothing of it may rest here.
    function recycled(bool home, uint256 debtOld, uint256 principal) internal pure returns (uint256) {
        if (!home) return 0;
        return Math.min(debtOld, principal);
    }

    /// @notice THE cash test every draw asks: `fresh` fits beside every OTHER armed loan's reservation.
    /// @notice `own` is a reservation the caller counts as its own before releasing it; zero for any fresh draw.
    /// @dev ADDITIVE, never `cash - rollReserve`: a lender's withdraw may take `cash` under the reserve, and a subtraction would brick.
    function cashAdmits(Market storage M, uint256 fresh, uint256 own) internal view returns (bool) {
        (bool fits, uint256 left) = Math.trySub(M.s.cash + own, fresh);
        return fits && M.s.rollReserve <= left;
    }

    /// @dev Frees a loan's roll reservation, SATURATING: a drifted sum can never brick the close that frees it.
    /// @dev Subtracts the STORED share, then zeroes it, so no second close of the same loan can free it twice.
    function releaseReserve(LoanBook storage B, Market storage M, uint256 id) internal {
        uint256 own = B.autoPolicyOf[id].reserved;
        if (own == 0) return;
        B.autoPolicyOf[id].reserved = 0;
        uint256 rr = M.s.rollReserve;
        M.s.rollReserve = uint128(Math.saturatingSub(rr, own));
    }

    /// @dev Clamps a live loan's reservation down to its roll's need at today's debt, FLOORED at the dust band's worst: a pure release.
    /// @dev The floor makes coverage ORDER-INDEPENDENT: a later borrower repay below `minDebt` finds the share an earlier shrink would have cut.
    /// @dev It holds at most `minDebt - 1` idle per armed loan, what repay-then-arm already reserves; a smaller share stays as it is.
    /// @dev Stores the smaller share and subtracts exactly the difference, SATURATING as `releaseReserve` does.
    /// @dev A shrink only: a growth would need a cash test, and a refused repay or melt is worse than an under-covered roll.
    function shrinkReserve(LoanBook storage B, Market storage M, Cfg memory c, uint256 id) internal {
        AutoPolicy storage ap = B.autoPolicyOf[id];
        uint256 own = ap.reserved;
        if (own == 0) return;
        uint256 need = rollNeed(c, B.loans[id].debt, ap.tenor);
        if (own <= need) return;
        // `rollNeed(1)` is the dust band's worst need, `minDebt - 1`: `feeFundable` keeps a successor under 4/3 of the debt it retires
        need = Math.max(need, rollNeed(c, 1, ap.tenor));
        if (own <= need) return;
        ap.reserved = uint128(need); // a shrunken debt frees what its roll no longer needs
        M.s.rollReserve = uint128(Math.saturatingSub(M.s.rollReserve, own - need));
    }

    /// @notice Arm, re-arm or disarm a loan's automatic continuation. ARMED MEANS RESERVED.
    /// @notice Arming holds the fresh cash its expiry roll draws out of every later draw; unbacked, it reverts `RollUnbacked`.
    /// @notice A RECORDLESS market cannot arm: a nonzero tenor there reverts `ArmNeedsRecord`, ahead of every policy rail.
    /// @notice A holder the market's borrower rule refuses cannot arm either, `GateRefused`: its home roll would be refused.
    /// @notice The hold binds everyone but the market's lender: a withdrawal under it can fail the market's armed rolls while the deficit stands.
    /// @notice Arm from a contract that reads `open`'s returned id: a pre-encoded multicall leg must predict it, and any id allocated first breaks it.
    /// @dev Borrower-only and explicitly NOT the credit-operator path: it is a fresh borrowing decision.
    /// @dev The title check runs before any market read, so an id naming no loan refuses as `NotBorrower`.
    /// @dev The 10000 bound leans on `LoanMath.triggerPrice` rounding UP: a live trigger is at least one, so no gap reaches the whole floor.
    /// @dev A disarm, or a re-arm needing no more than the loan holds, lands in any cash state: it only keeps or frees reserve.
    /// @dev A re-arm stores the EXACT `rollNeed(debt)`: a policy-only re-arm releases any share above it, the floor a shrink kept included.
    /// @dev A later repay under `minDebt` may then outgrow the share at the borrower's own risk, as arming at a low debt then repaying into the band does.
    function arm(LoanBook storage B, mapping(bytes32 => Market) storage MM, uint256 id, AutoPolicy memory ap) public {
        Loan storage L = B.loans[id];
        if (msg.sender != L.borrower) revert NotBorrower();
        if (L.closedAt != 0) revert LoanClosed();
        Market storage M = MM[L.market];
        uint256 r;
        if (ap.tenor != 0) {
            MarketParams storage p = M.p; // a pointer, so only the fields read below are loaded: a whole copy costs ~30k gas
            if (p.record == address(0)) revert ArmNeedsRecord(); // permanent, so first, as `_compatLeg` orders its own
            if (!gateAdmits(p.borrower, msg.sender)) revert GateRefused(); // permanent for this holder: its home roll is refused
            /// @dev Routing consent needs a RISK DISTANCE: the admissibility leg skips its check at a zero buffer.
            if (ap.maxFeeBps != 0 && ap.minBufferBps == 0) revert RoutingNeedsBuffer();
            if (ap.minBufferBps >= 10_000) revert BufferOutOfRange();
            uint64 minTenor = p.minTenor;
            uint256 baseBps = p.baseBps;
            if (ap.tenor < minTenor || ap.tenor > p.maxTenor) revert TenorOutOfRange();
            /// @dev Unreachable here: the clamp above, plus the genesis rail running THIS predicate at maxTenor.
            if (!LoanMath.feeFundable(baseBps, ap.tenor, minTenor)) revert AutoTenorUnfundable();
            r = rollNeed(baseBps, minTenor, p.minDebt, L.debt, ap.tenor);
            uint256 own = B.autoPolicyOf[id].reserved;
            if (r > own && !cashAdmits(M, r, own)) revert RollUnbacked();
        }
        releaseReserve(B, M, id);
        /// @dev Fits uint128: `cashAdmits` bounded the new sum by `cash`, or `r <= own` kept it at or under the old sum.
        M.s.rollReserve += uint128(r);
        ap.reserved = uint128(r);
        B.autoPolicyOf[id] = ap;
        emit AutoPolicySet(id, ap.tenor, ap.minBufferBps, ap.maxFeeBps);
    }

    /// @notice Disarms a live armed loan whose NEW holder the market's borrower rule refuses: that holder's home roll would be refused.
    /// @dev Runs after the title write, so `L.borrower` is the new holder; only the named holder arms, so in a named market every move disarms.
    /// @dev Releases the share, then stores and logs zeros; an open market, a disarmed or a closed loan is untouched.
    function disarmOnRetitle(LoanBook storage B, mapping(bytes32 => Market) storage MM, uint256 id) public {
        if (B.autoPolicyOf[id].tenor == 0) return;
        Loan storage L = B.loans[id];
        Market storage M = MM[L.market];
        if (L.closedAt != 0 || gateAdmits(M.p.borrower, L.borrower)) return;
        releaseReserve(B, M, id);
        delete B.autoPolicyOf[id];
        emit AutoPolicySet(id, 0, 0, 0);
    }

    /// @notice Retires one loan and opens its successor, carrying the auto policy across.
    /// @notice The borrower's net out is one amount: PAID in the call when `strict`, credited for a later claim when not.
    /// @notice A non-zero `withdrawUnits` also sheds collateral off the SUCCESSOR, released before any payout; zero skips that leg.
    /// @notice Any units, or any named `withdrawTo`, runs the recipient rule FIRST; zero units to no one is a plain refinance.
    /// @dev The shared body both entries run, with every authorization already spent by the caller.
    /// @dev Collateral must match, checked before state moves: the carry moves no token, so no transfer refuses a mismatch.
    /// @dev The quote must match too, so one migration settles in ONE token and the netting cannot mix two.
    /// @dev `pre` is what the CALLER already established, bar `recycle`, set here; it answers for the destination only when it names it.
    /// @dev A HOME migration recycles the retiring principal into the successor, so its draw takes only the fresh rest.
    /// @dev `strict` says the BORROWER started it: an armed successor the destination cannot hold or re-reserve then reverts, never disarms.
    function migrate(
        LoanBook storage B,
        mapping(bytes32 => Market) storage MM,
        Cfg memory cs,
        Cfg memory cd,
        MigrateArgs memory a,
        PreAdmitted memory pre,
        bool strict
    ) public returns (uint256 newId) {
        if (a.withdrawUnits != 0 || a.withdrawTo != address(0)) Recipients.check(a.withdrawTo, cd.positionManager);
        if (cs.p.collateral != cd.p.collateral) revert MarketPairMismatch();
        if (cs.p.quote != cd.p.quote) revert QuoteMismatch();
        address payee = B.loans[a.id].borrower; // never msg.sender: an executor must mint nothing to itself
        uint256 debtOld = B.loans[a.id].debt;
        uint256 refundOld;
        {
            bytes32 src = B.loans[a.id].market;
            /// @dev Collateral FIRST: the carry-out lands before the melt, which leaves the pools short of `recycle` until `_fund` debits.
            /// @dev In between run only the title mint, a leaf, and the borrower doors' record STATICCALL; every hub view netting the pools refuses there.
            uint256 units = _closeForRefinance(B, MM[src], cs, a.id);
            pre.recycle = recycled(a.dst == src, debtOld, a.newPrincipal);
            refundOld = _retire(B, MM[src], a.id, debtOld, pre.recycle);
            newId = _openNew(B, MM[a.dst], cd, a, payee, units, pre);
        }
        _carry(B, MM[a.dst], cd, a.id, newId, strict);
        /// @dev Debits, gates and logs the release; MOVES NO TOKEN, so the refusal lands before `_net` books anything.
        _withdrawCheck(B, MM[a.dst], cd, a, newId);
        uint256 out = _net(B, MM[B.loans[a.id].market], cd, a, debtOld, refundOld, payee, strict);
        /// @dev The transfers come after every gate and every write, so nothing reads state behind either.
        if (a.withdrawUnits != 0) IPositionManager(cd.positionManager).release(newId, a.withdrawTo, a.withdrawUnits);
        /// @dev Stable LAST, as `open` sends it; a quote that refuses the payout reverts the whole refinance.
        if (strict && out != 0) IERC20(cd.p.quote).safeTransfer(payee, out);
        emit Refinanced(a.id, newId, a.newPrincipal, a.newTenor, out, msg.sender);
    }

    /// @dev The draw, in its own frame: it rebuilds the bounds and the open args from the migration args.
    /// @dev It names the retiring loan as the custody source, so the open credits rather than pulls.
    /// @dev The payer field is unread on that branch and is passed zero rather than a misleading address.
    function _openNew(LoanBook storage B, Market storage M, Cfg memory cd, MigrateArgs memory a, address payee, uint256 units, PreAdmitted memory pre)
        private
        returns (uint256)
    {
        OpenBounds memory bnd = OpenBounds(0, a.bnd.minBufferWad, a.bnd.deadline);
        return _openFrom(B, M, cd, OpenArgs(a.dst, payee, address(0), address(this), units, a.newPrincipal, a.newTenor, bnd), a.id, pre);
    }

    /// @dev The refinance's storage-only middle: earn, refund, zero the debt, melt the claim.
    /// @dev Its own frame for the stack, and because NO external call may fall between these lines.
    /// @dev The fee-escrow earn MUST precede the melt: the melt retires the claim creditOverClaims needs.
    /// @return refundOld The unearned fee escrow, left in the pot for the netting to pay out.
    function _retire(LoanBook storage B, Market storage M, uint256 id, uint256 debtOld, uint256 recycle) private returns (uint256 refundOld) {
        LoanAccounting.earnFeeEscrowProRata(B, M, id);
        refundOld = B.feeEscrowOf[id];
        B.feeEscrowOf[id] = 0;
        B.loans[id].debt = 0;
        LoanAccounting.meltRecycling(M, id, debtOld, recycle);
    }

    /// @notice Debits the successor's collateral for a withdrawal leg and proves the loan still stands without it.
    /// @notice Zero units returns at once: the leg is optional and every ordinary caller skips it.
    /// @notice The recipient is not asked here: `migrate` checked it first, so a named hub or positionManager never gets this far.
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

    /// @dev The auto policy follows the position, or a manual continuation would silently disarm it.
    /// @dev Clamped into the destination grid: storage must equal what will execute, and so must the log.
    /// @dev BOTH directions: capped down at the destination's maxTenor, raised up to its minTenor.
    /// @dev ARMED MEANS RESERVED here too: the successor re-reserves from UNRESERVED cash, or it is not armed.
    /// @dev A RECORDLESS destination holds no policy at all, and that check runs first: it is permanent, the cash one is not.
    /// @dev `strict`, the borrower's own refinance, reverts `ArmNeedsRecord` or `RollUnbacked` there: the borrower is present to be told.
    /// @dev A keeper's or the fold's carry disarms instead, logging `AutoPolicySet(newId, 0, 0, 0)`: it never reverts, so no roll turns on it.
    /// @dev The recordless disarm is unreachable (the fold rolls home, a route refuses `RecordMismatch`), and kept so both writers refuse.
    /// @param M The DESTINATION market, which is where the successor's roll will draw.
    function _carry(LoanBook storage B, Market storage M, Cfg memory cd, uint256 oldId, uint256 newId, bool strict) private {
        AutoPolicy memory ap = B.autoPolicyOf[oldId];
        if (ap.tenor == 0) return; // the old entry stays behind `closedAt`: no hub verb acts on it, and the lens still reads it
        if (cd.p.record == address(0)) {
            if (strict) revert ArmNeedsRecord();
            emit AutoPolicySet(newId, 0, 0, 0);
            return;
        }
        uint64 t = uint64(Math.min(Math.max(ap.tenor, cd.p.minTenor), cd.p.maxTenor));
        uint256 r = rollNeed(cd, B.loans[newId].debt, t);
        if (!cashAdmits(M, r, 0)) {
            if (strict) revert RollUnbacked();
            emit AutoPolicySet(newId, 0, 0, 0);
            return;
        }
        M.s.rollReserve += uint128(r); // bounded by `cash`, as at arming
        B.autoPolicyOf[newId] = AutoPolicy(t, ap.minBufferBps, ap.maxFeeBps, uint128(r));
        emit AutoPolicySet(newId, t, ap.minBufferBps, ap.maxFeeBps);
    }

    /// @dev One netted amount: the new principal less its fee, plus the old refund, less the old debt.
    /// @dev Split out for the stack; it moves no token.
    /// @dev Every term is the SAME token, which `migrate`'s quote rail establishes before any state moves.
    /// @dev Books the credit only when `!strict` (the policy doors and the fold, whoever calls them), so a refused payee cannot brick a roll.
    /// @dev `M` is the RETIRING loan's market, which is where the credit's aggregate is booked.
    /// @return out The net out: already credited when `!strict`, for `migrate` to pay after the release when `strict`.
    function _net(LoanBook storage B, Market storage M, Cfg memory cd, MigrateArgs memory a, uint256 debtOld, uint256 refundOld, address payee, bool strict)
        private
        returns (uint256 out)
    {
        uint256 feeNew = LoanMath.originationFee(a.newPrincipal, a.newTenor, cd.p.baseBps, cd.p.minTenor);
        uint256 credit = a.newPrincipal - feeNew + refundOld; // `_openNew` already ran `_payoutCheck` on this pair, so the fee cannot exceed it
        if (credit < debtOld) revert DrawBelowDebt(); // repay the gap first, then refinance, in one multicall
        out = credit - debtOld;
        if (out < a.bnd.minPayout) revert PayoutBelowMin(); // ONE branch, so the floor binds the net out unconditionally
        if (!strict) LoanAccounting.creditQuote(B, M, a.id, payee, out);
    }

    /* ====== 4. HEALTH: the borrower's subject, read by every actor acting ON a loan ====== */

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
    /// @dev It is the CONTINUATION PREDICATE's read, so an unbounded copy here would inflate the frame that must settle.
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
