// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IApi3ReaderProxy} from "../../src/interfaces/IApi3ReaderProxy.sol";

/// @notice A Chainlink-shape feed that READS a settable dAPI: one price behind two feed classes.
/// @notice The playground's record twins read this, so moving the BTC dAPI moves them too, with no second write.
/// @dev The round id and both stamps are the dAPI's timestamp, so staleness follows the dAPI exactly.
/// @dev Nothing here is settable, so a bot re-stamps it by re-stamping the dAPI underneath.
/// @dev Not a real API3 proxy's own AggregatorV2V3 surface: that answers in 18 decimals, and the twins exercise Chainlink's 8.
contract MockAggregatorOverApi3 is IAggregatorV3 {
    IApi3ReaderProxy public immutable PROXY;
    uint8 private immutable FEED_DECIMALS; // private: a public `DECIMALS()` is how lib-feeds.sh spots a settable mock
    uint256 private immutable SCALE; // the digits a dAPI's 18 decimals carry past this feed's

    constructor(address proxy, uint8 feedDecimals) {
        require(feedDecimals <= 18, "a dAPI answers in 18 decimals, so a feed can only drop digits");
        PROXY = IApi3ReaderProxy(proxy);
        FEED_DECIMALS = feedDecimals;
        SCALE = 10 ** (18 - feedDecimals);
    }

    /// @notice The feed's own decimals.
    function decimals() external view returns (uint8) {
        return FEED_DECIMALS;
    }

    /// @notice The dAPI's value in this feed's decimals; a reverting dAPI reverts here too.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (int224 v, uint32 ts) = PROXY.read();
        return (uint80(ts), int256(v) / int256(SCALE), ts, ts, uint80(ts));
    }
}
