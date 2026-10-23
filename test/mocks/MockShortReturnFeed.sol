// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice A feed whose every call returns ONE word: `decimals()` decodes, while a round or a dAPI read is too short to.
/// @dev The shape a `try` cannot catch: the callee succeeds, and the caller's own decode is what fails.
contract MockShortReturnFeed {
    fallback() external {
        assembly {
            mstore(0, 8)
            return(0, 32)
        }
    }
}
