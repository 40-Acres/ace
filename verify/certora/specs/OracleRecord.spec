// OracleRecord: the single-pair Chainlink-shaped ORACLE-class record, proven against what the hub asks of it.
//
// WHAT THE HUB ASKS (MarketInit._requireAnswers, Borrower.persistedPrice / tryRecordState / _belowOrRevert):
//   - genesis calls minPrice, both twins at 0 and lastObserved once, and refuses a market whose record reverts on any;
//   - the draw cap and the record state read minPrice, where a revert is RecordUnreadable and a zero is NoPrice (closed);
//   - distress and settlement read the twins, where a revert is RecordUnreadable, so a revert BLOCKS settlement.
// So the record must answer every read on its pair for EVERY feed state, never revert there, and answer a sick feed as
// the dark value (zero, false), never as a live price. Those are OR-3 and OR-2 below.
//
// THE FEED AND THE TOKENS ARE MOCKS WHOSE BODIES RUN, DISPATCHED BY ADDRESS, NEVER LINKED. The record takes all three as
// constructor arguments and reads their decimals there. A `link` binds the immutable but not the argument, so under a
// link the constructor would read decimals off one contract and the frame invariant off another. `DISPATCHER(true)`
// case-splits a call over the scene's implementors BY THE CALLEE'S ADDRESS, so the constructor's read and the
// invariant's read of the same address land on the same mock. The optimistic half prunes a callee that is no scene
// contract: a codeless feed would revert the constructor's own `decimals()` read, so no deployed record holds one.
// The mock answers in full or reverts; a return too short to decode reverts the read (the header says so) and is the
// one feed behaviour this scene does not produce.
//
// `mulDiv` is EXACT, in unbounded integers, floored once, with its two reverting cases RECORDED in ghosts rather than
// required away, so OR-4 can prove the record never reaches either.
//
// THE AGGREGATOR FLOOR IS NOT THE RECORD'S QUESTION: the record reads no minAnswer, and OR-1 proves every fit answer
// prices at the exact frame, an answer frozen at its aggregator's floor included. Whether a feed's aggregator holds a
// live floor is checked before deploy, off-chain. A record that closed on the floor would turn OR-1 red there.
using MockPriceFeed as feed;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivExact(a, b, d);

    // the feed and both tokens arrive as constructor arguments, so no `link` can bind them: see the header
    function _.decimals() external => DISPATCHER(true);
    function _.latestRoundData() external => DISPATCHER(true);

    // the five priced reads reach `block.timestamp` through the staleness test, so each takes an `env`
    function supportsPair(address, address) external returns (bool) envfree;
    function QUOTE() external returns (address) envfree;
    function COLLATERAL() external returns (address) envfree;
    function FEED() external returns (address) envfree;
    function MAX_STALENESS() external returns (uint256) envfree;

    function priceNum() external returns (uint256) envfree;
    function priceDen() external returns (uint256) envfree;
    function quoteDecimals() external returns (uint8) envfree;
    function collateralDecimals() external returns (uint8) envfree;
    function feedDecimals() external returns (uint8) envfree;

    function MockPriceFeed.answerView() external returns (int256) envfree;
    function MockPriceFeed.updatedAtView() external returns (uint256) envfree;
    function MockPriceFeed.roundIdView() external returns (uint80) envfree;
    function MockPriceFeed.answeredInRoundView() external returns (uint80) envfree;
    function MockPriceFeed.revertsView() external returns (bool) envfree;
    function MockPriceFeed.setAnswer(int256) external envfree;
}

ghost bool zeroDenSeen;
ghost bool overflowSeen;

// The real library reverts on a zero divisor and on a quotient past a uint256; a summary cannot revert, so each case sets
// a flag and answers zero, and OR-4 proves the record reaches neither.
function mulDivExact(uint256 a, uint256 b, uint256 d) returns uint256 {
    if (d == 0) {
        zeroDenSeen = true;
        return 0;
    }
    mathint r = (a * b) / d;
    if (r > to_mathint(max_uint256)) {
        overflowSeen = true;
        return 0;
    }
    return require_uint256(r);
}

// THE ROUND IS FIT, as `ChainlinkDataFeed.latest` documents it: the read answered, a positive answer, a complete round, a
// stamp not ahead of the chain and an age of at most the bound. Each leg's negation is its own dark rule below.
function fitRound(env e) returns bool {
    return !feed.revertsView()
        && feed.answerView() > 0
        && feed.answeredInRoundView() >= feed.roundIdView()
        && to_mathint(feed.updatedAtView()) <= to_mathint(e.block.timestamp)
        && to_mathint(e.block.timestamp) - to_mathint(feed.updatedAtView()) <= to_mathint(MAX_STALENESS());
}

// every read the hub or a lens can make on the record's own pair answers the dark value at `x`
function readsDark(env e, uint256 x) returns bool {
    address q = QUOTE();
    address c = COLLATERAL();
    return lastObserved(e, q, c) == 0
        && minPrice(e, q, c) == 0
        && !persistedBelowDistress(e, q, c, x)
        && !persistedBelowSettle(e, q, c, x)
        && !persistedAbove(e, q, c, x);
}

// ---- OR-0: what the constructor fixes ----

// THE FRAME IS THE PAIR'S DECIMALS, read once at construction: `PRICE_NUM = 2^96 * 10^quoteDecimals` and
// `PRICE_DEN = 10^feedDecimals * 10^collateralDecimals`. The base case runs the constructor, so a decimals mutant there
// (the wrong token's decimals, a feed's scale dropped) fails it; every method is a view, so the step holds by itself.
// It is also what every rule below takes the frame's magnitude from: `PRICE_NUM >= 2^96` and `PRICE_DEN >= 1`.
// THE DECIMALS BOUNDS ARE THE CONSTRUCTOR'S OWN CHECKED ARITHMETIC, not an assumption: past 48 quote decimals the
// numerator overflows and past 77 combined the denominator does, so the constructor reverts. They are stated because the
// prover's power-of-ten table stops at 10^77, and a rule assuming the frame at a wider exponent would read garbage.
invariant theFrameIsThePairsDecimals()
    to_mathint(quoteDecimals()) <= 48
        && to_mathint(feedDecimals()) + to_mathint(collateralDecimals()) <= 77
        && to_mathint(priceNum()) == 2^96 * 10^quoteDecimals()
        && to_mathint(priceDen()) == 10^feedDecimals() * 10^collateralDecimals();

// THE WIRING THE CONSTRUCTOR ADMITS: a feed, two distinct tokens and a non-zero staleness bound.
invariant theWiringIsSound()
    FEED() != 0 && QUOTE() != 0 && COLLATERAL() != 0 && QUOTE() != COLLATERAL() && MAX_STALENESS() != 0;

// ---- OR-1: the exact price ----

// A FIT ROUND PRICES AT THE EXACT FRAMED FLOOR, `floor(answer * PRICE_NUM / PRICE_DEN)`, rounded down once. With OR-0
// that is the feed's answer rescaled by the constructor's decimals. The absurd guard is premised away here and is its
// own dark rule. An age of exactly the bound is inside the premise, so a staleness test made inclusive fails here.
rule aFitRoundPricesAtTheExactFrame(env e) {
    requireInvariant theFrameIsThePairsDecimals();
    require FEED() == feed;
    require fitRound(e);
    mathint a = to_mathint(feed.answerView());
    require a <= to_mathint(max_uint256) / to_mathint(priceNum());

    uint256 p = lastObserved(e, QUOTE(), COLLATERAL());
    assert to_mathint(p) == (a * to_mathint(priceNum())) / to_mathint(priceDen()),
        "a fit round did not price at the exact framed floor";
}

// ---- OR-2: every unfit leg reads dark, at every read ----

rule aRevertingFeedReadsDark(env e, uint256 x) {
    require FEED() == feed;
    require feed.revertsView();
    assert readsDark(e, x), "a reverting feed answered a live read";
}

rule aNonPositiveAnswerReadsDark(env e, uint256 x) {
    require FEED() == feed;
    require feed.answerView() <= 0;
    assert readsDark(e, x), "a non-positive answer answered a live read";
}

rule anIncompleteRoundReadsDark(env e, uint256 x) {
    require FEED() == feed;
    require feed.answeredInRoundView() < feed.roundIdView();
    assert readsDark(e, x), "an incomplete round answered a live read";
}

// a stamp ahead of the chain is closed, which is also what keeps the age from underflowing
rule aFutureStampReadsDark(env e, uint256 x) {
    require FEED() == feed;
    require to_mathint(feed.updatedAtView()) > to_mathint(e.block.timestamp);
    assert readsDark(e, x), "a round stamped ahead of the chain answered a live read";
}

// an age of exactly the bound is still fit, so this tests strictly past it
rule aStaleRoundReadsDark(env e, uint256 x) {
    require FEED() == feed;
    require to_mathint(feed.updatedAtView()) <= to_mathint(e.block.timestamp);
    require to_mathint(e.block.timestamp) - to_mathint(feed.updatedAtView()) > to_mathint(MAX_STALENESS());
    assert readsDark(e, x), "a stale round answered a live read";
}

// an answer too wide to frame is CLOSED rather than a panic
rule anAbsurdAnswerReadsDark(env e, uint256 x) {
    requireInvariant theFrameIsThePairsDecimals();
    require FEED() == feed;
    require to_mathint(feed.answerView()) > to_mathint(max_uint256) / to_mathint(priceNum());
    assert readsDark(e, x), "an answer too wide to frame answered a live read";
}

// ---- OR-3: the hub's reads never revert on the record's pair ----

// EVERY READ ON THE PAIR ANSWERS, for every feed state the mock can hold, a reverting feed included. A revert on a twin
// would block settlement and a revert on `minPrice` would brick genesis, so this is the property the hub depends on
// most. `msg.value` is zero because a view called with value reverts on Solidity's non-payable guard, which no hub call does.
rule noReadOnThePairEverReverts(env e, uint256 x) {
    requireInvariant theFrameIsThePairsDecimals();
    require FEED() == feed;
    require e.msg.value == 0;
    address q = QUOTE();
    address c = COLLATERAL();

    supportsPair@withrevert(q, c);
    assert !lastReverted, "supportsPair reverted";
    lastObserved@withrevert(e, q, c);
    assert !lastReverted, "lastObserved reverted on the record's pair";
    minPrice@withrevert(e, q, c);
    assert !lastReverted, "minPrice reverted on the record's pair";
    persistedBelowDistress@withrevert(e, q, c, x);
    assert !lastReverted, "persistedBelowDistress reverted on the record's pair";
    persistedBelowSettle@withrevert(e, q, c, x);
    assert !lastReverted, "persistedBelowSettle reverted on the record's pair, which would block settlement";
    persistedAbove@withrevert(e, q, c, x);
    assert !lastReverted, "persistedAbove reverted on the record's pair";
}

// AND EXACTLY WHEN THEY CAN: each read the hub makes reverts if and only if the pair is not the record's or the call
// carries value. The hub's reads are static calls with no value, so on a created market they never revert at all.
rule theHubsReadsRevertExactlyOnAWrongPairOrValue(env e, address q, address c, uint256 x) {
    requireInvariant theFrameIsThePairsDecimals();
    require FEED() == feed;
    bool refused = q != QUOTE() || c != COLLATERAL() || e.msg.value != 0;

    minPrice@withrevert(e, q, c);
    assert lastReverted <=> refused, "minPrice reverted other than on a wrong pair or a value";
    persistedBelowDistress@withrevert(e, q, c, x);
    assert lastReverted <=> refused, "persistedBelowDistress reverted other than on a wrong pair or a value";
    persistedBelowSettle@withrevert(e, q, c, x);
    assert lastReverted <=> refused, "persistedBelowSettle reverted other than on a wrong pair or a value";
}

// ---- OR-4: the record reaches neither of mulDiv's reverts ----

// The summary cannot revert, so OR-3 alone would pass with the absurd guard deleted; this is the rule that would not.
rule theRecordReachesNoRevertingMulDiv(env e) {
    requireInvariant theFrameIsThePairsDecimals();
    require FEED() == feed;
    require !zeroDenSeen && !overflowSeen;
    lastObserved(e, QUOTE(), COLLATERAL());
    assert !zeroDenSeen, "a zero divisor reached mulDiv, which the real library reverts on";
    assert !overflowSeen, "an absurd answer's quotient reached mulDiv, which the real library reverts on";
}

// ---- OR-5: the pair ----

rule thePairIsTheConstructorsPair(address q, address c) {
    assert supportsPair(q, c) <=> (q == QUOTE() && c == COLLATERAL()), "supportsPair is not the constructor's ordered pair";
}

// a wrong-pair read is a wiring bug, so it refuses loudly rather than answering
rule everyReadRefusesAnyOtherPair(env e, address q, address c, uint256 x) {
    require e.msg.value == 0;
    require q != QUOTE() || c != COLLATERAL();
    lastObserved@withrevert(e, q, c);
    assert lastReverted, "lastObserved answered a pair it does not price";
    minPrice@withrevert(e, q, c);
    assert lastReverted, "minPrice answered a pair it does not price";
    persistedBelowDistress@withrevert(e, q, c, x);
    assert lastReverted, "persistedBelowDistress answered a pair it does not price";
    persistedBelowSettle@withrevert(e, q, c, x);
    assert lastReverted, "persistedBelowSettle answered a pair it does not price";
    persistedAbove@withrevert(e, q, c, x);
    assert lastReverted, "persistedAbove answered a pair it does not price";
}

// ---- OR-6: one current price behind every read ----

// THE WINDOWED MINIMUM IS THE CURRENT PRICE, the twins are `p != 0 && p < x` off it, and above-ness is `p > x`. So the
// twins agree for every input, and a dark price is never below anything. This record holds no window, by ruling.
rule theReadsAreOneCurrentPrice(env e, uint256 x) {
    address q = QUOTE();
    address c = COLLATERAL();
    uint256 p = lastObserved(e, q, c);
    assert minPrice(e, q, c) == p, "minPrice parted from lastObserved";
    assert persistedBelowDistress(e, q, c, x) == (p != 0 && p < x), "the distress twin is not below-ness of the price";
    assert persistedBelowSettle(e, q, c, x) == (p != 0 && p < x), "the settle twin is not below-ness of the price";
    assert persistedAbove(e, q, c, x) == (p > x), "persistedAbove is not above-ness of the price";
}

// ---- OR-7: monotonicity ----

// A HIGHER ANSWER NEVER LOWERS THE PRICE while the read still answers: an answer past the absurd edge reads CLOSED, so
// the price falls to zero there, which is OR-2 rather than a price drop.
rule aHigherAnswerNeverLowersThePrice(env e, int256 a1, int256 a2) {
    require FEED() == feed;
    require a2 >= a1;

    storage genesis = lastStorage;
    feed.setAnswer(a1);
    uint256 p1 = lastObserved(e, QUOTE(), COLLATERAL());

    feed.setAnswer(a2) at genesis;
    uint256 p2 = lastObserved(e, QUOTE(), COLLATERAL());

    require p2 != 0;
    assert p2 >= p1, "a higher answer lowered the price while the read still answered";
}

// ---- witnesses: the rules above are not passing on a record that never prices ----

rule aLivePriceIsReachable(env e) {
    require FEED() == feed;
    satisfy lastObserved(e, QUOTE(), COLLATERAL()) > 0;
}

rule anAgeOfExactlyTheBoundStillPrices(env e) {
    require FEED() == feed;
    require to_mathint(e.block.timestamp) - to_mathint(feed.updatedAtView()) == to_mathint(MAX_STALENESS());
    satisfy lastObserved(e, QUOTE(), COLLATERAL()) > 0;
}

rule theTwinsCanAnswerBelow(env e, uint256 x) {
    require FEED() == feed;
    satisfy persistedBelowSettle(e, QUOTE(), COLLATERAL(), x);
}
