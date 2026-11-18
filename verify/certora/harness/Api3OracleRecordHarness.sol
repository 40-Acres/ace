// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Api3OracleRecord} from "../../../src/oracle/Api3OracleRecord.sol";
import {IERC20Decimals} from "../../../src/interfaces/IERC20Decimals.sol";

/// @title Api3OracleRecordHarness
/// @notice Api3OracleRecord plus views onto the frame it fixes at construction and the decimals that frame was read off.
/// @notice It adds getters and no state, so the layout is the record's and every method under test is its own.
/// @dev The frame getters read the immutables rather than recomputing them, so they cannot agree with a wrong constructor.
contract Api3OracleRecordHarness is Api3OracleRecord {
    constructor(address proxy, address quote, address collateral, uint256 maxStaleness) Api3OracleRecord(proxy, quote, collateral, maxStaleness) {}

    /// @notice The hub's frame times the quote's atoms per whole token.
    /// @return The price numerator fixed at construction.
    function priceNum() external view returns (uint256) {
        return PRICE_NUM;
    }

    /// @notice The dAPI's 18-decimal convention times the collateral's atoms per whole token.
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
}
