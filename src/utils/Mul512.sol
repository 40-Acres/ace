// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title Mul512
/// @notice Compares two 256-bit products exactly, without dividing and without overflowing.
/// @notice For a ratio band whose two sides are cross-multiplied, where a quotient would round the answer away.
/// @dev The COMPARISON is exported and the multiply is not, so no caller can assemble the halves wrongly.
library Mul512 {
    /// @notice Whether `a * b > c * d`, exact at every input, with no division and no overflow.
    /// @dev The 512-bit decomposition is the one `FullMath.mulDiv` performs internally, so no new maths enters here.
    /// @dev `mulmod` against `type(uint256).max` yields the product mod 2**256-1, and the high word follows by borrow.
    /// @dev The arithmetic is UNCHECKED on purpose: wrapping IS the representation, and 0.8 would revert on it.
    /// @param a First operand of the left product.
    /// @param b Second operand of the left product.
    /// @param c First operand of the right product.
    /// @param d Second operand of the right product.
    /// @return Whether the left product strictly exceeds the right.
    function gt512(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool) {
        (uint256 hiL, uint256 loL) = _mul512(a, b);
        (uint256 hiR, uint256 loR) = _mul512(c, d);
        return hiL > hiR || (hiL == hiR && loL > loR);
    }

    /// @dev The full 512-bit product, as a (high, low) pair of 256-bit words.
    /// @param x First operand.
    /// @param y Second operand.
    /// @return hi The high 256 bits.
    /// @return lo The low 256 bits.
    function _mul512(uint256 x, uint256 y) private pure returns (uint256 hi, uint256 lo) {
        unchecked {
            uint256 mm = mulmod(x, y, type(uint256).max);
            lo = x * y;
            hi = mm - lo - (mm < lo ? 1 : 0);
        }
    }
}
