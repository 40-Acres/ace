// Ace.extend, refinanceTo's claim reuse and its refusal from expiry, and forceClose -- obligations O72, O72b and O72c at
// the hub's own door, and O50's claim leg at the one settle verb.
//
// An extension lengthens a live loan IN PLACE: the same id and title, its term re-anchored at now and run for the loan's
// own tenor again, so the new expiry is `now + tenor`, at most `now + maxTenor`, and the tenor never moves. It lands only
// strictly inside the term: in the open second it adds no time and refuses, and from the expiry second it refuses
// `LoanMatured`. Its fee is `originationFee(debt, newExpiry - expiry, ...)`, the fee on the time it adds, and the CALLER
// pays it in cash: the protocol cut to revenue, the tick cut to `owed`, the escrow cut funded. First the funded escrow
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
//     as HubLeanGates.spec does: `view` or `pure`, so "returns anything, never reverts" is a superset. The extension's
//     caller, matured, no-time and borrower-rule legs stay REAL, as do `_preChecks`, `_payoutCheck`, `_askPolicy`'s
//     zero-policy test and the refinance gate.
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
// NO WRITE BEFORE THE ASK is read off a RAW store hook, which sees every slot the hub writes, packed or not; the reentrancy
// guard is transient and never reaches it. `theStoreHookSeesAnExtensionsWrites` is its witness.

using DummyERC20 as quoteToken;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    // NO SUMMARY for mulDivRoundingUp: via-IR inlines it, so one cannot bind and requesting it fails the run. Its body runs on the mulDiv above; see HubLoans.spec.

    // the extension's read-only record and admission legs
    function Borrower.tryRecordState(ExtendHarness.Cfg memory) internal returns (bool, ExtendHarness.RecordState, uint256) => NONDET;
    function Borrower._admissibleLeg(ExtendHarness.Cfg memory, uint256, uint256, uint256, uint256) internal returns (bytes4) => NONDET;
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
    function originationFeeOf(bytes32, uint256, uint64) external returns (uint256) envfree;
    function drawCountOf(bytes32) external returns (uint64) envfree;
    function poolOf(bytes32) external returns (uint256, uint256, uint256) envfree;
    function rollPolicyOf(address) external returns (address) envfree;
    function policyYes() external returns (bytes32) envfree;
    function protocolCut(uint256) external returns (uint256) envfree;
    function escrowCut(uint256) external returns (uint256) envfree;
    function tickCut(uint256) external returns (uint256) envfree;
    function quoteToken.balanceOf(address) external returns (uint256) envfree;
}

persistent ghost fmDown(uint256, uint256, uint256) returns uint256;

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
persistent ghost bool wroteBeforeAsk;
persistent ghost bool wroteAfterAsk;

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

// every persistent-storage write the hub's own code makes, split at the first ask
hook ALL_SSTORE(uint256 loc, uint256 v) {
    if (executingContract == currentContract) {
        if (asked) {
            wroteAfterAsk = true;
        } else {
            wroteBeforeAsk = true;
        }
    }
}

function nothingAskedYet() {
    require !asked && asks == 0 && !wroteBeforeAsk && !wroteAfterAsk;
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

// I1: every loan's term is one tenor long. `_record` writes it so at the open and `respread` at an extension, the only two
// writers of the term; an unissued id reads 0 + 0 == 0. The no-time refusal rests on it to fire only in the open second,
// and no safety leg does: the extension checks `newExpiry > expiry` and charges `newExpiry - expiry` directly
invariant theTermIdentityHolds(uint256 id)
    to_mathint(loanOpenTime(id)) + to_mathint(loanTenor(id)) == to_mathint(loanExpiry(id))
    {
        preserved with (env e) {
            require e.msg.sender != currentContract && aRealClock(e);
        }
    }

// I2: no verb moves an issued loan's tenor; an extension runs it again, and only the open that issues a loan writes it
rule aLoansTenorNeverMoves(env e, method f, calldataarg args, uint256 id) filtered { f -> !f.isView } {
    require e.msg.sender != currentContract && aRealClock(e);
    require homeOf(id) != to_bytes32(0);
    uint64 t0 = loanTenor(id);

    f(e, args);

    assert loanTenor(id) == t0, "a verb moved an issued loan's tenor";
}

// I2: an issued loan's tenor sits on its market's grid, from the open that issued it on, and the grid is write-once
rule aLoansTenorStaysOnItsGrid(env e, method f, calldataarg args, uint256 id) filtered { f -> !f.isView } {
    require e.msg.sender != currentContract && aRealClock(e);
    require homeOf(id) != to_bytes32(0) => onItsGrid(id);

    f(e, args);

    assert homeOf(id) != to_bytes32(0) => onItsGrid(id), "an issued loan's tenor left its market's grid";
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

// THE SAME SECOND: in the loan's open second its own tenor from now ends where it already does, so the extension adds no
// time and refuses before any write or policy ask
rule aSameSecondExtensionRefuses(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    requireInvariant theTermIdentityHolds(id);
    require to_mathint(e.block.timestamp) == to_mathint(loanOpenTime(id));
    nothingAskedYet();

    extend@withrevert(e, id, minBufferWad, data);

    assert lastReverted, "an extension in the loan's open second landed";
    assert !asked && !wroteBeforeAsk, "an extension in the loan's open second asked a policy or wrote";
}

// FROM EXPIRY: a matured loan's extension refuses, `LoanMatured`, before any write or policy ask; `forceClose` then settles it
rule anExtensionRefusesFromExpiry(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    require to_mathint(e.block.timestamp) >= to_mathint(loanExpiry(id));
    nothingAskedYet();

    extend@withrevert(e, id, minBufferWad, data);

    assert lastReverted, "an extension landed from the loan's expiry";
    assert !asked && !wroteBeforeAsk, "a matured loan's extension asked a policy or wrote";
}

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

// THE CALLER: the holder, or the market lender holding the holder's credit grant (review E-3); nobody else extends
rule onlyTheHolderOrItsGrantedLenderExtends(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    address holder = holderOf(id);
    address lender = lenderIn(homeOf(id));
    bool granted = creditOperatorOf(holder, e.msg.sender);

    extend(e, id, minBufferWad, data);

    assert e.msg.sender == holder || (e.msg.sender == lender && granted),
        "an extension landed for a caller who is neither the holder nor its granted lender";
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

// ---- O72c: no extension moves the debt, and the granted lender pays its own fee ----

rule anExtensionNeverMovesTheDebt(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    bytes32 m = homeOf(id);
    mathint debt0 = loanDebt(id);
    mathint claim0 = claimOf(m, id);

    extend(e, id, minBufferWad, data);

    assert to_mathint(loanDebt(id)) == debt0, "an extension moved the debt";
    assert to_mathint(claimOf(m, id)) == claim0, "an extension moved the claim";
}

// E-3: a lender extending under the holder's grant pays the fee itself, and the holder's quote never moves
rule aGrantedLenderPaysItsOwnFee(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    address holder = holderOf(id);
    require e.msg.sender != holder && holder != currentContract;
    mathint holder0 = quoteToken.balanceOf(holder);
    mathint payer0 = quoteToken.balanceOf(e.msg.sender);

    uint256 fee = extend(e, id, minBufferWad, data);

    assert to_mathint(quoteToken.balanceOf(holder)) == holder0, "a granted lender's extension moved the holder's quote";
    assert to_mathint(quoteToken.balanceOf(e.msg.sender)) == payer0 - fee, "a granted lender's extension was not paid by the lender";
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

// NO WRITE BEFORE THE ANSWER: every leg before the ask only reads, so the policy sees the loan as it stands, and a refusal,
// which reverts there, leaves storage as it was
rule anExtensionWritesNothingBeforeItsPolicyAnswers(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    nothingAskedYet();

    extend(e, id, minBufferWad, data);

    assert !wroteBeforeAsk, "an extension wrote storage before its lender's policy answered";
}

// ANTI-HOLLOW for the store hook: an extension's writes land after the ask, and the hook sees them
rule theStoreHookSeesAnExtensionsWrites(env e, uint256 id, uint256 minBufferWad, bytes data) {
    sceneHolds(e, id);
    nothingAskedYet();
    extend(e, id, minBufferWad, data);
    satisfy wroteAfterAsk;
}

// ---- refinanceTo: refused from expiry; before it, the retiring claim is reused only in its own market, on its lender's yes ----

// THE REFINANCE GATE: from the expiry second a refinance refuses `LoanMatured`, into any market, before any write and any
// policy ask, so a matured live loan leaves only by repay, forceClose, or finalize on persisted distress
rule aMaturedLoanNeverRefinances(env e, ExtendHarness.MigrateArgs a) {
    sceneHolds(e, a.id);
    require to_mathint(e.block.timestamp) >= to_mathint(loanExpiry(a.id));
    nothingAskedYet();

    refinanceTo@withrevert(e, a);

    assert lastReverted, "a matured loan refinanced";
    assert !asked && !wroteBeforeAsk, "a matured loan's refinance asked a policy or wrote";
}

// the policy is asked only when the refinance stays in the loan's own market, of its stored policy with POLICY_GAS and before
// any write; on its yes the successor draws only what the retiring claim does not recycle, and otherwise its whole
// principal. Anyone may create a market naming any lender, so another market, the same lender's included, draws it all
rule aRefinanceReusesTheClaimOnlyOnItsLendersYes(env e, ExtendHarness.MigrateArgs a) {
    sceneHolds(e, a.id);
    nothingAskedYet();
    bytes32 src = homeOf(a.id);
    mathint claim0 = claimOf(src, a.id);
    mathint cash0 = cashIn(a.dst);
    bool inPlace = a.dst == src;
    address policy = rollPolicyOf(lenderIn(src));

    refinanceTo(e, a);

    mathint p = a.newPrincipal;
    mathint recycle = claim0 < p ? claim0 : p;
    assert asked => inPlace && askedOf == policy && askedGas == POLICY_GAS(), "a refinance asked a policy outside the loan's own market";
    assert !inPlace => to_mathint(cashIn(a.dst)) == cash0 - p, "a refinance reused a claim outside the loan's own market";
    assert asked => !wroteBeforeAsk, "a refinance wrote storage before its lender's policy answered";
    assert (asked && said) => to_mathint(cashIn(a.dst)) == cash0 - (p - recycle), "a reusing refinance drew other than the fresh rest";
    assert !(asked && said) => to_mathint(cashIn(a.dst)) == cash0 - p, "a refinance reused a claim without its lender's yes";
}

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
