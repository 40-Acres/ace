// V-1, V-2, V-3's vault half and V-4 of the internal record, against `SAeroTerms`, the sAERO vault's terms and door,
// which hold the bid, the dials and the listing floor (the file keeps its name so the obligations' citations still resolve).
//
// THE ACCOUNT IS DISPATCHED, NOT LINKED, AND THAT IS THE RECORD LANE'S LESSON APPLIED RATHER THAN RE-LEARNED.
// "The account" here is the stake receipt (`MockSAeroStakeReceipt`); the rules keep the older word.
// `link` binds an address the contract HOLDS, so RECORD and FACTORY take it. The account arrives as an ARGUMENT --
// `derivedPrice(address receipt)`, `listFloor(address receipt)`, `r.collateral` -- so there is no field to bind and a
// `link` would be silently inapplicable, leaving every account read an AUTO summary: a per-call havoc. Under that,
// `derivedPrice` would read two different backings in one rule and the zero-legs would hold for nothing.
// See `the design record`.
//
// THE TERMS ARE AN `Initializable` BEHIND A PROXY, AND NO RULE HERE RUNS EITHER. Every rule starts from an arbitrary
// state of the terms, so the namespaced storage is havoced exactly as plain storage was, and the constructor (which
// sets only immutables and disables initializers) and `initialize` (which checks the wiring and writes the dials) are
// never executed. What `initialize` guarantees enters as `theDialRails` below, the same way the constructor's did.
//
// WHAT IS MODELLED, AND WHY EACH IS SOUND TO MODEL HERE. The RECORD is a linked mock answering one price and one
// credit flag, because the record is PROVEN on its own (O73-O76) and is an INPUT to the vault's bid. `PriceGrid.down`
// is a ghost carrying its two DOCUMENTED properties -- at or under its argument, and zero under the grid -- because it
// is tick math whose own correctness belongs to `PriceGrid`, and V-1 is a statement about what the vault FEEDS it.
// `FullMath.mulDiv` is summarized, with the two cases it reverts on recorded in ghosts rather than assumed away.
// So V-1 proves the vault's COMPOSITION of the bid, not the grid's arithmetic.
//
// TWO THINGS THE HARNESS GUARANTEES RATHER THAN ANY RULE PROVING THEM, written down because they are invisible and
// load-bearing. (1) THE CALLEE HAS CODE: every priced rule takes its account from `thePricedAccount()`, which returns
// the LINKED mock, so no rule here admits a codeless address -- the hazard the first `theBidNeverPanics` hit when it
// ranged over a free `address` and the factory blessed `0x401`. (2) AN EXTERNAL CALL DOES NOT RE-ENTER: that is the
// prover's default for an unresolved call, not something stated here.
//
// BOTH HOLD BY HOW THE RULES ARE WRITTEN, NOT BY A PROVEN PROPERTY, so parameterising any of them over a free address
// re-opens the first -- and the premise it would then need, "a blessed address is a well-formed account", is exactly
// what O82 (`SaeroStakeReceiptFactory::onlyMakeEverChangesTheRegistry` and `makeBlessesOnlyTheReceiptItMade`) does NOT
// give: that lane proves preservation, never the genesis store, and never the clone.
using MockRecord as record;
using MockSAeroStakeReceipt as acct;
using MockAccountFactory as factory;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivExact(a, b, d);
    function PriceGrid.down(uint256 p) internal returns (uint256) => gridDown(p);

    // the account reads, which arrive through a runtime argument no `link` can bind
    function _.backing() external => DISPATCHER(true);
    function _.totalSupply() external => DISPATCHER(true);
    function _.state() external => DISPATCHER(true);

    // only what these rules read: the listing floor, the curator's cap and the settings timelock. `derivedPrice` and
    // `dials` are declared nowhere and take an `env`; neither reads the clock.
    function listFloor(address) external returns (uint256) envfree;
    function maxLendPrice() external returns (uint256) envfree;
    function SETTINGS() external returns (address) envfree;

    function MockRecord.priceView() external returns (uint256) envfree;
    function MockRecord.creditOpenView() external returns (bool) envfree;
    function MockSAeroStakeReceipt.backingView() external returns (uint256) envfree;
    function MockSAeroStakeReceipt.supplyView() external returns (uint256) envfree;
    function MockSAeroStakeReceipt.stateView() external returns (uint8) envfree;
    function MockAccountFactory.isAccount(address) external returns (bool) envfree;
}

// `down` answers the highest grid price AT OR UNDER its argument, which is the whole of what V-1 needs of it. Stated as
// a ghost so the tick math is not unrolled: its own correctness is `PriceGrid`'s, and a rule that re-derived it here
// would be proving a copy. Monotonicity is its second stated property and is what carries the bid's monotonicity.
// ONLY THE TWO AXIOMS A RULE ACTUALLY USES, and that restraint is the point: an axiom is an ASSUMPTION about the real
// function, so a false one makes every rule that touches it unsound. `down`'s header states both of these outright --
// "the highest grid price at or under `p`", and "zero under the grid" -- so they are its documented contract.
//
// A MONOTONICITY AXIOM WAS HERE AND IS DELETED. No rule used it, and `down` reaches its answer through a square root,
// two tick floors and a `mulDiv`, so monotonicity is plausible rather than evident and could fail at extreme inputs.
// An unused assumption that might be false is pure downside: it buys nothing and would silently void any future rule
// that leaned on it. If one is ever needed, prove it of `PriceGrid` first.
ghost gridDown(uint256) returns uint256 {
    axiom forall uint256 p. gridDown(p) <= p;
    axiom gridDown(0) == 0;
}

// THE TWO WAYS THE REAL `FullMath.mulDiv` REVERTS ARE RECORDED IN GHOSTS RATHER THAN `require`d AWAY, and that is the
// whole instrument of this lane. A CVL summary cannot revert; a `require` therefore PRUNES the reverting state instead
// of exposing it, so a rule asserting "this never panics" passes by never visiting the panic. That is not a hypothetical
// -- it is what the first version of this spec did: with `require d != 0` in place, DELETING `derivedPrice`'s dark-record
// guard left every rule green, including the one named `theBidNeverPanics`.
//
// So the summary sets a flag instead. `zeroDenSeen` marks a zero denominator and `overflowSeen` a quotient past a
// uint256 -- exactly the two cases the real library reverts on -- and `theBidReachesNoRevertingMulDiv` below asserts
// neither is reachable. The flags turn "would have reverted" into something a rule can see.
ghost bool zeroDenSeen;
ghost bool overflowSeen;

function mulDivExact(uint256 a, uint256 b, uint256 d) returns uint256 {
    if (d == 0) {
        zeroDenSeen = true;
        return 0; // the real library reverts here; the flag is what carries that fact out
    }
    mathint r = (a * b) / d;
    if (r > to_mathint(max_uint256)) {
        overflowSeen = true;
        return 0; // likewise: `mulDiv` refuses a quotient it cannot return
    }
    return require_uint256(r);
}

// THE DIALS, WHICH THE PROVER HAVOCS AND V-5 DISCHARGES AS UNIT TESTS. They are storage only the settings timelock
// moves (the V-2 door rule at the end of this file): `initialize` and the setters refuse a buffer of zero or over 6000
// bps, a floor discount under 9000 or over the whole, and a smallest loan under two. So a rule that let any of them out
// of its rail would be reporting on a vault no door can build.
//
// NOT AN IOU -- ALREADY COVERED, and checked rather than assumed. `SAeroFixedVaultTerms.t.sol` pins `initialize`'s
// rails on both sides (`SAeroFixedVaultTermsTest::test_theDialRails`, `test_V5_everyRailsEdgeBuilds` and
// `test_V5_theFloorDiscountRails`, each a fresh proxy), and the dial suites pin the setters', so no rail is one atom
// tighter than it reads. Certora is the wrong engine for `initialize`, which runs once, through the proxy, on a fresh
// namespace that no rule here starts from.
//
// THE DIALS ARE READ THROUGH THE VAULT'S OWN VIEWS, NEVER STRAIGHT FROM STORAGE. They sit in the terms' ERC-7201
// namespace, which the prover cannot resolve under via-IR, so no `currentContract` field reaches them. `dials()`
// reports the ten in force (its three record dials come from the mock and no rule reads them), and `sizeCurve()` the
// size curve's knot and surcharge, so the exact bid below holds in every state.
// THE SIZE CURVE'S RAIL IS THE SUM, NOT THE SURCHARGE ALONE: the setter holds the buffer plus the surcharge to the
// buffer's max, at most 6000, and a havoced pair past the whole would underflow `WAD - buffer`.
function theDialRails(env e) {
    SAeroTerms.SAeroDials d = dials(e);
    uint256 knot;
    uint256 surcharge;
    knot, surcharge = sizeCurve(e);
    require d.bufferBps != 0 && d.bufferBps <= 6000;
    require to_mathint(d.bufferBps) + to_mathint(surcharge) <= 6000;
    require knot != 0 || surcharge == 0;
    require d.floorDiscountBps >= 9000 && d.floorDiscountBps <= 10000;
    require d.minPrincipal >= 2;
}

// THE SIZE CURVE'S BUFFER IN WAD, the terms' `bufferWadFor` restated: the buffer alone at or under the knot or with no
// surcharge, and past the knot the surcharge on the share of the backing over it, rounded up.
function curveBufferWad(uint256 base, uint256 knot, uint256 surcharge, uint256 backing) returns mathint {
    mathint wad = to_mathint(base) * 10 ^ 14;
    if (surcharge == 0 || backing <= knot) {
        return wad;
    }
    mathint num = to_mathint(surcharge) * 10 ^ 14 * (to_mathint(backing) - to_mathint(knot));
    return wad + (num + to_mathint(backing) - 1) / to_mathint(backing);
}

// the account every priced read takes: the linked mock, which the vault's factory must have made
function thePricedAccount() returns address {
    require factory.isAccount(acct);
    return acct;
}

// ---- V-1: the derived bid ----

// THE BID IS THE GRIDDED MINIMUM OF THE TWO CAPS, exactly. One is the record held under by the buffer; the other is the
// curator's cap per backing atom, spread over the receipt supply. Neither alone is the bid, and taking the max rather
// than the min, or gridding before the min rather than after, is the kind of error only this rule catches.
// STATED IN EVERY STATE: the pending set and its haircut scaling are gone, so its old premise went with them. The buffer
// is the size curve's on the account's backing, which is the old `bufferBps` exactly when the curve is flat. This form
// RAN in the pre-deploy pass (`emv-97`) and TIMED OUT, so it is UNPROVEN; its two halves are proven apart, the record leg
// by `theBidNeverExceedsTheRecord` and the cap leg by `theBidNeverExceedsTheCap`.
rule theBidIsTheGriddedMinimumOfTheRecordAndTheCap(env e) {
    address account = thePricedAccount();
    theDialRails(e);

    uint256 cap = maxLendPrice();
    uint256 pRec = record.priceView();
    uint256 supply = acct.supplyView();
    uint256 backing = acct.backingView();
    require cap != 0 && pRec != 0 && supply != 0;

    SAeroTerms.SAeroDials d = dials(e);
    uint256 knot;
    uint256 surcharge;
    knot, surcharge = sizeCurve(e);
    mathint bufWad = curveBufferWad(d.bufferBps, knot, surcharge, backing);
    mathint pBuf = (to_mathint(pRec) * (10 ^ 18 - bufWad)) / 10 ^ 18;
    mathint pCap = (to_mathint(cap) * to_mathint(backing)) / to_mathint(supply);
    require pBuf <= to_mathint(max_uint256) && pCap <= to_mathint(max_uint256);

    mathint lower = pBuf <= pCap ? pBuf : pCap;
    uint256 p = derivedPrice(e, account);

    // THE GUARD IS CONSERVATIVE, SO A ZERO IS NOT A COUNTEREXAMPLE TO THE FORMULA. `derivedPrice` refuses when
    // `cap * (backing / units)` plus one `cap` would not fit, which is a SUFFICIENT test rather than an exact one --
    // so states exist where the true quotient fits and the vault still answers CLOSED. That is the same shape as the
    // record's own absurd-backing refusal, and REC-1 excludes it the same way. Without this line the rule FAILS on a
    // state where the vault is deliberately conservative, which is what it did when the guard first landed.
    require p != 0;

    assert to_mathint(p) == to_mathint(gridDown(require_uint256(lower))),
        "the bid is not the gridded minimum of the buffered record and the backing cap";
}

// The bid is never above the record's own price: the buffer only ever holds it under, and the grid only ever floors.
// This is the sentence a lender cares about, and it follows from V-1 rather than restating it.
rule theBidNeverExceedsTheRecord(env e) {
    address account = thePricedAccount();
    theDialRails(e);
    require acct.supplyView() != 0;
    assert derivedPrice(e, account) <= record.priceView(), "the bid rose above the record's price";
}

// THE CAP LEG'S BOUND, the other half of the exact rule, stated alone so it can be proven where that rule times out: the
// bid spread over the receipt supply is never above the curator's cap over the stake's backing. It is the lend cap the
// curator sets, and it rests on the grid's `down(p) <= p`, the axiom above, which `PriceGrid.spec` does not yet discharge.
rule theBidNeverExceedsTheCap(env e) {
    address account = thePricedAccount();
    theDialRails(e);
    mathint supply = acct.supplyView();
    mathint backing = acct.backingView();
    mathint cap = maxLendPrice();
    uint256 p = derivedPrice(e, account);
    assert to_mathint(p) * supply <= cap * backing, "the bid over the receipt supply rose above the cap over the backing";
}

// ---- V-1's zero legs: no bid can be derived ----

rule aNonAccountBidsZero(env e, address account) {
    require !factory.isAccount(account);
    assert derivedPrice(e, account) == 0, "the vault bid on collateral its factory did not make";
}

rule aZeroCapBidsZero(env e) {
    address account = thePricedAccount();
    require maxLendPrice() == 0;
    assert derivedPrice(e, account) == 0, "a zero lend cap did not stop the bid";
}

rule aDarkRecordBidsZero(env e) {
    address account = thePricedAccount();
    require record.priceView() == 0;
    assert derivedPrice(e, account) == 0, "a dark record did not stop the bid";
}

// ---- the bid's panic-freedom, which the VAULT does not own ----

// `derivedPrice` divides by the account's receipt supply, so a zero supply is a division by zero, and NOTHING IN THE
// VAULT STOPS IT: the `cap == 0 || pRec == 0` guard is the only thing between the read and the divide. What makes it
// safe is a property of the RECORD -- a stakeless or supplyless account prices at zero (O74,
// `noStakeOrNoSupplyPricesAtZero`) -- so the guard catches the case the divide could not survive.
//
// THIS IS A COMPOSITION PROPERTY, and it is load-bearing rather than academic: the roll policy calls `derivedPrice`
// under the HUB'S LOCK, so a revert here is not a failed view, it is an extension that cannot land. Swap the record
// for one that answers non-zero on an empty account and the vault's bid starts panicking, with no vault change at all.
// THIS RULE COVERS ONLY THE REVERTS SOLIDITY ITSELF RAISES -- the `WAD - buffer` underflow, which V-5's rail
// excludes. It says NOTHING about `mulDiv`'s two reverts, because the summary cannot revert: that half is
// `theBidReachesNoRevertingMulDiv` below, and the two together are the no-panic property.
// A `view` called with value reverts on the non-payable guard before any line of the body runs, which is not a panic.
rule theBidNeverPanics(env e) {
    address account = thePricedAccount();
    theDialRails(e); // V-5: outside its rail a havoced buffer underflows `WAD - buffer`
    require e.msg.value == 0;
    derivedPrice@withrevert(e, account);
    assert !lastReverted, "the bid panicked on arithmetic of its own";
}

// A HAVOCED BUFFER OUTSIDE ITS RAIL REALLY DOES REVERT, so V-5 is load-bearing rather than hygiene. This rule used to
// be named for the RECORD's zero-supply rule and claimed to witness that -- it never did. Its trace carries no
// `pBuf` assignment and no account call at all: the revert it finds is the buffer underflow, reached long before the
// supply ever divides. The lesson is that a `satisfy` witnesses SOME path, not the path you had in mind; read its
// trace before crediting it to a premise.
rule aBufferOutsideItsRailReverts(env e) {
    address account = thePricedAccount();
    SAeroTerms.SAeroDials d = dials(e);
    require d.bufferBps > 10000;
    require e.msg.value == 0;
    derivedPrice@withrevert(e, account);
    satisfy lastReverted;
}

// ---- the half the summary would otherwise hide: neither of `mulDiv`'s reverts is reachable ----

// THE REAL `FullMath.mulDiv` REVERTS ON A ZERO DENOMINATOR AND ON A QUOTIENT PAST A UINT256, and `derivedPrice`'s
// `pCap` leg divides by the ACCOUNT'S RECEIPT SUPPLY with the curator's cap times the account's backing on top. So
// both reverts are live questions about this vault, and neither is visible unless the summary records them -- which
// is what the ghosts exist for.
//
// WHAT HOLDS THE ZERO DENOMINATOR OFF IS NOT THIS CONTRACT: `pRec == 0` whenever the supply is zero, which is the
// record's O74, plus the factory blessing only receipts it really made (V-3, proven as O82 by
// `SaeroStakeReceiptFactory::onlyMakeEverChangesTheRegistry` and `makeBlessesOnlyTheReceiptItMade`). That is the composition
// claim O80 is supposed to make, and this is the rule that actually makes it -- the premise below is load-bearing
// here in a way it was not in the rule above, because deleting it lets the flag be set.
// THE ZERO-DENOMINATOR HALF HOLDS, and this is the rule O80 should have cited all along: with the record's O74 and
// the factory's blessing in hand, a zero receipt supply never reaches the divide. Delete the premise below and the
// flag gets set -- which is what makes it load-bearing here, where in `theBidNeverPanics` it was decorative.
rule theBidReachesNoZeroDenominator(env e) {
    address account = thePricedAccount();
    theDialRails(e);
    require acct.supplyView() == 0 => record.priceView() == 0; // O74, PROVEN of NftAccountRecord

    require !zeroDenSeen;
    derivedPrice(e, account);
    assert !zeroDenSeen, "a zero receipt supply reached mulDiv, which the real library reverts on";
}

// THE OVERFLOW HALF NOW HOLDS, AND THIS RULE REPLACES A `satisfy` THAT USED TO WITNESS THE OPPOSITE. `pCap` is
// `mulDiv(cap, backing, supply)`, and until the guard landed NOTHING bounded its quotient -- so the real
// `FullMath.mulDiv` reverted and `derivedPrice` PANICKED, which mattered more than a failed view: the roll policy
// calls it under the hub's lock, so a panic was an extension that could not land. Found by the ghost instrument,
// filed as a `sev:low` defect, and fixed by mirroring the record's absurd-backing test rather than by
// bounding `setMaxLendPrice` -- answering CLOSED is this codebase's discipline on every other unfit leg.
//
// THE WITNESS RULE IS GONE BECAUSE THE FIX RETIRED IT, which was the point of writing it as a `satisfy`: a defect
// carried as a verified witness turns RED when someone fixes it, so the spec cannot keep asserting a hole that has
// been closed. An assertion is the right form now, and it is strictly stronger than the one it replaces.
//
// Sufficiency is the record lane's `theOverflowGuardIsSufficient`, already proven: with `backing <= units` the
// quotient cannot exceed `cap`, and with `backing > units` the guard checks `cap * (backing / units + 1)` fits.
rule theBidsQuotientNeverOverflows(env e) {
    address account = thePricedAccount();
    theDialRails(e);

    require !overflowSeen;
    derivedPrice(e, account);
    assert !overflowSeen, "the capped bid's quotient passed a uint256, which the real library reverts on";
}

// THE OTHER PRICED VIEW NEEDS THE SAME INSTRUMENT, and pointing it at only one of the two is how the asymmetry goes
// stale the next time someone adds a view. `listFloor` makes two `mulDiv` calls of its own: the discount leg is safe by
// construction (the multiplier is at most the denominator, so the quotient cannot exceed `value`), but
// `mulDiv(pRec, supply, Q96)` has NO quotient guard, exactly like `pCap`. It is far less reachable -- it needs a supply
// past 2^96 AND a near-max record price together, where `pCap` needs only a large cap -- so this is a COVERAGE gap
// rather than a suspected defect, and the rule says which by passing or by failing.
// The zero-denominator half is structural here rather than guarded: both of `listFloor`'s divisors are CONSTANTS
// (`Q96` and `BPS`), so no state reaches a zero one. Pinned anyway, because "the denominators are constants" is a fact
// about today's code and this is the rule that notices if one becomes a parameter.
rule theListingFloorReachesNoZeroDenominator(env e) {
    address account = thePricedAccount();
    theDialRails(e);
    require !zeroDenSeen;
    listFloor(account);
    assert !zeroDenSeen, "a zero denominator reached mulDiv in listFloor, whose divisors are both constants";
}

// THE SAME UNGUARDED-QUOTIENT CLASS AS `pCap`, AT A SECOND SITE, AND MUCH LESS REACHABLE. `mulDiv(pRec, supply, Q96)`
// has no bound on its quotient either, and the prover finds the state: `supply = 2^96 + 1` with a near-max record
// price, overflowing once `pRec * supply > 2^352`.
//
// WHY THIS IS INFO WHERE `pCap` IS LOW, and the difference is the whole of the judgement. `pCap` needs only a large
// CAP, and `setMaxLendPrice` has no rail, so a curator reaches it alone. This needs BOTH factors at once: a supply
// past 2^96 -- about 7.9e10 whole receipts, some fifty times AERO's entire supply -- AND a near-max price beside it.
// No curator, borrower or keeper route reaches that; it needs a collateral token that does not exist.
//
// A `satisfy` rather than an `assert`, for the same reason as `theCappedBidsQuotientCanOverflow`: it records a real
// property of the arithmetic as a VERIFIED WITNESS, and a guard that ever lands here turns it red instead of letting
// the spec and the code drift apart quietly.
rule theListingFloorsQuotientCanOverflow(env e) {
    address account = thePricedAccount();
    theDialRails(e);
    require !overflowSeen;
    listFloor(account);
    satisfy overflowSeen;
}

// ---- V-4: the operator's listing floor ----

// The floor is the record's value of the WHOLE stake -- price times the receipt supply, out of the hub's frame --
// times the discount. The vault's own share is not in it, which is: the operator's price
// need not net D. The discount is the one in force: a scheduled one binds nothing until SETTINGS executes it.
rule theListingFloorIsTheDiscountedValueOfTheWholeStake(env e) {
    address account = thePricedAccount();
    theDialRails(e);

    uint256 pRec = record.priceView();
    uint256 supply = acct.supplyView();
    mathint value = (to_mathint(pRec) * to_mathint(supply)) / (1 << 96);
    require value <= to_mathint(max_uint256);
    SAeroTerms.SAeroDials d = dials(e);
    mathint floor = (value * to_mathint(d.floorDiscountBps)) / 10000;
    require floor <= to_mathint(max_uint256);

    assert to_mathint(listFloor(account)) == floor, "the listing floor is not the discounted value of the whole stake";
}

// A dark record leaves no floor, which is what refuses the operator. The curator is not bound by it, which is V-4's
// other half and lives in the door rather than here.
rule aDarkRecordLeavesNoFloor() {
    address account = thePricedAccount();
    require record.priceView() == 0;
    assert listFloor(account) == 0, "a dark record left a listing floor standing";
}

// The floor is never above the whole stake's recorded value: the discount is at most the whole.
rule theFloorNeverExceedsTheStakesValue(env e) {
    address account = thePricedAccount();
    theDialRails(e);
    uint256 pRec = record.priceView();
    uint256 supply = acct.supplyView();
    mathint value = (to_mathint(pRec) * to_mathint(supply)) / (1 << 96);
    require value <= to_mathint(max_uint256);
    assert to_mathint(listFloor(account)) <= value, "the listing floor rose above the stake's recorded value";
}

// ---- V-2's door: who moves the dials. PROVEN on all 12 mutators in the pre-deploy pass (`emv-97`) ----

// ONLY SETTINGS MOVES THE TERMS' DIALS. Over every mutator but `initialize`, which runs once on a fresh proxy and
// whose rails the unit rows pin: when any of the terms' seven dials or the size curve's two fields moves, the caller
// was SETTINGS. There is no curator buffer verb and no grace. The record's three dials live on the record, which
// `setRecordDials` writes and the mock here does not take, so they are out of this rule.
rule onlySettingsMovesTheDials(env e, method f, calldataarg args) filtered {
    f -> !f.isView && f.selector != sig:initialize(SAeroTerms.SAeroTermsConfig).selector
} {
    SAeroTerms.SAeroDials d0 = dials(e);
    uint256 k0;
    uint256 s0;
    k0, s0 = sizeCurve(e);

    f(e, args);

    SAeroTerms.SAeroDials d1 = dials(e);
    uint256 k1;
    uint256 s1;
    k1, s1 = sizeCurve(e);

    bool moved = d0.bufferBps != d1.bufferBps || d0.floorDiscountBps != d1.floorDiscountBps || d0.lenderAprBps != d1.lenderAprBps
        || d0.coverageWad != d1.coverageWad || d0.minPrincipal != d1.minPrincipal || d0.minTenor != d1.minTenor
        || d0.maxTenor != d1.maxTenor || k0 != k1 || s0 != s1;

    assert moved => e.msg.sender == SETTINGS(), "a dial moved without SETTINGS";
}
