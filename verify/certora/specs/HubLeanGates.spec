// The hub's READ-ONLY admission gates, summarized as "returns anything, and never reverts".
//
// SOUND FOR ANY ASSERT-ON-EVERY-PATH PROPERTY, and only because each function below is `view` or `pure` (the
// compiler checks the mutability): it writes nothing, so replacing its outputs with arbitrary values and its
// refusals with none admits every real behaviour and more. A property that survives holds of the real code.
// NOT SOUND FOR LIVENESS (a rule that something CAN happen, or never reverts): the summary invents successes.
//
// WHY: the heavy verbs time out on PATH COUNT (2^22 to 2^89), and most of those branches are these refusal
// cascades. A rule about which slots a verb writes -- O13, O2 -- does not need them.
// A summary on a function via-IR inlined is NOT applied; read each run's "unable to locate" lines.
// TOO COARSE IS NOT UNSOUND, BUT IT IS USELESS: a gate whose refusal the property depends on gets a PARTIAL summary
// that keeps that refusal (tryContinue below), or the prover finds a spurious path the real code never takes.

methods {
    // the continuation predicate: every refusal leg of an armed roll, the fold and refinanceByPolicy. PARTIAL: its first
    // leg (a closed loan never continues) is kept, because O13 rests on it; fully arbitrary, it let a closed loan roll
    function Borrower.tryContinue(AceHarness.LoanBook storage, mapping(bytes32 => AceHarness.Market) storage, AceHarness.RollFrames memory, uint256 id, uint256)
        internal returns (bool, bytes4, uint256, uint256) => tryContinueKeepingItsFirstLeg(id);
    // the open path's local refusals and its admission gates
    function Borrower._preChecks(AceHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._gateCheck(AceHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._payoutCheck(AceHarness.Cfg memory, Borrower.OpenArgs memory, uint256) internal returns (uint256) => NONDET;
    function Borrower._previewFloor(AceHarness.Market storage, AceHarness.Cfg memory, uint256, AceHarness.PreAdmitted memory)
        internal returns (uint256) => NONDET;
    function Borrower._gate(uint256, uint256, uint256) internal returns (uint256) => NONDET;
    // the health arithmetic those gates and settlement read: ~20x the paths in `_openFrom` and in `_withdrawCheck` each
    function Borrower.triggerPrice(AceHarness.Loan storage, AceHarness.Cfg memory) internal returns (uint256) => NONDET;
    function Borrower.coverageLine(AceHarness.Cfg memory, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.requiredAt(AceHarness.Cfg memory, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.persistedPrice(AceHarness.Cfg memory) internal returns (uint256) => NONDET;
    function Borrower.cashAdmits(AceHarness.Market storage, uint256, uint256) internal returns (bool) => NONDET;
    function LoanAccounting.fundingFloor(AceHarness.Market storage, AceHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;
}

// The predicate's answer per loan, arbitrary and fixed for the rule, so a case rule can split on it (HubLoansCases.spec).
// A rule that leaves it free covers every answer. One answer per id also covers a batch: a repeated id's second pass
// finds the loan closed, so the real predicate refuses it and that path reverts out of the rule either way.
persistent ghost mapping(uint256 => bool) continueAnswer;

// A PARTIAL summary is still sound: it answers arbitrarily wherever the real predicate might say yes, and keeps the
// one refusal the property needs, so every real answer is among the summary's.
function tryContinueKeepingItsFirstLeg(uint256 id) returns (bool, bytes4, uint256, uint256) {
    bool ok = continueAnswer[id];
    bytes4 reason;
    uint256 principal;
    uint256 cap;
    require closedAtOf(id) != 0 => !ok;
    return (ok, reason, principal, cap);
}
