// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Range, Valued} from "../../interfaces/ICuratedSets.sol";

/// @title SetValue
/// @notice Prices a curated set at an oracle price, never at its pool's, and converts between the record's and the pool's price scales.
/// @dev A record price is USDC atoms per TOKEN atom at 2^96; a pool prices currency1 per currency0, so the sqrt price inverts when USDC sorts first.
library SetValue {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant BPS = 10_000;

    /// @notice The pool sqrt price a record price implies, clamped into v4's range.
    /// @dev Full width: sqrt(p << 96), never sqrt(p) << 48, which drops whole tenths of a percent at low prices.
    /// @param pQ96 The record price.
    /// @param usdcIs0 Whether USDC is the pool's currency0.
    function sqrtPriceX96(uint256 pQ96, bool usdcIs0) internal pure returns (uint160) {
        uint256 s = _sqrtShifted(pQ96);
        if (usdcIs0) s = s == 0 ? type(uint256).max : (uint256(1) << 192) / s;
        if (s < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (s >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    /// @notice Whether the price at `sp` sits within `bps` of the price at `ref`, either side. `bps` is at most `BPS`.
    /// @dev A sqrt ratio of two is a price ratio of four, past any band of at most 100%, so the square is capped there before it can overflow.
    function within(uint160 sp, uint160 ref, uint256 bps) internal pure returns (bool) {
        uint256 r = Math.mulDiv(sp, Q96, ref);
        uint256 pr = r >= 2 * Q96 ? 4 * Q96 : Math.mulDiv(r, r, Q96);
        return pr * BPS >= (BPS - bps) * Q96 && pr * BPS <= (BPS + bps) * Q96;
    }

    /// @notice A range's token amounts at `sp`, rounded down.
    function amountsAt(uint160 sp, Range memory r) internal pure returns (uint256 a0, uint256 a1) {
        if (r.liquidity == 0) return (0, 0);
        uint160 sa = TickMath.getSqrtPriceAtTick(r.tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(r.tickUpper);
        if (sp <= sa) {
            a0 = SqrtPriceMath.getAmount0Delta(sa, sb, r.liquidity, false);
        } else if (sp >= sb) {
            a1 = SqrtPriceMath.getAmount1Delta(sa, sb, r.liquidity, false);
        } else {
            a0 = SqrtPriceMath.getAmount0Delta(sp, sb, r.liquidity, false);
            a1 = SqrtPriceMath.getAmount1Delta(sa, sp, r.liquidity, false);
        }
    }

    /// @notice `amount` of one side in the other at the record price, rounded down: USDC into TOKEN when `fromUsdc`, else TOKEN into USDC.
    function convert(uint256 amount, uint256 pQ96, bool fromUsdc) internal pure returns (uint256) {
        return fromUsdc ? Math.mulDiv(amount, Q96, pQ96) : Math.mulDiv(amount, pQ96, Q96);
    }

    /// @notice A set's value in USDC atoms at the record price: ranges at that price, idle, and the book, the token converted at it.
    /// @dev The book counts at face; collateral recovered in kind counts as token at the record price.
    /// @param v The set's ranges, idle and book.
    /// @param pQ96 The record price.
    /// @param usdcIs0 Whether USDC is the pool's currency0.
    function value(Valued memory v, uint256 pQ96, bool usdcIs0) internal pure returns (uint256) {
        uint160 sp = sqrtPriceX96(pQ96, usdcIs0);
        uint256 t0 = v.idle0;
        uint256 t1 = v.idle1;
        for (uint256 i; i < v.ranges.length; ++i) {
            (uint256 a0, uint256 a1) = amountsAt(sp, v.ranges[i]);
            t0 += a0;
            t1 += a1;
        }
        (uint256 u, uint256 t) = usdcIs0 ? (t0, t1) : (t1, t0);
        return u + v.bookUsdc + convert(t + v.bookToken, pQ96, false);
    }

    /// @dev sqrt(p << 96) without overflowing the shift: past 2^160, root an even smaller shift and scale the root back.
    function _sqrtShifted(uint256 p) private pure returns (uint256) {
        if (p < 1 << 160) return Math.sqrt(p << 96);
        uint256 k = (255 - Math.log2(p)) & ~uint256(1);
        return Math.sqrt(p << k) << ((96 - k) / 2);
    }
}
