// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title ChainlinkDataFeed
/// @notice The checked `latestRoundData` read the Chainlink-shaped price records share: the round checks, spelled once.
/// @dev A return too short to decode is not caught: it reverts the caller's read rather than answering closed.
/// @dev A zero stamp is not special-cased: it is as old as the chain, so any bound short of that reads it stale.
/// @dev Framing the answer into a price, and refusing one too wide to frame, stay with each record.
library ChainlinkDataFeed {
    /// @notice The latest answer and its stamp when the round is fit to price off, else CLOSED as (0, 0), a reverting feed included.
    /// @dev Fit is a positive answer, `answeredInRound >= roundId`, a stamp not ahead of the chain and an age of at most `maxStaleness`.
    /// @param feed The Chainlink-shaped feed.
    /// @param maxStaleness Seconds since `updatedAt` that a round stays fit; an age of exactly the bound is still fit.
    /// @return answer The positive answer at the feed's own scale, or zero when the round is unfit.
    /// @return updatedAt The round's stamp, or zero when unfit; a fit round stamped zero returns zero too, so fitness is `answer != 0`, never the stamp.
    function latest(IAggregatorV3 feed, uint256 maxStaleness) internal view returns (uint256 answer, uint256 updatedAt) {
        try feed.latestRoundData() returns (uint80 r, int256 a, uint256, uint256 upd, uint80 answeredIn) {
            if (a <= 0) return (0, 0);
            if (answeredIn < r) return (0, 0); // incomplete round; `answeredInRound` is deprecated upstream, kept since it can only close a read
            if (upd > block.timestamp) return (0, 0); // stamped ahead of the chain: closed, and the age below cannot underflow
            if (block.timestamp - upd > maxStaleness) return (0, 0);
            return (uint256(a), upd);
        } catch {
            return (0, 0);
        }
    }
}
