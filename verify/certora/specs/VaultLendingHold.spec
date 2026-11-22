// AceVault's LENDING VERBS leave the requests' hold home: a borrow, a refinance or a top-up draws only cash the standing exit
// requests do not hold. VaultBoundary's `aPlacementSitsUnderLendable` states the borrow's draw against `lendable`; these state
// the verbs by their EFFECT on idle, which is what an LP waiting on a request relies on: after the call, idle still covers
// what the requests held before it. A refinance's and a top-up's own check read lendable cash after the verb's sweep, which a
// collect of what the hub owes the vault only raises, so the pre-call hold is the binding bound.
//
// THE SCENE, VaultBoundary's (see that spec's header): the MUNGED vault, DummyERC20, BoundaryHub moving the asset as the hub
// does (a deposit pulls into resting, an open or a refinance pays the vault from resting, a top-up pays the loan's holder
// from resting, a withdraw or a collect pays the lender), BoundaryTitle, and the three linked libraries; the terms and the
// door NONDET. The harness is VaultLivenessHarness,
// VaultBoundaryHarness plus the hold's view. Its premises are VaultBoundary's `scene`, unchanged.

using DummyERC20 as token;
using BoundaryHub as hub;
using BoundaryTitle as title;

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mdExact(x, y, d, false);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => mdExactRounded(x, y, d, r);

    function tailMatches() external returns (bool) envfree;
    function payoutCount(address) external returns (uint256) envfree;
    function requestedShares() external returns (uint256) envfree;
    function vestMaturity() external returns (uint64) envfree;
    function navMark() external returns (uint256) envfree;
    function grossNav() external returns (uint256) envfree;
    function TERMS() external returns (address) envfree;
    function DOOR() external returns (address) envfree;
    function PERF_FEE_BPS() external returns (uint16) envfree;
    function VEST_WINDOW() external returns (uint64) envfree;
    function CAP_TIMELOCK() external returns (uint64) envfree;
    function MIN_TENOR() external returns (uint64) envfree;
    function MAX_TENOR() external returns (uint64) envfree;

    function token.balanceOf(address) external returns (uint256) envfree;
    function hub.lenderAssets(address, address) external returns (uint256) envfree;
    function hub.lenderOwed(address, address) external returns (uint256) envfree;
    function hub.refinances() external returns (uint256) envfree;

    unresolved external in _._ => DISPATCH [
        token._,
        hub._,
        title._
    ] default NONDET;

    // VaultBoundary's named routing for a forwarded library body's calls, which the prover leaves out of the catch-all (see there).
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
    function _.createMarket(VaultLivenessHarness.MarketParams) external => DISPATCHER(true);
    function _.transferFrom(address f, address t, uint256 v) external with (env e) => moveFrom(e, calledContract, f, t, v) expect bool;
    function _.balanceOf(address a) external => cashBalance(calledContract, a) expect uint256;
    function _.approve(address s, uint256 v) external with (env e) => cashApprove(e, calledContract, s, v) expect bool;
    function _.allowance(address o, address s) external => cashAllowance(calledContract, o, s) expect uint256;
    function _.beforeLend(VaultLivenessHarness.Lend, VaultLivenessHarness.MarketParams, uint256, bytes) external => NONDET;
    function _.afterLend(VaultLivenessHarness.Lend, VaultLivenessHarness.MarketParams, uint256, address, bytes) external => NONDET;

    function token.allowance(address, address) external returns (uint256) envfree;
}

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

function cashApprove(env e, address c, address s, uint256 v) returns bool {
    if (c == token) {
        return token.approve(e, s, v);
    }
    bool b;
    return b;
}

// VaultBoundary's `moveFrom`: the asset's or the title's own move, as the callee is.
function moveFrom(env e, address c, address f, address t, uint256 v) returns bool {
    if (c == token) {
        return token.transferFrom(e, f, t, v);
    }
    if (c == title) {
        title.transferFrom(e, f, t, v);
        return true;
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

// VaultBoundary's `scene`, unchanged.
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
    require payoutCount(token) == 0;
}

// A landed refinance leaves idle covering what the standing requests held before it: its net new cash is lendable cash.
rule aRefinanceSitsUnderLendable(
    env e, uint256 loanId, address collateral, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad,
    uint64 deadline, uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);
    require e.msg.sender != currentContract;
    mathint held0 = heldCash(e);

    refinanceFor(e, loanId, collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    assert to_mathint(token.balanceOf(currentContract)) >= held0, "a refinance drew cash the standing exit requests held";
}

// A landed borrow leaves idle covering what the standing requests held before it.
rule aBorrowTakesNoHeldCash(env e, VaultLivenessHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    require e.msg.sender != currentContract;
    mathint held0 = heldCash(e);

    borrow(e, r, data, permit2);

    assert to_mathint(token.balanceOf(currentContract)) >= held0, "a borrow drew cash the standing exit requests held";
}

// A landed top-up leaves idle covering what the standing requests held before it: its amount is lendable cash.
rule aTopUpSitsUnderLendable(env e, uint256 loanId, uint256 amount, uint256 minPayout, uint256 minBufferWad, uint64 deadline, bytes data) {
    scene(e);
    require e.msg.sender != currentContract;
    mathint held0 = heldCash(e);

    drawMoreFor(e, loanId, amount, minPayout, minBufferWad, deadline, data);

    assert to_mathint(token.balanceOf(currentContract)) >= held0, "a top-up drew cash the standing exit requests held";
}

// THE SAME BOUNDS AT A SETTLED VAULT, the hold's core alone: no fee, the pile matured and the mark at gross, so no door's
// sync stamps or burns and its sweep mints no fee, and what is left is the hold against the door's own lendable cash.
// A narrower start than the three rules above, kept so a TIMEOUT there in the vest and fee arithmetic still settles the check.
function settled(env e) {
    require PERF_FEE_BPS() == 0;
    require vestMaturity() <= e.block.timestamp && to_mathint(navMark()) == grossNav();
}

rule aRefinanceSitsUnderLendableWhenSettled(
    env e, uint256 loanId, address collateral, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad,
    uint64 deadline, uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);
    settled(e);
    require e.msg.sender != currentContract;
    mathint held0 = heldCash(e);

    refinanceFor(e, loanId, collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    assert to_mathint(token.balanceOf(currentContract)) >= held0, "a refinance drew cash the standing exit requests held";
}

rule aBorrowTakesNoHeldCashWhenSettled(env e, VaultLivenessHarness.BorrowRequest r, bytes data, bytes permit2) {
    scene(e);
    settled(e);
    require e.msg.sender != currentContract;
    mathint held0 = heldCash(e);

    borrow(e, r, data, permit2);

    assert to_mathint(token.balanceOf(currentContract)) >= held0, "a borrow drew cash the standing exit requests held";
}

rule aTopUpSitsUnderLendableWhenSettled(env e, uint256 loanId, uint256 amount, uint256 minPayout, uint256 minBufferWad, uint64 deadline, bytes data) {
    scene(e);
    settled(e);
    require e.msg.sender != currentContract;
    mathint held0 = heldCash(e);

    drawMoreFor(e, loanId, amount, minPayout, minBufferWad, deadline, data);

    assert to_mathint(token.balanceOf(currentContract)) >= held0, "a top-up drew cash the standing exit requests held";
}

// witness: a refinance does draw fresh cash out of idle while requests stand, so the bound above is not passing on doors that never lend
rule aRefinanceCanDrawBesideAHold(
    env e, uint256 loanId, address collateral, uint256 principal, uint64 tenor, uint256 minPayout, uint256 minBufferWad,
    uint64 deadline, uint256 withdrawUnits, address withdrawTo, bytes data
) {
    scene(e);
    require e.msg.sender != currentContract && requestedShares() > 0;
    mathint idle0 = token.balanceOf(currentContract);

    refinanceFor(e, loanId, collateral, principal, tenor, minPayout, minBufferWad, deadline, withdrawUnits, withdrawTo, data);

    satisfy to_mathint(token.balanceOf(currentContract)) < idle0;
}
