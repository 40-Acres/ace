// Ace hub -- obligation O2: isolation is logical, per market id. No verb moves a market it does not name.
//
// "MOVES" is read through three digests, each a keccak the prover treats as collision-free:
//   `marketDigest(m, anyLoan, index)`: the market's own record -- params, its whole state (cash, the claims pot,
//     counters), one arbitrary loan's claim and inventory pot there, both list lengths and one entry of each list;
//   `loanRecordDigest(id, claimant)`: a loan's entries in the loan book -- the loan record (market, borrower, units,
//     debt, times, fee), its principal at open, its fee escrow, one claimant's owed units and quote, its shortfall;
//   `orderRecordDigest(id)`: an order's whole record.
// So each rule family proves a verb leaves another market's record, its standing loans and its standing orders alone.
//
// OUT OF SCOPE ON PURPOSE, because none is keyed by market:
//   the lender pools, keyed by (lender, quote), pool one lender's markets in that quote (sole tenancy), so a verb on
//     market X legitimately moves a pool that also backs market Y; their conservation belongs to O1/O4;
//   the protocol's revenue pots, keyed by quote in the `Protocol` root, pool every market's cut in that quote, so an
//     accrual in market X legitimately moves the pot market Y's cuts also land in; its conservation belongs to O1 and
//     O20 (revenue leaves only whole), and `sweepRevenue(quote)` names no market;
//   a borrower's credit-operator grants and nonce, keyed by the borrower;
//   the custodian's ledger, another contract: HubCustody.spec ties each live loan's custody to its units, which the
//     loan digest covers.
//
// A parametric rule cannot see a method's arguments, so each verb is called through a DISPATCHER that names its
// market explicitly: by `bytes32 id`, by loan id (`loanMarket(id) == market`) or by order id. The four families:
//   one market named, two markets named, no market named, and createMarket (the new market is its return value).
// A refinance into the loan's own market is the two-market rule with both names equal. `multicall` is excluded as in the
// other hub specs. `everyVerbIsClassified` fails on any hub mutator none of the four names, so a new verb cannot go unproven.
//
// Arithmetic and external calls are modelled as in HubRevenue.spec, on the same arguments, against the MUNGED hub.

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    // NO SUMMARY for mulDivRoundingUp: via-IR inlines it, so one cannot bind and requesting it fails the run. Its body runs on the mulDiv above; see HubLoans.spec.
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => ozPlain(x, y, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => ozRounded(x, y, d, r);
    function Mul512.gt512(uint256 a, uint256 b, uint256 c, uint256 d) internal returns (bool) => gt512Ghost(a, b, c, d);

    function marketDigest(bytes32, uint256, uint256) external returns (bytes32) envfree; // AceHarness
    function loanRecordDigest(uint256, address) external returns (bytes32) envfree; // AceHarness
    function orderRecordDigest(uint256) external returns (bytes32) envfree; // AceHarness
    function openedLoanAt(bytes32, uint256) external returns (uint256) envfree; // AceHarness
    function orderIdAt(bytes32, uint256) external returns (uint256) envfree; // AceHarness
    function orderMarketOf(uint256) external returns (bytes32) envfree; // AceHarness
    function idCount() external returns (uint256) envfree; // AceHarness, through Storage.book()
    function loanMarket(uint256) external returns (bytes32) envfree; // the hub's own view

    // NO `unresolved external` CATCH-ALL on a hub spec: see HubLoans.spec.
}

persistent ghost fmDown(uint256, uint256, uint256) returns uint256;
persistent ghost ozPlain(uint256, uint256, uint256) returns uint256;
persistent ghost ozFloor(uint256, uint256, uint256) returns uint256;
persistent ghost ozCeil(uint256, uint256, uint256) returns uint256;
persistent ghost ozTrunc(uint256, uint256, uint256) returns uint256;
persistent ghost ozExpand(uint256, uint256, uint256) returns uint256;
persistent ghost gt512Ghost(uint256, uint256, uint256, uint256) returns bool;

function ozRounded(uint256 x, uint256 y, uint256 d, Math.Rounding r) returns uint256 {
    if (r == Math.Rounding.Floor) { return ozFloor(x, y, d); }
    if (r == Math.Rounding.Ceil) { return ozCeil(x, y, d); }
    if (r == Math.Rounding.Trunc) { return ozTrunc(x, y, d); }
    return ozExpand(x, y, d);
}

// ---- the verbs that name exactly one market ----

definition byMarketId(method f) returns bool =
    f.selector == sig:deposit(bytes32,uint256).selector
    || f.selector == sig:depositWithPermit2(bytes32,uint256,bytes).selector
    || f.selector == sig:withdraw(bytes32,uint256,address,uint256).selector
    || f.selector == sig:postOrder(bytes32,uint256,uint256,uint256,uint256,uint64,uint64).selector
    || f.selector == sig:open(bytes32,uint256,uint256,uint64,address,AceHarness.OpenBounds).selector
    || f.selector == sig:openWithPermit2(bytes32,uint256,uint256,uint64,address,AceHarness.OpenBounds,bytes).selector;

definition byLoanId(method f) returns bool =
    f.selector == sig:repay(uint256,uint256).selector
    || f.selector == sig:repayWithPermit2(uint256,uint256,bytes).selector
    || f.selector == sig:withdrawCollateral(uint256,uint256,address).selector
    || f.selector == sig:deleverage(uint256,uint256,bytes).selector
    || f.selector == sig:finalize(uint256).selector
    || f.selector == sig:forceClose(uint256).selector
    || f.selector == sig:redeemInKind(uint256,address).selector
    || f.selector == sig:claimOwed(uint256,address).selector
    || f.selector == sig:claimOwed(uint256,address,address).selector
    || f.selector == sig:buyInventory(uint256,uint256,uint256,address).selector
    || f.selector == sig:retitle(uint256,address,address).selector
    || f.selector == sig:extend(uint256,uint256,bytes).selector
    || f.selector == sig:extendWithPermit2(uint256,uint256,bytes,bytes).selector
    || f.selector == sig:drawMore(uint256,uint256,AceHarness.OpenBounds).selector
    || f.selector == sig:addCollateral(uint256,uint256,bytes).selector;

definition byOrderId(method f) returns bool =
    f.selector == sig:fillOrder(uint256,uint256,uint256).selector
    || f.selector == sig:closeOrder(uint256,address).selector;

// call `f` naming `market`; any verb outside the three families above is unreachable here (and fails sanity)
function callNamingOneMarket(env e, method f, bytes32 market) {
    uint256 a; uint256 b; uint256 c; uint256 d; uint64 t; uint64 u;
    address to; address from; bytes data; bytes permit2; AceHarness.OpenBounds bnd;
    uint256 loanId; uint256 orderId;
    if (f.selector == sig:deposit(bytes32,uint256).selector) {
        deposit(e, market, a);
    } else if (f.selector == sig:depositWithPermit2(bytes32,uint256,bytes).selector) {
        depositWithPermit2(e, market, a, data);
    } else if (f.selector == sig:withdraw(bytes32,uint256,address,uint256).selector) {
        withdraw(e, market, a, to, b);
    } else if (f.selector == sig:postOrder(bytes32,uint256,uint256,uint256,uint256,uint64,uint64).selector) {
        postOrder(e, market, a, b, c, d, t, u);
    } else if (f.selector == sig:open(bytes32,uint256,uint256,uint64,address,AceHarness.OpenBounds).selector) {
        open(e, market, a, b, t, to, bnd);
    } else if (f.selector == sig:openWithPermit2(bytes32,uint256,uint256,uint64,address,AceHarness.OpenBounds,bytes).selector) {
        openWithPermit2(e, market, a, b, t, to, bnd, data);
    } else if (byLoanId(f)) {
        require loanMarket(loanId) == market;
        if (f.selector == sig:repay(uint256,uint256).selector) { repay(e, loanId, a); }
        else if (f.selector == sig:repayWithPermit2(uint256,uint256,bytes).selector) { repayWithPermit2(e, loanId, a, data); }
        else if (f.selector == sig:withdrawCollateral(uint256,uint256,address).selector) { withdrawCollateral(e, loanId, a, to); }
        else if (f.selector == sig:deleverage(uint256,uint256,bytes).selector) { deleverage(e, loanId, a, data); }
        else if (f.selector == sig:finalize(uint256).selector) { finalize(e, loanId); }
        else if (f.selector == sig:forceClose(uint256).selector) { forceClose(e, loanId); }
        else if (f.selector == sig:redeemInKind(uint256,address).selector) { redeemInKind(e, loanId, to); }
        else if (f.selector == sig:claimOwed(uint256,address).selector) { claimOwed(e, loanId, to); }
        else if (f.selector == sig:claimOwed(uint256,address,address).selector) { claimOwed(e, loanId, to, from); }
        else if (f.selector == sig:buyInventory(uint256,uint256,uint256,address).selector) { buyInventory(e, loanId, a, b, to); }
        else if (f.selector == sig:retitle(uint256,address,address).selector) { retitle(e, loanId, from, to); }
        else if (f.selector == sig:extend(uint256,uint256,bytes).selector) { extend(e, loanId, a, data); }
        else if (f.selector == sig:drawMore(uint256,uint256,AceHarness.OpenBounds).selector) { drawMore(e, loanId, a, bnd); }
        else if (f.selector == sig:addCollateral(uint256,uint256,bytes).selector) { addCollateral(e, loanId, a, permit2); }
        else { extendWithPermit2(e, loanId, a, data, permit2); }
    } else if (byOrderId(f)) {
        require orderMarketOf(orderId) == market;
        if (f.selector == sig:fillOrder(uint256,uint256,uint256).selector) { fillOrder(e, orderId, a, b); }
        else { closeOrder(e, orderId, to); }
    } else {
        require false;
    }
}

// O2, one market named: every OTHER market's record is untouched
rule aVerbMovesOnlyTheMarketItNames(env e, method f, bytes32 market, bytes32 other, uint256 anyLoan, uint256 index)
    filtered { f -> f.contract == currentContract && (byMarketId(f) || byLoanId(f) || byOrderId(f)) }
{
    require other != market;
    bytes32 before = marketDigest(other, anyLoan, index);
    callNamingOneMarket(e, f, market);
    assert marketDigest(other, anyLoan, index) == before, "a verb moved a market it does not name";
}

// ---- the verbs that name two markets: the loan's own and a destination ----

// `refinanceTo` is the one migration left; with `dst == src` it is the re-term the deleted `refinance` was
rule aMigrationMovesOnlyItsTwoMarkets(env e, AceHarness.MigrateArgs m, bytes32 other, uint256 anyLoan, uint256 index) {
    require other != loanMarket(m.id) && other != m.dst;
    bytes32 before = marketDigest(other, anyLoan, index);
    refinanceTo(e, m);
    assert marketDigest(other, anyLoan, index) == before, "a migration moved a third market";
}

// ---- the verbs that name no market, and createMarket ----

// `setRollPolicy` writes the caller's lender entry, which no market record holds; `sweepRevenue` and `setProtocolShareBps`
// write the `Protocol` root, keyed by quote and hub-wide
definition namesNoMarket(method f) returns bool =
    f.selector == sig:collect(address,address).selector
    || f.selector == sig:setCreditOperator(address,bool).selector
    || f.selector == sig:setCreditOperatorWithSig(address,address,bool,uint256,uint256,bytes).selector
    || f.selector == sig:setRollPolicy(address).selector
    || f.selector == sig:sweepRevenue(address).selector
    || f.selector == sig:setProtocolShareBps(uint256).selector
    || f.selector == sig:pushToken(address,address,uint256).selector;

rule aVerbNamingNoMarketMovesNone(env e, method f, calldataarg args, bytes32 any, uint256 anyLoan, uint256 index)
    filtered { f -> f.contract == currentContract && namesNoMarket(f) }
{
    bytes32 before = marketDigest(any, anyLoan, index);
    f(e, args);
    assert marketDigest(any, anyLoan, index) == before, "a verb that names no market moved one";
}

rule creatingAMarketMovesNoOther(env e, calldataarg args, bytes32 other, uint256 anyLoan, uint256 index) {
    bytes32 before = marketDigest(other, anyLoan, index);
    bytes32 created = createMarket(e, args);
    require created != other;
    assert marketDigest(other, anyLoan, index) == before, "creating a market moved an existing one";
}

// ---- THE LOAN BOOK: another market's standing loans and orders ----
//
// Loans and orders take separate rules: one premise each. A rule needing both would only check a market holding both,
// so the loans of a market with no orders would go unchecked.
//
// A STANDING loan or order of `m`: one that existed before the call. Both premises are invariants proven elsewhere:
//   `m != 0`: market zero is never created (HubLoans.spec `marketZeroIsNeverCreated`), so no loan or order names it;
//   `id <= idCount()`: an id above the counter holds no loan (HubAttribution.spec `aFreshIdHoldsNoLoan`) and no order
//     (HubCustody.spec `aFreshIdHoldsNoCustody`). A call that issues an id writes that fresh slot, which the prover
//     would otherwise start holding another market's loan.
// The no-market verbs and createMarket issue no id, so their rules take ANY id.

function requireStandingLoanOf(uint256 id, bytes32 m) {
    require m != to_bytes32(0);
    require loanMarket(id) == m;
    require id <= idCount();
}

function requireStandingOrderOf(uint256 id, bytes32 m) {
    require m != to_bytes32(0);
    require orderMarketOf(id) == m;
    require id <= idCount();
}

rule aVerbLeavesAnotherMarketsLoansAlone(env e, method f, bytes32 market, bytes32 other, uint256 id, address claimant)
    filtered { f -> f.contract == currentContract && (byMarketId(f) || byLoanId(f) || byOrderId(f)) }
{
    require other != market;
    requireStandingLoanOf(id, other);
    bytes32 before = loanRecordDigest(id, claimant);
    callNamingOneMarket(e, f, market);
    assert loanRecordDigest(id, claimant) == before, "a verb moved a loan of a market it does not name";
}

rule aVerbLeavesAnotherMarketsOrdersAlone(env e, method f, bytes32 market, bytes32 other, uint256 id)
    filtered { f -> f.contract == currentContract && (byMarketId(f) || byLoanId(f) || byOrderId(f)) }
{
    require other != market;
    requireStandingOrderOf(id, other);
    bytes32 before = orderRecordDigest(id);
    callNamingOneMarket(e, f, market);
    assert orderRecordDigest(id) == before, "a verb moved an order of a market it does not name";
}

rule aMigrationLeavesAThirdMarketsLoansAlone(env e, AceHarness.MigrateArgs m, bytes32 other, uint256 id, address claimant) {
    require other != loanMarket(m.id) && other != m.dst;
    requireStandingLoanOf(id, other);
    bytes32 before = loanRecordDigest(id, claimant);
    refinanceTo(e, m);
    assert loanRecordDigest(id, claimant) == before, "a migration moved a third market's loan";
}

rule aMigrationLeavesAThirdMarketsOrdersAlone(env e, AceHarness.MigrateArgs m, bytes32 other, uint256 id) {
    require other != loanMarket(m.id) && other != m.dst;
    requireStandingOrderOf(id, other);
    bytes32 before = orderRecordDigest(id);
    refinanceTo(e, m);
    assert orderRecordDigest(id) == before, "a migration moved a third market's order";
}

rule aVerbNamingNoMarketMovesNoLoan(env e, method f, calldataarg args, uint256 id, address claimant)
    filtered { f -> f.contract == currentContract && namesNoMarket(f) }
{
    bytes32 before = loanRecordDigest(id, claimant);
    f(e, args);
    assert loanRecordDigest(id, claimant) == before, "a verb that names no market moved a loan";
}

rule aVerbNamingNoMarketMovesNoOrder(env e, method f, calldataarg args, uint256 id)
    filtered { f -> f.contract == currentContract && namesNoMarket(f) }
{
    bytes32 before = orderRecordDigest(id);
    f(e, args);
    assert orderRecordDigest(id) == before, "a verb that names no market moved an order";
}

rule creatingAMarketMovesNoLoan(env e, calldataarg args, uint256 id, address claimant) {
    bytes32 before = loanRecordDigest(id, claimant);
    createMarket(e, args);
    assert loanRecordDigest(id, claimant) == before, "creating a market moved a loan";
}

rule creatingAMarketMovesNoOrder(env e, calldataarg args, uint256 id) {
    bytes32 before = orderRecordDigest(id);
    createMarket(e, args);
    assert orderRecordDigest(id) == before, "creating a market moved an order";
}

// ---- WITNESSES: each new read sees live storage, so no rule above passes on a digest that reads nothing ----

rule aRepayMovesItsOwnLoansRecord(env e, uint256 id, uint256 amount, address claimant) {
    bytes32 before = loanRecordDigest(id, claimant);
    repay(e, id, amount);
    satisfy loanRecordDigest(id, claimant) != before;
}

rule aCloseMovesItsOwnOrdersRecord(env e, uint256 id, address to) {
    bytes32 before = orderRecordDigest(id);
    closeOrder(e, id, to);
    satisfy orderRecordDigest(id) != before;
}

// the list reads are `_entryAt`, the one read the digest makes
rule anOpenWritesAnEntryOfItsOwnList(env e, bytes32 m, uint256 a, uint256 b, uint64 t, address to, AceHarness.OpenBounds bnd, uint256 index) {
    uint256 before = openedLoanAt(m, index);
    open(e, m, a, b, t, to, bnd);
    satisfy openedLoanAt(m, index) != before;
}

rule aPostWritesAnEntryOfItsOwnList(env e, bytes32 m, uint256 a, uint256 b, uint256 c, uint256 d, uint64 t, uint64 u, uint256 index) {
    uint256 before = orderIdAt(m, index);
    postOrder(e, m, a, b, c, d, t, u);
    satisfy orderIdAt(m, index) != before;
}

// ---- EVERY VERB IS CLASSIFIED: the rules above list their verbs by selector ----

// A verb added later, named in no family, would fall outside every rule above and go UNPROVEN with no warning: the
// one-market rules' filter drops it before sanity runs. This rule runs on every hub mutator, calls nothing, and fails
// on any selector no family names. `multicall` is classified as the exclusion the header states.
definition isClassified(method f) returns bool =
    byMarketId(f) || byLoanId(f) || byOrderId(f) || namesNoMarket(f)
    || f.selector == sig:createMarket(AceHarness.MarketParams).selector
    || f.selector == sig:refinanceTo(AceHarness.MigrateArgs).selector
    || f.selector == sig:multicall(bytes[]).selector;

rule everyVerbIsClassified(method f) filtered { f -> !f.isView && f.contract == currentContract } {
    assert isClassified(f), "a hub mutator is in none of the isolation rules' families, so no rule above proves it";
}
