// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IPersistenceRecord} from "../interfaces/IPersistenceRecord.sol";
import {IERC20Decimals} from "../interfaces/IERC20Decimals.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ChainlinkDataFeed} from "./ChainlinkDataFeed.sol";

/// @title OracleRecord
/// @notice ORACLE-class record: the feed is the truth, no persistence layer; window arguments are inert.
/// @dev Anything `ChainlinkDataFeed.latest` reads closed, or an answer too wide to frame, answers CLOSED (0/false), never a wrong action.
/// @dev A return too short to decode reverts the read: the hub's strict reads refuse it as `RecordUnreadable`, its try reads answer not-ok.
/// @dev A round stamped ahead of the chain reads closed until the chain catches up, which signing skew makes seconds.
/// @dev A sick feed yields inaction on every consumer: no draw, no distress, no finalize.
contract OracleRecord is IPersistenceRecord {
    error BadParams();
    error WrongPair();

    IAggregatorV3 public immutable FEED;
    address public immutable QUOTE;
    address public immutable COLLATERAL;
    uint256 public immutable MAX_STALENESS; // seconds since update before every read answers closed
    uint256 internal immutable PRICE_NUM; // the hub's fixed frame times the quote's atoms per whole token
    uint256 internal immutable PRICE_DEN; // the feed's own scale times the collateral's atoms per whole token

    /// @dev THE PAIR'S DECIMALS ARE READ HERE AND NOWHERE ELSE IN THE PRICE PATH.
    /// @dev A feed reports a HUMAN price, and the hub's frame is atoms per atom against a constant.
    /// @dev So the adapter is the only place that can carry the pair, and it does it once, at construction.
    constructor(address feed, address quote, address collateral, uint256 maxStaleness) {
        if (feed == address(0) || maxStaleness == 0) revert BadParams();
        if (quote == address(0) || collateral == address(0) || quote == collateral) revert BadParams();
        FEED = IAggregatorV3(feed);
        QUOTE = quote;
        COLLATERAL = collateral;
        MAX_STALENESS = maxStaleness;
        PRICE_NUM = (1 << 96) * 10 ** IERC20Decimals(quote).decimals();
        PRICE_DEN = (10 ** IAggregatorV3(feed).decimals()) * 10 ** IERC20Decimals(collateral).decimals();
    }

    /// @dev The one read: the current answer as quote atoms per collateral atom, 0 unless the round is fit.
    /// @dev Feed uptime and recovery are the ORACLE's own infrastructure concern, never modelled here.
    function _price() internal view returns (uint256) {
        (uint256 a,) = ChainlinkDataFeed.latest(FEED, MAX_STALENESS);
        if (a == 0) return 0;
        if (a > type(uint256).max / PRICE_NUM) return 0; // absurd answer: closed, not a panic
        return FullMath.mulDiv(a, PRICE_NUM, PRICE_DEN);
    }

    /// @notice The ordered pair this record prices; genesis refuses any other.
    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    /// @dev A wrong-pair read is a wiring bug, unreachable from a created market -- revert loudly.
    function _requirePair(address quote, address collateral) internal view {
        if (quote != QUOTE || collateral != COLLATERAL) revert WrongPair();
    }

    /// @notice Below-ness NOW, health-gated; this class holds no window to measure against.
    /// @dev HAVING NO WINDOW IS CORRECT AND RULED, not an omission to be repaired.
    /// @dev An ORACLE class is TRUSTED BY CONSTRUCTION, one publisher; a market wanting observation time names a windowed record, which ACE ships none of.
    /// @dev Consequence, accepted: one bad print is settleable in the block it lands. Choose the feed.
    function persistedBelowDistress(address quote, address collateral, uint256 x) external view returns (bool) {
        _requirePair(quote, collateral);
        return _below(x);
    }

    /// @notice Below-ness NOW for the settle question; the same answer as the distress twin, by the ruling above.
    /// @dev A DISTINCT FUNCTION answering identically, never one question: a record with real settle patience answers it off its own windows.
    function persistedBelowSettle(address quote, address collateral, uint256 x) external view returns (bool) {
        _requirePair(quote, collateral);
        return _below(x);
    }

    /// @dev The one below-test both twins answer with, so neither can drift from the other.
    function _below(uint256 x) internal view returns (bool) {
        uint256 p = _price();
        return p != 0 && p < x;
    }

    /// @notice Above-ness NOW, health-gated; false under any doubt is the safe direction.
    /// @dev NOT an interface member -- no hub verb asks the recovery question, only a view does.
    function persistedAbove(address quote, address collateral, uint256 x) external view returns (bool) {
        _requirePair(quote, collateral);
        return _price() > x; // 0 answers false
    }

    /// @notice The current answer, 0 when the feed is unfit to referee.
    function lastObserved(address quote, address collateral) external view returns (uint256) {
        _requirePair(quote, collateral);
        return _price();
    }

    /// @notice The windowed minimum IS the current answer -- there is no window in this class.
    function minPrice(address quote, address collateral) external view returns (uint256) {
        _requirePair(quote, collateral);
        return _price();
    }
}
