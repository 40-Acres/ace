// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CapListing, ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {AceVaultFlows, VaultConfig} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {AceVaultNav} from "../../../src/vault/libraries/AceVaultNav.sol";
import {VaultForwardHarness} from "./VaultForwardHarness.sol";

/// @title VaultBoundaryHarness
/// @notice VaultForwardHarness plus the five figures the boundary spec reads: the high-water, the drawdown, the pending pile, the lock, the escrow.
/// @dev It adds getters and no state; each reads through the vault's own helpers, so a rule states what the vault computes.
contract VaultBoundaryHarness is VaultForwardHarness {
    constructor(VaultConfig memory cfg, ProductConfig memory pc, CapListing[] memory caps, string memory name_, string memory symbol_)
        VaultForwardHarness(cfg, pc, caps, name_, symbol_)
    {}

    /// @notice Gross NAV's high-water.
    function navHigh() external view returns (uint256) {
        return AceVaultFlows.vaultLayout().navHigh;
    }

    /// @notice Gross NAV's fall below its high-water, the figure the total's room counts.
    function drawdown() external view returns (uint256) {
        return Math.saturatingSub(AceVaultFlows.vaultLayout().navHigh, grossNav());
    }

    /// @notice The deferred gain the next sync would leave at today's gross, which `totalAssets` takes off gross.
    function pendingPile() external view returns (uint256) {
        return AceVaultNav.deferredAt(grossNav(), VEST_WINDOW);
    }

    /// @notice Whether the vault's lock is held.
    function guardEntered() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    /// @notice The shares every standing exit request has escrowed on the vault.
    function requestedShares() external view returns (uint256) {
        return AceVaultFlows.vaultLayout().requestedShares;
    }
}
