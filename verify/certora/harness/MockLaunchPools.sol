// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title MockLaunchPools
/// @notice The two reads `RunwayHook` takes of the launch factory, answered from storage the prover sets.
/// @dev LINKED to the hook's `FACTORY` immutable. Every answer is free, so the hook meets every launchBy and every launching flag.
contract MockLaunchPools {
    mapping(bytes32 => uint64) internal launchBy; // what launchByOf answers
    bool internal launching_; // what launching answers

    /// @notice A pool's last second to open, zero for a key no launch recorded.
    /// @param id The pool.
    /// @return The stored second.
    function launchByOf(PoolId id) external view returns (uint64) {
        return launchBy[PoolId.unwrap(id)];
    }

    /// @notice Whether a launch is registering now.
    /// @return The stored flag.
    function launching() external view returns (bool) {
        return launching_;
    }

    /// @notice The launchBy a spec compares the hook against.
    /// @param id The pool, as its word.
    /// @return The stored second.
    function launchByView(bytes32 id) external view returns (uint64) {
        return launchBy[id];
    }

    /// @notice The launching flag, for a spec.
    /// @return The stored flag.
    function launchingView() external view returns (bool) {
        return launching_;
    }
}
