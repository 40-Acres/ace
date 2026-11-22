// Ace.extend, refinanceTo's claim reuse and its refusal from expiry, and forceClose -- obligations O72, O72b and O72c at
// the hub's own door, and O50's claim leg at the one settle verb.
//
// An extension lengthens a live loan IN PLACE: the same id and title, its term re-anchored at now and run for the loan's
// own tenor again, so the new expiry is `now + tenor`, at most `now + maxTenor`, and the tenor never moves. It lands only
// strictly inside the term: at `expiry - tenor` it adds no time and refuses, and from the expiry second it refuses
// `LoanMatured`. Its fee is `originationFee(debt, newExpiry - expiry, ...)` at the hub's live origination share, the fee on
// the time it adds, and the CALLER,
// whoever it is, pays it in cash: the protocol cut to revenue, the tick cut to `owed`, the escrow cut funded. A caller who
// is neither the holder nor an operator of its title lands only with the record at or above the price, the trigger out of
// the deleverage band, and at most a quarter of the tenor left. A top-up (`drawMore`) moves the debt and the claim by
// exactly its amount and re-anchors the fee schedule at now, so `openTime` is the schedule's start, and `addCollateral`
// moves the lot alone. First the funded escrow
// earns on the old schedule, its earned part into `owed`. The debt and the claim never move, and resting cash never funds
// an extension. The market lender's roll policy is asked LAST, through one gas-capped STATICCALL, before any write; no
// policy, or any answer but its selector, refuses. `refinanceTo` refuses from the expiry second before any write or ask;
// before it, it reuses the retiring claim only inside the loan's own market on that lender's yes, and otherwise draws its
// whole principal from resting cash: any other market, the same lender's included, is never asked about. `forceClose`
// settles at tenor and asks no policy.
//
// WHY AT THE VERB: an extension has no smaller callable unit. `Borrower.extend` is the whole body, and the munged hub
// inlines it into `Ace.extend`, which is what these rules call; `refinanceTo` and `forceClose` are likewise their verbs.
// `extendWithPermit2` runs `extend`'s body (`Ace._extend`) and differs only in the pull after every write.
//
// WHAT IS SUMMARIZED, and why each admits every real behaviour:
//   - each `FullMath` mulDiv the prover can locate is an uninterpreted, deterministic function. The fee rule compares the
//     verb against `originationFeeOf`, which runs the same `LoanMath.originationFee` on the same summary.
//   - the record and admission legs (`tryRecordState`, `_admissibleLeg`) and the open path's gates and health arithmetic,
//     as HubLeanGates.spec does: `view` or `pure`, so "returns anything, never reverts" is a superset. The record's answer
//     is RECORDED into persistent ghosts as it is returned, still unconstrained, so a rule can read the cap the verb saw.
//     The extension's matured, no-time and borrower-rule legs and the non-holder rule stay REAL, as do `_preChecks`,
//     `_payoutCheck`, `_askPolicy`'s zero-policy test and the refinance gate.
//   - THE HOLDER TEST, `Borrower.actsForHolder`, asks the title collection, which is NONDET here; it is summarized to an
//     uninterpreted ghost of (loan, holder, caller), so a rule names which callers count as the holder. If via-IR inlines
//     it the summary fails to bind and the non-holder rule FAILS rather than passes: read the run's "unable to locate" lines.
//   - THE POLICY ASK, `Probe.askBool`: a STATICCALL writes nothing, so answering anything is a superset. Its summary records
//     that it ran, whom it asked, with what budget, for which word, and the answer. It never reverts, where the real one
//     reverts `PolicyGasShort` on a short limit, which only adds paths. If via-IR inlines it, the rules reading the record
//     FAIL rather than pass: read the run's "unable to locate" lines.
//   - the custodian and the title collection, whose calls move ledgers and mint, never quote (NONDET).
//   - NOTHING ELSE: no summary on `respread` or any small function, since via-IR can eliminate one and the summary then
//     fails to bind (verify/README.md).
// THE QUOTE MOVES FOR REAL, as in HubSolvency.spec: the token is a linked DummyERC20 and every hub transfer of it runs its
// code; `anExtensionCanPullItsFee` and `aRefinanceCanPayOut` prove a pull and a payout move it.
// THE DOMAIN, stated: the quote under proof is not the market's collateral, its record, the custodian or the title
// collection, and the clock is real and past the loan's open.
// NO WRITE BEFORE THE ASK is ExtendAskOrder.spec's, and so is every rule that reads it: its raw store hook needs storage
// splitting off, so it runs in its own conf. Splitting here also needs the hub's two `extsload` views gone, since a raw
// sload turns it off for the whole contract: scripts/certora-munge.sh cuts them from the munged copy.

using DummyERC20 as quoteToken;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    // NO SUMMARY for mulDivRoundingUp: via-IR inlines it, so one cannot bind and requesting it fails the run. Its body runs on the mulDiv above; see HubLoans.spec.

    // the extension's read-only record and admission legs; the record's answer is recorded, unconstrained
    function Borrower.tryRecordState(ExtendHarness.Cfg memory) internal returns (bool, ExtendHarness.RecordState, uint256) => recordSays();
    function Borrower._admissibleLeg(ExtendHarness.Cfg memory, uint256, uint256, uint256, uint256) internal returns (bytes4) => NONDET;
    // the holder test, an uninterpreted ghost: which callers count as the holder is the rule's to name
    function Borrower.actsForHolder(ExtendHarness.Cfg memory, uint256 id, address holder, address caller) internal returns (bool)
        => holderTest(id, holder, caller);
    // the open path's gates and the health arithmetic, as HubLeanGates.spec summarizes them
    function Borrower._gateCheck(ExtendHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._previewFloor(ExtendHarness.Market storage, ExtendHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;
    function Borrower._gate(uint256, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.triggerPrice(ExtendHarness.Loan storage, ExtendHarness.Cfg memory) internal returns (uint256) => NONDET;
    function Borrower.coverageLine(ExtendHarness.Cfg memory, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.persistedPrice(ExtendHarness.Cfg memory) internal returns (uint256) => NONDET;

    // THE POLICY ASK, recorded
    function Probe.askBool(address target, bytes memory data, uint256 gasCap, bytes32 yes) internal returns (bool)
        => askPolicy(target, gasCap, yes);

    // how quote moves, as HubSolvency.spec models it: via-IR keeps safeTransfer's entry, and a call it inlines and hides
    // reaches the token by dispatch when the callee IS the token, and does nothing otherwise
    function SafeERC20.safeTransfer(address token, address to, uint256 value) internal => moveFromHub(token, to, value);
    unresolved external in _._ => DISPATCH [
        quoteToken.transfer(address,uint256),
        quoteToken.transferFrom(address,address,uint256),
        quoteToken.balanceOf(address)
    ] default NONDET;
    // the custodian and the title collection: ledgers and a mint, never quote
    function _.mint(uint256, address) external => NONDET;
    function _.carryOut(uint256, uint256) external => NONDET;
    function _.carryIn(uint256, uint256, uint256) external => NONDET;
    function _.pull(uint256, address, uint256) external => NONDET;
    function _.release(uint256, address, uint256) external => NONDET;
    function _.retireCustody(uint256, uint256) external => NONDET;

    function POSITION_MANAGER() external returns (address) envfree;
    function POSITION_TITLE() external returns (address) envfree;
    function POLICY_GAS() external returns (uint256) envfree;
    function idCount() external returns (uint256) envfree;
    function loanOf(uint256) external returns (bytes32, address, uint256, uint256, uint64) envfree;
    function termOf(uint256) external returns (uint64, uint64, uint64) envfree;
    function loanOpenTime(uint256) external returns (uint64) envfree;
    function loanTenor(uint256) external returns (uint64) envfree;
    function loanExpiry(uint256) external returns (uint64) envfree;
    function lastFeeOf(uint256) external returns (uint256) envfree;
    function claimOf(bytes32, uint256) external returns (uint256) envfree;
    function feeEscrowOf(uint256) external returns (uint256) envfree;
    function creditOperatorOf(address, address) external returns (bool) envfree;
    function marketOf(bytes32) external returns (address, uint256, uint256, uint256) envfree;
    function marketWiringOf(bytes32) external returns (address, address, address) envfree;
    function marketTermsOf(bytes32) external returns (uint64, uint64, uint256) envfree;
    function priceOf(bytes32) external returns (uint256) envfree;
    function bandLevelOf(uint256) external returns (uint256) envfree;
    function originationFeeOf(bytes32, uint256, uint64) external returns (uint256) envfree;
    function drawCountOf(bytes32) external returns (uint64) envfree;
    function poolOf(bytes32) external returns (uint256, uint256, uint256) envfree;
    function rollPolicyOf(address) external returns (address) envfree;
    function policyYes() external returns (bytes32) envfree;
    function protocolCut(uint256) external returns (uint256) envfree;
    function escrowCut(uint256) external returns (uint256) envfree;
    function tickCut(uint256) external returns (uint256) envfree;
    function protocolShareBps() external returns (uint256) envfree;
    function treasuryOf() external returns (address) envfree;
    function quoteToken.balanceOf(address) external returns (uint256) envfree;
}

persistent ghost fmDown(uint256, uint256, uint256) returns uint256;

// which callers the hub counts as a loan's holder: the holder, or an operator of its title, as the collection answers
persistent ghost holderTest(uint256, address, address) returns bool;

// ---- the record's answer, recorded as the verb receives it; every value stays unconstrained, so this is NONDET's superset ----

persistent ghost bool recordRead;
persistent ghost bool recordLive;
persistent ghost uint256 recordCap;

function recordSays() returns (bool, ExtendHarness.RecordState, uint256) {
    bool got;
    ExtendHarness.RecordState s;
    uint256 cap;
    recordRead = got;
    recordLive = s == ExtendHarness.RecordState.Live;
    recordCap = cap;
    return (got, s, cap);
}

function moveFromHub(address token, address to, uint256 value) {
    if (token == quoteToken) {
        env e;
        require e.msg.sender == currentContract && e.msg.value == 0;
        quoteToken.transfer(e, to, value);
    }
}

definition aRealClock(env e) returns bool = e.block.timestamp > 0 && e.block.timestamp < 2^64;

// THE CLOCK PAST THE OPEN, stated: `openTime` is only ever written from `block.timestamp`, and a chain's clock never runs
// backward, so no real call sees `now < openTime`. It enters through `sceneHolds` as domain, as `aRealClock` does.
definition aClockPastTheOpen(env e, uint256 id) returns bool = to_mathint(e.block.timestamp) >= to_mathint(loanOpenTime(id));

// ---- the policy ask, recorded. PERSISTENT, so no havocked call between the ask and the assert can erase it ----

persistent ghost bool asked;
persistent ghost mathint asks;
persistent ghost address askedOf;
persistent ghost uint256 askedGas;
persistent ghost bytes32 askedFor;
persistent ghost bool said;

function askPolicy(address target, uint256 gasCap, bytes32 yes) returns bool {
    bool answer;
    asked = true;
    asks = asks + 1;
    askedOf = target;
    askedGas = gasCap;
    askedFor = yes;
    said = answer;
    return answer;
}

function nothingAskedYet() {
    require !asked && asks == 0;
}

// ---- one-word reads of the harness's views ----

function homeOf(uint256 id) returns bytes32 {
    bytes32 m; address b; uint256 u; uint256 d; uint64 c;
    m, b, u, d, c = loanOf(id);
    return m;
}

function holderOf(uint256 id) returns address {
    bytes32 m; address b; uint256 u; uint256 d; uint64 c;
    m, b, u, d, c = loanOf(id);
    return b;
}

function unitsOf(uint256 id) returns uint256 {
    bytes32 m; address b; uint256 u; uint256 d; uint64 c;
    m, b, u, d, c = loanOf(id);
    return u;
}

function loanDebt(uint256 id) returns uint256 {
    bytes32 m; address b; uint256 u; uint256 d; uint64 c;
    m, b, u, d, c = loanOf(id);
    return d;
}

function closedOf(uint256 id) returns uint64 {
    bytes32 m; address b; uint256 u; uint256 d; uint64 c;
    m, b, u, d, c = loanOf(id);
    return c;
}

function cashIn(bytes32 m) returns uint256 {
    address q; uint256 cash; uint256 rev; uint256 pot;
    q, cash, rev, pot = marketOf(m);
    return cash;
}

function revenueIn(bytes32 m) returns uint256 {
    address q; uint256 cash; uint256 rev; uint256 pot;
    q, cash, rev, pot = marketOf(m);
    return rev;
}

function potIn(bytes32 m) returns uint256 {
    address q; uint256 cash; uint256 rev; uint256 pot;
    q, cash, rev, pot = marketOf(m);
    return pot;
}

function lenderIn(bytes32 m) returns address {
    address col; address rec; address lender;
    col, rec, lender = marketWiringOf(m);
    return lender;
}

function minTenorIn(bytes32 m) returns uint64 {
    uint64 lo; uint64 hi; uint256 floor;
    lo, hi, floor = marketTermsOf(m);
    return lo;
}

function maxTenorIn(bytes32 m) returns uint64 {
    uint64 lo; uint64 hi; uint256 floor;
    lo, hi, floor = marketTermsOf(m);
    return hi;
}

function minPrincipalIn(bytes32 m) returns uint256 {
    uint64 lo; uint64 hi; uint256 floor;
    lo, hi, floor = marketTermsOf(m);
    return floor;
}

function restingIn(bytes32 m) returns uint256 {
    uint256 r; uint256 l; uint256 o;
    r, l, o = poolOf(m);
    return r;
}

function lentIn(bytes32 m) returns uint256 {
    uint256 r; uint256 l; uint256 o;
    r, l, o = poolOf(m);
    return l;
}

function owedIn(bytes32 m) returns uint256 {
    uint256 r; uint256 l; uint256 o;
    r, l, o = poolOf(m);
    return o;
}

// an issued loan's tenor on its market's grid
function onItsGrid(uint256 id) returns bool {
    bytes32 m = homeOf(id);
    return loanTenor(id) >= minTenorIn(m) && loanTenor(id) <= maxTenorIn(m);
}

// ---- the scene ----

// market `m` quotes the token under proof, and none of the contracts it wires is that token; its lender is not the hub
function marketQuotesTheToken(bytes32 m) {
    address q; uint256 cash; uint256 rev; uint256 pot;
    q, cash, rev, pot = marketOf(m);
    address col; address rec; address lender;
    col, rec, lender = marketWiringOf(m);
    require q == quoteToken && col != quoteToken && rec != quoteToken && lender != currentContract;
}

// the deployment facts no line of the verb checks, and a live, issued loan `id` (id zero never is: HubLoans.spec)
function sceneHolds(env e, uint256 id) {
    require e.msg.sender != currentContract && aRealClock(e) && aClockPastTheOpen(e, id);
    require POSITION_MANAGER() != quoteToken && POSITION_TITLE() != quoteToken;
    require POSITION_MANAGER() != currentContract && POSITION_TITLE() != currentContract;
    require id != 0 && homeOf(id) != to_bytes32(0) && closedOf(id) == 0 && to_mathint(id) <= idCount();
    marketQuotesTheToken(homeOf(id));
}

// the id a refinance's successor takes is clean: no market, no close, no escrow (HubSolvency.spec `aFreshIdCarriesNoEscrow`)
function theFreshIdIsClean() {
    uint256 n = require_uint256(idCount() + 1);
    require homeOf(n) == to_bytes32(0) && closedOf(n) == 0 && feeEscrowOf(n) == 0;
}

// O10 of a loan, PROVEN in HubClaims.spec (`aLoanCarriesItsDebtAsItsClaim`): its debt is its claim
function debtIsClaim(uint256 id) returns bool {
    return to_mathint(loanDebt(id)) == to_mathint(claimOf(homeOf(id), id));
}

// ---- I1 and I2: the term ----

// THE HUB'S OWN VERBS, as HubLoans.spec's `freshIdVerb` takes them: a multicall is a sequence of these, so it composes
definition hubVerb(method f) returns bool = !f.isView && f.contract == currentContract
    && f.selector != sig:multicall(bytes[]).selector;

function quoteIn(bytes32 m) returns address {
    address q; uint256 cash; uint256 rev; uint256 pot;
    q, cash, rev, pot = marketOf(m);
    return q;
}

// PROVEN facts the frame rules start from: an issued loan sits at or under the id counter (HubLoans.spec
// `aFreshIdHasNeverClosed`) and in a created market (HubClaims.spec `aLoanSitsInACreatedMarket`, O56)
function anIssuedLoanIsCountedAndCreated(uint256 id) {
    require homeOf(id) != to_bytes32(0) => to_mathint(id) <= idCount() && quoteIn(homeOf(id)) != 0;
}

// THE FOUR VERBS THAT ISSUE A LOAN, each through `_record`, which takes `++count`: so the loan a call issues sits above
// the counter as the call found it, and every loan that already stood sits at or under it
definition issuesALoan(method f) returns bool =
    f.selector == sig:open(bytes32,uint256,uint256,uint64,address,ExtendHarness.OpenBounds).selector
    || f.selector == sig:openWithPermit2(bytes32,uint256,uint256,uint64,address,ExtendHarness.OpenBounds,bytes).selector
    || f.selector == sig:fillOrder(uint256,uint256,uint256).selector
    || f.selector == sig:refinanceTo(ExtendHarness.MigrateArgs).selector;

// I1's statement, shared by the invariant and the two halves of its step on the issuing verbs
definition termWhole(uint256 id) returns bool =
    to_mathint(loanExpiry(id)) - to_mathint(loanTenor(id)) <= to_mathint(loanOpenTime(id))
        && to_mathint(loanOpenTime(id)) <= to_mathint(loanExpiry(id));

// I1: every loan's fee schedule opens inside the last tenor before its expiry, `expiry - tenor <= openTime <= expiry`.
// `_record` writes `openTime + tenor == expiry` at the open and `respread` at an extension; a top-up moves `openTime` to
// now, strictly before expiry, and the clock never runs behind the schedule's start, which is the domain the preserved
// block states. An unissued id reads 0 <= 0 <= 0. The no-time refusal fires exactly when now is `expiry - tenor`, and no
// safety leg rests on I1: the extension checks `newExpiry > expiry` and charges `newExpiry - expiry` directly.
// ON THE FOUR ISSUING VERBS its induction step is the two rules below, one per case of `id` against the counter the call
// found, so together they are that step; the invariant takes every other verb, its base case and the transient reset
invariant theTermIdentityHolds(uint256 id)
    termWhole(id)
    filtered { f -> hubVerb(f) && !issuesALoan(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract && aRealClock(e) && aClockPastTheOpen(e, id);
        }
    }

// I1's step on an issuing verb, for a loan that already stood: the call never breaks its term
rule anIssuingVerbLeavesEveryStandingTermWhole(env e, method f, calldataarg args, uint256 id) filtered { f -> issuesALoan(f) } {
    require e.msg.sender != currentContract && aRealClock(e) && aClockPastTheOpen(e, id);
    require to_mathint(id) <= to_mathint(idCount());
    require termWhole(id);

    f(e, args);

    assert termWhole(id), "an issuing verb broke the term of a loan that already stood";
}

// I1's step on an issuing verb, for the id it may issue: the loan starts with its term whole
rule aLoanIsIssuedWithItsTermWhole(env e, method f, calldataarg args, uint256 id) filtered { f -> issuesALoan(f) } {
    require e.msg.sender != currentContract && aRealClock(e) && aClockPastTheOpen(e, id);
    require to_mathint(id) > to_mathint(idCount());
    require termWhole(id);

    f(e, args);

    assert termWhole(id), "a loan was issued with its term broken";
}

// I2: no verb moves an issued loan's tenor; an extension runs it again, and only the open that issues a loan writes it
rule aLoansTenorNeverMoves(env e, method f, calldataarg args, uint256 id) filtered { f -> hubVerb(f) } {
    require e.msg.sender != currentContract && aRealClock(e);
    require homeOf(id) != to_bytes32(0);
    anIssuedLoanIsCountedAndCreated(id);
    uint64 t0 = loanTenor(id);

    f(e, args);

    assert loanTenor(id) == t0, "a verb moved an issued loan's tenor";
}

// I2: an issued loan's tenor sits on its market's grid, from the open that issued it on, and the grid is write-once.
// The created-market premise is what makes it write-once here: `createMarket` refuses `MarketExists` on a live quote.
// On the four issuing verbs it is the two rules below, split as I1's step is
rule aLoansTenorStaysOnItsGrid(env e, method f, calldataarg args, uint256 id) filtered { f -> hubVerb(f) && !issuesALoan(f) } {
    require e.msg.sender != currentContract && aRealClock(e);
    require homeOf(id) != to_bytes32(0) => onItsGrid(id);
    anIssuedLoanIsCountedAndCreated(id);

    f(e, args);

    assert homeOf(id) != to_bytes32(0) => onItsGrid(id), "an issued loan's tenor left its market's grid";
}

// I2 on an issuing verb, for a loan that already stood: the call never moves it off its market's grid
rule anIssuingVerbKeepsEveryStandingLoanOnItsGrid(env e, method f, calldataarg args, uint256 id) filtered { f -> issuesALoan(f) } {
    require e.msg.sender != currentContract && aRealClock(e);
    require to_mathint(id) <= to_mathint(idCount());
    require homeOf(id) != to_bytes32(0) => onItsGrid(id);
    anIssuedLoanIsCountedAndCreated(id);

    f(e, args);

    assert homeOf(id) != to_bytes32(0) => onItsGrid(id), "an issuing verb moved a standing loan off its market's grid";
}

// I2 on an issuing verb, for the id it may issue: the loan starts on its market's grid
rule aLoanIsIssuedOnItsMarketsGrid(env e, method f, calldataarg args, uint256 id) filtered { f -> issuesALoan(f) } {
    require e.msg.sender != currentContract && aRealClock(e);
    require to_mathint(id) > to_mathint(idCount());
    anIssuedLoanIsCountedAndCreated(id);

    f(e, args);

    assert homeOf(id) != to_bytes32(0) => onItsGrid(id), "a loan was issued off its market's grid";
}

// ---- O72: an extension keeps its loan and runs its own tenor again from now ----

// the same id and title, no successor: market, holder, lot and liveness hold, the id counter stands and the draw counter
// moves once, since the lender's position moved
rule anExtensionKeepsItsLoan(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    bytes32 m = homeOf(id);
    address holder = holderOf(id);
    uint256 units = unitsOf(id);
    mathint count0 = idCount();
    mathint draws0 = drawCountOf(m);

    extend(e, id, minBufferWad, data);

    assert to_mathint(idCount()) == count0, "an extension issued an id";
    assert homeOf(id) == m && holderOf(id) == holder && unitsOf(id) == units && closedOf(id) == 0,
        "an extension moved its loan's market, holder or lot, or closed it";
    assert to_mathint(drawCountOf(m)) == draws0 + 1, "an extension did not bump its market's draw counter once";
}

// THE RE-ANCHOR: the term opens at now and runs the loan's own tenor, unchanged, so the new expiry is now plus that tenor,
// strictly later than the old one and never past now + maxTenor, one minTenor tighter than the deleted stacking cap. Each
// lender yes commits at most one tenor ahead. The grid bound is I2 (`aLoansTenorStaysOnItsGrid`), stated here
rule anExtensionRunsItsOwnTenorFromNow(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    require onItsGrid(id);
    bytes32 m = homeOf(id);
    uint64 open0; uint64 tenor0; uint64 expiry0;
    open0, tenor0, expiry0 = termOf(id);

    extend(e, id, minBufferWad, data);

    uint64 open1; uint64 tenor1; uint64 expiry1;
    open1, tenor1, expiry1 = termOf(id);
    mathint stamp = e.block.timestamp;
    assert to_mathint(open1) == stamp, "an extension did not re-anchor its term at now";
    assert tenor1 == tenor0, "an extension moved the loan's tenor";
    assert to_mathint(expiry1) == stamp + tenor0, "an extension did not run the loan's own tenor from now";
    assert expiry1 > expiry0, "an extension did not make the loan end later";
    assert to_mathint(expiry1) <= stamp + maxTenorIn(m), "an extension committed the lender past one maxTenor";
}

// the same-second and from-expiry refusals, before any write or ask, are ExtendAskOrder.spec's

// the preview agrees: from expiry `tryExtend` answers no, at no fee
rule thePreviewRefusesFromExpiry(env e, uint256 id, uint256 minBufferWad, bytes data, address caller) {
    sceneHolds(e, id);
    require to_mathint(e.block.timestamp) >= to_mathint(loanExpiry(id));

    bool ok; bytes4 why; uint256 fee;
    ok, why, fee = tryExtend(e, id, minBufferWad, data, caller);

    assert !ok && fee == 0, "the preview admitted a matured loan's extension";
}

// THE FEE IS THE TIME ADDED: the origination formula on the debt for exactly `newExpiry - expiry`, pinning its argument
rule anExtensionChargesTheTimeAdded(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    bytes32 m = homeOf(id);
    uint256 debt0 = loanDebt(id);
    mathint expiry0 = loanExpiry(id);

    uint256 fee = extend(e, id, minBufferWad, data);

    uint64 added = require_uint64(loanExpiry(id) - expiry0);
    assert fee == originationFeeOf(m, debt0, added), "an extension charged other than the fee on the time it added";
}

// THE CALLER: anyone may extend. One who is neither the holder nor an operator of its title lands only with the record
// read and at or above the market's price, the record at or above the band's level, and at most a quarter of the tenor
// left; a credit grant makes no holder. The holder and its operators meet only the legs every caller meets
rule aNonHolderExtendsOnlyAtPriceOutsideTheBand(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    bool holderLike = holderTest(id, holderOf(id), e.msg.sender);
    mathint left = loanExpiry(id) - e.block.timestamp;
    mathint tenor = loanTenor(id);
    uint256 price = priceOf(homeOf(id));
    uint256 bandLevel = bandLevelOf(id);

    extend(e, id, minBufferWad, data);

    assert !holderLike => recordRead && (recordLive => recordCap >= price), "a non-holder extended under the market's price";
    assert !holderLike => (recordLive => recordCap >= bandLevel), "a non-holder extended a loan the deleverage band admits";
    assert !holderLike => 4 * left <= tenor, "a non-holder extended before the term's last quarter";
}

// ---- O72: the accounting ----

// the caller pays the fee in. The protocol cut reaches revenue and the lender cut `owed` plus the funded escrow; the debt,
// the claim and `lent` hold; resting cash, the lender's resting pool and the claims pot hold
rule anExtensionBooksItsFeeInCash(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    bytes32 m = homeOf(id);
    mathint debt0 = loanDebt(id);
    mathint claim0 = claimOf(m, id);
    mathint esc0 = feeEscrowOf(id);
    mathint cash0 = cashIn(m);
    mathint rev0 = revenueIn(m);
    mathint pot0 = potIn(m);
    mathint resting0 = restingIn(m);
    mathint lent0 = lentIn(m);
    mathint owed0 = owedIn(m);
    mathint hub0 = quoteToken.balanceOf(currentContract);
    mathint payer0 = quoteToken.balanceOf(e.msg.sender);

    uint256 fee = extend(e, id, minBufferWad, data);

    assert to_mathint(quoteToken.balanceOf(currentContract)) == hub0 + fee, "an extension did not take its fee in";
    assert to_mathint(quoteToken.balanceOf(e.msg.sender)) == payer0 - fee, "an extension took its fee from someone else";
    assert to_mathint(loanDebt(id)) == debt0 && to_mathint(claimOf(m, id)) == claim0, "an extension moved the debt or the claim";
    assert to_mathint(lentIn(m)) == lent0, "an extension moved lent";
    assert to_mathint(revenueIn(m)) == rev0 + protocolCut(fee), "an extension's protocol cut did not reach revenue";
    assert owedIn(m) + feeEscrowOf(id) == owed0 + esc0 + tickCut(fee) + escrowCut(fee),
        "an extension's lender cut did not reach owed and the escrow whole";
    assert feeEscrowOf(id) >= escrowCut(fee), "an extension did not fund its escrow cut";
    assert to_mathint(cashIn(m)) == cash0 && to_mathint(restingIn(m)) == resting0 && to_mathint(potIn(m)) == pot0,
        "an extension drew resting cash or credited a claimant";
}

// O1 at the verb: the booked pots move by exactly the hub's quote
rule anExtensionConservesTheBookedPots(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    bytes32 m = homeOf(id);
    mathint booked0 = cashIn(m) + revenueIn(m) + potIn(m) + owedIn(m) + feeEscrowOf(id);
    mathint hub0 = quoteToken.balanceOf(currentContract);

    extend(e, id, minBufferWad, data);

    mathint booked1 = cashIn(m) + revenueIn(m) + potIn(m) + owedIn(m) + feeEscrowOf(id);
    assert booked1 - booked0 == quoteToken.balanceOf(currentContract) - hub0, "an extension moved booked quote it did not hold";
}

// ---- O72c: no extension moves the debt, and whoever extends pays its own fee ----

rule anExtensionNeverMovesTheDebt(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    bytes32 m = homeOf(id);
    mathint debt0 = loanDebt(id);
    mathint claim0 = claimOf(m, id);

    extend(e, id, minBufferWad, data);

    assert to_mathint(loanDebt(id)) == debt0, "an extension moved the debt";
    assert to_mathint(claimOf(m, id)) == claim0, "an extension moved the claim";
}

// whoever extends for a holder pays the fee itself, and the holder's quote never moves: a stranger, an operator, a lender
rule theCallerPaysItsOwnFee(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    address holder = holderOf(id);
    require e.msg.sender != holder && holder != currentContract;
    mathint holder0 = quoteToken.balanceOf(holder);
    mathint payer0 = quoteToken.balanceOf(e.msg.sender);

    uint256 fee = extend(e, id, minBufferWad, data);

    assert to_mathint(quoteToken.balanceOf(holder)) == holder0, "another caller's extension moved the holder's quote";
    assert to_mathint(quoteToken.balanceOf(e.msg.sender)) == payer0 - fee, "another caller's extension was not paid by that caller";
}

// ---- the top-up and the add: what each moves, and nothing else ----

// A TOP-UP moves the debt and the claim by exactly its amount and re-anchors the fee schedule at now; the expiry, the
// tenor, the market, the holder and the lot hold, and the claim stays live, so the funding floor, the market's price,
// never moves. No id is issued. The rail is genesis's: `createMarket` refuses `minPrincipal < 2` and the params are
// write-once, so the top-up's `minPrincipal` floor never admits a zero amount (without it, a zero top-up in a market with
// no floor left a zero claim at zero)
rule aTopUpMovesTheDebtAndTheClaimByExactlyTheAmount(env e, uint256 id, uint256 amount, ExtendHarness.OpenBounds bnd) {
    sceneHolds(e, id);
    bytes32 m = homeOf(id);
    require minPrincipalIn(m) >= 2;
    address holder = holderOf(id);
    uint256 units = unitsOf(id);
    mathint debt0 = loanDebt(id);
    mathint claim0 = claimOf(m, id);
    uint64 tenor0 = loanTenor(id);
    uint64 expiry0 = loanExpiry(id);
    mathint count0 = idCount();

    drawMore(e, id, amount, bnd);

    assert to_mathint(loanDebt(id)) == debt0 + amount && to_mathint(claimOf(m, id)) == claim0 + amount,
        "a top-up moved the debt or the claim by other than its amount";
    assert loanTenor(id) == tenor0 && loanExpiry(id) == expiry0, "a top-up moved the loan's tenor or expiry";
    assert to_mathint(loanOpenTime(id)) == to_mathint(e.block.timestamp), "a top-up did not re-anchor the fee schedule at now";
    assert homeOf(id) == m && holderOf(id) == holder && unitsOf(id) == units && closedOf(id) == 0,
        "a top-up moved the loan's market, holder or lot, or closed it";
    assert claimOf(m, id) != 0 && to_mathint(idCount()) == count0, "a top-up retired the claim or issued an id";
}

// AN ADD moves the lot alone: units rise by exactly the add, and the debt, the claim, the term, the escrow and every
// booked pot hold
rule anAddMovesOnlyTheUnits(env e, uint256 id, uint256 units, bytes permit2) {
    sceneHolds(e, id);
    bytes32 m = homeOf(id);
    address holder = holderOf(id);
    mathint units0 = unitsOf(id);
    mathint debt0 = loanDebt(id);
    mathint claim0 = claimOf(m, id);
    mathint esc0 = feeEscrowOf(id);
    uint64 open0; uint64 tenor0; uint64 expiry0;
    open0, tenor0, expiry0 = termOf(id);
    mathint cash0 = cashIn(m);
    mathint rev0 = revenueIn(m);
    mathint pot0 = potIn(m);
    mathint owed0 = owedIn(m);
    mathint resting0 = restingIn(m);
    mathint lent0 = lentIn(m);

    addCollateral(e, id, units, permit2);

    assert to_mathint(unitsOf(id)) == units0 + units, "an add moved the lot by other than the add";
    assert to_mathint(loanDebt(id)) == debt0 && to_mathint(claimOf(m, id)) == claim0 && to_mathint(feeEscrowOf(id)) == esc0,
        "an add moved the debt, the claim or the escrow";
    uint64 open1; uint64 tenor1; uint64 expiry1;
    open1, tenor1, expiry1 = termOf(id);
    assert open1 == open0 && tenor1 == tenor0 && expiry1 == expiry0, "an add moved the term";
    assert homeOf(id) == m && holderOf(id) == holder && closedOf(id) == 0, "an add moved the market or the holder, or closed the loan";
    assert to_mathint(cashIn(m)) == cash0 && to_mathint(revenueIn(m)) == rev0 && to_mathint(potIn(m)) == pot0,
        "an add moved resting cash, revenue or the claims pot";
    assert to_mathint(owedIn(m)) == owed0 && to_mathint(restingIn(m)) == resting0 && to_mathint(lentIn(m)) == lent0,
        "an add moved the lender's pools";
}

// ---- O72b: the lender's yes, asked last, before any write ----

// an extension lands only on its lender's policy's yes: asked once, of the policy the market lender stored, with
// POLICY_GAS, and for the policy's own selector
rule anExtensionLandsOnlyOnItsLendersYes(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    nothingAskedYet();
    address policy = rollPolicyOf(lenderIn(homeOf(id)));

    extend(e, id, minBufferWad, data);

    assert asked && said, "an extension landed without its lender's policy saying yes";
    assert asks == 1, "an extension asked its lender's policy other than once";
    assert askedOf == policy && policy != 0, "an extension asked a contract other than the lender's stored policy";
    assert askedGas == POLICY_GAS(), "an extension handed its policy a budget other than POLICY_GAS";
    assert askedFor == policyYes(), "an extension took a word other than the policy's selector for a yes";
}

// NO WRITE BEFORE THE ANSWER, its store-hook witness, the matured refinance's refusal and the refinance's claim reuse on its
// lender's yes are ExtendAskOrder.spec's

// ---- refinanceTo: floored at the destination's minPrincipal, and its home leg's accounting ----

// O55: every refinance is floored at the destination's minPrincipal: the successor is a birth
rule aRefinanceIsFlooredAtMinPrincipal(env e, ExtendHarness.MigrateArgs a) {
    sceneHolds(e, a.id);
    refinanceTo(e, a);
    assert a.newPrincipal >= minPrincipalIn(a.dst), "a refinance opened a successor under minPrincipal";
}

// a home refinance books its own protocol cut to revenue and funds its successor's escrow, retires the old claim, and its
// successor carries its debt as its claim
rule aHomeRefinanceBooksItsOwnFee(env e, ExtendHarness.MigrateArgs a) {
    sceneHolds(e, a.id);
    theFreshIdIsClean();
    bytes32 m = homeOf(a.id);
    require a.dst == m;
    mathint rev0 = revenueIn(m);

    uint256 n = refinanceTo(e, a);

    uint256 fee = lastFeeOf(n);
    assert to_mathint(revenueIn(m)) == rev0 + protocolCut(fee), "a refinance did not book exactly its own protocol cut";
    assert feeEscrowOf(n) == escrowCut(fee), "a refinance did not fund its successor's escrow";
    assert claimOf(m, a.id) == 0, "a refinance left the retiring loan a claim";
    assert homeOf(n) == m && loanDebt(n) == claimOf(m, n), "a refinance's successor does not carry its debt as its claim";
}

// O1 at the verb: across a home refinance the booked pots move by exactly the hub's quote. The netting reads the retiring
// debt word while the retire melts its claim, so it needs O10 of that loan
rule aHomeRefinanceConservesTheBookedPots(env e, ExtendHarness.MigrateArgs a) {
    sceneHolds(e, a.id);
    theFreshIdIsClean();
    bytes32 m = homeOf(a.id);
    require a.dst == m;
    require debtIsClaim(a.id);
    uint256 n = require_uint256(idCount() + 1);
    mathint booked0 = cashIn(m) + revenueIn(m) + potIn(m) + owedIn(m) + feeEscrowOf(a.id) + feeEscrowOf(n);
    mathint hub0 = quoteToken.balanceOf(currentContract);

    refinanceTo(e, a);

    mathint booked1 = cashIn(m) + revenueIn(m) + potIn(m) + owedIn(m) + feeEscrowOf(a.id) + feeEscrowOf(n);
    assert booked1 - booked0 == quoteToken.balanceOf(currentContract) - hub0, "a home refinance moved booked quote it did not hold";
}

// ---- forceClose: the one settle verb at tenor ----

// it asks no roll policy, whatever the loan or the market (R-8): settlement at tenor turns on no lender's answer
rule forceCloseAsksNoPolicy(env e, uint256 id) {
    sceneHolds(e, id);
    nothingAskedYet();
    forceClose(e, id);
    assert !asked, "forceClose asked a roll policy";
}

// O50's claim leg: settlement closes the loan, retires its claim whole, `lent` falls by exactly that claim, the escrow is
// earned whole, and protocol revenue never rises (a piggyback sweep may lower it)
rule aSettlementRetiresTheClaimWhole(env e, uint256 id) {
    sceneHolds(e, id);
    bytes32 m = homeOf(id);
    mathint claim0 = claimOf(m, id);
    mathint rev0 = revenueIn(m);
    mathint lent0 = lentIn(m);

    forceClose(e, id);

    assert closedOf(id) != 0, "forceClose returned without closing the loan";
    assert claimOf(m, id) == 0, "settlement left a claim";
    assert to_mathint(lentIn(m)) == lent0 - claim0, "settlement moved lent by other than the claim it retired";
    assert feeEscrowOf(id) == 0, "settlement left a fee escrow";
    assert to_mathint(revenueIn(m)) <= rev0, "settlement took protocol revenue";
}

// ---- ANTI-HOLLOW: the token model moves quote when the code does ----

rule anExtensionCanPullItsFee(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    uint256 hub0 = quoteToken.balanceOf(currentContract);
    extend(e, id, minBufferWad, data);
    satisfy quoteToken.balanceOf(currentContract) > hub0;
}

rule aRefinanceCanPayOut(env e, ExtendHarness.MigrateArgs a) {
    sceneHolds(e, a.id);
    theFreshIdIsClean();
    require a.dst == homeOf(a.id);
    uint256 hub0 = quoteToken.balanceOf(currentContract);
    refinanceTo(e, a);
    satisfy quoteToken.balanceOf(currentContract) < hub0;
}

// ---- THE ORIGINATION SHARE: the hub's one admin power ----

// The constructor writes the ceiling and the one setter refuses anything over it, so no verb ever prices a fee past 10%.
invariant theShareNeverPassesTheCeiling()
    to_mathint(protocolShareBps()) <= 1000
    filtered { f -> hubVerb(f) }

// Only the treasury moves the share, and only through its setter: no fee door, no settlement, no lender verb reaches it.
rule onlyTheTreasuryMovesTheShare(env e, method f, calldataarg args) filtered { f -> hubVerb(f) } {
    uint256 before = protocolShareBps();
    f(e, args);
    assert protocolShareBps() != before
        => f.selector == sig:setProtocolShareBps(uint256).selector && e.msg.sender == treasuryOf() && treasuryOf() != 0,
        "the share moved by other than its treasury's own setter";
}

// ANTI-HOLLOW: the treasury can move it down, to zero.
rule theTreasuryCanCutTheShareToZero(env e, uint256 s) {
    require e.msg.sender == treasuryOf() && treasuryOf() != 0 && e.msg.value == 0;
    setProtocolShareBps(e, s);
    satisfy protocolShareBps() == 0;
}

// ANTI-HOLLOW: and back UP from a cut to the ceiling, so the setter is no ratchet.
rule theTreasuryCanRaiseACutShareToTheCeiling(env e, uint256 s) {
    require e.msg.sender == treasuryOf() && treasuryOf() != 0 && e.msg.value == 0;
    require protocolShareBps() < 1000;
    setProtocolShareBps(e, s);
    satisfy protocolShareBps() == 1000;
}
