// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IERC20Decimals
/// @notice The optional ERC20 field genesis bounds a pair on, and a record adapter frames its price with.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
