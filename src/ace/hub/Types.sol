// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @dev What the price record is saying. Decoded once by `Borrower.recordState`, never re-derived.
/// @dev None: no record wired. NoPrice: it cannot produce one. Live: a real windowed minimum.
enum RecordState {
    None,
    NoPrice,
    Live
}

/// @notice The per-market config. `id = keccak256(abi.encode(params))`, stored at createMarket.
/// @dev Everything here is PER-MARKET; only the bounds on Ace are universal.
/// @dev Field order IS the hash preimage, so it is market identity: never reorder after launch.
struct MarketParams {
    // tokens and wired contracts
    address quote;
    address collateral;
    address record; // IPersistenceRecord: the one price source, for admission, distress, sizing and the disposal floor
    /// @notice The ONE address that may borrow here. ZERO IS PERMISSIONLESS, which is the default.
    /// @dev NEW CREDIT ONLY: a settlement never asks, so no borrower rule can strand a matured loan.
    /// @dev AN ADDRESS, NEVER A CONTRACT TO INTERVIEW: a comparison cannot revert, run out of gas or answer a different width.
    /// @dev THE COST: a market open to SEVERAL named borrowers is not expressible.
    /// @dev The rule reads the title's CURRENT holder, so here a loan whose title moved to anyone else cannot be extended.
    address borrower;
    /// @notice THE market's one price: quote atoms per collateral atom, raw Q96, write-once.
    /// @notice A curator's whole offer is this much, at this price, take it or leave it.
    /// @dev IT IS THE LENDER'S BID, not an oracle read and not a rate: what the lender values collateral at.
    /// @dev The record caps what a draw may fund at, bar a zero-fresh re-term, which it judges for admissibility instead, as it judges an extension.
    /// @dev ALWAYS LIVE, unlike a loan's funding floor, which is zero once its claim retires.
    /// @dev Q96 RAW rather than a human WAD, so it shares one frame with the record and the venue; nothing converts at a boundary.
    /// @dev Name it through the helper; never write the literal.
    /// @dev RECORDLESS, it is bounded only by `(0, MAX_PRICE]` and the openable-ticket rail: one far over the collateral lends against atoms.
    /// @dev No price or units rail can refuse that without refusing a real 0-decimal item worth more than `minPrincipal` a unit.
    uint256 price;
    uint256 fillFeeBps;
    // loan terms
    uint256 minCoverageWad; // WAD; scales debt into the trigger, so it also caps a draw at 1/k of its funding floor
    uint256 baseBps; // the LENDER's rate per minTenor; the borrower's all-in adds ACE's share on top
    uint64 minTenor;
    /// @notice The longest term this market writes; an extension runs a loan's own tenor from now, so never past it.
    /// @dev NO SEPARATE per-deposit horizon: on a write-once struct a second field could only advertise unfunded terms or never bind.
    /// @dev The draw checks the term against this, and an extension keeps the term drawn; nothing checks it at a deposit.
    uint64 maxTenor;
    /// @notice The smallest loan this market opens, and the smallest lot either lender door rests or leaves.
    /// @notice A live loan never carries less than HALF of it (`LoanMath.debtFloor`): a repay pays it off or leaves that much.
    /// @notice A crank whose restore would leave less closes the loan; an extension never moves the debt.
    /// @dev A DRAW subtracts its principal with no remainder test, so resting cash under it can remain; a withdraw always empties it.
    uint256 minPrincipal;
    // deleverage channel: band 0 is OFF, and genesis then requires the other four dials zero
    uint256 deleverageFloorEpsBps; // the keeper's whole pay; a sold unit melts (1-eps) of the record floor, less the cut on a restoring crank
    uint256 deleverageBandBps; // margin under which disposal opens: a LEVEL the record must hold below, not a decline; 0 = channel off
    uint256 deleverageTargetBps; // margin a deleverage restores to; > band, the hysteresis is mandatory
    // margin floor; below it the trade channel refuses and title-transfer settlement owns the loan
    uint256 deleverageStopBps;
    uint256 deleverageProtocolBps; // protocol cut off the top of deleverage proceeds; 0 = no cut
    /// @dev THE DISTRESS AND SETTLE WINDOWS ARE NOT HERE, deliberately: an oracle setting lives on the oracle.
    /// @dev The hub never computes with either, so carrying them would only put them in the id preimage.
    /// @dev The record owns them and answers over them; nothing here can disagree with what it measures.
    uint256 settleBountyBps;
    /// @notice The ONE address whose cash rests here. Every market is sole-tenant; genesis refuses a zero.
    /// @notice It is what lets `MarketState.cash` BE this lender's balance: no arithmetic splits it between owners.
    /// @dev APPENDED, never inserted: the field order is the hash preimage, so anything inserted above would re-key every market.
    /// @dev IN the preimage deliberately -- outside it, two markets differing only by lender would collide.
    address lender;
    /// @notice Whether anyone may buy a settled loan's pot from the hub at the market's price. OFF IS THE DEFAULT, and it is write-once.
    /// @notice OFF, only the lender's `redeemInKind` ever moves a settled pot: a lender that cannot call it must turn this ON, or its pots have no way home.
    /// @dev OFF requires a zero `fillFeeBps` at genesis: with no buyer the fee would be declared and never read.
    /// @dev APPENDED after `lender` and packed into its word, so no member below moved; in the preimage it is a word of its own.
    bool inventoryAsk;
}

/// @notice The per-market scalar state: the resting cash, the protocol's own pots, and the derived scales.
/// @dev THE LENDER'S THREE AGGREGATES ARE NOT HERE: `resting`, `lent` and `owed` live in `Lenders.pools`, keyed by (lender, quote).
/// @dev So a lender's position reads in O(1) at any market count, and no per-market split of those three exists.
/// @dev The protocol's own pots below stay per-market, so revenue and the settlement record are still attributable to one market.
struct MarketState {
    /// @notice Resting quote at this market's one price: what a draw consumes and a withdraw returns.
    /// @dev PER MARKET, unlike the lender's pooled `resting`, which spans their markets in this quote.
    /// @dev The two move together on every deposit, draw and withdraw and must never be netted.
    uint256 cash;
    uint64 drawCount; // draws and extensions made here, a lender's change detector; an extension can bump it once a second a loan, for an atom's fee
    uint256 cumulativeBackedBurns;
    uint256 netSyntheticOutflow;
    uint256 protocolRevenue; // the ONE protocol pot: the origination and deleverage cuts
    uint64 lastSweptAt;
    uint256 unitScale; // the FIXED price frame, 2^96: prices are quote atoms per collateral atom
    uint256 quoteOwedTotal; // quote credited to claimants, held outside the lender's pools: a solvency pot
    uint256 realizedLossAtBook; // running quote loss at book over short settlements; NOT a pot, and solvency never reads it
}

/// @notice One lender's whole position in one quote, summed over every market of theirs that uses it.
/// @dev THREE PLAIN WORDS, never a packed lossy encoding: the solvency check is an EQUALITY against the hub's balance.
/// @dev `lent` is NOT a pot: that quote has left the hub, so the solvency identity never reads it.
struct LenderPools {
    uint256 resting; // cash standing as a bid, across their markets in this quote
    uint256 lent; // drawn at par against their claims
    uint256 owed; // accumulated credit: a terminal close pushes it, the lender's own collect pulls it, and sale proceeds wait here for either
}

/// @notice One market's whole footprint; mappings live here, so a library takes them by storage ref.
struct Market {
    MarketParams p;
    MarketState s;
    /// @dev What one loan still owes this market, in quote. ONE WORD PER LOAN, so nothing walks or bounds it.
    /// @dev IT IS ALSO THE FUNDED FLAG: a live claim was funded at `p.price`; a zero claim never funded or has retired, and has no funding floor.
    mapping(uint256 => uint256) claim;
    /// @dev Every loan this market has EVER opened, in draw order. APPEND-ONLY: pushed once, never removed.
    /// @dev So an entry's index is fixed for life and a paginated read is gap-free by construction.
    /// @dev Membership is ever-opened, NOT live -- liveness is `loans[id].closedAt == 0`, read separately.
    /// @dev Removal was refused: it is what makes two ledgers disagree across an external call.
    uint256[] openedLoans;
    /// @dev Collateral owed the lender on a settled loan, resting on the custodian's retired ledger.
    /// @dev ONE POT PER LOAN: the lender takes it whole in kind, and where the market has the ask it sells at the market's own price.
    mapping(uint256 => uint256) invPotOf;
    /// @dev APPENDED: this market's credit orders, oldest first, in post order.
    /// @dev Append-only for the reason `openedLoans` is: removal is what makes two ledgers disagree.
    uint256[] orderIds;
}

/// @dev NO PER-HOLDER ENTITLEMENT LEDGER EXISTS, and sole tenancy makes one unrepresentable.
/// @dev One lender owns every pot outright, so no slice is ever computed and none can be double-sold.
/// @dev DO NOT ADD a stored per-holder collateral quantity: a market whose pots must not be sold leaves `inventoryAsk` off instead.

/// @notice The config cache: built ONCE per entry point and threaded through (Aave's ReserveCache).
struct Cfg {
    MarketParams p;
    uint256 unitScale;
    address positionTitle; // the position collection
    address positionManager; // the ONE position manager, a hub immutable a library cannot read itself
    uint256 policyGas; // the gas a roll-policy ask hands its callee, a hub value a library cannot read itself
}

/// @notice A terminal borrower loan. Loan ids are GLOBAL, so the loan carries its own market id.
/// @dev Callers therefore never pass a market on a loan-keyed call.
struct Loan {
    bytes32 market;
    address borrower; // the position's CURRENT holder; moves on an PositionTitleNFT transfer (retitle)
    uint256 collateralUnits;
    uint256 debt; // quote units; FIXED PREMIUM per admitted draw, nothing accrues, so a loan never drifts underwater by existing
    uint64 openTime;
    uint64 tenor;
    uint64 expiry;
    uint64 closedAt; // 0 IS live; packed beside expiry so the liveness guard warms its own write; also the inventory hold's origin
    uint256 lastFee;
}

/// @notice A resting credit order: a maker's escrowed, expiring pre-commitment to borrow.
/// @notice Ids come from the loan counter, so an id names a loan or an order and never both.
/// @dev `collateralUnits` and `principal` are REMAINING, not original: a partial fill consumes both.
/// @dev The band's LOW end is not held: a fill's low leg is the escrow's REMAINING ratio, at or under the posted low end by the fill slack.
struct Order {
    bytes32 market;
    address maker; // holds title and the debt at every fill
    uint64 tenor;
    bool closed; // a flag, not an instant: no order path reads when it closed
    uint256 collateralUnits; // derived at post from the band's LOW end plus a fill slack; with that end at or under the market's price, a full take is covered
    uint256 principal;
    uint256 minFillPrincipal; // the maker's floor on one fill; equal to principal IS all-or-nothing
    uint256 liqHigh; // the highest trigger a fill may land at
    uint64 expiry; // zero NEVER expires: it reaches the open as a zero deadline, which means off
}

/// @notice Optional borrower open-time bounds; all-zero == off.
struct OpenBounds {
    uint256 minPayout; // floor on an open's payout, and on the NET out of a refinance
    uint256 minBufferWad;
    uint64 deadline;
}

/// @notice `refinanceTo` args, bundled because the flat parameter list does not compile.
/// @dev FIELD ORDER IS THE SELECTOR: the tuple expands into the signature, so a reorder breaks routing.
/// @dev `dst` equal to the loan's own market re-terms the loan there: a new loan, a new id, a fresh term.
struct MigrateArgs {
    uint256 id;
    bytes32 dst;
    uint256 newPrincipal;
    uint64 newTenor;
    OpenBounds bnd;
    uint256 withdrawUnits; // collateral to release from the SUCCESSOR; zero with no `withdrawTo` is a plain refinance
    address withdrawTo; // recipient, the caller's own choice; never the hub or the positionManager, and zero only with zero units
}

/// @notice The market ledger's namespaced home: one member, the id-keyed market mapping.
/// @custom:storage-location erc7201:ace.storage.markets
struct Markets {
    mapping(bytes32 => Market) byId;
}

/// @notice Counts of one lender's settled pots in one quote: those not yet sold, and every one ever settled. Never money beside the pools.
/// @dev Counts and not sums: pots hold different collateral tokens, and a sum that could overflow would revert settlement.
/// @dev ONE WORD, so the second count takes no slot of its own; gas bounds both far below `uint128`, as each raise needs its own loan settled.
struct LenderUnresolved {
    uint128 unsoldPots; // settled loans in this pair whose inventory pot is not yet empty
    uint128 settledPots; // every settlement in this pair that left a pot; it only rises, so a reader can tell a new pot from an old one
}

/// @notice One lender's footprint against one collateral in one quote: principal out at par, and collateral held in unsold pots.
/// @dev SUMS, unlike the pair's counts: every pot this adds holds the one collateral token, so its atoms add.
/// @dev Both are a consumer's cap inputs and never a precondition of any close, so both decrements saturate.
struct LenderCollateral {
    uint256 lent; // drawn at par against this collateral's live claims; summed over collaterals it is the pair's `lent`
    uint256 unsoldUnits; // collateral atoms in this pair's settled pots of it that no buy or redeem has taken yet
}

/// @notice Every lender's position, keyed by the party and the asset rather than by the market.
/// @notice A MARKET NAMES ONE LENDER AND A LENDER MAY RUN MANY, so this is the natural key for a total.
/// @dev The quote is in the key or a lender's USDC and DAI atoms would add; it is what partitions the per-token solvency identity.
/// @dev ISOLATION BETWEEN PARTIES holds because the key IS the party: what pools is one lender's own markets, their own money.
/// @dev ONLY for a quote whose hub balance falls by the hub's own transfer alone: any other fall is paid by whichever party exits last.
/// @custom:storage-location erc7201:ace.storage.lenders
struct Lenders {
    mapping(address lender => mapping(address quote => LenderPools)) pools;
    mapping(address lender => mapping(address quote => LenderUnresolved)) unresolved;
    mapping(address lender => mapping(address quote => mapping(address collateral => LenderCollateral))) byCollateral; // APPENDED, so no member above moves
    mapping(address lender => address policy) rollPolicyOf; // APPENDED: the contract a lender's extensions ask; zero consents to none
}

/// @notice The hub's named storage: the ERC-7201 roots and the accessors over them, one home.
/// @dev Each root is keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff)).
/// @dev An accessor read costs what a state variable read did.
library Storage {
    // erc7201:ace.storage.markets
    bytes32 internal constant MARKETS = 0x4030e81e32d47a504b7bed6a68d304bb4225c2a178237499266df5bb9e2a6400;
    // erc7201:ace.storage.book
    bytes32 internal constant BOOK = 0x5967bc156a810f41a39d095ae4d338aca94a8ee479836018170c1fc64c743a00;
    // erc7201:ace.storage.lenders
    bytes32 internal constant LENDERS = 0x6bd405d8488bcf8aea88b86961ffb3be4d6d2f3e4b297dab758f37bb87f80c00;

    /// @notice The id-keyed market ledger; `byId` is member 0, so the mapping sits AT the root.
    function markets() internal pure returns (mapping(bytes32 => Market) storage $) {
        bytes32 slot = MARKETS;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    /// @notice The loan book; loan ids are GLOBAL.
    function book() internal pure returns (LoanBook storage $) {
        bytes32 slot = BOOK;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    /// @notice Every lender's pooled position, keyed by party and asset.
    function lenders() internal pure returns (Lenders storage $) {
        bytes32 slot = LENDERS;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    /// @notice The pool a market's writes land in: its own lender's, in its own quote.
    /// @dev THE ONE SPELLING, so no write site can key a pool differently from another.
    /// @dev Both fields are write-once and already warm -- every entry point builds `Cfg` from `M.p`.
    function poolOf(MarketParams storage p) internal view returns (LenderPools storage) {
        return lenders().pools[p.lender][p.quote];
    }

    /// @notice The unresolved counts a market's settlements land in, keyed exactly as its pool is.
    function unresolvedOf(MarketParams storage p) internal view returns (LenderUnresolved storage) {
        return lenders().unresolved[p.lender][p.quote];
    }

    /// @notice The per-collateral split a market's writes land in: its pool's key, plus the market's own collateral.
    function byCollateralOf(MarketParams storage p) internal view returns (LenderCollateral storage) {
        return lenders().byCollateral[p.lender][p.quote][p.collateral];
    }
}

/// @notice What a settlement's claims did not get, recorded once at the terminal close.
/// @dev `quoteAtBook` is AT BOOK, so it is a LOWER bound: a pot clearing under the price loses more.
struct Shortfall {
    uint256 units; // collateral atoms the claim did not get, net of any keeper sliver
    uint256 quoteAtBook; // that gap valued at the loan's funding floor
}

/// @notice The market-agnostic loan side. One struct so a library takes ONE storage pointer for it.
/// @custom:storage-location erc7201:ace.storage.book
struct LoanBook {
    uint256 count; // ids for loans and orders alike, only ever pre-incremented: the sole freshness guard for an order id; a loan id also has its title mint
    mapping(uint256 => Loan) loans;
    mapping(uint256 => uint256) principalOf;
    /// @dev CREDIT delegation, not the title's ERC-721 operator: the right to open loans in a borrower's name.
    /// @dev Unrelated grants; they must never share a mapping or a setter.
    mapping(address => mapping(address => bool)) creditOperator;
    mapping(address => uint256) creditOperatorNonce;
    /// @dev The refundable half of the lender fee, withheld at open or paid in by an extension, and settled at close.
    /// @dev Never enters the lender's pools, so a share price never prices revenue the term has not earned.
    mapping(uint256 => uint256) feeEscrowOf;
    mapping(uint256 => mapping(address => uint256)) unitsOwed; // index 6: collateral a claimant may pull
    mapping(uint256 => mapping(address => uint256)) quoteOwed; // index 7: quote a claimant may pull
    mapping(uint256 => Shortfall) shortfallOf; // index 8: written only when a settlement came up short
    mapping(uint256 => Order) orders; // index 9: credit orders on the loans' own counter, so an id names a loan or an order, never both
}
