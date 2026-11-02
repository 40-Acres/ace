// Ace hub -- the loan book's state machine: obligations O13 (settlement is terminal) and O11's freshness guard.
//
// O13: a closed loan never reopens. `closedAt` is 0 while a loan is live and is written once at its close, so
// across any hub call a non-zero `closedAt` must be left exactly as it was.
// O11 (its counter half): every loan and order id is a fresh `++count`, and that counter is the sole freshness
// guard for an order id, so it must never move backwards.
//
// The arithmetic and the external calls are modelled exactly as in HubRevenue.spec, on the same arguments.

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    // NO SUMMARY FOR `mulDivRoundingUp`, AND IT MUST NOT BE GIVEN ONE: via-IR inlines that 4-line wrapper, so a
    // requested summary cannot bind and the prover fails the run outright rather than warning (674 errors, every verb).
    // Its body calls `mulDiv`, which IS summarized, so the 512-bit nonlinear core is still uninterpreted; what runs is
    // `fmDown(a,b,d)` plus a `mulmod` ceil step. That is STRICTLY more faithful than a free `fmUp` ghost, which let the
    // ceiling and the floor drift apart arbitrarily instead of tying ceil to floor plus a remainder bit.
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => ozPlain(x, y, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => ozRounded(x, y, d, r);
    function Mul512.gt512(uint256 a, uint256 b, uint256 c, uint256 d) internal returns (bool) => gt512Ghost(a, b, c, d);

    function closedAtOf(uint256) external returns (uint64) envfree; // AceHarness, through Storage.book()
    function idCount() external returns (uint256) envfree; // AceHarness, through Storage.book()
    function loanMarket(uint256) external returns (bytes32) envfree;
    function marketQuoteOf(bytes32) external returns (address) envfree; // AceHarness
    function orderMarketOf(uint256) external returns (bytes32) envfree; // AceHarness

    // NO `unresolved external` CATCH-ALL THAT CAN SWALLOW HUB LOGIC. The hub's logic lives in external libraries
    // reached by delegatecall; under via-IR their selectors went unresolved, and a NONDET catch-all turned every library
    // call into a no-op -- `finalize` "verified" while Settlement.finalize never ran. MUNGING (scripts/certora-munge.sh)
    // inlines those libraries, so on the munged hub an unresolved call is a TOKEN call SafeERC20's assembly hid. The
    // token-model specs (HubSolvency, HubAttribution) dispatch those to the linked token and prove by `satisfy` that
    // the dispatch really moves it; this spec models no token and needs no catch-all at all.
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

// MULTICALL IS EXCLUDED from both rules: it replays ARBITRARY calldata into the hub by self-delegatecall, which the
// prover cannot resolve, so its counterexample is that havoc rather than a hub path. Nothing is lost: both
// properties COMPOSE over a sequence of verbs, so a batch preserves them whenever every leg does, and every leg is
// one of the verbs checked here.
definition notMulticall(method f) returns bool = f.selector != sig:multicall(bytes[]).selector;

// O13: once closed, a loan's close stands -- never reopened, never re-dated
rule aClosedLoanStaysClosed(env e, method f, calldataarg args, uint256 loanId)
    filtered { f -> !f.isView && f.contract == currentContract && notMulticall(f) }
{
    uint64 closed = closedAtOf(loanId);
    require closed != 0;
    f(e, args);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

// `pushToken` is out of both invariants: its one door is the hub's own self-call, vacuous with the hub barred as caller.
definition freshIdVerb(method f) returns bool = !f.isView && f.contract == currentContract && notMulticall(f)
    && f.selector != sig:pushToken(address,address,uint256).selector;

// MARKET ZERO IS NEVER CREATED: a market id is the hash of its params, and the hub's market cache refuses one with no
// quote. Without it the prover settles a blank loan, whose market is zero, against a market zero it made up.
invariant marketZeroIsNeverCreated()
    marketQuoteOf(to_bytes32(0)) == 0
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// A FRESH ID HAS NEVER CLOSED: an id above the counter was never issued, so it has no market and no close.
// With it, a closed loan sits at or under the counter, so no verb's fresh id can be one (HubLoansCases.spec).
// The market leg is HubAttribution's `aFreshIdHoldsNoLoan`, restated because the close leg leans on it: without it
// the induction step may start from a live loan above the counter, and closing that loan is not a defect.
invariant aFreshIdHasNeverClosed(uint256 id)
    id > idCount() => loanMarket(id) == to_bytes32(0) && closedAtOf(id) == 0
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; requireInvariant marketZeroIsNeverCreated(); } }

// ID ZERO IS NEVER ISSUED: every loan and order id is a `++count`, so zero names neither -- which is what lets the
// open body read a zero predecessor as "pull fresh collateral" (Borrower's NO_PREDECESSOR_LOAN). Without it the prover
// refinances a loan it made up at id zero, and the carried open pulls from the zero payer.
invariant idZeroIsNeverIssued()
    loanMarket(0) == to_bytes32(0) && orderMarketOf(0) == to_bytes32(0)
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// O11: the id counter only moves forward, so no id is ever issued twice
rule theIdCounterNeverMovesBack(env e, method f, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract && notMulticall(f) }
{
    mathint before = idCount();
    f(e, args);
    assert idCount() >= before, "the id counter moved backwards";
}

// THE CLOSED-LOAN LEG of the extension predicate, proven here on the REAL code (this spec summarizes no gate): a closed
// loan never extends. `tryExtend` runs `extend`'s own predicate for any caller, and the leg is its first and reads no
// other argument. HubLeanGates.spec keeps that leg real in `extend`.
rule aClosedLoanNeverExtends(env e, uint256 id, uint256 minBufferWad, bytes data, address caller) {
    require closedAtOf(id) != 0;
    bool ok; bytes4 reason; uint256 fee;
    ok, reason, fee = tryExtend(e, id, minBufferWad, data, caller);
    assert !ok, "the extension predicate admitted a closed loan";
}
