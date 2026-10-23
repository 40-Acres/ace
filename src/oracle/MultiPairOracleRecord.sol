// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Constants} from "../ace/hub/Constants.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IERC20Decimals} from "../interfaces/IERC20Decimals.sol";
import {IPersistenceRecord} from "../interfaces/IPersistenceRecord.sol";
import {ChainlinkDataFeed} from "./ChainlinkDataFeed.sol";

/// @title MultiPairOracleRecord
/// @notice ORACLE-class record for many ordered pairs at one address, each reading its own Chainlink-shaped feed.
/// @notice Its owner, named at deploy, may only ADD pairs, never rewire or remove one; renouncing ownership freezes the set.
/// @notice The owner vouches that each feed prices the collateral in the quote, the right way up; nothing here checks it.
/// @notice A pair is refused while its inverse is registered, keyed on the two tokens, never the feed; no price is ever inverted.
/// @dev Per pair, `OracleRecord`'s frame: answer x 2^96 x 10^qd / (10^fd x 10^cd), its decimals read once, at registration.
/// @dev NO SEQUENCER GATE: every read is the pair's staleness bound alone, so an L2 deploy reads through a sequencer outage and its recovery.
/// @dev A market naming this record on an L2 accepts that; the bound it chose is the only freshness test, as after Aave's sentinel removal.
/// @dev Anything `ChainlinkDataFeed.latest` reads closed, or an answer too wide to frame, answers CLOSED (0/false); an unregistered pair reverts.
/// @dev A return too short to decode reverts the read: the hub's strict reads refuse it as `RecordUnreadable`, its try reads answer not-ok.
contract MultiPairOracleRecord is IPersistenceRecord, Ownable2Step {
    /// @notice One registered pair's wiring, written once.
    struct Pair {
        IAggregatorV3 feed; // zero until the pair is registered
        uint96 maxStaleness; // seconds since the feed's update before every read on the pair answers closed
        uint256 priceNum; // the hub's frame times the quote's atoms per whole token
        uint256 priceDen; // the feed's own scale times the collateral's atoms per whole token
    }

    error BadParams(); // a zero address, quote == collateral, a token over 18 decimals, or a staleness of zero or past 2^96 - 1
    error WrongPair(); // a read on a pair this record does not price
    error PairExists(); // the pair is registered, and its wiring never changes
    error InversePairExists(); // the pair's inverse is registered

    /// @notice A pair was registered, with the scale its reads frame by.
    /// @param quote The pair's quote token.
    /// @param collateral The pair's collateral token.
    /// @param feed The Chainlink-shaped feed pricing the collateral in the quote.
    /// @param maxStaleness Seconds a round stays fit to price off.
    /// @param priceNum The hub's frame times the quote's atoms per whole token.
    /// @param priceDen The feed's scale times the collateral's atoms per whole token.
    event PairRegistered(address indexed quote, address indexed collateral, address indexed feed, uint256 maxStaleness, uint256 priceNum, uint256 priceDen);

    mapping(address quote => mapping(address collateral => Pair)) internal _pairs;

    /// @dev The owner is NAMED, never `msg.sender`, so a factory or CREATE2 deploy cannot end up holding the key; OZ refuses zero.
    /// @param initialOwner The address that registers pairs.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /* ============================== THE PAIRS ============================== */

    /// @notice Register an ordered pair once and for all: the feed, the staleness and the scale read off the three decimals.
    /// @dev A staleness past 2^96 - 1 seconds is refused, and loses nothing: no round can be that old.
    /// @dev A token over 18 decimals is refused, genesis's own bound, so no pair registers that no market could use.
    /// @dev The feed's decimals take no bound: wider only truncates down, and a scale too wide to compute panics the registration.
    /// @dev A feed or token that cannot answer `decimals()` reverts the registration.
    /// @param quote The pair's quote token.
    /// @param collateral The pair's collateral token.
    /// @param feed The Chainlink-shaped feed pricing one whole collateral in whole quote.
    /// @param maxStaleness Seconds since the feed's update a round stays fit; an age of exactly this is still fit.
    function registerPair(address quote, address collateral, address feed, uint256 maxStaleness) external onlyOwner {
        if (feed == address(0) || maxStaleness == 0 || maxStaleness > type(uint96).max) revert BadParams();
        if (quote == address(0) || collateral == address(0) || quote == collateral) revert BadParams();
        if (address(_pairs[quote][collateral].feed) != address(0)) revert PairExists();
        if (address(_pairs[collateral][quote].feed) != address(0)) revert InversePairExists(); // keyed on the tokens; nothing here computes 1/p
        uint8 qd = IERC20Decimals(quote).decimals();
        uint8 cd = IERC20Decimals(collateral).decimals();
        if (qd > Constants.MAX_DECIMALS || cd > Constants.MAX_DECIMALS) revert BadParams();
        uint256 num = (1 << 96) * 10 ** qd;
        uint256 den = (10 ** IAggregatorV3(feed).decimals()) * 10 ** cd;
        _pairs[quote][collateral] = Pair(IAggregatorV3(feed), uint96(maxStaleness), num, den);
        emit PairRegistered(quote, collateral, feed, maxStaleness, num, den);
    }

    /// @notice The pair's wiring; all zero for a pair never registered.
    function pairOf(address quote, address collateral) external view returns (Pair memory) {
        return _pairs[quote][collateral];
    }

    /// @notice Whether the ordered pair is registered; genesis refuses any other.
    function supportsPair(address quote, address collateral) external view returns (bool) {
        return address(_pairs[quote][collateral].feed) != address(0);
    }

    /// @dev A wrong-pair read is a wiring bug, unreachable from a created market: revert loudly.
    function _pair(address quote, address collateral) internal view returns (Pair storage s) {
        s = _pairs[quote][collateral];
        if (address(s.feed) == address(0)) revert WrongPair();
    }

    /* ============================== THE READS ============================== */

    /// @notice Below `x` now; this class holds no window to measure against.
    function persistedBelowDistress(address quote, address collateral, uint256 x) external view returns (bool) {
        return _below(_pair(quote, collateral), x);
    }

    /// @notice The settle question, answered as the distress one: an oracle class holds no window.
    /// @dev A DISTINCT FUNCTION answering identically, never one question: a record with real settle patience answers it off its own windows.
    function persistedBelowSettle(address quote, address collateral, uint256 x) external view returns (bool) {
        return _below(_pair(quote, collateral), x);
    }

    /// @notice Above `x` now; false under any doubt.
    /// @dev Not an interface member: no hub verb asks the recovery question, only a view does.
    function persistedAbove(address quote, address collateral, uint256 x) external view returns (bool) {
        return _price(_pair(quote, collateral)) > x; // 0 answers false
    }

    /// @notice The pair's current price, 0 when unfit.
    function lastObserved(address quote, address collateral) external view returns (uint256) {
        return _price(_pair(quote, collateral));
    }

    /// @notice The windowed minimum IS the current price: this class has no window.
    function minPrice(address quote, address collateral) external view returns (uint256) {
        return _price(_pair(quote, collateral));
    }

    /* ============================== INTERNALS ============================== */

    /// @dev The one below-test both twins answer with, so neither can drift from the other.
    function _below(Pair storage s, uint256 x) internal view returns (bool) {
        uint256 p = _price(s);
        return p != 0 && p < x;
    }

    /// @dev The pair's framed price, 0 when the round is unfit or the answer too wide to frame: `OracleRecord`'s read, check for check.
    function _price(Pair storage s) internal view returns (uint256) {
        (uint256 a,) = ChainlinkDataFeed.latest(s.feed, s.maxStaleness);
        if (a == 0) return 0;
        uint256 num = s.priceNum;
        if (a > type(uint256).max / num) return 0; // absurd answer: closed, not a panic
        return FullMath.mulDiv(a, num, s.priceDen);
    }
}
