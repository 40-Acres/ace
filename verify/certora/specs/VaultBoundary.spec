// AceVault's BOUNDARY: what the vault enforces whatever its product answers. The terms contract and the door are outside the
// scene, so every answer they give, every market they build and every draw they admit is arbitrary (NONDET); each rule
// holds for ANY product. They are the boundary the vault's design claims: what NAV is, who moves shares, where cash goes,
// the caps, the total and the drawdown, the tenor rail, that no exit calls the product, that every lending door on a live
// loan acts only for its holder, that nothing rests and every title goes home, and that the door's seized ledger is conserved.
//
// THE SCENE, each piece a stand-in whose behaviour admits at least the real one's on what a rule reads:
//   - the MUNGED vault (scripts/certora-munge-vault.sh): its fourteen forwarded verbs as typed internal calls;
//   - DummyERC20 as the asset, a plain token;
//   - BoundaryHub as the hub: reads answered from storage, writes recorded, and the asset moved as the hub moves it. A deposit
//     pulls into resting, an open lends from resting and pays the borrower less the hub's fee, a withdraw or a collect pays
//     the lender, a refinance pays its caller the net, an extension pulls its fee, a top-up pays the loan's holder. Its
//     `lenderAssets` counts resting, live claims and owed, so the vault's gross NAV moves exactly as the hub's books would
//     move it; their correctness is the hub specs' to prove;
//   - BoundaryTitle as the loan-title collection: the hub mints, the vault hands over.
// Under via-IR every call to them reaches the prover unresolved, so the catch-all's DISPATCH list routes it by callee and
// selector, as VaultSplit's does; the links fix the immutables the callees are read from. Every other callee, the terms,
// the door and any collateral token among them, takes the default: NONDET, a fresh answer and no write to this scene.
//
// WHY NONDET IS SOUND FOR THE TERMS AND THE DOOR: a callee that cannot write the vault's storage is exactly a callee that
// cannot re-enter a mutator, and `everyMutatorTakesTheLock` below proves every mutator but the share's `approve` refuses
// while the lock is held. `approve` writes only its caller's own allowance.
//
// WHAT THIS SPEC ASSUMES, each stated where the prover cannot see it for itself (`scene` below):
//   - THE SUFFIX MATCHES THE NAMED IMMUTABLES, as VaultForwardProbe states it: the constructor is not run.
//   - THE CONSTRUCTOR'S RAILS on the fee, the vest window, the cap timelock and the tenor rail, for the same reason.
//   - A REAL CLOCK, under 2^63, so the vest maturity and the due times stored as `uint64` do not wrap.
//   - THE HUB OWES THE VAULT NO MORE THAN IT HOLDS FOR IT (`lenderOwed <= lenderAssets`), as the hub's books keep it.
//   - THE PRODUCT IS NONE OF THE SCENE'S OWN CONTRACTS: the terms and the door are not the vault, the hub, the title or the
//     asset. A product may be its own door.
//   - THE IN-KIND TRACKER HOLDS NO PAYOUT OF THE ASSET: a collect pushes one only for the collateral of a loan the vault
//     opened, and `aBorrowNeverPledgesTheAsset` and `aRefinanceNeverPledgesTheAsset` below show no such loan pledges the
//     asset; from an arbitrary start a claim could otherwise pay idle out.
//   - Math.mulDiv IS EXACT, as VaultArithmetic and VaultSplit model it. OZ's implementation of it is taken as correct.
// Loops unroll twice, so a batch verb's result covers batches of at most two.

using DummyERC20 as token;
using BoundaryHub as hub;
using BoundaryTitle as title;

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mdExact(x, y, d, false);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => mdExactRounded(x, y, d, r);

    function tailMatches() external returns (bool) envfree;
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function allowance(address, address) external returns (uint256) envfree;
    function capOf(address) external returns (uint192, bool) envfree;
    function pendingCapOf(address) external returns (uint192, bool, uint64) envfree;
    function effectiveCap(address) external returns (uint256) envfree;
    function seizedOf(address) external returns (uint184, uint64, bool) envfree;
    function openSeizedOf() external returns (uint256) envfree;
    function payoutCount(address) external returns (uint256) envfree;
    function navHigh() external returns (uint256) envfree;
    function drawdown() external returns (uint256) envfree;
    function grossNav() external returns (uint256) envfree;
    function guardEntered() external returns (bool) envfree;
    function requestedShares() external returns (uint256) envfree;
    function SEED_SHARES() external returns (uint256) envfree;
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

    function token.balanceOf(address) external returns (uint256) envfree;
    function hub.lenderAssets(address, address) external returns (uint256) envfree;
    function hub.lenderOwed(address, address) external returns (uint256) envfree;
    function hub.lentAgainst(address, address, address) external returns (uint256) envfree;
    function hub.restingOf(bytes32) external returns (uint256) envfree;
    function hub.borrowerOf(uint256) external returns (address) envfree;
    function hub.debtOf(uint256) external returns (uint256) envfree;
    function hub.collateralOf(uint256) external returns (address) envfree;
    function hub.nextId() external returns (uint256) envfree;
    function hub.opens() external returns (uint256) envfree;
    function hub.openBorrower() external returns (address) envfree;
    function hub.openPrincipal() external returns (uint256) envfree;
    function hub.openTenor() external returns (uint64) envfree;
    function hub.extends() external returns (uint256) envfree;
    function hub.extendedLoan() external returns (uint256) envfree;
    function hub.refinances() external returns (uint256) envfree;
    function hub.refinancedLoan() external returns (uint256) envfree;
    function hub.refinancedPrincipal() external returns (uint256) envfree;
    function hub.refinancedTenor() external returns (uint64) envfree;
    function hub.topUps() external returns (uint256) envfree;
    function hub.toppedUpLoan() external returns (uint256) envfree;
    function hub.toppedUpAmount() external returns (uint256) envfree;
    function hub.rested() external returns (bool) envfree;
    function title.ownerOf(uint256) external returns (address) envfree;
    function title.heldBy(address) external returns (uint256) envfree;
    function title.peakOf(address) external returns (uint256) envfree;

    unresolved external in _._ => DISPATCH [
        token._,
        hub._,
        title._
    ] default NONDET;

    // THE SAME ROUTING, NAMED, for the calls a forwarded library body makes: the prover leaves them out of the catch-all and
    // AUTO-summarizes them, so a hub read answered freely and a product hook havocked every contract but the vault (`emv-44`).
    // The hub's own reads go to the hub, which only it implements; the asset's balance and allowance go to the asset alone;
    // the product's two hooks are NONDET, as the header rules for every product call.
    function _.borrowerOf(uint256) external => DISPATCHER(true);
    function _.loanMarket(uint256) external => DISPATCHER(true);
    function _.idToMarketParams(bytes32) external => DISPATCHER(true);
    function _.extsload(bytes32) external => DISPATCHER(true);
    function _.debtOf(uint256) external => DISPATCHER(true);
    function _.lenderAssets(address, address) external => DISPATCHER(true);
    function _.lenderOwed(address, address) external => DISPATCHER(true);
    function _.lenderByCollateral(address, address, address) external => DISPATCHER(true);
    function _.restingOf(bytes32) external => DISPATCHER(true);
    function _.deposit(bytes32, uint256) external => DISPATCHER(true);
    function _.balanceOf(address a) external => cashBalance(calledContract, a) expect uint256;
    function _.approve(address s, uint256 v) external with (env e) => cashApprove(e, calledContract, s, v) expect bool;
    function _.allowance(address o, address s) external => cashAllowance(calledContract, o, s) expect uint256;
    function _.beforeLend(VaultBoundaryHarness.Lend, VaultBoundaryHarness.MarketParams, uint256, bytes) external => NONDET;
    function _.afterLend(VaultBoundaryHarness.Lend, VaultBoundaryHarness.MarketParams, uint256, address, bytes) external => NONDET;

    function token.allowance(address, address) external returns (uint256) envfree;
}

// The asset's own answer when the callee is the asset; any other callee's is free, as the catch-all's default would leave it.
function cashBalance(address c, address a) returns uint256 {
    if (c == token) {
        return token.balanceOf(a);
    }
    uint256 x;
    return x;
}

function cashAllowance(address c, address o, address s) returns uint256 {
    if (c == token) {
        return token.allowance(o, s);
    }
    uint256 x;
    return x;
}

// The asset's approve as the vault calls it; another callee's approve answers freely and writes nothing, as NONDET would.
function cashApprove(env e, address c, address s, uint256 v) returns bool {
    if (c == token) {
        return token.approve(e, s, v);
    }
    bool b;
    return b;
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

// The vault as every deploy leaves it, in a world the scene's stand-ins describe; see the header.
function scene(env e) {
    require tailMatches();
    require PERF_FEE_BPS() <= 5000;
    require VEST_WINDOW() >= 3600 && VEST_WINDOW() <= 604800;
    require CAP_TIMELOCK() >= 86400 && CAP_TIMELOCK() <= 1209600;
    require MIN_TENOR() >= 86400 && MIN_TENOR() <= MAX_TENOR() && MAX_TENOR() <= 31536000;
    require e.block.timestamp > 0 && e.block.timestamp < 2^63;
    require hub.lenderOwed(currentContract, token) <= hub.lenderAssets(currentContract, token);
    require TERMS() != currentContract && TERMS() != hub && TERMS() != title && TERMS() != token;
    require DOOR() != currentContract && DOOR() != hub && DOOR() != title && DOOR() != token;
    require payoutCount(token) == 0; // a payout is pushed only for a market's collateral, and no vault market's collateral is the asset
}

definition exitVerb(method f) returns bool =
    f.selector == sig:withdraw(uint256, address, address).selector || f.selector == sig:redeem(uint256, address, address).selector
    || f.selector == sig:claimExit(uint256, address, uint256).selector;

// Every exit path and the permissionless crank and claim: no call from any of them reaches the product.
definition exitPath(method f) returns bool =
    exitVerb(f) || f.selector == sig:requestExit(uint256).selector || f.selector == sig:cancelExit(uint256).selector
    || f.selector == sig:lapseExit(address).selector || f.selector == sig:crank().selector
    || f.selector == sig:claim(address[], address).selector;

// The verbs whose only effect on gross and the high-water is cash in or out at par, the fee's shares or the drain.
definition holdsTheDrawdown(method f) returns bool =
    f.selector == sig:deposit(uint256, address).selector || f.selector == sig:mint(uint256, address).selector
    || f.selector == sig:requestExit(uint256).selector || f.selector == sig:cancelExit(uint256).selector
    || f.selector == sig:lapseExit(address).selector || f.selector == sig:collectFee().selector
    || f.selector == sig:setDrain(bool).selector;

// The thirteen verbs the vault forwards into a linked library, whose programs exhaust the heap in this scene; VaultBoundaryLite
// states the rules they reach in its lighter one.
definition forwarded(method f) returns bool =
    f.selector == sig:submitCap(address, uint192).selector || f.selector == sig:submitDelist(address).selector
    || f.selector == sig:acceptCap(address).selector || f.selector == sig:revokePendingCap(address).selector
    || f.selector == sig:collectForfeited(uint256[]).selector || f.selector == sig:claim(address[], address).selector
    || f.selector == sig:returnProceeds(address, uint256, bool).selector || f.selector == sig:submitWriteOff(address).selector
    || f.selector == sig:acceptWriteOff(address).selector || f.selector == sig:revokeWriteOff(address).selector
    || f.selector == sig:extendFor(uint256, uint256, uint256, bytes, bytes).selector
    || f.selector == sig:refinanceFor(uint256, address, uint256, uint64, uint256, uint256, uint64, uint256, address, bytes).selector
    || f.selector == sig:drawMoreFor(uint256, uint256, uint256, uint256, uint64, bytes).selector;

definition ledgerVerb(method f) returns bool =
    f.selector == sig:collectForfeited(uint256[]).selector || f.selector == sig:returnProceeds(address, uint256, bool).selector
    || f.selector == sig:submitWriteOff(address).selector || f.selector == sig:acceptWriteOff(address).selector
    || f.selector == sig:revokeWriteOff(address).selector;

// ---- the lock: the premise every NONDET product answer rests on ----

// Every mutator but the share's `approve` refuses while the lock is held, so no product call can re-enter one.
rule everyMutatorTakesTheLock(method f, env e, calldataarg args) filtered {
    f -> !f.isView && f.selector != sig:approve(address, uint256).selector
} {
    require guardEntered();
    f@withrevert(e, args);
    assert lastReverted, "a mutator ran while the vault's lock was held";
}

// ---- NAV ----

// NAV is the asset balance plus the hub's figure for this vault, less the pile the next sync would leave; nothing else enters it.
rule navIsBalancePlusHubLessPile(env e) {
    scene(e);
    mathint gross = grossNav();
    assert gross == token.balanceOf(currentContract) + hub.lenderAssets(currentContract, token), "gross NAV is not the balance plus the hub's figure";
    mathint pile = pendingPile(e);
    assert to_mathint(totalAssets(e)) == (pile >= gross ? 0 : gross - pile), "NAV is not gross NAV less the vest pile";
}

// witness: a pile can stand between gross and NAV, so the identity above is not passing on a pile that is always zero
rule navCanSitUnderGross(env e) {
    scene(e);
    satisfy totalAssets(e) < grossNav();
}

// ---- shares ----

// A holder's shares fall only when the caller is the holder, or a spender whose allowance covered the fall.
rule onlyOwnerOrSpenderLowersABalance(method f, env e, calldataarg args, address h) filtered { f -> !f.isView } {
    scene(e);
    require h != currentContract;
    uint256 bal0 = balanceOf(h);
    uint256 allow0 = allowance(h, e.msg.sender);

    f(e, args);

    uint256 bal1 = balanceOf(h);
    assert bal1 < bal0 => (e.msg.sender == h || to_mathint(allow0) >= bal0 - bal1), "a stranger lowered a holder's shares";
}

// witness: a spender's move does lower a holder's balance, so the rule above is not passing on a balance nothing lowers
rule aSpenderCanLowerABalance(env e, address h, address to, uint256 value) {
    scene(e);
    require h != currentContract && h != to && e.msg.sender != h;
    uint256 bal0 = balanceOf(h);

    transferFrom(e, h, to, value);

    satisfy balanceOf(h) < bal0;
}

// THE SEED SHARES NEVER LEAVE: the vault holds every standing request's escrow and its genesis seed's shares beside it, and
// no verb takes the vault under that. A claim burns only escrow and a cancel or lapse hands only escrow back, each lowering
// the requests' count by what moved; a gift only adds. INDUCTIVE: the constructor mints the seed's shares to the vault with
// no request standing, which is the base, and this rule is the step. The vault never calls a verb of its own share, and it
// grants no allowance over its own balance, which two premises state. The others are the stated supply consistency (each
// balance read, and each distinct pair of them, within the supply), as an ERC-20 credit to a balance past it would wrap.
// The forwarded verbs' legs are VaultBoundaryLite's; `transferFrom`, whose payer is an argument, is the rule after this one.
rule theSeedSharesNeverLeave(method f, env e, calldataarg args) filtered {
    f -> !f.isView && !forwarded(f) && f.selector != sig:transferFrom(address, address, uint256).selector
} {
    scene(e);
    require e.msg.sender != currentContract;
    require allowance(currentContract, e.msg.sender) == 0;
    require balanceOf(e.msg.sender) + balanceOf(currentContract) <= to_mathint(totalSupply()); //
    require to_mathint(balanceOf(currentContract)) >= requestedShares() + SEED_SHARES();

    f(e, args);

    assert to_mathint(balanceOf(currentContract)) >= requestedShares() + SEED_SHARES(), "a verb took the vault under its escrow and its seed";
}

// The same step for `transferFrom`, its payer named: a spender moving shares to the vault only adds to it.
rule theSeedSharesNeverLeaveOnATransferFrom(env e, address from, address to, uint256 value) {
    scene(e);
    require e.msg.sender != currentContract;
    require allowance(currentContract, e.msg.sender) == 0;
    require from == currentContract || balanceOf(from) + balanceOf(currentContract) <= to_mathint(totalSupply());
    require balanceOf(currentContract) <= totalSupply();
    require to_mathint(balanceOf(currentContract)) >= requestedShares() + SEED_SHARES();

    transferFrom(e, from, to, value);

    assert to_mathint(balanceOf(currentContract)) >= requestedShares() + SEED_SHARES(), "a transferFrom took the vault under its escrow and its seed";
}

// witness: a claim does lower the vault's own balance, so the rule above is not passing on a balance nothing lowers
rule aClaimCanLowerTheVaultsBalance(env e, uint256 shares, address receiver, uint256 minAssets) {
    scene(e);
    require e.msg.sender != currentContract;
    uint256 bal0 = balanceOf(currentContract);

    claimExit(e, shares, receiver, minAssets);

    satisfy balanceOf(currentContract) < bal0;
}

// ---- idle ----

// Idle falls only at an exit (`withdraw`, `redeem`, `claimExit`), or where the hub's figure for the vault rose at least by
// idle's fall: a placement or a lending door moves cash into a live claim, never out of gross NAV. The in-kind `claim` pays
// tokens other than the asset only (`scene`), so it lowers no idle.
rule idleFallsOnlyAtAnExitOrIntoTheHub(method f, env e, calldataarg args) filtered { f -> !f.isView && !exitVerb(f) } {
    scene(e);
    require e.msg.sender != currentContract;
    mathint idle0 = token.balanceOf(currentContract);
    mathint hub0 = hub.lenderAssets(currentContract, token);

    f(e, args);

    mathint idle1 = token.balanceOf(currentContract);
    mathint hub1 = hub.lenderAssets(currentContract, token);
    assert idle1 < idle0 => hub1 - hub0 >= idle0 - idle1, "a verb other than an exit lowered idle without the hub's figure rising to match";
}

// witness: a borrow does lower idle, so the rule above is not passing on a door that never lends
rule aBorrowLowersIdle(env e, VaultBoundaryHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    require e.msg.sender != currentContract;
    uint256 idle0 = token.balanceOf(currentContract);

    borrow(e, r, data, permit2);

    satisfy token.balanceOf(currentContract) < idle0;
}

// An instant withdraw pays exactly the assets it names, from idle.
rule aWithdrawPaysExactlyItsAssets(env e, uint256 assets, address receiver, address owner) {
    scene(e);
    require receiver != currentContract && assets > 0;
    uint256 idle0 = token.balanceOf(currentContract);

    withdraw(e, assets, receiver, owner);

    assert to_mathint(token.balanceOf(currentContract)) == idle0 - assets, "a withdraw paid other than the assets it named";
}

// ---- placements: lendable cash, the row, the total, the rail, the borrower ----

// A landed borrow opens exactly once, for no more than lendable cash before it.
rule aPlacementSitsUnderLendable(env e, VaultBoundaryHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    require e.msg.sender != currentContract;
    uint256 opens0 = hub.opens();
    uint256 lendable0 = lendable(e);

    borrow(e, r, data, permit2);

    assert hub.opens() == opens0 + 1, "a landed borrow did not open exactly once";
    assert hub.openPrincipal() <= lendable0, "a borrow lent more than lendable cash";
}

// A landed borrow fits its collateral's row: the effective cap less what is lent against it and what its goods still hold.
rule aPlacementSitsUnderItsRow(env e, VaultBoundaryHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    require e.msg.sender != currentContract;
    address c = r.collateral;
    uint256 eff = effectiveCap(c);
    uint256 lent = hub.lentAgainst(currentContract, token, c);
    uint184 held;
    uint64 w;
    bool o;
    held, w, o = seizedOf(c);

    borrow(e, r, data, permit2);

    mathint p = hub.openPrincipal();
    assert p == 0 || p + lent + held <= to_mathint(eff), "a borrow passed its collateral's row";
}

// At every placement, what is lent plus the drawdown plus the new principal stays within the vault-wide total.
rule aPlacementFitsTheTotal(env e, VaultBoundaryHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    require e.msg.sender != currentContract;
    mathint lent = hub.lenderAssets(currentContract, token) - hub.lenderOwed(currentContract, token);
    uint256 dd = drawdown();
    uint192 cap;
    bool listed;
    cap, listed = capOf(currentContract);

    borrow(e, r, data, permit2);

    mathint p = hub.openPrincipal();
    assert p == 0 || lent + dd + p <= to_mathint(cap), "a borrow passed the total, counted with the drawdown";
}

// A refinance's net new cash, the principal over the retiring debt, fits the same total.
rule aRefinanceFitsTheTotal(
    env e, uint256 loanId, address collateral, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad,
    uint64 deadline, uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);
    require e.msg.sender != currentContract;
    mathint lent = hub.lenderAssets(currentContract, token) - hub.lenderOwed(currentContract, token);
    uint256 dd = drawdown();
    uint256 debt = hub.debtOf(loanId);
    uint192 cap;
    bool listed;
    cap, listed = capOf(currentContract);

    refinanceFor(e, loanId, collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    mathint p = hub.refinancedPrincipal();
    mathint fresh = p > to_mathint(debt) ? p - debt : 0;
    assert fresh == 0 || lent + dd + fresh <= to_mathint(cap), "a refinance's new cash passed the total, counted with the drawdown";
}

// A top-up's new cash, its amount alone, fits the same total; a zero top-up adds none, as the two rules above exempt.
rule aTopUpFitsTheTotal(env e, uint256 loanId, uint256 amount, uint256 minPayout, uint256 minBufferWad, uint64 deadline, bytes data) {
    scene(e);
    require e.msg.sender != currentContract;
    mathint lent = hub.lenderAssets(currentContract, token) - hub.lenderOwed(currentContract, token);
    uint256 dd = drawdown();
    uint192 cap;
    bool listed;
    cap, listed = capOf(currentContract);

    drawMoreFor(e, loanId, amount, minPayout, minBufferWad, deadline, data);

    mathint fresh = hub.toppedUpAmount();
    assert fresh == 0 || lent + dd + fresh <= to_mathint(cap), "a top-up's new cash passed the total, counted with the drawdown";
}

// A default frees no room under the total: the hub's figure falls, the drawdown rises by the same, and a sync keeps it so.
rule aDefaultFreesNoRoom(env e, uint256 loss) {
    scene(e);
    require navHigh() >= grossNav(); // every sync leaves the high-water at or above gross
    uint256 held0 = hub.lenderAssets(currentContract, token);
    uint256 owed0 = hub.lenderOwed(currentContract, token);
    require loss > 0 && to_mathint(loss) <= held0 - owed0;
    mathint used0 = held0 - owed0 + drawdown();

    hub.writeDown(e, currentContract, token, loss);
    crank(e);

    mathint used1 = hub.lenderAssets(currentContract, token) - hub.lenderOwed(currentContract, token) + drawdown();
    assert used1 == used0, "a default changed what the total counts";
}

// Any open the vault asks the hub for names the vault itself as the borrower.
rule theHubOpensOnlyToTheVault(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    scene(e);
    uint256 opens0 = hub.opens();

    f(e, args);

    assert hub.opens() != opens0 => hub.openBorrower() == currentContract, "the vault opened a loan to someone else";
}

// A landed borrow's term sits inside the vault's write-once rail.
rule aBorrowRunsInsideTheRail(env e, VaultBoundaryHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    uint256 opens0 = hub.opens();

    borrow(e, r, data, permit2);

    assert hub.opens() == opens0 + 1, "a landed borrow did not open exactly once";
    assert hub.openTenor() >= MIN_TENOR() && hub.openTenor() <= MAX_TENOR(), "a borrow opened a term outside the rail";
}

// A landed refinance's successor term sits inside the rail.
rule aRefinanceRunsInsideTheRail(
    env e, uint256 loanId, address collateral, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad,
    uint64 deadline, uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);
    uint256 n0 = hub.refinances();

    refinanceFor(e, loanId, collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    assert hub.refinances() == n0 + 1, "a landed refinance did not refinance exactly once";
    assert hub.refinancedTenor() >= MIN_TENOR() && hub.refinancedTenor() <= MAX_TENOR(), "a refinance ran a term outside the rail";
}

// The vault consents to an extension only in its own market, with the market's tenors and the new expiry inside the rail.
rule theVaultConsentsOnlyInsideTheRail(env e, VaultBoundaryHarness.Extension x, bytes data) {
    scene(e);
    bytes4 yes = admitsExtension(e, x, data);
    assert yes != to_bytes4(0) => x.dst.lender == currentContract && x.dst.minTenor >= MIN_TENOR() && x.dst.maxTenor <= MAX_TENOR()
        && to_mathint(x.newExpiry) <= e.block.timestamp + MAX_TENOR(), "the vault consented to an extension outside its rail";
}

// witness: the vault does consent to some extension, so the rule above is not passing on a policy that always refuses
rule theVaultCanConsent(env e, VaultBoundaryHarness.Extension x, bytes data) {
    scene(e);
    satisfy admitsExtension(e, x, data) != to_bytes4(0);
}

// ---- caps ----

// A key's effective cap rises only at an accept, of a change on that key or on the wildcard that has waited out its timelock.
rule aCapRaiseLandsOnlyAfterTheTimelock(method f, env e, calldataarg args, address key) filtered { f -> !f.isView } {
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
rule aQueuedChangeWaitsTheTimelock(method f, env e, calldataarg args, address key) filtered { f -> !f.isView } {
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

// ---- the drawdown ----

// Entry, the exit requests, the fee and the drain leave the drawdown where it was.
rule theEntryVerbsHoldTheDrawdown(method f, env e, calldataarg args) filtered { f -> holdsTheDrawdown(f) } {
    scene(e);
    require e.msg.sender != currentContract;
    uint256 dd0 = drawdown();

    f(e, args);

    assert drawdown() == dd0, "an entry, a request, the fee or the drain moved the drawdown";
}

// An instant withdraw to anyone but the vault leaves the drawdown; one paid to the vault itself is a donation, as below.
rule aWithdrawHoldsTheDrawdown(env e, uint256 assets, address receiver, address owner) {
    scene(e);
    require e.msg.sender != currentContract && receiver != currentContract;
    uint256 dd0 = drawdown();

    withdraw(e, assets, receiver, owner);

    assert drawdown() == dd0, "a withdraw moved the drawdown";
}

rule aRedeemHoldsTheDrawdown(env e, uint256 shares, address receiver, address owner) {
    scene(e);
    require e.msg.sender != currentContract && receiver != currentContract;
    uint256 dd0 = drawdown();

    redeem(e, shares, receiver, owner);

    assert drawdown() == dd0, "a redeem moved the drawdown";
}

rule aClaimExitHoldsTheDrawdown(env e, uint256 shares, address receiver, uint256 minAssets) {
    scene(e);
    require e.msg.sender != currentContract && receiver != currentContract;
    uint256 dd0 = drawdown();

    claimExit(e, shares, receiver, minAssets);

    assert drawdown() == dd0, "a claim moved the drawdown";
}

// A sale's cash returned by the door lowers the drawdown one for one, to zero and no further.
rule aReturnLowersTheDrawdownOneForOne(env e, address c, uint256 cash, bool closes) {
    scene(e);
    require e.msg.sender == DOOR() && cash > 0;
    uint256 dd0 = drawdown();

    returnProceeds(e, c, cash, closes);

    assert to_mathint(drawdown()) == (dd0 > cash ? dd0 - cash : 0), "a return moved the drawdown by other than its cash";
}

// A donation reopens room one for one: a raw transfer in, then any sync, lowers the drawdown by its amount, to zero and no further.
rule aDonationReopensRoomOneForOne(env e, env d, uint256 amt) {
    scene(e);
    require d.msg.sender != currentContract && amt > 0;
    uint256 dd0 = drawdown();
    require dd0 > 0;

    token.transfer(d, currentContract, amt);
    crank(e);

    assert to_mathint(drawdown()) == (dd0 > amt ? dd0 - amt : 0), "a donation moved the drawdown by other than its amount";
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

// No exit path, nor the crank, nor the in-kind claim, makes a call or a static call to the terms or the door.
// The in-kind claim calls each token it pays, so a product that is itself a market's collateral would be called AS THAT
// TOKEN; that edge, a product holding payouts in the tracker, is excluded here and disclosed with the result.
rule noExitCallsAProduct(method f, env e, calldataarg args) filtered { f -> exitPath(f) } {
    scene(e);
    require termsG == TERMS() && doorG == DOOR();
    require payoutCount(termsG) == 0 && payoutCount(doorG) == 0;
    require !productCalled;

    f(e, args);

    assert !productCalled, "an exit path called the product";
}

// witness: entry does ask the product for its cap, so the hooks above fire on a call the prover leaves unresolved
rule anEntryAsksTheProduct(env e, uint256 assets, address receiver) {
    scene(e);
    require termsG == TERMS() && doorG == DOOR();
    require !productCalled;

    deposit(e, assets, receiver);

    satisfy productCalled;
}

// ---- the lending doors act only for the holder (I9) ----

// A landed extendFor acted for the loan's title holder, the caller, and on that loan alone.
rule anExtendForActsOnlyForTheHolder(env e, uint256 loanId, uint256 maxFee, uint256 minBufferWad, bytes data, bytes permit2) {
    scene(e);
    require e.msg.sender != currentContract;
    address holder = hub.borrowerOf(loanId);
    uint256 n0 = hub.extends();

    extendFor(e, loanId, maxFee, minBufferWad, data, permit2);

    assert holder == e.msg.sender, "an extension landed for a caller the hub does not name as the holder";
    assert hub.extends() == n0 + 1 && hub.extendedLoan() == loanId, "the extension acted on another loan, or on none";
}

// A landed refinanceFor acted for the loan's title holder, the caller, and retired that loan alone.
rule aRefinanceForActsOnlyForTheHolder(
    env e, uint256 loanId, address collateral, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad,
    uint64 deadline, uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);
    require e.msg.sender != currentContract;
    address holder = hub.borrowerOf(loanId);
    uint256 n0 = hub.refinances();

    refinanceFor(e, loanId, collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    assert holder == e.msg.sender, "a refinance landed for a caller the hub does not name as the holder";
    assert hub.refinances() == n0 + 1 && hub.refinancedLoan() == loanId, "the refinance retired another loan, or none";
}

// A landed drawMoreFor acted for the loan's title holder, the caller, and topped up that loan alone, by the amount asked.
rule aDrawMoreForActsOnlyForTheHolder(env e, uint256 loanId, uint256 amount, uint256 minPayout, uint256 minBufferWad, uint64 deadline, bytes data) {
    scene(e);
    require e.msg.sender != currentContract;
    address holder = hub.borrowerOf(loanId);
    uint256 n0 = hub.topUps();

    drawMoreFor(e, loanId, amount, minPayout, minBufferWad, deadline, data);

    assert holder == e.msg.sender, "a top-up landed for a caller the hub does not name as the holder";
    assert hub.topUps() == n0 + 1 && hub.toppedUpLoan() == loanId && hub.toppedUpAmount() == amount, "the top-up drew on another loan or amount, or none";
}

// ---- nothing rests, and every title goes home ----

// From nothing resting at a market, every verb ends with nothing resting there.
rule noVerbLeavesCashResting(method f, env e, calldataarg args, bytes32 id) filtered { f -> !f.isView } {
    scene(e);
    require hub.restingOf(id) == 0;

    f(e, args);

    assert hub.restingOf(id) == 0, "a verb left the vault's cash resting at a market";
}

// witness: a borrow does rest cash at the hub within the call, so the drain above is not passing on cash that never rested
rule aBorrowRestsThenDrains(env e, VaultBoundaryHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    require !hub.rested();

    borrow(e, r, data, permit2);

    satisfy hub.rested();
}

// A landed borrow hands the new loan's title to its caller.
rule aBorrowHandsTheTitleOver(env e, VaultBoundaryHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    require e.msg.sender != currentContract;
    uint256 id = hub.nextId();

    borrow(e, r, data, permit2);

    assert title.ownerOf(id) == e.msg.sender, "a borrow left the loan's title off its caller";
}

// A landed refinance hands both the successor's title and the retired loan's back to its caller.
rule aRefinanceHandsBothTitlesBack(
    env e, uint256 loanId, address collateral, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad,
    uint64 deadline, uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);
    require e.msg.sender != currentContract;
    uint256 newId = hub.nextId();

    refinanceFor(e, loanId, collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    assert title.ownerOf(newId) == e.msg.sender && title.ownerOf(loanId) == e.msg.sender, "a refinance kept a title";
}

// The titles the vault holds are counted by the title collection itself (`heldBy`, and `peakOf` for the most within a
// call), not by a storage hook: any storage hook makes the prover instrument the whole scene, and the vault's storage
// analysis does not complete under via-IR, which turned every rule touching the vault's verbs UNKNOWN.

// No verb leaves a loan title on the vault: from none held, every verb ends holding none.
rule noVerbLeavesATitleOnTheVault(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    scene(e);
    require title.heldBy(currentContract) == 0;

    f(e, args);

    assert title.heldBy(currentContract) == 0, "a verb left a loan title on the vault";
}

// witness: a refinance does hold a title within the call, so the count above is not passing on moves that never happen
rule aRefinanceHoldsATitleMidCall(
    env e, uint256 loanId, address collateral, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad,
    uint64 deadline, uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);
    require e.msg.sender != currentContract;
    require title.heldBy(currentContract) == 0 && title.peakOf(currentContract) == 0;

    refinanceFor(e, loanId, collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    satisfy title.peakOf(currentContract) > 0;
}

// ---- no loan of the vault's pledges the asset (the premise `scene` takes for the in-kind tracker) ----

// A borrow asking to pledge the vault's own asset is refused, in every mode: the base binds the market to the asked
// collateral, and the door's market check refuses the asset as collateral.
rule aBorrowNeverPledgesTheAsset(env e, VaultBoundaryHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    require r.collateral == token;

    borrow@withrevert(e, r, data, permit2);

    assert lastReverted, "a borrow pledged the vault's own asset";
}

// A refinance into a market pledging the vault's own asset is refused, in every mode, for the same two checks.
rule aRefinanceNeverPledgesTheAsset(
    env e, uint256 loanId, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad, uint64 deadline,
    uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);

    refinanceFor@withrevert(e, loanId, token, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    assert lastReverted, "a refinance pledged the vault's own asset";
}

// ---- the seized ledger is conserved ----
//
// THE CLAIM: `openSeized` is the number of keys whose `open` is set, and a key's value moves only at a collect (up), a return
// (down, saturating) or an accepted write-off (to zero). It is an INDUCTION, not a prover invariant, since no rule can count
// every key, and the collect's step is stated over loans against two named keys, its batch being at most two:
//   BASE: the constructor writes neither the ledger nor the count, so both start at zero, a hand step.
//   STEP: the five rules below, one per kind of verb: every other verb moves neither; a collect opens keys and counts each one
//         it opens exactly once; a return and an accepted write-off close only their own key and count it out only if it was
//         open; a write-off's submit and revoke move only its due time.

// No verb but the five ledger verbs moves any key's record or the open count.
rule onlyLedgerVerbsMoveTheLedger(method f, env e, calldataarg args, address c) filtered { f -> !f.isView && !ledgerVerb(f) } {
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

// A door-mode collect of loans against two keys only raises their values, never closes one, counts each key it opens once,
// and leaves every other key alone.
rule aCollectOnlyRaisesAndCountsItsKeys(env e, uint256[] ids, address c, address d, address k) {
    scene(e);
    require !IN_KIND() && e.msg.sender == DOOR();
    require ids.length <= 2 && c != d && k != c && k != d;
    require ids.length > 0 => (hub.collateralOf(ids[0]) == c || hub.collateralOf(ids[0]) == d);
    require ids.length > 1 => (hub.collateralOf(ids[1]) == c || hub.collateralOf(ids[1]) == d);
    uint184 vc0;
    uint64 wc0;
    bool oc0;
    vc0, wc0, oc0 = seizedOf(c);
    uint184 vd0;
    uint64 wd0;
    bool od0;
    vd0, wd0, od0 = seizedOf(d);
    uint184 vk0;
    uint64 wk0;
    bool ok0;
    vk0, wk0, ok0 = seizedOf(k);
    uint256 n0 = openSeizedOf();

    collectForfeited(e, ids);

    uint184 vc1;
    uint64 wc1;
    bool oc1;
    vc1, wc1, oc1 = seizedOf(c);
    uint184 vd1;
    uint64 wd1;
    bool od1;
    vd1, wd1, od1 = seizedOf(d);
    uint184 vk1;
    uint64 wk1;
    bool ok1;
    vk1, wk1, ok1 = seizedOf(k);
    assert vc1 >= vc0 && vd1 >= vd0, "a collect lowered a key's value";
    assert (oc0 => oc1) && (od0 => od1), "a collect closed a key";
    mathint opened = (!oc0 && oc1 ? 1 : 0) + (!od0 && od1 ? 1 : 0);
    assert to_mathint(openSeizedOf()) == n0 + opened, "a collect moved the count by other than the keys it opened";
    assert vk1 == vk0 && wk1 == wk0 && ok1 == ok0, "a collect moved a key none of its loans names";
}

// witness: a door-mode collect does open a key
rule aCollectCanOpenAKey(env e, uint256[] ids) {
    scene(e);
    require !IN_KIND() && e.msg.sender == DOOR();
    uint256 n0 = openSeizedOf();

    collectForfeited(e, ids);

    satisfy openSeizedOf() > n0;
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
