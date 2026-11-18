// Ace hub -- O45's allowance half on `deleverage`, with the keeper's callback routed to the keeper model the spec intends.
//
// HubAllowance.spec models the keeper as DeleverageKeeper and lists `keeper.onAceDeleverage` in its catch-all DISPATCH, so the
// callback hands an arbitrary `giveBack` of units back and the refund approval is really met. On prover 8.20.3 the call no
// longer reaches that catch-all: `IAceDeleverageCallback(msg.sender).onAceDeleverage(...)` gets an AUTO summary, which
// havocs every other contract's storage, the token model's allowances included. The one counterexample on main
// (`noHubAllowanceOutlivesItsVerb` on `deleverage`) is that havoc leaving an allowance standing, with the hub's own approve
// taking the dispatch's default, so no approval of the hub's was ever written. A real keeper cannot raise an allowance the
// hub owns: DummyERC20's `approve` writes only its caller's row, and spending one only lowers it.
//
// DISPATCHER(true) runs DeleverageKeeper's body for the callback, which is the keeper HubAllowance.spec's header says the
// scene stands in for, so the property is checked against the model it was written for. A NEW spec rather than an edit, as
// HubCustodyKeeper.spec does for the same 8.20.3 behaviour; only `deleverage` calls the callback.

import "HubAllowance.spec";

methods {
    function _.onAceDeleverage(uint256, uint256, bytes) external => DISPATCHER(true);
}

// the refund witness is re-used as the anti-hollow check: its trace must show DeleverageKeeper's body running
use rule noHubAllowanceOutlivesItsVerb;
use rule aDeleverageRefundApproves;
