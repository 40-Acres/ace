// YbRecord: the ORACLE-class record for YieldBasis collateral, proven against what the hub asks of it and against the
// bound its draw cap owes: never above the rate the collateral actually redeems at, which `pricePerShare` alone is not.
//
// THE PRICE: usd x rate / 1e18 [x c2a / 1e18], framed by `mulDiv(., PRICE_NUM, PRICE_DEN)`. The rate is
// `min(pricePerShare, preview_withdraw(1e18) x WITHDRAW_SCALE)` for `minPrice`, `lastObserved` and `persistedAbove`
// (the draw cap: the realizable rate), and `pricePerShare` alone for the two below-twins (the accounting rate), which still
// CALL and CHECK the redemption leg. The finding asked for the min; the header's claim is that a pool dent lowers the draw
// cap and never opens settlement or the band. YB-3 and YB-4 are those two sentences.
//
// WHAT THE HUB ASKS is OracleRecord.spec's header: genesis's four reads answer, `minPrice` is the draw cap, the twins gate
// distress and settlement, and a revert on a twin BLOCKS settlement. So YB-5 proves no read on the pair ever reverts.
//
// EVERY EXTERNAL PARTY IS A MOCK WHOSE BODY RUNS, DISPATCHED BY ADDRESS, NEVER LINKED: the feed, the LT, the gauge, the
// quote and the underlying are all constructor arguments, and a link binds an immutable without binding the argument
// the constructor interviews (OracleRecord.spec's header). The LT and the gauge answer `preview_withdraw` and
// `convertToAssets` PER SHARE COUNT, so the exact rule, which reads them at one share, catches a record asking about any
// other count. Each rate leg reverts on its own flag. Every mock answers in full or reverts.
//
// `mulDiv` is EXACT with its reverting cases recorded in ghosts. `Math.tryMul` and `Math.min` run as written.
//
// THE CONSTRUCTOR'S RAILS ARE PINNED AS STATE: YB-0's four invariants hold of the constructed record, each a base case
// through the real constructor, so a dropped or mis-scaled rail fails there.
using MockPriceFeed as feed;
using MockYbLt as lt;
using MockYbGauge as gauge;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivExact(a, b, d);

    // every party arrives as a constructor argument, so none can be linked: see the header
    function _.decimals() external => DISPATCHER(true);
    function _.latestRoundData() external => DISPATCHER(true);
    function _.pricePerShare() external => DISPATCHER(true);
    function _.preview_withdraw(uint256) external => DISPATCHER(true);
    function _.ASSET_TOKEN() external => DISPATCHER(true);
    function _.asset() external => DISPATCHER(true);
    function _.convertToAssets(uint256) external => DISPATCHER(true);

    function supportsPair(address, address) external returns (bool) envfree;
    function FEED() external returns (address) envfree;
    function LT() external returns (address) envfree;
    function GAUGE() external returns (address) envfree;
    function QUOTE() external returns (address) envfree;
    function COLLATERAL() external returns (address) envfree;
    function UNDERLYING() external returns (address) envfree;
    function WITHDRAW_SCALE() external returns (uint256) envfree;
    function MAX_STALENESS() external returns (uint256) envfree;

    function priceNum() external returns (uint256) envfree;
    function priceDen() external returns (uint256) envfree;
    function quoteDecimals() external returns (uint8) envfree;
    function feedDecimals() external returns (uint8) envfree;
    function collateralDecimals() external returns (uint8) envfree;
    function underlyingDecimals() external returns (uint8) envfree;

    function MockPriceFeed.answerView() external returns (int256) envfree;
    function MockPriceFeed.updatedAtView() external returns (uint256) envfree;
    function MockPriceFeed.roundIdView() external returns (uint80) envfree;
    function MockPriceFeed.answeredInRoundView() external returns (uint80) envfree;
    function MockPriceFeed.revertsView() external returns (bool) envfree;
    function MockPriceFeed.setAnswer(int256) external envfree;

    function MockYbLt.decimals() external returns (uint8) envfree;
    function MockYbLt.ASSET_TOKEN() external returns (address) envfree;
    function MockYbLt.ppsView() external returns (uint256) envfree;
    function MockYbLt.withdrawView(uint256) external returns (uint256) envfree;
    function MockYbLt.ppsRevertsView() external returns (bool) envfree;
    function MockYbLt.previewRevertsView() external returns (bool) envfree;
    function MockYbLt.setPps(uint256) external envfree;
    function MockYbLt.setWithdraw(uint256, uint256) external envfree;

    function MockYbGauge.decimals() external returns (uint8) envfree;
    function MockYbGauge.asset() external returns (address) envfree;
    function MockYbGauge.assetsView(uint256) external returns (uint256) envfree;
    function MockYbGauge.revertsView() external returns (bool) envfree;
}

definition ONE_SHARE() returns uint256 = 1000000000000000000;

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

// THE USD ROUND IS FIT, as `ChainlinkDataFeed.latest` documents it
function fitRound(env e) returns bool {
    return !feed.revertsView()
        && feed.answerView() > 0
        && feed.answeredInRoundView() >= feed.roundIdView()
        && to_mathint(feed.updatedAtView()) <= to_mathint(e.block.timestamp)
        && to_mathint(e.block.timestamp) - to_mathint(feed.updatedAtView()) <= to_mathint(MAX_STALENESS());
}

// the redemption quote for one share, rescaled into the 18-decimal frame `pricePerShare` uses
function scaledWithdraw() returns mathint {
    return to_mathint(lt.withdrawView(ONE_SHARE())) * to_mathint(WITHDRAW_SCALE());
}

// EVERY LEG ANSWERS A USABLE WORD: a fit round, both rate legs answering non-zero, the rescale fitting, the gauge answering
function legsFit(env e) returns bool {
    return fitRound(e)
        && !lt.ppsRevertsView() && lt.ppsView() != 0
        && !lt.previewRevertsView() && lt.withdrawView(ONE_SHARE()) != 0
        && scaledWithdraw() <= to_mathint(max_uint256)
        && (GAUGE() == 0 || !gauge.revertsView());
}

// the composed human price at `rate`, the gauge's one-share conversion composed in on a gauge market
function composedAt(mathint rate) returns mathint {
    mathint h = (to_mathint(feed.answerView()) * rate) / to_mathint(ONE_SHARE());
    if (GAUGE() == 0) {
        return h;
    }
    return (h * to_mathint(gauge.assetsView(ONE_SHARE()))) / to_mathint(ONE_SHARE());
}

// the products the record forms at `rate` all fit, so neither `tryMul` closes the read
function productsFitAt(mathint rate) returns bool {
    mathint h = (to_mathint(feed.answerView()) * rate) / to_mathint(ONE_SHARE());
    return to_mathint(feed.answerView()) * rate <= to_mathint(max_uint256)
        && (GAUGE() == 0 || h * to_mathint(gauge.assetsView(ONE_SHARE())) <= to_mathint(max_uint256));
}

function framed(mathint human) returns mathint {
    return (human * to_mathint(priceNum())) / to_mathint(priceDen());
}

function minRate() returns mathint {
    mathint pps = to_mathint(lt.ppsView());
    mathint w = scaledWithdraw();
    return pps < w ? pps : w;
}

function readsDark(env e, uint256 x) returns bool {
    address q = QUOTE();
    address c = COLLATERAL();
    return lastObserved(e, q, c) == 0
        && minPrice(e, q, c) == 0
        && !persistedBelowDistress(e, q, c, x)
        && !persistedBelowSettle(e, q, c, x)
        && !persistedAbove(e, q, c, x);
}

function theRailsHold() {
    requireInvariant theFrameIsTheConstructorsFrame();
    requireInvariant theCollateralIsTheLtOrItsGauge();
    requireInvariant theRescaleIsTheUnderlyings();
    require FEED() == feed;
}

// ---- YB-0: what the constructor fixes, each a base case through the real constructor ----

// THE FRAME: `PRICE_NUM = 2^96 * 10^quoteDecimals`, `PRICE_DEN = 10^feedDecimals * 10^18`, the collateral being one
// 18-decimal share. The decimals bounds are the constructor's own checked arithmetic (past them it overflows and
// reverts), stated because the prover's power-of-ten table stops at 10^77.
invariant theFrameIsTheConstructorsFrame()
    to_mathint(quoteDecimals()) <= 48
        && to_mathint(feedDecimals()) <= 59
        && collateralDecimals() == 18
        && to_mathint(priceNum()) == 2^96 * 10^quoteDecimals()
        && to_mathint(priceDen()) == 10^feedDecimals() * 10^18;

// THE COLLATERAL IS THE LT OR ITS GAUGE, each 18-decimal, and a gauge stakes exactly this LT.
invariant theCollateralIsTheLtOrItsGauge()
    LT() == lt && lt.decimals() == 18
        && (GAUGE() == 0
            ? COLLATERAL() == LT()
            : (GAUGE() == gauge && COLLATERAL() == GAUGE() && gauge.asset() == LT() && gauge.decimals() == 18));

// THE RESCALE IS THE REDEEMED TOKEN'S: the underlying is the LT's own `ASSET_TOKEN`, at most 18 decimals, and
// `WITHDRAW_SCALE = 10^(18 - underlyingDecimals)`, so an 8-decimal BTC quote lifts by 10^10 into pps's frame.
invariant theRescaleIsTheUnderlyings()
    UNDERLYING() == lt.ASSET_TOKEN()
        && to_mathint(underlyingDecimals()) <= 18
        && to_mathint(WITHDRAW_SCALE()) == 10^(18 - to_mathint(underlyingDecimals()));

invariant theWiringIsSound()
    FEED() != 0 && QUOTE() != 0 && QUOTE() != LT() && UNDERLYING() != 0 && MAX_STALENESS() != 0;

// ---- YB-1: the exact draw cap ----

// EVERY LEG FIT, THE DRAW CAP IS THE EXACT FRAMED FLOOR AT THE LOWER RATE: `floor(composed(min(pps, w x scale)) x
// PRICE_NUM / PRICE_DEN)`, each division a floor, the redemption leg and the gauge read at ONE share.
rule theDrawCapIsTheExactFrameAtTheLowerRate(env e) {
    theRailsHold();
    require legsFit(e);
    mathint rate = minRate();
    require productsFitAt(rate);
    mathint human = composedAt(rate);
    require human <= to_mathint(max_uint256) / to_mathint(priceNum());

    uint256 p = minPrice(e, QUOTE(), COLLATERAL());
    assert to_mathint(p) == framed(human), "the draw cap is not the exact framed floor at the lower of the two rates";
}

// and the twins' price is the same composition at the accounting rate, the redemption leg still read and checked
rule theTwinsPriceIsTheExactFrameAtTheAccountingRate(env e) {
    theRailsHold();
    require legsFit(e);
    mathint rate = to_mathint(lt.ppsView());
    require productsFitAt(rate);
    mathint human = composedAt(rate);
    require human <= to_mathint(max_uint256) / to_mathint(priceNum());

    uint256 a = accountingPrice(e);
    assert to_mathint(a) == framed(human), "the twins' price is not the exact framed floor at the accounting rate";
}

// ---- YB-2: which read answers off which rate ----

rule theReadsAnswerOffTheirRates(env e, uint256 x) {
    address q = QUOTE();
    address c = COLLATERAL();
    uint256 r = realizablePrice(e);
    uint256 a = accountingPrice(e);
    assert minPrice(e, q, c) == r, "minPrice is not the realizable price";
    assert lastObserved(e, q, c) == r, "lastObserved is not the realizable price";
    assert persistedAbove(e, q, c, x) == (r > x), "persistedAbove is not above-ness of the realizable price";
    assert persistedBelowDistress(e, q, c, x) == (a != 0 && a < x), "the distress twin is not below-ness at the accounting rate";
    assert persistedBelowSettle(e, q, c, x) == (a != 0 && a < x), "the settle twin is not below-ness at the accounting rate";
}

// ---- YB-3: the finding's bound, the draw cap never above what the collateral redeems for ----

// THE DRAW CAP NEVER EXCEEDS THE ACCOUNTING PRICE the twins read, wherever that price answers.
rule theDrawCapNeverExceedsTheAccountingPrice(env e) {
    theRailsHold();
    uint256 a = accountingPrice(e);
    require a != 0;
    assert minPrice(e, QUOTE(), COLLATERAL()) <= a, "the draw cap exceeded the accounting-rate price";
}

// THE DRAW CAP NEVER EXCEEDS THE PRICE AT THE REDEMPTION RATE, the ZeroLend gap the finding measured.
rule theDrawCapNeverExceedsTheRedemptionRate(env e) {
    theRailsHold();
    require legsFit(e);
    mathint rate = scaledWithdraw();
    require productsFitAt(rate);
    mathint human = composedAt(rate);
    require human <= to_mathint(max_uint256) / to_mathint(priceNum());
    assert to_mathint(minPrice(e, QUOTE(), COLLATERAL())) <= framed(human), "the draw cap exceeded the price at the redemption rate";
}

// ---- YB-4: a dent in the pool lowers the draw cap and never moves the twins ----

// TWO REDEMPTION QUOTES, BOTH USABLE, ANSWER THE SAME TWINS: a swap that dents the pool opens neither settlement nor the band.
rule aDentNeverMovesTheTwins(env e, uint256 x, uint256 w1, uint256 w2) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require w1 != 0 && w2 != 0;
    require to_mathint(w1) * to_mathint(WITHDRAW_SCALE()) <= to_mathint(max_uint256);
    require to_mathint(w2) * to_mathint(WITHDRAW_SCALE()) <= to_mathint(max_uint256);
    address q = QUOTE();
    address c = COLLATERAL();

    storage genesis = lastStorage;
    lt.setWithdraw(ONE_SHARE(), w1);
    bool d1 = persistedBelowDistress(e, q, c, x);
    bool s1 = persistedBelowSettle(e, q, c, x);

    lt.setWithdraw(ONE_SHARE(), w2) at genesis;
    bool d2 = persistedBelowDistress(e, q, c, x);
    bool s2 = persistedBelowSettle(e, q, c, x);

    assert d1 == d2, "a dent in the redemption quote moved the distress twin";
    assert s1 == s2, "a dent in the redemption quote moved the settle twin";
}

// and the dent never RAISES the draw cap: a lower redemption quote prices at or under a higher one while the higher answers
rule aDentNeverRaisesTheDrawCap(env e, uint256 w1, uint256 w2) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require w2 <= w1;
    address q = QUOTE();
    address c = COLLATERAL();

    storage genesis = lastStorage;
    lt.setWithdraw(ONE_SHARE(), w1);
    uint256 p1 = minPrice(e, q, c);

    lt.setWithdraw(ONE_SHARE(), w2) at genesis;
    uint256 p2 = minPrice(e, q, c);

    require p1 != 0;
    assert p2 <= p1, "a lower redemption quote raised the draw cap";
}

// ---- YB-5: every unfit leg reads dark at every read, and no read on the pair ever reverts ----

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

rule aFutureStampReadsDark(env e, uint256 x) {
    require FEED() == feed;
    require to_mathint(feed.updatedAtView()) > to_mathint(e.block.timestamp);
    assert readsDark(e, x), "a round stamped ahead of the chain answered a live read";
}

rule aStaleRoundReadsDark(env e, uint256 x) {
    require FEED() == feed;
    require to_mathint(feed.updatedAtView()) <= to_mathint(e.block.timestamp);
    require to_mathint(e.block.timestamp) - to_mathint(feed.updatedAtView()) > to_mathint(MAX_STALENESS());
    assert readsDark(e, x), "a stale round answered a live read";
}

rule aZeroAccountingRateReadsDark(env e, uint256 x) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require lt.ppsView() == 0;
    assert readsDark(e, x), "a zero pricePerShare answered a live read";
}

rule aRevertingAccountingRateReadsDark(env e, uint256 x) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require lt.ppsRevertsView();
    assert readsDark(e, x), "a reverting pricePerShare answered a live read";
}

rule aZeroRedemptionQuoteReadsDark(env e, uint256 x) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require lt.withdrawView(ONE_SHARE()) == 0;
    assert readsDark(e, x), "a zero preview_withdraw answered a live read";
}

// A LOCKED POOL CLOSES THE TWINS TOO: they call the redemption leg and refuse to answer off accounting mid-operation.
rule aRevertingRedemptionQuoteReadsDark(env e, uint256 x) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require lt.previewRevertsView();
    assert readsDark(e, x), "a reverting preview_withdraw answered a live read";
}

rule anAbsurdRedemptionQuoteReadsDark(env e, uint256 x) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require scaledWithdraw() > to_mathint(max_uint256);
    assert readsDark(e, x), "a redemption quote too wide to rescale answered a live read";
}

rule aRevertingGaugeReadsDark(env e, uint256 x) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require GAUGE() != 0 && gauge.revertsView();
    assert readsDark(e, x), "a reverting gauge answered a live read";
}

rule aZeroGaugeConversionReadsDark(env e, uint256 x) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require GAUGE() != 0 && gauge.assetsView(ONE_SHARE()) == 0;
    assert readsDark(e, x), "a zero gauge conversion answered a live read";
}

// a composed product too wide to carry closes the read that formed it rather than panicking
rule anAbsurdAccountingProductClosesTheTwins(env e, uint256 x) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require to_mathint(feed.answerView()) * to_mathint(lt.ppsView()) > to_mathint(max_uint256);
    assert !persistedBelowDistress(e, QUOTE(), COLLATERAL(), x), "an absurd accounting product answered the distress twin";
    assert !persistedBelowSettle(e, QUOTE(), COLLATERAL(), x), "an absurd accounting product answered the settle twin";
}

rule anAbsurdRealizableProductClosesTheDrawCap(env e) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require to_mathint(feed.answerView()) * minRate() > to_mathint(max_uint256);
    assert minPrice(e, QUOTE(), COLLATERAL()) == 0, "an absurd realizable product answered the draw cap";
}

// EVERY READ ON THE PAIR ANSWERS, for every state of every leg, each one reverting included. A revert on a twin would
// block settlement and one on `minPrice` would brick genesis.
rule noReadOnThePairEverReverts(env e, uint256 x) {
    theRailsHold();
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

// and exactly when they can: a wrong pair or a call carrying value, and nothing else
rule theHubsReadsRevertExactlyOnAWrongPairOrValue(env e, address q, address c, uint256 x) {
    theRailsHold();
    bool refused = q != QUOTE() || c != COLLATERAL() || e.msg.value != 0;

    minPrice@withrevert(e, q, c);
    assert lastReverted <=> refused, "minPrice reverted other than on a wrong pair or a value";
    persistedBelowDistress@withrevert(e, q, c, x);
    assert lastReverted <=> refused, "persistedBelowDistress reverted other than on a wrong pair or a value";
    persistedBelowSettle@withrevert(e, q, c, x);
    assert lastReverted <=> refused, "persistedBelowSettle reverted other than on a wrong pair or a value";
}

rule theRecordReachesNoRevertingMulDiv(env e, uint256 x) {
    theRailsHold();
    require !zeroDenSeen && !overflowSeen;
    minPrice(e, QUOTE(), COLLATERAL());
    persistedBelowSettle(e, QUOTE(), COLLATERAL(), x);
    assert !zeroDenSeen, "a zero divisor reached mulDiv, which the real library reverts on";
    assert !overflowSeen, "an absurd price's quotient reached mulDiv, which the real library reverts on";
}

// ---- YB-6: the pair ----

rule thePairIsTheConstructorsPair(address q, address c) {
    assert supportsPair(q, c) <=> (q == QUOTE() && c == COLLATERAL()), "supportsPair is not the constructor's ordered pair";
}

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

// ---- YB-7: monotonicity ----

rule aHigherFeedAnswerNeverLowersTheDrawCap(env e, int256 a1, int256 a2) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require a2 >= a1;

    storage genesis = lastStorage;
    feed.setAnswer(a1);
    uint256 p1 = minPrice(e, QUOTE(), COLLATERAL());

    feed.setAnswer(a2) at genesis;
    uint256 p2 = minPrice(e, QUOTE(), COLLATERAL());

    require p2 != 0;
    assert p2 >= p1, "a higher feed answer lowered the draw cap while it still answered";
}

rule aHigherAccountingRateNeverLowersTheTwinsPrice(env e, uint256 v1, uint256 v2) {
    require FEED() == feed;
    requireInvariant theCollateralIsTheLtOrItsGauge();
    require v2 >= v1;

    storage genesis = lastStorage;
    lt.setPps(v1);
    uint256 p1 = accountingPrice(e);

    lt.setPps(v2) at genesis;
    uint256 p2 = accountingPrice(e);

    require p2 != 0;
    assert p2 >= p1, "a higher pricePerShare lowered the twins' price while it still answered";
}

// ---- witnesses ----

rule aLivePriceIsReachableOnAnLtMarket(env e) {
    theRailsHold();
    require GAUGE() == 0;
    satisfy minPrice(e, QUOTE(), COLLATERAL()) > 0;
}

rule aLivePriceIsReachableOnAGaugeMarket(env e) {
    theRailsHold();
    require GAUGE() != 0;
    satisfy minPrice(e, QUOTE(), COLLATERAL()) > 0;
}

// the min really binds: the draw cap can sit strictly under the twins' price, which is the finding's whole gap
rule theRedemptionDiscountCanBind(env e) {
    theRailsHold();
    uint256 p = minPrice(e, QUOTE(), COLLATERAL());
    uint256 a = accountingPrice(e);
    satisfy p != 0 && p < a;
}

rule theTwinsCanAnswerBelow(env e, uint256 x) {
    theRailsHold();
    satisfy persistedBelowSettle(e, QUOTE(), COLLATERAL(), x);
}
