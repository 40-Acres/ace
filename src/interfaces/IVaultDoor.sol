// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IVaultDoor
/// @notice A door-mode AceVault's door: the contract its seized goods are handed to, which sells them and returns the cash.
/// @notice The vault never calls it; its constructor asks this one view, and refuses a door naming another vault or having no code.
/// @dev A door may also be the vault's TERMS: one address answering both interfaces.
interface IVaultDoor {
    /// @notice The one vault this door serves.
    function VAULT() external view returns (address);
}
