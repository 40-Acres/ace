// Ace hub -- the keeper's bill, the close's size, the stop gate and settlement's split, on the REAL code with exact mulDiv.
//
// HubClaimsExact.spec proves O10 on `deleverage` with `_owed` and `_cut` answered by monotone ghosts and the sizing, the
// secured base, the need and the sliver summarized away, so a crank that billed the keeper nothing, or a settlement that
// handed the keeper the whole lot, passed every hub rule. Here those bodies RUN, and each rule pins what moved:
//   - O54/O63 `aRestoringCrankPaysTheFloorBill`: a crank that leaves the loan live melted and cut exactly the ceiled floor
//     bill of what it took, `ceil(ps * sold * (1e4 - eps) / (1e4 * S))`, and the cut is the floor of its share of that bill;
//   - O54/O63 `aClosingCrankSellsTheSmallestLotThatPaysTheDebt`: a closing crank sold the fewest units whose bill covers the debt;
//   - O15 `aCrankSellsOnlyAboveTheStop`: any crank that sold did so at a record price strictly over the trigger's stop level;
//   - O50 `aSettlementSplitsTheLot*` (band off/on by door): settlement splits the lot into the keeper's sliver (its formula, exactly), the lender's
//     pot (the need, or all the lot can pay) and the borrower's credit, losing and minting nothing.
// O15 itself composes: the two crank rules here give the post-crank debt and lot, and CoverageMath.spec's
// `aSoldUnitMeltsAtLeastTheDebtPerUnit` and `theTriggerFallsWithTheDebtPerUnit` give a trigger that never rises.
//
// `FullMath.mulDiv` is EXACT, and a call the real routine refuses (a zero divisor, a quotient past 2^256 - 1) PRUNES its path:
// these are safety properties, and a reverting path writes nothing. `mulDivRoundingUp` takes no summary (via-IR eliminates
// it, see verify/README.md), so its body runs on the exact `mulDiv` and its ceil is derived, never asserted.
//
// SUMMARIZED, each a `view` or `pure` answered by "anything, never reverting", a superset of every real behaviour:
// the record's answers (the windowed minimum RECORDED, so the bill rule reads the price the crank priced at), the distress
// and band reads, the sizing, the secured base and the coverage line. Any size, any cap and any line is one of those answers,
// so a rule about what a sale of THAT size pays holds of the real one. The custodian, title, keeper and token calls do nothing.
// THE DOMAIN, stated: the market's rails hold (HubClaims.spec `aCreatedMarketKeepsItsRails`), the claim is the debt
// (HubClaims.spec O10). No revenue sweep rides a crank, so the quote's revenue pot moves only by the crank's own cut.

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivDownExact(a, b, d);

    // the record's windowed minimum for the verbs that read it with all gas, RECORDED; the crank reads `cappedPrice` below
    function Borrower.persistedPrice(HubCoverageHarness.Cfg memory) internal returns (uint256) => priceAsked();
    function Borrower.inDistress(HubCoverageHarness.Loan storage, HubCoverageHarness.Cfg memory) internal returns (bool) => NONDET;
    // the record's below-questions, on the one decoder both share: via-IR inlines `persistedBelowOrRevert` into `deleverage`
    // and `persistedBelowSettleOrRevert` into `finalize`, so a summary on either fails those verbs
    function Borrower._belowOrRevert(HubCoverageHarness.Cfg memory, bytes memory) internal returns (bool) => NONDET;
    function Deleverage._deleverageSizing(HubCoverageHarness.Cfg memory, uint256, uint256, uint256) internal returns (uint256, uint256) => NONDET;
    function LoanAccounting.securedBase(HubCoverageHarness.LoanBook storage, HubCoverageHarness.Market storage, HubCoverageHarness.Cfg memory,
        uint256, uint256) internal returns (uint256) => NONDET;
    // the coverage line RECORDED, still any answer: settlement's in-term cap is checked against the line the code asked
    function Borrower.coverageLine(HubCoverageHarness.Cfg memory c, uint256 debt, uint256 price) internal returns (uint256)
        => coverageLineAsked(c.p.minCoverageWad, c.unitScale, debt, price);
    // THE ONE CAPPED PRICE READ (#944, #945): the crank's and a band-on settlement's, RECORDED, any answer; its gas floor is assumed met
    function Borrower.cappedPrice(HubCoverageHarness.Cfg memory) internal returns (bool, uint256) => takeAsked();

    // the custodian, title and keeper calls, by selector; NO `unresolved` catch-all (see HubCoverage.spec)
    function _.mint(uint256, address) external => NONDET;
    function _.pull(uint256, address, uint256) external => NONDET;
    function _.release(uint256, address, uint256) external => NONDET;
    function _.retireCustody(uint256, uint256) external => NONDET;
    function _.onAceDeleverage(uint256, uint256, bytes) external => NONDET;

    function closedAtOf(uint256) external returns (uint64) envfree; // AceHarness
    function loanMarket(uint256) external returns (bytes32) envfree;
    function marketQuoteOf(bytes32) external returns (address) envfree; // AceHarness
    function loanUnitsOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanDebtOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanClaimOf(uint256) external returns (uint256) envfree; // AceHarness
    function loanExpiryOf(uint256) external returns (uint64) envfree; // AceHarness
    function loanBorrowerOf(uint256) external returns (address) envfree; // AceHarness
    function loanPotOf(uint256) external returns (uint256) envfree; // AceHarness
    function unitsOwedOf(uint256, address) external returns (uint256) envfree; // AceHarness
    function protocolRevenueOf(address) external returns (uint256) envfree; // AceHarness: one quote's pot
    function marketRailsOf(bytes32) external returns (uint256, uint256, uint256) envfree; // AceHarness
    function marketMinPrincipalOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketSettleBountyBpsOf(bytes32) external returns (uint256) envfree; // AceHarness
    function marketDeleverageOf(bytes32) external returns (uint256, uint256, uint256, uint256, uint256) envfree; // HubCoverageHarness
    function marketRecordOf(bytes32) external returns (address) envfree; // HubCoverageHarness
}

persistent ghost bool takeOk;
persistent ghost uint256 takeWord;

// the crank's price ghosts move with it: the crank rules read the one price it sized, billed and gated at
function takeAsked() returns (bool, uint256) {
    bool ok; uint256 w;
    takeOk = ok;
    takeWord = w;
    priceAsks = priceAsks + 1;
    priceSeen = w;
    return (ok, w);
}

function mulDivDownExact(uint256 a, uint256 b, uint256 d) returns uint256 {
    require d != 0;
    mathint r = (a * b) / d;
    require r <= max_uint256;
    return require_uint256(r);
}

persistent ghost mathint priceAsks;
persistent ghost uint256 priceSeen;

function priceAsked() returns uint256 {
    uint256 p;
    priceAsks = priceAsks + 1;
    priceSeen = p;
    return p;
}

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

definition S() returns mathint = 2^96;
definition aRealClock(env e) returns bool = e.block.timestamp > 0 && e.block.timestamp < 2^64;

function railsHold(bytes32 m) returns bool {
    uint256 cover; uint256 scale; uint256 price;
    cover, scale, price = marketRailsOf(m);
    return cover >= 105 * 10^16 && cover <= 20 * 10^18 && scale == 2^96 && price > 0 && price <= 2^224
        && marketMinPrincipalOf(m) >= 2 && marketMinPrincipalOf(m) <= max_uint128 && marketSettleBountyBpsOf(m) <= 200;
}

// a live loan in a created market under its rails, carrying its debt as its claim, acted on from outside the hub
function liveLoanPremises(env e, uint256 id) {
    require e.msg.sender != currentContract && aRealClock(e);
    require loanMarket(id) != to_bytes32(0) && closedAtOf(id) == 0 && marketQuoteOf(loanMarket(id)) != 0;
    // PROVEN IN HubClaims.spec (its `mulDiv` is the uninterpreted one, so it cannot be imported here):
    // `aCreatedMarketKeepsItsRails` with HubCoverage.spec's `aCreatedMarketKeepsItsBountyRail`, and O10.
    require railsHold(loanMarket(id));
    require loanClaimOf(id) == loanDebtOf(id) && loanDebtOf(id) > 0;
}

function crankPremises(env e, uint256 id) {
    liveLoanPremises(e, id);
    require priceAsks == 0;
}

// the keeper's eps and the protocol cut of a market
function epsOf(bytes32 m) returns mathint {
    uint256 eps; uint256 band; uint256 target; uint256 stop; uint256 cb;
    eps, band, target, stop, cb = marketDeleverageOf(m);
    return eps;
}

function cutBpsOf(bytes32 m) returns mathint {
    uint256 eps; uint256 band; uint256 target; uint256 stop; uint256 cb;
    eps, band, target, stop, cb = marketDeleverageOf(m);
    return cb;
}

function stopBpsOf(bytes32 m) returns mathint {
    uint256 eps; uint256 band; uint256 target; uint256 stop; uint256 cb;
    eps, band, target, stop, cb = marketDeleverageOf(m);
    return stop;
}

// ---- the keeper's bill ----

// A crank that leaves the loan live: what the keeper paid (the debt it melted plus the cut it took) is the ceiled floor
// bill of the units it took, to the atom, and the cut is the floor of its share of that bill or nothing.
rule aRestoringCrankPaysTheFloorBill(env e, uint256 id, uint256 minStableOut, bytes data) {
    crankPremises(e, id);
    bytes32 m = loanMarket(id);
    mathint eps = epsOf(m);
    mathint cb = cutBpsOf(m);
    mathint u0 = loanUnitsOf(id);
    mathint d0 = loanDebtOf(id);
    address q = marketQuoteOf(m);
    mathint r0 = protocolRevenueOf(q);
    deleverage(e, id, minStableOut, data);
    require closedAtOf(id) == 0; // the restore path
    mathint sold = u0 - loanUnitsOf(id);
    mathint taken = protocolRevenueOf(q) - r0;
    mathint paid = (d0 - loanDebtOf(id)) + taken;
    mathint exact = priceSeen * sold * (10000 - eps);
    assert sold > 0 => priceAsks == 1, "a crank sold without one record read";
    assert paid * 10000 * S() >= exact, "a crank melted less than the floor bill of what it took";
    assert (paid - 1) * 10000 * S() < exact, "a crank melted a whole atom or more past the floor bill";
    assert taken == 0 || (taken * 10000 <= paid * cb && (taken + 1) * 10000 > paid * cb), "the cut is not the floor of its share of the bill";
}

// A crank that closes the loan sold the FEWEST units whose ceiled bill covers the whole debt, and nothing else; the units
// it did not sell are the borrower's. `bill(sold) >= D` and `bill(sold - 1) < D`, on the record price it read.
rule aClosingCrankSellsTheSmallestLotThatPaysTheDebt(env e, uint256 id, uint256 minStableOut, bytes data) {
    crankPremises(e, id);
    bytes32 m = loanMarket(id);
    address b = loanBorrowerOf(id);
    mathint eps = epsOf(m);
    mathint u0 = loanUnitsOf(id);
    mathint d0 = loanDebtOf(id);
    mathint owed0 = unitsOwedOf(id, b);
    deleverage(e, id, minStableOut, data);
    require closedAtOf(id) != 0; // the close path
    mathint sold = u0 - (unitsOwedOf(id, b) - owed0);
    assert priceAsks == 1, "a crank closed without one record read";
    assert loanUnitsOf(id) == 0 && loanDebtOf(id) == 0, "a closing crank left units or debt on the loan";
    assert priceSeen * sold * (10000 - eps) > (d0 - 1) * 10000 * S(), "the closing sale's bill falls short of the debt";
    assert priceSeen * (sold - 1) * (10000 - eps) <= (d0 - 1) * 10000 * S(), "the closing sale sold a unit more than the debt needed";
}

// ---- O15's gate ----

// Any crank that sold, restoring or closing, read the record once and sold at a price strictly over the trigger's stop
// level, `ceil(trig * 1e18 / (1e18 - stop * 1e14))`, with `trig` the loan's own ceiled trigger going in.
rule aCrankSellsOnlyAboveTheStop(env e, uint256 id, uint256 minStableOut, bytes data) {
    crankPremises(e, id);
    bytes32 m = loanMarket(id);
    uint256 k; uint256 s; uint256 p;
    k, s, p = marketRailsOf(m);
    mathint stop = stopBpsOf(m);
    mathint u0 = loanUnitsOf(id);
    mathint d0 = loanDebtOf(id);
    deleverage(e, id, minStableOut, data);
    bool sold = closedAtOf(id) != 0 || to_mathint(loanUnitsOf(id)) < u0;
    mathint trig0 = u0 == 0 ? 0 : (k * d0 * S() + u0 * 10^18 - 1) / (u0 * 10^18);
    mathint q = 10^18 - stop * 10^14;
    assert sold => priceAsks == 1, "a crank sold without one record read";
    assert sold => q > 0 && to_mathint(priceSeen) > (trig0 * 10^18 + q - 1) / q, "a crank sold at or under the trigger's stop level";
}

// ---- settlement's split ----

// O50: settlement splits the lot exactly. The keeper's sliver is `min(floor(debt * bps * S / (1e4 * price)), lot)`; the
// lender's pot takes at least the claim's need `ceil(claim * S / price)` or all the lot past the sliver can pay. With a
// record it takes exactly the ruled take capped at the lot past the sliver. Band on, the claim at the record's price,
// ceiled, never under the need, at either door (#944, #945). Band off, inside the term the claim at the trigger,
// ceil(lot * 1e18 / k), held between the need and the coverage line the settlement asked on the loan's own dials and
// debt (RECORDED; its value is CoverageMath.spec's `theCoverageLineIsRequiredPlusOne`); from the expiry second the need.
// The borrower is credited the rest. Nothing is lost or minted, whoever the keeper is.
// PROVEN directly on the deep split once storage splitting was on (the munge cuts the hub's `extsload` views). Before
// that it was UNKNOWN even at 8 h. The composition still stands beside it: HubCoverage.spec
// `aSettlementConservesTheLot` and `aSettlementPaysTheSliverAndTheNeed` hold for every value of an unconstrained `mulDiv`,
// and CoverageMath.spec `theFloorsAndCeilsBindBothWays`, `theNeedIsTheClaimCeiled` and `theSliverIsTheDebtBountyFloored`
// give their values under the floor.
// SPLIT four ways, band off or on by door, so each solves alone: the band-on take divides by a second free price,
// and the one rule over both was UNKNOWN at 8 h on the deep split. The four together are the old rule's whole domain.
rule aSettlementSplitsTheLotBandOffViaFinalize(env e, uint256 id) { settlementSplits(e, id, true, false); }
rule aSettlementSplitsTheLotBandOffViaForceClose(env e, uint256 id) { settlementSplits(e, id, false, false); }
rule aSettlementSplitsTheLotBandOnViaFinalize(env e, uint256 id) { settlementSplits(e, id, true, true); }
rule aSettlementSplitsTheLotBandOnViaForceClose(env e, uint256 id) { settlementSplits(e, id, false, true); }

function settlementSplits(env e, uint256 id, bool viaFinalize, bool bandOn) {
    liveLoanPremises(e, id);
    bytes32 m = loanMarket(id);
    address b = loanBorrowerOf(id);
    address keeper = e.msg.sender;
    uint256 k; uint256 s; uint256 p;
    k, s, p = marketRailsOf(m);
    mathint bps = marketSettleBountyBpsOf(m);
    mathint u0 = loanUnitsOf(id);
    mathint d0 = loanDebtOf(id);
    mathint exp0 = loanExpiryOf(id);
    mathint pot0 = loanPotOf(id);
    mathint owedB0 = unitsOwedOf(id, b);
    mathint owedK0 = unitsOwedOf(id, keeper);
    mathint asks0 = covAsks;
    uint256 eps; uint256 band; uint256 target; uint256 stop; uint256 cut;
    eps, band, target, stop, cut = marketDeleverageOf(m);
    require bandOn == (band != 0);
    if (viaFinalize) {
        finalize(e, id);
    } else {
        forceClose(e, id);
    }
    mathint dPot = loanPotOf(id) - pot0;
    mathint dB = unitsOwedOf(id, b) - owedB0;
    mathint dK = unitsOwedOf(id, keeper) - owedK0;
    mathint need = (d0 * S() + p - 1) / p;
    mathint bounty = (d0 * bps * S()) / (10000 * p);
    mathint sliver = bounty < u0 ? bounty : u0;
    mathint afterSliver = u0 - sliver;
    bool inTerm = e.block.timestamp < exp0;
    // each variant encodes only its own take: a ternary still hands the solver the other branch's division
    mathint take;
    if (bandOn) {
        // band on (#944, #945): the claim (the debt, O10) at the recorded price, ceiled; a word-overflowing claim takes the lot
        bool priced = marketRecordOf(m) != 0 && takeOk && takeWord != 0;
        mathint atRecord = takeWord == 0 ? 0 : (to_mathint(takeWord) <= (d0 * S()) / max_uint256 ? max_uint256 : (d0 * S() + takeWord - 1) / takeWord);
        take = priced ? (atRecord > need ? atRecord : need) : need;
    } else {
        mathint atTrigger = (u0 * 10^18 + k - 1) / k;
        mathint capped = atTrigger < to_mathint(covLine) ? atTrigger : to_mathint(covLine);
        take = inTerm ? (capped > need ? capped : need) : need;
    }
    assert marketRecordOf(m) != 0 && inTerm && band == 0 =>
        covAsks > asks0 && covK == k && to_mathint(covS) == S() && to_mathint(covDebt) == d0 && covPrice <= p,
        "a band-off record-backed settlement inside the term did not cap at the coverage line of the loan's own dials and debt";
    assert band != 0 && marketRecordOf(m) != 0 && (!takeOk || takeWord == 0) => !inTerm,
        "a band-on settlement moved value inside the term on a dark record";
    assert closedAtOf(id) != 0 && loanUnitsOf(id) == 0, "settlement left the loan live or holding units";
    assert keeper != b => dPot + dB + dK == u0, "settlement lost or minted units";
    assert keeper == b => dPot + dB == u0, "settlement lost or minted units";
    assert keeper != b => dK == sliver, "the keeper's sliver is not its bounty at the funding floor, capped at the lot";
    assert dPot >= (need < afterSliver ? need : afterSliver), "the lender's pot took less than the need the lot could pay";
    assert dPot <= afterSliver, "the lender's pot ate into the keeper's sliver";
    assert marketRecordOf(m) != 0 => dPot == (take < afterSliver ? take : afterSliver), "a record-backed settlement's pot is not min(the ruled take, lot past the sliver)";
}

// ---- witnesses: each path the rules above restrict to is reachable under the same premises ----

rule aCrankCanRestore(env e, uint256 id, uint256 minStableOut, bytes data) {
    crankPremises(e, id);
    mathint u0 = loanUnitsOf(id);
    deleverage(e, id, minStableOut, data);
    satisfy closedAtOf(id) == 0 && to_mathint(loanUnitsOf(id)) < u0;
}

rule aCrankCanClose(env e, uint256 id, uint256 minStableOut, bytes data) {
    crankPremises(e, id);
    deleverage(e, id, minStableOut, data);
    satisfy closedAtOf(id) != 0;
}

rule aSettlementCanPayASliver(env e, uint256 id) {
    liveLoanPremises(e, id);
    address keeper = e.msg.sender;
    require keeper != loanBorrowerOf(id);
    mathint owedK0 = unitsOwedOf(id, keeper);
    forceClose(e, id);
    satisfy unitsOwedOf(id, keeper) > owedK0;
}
