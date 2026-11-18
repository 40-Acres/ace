// Ace hub -- WHO may move value off a live loan or a market, and WHEN: the doors, not the books.
//
// The other hub specs prove that the books agree (O1, O4, O5, O10, O13). None of them says who may lower a live loan's
// collateral, who may close it, or who may take a market's resting cash or a settled pot. A deleted `NotBorrower`, a
// deleted settle check or a deleted `_onlyLender` passes every one of them. These rules fail on exactly those deletions.
//
// THE CLAIMS:
//   1. A LIVE LOAN'S VALUE LEAVES ONLY THROUGH ITS DOORS (`liveLoanValueLeavesOnlyThroughItsDoors`, O49 and O53):
//      its units fall while it stays live only by its holder's `withdrawCollateral` or by a crank that passed its whole
//      gate; it closes only by a full repay, `forceClose` from expiry, `finalize` once the record said settle, its
//      holder's `refinanceTo` before expiry, or a crank that passed its whole gate. A crank's gate (O54): the band on,
//      before expiry, the record saying NOT distressed and IN band, and a nonzero windowed minimum; the stop is
//      `aCrankSellsOnlyAboveItsStop`. A refinance's withdrawal leg lands on the SUCCESSOR, a fresh id that was not live,
//      so the holder half of that door is the refinance's own `NotBorrower`, which the close leg checks.
//   2. AN OPEN NAMES ITS BORROWER ONLY WITH CONSENT (O48): the caller is the borrower, or holds the borrower's grant;
//      and that grant, with its nonce, moves only by its grantor's call or a signature checked as the grantor's.
//   3. ONLY THE LENDER, OR A DRAW, LOWERS A MARKET'S CASH; ONLY THE LENDER, OR A PAYING BUY, LOWERS A SETTLED POT (O47).
//      A draw is told apart by what it books: the cash that left lands in the lender's own `lent` and `owed`. What a
//      buy pays is HubAsk.spec's, on exact arithmetic.
//   4. `pushToken` ANSWERS ONLY THE HUB ITSELF (`SelfCallOnly`).
//   5. EVERY GUARDED HUB MUTATOR REFUSES WHILE THE LOCK IS HELD (O24's guard, as a proof rather than a grep).
//
// THE RECORD IS RECORDED, NEVER TRUSTED. Every record read goes through `Probe.askWord` (a crank's distress and band
// questions, finalize's settle question) or `Borrower.persistedPrice` (the windowed minimum). Both are summarized to
// answer ANYTHING, a codeless record answering nothing, and to write down what they answered. A STATICCALL writes no
// state, so any answer admits every real record and more. The rules then assert what the code must have heard before
// it moved value. A deleverage asks twice, distress then band; a finalize asks once. IF VIA-IR INLINES `askWord` at a
// call site, the summary does not bind there and nothing is written down, so the rules on that verb FAIL rather than
// pass: read the run's "unable to locate" lines.
//
// WHAT ELSE IS SUMMARIZED, each a `view` or `pure` function, so "returns anything, never reverts" is a superset:
//   - a signed grant's check, `SignatureChecker.isValidSignatureNowCalldata`, answering anything and recording whom it
//     was asked about, exactly as the record is: neither ECDSA recovery nor ERC-1271 reads hub state;
//   - the arithmetic, as in HubLoans.spec; `LoanMath.triggerPrice` as a deterministic ghost, so the two reads of a
//     loan's trigger inside one crank agree, as the real pure function's do;
//   - HubLeanGates.spec's read-only gates (the extension's legs, the open path's refusals and admission, the health
//     arithmetic), none of which any claim here rests on. Kept real: `withdrawCollateral`'s and `refinance`'s
//     `NotBorrower`, `_open`'s credit check, the settle verbs' clock and record checks, the crank's gates, both
//     `_onlyLender`s, `buyInventory`'s fold and the reentrancy guard.
// NO TOKEN IS MODELLED: an unresolved call takes the default and cannot write the hub. Exit destinations are
// HubExits.spec's, over a linked token.
//
// THE PREMISE every rule naming a loan takes, PROVEN elsewhere and restated because a different methods block cannot
// import it: an issued loan sits at or under the id counter (HubAttribution.spec `aFreshIdHoldsNoLoan`, O57), so no
// open, fill or refinance issues its id again.

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    // NO SUMMARY for mulDivRoundingUp: via-IR inlines it, so one cannot bind and requesting it fails the run. Its body runs on the mulDiv above; see HubLoans.spec.
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => ozPlain(x, y, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => ozRounded(x, y, d, r);
    function Mul512.gt512(uint256 a, uint256 b, uint256 c, uint256 d) internal returns (bool) => gt512Ghost(a, b, c, d);
    function LoanMath.triggerPrice(uint256 debt, uint256 units, uint256 coverageWad, uint256 unitScale) internal returns (uint256)
        => trigOf(debt, units, coverageWad, unitScale);

    // THE RECORD, recorded
    function Probe.askWord(address target, bytes memory data) internal returns (bool, uint256) => recordedAsk(target);
    function Borrower.persistedPrice(DoorsHarness.Cfg memory c) internal returns (uint256) => recordedPrice(c);
    // A SIGNED GRANT'S CHECK, recorded: whom it was asked of, and what it answered
    function SignatureChecker.isValidSignatureNowCalldata(address signer, bytes32 hash, bytes calldata signature) internal returns (bool)
        => recordedSig(signer);

    // HubLeanGates.spec's read-only gates, less the two health reads above
    function Borrower.tryRecordState(DoorsHarness.Cfg memory) internal returns (bool, DoorsHarness.RecordState, uint256) => NONDET;
    function Borrower._admissibleLeg(DoorsHarness.Cfg memory, uint256, uint256, uint256, uint256) internal returns (bytes4) => NONDET;
    function Probe.askBool(address, bytes memory, uint256, bytes32) internal returns (bool) => NONDET;
    function Borrower._preChecks(DoorsHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._gateCheck(DoorsHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._payoutCheck(DoorsHarness.Cfg memory, Borrower.OpenArgs memory, uint256) internal returns (uint256) => NONDET;
    function Borrower._previewFloor(DoorsHarness.Market storage, DoorsHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;
    function Borrower._gate(uint256, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.coverageLine(DoorsHarness.Cfg memory, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.requiredAt(DoorsHarness.Cfg memory, uint256, uint256) internal returns (uint256) => NONDET;
    function LoanAccounting.fundingFloor(DoorsHarness.Market storage, DoorsHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;

    function idCount() external returns (uint256) envfree;
    function loanMarket(uint256) external returns (bytes32) envfree;
    function closedAtOf(uint256) external returns (uint64) envfree;
    function loanBorrowerOf(uint256) external returns (address) envfree;
    function loanExpiryOf(uint256) external returns (uint64) envfree;
    function loanUnitsOf(uint256) external returns (uint256) envfree;
    function loanDebtOf(uint256) external returns (uint256) envfree;
    function loanPotOf(uint256) external returns (uint256) envfree;
    function restingOf(bytes32) external returns (uint256) envfree;
    function marketLenderOf(bytes32) external returns (address) envfree;
    function marketOwedOf(bytes32) external returns (uint256) envfree;
    function marketLentOf(bytes32) external returns (uint256) envfree;
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree;
    function marketGateOf(bytes32) external returns (uint256, uint256, address) envfree;
    function creditOperatorOf(address, address) external returns (bool) envfree;
    function creditNonceOf(address) external returns (uint256) envfree;
    function notEntered() external returns (bool) envfree;
}

persistent ghost fmDown(uint256, uint256, uint256) returns uint256;
persistent ghost ozPlain(uint256, uint256, uint256) returns uint256;
persistent ghost ozFloor(uint256, uint256, uint256) returns uint256;
persistent ghost ozCeil(uint256, uint256, uint256) returns uint256;
persistent ghost ozTrunc(uint256, uint256, uint256) returns uint256;
persistent ghost ozExpand(uint256, uint256, uint256) returns uint256;
persistent ghost gt512Ghost(uint256, uint256, uint256, uint256) returns bool;
persistent ghost trigOf(uint256, uint256, uint256, uint256) returns uint256;

function ozRounded(uint256 x, uint256 y, uint256 d, Math.Rounding r) returns uint256 {
    if (r == Math.Rounding.Floor) { return ozFloor(x, y, d); }
    if (r == Math.Rounding.Ceil) { return ozCeil(x, y, d); }
    if (r == Math.Rounding.Trunc) { return ozTrunc(x, y, d); }
    return ozExpand(x, y, d);
}

// ---- the record, recorded. PERSISTENT, so no havocked call between an ask and the assert can erase it ----

persistent ghost uint256 asks; // how many questions `askWord` was asked
persistent ghost bool ok1; // the first answer's success flag
persistent ghost uint256 word1; // the first answer's word
persistent ghost bool ok2;
persistent ghost uint256 word2;
persistent ghost uint256 prices; // how many windowed minimums were read
persistent ghost uint256 price1; // the first one

// anything at all, but a codeless record answers nothing: zero has no code, and the real probe checks code first
function recordedAsk(address target) returns (bool, uint256) {
    bool ok;
    uint256 word;
    require target == 0 => (!ok && word == 0);
    if (asks == 0) {
        ok1 = ok;
        word1 = word;
    }
    if (asks == 1) {
        ok2 = ok;
        word2 = word;
    }
    asks = require_uint256(asks + 1);
    return (ok, word);
}

// no record wired reads max, as the real one does; a wired one answers anything, never reverting where it might
function recordedPrice(DoorsHarness.Cfg c) returns uint256 {
    if (c.p.record == 0) {
        return max_uint256;
    }
    uint256 p;
    if (prices == 0) {
        price1 = p;
    }
    prices = require_uint256(prices + 1);
    return p;
}

function nothingAskedYet() {
    require asks == 0 && prices == 0;
}

// ---- which verb is which ----

definition hubVerb(method f) returns bool =
    !f.isView && f.contract == currentContract && f.selector != sig:multicall(bytes[]).selector
    && f.selector != sig:pushToken(address,address,uint256).selector;

definition withdrawsCollateral(method f) returns bool = f.selector == sig:withdrawCollateral(uint256,uint256,address).selector;
definition cranks(method f) returns bool = f.selector == sig:deleverage(uint256,uint256,bytes).selector;
definition finalizes(method f) returns bool = f.selector == sig:finalize(uint256).selector;
definition forceCloses(method f) returns bool = f.selector == sig:forceClose(uint256).selector;
definition refinances(method f) returns bool = f.selector == sig:refinanceTo(DoorsHarness.MigrateArgs).selector;
definition repays(method f) returns bool =
    f.selector == sig:repay(uint256,uint256).selector || f.selector == sig:repayWithPermit2(uint256,uint256,bytes).selector;
definition buys(method f) returns bool = f.selector == sig:buyInventory(uint256,uint256,uint256,address).selector;

// A REAL CLOCK, as HubClaims.spec's `aRealClock` states it: a close stamps `uint64(block.timestamp)`, so a clock at a
// multiple of 2^64 would stamp zero and leave a settled loan reading live (emv-2's two FAILs were exactly that).
definition aRealClock(env e) returns bool = e.block.timestamp > 0 && e.block.timestamp < 2^64;

// an issued loan, live or not, and a caller that is not the hub; the freshness premise keeps its market and id its own
function issuedLoan(env e, uint256 id) {
    require e.msg.sender != currentContract && aRealClock(e);
    require loanMarket(id) != to_bytes32(0);
    require id <= idCount(); // PROVEN: HubAttribution.spec `aFreshIdHoldsNoLoan`
}

// a live, issued loan
function liveLoan(env e, uint256 id) {
    issuedLoan(e, id);
    require closedAtOf(id) == 0;
}

// ---- 1. A LIVE LOAN'S VALUE LEAVES ONLY THROUGH ITS DOORS ----

rule liveLoanValueLeavesOnlyThroughItsDoors(env e, method f, calldataarg args, uint256 id) filtered { f -> hubVerb(f) } {
    liveLoan(e, id);
    nothingAskedYet();
    address holder = loanBorrowerOf(id);
    uint64 expiry = loanExpiryOf(id);
    uint256 units0 = loanUnitsOf(id);
    uint256 band;
    uint256 stop;
    address record;
    band, stop, record = marketGateOf(loanMarket(id));

    f(e, args);

    bool live = closedAtOf(id) == 0;
    // the crank's whole gate but the stop: band on, unexpired, not distressed, in band, a windowed minimum
    bool gate = band != 0 && e.block.timestamp < expiry && asks >= 2 && ok1 && word1 == 0 && ok2 && word2 == 1
        && prices >= 1 && price1 != 0;
    assert live && loanUnitsOf(id) < units0 => (withdrawsCollateral(f) && e.msg.sender == holder) || (cranks(f) && gate),
        "a live loan's collateral fell by a door that is not its holder's or a gated crank";
    assert !live => (repays(f) && loanDebtOf(id) == 0)
        || (forceCloses(f) && e.block.timestamp >= expiry)
        || (finalizes(f) && asks >= 1 && ok1 && word1 == 1)
        || (refinances(f) && e.msg.sender == holder && e.block.timestamp < expiry)
        || (cranks(f) && gate),
        "a live loan closed by a door that is not a full repay, tenor, a settle the record attested, its holder's refinance or a gated crank";
}

// THE STOP, the gate's last leg: a crank sells only while the windowed minimum is above the stop level. The level is
// `ceil(trigger / (1 - stop))`, at least its floor, so a minimum at or under the floor is under the level.
// RAIL PREMISE, from genesis (MarketInit: a band on needs `0 < stop < band < 10000`): the stop's complement is positive.
rule aCrankSellsOnlyAboveItsStop(env e, uint256 id, uint256 minStableOut, bytes data) {
    liveLoan(e, id);
    nothingAskedYet();
    bytes32 m = loanMarket(id);
    uint256 units0 = loanUnitsOf(id);
    uint256 debt0 = loanDebtOf(id);
    uint256 band;
    uint256 stop;
    address record;
    band, stop, record = marketGateOf(m);
    uint256 cover;
    uint256 scale;
    uint256 price;
    cover, scale, price = marketRailsOf(m);
    require stop < 10000;
    uint256 stopFloor = fmDown(trigOf(debt0, units0, cover, scale), 10^18, require_uint256(10^18 - stop * 10^14));

    deleverage(e, id, minStableOut, data);

    assert loanUnitsOf(id) < units0 || closedAtOf(id) != 0 => prices >= 1 && price1 > stopFloor,
        "a crank sold at or under its stop level";
}

// witnesses: a crank really sells off a live loan and leaves it live, and a finalize really closes one, so the gate
// and settle legs are reached on a path the recorded answers allow
rule aCrankCanSellAndLeaveTheLoanLive(env e, uint256 id, uint256 minStableOut, bytes data) {
    liveLoan(e, id);
    nothingAskedYet();
    uint256 units0 = loanUnitsOf(id);
    deleverage(e, id, minStableOut, data);
    satisfy closedAtOf(id) == 0 && loanUnitsOf(id) < units0;
}

rule aFinalizeCanClose(env e, uint256 id) {
    liveLoan(e, id);
    nothingAskedYet();
    finalize(e, id);
    satisfy closedAtOf(id) != 0;
}

// ---- 2. AN OPEN NAMES ITS BORROWER ONLY WITH CONSENT ----

rule anOpenNeedsItsBorrowersConsent(env e, bytes32 market, uint256 units, uint256 principal, uint64 tenor, address borrower,
    DoorsHarness.OpenBounds bnd) {
    require e.msg.sender != currentContract;
    bool granted = creditOperatorOf(borrower, e.msg.sender);
    uint256 id = open(e, market, units, principal, tenor, borrower, bnd);
    assert e.msg.sender == borrower || granted, "an open named a borrower who never consented";
    assert loanBorrowerOf(id) == borrower, "an open titled its loan to someone it did not name";
}

rule aPermitOpenNeedsItsBorrowersConsent(env e, bytes32 market, uint256 units, uint256 principal, uint64 tenor, address borrower,
    DoorsHarness.OpenBounds bnd, bytes permit2) {
    require e.msg.sender != currentContract;
    bool granted = creditOperatorOf(borrower, e.msg.sender);
    uint256 id = openWithPermit2(e, market, units, principal, tenor, borrower, bnd, permit2);
    assert e.msg.sender == borrower || granted, "a permit open named a borrower who never consented";
    assert loanBorrowerOf(id) == borrower, "a permit open titled its loan to someone it did not name";
}

// witness: an operator holding a grant really opens in another's name, so the grant leg is not hollow
rule anOperatorCanOpenForItsGrantor(env e, bytes32 market, uint256 units, uint256 principal, uint64 tenor, address borrower,
    DoorsHarness.OpenBounds bnd) {
    require e.msg.sender != currentContract && e.msg.sender != borrower;
    open(e, market, units, principal, tenor, borrower, bnd);
    satisfy true;
}

// ---- 2b. A GRANT MOVES ONLY BY ITS GRANTOR ----

// THE SIGNATURE CHECK IS RECORDED, as the record is: `isValidSignatureNowCalldata` answers anything and writes down whom it
// was asked about. ECDSA recovery and ERC-1271 both read no hub state, so any answer admits every real signer and more.
persistent ghost bool sigAsked; // whether a grant signature was checked
persistent ghost address sigSigner; // whose signature it was checked as
persistent ghost bool sigSaid; // what the check answered

function recordedSig(address signer) returns bool {
    bool ok;
    sigAsked = true;
    sigSigner = signer;
    sigSaid = ok;
    return ok;
}

definition setsOperator(method f) returns bool = f.selector == sig:setCreditOperator(address,bool).selector;
definition setsOperatorBySig(method f) returns bool =
    f.selector == sig:setCreditOperatorWithSig(address,address,bool,uint256,uint256,bytes).selector;

// O48's second half: a borrower's grant to an operator, and the nonce that arms its next signed grant, move only by the
// borrower's own `setCreditOperator`, or by a relayed `setCreditOperatorWithSig` whose signature was checked as the
// borrower's, said yes, and spent exactly the borrower's current nonce.
rule aGrantMovesOnlyByItsGrantor(env e, method f, calldataarg args, address borrower, address operator) filtered { f -> hubVerb(f) } {
    require e.msg.sender != currentContract;
    require !sigAsked;
    bool granted0 = creditOperatorOf(borrower, operator);
    mathint nonce0 = creditNonceOf(borrower);
    f(e, args);
    bool signed = setsOperatorBySig(f) && sigAsked && sigSigner == borrower && sigSaid && creditNonceOf(borrower) == nonce0 + 1;
    bool own = setsOperator(f) && e.msg.sender == borrower && creditNonceOf(borrower) == nonce0 + 1;
    assert creditOperatorOf(borrower, operator) != granted0 => own || signed, "a credit grant moved by someone other than its grantor";
    assert creditNonceOf(borrower) != nonce0 => own || signed, "a grant nonce moved by someone other than its grantor";
}

// witness: a relayed grant really lands, so the signed leg is not hollow
rule aSignedGrantCanLand(env e, address borrower, address operator, bool allowed, uint256 nonce, uint256 deadline, bytes signature) {
    require e.msg.sender != currentContract && e.msg.sender != borrower;
    require !sigAsked;
    bool granted0 = creditOperatorOf(borrower, operator);
    setCreditOperatorWithSig(e, borrower, operator, allowed, nonce, deadline, signature);
    satisfy creditOperatorOf(borrower, operator) != granted0;
}

// ---- 3. ONLY THE LENDER, OR A DRAW, LOWERS CASH; ONLY THE LENDER, OR A PAYING BUY, LOWERS A POT ----

// A draw moves the lender's money from resting to lent at par: `_fund` debits cash by the fresh draw and books the whole
// principal into the pool's `lent`. A refinance retiring a claim in the same pair moves that claim from `lent` to `owed`,
// or, recycled, nets it against the draw, so the pair's `lent + owed` rises by at least what left cash, fees on top.
// Anything else lowering cash moves the lender's money out of its pool, and only the lender may: `withdraw`.
rule onlyTheLenderOrADrawLowersCash(env e, method f, calldataarg args, bytes32 m) filtered { f -> hubVerb(f) } {
    require e.msg.sender != currentContract && aRealClock(e);
    address lender = marketLenderOf(m);
    mathint cash0 = restingOf(m);
    mathint held0 = marketLentOf(m) + marketOwedOf(m);
    f(e, args);
    mathint fell = cash0 - restingOf(m);
    assert fell > 0 => e.msg.sender == lender || marketLentOf(m) + marketOwedOf(m) - held0 >= fell,
        "a market's cash fell by more than the draw booked to its lender, and not by its lender";
}

// A buy pays in this call: the proceeds credit the lender's pool (`owed`), so a pot falling by a buy raises it.
// HOW MUCH it raises it is HubAsk.spec's `aBuyCreditsTheLenderTheAskValue`: at least the ask value of the units that
// left. It needs EXACT `mulDiv`, which every rule here would pay for, so it lives in its own scene; with this rule's
// door (no one but the lender or a buy lowers a pot) the two say a stranger takes a pot only by paying its ask.
rule onlyTheLenderOrABuyLowersAPot(env e, method f, calldataarg args, uint256 id) filtered { f -> hubVerb(f) } {
    issuedLoan(e, id);
    bytes32 m = loanMarket(id);
    address lender = marketLenderOf(m);
    mathint pot0 = loanPotOf(id);
    mathint owed0 = marketOwedOf(m);
    f(e, args);
    mathint fell = pot0 - loanPotOf(id);
    assert fell > 0 => e.msg.sender == lender || (buys(f) && marketOwedOf(m) > owed0),
        "a settled pot fell by a door that is neither its lender's nor a buy that paid the lender";
}

// witnesses: a stranger's draw lowers cash, and the lender's redeem lowers a pot, so neither leg is hollow
rule aStrangersDrawCanLowerCash(env e, bytes32 m, uint256 units, uint256 principal, uint64 tenor, address borrower,
    DoorsHarness.OpenBounds bnd) {
    require e.msg.sender != currentContract && e.msg.sender != marketLenderOf(m);
    mathint cash0 = restingOf(m);
    open(e, m, units, principal, tenor, borrower, bnd);
    satisfy restingOf(m) < cash0;
}

rule theLenderCanRedeemAPot(env e, uint256 id, address to) {
    issuedLoan(e, id);
    mathint pot0 = loanPotOf(id);
    redeemInKind(e, id, to);
    satisfy loanPotOf(id) < pot0;
}

// ---- 4. `pushToken` ANSWERS ONLY THE HUB ----

rule pushTokenAnswersOnlyTheHub(env e, address token, address to, uint256 amount) {
    require e.msg.sender != currentContract;
    pushToken@withrevert(e, token, to, amount);
    assert lastReverted, "pushToken moved a token for a caller other than the hub";
}

// witness: the hub's own hop can land, so the refusal above is the caller test, not a door that never opens
rule theHubsOwnPushCanLand(env e, address token, address to, uint256 amount) {
    require e.msg.sender == currentContract && e.msg.value == 0;
    pushToken@withrevert(e, token, to, amount);
    satisfy !lastReverted;
}

// ---- 5. EVERY GUARDED MUTATOR REFUSES UNDER THE LOCK ----

// The hub analog of VaultBoundary.spec's `everyMutatorTakesTheLock`. The four exceptions are `scripts/guard-check.sh`'s,
// each with the reason it records: `multicall` (its legs take and release the guard in turn), `pushToken` (the self-call
// hop, `SelfCallOnly`, whose every caller holds the guard), `createMarket` (it writes only fresh market storage) and
// `setCreditOperator` (two storage writes and an event, no external call).
definition unguarded(method f) returns bool =
    f.selector == sig:multicall(bytes[]).selector
    || f.selector == sig:pushToken(address,address,uint256).selector
    || f.selector == sig:createMarket(DoorsHarness.MarketParams).selector
    || f.selector == sig:setCreditOperator(address,bool).selector;

rule everyHubMutatorRefusesUnderTheLock(env e, method f, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract && !unguarded(f) }
{
    require !notEntered();
    f@withrevert(e, args);
    assert lastReverted, "a guarded hub mutator ran while the hub's lock was held";
}
