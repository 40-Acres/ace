// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";

/// @notice A persistence record that can be made to REVERT on `minPriceOverWindow` mid-test.
/// @dev Healthy at genesis (the frame and span rails read it), then `setRevoked(true)` sickens it.
/// @dev Exists to pin the must-execute backstop: a sick record routes an armed loan to SETTLEMENT.
contract MockRevertingRecord is IPersistenceRecord {
    address public QUOTE;
    address public COLLATERAL;
    bool public revoked;
    uint256 public windowMin = 2e18; // the value `minPrice(pair)` answers; named apart so the reader is the function
    bool public below;
    bool public above;

    constructor(address quote, address collateral) {
        QUOTE = quote;
        COLLATERAL = collateral;
    }

    /// @notice How `minPriceOverWindow` shapes its ANSWER: 0 clean, 1 empty, 2 short (31), 3 over-long (64).
    /// @dev A malformed answer is a SUCCESSFUL call, so it fails in the CALLER's decoder, not in this frame.
    /// @dev That is the case `try/catch` cannot absorb, which `revoked` (a plain revert) does not reach.
    uint8 public answerMode;

    function setRevoked(bool v) external {
        revoked = v;
    }

    function setAnswerMode(uint8 m) external {
        answerMode = m;
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

    /// @dev The one sickened read: the draw cap and the Price-mode baseline both come through here.
    function minPrice(address, address) external view returns (uint256) {
        require(!revoked, "record revoked");
        if (answerMode == 1) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (answerMode == 2) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 31)
            }
        }
        if (answerMode == 3) {
            assembly ("memory-safe") {
                mstore(0, 2000000000000000000)
                mstore(32, 0)
                return(0, 64)
            }
        }
        return windowMin;
    }
}
