// Ace hub -- O45, first half: a collateral pull names only the caller or the hub as payer.
//
// Users approve the custodian, and the custodian pulls from whatever payer the hub names: PositionManager.spec proves
// it obeys the hub (O40). This is the hub's half -- every `pull` the hub makes names the verb's caller (`open`, an
// order's maker at `postOrder`) or the hub itself (`openWithPermit2` after its permit, deleverage's refund). A carried
// open (a fill, a refinance, a roll) pulls nothing. A pull naming anyone else would drain a third party's approval.
//
// THE CUSTODIAN IS `PullRecorder`, which records every payer it is named. A SIGNATURE SUMMARY IS NOT ENOUGH: under
// via-IR the permit open's and the deleverage refund's `pull` calls are unresolved, and a `_.pull` summary matched
// neither -- the rule passed them by recording nothing, and only their witnesses below showed it. So a resolved `pull`
// is routed to the recorder by the summary and an unresolved one by the dispatch, which matches the runtime selector.
// Every other unresolved call does nothing, as a custodian or token call cannot name a payer.
//
// THE RECORDER'S STORAGE IS NOT THE RECORD. A call the prover resolves by signature to no linked contract -- the
// custodian's other verbs, a token, Permit2 -- is summarized AUTO, which havocs every other contract's storage, the
// recorder's included: `paid[stranger]` turned true on `withdrawCollateral` with no pull made. The record is the two
// persistent ghosts below, written only by store hooks on the recorder, which fire on a real `pull` and never on a havoc.

import "HubLoans.spec";

using PullRecorder as recorder;

methods {
    function _.pull(uint256 id, address from, uint256 units) external => recordPull(id, from, units) expect void;
    function recorder.paid(address) external returns (bool) envfree;
    function recorder.pulls() external returns (uint256) envfree;

    unresolved external in _._ => DISPATCH [
        recorder.pull(uint256,address,uint256)
    ] default NONDET;
}

function recordPull(uint256 id, address from, uint256 units) {
    env e;
    require e.msg.sender == currentContract && e.msg.value == 0;
    recorder.pull(e, id, from, units);
}

persistent ghost mapping(address => bool) named { // some real pull named this address as payer
    init_state axiom forall address a. !named[a];
}

persistent ghost mathint pullsMade { // real pulls recorded
    init_state axiom pullsMade == 0;
}

hook Sstore recorder.paid[KEY address a] bool v {
    if (v) {
        named[a] = true;
    }
}

hook Sstore recorder.pulls uint256 v {
    pullsMade = pullsMade + 1;
}

// O45, first half: whatever the verb, no pull names a stranger -- anyone but the caller and the hub
rule everyPullNamesTheCallerOrTheHub(env e, method f, calldataarg args, address stranger) filtered { f -> freshIdVerb(f) } {
    requireInvariant marketZeroIsNeverCreated();
    requireInvariant idZeroIsNeverIssued();
    require stranger != e.msg.sender && stranger != currentContract;
    require !named[stranger];
    f(e, args);
    assert !named[stranger], "a collateral pull named a payer who is neither the caller nor the hub";
}

// ---- ANTI-HOLLOW: a real pull reaches the hooks at each of the four pull sites ----

rule anOpenPulls(env e, bytes32 id, uint256 units, uint256 principal, uint64 tenor, address borrower, AceHarness.OpenBounds bnd) {
    require pullsMade == 0;
    open(e, id, units, principal, tenor, borrower, bnd);
    satisfy pullsMade > 0;
}

rule aPermitOpenPulls(env e, bytes32 id, uint256 units, uint256 principal, uint64 tenor, address borrower, AceHarness.OpenBounds bnd, bytes permit2) {
    require pullsMade == 0;
    openWithPermit2(e, id, units, principal, tenor, borrower, bnd, permit2);
    satisfy pullsMade > 0;
}

rule aPostPulls(env e, bytes32 market, uint256 principal, uint256 liqLow, uint256 liqHigh, uint256 minFill, uint64 tenor, uint64 expiry) {
    require pullsMade == 0;
    postOrder(e, market, principal, liqLow, liqHigh, minFill, tenor, expiry);
    satisfy pullsMade > 0;
}

rule aDeleverageRefundPulls(env e, uint256 id, uint256 minStableOut, bytes data) {
    require pullsMade == 0;
    deleverage(e, id, minStableOut, data);
    satisfy pullsMade > 0;
}
