// PositionManager, alone: the custodian's laws, and the fact the hub specs' summaries of it rest on.
//
// THE HUB IS ARBITRARY here except for two reads, modelled as the hub answers them: `escrowConfigOf(id)` and
// `isLiveLoan(id)` are FIXED PER ID (a loan's market config is write-once), so they are ghost functions of the id.
// Every token the custodian moves runs on `tok`, a plain linked ERC-20, through a transfer summary that calls it
// whenever the token the code called IS `tok` -- so calling the wrong token is a visible move, not a hidden one.
//
// THE CLAIMS:
//   - ACCESS (I-C): every ledger-moving verb refuses anyone but the loan manager.
//   - ONLY THE NAMED LOAN'S COLLATERAL MOVES, out of the payer the hub named (a pull) or the custodian itself.
//     This is what licenses HubSolvency.spec to summarize the custodian as moving none of the hub's QUOTE.
//   - THE POT COVERS WHAT IT OWES (I-A, pot side): custodiedOf(T) never exceeds the custodian's balance of T.
//   - THE LEDGER NEVER OUTGROWS CUSTODY but by an unpaired carry-in: the header says I-A "holds only while the hub
//     pairs carryOut with carryIn", so that pairing is the HUB's obligation, and this proves it is the only one.

using DummyERC20 as tok;

methods {
    function _.escrowConfigOf(uint256 id) external => escrowCfg(id) expect (address, address);
    function _.isLiveLoan(uint256 id) external => liveOf(id) expect bool;

    // via-IR keeps safeTransfer's entry but inlines pull's safeTransferFrom, leaving an assembly call whose callee
    // AND selector are unresolved, and the balance read after it loses its selector too. Both dispatch to `tok` when
    // the callee IS `tok`, else do nothing; aPullMovesThePayersUnits proves the dispatch fires
    function SafeERC20.safeTransfer(address token, address to, uint256 value) internal => moveFrom(token, currentContract, to, value);
    unresolved external in pull(uint256,address,uint256)
        => DISPATCH [ tok.transferFrom(address,address,uint256), tok.balanceOf(address) ] default NONDET;
    function _.balanceOf(address who) external => balanceOfCalled(calledContract, who) expect uint256;

    function LOAN_MANAGER() external returns (address) envfree;
    function collateralOf(uint256) external returns (uint256) envfree;
    function retiredOf(uint256) external returns (uint256) envfree;
    function custodiedOf(address) external returns (uint256) envfree;
    function tok.balanceOf(address) external returns (uint256) envfree;
}

// ---- the hub's two reads, fixed per id ----

persistent ghost collateralTokenOf(uint256) returns address;
persistent ghost quoteTokenOf(uint256) returns address;
persistent ghost liveOf(uint256) returns bool;

function escrowCfg(uint256 id) returns (address, address) {
    return (collateralTokenOf(id), quoteTokenOf(id));
}

// ---- how tokens move: through `tok` when the code names it, and not at all for any other token ----

function moveFrom(address token, address from, address to, uint256 value) {
    if (token == tok) {
        env e;
        require e.msg.sender == from && e.msg.value == 0;
        tok.transfer(e, to, value);
    }
}

function balanceOfCalled(address token, address who) returns uint256 {
    if (token == tok) { return tok.balanceOf(who); }
    uint256 any;
    return any;
}

definition ofTheCustodian(method f) returns bool = f.contract == currentContract && !f.isView;

// ---- ACCESS ----

rule onlyTheLoanManagerMovesALedger(env e, method f, calldataarg args) filtered { f -> ofTheCustodian(f) } {
    require e.msg.sender != LOAN_MANAGER();
    f@withrevert(e, args);
    assert lastReverted, "a stranger moved custody";
}

// ---- ONLY THE NAMED LOAN'S COLLATERAL MOVES, and only out of the payer or the custodian ----

// a token other than the loan's own collateral never moves, for anyone
rule aForeignTokenNeverMoves(env e, method f, uint256 loanId, address who) filtered { f -> ofTheCustodian(f) } {
    require collateralTokenOf(loanId) != tok;
    require e.msg.sender != currentContract;
    uint256 before = tok.balanceOf(who);
    callOnLoan(e, f, loanId);
    assert tok.balanceOf(who) == before, "the custodian moved a token that is not the loan's collateral";
}

// ANTI-HOLLOW: a pull really moves the payer's units into custody, so the dispatch above runs the token's code
rule aPullMovesThePayersUnits(env e, uint256 loanId, address from, uint256 units) {
    require collateralTokenOf(loanId) == tok && from != currentContract && units > 0;
    uint256 payer0 = tok.balanceOf(from);
    uint256 pot0 = tok.balanceOf(currentContract);
    pull(e, loanId, from, units);
    satisfy tok.balanceOf(from) == payer0 - units && tok.balanceOf(currentContract) == pot0 + units;
}

// whoever loses units of the loan's collateral is the payer the hub named, or the custodian itself
rule onlyThePayerOrTheCustodianPays(env e, uint256 loanId, address from, uint256 units, address who) {
    require collateralTokenOf(loanId) == tok;
    require who != from && who != currentContract;
    uint256 before = tok.balanceOf(who);
    pull(e, loanId, from, units);
    assert tok.balanceOf(who) >= before, "a pull took collateral from someone other than its named payer";
}

// ANTI-HOLLOW: both releases really pay their recipient, so the rule below is not true by nothing moving
rule aReleaseCanPay(env e, uint256 loanId, address to, uint256 units) {
    require collateralTokenOf(loanId) == tok && to != currentContract && units > 0;
    uint256 bal0 = tok.balanceOf(to);
    release(e, loanId, to, units);
    satisfy tok.balanceOf(to) == bal0 + units;
}

rule aRetiredReleaseCanPay(env e, uint256 loanId, address to, uint256 units) {
    require collateralTokenOf(loanId) == tok && to != currentContract && units > 0;
    uint256 bal0 = tok.balanceOf(to);
    releaseRetired(e, loanId, to, units);
    satisfy tok.balanceOf(to) == bal0 + units;
}

rule aReleasePaysOnlyOutOfCustody(env e, method f, uint256 loanId, address who) filtered {
    f -> f.selector == sig:release(uint256,address,uint256).selector || f.selector == sig:releaseRetired(uint256,address,uint256).selector
} {
    require who != currentContract;
    uint256 before = tok.balanceOf(who);
    callOnLoan(e, f, loanId);
    assert tok.balanceOf(who) >= before, "a release took collateral from someone other than the custodian";
}

// call `f` on `loanId`, with every other argument arbitrary
function callOnLoan(env e, method f, uint256 loanId) {
    address a; uint256 u; uint256 other;
    if (f.selector == sig:pull(uint256,address,uint256).selector) { pull(e, loanId, a, u); }
    else if (f.selector == sig:release(uint256,address,uint256).selector) { release(e, loanId, a, u); }
    else if (f.selector == sig:retireCustody(uint256,uint256).selector) { retireCustody(e, loanId, u); }
    else if (f.selector == sig:releaseRetired(uint256,address,uint256).selector) { releaseRetired(e, loanId, a, u); }
    else if (f.selector == sig:carryOut(uint256,uint256).selector) { carryOut(e, loanId, u); }
    else if (f.selector == sig:carryIn(uint256,uint256,uint256).selector) { carryIn(e, other, loanId, u); }
    else { require false; }
}

// ---- THE POT COVERS WHAT IT OWES (I-A, pot side) ----

// the custodian never approves anyone, so only its own verbs can lower its balance; a donation only raises it
invariant thePotCoversTheLedger()
    custodiedOf(tok) <= tok.balanceOf(currentContract)
    filtered { f -> ofTheCustodian(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// ---- THE LEDGER NEVER OUTGROWS CUSTODY, but by an unpaired carry-in ----

persistent ghost mapping(address => mathint) ledgerOf {
    init_state axiom forall address t. ledgerOf[t] == 0;
}

hook Sstore collateralOf[KEY uint256 id] uint256 newV (uint256 oldV) {
    ledgerOf[collateralTokenOf(id)] = ledgerOf[collateralTokenOf(id)] + newV - oldV;
}
hook Sstore retiredOf[KEY uint256 id] uint256 newV (uint256 oldV) {
    ledgerOf[collateralTokenOf(id)] = ledgerOf[collateralTokenOf(id)] + newV - oldV;
}

rule onlyACarryInGrowsTheLedgerPastCustody(env e, method f, calldataarg args, address t)
    filtered { f -> ofTheCustodian(f) && f.selector != sig:carryIn(uint256,uint256,uint256).selector }
{
    mathint gap0 = ledgerOf[t] - custodiedOf(t);
    f(e, args);
    assert ledgerOf[t] - custodiedOf(t) <= gap0, "a verb other than carryIn grew the ledger past custody";
}

// and a carry-in is only ever between two ids on the SAME collateral, out of an id no live loan backs
rule aCarryInStaysOnOneCollateral(env e, uint256 fromId, uint256 toId, uint256 units) {
    carryIn(e, fromId, toId, units);
    assert collateralTokenOf(fromId) == collateralTokenOf(toId), "a carry crossed collaterals";
    assert !liveOf(fromId), "a carry drew on units a live loan still backs";
}
