// MultiPairOracleRecord: many ordered pairs at one address, each reading its own Chainlink-shaped feed, registered once
// by the owner. Proven against what the hub asks of a record, per pair, and against the registry's own laws.
//
// WHAT THE HUB ASKS is OracleRecord.spec's header, now per pair: genesis's four reads answer, `minPrice` is the draw cap,
// the twins gate distress and settlement, and a revert on a twin BLOCKS settlement. MP-3 proves it of every registered pair.
//
// THE FEEDS AND THE TOKENS ARE MOCKS WHOSE BODIES RUN, DISPATCHED BY ADDRESS, NEVER LINKED: registration takes all three as
// arguments and reads their decimals there, so a pair's frame is tied to its sources by MP-1, a rule over the real
// `registerPair`, rather than by a constructor base case. Two feed contracts with their own storage let MP-4 move one
// pair's feed and read a pair priced off the other. Every mock answers in full or reverts.
//
// THE PAIR'S STORED WIRING IS FREE STORAGE in every rule, so the read rules are stated against it; MP-0 is the invariant
// that keeps a registered pair's frame in the range registration writes, which is what the no-revert rule rests on.
//
// `mulDiv` is EXACT with its reverting cases recorded in ghosts, as in OracleRecord.spec. The record reads no aggregator
// floor: every fit answer prices at the exact frame. Whether a pair's feed holds a live floor is its owner's check.
using MockPriceFeed as feedA;
using MockPriceFeedB as feedB;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivExact(a, b, d);

    // the feed and both tokens arrive as `registerPair` arguments, so none can be linked: see the header
    function _.decimals() external => DISPATCHER(true);
    function _.latestRoundData() external => DISPATCHER(true);

    function supportsPair(address, address) external returns (bool) envfree;
    function owner() external returns (address) envfree;
    function pairFeed(address, address) external returns (address) envfree;
    function pairStaleness(address, address) external returns (uint256) envfree;
    function pairNum(address, address) external returns (uint256) envfree;
    function pairDen(address, address) external returns (uint256) envfree;
    function decimalsOf(address) external returns (uint8) envfree;

    function MockPriceFeed.answerView() external returns (int256) envfree;
    function MockPriceFeed.updatedAtView() external returns (uint256) envfree;
    function MockPriceFeed.roundIdView() external returns (uint80) envfree;
    function MockPriceFeed.answeredInRoundView() external returns (uint80) envfree;
    function MockPriceFeed.revertsView() external returns (bool) envfree;
    function MockPriceFeed.setAnswer(int256) external envfree;
    function MockPriceFeedB.setRound(uint80, int256, uint256, uint80, bool) external envfree;
}

ghost bool zeroDenSeen;
ghost bool overflowSeen;

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

// feed A's round is fit under the pair's own staleness bound
function fitRound(env e, address q, address c) returns bool {
    return !feedA.revertsView()
        && feedA.answerView() > 0
        && feedA.answeredInRoundView() >= feedA.roundIdView()
        && to_mathint(feedA.updatedAtView()) <= to_mathint(e.block.timestamp)
        && to_mathint(e.block.timestamp) - to_mathint(feedA.updatedAtView()) <= to_mathint(pairStaleness(q, c));
}

function readsDark(env e, address q, address c, uint256 x) returns bool {
    return lastObserved(e, q, c) == 0
        && minPrice(e, q, c) == 0
        && !persistedBelowDistress(e, q, c, x)
        && !persistedBelowSettle(e, q, c, x)
        && !persistedAbove(e, q, c, x);
}

// the pair (q, c) is registered on feed A, with the frame MP-0 keeps it in
function onFeedA(address q, address c) {
    requireInvariant aRegisteredPairIsFramed(q, c);
    require pairFeed(q, c) == feedA;
}

// ---- MP-0: a registered pair's wiring stays in the range registration writes ----

// A REGISTERED PAIR IS TWO DISTINCT NON-ZERO TOKENS WITH A FRAME: a staleness bound in (0, 2^96), a numerator in
// [2^96, 2^96 * 10^18] (the token rail is 18 decimals), a denominator of at least one, and its inverse unregistered.
// The base case is the empty registry; the step is `registerPair`, the one writer.
invariant aRegisteredPairIsFramed(address q, address c)
    pairFeed(q, c) != 0 => (
        q != 0 && c != 0 && q != c
            && pairStaleness(q, c) != 0 && to_mathint(pairStaleness(q, c)) < 2^96
            && to_mathint(pairNum(q, c)) >= 2^96 && to_mathint(pairNum(q, c)) <= 2^96 * 10^18
            && pairDen(q, c) != 0
            && pairFeed(c, q) == 0
    )
    filtered { f -> f.contract == currentContract }

// ---- MP-1: registration writes the pair's frame, read once off the three decimals ----

// A REGISTRATION STORES THE FEED, THE BOUND AND THE FRAME `2^96 * 10^quoteDecimals` over `10^feedDecimals *
// 10^collateralDecimals`, each decimals read off the very address registered. A decimals mutant fails here.
rule aRegistrationWritesThePairsFrame(env e, address q, address c, address f, uint256 s) {
    registerPair(e, q, c, f, s);
    assert pairFeed(q, c) == f, "registration stored another feed";
    assert pairStaleness(q, c) == s, "registration stored another staleness bound";
    assert to_mathint(pairNum(q, c)) == 2^96 * 10^decimalsOf(q), "the numerator is not the quote's frame";
    assert to_mathint(pairDen(q, c)) == 10^decimalsOf(f) * 10^decimalsOf(c), "the denominator is not the feed's and the collateral's scale";
}

// A REGISTRATION THAT LANDS cleared every rail: the owner, a feed, a bound in (0, 2^96), two distinct tokens of at
// most 18 decimals, and neither the pair nor its inverse registered before.
rule aRegistrationClearsItsRails(env e, address q, address c, address f, uint256 s) {
    address ownerBefore = owner();
    bool pairBefore = pairFeed(q, c) != 0;
    bool inverseBefore = pairFeed(c, q) != 0;
    registerPair(e, q, c, f, s);
    assert e.msg.sender == ownerBefore, "a stranger registered a pair";
    assert f != 0 && s != 0 && to_mathint(s) < 2^96, "a registration took a zero feed or an unrepresentable bound";
    assert q != 0 && c != 0 && q != c, "a registration took a zero token or a self-pair";
    assert decimalsOf(q) <= 18 && decimalsOf(c) <= 18, "a registration took a token over 18 decimals";
    assert !pairBefore, "a registration rewired a registered pair";
    assert !inverseBefore, "a registration landed beside its own inverse";
}

// and the owner really can register, so the rails above are not passing on a door nobody opens
rule theOwnerCanRegister(env e, address q, address c, address f, uint256 s) {
    registerPair(e, q, c, f, s);
    satisfy supportsPair(q, c);
}

// A REGISTERED PAIR'S WIRING NEVER CHANGES, by any record method: add-only, never rewired, never removed.
rule aRegisteredPairIsNeverRewired(method f, env e, calldataarg args, address q, address c)
    filtered { f -> f.contract == currentContract }
{
    require pairFeed(q, c) != 0;
    address feedBefore = pairFeed(q, c);
    uint256 sBefore = pairStaleness(q, c);
    uint256 numBefore = pairNum(q, c);
    uint256 denBefore = pairDen(q, c);
    f(e, args);
    assert pairFeed(q, c) == feedBefore && pairStaleness(q, c) == sBefore, "a registered pair was rewired";
    assert pairNum(q, c) == numBefore && pairDen(q, c) == denBefore, "a registered pair was reframed";
}

// ONLY THE OWNER'S `registerPair` ADDS A PAIR
rule onlyTheOwnersRegistrationAddsAPair(method f, env e, calldataarg args, address q, address c)
    filtered { f -> f.contract == currentContract }
{
    address ownerBefore = owner();
    bool before = supportsPair(q, c);
    f(e, args);
    assert !before && supportsPair(q, c) =>
        (f.selector == sig:registerPair(address, address, address, uint256).selector && e.msg.sender == ownerBefore),
        "a pair was added by something other than the owner's registration";
}

// ---- MP-3: every registered pair reads as an OracleRecord would ----

// A FIT ROUND PRICES AT THE PAIR'S EXACT FRAMED FLOOR, rounded down once.
rule aFitRoundPricesAtThePairsExactFrame(env e, address q, address c) {
    onFeedA(q, c);
    require fitRound(e, q, c);
    mathint a = to_mathint(feedA.answerView());
    require a <= to_mathint(max_uint256) / to_mathint(pairNum(q, c));

    uint256 p = lastObserved(e, q, c);
    assert to_mathint(p) == (a * to_mathint(pairNum(q, c))) / to_mathint(pairDen(q, c)),
        "a fit round did not price at the pair's exact framed floor";
}

rule aRevertingFeedReadsDark(env e, address q, address c, uint256 x) {
    onFeedA(q, c);
    require feedA.revertsView();
    assert readsDark(e, q, c, x), "a reverting feed answered a live read";
}

rule aNonPositiveAnswerReadsDark(env e, address q, address c, uint256 x) {
    onFeedA(q, c);
    require feedA.answerView() <= 0;
    assert readsDark(e, q, c, x), "a non-positive answer answered a live read";
}

rule anIncompleteRoundReadsDark(env e, address q, address c, uint256 x) {
    onFeedA(q, c);
    require feedA.answeredInRoundView() < feedA.roundIdView();
    assert readsDark(e, q, c, x), "an incomplete round answered a live read";
}

rule aFutureStampReadsDark(env e, address q, address c, uint256 x) {
    onFeedA(q, c);
    require to_mathint(feedA.updatedAtView()) > to_mathint(e.block.timestamp);
    assert readsDark(e, q, c, x), "a round stamped ahead of the chain answered a live read";
}

// the pair's own bound, never another pair's: an age of exactly it is still fit
rule aStaleRoundReadsDark(env e, address q, address c, uint256 x) {
    onFeedA(q, c);
    require to_mathint(feedA.updatedAtView()) <= to_mathint(e.block.timestamp);
    require to_mathint(e.block.timestamp) - to_mathint(feedA.updatedAtView()) > to_mathint(pairStaleness(q, c));
    assert readsDark(e, q, c, x), "a round stale under the pair's bound answered a live read";
}

rule anAbsurdAnswerReadsDark(env e, address q, address c, uint256 x) {
    onFeedA(q, c);
    require to_mathint(feedA.answerView()) > to_mathint(max_uint256) / to_mathint(pairNum(q, c));
    assert readsDark(e, q, c, x), "an answer too wide for the pair's frame answered a live read";
}

// EVERY READ ON A REGISTERED PAIR ANSWERS, for every state of its feed, a reverting feed included.
rule noReadOnARegisteredPairEverReverts(env e, address q, address c, uint256 x) {
    onFeedA(q, c);
    require e.msg.value == 0;

    supportsPair@withrevert(q, c);
    assert !lastReverted, "supportsPair reverted";
    lastObserved@withrevert(e, q, c);
    assert !lastReverted, "lastObserved reverted on a registered pair";
    minPrice@withrevert(e, q, c);
    assert !lastReverted, "minPrice reverted on a registered pair";
    persistedBelowDistress@withrevert(e, q, c, x);
    assert !lastReverted, "persistedBelowDistress reverted on a registered pair";
    persistedBelowSettle@withrevert(e, q, c, x);
    assert !lastReverted, "persistedBelowSettle reverted on a registered pair, which would block settlement";
    persistedAbove@withrevert(e, q, c, x);
    assert !lastReverted, "persistedAbove reverted on a registered pair";
}

// AND EXACTLY WHEN THEY CAN: each read the hub makes reverts if and only if the pair is unregistered or the call
// carries value. The registered pair here is on feed A; a pair on feed B is the same statement by symmetry.
rule theHubsReadsRevertExactlyOnAnUnregisteredPairOrValue(env e, address q, address c, uint256 x) {
    requireInvariant aRegisteredPairIsFramed(q, c);
    require pairFeed(q, c) == 0 || pairFeed(q, c) == feedA;
    bool refused = pairFeed(q, c) == 0 || e.msg.value != 0;

    minPrice@withrevert(e, q, c);
    assert lastReverted <=> refused, "minPrice reverted other than on an unregistered pair or a value";
    persistedBelowDistress@withrevert(e, q, c, x);
    assert lastReverted <=> refused, "persistedBelowDistress reverted other than on an unregistered pair or a value";
    persistedBelowSettle@withrevert(e, q, c, x);
    assert lastReverted <=> refused, "persistedBelowSettle reverted other than on an unregistered pair or a value";
}

rule theRecordReachesNoRevertingMulDiv(env e, address q, address c) {
    onFeedA(q, c);
    require !zeroDenSeen && !overflowSeen;
    lastObserved(e, q, c);
    assert !zeroDenSeen, "a zero divisor reached mulDiv, which the real library reverts on";
    assert !overflowSeen, "an absurd answer's quotient reached mulDiv, which the real library reverts on";
}

rule supportsPairIsRegistration(address q, address c) {
    assert supportsPair(q, c) <=> pairFeed(q, c) != 0, "supportsPair is not the registry";
}

// an unregistered pair refuses every read loudly
rule everyReadRefusesAnUnregisteredPair(env e, address q, address c, uint256 x) {
    require e.msg.value == 0;
    require pairFeed(q, c) == 0;
    lastObserved@withrevert(e, q, c);
    assert lastReverted, "lastObserved answered an unregistered pair";
    minPrice@withrevert(e, q, c);
    assert lastReverted, "minPrice answered an unregistered pair";
    persistedBelowDistress@withrevert(e, q, c, x);
    assert lastReverted, "persistedBelowDistress answered an unregistered pair";
    persistedBelowSettle@withrevert(e, q, c, x);
    assert lastReverted, "persistedBelowSettle answered an unregistered pair";
    persistedAbove@withrevert(e, q, c, x);
    assert lastReverted, "persistedAbove answered an unregistered pair";
}

rule theReadsAreOneCurrentPrice(env e, address q, address c, uint256 x) {
    uint256 p = lastObserved(e, q, c);
    assert minPrice(e, q, c) == p, "minPrice parted from lastObserved";
    assert persistedBelowDistress(e, q, c, x) == (p != 0 && p < x), "the distress twin is not below-ness of the price";
    assert persistedBelowSettle(e, q, c, x) == (p != 0 && p < x), "the settle twin is not below-ness of the price";
    assert persistedAbove(e, q, c, x) == (p > x), "persistedAbove is not above-ness of the price";
}

rule aHigherAnswerNeverLowersThePrice(env e, address q, address c, int256 a1, int256 a2) {
    require pairFeed(q, c) == feedA;
    require a2 >= a1;

    storage genesis = lastStorage;
    feedA.setAnswer(a1);
    uint256 p1 = lastObserved(e, q, c);

    feedA.setAnswer(a2) at genesis;
    uint256 p2 = lastObserved(e, q, c);

    require p2 != 0;
    assert p2 >= p1, "a higher answer lowered the pair's price while the read still answered";
}

// ---- MP-4: each pair's answer depends only on its own wiring and its own feed ----

// MOVING ANOTHER FEED, IN ANY WAY, NEVER MOVES A PAIR PRICED OFF THIS ONE. No invariant is assumed, so a record that
// read another pair's wiring (the inverse's, say, which free storage may put on feed B) would fail here.
rule anotherFeedNeverMovesThisPair(env e, address q, address c, uint256 x, uint80 r, int256 a, uint256 u, uint80 inRound, bool down) {
    require pairFeed(q, c) == feedA;
    uint256 p1 = lastObserved(e, q, c);
    bool s1 = persistedBelowSettle(e, q, c, x);
    feedB.setRound(r, a, u, inRound, down);
    assert lastObserved(e, q, c) == p1, "moving another feed moved this pair's price";
    assert persistedBelowSettle(e, q, c, x) == s1, "moving another feed moved this pair's settle twin";
}

// NO RECORD METHOD MOVES A REGISTERED PAIR'S PRICE: registering any other pair and every ownership move included.
rule noRecordMethodMovesARegisteredPairsPrice(method f, env e, env eRead, calldataarg args, address q, address c)
    filtered { f -> f.contract == currentContract }
{
    require pairFeed(q, c) == feedA;
    uint256 p1 = lastObserved(eRead, q, c);
    f(e, args);
    assert lastObserved(eRead, q, c) == p1, "a record method moved a registered pair's price";
}

// ---- witnesses ----

rule aLivePriceIsReachable(env e, address q, address c) {
    onFeedA(q, c);
    satisfy lastObserved(e, q, c) > 0;
}

rule theTwinsCanAnswerBelow(env e, address q, address c, uint256 x) {
    onFeedA(q, c);
    satisfy persistedBelowSettle(e, q, c, x);
}
