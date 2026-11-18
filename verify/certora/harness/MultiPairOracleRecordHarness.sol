// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MultiPairOracleRecord} from "../../../src/oracle/MultiPairOracleRecord.sol";
import {IERC20Decimals} from "../../../src/interfaces/IERC20Decimals.sol";

/// @title MultiPairOracleRecordHarness
/// @notice MultiPairOracleRecord plus flat views onto one pair's stored wiring, and a decimals probe for any address.
/// @notice It adds getters and no state, so the layout is the record's and every method under test is its own.
/// @dev `pairOf` returns a struct; the four getters read the same storage field by field so a spec can compare each.
contract MultiPairOracleRecordHarness is MultiPairOracleRecord {
    constructor(address initialOwner) MultiPairOracleRecord(initialOwner) {}

    /// @notice The pair's feed, zero for a pair never registered.
    /// @param quote The pair's quote.
    /// @param collateral The pair's collateral.
    /// @return The stored feed.
    function pairFeed(address quote, address collateral) external view returns (address) {
        return address(_pairs[quote][collateral].feed);
    }

    /// @notice The pair's staleness bound.
    /// @param quote The pair's quote.
    /// @param collateral The pair's collateral.
    /// @return The stored bound.
    function pairStaleness(address quote, address collateral) external view returns (uint256) {
        return _pairs[quote][collateral].maxStaleness;
    }

    /// @notice The pair's price numerator.
    /// @param quote The pair's quote.
    /// @param collateral The pair's collateral.
    /// @return The stored numerator.
    function pairNum(address quote, address collateral) external view returns (uint256) {
        return _pairs[quote][collateral].priceNum;
    }

    /// @notice The pair's price denominator.
    /// @param quote The pair's quote.
    /// @param collateral The pair's collateral.
    /// @return The stored denominator.
    function pairDen(address quote, address collateral) external view returns (uint256) {
        return _pairs[quote][collateral].priceDen;
    }

    /// @notice What `token` answers for its decimals now, the same call registration makes.
    /// @param token Any token or feed.
    /// @return Its decimals.
    function decimalsOf(address token) external view returns (uint8) {
        return IERC20Decimals(token).decimals();
    }
}
