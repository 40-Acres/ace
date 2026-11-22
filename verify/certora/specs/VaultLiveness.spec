// AceVault's EXIT LIVENESS, the vault's core promise to its LPs: a standing exit request is never stranded by a borrower
// extending past it, an instant exit never takes the idle the requests hold, and the ERC-4626 exit views never revert and
// always name an exit that lands.
//
// THE SCENE, VaultSplit's: the MUNGED vault (scripts/certora-munge-vault.sh), DummyERC20 as its asset, AceLenderView as the
// hub (the two reads NAV and the entry gate make, answered from storage), and the three linked libraries. Under via-IR every
// call to them reaches the prover unresolved, so the catch-all's DISPATCH list routes it by callee and selector. Every other
// callee, the terms, the door and the hub's writing verbs among them, takes the default: NONDET, a fresh answer and no write
// to this scene. Each rule here reads only the vault's own storage, its asset balance and the two stored hub reads, so a view
// read before a verb and the verb's own read see one world.
//
// WHY NONDET IS SOUND HERE: a callee that cannot write the vault's storage is exactly one that cannot re-enter a mutator,
// and `everyMutatorTakesTheLock` proves every mutator but `approve` refuses under the lock. No exit path calls the product.
//
// MULDIV IS EXACT, AND ITS TWO REVERTS ARE A FLAG, NOT A PRUNE. OZ's `Math.mulDiv` reverts on a zero divisor and on a quotient
// past 256 bits. VaultSplit's summary prunes both, which is sound for a property of executions that land and unsound for a
// claim that something never reverts. Here the summary sets `mdReverts` in both cases instead, every rule starts with it
// clear, the two never-revert rules assert it stays clear, and every other rule prunes it before asserting.
//
// WHAT THIS SPEC ASSUMES (`scene` below), each a fact of every deploy that the prover cannot see, as the constructor is not run:
//   - THE SUFFIX MATCHES THE NAMED IMMUTABLES, and THE CONSTRUCTOR'S RAILS on the fee, the vest window, the cap timelock and
//     the tenor rail; a curator that is neither zero nor the vault;
//   - A REAL CLOCK, under 2^63, and the vest maturity at most one window ahead of it (VaultVest's induction hypothesis);
//   - THE PRODUCT IS NONE OF THE SCENE'S OWN CONTRACTS.
// The two never-revert rules add, in `exitable`, the bounds a reachable state has: OZ ERC-20's conservation (each balance
// read, and each distinct pair and triple of them, within the supply), a supply and gross NAV under 2^128, the requests'
// escrow within the vault's own balance (`theSeedSharesNeverLeave`), and no in-kind tracker, whose share-move consistency is
// SAMPLED only (`InKindInvariant`): those two rules cover door and hub-ask vaults.

using DummyERC20 as token;
using AceLenderView as hub;

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mdChecked(x, y, d, false);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => mdCheckedRounded(x, y, d, r);

    function tailMatches() external returns (bool) envfree;
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function allowance(address, address) external returns (uint256) envfree;
    function guardEntered() external returns (bool) envfree;
    function requestedShares() external returns (uint256) envfree;
    function troughHold() external returns (uint48) envfree;
    function vestMaturity() external returns (uint64) envfree;
    function navMark() external returns (uint256) envfree;
    function grossNav() external returns (uint256) envfree;
    function CURATOR() external returns (address) envfree;
    function TERMS() external returns (address) envfree;
    function DOOR() external returns (address) envfree;
    function IN_KIND() external returns (bool) envfree;
    function PERF_FEE_BPS() external returns (uint16) envfree;
    function VEST_WINDOW() external returns (uint64) envfree;
    function CAP_TIMELOCK() external returns (uint64) envfree;
    function MIN_TENOR() external returns (uint64) envfree;
    function MAX_TENOR() external returns (uint64) envfree;

    function token.balanceOf(address) external returns (uint256) envfree;
    function hub.lenderAssets(address, address) external returns (uint256) envfree;

    unresolved external in _._ => DISPATCH [
        token.balanceOf(address),
        token.transfer(address,uint256),
        token.transferFrom(address,address,uint256),
        token.approve(address,uint256),
        hub.lenderAssets(address,address),
        hub.lenderUnresolved(address,address)
    ] default NONDET;
}

// set wherever the real `Math.mulDiv` would revert: a zero divisor, or a quotient past 256 bits
ghost bool mdReverts;

function mdChecked(uint256 x, uint256 y, uint256 d, bool up) returns uint256 {
    mathint p = x * y;
    mathint q = d == 0 ? 0 : ((up && p % d != 0) ? p / d + 1 : p / d);
    if (d == 0 || q > max_uint256) {
        mdReverts = true;
    }
    mathint r = (d == 0 || q > max_uint256) ? 0 : q;
    return require_uint256(r);
}

// OZ rounds up for Ceil and Expand, down for Floor and Trunc; on unsigned values Trunc is Floor and Expand is Ceil
function mdCheckedRounded(uint256 x, uint256 y, uint256 d, Math.Rounding r) returns uint256 {
    return mdChecked(x, y, d, r == Math.Rounding.Ceil || r == Math.Rounding.Expand);
}

// The vault as every deploy leaves it; see the header.
function scene(env e) {
    require !mdReverts;
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
}

// The bounds a reachable state has, for the two never-revert rules; see the header.
function exitable(env e, address receiver) {
    address owner = e.msg.sender;
    require e.msg.value == 0 && owner != 0 && owner != currentContract;
    require !IN_KIND() && !guardEntered();
    require totalSupply() < 2^128;
    require balanceOf(owner) <= totalSupply();
    require balanceOf(currentContract) + balanceOf(CURATOR()) <= to_mathint(totalSupply());
    require owner == CURATOR() || balanceOf(owner) + balanceOf(currentContract) + balanceOf(CURATOR()) <= to_mathint(totalSupply());
    require requestedShares() <= balanceOf(currentContract);
    require token.balanceOf(currentContract) < 2^128 && hub.lenderAssets(currentContract, token) < 2^128;
    require receiver == currentContract || token.balanceOf(receiver) + token.balanceOf(currentContract) <= max_uint256;
}

definition instantExit(method f) returns bool =
    f.selector == sig:redeem(uint256, address, address).selector || f.selector == sig:withdraw(uint256, address, address).selector;

// ---- the exit gate: no extension past a loan's expiry while the standing requests are uncovered ----

// The vault consents to an extension that runs a loan past its expiry only while idle covers the standing requests' worth,
// or a stored trough hold already shuts entry (`AceVaultNav.shutByHoldAlone`, which the harness calls directly as `holdOnly`).
rule anExtensionPastExpiryNeedsCoveredExits(env e, VaultLivenessHarness.Extension x, bytes data) {
    scene(e);

    bytes4 yes = admitsExtension(e, x, data);

    require !mdReverts;
    assert yes != to_bytes4(0) && x.newExpiry > x.expiry => exitsCovered(e) || holdOnly(e),
        "the vault consented to run a loan past its expiry while the exit requests stood uncovered";
}

// The same gate with no restatement in it: with no trough hold stored, uncovered requests refuse every extension past expiry.
rule noExtensionPastExpiryWhileExitsAreUncovered(env e, VaultLivenessHarness.Extension x, bytes data) {
    scene(e);
    require troughHold() == 0;
    require x.newExpiry > x.expiry;
    bool covered = exitsCovered(e);
    require !covered;

    bytes4 yes = admitsExtension(e, x, data);

    require !mdReverts;
    assert yes == to_bytes4(0), "the vault consented past expiry with the requests uncovered and no hold stored";
}

// witness: with requests standing, the vault does consent past expiry, so the gate above is not passing on a policy that always refuses
rule anExtensionPastExpiryCanLand(env e, VaultLivenessHarness.Extension x, bytes data) {
    scene(e);
    require requestedShares() > 0 && x.newExpiry > x.expiry;

    bytes4 yes = admitsExtension(e, x, data);

    require !mdReverts;
    satisfy yes != to_bytes4(0);
}

// ---- an instant exit leaves the requests' hold home ----

// An instant `redeem` or `withdraw` never takes idle below what the standing requests held before it, at the NAV it prices at.
rule anInstantExitTakesNoHeldCash(method f, env e, calldataarg args) filtered { f -> instantExit(f) } {
    scene(e);
    require e.msg.sender != currentContract;
    mathint held0 = heldCash(e);

    f(e, args);

    require !mdReverts;
    assert to_mathint(token.balanceOf(currentContract)) >= held0, "an instant exit took cash the standing requests held";
}

// witness: an instant redeem does pay out of idle while the requests hold some of it
rule anInstantExitCanPayBesideAHold(env e, uint256 shares, address receiver) {
    scene(e);
    require e.msg.sender != currentContract && receiver != currentContract;
    mathint idle0 = token.balanceOf(currentContract);
    mathint held0 = heldCash(e);
    require held0 > 0;

    redeem(e, shares, receiver, e.msg.sender);

    require !mdReverts;
    satisfy to_mathint(token.balanceOf(currentContract)) < idle0;
}

// THE SAME BOUND AT A SETTLED VAULT, the hold's core alone: no fee, the pile matured and the mark at gross, so the exit's
// sync stamps and burns nothing and its fee mints nothing, and what is left is the hold's price against the exit's own.
// A narrower start than the rule above, kept so a TIMEOUT there in the vest and fee arithmetic still settles the check.
rule anInstantExitTakesNoHeldCashWhenSettled(method f, env e, calldataarg args) filtered { f -> instantExit(f) } {
    scene(e);
    require e.msg.sender != currentContract;
    require PERF_FEE_BPS() == 0;
    require vestMaturity() <= e.block.timestamp && to_mathint(navMark()) == grossNav();
    mathint held0 = heldCash(e);

    f(e, args);

    require !mdReverts;
    assert to_mathint(token.balanceOf(currentContract)) >= held0, "an instant exit took cash the standing requests held";
}

// A spender's instant exit spends the owner's allowance by exactly the shares it burns, an unlimited allowance excepted:
// the half VaultBoundary's `onlyOwnerOrSpenderLowersABalance` does not assert (it bounds the fall by the allowance, so a
// check that never decrements passes it), on the two verbs with the vault's own spend, `_exitNow`, at a settled vault so
// the exit's arithmetic stays inside the solver's budget.
rule aSpenderExitSpendsItsAllowanceWhenSettled(env e, uint256 amount, address receiver, address owner, bool byShares) {
    scene(e);
    require PERF_FEE_BPS() == 0;
    require vestMaturity() <= e.block.timestamp && to_mathint(navMark()) == grossNav();
    require owner != currentContract && e.msg.sender != owner && e.msg.sender != currentContract;
    require balanceOf(owner) + balanceOf(currentContract) <= to_mathint(totalSupply());
    uint256 bal0 = balanceOf(owner);
    uint256 allow0 = allowance(owner, e.msg.sender);

    if (byShares) {
        redeem(e, amount, receiver, owner);
    } else {
        withdraw(e, amount, receiver, owner);
    }

    require !mdReverts;
    uint256 bal1 = balanceOf(owner);
    assert bal1 < bal0 => to_mathint(allow0) >= bal0 - bal1, "a spender burned more of the owner's shares than its allowance";
    assert bal1 < bal0 => allow0 == max_uint256 || to_mathint(allowance(owner, e.msg.sender)) == allow0 - (bal0 - bal1),
        "a spender's exit did not spend the allowance by the shares it burned";
}

// ---- the ERC-4626 exit views: they never revert, and the exit they name lands ----

// `maxRedeem(owner)` never reverts, and `redeem(maxRedeem(owner))` by the owner lands, in the same block.
rule maxRedeemNeverRevertsAndLands(env e, address receiver) {
    scene(e);
    exitable(e, receiver);

    uint256 s = maxRedeem@withrevert(e, e.msg.sender);
    assert !lastReverted && !mdReverts, "maxRedeem reverted";

    redeem@withrevert(e, s, receiver, e.msg.sender);
    assert !lastReverted && !mdReverts, "a redeem of maxRedeem reverted";
}

// `maxWithdraw(owner)` never reverts, and `withdraw(maxWithdraw(owner))` by the owner lands, in the same block.
rule maxWithdrawNeverRevertsAndLands(env e, address receiver) {
    scene(e);
    exitable(e, receiver);

    uint256 a = maxWithdraw@withrevert(e, e.msg.sender);
    assert !lastReverted && !mdReverts, "maxWithdraw reverted";

    withdraw@withrevert(e, a, receiver, e.msg.sender);
    assert !lastReverted && !mdReverts, "a withdraw of maxWithdraw reverted";
}

// The redeem view and its exit at a settled vault, as for the hold above: no fee, the pile matured and the mark at gross.
rule maxRedeemNeverRevertsAndLandsWhenSettled(env e, address receiver) {
    scene(e);
    exitable(e, receiver);
    require PERF_FEE_BPS() == 0;
    require vestMaturity() <= e.block.timestamp && to_mathint(navMark()) == grossNav();

    uint256 s = maxRedeem@withrevert(e, e.msg.sender);
    assert !lastReverted && !mdReverts, "maxRedeem reverted";

    redeem@withrevert(e, s, receiver, e.msg.sender);
    assert !lastReverted && !mdReverts, "a redeem of maxRedeem reverted";
}

// witness: the view names a real exit, so the rule above is not passing on a view that always answers zero
rule maxRedeemCanNameShares(env e, address receiver) {
    scene(e);
    exitable(e, receiver);

    uint256 s = maxRedeem(e, e.msg.sender);

    require !mdReverts;
    satisfy s > 0;
}
