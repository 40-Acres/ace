// Ace hub -- O5's three custody invariants again, with the deleverage keeper's callback summarized as NONDET.
//
// HubCustody.spec leaves `onAceDeleverage` to the prover's default, and on prover 8.20.3 that default is an AUTO summary:
// a havoc of every other contract's storage, the custodian's ledger included. Both deleverage counterexamples on main
// (`aFreshIdHoldsNoCustody`, `theCustodianHoldsALiveLoansUnits`) are exactly that havoc writing `collateralOf` of a loan
// the sale does not name. No keeper can make that write: the custodian's ledger verbs are loan-manager only, so they
// revert for any caller but the hub, and a re-entry into the hub reverts on its guard. So the callback moves none of the
// state these invariants read, which is what NONDET (only its return havocked; it returns nothing) says.
// HubSolvency.spec and HubAttribution.spec summarize it the same way.
//
// A NEW SPEC RATHER THAN AN EDIT: HubCustody.spec is one of the specs PR #843 restructures. This file adds the one summary
// and a witness, and re-uses the three invariants with their preserved blocks unchanged. Only `deleverage` calls the
// callback, so every other verb's step is the same proof obligation HubCustody.conf already discharges.

import "HubCustody.spec";

methods {
    function _.onAceDeleverage(uint256, uint256, bytes) external => NONDET;
}

use invariant aFreshIdHoldsNoCustody;
use invariant anIdIsNeverBothALoanAndAnOrder;
use invariant theCustodianHoldsALiveLoansUnits;

// ANTI-HOLLOW: with the callback summarized, a deleverage still runs the custodian's real `release` on the loan it sells
rule aDeleverageReleasesCustody(env e, uint256 id, uint256 minStableOut, bytes data) {
    uint256 before = pm.collateralOf(id);
    deleverage(e, id, minStableOut, data);
    satisfy pm.collateralOf(id) < before;
}
