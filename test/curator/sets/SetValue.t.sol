// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SetValue} from "../../../src/curator/sets/SetValue.sol";
import {Range, Valued} from "../../../src/interfaces/ICuratedSets.sol";

/// @notice External face of `SetValue`'s internal functions.
contract SetValueHarness {
    function sqrtPriceX96(uint256 p, bool usdcIs0) external pure returns (uint160) {
        return SetValue.sqrtPriceX96(p, usdcIs0);
    }

    function within(uint160 sp, uint160 ref, uint256 bps) external pure returns (bool) {
        return SetValue.within(sp, ref, bps);
    }

    function value(Valued memory v, uint256 p, bool usdcIs0) external pure returns (uint256) {
        return SetValue.value(v, p, usdcIs0);
    }

    function convert(uint256 amount, uint256 p, bool fromUsdc) external pure returns (uint256) {
        return SetValue.convert(amount, p, fromUsdc);
    }
}

/// @notice The oracle-to-pool price conversion and the oracle valuation, in both orientations and at the extremes.
contract SetValueTest is Test {
    uint256 internal constant Q96 = 1 << 96;
    SetValueHarness internal h;

    function setUp() public {
        h = new SetValueHarness();
    }

    /// @dev TOKEN first: the pool price IS the record price, so s^2 / 2^96 recovers it.
    function testFuzz_SqrtPrice_TokenFirst_RoundTrips(uint256 p) public view {
        p = bound(p, 1 << 40, (1 << 160) - 1);
        uint256 s = h.sqrtPriceX96(p, false);
        uint256 back = Math.mulDiv(s, s, Q96);
        assertLe(back, p, "floor never overshoots");
        assertLe(p - back, p / 1e12 + 1, "recovers the record price");
    }

    /// @dev USDC first: the pool prices TOKEN per USDC, so the pool price times the record price is one.
    function testFuzz_SqrtPrice_UsdcFirst_RoundTrips(uint256 p) public view {
        p = bound(p, 1 << 40, 1 << 150);
        uint256 s = h.sqrtPriceX96(p, true);
        uint256 poolQ = Math.mulDiv(s, s, Q96);
        uint256 one = Math.mulDiv(poolQ, p, Q96);
        assertApproxEqRel(one, Q96, 1e6, "pool price is the inverse of the record price");
    }

    /// @dev Through the large-price branch: s^2 must still equal p * 2^96.
    function testFuzz_SqrtPrice_FullWidthAbove2e160(uint256 p) public view {
        p = bound(p, 1 << 160, (1 << 222) - 1);
        uint256 s = h.sqrtPriceX96(p, false);
        assertApproxEqRel(Math.mulDiv(s, s, p), Q96, 1e6, "s^2 == p << 96 past the shift's overflow");
    }

    /// @dev Against TickMath: a tick's own sqrt price, turned into a record price, converts back to itself.
    function testFuzz_SqrtPrice_AgreesWithTickMath(int24 tick) public view {
        tick = int24(bound(tick, -400_000, 400_000));
        uint256 s = TickMath.getSqrtPriceAtTick(tick);
        uint256 pTokenFirst = Math.mulDiv(s, s, Q96);
        assertApproxEqAbs(h.sqrtPriceX96(pTokenFirst, false), s, Q96 / (2 * s) + 2, "token-first, within what flooring p lost");
        uint256 pUsdcFirst = Math.mulDiv(Q96, Q96, pTokenFirst);
        assertApproxEqRel(h.sqrtPriceX96(pUsdcFirst, true), s, 1e8, "usdc-first, within the test's own inversion rounding");
    }

    function test_SqrtPrice_Extremes_ClampBothOrientations() public view {
        assertEq(h.sqrtPriceX96(0, false), TickMath.MIN_SQRT_PRICE, "dark, token first: the floor");
        assertEq(h.sqrtPriceX96(0, true), TickMath.MAX_SQRT_PRICE - 1, "dark, usdc first: the ceiling");
        assertEq(h.sqrtPriceX96(type(uint256).max, false), TickMath.MAX_SQRT_PRICE - 1, "huge, token first: the ceiling");
        assertEq(h.sqrtPriceX96(type(uint256).max, true), TickMath.MIN_SQRT_PRICE, "huge, usdc first: the floor");
        assertEq(h.sqrtPriceX96(1, false), 1 << 48, "one atom, token first");
        assertEq(h.sqrtPriceX96(1, true), 1 << 144, "one atom, usdc first");
        assertEq(h.sqrtPriceX96(1 << 224, false), TickMath.MAX_SQRT_PRICE - 1, "just past the ceiling");
    }

    /// @dev The trap a narrow `sqrt(p) << 48` falls into: at a low price it loses whole tenths of a percent.
    function test_SqrtPrice_LowPrice_KeepsFullWidth() public view {
        uint256 p = 12_345;
        uint256 s = h.sqrtPriceX96(p, false);
        assertApproxEqAbs(Math.mulDiv(s, s, Q96), p, 1, "full width recovers the price to the atom");
        uint256 narrow = Math.sqrt(p) << 48;
        assertGt(p - Math.mulDiv(narrow, narrow, Q96), p / 1000, "the narrow form's price would be off by over 0.1%");
    }

    function test_Within_BothSides() public view {
        uint256 p = 1e17;
        uint160 ref = h.sqrtPriceX96(p, false);
        assertTrue(h.within(ref, ref, 0), "equal is within zero");
        assertTrue(h.within(h.sqrtPriceX96(p * 10_299 / 10_000, false), ref, 300), "+2.99% inside 3%");
        assertTrue(h.within(h.sqrtPriceX96(p * 9_701 / 10_000, false), ref, 300), "-2.99% inside 3%");
        assertFalse(h.within(h.sqrtPriceX96(p * 10_301 / 10_000, false), ref, 300), "+3.01% outside 3%");
        assertFalse(h.within(h.sqrtPriceX96(p * 9_699 / 10_000, false), ref, 300), "-3.01% outside 3%");
        assertFalse(h.within(TickMath.MAX_SQRT_PRICE - 1, TickMath.MIN_SQRT_PRICE, 10_000), "the extremes never pass");
        assertFalse(h.within(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1, 9_999), "nor the other way");
    }

    /// @dev One range straddling the oracle price, one wholly above it, plus idle; valued in USDC at the oracle.
    function test_Value_RangesAtOraclePlusIdle_BothOrientations() public view {
        uint256 p = 158_456_325_028_528_675; // $2 per 18-dec token in 6-dec USDC, at Q96
        for (uint256 o; o < 2; ++o) {
            bool usdcIs0 = o == 1;
            uint160 sp = h.sqrtPriceX96(p, usdcIs0);
            int24 t = TickMath.getTickAtSqrtPrice(sp) / 60 * 60;
            Valued memory v;
            v.ranges = new Range[](2);
            v.ranges[0] = Range(t - 600, t + 600, 1e17);
            v.ranges[1] = Range(t + 1200, t + 2400, 5e16);
            v.idle0 = 7e9;
            v.idle1 = 3e21;
            uint256 a0 = v.idle0 + SqrtPriceMath.getAmount0Delta(sp, TickMath.getSqrtPriceAtTick(t + 600), 1e17, false)
                + SqrtPriceMath.getAmount0Delta(TickMath.getSqrtPriceAtTick(t + 1200), TickMath.getSqrtPriceAtTick(t + 2400), 5e16, false);
            uint256 a1 = v.idle1 + SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(t - 600), sp, 1e17, false);
            uint256 want = usdcIs0 ? a0 + Math.mulDiv(a1, p, Q96) : a1 + Math.mulDiv(a0, p, Q96);
            assertEq(h.value(v, p, usdcIs0), want, usdcIs0 ? "usdc first" : "token first");
        }
    }

    function test_Convert_BothWays() public view {
        uint256 p = 158_456_325_028_528_675;
        assertEq(h.convert(1e18, p, false), 2e6 - 1, "one token is $2 less a floor atom");
        assertEq(h.convert(2e6, p, true), Math.mulDiv(2e6, Q96, p), "two dollars is one token");
    }

    /// @dev `within` written the other way: a price ratio of four or more refused outright rather than capped, then the square compared.
    function _withinRef(uint160 sp, uint160 ref, uint256 bps) internal pure returns (bool) {
        uint256 r = Math.mulDiv(sp, Q96, ref);
        if (r >= 2 * Q96) return false;
        uint256 pr = Math.mulDiv(r, r, Q96);
        return pr * 10_000 >= (10_000 - bps) * Q96 && pr * 10_000 <= (10_000 + bps) * Q96;
    }

    function testFuzz_Within_AsTheReplacedFormula(uint160 sp, uint160 ref, uint256 bps) public pure {
        sp = uint160(bound(sp, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        ref = uint160(bound(ref, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        bps = bound(bps, 0, 10_000);
        assertEq(SetValue.within(sp, ref, bps), _withinRef(sp, ref, bps), "within");
    }
}
