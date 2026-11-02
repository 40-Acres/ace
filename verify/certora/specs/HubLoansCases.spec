// O13 on the heavy verbs, CASE BY CASE: the same assertion as HubLoans.spec's `aClosedLoanStaysClosed`, called per verb
// with the inputs SPLIT so each case is a smaller problem, and the read-only gates summarized (HubLeanGates.spec).
//
// TWO WALLS, TWO SPLITS. Paths MULTIPLY across a verb's stages, and the lean gates cut the deleted `refinance` (today's
// `refinanceTo` aimed home) from ~2^16 to ~2^12; what was left is ALIASING: a migration makes ~230 storage writes and the
// solver had to rule out each one landing on the closed loan. A migration opens its successor at `idCount() + 1`, so it is
// split on whether the closed loan sits at that fresh id. Unsplit, these ran 8 hours unfinished. A call naming the closed
// loan itself refuses at its guard, but the solver still has to discharge that refusal, and inside a fresh-id case it
// stalled `refinance` for 8 hours until moved into the complement. KEEP THE SELF CELL OUT OF A HARD CASE. The fresh-id
// cases are also UNREACHABLE: `aFreshIdHasNeverClosed` (HubLoans.spec) says no id past the counter is closed, so wherever
// that invariant holds, the complement rule plus it is the whole of O13 for the verb.
//
// A SPLIT IS ONLY SOUND IF ITS CASES COVER EVERY INPUT. Each verb's preconditions are written as an explicit partition,
// so their union is the unrestricted rule. Each case carries its own vacuity check (`rule_sanity: basic`). NO
// `@withrevert` ON A SINGLE-VERB CALL: it crashes this prover on the hub ("a TAC program with multiple roots"), with the
// summaries and without them.

import "HubLoans.spec";
import "HubLeanGates.spec";

// the rule's frame: the loan is closed going in; each case calls one verb, then asserts the close stands
function closedGoingIn(uint256 loanId) returns uint64 {
    uint64 closed = closedAtOf(loanId);
    require closed != 0;
    return closed;
}

// ---- refinanceTo: the fresh id / otherwise, the latter split on the withdrawal leg (none / some).
// Into the loan's own market it is the re-term the deleted `refinance` was, so these three cover that verb's inputs too.

rule closedStaysClosedRefinanceToFreshId(env e, uint256 loanId, AceHarness.MigrateArgs m) {
    require to_mathint(loanId) == idCount() + 1;
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

// ---- openWithPermit2: one case. A fresh open writes no `closedAt`, so this only has to see past its branching.

rule closedStaysClosedOpenWithPermit2(
    env e, uint256 loanId, bytes32 id, uint256 units, uint256 principal, uint64 tenor, address borrower, AceHarness.OpenBounds bnd, bytes permit2
) {
    uint64 closed = closedGoingIn(loanId);
    openWithPermit2(e, id, units, principal, tenor, borrower, bnd, permit2);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}

// ---- forceClose: one case. It only settles, writes only the loan it names, and issues no fresh id to split on.

rule closedStaysClosedForceClose(env e, uint256 loanId, uint256 id) {
    uint64 closed = closedGoingIn(loanId);
    forceClose(e, id);
    assert closedAtOf(loanId) == closed, "a closed loan reopened or was re-dated";
}
