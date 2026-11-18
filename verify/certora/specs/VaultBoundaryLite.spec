// AceVault's BOUNDARY over its forwarded verbs, in a lighter scene. These are VaultBoundary's rules whose property is a check
// the vault makes on its own storage or its own calls, stated over the thirteen verbs the vault forwards into its linked
// libraries: `submitCap`, `submitDelist`, `acceptCap`, `revokePendingCap`, `collectForfeited`, `claim`, `returnProceeds`,
// `submitWriteOff`, `acceptWriteOff`, `revokeWriteOff`, `extendFor`, `refinanceFor` and `drawMoreFor`. Each VaultBoundary rule here keeps its
// name and body, its filter narrowed to those verbs (and `theSeedSharesNeverLeave` its premises), so a verdict here is that rule's verdict on those legs; the two witnesses
// `aForwardedVerbLandsUnlocked` and `aRaiseQueues` are this scene's own. VaultBoundary keeps every other leg, and every rule
// whose property reads the hub stand-in's or the title's records.
//
// THE SCENE: the MUNGED vault (scripts/certora-munge-vault.sh), DummyERC20 as its asset, and its three linked libraries. No
// hub, title, terms or door is in it, so every call to one is NONDET: an arbitrary answer and no write to this scene. The
// DISPATCH list routes only the asset's four calls, which the libraries make to an address they read from the suffix.
//
// WHY NONDET IS SOUND FOR EACH RULE HERE: an arbitrary answer admits every answer the real hub, title or product gives, and
// none of them can write the vault: the lock rule below, and `approve` writes only its caller's allowance, which no forwarded
// verb spends. What NONDET leaves out is a callee moving the asset, so idle cannot change inside a hub call. No rule here
// reads idle, and each is one of five kinds that cannot depend on it:
//   - THE LOCK: every forwarded wrapper takes the lock before its first call, so no path reaches a stand-in at all;
//   - A WRITE MADE BEFORE ANY CALL: the cap and write-off verbs make no external call, and the return's only calls before its
//     ledger write are the sync's hub views, which NONDET models exactly, and the asset's pull, which is dispatched;
//   - A FIELD NO REACHABLE STATEMENT WRITES: the caps outside the cap verbs, the ledger outside its five verbs, and a share
//     balance anywhere but the fee mint, which only raises; no answer can steer a path into a write that is not there;
//   - A REFUSAL ON EVERY PATH: the vault's own market and ask checks sit on every path that has not already reverted;
//   - THE CLAIM'S CALLS: the claim calls only the tokens it names, never a hub or a title, so the scene changes none of them.
// The CALL and STATICCALL opcode hooks below are not storage hooks, which the vault's via-IR storage analysis cannot carry.
//
// WHAT THIS SPEC ASSUMES (`scene` below), each a fact of every deploy that the prover cannot see, as the constructor is not run:
//   - THE SUFFIX MATCHES THE NAMED IMMUTABLES;
//   - THE CONSTRUCTOR'S RAILS on the fee, the vest window, the cap timelock and the tenor rail;
//   - A REAL CLOCK, under 2^63, so the due times stored as `uint64` do not wrap;
//   - THE PRODUCT IS NEITHER THE VAULT NOR THE ASSET;
//   - Math.mulDiv IS EXACT, as VaultBoundary models it. OZ's implementation of it is taken as correct.
// VaultBoundary's two hub premises and its asset-payout premise are dropped: no rule here reads what they constrain.
// Loops unroll twice, so a batch verb's result covers batches of at most two.

using DummyERC20 as token;

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mdExact(x, y, d, false);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => mdExactRounded(x, y, d, r);

    function tailMatches() external returns (bool) envfree;
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function allowance(address, address) external returns (uint256) envfree;
    function pendingCapOf(address) external returns (uint192, bool, uint64) envfree;
    function effectiveCap(address) external returns (uint256) envfree;
    function seizedOf(address) external returns (uint184, uint64, bool) envfree;
    function openSeizedOf() external returns (uint256) envfree;
    function payoutCount(address) external returns (uint256) envfree;
    function guardEntered() external returns (bool) envfree;
    function requestedShares() external returns (uint256) envfree;
    function SEED_SHARES() external returns (uint256) envfree;
    function CURATOR() external returns (address) envfree;
    function GUARDIAN() external returns (address) envfree;
    function TERMS() external returns (address) envfree;
    function DOOR() external returns (address) envfree;
    function PERF_FEE_BPS() external returns (uint16) envfree;
    function VEST_WINDOW() external returns (uint64) envfree;
    function CAP_TIMELOCK() external returns (uint64) envfree;
    function MIN_TENOR() external returns (uint64) envfree;
    function MAX_TENOR() external returns (uint64) envfree;

    unresolved external in _._ => DISPATCH [
        token.balanceOf(address),
        token.transfer(address,uint256),
        token.transferFrom(address,address,uint256),
        token.approve(address,uint256)
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

// The vault as every deploy leaves it; see the header.
function scene(env e) {
    require tailMatches();
    require PERF_FEE_BPS() <= 5000;
    require VEST_WINDOW() >= 3600 && VEST_WINDOW() <= 604800;
    require CAP_TIMELOCK() >= 86400 && CAP_TIMELOCK() <= 1209600;
    require MIN_TENOR() >= 86400 && MIN_TENOR() <= MAX_TENOR() && MAX_TENOR() <= 31536000;
    require e.block.timestamp > 0 && e.block.timestamp < 2^63;
    require TERMS() != currentContract && TERMS() != token;
    require DOOR() != currentContract && DOOR() != token;
}

// The thirteen verbs whose bodies the vault runs in a linked library, under its lock.
definition forwarded(method f) returns bool =
    f.selector == sig:submitCap(address, uint192).selector || f.selector == sig:submitDelist(address).selector
    || f.selector == sig:acceptCap(address).selector || f.selector == sig:revokePendingCap(address).selector
    || f.selector == sig:collectForfeited(uint256[]).selector || f.selector == sig:claim(address[], address).selector
    || f.selector == sig:returnProceeds(address, uint256, bool).selector || f.selector == sig:submitWriteOff(address).selector
    || f.selector == sig:acceptWriteOff(address).selector || f.selector == sig:revokeWriteOff(address).selector
    || f.selector == sig:extendFor(uint256, uint256, uint256, bytes, bytes).selector
    || f.selector == sig:refinanceFor(uint256, address, uint256, uint64, uint256, uint256, uint64, uint256, address, bytes).selector
    || f.selector == sig:drawMoreFor(uint256, uint256, uint256, uint256, uint64, bytes).selector;

// VaultBoundary's exit paths; of them only the in-kind claim is forwarded.
definition exitPath(method f) returns bool =
    f.selector == sig:withdraw(uint256, address, address).selector || f.selector == sig:redeem(uint256, address, address).selector
    || f.selector == sig:claimExit(uint256, address, uint256).selector || f.selector == sig:requestExit(uint256).selector
    || f.selector == sig:cancelExit(uint256).selector || f.selector == sig:lapseExit(address).selector
    || f.selector == sig:crank().selector || f.selector == sig:claim(address[], address).selector;

definition ledgerVerb(method f) returns bool =
    f.selector == sig:collectForfeited(uint256[]).selector || f.selector == sig:returnProceeds(address, uint256, bool).selector
    || f.selector == sig:submitWriteOff(address).selector || f.selector == sig:acceptWriteOff(address).selector
    || f.selector == sig:revokeWriteOff(address).selector;

// ---- the lock: the premise every NONDET answer rests on ----

// Every forwarded verb refuses while the lock is held, so no hub, token or product call can re-enter one.
rule everyMutatorTakesTheLock(method f, env e, calldataarg args) filtered { f -> forwarded(f) } {
    require guardEntered();
    f@withrevert(e, args);
    assert lastReverted, "a mutator ran while the vault's lock was held";
}

// witness: with the lock free each forwarded verb has a path that lands, so the reverts above are the lock's
rule aForwardedVerbLandsUnlocked(method f, env e, calldataarg args) filtered { f -> forwarded(f) } {
    scene(e);
    require !guardEntered();
    f@withrevert(e, args);
    satisfy !lastReverted;
}

// ---- shares ----

// A holder's shares fall only when the caller is the holder, or a spender whose allowance covered the fall.
rule onlyOwnerOrSpenderLowersABalance(method f, env e, calldataarg args, address h) filtered { f -> forwarded(f) } {
    scene(e);
    require h != currentContract;
    // OZ's ERC-20 keeps every balance under the supply; without it a fee mint wraps a holder's unchecked balance to zero
    require balanceOf(h) <= totalSupply();
    uint256 bal0 = balanceOf(h);
    uint256 allow0 = allowance(h, e.msg.sender);

    f(e, args);

    uint256 bal1 = balanceOf(h);
    assert bal1 < bal0 => (e.msg.sender == h || to_mathint(allow0) >= bal0 - bal1), "a stranger lowered a holder's shares";
}

// VaultBoundary's `theSeedSharesNeverLeave` on the forwarded legs: the vault keeps its escrow and its genesis seed's shares.
rule theSeedSharesNeverLeave(method f, env e, calldataarg args) filtered { f -> forwarded(f) } {
    scene(e);
    require e.msg.sender != currentContract;
    require allowance(currentContract, e.msg.sender) == 0;
    require balanceOf(currentContract) <= totalSupply(); // the supply-consistency premise, stated as rules
    require to_mathint(balanceOf(currentContract)) >= requestedShares() + SEED_SHARES();

    f(e, args);

    assert to_mathint(balanceOf(currentContract)) >= requestedShares() + SEED_SHARES(), "a verb took the vault under its escrow and its seed";
}

// ---- caps ----

// A key's effective cap rises only at an accept, of a change on that key or on the wildcard that has waited out its timelock.
rule aCapRaiseLandsOnlyAfterTheTimelock(method f, env e, calldataarg args, address key) filtered { f -> forwarded(f) } {
    scene(e);
    uint256 eff0 = effectiveCap(key);
    uint192 p;
    bool pl;
    uint64 v;
    p, pl, v = pendingCapOf(key);
    uint192 pw;
    bool pwl;
    uint64 vw;
    pw, pwl, vw = pendingCapOf(0);

    f(e, args);

    assert effectiveCap(key) > eff0 => f.selector == sig:acceptCap(address).selector
        && ((v != 0 && e.block.timestamp >= v) || (vw != 0 && e.block.timestamp >= vw)), "a cap rose before its timelock";
}

// A change that queues waits exactly one cap timelock from now.
rule aQueuedChangeWaitsTheTimelock(method f, env e, calldataarg args, address key) filtered { f -> forwarded(f) } {
    scene(e);
    uint192 p0;
    bool l0;
    uint64 v0;
    p0, l0, v0 = pendingCapOf(key);

    f(e, args);

    uint192 p1;
    bool l1;
    uint64 v1;
    p1, l1, v1 = pendingCapOf(key);
    assert v1 != v0 && v1 != 0 => to_mathint(v1) == e.block.timestamp + CAP_TIMELOCK(), "a queued cap change is due before its timelock";
}

// witness: a submit does queue a change, so the rule above is not passing on changes that never wait
rule aRaiseQueues(env e, address key, uint192 cap) {
    scene(e);
    uint192 p0;
    bool l0;
    uint64 v0;
    p0, l0, v0 = pendingCapOf(key);

    submitCap(e, key, cap);

    uint192 p1;
    bool l1;
    uint64 v1;
    p1, l1, v1 = pendingCapOf(key);
    satisfy v1 != v0 && v1 != 0;
}

// A cut by the curator or the guardian lands in its own call: the key's effective cap is the cut, and nothing waits on it.
rule aCapCutLandsAtOnce(env e, address key, uint192 cap) {
    scene(e);
    require e.msg.sender == CURATOR() || (GUARDIAN() != 0 && e.msg.sender == GUARDIAN());
    require to_mathint(cap) < to_mathint(effectiveCap(key));

    submitCap(e, key, cap);

    uint192 p;
    bool pl;
    uint64 v;
    p, pl, v = pendingCapOf(key);
    assert effectiveCap(key) == to_mathint(cap), "a cut did not land in its own call";
    assert v == 0, "a cut left a change pending on its key";
}

// witness: an accept does raise an effective cap
rule anAcceptedRaiseLands(env e, address key) {
    scene(e);
    uint256 eff0 = effectiveCap(key);

    acceptCap(e, key);

    satisfy effectiveCap(key) > eff0;
}

// ---- no exit calls a product ----

ghost address termsG;
ghost address doorG;
ghost bool productCalled;

hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (addr == termsG || (doorG != 0 && addr == doorG)) {
        productCalled = true;
    }
}

hook STATICCALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (addr == termsG || (doorG != 0 && addr == doorG)) {
        productCalled = true;
    }
}

// The in-kind claim makes no call or static call to the terms or the door.
// It calls each token it pays, so a product that is itself a market's collateral would be called AS THAT TOKEN; that edge,
// a product holding payouts in the tracker, is excluded here and disclosed with the result.
rule noExitCallsAProduct(method f, env e, calldataarg args) filtered { f -> exitPath(f) && forwarded(f) } {
    scene(e);
    require termsG == TERMS() && doorG == DOOR();
    require payoutCount(termsG) == 0 && payoutCount(doorG) == 0;
    require !productCalled;

    f(e, args);

    assert !productCalled, "an exit path called the product";
}

// witness: entry does ask the product for its cap, so the hooks above fire on a call this scene leaves unresolved
rule anEntryAsksTheProduct(env e, uint256 assets, address receiver) {
    scene(e);
    require termsG == TERMS() && doorG == DOOR();
    require !productCalled;

    deposit(e, assets, receiver);

    satisfy productCalled;
}

// ---- the seized ledger: the step rules of VaultBoundary's induction that read only the vault ----

// No verb but the five ledger verbs moves any key's record or the open count.
rule onlyLedgerVerbsMoveTheLedger(method f, env e, calldataarg args, address c) filtered { f -> forwarded(f) && !ledgerVerb(f) } {
    scene(e);
    uint184 v0;
    uint64 w0;
    bool o0;
    v0, w0, o0 = seizedOf(c);
    uint256 n0 = openSeizedOf();

    f(e, args);

    uint184 v1;
    uint64 w1;
    bool o1;
    v1, w1, o1 = seizedOf(c);
    assert v1 == v0 && w1 == w0 && o1 == o0 && openSeizedOf() == n0, "a verb outside the ledger moved it";
}

// A return lowers its key's value by its cash, saturating, closes it only when asked and open, and counts it out only then.
rule aReturnLowersOnlyItsKey(env e, address c, uint256 cash, bool closes, address k) {
    scene(e);
    require e.msg.sender == DOOR() && k != c;
    uint184 v0;
    uint64 w0;
    bool o0;
    v0, w0, o0 = seizedOf(c);
    uint184 vk0;
    uint64 wk0;
    bool ok0;
    vk0, wk0, ok0 = seizedOf(k);
    uint256 n0 = openSeizedOf();

    returnProceeds(e, c, cash, closes);

    uint184 v1;
    uint64 w1;
    bool o1;
    v1, w1, o1 = seizedOf(c);
    uint184 vk1;
    uint64 wk1;
    bool ok1;
    vk1, wk1, ok1 = seizedOf(k);
    assert to_mathint(v1) == (v0 > cash ? v0 - cash : 0), "a return moved its key's value by other than its cash";
    assert w1 == w0 && o1 == (o0 && !closes), "a return moved its key's due time, or closed it unasked";
    assert to_mathint(openSeizedOf()) == n0 - (o0 && closes ? 1 : 0), "a return moved the count by other than its own close";
    assert vk1 == vk0 && wk1 == wk0 && ok1 == ok0, "a return moved another key";
}

// An accepted write-off lands only once due, zeroes and closes its own key, and counts it out only if it was open.
rule anAcceptedWriteOffClearsOnlyItsKey(env e, address c, address k) {
    scene(e);
    require k != c;
    uint184 v0;
    uint64 w0;
    bool o0;
    v0, w0, o0 = seizedOf(c);
    uint184 vk0;
    uint64 wk0;
    bool ok0;
    vk0, wk0, ok0 = seizedOf(k);
    uint256 n0 = openSeizedOf();

    acceptWriteOff(e, c);

    uint184 v1;
    uint64 w1;
    bool o1;
    v1, w1, o1 = seizedOf(c);
    uint184 vk1;
    uint64 wk1;
    bool ok1;
    vk1, wk1, ok1 = seizedOf(k);
    assert w0 != 0 && to_mathint(e.block.timestamp) >= to_mathint(w0), "a write-off landed before it was due";
    assert v1 == 0 && w1 == 0 && !o1, "an accepted write-off left value, a due time or an open key";
    assert to_mathint(openSeizedOf()) == n0 - (o0 ? 1 : 0), "an accepted write-off moved the count by other than its own close";
    assert vk1 == vk0 && wk1 == wk0 && ok1 == ok0, "an accepted write-off moved another key";
}

// A write-off's submit or revoke moves only its own key's due time: no value, no open flag, no count.
rule aWriteOffSubmitOrRevokeMovesOnlyItsDueTime(env e, address c, address k, bool submit) {
    scene(e);
    require k != c;
    uint184 v0;
    uint64 w0;
    bool o0;
    v0, w0, o0 = seizedOf(c);
    uint184 vk0;
    uint64 wk0;
    bool ok0;
    vk0, wk0, ok0 = seizedOf(k);
    uint256 n0 = openSeizedOf();

    if (submit) {
        submitWriteOff(e, c);
    } else {
        revokeWriteOff(e, c);
    }

    uint184 v1;
    uint64 w1;
    bool o1;
    v1, w1, o1 = seizedOf(c);
    uint184 vk1;
    uint64 wk1;
    bool ok1;
    vk1, wk1, ok1 = seizedOf(k);
    assert v1 == v0 && o1 == o0 && openSeizedOf() == n0, "a write-off's submit or revoke moved value, the open flag or the count";
    assert vk1 == vk0 && wk1 == wk0 && ok1 == ok0, "a write-off's submit or revoke moved another key";
}

// ---- no refinance pledges the asset ----

// A refinance into a market pledging the vault's own asset is refused, in every mode: the base binds the market to the asked
// collateral, and the door's market check refuses the asset as collateral.
rule aRefinanceNeverPledgesTheAsset(
    env e, uint256 loanId, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad, uint64 deadline,
    uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);

    refinanceFor@withrevert(e, loanId, token, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    assert lastReverted, "a refinance pledged the vault's own asset";
}
