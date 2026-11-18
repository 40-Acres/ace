// CoverageCut: the restore's protocol cut and its net melt, `Deleverage._cut` and `_net`, on Uniswap's OWN `mulDiv`.
//
// CoverageMath.spec summarizes `FullMath.mulDiv` exactly, and inside `_cut` that summary LOST ITS RESULT: the trace showed it
// computing 30 and the harness returning 0 (emv-8). So these two run with no summary at all, on the pure-munged harness.
// The prover cannot follow that 512-bit body once a product passes 2^256 (emv-11), so the domain keeps `gross * bps` under
// it: a gross under 2^128 and a cut at most 1e4 bps (genesis caps it at MAX_DELEVERAGE_PROTOCOL_BPS = 2000). A gross that
// large is past any admissible bill, which a uint128 debt and the stop gate bound.

methods {
    function cut(uint256, uint256, bool) external returns (uint256) envfree;
    function net(uint256, uint256, bool) external returns (uint256) envfree;
}

// `_cut`: "truncated down, loan-favourable", and nothing when the restore does not charge
rule theCutFloorsTheGross(uint256 b, uint256 g, bool charge) {
    require b <= 10000 && g < 2^128;
    mathint c = cut(b, g, charge);
    assert !charge => c == 0, "a crank that charges no cut took one";
    assert charge => c * 10000 <= g * b, "the cut rounded up against the loan";
    assert charge => (c + 1) * 10000 > g * b, "the cut fell a whole atom short";
}

// `_net`: what a gross melts is the gross less its cut, exactly
rule theNetIsTheGrossLessTheCut(uint256 b, uint256 g, bool charge) {
    require b <= 10000 && g < 2^128;
    mathint n = net(b, g, charge);
    assert !charge => n == to_mathint(g), "an uncharged restore melted less than its gross";
    assert charge => n == g - (g * b) / 10000, "the net melt is not the gross less its floored cut";
}

// the cut can be positive, so the floor assertion above is not about zeros alone
rule aCutCanBePositive(uint256 b, uint256 g) {
    require b <= 10000 && g < 2^128;
    satisfy cut(b, g, true) > 0;
}
