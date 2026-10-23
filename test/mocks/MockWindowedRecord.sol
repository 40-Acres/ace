// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";

/// @title MockWindowedRecord
/// @notice A persistence record that ACTUALLY HONOURS ITS WINDOW: prints are timestamped and read back.
/// @notice `MockPersistenceRecord` answers `persistedBelow` by arithmetic and IGNORES the window argument.
/// @notice That is right for a suite testing the sizing and WRONG for any suite testing a rate over time.
/// @dev THE RECORD IS A STEP FUNCTION: a print at `t` holds until the next one, as a buffer does between writes.
/// @dev `persistedBelow(x, w)` is true iff every segment covering `[now - w, now]` is strictly under `x`.
/// @dev It also needs the record to reach back that far: a young record answers false rather than optimistically.
/// @dev `minPriceOverWindow` answers 0 when it does not span, which is the interface's own sentinel.
/// @dev IT DOES NOT MODEL FRESHNESS: `PersistenceRecord` refuses a window it has not printed inside; this answers.
/// @dev So a fixture on this record can draw over silence that the real record would refuse at the draw door.
contract MockWindowedRecord is IPersistenceRecord {
    address public QUOTE;
    address public COLLATERAL;

    uint256[] public times; // the timestamp each print landed at, strictly increasing
    uint256[] public prices; // the price in force from that timestamp until the next print

    uint256 public span = 365 days; // what this record answers over: finite, since `max` is the ORACLE sentinel
    uint256 public depth; // the depth answer; irrelevant to every rate measurement here

    /// @dev THE RECORD OWNS ITS WINDOWS now, so the interface members take none and read these.
    /// @dev Defaulted to the shipped pair so a fixture that never sets them still measures something real.
    uint256 public PERSISTENCE_WINDOW = 30 minutes;
    uint256 public PENDING_WINDOW = 4 hours;

    constructor(address quote, address collateral) {
        QUOTE = quote;
        COLLATERAL = collateral;
    }

    /// @notice Set what the two below-questions measure over; the settle window is their sum.
    function setWindows(uint256 p, uint256 pending) external {
        PERSISTENCE_WINDOW = p;
        PENDING_WINDOW = pending;
    }

    function SETTLE_WINDOW() external view returns (uint256) {
        return PERSISTENCE_WINDOW + PENDING_WINDOW;
    }

    /// @notice Land a print at the current block timestamp; it holds until the next one.
    /// @dev A second print in the same second REPLACES the first rather than appending a zero-width segment.
    /// @param price The price (1e18 quote per collateral) from now until the next print.
    function push(uint256 price) external {
        uint256 n = times.length;
        if (n > 0 && times[n - 1] == block.timestamp) {
            prices[n - 1] = price;
            return;
        }
        times.push(block.timestamp);
        prices.push(price);
    }

    function setSpan(uint256 v) external {
        span = v;
    }

    function setDepth(uint256 v) external {
        depth = v;
    }

    function printCount() external view returns (uint256) {
        return times.length;
    }

    /// @dev The first print in force over `[now - window, now]`, or `spans = false` if the record is too young.
    /// @dev Walks back from the newest, so the common case of a short window over a long history is cheap.
    function _from(uint256 window) private view returns (uint256 from, bool spans) {
        if (times.length == 0 || block.timestamp < window) return (0, false);
        uint256 start = block.timestamp - window;
        if (times[0] > start) return (0, false);
        from = times.length - 1;
        while (times[from] > start) from--;
        spans = true;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256 price) external view returns (bool) {
        return persistedBelowOver(price, PERSISTENCE_WINDOW);
    }

    function persistedBelowSettle(address, address, uint256 price) external view returns (bool) {
        return persistedBelowOver(price, PERSISTENCE_WINDOW + PENDING_WINDOW);
    }

    /// @notice The window-taking body, kept PUBLIC and non-interface: measuring over an arbitrary window is this mock's job.
    function persistedBelowOver(uint256 price, uint256 window) public view returns (bool) {
        (uint256 from, bool spans) = _from(window);
        if (!spans) return false;
        for (uint256 i = from; i < prices.length; i++) {
            if (prices[i] >= price) return false;
        }
        return true;
    }

    /// @dev NOT an interface member any more; kept public because the lens still probes it by signature.
    function persistedAbove(address, address, uint256 price) external view returns (bool) {
        return persistedAboveOver(price, PERSISTENCE_WINDOW);
    }

    function persistedAboveOver(uint256 price, uint256 window) public view returns (bool) {
        (uint256 from, bool spans) = _from(window);
        if (!spans) return false;
        for (uint256 i = from; i < prices.length; i++) {
            if (prices[i] <= price) return false;
        }
        return true;
    }

    function lastObserved(address, address) external view returns (uint256) {
        uint256 n = prices.length;
        return n == 0 ? 0 : prices[n - 1];
    }

    function minPrice(address, address) external view returns (uint256) {
        return minPriceOver(PERSISTENCE_WINDOW);
    }

    /// @notice The window-taking body, kept PUBLIC and non-interface, for the same reason as the below twin.
    function minPriceOver(uint256 window) public view returns (uint256) {
        (uint256 from, bool spans) = _from(window);
        if (!spans) return 0;
        uint256 lo = type(uint256).max;
        for (uint256 i = from; i < prices.length; i++) {
            if (prices[i] < lo) lo = prices[i];
        }
        return lo;
    }

    function minDepthOverWindow(uint256) external view returns (uint256) {
        return depth;
    }

    /// @dev Zero, so `MarketInit`'s "depth window over blackout" rail passes at any persistence window.
    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }

    /// @dev NOT an interface member any more; kept public because a fixture still asserts the ring's reach.
    function minGuaranteedSpan() external view returns (uint256) {
        return span;
    }
}
