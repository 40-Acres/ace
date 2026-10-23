// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Storage, Cfg, Loan, MarketParams, MarketState, OpenBounds, Order, RecordState} from "../hub/Types.sol";
import {LoanMath} from "../hub/libraries/LoanMath.sol";
import {Constants} from "../hub/Constants.sol";
import {Borrower, NoRecordPrice} from "../hub/Borrower.sol";
import {FillBelowMin, FillOverCollateralized, FillOverOrder, FillUnderCollateralized, OrderClosed, RemainderBelowMin} from "../hub/Orders.sol";
import {Probe} from "../hub/libraries/Probe.sol";
import {MarketInit} from "../hub/MarketInit.sol";
import {IPersistenceRecord} from "../../interfaces/IPersistenceRecord.sol";
import {Mul512} from "../../utils/Mul512.sol";

error ZeroLimit(); // limit 0 is ambiguous: an empty page to the hub, a full one to this side; refuse, never guess
error RowUnevaluable(); // a batch row threw with no selector to report: the row is refused, the batch is not
error NoMarket(); // no market at this id; deliberately the selector the hub throws, so one catch covers both
error TornRead(); // an ON-CHAIN CALLABLE view was called mid-hub-body, where the aggregates it reads are half-updated

/// @notice The hub's read door: extsload, the quote preview, and the views it is required to keep.
interface IAceHub {
    function extsload(bytes32 slot) external view returns (bytes32);
    function extsload(bytes32 startSlot, uint256 n) external view returns (bytes32[] memory);
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function restingOf(bytes32 id) external view returns (uint256);
    function lenderAssets(address lender, address quote) external view returns (uint256);
    function notEntered() external view returns (bool);
    function marketLoansLength(bytes32 id) external view returns (uint256);
    function marketLoans(bytes32 id, uint256 offset, uint256 limit) external view returns (uint256[] memory);
    function tryContinue(uint256 loanId) external view returns (bool ok, bytes4 reason, uint256 principal);
    function orderOf(uint256 id) external view returns (Order memory);
    function previewOpen(bytes32 id, uint256 collateralUnits, uint256 principal, uint64 tenor, address borrower, OpenBounds calldata bnd)
        external
        view
        returns (Borrower.Quote memory);
}

/// @notice The venue-dependency disclosure behind one record and ordered pair: WHICH markets, on WHOSE terms.
/// @notice NO MONEY FIGURE: a lender's (lender, quote) pool spans markets outside this venue, so any sum would charge it their whole book.
/// @dev INFORMATIONAL: it gates nothing. The manipulation-cost read lives off-chain, by decision.
/// @dev Capital-at-risk per venue is an off-chain join over the `Deposit` and `Funded` logs.
struct VenueExposure {
    uint256 verified; // ids whose params name this record AND this ordered pair
    uint256 rejected; // ids skipped: no market, wrong record, or wrong pair
    uint256 capPrice; // the record's windowed min over its OWN distress window: the shared funding ceiling
    /// @dev BOTH windows are probed off the RECORD, which owns them; every market behind it shares them.
    /// @dev A record that exposes neither reads 0 twice, and its settle patience is then undiscoverable on-chain.
    /// @dev That is disclosure ACE OFFERS, never a guarantee it makes: the ORACLE class answers 0 for both.
    uint256 distressWindow; // the record's own persistence window; 0 when it does not expose one
    uint256 settleWindow; // the record's own settle window: how long before the verb that moves TITLE opens
    uint256 minK; // smallest trigger multiplier in the set: where a lift buys the most debt
    uint256 maxK;
    uint256 minDepth; // best-effort probe; 0 when the record answers no depth (ORACLE class)
    address writer; // best-effort probe; a windowed record's writer, for an off-chain pool-level roll-up
    bool depthSupported; // a word came back; a catch-all fallback fakes this, so never a capability proof
    bool recordObserving; // a nonzero lastObserved came back; false = dead, hostile, or no record at all
}

/// @title AceLens
/// @notice BUILT FOR OFF-CHAIN READERS: every view here is a convenience, never a dependency.
/// @notice Quotes forward from the hub's preview; state reads go through extsload on derived slots.
/// @notice AN ON-CHAIN CALLER IS THE EXCEPTION: the views that support one say `ON-CHAIN CALLABLE`.
/// @notice The rest are unguarded and can see a half-updated hub, so price nothing off them.
/// @notice NEVER PRICE SHARES OFF THIS CONTRACT: the hub's own `lenderAssets` and `lenderOwed` are the guarded reads.
/// @notice NOTHING IN `src` DOES: the vaults price their shares off the hub's own `lenderAssets`.
/// @dev A health read taken inside the keeper hand-off is over-distressed by design: the debt leg lands after.
/// @dev NOT AUDITED, so nothing audited may depend on it beyond the ON-CHAIN CALLABLE views.
/// @dev The slot derivations below are THE spelling: a reader that re-derives them locally drifts.
contract AceLens {
    IAceHub public immutable ACE;

    /// @dev ERC-7201 roots from Storage; LoanBook members are base + declaration index.
    uint256 private constant M_MAP = uint256(Storage.MARKETS);
    uint256 private constant B_BASE = uint256(Storage.BOOK);
    uint256 private constant B_COUNT = B_BASE;
    uint256 private constant B_LOANS = B_BASE + 1;
    uint256 private constant B_PRINCIPAL = B_BASE + 2;
    uint256 private constant B_CREDIT_OPERATOR = B_BASE + 3;
    uint256 private constant B_FEE_ESCROW = B_BASE + 5; // +4 is creditOperatorNonce, not a gap
    uint256 private constant B_AUTO_POLICY = B_BASE + 6;
    uint256 private constant B_UNITS_OWED = B_BASE + 7;
    uint256 private constant B_QUOTE_OWED = B_BASE + 8;
    uint256 private constant B_SHORTFALL = B_BASE + 9;

    /// @dev Member offsets inside one `Market`: params occupy 0..16, state 17..25, mappings after.
    /// @dev A wrong index reads a plausible number and reverts nothing, so never edit this by hand.
    /// @dev Re-verify these against the compiler's own storage layout after ANY change to `Market`.
    /// @dev A field APPENDED to MarketState still shifts every constant below it, unlike a LoanBook append.
    /// @dev 19 fields make 17 slots because TWO groups pack: `minTenor` with `maxTenor`, and `lender` with `inventoryAsk`.
    /// @dev `inventoryAsk` is a `bool` appended LAST, into the word the lender's address leaves room in, so adding it moved no slot.
    /// @dev The ENCODED width is 19 words: abi.encode pads every field, so the id preimage packs nothing.
    uint256 private constant M_STATE = 17; // MarketParams inline slots; a field that adds or drops a SLOT shifts everything below
    uint256 private constant M_STATE_WORDS = 9;
    uint256 private constant M_CLAIM = 26;
    uint256 private constant M_INV_POT = 28; // +27 is the openedLoans array, not a gap

    uint256 private constant L_POOLS = uint256(Storage.LENDERS); // `pools`, member 0 of the `lenders` root: an entry is _entry(quote, _entry(lender, root))
    uint256 private constant UNIT_SCALE = 1 << 96; // the one price frame genesis writes into every market; a record declaring another is refused

    constructor(address ace) {
        ACE = IAceHub(ace);
    }

    // ---- quotes (forwarded, never computed) ----

    /// @notice What `open` would do for `borrower`, in the field order the hub's own door takes.
    /// @notice Every quote door names the borrower: the lens is never the subject of the market's gate.
    /// @dev Reverts wherever `open` would. Use `tryQuoteOpen` from a batched read.
    function quoteOpen(bytes32 id, uint256 collateralUnits, uint256 principal, uint64 tenor, address borrower)
        external
        view
        returns (uint256 fee, uint256 payout, uint256 postDrawFloor, uint256 triggerAtOpen, uint256 bufferWad, uint256 protocolFee)
    {
        Borrower.Quote memory q = ACE.previewOpen(id, collateralUnits, principal, tenor, borrower, OpenBounds(0, 0, 0));
        return (q.fee, q.payout, q.postDrawFloor, q.triggerAtOpen, q.bufferWad, q.protocolFee);
    }

    /// @notice The same quote under the borrower's own open-time bounds.
    function quoteOpenWithBounds(bytes32 id, uint256 collateralUnits, uint256 principal, uint64 tenor, address borrower, OpenBounds calldata bnd)
        external
        view
        returns (Borrower.Quote memory)
    {
        return ACE.previewOpen(id, collateralUnits, principal, tenor, borrower, bnd);
    }

    /// @notice The non-reverting form: `ok` false carries the refusal's selector instead of throwing.
    function tryQuoteOpen(bytes32 id, uint256 collateralUnits, uint256 principal, uint64 tenor, address borrower, OpenBounds calldata bnd)
        external
        view
        returns (bool ok, bytes4 reason, Borrower.Quote memory q)
    {
        try ACE.previewOpen(id, collateralUnits, principal, tenor, borrower, bnd) returns (Borrower.Quote memory r) {
            return (true, bytes4(0), r);
        } catch (bytes memory err) {
            return (false, _selOf(err), q);
        }
    }

    /// @notice Whether `refinanceByPolicy` would continue this loan right now; the hub's own answer, forwarded.
    function tryContinue(uint256 loanId) external view returns (bool ok, bytes4 reason, uint256 principal) {
        return ACE.tryContinue(loanId);
    }

    /// @notice THE BATCH FILTER for `refinanceByPolicies`, which is all-or-nothing: one bad id reverts it.
    /// @notice Rows are positional, so a keeper drops the refused ids and submits the rest unchanged.
    /// @notice BLOCK-SCOPED like the singular: an answer read in one block does not bind the next.
    /// @dev A hostile market record can make its own row expensive; the cost is bounded by the caller's own gas.
    /// @dev PER ROW, so one id that throws refuses its own row instead of the batch: a filter that reverts filters nothing.
    /// @dev A thrown row reports the thrower's own selector where it gave one, and `RowUnevaluable` where it gave none.
    /// @dev It cannot catch an out-of-gas row: a callee that burns the whole allowance leaves nothing to catch with.
    function tryContinueMany(uint256[] calldata loanIds) external view returns (bool[] memory oks, bytes4[] memory reasons, uint256[] memory principals) {
        oks = new bool[](loanIds.length);
        reasons = new bytes4[](loanIds.length);
        principals = new uint256[](loanIds.length);
        for (uint256 i; i < loanIds.length; i++) {
            try ACE.tryContinue(loanIds[i]) returns (bool ok, bytes4 reason, uint256 principal) {
                (oks[i], reasons[i], principals[i]) = (ok, reason, principal);
            } catch (bytes memory err) {
                reasons[i] = err.length >= 4 ? bytes4(err) : RowUnevaluable.selector;
            }
        }
    }

    /// @notice Whether `fillOrder` would take this fill right now, and the first fact that refuses it.
    /// @notice TOTAL: every refusal comes back as a selector, so a batching filler gets an answer and never a throw.
    /// @notice BLOCK-SCOPED, not a guarantee: the market's resting cash moves with every deposit, withdraw and draw.
    /// @notice Blind to token-side failure, exactly as `previewOpen` is: those turn on balances, not order state.
    /// @dev A fill IS an open, so the open's own legs come from the hub's preview rather than a second copy here.
    /// @dev An id naming no order carries no market, which is the fact the hub resolves before any order leg.
    /// @dev The tenor is passed RAW, as the fill passes it; the preview applies its zero-tenor sentinel to every caller, a no-op here.
    /// @dev A zero-tenor order cannot exist while `minTenor` is non-zero, which is what holds the two doors together here.
    /// @dev A fill states no payout floor and no buffer floor, so neither of those open legs can answer through this door.
    /// @param orderId The resting order to draw against.
    /// @param principalOut Quote this fill would draw.
    /// @param unitsOut Collateral this fill would carry out of the escrow.
    /// @return ok Whether the fill is admissible on order and market state alone.
    /// @return reason The first failing leg's selector; zero when `ok`.
    function tryFillOrder(uint256 orderId, uint256 principalOut, uint256 unitsOut) external view returns (bool ok, bytes4 reason) {
        Order memory o = ACE.orderOf(orderId);
        if (o.market == bytes32(0)) return (false, NoMarket.selector);
        bytes4 bad = _fillLeg(o, principalOut, unitsOut);
        if (bad != bytes4(0)) return (false, bad);
        /// @dev The order's own expiry rides as the open's deadline, exactly as the fill passes it.
        try ACE.previewOpen(o.market, unitsOut, principalOut, o.tenor, o.maker, OpenBounds(0, 0, o.expiry)) returns (Borrower.Quote memory) {
            return (true, bytes4(0));
        } catch (bytes memory err) {
            return (false, _selOf(err));
        }
    }

    /// @dev The order-layer legs made total, in their own frame; zero admits the fill to the open.
    /// @dev LEG ORDER MATCHES `Orders.fill`, so the two doors name the same fact when more than one holds.
    /// @dev The config read sits behind the four cheap legs, exactly as the verb's own trigger read does.
    function _fillLeg(Order memory o, uint256 principalOut, uint256 unitsOut) private view returns (bytes4) {
        if (o.closed) return OrderClosed.selector;
        if (principalOut > o.principal || unitsOut > o.collateralUnits) return FillOverOrder.selector;
        if (principalOut < o.minFillPrincipal) return FillBelowMin.selector;
        if (Mul512.gt512(unitsOut, o.principal, principalOut, o.collateralUnits)) return FillOverCollateralized.selector;
        Cfg memory c = _gateCfg(o.market);
        if (LoanMath.triggerPrice(principalOut, unitsOut, c.p.minCoverageWad, c.unitScale) > o.liqHigh) return FillUnderCollateralized.selector;
        uint256 rp = o.principal - principalOut;
        return rp != 0 && rp < o.minFillPrincipal ? RemainderBelowMin.selector : bytes4(0);
    }

    /// @dev The revert's selector, or zero for a bare/short revert.
    function _selOf(bytes memory reason) private pure returns (bytes4 s) {
        if (reason.length < 4) return bytes4(0);
        s = bytes4(reason[0]) | (bytes4(reason[1]) >> 8) | (bytes4(reason[2]) >> 16) | (bytes4(reason[3]) >> 24);
    }

    // ---- slot derivation ----

    function _marketBase(bytes32 id) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(id, M_MAP)));
    }

    function _entry(uint256 key, uint256 slot) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, slot)));
    }

    function _entry(address key, uint256 slot) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, slot)));
    }

    function _word(uint256 slot) private view returns (uint256) {
        return uint256(ACE.extsload(bytes32(slot)));
    }

    function _words(uint256 slot, uint256 n) private view returns (bytes32[] memory) {
        return ACE.extsload(bytes32(slot), n);
    }

    // ---- market state ----

    /// @notice This market's posted rate, annualized, and what an armed roll at `maxTenor` does to a loan's face.
    /// @notice `baseBps` IS PER THE MARKET'S OWN `minTenor`; the raw number never compares across markets and the APR legs do.
    /// @notice BOTH APR LEGS ARE HELD-TO-TERM: half the lender cut is refundable, so an early close realizes less on each.
    /// @notice THE ALL-IN LEG IS A RATE ON FACE: the fee is prepaid out of the draw, so the cost on the cash received is higher.
    /// @notice THE ROLL LEG IS TAKEN AT `maxTenor`; a borrower's own shorter roll inflates the face by less.
    /// @notice It is the worst roll only for a debt of at least `minDebt` divided by this multiplier: a smaller one floors at `minDebt`, a larger multiple.
    /// @notice It is FACE GROWTH alone: a keeper-run roll also takes `settleBountyBps` of the debt in collateral.
    /// @notice A RECORDLESS market reports a zero roll leg: it cannot arm, so no loan there ever takes that roll.
    /// @dev PER YEAR IN BPS, multiply-before-divide, and SIMPLE: the fee is prepaid at the draw, so nothing compounds.
    /// @dev `maxTenor` is also the term the fee-share rail is checked at, so this number and that rail share one corner.
    /// @dev Truncating, so a `minTenor` over a year at the floor rate reads zero; the error is under one bps of APR always.
    /// @dev Zeros for a market that does not exist, which is what the neighbouring views answer rather than reverting.
    /// @param id The market.
    /// @return lenderAprBps What the lender earns, annualized.
    /// @return allInAprBps The borrower's fee per unit of face, annualized, protocol share included.
    /// @return worstRollFaceMulWad The face multiplier an armed same-market roll applies at `maxTenor`, in WAD; zero where no loan can arm.
    function rateBps(bytes32 id) external view returns (uint256 lenderAprBps, uint256 allInAprBps, uint256 worstRollFaceMulWad) {
        MarketParams memory p = ACE.idToMarketParams(id);
        if (p.minTenor == 0) return (0, 0, 0);
        uint256 gross = 10000 + Constants.PROTOCOL_SHARE_BPS;
        lenderAprBps = p.baseBps * 365 days / p.minTenor;
        allInAprBps = p.baseBps * gross * 365 days / (10000 * p.minTenor);
        if (p.record == address(0)) return (lenderAprBps, allInAprBps, 0); // recordless: `ArmNeedsRecord`, so there is no roll
        uint256 d = 10000 * 10000 * uint256(p.minTenor);
        uint256 n = p.baseBps * uint256(p.maxTenor) * gross;
        /// @dev `d > n` is the fee-share rail restated, so genesis holds it for every creatable market.
        worstRollFaceMulWad = d > n ? FullMath.mulDiv(1e18, d, d - n) : 0;
    }

    /// @notice The market's scalar state: the O(1) aggregate mirrors plus the derived scales.
    function marketState(bytes32 id) public view returns (MarketState memory s) {
        bytes32[] memory w = _words(_marketBase(id) + M_STATE, M_STATE_WORDS);
        s.cash = uint256(w[0]);
        s.drawCount = uint64(uint256(w[1]));
        s.rollReserve = uint128(uint256(w[1]) >> 64); // packed beside drawCount, at byte offset 8
        s.cumulativeBackedBurns = uint256(w[2]);
        s.netSyntheticOutflow = uint256(w[3]);
        s.protocolRevenue = uint256(w[4]);
        s.lastSweptAt = uint64(uint256(w[5]));
        s.unitScale = uint256(w[6]);
        s.quoteOwedTotal = uint256(w[7]);
        s.realizedLossAtBook = uint256(w[8]);
    }

    /// @notice What a loan has credited one claimant and not yet paid out; the hub's `owedOf`, off-chain.
    /// @param loanId The loan to read.
    /// @param claimant The party whose entry to read.
    /// @return units Collateral units owed.
    /// @return amount Quote owed.
    function owedOf(uint256 loanId, address claimant) external view returns (uint256 units, uint256 amount) {
        units = _word(_entry(claimant, _entry(loanId, B_UNITS_OWED)));
        amount = _word(_entry(claimant, _entry(loanId, B_QUOTE_OWED)));
    }

    /// @notice What a settled loan's claims did not get. Zero on every loan that closed clean.
    /// @notice FINAL ONLY once the loan's `Finalized` or `ForceClosed` has been emitted.
    /// @notice Inside a settling loan's custody callback it still reads zero, on a loan that already reads closed.
    /// @dev `quoteAtBook` is AT BOOK, so it is a LOWER bound: a pot clearing under the price loses more.
    /// @param loanId The loan to read.
    /// @return units Collateral atoms the claims did not get.
    /// @return quoteAtBook That gap valued at the funding floor.
    function shortfallOf(uint256 loanId) external view returns (uint256 units, uint256 quoteAtBook) {
        uint256 base = _entry(loanId, B_SHORTFALL);
        units = _word(base);
        quoteAtBook = _word(base + 1);
    }

    /// @notice Draws ever made in this market: the change detector a lender contract caches against.
    /// @notice Unchanged since your last check means no draw anywhere can have altered what you are owed.
    /// @dev Conservative by construction: it may move when nothing of yours changed, never the reverse.
    function drawCount(bytes32 id) external view returns (uint64) {
        return uint64(_word(_marketBase(id) + M_STATE + 1));
    }

    /// @notice The cash resting in this market, which under sole tenancy IS its lender's balance here.
    /// @notice NOT what a fresh draw may take: `drawableOf` nets out what armed loans reserved for their rolls.
    /// @dev PER MARKET, unlike `lenderPools`, whose `resting` spans that lender's markets in this quote.
    function restingOf(bytes32 id) public view returns (uint256) {
        return _word(_marketBase(id) + M_STATE);
    }

    /// @notice The part of this market's resting cash its armed loans hold for their expiry rolls.
    /// @notice ON-CHAIN CALLABLE: it refuses mid-body, where a roll has moved the reserve and not yet the cash.
    /// @dev It may exceed `restingOf`: the lender's own withdraw is not held to it, by the lender's consent.
    function rollReserve(bytes32 id) public view returns (uint256) {
        if (!ACE.notEntered()) revert TornRead();
        return uint128(_word(_marketBase(id) + M_STATE + 1) >> 64);
    }

    /// @notice What a fresh draw may take from this market now: resting cash less the roll reserve, floored at zero.
    /// @notice A QUOTE SIZES AGAINST THIS, never `restingOf`: reserved cash is refused to every draw but its own loan's roll.
    /// @notice ON-CHAIN CALLABLE: it refuses mid-body, at `rollReserve`'s guard.
    function drawableOf(bytes32 id) external view returns (uint256) {
        uint256 cash = restingOf(id);
        uint256 rr = rollReserve(id);
        return Math.saturatingSub(cash, rr);
    }

    /// @notice One armed loan's share of its market's roll reserve; zero once disarmed, rolled or closed.
    function reservedOf(uint256 loanId) public view returns (uint256) {
        return uint128(_word(_entry(loanId, B_AUTO_POLICY)) >> 96);
    }

    /// @notice Whether arming this loan at `tenor` would find its roll backed right now, and the cash it would reserve.
    /// @notice BLOCK-SCOPED: any draw or withdraw moves the answer, so a borrower arms in the open's own transaction.
    /// @notice It answers the record class, the borrower rule, the CASH question and the tenor grid; the other rails are the caller's inputs.
    /// @notice A RECORDLESS market answers `(false, 0)`: no loan there can arm, at any cash level.
    /// @notice ON-CHAIN CALLABLE: past its closed-loan and off-grid refusals it refuses mid-body, at `rollReserve`'s guard.
    /// @dev It re-spells `Borrower.arm`'s cash test, which reads hub storage a lens cannot reach, so the two must agree.
    /// @dev A need within the loan's current reservation lands in any cash state; a larger one must fit with that reservation counted as its own.
    /// @dev For a live loan on the grid the record check runs AFTER the guarded read, so a mid-body call refuses `TornRead` in a recordless market too.
    /// @param loanId The loan to arm.
    /// @param tenor The continuation term; outside the market's grid answers false.
    /// @return ok Whether `setAutoRefinance` would reserve rather than revert `ArmNeedsRecord`, `GateRefused` or `RollUnbacked`.
    /// @return reserve The fresh cash its expiry roll would draw, held back by arming; zero closed, off the grid, recordless or gate-refused.
    function armable(uint256 loanId, uint64 tenor) external view returns (bool ok, uint256 reserve) {
        Loan memory l = loan(loanId);
        if (l.market == bytes32(0) || l.closedAt != 0) return (false, 0);
        Cfg memory c = _gateCfg(l.market);
        if (tenor < c.p.minTenor || tenor > c.p.maxTenor) return (false, 0);
        reserve = Borrower.rollNeed(c, l.debt, tenor);
        uint256 own = reservedOf(loanId);
        uint256 held = rollReserve(l.market); // read before the short-circuit: it carries the torn-read guard
        if (c.p.record == address(0)) return (false, 0); // explicit: the need computed above must not leak out as a quote
        if (!Borrower.gateAdmits(c.p.borrower, l.borrower)) return (false, 0); // the hub's `GateRefused`, through the hub's one spelling
        ok = reserve <= own || reserve + held <= restingOf(l.market) + own;
    }

    /// @notice The collateral a settled loan left its lender.
    function invPotOf(bytes32 id, uint256 loanId) public view returns (uint256) {
        return _word(_entry(loanId, _marketBase(id) + M_INV_POT));
    }

    /// @notice Quote value of one pot at the hub's OWN ask price.
    /// @notice Mirrors the buy leg's PRICE: the ask is max(book, windowed-min), so a Live record marks above book.
    /// @notice NOT its TIMING: a held pot still marks, deliberately, and `inventoryAskOpensAt` says when its ask opens.
    /// @notice A VALUATION, NOT AN OFFER: on a market without the ask it prices a pot nobody may buy, at what the ask would have asked.
    /// @dev invPot times ask over unitScale, FLOORED: a valuation, not the budget that empties the pot (`AceInventoryLens.clearingBudget`).
    /// @dev No record wired reads the max sentinel, which is NO floor rather than an infinite one: the ask is book.
    /// @dev REFUSES on NoPrice, as the buy leg does where a market has one: the market named a record, so book alone is not a price it chose.
    /// @dev An unknown id marks zero through the empty-pot path: claiming no value is conservative, so no guard is owed.
    /// @dev THE WHOLE POT is the lender's, so this is their claim outright and nothing scales it down.
    /// @dev No vault reads this: a vault's NAV is cost-based and reads no price, whatever its door prices off.
    function inventoryMark(bytes32 id, uint256 loanId) external view returns (uint256) {
        uint256 invPot = invPotOf(id, loanId);
        if (invPot == 0) return 0;
        (RecordState s, uint256 cap) = recordStateOf(id);
        if (s == RecordState.NoPrice) revert NoRecordPrice();
        uint256 ask = ACE.idToMarketParams(id).price;
        uint256 askFloor = cap == type(uint256).max ? 0 : cap;
        ask = Math.max(ask, askFloor);
        return FullMath.mulDiv(invPot, ask, marketState(id).unitScale);
    }

    /// @notice When this loan's settled inventory becomes buyable: `closedAt` plus the market's hold.
    /// @notice THE MAX WORD MEANS NEVER: the loan's market has no ask, so its pot leaves only by the lender's own in-kind exit.
    /// @notice Zero means there is no pot to open: the loan is live in a market with the ask, or no loan was ever opened at this id.
    /// @dev THE MARKET ANSWERS BEFORE THE LOAN'S LIVENESS, so a live loan in a market without the ask reads never rather than zero.
    /// @dev TEST THE TWO SENTINELS FIRST: zero and the max word are answers, never instants, so neither may be added to, cast down or shown as a date.
    /// @dev Any other value AT or BEFORE `block.timestamp` means the ask is open now.
    /// @dev The hold gates the permissionless ask alone; the lender's own in-kind exit never waits on it.
    /// @dev Reported for any retired loan, including one that closed clean and so left no pot.
    function inventoryAskOpensAt(uint256 loanId) external view returns (uint256) {
        Loan memory l = loan(loanId);
        if (l.market == bytes32(0)) return 0;
        MarketParams memory p = ACE.idToMarketParams(l.market);
        if (!p.inventoryAsk) return type(uint256).max;
        if (l.closedAt == 0) return 0;
        return uint256(l.closedAt) + MarketInit.inventoryHold(p.minTenor);
    }

    // ---- loan side ----

    /// @notice The price this loan was funded at; zero once its claim is fully melted or closed.
    /// @notice TWO PRICES EXIST: this is the LOAN's, where zero is an answer; the MARKET's always-live bid is `idToMarketParams(id).price`.
    /// @dev DERIVED, never stored: the claim moved in exact lockstep with a stored floor, so it was a copy of it.
    function fundingFloor(bytes32 id, uint256 loanId) public view returns (uint256) {
        return claimOf(id, loanId) == 0 ? 0 : ACE.idToMarketParams(id).price;
    }

    /// @notice This loan's live claim on its market, in quote. It is also the funded flag.
    function claimOf(bytes32 id, uint256 loanId) public view returns (uint256) {
        return _word(_entry(loanId, _marketBase(id) + M_CLAIM));
    }

    function loanCount() external view returns (uint256) {
        return _word(B_COUNT);
    }

    /// @notice The loans this market's cash is funding, filtered out of its ever-opened loan list.
    /// @dev No stored market -> live-loans index: it would duplicate `claim` and cost draw-path gas per open.
    /// @dev `offset`/`limit` bound the WINDOW scanned, not the result -- a page may match nothing.
    /// @dev Closed loans self-filter: a melt or a settlement zeroes the claim, so the predicate skips them.
    /// @dev COST is one staticcall per scanned member; the hub clamps `limit` to 256. An eth_call view only.
    /// @dev `limit == 0` REVERTS `ZeroLimit`: the hub reads it as an empty page, this side read it as full.
    /// @param offset Start near the tail -- ids are monotone and loans are tenor-bounded.
    /// @param limit Members to examine; must be non-zero. The hub clamps the ceiling.
    /// @return loanIds The matches inside the scanned window.
    /// @return scanned Members examined; 0 means the window ran past the end.
    /// @return nextOffset Pass back as `offset`. Empty `loanIds` is not done; `scanned == 0` is.
    function fundedLoans(bytes32 id, uint256 offset, uint256 limit) external view returns (uint256[] memory loanIds, uint256 scanned, uint256 nextOffset) {
        if (limit == 0) revert ZeroLimit();
        uint256[] memory page = ACE.marketLoans(id, offset, limit);
        scanned = page.length;
        nextOffset = offset + scanned;
        uint256[] memory hit = new uint256[](scanned);
        uint256 n;
        for (uint256 i; i < scanned; i++) {
            if (claimOf(id, page[i]) != 0) hit[n++] = page[i];
        }
        loanIds = new uint256[](n);
        for (uint256 i; i < n; i++) {
            loanIds[i] = hit[i];
        }
    }

    /// @notice The market one loan belongs to, as ONE slot instead of the whole six-word record.
    /// @notice ON-CHAIN CALLABLE, and UNGUARDED: one slot, set at open and never moved, so there is nothing to tear.
    /// @notice THE HUB TWINS IT at `loanMarket`, and nothing in `src` reads this copy; prefer the hub's.
    /// @dev Zero for an id that was never opened, which a caller may read as "no such loan".
    function loanMarket(uint256 loanId) external view returns (bytes32) {
        return bytes32(_word(_entry(loanId, B_LOANS)));
    }

    /// @notice One loan record, market and all.
    function loan(uint256 loanId) public view returns (Loan memory l) {
        bytes32[] memory w = _words(_entry(loanId, B_LOANS), 6);
        l.market = w[0];
        l.borrower = address(uint160(uint256(w[1])));
        l.collateralUnits = uint256(w[2]);
        l.debt = uint256(w[3]);
        uint256 p = uint256(w[4]);
        l.openTime = uint64(p);
        l.tenor = uint64(p >> 64);
        l.expiry = uint64(p >> 128);
        l.closedAt = uint64(p >> 192);
        l.lastFee = uint256(w[5]);
    }

    function principalOf(uint256 loanId) external view returns (uint256) {
        return _word(_entry(loanId, B_PRINCIPAL));
    }

    /// @notice The refundable half of this loan's lender fee, still unearned.
    function feeEscrowOf(uint256 loanId) external view returns (uint256) {
        return _word(_entry(loanId, B_FEE_ESCROW));
    }

    /// @notice This loan's armed automatic continuation; `tenor == 0` is disarmed, and a CLOSED loan still reads the policy it closed with.
    /// @dev A sponsor enumerates the armed set from here among LIVE loans; the hub itself pays no crank caller.
    /// @dev `maxFeeBps` carries a CONSENT and not just a number: nonzero admits a keeper-named venue.
    function autoPolicyOf(uint256 loanId) external view returns (uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) {
        uint256 p = _word(_entry(loanId, B_AUTO_POLICY));
        tenor = uint64(p);
        minBufferBps = uint16(p >> 64);
        maxFeeBps = uint16(p >> 80);
    }

    function creditOperator(address borrower, address operator) external view returns (bool) {
        return _word(_entry(operator, _entry(borrower, B_CREDIT_OPERATOR))) != 0;
    }

    /// @notice The next EIP-712 nonce a borrower's credit-delegation signature must carry.
    /// @notice A direct `setCreditOperator` moves it too, so re-read it before every signature rather than caching one.
    function creditOperatorNonce(address borrower) external view returns (uint256) {
        return _word(_entry(borrower, B_CREDIT_OPERATOR + 1));
    }

    // ---- derived ----

    /// @notice The one lender a market names, which is the join every pooled read starts from.
    /// @dev Sole tenancy puts `lender` in the id preimage, so this can never change under a reader.
    function lenderOf(bytes32 id) external view returns (address) {
        return ACE.idToMarketParams(id).lender;
    }

    /// @notice One lender's whole position in one quote: resting cash, drawn at par, and uncollected credit.
    /// @notice POOLED ACROSS THEIR MARKETS; `lent` alone also splits by collateral, read through the hub's guarded `lenderByCollateral`.
    /// @notice UNGUARDED, so never price shares off it -- the hub's own `lenderAssets` is the read that refuses.
    /// @param lender The lender to read.
    /// @param quote The token the pool is denominated in.
    function lenderPools(address lender, address quote) public view returns (uint256 resting, uint256 lent, uint256 owed) {
        uint256 base = _entry(quote, _entry(lender, L_POOLS));
        bytes32[] memory w = _words(base, 3);
        return (uint256(w[0]), uint256(w[1]), uint256(w[2]));
    }

    /// @notice A LENDER's lent principal as WAD share of their lendable capital. INFORMATIONAL: it gates nothing.
    /// @notice NOT A MARKET FIGURE: the hub pools these by (lender, quote), so no per-market split exists.
    function utilization(address lender, address quote) external view returns (uint256) {
        (uint256 resting, uint256 lent,) = lenderPools(lender, quote);
        uint256 denom = resting + lent;
        if (denom == 0) return 0;
        return (lent * 1e18) / denom;
    }

    /// @notice The loan's triggerable price: pure debt arithmetic, no oracle read.
    function triggerPrice(uint256 loanId) public view returns (uint256) {
        Loan memory l = loan(loanId);
        MarketParams memory p = ACE.idToMarketParams(l.market);
        return LoanMath.triggerPrice(l.debt, l.collateralUnits, p.minCoverageWad, marketState(l.market).unitScale);
    }

    /// @notice Collateral this loan must deliver to fill its live claim at the price it was funded at.
    /// @notice What the coverage line has to keep covered at both doors, which is why that line derives off this.
    /// @notice NOT what a RECORDLESS settlement takes: that class forfeits the whole coverage line to its lender.
    /// @dev ONE CEIL, matching settlement, which is what lets the line's own epsilon be a single atom.
    /// @dev Zero once the claim is gone, which reads the same for a repaid loan and a settled one.
    /// @param id The market.
    /// @param loanId The loan.
    /// @return need Collateral units the claim requires.
    function collateralNeeded(bytes32 id, uint256 loanId) public view returns (uint256 need) {
        uint256 amt = claimOf(id, loanId);
        if (amt == 0) return 0;
        return FullMath.mulDivRoundingUp(amt, marketState(id).unitScale, ACE.idToMarketParams(id).price);
    }

    /// @notice What the holder may still take out: the units above this loan's coverage line.
    /// @notice Zero when the loan sits on the line or under it, so a caller never reads a negative as a large number.
    /// @notice Zero on a closed loan and from the expiry second, where the verb refuses `LoanClosed` and `LoanMatured`.
    /// @notice Always leaves at least one unit, as the verb's `ZeroCollateral` requires: a live loan carries debt, and its ceiled line is never zero.
    /// @notice THIS loan only: a refinance redraws at today's price, so its successor's line can free more than zero.
    /// @dev Reproduces `withdrawCollateral`'s gate rather than restating it: same price fold, same line, same library.
    /// @dev The price is the LOWER of the funding floor and the live persisted price, so a fallen record tightens this.
    /// @param id The market.
    /// @param loanId The loan.
    /// @return The withdrawable units.
    function withdrawableUnits(bytes32 id, uint256 loanId) public view returns (uint256) {
        Loan memory l = loan(loanId);
        if (l.closedAt != 0) return 0;
        if (block.timestamp >= l.expiry) return 0;
        Cfg memory c = _gateCfg(id);
        uint256 floor = fundingFloor(id, loanId);
        uint256 cap = Borrower.persistedPrice(c);
        floor = Math.min(floor, cap);
        uint256 line = Borrower.coverageLine(c, l.debt, floor);
        return Math.saturatingSub(l.collateralUnits, line);
    }

    /// @dev The gate's config, and ONLY the gate's: `p` in full plus `unitScale`, which is all the line reads.
    /// @dev `positionTitle` and `positionManager` stay ZERO -- a caller needing one must fill it.
    function _gateCfg(bytes32 id) private view returns (Cfg memory c) {
        c.p = ACE.idToMarketParams(id);
        c.unitScale = marketState(id).unitScale;
    }

    /// @notice Whether distress has persisted for the full settle window: the ONLY finalize precondition.
    /// @notice False again for free the moment the record prints a recovery.
    /// @notice False on a closed loan, without asking the record: `finalize` refuses `LoanClosed` before it reads one.
    /// @notice False with no record: finalize is unreachable there, and the hub answers `NoRecord`.
    /// @notice That is the DISTRESS channel only: a record-less loan, which cannot arm, still settles at tenor via `forceClose`.
    function settleable(uint256 loanId) external view returns (bool) {
        (MarketParams memory p, uint256 trig, bool closed) = _riskView(loanId);
        if (closed || p.record == address(0)) return false;
        return IPersistenceRecord(p.record).persistedBelowSettle(p.quote, p.collateral, trig);
    }

    /// @notice Distress: the record has held below this loan's trigger for the guard window.
    /// @notice False on a closed loan, as the hub's own distress test is.
    /// @notice False with no record: distress cannot be EARNED where nothing persists.
    function inDistress(uint256 loanId) public view returns (bool) {
        (MarketParams memory p, uint256 trig, bool closed) = _riskView(loanId);
        if (closed || p.record == address(0)) return false;
        return IPersistenceRecord(p.record).persistedBelowDistress(p.quote, p.collateral, trig);
    }

    /// @notice Persistence-grade health: the record holds this loan above its trigger. INFORMATIONAL: no hub verb asks it.
    /// @notice False on a closed loan, exactly as `inDistress` is: a closed loan has no trigger left, which any record holds above.
    /// @notice False with no record, exactly as `inDistress` is: neither is PROVABLE, so neither is claimed.
    /// @notice Both false is not proof of a record-less market: a closed loan or a straddling window denies both; ask `recordStateOf`.
    function isHealthy(uint256 loanId) external view returns (bool) {
        (MarketParams memory p, uint256 trig, bool closed) = _riskView(loanId);
        if (closed || p.record == address(0)) return false;
        return _probeAbove(p, trig);
    }

    /// @dev The recovery question, probed by SIGNATURE: it is not an interface member, so a record may not answer it.
    /// @dev No hub verb asks it, so a record owing nothing here reads false rather than bricking a view.
    function _probeAbove(MarketParams memory p, uint256 trig) private view returns (bool) {
        bytes memory data = abi.encodeWithSignature("persistedAbove(address,address,uint256)", p.quote, p.collateral, trig);
        (bool ok, uint256 word) = Probe.askWord(p.record, data);
        return ok && word == 1;
    }

    /// @dev One read of the loan for the three risk predicates: its market's params, its trigger, and whether it has closed.
    function _riskView(uint256 loanId) private view returns (MarketParams memory p, uint256 trig, bool closed) {
        Loan memory l = loan(loanId);
        p = ACE.idToMarketParams(l.market);
        trig = LoanMath.triggerPrice(l.debt, l.collateralUnits, p.minCoverageWad, marketState(l.market).unitScale);
        closed = l.closedAt != 0;
    }

    // ---- the decline channel and the record, as an integrator sees them ----

    /// @notice What this market's price record is saying, and the highest price a draw may fund at.
    /// @notice Live is the only usable state: `cap` is a real windowed minimum and every price-gated verb runs.
    /// @notice NoPrice closes the price-gated ones -- draws, collateral withdrawal, deleverage, the inventory ask -- and carries no cap.
    /// @notice None is a market with NO record: draws are UNCAPPED by ruling, so it is not the safe answer.
    /// @dev `cap` is the max sentinel on None, which means no ceiling; never read it as a price.
    /// @dev Reverts on an id never created: a zero-filled params struct would answer None, the fail-open state.
    /// @dev Deliberately WIDER than the hub's two refusals: this MERGES them so a display never reverts.
    /// @dev A record that answered zero and one that could not answer both read NoPrice here; `recordHealthOf` tells them apart.
    function recordStateOf(bytes32 id) public view returns (RecordState state, uint256 cap) {
        Cfg memory c = _gateCfg(id);
        if (c.p.quote == address(0)) revert NoMarket();
        (bool ok, uint256 p) = Borrower.tryPersistedPrice(c);
        if (!ok) return (RecordState.NoPrice, 0);
        return (c.p.record == address(0) ? RecordState.None : RecordState.Live, p);
    }

    /// @notice `recordStateOf` plus the fact it merges: whether the record ANSWERED at all.
    /// @notice A stale feed answering zero and a dead record answering nothing both close the price-gated verbs.
    /// @notice They are different faults, and only this view separates them: one is the market's state, the other is its record's health.
    /// @dev The deposit door turns on exactly this distinction, so an integrator sizing a lot needs it before they send one.
    /// @dev `answered` is true on a market with NO record: the max sentinel is a ruling, not a reading.
    /// @dev Non-reverting like its sibling, so a display can render a dead record rather than failing to render at all.
    function recordHealthOf(bytes32 id) external view returns (RecordState state, uint256 cap, bool answered) {
        Cfg memory c = _gateCfg(id);
        if (c.p.quote == address(0)) revert NoMarket();
        if (c.p.record == address(0)) return (RecordState.None, type(uint256).max, true);
        bytes memory data = abi.encodeCall(IPersistenceRecord.minPrice, (c.p.quote, c.p.collateral));
        (bool ok, uint256 p) = Probe.askWord(c.p.record, data);
        if (!ok) return (RecordState.NoPrice, 0, false);
        return (p == 0 ? RecordState.NoPrice : RecordState.Live, p, true);
    }

    /// @notice Whether this market's record currently proves any price at all.
    /// @notice False from a record that cannot price closes every price-gated verb: draws, withdrawal, deleverage, the ask.
    /// @notice `finalize` is NOT one: a record answering ZERO may still persist below-ness, so title can move while this reads false.
    /// @notice False from NO record is a different market entirely -- draws are UNCAPPED, not closed.
    /// @dev `recordStateOf` tells the two apart directly; this is the bool projection of it, nothing more.
    function recordLive(bytes32 id) external view returns (bool) {
        (RecordState s,) = recordStateOf(id);
        return s == RecordState.Live;
    }

    /// @notice Pre-flight for a candidate price source: would genesis admit it for this pair, and what would a draw read from it now.
    /// @notice `supported` replays genesis's interview of the SOURCE only: the pair affirmed, four reads answered, any declared unit scale this frame.
    /// @notice `price` is the windowed minimum the draw door reads, never the source's last print: `lastObserved` on the source is that.
    /// @notice Zero on a supported source means it answered zero: creatable and inert, every draw refusing `NoRecordPrice` until it prints.
    /// @dev A pre-flight, never a promise: a source can answer by caller or by block, and a `UNIT_SCALE()` answer too large for genesis to copy passes here.
    /// @dev Never reverts on a source's ANSWER, however failed, short or large: each read goes through `Probe`, which copies one word.
    /// @dev Forwards all gas, so a source burning it on each of six reads can exhaust the call; a stipend would refuse a costly source genesis admits.
    /// @dev `src` is a CANDIDATE the caller names: the least vetted address this contract calls, and a hostile one can break only the caller's own pre-flight.
    function recordFitFor(address src, address quote, address collateral) external view returns (bool supported, uint256 price) {
        (bool ok, uint256 word) = Probe.askWord(src, abi.encodeCall(IPersistenceRecord.supportsPair, (quote, collateral)));
        if (!ok || word != 1) return (false, 0); // genesis decodes a strict bool and requires it true
        (ok, price) = Probe.askWord(src, abi.encodeCall(IPersistenceRecord.minPrice, (quote, collateral)));
        if (!ok || !_answersTheInterview(src, quote, collateral)) return (false, 0);
        supported = true;
    }

    /// @dev Genesis's other three interview reads and its unit-scale check, each through `Probe`, so a failed required read answers false.
    /// @dev A below-answer outside {0, 1} fails, as genesis's bool decode refuses it; a unit scale that does not answer is absent.
    function _answersTheInterview(address src, address quote, address collateral) private view returns (bool) {
        (bool ok, uint256 w) = Probe.askWord(src, abi.encodeCall(IPersistenceRecord.persistedBelowDistress, (quote, collateral, 0)));
        if (!ok || w > 1) return false;
        (ok, w) = Probe.askWord(src, abi.encodeCall(IPersistenceRecord.persistedBelowSettle, (quote, collateral, 0)));
        if (!ok || w > 1) return false;
        (ok,) = Probe.askWord(src, abi.encodeCall(IPersistenceRecord.lastObserved, (quote, collateral)));
        if (!ok) return false;
        (ok, w) = Probe.askWord(src, abi.encodeWithSignature("UNIT_SCALE()"));
        return !ok || w == UNIT_SCALE;
    }

    /// @notice The price level below which this loan's deleverage band opens; 0 when the channel is off.
    /// @dev MIRRORS Deleverage.deleverage's band derivation (ceil against the borrower).
    /// @dev A MIRROR, not the gate: the crank re-derives it independently; a drift between the two is caught, not silent.
    function deleverageBandLevel(uint256 loanId) public view returns (uint256) {
        Loan memory l = loan(loanId);
        MarketParams memory p = ACE.idToMarketParams(l.market);
        if (p.deleverageBandBps == 0 || l.closedAt != 0) return 0;
        uint256 trig = LoanMath.triggerPrice(l.debt, l.collateralUnits, p.minCoverageWad, marketState(l.market).unitScale);
        return FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - p.deleverageBandBps * 1e14);
    }

    /// @notice The price at or below which this loan drops under the deleverage stop floor; 0 when off.
    /// @dev MIRRORS Deleverage.deleverage's stop derivation (ceil against the borrower).
    /// @dev At or below this the trade channel refuses (DeleverageStopped); settlement owns the loan.
    function deleverageStopLevel(uint256 loanId) public view returns (uint256) {
        Loan memory l = loan(loanId);
        MarketParams memory p = ACE.idToMarketParams(l.market);
        if (p.deleverageBandBps == 0 || l.closedAt != 0) return 0;
        uint256 trig = LoanMath.triggerPrice(l.debt, l.collateralUnits, p.minCoverageWad, marketState(l.market).unitScale);
        return FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - p.deleverageStopBps * 1e14);
    }

    /// @notice Whether a deleverage crank would pass the channel's entry gates right now.
    /// @dev Gate mirror: band on, open, unexpired, over `minDebt`, not distressed, persistently in the band, above the stop.
    /// @dev It mirrors the `minDebt` cap with the crank's own fused mulDiv: false when the head buys no whole unit at the record price.
    /// @dev True means admitted, not profitable or even selling: at/above target, on a dust restore, or with the reserve holding the whole sale it sells 0.
    /// @dev The record reads below are RAW, deliberately: a live band implies a non-zero record at genesis.
    /// @dev The `no record -> max` sentinel would read as ELIGIBLE with no price source: fail-OPEN, so never apply it.
    function deleverageEligible(uint256 loanId) external view returns (bool) {
        Loan memory l = loan(loanId);
        MarketParams memory p = ACE.idToMarketParams(l.market);
        if (p.deleverageBandBps == 0 || l.closedAt != 0) return false;
        if (block.timestamp >= l.expiry) return false;
        if (l.debt <= p.minDebt) return false;
        if (inDistress(loanId)) return false;
        if (!IPersistenceRecord(p.record).persistedBelowDistress(p.quote, p.collateral, deleverageBandLevel(loanId))) return false;
        /// @dev mirror the crank's stop gate: below the stop floor the trade channel refuses
        uint256 ps = IPersistenceRecord(p.record).minPrice(p.quote, p.collateral);
        if (ps <= deleverageStopLevel(loanId)) return false;
        uint256 epsC = 10000 - p.deleverageFloorEpsBps;
        /// @dev Past this the crank's own sizing sells nothing, since `ps / 1e4` already clears any uint128-debt trigger.
        if (ps > type(uint256).max / epsC) return false;
        return FullMath.mulDiv(l.debt - p.minDebt, 10000 * marketState(l.market).unitScale, ps * epsC) != 0;
    }

    // ---- venue-side helpers ----

    /// @notice Ask-side headroom in units: backed burns not yet delivered.
    function headroom(bytes32 id) external view returns (uint256) {
        MarketState memory s = marketState(id);
        return s.cumulativeBackedBurns - s.netSyntheticOutflow;
    }

    /// @notice Whether this market has any resting cash at all; reserved cash counts, so `drawableOf` says what a draw may take.
    function isActive(bytes32 id) external view returns (bool) {
        return restingOf(id) != 0;
    }

    /// @notice What a `collect` would pay this lender right now, across every market they run in this quote.
    /// @notice ONE NUMBER: a single claimant per market and one pool per pair leaves nothing to enumerate.
    /// @notice ON-CHAIN CALLABLE, since it refuses mid-body; a money rail still asks the hub's `lenderOwed`, the same word at its owner.
    /// @dev LEDGER CREDIT: where the hub's quote balance is short of it, `collect` refuses rather than paying less.
    /// @dev GUARDED although no contract prices off it: an off-chain reader is still never handed a torn pool.
    function claimable(address lender, address quote) external view returns (uint256) {
        if (!ACE.notEntered()) revert TornRead();
        (,, uint256 owed) = lenderPools(lender, quote);
        return owed;
    }

    // ---- venue-dependency disclosure ----

    /// @notice Aggregate exposure behind one record and ordered pair, over a caller-supplied id list.
    /// @notice SOUND, NOT COMPLETE: every id counted provably names this record and pair.
    /// @notice Nothing proves the list is all of them -- build it from the MarketCreated log.
    /// @dev `rejected` is the receipt that the list was filtered, never a silent skip.
    /// @dev Duplicates double-count: overstating exposure is the safe direction, and the caller owns the list.
    /// @dev capPrice 0 with recordObserving true is a record that cannot price failing closed -- borrowing dark, not zero exposure.
    /// @dev NOT the `recordLive` function: that reads the windowed min, this field reads lastObserved. Different questions.
    /// @dev Caller-bounded loop: no protocol-owned market enumeration exists to walk.
    function venueExposure(address record, address quote, address collateral, bytes32[] calldata ids) external view returns (VenueExposure memory v) {
        for (uint256 i; i < ids.length; i++) {
            MarketParams memory p = ACE.idToMarketParams(ids[i]);
            if (p.quote != quote || p.collateral != collateral || p.record != record || p.quote == address(0)) {
                v.rejected++;
                continue;
            }
            if (v.verified == 0 || p.minCoverageWad < v.minK) v.minK = p.minCoverageWad;
            v.maxK = Math.max(v.maxK, p.minCoverageWad);
            v.verified++;
        }
        _probeRecord(v, record, quote, collateral);
    }

    /// @dev Every best-effort read of the record, in its own frame: inlined they run the stack out.
    /// @dev ALL PROBED BY SIGNATURE OR TOTAL: a record owing none of these must render, never revert the view.
    function _probeRecord(VenueExposure memory v, address record, address quote, address collateral) private view {
        (bool ok, uint256 u) = Probe.askWord(record, abi.encodeCall(IPersistenceRecord.minPrice, (quote, collateral)));
        if (ok) v.capPrice = u;
        (ok, u) = Probe.askWord(record, abi.encodeCall(IPersistenceRecord.lastObserved, (quote, collateral)));
        v.recordObserving = ok && u != 0;
        (ok, u) = Probe.askWord(record, abi.encodeWithSignature("PERSISTENCE_WINDOW()"));
        if (ok) v.distressWindow = u;
        (ok, u) = Probe.askWord(record, abi.encodeWithSignature("SETTLE_WINDOW()"));
        if (ok) v.settleWindow = u;
        (ok, u) = Probe.askWord(record, abi.encodeWithSignature("DEPTH_WINDOW()"));
        (v.depthSupported, u) = Probe.askWord(record, abi.encodeWithSignature("minDepthOverWindow(uint256)", ok ? u : 0));
        if (v.depthSupported) v.minDepth = u;
        (ok, u) = Probe.askWord(record, abi.encodeWithSignature("WRITER()"));
        if (ok) v.writer = address(uint160(u));
    }
}
