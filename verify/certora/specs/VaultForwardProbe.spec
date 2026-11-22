// REGRESSION ROW: the vault's fourteen forwarded verbs under the prover. AceVault names each verb's selector itself and runs
// its body in a linked library by a DELEGATECALL of the vault's own calldata: `submitCap`, `submitDelist`, `acceptCap` and
// `revokePendingCap` into AceVaultCaps; `claim` and the in-kind `collectForfeited` into AceVaultInKind; the
// door-mode `collectForfeited`, `returnProceeds`, `submitWriteOff`, `acceptWriteOff`, `revokeWriteOff`, `extendFor`,
// `refinanceFor` and `drawMoreFor` into AceVaultFlows.
//
// THE CAUSE IT GUARDS: the forward was first written as an assembly calldatacopy and DELEGATECALL. The prover could not
// resolve that call, and its default summary havocked only the return value, so the library body never ran: a rule over a
// forwarded verb proved things about a no-op. The Solidity form, `lib.delegatecall(msg.data)`, resolves into the library.
//
// THE SECOND CAUSE: the libraries first read the vault's write-once figures back by static call to the vault, and via-IR
// shared those read-backs between two cap verbs in a way the prover could not load. The vault now appends its figures as a
// fixed suffix after the caller's bytes and each library reads them from the end of its calldata, so no call goes back.
// The prover's inliner cannot load a delegatecall carrying that suffix either, so this row runs on the MUNGED vault
// (scripts/certora-munge-vault.sh): each forward a typed internal call, routed by selector AND library, the suffix words in
// transient storage. The row then guards the copy's dispatch: a selector routed to the wrong body, or to none, fails its
// verb's effect row.
//
// Each verb has an EFFECT row that holds only if its body ran on the vault's storage, so it FAILS on a no-op forward, and
// fields it never writes, which FAIL if the call havocs the vault's storage instead. The suffix carries the vault's own
// immutables, so the auth and mode reads are the real ones. The hub, the terms and the door are outside the scene: their
// answers are NONDET, but the hub's `borrowerOf`, which is a ghost so the lending verbs' holder check reads a fixed answer.
//
// WHAT THIS SPEC ASSUMES, each stated where the prover cannot see it for itself:
//   - THE SUFFIX MATCHES THE NAMED IMMUTABLES (`deployed()` below). The constructor packs the five suffix words from the
//     same values the named immutables take, the terms and the door bit included, but the prover cannot run this
//     constructor under via-IR, so it would otherwise pick the two independently: a cap verb by a suffix curator that is
//     not CURATOR. Every rule requires the harness's `tailMatches()`; AceVaultForwardTail's layout tests pin the same
//     equality on a real deploy.
//   - Math.mulDiv IS EXACT: OZ's 512-bit routine is summarized by its definition in unbounded integers with its two revert
//     cases pruned, as VaultArithmetic and VaultSplit do. OZ's implementation of it is taken as correct.
//   - THE ASSET'S CALLS REACH THE DUMMY TOKEN. A library reads the asset from the suffix, so the prover cannot resolve the
//     callee and the catch-all's DISPATCH list routes it by selector, as VaultSplit does. With an empty list every such
//     call havocked only its return, and a return's cash never reached the balance a row reads.
//   - A REAL CLOCK: the write-off due time is stored as `uint64(now) + timelock`, so a row timing it bounds `now`.
//   - A PAYOUT LIST UNDER 2^48: a collect appends at most one payout per token per batch, and the batch count is a uint48,
//     so a claim's cursor never fills its 128-bit half; from a list 2^128 long the packed cursor wraps (`aClaimMakesProgress`).

using DummyERC20 as token;

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mdExact(x, y, d, false);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => mdExactRounded(x, y, d, r);

    function tailMatches() external returns (bool) envfree;
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function capOf(address) external returns (uint192, bool) envfree;
    function pendingCapOf(address) external returns (uint192, bool, uint64) envfree;
    function seizedOf(address) external returns (uint184, uint64, bool) envfree;
    function openSeizedOf() external returns (uint256) envfree;
    function navMark() external returns (uint256) envfree;
    function CURATOR() external returns (address) envfree;
    function GUARDIAN() external returns (address) envfree;
    function DOOR() external returns (address) envfree;
    function IN_KIND() external returns (bool) envfree;
    function CAP_TIMELOCK() external returns (uint64) envfree;
    function MIN_TENOR() external returns (uint64) envfree;
    function decimals() external returns (uint8) envfree;
    function fold() external returns (uint64, uint64) envfree;
    function batchOf(uint256) external returns (uint48, uint208) envfree;
    function trackedSupplyOf() external returns (uint256) envfree;
    function heldTracked(address) external returns (uint256) envfree;
    function cursorOf(address, address) external returns (uint256) envfree;
    function cursorCheckpointOf(address, address) external returns (uint256) envfree;
    function payoutCount(address) external returns (uint256) envfree;
    function payoutOpen(address, uint256) external returns (bool) envfree;
    function token.balanceOf(address) external returns (uint256) envfree;
    function _.borrowerOf(uint256 loanId) external => holderOf(loanId) expect address;

    unresolved external in _._ => DISPATCH [
        token.balanceOf(address),
        token.transfer(address,uint256),
        token.transferFrom(address,address,uint256),
        token.approve(address,uint256)
    ] default NONDET;
}

// The hub's answer to who holds a loan's title: fixed per loan for the whole call, as the hub's own ledger is. PERSISTENT,
// because the vault's AUTO-summarized `collect` havocs every other ghost before the door asks, re-picking the holder.
persistent ghost mapping(uint256 => address) holderGhost;

function holderOf(uint256 loanId) returns address {
    return holderGhost[loanId];
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

// The vault as every deploy leaves it: its suffix words packed from its named immutables.
function deployed() {
    require tailMatches();
}

definition collectVerb(method f) returns bool = f.selector == sig:collectForfeited(uint256[]).selector;

definition capVerb(method f) returns bool =
    f.selector == sig:submitCap(address, uint192).selector || f.selector == sig:submitDelist(address).selector
    || f.selector == sig:acceptCap(address).selector || f.selector == sig:revokePendingCap(address).selector;

// The tracker's own verb; the collect is in-kind or door-mode by the vault's mode, so it is named on its own.
definition trackerVerb(method f) returns bool = f.selector == sig:claim(address[], address).selector;

definition inKindVerb(method f) returns bool = collectVerb(f) || trackerVerb(f);

definition writeOffVerb(method f) returns bool =
    f.selector == sig:submitWriteOff(address).selector || f.selector == sig:acceptWriteOff(address).selector
    || f.selector == sig:revokeWriteOff(address).selector;

// The verbs whose wrapper sweeps around the body, so the sweep may mint the curator's fee.
definition sweptVerb(method f) returns bool =
    collectVerb(f) || f.selector == sig:returnProceeds(address, uint256, bool).selector
    || f.selector == sig:extendFor(uint256, uint256, uint256, bytes, bytes).selector;

// ---- fields the forwarded verbs never write ----

// No forwarded verb but the swept ones mints, burns or moves a share.
rule noForwardMovesAShare(method f, env e, calldataarg args, address holder) filtered {
    f -> capVerb(f) || trackerVerb(f) || writeOffVerb(f)
} {
    deployed();
    uint256 supply0 = totalSupply();
    uint256 bal0 = balanceOf(holder);

    f(e, args);

    assert totalSupply() == supply0, "a forwarded verb moved the share supply";
    assert balanceOf(holder) == bal0, "a forwarded verb moved a holder's shares";
}

// A swept verb burns no share and moves no holder's but the curator's: the only share it can mint is the fee its sweep collects.
rule aSweptVerbMintsOnlyTheFee(method f, env e, calldataarg args, address holder) filtered { f -> sweptVerb(f) } {
    deployed();
    require holder != CURATOR();
    uint256 supply0 = totalSupply();
    uint256 bal0 = balanceOf(holder);

    f(e, args);

    assert totalSupply() >= supply0, "a swept verb burned shares";
    assert balanceOf(holder) == bal0, "a swept verb moved a holder's shares";
}

// A cap or write-off verb leaves the vault's cash, the NAV mark and every holder's standing in the tracker.
rule aCapOrWriteOffVerbLeavesCashMarkAndTracker(method f, env e, calldataarg args, address holder, address t) filtered {
    f -> capVerb(f) || writeOffVerb(f)
} {
    deployed();
    uint256 idle0 = token.balanceOf(currentContract);
    uint256 mark0 = navMark();
    uint256 tracked0 = heldTracked(holder);
    uint256 supply0 = trackedSupplyOf();
    uint256 cursor0 = cursorOf(holder, t);

    f(e, args);

    assert token.balanceOf(currentContract) == idle0, "the verb moved the vault's cash";
    assert navMark() == mark0, "the verb moved the NAV mark";
    assert heldTracked(holder) == tracked0 && trackedSupplyOf() == supply0, "the verb moved tracked shares";
    assert cursorOf(holder, t) == cursor0, "the verb moved a claim cursor";
}

// An in-kind or door-mode verb leaves every key's cap and pending change.
rule aNonCapVerbLeavesTheCaps(method f, env e, calldataarg args, address key) filtered {
    f -> inKindVerb(f) || writeOffVerb(f) || sweptVerb(f)
} {
    deployed();
    uint192 c0;
    bool l0;
    c0, l0 = capOf(key);
    uint192 p0;
    bool pl0;
    uint64 v0;
    p0, pl0, v0 = pendingCapOf(key);

    f(e, args);

    uint192 c1;
    bool l1;
    c1, l1 = capOf(key);
    uint192 p1;
    bool pl1;
    uint64 v1;
    p1, pl1, v1 = pendingCapOf(key);
    assert c1 == c0 && l1 == l0, "the verb moved a cap";
    assert p1 == p0 && pl1 == pl0 && v1 == v0, "the verb moved a pending cap";
}

// A cap verb or a claim leaves the door's ledger; the collect writes it in door mode, so it is not among them.
rule aCapOrTrackerVerbLeavesTheLedger(method f, env e, calldataarg args, address c) filtered { f -> capVerb(f) || trackerVerb(f) } {
    deployed();
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
    assert v1 == v0 && w1 == w0 && o1 == o0 && openSeizedOf() == n0, "the verb moved the door's ledger";
}

// Of the in-kind verbs only the collect, which syncs and sweeps around its body, moves the NAV mark.
rule onlyTheCollectMovesTheMark(method f, env e, calldataarg args) filtered { f -> trackerVerb(f) } {
    deployed();
    uint256 mark0 = navMark();

    f(e, args);

    assert navMark() == mark0, "a claim moved the NAV mark";
}

// ---- each verb's effect: these FAIL if the forward does not run the library body ----

// submitCap: a cut to zero by the curator always lands at once, so on every path that does not revert the key reads zero, listed.
rule aCutLandsExactly(env e, address key) {
    deployed();
    require e.msg.sender == CURATOR();

    submitCap(e, key, 0);

    uint192 c;
    bool listed;
    c, listed = capOf(key);
    assert c == 0 && listed, "a curator's cut to zero did not land";
}

// submitCap: witness that some call moves a key's stored cap.
rule theCapCanMove(env e, address key, uint192 cap) {
    deployed();
    uint192 c0;
    bool l0;
    c0, l0 = capOf(key);

    submitCap(e, key, cap);

    uint192 c1;
    bool l1;
    c1, l1 = capOf(key);
    satisfy c1 != c0;
}

// submitDelist: the curator delisting a row the wildcard does not exceed lands at once, leaving the key unlisted at zero.
rule aDelistUnderTheRowLandsAtOnce(env e, address c, address wildcard) {
    deployed();
    require wildcard == 0;
    require e.msg.sender == CURATOR();
    uint192 w;
    bool wl;
    w, wl = capOf(wildcard);
    uint192 r;
    bool rl;
    r, rl = capOf(c);
    require rl && w <= r;

    submitDelist(e, c);

    uint192 r1;
    bool rl1;
    r1, rl1 = capOf(c);
    assert r1 == 0 && !rl1, "a delist under the row did not land";
}

// acceptCap: a successful accept makes the pending change the key's cap and clears it.
rule anAcceptLandsThePendingChange(env e, address key) {
    deployed();
    uint192 p;
    bool pl;
    uint64 v;
    p, pl, v = pendingCapOf(key);

    acceptCap(e, key);

    uint192 c1;
    bool l1;
    c1, l1 = capOf(key);
    uint192 p1;
    bool pl1;
    uint64 v1;
    p1, pl1, v1 = pendingCapOf(key);
    assert c1 == p && l1 == pl, "the accept did not land the pending change";
    assert v1 == 0, "the accept left the change pending";
}

// revokePendingCap: a successful revoke leaves nothing pending on the key.
rule aRevokeDropsThePending(env e, address key) {
    deployed();
    revokePendingCap(e, key);

    uint192 p;
    bool pl;
    uint64 v;
    p, pl, v = pendingCapOf(key);
    assert v == 0, "the revoke left a change pending";
}

// collectForfeited, in kind: an empty batch still closes the batch waiting from an earlier block, on any nonzero tracked supply.
rule aCollectFoldsWhatWaits(env e) {
    deployed();
    require IN_KIND();
    uint64 n0;
    uint64 b0;
    n0, b0 = fold();
    require n0 != 0 && b0 != 0 && b0 < e.block.number;
    uint256 ts0 = trackedSupplyOf();
    require ts0 != 0;
    uint256[] ids;
    require ids.length == 0;

    collectForfeited(e, ids);

    uint64 n1;
    uint64 b1;
    n1, b1 = fold();
    uint48 closedAt;
    uint208 supply;
    closedAt, supply = batchOf(n0);
    assert b1 == 0 && n1 == n0, "the collect did not close the waiting batch";
    assert supply == ts0, "the batch closed on another supply than the tracked one";
}

// claim: a claim of one token from a stored cursor never moves it back, and moves it on (a payout, or a checkpoint searched) unless
// the next payout's batch is still open.
rule aClaimMakesProgress(env e, address t, address to) {
    deployed();
    require IN_KIND();
    require decimals() <= 30;
    address[] tokens;
    require tokens.length == 1 && tokens[0] == t;
    uint256 c0 = cursorOf(e.msg.sender, t);
    uint256 j0 = cursorCheckpointOf(e.msg.sender, t);
    uint256 n = payoutCount(t);
    require c0 != 0 && c0 < n;
    require n < 2^48; // a token's payout list gains at most one entry per batch, and batches count in a uint48

    claim(e, tokens, to);

    uint256 c1 = cursorOf(e.msg.sender, t);
    uint256 j1 = cursorCheckpointOf(e.msg.sender, t);
    assert c1 >= c0, "the claim moved the cursor back";
    assert c1 > c0 || j1 > j0 || payoutOpen(t, c0), "the claim made no progress it could";
}

// collectForfeited, door mode: witness that the door's collect can open a key.
rule aDoorCollectCanOpenAKey(env e, uint256[] ids) {
    deployed();
    require !IN_KIND() && DOOR() != 0 && e.msg.sender == DOOR();
    uint256 n0 = openSeizedOf();

    collectForfeited(e, ids);

    satisfy openSeizedOf() > n0;
}

// returnProceeds: a non-closing return of cash from the door lands exactly that cash in the vault.
rule aReturnLandsItsCash(env e, address c, uint256 cash) {
    deployed();
    require e.msg.sender == DOOR() && e.msg.sender != currentContract;
    require cash > 0;
    uint256 idle0 = token.balanceOf(currentContract);

    returnProceeds(e, c, cash, false);

    assert to_mathint(token.balanceOf(currentContract)) == idle0 + cash, "the return did not land its cash";
}

// returnProceeds: a closing return of no cash closes an open key and counts it out.
rule aClosingReturnClosesTheKey(env e, address c) {
    deployed();
    uint184 v0;
    uint64 w0;
    bool o0;
    v0, w0, o0 = seizedOf(c);
    require o0;
    uint256 n0 = openSeizedOf();

    returnProceeds(e, c, 0, true);

    uint184 v1;
    uint64 w1;
    bool o1;
    v1, w1, o1 = seizedOf(c);
    assert !o1 && to_mathint(openSeizedOf()) == n0 - 1, "the closing return did not close the key";
}

// submitWriteOff: a successful submit sets the key due exactly one cap timelock from now.
rule aSubmittedWriteOffWaitsTheTimelock(env e, address c) {
    deployed();
    require e.block.timestamp <= max_uint64;
    submitWriteOff(e, c);

    uint184 v;
    uint64 w;
    bool o;
    v, w, o = seizedOf(c);
    assert to_mathint(w) == e.block.timestamp + CAP_TIMELOCK(), "the submit did not set the write-off due at the timelock";
}

// acceptWriteOff: a successful accept zeroes and closes the key and clears the write-off.
rule anAcceptedWriteOffZeroesTheKey(env e, address c) {
    deployed();
    acceptWriteOff(e, c);

    uint184 v;
    uint64 w;
    bool o;
    v, w, o = seizedOf(c);
    assert v == 0 && w == 0 && !o, "the accept left value, a due time or an open key";
}

// revokeWriteOff: a successful revoke leaves no write-off pending on the key.
rule aRevokeClearsTheWriteOff(env e, address c) {
    deployed();
    revokeWriteOff(e, c);

    uint184 v;
    uint64 w;
    bool o;
    v, w, o = seizedOf(c);
    assert w == 0, "the revoke left a write-off pending";
}

// extendFor: on allowance, a successful extension took exactly the fee it answers from the holder.
rule anExtendForPullsItsFeeFromTheHolder(env e, uint256 loanId, uint256 maxFee, uint256 minBufferWad, bytes data, bytes permit2) {
    deployed();
    require e.msg.sender != currentContract;
    require permit2.length == 0;
    uint256 bal0 = token.balanceOf(e.msg.sender);

    uint256 fee = extendFor(e, loanId, maxFee, minBufferWad, data, permit2);

    assert to_mathint(token.balanceOf(e.msg.sender)) == bal0 - fee, "the extension did not pull its fee from the holder";
}

// extendFor: witness that an extension lands for a nonzero fee.
rule anExtendForCanLand(env e, uint256 loanId, uint256 maxFee, uint256 minBufferWad, bytes data, bytes permit2) {
    deployed();
    require e.msg.sender != currentContract;

    uint256 fee = extendFor(e, loanId, maxFee, minBufferWad, data, permit2);

    satisfy fee != 0;
}

// refinanceFor: the body asks the hub who holds the loan and refuses anyone else, so a forward that never ran it would let a
// caller the hub does not name through.
rule aRefinanceForRefusesANonHolder(
    env e, uint256 loanId, address collateral, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad,
    uint64 deadline, uint256 withdrawUnits, address withdrawTo, bytes data
) {
    deployed();
    require holderOf(loanId) != e.msg.sender;

    refinanceFor@withrevert(e, loanId, collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    assert lastReverted, "a refinance for a caller the hub does not name as the holder landed";
}

// drawMoreFor: the body asks the hub who holds the loan and refuses anyone else, so a forward that never ran it would let a
// caller the hub does not name through.
rule aDrawMoreForRefusesANonHolder(env e, uint256 loanId, uint256 amount, uint256 minPayout, uint256 minBufferWad, uint64 deadline, bytes data) {
    deployed();
    require holderOf(loanId) != e.msg.sender;

    drawMoreFor@withrevert(e, loanId, amount, minPayout, minBufferWad, deadline, data);

    assert lastReverted, "a top-up for a caller the hub does not name as the holder landed";
}
