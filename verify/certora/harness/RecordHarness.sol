// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {NftAccountRecord} from "../../../src/oracle/NftAccountRecord.sol";

/// @title RecordHarness
/// @notice NftAccountRecord plus two views onto the framing it fixes at genesis, so a spec can state the price EXACTLY.
/// @notice The frame is a pair of internal immutables, and a rule asserting the formula cannot be written without them.
/// @notice It adds getters and no state, so the layout is the record's and every method under test is its own.
/// @dev The getters read the immutables rather than recomputing them, so they cannot agree with a wrong constructor.
contract RecordHarness is NftAccountRecord {
    constructor(address feed, address factory, address quote, uint16 haircutBps, uint256 maxStaleness, address sequencerFeed, uint256 grace)
        NftAccountRecord(feed, factory, quote, haircutBps, maxStaleness, sequencerFeed, grace)
    {}

    /// @notice The hub's frame times the quote's atoms per whole token; the haircut is the stored dial, applied per read.
    /// @return The price numerator fixed at genesis.
    function priceNum() external view returns (uint256) {
        return PRICE_NUM;
    }

    /// @notice The feed's scale times a receipt's atoms per whole token, times the bps base.
    /// @return The price denominator fixed at genesis.
    function priceDen() external view returns (uint256) {
        return PRICE_DEN;
    }

    /// @notice The feed answer framed at the stored haircut, as the price path used it; zero when the round or the sequencer closed it.
    /// @return The spot numerator the record itself computed.
    /// @dev A spec stating the exact formula must multiply by THIS, never by a spot it re-derives from the feed mock.
    /// @dev Re-deriving it would duplicate the staleness and absurd-answer gates, so a wrong copy would read as a proof.
    function spotNum() external view returns (uint256) {
        (uint256 num,,,) = _spot();
        return num;
    }
}
