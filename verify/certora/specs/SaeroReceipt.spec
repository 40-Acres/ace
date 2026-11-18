// `SAeroStakeReceipt`, the A-* properties of the internal record, in five groups:
//   R1  the payout order (A-F3, A-G2): settle, sweep and claimCash pay the vault's open claim D first, then the lenders' fee,
//       then the owner, and the owner is paid only out of cash beyond both;
//   R2  the lenders' fee (A-F1, A-F6): booked only at the seizure, at exactly floor(D * LENDER_FEE_BPS / 10000), the
//       receipt's own constant, and never paid out of cash D needs;
//   R3  cash conservation (A-G1): a payout's cash out is the vault leg plus the owner leg, and no other balance moves;
//   R4  units (A-R3, A-R4, A-R5, A-M1): every unit leaving the custodian burns, `outstanding` falls only then, and a clean
//       close is Holding with every unit burned and none to the door;
//   R5  the reward repay (A-C1, A-L4): only the portfolio, its owner or a nonzero operator; never under max(floor, bound);
//       a close only by the portfolio or its owner, with covering cash and cap and no bound.
// Each group carries a `satisfy` witness that its path is reachable, beside `rule_sanity: basic`.
//
// PROVEN, the pre-deploy pass, on the code as it now is (the fee the receipt's constant, `mint` reading no
// door, `rewardRepay`, `previewSplit` and `clearRow` gone): 34 of the 37 rules SUCCESS, every witness found, and a
// `LENDER_FEE_BPS = 400` mutant caught. The other 3 are the invariants' constructor base case, ARGUED below, not proven.
//
// THE RECEIPT IS MUNGED, ONE LINE, AND THE REASON IS MEASURED, NOT ASSUMED. A receipt is a clone whose three args are
// bytes after its own code, read by an EXTCODECOPY of itself; the prover havocs every EXTCODECOPY site afresh, so on the
// unmunged receipt `PORTFOLIO() == PORTFOLIO()` and `UNITS() == totalSupply()` both FAIL. The copy makes `_args()` virtual
// and `SAeroStakeReceiptHarness` answers three storage words no function writes: a fixed, arbitrary (P, S, U) for the
// whole rule, which is every args triple a factory writes. `scripts/certora-munge-receipt.sh` carries the argument.
//
// WHAT IS MODELLED, AND WHY EACH ADMITS EVERY REAL BEHAVIOUR THE RULES NEED.
// THE ASSET is `DummyERC20`, LINKED: exact transfers, no hooks, as USDC is, so balances are real and nothing re-enters.
// THE HUB is `MockReceiptHub`, LINKED: every read is free storage, and `repay` lowers the debt it names by the amount and
// pulls that amount, enforcing no floor of its own, so R5's bound is the receipt's alone. Its one stated fact is the
// hub's market rail: `MarketInit` refuses a market whose `minPrincipal` is under 2, and params are write-once, so a market
// pledging this receipt has a positive debt floor (`hubRails`). Without it an operator's partial at a zero floor would
// close the loan; the rail is what makes `debt - floor` short of the debt.
// THE DOOR is `MockReceiptDoor`, LINKED: its operator and seizure map are free storage, and `returnClaimed`
// either refuses or pulls a free amount from the receipt, so it meets a full take, a short take, no take and a refusal;
// a pull past the receipt's approval reverts in the token. The real door's own checks only narrow that.
// THE 40 ACRES READS -- the portfolio's owner, the escrow's holder, custody's map, the marketplace's row -- are LINKED
// mocks of free storage. The receipt tolerates a revert, a short or a dirty answer from the escrow, custody and the
// marketplace, and every outcome such an answer produces (no holder known, mapped here, no standing row) is one some
// free answer produces too. It does NOT tolerate one from the owner read: `_ownerOf` is a typed call, so a revert there
// reverts `seize`, a Holding `claimCash` and an owner-path repay. The mock never reverts, so no rule here covers that case.
// THE WIRING, `wired()`, keeps the receipt's own seats distinct and nonzero (the portfolio, the vault, the custodian,
// the door): a deployed receipt's are four different contracts. It is a premise of the units rules only.
//
// WHAT IS NOT CLAIMED: the hub's and the door's own logic (proved in their lanes or modelled), 40 Acres' lock, and any
// state-machine fact beyond the five groups.
using DummyERC20 as cash;
using MockReceiptHub as hub;
using MockReceiptDoor as door;
using MockPortfolioOwners as owners;

methods {
    function PORTFOLIO() external returns (address) envfree;
    function UNITS() external returns (uint256) envfree;
    function outstanding() external returns (uint256) envfree;
    function state() external returns (SAeroStakeReceipt.State) envfree;
    function owner() external returns (address) envfree;
    function burned() external returns (uint256) envfree;
    function doorBurned() external returns (uint256) envfree;
    function seniorDebt() external returns (uint256) envfree;
    function lenderFee() external returns (uint256) envfree;
    function LENDER_FEE_BPS() external returns (uint256) envfree;
    function VAULT() external returns (address) envfree;
    function DOOR() external returns (address) envfree;
    function POSITION_MANAGER() external returns (address) envfree;
    function balanceOf(address) external returns (uint256) envfree;

    function DummyERC20.balanceOf(address) external returns (uint256) envfree;
    function DummyERC20.allowance(address, address) external returns (uint256) envfree;
    function MockReceiptHub.debtView(uint256) external returns (uint256) envfree;
    function MockReceiptHub.collateralOfLoan(uint256) external returns (address) envfree;
    function MockReceiptHub.minPrincipalOfLoan(uint256) external returns (uint256) envfree;
    function MockReceiptDoor.operatorView() external returns (address) envfree;
    function MockPortfolioOwners.ownerView(address) external returns (address) envfree;

    // OZ's 512-bit `mulDiv`, the seizure's one product, is its documented exact floor: its own body TIMES OUT `aSeizureBooksTheFixedFee`.
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivFloor(x, y, d);

    // THE LINKS DO NOT BIND IN THE VERBS THAT MOVE CASH, AND THIS IS WHAT STANDS IN. Measured on the first run: in
    // `repayFromRewards`, `settle`, `sweep`, `claimCash` and `draw` the prover's pointer analysis gives up, so every call
    // there -- the hub's typed reads, the 40 Acres reads, and SafeERC20's assembly calls -- arrived as an AUTO havoc that
    // rewrote the token's balances and every ghost. Each unresolved call is therefore DISPATCHED by callee AND selector:
    // it runs the mock at its target address when there is one, so every call reaches exactly the code its link names,
    // and a call to any other address is NONDET, which moves nothing. Every target the receipt calls is a linked
    // immutable, so the default meets none of them.
    unresolved external in _._ => DISPATCH [
        DummyERC20.transfer(address, uint256),
        DummyERC20.transferFrom(address, address, uint256),
        DummyERC20.approve(address, uint256),
        DummyERC20.balanceOf(address),
        MockReceiptHub.isLiveLoan(uint256),
        MockReceiptHub.debtOf(uint256),
        MockReceiptHub.loanMarket(uint256),
        MockReceiptHub.idToMarketParams(bytes32),
        MockReceiptHub.owedOf(uint256, address),
        MockReceiptHub.tryExtend(uint256, uint256, bytes, address),
        MockReceiptHub.repay(uint256, uint256),
        MockReceiptDoor.operator(),
        MockReceiptDoor.seizedReceiptOf(uint256),
        MockReceiptDoor.returnClaimed(uint256),
        MockPortfolioOwners.ownerOf(address),
        MockSeizedCustody.receiptOf(uint256),
        MockListings.getListing(uint256),
        MockStakeEscrow.ownerOf(uint256),
        MockStakeEscrow.staked(uint256)
    ] default NONDET;
}

// `Math.mulDiv`'s contract: floor(x * y / d), refusing a zero divisor or a quotient past a uint256. The `require`s stand
// for those two refusals, and they prune nothing a rule here needs: the receipt's one call divides by the constant 10000,
// and no rule calls `seize` with revert, so a refused product is a reverted seizure, which every rule excludes anyway.
function mulDivFloor(uint256 x, uint256 y, uint256 d) returns uint256 {
    require d != 0;
    return require_uint256((to_mathint(x) * to_mathint(y)) / to_mathint(d));
}

definition isPayout(method f) returns bool =
    f.selector == sig:settle().selector || f.selector == sig:sweep().selector || f.selector == sig:claimCash().selector;

definition min(mathint a, mathint b) returns mathint = a < b ? a : b;
definition max(mathint a, mathint b) returns mathint = a > b ? a : b;

// the receipt's four seats are four different, nonzero contracts, as a deployed receipt's are
function wired() {
    address p = PORTFOLIO();
    require p != 0 && VAULT() != 0 && POSITION_MANAGER() != 0;
    require p != VAULT() && p != POSITION_MANAGER() && p != DOOR() && p != currentContract;
    require VAULT() != POSITION_MANAGER() && VAULT() != DOOR() && POSITION_MANAGER() != DOOR();
}

// the hub's market rail: a market this receipt is pledged in has `minPrincipal >= 2` (MarketInit, write-once params)
function hubRails(uint256 loanId) {
    require hub.collateralOfLoan(loanId) == currentContract => hub.minPrincipalOfLoan(loanId) >= 2;
}

// one payout verb by index: 0 settle, 1 sweep, 2 claimCash; the vault leg and the owner leg as each reports them
function payout(env e, uint8 which) returns (uint256, uint256) {
    uint256 v;
    uint256 o;
    if (which == 0) {
        v = settle(e);
        o = 0;
    } else if (which == 1) {
        v = sweep(e);
        o = 0;
    } else {
        v, o = claimCash(e);
    }
    return (v, o);
}

// the address `claimCash` pays the owner's part to: the owner recorded at the seizure, or after a clean close the portfolio's, read now
function ownerLeg() returns address {
    return state() == SAeroStakeReceipt.State.Sold ? owner() : owners.ownerView(PORTFOLIO());
}

// ---- R1: the payout order ----

// D FIRST, THEN THE FEE, THEN THE OWNER, on each of the three verbs that pay cash out. What the vault leg took lowers D
// by up to all of D and the fee by the rest; the fee falls only once D is zero; the owner's part is exactly the cash
// beyond D + fee read before the door leg, so a short door take never hands the owner the claim's cash, which stays here.
function checkPayoutOrder(env e, uint8 which) {
    mathint d0 = seniorDebt();
    mathint f0 = lenderFee();
    mathint b0 = cash.balanceOf(currentContract);

    uint256 v;
    uint256 o;
    v, o = payout(e, which);

    mathint d1 = seniorDebt();
    mathint f1 = lenderFee();
    mathint toD = min(v, d0);

    assert v <= b0 && v <= d0 + f0, "the vault leg took more than the cash here or the open claim";
    assert d1 == d0 - toD && f1 == f0 - (v - toD), "the vault leg did not pay D first and the fee after";
    assert f1 < f0 => d1 == 0, "the lenders' fee was paid while the vault's claim was still open";
    assert f0 - f1 <= max(b0 - d0, 0), "the fee paid exceeded the cash above D";
    assert o > 0 => (b0 > d0 + f0 && o == b0 - d0 - f0), "the owner was paid out of cash the claim and the fee needed";
    assert b0 >= d0 + f0 => cash.balanceOf(currentContract) >= d1 + f1, "cash the open claim needs left the receipt";
}

rule settlePaysTheClaimFirstThenTheFeeThenTheOwner(env e) {
    checkPayoutOrder(e, 0);
}

rule sweepPaysTheClaimFirstThenTheFeeThenTheOwner(env e) {
    checkPayoutOrder(e, 1);
}

rule claimCashPaysTheClaimFirstThenTheFeeThenTheOwner(env e) {
    checkPayoutOrder(e, 2);
}

// A-F3's exact half: a sale or a sweep pays the door the whole of what the cash here covers, min(cash, D + fee).
rule aSaleOrASweepPaysTheDoorAllTheCashCovers(env e, uint8 which) {
    require which < 2;
    mathint owed = min(cash.balanceOf(currentContract), seniorDebt() + lenderFee());
    uint256 v;
    uint256 o;
    v, o = payout(e, which);
    assert to_mathint(v) == owed, "a sale or a sweep paid the door other than min(cash, D + fee)";
    assert state() == SAeroStakeReceipt.State.Sold, "a sale or a sweep did not leave the receipt Sold";
}

// WITNESSES: a claim paying D, the fee and the owner in full; a short door take still paying the owner's excess; a
// sale whose cash reaches the fee.
rule witnessAClaimPaysAllThreeLegs(env e) {
    mathint d0 = seniorDebt();
    mathint f0 = lenderFee();
    uint256 v;
    uint256 o;
    v, o = claimCash(e);
    satisfy d0 > 0 && f0 > 0 && to_mathint(v) == d0 + f0 && o > 0;
}

rule witnessAShortDoorTakeStillPaysTheOwnersExcess(env e) {
    mathint d0 = seniorDebt();
    uint256 v;
    uint256 o;
    v, o = claimCash(e);
    satisfy to_mathint(v) < d0 && o > 0 && seniorDebt() > 0;
}

rule witnessASalePaysTheFee(env e) {
    mathint f0 = lenderFee();
    settle(e);
    satisfy to_mathint(lenderFee()) < f0;
}

// ---- R2: the lenders' fee ----

// THE SEIZURE BOOKS THE FIXED FEE, EXACTLY: floor(D * LENDER_FEE_BPS / 10000), returned, beside D.
rule aSeizureBooksTheFixedFee(env e, uint256 loanId, uint256 debt) {
    mathint bps = LENDER_FEE_BPS();
    uint256 fee = seize(e, loanId, debt);
    assert to_mathint(fee) == (to_mathint(debt) * bps) / 10000, "the fee booked is not floor(D * LENDER_FEE_BPS / 10000)";
    assert lenderFee() == fee && seniorDebt() == debt, "the seizure did not book the fee and the claim it returned";
    assert state() == SAeroStakeReceipt.State.Seized, "the seizure did not leave the receipt Seized";
}

// THE FEE IS THE RECEIPT'S CONSTANT, 500 bps, the same for every receipt: no door, no state and no upgrade moves it.
rule theFeeIsFiveHundredBps() {
    assert LENDER_FEE_BPS() == 500, "the receipt's fee constant is not 500 bps";
}

// ONLY THE SEIZURE RAISES THE FEE, and only a payout verb lowers it: no other method writes it at all.
// From a reachable state: a Holding receipt carries no fee (`noClaimBeforeTheSeizure`), so the seizure only raises it.
rule onlyTheSeizureRaisesTheFee(method f, env e, calldataarg args) {
    requireInvariant noClaimBeforeTheSeizure();
    uint256 fee0 = lenderFee();
    f(e, args);
    assert lenderFee() > fee0 => f.selector == sig:seize(uint256, uint256).selector, "something other than seize raised the fee";
    assert lenderFee() < fee0 => isPayout(f), "something other than a payout lowered the fee";
}

// no claim and no fee exist before the seizure, so a clean close owes neither
invariant noClaimBeforeTheSeizure()
    (state() == SAeroStakeReceipt.State.None || state() == SAeroStakeReceipt.State.Holding) => (seniorDebt() == 0 && lenderFee() == 0);

rule witnessASeizureBooksAFee(env e, uint256 loanId, uint256 debt) {
    uint256 fee = seize(e, loanId, debt);
    satisfy fee > 0;
}

// ---- R3: cash conservation ----

// A PAYOUT'S CASH OUT IS THE VAULT LEG PLUS THE OWNER LEG, AND NOTHING ELSE MOVES: the door gains the vault leg, the
// owner gains the owner leg, any third address keeps its balance, and the door's approval is spent or cleared.
// The owner is held apart from the receipt and the door, so each leg is read off one balance.
function checkConservation(env e, uint8 which, address x) {
    address o = ownerLeg();
    require o != currentContract && o != door;
    require x != currentContract && x != door && x != o;

    mathint owed = min(cash.balanceOf(currentContract), seniorDebt() + lenderFee());
    mathint b0 = cash.balanceOf(currentContract);
    mathint db0 = cash.balanceOf(door);
    mathint ob0 = cash.balanceOf(o);
    mathint xb0 = cash.balanceOf(x);

    uint256 v;
    uint256 toOwner;
    v, toOwner = payout(e, which);

    assert b0 - cash.balanceOf(currentContract) == v + toOwner, "the receipt's cash out is not the vault leg plus the owner leg";
    assert cash.balanceOf(door) - db0 == to_mathint(v), "the door did not gain exactly the vault leg";
    assert cash.balanceOf(o) - ob0 == to_mathint(toOwner), "the owner did not gain exactly the owner leg";
    assert cash.balanceOf(x) == xb0, "a payout moved a third address's cash";
    assert (which == 2 && owed != 0) => cash.allowance(currentContract, door) == 0, "a claim left the door an approval";
}

rule settleConservesCash(env e, address x) {
    checkConservation(e, 0, x);
}

rule sweepConservesCash(env e, address x) {
    checkConservation(e, 1, x);
}

rule claimCashConservesCash(env e, address x) {
    checkConservation(e, 2, x);
}

// A-G1: the receipt's cash falls only through its five spending verbs
rule cashLeavesOnlyThroughTheFiveVerbs(method f, env e, calldataarg args) {
    mathint b0 = cash.balanceOf(currentContract);
    f(e, args);
    assert cash.balanceOf(currentContract) < b0 => (isPayout(f) || f.selector == sig:draw(uint256).selector
        || f.selector == sig:repayFromRewards(uint256, uint256, uint256).selector), "cash left the receipt through another verb";
}

// R1 OVER EVERY VERB RESTS ON ONE FACT OUTSIDE THIS CONTRACT, so it is stated and witnessed rather than assumed. Once
// seized, a receipt's cash leaves only through the three payout verbs or `repayFromRewards`: `draw` refuses outside
// Holding. `repayFromRewards` checks no state, only that its loan is live and pledges this receipt, so its exclusion
// is the fact that no live loan pledges a seized receipt: every unit leaves the custodian by burning, and the vault
// pledges all UNITS in one loan (A-R2, V-15), which are the hub's and the vault's to keep, not this lane's.
// `draw`, `mint` and `seize` refuse from Seized and Sold (the rule below), so they are filtered here rather than vacuous.
rule aSeizedReceiptsCashLeavesOnlyThroughThePayoutsOrALiveLoan(method f, env e, calldataarg args) filtered {
    f -> f.selector != sig:draw(uint256).selector && f.selector != sig:mint().selector
        && f.selector != sig:seize(uint256, uint256).selector
} {
    require state() == SAeroStakeReceipt.State.Seized || state() == SAeroStakeReceipt.State.Sold;
    mathint b0 = cash.balanceOf(currentContract);
    f(e, args);
    assert cash.balanceOf(currentContract) < b0 => (isPayout(f) || f.selector == sig:repayFromRewards(uint256, uint256, uint256).selector),
        "a seized receipt's cash left through a verb other than a payout or a live loan's repay";
}

// a seized or sold receipt refuses the three verbs of its earlier states: the draw and the seizure need Holding, the mint None
rule aSeizedReceiptRefusesItsEarlierVerbs(method f, env e, calldataarg args) filtered {
    f -> f.selector == sig:draw(uint256).selector || f.selector == sig:mint().selector
        || f.selector == sig:seize(uint256, uint256).selector
} {
    require state() == SAeroStakeReceipt.State.Seized || state() == SAeroStakeReceipt.State.Sold;
    f@withrevert(e, args);
    assert lastReverted, "a seized or sold receipt took a draw, a mint or a second seizure";
}

// and the premise is load-bearing: given a live loan pledging it, a Sold receipt with its claim open repays that loan
rule witnessTheRepayIsNotGatedOnTheReceiptsState(env e, uint256 loanId, uint256 maxAmount, uint256 minDebtAfter) {
    require state() == SAeroStakeReceipt.State.Sold && seniorDebt() > 0;
    uint256 paid = repayFromRewards(e, loanId, maxAmount, minDebtAfter);
    satisfy paid > 0;
}

rule witnessAClaimMovesBothLegs(env e) {
    uint256 v;
    uint256 o;
    v, o = claimCash(e);
    satisfy v > 0 && o > 0;
}

// ---- R4: units ----

ghost mathint sumOfUnits {
    init_state axiom sumOfUnits == 0;
}

hook Sstore _balances[KEY address a] uint256 v (uint256 prev) {
    sumOfUnits = sumOfUnits + v - prev;
}

hook Sload uint256 v _balances[KEY address a] {
    require sumOfUnits >= to_mathint(v);
}

invariant unitsAreTheSumOfBalances()
    to_mathint(outstanding()) == sumOfUnits;

// A-R5 and A-M1: nothing exists before the mint, every unit after it is outstanding or burned, and the door's burns
// are part of the burns
invariant unitsAreConserved()
    (state() == SAeroStakeReceipt.State.None => (outstanding() == 0 && burned() == 0 && doorBurned() == 0))
    && (state() != SAeroStakeReceipt.State.None => to_mathint(outstanding()) + to_mathint(burned()) == to_mathint(UNITS()))
    && doorBurned() <= burned()
    {
        preserved with (env e) {
            requireInvariant unitsAreTheSumOfBalances();
            wired();
        }
    }

// THE INVARIANTS' BASE CASE IS ARGUED, NOT PROVEN. The prover's own base case runs the IMPLEMENTATION's constructor,
// and its storage analysis of that constructor fails under via-IR, so each of the three invariants reports that step
// UNKNOWN; every induction step is proven. The argument: a receipt is a clone, which runs no constructor, so its
// storage starts all zero until `make` calls `mint`, and `mint` is one of the proven induction steps. This rule calls
// nothing and asserts its own `require`s back, so it proves nothing: it only writes the zero state down beside the
// three invariants it would satisfy.
rule arguedBaseCase_aFreshCloneIsTheZeroState() {
    require state() == SAeroStakeReceipt.State.None;
    require seniorDebt() == 0 && lenderFee() == 0;
    require outstanding() == 0 && burned() == 0 && doorBurned() == 0;
    require sumOfUnits == 0;

    assert seniorDebt() == 0 && lenderFee() == 0, "noClaimBeforeTheSeizure fails on a fresh clone";
    assert to_mathint(outstanding()) == sumOfUnits, "unitsAreTheSumOfBalances fails on a fresh clone";
    assert outstanding() == 0 && burned() == 0 && doorBurned() == 0 && doorBurned() <= burned(),
        "unitsAreConserved fails on a fresh clone";
}

// EVERY UNIT LEAVING THE CUSTODIAN BURNS: when the custodian's balance falls, the supply falls by the same, `burned`
// rises by the same, and no other address's balance rises.
rule everyExitFromTheCustodianBurns(method f, env e, calldataarg args, address x) {
    requireInvariant unitsAreTheSumOfBalances();
    wired();
    address pm = POSITION_MANAGER();
    require x != pm;
    mathint pm0 = balanceOf(pm);
    mathint x0 = balanceOf(x);
    mathint out0 = outstanding();
    mathint burned0 = burned();

    f(e, args);

    mathint left = pm0 - balanceOf(pm);
    assert left > 0 => (to_mathint(outstanding()) == out0 - left && to_mathint(burned()) == burned0 + left),
        "units left the custodian without burning";
    assert left > 0 => to_mathint(balanceOf(x)) <= x0, "a unit leaving the custodian was credited to someone";
}

// `outstanding` FALLS ONLY ON A CUSTODIAN EXIT, by what left it, and `doorBurned` rises only then
rule outstandingFallsOnlyOnACustodianExit(method f, env e, calldataarg args) {
    requireInvariant unitsAreTheSumOfBalances();
    wired();
    address pm = POSITION_MANAGER();
    mathint out0 = outstanding();
    mathint pm0 = balanceOf(pm);
    mathint burned0 = burned();
    mathint door0 = doorBurned();

    f(e, args);

    mathint fell = out0 - outstanding();
    assert fell > 0 => (pm0 - balanceOf(pm) == fell && burned() - burned0 == fell), "outstanding fell other than by a custodian exit";
    assert doorBurned() > door0 => pm0 - balanceOf(pm) == doorBurned() - door0, "doorBurned rose other than by a custodian exit";
}

// A custodian exit to the door counts in `doorBurned` as well, and one to anyone else does not; the recipient gets nothing.
rule anExitToTheDoorCountsAsTheDoors(env e, address to, uint256 amount) {
    requireInvariant unitsAreTheSumOfBalances();
    wired();
    require e.msg.sender == POSITION_MANAGER() && to != POSITION_MANAGER();
    mathint burned0 = burned();
    mathint door0 = doorBurned();
    mathint to0 = balanceOf(to);

    transfer(e, to, amount);

    assert to_mathint(burned()) == burned0 + amount, "a custodian exit did not count in burned";
    assert to_mathint(doorBurned()) == door0 + (to == DOOR() ? to_mathint(amount) : 0), "doorBurned miscounted a custodian exit";
    assert to_mathint(balanceOf(to)) == to0, "the recipient of a custodian exit was credited a unit";
}

// A-R3: a balance rises only along the three legs: the mint to the portfolio, the portfolio to the vault by the vault,
// the vault to the custodian by the custodian; and only those two approvals land
rule unitsMoveOnlyAlongTheirLegs(method f, env e, calldataarg args, address x) {
    wired();
    mathint x0 = balanceOf(x);
    f(e, args);
    assert to_mathint(balanceOf(x)) > x0 => (
        (x == PORTFOLIO() && f.selector == sig:mint().selector)
        || (x == VAULT() && e.msg.sender == VAULT())
        || (x == POSITION_MANAGER() && e.msg.sender == POSITION_MANAGER())
    ), "a unit moved outside the receipt's three legs";
}

rule onlyTheTwoApprovalsLand(env e, address spender, uint256 value) {
    wired();
    approve(e, spender, value);
    assert (e.msg.sender == PORTFOLIO() && spender == VAULT()) || (e.msg.sender == VAULT() && spender == POSITION_MANAGER()),
        "an approval other than the two legs' landed";
}

// A CLEAN CLOSE IS HOLDING WITH EVERY UNIT BURNED AND NONE AT THE DOOR: the only Holding state `claimCash` pays from.
rule aCleanCloseIsHoldingWithEveryUnitBurnedAndNoneAtTheDoor(env e) {
    requireInvariant unitsAreConserved();
    require state() == SAeroStakeReceipt.State.Holding;
    claimCash(e);
    assert outstanding() == 0 && burned() == UNITS() && doorBurned() == 0, "claimCash paid a Holding receipt that had not closed clean";
}

rule witnessAnExitToTheDoorBurns(env e, uint256 amount) {
    require e.msg.sender == POSITION_MANAGER();
    mathint door0 = doorBurned();
    transfer(e, DOOR(), amount);
    satisfy to_mathint(doorBurned()) > door0;
}

rule witnessACleanClosePaysTheOwner(env e) {
    requireInvariant unitsAreConserved();
    require state() == SAeroStakeReceipt.State.Holding;
    uint256 v;
    uint256 o;
    v, o = claimCash(e);
    satisfy o > 0 && UNITS() > 0;
}

// ---- R5: the reward repay ----

// THE GATE: only the portfolio, its owner (read now off the 40 Acres factory) or a nonzero operator (read now off the door).
rule onlyThePortfolioItsOwnerOrTheOperatorRepays(env e, uint256 loanId, uint256 maxAmount, uint256 minDebtAfter) {
    address p = PORTFOLIO();
    address o = owners.ownerView(p);
    address op = door.operatorView();
    repayFromRewards@withrevert(e, loanId, maxAmount, minDebtAfter);
    assert !lastReverted => (e.msg.sender == p || e.msg.sender == o || (op != 0 && e.msg.sender == op)),
        "a caller other than the portfolio, its owner or the operator repaid";
}

// THE BOUND: a repay never leaves the debt it read under max(floor, minDebtAfter) unless it repaid the whole debt, never
// applies more than the cap or the cash, and approves the hub exactly what it applies.
rule aRepayNeverLeavesTheDebtUnderTheBound(env e, uint256 loanId, uint256 maxAmount, uint256 minDebtAfter) {
    mathint debt0 = hub.debtView(loanId);
    mathint cash0 = cash.balanceOf(currentContract);
    mathint keep = max(hub.minPrincipalOfLoan(loanId) / 2, minDebtAfter);

    uint256 paid = repayFromRewards(e, loanId, maxAmount, minDebtAfter);

    mathint debt1 = hub.debtView(loanId);
    assert debt1 == debt0 - paid, "the hub was asked for other than the amount applied";
    assert paid <= maxAmount && to_mathint(paid) <= cash0, "the repay applied more than the cap or the cash";
    assert debt1 == 0 || debt1 >= keep, "a partial repay left the debt under max(floor, minDebtAfter)";
    assert cash.allowance(currentContract, hub) == 0, "the repay approved the hub other than the amount it applied";
}

// THE CLOSE: only the portfolio or its owner, with the cash and the cap both covering the debt, and no bound.
rule onlyThePortfoliosCoveredUnboundCallCloses(env e, uint256 loanId, uint256 maxAmount, uint256 minDebtAfter) {
    hubRails(loanId);
    address p = PORTFOLIO();
    mathint debt0 = hub.debtView(loanId);
    mathint cash0 = cash.balanceOf(currentContract);

    uint256 paid = repayFromRewards(e, loanId, maxAmount, minDebtAfter);

    assert to_mathint(paid) == debt0 => (
        (e.msg.sender == p || e.msg.sender == owners.ownerView(p))
        && minDebtAfter == 0 && cash0 >= debt0 && to_mathint(maxAmount) >= debt0
    ), "a repay closed the loan for a caller, a cap, a cash or a bound that may not close it";
}

// and the close is no narrower: the portfolio's or its owner's covered call with no bound repays the whole debt
rule theOwnersCoveredUnboundCallCloses(env e, uint256 loanId, uint256 maxAmount) {
    address p = PORTFOLIO();
    require e.msg.sender == p || e.msg.sender == owners.ownerView(p);
    mathint debt0 = hub.debtView(loanId);
    require cash.balanceOf(currentContract) >= debt0 && to_mathint(maxAmount) >= debt0;

    uint256 paid = repayFromRewards(e, loanId, maxAmount, 0);

    assert to_mathint(paid) == debt0 && hub.debtView(loanId) == 0, "the owner's covered call did not close the loan";
}

rule witnessTheOwnerCloses(env e, uint256 loanId, uint256 maxAmount) {
    require e.msg.sender == owners.ownerView(PORTFOLIO()) && e.msg.sender != PORTFOLIO();
    mathint debt0 = hub.debtView(loanId);
    repayFromRewards(e, loanId, maxAmount, 0);
    satisfy debt0 > 0 && hub.debtView(loanId) == 0;
}

rule witnessTheOperatorsBoundedPartial(env e, uint256 loanId, uint256 maxAmount, uint256 minDebtAfter) {
    hubRails(loanId);
    require e.msg.sender == door.operatorView() && e.msg.sender != PORTFOLIO() && e.msg.sender != owners.ownerView(PORTFOLIO());
    require to_mathint(minDebtAfter) > hub.minPrincipalOfLoan(loanId) / 2;
    uint256 paid = repayFromRewards(e, loanId, maxAmount, minDebtAfter);
    satisfy paid > 0 && hub.debtView(loanId) == minDebtAfter;
}
