// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Storage, Loan, MarketParams, MarketState} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {Probe} from "../../src/ace/hub/libraries/Probe.sol";

/// @notice The hub's read door plus the two views it is required to keep.
interface IAceRead {
    function extsload(bytes32 slot) external view returns (bytes32);
    function extsload(bytes32 startSlot, uint256 n) external view returns (bytes32[] memory);
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
}

/// @title AceReader
/// @notice Test-side reader over the singleton's storage: the only way a suite sees hub state.
/// @notice The hub carries no views by design, so every slot derivation here is exercised by the suites.
/// @dev Reads exclusively through `extsload`, the same mechanism the shipped lens uses.
/// @dev Slot numbers come from the compiler's own layout for `Ace`; a wrong one fails loudly, not silently.
contract AceReader {
    IAceRead public immutable ACE;

    /// @dev ERC-7201 roots from Storage; LoanBook members are base + declaration index.
    uint256 private constant M_MAP = uint256(Storage.MARKETS);
    uint256 private constant B_BASE = uint256(Storage.BOOK);
    uint256 private constant B_COUNT = B_BASE;
    uint256 private constant B_LOANS = B_BASE + 1;
    uint256 private constant B_PRINCIPAL = B_BASE + 2;
    uint256 private constant B_CREDIT_OPERATOR = B_BASE + 3;
    /// @dev `feeEscrowOf` sits past the nonce at index 5.
    uint256 private constant B_FEE_ESCROW = B_BASE + 5;
    /// @dev `autoPolicyOf` was APPENDED after it, at index 6.
    uint256 private constant B_AUTO_POLICY = B_BASE + 6;
    /// @dev The pull-credit ledger, APPENDED at 7 and 8.
    uint256 private constant B_UNITS_OWED = B_BASE + 7;
    uint256 private constant B_QUOTE_OWED = B_BASE + 8;
    uint256 private constant B_SHORTFALL = B_BASE + 9;

    /// @dev Member offsets inside one `Market`: params occupy 0..16, state 17..25, mappings after.
    /// @dev A wrong index reads a plausible number and reverts nothing, so never edit these by hand.
    /// @dev Verify with `scripts/layout-check.sh`: it reads the compiler's layout, not this file.
    /// @dev `AceSettlement::test_ReaderSlots_AgreeWithKnownValues` also pins one value per region.
    /// @dev A field APPENDED to MarketState still shifts every constant below it.
    uint256 private constant M_STATE = 17; // MarketParams inline slots; minTenor packs with maxTenor, and lender with inventoryAsk
    uint256 private constant M_STATE_WORDS = 9;
    uint256 private constant M_CLAIM = 26;
    uint256 private constant M_INV_POT = 28; // +27 is the openedLoans array, not a gap

    uint256 private constant L_POOLS = uint256(Storage.LENDERS); // `pools`, member 0 of three; an entry is _entry(quote, _entry(lender, root))

    constructor(address ace) {
        ACE = IAceRead(ace);
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

    /// @notice One lender's whole position in one quote: resting cash, drawn at par, and uncollected credit.
    function lenderPools(address lender, address quote) public view returns (uint256 resting, uint256 lent, uint256 owed) {
        bytes32[] memory w = _words(_entry(quote, _entry(lender, L_POOLS)), 3);
        return (uint256(w[0]), uint256(w[1]), uint256(w[2]));
    }

    /// @notice The pool a market's writes land in: its own lender's, in its own quote.
    /// @notice NOT A PER-MARKET FIGURE, and there is no longer such a thing -- the name says pool for that reason.
    /// @dev A shorthand for the single-market fixture, where "this market's" and "this lender's" coincide.
    /// @dev THEY DO NOT COINCIDE once one lender runs two markets in a quote: this then spans both, and a test
    /// @dev meaning to isolate one of them must drive the other lender apart or assert on a delta instead.
    function poolOf(bytes32 id) public view returns (uint256 resting, uint256 lent, uint256 owed) {
        MarketParams memory p = ACE.idToMarketParams(id);
        return lenderPools(p.lender, p.quote);
    }

    // ---- market state ----

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

    /// @notice What a `collect` would pay this lender: their pool's credit leg, across every market.
    function unitOwed(address lender, address quote) external view returns (uint256) {
        (,, uint256 owed) = lenderPools(lender, quote);
        return owed;
    }

    /// @dev NO `unitOwed(bytes32)`, `totalCash(bytes32)` or `totalLent(bytes32)` OVERLOAD, deliberately: each
    /// @dev would leave every old call site compiling while its meaning changed from this market's figure to
    /// @dev this lender's. The three below are the id-shaped forms and they are SPELLED DIFFERENTLY for exactly
    /// @dev that reason -- the rename is what forces a human to look at the site. Read `poolOf` for the caveat.

    /// @notice Resting cash in the pool a market writes into: its lender's, in its quote, over all their markets.
    function poolResting(bytes32 id) external view returns (uint256 r) {
        (r,,) = poolOf(id);
    }

    /// @notice Principal drawn at par out of that same pool.
    function poolLent(bytes32 id) external view returns (uint256 l) {
        (, l,) = poolOf(id);
    }

    /// @notice Uncollected credit in that same pool: what a `collect` would pay.
    function poolOwed(bytes32 id) external view returns (uint256 o) {
        (,, o) = poolOf(id);
    }

    /// @notice The market's aggregate of quote credited to claimants and not yet pulled.
    function quoteOwedTotal(bytes32 id) external view returns (uint256) {
        return _word(_marketBase(id) + M_STATE + 7);
    }

    /// @notice The cash resting in this market, which under sole tenancy IS its lender's balance here.
    /// @dev PER MARKET, unlike `poolResting`, which is that lender's total across their markets in this quote.
    function restingOf(bytes32 id) external view returns (uint256) {
        return _word(_marketBase(id) + M_STATE);
    }

    /// @notice Collateral units one loan has credited one claimant and not yet paid out.
    function unitsOwedOf(uint256 loanId, address claimant) external view returns (uint256) {
        return _word(_entry(claimant, _entry(loanId, B_UNITS_OWED)));
    }

    /// @notice Quote one loan has credited one claimant and not yet paid out.
    function quoteOwedOf(uint256 loanId, address claimant) external view returns (uint256) {
        return _word(_entry(claimant, _entry(loanId, B_QUOTE_OWED)));
    }

    /// @notice What a settled loan's claims did not get: atoms short, and their value at the funding ticks.
    function shortfallOf(uint256 loanId) external view returns (uint256 units, uint256 quoteAtBook) {
        uint256 base = _entry(loanId, B_SHORTFALL);
        units = _word(base);
        quoteAtBook = _word(base + 1);
    }

    /// @notice A lender's resting cash, pooled over their markets in this quote.
    function totalCash(address lender, address quote) external view returns (uint256) {
        (uint256 resting,,) = lenderPools(lender, quote);
        return resting;
    }

    /// @notice A lender's principal drawn at par, pooled over their markets in this quote.
    function totalLent(address lender, address quote) external view returns (uint256) {
        (, uint256 lent,) = lenderPools(lender, quote);
        return lent;
    }

    function protocolRevenue(bytes32 id) external view returns (uint256) {
        return _word(_marketBase(id) + M_STATE + 4);
    }

    /// @notice The slot a market's resting cash sits in; the successor to the per-tick `bucketSlot`.
    /// @dev Exposed so a test can vm.store a field the hub has no setter for, without a fourth offset copy.
    function cashSlot(bytes32 id) external pure returns (uint256) {
        return _marketBase(id) + M_STATE;
    }

    /// @notice The slot one member of a market's `MarketParams` occupies, by declaration index.
    /// @dev Exposed so a test can vm.store a param past a genesis rail, without hardcoding an offset.
    function marketSlot(bytes32 id, uint256 index) external pure returns (uint256) {
        return _marketBase(id) + index;
    }

    /// @notice The collateral a settled loan left its lender.
    function invPotOf(bytes32 id, uint256 loanId) external view returns (uint256) {
        return _word(_entry(loanId, _marketBase(id) + M_INV_POT));
    }

    // ---- loan side ----

    /// @notice The price this loan was funded at; zero once its claim is fully melted or closed.
    /// @dev DERIVED, exactly as the hub derives it: the claim moved in lockstep with the stored floor.
    function fundingFloor(bytes32 id, uint256 loanId) external view returns (uint256) {
        return claimOf(id, loanId) == 0 ? 0 : ACE.idToMarketParams(id).price;
    }

    /// @notice This loan's live claim on its market, in quote. It is also the funded flag.
    /// @dev The slot is exposed too: a test that vm.stores a claim needs no fourth copy of the offsets.
    function claimOf(bytes32 id, uint256 loanId) public view returns (uint256) {
        return _word(claimSlot(id, loanId));
    }

    function claimSlot(bytes32 id, uint256 loanId) public pure returns (uint256) {
        return _entry(loanId, _marketBase(id) + M_CLAIM);
    }

    /// @notice How many claims this loan holds: ONE while it is funded, zero once it retires.
    /// @dev THE SUCCESSOR TO `claimTicks(id, loanId).length`, and it is deliberately not a list.
    /// @dev A loan funded from a band of ticks and held one claim per tick, so the COUNT was a real variable
    /// @dev and every fixture asserted it. It is now zero or one, and saying so in one place is what lets a
    /// @dev migrated suite keep asserting "the draw funded" without pretending an array still exists.
    function claimCount(bytes32 id, uint256 loanId) external view returns (uint256) {
        return claimOf(id, loanId) == 0 ? 0 : 1;
    }

    function loanCount() external view returns (uint256) {
        return _word(B_COUNT);
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

    /// @notice The second this settled loan's HOLD ends, where an ask opens if its market has one: `closedAt` plus THIS market's own hold.
    /// @notice Zero for a live loan, which has no pot and no opening time.
    /// @dev NOT `AceLens.inventoryAskOpensAt` on an ask-off market: the lens answers never there, and this names the hold's end for a fixture to warp past.
    /// @dev A fixture warps to this rather than to a literal hour: the hold is `min(1 hours, minTenor / 2)`.
    /// @dev A minute-scale market therefore opens its ask inside its own term, and a literal would overshoot.
    function inventoryAskOpensAt(uint256 loanId) public view returns (uint256) {
        Loan memory l = loan(loanId);
        if (l.closedAt == 0) return 0;
        return uint256(l.closedAt) + MarketInit.inventoryHold(ACE.idToMarketParams(l.market).minTenor);
    }

    /// @notice The RAW stored word, which a settled loan keeps; `Ace.debtOf` reads zero once a loan closes.
    function debtOf(uint256 loanId) external view returns (uint256) {
        return _word(_entry(loanId, B_LOANS) + 3);
    }

    function principalOf(uint256 loanId) external view returns (uint256) {
        return _word(_entry(loanId, B_PRINCIPAL));
    }

    /// @notice The withheld early-exit escrow still held against this loan; zero once it is closed.
    function feeEscrowOf(uint256 loanId) public view returns (uint256) {
        return _word(_entry(loanId, B_FEE_ESCROW));
    }

    /// @notice What a clean close right now would return to the borrower; rounds DOWN, as the hub does.
    function earlyExitRefund(uint256 loanId) external view returns (uint256) {
        Loan memory l = loan(loanId);
        if (l.closedAt != 0 || l.tenor == 0) return 0;
        uint256 remaining = l.expiry > block.timestamp ? l.expiry - block.timestamp : 0;
        return FullMath.mulDiv(feeEscrowOf(loanId), remaining, l.tenor);
    }

    /// @notice This loan's armed automatic continuation; `tenor == 0` is disarmed.
    /// @dev The third field is the MIRROR of `AceLens.autoPolicyOf`: the two decode one slot and must move together.
    function autoPolicyOf(uint256 loanId) external view returns (uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) {
        uint256 p = _word(_entry(loanId, B_AUTO_POLICY));
        tenor = uint64(p);
        minBufferBps = uint16(p >> 64);
        maxFeeBps = uint16(p >> 80);
    }

    /// @notice One armed loan's share of its market's roll reserve; the MIRROR of `AceLens.reservedOf`.
    function reservedOf(uint256 loanId) external view returns (uint256) {
        return uint128(_word(_entry(loanId, B_AUTO_POLICY)) >> 96);
    }

    /// @notice The cash a market's armed loans hold for their rolls; unguarded here, since a test reads between calls.
    function rollReserve(bytes32 id) external view returns (uint256) {
        return uint128(_word(_marketBase(id) + M_STATE + 1) >> 64);
    }

    function creditOperator(address borrower, address operator) external view returns (bool) {
        return _word(_entry(operator, _entry(borrower, B_CREDIT_OPERATOR))) != 0;
    }

    /// @notice The next EIP-712 nonce a borrower's credit-delegation signature must carry.
    function creditOperatorNonce(address borrower) external view returns (uint256) {
        return _word(_entry(borrower, B_CREDIT_OPERATOR + 1));
    }

    // ---- derived ----

    /// @notice A LENDER's lent principal as WAD share of their lendable capital; informational.
    function utilization(address lender, address quote) external view returns (uint256) {
        (uint256 resting, uint256 lent,) = lenderPools(lender, quote);
        uint256 denom = resting + lent;
        if (denom == 0) return 0;
        return (lent * 1e18) / denom;
    }

    /// @notice The loan's triggerable price: pure debt arithmetic, no oracle read.
    function triggerPrice(uint256 loanId) external view returns (uint256) {
        Loan memory l = loan(loanId);
        MarketParams memory p = ACE.idToMarketParams(l.market);
        return LoanMath.triggerPrice(l.debt, l.collateralUnits, p.minCoverageWad, marketState(l.market).unitScale);
    }

    /// @notice Whether distress has persisted for the full settle window: the ONLY precondition on finalize.
    /// @notice False again for free the moment the record prints a recovery.
    /// @notice Record-less and closed loans answer false on all three, mirroring `AceLens` so parity holds.
    function settleable(uint256 loanId) external view returns (bool) {
        (MarketParams memory p, uint256 trig, bool closed) = _riskView(loanId);
        if (closed || p.record == address(0)) return false;
        return IPersistenceRecord(p.record).persistedBelowSettle(p.quote, p.collateral, trig);
    }

    /// @notice Distress: the record has held below this loan's trigger for the guard window.
    function inDistress(uint256 loanId) external view returns (bool) {
        (MarketParams memory p, uint256 trig, bool closed) = _riskView(loanId);
        if (closed || p.record == address(0)) return false;
        return IPersistenceRecord(p.record).persistedBelowDistress(p.quote, p.collateral, trig);
    }

    /// @notice Persistence-grade health: the record holds this loan above its trigger. Informational: no hub verb asks it.
    function isHealthy(uint256 loanId) external view returns (bool) {
        (MarketParams memory p, uint256 trig, bool closed) = _riskView(loanId);
        if (closed || p.record == address(0)) return false;
        (bool ok, uint256 word) = Probe.askWord(p.record, abi.encodeWithSignature("persistedAbove(address,address,uint256)", p.quote, p.collateral, trig));
        return ok && word == 1;
    }

    function _riskView(uint256 loanId) private view returns (MarketParams memory p, uint256 trig, bool closed) {
        Loan memory l = loan(loanId);
        p = ACE.idToMarketParams(l.market);
        trig = LoanMath.triggerPrice(l.debt, l.collateralUnits, p.minCoverageWad, marketState(l.market).unitScale);
        closed = l.closedAt != 0;
    }

    /// @notice What a market asks for settled inventory: its own price, or the record's windowed min if higher.
    /// @dev The relist rule in ONE place, as `askTickFor` was: a market re-lists at the price it acquired at,
    /// @dev which under one price is simply the market's price. The record floor is the hub verb's, not this.
    function askPriceFor(bytes32 id) external view returns (uint256) {
        return ACE.idToMarketParams(id).price;
    }

    /// @notice Ask-side headroom in units: backed burns not yet delivered (LR-9).
    function headroom(bytes32 id) external view returns (uint256) {
        MarketState memory s = marketState(id);
        return s.cumulativeBackedBurns - s.netSyntheticOutflow;
    }

    /// @notice Whether this market has any resting cash at all: the one-price successor to the tick bitmap.
    /// @dev `activeTicks`, `tickWord` and `tickInitialized` are GONE with the coordinate they indexed.
    /// @dev The bitmap-vs-live-state drift they existed to catch is unrepresentable: there is one number.
    function isActive(bytes32 id) external view returns (bool) {
        return marketState(id).cash != 0;
    }
}
