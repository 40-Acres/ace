// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";

/// @title UntrustedDependencyMocks
/// @notice Creator-chosen dependencies that fail in the two ways a bounded copy does not fix: gas, and no answer.
/// @dev `invalid()` models the EIP-150 shape exactly: the sub-call consumes its whole allowance and returns nothing.
/// @dev An HONEST but over-expensive callee lands in the same place, so these model the COST, never the malice.
/// @dev THE RECORD IS THE ONLY UNTRUSTED CALLEE LEFT on the entry path: `BurnAllGate` went with the gate
/// @dev interface, since admission is now an address comparison and calls nothing.

/// @notice A record whose windowed-min read consumes every wei of gas forwarded to it once armed.
/// @dev `minGuaranteedSpan` is the unbounded sentinel, so genesis takes the `MarketInit` cost-interview exemption.
contract BurnAllRecord is IPersistenceRecord {
    address public QUOTE; // the ordered pair genesis binds against
    address public COLLATERAL; // its collateral half
    uint256 public windowMin = 2e18; // above every seeded tick, so the cap binds without gating
    bool public burning; // armed after genesis: the creation interview must still get an answer
    bool public below; // what `persistedBelow` answers while the record is readable
    bool public above; // its mirror

    constructor(address quote, address collateral) {
        QUOTE = quote;
        COLLATERAL = collateral;
    }

    function setBurning(bool v) external {
        burning = v;
    }

    function setMinPrice(uint256 v) external {
        windowMin = v;
    }

    function setBelow(bool v) external {
        below = v;
    }

    function setAbove(bool v) external {
        above = v;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256) external view returns (bool) {
        return below;
    }

    function persistedBelowSettle(address, address, uint256) external view returns (bool) {
        return below;
    }

    /// @dev NOT an interface member any more; kept public because the lens still probes it by signature.
    function persistedAbove(address, address, uint256) external view returns (bool) {
        return above;
    }

    function lastObserved(address, address) external pure returns (uint256) {
        return 0;
    }

    function minDepthOverWindow(uint256) external pure returns (uint256) {
        return 0;
    }

    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }

    /// @notice The windowed minimum, which every judgment-spending verb reads.
    /// @dev The one burning read: the draw cap, the fold's predicate and the disposal floor all come through here.
    function minPrice(address, address) external view returns (uint256) {
        if (burning) _burnAll();
        return windowMin;
    }

    function _burnAll() private pure {
        assembly {
            invalid()
        }
    }
}

/// @notice An HONEST record that answers correctly but charges a caller-chosen amount of gas to do it.
/// @dev The rail-legal 1-day/60s window shape, priced as a dial: this is the callee no fixed stipend can bound.
contract CostlyRecord is IPersistenceRecord {
    address public QUOTE; // the ordered pair genesis binds against
    address public COLLATERAL; // its collateral half
    uint256 public windowMin = 2e18; // the answer, once it has been paid for
    uint256 public rounds; // hash rounds per windowed-min read; the predicate cost dial
    bool public below; // what `persistedBelow` answers
    bool public above; // its mirror

    constructor(address quote, address collateral) {
        QUOTE = quote;
        COLLATERAL = collateral;
    }

    function setRounds(uint256 v) external {
        rounds = v;
    }

    function setMinPrice(uint256 v) external {
        windowMin = v;
    }

    function setBelow(bool v) external {
        below = v;
    }

    function setAbove(bool v) external {
        above = v;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256) external view returns (bool) {
        return below;
    }

    function persistedBelowSettle(address, address, uint256) external view returns (bool) {
        return below;
    }

    /// @dev NOT an interface member any more; kept public because the lens still probes it by signature.
    function persistedAbove(address, address, uint256) external view returns (bool) {
        return above;
    }

    function lastObserved(address, address) external pure returns (uint256) {
        return 0;
    }

    function minDepthOverWindow(uint256) external pure returns (uint256) {
        return 0;
    }

    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }

    /// @notice The windowed minimum, answered truthfully after the ring walk it costs.
    function minPrice(address, address) external view returns (uint256) {
        uint256 n = rounds;
        bytes32 h = bytes32(n);
        for (uint256 i; i < n; i++) {
            h = keccak256(abi.encode(h, i));
        }
        return h == bytes32(type(uint256).max) ? 0 : windowMin; // the walk feeds the answer, so it cannot be elided
    }
}

/// @notice A record whose windowed-min read answers with a caller-chosen PILE, the first word well-formed.
/// @dev Only a size bound can refuse it, so it isolates the returndata bound from the value decode.
contract FloodRecord is IPersistenceRecord {
    address public QUOTE; // the ordered pair genesis binds against
    address public COLLATERAL; // its collateral half
    uint256 public windowMin = 2e18; // the first word, always well-formed
    uint256 public words = 1; // how many words the answer carries; the pile the caller must not pay for

    constructor(address quote, address collateral) {
        QUOTE = quote;
        COLLATERAL = collateral;
    }

    function setWords(uint256 n) external {
        words = n;
    }

    function setMinPrice(uint256 v) external {
        windowMin = v;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function persistedBelowSettle(address, address, uint256) external pure returns (bool) {
        return false;
    }

    /// @dev NOT an interface member any more; kept public because the lens still probes it by signature.
    function persistedAbove(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function lastObserved(address, address) external pure returns (uint256) {
        return 0;
    }

    function minDepthOverWindow(uint256) external pure returns (uint256) {
        return 0;
    }

    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }

    /// @notice The windowed minimum, returned inside a pile of the caller's chosen size.
    function minPrice(address, address) external view returns (uint256) {
        uint256 n = words * 32;
        uint256 v = windowMin;
        assembly ("memory-safe") {
            mstore(0, v)
            return(0, n)
        }
    }
}

/// @notice A record that cannot answer `persistedBelow` for thresholds inside a caller-chosen window.
/// @dev The two distress reads on the deleverage path ask different thresholds, so a window isolates either one.
contract SelectiveRecord is IPersistenceRecord {
    address public QUOTE; // the ordered pair genesis binds against
    address public COLLATERAL; // its collateral half
    uint256 public windowMin = 2e18; // the windowed minimum, which stays readable throughout
    uint256 public bandPrice; // `persistedBelow(x)` answers `x > bandPrice` wherever it can answer at all
    uint256 public breakFrom; // inclusive lower edge of the thresholds it refuses
    uint256 public breakTo; // inclusive upper edge; zero disables the window entirely
    bool public priceBroken; // when set, the windowed-min read reverts too

    constructor(address quote, address collateral) {
        QUOTE = quote;
        COLLATERAL = collateral;
    }

    function setBandPrice(uint256 v) external {
        bandPrice = v;
    }

    function setMinPrice(uint256 v) external {
        windowMin = v;
    }

    function setPriceBroken(bool v) external {
        priceBroken = v;
    }

    /// @notice Refuse every `persistedBelow` threshold in `[from, to]`; `to == 0` answers everything.
    /// @param from Inclusive lower edge.
    /// @param to Inclusive upper edge.
    function setBreakWindow(uint256 from, uint256 to) external {
        breakFrom = from;
        breakTo = to;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256 x) external view returns (bool) {
        return _below(x);
    }

    function persistedBelowSettle(address, address, uint256 x) external view returns (bool) {
        return _below(x);
    }

    /// @dev The refusal band is a property of the THRESHOLD, not of the window, so both twins hit it alike.
    function _below(uint256 x) internal view returns (bool) {
        require(breakTo == 0 || x < breakFrom || x > breakTo, "record cannot answer");
        return x > bandPrice;
    }

    /// @dev NOT an interface member any more; kept public because the lens still probes it by signature.
    function persistedAbove(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function lastObserved(address, address) external pure returns (uint256) {
        return 0;
    }

    function minDepthOverWindow(uint256) external pure returns (uint256) {
        return 0;
    }

    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }

    function minPrice(address, address) external view returns (uint256) {
        require(!priceBroken, "record cannot answer");
        return windowMin;
    }
}
