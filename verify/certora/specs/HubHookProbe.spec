// PROBE: do store hooks on the hub's namespaced storage fire, through the storage-extension harness, on the munged
// via-IR hub? O1 (solvency) needs running sums over the three pots, and a sum is only as good as its hooks.
//
// A ghost MIRRORS one market's revenue pot through an Sstore hook. If, after a verb, the mirror still equals the
// hub's own getter for the same slot, the hook saw every write that verb made. A hook that misses a write -- or an
// extension the prover did not apply -- shows up as a mismatch, not as silence.

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    function FullMath.mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmUp(a, b, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => ozPlain(x, y, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => ozRounded(x, y, d, r);
    function Mul512.gt512(uint256 a, uint256 b, uint256 c, uint256 d) internal returns (bool) => gt512Ghost(a, b, c, d);

    function protocolRevenueOf(bytes32) external returns (uint256) envfree;
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

persistent ghost mapping(bytes32 => uint256) mirror;

hook Sstore currentContract.markets.byId[KEY bytes32 id].s.protocolRevenue uint256 newV {
    mirror[id] = newV;
}

rule theHookSeesEveryRevenueWrite(env e, method f, calldataarg args, bytes32 id)
    filtered { f -> !f.isView && f.contract == currentContract && f.selector != sig:multicall(bytes[]).selector }
{
    require mirror[id] == protocolRevenueOf(id);
    f(e, args);
    assert mirror[id] == protocolRevenueOf(id), "a revenue write slipped past the hook";
}

// and the probe is not vacuous: some verb does write the pot
rule someVerbWritesThePot(env e, method f, calldataarg args, bytes32 id)
    filtered { f -> !f.isView && f.contract == currentContract && f.selector != sig:multicall(bytes[]).selector }
{
    uint256 before = protocolRevenueOf(id);
    f(e, args);
    satisfy protocolRevenueOf(id) != before;
}
