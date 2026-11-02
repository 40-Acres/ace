// Ace hub -- O10 on `deleverage`, the one verb whose leg needs real arithmetic.
//
// HubClaims.spec proves `aLoanCarriesItsDebtAsItsClaim` on every other verb under an uninterpreted `mulDiv`. A
// deleverage either RESTORES or CLOSES. A restore melts the debt and the claim by one `net`; a close melts the whole
// debt and the whole claim, then retires the loan. Neither needs arithmetic; what does is the restore's positive-debt
// leg. THE CLOSE DECISION routes a crank to the close whenever the full fill's net melt would leave the debt under
// the debt floor, half `minPrincipal`, so a restore keeps `debt >= floor + net(owed(sold))`, and a fill of at most `sold`
// melts no more -- genesis keeps the floor positive. Uninterpreted, a bill means nothing, so every `mulDiv` is EXACT. A call the
// real routine refuses (a zero divisor, a result past 2^256 - 1, a checked subtraction that would wrap) PRUNES its path
// rather than asserting: this is a safety property, and a reverting path writes nothing.
//
// SPLIT, because the whole invariant came back UNKNOWN at an 8-hour budget. Its preservation under `deleverage(x)` is
// written as two rules that partition the inputs: the loan under proof is the one sold (`x == id`), or it is not. Each
// assumes the invariant of `id` going in and asserts it coming out, which is exactly the invariant's inductive step for
// this verb; its base case is the constructor's, proven in HubClaims.spec. The other-loan case needs no arithmetic,
// only that no write lands on `id`. The own-loan case is the decision argument: the bill only grows with the units and
// the net melt only grows with the bill, so no restore fill melts past `debt - floor`.
//
// THE READ-ONLY GATES ARE SUMMARIZED (HubLeanGates.spec, plus the deleverage path's own view reads below): returning
// anything and never reverting admits every real behaviour of a `view`/`pure` function, so an assert-on-every-path
// property that survives holds of the real code. None of them feeds the melt bound: the sizing may return any `u`,
// the trigger, the band read and the distress read any answer, and `securedBase` any cap, because the decision alone
// bounds what a restore melts. What stays real is `_fit`, the decision, the close's size and the melt itself. `_owed`
// and `_cut` answer through MONOTONE ghosts (`owedG`, `cutG`), which `theBillIsMonotoneInUnits` and
// `theNetMeltIsMonotone` prove of the exact formulas; `theDecisionBoundsEveryRestoreFill` composes the two on the exact
// formulas, and `theCloseLemmaHolds` proves the close's size is the exact inverse of the bill.

import "HubLeanGates.spec";

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivDownExact(a, b, d);
    // NO SUMMARY for mulDivRoundingUp: via-IR eliminates that wrapper, so one cannot bind and requesting it FAILS the run.
    // Exactness survives: its body is `mulDiv` plus a `mulmod` ceil bit, and `mulDiv` is summarized exact just above, so
    // the ceiling is DERIVED from the floor rather than asserted by a second formula. See HubLoans.spec.

    // the deleverage path's view reads the lean gates do not already cover
    function Borrower.inDistress(AceHarness.Loan storage L, AceHarness.Cfg memory c) internal returns (bool) => NONDET;
    function Borrower.persistedBelowOrRevert(AceHarness.Cfg memory c, uint256 level) internal returns (bool) => NONDET;
    function LoanAccounting.securedBase(AceHarness.LoanBook storage B, AceHarness.Market storage M, AceHarness.Cfg memory c, uint256 id,
        uint256 units) internal returns (uint256) => NONDET;
    function Deleverage._deleverageSizing(AceHarness.Cfg memory c, uint256 units, uint256 trig, uint256 ps)
        internal returns (uint256, uint256) => NONDET;

    // VIA-IR INLINES `persistedBelowOrRevert` and `securedBase` in the own-loan rule, so their summaries above
    // never land there (an earlier run logged "unable to locate" for each). The same answer one call deeper, at
    // what each one calls; every function here is `view` or `pure`, so NONDET still admits every real behaviour.
    // `_belowOrRevert` and `Probe.askWord` are left real: their body is one staticcall to the unlinked record, whose
    // answer the prover already havocs, so a summary there buys little. Summarized too, the witness still passes.
    function Borrower.requiredAt(uint256, uint256, uint256, uint256) internal returns (uint256) => NONDET;
    function LoanAccounting.collateralNeeded(AceHarness.Market storage, AceHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;
    function LoanAccounting.sliverUnits(AceHarness.LoanBook storage, AceHarness.Market storage, AceHarness.Cfg memory, uint256, uint256)
        internal returns (uint256) => NONDET;

    // THE TWO NONLINEAR STEPS, FACTORED OUT. The own-loan rule needs the bill at the decision's size and at the fill's
    // to be ordered, and the net melt to keep that order through the cut. Exact, the old bound buried in the whole verb
    // ran 8 hours to 93%. So both answer through ghosts that keep only the order (`owedG`, `cutG`), and the lemma rules
    // prove the exact formulas keep it. `_fit` and the decision stay real, so a wrong decision is still caught.
    // TWO INLINING CASES, AND ONLY ONE IS BENIGN. If via-IR inlines a CALL SITE while the function survives, the summary
    // still binds elsewhere and the real arithmetic runs under the exact `mulDiv`: sound, only slower. If it ELIMINATES
    // the function, no summary can bind and the prover FAILS the run outright rather than warning -- measured on
    // `FullMath.mulDivRoundingUp`, 674 errors across every verb. So read each run's unresolved lines for these two names.
    function Deleverage._owed(AceHarness.Cfg memory c, uint256 units, uint256 floorPrice) internal returns (uint256)
        => owedSummary(c, units, floorPrice);
    function Deleverage._cut(AceHarness.Cfg memory c, uint256 gross, bool charge) internal returns (uint256)
        => cutSummary(c, gross, charge);

    function closedAtOf(uint256) external returns (uint64) envfree; // AceHarness
    function loanMarket(uint256) external returns (bytes32) envfree;
    function loanDebtOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanClaimOf(uint256) external returns (uint256) envfree; // AceHarness: read in the loan's own market
    function marketMinPrincipalOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketDebtFloorOf(bytes32) external returns (uint256) envfree; // AceHarness: `LoanMath.debtFloor`
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree; // AceHarness
}

function mulDivDownExact(uint256 a, uint256 b, uint256 d) returns uint256 {
    require d != 0;
    mathint r = (a * b) / d;
    require r <= max_uint256;
    return require_uint256(r);
}

// The keeper's bill, keyed by (eps, unit scale, floor price, units): ANY answer that never falls as the units grow.
// PERSISTENT, and that is load-bearing: the sale's outside calls take AUTO summaries, which havoc every non-persistent
// ghost, and a bill havocked between the decision and the fill would unorder the two (the room lemma's 10:15
// counterexample was that failure). Sound for every key: where the real `_owed` reverts it never answers, and
// everywhere else `theBillIsMonotoneInUnits` proves the exact ceil keeps the order.
persistent ghost owedG(uint256, uint256, uint256, uint256) returns uint256 {
    axiom forall uint256 e. forall uint256 s. forall uint256 p. forall uint256 u1. forall uint256 u2.
        u1 <= u2 => owedG(e, s, p, u1) <= owedG(e, s, p, u2);
}

// The protocol cut on a gross, keyed by (cut bps, gross): ANY answer whose net melt never falls as the gross grows,
// among the grosses whose cut fits under them (a cut past its gross makes the checked `gross - cut` revert, so no
// path carries one). `theNetMeltIsMonotone` proves the exact floor keeps it for EVERY bps, the rails' or not.
persistent ghost cutG(uint256, uint256) returns uint256 {
    axiom forall uint256 b. forall uint256 g1. forall uint256 g2.
        (g1 <= g2 && cutG(b, g1) <= g1 && cutG(b, g2) <= g2) => g1 - cutG(b, g1) <= g2 - cutG(b, g2);
}

// `_owed(c, units, p)` is `ceil(p * units * (10000 - eps) / (10000 * unitScale))`; this answers through `owedG`, which
// admits the real answer. It never reverts, where the real one can on overflow, which only adds paths.
function owedSummary(AceHarness.Cfg c, uint256 units, uint256 floorPrice) returns uint256 {
    return owedG(c.p.deleverageFloorEpsBps, c.unitScale, floorPrice, units);
}

// `_cut(c, gross, charge)` is `charge ? floor(gross * cutBps / 10000) : 0`; this answers through `cutG` when charged.
function cutSummary(AceHarness.Cfg c, uint256 gross, bool charge) returns uint256 {
    return charge ? cutG(c.p.deleverageProtocolBps, gross) : 0;
}

// `_owed`'s exact ceil only grows with the units: what makes a partial fill's bill at most the full fill's.
rule theBillIsMonotoneInUnits(uint256 p, uint256 u1, uint256 u2, uint256 e, uint256 s) {
    require e <= 10000 && s > 0 && u1 <= u2;
    mathint b1 = (p * (u1 * (10000 - e)) + 10000 * s - 1) / (10000 * s);
    mathint b2 = (p * (u2 * (10000 - e)) + 10000 * s - 1) / (10000 * s);
    assert b1 <= b2, "a larger sale was billed less";
}

// `_cut`'s exact floor keeps the net melt growing with the gross, for any bps, wherever the cut fits under the gross.
rule theNetMeltIsMonotone(uint256 b, uint256 g1, uint256 g2) {
    mathint c1 = (g1 * b) / 10000;
    mathint c2 = (g2 * b) / 10000;
    require g1 <= g2 && c1 <= to_mathint(g1) && c2 <= to_mathint(g2);
    assert g1 - c1 <= g2 - c2, "a larger gross melted less";
}

// THE DECISION LEMMA, on the exact formulas: a crank the decision sends down the restore path keeps
// `debt >= floor + net(owed(u))`, and any fill `f <= u` then leaves at least `floor`. It is why no restore
// leaves dust, and with genesis's positive floor why a restore never melts a live loan's debt to zero.
rule theDecisionBoundsEveryRestoreFill(uint256 debt, uint256 floor, uint256 u, uint256 f, uint256 p, uint256 e, uint256 s,
    uint256 b) {
    require e <= 10000 && s > 0 && f <= u;
    mathint gu = (p * (u * (10000 - e)) + 10000 * s - 1) / (10000 * s);
    mathint gf = (p * (f * (10000 - e)) + 10000 * s - 1) / (10000 * s);
    mathint cu = (gu * b) / 10000;
    mathint cf = (gf * b) / 10000;
    require cu <= gu && cf <= gf; // neither checked `gross - cut` reverted
    require to_mathint(debt) >= floor + (gu - cu); // the decision chose the restore
    assert debt - (gf - cf) >= to_mathint(floor), "a restore fill melted the debt under the floor";
}

// THE CLOSE LEMMA, on the exact formulas: `uClose = floor((D - 1) * 10000 * S / (ps * (10000 - eps))) + 1` is the
// smallest sale whose ceiled bill covers the whole debt -- its bill reaches `D`, and one unit less does not.
rule theCloseLemmaHolds(uint256 d, uint256 p, uint256 e, uint256 s) {
    require d > 0 && p > 0 && e < 10000 && s > 0;
    mathint u = ((d - 1) * (10000 * s)) / (p * (10000 - e)) + 1;
    assert (p * (u * (10000 - e)) + 10000 * s - 1) / (10000 * s) >= to_mathint(d), "the close's bill falls short of the debt";
    assert (p * ((u - 1) * (10000 - e)) + 10000 * s - 1) / (10000 * s) < to_mathint(d), "one unit less also covers the debt";
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
        && marketMinPrincipalOf(m) >= 2 && marketMinPrincipalOf(m) <= max_uint128;
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

// case 1 of 2: another loan is sold, and nothing it writes lands on the loan under proof
rule claimIsDebtWhenAnotherLoanDeleverages(env e, uint256 id, uint256 x, uint256 minStableOut, bytes data) {
    require x != id;
    deleveragePremises(e, id, x);
    deleverage(e, x, minStableOut, data);
    assert claimIsDebt(id), "selling another loan moved this loan's claim, debt or close";
}

// case 2 of 2: the loan under proof is the one sold; the decision keeps a restore's debt at or above the floor, and a
// close retires the claim
rule claimIsDebtWhenItDeleverages(env e, uint256 id, uint256 minStableOut, bytes data) {
    deleveragePremises(e, id, id);
    deleverage(e, id, minStableOut, data);
    assert claimIsDebt(id), "a deleverage melted the claim off the debt, or melted a live loan's debt to zero";
}

// O54's dust leg, and O71c's deleverage step: a crank keeps a live loan at or above its debt floor, or closes it.
// Another loan's crank writes nothing on this one (case 1 above), so the sold loan is the only case.
rule aCrankLeavesTheDebtAtTheFloorOrClosesTheLoan(env e, uint256 id, uint256 minStableOut, bytes data) {
    deleveragePremises(e, id, id);
    require loanMarket(id) != to_bytes32(0);
    require closedAtOf(id) == 0 => loanDebtOf(id) >= marketDebtFloorOf(loanMarket(id)); // O71c before, HubClaims.spec
    deleverage(e, id, minStableOut, data);
    assert closedAtOf(id) == 0 => loanDebtOf(id) >= marketDebtFloorOf(loanMarket(id)),
        "a crank left a live loan's debt under its debt floor";
}

// the restore witness: under the same premises a sale really melts the debt and leaves the loan live, so case 2 is
// not vacuous on the restore path
rule aDeleverageMeltsTheDebt(env e, uint256 id, uint256 minStableOut, bytes data) {
    deleveragePremises(e, id, id);
    uint256 before = loanDebtOf(id);
    deleverage(e, id, minStableOut, data);
    satisfy loanDebtOf(id) < before && closedAtOf(id) == 0;
}

// the close witness: under the same premises a crank really closes a live loan, so case 2 is not vacuous on the close
rule aDeleverageClosesTheLoan(env e, uint256 id, uint256 minStableOut, bytes data) {
    deleveragePremises(e, id, id);
    require loanMarket(id) != to_bytes32(0) && closedAtOf(id) == 0;
    deleverage(e, id, minStableOut, data);
    satisfy closedAtOf(id) != 0;
}
