// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PriceGrid} from "../../src/curator/libraries/PriceGrid.sol";

/// @notice External face of `PriceGrid.sqrtPriceX96`, an internal function.
contract SqrtPriceHarness {
    function sqrtPriceX96(uint256 p, bool usdcIs0) external pure returns (uint160) {
        return PriceGrid.sqrtPriceX96(p, usdcIs0);
    }
}

/// @notice The shared price grid the door rounds onto, exposed so its bound can be fuzzed.
contract QuantizeHarness {
    function full(uint256 p) external pure returns (uint256) {
        return PriceGrid.down(p);
    }
}

/// @notice The record-to-pool sqrt price conversion every grid read runs, in both orientations and at the extremes.
contract PriceGridSqrtPriceTest is Test {
    uint256 internal constant Q96 = 1 << 96;
    SqrtPriceHarness internal h;

    function setUp() public {
        h = new SqrtPriceHarness();
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

    /// @dev The two roots meet at 2^160 exactly: one atom under it is the plain root, 2^128 - 1, and 2^160 itself the shifted one, 2^128.
    /// @dev A seam moved up a bit would shift 2^160 past the word and root zero, so the grid price there would fall to nothing.
    function test_SqrtPrice_TheBranchSeamIsExact() public {
        uint256 seam = 1 << 160;
        assertEq(h.sqrtPriceX96(seam - 1, false), (1 << 128) - 1, "one atom under the seam, by the plain root");
        assertEq(h.sqrtPriceX96(seam, false), 1 << 128, "the seam itself, by the shifted root");
        assertEq(h.sqrtPriceX96(seam - 1, true), 1 << 64, "usdc first, one atom under the seam");
        assertEq(h.sqrtPriceX96(seam, true), 1 << 64, "usdc first, at the seam");
        QuantizeHarness g = new QuantizeHarness();
        assertGt(g.full(seam - 1), 0, "the grid prices one atom under the seam");
        assertLe(g.full(seam - 1), g.full(seam), "and never grids the seam itself lower");
    }
}

/// @notice The grid's quantizer at tiny per-atom prices, where a coarser root would fall more than a step short.
contract PriceGridQuantizeTest is Test {
    /// @dev Down to tiny per-atom prices the full-width form stays within one grid step under `p`.
    function testFuzz_Quantize_StaysWithinOneStepAtTinyPrices(uint256 p) public {
        QuantizeHarness h = new QuantizeHarness();
        p = bound(p, 1 << 14, 1 << 60);
        uint256 q = h.full(p);
        assertLe(q, p, "never over");
        assertGt(q, 0, "a price, not a refusal");
        uint256 up = Math.mulDiv(q + 1, 1_005_013, 1_000_000, Math.Rounding.Ceil); // one step is 1.0001^50 = 1.0050122; +1 and Ceil cover the floors
        assertLt(p, up, "within one grid step of p");
    }

    /// @dev A higher price never grids lower, so a rising record never moves a borrow to a lower market.
    /// @dev The price is drawn per binade so every magnitude is hit, and its neighbour sits within about 1.5%, a few steps.
    function testFuzz_Down_IsMonotone(uint256 binade, uint256 frac, uint256 d) public {
        QuantizeHarness g = new QuantizeHarness();
        uint256 e = bound(binade, 0, 223);
        uint256 p = (uint256(1) << e) + frac % (uint256(1) << e);
        d = bound(d, 1, p / 64 + 1);
        assertLe(g.full(p), g.full(p + d), "a higher price never grids lower");
    }
}
