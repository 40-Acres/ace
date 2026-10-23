// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {YbRecord} from "../../src/oracle/YbRecord.sol";
import {MockApi3ReaderProxy} from "../mocks/MockApi3ReaderProxy.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockShortReturnFeed} from "../mocks/MockShortReturnFeed.sol";
import {MockYbGauge, MockYbLt} from "../mocks/MockYb.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @notice Passes the `asset()` wiring rail and fails the frame rail: it exists only to be refused.
/// @dev Not a knob on `MockYbGauge`, which stands in for the live gauge and IS 18-dec.
contract NarrowGauge {
    address public immutable asset; // the LT, so the wiring rail is not what fires
    uint8 public constant decimals = 8;

    constructor(address lt) {
        asset = lt;
    }
}

/// @notice The same refusal from ABOVE: at 24 decimals a literal 1e18 is a millionth of a share.
/// @dev Its own contract rather than a knob on `NarrowGauge`, so no existing call site is touched.
contract WideGauge {
    address public immutable asset; // the LT, so the wiring rail is not what fires
    uint8 public constant decimals = 24;

    constructor(address lt) {
        asset = lt;
    }
}

/// @title YbRecordTest
/// @notice The composed YieldBasis record: dAPI x pricePerShare [x convertToAssets], every leg fail-closed.
/// @dev The frame is declared per pair and windows are inert: this is the ORACLE-class contract, composed.
contract YbRecordTest is WarpClock {
    address internal USDC; // a REAL 6-dec token: the record reads the quote's decimals to build its frame
    uint256 internal constant STALE = 25 hours;
    int224 internal constant BTC = 64_978e18;

    MockApi3ReaderProxy internal dapi;
    MockYbLt internal lt;
    MockYbGauge internal gauge;
    YbRecord internal ltRec;
    YbRecord internal gRec;

    /// @dev EIGHT decimals on purpose: the underlying is BTC, and `preview_withdraw` answers in ITS
    /// @dev frame while `pricePerShare` is always 1e18. An 18-dec stand-in would hide the rescale.
    MockERC20 internal btc;

    function setUp() public {
        dapi = new MockApi3ReaderProxy();
        dapi.set(BTC);
        lt = new MockYbLt();
        gauge = new MockYbGauge(address(lt));
        btc = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        lt.setAssetToken(address(btc));
        USDC = address(new MockERC20("USD Coin", "USDC", 6));
        ltRec = new YbRecord(address(dapi), address(lt), address(0), USDC, address(btc), STALE);
        gRec = new YbRecord(address(dapi), address(lt), address(gauge), USDC, address(btc), STALE);
    }

    function test_Composition_LtAndGauge() public view {
        uint256 expectedLt = (uint256(int256(BTC)) * 1.006194e18) / 1e18;
        assertEq(ltRec.lastObserved(USDC, address(lt)), PriceFrame.px(expectedLt, USDC, address(lt)), "lt: dAPI x pps");
        uint256 expectedG = (expectedLt * 0.993443e18) / 1e18;
        assertEq(gRec.lastObserved(USDC, address(gauge)), PriceFrame.px(expectedG, USDC, address(gauge)), "gauge: x convertToAssets");
        assertLt(expectedG, expectedLt, "gauge shares price under LT while c2a < 1");
    }

    /// @dev Every leg fails CLOSED: a sick source answers 0/false, never a wrong number.
    function test_FailClosed_OnEveryLeg() public {
        dapi.setStamped(BTC, uint32(_now()));
        _warpBy(STALE + 1);
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "stale dAPI closes");
        _warpTo(_now() - STALE);

        dapi.setReverting(true);
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "reverting dAPI closes");
        dapi.setReverting(false);

        lt.setBroken(true);
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "reverting pricePerShare closes");
        lt.setBroken(false);
        lt.setPps(0);
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "zero pricePerShare closes");
        lt.setPps(1.006194e18);

        gauge.setBroken(true);
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "reverting convertToAssets closes");
        assertFalse(gRec.persistedBelowDistress(USDC, address(gauge), type(uint256).max), "closed proves no below-ness");
        gauge.setBroken(false);

        assertGt(gRec.lastObserved(USDC, address(gauge)), 0, "and recovery reopens with no verb");
    }

    function test_Frame_DeclaredPerVariant_WrongPairLoud() public {
        assertTrue(ltRec.supportsPair(USDC, address(lt)), "lt record prices the LT");
        assertFalse(ltRec.supportsPair(USDC, address(gauge)), "lt record refuses the gauge");
        assertTrue(gRec.supportsPair(USDC, address(gauge)), "gauge record prices the gauge");
        assertFalse(gRec.supportsPair(USDC, address(lt)), "gauge record refuses the LT");
        vm.expectRevert(YbRecord.WrongPair.selector);
        ltRec.lastObserved(USDC, address(gauge));
    }

    /// @dev The class carries no window at all now, so the min IS the current answer and the twins agree.
    function test_NoWindowInThisClass_MinIsCurrent() public view {
        assertEq(gRec.minPrice(USDC, address(gauge)), gRec.lastObserved(USDC, address(gauge)), "no window in this class");
        uint256 x = gRec.lastObserved(USDC, address(gauge)) + 1;
        assertEq(gRec.persistedBelowDistress(USDC, address(gauge), x), gRec.persistedBelowSettle(USDC, address(gauge), x), "and the twins agree");
    }

    /// @dev The staleness edge is exact, not approximately right: AT the limit the feed still referees, one second past it closes.
    /// @dev `>` rather than `>=` is the whole difference, and a STALE+1-only test cannot see it.
    function test_Staleness_BoundaryIsExact() public {
        uint32 stamp = uint32(_now());
        dapi.setStamped(BTC, stamp);
        _warpTo(uint256(stamp) + STALE);
        assertGt(gRec.lastObserved(USDC, address(gauge)), 0, "at exactly MAX_STALENESS the feed still counts");
        _warpTo(uint256(stamp) + STALE + 1);
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "one second past it, closed");
    }

    /// @dev A zero conversion leg composes to zero rather than panicking or answering the LT price.
    /// @dev A gauge that has forgotten how to price its shares must not silently price them AS the LT.
    function test_ZeroConversionLeg_ComposesToClosed() public {
        gauge.setC2a(0);
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "zero c2a closes the composition");
        assertEq(gRec.minPrice(USDC, address(gauge)), 0, "and the floor read with it");
        assertGt(ltRec.lastObserved(USDC, address(lt)), 0, "the LT record is untouched: the legs are per-variant");
    }

    /// @dev The property the composition exists for, over the whole plausible surface rather than one hand-picked triple.
    /// @dev The gauge's price is monotone in every leg and sits strictly under the LT's whenever the gauge converts at a discount.
    /// @dev Asserted as ORDER, never by restating the product.
    function testFuzz_Composition_IsMonotoneInEveryLeg(uint256 btc, uint256 pps, uint256 c2a) public {
        btc = bound(btc, 1e18, 1_000_000e18);
        pps = bound(pps, 0.1e18, 10e18);
        c2a = bound(c2a, 0.1e18, 0.999e18); // a discounting gauge, which is the live shape

        dapi.set(int224(int256(btc)));
        lt.setPps(pps);
        gauge.setC2a(c2a);
        uint256 base = gRec.lastObserved(USDC, address(gauge));
        assertGt(base, 0, "every leg healthy: the record referees");
        assertLt(base, ltRec.lastObserved(USDC, address(lt)), "a discounting gauge prices under the LT");

        dapi.set(int224(int256(btc * 2)));
        assertGt(gRec.lastObserved(USDC, address(gauge)), base, "monotone in the feed");
        dapi.set(int224(int256(btc)));

        lt.setPps(pps * 2);
        assertGt(gRec.lastObserved(USDC, address(gauge)), base, "monotone in pricePerShare");
        lt.setPps(pps);

        gauge.setC2a((c2a * 3) / 2);
        assertGt(gRec.lastObserved(USDC, address(gauge)), base, "monotone in the conversion leg");
    }

    function test_Ctor_RefusesMismatchedGauge() public {
        MockYbLt other = new MockYbLt();
        assertEq(other.decimals(), 18, "PREMISE: the wiring rail fires here, not the LT decimals rail");
        assertEq(gauge.decimals(), 18, "PREMISE: nor the gauge decimals rail");
        vm.expectRevert(YbRecord.BadParams.selector);
        new YbRecord(address(dapi), address(other), address(gauge), USDC, address(btc), STALE);
    }

    /// @notice A share token that is not 18-dec is REFUSED at genesis: `_price` spends 1e18 as ONE share.
    /// @dev The LT rail is load-bearing: it frames both `preview_withdraw`'s argument and the LT-denominated `convertToAssets` compose.
    function testRevert_Ctor_RefusesANonEighteenDecimalLt() public {
        MockERC20 narrow = new MockERC20("Narrow LT", "nLT", 8);
        vm.expectRevert(YbRecord.BadParams.selector);
        new YbRecord(address(dapi), address(narrow), address(0), USDC, address(btc), STALE);
    }

    /// @notice The gauge leg carries the same frame rail: `convertToAssets(1e18)` must mean one share.
    function testRevert_Ctor_RefusesANonEighteenDecimalGauge() public {
        NarrowGauge narrow = new NarrowGauge(address(lt));
        vm.expectRevert(YbRecord.BadParams.selector);
        new YbRecord(address(dapi), address(lt), address(narrow), USDC, address(btc), STALE);
    }

    /// @notice The LT rail is an EQUALITY, not a floor: 24 decimals mis-frames 1e18 exactly as 8 does.
    /// @dev Without this the rail weakens from `!= 18` to `< 18` with every other test still green.
    function testRevert_Ctor_RefusesAnLtWiderThanEighteenDecimals() public {
        MockERC20 wide = new MockERC20("Wide LT", "wLT", 24);
        vm.expectRevert(YbRecord.BadParams.selector);
        new YbRecord(address(dapi), address(wide), address(0), USDC, address(btc), STALE);
    }

    /// @notice The gauge rail is an EQUALITY too: `convertToAssets(1e18)` must mean ONE share, not 1e-6.
    function testRevert_Ctor_RefusesAGaugeWiderThanEighteenDecimals() public {
        WideGauge wide = new WideGauge(address(lt));
        assertEq(lt.decimals(), 18, "PREMISE: the gauge rail fires here, not the LT rail beside it");
        vm.expectRevert(YbRecord.BadParams.selector);
        new YbRecord(address(dapi), address(lt), address(wide), USDC, address(btc), STALE);
    }

    // ---- the rate leg is the LOWER of the two YieldBasis publishes ----

    /// @notice `pricePerShare` is ACCOUNTING; a redeemer gets an imbalanced pool exit that pays less.
    /// @notice Pricing off the accounting rate lends against a number nobody can realize: ZeroLend's error.
    /// @dev Live gap at the time this landed: WBTC 3.90%, cbBTC 1.30%, tBTC 3.55%.
    function test_RateLeg_TakesTheREALIZABLERateWhenItIsLower() public {
        uint256 both = ltRec.lastObserved(USDC, address(lt));
        assertEq(both, PriceFrame.px((uint256(int256(BTC)) * 1.006194e18) / 1e18, USDC, address(lt)), "PREMISE: equal legs quote the pps");

        lt.setPreviewWithdraw(0.96e8); // UNDERLYING-NATIVE: a discount well inside what has been seen live
        uint256 discounted = ltRec.lastObserved(USDC, address(lt));

        assertLt(discounted, both, "the discount must reach the price, or the second leg is decorative");
        assertEq(discounted, PriceFrame.px((uint256(int256(BTC)) * 0.96e18) / 1e18, USDC, address(lt)), "and the price IS the realizable rate");
    }

    /// @notice The min is a FLOOR on optimism, not a swap: a redemption ABOVE pps never lifts the price.
    /// @dev Otherwise a pool imbalance in the other direction would inflate borrowing power.
    function test_RateLeg_IgnoresARedemptionRateAboveThePps() public {
        uint256 base = ltRec.lastObserved(USDC, address(lt));

        lt.setPreviewWithdraw(1.5e8); // UNDERLYING-NATIVE, far above pps; the min must refuse it
        assertEq(ltRec.lastObserved(USDC, address(lt)), base, "a rate above pps cannot raise the price");
    }

    /// @notice THE FRAME, which is the bug that nearly shipped: the two legs are in DIFFERENT decimals.
    /// @notice `pricePerShare` is 1e18 whatever the underlying is; `preview_withdraw` is underlying-native.
    /// @dev Compared unrescaled, the min takes an 8-dec number against an 18-dec one and collapses the
    /// @dev price by 1e10. A mainnet fork caught it; the mock could not, because the mock had one frame.
    function test_RateLeg_RescalesTheUnderlyingNativeLegBeforeComparing() public {
        uint256 quoted = ltRec.lastObserved(USDC, address(lt));
        uint256 fromPpsAlone = PriceFrame.px((uint256(int256(BTC)) * 1.006194e18) / 1e18, USDC, address(lt));

        assertEq(quoted, fromPpsAlone, "an undiscounted 8-dec leg must rescale to EQUAL the 18-dec pps");
        assertGt(quoted, fromPpsAlone / 1e9, "and must not land orders of magnitude low, which is the bug");
    }

    /// @notice The scale is DERIVED from the underlying token, so an 18-dec underlying needs no rescale.
    function test_RateLeg_AnEighteenDecimalUnderlyingRescalesByOne() public {
        MockERC20 wide = new MockERC20("Wrapped Something", "WSOM", 18);
        lt.setAssetToken(address(wide));
        YbRecord rec18 = new YbRecord(address(dapi), address(lt), address(0), USDC, address(wide), STALE);
        lt.setUnderlyingScale(1); // an 18-dec underlying: preview_withdraw already answers in 1e18

        uint256 want = PriceFrame.px((uint256(int256(BTC)) * 1.006194e18) / 1e18, USDC, address(lt));
        assertEq(rec18.lastObserved(USDC, address(lt)), want, "no rescale");
    }

    /// @notice An underlying above 18 decimals is REFUSED at genesis rather than rescaled lossily.
    function testRevert_Ctor_RefusesAnUnderlyingWiderThanEighteenDecimals() public {
        MockERC20 tooWide = new MockERC20("Too Wide", "WIDE", 19);
        vm.expectRevert(YbRecord.BadParams.selector);
        new YbRecord(address(dapi), address(lt), address(0), USDC, address(tooWide), STALE);
    }

    /// @notice The new leg fails CLOSED like every other: a sick redemption read answers 0, never a guess.
    function test_RateLeg_ZeroRedemptionComposesToClosed() public {
        lt.setPreviewWithdraw(1); // non-zero sentinel first, so the knob is provably armed
        assertGt(ltRec.lastObserved(USDC, address(lt)), 0, "PREMISE: a tiny rate still prices");

        lt.setBroken(true);
        assertEq(ltRec.lastObserved(USDC, address(lt)), 0, "a reverting redemption read closes the record");
    }

    // ---- the asset leg is the WRAPPER's own USD feed (#426 5r1) ----

    /// @notice A cbBTC depeg reaches the price: the feed is cbBTC/USD, never BTC/USD with the wrapper taken at par.
    /// @dev An 8-decimal Chainlink-shape feed at 0.90 x BTC must price the LT at 0.90 x, framed exactly.
    function test_AssetLeg_AWrapperDepegReachesThePrice() public {
        uint256 depegged = (uint256(int256(BTC)) * 90) / 100; // 0.90 x BTC, as a human wad
        MockAggregatorV3 cbBtcUsd = new MockAggregatorV3(8);
        cbBtcUsd.push(int256(depegged / 1e10)); // in the feed's own 8 decimals
        YbRecord rec = new YbRecord(address(cbBtcUsd), address(lt), address(0), USDC, address(btc), STALE);

        uint256 want = PriceFrame.px((depegged * 1.006194e18) / 1e18, USDC, address(lt));
        assertEq(rec.lastObserved(USDC, address(lt)), want, "the wrapper's own USD price composes with the share rate");
        assertLt(rec.lastObserved(USDC, address(lt)), ltRec.lastObserved(USDC, address(lt)), "and sits under the par-wrapper price");
    }

    /// @notice The record names the feed it was given, and the feed's decimals are framed out: 8 and 18 land on one price.
    /// @dev `ltRec` reads the dAPI mock through its 18-decimal Chainlink surface, as a real API3 reader proxy answers it.
    function test_AssetLeg_TheFeedsDecimalsAreFramedOut() public {
        MockAggregatorV3 cl = new MockAggregatorV3(8);
        cl.push(int256(uint256(int256(BTC)) / 1e10));
        YbRecord rec = new YbRecord(address(cl), address(lt), address(0), USDC, address(btc), STALE);
        assertEq(address(rec.FEED()), address(cl), "the record names the feed it was given");
        assertEq(rec.lastObserved(USDC, address(lt)), ltRec.lastObserved(USDC, address(lt)), "an 8- and an 18-decimal print of one price agree");
    }

    /// @notice The feed leg reads the Chainlink round the way OracleRecord does: an incomplete or non-positive round is closed.
    function test_AssetLeg_AnUnfitRoundReadsClosed() public {
        MockAggregatorV3 cbBtcUsd = new MockAggregatorV3(8);
        cbBtcUsd.push(64_000e8);
        YbRecord rec = new YbRecord(address(cbBtcUsd), address(lt), address(0), USDC, address(btc), STALE);
        assertGt(rec.lastObserved(USDC, address(lt)), 0, "PREMISE: a fit round prices");
        cbBtcUsd.setRound(2, 64_000e8, _now(), 1);
        assertEq(rec.lastObserved(USDC, address(lt)), 0, "an incomplete round is closed");
        cbBtcUsd.push(0);
        assertEq(rec.lastObserved(USDC, address(lt)), 0, "a zero answer is closed");
        cbBtcUsd.push(-1);
        assertEq(rec.lastObserved(USDC, address(lt)), 0, "a negative answer is closed");
    }

    /// @notice A print stamped AHEAD of the chain reads closed, at the edge and at the furthest stamp a feed can carry.
    /// @dev The subtraction form cannot underflow and the old addition form could overflow; neither panics now.
    function test_Staleness_AFutureStampReadsClosed() public {
        dapi.setStamped(BTC, uint32(_now()));
        assertGt(gRec.lastObserved(USDC, address(gauge)), 0, "PREMISE: a print stamped now reads");
        dapi.setStamped(BTC, uint32(_now() + 1));
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "one second ahead of the chain is closed");
        dapi.setStamped(BTC, type(uint32).max);
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "and so is the furthest stamp a dAPI carries");

        MockAggregatorV3 cbBtcUsd = new MockAggregatorV3(8);
        cbBtcUsd.setRound(1, 64_000e8, type(uint256).max, 1);
        YbRecord rec = new YbRecord(address(cbBtcUsd), address(lt), address(0), USDC, address(btc), STALE);
        assertEq(rec.lastObserved(USDC, address(lt)), 0, "a Chainlink stamp at the word's ceiling is closed, never a panic");
    }

    /// @notice A feed return too short to decode REVERTS the read; the hub's strict reads name it `RecordUnreadable`, never zero.
    function testRevert_ShortFeedReturn_RevertsTheRead() public {
        YbRecord rec = new YbRecord(address(new MockShortReturnFeed()), address(lt), address(0), USDC, address(btc), STALE);
        vm.expectRevert();
        rec.lastObserved(USDC, address(lt));
    }

    // ---- an absurd word on any leg reads closed, never a panic (#399 L13) ----

    /// @notice `w x WITHDRAW_SCALE` would overflow: the redemption leg reads closed.
    function test_AbsurdWord_RedemptionLegReadsClosed() public {
        lt.setPreviewWithdraw(type(uint256).max);
        assertEq(ltRec.lastObserved(USDC, address(lt)), 0, "an absurd redemption word is closed");
        assertFalse(ltRec.persistedBelowDistress(USDC, address(lt), type(uint256).max), "and proves no below-ness");
    }

    /// @notice `feed x rate` would overflow: the composed product reads closed.
    /// @dev The redemption leg is set just under the rate so it binds without overflowing its own rescale.
    function test_AbsurdWord_FeedTimesRateReadsClosed() public {
        lt.setPps(2 ** 200);
        lt.setPreviewWithdraw(uint256(2 ** 200) / 1e10);
        assertEq(ltRec.lastObserved(USDC, address(lt)), 0, "an absurd share rate is closed");
    }

    /// @notice `price x convertToAssets` would overflow: the gauge leg reads closed.
    function test_AbsurdWord_GaugeConversionReadsClosed() public {
        gauge.setC2a(type(uint256).max / 1e18); // the mock answers this word itself for one share
        assertEq(gRec.lastObserved(USDC, address(gauge)), 0, "an absurd conversion word is closed");
        assertGt(ltRec.lastObserved(USDC, address(lt)), 0, "the LT record is untouched");
    }

    // ---- the underlying is the LT's own (#399 M14) ----

    /// @notice An underlying the LT does not name is REFUSED, whatever its decimals: the rescale would be set off a stranger.
    /// @dev 18 decimals rescales by one and leaves the redemption leg 1e10 low; 6 decimals lets the min never bind.
    function testRevert_Ctor_RefusesAnUnderlyingTheLtDoesNotName() public {
        assertEq(lt.ASSET_TOKEN(), address(btc), "PREMISE: the LT names cbBTC");
        MockERC20 wide = new MockERC20("Wrapped Something", "WSOM", 18);
        vm.expectRevert(YbRecord.BadParams.selector);
        new YbRecord(address(dapi), address(lt), address(0), USDC, address(wide), STALE);
        MockERC20 narrow = new MockERC20("Narrow Something", "NSOM", 6);
        vm.expectRevert(YbRecord.BadParams.selector);
        new YbRecord(address(dapi), address(lt), address(gauge), USDC, address(narrow), STALE);
    }

    /// @notice The record's underlying IS the token the LT names, for both collateral shapes.
    function test_Ctor_TheUnderlyingIsTheLtsAssetToken() public view {
        assertEq(ltRec.UNDERLYING(), lt.ASSET_TOKEN(), "the LT record");
        assertEq(gRec.UNDERLYING(), lt.ASSET_TOKEN(), "and the gauge record");
    }
}
