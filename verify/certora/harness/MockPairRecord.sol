// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockPairRecord
/// @notice A price record keyed by the ORDERED pair: each (quote, collateral) has its own price and its own support flag.
/// @notice So a read with the pair inverted reads another answer, which `MockRecord` (one price for every pair) cannot show.
/// @dev Every answer is storage the prover sets; a zero price is a dark record.
contract MockPairRecord {
    mapping(address => mapping(address => uint256)) internal price; // quote, collateral
    mapping(address => mapping(address => bool)) internal supported; // quote, collateral

    /// @notice The stored price for the ordered pair.
    function minPrice(address quote, address collateral) external view returns (uint256) {
        return price[quote][collateral];
    }

    /// @notice The stored support flag for the ordered pair.
    function supportsPair(address quote, address collateral) external view returns (bool) {
        return supported[quote][collateral];
    }

    /// @notice The stored price, for a spec.
    function priceView(address quote, address collateral) external view returns (uint256) {
        return price[quote][collateral];
    }
}
