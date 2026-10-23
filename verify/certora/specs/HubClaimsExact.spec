// Ace hub -- O10 on `deleverage`, the one verb whose leg needs real arithmetic.
//
// HubClaims.spec proves `aLoanCarriesItsDebtAsItsClaim` on every other verb under an uninterpreted `mulDiv`. A
// deleverage melts the debt and the claim by one `net`, which needs no arithmetic; what does is the positive-debt leg.
// `_fit` caps a sale at `room`, the largest whose proceeds cannot melt the debt under `minDebt`, so the melt leaves at
// least `minDebt` -- and genesis refuses a zero `minDebt`. Uninterpreted, `room` means nothing (it came back past
// 2^128 on a head of one), so here every `mulDiv` is EXACT. A call the real routine refuses (a zero divisor, a result
// past 2^256 - 1) PRUNES its path rather than asserting: this is a safety property, and a reverting path writes nothing.
//
// SPLIT, because the whole invariant came back UNKNOWN at an 8-hour budget. Its preservation under `deleverage(x)` is
// written as two rules that partition the inputs: the loan under proof is the one sold (`x == id`), or it is not. Each
// assumes the invariant of `id` going in and asserts it coming out, which is exactly the invariant's inductive step for
// this verb; its base case is the constructor's, proven in HubClaims.spec. The other-loan case needs no arithmetic,
// only that no write lands on `id`. The own-loan case is the `room` argument: `_owed(room) <= head`, and `_owed` only
// grows with the units, so no fill melts past `head = debt - minDebt`.
//
// THE READ-ONLY GATES ARE SUMMARIZED (HubLeanGates.spec, plus the deleverage path's own view reads below): returning
// anything and never reverting admits every real behaviour of a `view`/`pure` function, so an assert-on-every-path
// property that survives holds of the real code. None of them feeds the melt bound: the sizing may return any `u`,
// the trigger, the band read and the distress read any answer, and `securedBase` any cap, because `room` alone bounds
// what is sold. What stays real is `_fit`'s `room`, the cut and the melt itself. `_owed` answers through the room
// lemma (`owedSummary`), which `theRoomLemmaHolds` proves of the exact ceil.

import "HubLeanGates.spec";

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivDownExact(a, b, d);
    function FullMath.mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivUpExact(a, b, d);

    // the deleverage path's view reads the lean gates do not already cover
    function Borrower.inDistress(AceHarness.Loan storage L, AceHarness.Cfg memory c) internal returns (bool) => NONDET;
    function Borrower.persistedBelowOrRevert(AceHarness.Cfg memory c, uint256 level) internal returns (bool) => NONDET;
    function Borrower.rollNeed(AceHarness.Cfg memory c, uint256 debt, uint64 tenor) internal returns (uint256) => NONDET;
    function LoanAccounting.securedBase(AceHarness.LoanBook storage B, AceHarness.Market storage M, AceHarness.Cfg memory c, uint256 id,
        uint256 units) internal returns (uint256) => NONDET;
    function Deleverage._deleverageSizing(AceHarness.Cfg memory c, uint256 units, uint256 trig, uint256 ps)
        internal returns (uint256, uint256) => NONDET;

    // VIA-IR INLINES `persistedBelowOrRevert`, `rollNeed` and `securedBase` in the own-loan rule, so their summaries above
    // never land there (an earlier run logged "unable to locate" for each). The same answer one call deeper, at
    // what each one calls; every function here is `view` or `pure`, so NONDET still admits every real behaviour.
    // `_belowOrRevert` and `Probe.askWord` are left real: their body is one staticcall to the unlinked record, whose
    // answer the prover already havocs, so a summary there buys little. Summarized too, the witness still passes.
    function Borrower.rollNeed(uint256, uint64, uint256, uint256, uint64) internal returns (uint256) => NONDET;
    function Borrower.successorPrincipal(uint256, uint64, uint256, uint256, uint64) internal returns (uint256) => NONDET;
    function LoanMath.principalForOwed(uint256, uint64, uint256, uint64) internal returns (uint256) => NONDET;
    function Borrower.requiredAt(uint256, uint256, uint256, uint256) internal returns (uint256) => NONDET;
    function LoanAccounting.collateralNeeded(AceHarness.Market storage, AceHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;
    function LoanAccounting.sliverUnits(AceHarness.LoanBook storage, AceHarness.Market storage, AceHarness.Cfg memory, uint256, uint256)
        internal returns (uint256) => NONDET;

    // THE ROOM LEMMA, FACTORED OUT. `_owed` is the one place the own-loan rule needs nonlinear arithmetic: the bill for
    // a sale `_fit` capped at `room` must not exceed the head. Exact, that buried in the whole verb ran 8 hours to 93%.
    // So `_owed` answers anything that keeps the lemma (`owedSummary`), and `theRoomLemmaHolds` proves the exact ceil
    // keeps it. `_fit`, and so `room`, stays real, so a wrong room is still caught.
    function Deleverage._owed(AceHarness.Cfg memory c, uint256 units, uint256 floorPrice) internal returns (uint256)
        => owedSummary(c, units, floorPrice);

    function closedAtOf(uint256) external returns (uint64) envfree; // AceHarness
    function loanMarket(uint256) external returns (bytes32) envfree;
    function loanDebtOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanClaimOf(uint256) external returns (uint256) envfree; // AceHarness: read in the loan's own market
    function marketMinDebtOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree; // AceHarness
}

function mulDivDownExact(uint256 a, uint256 b, uint256 d) returns uint256 {
    require d != 0;
    mathint r = (a * b) / d;
    require r <= max_uint256;
    return require_uint256(r);
}

function mulDivUpExact(uint256 a, uint256 b, uint256 d) returns uint256 {
    require d != 0;
    mathint r = (a * b + d - 1) / d;
    require r <= max_uint256;
    return require_uint256(r);
}

// the head the own-loan rule sells under, set before its call; any value keeps `owedSummary` sound, since the lemma
// holds for every head. PERSISTENT, and that is load-bearing: the sale's outside calls take AUTO summaries, which
// havoc every non-persistent ghost, and a head havocked mid-verb freed `_owed` from the lemma (the 10:15 counterexample)
persistent ghost uint256 headUnderProof;

// `_owed(c, units, p)` is `ceil(p * units * (10000 - eps) / (10000 * unitScale))`. This answers ANY bill that keeps the
// room lemma for `headUnderProof`, which the exact ceil does (`theRoomLemmaHolds`), so it admits the real answer. It never
// reverts, where the real one can on overflow, which only adds paths.
function owedSummary(AceHarness.Cfg c, uint256 units, uint256 floorPrice) returns uint256 {
    uint256 owed;
    mathint e = c.p.deleverageFloorEpsBps;
    mathint s = c.unitScale;
    require (floorPrice > 0 && e < 10000 && s > 0
        && to_mathint(units) <= (headUnderProof * (10000 * s)) / (floorPrice * (10000 - e)))
        => owed <= headUnderProof;
    return owed;
}

// THE ROOM LEMMA, on the exact formulas: `_fit`'s `room = floor(head * 10000 * S / (ps * (10000 - eps)))`, and `_owed`'s
// ceil bill on any `u <= room` is at most `head`. It is why a melt never takes the debt under `minDebt`.
rule theRoomLemmaHolds(uint256 h, uint256 u, uint256 p, uint256 e, uint256 s) {
    require p > 0 && e < 10000 && s > 0;
    require to_mathint(u) <= (h * (10000 * s)) / (p * (10000 - e));
    assert (p * (u * (10000 - e)) + 10000 * s - 1) / (10000 * s) <= to_mathint(h);
}

// O10, as HubClaims.spec states it: an issued loan, while live, carries its debt as its claim and a positive debt
function claimIsDebt(uint256 id) returns bool {
    return loanMarket(id) != to_bytes32(0) => (
        closedAtOf(id) == 0
            ? (loanClaimOf(id) == loanDebtOf(id) && loanDebtOf(id) > 0)
            : loanClaimOf(id) == 0
    );
}

function railsHold(bytes32 m) returns bool {
    uint256 cover; uint256 scale; uint256 price;
    cover, scale, price = marketRailsOf(m);
    return cover >= 105 * 10^16 && cover <= 20 * 10^18 && scale == 2^96 && price > 0 && price <= 2^224
        && marketMinDebtOf(m) > 0;
}

// the invariant's preserved block, for the loan under proof and the loan being sold
function deleveragePremises(env e, uint256 id, uint256 x) {
    require e.msg.sender != currentContract;
    require e.block.timestamp > 0 && e.block.timestamp < 2^64; // the chain's clock (HubClaims.spec, aRealClock)
    // PROVEN IN HubClaims.spec, which this spec cannot import (its `mulDiv` is the uninterpreted one):
    // aLoanSitsInACreatedMarket and aCreatedMarketKeepsItsRails give every loan its market's rails. A fixed unit
    // scale is what keeps the arithmetic linear.
    require loanMarket(id) != to_bytes32(0) => railsHold(loanMarket(id));
    require loanMarket(x) != to_bytes32(0) => railsHold(loanMarket(x));
    require claimIsDebt(id);
}

// the head `deleverage(id)` computes, `saturatingSub(debt, minDebt)`, pinned for `owedSummary` before the call
function pinTheHead(uint256 id) {
    uint256 debt = loanDebtOf(id);
    uint256 minDebt = marketMinDebtOf(loanMarket(id));
    require to_mathint(headUnderProof) == (debt > minDebt ? debt - minDebt : 0);
}

// case 1 of 2: another loan is sold, and nothing it writes lands on the loan under proof
rule claimIsDebtWhenAnotherLoanDeleverages(env e, uint256 id, uint256 x, uint256 minStableOut, bytes data) {
    require x != id;
    deleveragePremises(e, id, x);
    deleverage(e, x, minStableOut, data);
    assert claimIsDebt(id), "selling another loan moved this loan's claim, debt or close";
}

// case 2 of 2: the loan under proof is the one sold; the `room` cap keeps its debt at or above `minDebt`
rule claimIsDebtWhenItDeleverages(env e, uint256 id, uint256 minStableOut, bytes data) {
    deleveragePremises(e, id, id);
    pinTheHead(id);
    deleverage(e, id, minStableOut, data);
    assert claimIsDebt(id), "a deleverage melted the claim off the debt, or melted a live loan's debt to zero";
}

// the witness: under the same premises a sale really melts the debt, so case 2 is not vacuous on the path it is for
rule aDeleverageMeltsTheDebt(env e, uint256 id, uint256 minStableOut, bytes data) {
    deleveragePremises(e, id, id);
    pinTheHead(id);
    uint256 before = loanDebtOf(id);
    deleverage(e, id, minStableOut, data);
    satisfy loanDebtOf(id) < before;
}
