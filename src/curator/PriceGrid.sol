// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title PriceGrid
/// @notice The one price grid every vault door rounds onto: 50 ticks a step, about 0.5%, so nearby borrows share a market.
/// @dev `down` is linked rather than inlined: the tick math is the heaviest code a vault would otherwise carry, and every door shares one copy.
library PriceGrid {
    int24 internal constant TICKS = 50; // the grid's step, about 0.5%
    uint256 internal constant Q96 = 1 << 96; // the hub's price frame

    /// @notice The highest grid price at or under `p`, except a grid price whose root is inexact, which floors one step down; zero under the grid.
    /// @dev The root floors and the tick floors twice, in `getTickAtSqrtPrice` and `compress`, so the result never exceeds `p`.
    function down(uint256 p) public pure returns (uint256) {
        if (p == 0) return 0;
        int24 t = TickBitmap.compress(TickMath.getTickAtSqrtPrice(sqrtPriceX96(p, false)), TICKS) * TICKS;
        if (t < TickMath.MIN_TICK) return 0;
        uint256 g = TickMath.getSqrtPriceAtTick(t);
        return Math.mulDiv(g, g, Q96);
    }

    /// @notice The pool sqrt price of a Q96 price, quote atoms per token atom, clamped into v4's range.
    /// @dev Full width: sqrt(p << 96), never sqrt(p) << 48, which drops whole tenths of a percent at low prices.
    /// @param pQ96 The price.
    /// @param usdcIs0 Whether the quote, USDC, is the pool's currency0: a pool prices currency1 per currency0, so true inverts the root.
    function sqrtPriceX96(uint256 pQ96, bool usdcIs0) internal pure returns (uint160) {
        uint256 s = _sqrtShifted(pQ96);
        if (usdcIs0) s = s == 0 ? type(uint256).max : (uint256(1) << 192) / s;
        if (s < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (s >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    /// @dev sqrt(p << 96) without overflowing the shift: past 2^160, root an even smaller shift and scale the root back.
    /// @dev Exact below 2^160; past it the scaled root drops low bits, a relative error under 2^-127.
    function _sqrtShifted(uint256 p) private pure returns (uint256) {
        if (p < 1 << 160) return Math.sqrt(p << 96);
        uint256 k = (255 - Math.log2(p)) & ~uint256(1);
        return Math.sqrt(p << k) << ((96 - k) / 2);
    }
}
