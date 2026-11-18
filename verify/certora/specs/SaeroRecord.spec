// REC-1..REC-8 of the internal record, against the reused `NftAccountRecord`.
//
// EVERY EXTERNAL PARTY IS A REAL MOCK WHOSE BODY RUNS, NEVER A HAVOCED ANSWER, and that choice is load-bearing twice
// over. A havoc hands each call a FRESH arbitrary answer, so two reads inside one rule may disagree. REC-5 says the two
// below-twins answer alike for every input, which is a statement about ONE oracle state; under a havoc each twin
// would read its own feed and the rule would fail on a state no chain can hold. Mock storage answers the same twice.
// And REC-2 and REC-3 are precisely about the record's `try`/`catch` legs, which a havoced call can never reach,
// because it always returns. `MockStakeAccount`'s three reads each revert on a flag the prover sets.
//
// WHAT IS STILL MODELLED, per the approved scope: Chainlink and the sequencer "answer as `NftAccountRecord` reads
// them". Linking a mock feed honours that and goes further -- the real `ChainlinkDataFeed` and `SequencerUptime`
// bodies run, so the staleness and grace arithmetic is proven rather than assumed.
//
// `mulDiv` is EXACT, in unbounded integers: REC-1 states the formula and REC-7 states monotonicity, and neither
// survives an uninterpreted product.

// TWO MECHANISMS REACH THOSE MOCK BODIES, AND WHICH ONE APPLIES IS DECIDED BY WHERE THE ADDRESS COMES FROM.
// `link` binds an address the record HOLDS, so the three immutables take it. `SEQUENCER_FEED` was left out of the
// first run and all four priced rules failed, because each read drew its own sequencer status; it is its own contract
// rather than a second instance of the price feed, so a restart is not coupled to a price round.
//
// THE ACCOUNT CANNOT BE LINKED, AND NOTHING WARNS YOU: it arrives as `_perReceipt`'s `collateral` ARGUMENT, so there
// is no field to bind and `link` is silently inapplicable. Every read on it then resolves to an AUTO summary -- a
// per-call havoc -- which is why the dispatchers below are not a style choice. Under the havoc the twins read two
// different backings, `heldView` constrains storage no return value consults, and the `catch` legs are unreachable, so
// REC-2 and REC-3 were vacuous rather than failing. `DISPATCHER(true)` case-splits over the scene's implementors of
// each signature; `MockStakeAccount` is the only one, and the rules pass that very account as the collateral, so the
// optimistic dispatcher's assumption that the callee is a known contract is discharged by construction.
using MockStakeAccount as account;
using MockAggregator as feed;
using MockSequencer as sequencer;
using MockAccountFactory as factory;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivExact(a, b, d);

    // the account reads, which arrive through a runtime argument no `link` can bind: see the header
    function _.holdsStake() external => DISPATCHER(true);
    function _.totalSupply() external => DISPATCHER(true);
    function _.backing() external => DISPATCHER(true);

    // The five priced reads and `spotNum` are declared NOWHERE: each reaches `block.timestamp`, through
    // `ChainlinkDataFeed`'s staleness test and `SequencerUptime.pastGrace`, so each takes an `env` and a
    // declaration without `envfree` has no effect -- the prover warns on one. Only the pair reads are envfree.
    function supportsPair(address, address) external returns (bool) envfree;
    function QUOTE() external returns (address) envfree;
    function GRACE() external returns (uint256) envfree;

    // the harness's two framing getters; `spotNum` is the third and takes an `env`, so it is not declared here
    function priceNum() external returns (uint256) envfree;
    function priceDen() external returns (uint256) envfree;

    function MAX_STALENESS() external returns (uint256) envfree;

    // the three stored dials; only the factory's vault moves them, through `setDials`
    function haircutBps() external returns (uint16) envfree;
    function maxStaleness() external returns (uint32) envfree;
    function grace() external returns (uint32) envfree;

    function MockSequencer.saysUp() external returns (bool) envfree;
    function MockSequencer.startedAtView() external returns (uint256) envfree;
    function MockSequencer.setStartedAt(uint256) external envfree;
    function MockStakeAccount.setBacking(uint256) external envfree;
    function MockStakeAccount.setSupply(uint256) external envfree;
    function MockAggregator.setAnswer(int256) external envfree;
    function MockAggregator.answerView() external returns (int256) envfree;
    function MockAggregator.updatedAtView() external returns (uint256) envfree;
    function MockAggregator.roundIdView() external returns (uint80) envfree;
    function MockAggregator.answeredInRoundView() external returns (uint80) envfree;

    function MockStakeAccount.supplyView() external returns (uint256) envfree;
    function MockStakeAccount.backingView() external returns (uint256) envfree;
    function MockStakeAccount.heldView() external returns (bool) envfree;
    function MockStakeAccount.anyReverts() external returns (bool) envfree;
    function MockAccountFactory.isAccount(address) external returns (bool) envfree;
    function MockAccountFactory.TERMS() external returns (address) envfree;
}

// EXACT in unbounded integers, floored once, so REC-1's formula and REC-7's monotonicity are statements about the real
// arithmetic rather than about an uninterpreted symbol.
//
// THE TWO `require`s ARE ASSUMPTIONS, NOT FACTS, and naming them matters because the real `FullMath.mulDiv` REVERTS
// where this one assumes. A CVL summary cannot revert, so a state that would overflow is PRUNED here rather than
// caught -- which means `noPricedReadEverPanics` cannot by itself prove `_perReceipt`'s overflow guard sufficient; it
// would pass even if the guard were absent. `theOverflowGuardIsSufficient` below is what discharges the second
// `require`, as a lemma about the guard's own arithmetic, and the first is discharged by `den >= PRICE_DEN > 0`.
// THE FLAGS REPLACE THE `require`s, for the reason the paragraph above gives: a pruned state is a state no rule can
// see. Measured consequence of the old form, found by review -- DELETING `_perReceipt`'s absurd-backing guard was
// undetectable by the entire suite, because the overflow it exists to prevent was `require`d out of existence.
ghost bool zeroDenSeen;
ghost bool overflowSeen;

function mulDivExact(uint256 a, uint256 b, uint256 d) returns uint256 {
    if (d == 0) {
        zeroDenSeen = true;
        return 0; // the real library reverts here; the flag carries that fact out
    }
    mathint r = (a * b) / d;
    if (r > to_mathint(max_uint256)) {
        overflowSeen = true;
        return 0; // likewise: `mulDiv` refuses a quotient it cannot return
    }
    return require_uint256(r);
}

// the pair every priced read takes: the record's own quote, and the linked account, which the factory must have made
function thePricedPair() returns address {
    require factory.isAccount(account);
    return account;
}

// ---- the stored dials: in their rails at construction, and kept there by every method ----

// THE DIALS ARE STORAGE, SO THE PROVER HAVOCS THEM in every rule, and outside the rails the record really panics: a
// zero haircut makes `_spot`'s absurd-answer test a division by zero. This is what licenses assuming the rails where
// a rule needs them. The base case is the constructor's `checkDials`; preservation is `setDials`, which checks again.
invariant theDialsSitInTheirRails()
    to_mathint(haircutBps()) >= 5000 && to_mathint(haircutBps()) <= 9500
        && maxStaleness() != 0 && to_mathint(maxStaleness()) <= 172800
        && grace() != 0 && to_mathint(grace()) <= 86400;

// REC-9: ONLY THE FACTORY'S TERMS MOVE A DIAL, and a factory naming no terms leaves them as built. Every method is in
// scope, so a second writer added later fails here. The mock's `TERMS` is free, which is what makes the gate a test.
// The rule names keep "Vault" so the obligations' citations resolve; the writer is the product's terms, which hold the dials.
rule onlyTheFactorysVaultMovesTheDials(method f, env e, calldataarg args) {
    uint16 h = haircutBps();
    uint32 s = maxStaleness();
    uint32 g = grace();
    f(e, args);
    assert haircutBps() != h || maxStaleness() != s || grace() != g => e.msg.sender == factory.TERMS() && e.msg.sender != 0,
        "a dial moved for a caller that is not the factory's terms";
}

// and the terms really can move them, so the rule above is not passing on a writer nobody reaches
rule theVaultCanMoveTheDials(env e, uint16 h, uint32 s, uint32 g) {
    require e.msg.sender == factory.TERMS();
    setDials(e, h, s, g);
    satisfy haircutBps() == h && maxStaleness() == s && grace() == g;
}

// ---- REC-5: the settle twin implies the distress twin ----

// THE TWINS ARE NO LONGER ONE FUNCTION: the settle twin holds HOLD, so distress can answer true a whole window before
// settle does, and the old equality (`theDistressAndSettleTwinsAgree`) was false by design. What holds is the one way
// (O76): a settle needs the latest round live, priced and under `x`, which is distress's whole question, and its high
// sits at or over that latest round's price. The walk reads the mock feed's past rounds, one arbitrary round per id.
// BOUND: run in `SaeroRecordWalk.conf`, pessimistic at 64, so it covers every walk up to MAX_HOLD_ROUNDS; `SaeroRecord.conf`
// excludes it, as it does the two walk rules below and the settle twin's no-panic half.
// At 64 this form TIMES OUT; the same implication is proven split, over the walk's contract: `SaeroRecordWalkLemma.spec`
// proves the contract of the real walk at 64 rounds, and `SaeroRecordWalkSplit.spec` the implication over it.
rule theSettleTwinImpliesTheDistressTwin(env e, uint256 x) {
    address collateral = thePricedPair();
    bool distress = persistedBelowDistress(e, QUOTE(), collateral, x);
    bool settle = persistedBelowSettle(e, QUOTE(), collateral, x);
    assert settle => distress, "the settle twin answered below where the distress twin did not";
}

// and the implication is not satisfied by a settle twin that never answers true; BOUND: `SaeroRecordWalk.conf`, at 64
rule theSettleTwinCanAnswerBelow(env e, uint256 x) {
    address collateral = thePricedPair();
    satisfy persistedBelowSettle(e, QUOTE(), collateral, x);
}

// ---- the lemma the mulDiv summary rests on: `_perReceipt`'s overflow guard is sufficient ----

// A LEMMA ABOUT ARITHMETIC, WITH NO CALL IN IT, and it is here because the summary above assumes what the real
// `FullMath.mulDiv` would revert on. `_perReceipt` admits the product in two cases: `backing <= den`, where the
// quotient cannot exceed `num`; or `backing > den` with `num * (backing / den + 1)` fitting. This says those two
// cases are enough -- that no admitted triple has a quotient past a uint256 -- so the pruning the summary does is
// pruning nothing reachable. Without it, REC-1 and REC-3 would both be conditioned on an unproven step.
rule theOverflowGuardIsSufficient(uint256 num, uint256 backing, uint256 den) {
    require den != 0;
    require to_mathint(backing) <= to_mathint(den)
        || to_mathint(num) * (to_mathint(backing) / to_mathint(den) + 1) <= to_mathint(max_uint256);
    assert (to_mathint(num) * to_mathint(backing)) / to_mathint(den) <= to_mathint(max_uint256),
        "the guard admitted a product whose quotient does not fit a uint256";
}

// ---- REC-2's backing leg: the record REACHES neither of mulDiv's reverts ----

// `theOverflowGuardIsSufficient` proves the guard's ARITHMETIC is enough; this proves the record actually REACHES it,
// which is the other half and the half that was missing. Between them: the absurd-backing test is both correct and
// correctly placed. Without this rule, DELETING that guard outright was invisible to all two dozen rules -- the
// overflow it prevents was pruned by the old summary's `require`, so nothing could observe its absence.
//
// The zero-denominator half is the supply leg: `_perReceipt` returns early on a zero supply, so the framed divisor is
// never zero. The overflow half is the backing leg. Both of mulDiv's reverts, one rule.
rule theRecordReachesNoRevertingMulDiv(env e) {
    address collateral = thePricedPair();
    require to_mathint(priceNum()) >= 79228162514264337593543950336; // 2^96
    require to_mathint(priceDen()) >= 10000000000000000000000; // 10^22

    require !zeroDenSeen && !overflowSeen;
    lastObserved(e, QUOTE(), collateral);

    assert !zeroDenSeen, "a zero framed divisor reached mulDiv, which the real library reverts on";
    assert !overflowSeen, "an absurd backing's quotient reached mulDiv, which the real library reverts on";
}

// ---- the harness's own liveness check, which is about the HARNESS and not about the record ----

// EVERY ZERO-PRICED RULE BELOW IS WORTHLESS IF THE ACCOUNT READS ARE UNREACHABLE, and the sanity check cannot tell
// you: `DISPATCHER(true)` is OPTIMISTIC, so had it found no implementor it would assume those calls away, and the
// zero-price rules would then hold on pruned paths. Vacuity does not catch that either -- a sequencer-down state
// prices at zero without ever calling the account, so it witnesses reachability for the wrong reason, which is
// exactly what the first witness did. A POSITIVE price cannot be witnessed unless the mock's own storage answered
// all three reads, so this rule is what licenses reading the others as proofs.
rule aLivePriceIsReachable(env e) {
    address collateral = thePricedPair();
    satisfy lastObserved(e, QUOTE(), collateral) > 0;
}

// ---- REC-6: the pair the record prices ----

// `supportsPair` is true exactly for the quote it was built with and an account its factory made.
rule thePairIsTheQuoteAndAMadeAccount(address quote, address collateral) {
    bool supported = supportsPair(quote, collateral);
    assert supported <=> (quote == QUOTE() && factory.isAccount(collateral)),
        "supportsPair admitted a pair that is not the quote and a made account, or refused one that is";
}

// ---- REC-4, the half that must never darken: the price an extension is judged at ----

// `minPrice` and `lastObserved` are the same read, and neither consults the grace, so a sequencer restart can delay a
// seizure and can never darken the price. The twins DO consult it, which is REC-4's other half and its own rule.
rule theWindowedMinimumIsTheCurrentPrice(env e) {
    address collateral = thePricedPair();
    uint256 observed = lastObserved(e, QUOTE(), collateral);
    uint256 floor = minPrice(e, QUOTE(), collateral);
    assert observed == floor, "minPrice and lastObserved parted, so this class grew a window";
}

// THE RULE ABOVE IS AN EQUALITY, AND TWO ZEROES SATISFY IT. On its own it does NOT say the price stays LIVE through a
// restart -- a `_read` rewritten to darken inside the grace keeps it green, and that is the whole property the
// record's header calls load-bearing ("a restart can never darken the price an extension is judged at"). The
// asymmetry needs its live half stated separately, and these two rules are it.
//
// THE STRONG FORM IS INDEPENDENCE, not reachability: the price is the same at two different grace windows, so the
// window cannot move it at all. Both starts are non-zero because a zero start is how this feed reports DOWN, and a
// down sequencer darkens every read by design (O74) rather than by the grace.
rule theGraceNeverMovesThePrice(env e, uint256 s1, uint256 s2) {
    address collateral = thePricedPair();
    require s1 != 0 && s2 != 0;

    storage genesis = lastStorage;
    sequencer.setStartedAt(s1);
    uint256 p1 = lastObserved(e, QUOTE(), collateral);

    sequencer.setStartedAt(s2) at genesis;
    uint256 p2 = lastObserved(e, QUOTE(), collateral);

    assert p1 == p2, "the sequencer's grace window moved the price an extension is judged at";
}

// And the price really can be positive INSIDE the grace, which is the reachability the equality rule cannot give.
rule aLivePriceIsReachableInsideTheGrace(env e) {
    address collateral = thePricedPair();
    require sequencer.saysUp();
    require to_mathint(e.block.timestamp) < to_mathint(sequencer.startedAtView()) + to_mathint(GRACE());
    satisfy lastObserved(e, QUOTE(), collateral) > 0;
}

// ---- REC-2, the closed answers that need no feed: no stake, and no supply ----

// An account that does not hold its stake, or holds no receipts, prices at 0 whatever the feed says.
rule noStakeOrNoSupplyPricesAtZero(env e) {
    address collateral = thePricedPair();
    require !account.anyReverts();
    require !account.heldView() || account.supplyView() == 0;
    assert lastObserved(e, QUOTE(), collateral) == 0, "a stakeless or supplyless account priced above zero";
}

// A read that reverts is caught and answers 0, which is why the account is dispatched rather than havoced.
rule aRevertingAccountReadPricesAtZero(env e) {
    address collateral = thePricedPair();
    require account.anyReverts();
    assert lastObserved(e, QUOTE(), collateral) == 0, "a reverting account read escaped the catch";
}

// A down sequencer darkens the price itself, not merely the seizure gate.
rule aDownSequencerPricesAtZero(env e) {
    address collateral = thePricedPair();
    require !sequencer.saysUp();
    assert lastObserved(e, QUOTE(), collateral) == 0, "a down sequencer did not darken the price";
}

// An unfit round -- stale, non-positive, or too wide to frame -- prices at zero whatever the account holds.
rule anUnfitRoundPricesAtZero(env e) {
    address collateral = thePricedPair();
    require spotNum(e) == 0;
    assert lastObserved(e, QUOTE(), collateral) == 0, "an unfit round priced above zero";
}

// A supply so large that framing it would overflow is CLOSED rather than a panic.
rule anAbsurdSupplyPricesAtZero(env e) {
    address collateral = thePricedPair();
    require !account.anyReverts();
    require account.heldView();
    require to_mathint(priceDen()) * to_mathint(account.supplyView()) > to_mathint(max_uint256);
    assert lastObserved(e, QUOTE(), collateral) == 0, "an absurd supply was not closed";
}

// ---- REC-2, the ROUND legs, proven at the gate rather than at its output ----

// `anUnfitRoundPricesAtZero` above conditions on `spotUsd == 0`, which is nearly a tautology: it says a closed spot
// prices at zero and says nothing about WHICH rounds close. These four are the real content, one per leg of
// `ChainlinkDataFeed.latest`, and together they are what REC-2 asks of the feed half.
rule aNonPositiveRoundPricesAtZero(env e) {
    address collateral = thePricedPair();
    require feed.answerView() <= 0;
    assert lastObserved(e, QUOTE(), collateral) == 0, "a non-positive round priced above zero";
}

rule anIncompleteRoundPricesAtZero(env e) {
    address collateral = thePricedPair();
    require feed.answeredInRoundView() < feed.roundIdView();
    assert lastObserved(e, QUOTE(), collateral) == 0, "an incomplete round priced above zero";
}

// A stamp ahead of the chain is closed, which is also what stops the age below underflowing.
rule aRoundStampedAheadPricesAtZero(env e) {
    address collateral = thePricedPair();
    require to_mathint(feed.updatedAtView()) > to_mathint(e.block.timestamp);
    assert lastObserved(e, QUOTE(), collateral) == 0, "a round stamped ahead of the chain priced above zero";
}

// An age of exactly the bound is still fit, so the rule tests strictly past it.
rule aStaleRoundPricesAtZero(env e) {
    address collateral = thePricedPair();
    require to_mathint(feed.updatedAtView()) <= to_mathint(e.block.timestamp);
    require to_mathint(e.block.timestamp) - to_mathint(feed.updatedAtView()) > to_mathint(MAX_STALENESS());
    assert lastObserved(e, QUOTE(), collateral) == 0, "a stale round priced above zero";
}

// ---- REC-6, the half about the READS rather than the predicate ----

// `thePairIsTheQuoteAndAMadeAccount` pins `supportsPair`'s truth table; this pins that the five priced reads ACT on
// it, refusing loudly rather than answering. A wrong-pair read is a wiring bug, so `WrongPair` is the right answer
// and silence would be the wrong one -- an unreachable-from-a-created-market path is still a path.
rule everyPricedReadRefusesAnyOtherPair(env e, address quote, address collateral, uint256 x) {
    require e.msg.value == 0;
    require quote != QUOTE() || !factory.isAccount(collateral);

    lastObserved@withrevert(e, quote, collateral);
    assert lastReverted, "lastObserved answered a pair it does not price";

    minPrice@withrevert(e, quote, collateral);
    assert lastReverted, "minPrice answered a pair it does not price";

    persistedBelowDistress@withrevert(e, quote, collateral, x);
    assert lastReverted, "persistedBelowDistress answered a pair it does not price";

    persistedBelowSettle@withrevert(e, quote, collateral, x);
    assert lastReverted, "persistedBelowSettle answered a pair it does not price";

    persistedAbove@withrevert(e, quote, collateral, x);
    assert lastReverted, "persistedAbove answered a pair it does not price";

    minPriceAndCreditOpen@withrevert(e, quote, collateral);
    assert lastReverted, "minPriceAndCreditOpen answered a pair it does not price";
}

// ---- the one read: `minPrice` and `creditOpen` together ----

// THE ONE READ IS THE PAIR OF TWO, in every state the record can hold: a caller asking both reads them once. Each side
// is its own assert, and the two witnesses below pin that neither side is degenerate, the grace's asymmetry included.
rule theOneReadIsMinPriceAndCreditOpen(env e) {
    address collateral = thePricedPair();
    uint256 p;
    bool open;
    p, open = minPriceAndCreditOpen(e, QUOTE(), collateral);
    assert p == minPrice(e, QUOTE(), collateral), "the one read's price is not minPrice's";
    assert open == creditOpen(e), "the one read's credit flag is not creditOpen's";
}

// inside the grace the one read prices and keeps credit shut, as the two reads do
rule theOneReadPricesWithCreditShut(env e) {
    address collateral = thePricedPair();
    uint256 p;
    bool open;
    p, open = minPriceAndCreditOpen(e, QUOTE(), collateral);
    satisfy p != 0 && !open;
}

// and it prices with credit open
rule theOneReadPricesWithCreditOpen(env e) {
    address collateral = thePricedPair();
    uint256 p;
    bool open;
    p, open = minPriceAndCreditOpen(e, QUOTE(), collateral);
    satisfy p != 0 && open;
}

// ---- REC-4, the half that DOES consult the grace: the seizure twins ----

// Inside the post-restart grace the twins stay dark, which is what delays a seizure. `minPrice` above does not,
// which is what stops the same restart darkening the price an extension is judged at. The two rules are the asymmetry.
rule insideTheGraceTheSeizureTwinsStayDark(env e, uint256 x) {
    address collateral = thePricedPair();
    require sequencer.saysUp();
    require to_mathint(e.block.timestamp) < to_mathint(sequencer.startedAtView()) + to_mathint(GRACE());
    assert !persistedBelowDistress(e, QUOTE(), collateral, x), "a seizure twin answered inside the grace";
}

// NEW CREDIT IS SHUT INSIDE THE GRACE TOO, which REC-4 names alongside the twins and no rule above covers. It is
// the same gate as the twins' and a separate verb, so a drift between them would be invisible to the twin rule.
rule creditIsShutInsideTheGrace(env e) {
    require sequencer.saysUp();
    require to_mathint(e.block.timestamp) < to_mathint(sequencer.startedAtView()) + to_mathint(GRACE());
    assert !creditOpen(e), "credit opened inside the grace";
}

// ---- REC-4's THIRD clause: past the grace, the ROUND must also post-date it ----

// `_live` IS A CONJUNCTION AND THE RULES ABOVE ONLY EXERCISE ITS FIRST HALF. It is
// `pastGrace(up, startedAt, GRACE) && updated >= startedAt + GRACE`, so waiting out the grace is NOT enough: the
// price round must itself have printed at or after the grace's end. A round from inside the outage is not trusted to
// seize off, however long ago the outage ended. Nothing above constrains `updatedAt` against `startedAt + GRACE`, so
// this clause was unproven through the pass that claimed to close REC-4 -- found by reading the conjunction, which is
// the same lesson as the half-proven sweep: a property with an `&&` in it needs a rule per side.
rule aRoundFromInsideTheGraceLicensesNoSeizure(env e, uint256 x) {
    address collateral = thePricedPair();
    require sequencer.saysUp();
    require to_mathint(e.block.timestamp) >= to_mathint(sequencer.startedAtView()) + to_mathint(GRACE());
    require to_mathint(feed.updatedAtView()) < to_mathint(sequencer.startedAtView()) + to_mathint(GRACE());
    assert !persistedBelowDistress(e, QUOTE(), collateral, x),
        "a round printed inside the grace licensed a seizure once the grace had passed";
}

rule aRoundFromInsideTheGraceOpensNoCredit(env e) {
    require sequencer.saysUp();
    require to_mathint(e.block.timestamp) >= to_mathint(sequencer.startedAtView()) + to_mathint(GRACE());
    require to_mathint(feed.updatedAtView()) < to_mathint(sequencer.startedAtView()) + to_mathint(GRACE());
    assert !creditOpen(e), "a round printed inside the grace opened credit once the grace had passed";
}

// ---- REC-1: the exact price ----

// THE GENESIS FRAMING IS READ, NEVER RE-DERIVED. `priceNum`/`priceDen` are the immutables the constructor fixed, and
// `spotNum` is the numerator the record's own `_spot` computed -- so this rule cannot pass by duplicating the staleness
// and absurd-answer gates slightly wrong. What it assumes is `priceDen != 0`, which the constructor's own guards give
// and no engine proves (see `noPricedReadEverPanics`, where the same assumption is stated at length); and that
// `FullMath.mulDiv` is exact, which is the summary at the top of this file. So the rule proves the record's
// COMPOSITION of the frame, with mulDiv's own correctness left to its library. The rule after it pins the numerator.
rule thePriceIsTheExactFramedFloor(env e) {
    address collateral = thePricedPair();
    require priceDen() != 0;
    require !account.anyReverts();
    require account.heldView();

    uint256 num = spotNum(e);
    uint256 supply = account.supplyView();
    uint256 backing = account.backingView();
    require num != 0 && supply != 0;

    mathint den = to_mathint(priceDen()) * to_mathint(supply);
    require den <= to_mathint(max_uint256); // the framing gate: an absurd supply is closed, which is its own rule

    uint256 p = lastObserved(e, QUOTE(), collateral);
    require p != 0; // an absurd backing answers CLOSED, and that leg is its own rule rather than a price

    assert to_mathint(p) == (to_mathint(num) * to_mathint(backing)) / den,
        "the price is not the framed floor of the account's backing per receipt";
}

// THE HAIRCUT IS A STORED DIAL, SO REC-1 NEEDS ITS NUMERATOR STATED AGAINST IT: a fit round's answer times the frame
// times the haircut in force now. Together with the rule above, the price is `answer x frame x haircut x backing /
// (den x supply)`, and a vault-accepted haircut change moves every price in proportion, at once.
rule theSpotIsTheAnswerFramedAtTheStoredHaircut(env e) {
    uint256 num = spotNum(e);
    require num != 0;
    assert to_mathint(num) == to_mathint(feed.answerView()) * to_mathint(priceNum()) * to_mathint(haircutBps()),
        "the spot is not the feed's answer times the frame times the stored haircut";
}

// ---- REC-7: monotonicity ----

// MONOTONICITY HOLDS ONLY WHILE THE READ ANSWERS, and that is a statement about the code rather than a convenience:
// a backing large enough to overflow the frame answers CLOSED, so the price falls to zero as backing rises past it.
// Conditioning on a live answer is what makes the rule true; `p2 != 0` is where that condition sits.
rule aHigherBackingNeverLowersThePrice(env e, uint256 b1, uint256 b2) {
    address collateral = thePricedPair();
    require b2 >= b1;

    storage genesis = lastStorage;
    account.setBacking(b1);
    uint256 p1 = lastObserved(e, QUOTE(), collateral);

    account.setBacking(b2) at genesis;
    uint256 p2 = lastObserved(e, QUOTE(), collateral);

    require p2 != 0;
    assert p2 >= p1, "a higher backing lowered the price while the read still answered";
}

// REC-7 NAMES THREE DIRECTIONS AND THE BACKING IS ONLY ONE OF THEM. These are the other two, and the supply one
// runs the opposite way: a rising supply divides the same backing across more receipts, so the price must not RISE.
rule aHigherFeedAnswerNeverLowersThePrice(env e, int256 a1, int256 a2) {
    address collateral = thePricedPair();
    require a2 >= a1;

    storage genesis = lastStorage;
    feed.setAnswer(a1);
    uint256 p1 = lastObserved(e, QUOTE(), collateral);

    feed.setAnswer(a2) at genesis;
    uint256 p2 = lastObserved(e, QUOTE(), collateral);

    require p2 != 0; // an answer too wide to frame answers CLOSED, which is REC-2 rather than a price drop
    assert p2 >= p1, "a higher feed answer lowered the price while the read still answered";
}

rule aHigherSupplyNeverRaisesThePrice(env e, uint256 s1, uint256 s2) {
    address collateral = thePricedPair();
    require s2 >= s1;

    storage genesis = lastStorage;
    account.setSupply(s1);
    uint256 p1 = lastObserved(e, QUOTE(), collateral);

    account.setSupply(s2) at genesis;
    uint256 p2 = lastObserved(e, QUOTE(), collateral);

    require p1 != 0; // a zero supply prices at zero, so the smaller side must be a real price for this to say anything
    assert p2 <= p1, "a higher supply raised the price";
}

// ---- REC-3: no panic ----

// EVERY PRICED READ ANSWERS OR REFUSES THE PAIR -- it never panics, for any feed, sequencer or account state. This is
// the rule the `try`/`catch` legs and the two overflow gates exist for, and the only one that would catch a division
// by zero or an unchecked product. The pair is good by construction here, so a revert is a panic and nothing else.
// The settle twin's half is `theSettleTwinNeverPanics` below, which walks the feed's history at its full depth.
rule noPricedReadEverPanics(env e, uint256 x) {
    address collateral = thePricedPair();

    // THE ASSUMPTION IS THE GENESIS FRAMING, AND NON-ZERO IS NOT ENOUGH -- which took two counterexamples to learn.
    // The prover havocs both constants, since they are immutables and the constructor is not analysed here, and the
    // record panics three ways on values genesis cannot produce: `_spot` multiplies `PRICE_NUM` by the haircut, which
    // overflows on a frame too wide; it divides by that product to refuse an absurd answer, so a zero is a division by
    // zero; and `_perReceipt` computes `backing / den + 1`, which OVERFLOWS when `den` is 1 and the backing is
    // MAX_UINT256. So the bounds are not hygiene -- each is the reason a step is safe.
    //
    // What genesis actually builds, from the constructor: `PRICE_NUM = 2^96 * 10^quoteDecimals`, so at least 2^96, and
    // refused past `max / 9500`, so the haircut rail's top frames; `PRICE_DEN = 10^feedDecimals * 10^18 * 10000`, so at
    // least 10^22. NOTHING PROVES THAT, and REC-8 is NOT it: REC-8 is the constructor's refusal of bad params, which
    // unit tests cover in full. These bounds are the framing's MAGNITUDE, a separate claim no engine states.
    // The haircut itself is STORAGE, and its rail is proven rather than assumed: `theDialsSitInTheirRails`.
    require to_mathint(priceNum()) >= 79228162514264337593543950336; // 2^96
    require to_mathint(priceNum()) * 9500 <= to_mathint(max_uint256); // the constructor refuses a wider frame
    require to_mathint(priceDen()) >= 10000000000000000000000; // 10^22
    requireInvariant theDialsSitInTheirRails();

    // A `view` called with value reverts on the non-payable guard, one branch in and before any line of the body
    // runs. That is Solidity's, not a panic, and only this rule can see it: every other rule calls without
    // `@withrevert`, which prunes the reverting path. The first counterexample here was a transfer of 4769 wei.
    require e.msg.value == 0;

    lastObserved@withrevert(e, QUOTE(), collateral);
    assert !lastReverted, "lastObserved panicked on a pair it prices";

    minPrice@withrevert(e, QUOTE(), collateral);
    assert !lastReverted, "minPrice panicked on a pair it prices";

    persistedBelowDistress@withrevert(e, QUOTE(), collateral, x);
    assert !lastReverted, "persistedBelowDistress panicked on a pair it prices";

    persistedAbove@withrevert(e, QUOTE(), collateral, x);
    assert !lastReverted, "persistedAbove panicked on a pair it prices";

    minPriceAndCreditOpen@withrevert(e, QUOTE(), collateral);
    assert !lastReverted, "minPriceAndCreditOpen panicked on a pair it prices";
}

// THE SETTLE TWIN'S HALF OF THE RULE ABOVE, on its own because it alone walks the feed's history, the scene's heaviest
// path. The same genesis framing, for the same reasons. BOUND: `SaeroRecordWalk.conf`, pessimistic at 64, every walk.
// The walk reads past rounds; with no `getRoundData` on the mock feed the prover answered it with an AUTO summary whose
// short return the `try` cannot catch, so the no-panic rule failed on the harness, never on the record. The mock now
// answers each id from storage, as a real feed answers in full or reverts.
rule theSettleTwinNeverPanics(env e, uint256 x) {
    address collateral = thePricedPair();
    require to_mathint(priceNum()) >= 79228162514264337593543950336; // 2^96
    require to_mathint(priceNum()) * 9500 <= to_mathint(max_uint256); // the constructor refuses a wider frame
    require to_mathint(priceDen()) >= 10000000000000000000000; // 10^22
    requireInvariant theDialsSitInTheirRails();
    require e.msg.value == 0;

    persistedBelowSettle@withrevert(e, QUOTE(), collateral, x);
    assert !lastReverted, "persistedBelowSettle panicked on a pair it prices";
}
