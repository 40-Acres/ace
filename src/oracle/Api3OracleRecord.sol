// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IApi3ReaderProxy} from "../interfaces/IApi3ReaderProxy.sol";
import {IPersistenceRecord} from "../interfaces/IPersistenceRecord.sol";
import {IERC20Decimals} from "../interfaces/IERC20Decimals.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title Api3OracleRecord
/// @notice ORACLE-class record over an API3 dAPI: pure read-and-check, window arguments inert.
/// @dev The dAPI value is 18-decimal by convention, a HUMAN price, so it is scaled into the hub's atom frame here.
/// @dev Feed uptime is the oracle's own infrastructure concern, never modelled here.
/// @dev A reverting dAPI or a non-positive, stale or future-stamped value answers CLOSED (0/false), so a sick feed yields inaction.
/// @dev A return too short to decode reverts the read: the hub's strict reads refuse it as `RecordUnreadable`, its try reads answer not-ok.
/// @dev A value stamped ahead of the chain reads closed until the chain catches up: seconds of skew in practice, and API3 admits up to an hour.
contract Api3OracleRecord is IPersistenceRecord {
    error BadParams();
    error WrongPair();

    IApi3ReaderProxy public immutable PROXY;
    address public immutable QUOTE;
    address public immutable COLLATERAL;
    uint256 public immutable MAX_STALENESS; // seconds since the dAPI timestamp before reads answer closed
    uint256 internal immutable PRICE_NUM; // the hub's fixed frame times the quote's atoms per whole token
    uint256 internal immutable PRICE_DEN; // the dAPI's 18-decimal convention times the collateral's atoms per whole token

    /// @dev THE PAIR'S DECIMALS ARE READ HERE AND NOWHERE ELSE IN THE PRICE PATH.
    /// @dev A dAPI reports a HUMAN price, and the hub's frame is atoms per atom against a constant.
    constructor(address proxy, address quote, address collateral, uint256 maxStaleness) {
        if (proxy == address(0) || maxStaleness == 0) revert BadParams();
        if (quote == address(0) || collateral == address(0) || quote == collateral) revert BadParams();
        PROXY = IApi3ReaderProxy(proxy);
        QUOTE = quote;
        COLLATERAL = collateral;
        MAX_STALENESS = maxStaleness;
        PRICE_NUM = (1 << 96) * 10 ** IERC20Decimals(quote).decimals();
        PRICE_DEN = 1e18 * 10 ** IERC20Decimals(collateral).decimals();
    }

    /// @notice The ordered pair this record prices; genesis refuses any other.
    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    /// @dev A wrong-pair read is a wiring bug, unreachable from a created market -- revert loudly.
    function _requirePair(address quote, address collateral) internal view {
        if (quote != QUOTE || collateral != COLLATERAL) revert WrongPair();
    }

    /// @dev The one read: the current dAPI value, 0 unless positive and fresh.
    function _price() internal view returns (uint256) {
        try PROXY.read() returns (int224 value, uint32 timestamp) {
            if (value <= 0) return 0;
            if (timestamp > block.timestamp) return 0; // stamped ahead of the chain: closed, and the age below cannot underflow
            if (block.timestamp - timestamp > MAX_STALENESS) return 0;
            uint256 v = uint256(int256(value));
            if (v > type(uint256).max / PRICE_NUM) return 0; // absurd answer: closed, not a panic
            return FullMath.mulDiv(v, PRICE_NUM, PRICE_DEN); // 18-dec human dAPI into the hub's atom frame
        } catch {
            return 0;
        }
    }

    /// @notice Below-ness NOW, health-gated; this class holds no window to measure against.
    /// @dev HAVING NO WINDOW IS CORRECT AND RULED for an oracle class: one publisher, trusted by construction.
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

    /// @notice The current value, 0 when the feed is unfit to referee.
    function lastObserved(address quote, address collateral) external view returns (uint256) {
        _requirePair(quote, collateral);
        return _price();
    }

    /// @notice The windowed minimum IS the current value -- there is no window in this class.
    function minPrice(address quote, address collateral) external view returns (uint256) {
        _requirePair(quote, collateral);
        return _price();
    }
}
