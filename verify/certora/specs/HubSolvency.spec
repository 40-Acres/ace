// Ace hub -- obligation O1: the hub's quote balance is exactly the booked pots, with no other float.
//
// THE BOOKED POTS, per quote token -- the same sum `test/utils/BookedQuote.sol` asserts in the fuzz suite:
//   every market quoting it: `cash + protocolRevenue + quoteOwedTotal`; every loan in those markets: `feeEscrowOf`;
//   every lender: `pools[lender][quote].owed`. (`pools.resting` is NOT added: it is the same money as market `cash`.)
// Kept as one running ghost per quote, `booked[quote]`, by store hooks on those fields. The hooks reach the hub's
// ERC-7201 namespaces through `AceStorageLink` (storage_extension_harnesses). HubHookProbe.spec showed a hook on
// `s.protocolRevenue` firing on every write of every verb it finished; the book and lender hooks were not probed
// separately, and rest instead on the witnesses below, which fail if a pull, payout or push books nothing.
//
// THE TWO CLAIMS:
//   1. THE FLOAT NEVER MOVES (`theFloatNeverMoves`): across any hub verb, the change in the hub's balance of the
//      quote token equals the change in its booked pots. Exact accounting, indifferent to a pre-deploy donation.
//   2. SOLVENT (`theHubIsSolvent`): the balance is at least the booked total -- from (1) and a zero start.
//
// THE QUOTE TOKEN is `quoteToken`, a plain linked ERC-20 (DummyERC20). The proof is about the markets quoting it.
// THE DOMAIN, stated because it is a real restriction: NO MARKET USES `quoteToken` AS COLLATERAL. The hub briefly
// holds collateral (a permit pull, a deleverage refund) and hands it straight to the position manager, whose calls
// are summarized below as moving nothing; with the quote token also somebody's collateral, that hand-off would be
// quote leaving the hub unmodelled. Enforced by hooks on every read and write of a market's collateral.
//
// HOW QUOTE MOVES, modelled exactly: every token call the hub makes on `quoteToken` runs `quoteToken`'s own code,
// and every Permit2 pull of it is a real transfer on it; a call to any other token does nothing (another token
// cannot move `quoteToken` balances). The methods block says where via-IR forced each summary to sit.
// WHAT IS SUMMARIZED AS MOVING NOTHING: the position manager, the title NFT and the deleverage callback. The first
// two never hold or are approved for the hub's quote (the hub's only approvals are of COLLATERAL to the position
// manager). The callback is keeper code that runs INSIDE `deleverage`, and it could SEND the hub quote mid-verb: a
// donation, which raises the real float and which claim 1 EXCLUDES -- the summary is what excludes it. Re-entering
// the hub is refused by its guard. `multicall` is excluded; `pushToken` is vacuous with the hub barred as caller.

using DummyERC20 as quoteToken;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    function FullMath.mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmUp(a, b, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => ozPlain(x, y, d);
    function Math.mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) internal returns (uint256) => ozRounded(x, y, d, r);
    function Mul512.gt512(uint256 a, uint256 b, uint256 c, uint256 d) internal returns (bool) => gt512Ghost(a, b, c, d);

    // how quote moves. via-IR keeps the entries of safeTransfer and trySafeTransfer, so they are summarized there.
    function SafeERC20.safeTransfer(address token, address to, uint256 value) internal => moveFromHub(token, to, value);
    function SafeERC20.trySafeTransfer(address token, address to, uint256 value) internal returns (bool)
        => tryMoveFromHub(token, to, value);
    // It INLINES safeTransferFrom and forceApprove, leaving assembly calls whose callee AND selector are unresolved,
    // and the balance reads after them lose their selectors too. Those dispatch to `quoteToken`'s own code when the
    // callee IS `quoteToken`, and do nothing otherwise: a call to another token cannot move quote balances.
    // NOT the hollow catch-all HubLoans.spec bans: the munged hub has no library call left to swallow, and the
    // ANTI-HOLLOW rules below prove a pull and a payout really move quote through it.
    // The hub's own `this.pushToken` self-call (the sweep, the lender push) is unresolved too, and is dispatched to
    // the hub: left to the default, a push "succeeded" moving nothing, and the float rule failed on every close.
    unresolved external in _._ => DISPATCH [
        quoteToken.transfer(address,uint256),
        quoteToken.transferFrom(address,address,uint256),
        quoteToken.balanceOf(address),
        currentContract.pushToken(address,address,uint256)
    ] default NONDET;
    // Permits.pull is inlined too; its one call is Permit2's, at a fixed address no contract in the scene occupies
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

    function quoteToken.balanceOf(address) external returns (uint256) envfree;
    function treasuryOf() external returns (address) envfree; // AceHarness: the hub keeps TREASURY internal
    function lenderOwed(address, address) external returns (uint256) envfree;
    function idCount() external returns (uint256) envfree; // AceHarness, through Storage.book()
    function feeEscrowOfLoan(uint256) external returns (uint256) envfree; // AceHarness
    function orderMakerOf(uint256) external returns (address) envfree; // AceHarness
}

persistent ghost fmDown(uint256, uint256, uint256) returns uint256;
persistent ghost fmUp(uint256, uint256, uint256) returns uint256;
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

// ---- how quote moves ----

function moveFromHub(address token, address to, uint256 value) {
    if (token == quoteToken) {
        env e;
        require e.msg.sender == currentContract && e.msg.value == 0;
        quoteToken.transfer(e, to, value);
    }
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

// ---- which market quotes what, and which loan lives where (kept in step with storage) ----

persistent ghost mapping(bytes32 => address) quoteOf;
persistent ghost mapping(uint256 => bytes32) loanMarketOf;

hook Sstore currentContract.markets.byId[KEY bytes32 id].p.quote address newV {
    quoteOf[id] = newV;
}
hook Sload address q currentContract.markets.byId[KEY bytes32 id].p.quote {
    require quoteOf[id] == q;
}
hook Sstore currentContract.book.loans[KEY uint256 loanId].market bytes32 newV {
    loanMarketOf[loanId] = newV;
}
hook Sload bytes32 m currentContract.book.loans[KEY uint256 loanId].market {
    require loanMarketOf[loanId] == m;
}

// THE DOMAIN: no market's collateral is the quote token under proof
hook Sstore currentContract.markets.byId[KEY bytes32 id].p.collateral address newV {
    require newV != quoteToken;
}
hook Sload address col currentContract.markets.byId[KEY bytes32 id].p.collateral {
    require col != quoteToken;
}

// THE DEPLOYMENT, two facts no hub code enforces and no deployment breaks:
//   - the treasury is its own contract, never the hub (a self-sweep would zero the pot and keep the quote);
//   - no market's lender is the hub. Such a market is creatable but INERT: only its lender may deposit, the hub
//     never calls its own `deposit`, so it holds no cash, draws nothing and accrues no credit to push to itself.
hook Sstore currentContract.markets.byId[KEY bytes32 id].p.lender address newV {
    require newV != currentContract;
}
hook Sload address l currentContract.markets.byId[KEY bytes32 id].p.lender {
    require l != currentContract;
}

// ---- the booked pots, per quote ----

persistent ghost mapping(address => mathint) booked {
    init_state axiom forall address q. booked[q] == 0;
}

hook Sstore currentContract.markets.byId[KEY bytes32 id].s.cash uint256 newV (uint256 oldV) {
    booked[quoteOf[id]] = booked[quoteOf[id]] + newV - oldV;
}
hook Sstore currentContract.markets.byId[KEY bytes32 id].s.protocolRevenue uint256 newV (uint256 oldV) {
    booked[quoteOf[id]] = booked[quoteOf[id]] + newV - oldV;
}
hook Sstore currentContract.markets.byId[KEY bytes32 id].s.quoteOwedTotal uint256 newV (uint256 oldV) {
    booked[quoteOf[id]] = booked[quoteOf[id]] + newV - oldV;
}
hook Sstore currentContract.book.feeEscrowOf[KEY uint256 loanId] uint256 newV (uint256 oldV) {
    booked[quoteOf[loanMarketOf[loanId]]] = booked[quoteOf[loanMarketOf[loanId]]] + newV - oldV;
}
hook Sstore currentContract.lenders.pools[KEY address lender][KEY address q].owed uint256 newV (uint256 oldV) {
    booked[q] = booked[q] + newV - oldV;
}

// `pushToken` is out: its one door is the hub's own self-call, which every rule here covers inside the verbs that
// make it; called from outside it always reverts, so it was a sanity failure on every rule that bars the hub as caller
definition hubVerb(method f) returns bool =
    !f.isView && f.contract == currentContract && f.selector != sig:multicall(bytes[]).selector
    && f.selector != sig:pushToken(address,address,uint256).selector;

// A FRESH ID CARRIES NO ESCROW: an id above the counter has never been issued, so nothing has written its escrow.
// Without it the prover opens a loan onto an id holding a stale escrow, and the open's write "unbooks" quote.
// (The freshness half O11's monotonic counter leaves open, proven here for the one field O1 books per loan.)
invariant aFreshIdCarriesNoEscrow(uint256 id)
    id > idCount() => feeEscrowOfLoan(id) == 0
    filtered { f -> hubVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// NO ORDER IS THE HUB'S: `postOrder` takes its maker from `msg.sender`, and the hub never posts on its own behalf.
// Without it the prover fills an order the hub "made", the open skips paying a hub payee, and quote is unbooked.
// `pushToken` is excluded as in the rules: its one door is the hub's own self-call, vacuous with the hub barred.
invariant noOrderIsTheHubs(uint256 id)
    orderMakerOf(id) != currentContract
    filtered { f -> hubVerb(f) && f.selector != sig:pushToken(address,address,uint256).selector }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// O1, CLAIM 1: no hub verb creates or destroys unbooked quote.
// A FILL is its own rule below, since the order it fills is an argument the parametric form cannot name.
rule theFloatNeverMoves(env e, method f, calldataarg args)
    filtered { f -> hubVerb(f) && f.selector != sig:fillOrder(uint256,uint256,uint256).selector }
{
    require e.msg.sender != currentContract && treasuryOf() != currentContract;
    // the ids a verb can issue: one per open, and the batch refinance is unrolled twice (loop_iter 2)
    requireInvariant aFreshIdCarriesNoEscrow(require_uint256(idCount() + 1));
    requireInvariant aFreshIdCarriesNoEscrow(require_uint256(idCount() + 2));
    mathint float0 = quoteToken.balanceOf(currentContract) - booked[quoteToken];
    f(e, args);
    assert quoteToken.balanceOf(currentContract) - booked[quoteToken] == float0,
        "a hub verb moved quote it did not book, or booked quote it did not move";
}

// ANTI-VACUITY for the fill rule below: under its exact requirements a fill can complete and pay its maker.
// The prover's own vacuity check timed out on the fill; this witness answers the same question directly.
rule aFillCanPayItsMaker(env e, uint256 orderId, uint256 principalOut, uint256 unitsOut) {
    require e.msg.sender != currentContract && treasuryOf() != currentContract;
    requireInvariant aFreshIdCarriesNoEscrow(require_uint256(idCount() + 1));
    requireInvariant noOrderIsTheHubs(orderId);
    address maker = orderMakerOf(orderId);
    uint256 bal0 = quoteToken.balanceOf(maker);
    fillOrder(e, orderId, principalOut, unitsOut);
    satisfy quoteToken.balanceOf(maker) > bal0;
}

rule theFloatNeverMovesOnAFill(env e, uint256 orderId, uint256 principalOut, uint256 unitsOut) {
    require e.msg.sender != currentContract && treasuryOf() != currentContract;
    requireInvariant aFreshIdCarriesNoEscrow(require_uint256(idCount() + 1));
    requireInvariant noOrderIsTheHubs(orderId);
    mathint float0 = quoteToken.balanceOf(currentContract) - booked[quoteToken];
    fillOrder(e, orderId, principalOut, unitsOut);
    assert quoteToken.balanceOf(currentContract) - booked[quoteToken] == float0,
        "a fill moved quote it did not book, or booked quote it did not move";
}

// ---- ANTI-HOLLOW: quote really moves through the summaries, in by a pull and by a permit, out by a payout ----

rule aDepositPullsTheQuote(env e, bytes32 id, uint256 assets) {
    require quoteOf[id] == quoteToken && e.msg.sender != currentContract && assets > 0;
    uint256 bal0 = quoteToken.balanceOf(currentContract);
    deposit(e, id, assets);
    satisfy quoteToken.balanceOf(currentContract) == bal0 + assets;
}

rule aPermitDepositPullsTheQuote(env e, bytes32 id, uint256 assets, bytes permit2) {
    require quoteOf[id] == quoteToken && e.msg.sender != currentContract && assets > 0;
    uint256 bal0 = quoteToken.balanceOf(currentContract);
    depositWithPermit2(e, id, assets, permit2);
    satisfy quoteToken.balanceOf(currentContract) == bal0 + assets;
}

// the push rides a try/catch, so a dispatch that always reverted would pass the float rule on its catch branch alone
rule aCloseCanPushTheLender(env e, uint256 id, address lender) {
    require lender != currentContract && e.msg.sender != currentContract;
    mathint owed0 = lenderOwed(lender, quoteToken);
    mathint bal0 = quoteToken.balanceOf(lender);
    settleExpired(e, id);
    satisfy lenderOwed(lender, quoteToken) < owed0 && quoteToken.balanceOf(lender) > bal0;
}

rule aWithdrawPaysTheQuote(env e, bytes32 id, uint256 assets, address to, uint256 minPaid) {
    require quoteOf[id] == quoteToken && to != currentContract;
    uint256 bal0 = quoteToken.balanceOf(currentContract);
    uint256 paid = withdraw(e, id, assets, to, minPaid);
    satisfy paid > 0 && quoteToken.balanceOf(currentContract) == bal0 - paid;
}

// O1, CLAIM 2: the hub always holds at least what it has booked
invariant theHubIsSolvent()
    to_mathint(quoteToken.balanceOf(currentContract)) >= booked[quoteToken]
    filtered { f -> hubVerb(f) }
    {
        preserved with (env e) { require e.msg.sender != currentContract && treasuryOf() != currentContract; }
        preserved constructor() { require quoteToken.balanceOf(currentContract) >= 0; }
    }
