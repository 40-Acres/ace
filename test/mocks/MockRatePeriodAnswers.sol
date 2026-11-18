// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice A hub naming a rate period of any length, so a probe can be asked about a second either side of a year.
contract MockPeriodHub {
    uint256 internal immutable PERIOD;

    constructor(uint256 period) {
        PERIOD = period;
    }

    /// @notice The period this stand-in was built with.
    function RATE_PERIOD() external view returns (uint256) {
        return PERIOD;
    }
}

/// @notice A contract whose fallback succeeds on every call with `ret` as its whole returndata, unencoded.
/// @dev An empty `ret` is a success that says nothing; a short one is a success that says less than a word.
contract MockRawAnswerHub {
    bytes internal ret;

    constructor(bytes memory r) {
        ret = r;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return ret;
    }
}

/// @notice A hub whose `RATE_PERIOD()` reverts with one 365-day year as its revert data: a failure that carries the right word.
contract MockRevertingYearHub {
    /// @notice Never answers: it reverts, carrying 31,536,000 as the whole revert payload.
    function RATE_PERIOD() external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0, 31536000)
            revert(0, 0x20)
        }
    }
}
