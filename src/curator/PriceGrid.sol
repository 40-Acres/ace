// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SetValue} from "./sets/SetValue.sol";

/// @title PriceGrid
/// @notice The one price grid every vault door rounds onto: 50 ticks a step, about 0.5%, so nearby borrows share a market.
/// @dev Rooted at full width, `sqrt(p << 96)`, so a low price keeps every digit a coarser root would drop.
/// @dev Linked rather than inlined: the tick math is the heaviest code a vault would otherwise carry, and every door shares one copy.
library PriceGrid {
    int24 internal constant TICKS = 50; // the grid's step, about 0.5%
    uint256 internal constant Q96 = 1 << 96; // the hub's price frame

    /// @notice The highest price on the grid at or under `p`; zero for a zero price or one under the grid's range.
    /// @dev The root floors and the tick floors twice, in `getTickAtSqrtPrice` and `compress`, so the result never exceeds `p`.
    function down(uint256 p) public pure returns (uint256) {
        if (p == 0) return 0;
        int24 t = TickBitmap.compress(TickMath.getTickAtSqrtPrice(SetValue.sqrtPriceX96(p, false)), TICKS) * TICKS;
        if (t < TickMath.MIN_TICK) return 0;
        uint256 g = TickMath.getSqrtPriceAtTick(t);
        return Math.mulDiv(g, g, Q96);
    }
}
