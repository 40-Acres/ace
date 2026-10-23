// Ace hub -- obligation O2: isolation is logical, per market id. No verb moves a market it does not name.
//
// "MOVES" means `marketDigest(m, anyLoan)`: a keccak over the market's params, its whole state (cash, the three pots,
// rollReserve, counters), one arbitrary loan's claim and inventory pot there, and both append-only list lengths.
// The prover treats keccak as collision-free, so an unchanged digest is an unchanged MARKET RECORD -- and nothing
// more. THE LOAN BOOK IS NOT IN IT: another market's loans (debt, units, borrower), fee escrows, auto policies,
// owed claims and orders, and the CONTENTS of its two lists, can move without moving the digest. So this proves a
// verb leaves every other market's own record alone, not that it leaves that market's loans alone.
//
// LENDER POOLS ARE OUT OF SCOPE ON PURPOSE. They are keyed by (lender, quote) and pool one lender's markets in that
// quote (sole tenancy), so a verb on market X legitimately moves a pool that also backs market Y. O2 is about
// markets, and the pools' own conservation belongs to O1/O4.
//
// A parametric rule cannot see a method's arguments, so each verb is called through a DISPATCHER that names its
// market explicitly: by `bytes32 id`, by loan id (`loanMarket(id) == market`) or by order id. The four rules:
//   one market named, two markets named, no market named, and createMarket (the new market is its return value).
// `refinanceByPolicies` names one market per element of an array and is the loop of `refinanceByPolicy`, so it is
// covered by composition and excluded; `multicall` is excluded as in the other hub specs.
//
// Arithmetic and external calls are modelled as in HubRevenue.spec, on the same arguments, against the MUNGED hub.

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    function FullMath.mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmUp(a, b, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => ozPlain(x, y, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => ozRounded(x, y, d, r);
    function Mul512.gt512(uint256 a, uint256 b, uint256 c, uint256 d) internal returns (bool) => gt512Ghost(a, b, c, d);

    function marketDigest(bytes32, uint256) external returns (bytes32) envfree; // AceHarness
    function orderMarketOf(uint256) external returns (bytes32) envfree; // AceHarness
    function loanMarket(uint256) external returns (bytes32) envfree; // the hub's own view

    // NO `unresolved external` CATCH-ALL on a hub spec: see HubLoans.spec.
}

persistent ghost fmDown(uint256, uint256, uint256) returns uint256;
persistent ghost fmUp(uint256, uint256, uint256) returns uint256;
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
    || f.selector == sig:sweepRevenue(bytes32).selector
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
    || f.selector == sig:settleExpired(uint256).selector
    || f.selector == sig:redeemInKind(uint256,address).selector
    || f.selector == sig:claimOwed(uint256,address).selector
    || f.selector == sig:claimOwed(uint256,address,address).selector
    || f.selector == sig:buyInventory(uint256,uint256,uint256,address).selector
    || f.selector == sig:retitle(uint256,address,address).selector
    || f.selector == sig:setAutoRefinance(uint256,uint64,uint16,uint16).selector
    || f.selector == sig:refinance(uint256,uint256,uint64,AceHarness.OpenBounds).selector
    || f.selector == sig:refinanceByPolicy(uint256).selector;

definition byOrderId(method f) returns bool =
    f.selector == sig:fillOrder(uint256,uint256,uint256).selector
    || f.selector == sig:closeOrder(uint256,address).selector;

// call `f` naming `market`; any verb outside the three families above is unreachable here (and fails sanity)
function callNamingOneMarket(env e, method f, bytes32 market) {
    uint256 a; uint256 b; uint256 c; uint256 d; uint64 t; uint64 u; uint16 x; uint16 y;
    address to; address from; bytes data; AceHarness.OpenBounds bnd;
    uint256 loanId; uint256 orderId;
    if (f.selector == sig:deposit(bytes32,uint256).selector) {
        deposit(e, market, a);
    } else if (f.selector == sig:depositWithPermit2(bytes32,uint256,bytes).selector) {
        depositWithPermit2(e, market, a, data);
    } else if (f.selector == sig:withdraw(bytes32,uint256,address,uint256).selector) {
        withdraw(e, market, a, to, b);
    } else if (f.selector == sig:sweepRevenue(bytes32).selector) {
        sweepRevenue(e, market);
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
        else if (f.selector == sig:settleExpired(uint256).selector) { settleExpired(e, loanId); }
        else if (f.selector == sig:redeemInKind(uint256,address).selector) { redeemInKind(e, loanId, to); }
        else if (f.selector == sig:claimOwed(uint256,address).selector) { claimOwed(e, loanId, to); }
        else if (f.selector == sig:claimOwed(uint256,address,address).selector) { claimOwed(e, loanId, to, from); }
        else if (f.selector == sig:buyInventory(uint256,uint256,uint256,address).selector) { buyInventory(e, loanId, a, b, to); }
        else if (f.selector == sig:retitle(uint256,address,address).selector) { retitle(e, loanId, from, to); }
        else if (f.selector == sig:setAutoRefinance(uint256,uint64,uint16,uint16).selector) { setAutoRefinance(e, loanId, t, x, y); }
        else if (f.selector == sig:refinance(uint256,uint256,uint64,AceHarness.OpenBounds).selector) { refinance(e, loanId, a, t, bnd); }
        else { refinanceByPolicy(e, loanId); }
    } else if (byOrderId(f)) {
        require orderMarketOf(orderId) == market;
        if (f.selector == sig:fillOrder(uint256,uint256,uint256).selector) { fillOrder(e, orderId, a, b); }
        else { closeOrder(e, orderId, to); }
    } else {
        require false;
    }
}

// O2, one market named: every OTHER market is untouched
rule aVerbMovesOnlyTheMarketItNames(env e, method f, bytes32 market, bytes32 other, uint256 anyLoan)
    filtered { f -> f.contract == currentContract && (byMarketId(f) || byLoanId(f) || byOrderId(f)) }
{
    require other != market;
    bytes32 before = marketDigest(other, anyLoan);
    callNamingOneMarket(e, f, market);
    assert marketDigest(other, anyLoan) == before, "a verb moved a market it does not name";
}

// ---- the verbs that name two markets: the loan's own and a destination ----

rule aMigrationMovesOnlyItsTwoMarkets(env e, method f, bytes32 src, bytes32 dst, bytes32 other, uint256 anyLoan)
    filtered {
        f -> f.contract == currentContract && (
            f.selector == sig:refinanceTo(AceHarness.MigrateArgs).selector
            || f.selector == sig:refinanceByPolicyTo(uint256,bytes32).selector
        )
    }
{
    require other != src && other != dst;
    bytes32 before = marketDigest(other, anyLoan);
    if (f.selector == sig:refinanceTo(AceHarness.MigrateArgs).selector) {
        AceHarness.MigrateArgs m;
        require m.dst == dst && loanMarket(m.id) == src;
        refinanceTo(e, m);
    } else {
        uint256 loanId;
        require loanMarket(loanId) == src;
        refinanceByPolicyTo(e, loanId, dst);
    }
    assert marketDigest(other, anyLoan) == before, "a migration moved a third market";
}

// ---- the verbs that name no market, and createMarket ----

definition namesNoMarket(method f) returns bool =
    f.selector == sig:collect(address,address).selector
    || f.selector == sig:setCreditOperator(address,bool).selector
    || f.selector == sig:setCreditOperatorWithSig(address,address,bool,uint256,uint256,bytes).selector
    || f.selector == sig:pushToken(address,address,uint256).selector;

rule aVerbNamingNoMarketMovesNone(env e, method f, calldataarg args, bytes32 any, uint256 anyLoan)
    filtered { f -> f.contract == currentContract && namesNoMarket(f) }
{
    bytes32 before = marketDigest(any, anyLoan);
    f(e, args);
    assert marketDigest(any, anyLoan) == before, "a verb that names no market moved one";
}

rule creatingAMarketMovesNoOther(env e, calldataarg args, bytes32 other, uint256 anyLoan) {
    bytes32 before = marketDigest(other, anyLoan);
    bytes32 created = createMarket(e, args);
    require created != other;
    assert marketDigest(other, anyLoan) == before, "creating a market moved an existing one";
}
