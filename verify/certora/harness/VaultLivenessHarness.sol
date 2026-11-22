// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CapListing, ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {AceVaultFlows, VaultConfig, VaultLayout} from "../../../src/curator/AceVaultFlows.sol";
import {VaultBoundaryHarness} from "./VaultBoundaryHarness.sol";

/// @title VaultLivenessHarness
/// @notice VaultBoundaryHarness plus the exit gate's two legs, the requests' hold, one holder's request and the exemption word.
/// @notice A spec reads with them what the vault promises an LP: exits stay covered, held cash stays home, and only the keys move what they own.
/// @dev It adds getters and no state; each reads through the vault's own helpers, except `holdOnly`, which restates a private one.
contract VaultLivenessHarness is VaultBoundaryHarness {
    uint48 private constant TROUGH_MARKED = type(uint48).max; // AceVault's private mark word, restated for `holdOnly`

    constructor(VaultConfig memory cfg, ProductConfig memory pc, CapListing[] memory caps, string memory name_, string memory symbol_)
        VaultBoundaryHarness(cfg, pc, caps, name_, symbol_)
    {}

    /// @notice The vault's exit gate: whether idle covers the standing requests' worth at the last sync's NAV.
    function exitsCovered() external view returns (bool) {
        return _exitsCovered();
    }

    /// @notice The stored trough hold: zero for none, all ones for a mark, else the second it lifts by.
    function troughHold() external view returns (uint48) {
        return AceVaultFlows.layout().troughHold;
    }

    /// @notice AceVault's `_shutByHoldAlone`, restated line for line over the vault's own helpers, as a derived contract cannot call a private function.
    /// @dev A spec that reads this states the gate's second leg as written; a rule that must not lean on the restatement reads `troughHold` instead.
    function holdOnly() external view returns (bool) {
        VaultLayout storage $ = AceVaultFlows.layout();
        uint48 holdUntil = $.troughHold;
        if (holdUntil == 0 || holdUntil == TROUGH_MARKED || block.timestamp >= holdUntil || ($.openSeized != 0 && $.exemptSettled == 0)) return false;
        (uint256 deferred, uint256 mark) = (unvested(), $.navMark);
        return AceVaultFlows.material(deferred, mark) && !_vesting(deferred, Math.saturatingSub(mark, deferred));
    }

    /// @notice The idle the standing requests hold at today's NAV: what no instant exit and no placement may take.
    function heldCash() external view returns (uint256 held) {
        (, held) = _holdsAt(totalAssets());
    }

    /// @notice The shares `holder`'s request escrows on the vault.
    function requestOf(address holder) external view returns (uint256) {
        return AceVaultFlows.layout().requests[holder].shares;
    }

    /// @notice When `holder`'s request lapses unless renewed.
    function requestExpiryOf(address holder) external view returns (uint64) {
        return AceVaultFlows.layout().requests[holder].expiresAt;
    }

    /// @notice The hub's settled count at the guardian's last dead-pot exemption; zero is none.
    function exemptSettledOf() external view returns (uint256) {
        return AceVaultFlows.layout().exemptSettled;
    }
}
