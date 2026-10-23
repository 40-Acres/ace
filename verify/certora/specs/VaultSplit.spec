// CuratorVault: SPLIT-ADDITIVITY of entry, the property Bunni v2 lacked. Two entries never beat one entry of their sum.
//
// Bunni's rounding was safe per call and ratcheted across 44 calls; a fuzzer never chained them. A rule stated from
// ANY state covers every chain: a split of n pieces is n-1 applications of the two-piece rule, each from the state
// the previous piece left. Both legs run the real entry, so the first leg's `_sync`, fee collection, vest stamp and
// high-water write are the state the second leg sees.
//
// Math.mulDiv is modelled EXACTLY, as in VaultArithmetic.spec: floor(x * y / d) in unbounded integers, the two revert
// cases pruned, OZ's implementation taken as correct.
//
// THE WORLD THE NAV READS IS STORAGE IN THE SCENE, so the two-call legs and the one-call leg price against one world.
// `grossNav()` reads two things outside the vault: its own balance of the asset, which is its idle cash, and the hub's
// pooled figure for this vault. The asset is `DummyERC20`, a plain token, and the hub is `AceLenderView`, stored
// figures the entry only reads: the pooled figure, and the unsold-pot counts the `InventoryUnsold` gate reads. All of
// it is storage, so `at init` rolls it back with the vault's own, and every leg of a split sees one answer.
// UNDER VIA-IR EVERY ONE OF THOSE CALLS REACHES THE PROVER UNRESOLVED, so neither a selector-keyed summary nor a
// `link` routes it: both were tried, and the catch-all answered each read afresh, so each leg priced an unrelated
// NAV. The catch-all's DISPATCH list is what routes them: a call runs a listed function only when its callee IS that
// contract and its selector matches. The links fix the two immutables the callees are read from (OZ's `_asset` and
// the vault's `ACE`). The asset's pull is dispatched too, so a deposit's cash lands in the balance the next leg reads.
// Every other outside call, the hub's writing verbs a borrow or a crank reaches among them, takes the default.
//
// THE START STATE IS ANY STATE, LESS THREE THINGS NO DEPLOYMENT REACHES (`aReachableStart`), each a fact of the code:
//   - a real clock, as VaultArithmetic.spec states it: the vest maturity is stored as `uint64(now + VEST_WINDOW)`;
//   - the fee bound and the vest-window bounds the constructor enforces;
//   - the pile within the mark: `unvested() <= navMark()`, which the two lemma rules below PROVE inductively. The
//     constructor starts both at zero, every mutator keeps it at its own timestamp, and time only lowers the pile.
// Without the first two the counterexamples began at timestamp 2^255. Without the third they began with a pile k wei
// past a mark equal to gross, the state the vest cap now refuses to write. A fourth premise, the
// redemption queue's escrow, went with the queue.

using DummyERC20 as token;
using AceLenderView as hub;

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mdExact(x, y, d, false);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => mdExactRounded(x, y, d, r);

    function token.balanceOf(address) external returns (uint256) envfree;
    function PERF_FEE_BPS() external returns (uint16) envfree;
    function MAX_PERF_FEE_BPS() external returns (uint16) envfree;
    function VEST_WINDOW() external returns (uint64) envfree;
    function MIN_VEST_WINDOW() external returns (uint64) envfree;
    function MAX_VEST_WINDOW() external returns (uint64) envfree;
    function totalSupply() external returns (uint256) envfree;
    function navMark() external returns (uint256) envfree; // the harness getter: a raw read fails under via-IR
    function unvested() external returns (uint256); // reads the clock, so it takes an env

    unresolved external in _._ => DISPATCH [
        token.balanceOf(address),
        token.transfer(address,uint256),
        token.transferFrom(address,address,uint256),
        token.approve(address,uint256),
        hub.lenderAssets(address,address),
        hub.lenderUnresolved(address,address)
    ] default NONDET;
}

function aReachableStart(env e) {
    require e.block.timestamp > 0 && e.block.timestamp + VEST_WINDOW() < 2^64;
    require PERF_FEE_BPS() <= MAX_PERF_FEE_BPS();
    require VEST_WINDOW() >= MIN_VEST_WINDOW() && VEST_WINDOW() <= MAX_VEST_WINDOW();
    require unvested(e) <= navMark(); // proven by pileStaysWithinMark and pileOnlyDecays
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

// ---- the pile-within-mark lemma, which the split rules' start state assumes ----

// Every mutator, run at time t from a state whose pile at t is within the mark, leaves the pile at t within the mark.
// The stamp is capped at the gross it observed, a fall floors, an exit pays at most NAV, and a deposit lifts both sides.
rule pileStaysWithinMark(env e, method f, calldataarg args) filtered { f -> !f.isView } {
    require e.msg.sender != currentContract;
    require e.block.timestamp > 0 && e.block.timestamp + VEST_WINDOW() < 2^64;
    require PERF_FEE_BPS() <= MAX_PERF_FEE_BPS();
    require VEST_WINDOW() >= MIN_VEST_WINDOW() && VEST_WINDOW() <= MAX_VEST_WINDOW();
    require unvested(e) <= navMark();

    f(e, args);

    assert unvested(e) <= navMark(), "a mutator left the vest pile past the NAV mark";
}

// With storage fixed, the pile read later is never larger: time between two verbs cannot lift it past the mark.
rule pileOnlyDecays(env e1, env e2) {
    require e1.block.timestamp <= e2.block.timestamp;
    assert unvested(e2) <= unvested(e1), "the vest pile grew with the clock alone";
}

// ---- split-additivity ----

// Splitting a deposit never mints more shares than depositing the sum at once, from any state, at one timestamp.
rule depositSplitNeverMintsMore(env e, uint256 x, uint256 y, address receiver) {
    require e.msg.sender != currentContract;
    aReachableStart(e);
    require x + y <= max_uint256;
    storage init = lastStorage;

    uint256 sharesX = deposit(e, x, receiver);
    uint256 sharesY = deposit(e, y, receiver);

    uint256 sharesXY = deposit(e, require_uint256(x + y), receiver) at init;

    assert sharesX + sharesY <= to_mathint(sharesXY), "two deposits minted more shares than one deposit of their sum";
}

// Splitting a mint never charges fewer assets than minting the sum at once, from any state, at one timestamp.
rule mintSplitNeverChargesLess(env e, uint256 s1, uint256 s2, address receiver) {
    require e.msg.sender != currentContract;
    aReachableStart(e);
    require s1 + s2 <= max_uint256;
    storage init = lastStorage;

    uint256 assets1 = mint(e, s1, receiver);
    uint256 assets2 = mint(e, s2, receiver);

    uint256 assets12 = mint(e, require_uint256(s1 + s2), receiver) at init;

    assert assets1 + assets2 >= to_mathint(assets12), "two mints charged fewer assets than one mint of their sum";
}

// ---- witnesses: the legs above complete through the real entry, with the vault's cash actually moving ----

// A split that strictly loses to the whole, both legs minting: a trace with `_sync`, `_collectFeeAt` and `_deposit` running.
rule depositSplitWitness(env e, uint256 x, uint256 y, address receiver) {
    require e.msg.sender != currentContract;
    aReachableStart(e);
    require x + y <= max_uint256;
    uint256 cash0 = token.balanceOf(currentContract);
    storage init = lastStorage;

    uint256 sharesX = deposit(e, x, receiver);
    uint256 sharesY = deposit(e, y, receiver);
    uint256 cashSplit = token.balanceOf(currentContract);

    uint256 sharesXY = deposit(e, require_uint256(x + y), receiver) at init;

    satisfy sharesX > 0 && sharesY > 0 && sharesX + sharesY < to_mathint(sharesXY) && to_mathint(cashSplit) == cash0 + x + y;
}

rule mintSplitWitness(env e, uint256 s1, uint256 s2, address receiver) {
    require e.msg.sender != currentContract;
    aReachableStart(e);
    require s1 + s2 <= max_uint256;
    storage init = lastStorage;

    uint256 assets1 = mint(e, s1, receiver);
    uint256 assets2 = mint(e, s2, receiver);

    uint256 assets12 = mint(e, require_uint256(s1 + s2), receiver) at init;

    satisfy assets1 > 0 && assets2 > 0 && assets1 + assets2 > to_mathint(assets12);
}
