// AceVault: the properties that DEPEND on the arithmetic, so mulDiv is modelled EXACTLY here.
//
// Math.mulDiv is OZ's 512-bit routine: floor(x * y / d), reverting on d == 0 or a quotient past 256 bits.
// The summary is that definition in unbounded integers, with the two revert cases pruned, which is equivalent
// for properties of executions that do not revert. OZ's implementation of it is taken as correct.
//
// EVERY EXTERNAL CALL (the hub, the asset, the terms and the door) reaches the prover UNRESOLVED under via-IR and takes
// the catch-all below: NONDET with an empty DISPATCH list, so no side effect and a fresh return value at each call. That
// leaves this vault's storage alone. A CALLBACK INTO THE VAULT IS NOT MODELLED, which is sound here: every vault
// mutator takes the vault's lock, share `transfer` and `transferFrom` included, and the one unguarded mutator, the
// share's `approve`, writes only its caller's allowance, never the fee high-water or the vest.

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mdExact(x, y, d, false);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => mdExactRounded(x, y, d, r);

    function feeHighWater() external returns (uint256) envfree;
    function VEST_WINDOW() external returns (uint64) envfree;
    function vestMaturity() external returns (uint64) envfree; // the harness's one addition: a raw read fails under via-IR
    function PERF_FEE_BPS() external returns (uint16) envfree;
    function MAX_PERF_FEE_BPS() external returns (uint16) envfree;
    function totalSupply() external returns (uint256) envfree;
    function SEED_SHARES() external returns (uint256) envfree;

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

// ---- the performance fee's high-water mark, carried per virtual share: a COLLECTION only ratchets it up ----

// THE RATCHET IS THE COLLECTION'S PROPERTY, NOT THE VAULT'S. An entry raises `feeHighWater` by the larger of its cash
// and its own per-virtual-share price for the shares minted, an exit scales it down by the shares burnt (floored at the
// NAV left), and a vault with no live share restamps it at NAV. So "it never falls" is not the vault's claim, and the rule
// is scoped to the two verbs that do nothing to it but collect, with a holder standing before the call.
// A HOLDER STANDING IS A LIVE SHARE, `totalSupply() > SEED_SHARES()`: the genesis seed's shares sit on the vault for life,
// so a supply of exactly the seed's is the empty vault, and every rule below states its holder that way.
// The figure a share's fee is charged above is the high-water PER VIRTUAL SHARE; the three rules after the entry rules bound it.
definition collectsOnly(method f) returns bool =
    f.selector == sig:collectFee().selector || f.selector == sig:crank().selector;

// The fee bound mirrors the constructor's rail; the ratchet itself does not need it, since a collection writes NAV.
rule feeHighWaterNeverFallsAtACollection(env e, method f, calldataarg args) filtered { f -> collectsOnly(f) } {
    require e.msg.sender != currentContract;
    require PERF_FEE_BPS() <= MAX_PERF_FEE_BPS();
    require totalSupply() > SEED_SHARES();
    mathint before = feeHighWater();
    f(e, args);
    assert feeHighWater() >= before, "a collection lowered the fee high-water, so a curator would be paid twice for one recovery";
}

// ---- an entry raises the high-water by at least its cash, so it never shrinks the fee-free gap in assets ----

// A fee-charging vault with a holder standing: the entry's own collection may lift it to NAV first, then the cash lands.
rule aDepositRaisesTheHighWaterByItsCash(env e, uint256 assets, address receiver) {
    require e.msg.sender != currentContract;
    require PERF_FEE_BPS() > 0 && PERF_FEE_BPS() <= MAX_PERF_FEE_BPS();
    require totalSupply() > SEED_SHARES();
    mathint before = feeHighWater();
    deposit(e, assets, receiver);
    assert feeHighWater() >= before + assets, "a deposit raised the fee high-water by less than its cash";
}

rule aMintRaisesTheHighWaterByItsCash(env e, uint256 shares, address receiver) {
    require e.msg.sender != currentContract;
    require PERF_FEE_BPS() > 0 && PERF_FEE_BPS() <= MAX_PERF_FEE_BPS();
    require totalSupply() > SEED_SHARES();
    mathint before = feeHighWater();
    uint256 assets = mint(e, shares, receiver);
    assert feeHighWater() >= before + assets, "a mint raised the fee high-water by less than the assets it took";
}

// ---- the high-water per virtual share: no collection or entry lowers it, and an exit lowers it by under one wei ----

// The rules above bound `feeHighWater` itself; these bound H / (supply + VIRTUAL_SHARES), cross-multiplied, so exact.
// H and supply move together at four sites only, the entry leg, the two exits' payout and the collection, and every
// other verb reaches the high-water only through the collection, so the three cover each verb that moves either.
// An exit floors its scaled H, the stayers' dust: that is the one wei the exit rule allows, and nothing else does.
// VIRTUAL_SHARES is AceVault's private constant, which no getter reads; it is 10^6 and must agree with the vault.
definition VIRTUAL_SHARES() returns mathint = 10^6;

definition entersOnly(method f) returns bool =
    f.selector == sig:deposit(uint256,address).selector || f.selector == sig:mint(uint256,address).selector;

definition exitsOnly(method f) returns bool =
    f.selector == sig:redeem(uint256,address,address).selector || f.selector == sig:withdraw(uint256,address,address).selector
    || f.selector == sig:claimExit(uint256,address,uint256).selector;

rule aCollectionNeverLowersTheHighWaterPerShare(env e, method f, calldataarg args) filtered { f -> collectsOnly(f) } {
    require e.msg.sender != currentContract;
    require PERF_FEE_BPS() > 0 && PERF_FEE_BPS() <= MAX_PERF_FEE_BPS();
    require totalSupply() > SEED_SHARES();
    mathint h = feeHighWater();
    mathint sv = totalSupply() + VIRTUAL_SHARES();
    f(e, args);
    assert feeHighWater() * sv >= h * (totalSupply() + VIRTUAL_SHARES()), "a collection lowered the high-water per share, so a share pays fee twice";
}

rule anEntryNeverLowersTheHighWaterPerShare(env e, method f, calldataarg args) filtered { f -> entersOnly(f) } {
    require e.msg.sender != currentContract;
    require PERF_FEE_BPS() > 0 && PERF_FEE_BPS() <= MAX_PERF_FEE_BPS();
    require totalSupply() > SEED_SHARES();
    mathint h = feeHighWater();
    mathint sv = totalSupply() + VIRTUAL_SHARES();
    f(e, args);
    assert feeHighWater() * sv >= h * (totalSupply() + VIRTUAL_SHARES()), "an entry lowered the incumbents' high-water per share";
}

rule anExitLowersTheHighWaterPerShareByUnderAWei(env e, method f, calldataarg args) filtered { f -> exitsOnly(f) } {
    require e.msg.sender != currentContract;
    require PERF_FEE_BPS() > 0 && PERF_FEE_BPS() <= MAX_PERF_FEE_BPS();
    require totalSupply() > SEED_SHARES();
    mathint h = feeHighWater();
    mathint sv = totalSupply() + VIRTUAL_SHARES();
    f(e, args);
    assert (feeHighWater() + 1) * sv > h * (totalSupply() + VIRTUAL_SHARES()), "an exit lowered the stayers' high-water per share by a wei or more";
}

// ---- the vest maturity only moves later ----

// THE PRECONDITION IS AN INDUCTION, and both its legs are stated rather than left implicit:
//   BASE: the constructor never writes the maturity `vestMaturity()` reads (only _stampVest does), so it starts at 0 <= now + W.
//     The genesis seed changes nothing here: the constructor books it through `_mintBooked`, which writes the shares, the fee
//     high-water, the mark and the high-water of gross, and never calls `_stampVest`.
//   STEP: the companion rule below, plus one fact of the chain -- block.timestamp never runs backwards.
// The base is a hand step, checkable by reading every write to the layout's vestMaturity field; no rule here checks it.
rule vestMaturityNeverMovesEarlier(env e, method f, calldataarg args) filtered { f -> !f.isView } {
    require e.msg.sender != currentContract;
    require e.block.timestamp + VEST_WINDOW() < 2^64;
    require vestMaturity() <= e.block.timestamp + VEST_WINDOW();
    mathint before = vestMaturity();
    f(e, args);
    assert vestMaturity() >= before, "the vest maturity moved earlier, releasing a deferred gain early";
}

// every write leaves the maturity at most one window ahead of now, which is the precondition above
rule vestMaturityStaysWithinOneWindow(env e, method f, calldataarg args) filtered { f -> !f.isView } {
    require e.msg.sender != currentContract;
    require e.block.timestamp + VEST_WINDOW() < 2^64;
    require vestMaturity() <= e.block.timestamp + VEST_WINDOW();
    f(e, args);
    assert vestMaturity() <= e.block.timestamp + VEST_WINDOW(), "a stamp pushed the maturity past one window";
}
