// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {YbRecord, IERC20Decimals} from "../../../src/oracle/YbRecord.sol";

/// @title YbRecordHarness
/// @notice YbRecord plus views onto the frame it fixes at construction, the decimals that frame was read off, and its two reads.
/// @notice It adds getters and no state, so the layout is the record's and every method under test is its own.
/// @dev The two price getters call the record's own `_price`, so a spec compares the twins' rate to the draw cap's without re-deriving either.
contract YbRecordHarness is YbRecord {
    constructor(address feed, address lt, address gauge, address quote, address underlying, uint256 maxStaleness)
        YbRecord(feed, lt, gauge, quote, underlying, maxStaleness)
    {}

    /// @notice The hub's frame times the quote's atoms per whole token.
    /// @return The price numerator fixed at construction.
    function priceNum() external view returns (uint256) {
        return PRICE_NUM;
    }

    /// @notice The feed's scale times one collateral share.
    /// @return The price denominator fixed at construction.
    function priceDen() external view returns (uint256) {
        return PRICE_DEN;
    }

    /// @notice The quote's decimals, asked now.
    /// @return What the quote answers.
    function quoteDecimals() external view returns (uint8) {
        return IERC20Decimals(QUOTE).decimals();
    }

    /// @notice The feed's decimals, asked now.
    /// @return What the feed answers.
    function feedDecimals() external view returns (uint8) {
        return FEED.decimals();
    }

    /// @notice The collateral's decimals, asked now.
    /// @return What the collateral answers.
    function collateralDecimals() external view returns (uint8) {
        return IERC20Decimals(COLLATERAL).decimals();
    }

    /// @notice The underlying's decimals, asked now.
    /// @return What the underlying answers.
    function underlyingDecimals() external view returns (uint8) {
        return IERC20Decimals(UNDERLYING).decimals();
    }

    /// @notice The composed price at the accounting rate, the one the below-twins answer off.
    /// @return The record's own `_price(false)`.
    function accountingPrice() external view returns (uint256) {
        return _price(false);
    }

    /// @notice The composed price at the lower of the two rates, the one `minPrice` answers.
    /// @return The record's own `_price(true)`.
    function realizablePrice() external view returns (uint256) {
        return _price(true);
    }
}
