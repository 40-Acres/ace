// Ace hub -- O6, with the sliver: every live loan holds what its settlement takes off the lot.
//
// Settlement takes the keeper's sliver off the top (`Settlement._settle`), then the claim's need at the funding floor. So
// a loan settles whole only while `units >= collateralNeeded(claim) + sliverUnits(debt)`. A NEW VERB THAT LOWERS A LIVE
// LOAN'S LOT OR RAISES ITS DEBT WITHOUT A CHECK breaks that, and before this spec no hub rule would have noticed.
//
// THE PROOF IS IN TWO HALVES, each on the real code:
//   - THE FORMULAS, in CoverageMath.spec on the pure harness: `coverageLine(k, S, d, f) >= need(d) + sliver(d)` at any
//     `0 < f <= price` (`theCoverageLineCoversSettlement`, the claim at Constants.sol's MAX_SETTLE_BOUNTY_BPS), at a zero
//     price the line is the max sentinel (`requiredAtIsTheCoverageCeiled`), the need and the sliver fall with the debt
//     (`theNeedAndSliverFallWithTheDebt`), and a sale inside `securedBase` keeps them (`aSaleWithinTheSecuredBaseKeepsTheCover`).
//   - THE WIRING, here: which lot, which debt and which price each door compares, and that nothing else moves them.
//     `loanLotAndDebtMoveOnlyThroughGatedVerbs` says no verb but a withdrawal and a deleverage lowers a live loan's lot or
//     raises its debt. `aWithdrawalLeavesTheLotOnTheCoverageLine`, `aBirthOpensOnTheCoverageLine` and
//     `aRefinanceLeavesTheSuccessorOnTheCoverageLine` say each door compares the lot it leaves with the line at the loan's
//     own debt, its own market's dials and a price at or under that market's price. `aRestoreSellsOnlyTheSecuredBase`
//     says a crank that leaves the loan live takes at most what `securedBase` allowed.
// Together, with O10 (the claim is the debt, HubClaims.spec) and O56 (params never change, the rails hold), they give
// `aLiveLoanCoversItsSettlement` by induction over the verbs. The composition is stated in obligations.md, row O6.
//
// WHY NOT ONE INVARIANT: its inductive step needs the line's arithmetic at every door, and every exact hub run of that
// shape has timed out (HubClaimsExact's 8-hour UNKNOWN). Here `mulDiv` stays uninterpreted (HubLoans.spec), so nothing
// below depends on a formula: the coverage line ANSWERS ANYTHING and is recorded, and the rules say what was asked and
// that the lot left stands at or over the answer. Any real answer is one of those answers, so the wiring holds of it.
//
// ALSO HERE, the same wiring-under-any-`mulDiv` shape for the keeper and settlement, whose exact-arithmetic forms in
// HubCoverageExact.spec time out: `aCrankSellsOnlyAboveTheStopLevel` (O15's gate), `aClosingCrankSellsTheCloseSize` (the
// close's size), `aSettlementConservesTheLot` and `aSettlementPaysTheSliverAndTheNeed` (O50), plus O59's
// `aClosedLoanHoldsNoEscrow` and the bounty rail `aCreatedMarketKeepsItsBountyRail`.
//
// SUMMARIES: the coverage line and the record's windowed minimum (each recorded, any answer), and the read-only gates as
// HubLeanGates.spec has them. NOT summarized, because the wiring reads them: `_previewFloor` (the birth's price),
// `fundingFloor`, `securedBase`, `requiredAt`, `collateralNeeded`, `sliverUnits` and the trigger.
// The custodian, title and keeper calls do nothing; any other unresolved call (a token, the record) takes the prover's
// default, which never writes the hub. No library call is left on the munged hub, so nothing of the hub is swallowed.

import "HubLoans.spec";

methods {
    // THE COVERAGE LINE, RECORDED, on the three-field form every gate calls. The four-field form is NOT summarized: via-IR
    // inlines it into `createMarket`, and a summary on a function the prover cannot locate at a call site fails that verb.
    function Borrower.coverageLine(HubCoverageHarness.Cfg memory c, uint256 debt, uint256 price) internal returns (uint256)
        => coverageLineAsked(c.p.minCoverageWad, c.unitScale, debt, price);

    // the read-only gates, "returns anything, never reverts": a superset of every real behaviour of a view
    function Borrower.tryRecordState(HubCoverageHarness.Cfg memory) internal returns (bool, HubCoverageHarness.RecordState, uint256) => NONDET;
    function Borrower._admissibleLeg(HubCoverageHarness.Cfg memory, uint256, uint256, uint256, uint256) internal returns (bytes4) => NONDET;
    function Probe.askBool(address, bytes memory, uint256, bytes32) internal returns (bool) => NONDET;
    function Borrower._preChecks(HubCoverageHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._gateCheck(HubCoverageHarness.Cfg memory, Borrower.OpenArgs memory) internal => NONDET;
    function Borrower._payoutCheck(HubCoverageHarness.Cfg memory, Borrower.OpenArgs memory, uint256) internal returns (uint256) => NONDET;
    function Borrower._gate(uint256, uint256, uint256) internal returns (uint256) => NONDET;
    // `Borrower.triggerPrice` is NOT summarized: the crank's stop gate reads it, and `aCrankSellsOnlyAboveTheStopLevel`
    // compares that gate with the harness's `stopLevelOf`, which reads it too. The record's windowed minimum is RECORDED and
    // answers anything: the price the crank gated, sized and billed at.
    function Borrower.persistedPrice(HubCoverageHarness.Cfg memory) internal returns (uint256) => priceAsked();
    function Borrower.inDistress(HubCoverageHarness.Loan storage, HubCoverageHarness.Cfg memory) internal returns (bool) => NONDET;
    // the record's below-questions, on the one decoder both share: via-IR inlines `persistedBelowOrRevert` into `deleverage`
    // and `persistedBelowSettleOrRevert` into `finalize`, so a summary on either fails those verbs
    function Borrower._belowOrRevert(HubCoverageHarness.Cfg memory, bytes memory) internal returns (bool) => NONDET;
    function Deleverage._deleverageSizing(HubCoverageHarness.Cfg memory, uint256, uint256, uint256) internal returns (uint256, uint256) => NONDET;

    // the custodian, title and keeper calls, by selector: none can write the hub's loan book. NO `unresolved` catch-all: a
    // DISPATCH default refuses the record's zero-size staticcall return, and the prover's own default is what HubLoans.spec
    // proves under
    function _.mint(uint256, address) external => NONDET;
    function _.pull(uint256, address, uint256) external => NONDET;
    function _.release(uint256, address, uint256) external => NONDET;
    function _.retireCustody(uint256, uint256) external => NONDET;
    function _.releaseRetired(uint256, address, uint256) external => NONDET;
    function _.carryOut(uint256, uint256) external => NONDET;
    function _.carryIn(uint256, uint256, uint256) external => NONDET;
    function _.onAceDeleverage(uint256, uint256, bytes) external => NONDET;

    function loanUnitsOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanDebtOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanClaimOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanExpiryOf(uint256) external returns (uint64) envfree; // HubCoverageHarness
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree; // AceHarness
    function marketSettleBountyBpsOf(bytes32) external returns (uint256) envfree; // AceHarness
    function securedBaseOf(uint256) external returns (uint256) envfree; // HubCoverageHarness
    function feeEscrowOfLoan(uint256) external returns (uint256) envfree; // HubCoverageHarness
    function loanBorrowerOf(uint256) external returns (address) envfree; // HubCoverageHarness
    function loanPotOf(uint256) external returns (uint256) envfree; // HubCoverageHarness
    function unitsOwedOf(uint256, address) external returns (uint256) envfree; // HubCoverageHarness
    function marketRecordOf(bytes32) external returns (address) envfree; // HubCoverageHarness
    function settlementNeedOf(uint256) external returns (uint256) envfree; // HubCoverageHarness
    function settlementSliverOf(uint256) external returns (uint256) envfree; // HubCoverageHarness
    function stopLevelOf(uint256) external returns (uint256) envfree; // HubCoverageHarness: the one re-spelling, of an inline gate
    function marketDeleverageOf(bytes32) external returns (uint256, uint256, uint256, uint256, uint256) envfree; // HubCoverageHarness
}

persistent ghost mathint priceAsks;
persistent ghost uint256 priceSeen;

function priceAsked() returns uint256 {
    uint256 p;
    priceAsks = priceAsks + 1;
    priceSeen = p;
    return p;
}

// ---- the coverage line, recorded. PERSISTENT, so no call between the gate and the assert can erase it ----

persistent ghost mathint covAsks;
persistent ghost uint256 covK;
persistent ghost uint256 covS;
persistent ghost uint256 covDebt;
persistent ghost uint256 covPrice;
persistent ghost uint256 covLine;

function coverageLineAsked(uint256 k, uint256 s, uint256 debt, uint256 price) returns uint256 {
    uint256 line;
    covAsks = covAsks + 1;
    covK = k;
    covS = s;
    covDebt = debt;
    covPrice = price;
    covLine = line;
    return line;
}

definition live(uint256 id) returns bool = loanMarket(id) != to_bytes32(0) && closedAtOf(id) == 0;

// the last line asked was the loan's own: its market's dials, its debt as it stands, a price at or under its market's price,
// and the lot it holds stands at or over the answer
function onItsOwnLine(uint256 id) returns bool {
    uint256 k; uint256 s; uint256 p;
    k, s, p = marketRailsOf(loanMarket(id));
    return covK == k && covS == s && covDebt == loanDebtOf(id) && covPrice <= p && loanUnitsOf(id) >= covLine;
}

// THE CHAIN'S CLOCK (HubClaims.spec `aRealClock`): a close stamps `uint64(block.timestamp)` and liveness IS `closedAt == 0`,
// so a close at a timestamp of 0 mod 2^64 would leave a closed loan reading live with its lot retired
function scene(env e) {
    require e.msg.sender != currentContract;
    require aRealClock(e);
    requireInvariant marketZeroIsNeverCreated();
    requireInvariant idZeroIsNeverIssued();
    requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 1));
    requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 2));
}

// ---- THE FRAME: what may lower a live loan's lot or raise its debt ----

definition notAGatedVerb(method f) returns bool =
    f.selector != sig:withdrawCollateral(uint256,uint256,address).selector
    && f.selector != sig:deleverage(uint256,uint256,bytes).selector;

// THE EULER CLASS: outside a withdrawal and a deleverage, no verb lowers a loan's lot or raises its debt while it stays
// live. A new verb that does fails here, whatever else it does. A birth is outside it: a fresh id was never live.
rule loanLotAndDebtMoveOnlyThroughGatedVerbs(env e, method f, calldataarg args, uint256 id)
    filtered { f -> freshIdVerb(f) && notAGatedVerb(f) }
{
    scene(e);
    requireInvariant aFreshIdHasNeverClosed(id);
    bool wasLive = live(id);
    mathint u0 = loanUnitsOf(id);
    mathint d0 = loanDebtOf(id);
    f(e, args);
    assert (wasLive && live(id)) => loanUnitsOf(id) >= u0, "a verb outside the gated doors lowered a live loan's lot";
    assert (wasLive && live(id)) => loanDebtOf(id) <= d0, "a verb outside the gated doors raised a live loan's debt";
}

// ---- THE GATED DOORS: each compares the lot it leaves with the loan's own coverage line ----

// a withdrawal leaves the loan on its own line, at the live fold of funding floor and record
rule aWithdrawalLeavesTheLotOnTheCoverageLine(env e, uint256 id, uint256 units, address to) {
    scene(e);
    require covAsks == 0;
    withdrawCollateral(e, id, units, to);
    assert covAsks == 1, "a withdrawal asked no coverage line";
    assert live(id) && onItsOwnLine(id), "a withdrawal left the lot under its own coverage line";
}

definition isBirth(method f) returns bool =
    f.selector == sig:open(bytes32,uint256,uint256,uint64,address,HubCoverageHarness.OpenBounds).selector
    || f.selector == sig:openWithPermit2(bytes32,uint256,uint256,uint64,address,HubCoverageHarness.OpenBounds,bytes).selector
    || f.selector == sig:fillOrder(uint256,uint256,uint256).selector;

// every birth opens its loan on its own line, at the market's price or the record under it, with the claim the debt
rule aBirthOpensOnTheCoverageLine(env e, method f, calldataarg args) filtered { f -> isBirth(f) } {
    scene(e);
    require covAsks == 0;
    uint256 id = require_uint256(idCount() + 1);
    f(e, args);
    assert covAsks == 1, "a birth asked no coverage line";
    assert live(id) && onItsOwnLine(id), "a birth opened under its own coverage line";
}

// a refinance opens its successor on the destination's line, and a withdrawal leg re-asks it on the lot that leg leaves
rule aRefinanceLeavesTheSuccessorOnTheCoverageLine(env e, HubCoverageHarness.MigrateArgs a) {
    scene(e);
    require covAsks == 0;
    uint256 id = require_uint256(idCount() + 1);
    refinanceTo(e, a);
    assert loanMarket(id) == a.dst, "the successor sits outside its destination";
    assert covAsks == (a.withdrawUnits == 0 ? 1 : 2), "the successor's line was asked the wrong number of times";
    assert live(id) && onItsOwnLine(id), "a refinance left its successor under its own coverage line";
}

// a crank that leaves the loan live sold at most the secured base it had going in; a refund only adds back
rule aRestoreSellsOnlyTheSecuredBase(env e, uint256 id, uint256 minStableOut, bytes data) {
    scene(e);
    require live(id);
    mathint sb = securedBaseOf(id);
    mathint u0 = loanUnitsOf(id);
    mathint d0 = loanDebtOf(id);
    deleverage(e, id, minStableOut, data);
    assert closedAtOf(id) == 0 => loanUnitsOf(id) + sb >= u0, "a restoring crank sold past the secured base";
    assert loanDebtOf(id) <= d0, "a crank raised the debt";
}

// O15's gate, its wiring: a crank that sold anything, restoring or closing, read the record once and cleared the loan's
// stop level as it stood going in. `stopLevelOf` re-spells the inline gate; the arithmetic it feeds is CoverageMath.spec's
// `aSoldUnitMeltsAtLeastTheDebtPerUnit`, and HubCoverageExact.spec states the same gate on exact arithmetic.
rule aCrankSellsOnlyAboveTheStopLevel(env e, uint256 id, uint256 minStableOut, bytes data) {
    scene(e);
    require live(id);
    require priceAsks == 0;
    mathint stopLevel = stopLevelOf(id);
    mathint u0 = loanUnitsOf(id);
    deleverage(e, id, minStableOut, data);
    bool sold = closedAtOf(id) != 0 || to_mathint(loanUnitsOf(id)) < u0;
    assert sold => priceAsks == 1, "a crank sold without one record read";
    assert sold => to_mathint(priceSeen) > stopLevel, "a crank sold at or under the loan's stop level";
}

// O54/O63, the closing crank's size, its wiring: a crank that closes the loan sold exactly
// `mulDiv(debt - 1, 1e4 * S, ps * (1e4 - eps)) + 1` units at the record price it read, on the debt as it stood, and the
// units it did not sell are the borrower's. `mulDiv` here IS the code's (`fmDown`, HubLoans.spec), so this pins the inline
// formula in `_closeSale`; HubClaimsExact.spec's `theCloseLemmaHolds` proves that formula is the smallest sale whose ceiled
// bill covers the debt.
rule aClosingCrankSellsTheCloseSize(env e, uint256 id, uint256 minStableOut, bytes data) {
    scene(e);
    require live(id);
    require priceAsks == 0;
    bytes32 m = loanMarket(id);
    address b = loanBorrowerOf(id);
    uint256 eps; uint256 band; uint256 target; uint256 stop; uint256 cb;
    eps, band, target, stop, cb = marketDeleverageOf(m);
    uint256 k; uint256 s; uint256 p;
    k, s, p = marketRailsOf(m);
    mathint u0 = loanUnitsOf(id);
    mathint d0 = loanDebtOf(id);
    mathint owed0 = unitsOwedOf(id, b);
    deleverage(e, id, minStableOut, data);
    require closedAtOf(id) != 0; // the close path
    mathint sold = u0 - (unitsOwedOf(id, b) - owed0);
    assert priceAsks == 1, "a crank closed without one record read";
    assert loanUnitsOf(id) == 0 && loanDebtOf(id) == 0, "a closing crank left units or debt on the loan";
    assert sold == fmDown(require_uint256(d0 - 1), require_uint256(10000 * s), require_uint256(priceSeen * (10000 - eps))) + 1,
        "a closing crank sold other than the close size at the price it read";
}

// ---- SETTLEMENT'S SPLIT, its wiring (the formulas are CoverageMath.spec's; the exact-arithmetic form is HubCoverageExact.spec's) ----

// settle `id` by the verb chosen: `finalize` on persisted distress, or `forceClose` from expiry
function settle(env e, uint256 id, bool viaFinalize) {
    if (viaFinalize) {
        finalize(e, id);
    } else {
        forceClose(e, id);
    }
}

// O50: settlement conserves the lot. The loan's whole lot lands, to the unit, in the lender's pot, the keeper's credit and
// the borrower's credit, whoever the keeper is; the loan closes holding nothing.
rule aSettlementConservesTheLot(env e, uint256 id, bool viaFinalize) {
    scene(e);
    require live(id);
    requireInvariant aFreshIdHasNeverClosed(id);
    address b = loanBorrowerOf(id);
    address keeper = e.msg.sender;
    mathint u0 = loanUnitsOf(id);
    mathint pot0 = loanPotOf(id);
    mathint owedB0 = unitsOwedOf(id, b);
    mathint owedK0 = unitsOwedOf(id, keeper);
    settle(e, id, viaFinalize);
    mathint landed = (loanPotOf(id) - pot0) + (unitsOwedOf(id, b) - owedB0) + (keeper == b ? 0 : unitsOwedOf(id, keeper) - owedK0);
    assert closedAtOf(id) != 0 && loanUnitsOf(id) == 0, "settlement left the loan live or holding units";
    assert landed == u0, "settlement lost or minted units";
}

// O50: the keeper is credited exactly the sliver `sliverUnits` prices off the loan as it stood, and the lender's pot takes
// at least the claim's need `collateralNeeded`, or all the lot past the sliver can pay. With a record it takes exactly the
// ruled take, capped at the lot past the sliver: inside the term the claim at the trigger, ceil(lot * 1e18 / k), held
// between the need and the coverage line the settlement asked on the loan's own dials and debt; from the expiry second the
// need; with no need, nothing. The line's value is CoverageMath.spec's (`theCoverageLineIsRequiredPlusOne`): here it is
// the RECORDED answer, so the take is checked against the line the code used rather than a CVL copy of its formula.
rule aSettlementPaysTheSliverAndTheNeed(env e, uint256 id, bool viaFinalize) {
    scene(e);
    require live(id);
    requireInvariant aFreshIdHasNeverClosed(id);
    address b = loanBorrowerOf(id);
    address keeper = e.msg.sender; // any caller, the borrower included: only the sliver's credit is keeper-specific
    uint256 k; uint256 s; uint256 p;
    k, s, p = marketRailsOf(loanMarket(id));
    // PROVEN IN HubClaims.spec, which cannot be imported here: a loan sits in a created market (`aLoanSitsInACreatedMarket`)
    // whose rails hold (`aCreatedMarketKeepsItsRails`). Only the two bounds this rule divides by are stated.
    require k >= 105 * 10^16 && p > 0;
    uint256 lot = loanUnitsOf(id);
    mathint u0 = lot;
    mathint d0 = loanDebtOf(id);
    mathint exp0 = loanExpiryOf(id);
    mathint need = settlementNeedOf(id);
    mathint sliver = settlementSliverOf(id);
    mathint pot0 = loanPotOf(id);
    mathint owedK0 = unitsOwedOf(id, keeper);
    mathint asks0 = covAsks;
    settle(e, id, viaFinalize);
    mathint dPot = loanPotOf(id) - pot0;
    mathint afterSliver = u0 - sliver;
    bool inTerm = e.block.timestamp < exp0;
    // the code's `mulDivRoundingUp(lot, 1e18, k)` under this file's `mulDiv` (`fmDown`). `fmDown` is unconstrained, so this
    // holds for every value of it, the exact floor included; with the floor, floor + (remainder != 0) is the ceil
    // (CoverageMath.spec `theFloorsAndCeilsBindBothWays`), which makes this rule O50's exact form
    mathint atTrigger = fmDown(lot, 10^18, k) + ((u0 * 10^18) % k > 0 ? 1 : 0);
    mathint capped = atTrigger < to_mathint(covLine) ? atTrigger : to_mathint(covLine);
    mathint take = need == 0 ? 0 : (inTerm ? (capped > need ? capped : need) : need);
    assert keeper != b => unitsOwedOf(id, keeper) - owedK0 == sliver, "the keeper was not credited the sliver the loan's debt prices";
    assert dPot >= (need < afterSliver ? need : afterSliver), "the lender's pot took less than the need the lot could pay";
    assert dPot <= afterSliver, "the lender's pot ate into the keeper's sliver";
    assert marketRecordOf(loanMarket(id)) != 0 && need != 0 && inTerm =>
        covAsks > asks0 && covK == k && covS == s && to_mathint(covDebt) == d0 && covPrice <= p,
        "a record-backed settlement inside the term did not cap at the coverage line of the loan's own dials and debt";
    assert marketRecordOf(loanMarket(id)) != 0 => dPot == (take < afterSliver ? take : afterSliver),
        "a record-backed settlement's pot is not min(the ruled take, lot past the sliver)";
}

// O56's bounty leg, which O51 and the coverage line both rest on: genesis caps the sliver at MAX_SETTLE_BOUNTY_BPS
invariant aCreatedMarketKeepsItsBountyRail(bytes32 m)
    marketQuoteOf(m) != 0 => marketSettleBountyBpsOf(m) <= 200
    filtered { f -> freshIdVerb(f) }
    { preserved with (env e) { require e.msg.sender != currentContract; } }

// O59: a closed loan holds no fee escrow. Every close empties it: a clean close refunds what the term did not earn, a
// refinance refunds it into the netting, settlement earns it whole, and nothing writes a closed loan's escrow again.
// O1 counts escrow as booked, so an escrow stranded on a closed loan would balance there perfectly.
invariant aClosedLoanHoldsNoEscrow(uint256 id)
    closedAtOf(id) != 0 => feeEscrowOfLoan(id) == 0
    filtered { f -> freshIdVerb(f) }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            require aRealClock(e);
            requireInvariant marketZeroIsNeverCreated();
            requireInvariant idZeroIsNeverIssued();
            requireInvariant aFreshIdHasNeverClosed(id);
            requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 1));
            requireInvariant aFreshIdHasNeverClosed(require_uint256(idCount() + 2));
        }
    }

definition aRealClock(env e) returns bool = e.block.timestamp > 0 && e.block.timestamp < 2^64;
