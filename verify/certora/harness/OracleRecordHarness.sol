// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {OracleRecord} from "../../../src/oracle/OracleRecord.sol";
import {IERC20Decimals} from "../../../src/interfaces/IERC20Decimals.sol";

/// @title OracleRecordHarness
/// @notice OracleRecord plus views onto the frame it fixes at construction and the decimals that frame was read off.
/// @notice It adds getters and no state, so the layout is the record's and every method under test is its own.
/// @dev The frame getters read the immutables rather than recomputing them, so they cannot agree with a wrong constructor.
/// @dev The decimals getters ask the wired contracts now, which is what lets an invariant tie the frame to its sources.
contract OracleRecordHarness is OracleRecord {
    constructor(address feed, address quote, address collateral, uint256 maxStaleness) OracleRecord(feed, quote, collateral, maxStaleness) {}

    /// @notice The hub's frame times the quote's atoms per whole token.
    /// @return The price numerator fixed at construction.
    function priceNum() external view returns (uint256) {
        return PRICE_NUM;
    }

    /// @notice The feed's scale times the collateral's atoms per whole token.
    /// @return The price denominator fixed at construction.
    function priceDen() external view returns (uint256) {
        return PRICE_DEN;
    }

    /// @notice The quote's decimals, asked now.
    /// @return What the quote answers.
    function quoteDecimals() external view returns (uint8) {
        return IERC20Decimals(QUOTE).decimals();
    }

    /// @notice The collateral's decimals, asked now.
    /// @return What the collateral answers.
    function collateralDecimals() external view returns (uint8) {
        return IERC20Decimals(COLLATERAL).decimals();
    }

    /// @notice The feed's decimals, asked now.
    /// @return What the feed answers.
    function feedDecimals() external view returns (uint8) {
        return FEED.decimals();
    }
}
