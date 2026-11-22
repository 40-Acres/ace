// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CapListing, ProductConfig} from "../../../src/curator/libraries/AceVaultCaps.sol";
import {AceVaultFlows, VaultConfig} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {AceVaultNav} from "../../../src/curator/libraries/AceVaultNav.sol";
import {VaultBoundaryHarness} from "./VaultBoundaryHarness.sol";

/// @title VaultLivenessHarness
/// @notice VaultBoundaryHarness plus the exit gate's two legs, the requests' hold, one holder's request and the exemption word.
/// @notice A spec reads with them what the vault promises an LP: exits stay covered, held cash stays home, and only the keys move what they own.
/// @dev It adds getters and no state; each reads through the vault's own helpers.
contract VaultLivenessHarness is VaultBoundaryHarness {
    constructor(VaultConfig memory cfg, ProductConfig memory pc, CapListing[] memory caps, string memory name_, string memory symbol_)
        VaultBoundaryHarness(cfg, pc, caps, name_, symbol_)
    {}

    /// @notice The vault's exit gate: whether idle covers the standing requests' worth at the last sync's NAV.
    function exitsCovered() external view returns (bool) {
        return _exitsCovered();
    }

    /// @notice The stored trough hold: zero for none, all ones for a mark, else the second it lifts by.
    function troughHold() external view returns (uint48) {
        return AceVaultFlows.vaultLayout().troughHold;
    }

    /// @notice The gate's second leg as the vault runs it: whether the stored trough hold alone shuts entry, `AceVaultNav.shutByHoldAlone`.
    function holdOnly() external view returns (bool) {
        return AceVaultNav.shutByHoldAlone(VEST_WINDOW, VEST_FLOOR);
    }

    /// @notice The idle the standing requests hold at today's NAV: what no instant exit and no placement may take.
    function heldCash() external view returns (uint256 held) {
        held = idle() - _instantCashAt(totalAssets());
    }

    /// @notice The shares `holder`'s request escrows on the vault.
    function requestOf(address holder) external view returns (uint256) {
        return AceVaultFlows.vaultLayout().requests[holder].shares;
    }

    /// @notice When `holder`'s request lapses unless renewed.
    function requestExpiryOf(address holder) external view returns (uint64) {
        return AceVaultFlows.vaultLayout().requests[holder].expiresAt;
    }

    /// @notice The hub's settled count at the guardian's last dead-pot exemption; zero is none.
    function exemptSettledOf() external view returns (uint256) {
        return AceVaultFlows.vaultLayout().exemptSettled;
    }
}
