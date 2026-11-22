// Ace hub -- EXIT DESTINATIONS: a payout lands where it was sent, and nowhere else.
//
// HubAttribution.spec proves a STRANGER'S verb never redirects a party's credit; its claims exclude the caller by
// construction, so a `collect` paying the treasury, the custodian or its own caller instead of `to` survives them. And
// O20 (HubRevenue.spec) proves revenue leaves only whole, not WHERE it goes. These rules pin both destinations:
//   1. `collect` PAYS EXACTLY `to` (`aCollectPaysExactlyItsRecipient`): the caller's whole credit, and no other balance moves.
//   2. THE SWEEP PAYS EXACTLY THE TREASURY (`aSweepPaysExactlyTheTreasury`): what left the quote's pot, and nothing else moves.
//   3. REVENUE LEAVES ONLY INTO THE TREASURY (`revenueLeavesOnlyToTheTreasury`, every verb): a fall in the quote's pot is
//      matched by at least as much reaching the treasury.
//   4. SETTLEMENT NEVER PAYS THE TREASURY (`aSettlementNeverPaysTheTreasury`): no revenue sweep rides `forceClose`, so
//      with the market's lender not the treasury, the treasury's balance holds.
//
// THE MODEL is HubSolvency.spec's, verbatim in the methods block: the munged hub, `quoteToken` a plain ERC-20 whose own
// code runs for every call the hub makes on it, the hub's own `pushToken` hop dispatched to its real body, and the
// custodian, the title collection and the keeper callback moving nothing. HubSolvency.spec's anti-hollow rules show a
// pull, a payout and a push really move the token through it. Its two domain hooks are not needed: no claim here rests
// on the hub's float. HubLeanGates.spec's read-only gates are summarized as there; no claim here reads one.

using DummyERC20 as quoteToken;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    // NO SUMMARY for mulDivRoundingUp: via-IR inlines it, so one cannot bind and requesting it fails the run. Its body runs on the mulDiv above; see HubLoans.spec.
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => ozPlain(x, y, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => ozRounded(x, y, d, r);
    function Mul512.gt512(uint256 a, uint256 b, uint256 c, uint256 d) internal returns (bool) => gt512Ghost(a, b, c, d);

    // how quote moves: as in HubSolvency.spec, whose methods block says where via-IR forced each summary to sit
    function SafeERC20.safeTransfer(address token, address to, uint256 value) internal => moveFromHub(token, to, value);
    function SafeERC20.trySafeTransfer(address token, address to, uint256 value) internal returns (bool)
        => tryMoveFromHub(token, to, value);
    unresolved external in _._ => DISPATCH [
        quoteToken.transfer(address,uint256),
        quoteToken.transferFrom(address,address,uint256),
        quoteToken.balanceOf(address),
        currentContract.pushToken(address,address,uint256)
    ] default NONDET;
    function _.permitTransferFrom(IPermit2.PermitTransferFrom p, IPermit2.SignatureTransferDetails d, address owner, bytes sig) external
        => permit2Pull(p.permitted.token, owner, d.to, d.requestedAmount) expect void;
    function _.balanceOf(address who) external => balanceOfCalled(calledContract, who) expect uint256;

    // contracts that hold collateral, never the hub's quote
    function _.pull(uint256, address, uint256) external => NONDET;
    function _.release(uint256, address, uint256) external => NONDET;
    function _.retireCustody(uint256, uint256) external => NONDET;
    function _.releaseRetired(uint256, address, uint256) external => NONDET;
    function _.carryOut(uint256, uint256) external => NONDET;
    function _.carryIn(uint256, uint256, uint256) external => NONDET;
    function _.mint(uint256, address) external => NONDET;
    function _.onAceDeleverage(uint256, uint256, bytes) external => NONDET;

    // HubLeanGates.spec's read-only gates
    function Borrower.tryRecordState(AceHarness.Cfg memory) internal returns (bool, AceHarness.RecordState, uint256) => NONDET;
    function Borrower._admissibleLeg(AceHarness.Cfg memory, uint256, uint256, uint256, uint256) internal returns (bytes4) => NONDET;
    function Probe.askBool(address, bytes memory, uint256, bytes32) internal returns (bool) => NONDET;
    function Borrower._preChecks(AceHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._gateCheck(AceHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._payoutCheck(AceHarness.Cfg memory, Borrower.OpenArgs memory, uint256) internal returns (uint256) => NONDET;
    function Borrower._previewFloor(AceHarness.Market storage, AceHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;
    function Borrower._gate(uint256, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.triggerPrice(AceHarness.Loan storage, AceHarness.Cfg memory) internal returns (uint256) => NONDET;
    function Borrower.coverageLine(AceHarness.Cfg memory, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.requiredAt(AceHarness.Cfg memory, uint256, uint256) internal returns (uint256) => NONDET;
    function Borrower.persistedPrice(AceHarness.Cfg memory) internal returns (uint256) => NONDET;
    function LoanAccounting.fundingFloor(AceHarness.Market storage, AceHarness.Cfg memory, uint256) internal returns (uint256) => NONDET;

    function quoteToken.balanceOf(address) external returns (uint256) envfree;
    function treasuryOf() external returns (address) envfree; // AceHarness: the hub keeps TREASURY internal
    function lenderOwed(address, address) external returns (uint256) envfree;
    function protocolRevenueOf(address) external returns (uint256) envfree; // AceHarness: one quote's pot
    function loanMarket(uint256) external returns (bytes32) envfree;
    function marketLenderOf(bytes32) external returns (address) envfree; // AceHarness
}

persistent ghost fmDown(uint256, uint256, uint256) returns uint256;
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

// ---- how quote moves, as in HubSolvency.spec ----

function moveFromHub(address token, address to, uint256 value) {
    if (token == quoteToken) {
        env e;
        require e.msg.sender == currentContract && e.msg.value == 0;
        quoteToken.transfer(e, to, value);
    }
}

function tryMoveFromHub(address token, address to, uint256 value) returns bool {
    if (token == quoteToken) {
        env e;
        require e.msg.sender == currentContract && e.msg.value == 0;
        quoteToken.transfer@withrevert(e, to, value);
        return !lastReverted;
    }
    bool ok;
    return ok;
}

function permit2Pull(address token, address owner, address to, uint256 value) {
    if (token == quoteToken) {
        env e;
        require e.msg.sender == owner && e.msg.value == 0;
        quoteToken.transfer(e, to, value);
    }
}

function balanceOfCalled(address token, address who) returns uint256 {
    if (token == quoteToken) { return quoteToken.balanceOf(who); }
    uint256 any;
    return any;
}

// `pushToken` is out, as in HubSolvency.spec: its one door is the hub's own self-call, covered inside the verbs
definition hubVerb(method f) returns bool =
    !f.isView && f.contract == currentContract && f.selector != sig:multicall(bytes[]).selector
    && f.selector != sig:pushToken(address,address,uint256).selector;

// ---- 1. `collect` PAYS EXACTLY `to` ----

rule aCollectPaysExactlyItsRecipient(env e, address to, address other) {
    require e.msg.sender != currentContract;
    require other != to && other != currentContract;
    mathint owed0 = lenderOwed(e.msg.sender, quoteToken);
    mathint to0 = quoteToken.balanceOf(to);
    mathint other0 = quoteToken.balanceOf(other);
    uint256 paid = collect(e, quoteToken, to);
    assert to_mathint(paid) == owed0, "a collect paid other than the caller's whole credit";
    assert quoteToken.balanceOf(to) == to0 + paid, "a collect's recipient did not receive what it paid";
    assert quoteToken.balanceOf(other) == other0, "a collect moved a balance other than its recipient's and the hub's";
}

// witness: a collect really pays, so the destination asserts are not passing on zero
rule aCollectCanPay(env e, address to) {
    require e.msg.sender != currentContract;
    uint256 paid = collect(e, quoteToken, to);
    satisfy paid > 0;
}

// ---- 2. THE SWEEP PAYS EXACTLY THE TREASURY ----

// the quote under proof is `quoteToken`, the one token the model moves for real
rule aSweepPaysExactlyTheTreasury(env e, address other) {
    address t = treasuryOf();
    require e.msg.sender != currentContract && t != currentContract;
    require other != t && other != currentContract;
    mathint rev0 = protocolRevenueOf(quoteToken);
    mathint t0 = quoteToken.balanceOf(t);
    mathint other0 = quoteToken.balanceOf(other);
    sweepRevenue(e, quoteToken);
    assert quoteToken.balanceOf(t) == t0 + (rev0 - protocolRevenueOf(quoteToken)), "a sweep's treasury did not receive what left the pot";
    assert quoteToken.balanceOf(other) == other0, "a sweep moved a balance other than the treasury's and the hub's";
}

// witness: a sweep really pays the treasury, so the destination asserts are not passing on zero
rule aSweepCanPayTheTreasury(env e) {
    address t = treasuryOf();
    require e.msg.sender != currentContract && t != currentContract;
    mathint t0 = quoteToken.balanceOf(t);
    sweepRevenue(e, quoteToken);
    satisfy quoteToken.balanceOf(t) > t0;
}

// ---- 3. REVENUE LEAVES ONLY INTO THE TREASURY, on every verb ----

// The treasury is not the caller: a verb pulls quote only from its caller (HubAttribution.spec claim 3), so with it
// barred the treasury's balance never falls and a rise of at least the pot's fall is the sweep's whole delivery.
rule revenueLeavesOnlyToTheTreasury(env e, method f, calldataarg args) filtered { f -> hubVerb(f) } {
    address t = treasuryOf();
    require e.msg.sender != currentContract && t != currentContract && t != e.msg.sender;
    mathint rev0 = protocolRevenueOf(quoteToken);
    mathint t0 = quoteToken.balanceOf(t);
    f(e, args);
    mathint fell = rev0 - protocolRevenueOf(quoteToken);
    assert fell > 0 => quoteToken.balanceOf(t) - t0 >= fell, "protocol revenue left its pot for somewhere other than the treasury";
}

// ---- 4. SETTLEMENT NEVER PAYS THE TREASURY ----

// `forceClose`'s one quote leg is the push to the market's lender, so with that lender not the treasury, and the treasury
// neither the caller nor the hub, the treasury's balance holds: the protocol's cut waits in its pot for `sweepRevenue`
rule aSettlementNeverPaysTheTreasury(env e, uint256 id) {
    address t = treasuryOf();
    require e.msg.sender != currentContract && t != currentContract && t != e.msg.sender;
    require marketLenderOf(loanMarket(id)) != t;
    mathint t0 = quoteToken.balanceOf(t);
    forceClose(e, id);
    assert quoteToken.balanceOf(t) == t0, "a settlement paid the treasury";
}
