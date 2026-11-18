// `PriceGrid.down`, the one price grid every vault door rounds onto. Every door's spec (`SaeroVault.spec` and the vault
// lanes) carries two facts about it as AXIOMS: `down(p) <= p` and `down(0) == 0`. This spec is written to prove both.
//
// IT DOES NOT RUN YET, AND ITS FAILS ARE NOT EVIDENCE. Under via-IR the prover cannot locate `Math.log2` or
// `TickMath.getTickAtSqrtPrice` inside `down`, in either finder mode, so their summaries do not bind and the run errors:
// every rule but the witness then reads FAIL on havoced calls (`emv-8` and two reruns of 2026-11-13, the second with
// `relaxed` finders). The library cannot be verified directly either: CVL cannot call a library function. Until a form
// binds, the two axioms stay ASSUMED. The decomposition below is the intended proof, kept as the starting point.
//
// WHAT IS PROVEN, AND OVER WHAT. The library's OWN steps run as written: the zero test, `_sqrtShifted`'s two branches and
// its shifts, `sqrtPriceX96`'s clamp into v4's range, `compress` and the step multiply, the `MIN_TICK` test. The four
// audited functions it calls are replaced by their DOCUMENTED CONTRACTS, each a summary that admits every answer the
// contract allows, so the proof holds for any implementation meeting them:
//   OZ `Math.sqrt(x)`         the floor root: r*r <= x < (r+1)^2;
//   OZ `Math.log2(x)`         the floor log: 2^l <= x < 2^(l+1), and 0 at 0;
//   OZ `Math.mulDiv(x, y, d)` the exact floor of x*y/d (here d is the constant 2^96);
//   v4 `TickMath`             `getSqrtPriceAtTick` strictly increasing over [MIN_TICK, MAX_TICK], MIN_SQRT_PRICE at
//                             MIN_TICK; `getTickAtSqrtPrice(s)` a tick in range whose root is at or under `s`, its
//                             natspec's "greatest tick such that getSqrtPriceAtTick(tick) <= sqrtPriceX96" weakened to
//                             any such tick. Both refuse outside their ranges, which the summaries state as `require`s.
// So the axioms the doors assume about OUR library become facts about OZ's and Uniswap's documented functions, which is
// as far as a solver goes: the libraries' own bodies are nonlinear bit arithmetic no SMT run settles.
// A refused input is a reverted `down`, which no door reads: every rule here is about an answer `down` returned.
methods {
    function down(uint256) external returns (uint256) envfree;

    function Math.sqrt(uint256 x) internal returns (uint256) => sqrtFloor(x);
    function Math.log2(uint256 x) internal returns (uint256) => log2Floor(x);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivFloor(x, y, d);
    function TickMath.getTickAtSqrtPrice(uint160 s) internal returns (int24) => tickAtSqrt(s);
    function TickMath.getSqrtPriceAtTick(int24 t) internal returns (uint160) => sqrtAtTick(t);
}

definition MIN_TICK() returns mathint = -887272;
definition MAX_TICK() returns mathint = 887272;
definition MIN_SQRT() returns mathint = 4295128739;
definition MAX_SQRT() returns mathint = 1461446703485210103287273052203988822378723970342;

// OZ `Math.sqrt`: the floor root
function sqrtFloor(uint256 x) returns uint256 {
    uint256 r;
    require to_mathint(r) * to_mathint(r) <= to_mathint(x);
    require (to_mathint(r) + 1) * (to_mathint(r) + 1) > to_mathint(x);
    return r;
}

// OZ `Math.log2`: the floor log, zero at zero
function log2Floor(uint256 x) returns uint256 {
    uint256 l;
    require l < 256;
    require x == 0 => l == 0;
    require x != 0 => (x >> l) == 1;
    return l;
}

// OZ `Math.mulDiv`: the exact floor; a zero divisor or an over-wide quotient is its refusal
function mulDivFloor(uint256 x, uint256 y, uint256 d) returns uint256 {
    require d != 0;
    return require_uint256((to_mathint(x) * to_mathint(y)) / to_mathint(d));
}

// v4 `getSqrtPriceAtTick`, an increasing map of the tick range onto v4's roots
ghost sqrtAtGhost(int24) returns uint160 {
    axiom forall int24 a. forall int24 b. (-887272 <= a && a < b && b <= 887272) => sqrtAtGhost(a) < sqrtAtGhost(b);
    axiom to_mathint(sqrtAtGhost(-887272)) == 4295128739;
}

// v4 `getSqrtPriceAtTick`: refuses a tick outside the range (`InvalidTick`)
function sqrtAtTick(int24 t) returns uint160 {
    require to_mathint(t) >= MIN_TICK() && to_mathint(t) <= MAX_TICK();
    return sqrtAtGhost(t);
}

// v4 `getTickAtSqrtPrice`: refuses a root outside [MIN_SQRT_PRICE, MAX_SQRT_PRICE) (`InvalidSqrtPrice`), else a tick in
// range whose root is at or under it
function tickAtSqrt(uint160 s) returns int24 {
    require to_mathint(s) >= MIN_SQRT() && to_mathint(s) < MAX_SQRT();
    int24 t;
    require to_mathint(t) >= MIN_TICK() && to_mathint(t) <= MAX_TICK();
    require sqrtAtGhost(t) <= s;
    return t;
}

// ZERO UNDER THE GRID, AND ZERO AT ZERO
rule downIsZeroAtZero() {
    assert down(0) == 0, "the grid answered a price for zero";
}

// THE GRID NEVER ROUNDS UP, below the shift's switch: p < 2^160, where the root is taken of `p << 96` directly
rule downNeverExceedsItsArgumentBelowTwoTo160(uint256 p) {
    require to_mathint(p) < 2 ^ 160;
    assert down(p) <= p, "the grid rounded a price up";
}

// and at or above it, where the root is taken of a smaller shift and scaled back
rule downNeverExceedsItsArgumentFromTwoTo160(uint256 p) {
    require to_mathint(p) >= 2 ^ 160;
    assert down(p) <= p, "the grid rounded a price up";
}

// and the grid answers: a positive price on the grid comes back positive
rule witnessTheGridAnswersAPrice(uint256 p) {
    satisfy down(p) > 0;
}
