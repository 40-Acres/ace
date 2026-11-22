// AceVault: the vest maturity's two bounds and the stamp's exact read-back, proved ONCE, at the one line that writes them;
// and the pile's two other writes, the burn on a NAV fall and the last requester's release, each at its own line.
//
// THE LEMMA UNDER VaultArithmetic.spec's TWO PARAMETRIC VEST RULES. The vault assigns `vestMaturity` at exactly one site,
// `AceVaultNav.stampVest`, which `_sync` reaches on a NAV rise; `grep -rn vestMaturity src` shows every other hit is a read.
// That grep is the composition's evidence, since a storage hook fails the vault's storage analysis under via-IR. So a bound
// proved here, from every start and for every amount, holds across every verb by that written step, with no per-verb run.
//
// THE PREMISE IS AN INDUCTION, as in VaultArithmetic.spec: the constructor writes no maturity (it books the genesis seed into
// the mark and the high-waters and stamps no vest), so it starts at 0, within one window of any clock; the step is the second
// rule below, plus the fact that block.timestamp never runs backwards.
//
// mulDiv is modelled EXACTLY, as in VaultArithmetic.spec. No outside call is reached on these paths; the catch-all is kept
// so that holds whatever the vault's other code imports.

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mdExact(x, y, d, false);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => mdExactRounded(x, y, d, r);

    function vestMaturity() external returns (uint64) envfree;
    function vestBasis() external returns (uint128) envfree;
    function navMark() external returns (uint256) envfree;
    function tailMatches() external returns (bool) envfree;
    function VEST_WINDOW() external returns (uint64) envfree;
    function unvested() external returns (uint256); // reads the clock, so it takes an env

    unresolved external in _._ => DISPATCH [] default NONDET;
}

function mdExact(uint256 x, uint256 y, uint256 d, bool up) returns uint256 {
    require d != 0;
    mathint p = x * y;
    mathint q = (up && p % d != 0) ? p / d + 1 : p / d;
    return require_uint256(q);
}

// OZ rounds up for Ceil and Expand, down for Floor and Trunc; on unsigned values Trunc is Floor and Expand is Ceil
function mdExactRounded(uint256 x, uint256 y, uint256 d, Math.Rounding r) returns uint256 {
    return mdExact(x, y, d, r == Math.Rounding.Ceil || r == Math.Rounding.Expand);
}

// a real clock, and the induction's hypothesis: the maturity stands at most one window ahead of now; the suffix as deployed
function aWindowAhead(env e) {
    require tailMatches();
    require e.block.timestamp + VEST_WINDOW() < 2^64;
    require vestMaturity() <= e.block.timestamp + VEST_WINDOW();
}

rule aStampNeverMovesTheMaturityEarlier(env e, uint256 amount) {
    aWindowAhead(e);
    mathint before = vestMaturity();
    stampVest(e, amount);
    assert vestMaturity() >= before, "a stamp moved the vest maturity earlier, releasing a deferred gain early";
}

rule aStampLeavesTheMaturityWithinOneWindow(env e, uint256 amount) {
    aWindowAhead(e);
    stampVest(e, amount);
    assert vestMaturity() <= e.block.timestamp + VEST_WINDOW(), "a stamp pushed the vest maturity past one window";
}

// a rise onto a pile already matured runs one full window from now: nothing deferred is older than the stamp
rule aStampOnAMaturedPileRunsAFullWindow(env e, uint256 amount) {
    aWindowAhead(e);
    require amount != 0;
    require vestMaturity() <= e.block.timestamp;
    stampVest(e, amount);
    assert vestMaturity() == e.block.timestamp + VEST_WINDOW(), "a stamp on a matured pile ran less or more than one window";
}

// THE WITNESS: a rise onto a running pile blends the maturity strictly between the old one and a full window
rule aStampCanBlendTheMaturity(env e, uint256 amount) {
    aWindowAhead(e);
    mathint before = vestMaturity();
    require before > e.block.timestamp;
    stampVest(e, amount);
    satisfy vestMaturity() > before && vestMaturity() < e.block.timestamp + VEST_WINDOW();
}

// ---- the stamp's read-back: the basis is FLOORED, so the pile reads back exactly what it held plus the rise ----

// THE ROOT CAP. The stamp re-grosses the basis from the pile it reads plus the rise, floored, and the read is ceiled:
// with r = maturity - now in (0, W], ceil(floor(X * W / r) * r / W) = X. Under the uint128 ceiling the basis does not
// saturate, which the bound on X * W guarantees since r >= 1; past it the next rule still holds.
rule aStampReadsBackExactlyItsRise(env e, uint256 amount) {
    aWindowAhead(e);
    require amount != 0;
    mathint before = unvested(e);
    require (before + amount) * VEST_WINDOW() < 2^128;
    stampVest(e, amount);
    assert to_mathint(unvested(e)) == before + amount, "a stamp read back other than the pile it held plus its rise";
}

// THE IDENTITY UNDER THE READ-BACK, on its own and with no contract in it: a basis floored over r seconds left of a W-second
// window, read back ceiled over the same r, is exactly what was grossed. The rule above composes it with `AceVaultNav.grossed`'s maturity.
rule theFlooredBasisReadsBackExactly(uint256 x, uint64 w, uint64 r) {
    require x > 0 && w > 0 && r > 0 && r <= w;
    mathint b = (x * w) / r;
    mathint p = b * r;
    mathint back = p % w == 0 ? p / w : p / w + 1;
    assert back == to_mathint(x), "a floored basis read back ceiled was not the pile it was grossed from";
}

// A STAMP NEVER LOWERS NAV: the sync books the rise into the mark and stamps it, so NAV holds while the pile reads at most
// the old pile plus the rise. Saturation included: a saturated basis defers less, never more.
rule aStampNeverLowersNav(env e, uint256 amount) {
    aWindowAhead(e);
    mathint before = unvested(e);
    stampVest(e, amount);
    assert to_mathint(unvested(e)) <= before + amount, "a stamp deferred more than its rise, so NAV fell under the mark it booked";
}

// ---- the vest's two other writes: the burn on a NAV fall, and the last requester's release ----

// THE BURN, `AceVaultNav.burnVest`, the sync's write on a fall of `d`: it rescales the basis by (u - d) / u, FLOORED, where u is the pile
// read now. So the pile then reads at most u - d, none once d reaches u: the fall burns the pile first and NAV does not move
// under it. And it reads at least u - d - 1: the floor and the ceiled read release at most one wei of the pile into NAV.
// The maturity is untouched, so the burn moves no vest time. With r = maturity - now in (0, W] and x = basis * r / W, u is
// ceil(x); the new read is at most ceil(x * (u - d) / u) <= u - d, and over (x * (u - d) / u - r / W) > u - d - 2.
rule aBurnLeavesAtMostThePileLessTheFall(env e, uint256 d) {
    aWindowAhead(e);
    mathint u = unvested(e);
    mathint m0 = vestMaturity();

    burnVest(e, d);

    mathint u1 = unvested(e);
    assert u1 <= (u > to_mathint(d) ? u - d : 0), "a burn left more of the pile than the fall had not burned, so NAV fell with it";
    assert u1 >= u - d - 1, "a burn released more than one wei of the pile into NAV";
    assert to_mathint(vestMaturity()) == m0, "a burn moved the vest maturity";
}

// THE SAME BOUNDS IN TWO STEPS, as the stamp's read-back is stated: the burn's write, against the vault's own code, and the
// arithmetic under it, with no contract in it. Together they give the rule above, by the one substitution of the written basis.
// The write: the burn leaves the basis floor(b * (u - d) / u), none once d reaches u, untouched with no pile or no fall,
// and the maturity untouched.
rule aBurnWritesTheScaledBasis(env e, uint256 d) {
    aWindowAhead(e);
    mathint u = unvested(e);
    mathint b0 = vestBasis();
    mathint m0 = vestMaturity();

    burnVest(e, d);

    mathint want = (u == 0 || d == 0) ? b0 : (to_mathint(d) >= u ? 0 : b0 * (u - d) / u);
    assert to_mathint(vestBasis()) == want, "a burn wrote other than the basis scaled by the pile it leaves";
    assert to_mathint(vestMaturity()) == m0, "a burn moved the vest maturity";
}

// The arithmetic: a basis b read ceiled over r seconds of a W-second window is u; scaled floored by (u - d) / u and read back
// over the same r, it reads at most u - d and at least u - d - 1.
rule theScaledBasisReadsBackWithinTheFall(uint128 b, uint64 w, uint64 r, uint256 d) {
    require w > 0 && r > 0 && r <= w;
    mathint p0 = b * r;
    mathint u = p0 % w == 0 ? p0 / w : p0 / w + 1;
    require u > 0 && to_mathint(d) < u;
    mathint b1 = b * (u - d) / u;
    mathint p1 = b1 * r;
    mathint u1 = p1 % w == 0 ? p1 / w : p1 / w + 1;
    assert u1 <= u - d, "a scaled basis read back more than the pile less the fall";
    assert u1 >= u - d - 1, "a scaled basis read back more than one wei under the pile less the fall";
}

// witness: a burn does shrink a standing pile without emptying it, so both bounds above bind on a live basis
rule aBurnCanShrinkAPile(env e, uint256 d) {
    aWindowAhead(e);
    mathint u = unvested(e);
    require d > 0;

    burnVest(e, d);

    satisfy to_mathint(unvested(e)) < u && unvested(e) > 0;
}

// THE RELEASE, `AceVaultNav.release(g)`, the last requester's write: the whole pile vests at once and the mark takes the gross the sync
// read, so nothing deferred is left for a claim to leave behind.
rule aReleaseZeroesThePile(env e, uint256 g) {
    aWindowAhead(e);

    release(e, g);

    assert unvested(e) == 0 && vestBasis() == 0, "a release left a vesting pile";
    assert navMark() == g, "a release left the mark off the gross it was handed";
}

// witness: a release does clear a standing pile
rule aReleaseCanClearAPile(env e, uint256 g) {
    aWindowAhead(e);
    require unvested(e) > 0;

    release(e, g);

    satisfy unvested(e) == 0;
}
