// Ace hub -- O45, second half: no allowance the hub grants outlives the verb that granted it.
//
// The hub approves in exactly two places, both to the custodian on collateral: the permit open stages its units
// (Borrower.pullCollateralPermit) and a deleverage re-credits its refund (Deleverage._recreditRefund). Each approval is
// for exactly what the custodian's next `pull` takes from the hub, so the allowance is spent to zero inside the verb.
// A residue would let the custodian -- or, for a wrong spender, anyone -- pull the hub's units later.
//
// THE TOKEN IS DummyERC20, which always spends allowance on `transferFrom`, and the custodian runs for real. Under
// via-IR every token call and every custodian call is unresolved, so the dispatch routes each by selector: EVERY
// `approve` the hub makes lands in the one token model, whatever token it named. That over-approximates on purpose --
// the rule then covers a hub approval on any token, and a quote and a collateral may alias, which only adds behaviours.
// Permit2 and every other unresolved call take the default, which moves no modelled token.
//
// THE KEEPER IS DeleverageKeeper, which hands an arbitrary `giveBack` of the units it was sent back to the hub. Left to
// the default, the callback would move nothing, the refund would always be zero, and the rule would pass deleverage
// without ever meeting its approval -- the refund witness below is what shows it does.

import "HubLoans.spec";

using PositionManagerHarness as pm;
using DummyERC20 as token;
using DeleverageKeeper as keeper;

methods {
    function token.allowance(address, address) external returns (uint256) envfree;

    // THE TWO STATE-CHANGING CALLS TO CONTRACTS OUTSIDE THE SCENE. Left to AUTO, each havocs every other contract's
    // storage -- the token model's allowances included -- which failed HubPayer.spec on every open. Neither can move
    // an allowance the hub granted: only the hub approves for itself, and a re-entry into the hub trips its guard.
    function _.mint(uint256, address) external => NONDET; // the title collection, at every open
    function _.permitTransferFrom(IPermit2.PermitTransferFrom, IPermit2.SignatureTransferDetails, address, bytes) external => NONDET;

    unresolved external in _._ => DISPATCH [
        token.approve(address,uint256),
        token.transfer(address,uint256),
        token.transferFrom(address,address,uint256),
        token.balanceOf(address),
        pm.pull(uint256,address,uint256),
        pm.release(uint256,address,uint256),
        pm.retireCustody(uint256,uint256),
        pm.releaseRetired(uint256,address,uint256),
        pm.carryOut(uint256,uint256),
        pm.carryIn(uint256,uint256,uint256),
        keeper.onAceDeleverage(uint256,uint256,bytes)
    ] default NONDET;

    // INSIDE THE CUSTODIAN, ITS TOKEN CALLS GO TO THE TOKEN MODEL ALONE. Via-IR loses their callee and selector, so left
    // to the catch-all each inlined every target above again, the custodian's verbs among them, and the nesting took
    // HubCustody.spec past the prover's program-size limit. `pull`'s `transferFrom` is what spends the hub's allowance.
    unresolved external in pm.pull(uint256,address,uint256)
        => DISPATCH [ token.transferFrom(address,address,uint256), token.balanceOf(address) ] default NONDET;
    unresolved external in pm.release(uint256,address,uint256)
        => DISPATCH [ token.transfer(address,uint256), token.balanceOf(address) ] default NONDET;
    unresolved external in pm.releaseRetired(uint256,address,uint256)
        => DISPATCH [ token.transfer(address,uint256), token.balanceOf(address) ] default NONDET;
}

// WITNESS MIRROR: set when the hub writes a non-zero allowance, so the witnesses can show an approval really landed.
persistent ghost bool hubApproved {
    init_state axiom !hubApproved;
}

hook Sstore token.allowance[KEY address owner][KEY address spender] uint256 v {
    if (owner == currentContract && v > 0) {
        hubApproved = true;
    }
}

// O45, second half: whatever the verb, the hub ends it owing no allowance it did not owe before
rule noHubAllowanceOutlivesItsVerb(env e, method f, calldataarg args, address spender) filtered { f -> freshIdVerb(f) } {
    requireInvariant marketZeroIsNeverCreated();
    requireInvariant idZeroIsNeverIssued();
    require e.msg.sender != currentContract && e.msg.sender != pm;
    require token.allowance(currentContract, spender) == 0;
    f(e, args);
    assert token.allowance(currentContract, spender) == 0, "an allowance the hub granted outlived its verb";
}

// ---- ANTI-HOLLOW: both approvals really land in the model, so the rule sees them spent ----

rule aPermitOpenApproves(env e, bytes32 m, uint256 units, uint256 principal, uint64 tenor, address borrower, AceHarness.OpenBounds bnd, bytes permit2) {
    require !hubApproved;
    openWithPermit2(e, m, units, principal, tenor, borrower, bnd, permit2);
    satisfy hubApproved;
}

rule aDeleverageRefundApproves(env e, uint256 id, uint256 minStableOut, bytes data) {
    require !hubApproved;
    deleverage(e, id, minStableOut, data);
    satisfy hubApproved;
}
