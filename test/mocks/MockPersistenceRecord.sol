// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @notice Stand-in for the v4 hook's observation buffer.
/// @notice Tests set whether price "persisted" below or above a threshold for a window, so settlement runs without the real hook.
/// @dev One source answers every price question, so a sick record closes the draw cap and the disposal floor together.
contract MockPersistenceRecord is IPersistenceRecord {
    bool public below;
    bool public above;
    uint256 public observed;

    address public QUOTE;
    address public COLLATERAL;

    /// @dev The ordered pair genesis binds against; an undeclared frame is refused by the rail, so a fixture must state the one it means.
    constructor(address quote, address collateral) {
        QUOTE = quote;
        COLLATERAL = collateral;
        // an UNDECLARED frame is a fixture genesis must refuse, so it has to be constructible: no decimals to read
        if (quote != address(0) && collateral != address(0)) windowMin = PriceFrame.px(2e18, quote, collateral);
    }

    function setFrame(address quote, address collateral) external {
        QUOTE = quote;
        COLLATERAL = collateral;
    }

    function setBelow(bool v) external {
        below = v;
    }

    function setAbove(bool v) external {
        above = v;
    }

    function setObserved(uint256 v) external {
        observed = v;
    }

    /// @dev Band mode: the record "sits" just under `level`, and persistedBelow(x) answers by ARITHMETIC (is x above the band?).
    /// @dev That lets a test watch distress dissolve as repay lowers the trigger; a zero band falls back to flag mode.
    uint256 public bandPrice;

    function setBelowBand(uint256 level) external {
        bandPrice = (level * 99) / 100; // band rests 1% under the given level
    }

    /// @dev The band price with no inset: `setBelowBand` rounds, so it cannot land a boundary on an exact wei.
    function setBandPrice(uint256 v) external {
        bandPrice = v;
    }

    /// @dev Answering only for the declared frame mirrors the real records; the frame stays settable because fixtures re-aim it mid-test.
    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256 x) external view returns (bool) {
        return _below(x);
    }

    /// @dev Mirrors the distress answer unless a fixture sets the twin apart, which is the straddle case.
    /// @dev Defaulting to a mirror keeps every suite written before the split reading as it did.
    function persistedBelowSettle(address, address, uint256 x) external view returns (bool) {
        return settleSplit ? settleBelow : _below(x);
    }

    function _below(uint256 x) internal view returns (bool) {
        if (bandPrice != 0) return x > bandPrice;
        return below;
    }

    bool public settleSplit; // when set, the settle twin answers `settleBelow` instead of mirroring distress
    bool public settleBelow;

    /// @dev The only way to make the two below-questions disagree: a break inside settle but past distress.
    function setSettleBelow(bool v) external {
        settleSplit = true;
        settleBelow = v;
    }

    /// @dev NOT an interface member any more; kept public because the lens still probes it by signature.
    function persistedAbove(address, address, uint256) external view returns (bool) {
        return above;
    }

    function lastObserved(address, address) external view returns (uint256) {
        return observed;
    }

    uint256 public minDepth;

    function setMinDepth(uint256 v) external {
        minDepth = v;
    }

    uint256 public DEPTH_WINDOW; // zero by default: no depth window matures the denominator instantly, so there is no blackout to cover

    function setDepthWindow(uint256 v) external {
        DEPTH_WINDOW = v;
    }

    uint256 public minGuaranteedSpan = 365 days; // finite: `max` is the ORACLE-class sentinel, and this mock is a ring

    function setMinGuaranteedSpan(uint256 v) external {
        minGuaranteedSpan = v;
    }

    function minDepthOverWindow(uint256) external view returns (uint256) {
        return minDepth;
    }

    /// @dev FINITE by default, and deliberately so: `max` is the NO-RECORD sentinel.
    /// @dev Defaulting to it gave every suite an infinite draw cap while it believed it held a record.
    /// @dev Two quote per collateral is the suite-wide idiom for "above every seeded tick", so the cap binds without gating.
    /// @dev Stated through `PriceFrame` rather than as a literal: it is a DEFAULT, so it reaches suites that name no price at all.
    uint256 public windowMin; // the value `minPrice(pair)` answers; named apart so the reader is the function

    function setMinPrice(uint256 v) external {
        windowMin = v;
    }

    bool public sick; // when set, the windowed-min read REVERTS: a feed that is broken, not merely dark

    /// @dev The third record shape, distinct from `minPrice = 0`: that answers zero, this refuses to answer.
    /// @dev The hub's `recordState` BUBBLES this while `tryPersistedPrice` absorbs it, so the two differ only here.
    function setSick(bool v) external {
        sick = v;
    }

    bool public shortAnswer; // when set, the windowed-min read RETURNS ZERO BYTES: an answer nothing can decode

    /// @dev The fourth record shape: the call SUCCEEDS and returns nothing, so the DECODE is what would fail.
    /// @dev Only a raw staticcall separates this from a real answer; try/catch sees success and decodes past the end.
    function setShortAnswer(bool v) external {
        shortAnswer = v;
    }

    function minPrice(address, address) external view returns (uint256) {
        require(!sick, "record sick");
        if (shortAnswer) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return windowMin;
    }

    uint256 public PERSISTENCE_WINDOW; // probed by the lens, never by the hub; zero reads as "does not disclose"
    uint256 public SETTLE_WINDOW;

    /// @dev The disclosure the lens probes off the record now that no market carries a window.
    function setWindows(uint256 p, uint256 pending) external {
        PERSISTENCE_WINDOW = p;
        SETTLE_WINDOW = p + pending;
    }
}
