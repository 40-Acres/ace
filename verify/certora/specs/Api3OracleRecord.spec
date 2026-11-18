// Api3OracleRecord: the single-pair ORACLE-class record over an API3 dAPI, proven against what the hub asks of it.
//
// WHAT THE HUB ASKS is OracleRecord.spec's header, read for read: genesis's four reads answer, `minPrice` is the draw cap
// (a revert is RecordUnreadable, a zero is NoPrice), and the twins gate distress and settlement, where a revert blocks.
// So every read on the pair must answer for every dAPI state, never revert, and read a sick dAPI as the dark value.
//
// THE PROXY AND THE TOKENS ARE MOCKS WHOSE BODIES RUN, DISPATCHED BY ADDRESS, NEVER LINKED, for OracleRecord.spec's
// reason: all three are constructor arguments, and a link binds the immutable without binding the argument. The proxy
// mock answers in full or reverts; a return too short to decode reverts the read and is the one behaviour not produced.
//
// `mulDiv` is EXACT with its reverting cases recorded in ghosts, as in OracleRecord.spec.
using MockApi3Proxy as proxy;

methods {
    function FullMath.mulDiv(uint256 a, uint256 b, uint256 d) internal returns (uint256) => mulDivExact(a, b, d);

    // both tokens arrive as constructor arguments, the proxy too: see the header
    function _.decimals() external => DISPATCHER(true);
    function _.read() external => DISPATCHER(true);

    function supportsPair(address, address) external returns (bool) envfree;
    function QUOTE() external returns (address) envfree;
    function COLLATERAL() external returns (address) envfree;
    function PROXY() external returns (address) envfree;
    function MAX_STALENESS() external returns (uint256) envfree;

    function priceNum() external returns (uint256) envfree;
    function priceDen() external returns (uint256) envfree;
    function quoteDecimals() external returns (uint8) envfree;
    function collateralDecimals() external returns (uint8) envfree;

    function MockApi3Proxy.valueView() external returns (int224) envfree;
    function MockApi3Proxy.timestampView() external returns (uint32) envfree;
    function MockApi3Proxy.revertsView() external returns (bool) envfree;
    function MockApi3Proxy.setValue(int224) external envfree;
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

// THE VALUE IS FIT, as the record's header documents it: the read answered, a positive value, a timestamp not ahead of
// the chain and an age of at most the bound. Each leg's negation is its own dark rule below.
function fitValue(env e) returns bool {
    return !proxy.revertsView()
        && proxy.valueView() > 0
        && to_mathint(proxy.timestampView()) <= to_mathint(e.block.timestamp)
        && to_mathint(e.block.timestamp) - to_mathint(proxy.timestampView()) <= to_mathint(MAX_STALENESS());
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

// ---- A3-0: what the constructor fixes ----

// THE FRAME IS THE PAIR'S DECIMALS AND THE dAPI's 18: `PRICE_NUM = 2^96 * 10^quoteDecimals` and
// `PRICE_DEN = 10^18 * 10^collateralDecimals`. The base case runs the constructor, so a decimals mutant there fails it.
// The decimals bounds are the constructor's own checked arithmetic (past them it overflows and reverts), stated because
// the prover's power-of-ten table stops at 10^77; see OracleRecord.spec.
invariant theFrameIsThePairsDecimals()
    to_mathint(quoteDecimals()) <= 48
        && to_mathint(collateralDecimals()) <= 59
        && to_mathint(priceNum()) == 2^96 * 10^quoteDecimals()
        && to_mathint(priceDen()) == 10^18 * 10^collateralDecimals();

invariant theWiringIsSound()
    PROXY() != 0 && QUOTE() != 0 && COLLATERAL() != 0 && QUOTE() != COLLATERAL() && MAX_STALENESS() != 0;

// ---- A3-1: the exact price ----

// A FIT VALUE PRICES AT THE EXACT FRAMED FLOOR, `floor(value * PRICE_NUM / PRICE_DEN)`, rounded down once.
rule aFitValuePricesAtTheExactFrame(env e) {
    requireInvariant theFrameIsThePairsDecimals();
    require PROXY() == proxy;
    require fitValue(e);
    mathint v = to_mathint(proxy.valueView());
    require v <= to_mathint(max_uint256) / to_mathint(priceNum());

    uint256 p = lastObserved(e, QUOTE(), COLLATERAL());
    assert to_mathint(p) == (v * to_mathint(priceNum())) / to_mathint(priceDen()),
        "a fit value did not price at the exact framed floor";
}

// ---- A3-2: every unfit leg reads dark, at every read ----

rule aRevertingProxyReadsDark(env e, uint256 x) {
    require PROXY() == proxy;
    require proxy.revertsView();
    assert readsDark(e, x), "a reverting dAPI answered a live read";
}

rule aNonPositiveValueReadsDark(env e, uint256 x) {
    require PROXY() == proxy;
    require proxy.valueView() <= 0;
    assert readsDark(e, x), "a non-positive value answered a live read";
}

rule aFutureStampReadsDark(env e, uint256 x) {
    require PROXY() == proxy;
    require to_mathint(proxy.timestampView()) > to_mathint(e.block.timestamp);
    assert readsDark(e, x), "a value stamped ahead of the chain answered a live read";
}

rule aStaleValueReadsDark(env e, uint256 x) {
    require PROXY() == proxy;
    require to_mathint(proxy.timestampView()) <= to_mathint(e.block.timestamp);
    require to_mathint(e.block.timestamp) - to_mathint(proxy.timestampView()) > to_mathint(MAX_STALENESS());
    assert readsDark(e, x), "a stale value answered a live read";
}

rule anAbsurdValueReadsDark(env e, uint256 x) {
    requireInvariant theFrameIsThePairsDecimals();
    require PROXY() == proxy;
    require to_mathint(proxy.valueView()) > to_mathint(max_uint256) / to_mathint(priceNum());
    assert readsDark(e, x), "a value too wide to frame answered a live read";
}

// ---- A3-3: the hub's reads never revert on the record's pair ----

rule noReadOnThePairEverReverts(env e, uint256 x) {
    requireInvariant theFrameIsThePairsDecimals();
    require PROXY() == proxy;
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
    requireInvariant theFrameIsThePairsDecimals();
    require PROXY() == proxy;
    bool refused = q != QUOTE() || c != COLLATERAL() || e.msg.value != 0;

    minPrice@withrevert(e, q, c);
    assert lastReverted <=> refused, "minPrice reverted other than on a wrong pair or a value";
    persistedBelowDistress@withrevert(e, q, c, x);
    assert lastReverted <=> refused, "persistedBelowDistress reverted other than on a wrong pair or a value";
    persistedBelowSettle@withrevert(e, q, c, x);
    assert lastReverted <=> refused, "persistedBelowSettle reverted other than on a wrong pair or a value";
}

// ---- A3-4: the record reaches neither of mulDiv's reverts ----

rule theRecordReachesNoRevertingMulDiv(env e) {
    requireInvariant theFrameIsThePairsDecimals();
    require PROXY() == proxy;
    require !zeroDenSeen && !overflowSeen;
    lastObserved(e, QUOTE(), COLLATERAL());
    assert !zeroDenSeen, "a zero divisor reached mulDiv, which the real library reverts on";
    assert !overflowSeen, "an absurd value's quotient reached mulDiv, which the real library reverts on";
}

// ---- A3-5: the pair ----

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

// ---- A3-6: one current price behind every read ----

rule theReadsAreOneCurrentPrice(env e, uint256 x) {
    address q = QUOTE();
    address c = COLLATERAL();
    uint256 p = lastObserved(e, q, c);
    assert minPrice(e, q, c) == p, "minPrice parted from lastObserved";
    assert persistedBelowDistress(e, q, c, x) == (p != 0 && p < x), "the distress twin is not below-ness of the price";
    assert persistedBelowSettle(e, q, c, x) == (p != 0 && p < x), "the settle twin is not below-ness of the price";
    assert persistedAbove(e, q, c, x) == (p > x), "persistedAbove is not above-ness of the price";
}

// ---- A3-7: monotonicity ----

rule aHigherValueNeverLowersThePrice(env e, int224 v1, int224 v2) {
    require PROXY() == proxy;
    require v2 >= v1;

    storage genesis = lastStorage;
    proxy.setValue(v1);
    uint256 p1 = lastObserved(e, QUOTE(), COLLATERAL());

    proxy.setValue(v2) at genesis;
    uint256 p2 = lastObserved(e, QUOTE(), COLLATERAL());

    require p2 != 0;
    assert p2 >= p1, "a higher value lowered the price while the read still answered";
}

// ---- witnesses ----

rule aLivePriceIsReachable(env e) {
    require PROXY() == proxy;
    satisfy lastObserved(e, QUOTE(), COLLATERAL()) > 0;
}

rule anAgeOfExactlyTheBoundStillPrices(env e) {
    require PROXY() == proxy;
    require to_mathint(e.block.timestamp) - to_mathint(proxy.timestampView()) == to_mathint(MAX_STALENESS());
    satisfy lastObserved(e, QUOTE(), COLLATERAL()) > 0;
}

rule theTwinsCanAnswerBelow(env e, uint256 x) {
    require PROXY() == proxy;
    satisfy persistedBelowSettle(e, QUOTE(), COLLATERAL(), x);
}
