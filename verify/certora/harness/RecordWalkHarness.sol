// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {RecordHarness} from "./RecordHarness.sol";

/// @title RecordWalkHarness
/// @notice RecordHarness plus one entry point onto the settle twin's walk back through the feed's rounds, so a lemma can state its contract.
/// @dev It adds no state, so the layout is the record's; the walk it reaches is the record's own `_walk`, unchanged.
contract RecordWalkHarness is RecordHarness {
    constructor(address feed, address factory, address quote, uint16 haircutBps, uint256 maxStaleness, address sequencerFeed, uint256 grace)
        RecordHarness(feed, factory, quote, haircutBps, maxStaleness, sequencerFeed, grace)
    {}

    /// @notice The record's walk back from round `id`, stamped `upd`, to the round standing at `from`, carrying the high `hi`.
    /// @param id The latest round's id.
    /// @param upd The latest round's stamp.
    /// @param hi The high so far, the latest answer.
    /// @param from The window's start.
    /// @param fresh The earliest stamp a round may carry, the grace's end.
    /// @return ok Whether the walk reached the round standing at `from` with no doubt.
    /// @return high The highest answer it saw.
    function walkOf(uint80 id, uint256 upd, uint256 hi, uint256 from, uint256 fresh) external view returns (bool ok, uint256 high) {
        return _walk(id, upd, hi, from, fresh);
    }
}
