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
// that keeps that refusal, or the prover finds a spurious path the real code never takes. None needs one now:
// `extend`'s predicate keeps its closed-loan leg real, since only its later legs are summarized.

methods {
    // the borrower's extension legs past its closed-loan, caller, matured and no-time tests: the record, admission, the policy
    function Borrower.tryRecordState(AceHarness.Cfg memory) internal returns (bool, AceHarness.RecordState, uint256) => NONDET;
    function Borrower._admissibleLeg(AceHarness.Cfg memory, uint256, uint256, uint256, uint256) internal returns (bytes4) => NONDET;
    function Probe.askBool(address, bytes memory, uint256, bytes32) internal returns (bool) => NONDET;
    // the open path's local refusals and its admission gates
    function Borrower._preChecks(AceHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._gateCheck(AceHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._payoutCheck(AceHarness.Cfg memory, Borrower.OpenArgs memory, uint256) internal returns (uint256) => NONDET;
    function Borrower._previewFloor(AceHarness.Market storage, AceHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;
    function Borrower._gate(uint256, uint256, uint256) internal returns (uint256) => NONDET;
    // the health arithmetic those gates and settlement read: ~20x the paths in `_openFrom` and in `_withdrawCheck` each
    function Borrower.triggerPrice(AceHarness.Loan storage, AceHarness.Cfg memory) internal returns (uint256) => NONDET;
    function Borrower.coverageLine(AceHarness.Cfg memory, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.requiredAt(AceHarness.Cfg memory, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.persistedPrice(AceHarness.Cfg memory) internal returns (uint256) => NONDET;
    function LoanAccounting.fundingFloor(AceHarness.Market storage, AceHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;
}
