// Ace.extend's I2 grid rule on `createMarket`, with the one premise its counterexample lacked.
//
// `Extend.spec`'s `aLoansTenorStaysOnItsGrid` FAILS on `createMarket` alone: its counterexample's loan sits in a market
// whose params read zero, so the market was never created, and `createMarket` then creates exactly that id and writes a
// grid the loan's tenor is off. No reachable state has a loan in an uncreated market: HubClaims.spec's
// `aLoanSitsInACreatedMarket` (an issued loan's market has a non-zero quote) is proven on every verb. This rule is the
// same statement with that fact required of the loan in the pre-state, so the two together are the grid rule on
// `createMarket`; MarketInit's `MarketExists` refusal is what the premise lets the prover see.
//
// A NEW SPEC RATHER THAN AN EDIT, written while `Extend.spec`'s rule lacked the premise. `Extend.spec`'s rule now carries it
// (`anIssuedLoanIsCountedAndCreated`, #867), so this one restates it on `createMarket` and its verdict is recorded as it ran.

import "Extend.spec";

// the loan's market is created, as HubClaims.spec's `aLoanSitsInACreatedMarket` proves of every issued loan
function aCreatedHome(uint256 id) returns bool {
    address q; uint256 cash; uint256 rev; uint256 pot;
    q, cash, rev, pot = marketOf(homeOf(id));
    return q != 0;
}

rule aLoansTenorStaysOnItsGridInACreatedMarket(env e, method f, calldataarg args, uint256 id) filtered { f -> !f.isView } {
    require e.msg.sender != currentContract && aRealClock(e);
    require homeOf(id) != to_bytes32(0) => (onItsGrid(id) && aCreatedHome(id));

    f(e, args);

    assert homeOf(id) != to_bytes32(0) => onItsGrid(id), "an issued loan's tenor left its market's grid";
}
