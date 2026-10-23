// Ace hub -- the feasibility probe, and obligation O20: protocol revenue leaves its pot only by being swept WHOLE.
//
// THE POT'S WRITERS, read off the code: LoanAccounting.accrueProtocolFee adds to it; _sweepRevenue zeroes it before
// the transfer and, on a swallowed piggyback failure, restores the same amount. So across any call the pot either
// rises, stays, or falls to exactly zero. A partial fall would be revenue leaving by some other door.
//
// THE ARITHMETIC IS A BLACK BOX: every 512-bit mulDiv (Uniswap's FullMath, OZ's Math) and Mul512.gt512 is an
// uninterpreted, deterministic function, a superset of what the real routines answer. O20 never reads a computed value, so this only
// removes paths the solver need not grind through; it cannot hide a write to the pot.
//
// External calls take the AUTO summary (HAVOC_ECF): other contracts change arbitrarily, this one does not, and no
// callback into the hub is modelled -- every hub mutator is nonReentrant, on the hub's own guard.
// THE HUB'S OWN LIBRARIES MUST RESOLVE AND RUN. A result is only worth anything once a trace shows the library
// body executing (e.g. `Settlement.finalize` with its stores), not a summary standing in for it.

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    function FullMath.mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmUp(a, b, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => ozPlain(x, y, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => ozRounded(x, y, d, r);
    function Mul512.gt512(uint256 a, uint256 b, uint256 c, uint256 d) internal returns (bool) => gt512Ghost(a, b, c, d);

    function protocolRevenueOf(bytes32) external returns (uint256) envfree; // AceHarness: the pot, read through Storage.markets()

    // NO `unresolved external` CATCH-ALL, EVER, ON THE HUB: see HubLoans.spec. It silently turned the hub's library
    // calls into no-ops, which made this rule's first "28 verified" hollow.
}

persistent ghost fmDown(uint256, uint256, uint256) returns uint256;
persistent ghost fmUp(uint256, uint256, uint256) returns uint256;
persistent ghost ozPlain(uint256, uint256, uint256) returns uint256;
persistent ghost ozFloor(uint256, uint256, uint256) returns uint256;
persistent ghost ozCeil(uint256, uint256, uint256) returns uint256;
persistent ghost ozTrunc(uint256, uint256, uint256) returns uint256;
persistent ghost ozExpand(uint256, uint256, uint256) returns uint256;
persistent ghost gt512Ghost(uint256, uint256, uint256, uint256) returns bool;

function ozRounded(uint256 x, uint256 y, uint256 d, Math.Rounding r) returns uint256 {
    if (r == Math.Rounding.Floor) { return ozFloor(x, y, d); }
    if (r == Math.Rounding.Ceil) { return ozCeil(x, y, d); }
    if (r == Math.Rounding.Trunc) { return ozTrunc(x, y, d); }
    return ozExpand(x, y, d);
}

// O20: across any hub call, a market's revenue pot rises, holds, or is swept to zero -- never trimmed
// MULTICALL IS EXCLUDED, for two reasons. It replays ARBITRARY calldata into the hub by self-delegatecall, which the
// prover cannot resolve (its counterexample is that havoc, not a hub path). And its legs are the verbs this rule
// checks one by one; the rule's single-call form does not compose over a batch, which may sweep and then accrue.
rule revenueLeavesOnlyWhole(env e, method f, calldataarg args, bytes32 id)
    filtered { f -> !f.isView && f.contract == currentContract && f.selector != sig:multicall(bytes[]).selector }
{
    mathint before = protocolRevenueOf(id);
    f(e, args);
    mathint after = protocolRevenueOf(id);
    assert after < before => after == 0, "protocol revenue left the pot other than by a whole sweep";
}
