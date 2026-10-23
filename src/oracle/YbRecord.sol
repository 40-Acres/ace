// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IPersistenceRecord} from "../interfaces/IPersistenceRecord.sol";
import {ChainlinkDataFeed} from "./ChainlinkDataFeed.sol";

interface IYbLt {
    function pricePerShare() external view returns (uint256);
    function preview_withdraw(uint256 shares) external view returns (uint256);
    function ASSET_TOKEN() external view returns (address);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface IYbGauge {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title YbRecord
/// @notice ORACLE-class record for YieldBasis collateral: the USD feed of the LT's own asset token, composed with share price.
/// @notice When the collateral is the staking gauge, the gauge's LT-per-share composes in too.
/// @notice price = feed x min(pricePerShare, preview_withdraw(1e18)) [x convertToAssets(1e18)], then framed.
/// @dev The deployer must pass the USD feed of the LT's `ASSET_TOKEN`: the record cannot check it, and a BTC/USD feed would silently take the wrapper at par.
/// @dev It answers in USD and the hub reads it as quote: a USD-pegged quote such as USDC is taken at par, with no quote/USD leg.
/// @dev The answer is per share off a one-share sample at every size, for the draw cap, distress and settle; a lender covers the size it takes in kind.
/// @dev Same posture as OracleRecord: the feed is the truth, no persistence layer, windows inert.
/// @dev A reverting leg, an unfit round, or a zero or absurd word answers CLOSED (0/false).
/// @dev A return too short to decode reverts the read: the hub's strict reads refuse it as `RecordUnreadable`, its try reads answer not-ok.
/// @dev A future stamp stays closed only until the chain catches up: seconds of skew in practice, up to an hour on an API3 shim feed.
/// @dev The composition exists because a raw BTC record understates a compounding share monotonically.
contract YbRecord is IPersistenceRecord {
    error BadParams();
    error WrongPair();

    IAggregatorV3 public immutable FEED; // the underlying's own USD feed, Chainlink-shaped
    address public immutable LT; // the yb liquidity token; both rate legs are read here, in the underlying's frame
    address public immutable GAUGE; // zero for an LT market; the staking gauge when it IS the collateral
    address public immutable QUOTE;
    address public immutable COLLATERAL; // the LT, or the gauge where one is set
    address public immutable UNDERLYING; // the LT's own ASSET_TOKEN: the token the feed must price and the rescale is read off
    uint256 public immutable WITHDRAW_SCALE; // multiplies preview_withdraw into the 1e18 frame pps uses
    uint256 public immutable MAX_STALENESS; // seconds since the feed's update before every read answers closed
    uint256 internal immutable PRICE_NUM; // the hub's fixed frame times the quote's atoms per whole token
    uint256 internal immutable PRICE_DEN; // the feed's own scale times the collateral's atoms per whole token

    /// @param feed The USD feed of the token `lt` redeems into, Chainlink-shaped.
    /// @param underlying What `lt` redeems into: a TOKEN, never a decimals number, and the one the LT names.
    /// @dev A hand-passed decimals is a silent mispricing when wrong; a token address is checkable, and is checked here.
    constructor(address feed, address lt, address gauge, address quote, address underlying, uint256 maxStaleness) {
        if (feed == address(0) || lt == address(0) || maxStaleness == 0) revert BadParams();
        if (quote == address(0) || quote == lt) revert BadParams();
        if (underlying == address(0)) revert BadParams();
        if (gauge != address(0) && IYbGauge(gauge).asset() != lt) revert BadParams();
        if (IERC20Decimals(lt).decimals() != 18) revert BadParams(); // 1e18 is one LT share, and convertToAssets answers in LT units
        if (gauge != address(0) && IERC20Decimals(gauge).decimals() != 18) revert BadParams(); // 1e18 is one gauge share
        uint8 dec = IERC20Decimals(underlying).decimals();
        if (dec > 18) revert BadParams(); // above 18 the rescale would divide and lose the discount
        if (IYbLt(lt).ASSET_TOKEN() != underlying) revert BadParams(); // the rescale is the redeemed token's, never a stranger's
        FEED = IAggregatorV3(feed);
        LT = lt;
        GAUGE = gauge;
        QUOTE = quote;
        UNDERLYING = underlying;
        WITHDRAW_SCALE = 10 ** (18 - dec);
        COLLATERAL = gauge == address(0) ? lt : gauge;
        MAX_STALENESS = maxStaleness;
        /// @dev THE PAIR'S AND THE FEED'S DECIMALS ARE READ HERE, once: the hub's frame is a constant and knows none.
        /// @dev Both collateral shapes are 18-dec by the rails above, so the collateral's term is one share.
        PRICE_NUM = (1 << 96) * 10 ** IERC20Decimals(quote).decimals();
        PRICE_DEN = (10 ** IAggregatorV3(feed).decimals()) * 10 ** IERC20Decimals(gauge == address(0) ? lt : gauge).decimals();
    }

    /// @dev The composed legs answer a HUMAN price at the feed's scale; the hub reads quote atoms per collateral atom.
    /// @param human The composed price, at the feed's own scale.
    /// @return The same price in the hub's frame, or zero when the answer is too wide to carry.
    function _toFrame(uint256 human) private view returns (uint256) {
        if (human > type(uint256).max / PRICE_NUM) return 0; // absurd answer: closed, not a panic
        return FullMath.mulDiv(human, PRICE_NUM, PRICE_DEN);
    }

    /// @notice The ordered pair this record prices; genesis refuses any other.
    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    /// @dev A wrong-pair read is a wiring bug, unreachable from a created market -- revert loudly.
    function _requirePair(address quote, address collateral) internal view {
        if (quote != QUOTE || collateral != COLLATERAL) revert WrongPair();
    }

    /// @dev The composed read: every leg checked, and a reverting, unfit or absurd one answers 0.
    function _price() internal view returns (uint256) {
        (uint256 usd,) = ChainlinkDataFeed.latest(FEED, MAX_STALENESS);
        if (usd == 0) return 0;
        uint256 pps;
        try IYbLt(LT).pricePerShare() returns (uint256 v) {
            if (v == 0) return 0;
            pps = v;
        } catch {
            return 0;
        }
        /// @dev The LOWER of the two rates YieldBasis publishes, because they are not the same number.
        /// @dev `pricePerShare` is accounting; a redeemer gets an imbalanced Curve exit, which pays less.
        /// @dev Their own docs name the gap the "Temporary Redemption Discount", and `preview_withdraw` quotes it.
        /// @dev Nonreentrant upstream where `pricePerShare` is not: a locked read reverts into the catch.
        /// @dev So a read mid-YieldBasis-operation closes the record instead of answering off accounting.
        /// @dev `pricePerShare` is 18-dec whatever the underlying is; this leg is UNDERLYING-NATIVE.
        /// @dev Rescaling it up is what makes the two comparable; skip it and the min is off by 1e10 on BTC.
        try IYbLt(LT).preview_withdraw(1e18) returns (uint256 w) {
            if (w == 0) return 0;
            (bool fits, uint256 scaled) = Math.tryMul(w, WITHDRAW_SCALE);
            if (!fits) return 0; // absurd answer: closed, not a panic
            pps = Math.min(pps, scaled);
        } catch {
            return 0;
        }
        (bool ok, uint256 p) = Math.tryMul(usd, pps);
        if (!ok) return 0; // absurd product: closed, not a panic
        p /= 1e18;
        if (GAUGE == address(0)) return _toFrame(p);
        try IYbGauge(GAUGE).convertToAssets(1e18) returns (uint256 c2a) {
            (ok, p) = Math.tryMul(p, c2a);
            return ok ? _toFrame(p / 1e18) : 0; // zero c2a composes to zero and an absurd one closes: never a panic
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

    /// @notice The current composed value, 0 when any leg is unfit to referee.
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
