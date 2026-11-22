// AceVault's SHARE VALUE: no verb dilutes a share, a deposit redeemed in the same block pays back at most its cash, an entry
// is worth its cash less at most one share, and the fee's mint is worth at most its cut. These are the per-verb rounding
// directions: each conversion rounds against the caller (deposit and redeem down, mint and withdraw up), and a slip in one
// direction moves value between the caller and the stayers on every call.
//
// THE SCENE, VaultSplit's (see VaultLiveness.spec): the MUNGED vault, DummyERC20 as its asset, AceLenderView as the hub, its
// three linked libraries, the DISPATCH list routing the asset and the two stored hub reads, every other callee NONDET. So the
// hub's writing verbs move no cash here: a borrow, a crank or a lending verb is NAV-neutral in this scene, and what the rules
// test is the vault's own arithmetic, entry, exit, request, fee and vest. The hub's own books are the hub specs' to prove.
//
// Math.mulDiv IS EXACT, floor(x * y / d) in unbounded integers with its two revert cases pruned, as VaultSplit models it.
//
// THE START STATE (`valueStart` below), each a fact of the code that a rule takes because it starts from an arbitrary state:
//   - the suffix, the constructor's rails and a real clock, as VaultLiveness states them;
//   - the pile within the mark, `unvested() <= navMark()` (VaultSplit's lemma `pileStaysWithinMark`, PROVEN on 12 verbs and
//     unsettled on the rest), so NAV is gross less the pile and never saturates at zero;
//   - SUPPLY CONSISTENCY, in VaultBoundary's form (): the caller's balance plus the vault's
//     own within the supply. `redeem` and `withdraw` burn an OWNER's shares, so they have their own rule with the owner named.
// VIRTUAL_SHARES is AceVault's private constant, 10^6; the virtual asset is one.

using DummyERC20 as token;
using AceLenderView as hub;

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mdExact(x, y, d, false);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => mdExactRounded(x, y, d, r);

    function tailMatches() external returns (bool) envfree;
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function navMark() external returns (uint256) envfree;
    function vestMaturity() external returns (uint64) envfree;
    function feeHighWater() external returns (uint256) envfree;
    function grossNav() external returns (uint256) envfree;
    function payoutCount(address) external returns (uint256) envfree;
    function CURATOR() external returns (address) envfree;
    function TERMS() external returns (address) envfree;
    function DOOR() external returns (address) envfree;
    function PERF_FEE_BPS() external returns (uint16) envfree;
    function VEST_WINDOW() external returns (uint64) envfree;
    function CAP_TIMELOCK() external returns (uint64) envfree;
    function MIN_TENOR() external returns (uint64) envfree;
    function MAX_TENOR() external returns (uint64) envfree;

    function token.balanceOf(address) external returns (uint256) envfree;

    unresolved external in _._ => DISPATCH [
        token.balanceOf(address),
        token.transfer(address,uint256),
        token.transferFrom(address,address,uint256),
        token.approve(address,uint256),
        hub.lenderAssets(address,address),
        hub.lenderUnresolved(address,address)
    ] default NONDET;
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

definition VIRTUAL_SHARES() returns mathint = 10^6;

// A reachable start; see the header.
function valueStart(env e) {
    require tailMatches();
    require PERF_FEE_BPS() <= 5000;
    require VEST_WINDOW() >= 3600 && VEST_WINDOW() <= 604800;
    require CAP_TIMELOCK() >= 86400 && CAP_TIMELOCK() <= 1209600;
    require MIN_TENOR() >= 86400 && MIN_TENOR() <= MAX_TENOR() && MAX_TENOR() <= 31536000;
    require e.block.timestamp > 0 && e.block.timestamp < 2^63;
    require vestMaturity() <= e.block.timestamp + VEST_WINDOW();
    require CURATOR() != 0 && CURATOR() != currentContract;
    require TERMS() != currentContract && TERMS() != hub && TERMS() != token;
    require DOOR() != currentContract && DOOR() != hub && DOOR() != token;
    require e.msg.sender != currentContract;
    require unvested(e) <= navMark(); // VaultSplit's `pileStaysWithinMark`
    require balanceOf(e.msg.sender) + balanceOf(currentContract) <= to_mathint(totalSupply()); //
    require payoutCount(token) == 0; // VaultBoundary's premise: no loan of the vault's pledges the asset, so no in-kind payout of it
}

definition instantExit(method f) returns bool =
    f.selector == sig:redeem(uint256, address, address).selector || f.selector == sig:withdraw(uint256, address, address).selector;

// ---- no verb dilutes a share ----

// With no fee, the assets behind one virtual share, (totalAssets + 1) / (totalSupply + VIRTUAL_SHARES), never fall across a
// verb, at one timestamp. Every conversion rounds in the stayers' favour, so the stayers' price can only hold or rise.
// `redeem` and `withdraw` burn an OWNER's shares, who may not be the caller, so they are the rule after this one.
rule noVerbDilutesAShare(method f, env e, calldataarg args) filtered { f -> !f.isView && !instantExit(f) } {
    valueStart(e);
    require PERF_FEE_BPS() == 0;
    mathint a0 = totalAssets(e);
    mathint s0 = totalSupply() + VIRTUAL_SHARES();

    f(e, args);

    assert (totalAssets(e) + 1) * s0 >= (a0 + 1) * (totalSupply() + VIRTUAL_SHARES()), "a verb lowered the assets behind a share";
}

// The same step for the two instant exits, the owner named and held within the supply, as VaultBoundary names `transferFrom`'s payer.
rule noInstantExitDilutesAShare(env e, uint256 amount, address receiver, address owner, bool byShares) {
    valueStart(e);
    require PERF_FEE_BPS() == 0;
    require owner == currentContract || balanceOf(owner) + balanceOf(currentContract) <= to_mathint(totalSupply());
    require balanceOf(currentContract) <= totalSupply();
    mathint a0 = totalAssets(e);
    mathint s0 = totalSupply() + VIRTUAL_SHARES();

    if (byShares) {
        redeem(e, amount, receiver, owner);
    } else {
        withdraw(e, amount, receiver, owner);
    }

    assert (totalAssets(e) + 1) * s0 >= (a0 + 1) * (totalSupply() + VIRTUAL_SHARES()), "an instant exit lowered the assets behind a share";
}

// THE SAME TWO STEPS AT A SETTLED VEST, the rounding core alone: with the pile matured and the mark at gross, no sync stamps
// or burns, so NAV is gross and each verb's share price is its conversion's rounding and nothing else. A narrower start than
// the two rules above, kept so a TIMEOUT there in the vest's arithmetic still leaves every conversion's direction settled.
rule noVerbDilutesASettledShare(method f, env e, calldataarg args) filtered { f -> !f.isView && !instantExit(f) } {
    valueStart(e);
    require PERF_FEE_BPS() == 0;
    require vestMaturity() <= e.block.timestamp && to_mathint(navMark()) == grossNav();
    mathint a0 = totalAssets(e);
    mathint s0 = totalSupply() + VIRTUAL_SHARES();

    f(e, args);

    assert (totalAssets(e) + 1) * s0 >= (a0 + 1) * (totalSupply() + VIRTUAL_SHARES()), "a verb lowered the assets behind a share";
}

rule noInstantExitDilutesASettledShare(env e, uint256 amount, address receiver, address owner, bool byShares) {
    valueStart(e);
    require PERF_FEE_BPS() == 0;
    require vestMaturity() <= e.block.timestamp && to_mathint(navMark()) == grossNav();
    require owner == currentContract || balanceOf(owner) + balanceOf(currentContract) <= to_mathint(totalSupply());
    require balanceOf(currentContract) <= totalSupply();
    mathint a0 = totalAssets(e);
    mathint s0 = totalSupply() + VIRTUAL_SHARES();

    if (byShares) {
        redeem(e, amount, receiver, owner);
    } else {
        withdraw(e, amount, receiver, owner);
    }

    assert (totalAssets(e) + 1) * s0 >= (a0 + 1) * (totalSupply() + VIRTUAL_SHARES()), "an instant exit lowered the assets behind a share";
}

// witness: a deposit does raise the assets behind a share by its rounding, so the rule above is not passing on prices nothing moves
rule aDepositCanRaiseTheShareValue(env e, uint256 assets, address receiver) {
    valueStart(e);
    require PERF_FEE_BPS() == 0;
    mathint a0 = totalAssets(e);
    mathint s0 = totalSupply() + VIRTUAL_SHARES();

    deposit(e, assets, receiver);

    satisfy (totalAssets(e) + 1) * s0 > (a0 + 1) * (totalSupply() + VIRTUAL_SHARES());
}

// ---- a round trip, and what an entry is worth ----

// A deposit redeemed in the same block by its depositor pays back at most the cash it took, fee or none.
rule aDepositThenRedeemPaysAtMostItsCash(env e, uint256 assets, address receiver) {
    valueStart(e);

    uint256 shares = deposit(e, assets, e.msg.sender);
    uint256 back = redeem(e, shares, receiver, e.msg.sender);

    assert back <= assets, "a deposit redeemed at once paid back more than its cash";
}

// An entry is worth its cash less at most one share: the shares a deposit mints, plus one, are worth at least its cash at
// the NAV and supply it leaves; and a deposit whose cash buys a share at the price it pays mints at least one.
rule anEntryIsWorthItsCashLessOneShare(env e, uint256 assets, address receiver) {
    valueStart(e);
    mathint a0 = totalAssets(e);
    mathint q0 = totalSupply() + VIRTUAL_SHARES() + pendingFeeShares(e);

    uint256 shares = deposit(e, assets, receiver);

    mathint a1 = totalAssets(e);
    mathint q1 = totalSupply() + VIRTUAL_SHARES();
    assert (shares + 1) * (a1 + 1) >= assets * q1, "a deposit's shares were worth less than its cash less one share";
    assert assets * q0 >= a0 + 1 => shares > 0, "a deposit whose cash buys a share minted none";
}

// The same two bounds at a settled vest, the pile matured and the mark at gross, as the settled dilution rules state them:
// the entry's own conversion with no stamp or burn before it. A fee may still stand, so the entry's collection runs.
rule anEntryIsWorthItsCashLessOneShareWhenSettled(env e, uint256 assets, address receiver) {
    valueStart(e);
    require vestMaturity() <= e.block.timestamp && to_mathint(navMark()) == grossNav();
    mathint a0 = totalAssets(e);
    mathint q0 = totalSupply() + VIRTUAL_SHARES() + pendingFeeShares(e);

    uint256 shares = deposit(e, assets, receiver);

    mathint a1 = totalAssets(e);
    mathint q1 = totalSupply() + VIRTUAL_SHARES();
    assert (shares + 1) * (a1 + 1) >= assets * q1, "a deposit's shares were worth less than its cash less one share";
    assert assets * q0 >= a0 + 1 => shares > 0, "a deposit whose cash buys a share minted none";
}

rule aDepositThenRedeemPaysAtMostItsCashWhenSettled(env e, uint256 assets, address receiver) {
    valueStart(e);
    require vestMaturity() <= e.block.timestamp && to_mathint(navMark()) == grossNav();

    uint256 shares = deposit(e, assets, e.msg.sender);
    uint256 back = redeem(e, shares, receiver, e.msg.sender);

    assert back <= assets, "a deposit redeemed at once paid back more than its cash";
}

// ---- the fee's mint ----

// A collection mints the curator shares worth at most the fee, PERF_FEE_BPS of NAV's rise past the high-water, at the NAV
// and supply it leaves, rounded down as a redeem would pay them.
rule aFeeMintIsWorthAtMostItsCut(env e) {
    valueStart(e);
    require PERF_FEE_BPS() > 0;
    mathint a = totalAssets(e);
    mathint h = feeHighWater();
    mathint c0 = balanceOf(CURATOR());
    require c0 + balanceOf(currentContract) <= to_mathint(totalSupply());

    collectFee(e);

    mathint minted = balanceOf(CURATOR()) - c0;
    mathint fee = a > h ? (a - h) * PERF_FEE_BPS() / 10000 : 0;
    mathint a1 = totalAssets(e);
    assert minted * (a1 + 1) < (fee + 1) * (totalSupply() + VIRTUAL_SHARES()), "the fee's shares are worth more than its cut";
}

// The same bound at a settled vest, the pile matured and the mark at gross, so the collection's sync stamps and burns
// nothing and the rule weighs the fee's two quotients alone.
rule aFeeMintIsWorthAtMostItsCutWhenSettled(env e) {
    valueStart(e);
    require PERF_FEE_BPS() > 0;
    require vestMaturity() <= e.block.timestamp && to_mathint(navMark()) == grossNav();
    mathint a = totalAssets(e);
    mathint h = feeHighWater();
    mathint c0 = balanceOf(CURATOR());
    require c0 + balanceOf(currentContract) <= to_mathint(totalSupply());

    collectFee(e);

    mathint minted = balanceOf(CURATOR()) - c0;
    mathint fee = a > h ? (a - h) * PERF_FEE_BPS() / 10000 : 0;
    mathint a1 = totalAssets(e);
    assert minted * (a1 + 1) < (fee + 1) * (totalSupply() + VIRTUAL_SHARES()), "the fee's shares are worth more than its cut";
}

// witness: a collection does mint fee shares, so the bound above is not passing on a fee that never mints
rule aFeeMintCanLand(env e) {
    valueStart(e);
    require PERF_FEE_BPS() > 0;
    mathint c0 = balanceOf(CURATOR());

    collectFee(e);

    satisfy balanceOf(CURATOR()) > c0;
}
