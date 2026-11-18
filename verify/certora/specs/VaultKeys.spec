// AceVault's KEYS: who may move each piece of privileged state, over every verb, and whose exit request a verb may move.
//
// The privileged state and its keys, as AceVaultCaps, AceVaultFlows and AceVault write them:
//   - a key's cap (`caps`): landed at once only by the curator or the guardian, or by anyone's `acceptCap` once due;
//   - a key's pending cap change (`pendingCaps`): queued only by the curator; dropped by the curator or the guardian, or at
//     anyone's `acceptCap` once due;
//   - a write-off's due time (`seized[c].writeOffAt`): set only by the curator; cleared by the curator or the guardian, at
//     anyone's `acceptWriteOff` once due, or by the door's own collect on that key;
//   - the drain (`draining`): on by the curator or the guardian, off by the curator alone;
//   - the dead-pot exemption (`exemptSettled`): written by the guardian, or zeroed by the door's own collect once voided;
//   - the door's two verbs, `returnProceeds` and the door-mode `collectForfeited`: the door alone.
// No rule here asks WHEN (the timelocks are VaultBoundary's and VaultBoundaryLite's cap and write-off rules) or HOW MUCH; each
// asks WHO, so a new verb, or an old one losing its key check, that writes privileged state fails here on its own selector.
//
// AND THE REQUESTS, PER HOLDER. `theSeedSharesNeverLeave` bounds the requests' TOTAL against the vault's balance, and a total
// over a set cannot see value move between its members. So `aRequestMovesOnlyWithItsHolder` asserts per holder, across one
// call: no verb but `lapseExit` moves a request its caller does not own, and the requests' total moves by exactly the
// caller's own request's change. `aLapseMovesOnlyItsHoldersRequest` is the step for `lapseExit`. With both totals zero at
// construction, the two rules are the induction's step for `requestedShares == sum of every holder's request`.
//
// THE SCENE, VaultBoundaryLite's: the MUNGED vault, DummyERC20 as its asset, the three linked libraries; the hub, the title,
// the terms and the door NONDET. Every write a rule reads is a vault storage write made under the caller's own checks, so an
// arbitrary hub or product answer can only add paths, never steer one past a key check that is not there.
//
// WHAT THIS SPEC ASSUMES (`scene` below), as VaultBoundaryLite does: the suffix matches the named immutables, the
// constructor's rails, a real clock, and a product that is neither the vault nor the asset. And A REAL SENDER: no call comes
// from the zero address, which a vault with no guardian names as its guardian.
//
// Math.mulDiv IS NONDET HERE, an arbitrary answer at each call, which admits every real one. No write a rule reads is
// priced: who may move a cap, a write-off, the drain, the exemption or a request never turns on a quotient. So the
// over-approximation can only add paths, and it keeps the vest and fee arithmetic every verb's sync runs out of the
// solver, which with the exact summary held the sync-bearing verbs past a 3-hour budget in this scene.

using DummyERC20 as token;

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => NONDET;
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => NONDET;

    function tailMatches() external returns (bool) envfree;
    function capOf(address) external returns (uint192, bool) envfree;
    function pendingCapOf(address) external returns (uint192, bool, uint64) envfree;
    function seizedOf(address) external returns (uint184, uint64, bool) envfree;
    function draining() external returns (bool) envfree;
    function exemptSettledOf() external returns (uint256) envfree;
    function requestOf(address) external returns (uint256) envfree;
    function requestExpiryOf(address) external returns (uint64) envfree;
    function requestedShares() external returns (uint256) envfree;
    function CURATOR() external returns (address) envfree;
    function GUARDIAN() external returns (address) envfree;
    function TERMS() external returns (address) envfree;
    function DOOR() external returns (address) envfree;
    function IN_KIND() external returns (bool) envfree;
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
    require e.msg.sender != 0;
}

// ---- who moves the privileged state ----

// Every verb, from any state: each piece of privileged state moves only by its keys, or at its permissionless accept.
rule onlyTheKeysMovePrivilegedState(method f, env e, calldataarg args, address key, address c) filtered { f -> !f.isView } {
    scene(e);
    bool byCurator = e.msg.sender == CURATOR();
    bool byGuardian = e.msg.sender == GUARDIAN();
    bool byDoor = e.msg.sender == DOOR();
    uint192 cap0;
    bool listed0;
    cap0, listed0 = capOf(key);
    uint192 pc0;
    bool pl0;
    uint64 pv0;
    pc0, pl0, pv0 = pendingCapOf(key);
    uint184 sv0;
    uint64 w0;
    bool so0;
    sv0, w0, so0 = seizedOf(c);
    bool d0 = draining();
    uint256 x0 = exemptSettledOf();

    f(e, args);

    uint192 cap1;
    bool listed1;
    cap1, listed1 = capOf(key);
    uint192 pc1;
    bool pl1;
    uint64 pv1;
    pc1, pl1, pv1 = pendingCapOf(key);
    uint184 sv1;
    uint64 w1;
    bool so1;
    sv1, w1, so1 = seizedOf(c);
    bool d1 = draining();
    uint256 x1 = exemptSettledOf();
    bool accept = f.selector == sig:acceptCap(address).selector;

    assert (cap1 != cap0 || listed1 != listed0) => byCurator || byGuardian || accept, "a stranger moved a cap";
    assert (pc1 != pc0 || pl1 != pl0 || pv1 != pv0) => byCurator || byGuardian || accept, "a stranger moved a pending cap change";
    assert (pv1 != pv0 && pv1 != 0) => byCurator, "anyone but the curator queued a cap change";
    assert (w1 != w0 && w1 != 0) => byCurator, "anyone but the curator queued a write-off";
    assert (w1 != w0 && w1 == 0) => byCurator || byGuardian || f.selector == sig:acceptWriteOff(address).selector
        || (byDoor && f.selector == sig:collectForfeited(uint256[]).selector), "a stranger dropped a pending write-off";
    assert (d0 && !d1) => byCurator, "anyone but the curator switched the drain off";
    assert (!d0 && d1) => byCurator || byGuardian, "a stranger switched the drain on";
    assert x1 != x0 => byGuardian || (byDoor && f.selector == sig:collectForfeited(uint256[]).selector && x1 == 0),
        "anyone but the guardian, or the door's collect voiding it, moved the dead-pot exemption";
}

// The door's return refuses every caller but the door.
rule onlyTheDoorReturnsProceeds(env e, address c, uint256 cash, bool closes) {
    scene(e);
    require e.msg.sender != DOOR();

    returnProceeds@withrevert(e, c, cash, closes);

    assert lastReverted, "a caller other than the door returned proceeds";
}

// A door-mode collect refuses every caller but the door.
rule onlyTheDoorCollectsInDoorMode(env e, uint256[] ids) {
    scene(e);
    require !IN_KIND() && e.msg.sender != DOOR();

    collectForfeited@withrevert(e, ids);

    assert lastReverted, "a caller other than the door ran a door-mode collect";
}

// witness: the door's return does land for the door, so the refusal above is the door check's
rule theDoorCanReturnProceeds(env e, address c, uint256 cash, bool closes) {
    scene(e);
    require e.msg.sender == DOOR() && DOOR() != 0;

    returnProceeds@withrevert(e, c, cash, closes);

    satisfy !lastReverted;
}

// ---- the requests, per holder ----

// No verb but `lapseExit` moves a request its caller does not own, and the requests' total moves by exactly the caller's own.
rule aRequestMovesOnlyWithItsHolder(method f, env e, calldataarg args, address h) filtered {
    f -> !f.isView && f.selector != sig:lapseExit(address).selector
} {
    scene(e);
    mathint r0 = requestOf(h);
    mathint total0 = requestedShares();

    f(e, args);

    mathint r1 = requestOf(h);
    assert h != e.msg.sender => r1 == r0, "a verb moved a request its caller does not own";
    assert h == e.msg.sender => requestedShares() - total0 == r1 - r0, "the requests' total moved by other than the caller's own request";
}

// A lapse, once due, returns exactly its holder's whole request, and moves no other.
rule aLapseMovesOnlyItsHoldersRequest(env e, address holder, address h) {
    scene(e);
    require h != holder;
    mathint mine0 = requestOf(holder);
    mathint other0 = requestOf(h);
    mathint total0 = requestedShares();
    uint64 due = requestExpiryOf(holder);

    lapseExit(e, holder);

    assert to_mathint(e.block.timestamp) >= to_mathint(due), "a request lapsed before its lease ran";
    assert requestOf(holder) == 0 && to_mathint(requestedShares()) == total0 - mine0, "a lapse returned other than its holder's whole request";
    assert to_mathint(requestOf(h)) == other0, "a lapse moved another holder's request";
}

// witness: a cancel does move the caller's request, so the per-holder rule above is not passing on requests nothing moves
rule aCancelCanMoveARequest(env e, uint256 shares) {
    scene(e);
    mathint r0 = requestOf(e.msg.sender);

    cancelExit(e, shares);

    satisfy to_mathint(requestOf(e.msg.sender)) < r0;
}
