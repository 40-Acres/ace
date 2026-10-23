// O13 on the heavy verbs, CASE BY CASE: the same assertion as HubLoans.spec's `aClosedLoanStaysClosed`, called per verb
// with the inputs SPLIT so each case is a smaller problem, and the read-only gates summarized (HubLeanGates.spec).
//
// TWO WALLS, TWO SPLITS. Paths MULTIPLY across a verb's stages, and the lean gates cut `refinance` from ~2^16 to ~2^12;
// what was left is ALIASING: a migration makes ~230 storage writes and the solver had to rule out each one landing on
// the closed loan. A migration opens its successor at `idCount() + 1`, so each verb is split on whether the closed loan
// sits at that fresh id. Unsplit, these ran 8 hours unfinished. A call naming the closed loan itself refuses at its
// guard, but the solver still has to discharge that refusal, and inside a fresh-id case it stalled `refinance` for 8
// hours; moved into the complement (`...OtherwiseOrSelf`) the fresh-id cases settled. KEEP THE SELF CELL OUT OF A
// HARD CASE. The fresh-id cases are also UNREACHABLE: `aFreshIdHasNeverClosed` (HubLoans.spec) says no id past the
// counter is closed, so wherever that invariant holds, the complement rule plus it is the whole of O13 for the verb.
//
// A SPLIT IS ONLY SOUND IF ITS CASES COVER EVERY INPUT. Each verb's preconditions are written as an explicit partition,
// so their union is the unrestricted rule. The one bound that is not a partition is the global loop bound:
// `refinanceByPolicies` is covered for batches of at most two, as everywhere in this lane. Each case carries its own
// vacuity check (`rule_sanity: basic`). NO `@withrevert` ON A SINGLE-VERB CALL: it crashes this prover on the hub
// ("a TAC program with multiple roots"), with the summaries and without them.

import "HubLoans.spec";
import "HubLeanGates.spec";

methods {
    function autoTenorOf(uint256) external returns (uint64) envfree; // AceHarness: zero is disarmed
}

// the rule's frame: the loan is closed going in; each case calls one verb, then asserts the close stands
function closedGoingIn(uint256 loanId) returns uint64 {
    uint64 closed = closedAtOf(loanId);
    require closed != 0;
    return closed;
}

// ---- refinance: the closed loan is at the fresh id (unarmed / armed) / it is not. A fresh-id case writes the new loan
// onto the closed one's record, and an armed one also re-reserves its roll there.

rule closedStaysClosedRefinanceFreshIdUnarmed(env e, uint256 loanId, uint256 id, uint256 newPrincipal, uint64 newTenor, AceHarness.OpenBounds bnd) {
    require to_mathint(loanId) == idCount() + 1 && id != loanId && autoTenorOf(id) == 0;
    uint64 closed = closedGoingIn(loanId);
    refinance(e, id, newPrincipal, newTenor, bnd);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceFreshIdArmed(env e, uint256 loanId, uint256 id, uint256 newPrincipal, uint64 newTenor, AceHarness.OpenBounds bnd) {
    require to_mathint(loanId) == idCount() + 1 && id != loanId && autoTenorOf(id) != 0;
    uint64 closed = closedGoingIn(loanId);
    refinance(e, id, newPrincipal, newTenor, bnd);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceOtherwise(env e, uint256 loanId, uint256 id, uint256 newPrincipal, uint64 newTenor, AceHarness.OpenBounds bnd) {
    require to_mathint(loanId) != idCount() + 1;
    uint64 closed = closedGoingIn(loanId);
    refinance(e, id, newPrincipal, newTenor, bnd);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

// the complement of the fresh-id cases: Otherwise plus the closed loan refinancing itself at the fresh id
rule closedStaysClosedRefinanceOtherwiseOrSelf(env e, uint256 loanId, uint256 id, uint256 newPrincipal, uint64 newTenor, AceHarness.OpenBounds bnd) {
    require to_mathint(loanId) != idCount() + 1 || id == loanId;
    uint64 closed = closedGoingIn(loanId);
    refinance(e, id, newPrincipal, newTenor, bnd);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

// ---- refinanceTo: the fresh id (unarmed / armed) / otherwise, the latter split on the withdrawal leg (none / some)

rule closedStaysClosedRefinanceToFreshIdUnarmed(env e, uint256 loanId, AceHarness.MigrateArgs m) {
    require to_mathint(loanId) == idCount() + 1 && autoTenorOf(m.id) == 0;
    uint64 closed = closedGoingIn(loanId);
    refinanceTo(e, m);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceToFreshIdArmed(env e, uint256 loanId, AceHarness.MigrateArgs m) {
    require to_mathint(loanId) == idCount() + 1 && autoTenorOf(m.id) != 0;
    uint64 closed = closedGoingIn(loanId);
    refinanceTo(e, m);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceToOtherwiseNoLeg(env e, uint256 loanId, AceHarness.MigrateArgs m) {
    require to_mathint(loanId) != idCount() + 1 && m.withdrawUnits == 0 && m.withdrawTo == 0;
    uint64 closed = closedGoingIn(loanId);
    refinanceTo(e, m);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceToOtherwiseWithLeg(env e, uint256 loanId, AceHarness.MigrateArgs m) {
    require to_mathint(loanId) != idCount() + 1 && (m.withdrawUnits != 0 || m.withdrawTo != 0);
    uint64 closed = closedGoingIn(loanId);
    refinanceTo(e, m);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

// ---- the policy verbs: the same two. A call naming the closed loan refuses at the predicate's kept closed-loan leg,
// which `aClosedLoanNeverContinues` proves on the real predicate.

rule closedStaysClosedRefinanceByPolicyFreshIdUnarmed(env e, uint256 loanId, uint256 id) {
    require to_mathint(loanId) == idCount() + 1 && autoTenorOf(id) == 0;
    uint64 closed = closedGoingIn(loanId);
    refinanceByPolicy(e, id);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceByPolicyFreshIdArmed(env e, uint256 loanId, uint256 id) {
    require to_mathint(loanId) == idCount() + 1 && autoTenorOf(id) != 0;
    uint64 closed = closedGoingIn(loanId);
    refinanceByPolicy(e, id);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceByPolicyOtherwise(env e, uint256 loanId, uint256 id) {
    require to_mathint(loanId) != idCount() + 1;
    uint64 closed = closedGoingIn(loanId);
    refinanceByPolicy(e, id);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceByPolicyToFreshIdUnarmed(env e, uint256 loanId, uint256 id, bytes32 dst) {
    require to_mathint(loanId) == idCount() + 1 && autoTenorOf(id) == 0;
    uint64 closed = closedGoingIn(loanId);
    refinanceByPolicyTo(e, id, dst);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceByPolicyToFreshIdArmed(env e, uint256 loanId, uint256 id, bytes32 dst) {
    require to_mathint(loanId) == idCount() + 1 && autoTenorOf(id) != 0;
    uint64 closed = closedGoingIn(loanId);
    refinanceByPolicyTo(e, id, dst);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceByPolicyToOtherwise(env e, uint256 loanId, uint256 id, bytes32 dst) {
    require to_mathint(loanId) != idCount() + 1;
    uint64 closed = closedGoingIn(loanId);
    refinanceByPolicyTo(e, id, dst);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

// ---- refinanceByPolicies: a batch writes up to four loans -- its ids and the fresh ids `idCount() + 1` and `+ 2` --
// so the closed loan is in the batch (the call reverts) / at a fresh id / neither

definition inBatch(uint256 loanId, uint256[] ids) returns bool =
    (ids.length > 0 && ids[0] == loanId) || (ids.length > 1 && ids[1] == loanId);

rule continuingAClosedLoanInABatchReverts(env e, uint256 loanId, uint256[] ids) {
    require inBatch(loanId, ids);
    uint64 closed = closedGoingIn(loanId);
    refinanceByPolicies@withrevert(e, ids);
    assert lastReverted, "a closed loan was continued";
}

rule closedStaysClosedRefinanceByPoliciesAtNextId(env e, uint256 loanId, uint256[] ids) {
    require !inBatch(loanId, ids) && (to_mathint(loanId) == idCount() + 1 || to_mathint(loanId) == idCount() + 2);
    uint64 closed = closedGoingIn(loanId);
    refinanceByPolicies(e, ids);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedRefinanceByPoliciesDistinct(env e, uint256 loanId, uint256[] ids) {
    require !inBatch(loanId, ids) && to_mathint(loanId) != idCount() + 1 && to_mathint(loanId) != idCount() + 2;
    uint64 closed = closedGoingIn(loanId);
    refinanceByPolicies(e, ids);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

// ---- openWithPermit2: one case. A fresh open writes no `closedAt`, so this only has to see past its branching.

rule closedStaysClosedOpenWithPermit2(
    env e, uint256 loanId, bytes32 id, uint256 units, uint256 principal, uint64 tenor, address borrower, AceHarness.OpenBounds bnd, bytes permit2
) {
    uint64 closed = closedGoingIn(loanId);
    openWithPermit2(e, id, units, principal, tenor, borrower, bnd, permit2);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

// ---- forceClose: unarmed (settles) / armed and the predicate refuses (settles) / armed and it admits (rolls).
// The last two split on the summarized predicate's answer, `continueAnswer`, which is free in a rule that does not fix it.

rule closedStaysClosedForceCloseUnarmed(env e, uint256 loanId, uint256 id) {
    require autoTenorOf(id) == 0;
    uint64 closed = closedGoingIn(loanId);
    forceClose(e, id);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedForceCloseArmedSettles(env e, uint256 loanId, uint256 id) {
    require autoTenorOf(id) != 0 && !continueAnswer[id];
    uint64 closed = closedGoingIn(loanId);
    forceClose(e, id);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

// the roll, split as a migration is: the closed loan at the fresh id / not

rule closedStaysClosedForceCloseRollsFreshId(env e, uint256 loanId, uint256 id) {
    require autoTenorOf(id) != 0 && continueAnswer[id];
    require to_mathint(loanId) == idCount() + 1;
    uint64 closed = closedGoingIn(loanId);
    forceClose(e, id);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

rule closedStaysClosedForceCloseRollsOtherwise(env e, uint256 loanId, uint256 id) {
    require autoTenorOf(id) != 0 && continueAnswer[id];
    require to_mathint(loanId) != idCount() + 1;
    uint64 closed = closedGoingIn(loanId);
    forceClose(e, id);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}
