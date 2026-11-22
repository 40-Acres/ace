// CoverageMath: the settlement and keeper formulas that live outside LoanMath, checked on the REAL bodies.
//
// Every hub spec summarizes these away or restates them in CVL, so a mutant in any of them passed every hub rule:
// `_owed` returning zero, `securedBase` returning the whole lot, `sliverUnits` without its `/10000`. Here each is called
// through `CoverageMathHarness`, one call to the real function, and its answer is pinned by an exact characterization:
// what it must be bounded below and above by, so any change to the formula fails a rule.
//
// THE PURE-MUNGED TREE (scripts/certora-munge-pure.sh): `Deleverage._owed`, `_cut`, `_net` and `Lender._askLeg` are
// private, so the harness is compiled from a copy where they are internal. That changes who may name them, nothing else.
//
// `FullMath.mulDiv` is modelled EXACTLY, the floor of `a*b/d` in unbounded integers, with the two cases where the real
// routine reverts (a zero divisor, a quotient past 256 bits) pruned; `mulDivRoundingUp` runs its own body on it. Uniswap's
// implementation of that definition is taken as correct, as LoanMath.spec takes it; what is checked is the formula built on
// it. A pruned path is a call that reverts, and every rule here is about the value a call returns. Each characterization is
// TWO-SIDED, so a summary whose result never reached the caller (the `_cut` case, below) would fail it, not pass it.
// PROVER 8.20.3, like the hub confs (the `scripts/certora-setup.sh` pin, which `certora-run.sh` checks), with storage splitting off
// (the conf): the harness hands storage structs to hub library code, and the scratch loan's id is read at run time, since a
// constant id let the compiler fold the write's slot and the prover then read a debt the harness never wrote (emv-8, emv-9).
//
// THE UNIT SCALE IS 2^96 wherever a rule reads more than one product: genesis fixes it (HubClaims.spec
// `aCreatedMarketKeepsItsRails`), and a constant keeps the solver's products to the ones the formula has.
//
// HOW THE HUB RULES USE THESE: HubCoverage.spec proves the WIRING (which debt, which price, which lot each gate compares)
// on the hub, and the rules here prove the FORMULAS the wiring feeds. Each half is on the real code.

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => floorMulDiv(a, b, d);
    // NO SUMMARY for mulDivRoundingUp: via-IR inlines it, and on 8.20.3 a summary the prover cannot locate fails the rule.
    // Its body runs on the exact `mulDiv` above, so the ceil is DERIVED from the floor (verify/README.md).
    // `_cut` and `_net` are NOT here: inside `_cut` this summary LOST ITS RESULT (emv-8: it computed 30, the harness
    // returned 0), so they are checked on Uniswap's own body in CoverageCut.spec. The prover cannot follow that body past
    // 2^256 (emv-11: a claim of 2 at a unit scale of 2^255 read a need of 1), so it is used only where products stay under it.

    function owed(uint256, uint256, uint256, uint256) external returns (uint256) envfree;
    function cut(uint256, uint256, bool) external returns (uint256) envfree;
    function net(uint256, uint256, bool) external returns (uint256) envfree;
    function collateralNeeded(uint256, uint256, uint256) external returns (uint256) envfree;
    function sliverUnits(uint256, uint256, uint256, uint256, uint256, uint256) external returns (uint256) envfree;
    function securedBase(uint256, uint256, uint256, uint256, uint256, uint256, uint256) external returns (uint256) envfree;
    function requiredAt(uint256, uint256, uint256, uint256) external returns (uint256) envfree;
    function coverageLine(uint256, uint256, uint256, uint256) external returns (uint256) envfree;
    function debtFloor(uint256) external returns (uint256) envfree;
    function triggerPrice(uint256, uint256, uint256, uint256) external returns (uint256) envfree;
    function askLeg(uint256, uint256, uint256, uint256, uint256, uint256) external returns (uint256, uint256) envfree;
}

function floorMulDiv(uint256 a, uint256 b, uint256 d) returns uint256 {
    require d != 0;
    mathint q = (a * b) / d;
    return require_uint256(q);
}

definition S() returns mathint = 2^96;

// ---- the keeper's bill, the cut and the net melt ----

// `_owed`: "Ceil: the payer never rounds in their own favour" -- and by less than one atom
rule theBillRoundsUpByUnderOne(uint256 eps, uint256 units, uint256 p) {
    require eps < 10000;
    mathint bill = owed(eps, require_uint256(S()), units, p);
    mathint exact = p * units * (10000 - eps);
    assert bill * 10000 * S() >= exact, "the keeper's bill rounded down: a sold unit melts less than the floor less eps";
    assert (bill - 1) * 10000 * S() < exact, "the keeper's bill rounded up by a whole atom or more";
}

// `_cut` and `_net` are CoverageCut.spec's, on Uniswap's own `mulDiv` (see the methods block)

// ---- settlement's need, the sliver and the secured base ----

// `collateralNeeded`: ONE CEIL of the claim at the price, and nothing for no claim
rule theNeedIsTheClaimCeiled(uint256 claim, uint256 price, uint256 s) {
    require price > 0 && s > 0;
    mathint n = collateralNeeded(claim, price, s);
    assert claim == 0 => n == 0, "a retired claim needs units";
    assert claim > 0 => n * price >= claim * s, "the need rounded down: fewer units cannot pay the claim";
    assert claim > 0 => (n - 1) * price < claim * s, "the need rounded up by a whole unit or more";
}

// `sliverUnits`: `debt * bps` of the debt at the funding floor, floored, capped at the lot, and none with no claim
rule theSliverIsTheDebtBountyFloored(uint256 debt, uint256 claim, uint256 b, uint256 price, uint256 s, uint256 units) {
    require price > 0 && s > 0;
    mathint sl = sliverUnits(debt, claim, b, price, s, units);
    assert sl <= to_mathint(units), "the sliver passed the lot";
    assert claim == 0 => sl == 0, "a loan with no funding floor paid a sliver";
    assert sl * 10000 * price <= debt * b * s, "the sliver passed its bounty at the funding floor";
    assert (claim > 0 && sl < to_mathint(units)) => (sl + 1) * 10000 * price > debt * b * s, "the sliver fell a whole unit short";
}

// `securedBase`: a disposal never sizes into what settlement keeps (the need plus the sliver), nor past `requiredAt`
rule theSecuredBaseKeepsWhatSettlementNeeds(uint256 debt, uint256 claim, uint256 k, uint256 b, uint256 price, uint256 units) {
    require price > 0;
    mathint sb = securedBase(debt, claim, k, b, price, require_uint256(S()), units);
    mathint need = collateralNeeded(claim, price, require_uint256(S()));
    mathint sl = sliverUnits(debt, claim, b, price, require_uint256(S()), units);
    mathint req = requiredAt(k, require_uint256(S()), debt, claim == 0 ? 0 : price);
    assert sb <= req, "the secured base passed what the debt secures";
    assert sb == 0 || sb + need + sl <= to_mathint(units), "the secured base ate into settlement's need or the sliver";
}

// need and sliver only fall as the debt falls (claim and debt are one number on a live loan: HubClaims.spec O10)
rule theNeedAndSliverFallWithTheDebt(uint256 d0, uint256 d1, uint256 b, uint256 price, uint256 units) {
    require price > 0 && d1 <= d0;
    assert collateralNeeded(d1, price, require_uint256(S())) <= collateralNeeded(d0, price, require_uint256(S())),
        "a smaller claim needs more units";
    assert sliverUnits(d1, d1, b, price, require_uint256(S()), units) <= sliverUnits(d0, d0, b, price, require_uint256(S()), units),
        "a smaller debt pays a larger sliver";
}

// THE SALE'S KEEP CARRIES TO THE POST-SALE LOAN: a live loan that sells `s` within its secured base, then owes `d1` at
// most what it owed, still holds its settlement need plus the uncapped sliver. A restore melts the debt, never raises it.
rule aSaleWithinTheSecuredBaseKeepsTheCover(uint256 d0, uint256 d1, uint256 k, uint256 b, uint256 price, uint256 units, uint256 s) {
    require price > 0 && d0 > 0 && d1 <= d0 && s > 0;
    require s <= securedBase(d0, d0, k, b, price, require_uint256(S()), units);
    mathint left = units - s;
    assert left >= collateralNeeded(d1, price, require_uint256(S())) + sliverUnits(d1, d1, b, price, require_uint256(S()), max_uint256),
        "a sale inside the secured base left the loan short of settlement's need plus the sliver";
}

// ---- the coverage line ----

// `requiredAt`: the units `minCoverageWad` times the debt needs at `price`, ONE ceil, on both of its overflow branches
rule requiredAtIsTheCoverageCeiled(uint256 k, uint256 s, uint256 d, uint256 p) {
    require s > 0;
    mathint r = requiredAt(k, s, d, p);
    assert d == 0 => r == 0, "no debt needs units";
    assert (d > 0 && p == 0) => r == max_uint256, "a zero price failed open";
    assert (d > 0 && p > 0) => r * p * 10^18 >= k * d * s, "requiredAt rounded down";
    assert (d > 0 && p > 0) => (r - 1) * p * 10^18 < k * d * s, "requiredAt rounded up by a whole unit or more";
}

// `coverageLine`: `requiredAt` plus ONE atom, saturating
rule theCoverageLineIsRequiredPlusOne(uint256 k, uint256 s, uint256 d, uint256 p) {
    mathint r = requiredAt(k, s, d, p);
    mathint line = coverageLine(k, s, d, p);
    assert line == (r == max_uint256 ? r : r + 1), "the coverage line is not requiredAt plus one atom";
}

// Constants.sol: "the coverage line holds at BOTH doors iff b <= k-1". At any price at or under the funding floor, the
// line covers what settlement takes off the lot: the claim's need at the floor plus the keeper's whole sliver.
rule theCoverageLineCoversSettlement(uint256 k, uint256 b, uint256 d, uint256 f, uint256 p) {
    require 0 < f && f <= p && p <= 2^224;
    require b * 10^14 + 10^18 <= k && k <= 20 * 10^18; // b <= k - 1, the bounty in bps against a WAD coverage
    require 0 < d && d <= max_uint128;
    mathint line = coverageLine(k, require_uint256(S()), d, f);
    mathint need = collateralNeeded(d, p, require_uint256(S()));
    mathint sl = sliverUnits(d, d, b, p, require_uint256(S()), max_uint256);
    assert line >= need + sl, "the coverage line does not cover settlement's need plus the sliver";
}

// the genesis rails (`MIN_COVERAGE_WAD`, `MAX_SETTLE_BOUNTY_BPS`) give the premise above
rule theGenesisRailsPutTheBountyUnderKMinusOne(uint256 k, uint256 b) {
    require k >= 105 * 10^16 && b <= 200;
    assert b * 10^14 + 10^18 <= to_mathint(k), "the rails admit a bounty past k - 1";
}

// ---- the debt floor ----

// `debtFloor`: half `minPrincipal`, rounded down, and positive at genesis's `minPrincipal >= 2`
rule theDebtFloorIsHalfRoundedDown(uint256 m) {
    mathint f = debtFloor(m);
    assert 2 * f <= to_mathint(m) && 2 * f + 2 > to_mathint(m), "the debt floor is not half minPrincipal rounded down";
    assert m >= 2 => f >= 1, "a market genesis admits has a zero debt floor";
}

// ---- the ask ----

// `_askLeg`: a buy never pays past its budget, never takes past the pot, and pays at least the ask on what leaves,
// its fee included. Genesis: the unit scale is 2^96, the fill fee at most 50 bps, the price in (0, 2^224].
// SPLIT BY LEG: the four bounds as one rule were UNKNOWN at two hours alone (emv-8, emv-39). The leg is decided here in
// CVL from the quantities `_askLeg` reads; the rules split on it and its negation, so together they cover every input
// whatever the code's own branch does, and the code's branch is only what makes each half cheap.

definition askOf(uint256 price, uint256 askFloor) returns mathint = price > askFloor ? price : askFloor;

// the all-in unit price, its fee ceiled, as `effPrice`
definition effOf(mathint ask, uint256 fee) returns mathint = ask + (ask * fee + 9999) / 10000;

// what the budget affords at that price, capped at the pot, as `take`
definition takeOf(uint256 inv, uint256 remaining, mathint eff) returns mathint =
    (remaining * S()) / eff < to_mathint(inv) ? (remaining * S()) / eff : to_mathint(inv);

// the whole pot's ceiled charge, its fee ceiled on top, as the whole-pot leg's `total`
definition wholeTotal(uint256 inv, mathint ask, uint256 fee) returns mathint =
    (inv * ask + S() - 1) / S() + (((inv * ask + S() - 1) / S()) * fee + 9999) / 10000;

// THE WHOLE-POT LEG: the budget takes the whole pot, and covers its ceiled charge
definition wholeLeg(uint256 inv, uint256 remaining, uint256 fee, uint256 askFloor, uint256 price) returns bool =
    inv > 0 && takeOf(inv, remaining, effOf(askOf(price, askFloor), fee)) == to_mathint(inv)
        && wholeTotal(inv, askOf(price, askFloor), fee) <= to_mathint(remaining);

rule theAskWholePotLegStaysInsideTheBudgetAndThePot(uint256 inv, uint256 remaining, uint256 fee, uint256 askFloor, uint256 price) {
    require fee <= 50 && price > 0 && price <= 2^224 && askFloor <= 2^224;
    require wholeLeg(inv, remaining, fee, askFloor, price);
    uint256 deliver; uint256 total;
    deliver, total = askLeg(inv, remaining, require_uint256(S()), fee, askFloor, price);
    mathint ask = askOf(price, askFloor);
    assert total <= remaining, "a whole-pot buy paid past its budget";
    assert deliver <= inv, "a whole-pot buy took past the pot";
    assert total * S() >= deliver * ask, "a whole-pot buy paid under the ask for what left the pot";
    assert total * 10000 * S() >= deliver * ask * (10000 + fee), "a whole-pot buy paid under the ask plus its fee";
}

// every other input: the part leg, and the zero leg it can end in (its budget bound is the composition's, below)
rule theAskPartLegStaysInsideThePot(uint256 inv, uint256 remaining, uint256 fee, uint256 askFloor, uint256 price) {
    require fee <= 50 && price > 0 && price <= 2^224 && askFloor <= 2^224;
    require !wholeLeg(inv, remaining, fee, askFloor, price);
    uint256 deliver; uint256 total;
    deliver, total = askLeg(inv, remaining, require_uint256(S()), fee, askFloor, price);
    assert deliver <= inv, "a part buy took past the pot";
}

rule theAskPartLegPaysTheAskAndItsFee(uint256 inv, uint256 remaining, uint256 fee, uint256 askFloor, uint256 price) {
    require fee <= 50 && price > 0 && price <= 2^224 && askFloor <= 2^224;
    require !wholeLeg(inv, remaining, fee, askFloor, price);
    uint256 deliver; uint256 total;
    deliver, total = askLeg(inv, remaining, require_uint256(S()), fee, askFloor, price);
    mathint ask = askOf(price, askFloor);
    assert total * S() >= deliver * ask, "a part buy paid under the ask for what left the pot";
    assert total * 10000 * S() >= deliver * ask * (10000 + fee), "a part buy paid under the ask plus its fee";
}

// THE PART LEG'S BUDGET BOUND, SPLIT FURTHER: on the code it was the slow one, open past an hour alone (its degree-three
// fee chain against two floors and two ceils). (E) the code IS the part leg's arithmetic, (F) each floor and ceil there
// binds its value both ways, and (P) any values so bound stay inside the budget and the pot and pay the ask and its fee,
// composed linearly from instances of the factor lemmas below. P calls nothing; F's bounds are its premises and E ties
// them to the code. The pot and pay bounds are also proven on the code directly, above.

// the part leg's steps past the whole-pot test, as `_askLeg` takes them (`mulDivRoundingUp` is the floor plus a remainder)
definition partG1(uint256 inv, uint256 remaining, uint256 fee, uint256 askFloor, uint256 price) returns mathint =
    (takeOf(inv, remaining, effOf(askOf(price, askFloor), fee)) * askOf(price, askFloor)) / S();
definition partDeliver(uint256 inv, uint256 remaining, uint256 fee, uint256 askFloor, uint256 price) returns mathint =
    (partG1(inv, remaining, fee, askFloor, price) * S()) / askOf(price, askFloor);
definition partG2(uint256 inv, uint256 remaining, uint256 fee, uint256 askFloor, uint256 price) returns mathint =
    (partDeliver(inv, remaining, fee, askFloor, price) * askOf(price, askFloor)) / S()
        + ((partDeliver(inv, remaining, fee, askFloor, price) * askOf(price, askFloor)) % S() != 0 ? 1 : 0);
definition partTotal(uint256 inv, uint256 remaining, uint256 fee, uint256 askFloor, uint256 price) returns mathint =
    partG2(inv, remaining, fee, askFloor, price) + (partG2(inv, remaining, fee, askFloor, price) * fee + 9999) / 10000;

// (E) on the real code: off the whole-pot leg, `_askLeg` returns exactly the part leg's arithmetic, or nothing
rule theAskPartLegIsItsArithmetic(uint256 inv, uint256 remaining, uint256 fee, uint256 askFloor, uint256 price) {
    require fee <= 50 && price > 0 && price <= 2^224 && askFloor <= 2^224;
    require !wholeLeg(inv, remaining, fee, askFloor, price);
    uint256 deliver; uint256 total;
    deliver, total = askLeg(inv, remaining, require_uint256(S()), fee, askFloor, price);
    bool none = takeOf(inv, remaining, effOf(askOf(price, askFloor), fee)) == 0 || partG1(inv, remaining, fee, askFloor, price) == 0;
    assert none => deliver == 0 && total == 0, "a part leg with nothing to buy bought something";
    assert !none => to_mathint(deliver) == partDeliver(inv, remaining, fee, askFloor, price), "the part leg delivered off its arithmetic";
    assert !none => to_mathint(total) == partTotal(inv, remaining, fee, askFloor, price), "the part leg charged off its arithmetic";
}

// (F) a floor, a ceil, a ceiled fee and the take's min bind their values both ways (free integers)
rule theFloorsAndCeilsBindBothWays() {
    mathint n; mathint d; mathint a; mathint f;
    require n >= 0 && d > 0 && a >= 0 && f >= 0;
    mathint q = n / d;
    mathint c = n / d + (n % d != 0 ? 1 : 0);
    assert q * d <= n && n < q * d + d, "the floor missed its bounds";
    assert c * d >= n && c * d < n + d, "the ceil missed its bounds";
    mathint e = a + (a * f + 9999) / 10000;
    assert e * 10000 >= a * (10000 + f), "the ceiled fee fell under the fee";
    assert e * 10000 < a * (10000 + f) + 10000, "the ceiled fee rose a whole atom";
    mathint mn = n / d < a ? n / d : a;
    assert mn <= a && mn * d <= n, "the min missed its bounds";
}

// (P) values bound as the part leg's floors and ceils bind them stay inside and pay the ask and its fee (calls nothing)
rule aPartLegsArithmeticStaysInsideAndPaysTheAsk(uint256 inv, uint256 remaining, uint256 fee) {
    require fee <= 50;
    mathint ask; mathint eff; mathint take; mathint g1; mathint dl; mathint g2; mathint tot;
    require ask > 0 && take >= 0 && g1 >= 0 && dl >= 0 && g2 >= 0;
    require eff * 10000 >= ask * (10000 + fee);                       // effPrice ceils its fee
    require take <= to_mathint(inv) && take * eff <= remaining * S(); // take: the min of the pot and the floored budget
    require g1 * S() <= take * ask;                                   // gross: floored
    require dl * ask <= g1 * S();                                     // deliver: floored
    require g2 * S() >= dl * ask && g2 * S() < dl * ask + S();        // the re-price: ceiled
    require tot * 10000 >= g2 * (10000 + fee) && tot * 10000 < g2 * (10000 + fee) + 10000; // its fee: ceiled

    // aNonNegativeFactorKeepsAnInequality, five instances, and aPositiveFactorCancels, one
    mathint fe = 10000 + fee;
    require (g1 >= g2 && fe >= 0) => g1 * fe >= g2 * fe;
    require (take * ask >= g1 * S() && fe >= 0) => take * ask * fe >= g1 * S() * fe;
    require (eff * 10000 >= ask * fe && take >= 0) => eff * 10000 * take >= ask * fe * take;
    require (g2 * S() >= dl * ask && fe >= 0) => g2 * S() * fe >= dl * ask * fe;
    require (g2 >= 0 && fee >= 0) => g2 * fee >= 0 * fee;
    require (ask > 0 && take * ask >= dl * ask) => take >= dl;

    assert tot <= to_mathint(remaining), "a part buy paid past its budget";
    assert dl <= to_mathint(inv), "a part buy took past the pot";
    assert tot * S() >= dl * ask, "a part buy paid under the ask for what left the pot";
    assert tot * 10000 * S() >= dl * ask * (10000 + fee), "a part buy paid under the ask plus its fee";
}

// ---- O15, a crank never raises the trigger, per crank on exact arithmetic ----

// THE SELL-MAX RAIL, as MarketInit states it: `stop * 1e14 + floor(floor(k * (1e4 - eps) / 1e4) * (1e4 - cut) / 1e4) > 1e18`
definition sellMaxRail(mathint k, mathint eps, mathint cb, mathint stop) returns bool =
    stop * 10^14 + ((k * (10000 - eps)) / 10000) * (10000 - cb) / 10000 > 10^18;

// THE STOP GATE, as `deleverage` asks it: the record's price strictly above the trigger's stop level, ceiled
definition aboveTheStop(mathint ps, mathint trig, mathint stop) returns bool =
    ps > (trig * 10^18 + (10^18 - stop * 10^14) - 1) / (10^18 - stop * 10^14);

// O15 STEP ONE, SPLIT INTO LEMMAS. As one rule over the real `_owed` and `triggerPrice` it was UNKNOWN at two hours alone
// (emv-12, emv-39): degree-four products against two ceils. Here each ceil is a two-sided lemma on its real body, the gate
// and the rail are unfolded in CVL arithmetic, and the composition calls nothing: it takes the code's two answers as free
// values bound only by what their lemmas prove, so it covers the real answers among all others.
// The trigger's lemma is LoanMath.spec `theTriggerRoundsUpByUnderOne`, on the real `triggerPrice` over every unit scale;
// a copy here, deriving the ceil from the floor, was UNKNOWN at an hour alone, so it is not restated.

// the net melt keeps all of the bill but the cut, charged or not (the net's form is CoverageCut.spec's)
rule theNetMeltKeepsAllButTheCut(bool charge) {
    mathint bill; mathint cb;
    require bill >= 0 && 0 <= cb && cb <= 10000;
    mathint melt = charge ? bill - (bill * cb) / 10000 : bill;
    assert melt * 10000 >= bill * (10000 - cb), "the net melt lost more than the cut";
}

// a price the stop gate admits clears the trigger's stop level outright
rule theStopGateClearsTheStopLevel(uint256 ps, uint256 stop) {
    mathint trig;
    require trig >= 0 && 0 < stop && stop < 10000;
    require aboveTheStop(ps, trig, stop);
    assert ps * (10^18 - stop * 10^14) > trig * 10^18, "a price the stop gate admits sits at or under the stop level";
}

// the sell-max rail, floors dropped: the coverage less eps and the cut clears the stop level
rule theSellMaxRailClearsTheStopLevel(uint256 k, uint256 eps, uint256 cb, uint256 stop) {
    require eps <= 10000 && cb <= 10000 && stop < 10000;
    require sellMaxRail(k, eps, cb, stop);
    assert k * (10000 - eps) * (10000 - cb) > 10^8 * (10^18 - stop * 10^14), "the rail does not clear the stop level";
}

// MULTIPLYING BOTH SIDES BY A NON-NEGATIVE FACTOR KEEPS AN INEQUALITY, over free integers; the composition requires instances
rule aNonNegativeFactorKeepsAnInequality() {
    mathint a; mathint b; mathint x;
    require a >= b && x >= 0;
    assert a * x >= b * x, "a non-negative factor turned an inequality";
}

// A POSITIVE FACTOR CANCELS, over free integers; the composition requires one instance
rule aPositiveFactorCancels() {
    mathint a; mathint b; mathint x;
    require x > 0 && a * x >= b * x;
    assert a >= b, "a positive factor did not cancel";
}

// O15, step one: at any price the stop gate admits, a sold unit melts at least the loan's debt per unit, so `D f <= net C`.
// `f` is what FILLED, any amount up to the lot; the cut is charged or not. This is the rail's SECOND JOB in MarketInit.
// `trig` and `bill` stand for the real `triggerPrice` and `_owed`, bound by LoanMath.spec `theTriggerRoundsUpByUnderOne`
// and `theBillRoundsUpByUnderOne`; only their LOWER bounds are used, and a higher trigger only narrows the gate. The net is
// `bill - floor(bill * cut / 1e4)`, or the bill uncharged, which is what CoverageCut.spec proves `_net` returns. Every other
// premise is an instance of a lemma above, so the chain from the bill to the debt is linear over the products it names.
rule aSoldUnitMeltsAtLeastTheDebtPerUnit(uint256 d, uint256 c, uint256 f, uint256 ps, uint256 k, uint256 eps, uint256 cb, uint256 stop,
    bool charge) {
    require k >= 105 * 10^16 && k <= 20 * 10^18 && 0 < eps && eps <= 200 && cb <= 2000 && 0 < stop && stop < 10000;
    require sellMaxRail(k, eps, cb, stop);
    require d > 0 && d <= max_uint128 && c > 0 && f <= c;
    mathint trig; mathint bill;
    require trig >= 0 && bill >= 0;
    require trig * c * 10^18 >= k * d * S();                     // LoanMath.spec theTriggerRoundsUpByUnderOne
    require aboveTheStop(ps, trig, stop);
    require bill * 10000 * S() >= ps * f * (10000 - eps);        // theBillRoundsUpByUnderOne
    mathint melt = charge ? bill - (bill * cb) / 10000 : bill;

    mathint e = 10000 - eps;
    mathint cc = 10000 - cb;
    mathint dd = 10^18 - stop * 10^14;
    require melt * 10000 >= bill * cc;                           // theNetMeltKeepsAllButTheCut
    require ps * dd > trig * 10^18;                              // theStopGateClearsTheStopLevel
    require k * e * cc > 10^8 * dd;                              // theSellMaxRailClearsTheStopLevel

    // aNonNegativeFactorKeepsAnInequality, five instances: melt -> bill -> price -> trigger -> coverage -> debt
    mathint x1 = 10000 * S() * c * dd;
    mathint x2 = cc * c * dd;
    mathint x3 = c * f * e * cc;
    mathint x4 = f * e * cc;
    mathint x5 = d * S() * f;
    require (melt * 10000 >= bill * cc && x1 >= 0) => melt * 10000 * x1 >= bill * cc * x1;
    require (bill * 10000 * S() >= ps * f * e && x2 >= 0) => bill * 10000 * S() * x2 >= ps * f * e * x2;
    require (ps * dd >= trig * 10^18 && x3 >= 0) => ps * dd * x3 >= trig * 10^18 * x3;
    require (trig * c * 10^18 >= k * d * S() && x4 >= 0) => trig * c * 10^18 * x4 >= k * d * S() * x4;
    require (k * e * cc >= 10^8 * dd && x5 >= 0) => k * e * cc * x5 >= 10^8 * dd * x5;

    // aPositiveFactorCancels, one instance
    mathint kk = 10^8 * S() * dd;
    require (kk > 0 && melt * c * kk >= d * f * kk) => melt * c >= d * f;

    assert d * f <= melt * c, "a sold unit melted less than the loan's debt per unit";
}

// O15, step two: the trigger only falls with the debt per unit, so `D1 C0 <= D0 C1` never raises it
rule theTriggerFallsWithTheDebtPerUnit(uint256 d0, uint256 c0, uint256 d1, uint256 c1, uint256 k) {
    require c0 > 0 && c1 > 0 && k <= 20 * 10^18 && d0 <= max_uint128;
    require d1 * c0 <= d0 * c1;
    assert triggerPrice(d1, c1, k, require_uint256(S())) <= triggerPrice(d0, c0, k, require_uint256(S())),
        "a lower debt per unit raised the trigger";
}

// O50's in-term take: a trigger at or under the price makes the claim at the trigger, ceil(lot * 1e18 / k), cover the
// need, so `_marketBound`'s floor at the need is belt-and-braces on every live recorded loan (the trigger stays at or
// under the price from the open gate on: withdrawals fold at min(price, record) and deleverage only lowers it)
rule aTriggerAtOrUnderThePriceMakesTheTakeCoverTheNeed(uint256 d, uint256 c, uint256 k, uint256 price) {
    require d > 0 && d <= max_uint128 && c > 0 && c <= max_uint256 / 10^18 && price > 0;
    require k >= 105 * 10^16 && k <= 20 * 10^18;
    require triggerPrice(d, c, k, require_uint256(S())) <= price;
    mathint atTrigger = (c * 10^18 + k - 1) / k;
    assert atTrigger >= collateralNeeded(d, price, require_uint256(S())), "the claim at the trigger fell under the need";
}

// THE BAND-ON TAKE (#944, #945): `_marketBound` takes `mulDivRoundingUp(claim, unitScale, ps)`, which is `collateralNeeded`
// at the record's price `ps`. It is the debt's worth at `ps` plus at most one ceil atom: whole there, never a unit more.
rule theTakeAtTheRecordIsTheDebtThereCeiled(uint256 d, uint256 ps) {
    require d > 0 && d <= max_uint128 && ps > 0;
    mathint take = collateralNeeded(d, ps, require_uint256(S()));
    assert take * ps >= d * S(), "the take at the record is worth less than the debt there";
    assert take <= (d * S()) / ps + 1, "the take at the record passed the debt there by more than one ceil atom";
}

// ... and it sits strictly under the coverage line at that same price, so a band-on seizure never takes units a withdrawal
// gated at that record would have let the borrower take out (the claim is the debt, O10)
rule theTakeAtTheRecordSitsUnderTheLineThere(uint256 d, uint256 ps, uint256 k) {
    require d > 0 && d <= max_uint128 && ps > 0 && ps <= 2^224;
    require k >= 105 * 10^16 && k <= 20 * 10^18;
    assert collateralNeeded(d, ps, require_uint256(S())) < coverageLine(k, require_uint256(S()), d, ps),
        "the take at the record reached the coverage line at the record";
}
