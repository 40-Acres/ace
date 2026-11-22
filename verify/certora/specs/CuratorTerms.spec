// `CuratorTerms`, the curated AceVault's terms and, in door mode, its door. `TERMS` is write-once in its vault, so this
// contract is the curator's whole trust boundary: the collateral table, the price every loan opens at, the room, the
// hooks, and the sale of seized goods. Five groups:
//   T  the table: a live row changes only at an accept of its own pending row after the timelock; only the curator
//      submits, the curator or the guardian revokes; every row sits inside the rails `_checkRow` enforces;
//   H  the hooks and the vault's questions: only the vault calls `beforeLend`/`afterLend`, `beforeLend` admits exactly
//      its own vault, `admitsExtension` answers exactly the row and record legs, a refinance is priced on the row at or
//      under the buffered minimum;
//   P  the price: the record's windowed minimum less the row's buffer, gridded down, on the market these terms build;
//      a borrow refuses exactly when the collateral is unlisted or the gridded price is zero;
//   D  the door: only the curator sells; a sale never clears under the floor while the key is open (the 20% discount,
//      raised to the lesser of the units' booked share and their record value), and one at or over it lands; the cash
//      goes to the vault against the item and nowhere else; the floor's record is
//      the one the latest collect pinned, and nothing else moves it; stray cash forwards under the asset's key;
//   R  the room: the vault's cap less what is lent and the unsold pots held at the market record's minimum.
//
// The door group's sale callback is `IDoorSaleCallback.onDoorSale`.
//
// WHAT IS MODELLED, AND WHY EACH ADMITS EVERY REAL BEHAVIOUR THE RULES NEED.
// THE TERMS are `CuratorTermsHarness`, which adds one view and no state: whether the transient guard is entered.
// THE VAULT is `MockCuratedVault`, LINKED to `VAULT`: its keys, door, copies, caps and raw slots are free storage, its
// collect reports free units per id, and its `returnProceeds` pulls the named cash from the caller. It enforces none of
// the real vault's door checks, so every rule reads the terms' own checks alone. Its seized ledger is read at the slot
// the vault's layout gives (`ROOT + 9`, open flag at bit 248), spelled in the mock, never through the terms' code.
// THE HUB is `MockCuratedHub`, LINKED to `ACE`: free storage keyed by every argument, so a swapped argument reads
// another answer. THE RECORD is `MockPairRecord`, keyed by the ORDERED pair for the same reason; a row, a market or a
// pin naming any other address gets the default below, so a priced rule names the mock as its record.
// THE ASSET is `DummyERC20`, LINKED to `ASSET`: exact transfers, no hooks, the asset the vault requires. THE GOODS are
// `MockGoods`, its copy under another name. THE BUYER is `MockSaleBuyer` where a rule needs a cooperating buyer: it
// approves a free amount and states a free figure, and records what it was told.
// EVERY UNRESOLVED CALL IS DISPATCHED BY CALLEE: a call to a mock's address runs that mock, and a call anywhere else
// is NONDET, moving nothing and answering anything. So an unresolved call never re-enters, which is a stated premise:
// the curator as buyer could re-enter `submitCollateral`, `accept` or `revokePending` from the callback, each still
// bound by its own checks, and `sell`, `collectForfeited` and `forwardCash` sit under the lock.
// `Math.mulDiv` IS ITS EXACT FLOOR, with its two reverts recorded in ghosts rather than pruned, so a rule that needs the
// real call to succeed states the fit itself. `FullMath.mulDiv`, reached only from `_checkRow`'s fee rail, is NONDET:
// no rule reads that rail's answer, and an arbitrary answer admits every real one. `PriceGrid.down` is a ghost with its
// two documented properties, at or under its argument and zero at zero, as in `SaeroVault.spec`.
//
// THE CONSTRUCTOR IS NEVER RUN, so the immutables are free and the rails it enforces enter as `termsRails`. The row
// rails are proven PRESERVED by every verb; their base case is the constructor's own `_checkRow` over each listing,
// ARGUED, not proven, as for the receipt's invariants.
using DummyERC20 as cash;
using MockGoods as goods;
using MockCuratedVault as vault;
using MockCuratedHub as hub;
using MockPairRecord as record;
using MockSaleBuyer as buyerMock;

methods {
    function VAULT() external returns (address) envfree;
    function ACE() external returns (address) envfree;
    function ASSET() external returns (address) envfree;
    function TIMELOCK() external returns (uint64) envfree;
    function MIN_TENOR() external returns (uint64) envfree;
    function MAX_TENOR() external returns (uint64) envfree;
    function MIN_PRINCIPAL() external returns (uint256) envfree;
    function COVERAGE_WAD() external returns (uint256) envfree;
    function saleRecord(address) external returns (address) envfree;
    function rowOf(address) external returns (CuratorTermsHarness.Row) envfree;
    function pendingRowOf(address) external returns (CuratorTermsHarness.Row, uint64) envfree;
    function entered() external returns (bool) envfree;

    function DummyERC20.balanceOf(address) external returns (uint256) envfree;
    function DummyERC20.allowance(address, address) external returns (uint256) envfree;
    function MockGoods.balanceOf(address) external returns (uint256) envfree;
    function MockCuratedVault.CURATOR() external returns (address) envfree;
    function MockCuratedVault.GUARDIAN() external returns (address) envfree;
    function MockCuratedVault.DOOR() external returns (address) envfree;
    function MockCuratedVault.IN_KIND() external returns (bool) envfree;
    function MockCuratedVault.ACE() external returns (address) envfree;
    function MockCuratedVault.asset() external returns (address) envfree;
    function MockCuratedVault.MIN_TENOR() external returns (uint64) envfree;
    function MockCuratedVault.MAX_TENOR() external returns (uint64) envfree;
    function MockCuratedVault.effectiveCap(address) external returns (uint256) envfree;
    function MockCuratedVault.keyOpenView(address) external returns (bool) envfree;
    function MockCuratedVault.bookedView(address) external returns (uint256) envfree;
    function MockCuratedVault.collectedView(uint256) external returns (uint256) envfree;
    function MockCuratedVault.returnCount() external returns (uint256) envfree;
    function MockCuratedVault.lastKey() external returns (address) envfree;
    function MockCuratedVault.lastCash() external returns (uint256) envfree;
    function MockCuratedVault.lastCloses() external returns (bool) envfree;
    function MockCuratedHub.lenderByCollateral(address, address, address) external returns (uint256, uint256) envfree;
    function MockCuratedHub.collateralOfLoan(uint256) external returns (address) envfree;
    function MockCuratedHub.recordOfLoan(uint256) external returns (address) envfree;
    function MockPairRecord.priceView(address, address) external returns (uint256) envfree;
    function MockSaleBuyer.statedView() external returns (uint256) envfree;
    function MockSaleBuyer.approvedView() external returns (uint256) envfree;
    function MockSaleBuyer.calls() external returns (uint256) envfree;
    function MockSaleBuyer.lastOwed() external returns (uint256) envfree;

    function Math.mulDiv(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivFloor(x, y, d);
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => NONDET;
    function PriceGrid.down(uint256 p) external returns (uint256) => gridDown(p);

    // THE CATCH-ALL BELOW DID NOT REACH THESE THREE, measured on the first run (emv-1): every `minPrice`, `supportsPair`
    // and the first `balanceOf` of `sell` took an AUTO summary, so every priced rule read an arbitrary price. Each is
    // named here with the same address-aware split: a callee equal to a mock runs that mock, any other is havoced.
    function _.minPrice(address, address) external => DISPATCHER(false);
    function _.supportsPair(address, address) external => DISPATCHER(false);
    function _.balanceOf(address) external => DISPATCHER(false);

    unresolved external in _._ => DISPATCH [
        DummyERC20.balanceOf(address),
        DummyERC20.allowance(address, address),
        DummyERC20.transfer(address, uint256),
        DummyERC20.transferFrom(address, address, uint256),
        DummyERC20.approve(address, uint256),
        MockGoods.balanceOf(address),
        MockGoods.transfer(address, uint256),
        MockGoods.transferFrom(address, address, uint256),
        MockGoods.approve(address, uint256),
        MockCuratedVault.CURATOR(),
        MockCuratedVault.GUARDIAN(),
        MockCuratedVault.DOOR(),
        MockCuratedVault.IN_KIND(),
        MockCuratedVault.ACE(),
        MockCuratedVault.asset(),
        MockCuratedVault.MIN_TENOR(),
        MockCuratedVault.MAX_TENOR(),
        MockCuratedVault.effectiveCap(address),
        MockCuratedVault.extsload(bytes32[]),
        MockCuratedVault.collectForfeited(uint256[]),
        MockCuratedVault.returnProceeds(address, uint256, bool),
        MockCuratedHub.lenderByCollateral(address, address, address),
        MockCuratedHub.loanMarket(uint256),
        MockCuratedHub.idToMarketParams(bytes32),
        MockPairRecord.minPrice(address, address),
        MockPairRecord.supportsPair(address, address),
        MockSaleBuyer.onDoorSale(address, uint256, uint256, bytes)
    ] default NONDET;
}

// `down`'s documented contract, and only that: the highest grid price at or under its argument, zero at zero.
ghost gridDown(uint256) returns uint256 {
    axiom forall uint256 p. gridDown(p) <= p;
    axiom gridDown(0) == 0;
}

// OZ `Math.mulDiv`'s two reverts, a zero divisor and a quotient past a uint256, set a flag instead of pruning the path.
ghost bool zeroDenSeen;
ghost bool overflowSeen;

function mulDivFloor(uint256 x, uint256 y, uint256 d) returns uint256 {
    if (d == 0) {
        zeroDenSeen = true;
        return 0;
    }
    mathint r = (to_mathint(x) * to_mathint(y)) / to_mathint(d);
    if (r > max_uint256) {
        overflowSeen = true;
        return 0;
    }
    return require_uint256(r);
}

definition maxOf(mathint a, mathint b) returns mathint = a > b ? a : b;

// the constructor's rails on the immutables: the timelock in [1 day, 14 days], the tenor rail in [1 day, 365 days]
function termsRails() {
    require TIMELOCK() >= 86400 && TIMELOCK() <= 1209600;
    require MIN_TENOR() >= 86400 && MIN_TENOR() <= MAX_TENOR() && MAX_TENOR() <= 31536000;
}

function sameRow(CuratorTermsHarness.Row a, CuratorTermsHarness.Row b) returns bool {
    return a.record == b.record && a.bufferBps == b.bufferBps && a.lenderAprBps == b.lenderAprBps && a.minTenor == b.minTenor && a.maxTenor == b.maxTenor;
}

function isZeroRow(CuratorTermsHarness.Row a) returns bool {
    return a.record == 0 && a.bufferBps == 0 && a.lenderAprBps == 0 && a.minTenor == 0 && a.maxTenor == 0;
}

// `_checkRow`'s stored rails: a record, a buffer under the whole, a rate of at least one bps a year, tenors inside the vault's rail
function inRails(CuratorTermsHarness.Row w) returns bool {
    return w.record != 0 && w.bufferBps < 10000 && w.lenderAprBps >= 1 && w.minTenor >= MIN_TENOR() && w.maxTenor >= w.minTenor
        && w.maxTenor <= MAX_TENOR();
}

// collateral `c`'s table: its live row is none or inside the rails, its pending row is inside them once submitted,
// and the vault's own asset and share never list, nor the zero address
function tableHolds(address c) returns bool {
    CuratorTermsHarness.Row r = rowOf(c);
    CuratorTermsHarness.Row p;
    uint64 v;
    p, v = pendingRowOf(c);
    bool own = c == 0 || c == ASSET() || c == VAULT();
    return (r.record == 0 || (inRails(r) && !own)) && (v != 0 => (inRails(p) && !own));
}

// THE FLOOR THE DOOR RULES, restated from, and
//, for the goods the rules sell: zero unless their key is open; the units' pro-rata share
// of the key's booked value, s = ceil(booked * units / max(units, held)), alone while the pinned record answers zero (the
// share reads no price); past `max / 8000` an unpayable floor; else the discounted d = ceil(units * minPrice * 8000 /
// (10000 * 2^96)), raised to the lesser of s and the units' record value v = ceil(units * minPrice / 2^96). `held` is
// the door's balance before the sale moves it. It reads the key from the vault's layout and the record through the mock,
// so it shares no line with `_floor`. A rule using it names the mock as the goods' pinned record.
function saleFloor(mathint units) returns mathint {
    if (!vault.keyOpenView(goods)) {
        return 0;
    }
    mathint held = goods.balanceOf(currentContract);
    mathint den = units > held ? units : held;
    mathint s = den == 0 ? 0 : (vault.bookedView(goods) * units + den - 1) / den;
    mathint m = record.priceView(cash, goods);
    if (m == 0) {
        return s;
    }
    if (m > max_uint256 / 8000) {
        return max_uint256;
    }
    mathint d = (units * m * 8000 + 2 ^ 96 * 10000 - 1) / (2 ^ 96 * 10000);
    if (d >= s) {
        return d;
    }
    mathint v = (units * m + 2 ^ 96 - 1) / 2 ^ 96;
    return s < v ? s : v;
}

// ---- T: the table ----

// THE TIMELOCK IS THE CURATOR'S WHOLE BOUND ON THE PRICE SOURCE, THE BUFFER, THE RATE AND THE TENORS. Over every verb:
// a live row moves only at an `accept` of that same collateral, after its pending row has waited out the timelock, and
// it lands as exactly that pending row. No verb writes a row directly, and nothing else ever moves one.
rule aRowChangesOnlyAtAnAcceptAfterItsTimelock(env e, method f, calldataarg args, address c) filtered { f -> !f.isView } {
    CuratorTermsHarness.Row r0 = rowOf(c);
    CuratorTermsHarness.Row p0;
    uint64 v0;
    p0, v0 = pendingRowOf(c);

    address k;
    if (f.selector == sig:accept(address).selector) {
        accept(e, k);
    } else {
        f(e, args);
    }

    CuratorTermsHarness.Row r1 = rowOf(c);
    assert !sameRow(r0, r1) => f.selector == sig:accept(address).selector && k == c && v0 != 0 && to_mathint(e.block.timestamp) >= to_mathint(v0)
        && sameRow(r1, p0),
        "a live row moved other than by an accept of its own pending row after the timelock";
}

// An accept lands the pending row whole and clears it, and only from its `validAt`.
rule anAcceptLandsItsPendingRowAndClearsIt(env e, address c) {
    CuratorTermsHarness.Row p0;
    uint64 v0;
    p0, v0 = pendingRowOf(c);

    accept(e, c);

    CuratorTermsHarness.Row r1 = rowOf(c);
    CuratorTermsHarness.Row p1;
    uint64 v1;
    p1, v1 = pendingRowOf(c);
    assert v0 != 0 && to_mathint(e.block.timestamp) >= to_mathint(v0), "an accept landed before the timelock ran";
    assert sameRow(r1, p0), "an accept landed a row other than the pending one";
    assert isZeroRow(p1) && v1 == 0, "an accept left its pending row standing";
}

// WHO MOVES A PENDING ROW. Over every verb: a collateral's pending row changes only by the curator's submit of that
// collateral, which writes exactly the submitted row due `TIMELOCK` from now; by an accept of it, which clears it; or by
// the curator's or the guardian's revoke of it, which clears it.
rule onlyTheCuratorSubmits(env e, method f, calldataarg args, address c) filtered { f -> !f.isView } {
    require e.block.timestamp <= max_uint64; // a real clock fits the `uint64` a submit stamps it into
    CuratorTermsHarness.Row p0;
    uint64 v0;
    p0, v0 = pendingRowOf(c);
    address curator = vault.CURATOR();
    address guardian = vault.GUARDIAN();

    address k;
    CuratorTermsHarness.Row w;
    if (f.selector == sig:submitCollateral(address, CuratorTermsHarness.Row).selector) {
        submitCollateral(e, k, w);
    } else if (f.selector == sig:accept(address).selector) {
        accept(e, k);
    } else if (f.selector == sig:revokePending(address).selector) {
        revokePending(e, k);
    } else {
        f(e, args);
    }

    CuratorTermsHarness.Row p1;
    uint64 v1;
    p1, v1 = pendingRowOf(c);
    bool moved = !sameRow(p0, p1) || v0 != v1;
    bool cleared = isZeroRow(p1) && v1 == 0;
    bool bySubmit = f.selector == sig:submitCollateral(address, CuratorTermsHarness.Row).selector && e.msg.sender == curator && sameRow(p1, w)
        && to_mathint(v1) == e.block.timestamp + TIMELOCK();
    bool byAccept = f.selector == sig:accept(address).selector && cleared;
    bool byRevoke = f.selector == sig:revokePending(address).selector && cleared && (e.msg.sender == curator || e.msg.sender == guardian);
    assert moved => k == c && (bySubmit || byAccept || byRevoke), "a pending row moved without its key";
}

rule onlyTheCuratorMaySubmit(env e, address c, CuratorTermsHarness.Row w) {
    address curator = vault.CURATOR();
    submitCollateral@withrevert(e, c, w);
    assert e.msg.sender != curator => lastReverted, "a submit by someone other than the curator landed";
}

rule onlyTheCuratorOrGuardianMayRevoke(env e, address c) {
    address curator = vault.CURATOR();
    address guardian = vault.GUARDIAN();
    revokePending@withrevert(e, c);
    assert e.msg.sender != curator && e.msg.sender != guardian => lastReverted, "a revoke by a stranger landed";
}

// EVERY ROW SITS INSIDE THE RAILS, preserved by every verb: what `_checkRow` refuses at a submit never reaches the
// table, and an accept moves only a checked row. This is what keeps `10_000 - bufferBps` from underflowing in the price.
rule everyRowSitsInsideTheRails(env e, method f, calldataarg args, address c) filtered { f -> !f.isView } {
    termsRails();
    require tableHolds(c);
    f(e, args);
    assert tableHolds(c), "a verb put a row outside the rails, or listed the vault's own token";
}

// A submit from the curator can land, so the rules above are not vacuous over it.
rule aCuratorSubmitCanLand(env e, address c, CuratorTermsHarness.Row w) {
    termsRails();
    require e.msg.sender == vault.CURATOR();
    submitCollateral(e, c, w);
    satisfy true;
}

// ---- H: the hooks and the vault's questions ----

rule onlyTheVaultCallsTheHooks(env e, CuratorTermsHarness.Lend kind, CuratorTermsHarness.MarketParams mp, uint256 id, address who, bytes data, bool after) {
    bool stranger = e.msg.sender != VAULT();
    if (after) {
        afterLend@withrevert(e, kind, mp, id, who, data);
    } else {
        beforeLend@withrevert(e, kind, mp, id, data);
    }
    assert stranger => lastReverted, "a lend hook answered a caller other than the vault";
}

// `beforeLend` admits EXACTLY the vault these terms were built for: its hub, asset and tenor rail equal the copies, its
// door is none or these terms, and a door vault names a guardian. Any other caller, or any value, refuses too.
rule beforeLendAdmitsExactlyItsOwnVault(env e, CuratorTermsHarness.Lend kind, CuratorTermsHarness.MarketParams mp, uint256 id, bytes data) {
    address door = vault.DOOR();
    bool mismatch = vault.ACE() != ACE() || vault.asset() != ASSET() || vault.MIN_TENOR() != MIN_TENOR() || vault.MAX_TENOR() != MAX_TENOR()
        || (door != 0 && door != currentContract);
    bool guardianless = door != 0 && vault.GUARDIAN() == 0;
    bool stranger = e.msg.sender != VAULT();

    beforeLend@withrevert(e, kind, mp, id, data);
    assert lastReverted <=> (stranger || e.msg.value != 0 || mismatch || guardianless),
        "beforeLend admitted a vault these terms were not built for, or refused their own";
}

// The extension legs, exactly: the row still names the market's record, rate and tenors, and the record's windowed
// minimum, read for the market's own pair, is at or over the market's price. It never reverts on a live record.
rule anExtensionIsAdmittedExactlyOnItsRowAndRecord(env e, CuratorTermsHarness.Extension x, bytes data) {
    require x.dst.record == record;
    require e.msg.value == 0;
    CuratorTermsHarness.Row w = rowOf(x.dst.collateral);
    bool rowSame = w.record == x.dst.record && to_mathint(w.lenderAprBps) == to_mathint(x.dst.lenderAprBps) && w.minTenor == x.dst.minTenor
        && w.maxTenor == x.dst.maxTenor;
    bool priced = record.priceView(x.dst.quote, x.dst.collateral) >= x.dst.price;

    bool yes = admitsExtension@withrevert(e, x, data);
    assert !lastReverted, "the extension question reverted";
    assert yes <=> (rowSame && priced), "the extension answer is not the row and record legs";
}

// A refinance is priced in a market the row still names, at or under today's buffered minimum, for the asked principal:
// the loan's own market while it qualifies, else today's. So these terms never re-lend above what they would open now.
rule aRefinanceIsPricedOnTheRowUnderTheBufferedMinimum(env e, address who, uint256 loanId, CuratorTermsHarness.RefinanceRequest r, bytes data) {
    CuratorTermsHarness.Row w = rowOf(r.collateral);
    require w.record == record;
    mathint m = record.priceView(cash, r.collateral);

    CuratorTermsHarness.MarketParams mp;
    CuratorTermsHarness.Terms t;
    mp, t = refinanceTerms(e, who, loanId, r, data);

    assert to_mathint(mp.price) <= (m * (10000 - to_mathint(w.bufferBps))) / 10000, "a refinance was priced above the buffered minimum";
    assert mp.collateral == r.collateral && mp.record == w.record && mp.lenderAprBps == w.lenderAprBps && mp.minTenor == w.minTenor
        && mp.maxTenor == w.maxTenor, "a refinance was priced in a market the row does not name";
    assert t.principal == r.principal, "a refinance's draw is not the asked principal";
}

// witness: a refinance can keep the loan's own market off today's grid point, so the rule above covers that answer too
rule aRefinanceCanKeepTheLoansOwnMarket(env e, address who, uint256 loanId, CuratorTermsHarness.RefinanceRequest r, bytes data) {
    CuratorTermsHarness.Row w = rowOf(r.collateral);
    require w.record == record;
    mathint buffered = (record.priceView(cash, r.collateral) * (10000 - to_mathint(w.bufferBps))) / 10000;

    CuratorTermsHarness.MarketParams mp;
    CuratorTermsHarness.Terms t;
    mp, t = refinanceTerms(e, who, loanId, r, data);

    satisfy to_mathint(mp.price) != to_mathint(gridDown(require_uint256(buffered)));
}

// ---- P: the price ----

// THE PRICE IS THE RECORD'S WINDOWED MINIMUM LESS THE BUFFER, GRIDDED DOWN, EXACTLY. The minimum is read for the
// ORDERED pair (the vault's asset, the collateral) from the row's own record, and the buffer is the row's.
rule thePriceIsTheGriddedBufferedMinimum(env e, address borrower, CuratorTermsHarness.BorrowRequest r, bytes data) {
    CuratorTermsHarness.Row w = rowOf(r.collateral);
    require w.record == record;
    mathint m = record.priceView(cash, r.collateral);

    CuratorTermsHarness.MarketParams mp;
    CuratorTermsHarness.Terms t;
    mp, t = borrowTerms(e, borrower, r, data);

    mathint buffered = (m * (10000 - to_mathint(w.bufferBps))) / 10000;
    assert to_mathint(mp.price) == to_mathint(gridDown(require_uint256(buffered))), "the price is not the gridded buffered minimum";
}

// The sentence a lender cares about, kept as its own rule so it stands whatever the exact form's verdict.
rule thePriceNeverExceedsTheBufferedMinimum(env e, address borrower, CuratorTermsHarness.BorrowRequest r, bytes data) {
    CuratorTermsHarness.Row w = rowOf(r.collateral);
    require w.record == record;
    mathint m = record.priceView(cash, r.collateral);

    CuratorTermsHarness.MarketParams mp;
    CuratorTermsHarness.Terms t;
    mp, t = borrowTerms(e, borrower, r, data);

    assert to_mathint(mp.price) <= (m * (10000 - to_mathint(w.bufferBps))) / 10000, "the price rose above the buffered minimum";
}

// THE MARKET THESE TERMS BUILD: the vault's asset as quote, the asked collateral, the row's record, rate and tenors, the
// vault as lender, the deploy's coverage and smallest loan; nobody as borrower, no fill fee, no settle bounty, no
// deleverage band; the hub's ask on exactly in hub-ask mode: no door and not in kind. The draw is the asked one, its tenor defaulting
// to the row's shortest.
rule theMarketIsTheRowsOwn(env e, address borrower, CuratorTermsHarness.BorrowRequest r, bytes data) {
    CuratorTermsHarness.Row w = rowOf(r.collateral);
    CuratorTermsHarness.MarketParams mp;
    CuratorTermsHarness.Terms t;
    mp, t = borrowTerms(e, borrower, r, data);

    assert mp.quote == ASSET() && mp.collateral == r.collateral && mp.record == w.record && mp.lender == VAULT() && mp.borrower == 0,
        "the market names the wrong tokens, record, lender or borrower";
    assert mp.minCoverageWad == COVERAGE_WAD() && mp.minPrincipal == MIN_PRINCIPAL() && mp.lenderAprBps == to_mathint(w.lenderAprBps)
        && mp.minTenor == w.minTenor && mp.maxTenor == w.maxTenor, "the market's terms are not the row's and the deploy's";
    assert mp.fillFeeBps == 0 && mp.settleBountyBps == 0 && mp.deleverageFloorEpsBps == 0 && mp.deleverageBandBps == 0
        && mp.deleverageTargetBps == 0 && mp.deleverageStopBps == 0 && mp.deleverageProtocolBps == 0,
        "the market carries a fee, a bounty or a deleverage band";
    assert mp.inventoryAsk <=> (!vault.IN_KIND() && vault.DOOR() == 0), "the hub's ask is not on exactly in hub-ask mode";
    assert t.units == r.units && t.principal == r.principal && t.minBufferWad == r.minBufferWad
        && t.tenor == (r.tenor == 0 ? w.minTenor : r.tenor), "the draw is not the asked one";
}

// WITNESS: beside an in-kind vault a borrow is answered at a live price with the hub's ask off, so that mode is reached.
rule anInKindVaultIsPriced(env e, address borrower, CuratorTermsHarness.BorrowRequest r, bytes data) {
    require vault.IN_KIND();
    CuratorTermsHarness.MarketParams mp;
    CuratorTermsHarness.Terms t;
    mp, t = borrowTerms(e, borrower, r, data);
    satisfy !mp.inventoryAsk && mp.price != 0;
}

// A BORROW REFUSES EXACTLY WHEN THERE IS NO PRICE: the collateral is unlisted, or its gridded buffered minimum is zero,
// which is every dark record. Wherever both stand it answers, so a listed, lit row always prices a loan.
rule thePriceAnswersExactlyWhenListedAndLit(env e, address borrower, CuratorTermsHarness.BorrowRequest r, bytes data) {
    CuratorTermsHarness.Row w = rowOf(r.collateral);
    require w.record == 0 || w.record == record;
    require w.bufferBps < 10000; // the row rail, preserved by `everyRowSitsInsideTheRails`
    require e.msg.value == 0;
    mathint m = record.priceView(cash, r.collateral);
    mathint buffered = (m * (10000 - to_mathint(w.bufferBps))) / 10000;

    borrowTerms@withrevert(e, borrower, r, data);
    assert lastReverted <=> (w.record == 0 || gridDown(require_uint256(buffered)) == 0), "a borrow refused a priced row, or priced none";
}

// ---- D: the door and the curator's sale ----

rule onlyTheCuratorSells(env e, address item, uint256 units, address buyer, uint256 minOut, bytes data) {
    address curator = vault.CURATOR();
    sell@withrevert(e, item, units, buyer, minOut, data);
    assert e.msg.sender != curator => lastReverted, "a sale by someone other than the curator landed";
}

// THE FLOOR: while the item's key is open, no sale clears under the record's minimum less 20%, rounded up, nor under
// the lesser of the units' booked share and their record value, nor, while the record answers zero, under the share,
// priced on the units actually sold (`max` resolving to the door's whole balance).
rule aSaleNeverClearsUnderTheFloor(env e, uint256 units, address buyer, uint256 minOut, bytes data) {
    require saleRecord(goods) == record;
    mathint u = units == max_uint256 ? to_mathint(goods.balanceOf(currentContract)) : to_mathint(units);
    mathint floor = saleFloor(u);
    require floor <= max_uint256;

    uint256 paid = sell(e, goods, units, buyer, minOut, data);
    assert to_mathint(paid) >= floor, "a sale cleared under the floor";
}

// AND THE FLOOR IS NO HIGHER THAN RULED: a curator's sale at or over it, and over `minOut`, to a buyer that pays what it
// states, lands. With the rule above this pins the floor exactly: the discount, the share, the record value, the open key.
rule aSaleAtOrOverTheFloorLands(env e, uint256 units, uint256 minOut, bytes data) {
    require e.msg.sender == vault.CURATOR() && e.msg.value == 0;
    // THE GUARD STARTS CLEAR, as every transaction's transient storage does; the prover starts a rule from arbitrary
    // transient storage, and emv-2's counterexample held the lock word at 2^255
    require !entered();

    require saleRecord(goods) == record;
    uint256 held = goods.balanceOf(currentContract);
    mathint u = units == max_uint256 ? to_mathint(held) : to_mathint(units);
    require u > 0 && u <= to_mathint(held);
    mathint floor = saleFloor(u);
    uint256 s = buyerMock.statedView();
    require to_mathint(s) >= floor && s >= minOut && s > 0;
    require buyerMock.approvedView() >= s && cash.balanceOf(buyerMock) >= s;
    require goods.balanceOf(buyerMock) + u <= max_uint256; // the goods' supply fits a word
    require cash.balanceOf(currentContract) + s <= max_uint256 && cash.balanceOf(vault) + s <= max_uint256; // so does the asset's
    require buyerMock.calls() < max_uint256 && vault.returnCount() < max_uint256; // the mocks' own counters

    sell@withrevert(e, goods, units, buyerMock, minOut, data);
    assert !lastReverted, "a sale at or over the floor and minOut refused";
}

// The buyer is told the least the door takes: the larger of `minOut`, the floor and one atom.
rule theBuyerIsToldTheLeastTheDoorTakes(env e, uint256 units, uint256 minOut, bytes data) {
    require saleRecord(goods) == record;
    mathint u = units == max_uint256 ? to_mathint(goods.balanceOf(currentContract)) : to_mathint(units);
    mathint floor = saleFloor(u);
    require floor <= max_uint256;
    mathint c0 = buyerMock.calls();

    sell(e, goods, units, buyerMock, minOut, data);
    assert to_mathint(buyerMock.calls()) == c0 + 1, "the buyer was not called back once";
    assert to_mathint(buyerMock.lastOwed()) == maxOf(maxOf(minOut, floor), 1), "the buyer was told another figure";
}

// A sale clears for real cash: at least the curator's `minOut` and at least one atom, whatever the floor.
rule aSaleAlwaysClearsAtLeastMinOutAndOneAtom(env e, address item, uint256 units, address buyer, uint256 minOut, bytes data) {
    uint256 paid = sell(e, item, units, buyer, minOut, data);
    assert paid >= minOut && paid > 0, "a sale cleared under minOut or for nothing";
}

// What is never a good, and who is never a buyer: the asset, the vault's share, the vault or the terms as buyer, and an
// empty lot (`max` over an empty door included) all refuse.
rule aSaleRefusesWhatIsNotAGood(env e, address item, uint256 units, address buyer, uint256 minOut, bytes data) {
    bool emptyLot = units == 0 || (units == max_uint256 && item == goods && goods.balanceOf(currentContract) == 0);
    bool notAGood = item == ASSET() || item == VAULT() || buyer == VAULT() || buyer == currentContract;
    sell@withrevert(e, item, units, buyer, minOut, data);
    assert notAGood || emptyLot => lastReverted,
        "a sale of the asset, the share or nothing, or to the vault or the terms, landed";
}

// THE SALE'S CASH GOES TO THE VAULT AGAINST THE ITEM, EXACTLY: the buyer pays `paid`, the vault receives `paid` through
// one `returnProceeds(item, paid, closes)`, `closes` exactly when the door holds none of the item left, the door's own
// cash is untouched and no allowance is left standing.
rule aSalesCashGoesToTheVaultAgainstTheItem(env e, uint256 units, uint256 minOut, bytes data) {
    mathint t0 = cash.balanceOf(currentContract);
    mathint v0 = cash.balanceOf(vault);
    mathint b0 = cash.balanceOf(buyerMock);
    mathint n0 = vault.returnCount();

    uint256 paid = sell(e, goods, units, buyerMock, minOut, data);

    assert to_mathint(cash.balanceOf(currentContract)) == t0, "the sale moved the door's own cash";
    assert to_mathint(cash.balanceOf(vault)) == v0 + paid, "the vault did not receive exactly the sale's cash";
    assert to_mathint(cash.balanceOf(buyerMock)) == b0 - paid, "the buyer did not pay exactly what it stated";
    assert to_mathint(vault.returnCount()) == n0 + 1 && vault.lastKey() == goods && vault.lastCash() == paid,
        "the cash was not returned once against the item";
    assert vault.lastCloses() <=> goods.balanceOf(currentContract) == 0, "the return's close flag is not whether the door holds none";
    assert cash.allowance(currentContract, vault) == 0, "the door left the vault an allowance";
}

// The goods go to the buyer, exactly the units sold.
rule aSaleSendsTheGoodsToTheBuyer(env e, uint256 units, address buyer, uint256 minOut, bytes data) {
    require buyer != currentContract;
    mathint g0 = goods.balanceOf(currentContract);
    mathint gb0 = goods.balanceOf(buyer);
    mathint u = units == max_uint256 ? g0 : to_mathint(units);

    sell(e, goods, units, buyer, minOut, data);
    assert to_mathint(goods.balanceOf(currentContract)) == g0 - u, "the door gave up other than the units sold";
    assert to_mathint(goods.balanceOf(buyer)) == gb0 + u, "the buyer received other than the units sold";
}

// NOBODY BUT THE VAULT GAINS THE ASSET THROUGH THESE TERMS, over every verb: a sale's cash and a forward both land at
// the vault, the buyer only pays, and no address is ever paid out.
rule noOneButTheVaultGainsTheDoorsCash(env e, method f, calldataarg args, address x) filtered { f -> !f.isView } {
    require x != vault;
    mathint b0 = cash.balanceOf(x);
    f(e, args);
    assert to_mathint(cash.balanceOf(x)) <= b0, "an address other than the vault gained the asset";
}

// A forward sends the door's whole cash to the vault under the asset's own key and closes nothing; an empty door calls
// nothing.
rule aForwardSendsTheDoorsCashToTheVaultUnderTheAssetsKey(env e) {
    mathint held = cash.balanceOf(currentContract);
    mathint v0 = cash.balanceOf(vault);
    mathint n0 = vault.returnCount();

    uint256 out = forwardCash(e);

    assert to_mathint(out) == held && cash.balanceOf(currentContract) == 0, "the forward did not send the door's whole cash";
    assert to_mathint(cash.balanceOf(vault)) == v0 + held, "the vault did not receive the forward";
    assert held == 0 => to_mathint(vault.returnCount()) == n0, "an empty forward called the vault";
    assert held != 0 => (to_mathint(vault.returnCount()) == n0 + 1 && vault.lastKey() == cash && to_mathint(vault.lastCash()) == held
        && !vault.lastCloses()), "the forward was not one return under the asset's key, closing nothing";
}

// THE FLOOR'S RECORD IS THE LATEST DELIVERED POT'S MARKET RECORD. A collect of up to two ids pins, for each collateral,
// the record of the market of the last id that delivered units of it, and leaves every other pin where it was.
rule aCollectPinsTheLatestPotsRecord(env e, uint256[] ids, address c) {
    require ids.length <= 2;
    address expected = saleRecord(c);
    if (ids.length > 0 && vault.collectedView(ids[0]) != 0 && hub.collateralOfLoan(ids[0]) == c) {
        expected = hub.recordOfLoan(ids[0]);
    }
    if (ids.length > 1 && vault.collectedView(ids[1]) != 0 && hub.collateralOfLoan(ids[1]) == c) {
        expected = hub.recordOfLoan(ids[1]);
    }

    collectForfeited(e, ids);
    assert saleRecord(c) == expected, "the pin is not the latest delivered pot's market record";
}

// AND NOTHING ELSE MOVES IT: a row change, an accept, a sale or a forward leaves every pinned record where it was.
rule onlyACollectMovesTheSaleRecord(env e, method f, calldataarg args, address c) filtered { f -> !f.isView } {
    address r0 = saleRecord(c);
    f(e, args);
    assert saleRecord(c) != r0 => f.selector == sig:collectForfeited(uint256[]).selector, "a pinned record moved outside a collect";
}

// A sale can clear at a positive floor, so the floor's probe really reaches the pinned record and the key's read.
rule aSaleCanClearAtAPositiveFloor(env e, uint256 units, uint256 minOut, bytes data) {
    require saleRecord(goods) == record;
    mathint u = units == max_uint256 ? to_mathint(goods.balanceOf(currentContract)) : to_mathint(units);
    mathint floor = saleFloor(u);
    uint256 paid = sell(e, goods, units, buyerMock, minOut, data);
    satisfy floor > 0 && floor < max_uint256 && to_mathint(paid) == floor;
}

// ---- R: the room ----

// THE ROOM IS THE VAULT'S CAP LESS WHAT IS LENT AND THE UNSOLD POTS HELD AT THE MARKET RECORD'S MINIMUM, saturating at
// zero, read for this vault in its own asset; with no unsold pot it is uncapped. It answers wherever that sum fits.
rule theRoomIsTheCapLessTheLentAndTheParkedPots(env e, CuratorTermsHarness.MarketParams mp) {
    require mp.record == record;
    require e.msg.value == 0;
    uint256 lent;
    uint256 unsold;
    lent, unsold = hub.lenderByCollateral(vault, cash, mp.collateral);
    mathint parked = (to_mathint(unsold) * to_mathint(record.priceView(cash, mp.collateral))) / 2 ^ 96;
    require parked <= max_uint256 && lent + parked <= max_uint256;
    mathint cap = vault.effectiveCap(mp.collateral);

    uint256 r = room@withrevert(e, mp);
    assert !lastReverted, "the room reverted where its sum fits";
    assert unsold == 0 => r == max_uint256, "the room was capped with no unsold pot";
    assert unsold != 0 => to_mathint(r) == (cap > lent + parked ? cap - lent - parked : 0), "the room is not the cap less lent and parked";
}
