// Ace hub -- O5, its per-loan leg: the custodian holds exactly a live loan's units, and nothing for a closed one.
//
// The hub's `collateralUnits` and the custodian's `collateralOf` are two ledgers of one lot, written by two contracts.
// Every hub write is paired with a custodian move on the same id: an open pulls or carries in what it books, a
// withdrawal and a deleverage release what they debit, a refund pulls back what it re-credits, a close retires or
// carries out the whole lot. PositionManager.spec proves the custodian's side (O40); this is the pairing, which is
// the hub's alone. The unpaid backstop leans on it: `settleExpired` retires the loan's units, which must be there.
//
// THE CUSTODIAN RUNS FOR REAL, linked both ways as the hub's constructor requires. Under via-IR the hub's custodian
// calls are unresolved, so the dispatch routes them to its six ledger verbs by selector. Every other unresolved call
// takes the default, which is sound here: a ledger cannot move but through those six, and the witnesses below show
// each verb's custodian leg moving `collateralOf`.
//
// Loans and orders share one id counter and one custody map, so an id must never be both: a live order's `release`
// on a loan's id would move a loan's custody with no hub write to match. That is the second invariant.

import "HubLoans.spec";

using PositionManagerHarness as pm;

methods {
    function loanUnitsOf(uint256) external returns (uint256) envfree; // AceHarness
    function pm.collateralOf(uint256) external returns (uint256) envfree;

    // THE TWO STATE-CHANGING CALLS TO CONTRACTS OUTSIDE THE SCENE. Left to AUTO, each havocs every other contract's
    // storage -- the custodian's ledger included -- which failed HubPayer.spec on every open. Neither can move a ledger:
    // the custodian is loan-manager only, and a re-entry into the hub trips its guard.
    function _.mint(uint256, address) external => NONDET; // the title collection, at every open
    function _.permitTransferFrom(IPermit2.PermitTransferFrom, IPermit2.SignatureTransferDetails, address, bytes) external => NONDET;

    unresolved external in _._ => DISPATCH [
        pm.pull(uint256,address,uint256),
        pm.release(uint256,address,uint256),
        pm.retireCustody(uint256,uint256),
        pm.releaseRetired(uint256,address,uint256),
        pm.carryOut(uint256,uint256),
        pm.carryIn(uint256,uint256,uint256)
    ] default NONDET;

    // THE CUSTODIAN'S OWN TOKEN CALLS MOVE TOKENS, NEVER ITS LEDGER, so they do nothing here. Via-IR loses their callee
    // AND selector, so left to the catch-all each inlined all six verbs again, and those their own token calls: the
    // nesting took every verb past the prover's program-size limit (1M commands), `deposit` included.
    unresolved external in pm.pull(uint256,address,uint256) => DISPATCH [] default NONDET;
    unresolved external in pm.release(uint256,address,uint256) => DISPATCH [] default NONDET;
    unresolved external in pm.releaseRetired(uint256,address,uint256) => DISPATCH [] default NONDET;
}

definition aRealClock(env e) returns bool = e.block.timestamp > 0 && e.block.timestamp < 2^64;

// THE CUSTODIAN STARTS EMPTY. An invariant's base case zeroes only the hub's storage, so without this mirror the prover
// began the custodian holding units for an id no loan had (`collateralOf[11410] = 1` after the hub's constructor). A real
// custodian is deployed empty and only the hub can write it, so the ledger is read through a ghost that starts at zero.
ghost mapping(uint256 => uint256) custody {
    init_state axiom forall uint256 i. custody[i] == 0;
}

hook Sload uint256 v pm.collateralOf[KEY uint256 i] {
    require custody[i] == v;
}

hook Sstore pm.collateralOf[KEY uint256 i] uint256 v {
    custody[i] = v;
}

// THE CUSTODIAN'S OWN VERBS ARE OUT: each is loan-manager only (O40's `onlyTheLoanManagerMovesALedger`), so called by
// anyone but the hub it reverts, and the hub reaches them only from inside the verbs checked here.

// A FRESH ID HOLDS NO CUSTODY AND NAMES NO ORDER: an id above the counter was never issued, so nothing was pulled or
// carried into it and no order was posted at it. Without it the prover opens a loan onto stale custody.
invariant aFreshIdHoldsNoCustody(uint256 id)
    id > idCount() => pm.collateralOf(id) == 0 && orderMarketOf(id) == to_bytes32(0)
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant marketZeroIsNeverCreated();
            requireInvariant idZeroIsNeverIssued();
            requireInvariant aFreshIdHasNeverClosed(id);
        }
    }

// AN ID IS A LOAN OR AN ORDER, NEVER BOTH: each is a fresh `++count`, so the one written at an id is the only one.
invariant anIdIsNeverBothALoanAndAnOrder(uint256 id)
    loanMarket(id) == to_bytes32(0) || orderMarketOf(id) == to_bytes32(0)
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant marketZeroIsNeverCreated();
            requireInvariant idZeroIsNeverIssued();
            requireInvariant aFreshIdHasNeverClosed(id);
            requireInvariant aFreshIdHoldsNoCustody(id);
        }
    }

// O5, per loan: a live loan's custody is its units, and a closed loan's is zero
invariant theCustodianHoldsALiveLoansUnits(uint256 id)
    loanMarket(id) != to_bytes32(0) => pm.collateralOf(id) == (closedAtOf(id) == 0 ? loanUnitsOf(id) : 0)
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            require aRealClock(e);
            requireInvariant marketZeroIsNeverCreated();
            requireInvariant idZeroIsNeverIssued();
            requireInvariant aFreshIdHasNeverClosed(id);
            requireInvariant aFreshIdHoldsNoCustody(id);
            requireInvariant anIdIsNeverBothALoanAndAnOrder(id);
            // the ids a verb can issue: a predecessor named at one of them is fresh, so it has no market and reverts
            requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 1));
            requireInvariant aFreshIdHoldsNoCustody(require_uint256(idCount() + 1));
            requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 2));
            requireInvariant aFreshIdHoldsNoCustody(require_uint256(idCount() + 2));
        }
    }

// ---- ANTI-HOLLOW: each custodian leg really moves `collateralOf` through the dispatch ----

// `pull`, by a fresh open
rule anOpenPullsIntoCustody(env e, bytes32 m, uint256 units, uint256 principal, uint64 tenor, address borrower, AceHarness.OpenBounds bnd) {
    uint256 fresh = require_uint256(idCount() + 1);
    require pm.collateralOf(fresh) == 0;
    open(e, m, units, principal, tenor, borrower, bnd);
    satisfy pm.collateralOf(fresh) > 0;
}

// `release`, by a withdrawal
rule aWithdrawalReleasesCustody(env e, uint256 id, uint256 units, address to) {
    uint256 before = pm.collateralOf(id);
    withdrawCollateral(e, id, units, to);
    satisfy pm.collateralOf(id) < before;
}

// `retireCustody`, by the unpaid backstop
rule theBackstopRetiresCustody(env e, uint256 id) {
    uint256 before = pm.collateralOf(id);
    settleExpired(e, id);
    satisfy pm.collateralOf(id) < before;
}

// `carryOut` and `carryIn`, by a fill: the order's custody falls and the fresh loan's rises
rule aFillCarriesCustody(env e, uint256 orderId, uint256 a, uint256 b) {
    uint256 fresh = require_uint256(idCount() + 1);
    require pm.collateralOf(fresh) == 0;
    uint256 before = pm.collateralOf(orderId);
    fillOrder(e, orderId, a, b);
    satisfy pm.collateralOf(orderId) < before && pm.collateralOf(fresh) > 0;
}
