// `SAeroStakeReceipt`'s own gates: the checks a frozen clone holds against its door, which is upgradeable, and the
// order its state may take. `SaeroReceipt.spec` proves what the payouts pay; this spec proves who may move the receipt
// and what each verb must have read first. Same scene, same mocks, same munge (`confs/SaeroReceiptGates.conf`).
//   G1  `seize`: only DOOR, only Holding, only a dead loan whose market pledges this receipt, only with units burned to
//       the door, and D nonzero and at most `bookValue(doorBurned, that market's price)` (the OverBook bound);
//   G2  `repayFromRewards`: only a live loan that pledges this receipt, and no other loan's debt moves;
//   G3  the state machine: None -> Holding by `mint`, Holding -> Seized by `seize`, Seized -> Sold by `settle` or `sweep`,
//       and nothing else; past None only DOOR moves it; `owner` is written only by `seize`, as the portfolio's owner
//       read then; `swept` only by `sweep`; the row only by `record`, as the marketplace's listing read back;
//   G4  `draw`: only PORTFOLIO, only Holding, only a live loan pledging this receipt; it pays PORTFOLIO alone, the
//       lesser of the cash here and the hub's quoted fee when the hub admits the roll, else nothing;
//   G5  the sale proof, AS IT IS: `settle` lands exactly when the recorded row has gone, custody no longer holds the
//       stake for this receipt, and the cash here has risen by at least `saleNet(rowPrice)` since the seizure. The proof
//       reads a balance, so ANY inflow after the seizure counts toward it. That is recorded here as behaviour, not
//       judged: the cash still pays D first (`SaeroReceipt.spec` R1), and the ruling on it is owed. A stake that left
//       custody unsold can always be swept, while the row price is at most `max / 1000`; past it, both payout doors
//       panic in `saleNet` for good, also recorded as it is, with its ruling owed.
// Each group carries a `satisfy` witness beside `rule_sanity: basic`.
//
// THE MODEL IS `SaeroReceipt.spec`'s, and its header argues each choice: the munged `_args()`, the linked DummyERC20,
// the free-storage mocks for the hub, the door and the 40 Acres reads, and the DISPATCH of every unresolved call by
// callee and selector. One stated consequence matters here: the mocks answer every 40 Acres read with one clean word,
// so the escrow's holder, custody's map and the marketplace's row are each KNOWN in every rule below. The receipt's
// handling of a reverting, short or dirty answer is not covered by G5.
using DummyERC20 as cash;
using MockReceiptHub as hub;
using MockReceiptDoor as door;
using MockPortfolioOwners as owners;
using MockSeizedCustody as custody;
using MockListings as listings;
using MockStakeEscrow as escrow;

methods {
    function PORTFOLIO() external returns (address) envfree;
    function STAKE_ID() external returns (uint256) envfree;
    function UNITS() external returns (uint256) envfree;
    function state() external returns (SAeroStakeReceipt.State) envfree;
    function owner() external returns (address) envfree;
    function swept() external returns (bool) envfree;
    function seizedAt() external returns (uint64) envfree;
    function doorBurned() external returns (uint256) envfree;
    function seniorDebt() external returns (uint256) envfree;
    function lenderFee() external returns (uint256) envfree;
    function cashAtSeizure() external returns (uint256) envfree;
    function rowPrice() external returns (uint256) envfree;
    function rowNonce() external returns (uint256) envfree;
    function FACTORY() external returns (address) envfree;
    function DOOR() external returns (address) envfree;
    function CUSTODY() external returns (address) envfree;
    function CASH() external returns (address) envfree;
    function notEntered() external returns (bool) envfree;

    function DummyERC20.balanceOf(address) external returns (uint256) envfree;
    function MockReceiptHub.debtView(uint256) external returns (uint256) envfree;
    function MockReceiptHub.liveView(uint256) external returns (bool) envfree;
    function MockReceiptHub.collateralOfLoan(uint256) external returns (address) envfree;
    function MockReceiptHub.priceOfLoan(uint256) external returns (uint256) envfree;
    function MockReceiptHub.extendOkView(uint256) external returns (bool) envfree;
    function MockReceiptHub.extendFeeView(uint256) external returns (uint256) envfree;
    function MockPortfolioOwners.ownerView(address) external returns (address) envfree;
    function MockSeizedCustody.receiptOf(uint256) external returns (address) envfree;
    function MockListings.getListing(uint256) external returns (IFortyAcresMarketplace.Listing) envfree;
    function MockStakeEscrow.ownerOf(uint256) external returns (address) envfree;

    // as in `SaeroReceipt.spec`: OZ's `mulDiv`, the seizure's fee, is its documented exact floor
    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivFloor(x, y, d);

    // as in `SaeroReceipt.spec`: every unresolved call reaches the mock at its callee, and any other callee is NONDET
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

// `Math.mulDiv`'s contract, as in `SaeroReceipt.spec`; the receipt's one call divides by the constant 10000
function mulDivFloor(uint256 x, uint256 y, uint256 d) returns uint256 {
    require d != 0;
    return require_uint256((to_mathint(x) * to_mathint(y)) / to_mathint(d));
}

definition NONE() returns SAeroStakeReceipt.State = SAeroStakeReceipt.State.None;
definition HOLDING() returns SAeroStakeReceipt.State = SAeroStakeReceipt.State.Holding;
definition SEIZED() returns SAeroStakeReceipt.State = SAeroStakeReceipt.State.Seized;
definition SOLD() returns SAeroStakeReceipt.State = SAeroStakeReceipt.State.Sold;

definition min(mathint a, mathint b) returns mathint = a < b ? a : b;

// the receipt's `saleNet`: the price less the 40 Acres fee at its 1000 bps cap, the fee floored
definition saleNetOf(mathint p) returns mathint = p - (p * 1000) / 10000;

definition isDoorVerb(method f) returns bool =
    f.selector == sig:seize(uint256, uint256).selector || f.selector == sig:record(uint256, uint64).selector
    || f.selector == sig:settle().selector || f.selector == sig:sweep().selector;

// custody may hold the stake for this receipt: the escrow names custody, and custody maps the stake here
function custodyHoldsHere() returns bool {
    uint256 id = STAKE_ID();
    return escrow.ownerOf(id) == CUSTODY() && custody.receiptOf(id) == currentContract;
}

// the recorded row still stands: a row was recorded, and the marketplace's row is custody's at the recorded nonce
function rowStands() returns bool {
    IFortyAcresMarketplace.Listing l = listings.getListing(STAKE_ID());
    return rowPrice() != 0 && l.owner == CUSTODY() && l.nonce == rowNonce();
}

// ---- G1: the seizure ----

// ONLY DOOR SEIZES, ONLY A HOLDING RECEIPT, ONLY AGAINST A DEAD LOAN WHOSE MARKET PLEDGES THIS RECEIPT, ONLY WITH UNITS
// BURNED TO THE DOOR, AND D IS AT MOST THE DOOR'S BURNED UNITS AT THAT MARKET'S PRICE. `bookValue` saturates where
// `pot * price` passes a word, so there the bound is a word's worth: the disjunct states the code's bound exactly. At
// the hub's price ceiling (2^224) that needs a pot past 2^32 atoms at a price no sAERO market quotes.
rule aSeizureIsGated(env e, uint256 loanId, uint256 debt) {
    SAeroStakeReceipt.State s0 = state();
    mathint pot = doorBurned();
    bool live = hub.liveView(loanId);
    address coll = hub.collateralOfLoan(loanId);
    mathint price = hub.priceOfLoan(loanId);

    seize@withrevert(e, loanId, debt);
    bool ok = !lastReverted;

    assert ok => e.msg.sender == DOOR(), "a caller other than the door seized";
    assert ok => s0 == HOLDING(), "a receipt that was not Holding was seized";
    assert ok => coll == currentContract, "the seizure named a loan whose market does not pledge this receipt";
    assert ok => !live, "the seizure named a live loan";
    assert ok => pot > 0 && debt > 0, "a seizure took a zero claim, or no unit had burned to the door";
    assert ok => (pot * price > max_uint256 || to_mathint(debt) * 2 ^ 96 <= pot * price),
        "the claim exceeds the door's burned units at the market's price";
}

// THE SEIZURE RECORDS THE PORTFOLIO'S OWNER AS 40 ACRES NAMES IT THEN, THE CLOCK, AND THE CASH HERE AS THE BASELINE
rule aSeizureRecordsTheOwnerTheClockAndTheBaseline(env e, uint256 loanId, uint256 debt) {
    require e.block.timestamp <= max_uint64;
    seize(e, loanId, debt);
    assert owner() == owners.ownerView(PORTFOLIO()), "the seizure recorded an owner other than the portfolio's";
    assert to_mathint(seizedAt()) == to_mathint(e.block.timestamp), "the seizure recorded another second";
    assert cashAtSeizure() == cash.balanceOf(currentContract), "the seizure's baseline is not the cash here";
}

// and the bound is tight: a seizure at exactly the book value of the door's pot lands
rule witnessASeizureAtTheBook(env e, uint256 loanId, uint256 debt) {
    mathint book = (to_mathint(doorBurned()) * to_mathint(hub.priceOfLoan(loanId))) / 2 ^ 96;
    seize(e, loanId, debt);
    satisfy debt > 0 && to_mathint(debt) == book;
}

// ---- G2: the reward repay ----

// THE REPAY REPAYS ONLY A LIVE LOAN WHOSE MARKET PLEDGES THIS RECEIPT, AND MOVES NO OTHER LOAN'S DEBT
rule aRewardRepayRepaysOnlyALiveLoanThatPledgesThisReceipt(env e, uint256 loanId, uint256 maxAmount, uint256 minDebtAfter, uint256 other) {
    require other != loanId;
    bool live = hub.liveView(loanId);
    address coll = hub.collateralOfLoan(loanId);
    mathint otherDebt = hub.debtView(other);

    repayFromRewards@withrevert(e, loanId, maxAmount, minDebtAfter);
    bool ok = !lastReverted;

    assert ok => coll == currentContract, "a repay reached a loan whose market does not pledge this receipt";
    assert ok => live, "a repay reached a loan that is not live";
    assert ok => to_mathint(hub.debtView(other)) == otherDebt, "a repay moved another loan's debt";
}

rule witnessARewardRepayLands(env e, uint256 loanId, uint256 maxAmount, uint256 minDebtAfter) {
    uint256 paid = repayFromRewards(e, loanId, maxAmount, minDebtAfter);
    satisfy paid > 0;
}

// ---- G3: the state machine ----

// THE STATE ONLY ADVANCES, ONE STEP, EACH BY ITS OWN VERB: mint, seize, then settle or sweep
rule theStateOnlyAdvances(method f, env e, calldataarg args) {
    SAeroStakeReceipt.State s0 = state();
    f(e, args);
    SAeroStakeReceipt.State s1 = state();
    assert s1 == s0
        || (s0 == NONE() && s1 == HOLDING() && f.selector == sig:mint().selector)
        || (s0 == HOLDING() && s1 == SEIZED() && f.selector == sig:seize(uint256, uint256).selector)
        || (s0 == SEIZED() && s1 == SOLD() && (f.selector == sig:settle().selector || f.selector == sig:sweep().selector)),
        "the state moved other than one step forward by its own verb";
}

// PAST None, ONLY THE DOOR MOVES THE STATE; the one step before it is the factory's mint
rule onlyTheDoorMovesTheState(method f, env e, calldataarg args) {
    SAeroStakeReceipt.State s0 = state();
    f(e, args);
    assert state() != s0 => (e.msg.sender == DOOR() || (s0 == NONE() && e.msg.sender == FACTORY())),
        "a caller other than the door, or the factory at the mint, moved the state";
}

// THE FOUR DOOR VERBS REFUSE EVERY OTHER CALLER
rule onlyTheDoorSeizesRecordsSettlesOrSweeps(method f, env e, calldataarg args) filtered { f -> isDoorVerb(f) } {
    f@withrevert(e, args);
    assert !lastReverted => e.msg.sender == DOOR(), "a door verb took a caller other than the door";
}

// `owner` IS WRITTEN ONLY BY THE SEIZURE
rule onlySeizeWritesTheOwner(method f, env e, calldataarg args) {
    address o0 = owner();
    f(e, args);
    assert owner() != o0 => f.selector == sig:seize(uint256, uint256).selector, "something other than seize wrote the owner";
}

// `swept` IS SET ONLY BY THE SWEEP, AND NEVER CLEARED
rule onlySweepSetsSwept(method f, env e, calldataarg args) {
    bool s0 = swept();
    f(e, args);
    assert swept() != s0 => (f.selector == sig:sweep().selector && swept()), "something other than sweep moved swept";
}

// THE ROW IS WRITTEN ONLY BY `record`
rule onlyRecordWritesTheRow(method f, env e, calldataarg args) {
    uint256 p0 = rowPrice();
    uint256 n0 = rowNonce();
    f(e, args);
    assert (rowPrice() != p0 || rowNonce() != n0) => f.selector == sig:record(uint256, uint64).selector,
        "something other than record wrote the row";
}

// AND `record` WRITES ONLY WHAT IT READ BACK: custody's listing of this stake, at the price named, in the vault's asset,
// open to any buyer, expiring when named; the nonce is the marketplace's. Only while Seized.
rule aRecordWritesTheRowItReadsBack(env e, uint256 price, uint64 expiresAt) {
    uint256 id = STAKE_ID();
    IFortyAcresMarketplace.Listing l = listings.getListing(id);
    record(e, price, expiresAt);
    assert state() == SEIZED(), "a receipt that was not Seized recorded a row";
    assert price != 0 && rowPrice() == price && rowNonce() == l.nonce, "the row is not the price named at the listing's nonce";
    assert l.owner == CUSTODY() && l.tokenId == id && l.price == price, "the row recorded is not custody's listing of this stake at that price";
    assert l.paymentToken == CASH() && to_mathint(l.expiresAt) == to_mathint(expiresAt) && l.allowedBuyer == 0,
        "the row recorded is not in the vault's asset, open to all, expiring when named";
}

rule witnessARecordLands(env e, uint256 price, uint64 expiresAt) {
    record(e, price, expiresAt);
    satisfy rowPrice() == price;
}

// ---- G4: the draw ----

// ONLY PORTFOLIO DRAWS, ONLY WHILE HOLDING, ONLY AGAINST A LIVE LOAN PLEDGING THIS RECEIPT
rule aDrawIsGated(env e, uint256 loanId) {
    SAeroStakeReceipt.State s0 = state();
    bool live = hub.liveView(loanId);
    address coll = hub.collateralOfLoan(loanId);
    draw@withrevert(e, loanId);
    bool ok = !lastReverted;
    assert ok => e.msg.sender == PORTFOLIO(), "a caller other than the portfolio drew";
    assert ok => s0 == HOLDING(), "a receipt that was not Holding paid a draw";
    assert ok => (live && coll == currentContract), "a draw named a loan that is not live or does not pledge this receipt";
}

// THE DRAW PAYS PORTFOLIO ALONE, EXACTLY min(cash, the hub's fee) WHEN THE HUB ADMITS THE ROLL, ELSE NOTHING
rule aDrawPaysThePortfolioAtMostTheQuotedFee(env e, uint256 loanId, address x) {
    address p = PORTFOLIO();
    require p != currentContract;
    require x != p && x != currentContract;
    mathint fee = hub.extendFeeView(loanId);
    bool admits = hub.extendOkView(loanId);
    mathint b0 = cash.balanceOf(currentContract);
    mathint p0 = cash.balanceOf(p);
    mathint x0 = cash.balanceOf(x);

    uint256 paid = draw(e, loanId);

    assert to_mathint(paid) == (admits ? min(b0, fee) : 0), "the draw paid other than min(cash, the quoted fee) of an admitted roll";
    assert b0 - cash.balanceOf(currentContract) == to_mathint(paid), "the receipt's cash fell by other than the draw";
    assert cash.balanceOf(p) - p0 == to_mathint(paid), "the portfolio did not gain exactly the draw";
    assert to_mathint(cash.balanceOf(x)) == x0, "a draw moved a third address's cash";
}

rule witnessADrawPays(env e, uint256 loanId) {
    uint256 paid = draw(e, loanId);
    satisfy paid > 0;
}

// ---- G5: the sale proof, as it is ----

// `settle` NEEDS THE WHOLE PROOF: the door, Seized, a recorded row no longer standing, custody not holding the stake
// for this receipt, and cash here at least `saleNet(rowPrice)` above the seizure's baseline.
rule settleNeedsTheSaleProof(env e) {
    SAeroStakeReceipt.State s0 = state();
    mathint bal = cash.balanceOf(currentContract);
    mathint base = cashAtSeizure();
    mathint rp = rowPrice();
    bool stands = rowStands();
    bool holds = custodyHoldsHere();

    settle@withrevert(e);
    bool ok = !lastReverted;

    assert ok => (e.msg.sender == DOOR() && s0 == SEIZED()), "settle took a caller other than the door, or a receipt not Seized";
    assert ok => (rp != 0 && !stands && !holds), "settle booked a sale with no row, a standing row, or the stake in custody";
    assert ok => bal - base >= saleNetOf(rp), "settle booked a sale on less new cash than the row's net";
}

// AND THE PROOF IS ONLY THAT: given it, `settle` lands, whoever sent the cash. The model's cash has no source, so this
// rule is the record that a donation, a late reward or any other inflow of `saleNet(rowPrice)` after the seizure books
// a sale exactly as a sale's proceeds would. Ruling owed; see the findings file. A row price past `max / 1000` is held
// out: `saleNet` multiplies it by the fee cap, and that product panics in `settle` and `sweep` alike.
rule anyInflowPastTheSeizureProvesTheSale(env e) {
    require e.msg.value == 0 && notEntered(); // not payable; a transaction starts with the guard clear
    require e.msg.sender == DOOR();
    require state() == SEIZED();
    mathint bal = cash.balanceOf(currentContract);
    mathint rp = rowPrice();
    require rp != 0 && rp <= max_uint256 / 1000;
    require !rowStands() && !custodyHoldsHere();
    require bal - cashAtSeizure() >= saleNetOf(rp);
    require cash.balanceOf(DOOR()) + bal <= max_uint256;

    settle@withrevert(e);

    assert !lastReverted, "settle refused a sale the proof shows";
}

rule witnessASettleLands(env e) {
    uint256 due = settle(e);
    satisfy due > 0;
}

// A STAKE THAT LEFT CUSTODY UNSOLD CAN BE SWEPT: the door, Seized, the row gone, custody not holding it here, and no
// sale the cash would prove, and `sweep` lands. Held to a row price at most `max / 1000`, for the reason below.
rule aStakeThatLeftCustodyUnsoldCanBeSwept(env e) {
    require e.msg.value == 0 && notEntered(); // not payable; a transaction starts with the guard clear
    require e.msg.sender == DOOR();
    require state() == SEIZED();
    mathint bal = cash.balanceOf(currentContract);
    mathint rp = rowPrice();
    require rp <= max_uint256 / 1000;
    require !rowStands() && !custodyHoldsHere();
    require rp == 0 || bal - cashAtSeizure() < saleNetOf(rp);
    require cash.balanceOf(DOOR()) + bal <= max_uint256;

    sweep@withrevert(e);

    assert !lastReverted, "sweep refused a stake that left custody unsold";
}

// AND PAST IT, NEITHER PAYOUT DOOR EVER OPENS. Once the row is gone and custody no longer holds the stake here, both
// `settle` and `sweep` evaluate `saleNet(rowPrice)`, whose `price * 1000` panics past `max / 1000`. Only a fresh
// `record` resets the row, and `record` reads custody's listing of the stake, which custody cannot make once the stake
// has left it. So a row recorded at such a price, then a stake leaving custody unsold, strands the receipt in Seized
// with its cash. A record of the code as it is, carried as an assertion so a fix turns it red; see the findings file.
rule aRowPricedPastTheFeeProductStrandsTheReceipt(env e, bool viaSweep) {
    require e.msg.sender == DOOR();
    require state() == SEIZED();
    require to_mathint(rowPrice()) > max_uint256 / 1000;
    require !rowStands() && !custodyHoldsHere();

    if (viaSweep) {
        sweep@withrevert(e);
    } else {
        settle@withrevert(e);
    }

    assert lastReverted, "a payout door opened on a row priced past the fee product";
}

// and the receipt's own `record` admits such a row: it refuses only a zero price and a row that does not read back
rule witnessARecordStoresARowPricedPastTheFeeProduct(env e, uint256 price, uint64 expiresAt) {
    require to_mathint(price) > max_uint256 / 1000;
    record(e, price, expiresAt);
    satisfy rowPrice() == price;
}
