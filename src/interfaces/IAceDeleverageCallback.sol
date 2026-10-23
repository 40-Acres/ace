// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice The keeper's routing callback: ACE hands over the units, the keeper returns the floor.
/// @dev The callee is always `msg.sender`, so there is no third party to authenticate.
/// @dev ACE pulls an EXACT `transferFrom` on return, never a delta -- APPROVE the hub `quoteOwed`.
/// @dev Anything the route earns above `quoteOwed` stays with the keeper.
/// @dev Mid-callback THIS loan reads under-collateralized: units gone, debt not yet melted.
interface IAceDeleverageCallback {
    /// @param unitsSold Collateral units already transferred to the keeper.
    /// @param quoteOwed The floor at FULL size; refusing a tail lowers the pull pro-rata on what filled.
    /// @param data Opaque routing payload the keeper passed to `deleverage`.
    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata data) external;
}
