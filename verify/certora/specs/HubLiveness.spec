// Ace hub -- liveness beside O51: a full repay and a settle-window `finalize` must execute.
//
// HubBackstop.spec states it for `forceClose`, the one settle verb at tenor. These are its two siblings:
//   - `aFullRepayMustExecute`: a payer funded and approved for the whole debt can always pay a live loan off and close it.
//     If it could jam, the borrower could not take the collateral back early; forceClose still settles at book at tenor.
//   - `finalizeMustExecute`: once the record says the loan's distress has held for the settle window, `finalize` closes it.
//
// A LIVENESS rule, so every premise is a refusal the property allows or a fact about reachable states, and NO summary may
// assume a call succeeds that the code could see fail. Each `mulDiv` is EXACT and ASSERTED never to revert (a zero divisor,
// a quotient past 2^256 - 1), as HubBackstop.spec does. `mulDivRoundingUp` takes no summary (via-IR eliminates it,
// verify/README.md): its body runs on the checked `mulDiv`.
//
// THE TOKEN AND THE CUSTODIAN RUN FOR REAL: the quote is a linked DummyERC20 and the custodian the real PositionManager,
// bound both ways as the hub's constructor requires. via-IR hides the callee and selector of their calls, so the dispatch
// routes them, and the hub's own push self-call, to their code. Any OTHER unresolved call takes the default, which assumes
// it succeeds, so the call-resolution report is read for them: a liveness proof is only as good as that list.
// THE ONE ALLOWED REFUSAL besides the premises is a caller whose gas limit leaves less than the push's floor.
//
// THE STORAGE PREMISES, each guarding a checked step on the path, are SCAFFOLDING as in HubBackstop.spec: O10 (the claim is
// the debt, positive), O4 per loan (the pool's `lent` covers the claim), O5 (custody covers the units), and the rails.
// `finalize` adds ONE MODEL PREMISE, which is the property's own condition: the record answers that distress has held for
// the settle window (the record's below-question decoder, `_belowOrRevert`, answers yes).
// BAND ON `finalize` also reads the record's price under the policy budget, and a DARK answer refuses until
// `SETTLE_DARK_GRACE` past expiry: the one further refusal the rule admits. The read is summarized as any answer, never
// reverting, and recorded in persistent ghosts so the assert sees what a reverted call read; its gas floor is assumed met,
// as the push's is (HubBackstop.spec states `forceClose` the same way).

using PositionManagerHarness as pm;
using DummyERC20 as quoteToken;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivDownChecked(a, b, d);

    // the record's answer to the settle question: yes, the condition `finalizeMustExecute` is about. It sits on the one
    // decoder every below-question shares, because via-IR eliminates `persistedBelowSettleOrRevert`, its only caller being
    // `finalize`, and a summary on an eliminated function fails the run (verify/README.md). `repay` asks the record nothing.
    function Borrower._belowOrRevert(HubCoverageHarness.Cfg memory c, bytes memory data) internal returns (bool) => settleSaysYes();

    // the band-on settlement's record read: any answer, never reverting, RECORDED; the gas floor before it is assumed met
    function Borrower.cappedPrice(HubCoverageHarness.Cfg memory c) internal returns (bool, uint256) => readAsked();
    function marketDeleverageOf(bytes32) external returns (uint256, uint256, uint256, uint256, uint256) envfree; // HubCoverageHarness
    function loanExpiryOf(uint256) external returns (uint64) envfree; // HubCoverageHarness
    function settleDarkGrace() external returns (uint256) envfree; // HubCoverageHarness: Constants.SETTLE_DARK_GRACE

    function closedAtOf(uint256) external returns (uint64) envfree; // AceHarness
    function loanMarket(uint256) external returns (bytes32) envfree;
    function marketQuoteOf(bytes32) external returns (address) envfree; // AceHarness
    function marketRecordOf(bytes32) external returns (address) envfree; // HubCoverageHarness
    function loanUnitsOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanDebtOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanClaimOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanPotOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanBorrowerOf(uint256) external returns (address) envfree; // AceHarness
    function unitsOwedOf(uint256, address) external returns (uint256) envfree; // AceHarness
    function quoteClaimOf(uint256, address) external returns (uint256) envfree; // AceHarness
    function quoteOwedTotalOf(bytes32) external returns (uint256) envfree; // AceHarness
    function feeEscrowOfLoan(uint256) external returns (uint256) envfree; // AceHarness
    function marketLentOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketOwedOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketTotalsOf(bytes32) external returns (uint256, uint256) envfree; // AceHarness
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree; // AceHarness
    function marketSettleBountyBpsOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketUnsoldUnitsOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketPotCountsOf(bytes32) external returns (uint256, uint256) envfree; // AceHarness
    function notEntered() external returns (bool) envfree;
    function PUSH_FLOOR() external returns (uint256) envfree;
    function pm.collateralOf(uint256) external returns (uint256) envfree;
    function pm.retiredOf(uint256) external returns (uint256) envfree;
    function pm.notEntered() external returns (bool) envfree; // PositionManagerHarness
    function quoteToken.balanceOf(address) external returns (uint256) envfree;
    function quoteToken.allowance(address, address) external returns (uint256) envfree;

    // A call whose SELECTOR survives but whose callee is a storage word (the market's quote) is not "unresolved", and the
    // default AUTO summary of `balanceOf` REVERTS: the first run (emv-14) refused the repay at the pull's opening balance
    // read. So the known selectors dispatch to the scene's one implementer, which the premises name as the quote and the
    // custodian; the `unresolved` list below catches the calls via-IR hides selector and all.
    function _.balanceOf(address) external => DISPATCHER(true);
    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.transferFrom(address, address, uint256) external => DISPATCHER(true);
    function _.retireCustody(uint256, uint256) external => DISPATCHER(true);

    unresolved external in _._ => DISPATCH [
        pm.retireCustody(uint256,uint256),
        currentContract.pushToken(address,address,uint256),
        quoteToken.transfer(address,uint256),
        quoteToken.transferFrom(address,address,uint256),
        quoteToken.balanceOf(address)
    ] default NONDET;
}

function mulDivDownChecked(uint256 a, uint256 b, uint256 d) returns uint256 {
    assert d != 0, "a mulDiv on the path divides by zero";
    mathint r = (a * b) / d;
    assert r <= max_uint256, "a mulDiv on the path overflows";
    return require_uint256(r);
}

function settleSaysYes() returns bool {
    return true;
}

// the band-on read, RECORDED in persistent ghosts so a reverted call still says what it read
persistent ghost bool readSeen;
persistent ghost bool readOk;
persistent ghost uint256 readWord;

function readAsked() returns (bool, uint256) {
    bool ok; uint256 w;
    readSeen = true;
    readOk = ok;
    readWord = w;
    return (ok, w);
}

// the caller sends enough gas: every `gasleft()` read is held at or above the push's floor (HubBackstop.spec)
persistent ghost uint256 pushFloor;
hook GAS uint256 g {
    require g >= pushFloor;
}

definition aRealClock(env e) returns bool = e.block.timestamp > 0 && e.block.timestamp < 2^64;

// the premises both rules share: a live loan, its storage facts, its rails and its domain
function liveLoanScene(env e, uint256 id) {
    require pushFloor == PUSH_FLOOR();
    require e.msg.value == 0 && notEntered() && pm.notEntered(); // not payable; a transaction starts both guards clear
    require e.msg.sender != currentContract && e.msg.sender != pm && e.msg.sender != 0;
    require aRealClock(e);
    require loanMarket(id) != to_bytes32(0) && closedAtOf(id) == 0;
    bytes32 m = loanMarket(id);
    require marketQuoteOf(m) != 0;
    // SCAFFOLDING, each proven or owed elsewhere, as HubBackstop.spec lists them:
    require loanClaimOf(id) == loanDebtOf(id) && loanDebtOf(id) > 0; // O10
    require marketLentOf(m) >= loanClaimOf(id);                      // O4 per loan
    require pm.collateralOf(id) >= loanUnitsOf(id);                  // O5
    uint256 cover; uint256 scale; uint256 price;
    cover, scale, price = marketRailsOf(m);
    require cover >= 105 * 10^16 && cover <= 20 * 10^18 && scale == 2^96 && price > 0 && price <= 2^224; // O56
    require marketSettleBountyBpsOf(m) <= 200; // HubCoverage.spec `aCreatedMarketKeepsItsBountyRail`
    // THE DOMAIN: a loan's amounts fit in 128 bits and a running total sits under 2^255, so no addition below overflows
    address b = loanBorrowerOf(id);
    uint256 burns; uint256 loss;
    burns, loss = marketTotalsOf(m);
    require loanDebtOf(id) < 2^128 && loanUnitsOf(id) < 2^128 && feeEscrowOfLoan(id) < 2^128;
    require marketOwedOf(m) < 2^255 && burns < 2^255 && loss < 2^255 && quoteOwedTotalOf(m) < 2^255;
    require unitsOwedOf(id, b) < 2^255 && unitsOwedOf(id, e.msg.sender) < 2^255 && quoteClaimOf(id, b) < 2^255;
    require pm.retiredOf(id) < 2^255;
    uint256 unsoldPots; uint256 settledPots;
    unsoldPots, settledPots = marketPotCountsOf(m);
    require loanPotOf(id) < 2^254 && marketUnsoldUnitsOf(m) < 2^254 && unsoldPots < 2^127 && settledPots < 2^127;
}

// a full repay by a payer funded and approved for the whole debt completes, and closes the loan
rule aFullRepayMustExecute(env e, uint256 id, uint256 amount) {
    liveLoanScene(e, id);
    bytes32 m = loanMarket(id);
    require marketQuoteOf(m) == quoteToken;
    uint256 debt = loanDebtOf(id);
    require amount >= debt;
    require quoteToken.balanceOf(e.msg.sender) >= debt;
    require quoteToken.allowance(e.msg.sender, currentContract) >= debt;
    require quoteToken.balanceOf(currentContract) + debt <= max_uint256;
    repay@withrevert(e, id, amount);
    assert !lastReverted, "a funded, approved full repay was refused";
    assert closedAtOf(id) != 0, "a full repay returned without closing the loan";
}

// once the record says distress held for the settle window, finalize completes, and closes the loan
// band on, a DARK price read may hold it until SETTLE_DARK_GRACE past expiry; a live read must still settle
rule finalizeMustExecute(env e, uint256 id) {
    liveLoanScene(e, id);
    bytes32 m = loanMarket(id);
    require marketRecordOf(m) != 0; // finalize opens only where a record is wired: a recordless loan settles at tenor
    require !readSeen; // no read yet in this transaction
    uint256 eps; uint256 band; uint256 target; uint256 stop; uint256 cut;
    eps, band, target, stop, cut = marketDeleverageOf(m);
    mathint graceEnd = to_mathint(loanExpiryOf(id)) + to_mathint(settleDarkGrace()); // read BEFORE the call: a later call resets lastReverted
    finalize@withrevert(e, id);
    bool refused = lastReverted;
    bool darkWait = band != 0 && readSeen && (!readOk || readWord == 0) && to_mathint(e.block.timestamp) < graceEnd;
    assert !refused || darkWait, "finalize refused a loan whose record said settle";
    assert !refused => closedAtOf(id) != 0, "finalize returned without closing the loan";
}
