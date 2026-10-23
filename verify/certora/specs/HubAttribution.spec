// Ace hub -- WHO GETS PAID: a party's settled entitlements move on their own word, or straight into their wallet.
//
// THE ENTITLEMENTS are what the hub has SETTLED as owed to a party: a lender's credit pool (`lenderOwed`) and a
// claimant's per-loan claims (`owedOf`, units and quote). Resting cash is NOT one: a draw lends it out, which is what
// it rests for, and a loss on a lent loan is the lender's risk. These three only ever fall by being paid out.
//
// THE CLAIMS, for any hub verb and any party `p` other than its caller and the hub:
//   1. A CLAIM IS ITS CLAIMANT'S: no verb a stranger calls lowers p's units or quote owed on any loan.
//   2. CREDIT LEAVES ONLY INTO ITS OWNER'S WALLET: when a stranger's verb lowers p's credit pool in `quoteToken`, p's
//      `quoteToken` balance rises by at least as much (the terminal close's push), so nothing redirects it.
//   3. THE HUB PULLS ONLY FROM ITS CALLER: p's `quoteToken` balance never falls, whatever allowance p has granted.
//
// THE MODEL is HubSolvency.spec's, verbatim in the methods block: the munged hub, `quoteToken` a plain ERC-20 whose
// own code runs for every call the hub makes on it, the custodian and the title NFT moving nothing, and the domain
// that no market's collateral is `quoteToken`. Claim 1 reads hub storage alone and does not lean on the token model.

using DummyERC20 as quoteToken;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmDown(a, b, d);
    function FullMath.mulDivRoundingUp(uint256 a, uint256 b, uint256 d) internal returns (uint256) => fmUp(a, b, d);
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

    function owedOf(uint256, address) external returns (uint256, uint256) envfree;
    function lenderOwed(address, address) external returns (uint256) envfree;
    function loanMarket(uint256) external returns (bytes32) envfree;
    function idCount() external returns (uint256) envfree; // AceHarness, through Storage.book()
    function quoteOwedTotalOf(bytes32) external returns (uint256) envfree; // AceHarness, through Storage.markets()
    function marketQuoteOf(bytes32) external returns (address) envfree; // AceHarness
    function quoteClaimOf(uint256, address) external returns (uint256) envfree; // AceHarness
    function notEntered() external returns (bool) envfree;
    function POSITION_MANAGER() external returns (address) envfree;
    function quoteToken.balanceOf(address) external returns (uint256) envfree;
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

// THE DOMAIN, as in HubSolvency.spec: no market's collateral is the quote token under proof
hook Sstore currentContract.markets.byId[KEY bytes32 id].p.collateral address newV {
    require newV != quoteToken;
}
hook Sload address col currentContract.markets.byId[KEY bytes32 id].p.collateral {
    require col != quoteToken;
}

// `pushToken` is out, as in HubSolvency.spec: its one door is the hub's own self-call, covered inside the verbs
definition hubVerb(method f) returns bool =
    !f.isView && f.contract == currentContract && f.selector != sig:multicall(bytes[]).selector
    && f.selector != sig:pushToken(address,address,uint256).selector;

// 1. A CLAIM IS ITS CLAIMANT'S
rule aClaimIsItsClaimants(env e, method f, calldataarg args, uint256 loanId, address p) filtered { f -> hubVerb(f) } {
    require p != e.msg.sender && p != currentContract;
    uint256 units0; uint256 quote0;
    units0, quote0 = owedOf(loanId, p);
    f(e, args);
    uint256 units1; uint256 quote1;
    units1, quote1 = owedOf(loanId, p);
    assert units1 >= units0, "a stranger's verb lowered a claimant's collateral claim";
    assert quote1 >= quote0, "a stranger's verb lowered a claimant's quote claim";
}

// 2. CREDIT LEAVES ONLY INTO ITS OWNER'S WALLET
rule creditLeavesOnlyIntoItsOwnersWallet(env e, method f, calldataarg args, address p) filtered { f -> hubVerb(f) } {
    require p != e.msg.sender && p != currentContract;
    mathint owed0 = lenderOwed(p, quoteToken);
    mathint bal0 = quoteToken.balanceOf(p);
    f(e, args);
    mathint fell = owed0 - lenderOwed(p, quoteToken);
    assert fell <= 0 || quoteToken.balanceOf(p) - bal0 >= fell, "a lender's credit fell by more than reached their wallet";
}

// 3. THE HUB PULLS ONLY FROM ITS CALLER
rule theHubPullsOnlyFromItsCaller(env e, method f, calldataarg args, address p) filtered { f -> hubVerb(f) } {
    require p != e.msg.sender && p != currentContract;
    uint256 bal0 = quoteToken.balanceOf(p);
    f(e, args);
    assert quoteToken.balanceOf(p) >= bal0, "a verb took quote from someone other than its caller";
}

// ---- THE CLAIMS POT IS ITS CLAIMS: a market's `quoteOwedTotal` is exactly the quote its claimants may pull ----
// The pot is one of O1's booked pots; this says WHOSE it is. A total under its claims strands the last claimant,
// a total over them is quote booked to nobody. Claims are summed per market through the loan they sit on.

persistent ghost mapping(uint256 => bytes32) loanMarketOf;
hook Sstore currentContract.book.loans[KEY uint256 loanId].market bytes32 newV {
    loanMarketOf[loanId] = newV;
}
hook Sload bytes32 m currentContract.book.loans[KEY uint256 loanId].market {
    require loanMarketOf[loanId] == m;
}

persistent ghost mapping(bytes32 => mathint) claimsIn {
    init_state axiom forall bytes32 m. claimsIn[m] == 0;
}
hook Sstore currentContract.book.quoteOwed[KEY uint256 loanId][KEY address who] uint256 newV (uint256 oldV) {
    claimsIn[loanMarketOf[loanId]] = claimsIn[loanMarketOf[loanId]] + newV - oldV;
}
// one entry never exceeds the sum it is part of: sound while the sum is exact and a loan never changes market
hook Sload uint256 v currentContract.book.quoteOwed[KEY uint256 loanId][KEY address who] {
    require claimsIn[loanMarketOf[loanId]] >= to_mathint(v);
}

// an id above the counter was never issued, so no loan sits on it: without this the prover opens a loan onto an id
// already carrying a stale market, and "the open moved a loan" (the freshness O11's monotonic counter leaves open)
invariant aFreshIdHoldsNoLoan(uint256 id)
    id > idCount() => loanMarket(id) == to_bytes32(0)
    filtered { f -> hubVerb(f) && f.selector != sig:pushToken(address,address,uint256).selector }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// what the Sload bound above leans on: a loan, once in a market, stays in it
rule aLoanNeverChangesMarket(env e, method f, calldataarg args, uint256 id) filtered { f -> hubVerb(f) } {
    requireInvariant aFreshIdHoldsNoLoan(id); // so a loan with a market is an issued id, which no open re-issues
    bytes32 m0 = loanMarket(id);
    require m0 != to_bytes32(0);
    f(e, args);
    assert loanMarket(id) == m0, "a loan moved to another market";
}

invariant theClaimsPotIsItsClaims(bytes32 m)
    claimsIn[m] == to_mathint(quoteOwedTotalOf(m))
    filtered { f -> hubVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// a claim is only ever credited on a loan whose market was created: every credit site builds that market's cache
// first, which refuses a market that does not exist, and a market's quote is write-once
// `pushToken` is excluded: its one door is the hub's own self-call, so with the hub barred as caller it is vacuous
invariant aClaimSitsInARealMarket(uint256 id, address p)
    quoteClaimOf(id, p) > 0 => marketQuoteOf(loanMarket(id)) != 0
    filtered { f -> hubVerb(f) && f.selector != sig:pushToken(address,address,uint256).selector }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// ---- LIVENESS: a settled entitlement can always be taken ----
// Premises: the hub's own solvency (HubSolvency.spec: its balance covers every booked pot, and these are booked pots),
// a token that refuses nothing but its own arithmetic (DummyERC20), and the recipient rule, which is the caller's.

rule aLenderCanAlwaysCollect(env e, address to) {
    uint256 owed = lenderOwed(e.msg.sender, quoteToken);
    require e.msg.value == 0 && notEntered();
    require to != 0 && to != currentContract && to != POSITION_MANAGER();
    require quoteToken.balanceOf(currentContract) >= owed;
    require quoteToken.balanceOf(to) + owed <= max_uint256;
    collect@withrevert(e, quoteToken, to);
    assert !lastReverted, "a lender's settled credit could not be collected";
    assert lenderOwed(e.msg.sender, quoteToken) == 0, "a collect left credit behind";
}

rule aClaimantCanAlwaysClaimTheirQuote(env e, uint256 id, address to, address noUnits) {
    require noUnits == 0; // the units leg is skipped, so this is the quote leg alone
    bytes32 m = loanMarket(id);
    requireInvariant theClaimsPotIsItsClaims(m);
    requireInvariant aClaimSitsInARealMarket(id, e.msg.sender);
    uint256 units0; uint256 amount;
    units0, amount = owedOf(id, e.msg.sender);
    require amount > 0; // liveness of an entitlement that exists; an empty claim on an unopened loan may revert
    require e.msg.value == 0 && notEntered();
    require to != 0 && to != currentContract && to != POSITION_MANAGER();
    require quoteToken.balanceOf(currentContract) >= amount;
    require quoteToken.balanceOf(to) + amount <= max_uint256;
    claimOwed@withrevert(e, id, noUnits, to);
    assert !lastReverted, "a claimant's quote claim could not be pulled";
}

// ANTI-HOLLOW: a stranger's terminal close really pays a lender, so claim 2 is not true merely by nothing moving
rule aStrangersCloseCanPayTheLender(env e, uint256 id, address p) {
    require p != e.msg.sender && p != currentContract;
    mathint owed0 = lenderOwed(p, quoteToken);
    mathint bal0 = quoteToken.balanceOf(p);
    settleExpired(e, id);
    satisfy lenderOwed(p, quoteToken) < owed0 && quoteToken.balanceOf(p) > bal0;
}
