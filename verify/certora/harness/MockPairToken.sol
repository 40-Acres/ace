// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockPairToken
/// @notice A token as an oracle-class record interviews it: `decimals` alone, storage the prover sets.
/// @notice DISPATCHED rather than linked, since a record reads its pair's decimals off constructor arguments.
/// @dev Three named copies follow, so a scene can hold a quote, a collateral and an underlying that answer apart.
contract MockPairToken {
    uint8 internal dec; // what decimals answers

    /// @notice The token's decimals.
    /// @return The stored decimals.
    function decimals() external view returns (uint8) {
        return dec;
    }
}

/// @title MockQuoteToken
/// @notice The pair's quote, its own storage.
contract MockQuoteToken is MockPairToken {}

/// @title MockCollateralToken
/// @notice The pair's collateral, its own storage.
contract MockCollateralToken is MockPairToken {}

/// @title MockUnderlyingToken
/// @notice The token a yb LT redeems into, its own storage.
contract MockUnderlyingToken is MockPairToken {}
