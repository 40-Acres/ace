// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {AceVaultInKind} from "../../../src/curator/libraries/AceVaultInKind.sol";
import {CapListing, ProductConfig} from "../../../src/curator/libraries/AceVaultCaps.sol";
import {AceVaultFlows, Cap, PendingCap, Seizure, VaultConfig} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {CuratorVaultHarness} from "./CuratorVaultHarness.sol";

/// @title VaultForwardHarness
/// @notice CuratorVaultHarness, whose `tailMatches` it inherits, plus read-only views of the caps, the door's ledger and the in-kind tracker.
/// @dev It adds getters and no state; each figure is read through its library's own layout.
contract VaultForwardHarness is CuratorVaultHarness {
    constructor(VaultConfig memory cfg, ProductConfig memory pc, CapListing[] memory caps, string memory name_, string memory symbol_)
        CuratorVaultHarness(cfg, pc, caps, name_, symbol_)
    {}

    /// @notice A key's stored cap.
    function capOf(address key) external view returns (uint192 cap, bool listed) {
        Cap memory c = AceVaultFlows.vaultLayout().caps[key];
        return (c.cap, c.listed);
    }

    /// @notice A key's pending change.
    function pendingCapOf(address key) external view returns (uint192 cap, bool listed, uint64 validAt) {
        PendingCap memory p = AceVaultFlows.vaultLayout().pendingCaps[key];
        return (p.value.cap, p.value.listed, p.validAt);
    }

    /// @notice A collateral's record in the door's ledger.
    function seizedOf(address c) external view returns (uint184 value, uint64 writeOffAt, bool open) {
        Seizure memory s = AceVaultFlows.vaultLayout().seized[c];
        return (s.value, s.writeOffAt, s.open);
    }

    /// @notice The keys open in the door's ledger.
    function openSeizedOf() external view returns (uint256) {
        return AceVaultFlows.vaultLayout().openSeized;
    }

    /// @notice The batch count, and the open batch's block (zero is none).
    function fold() external view returns (uint64 count, uint64 foldBlock) {
        AceVaultInKind.Layout storage s = AceVaultInKind.inKindLayout();
        return (s.batchCount, s.foldBlock);
    }

    /// @notice Batch `k`'s block and the supply it closed on; zero supply while it is open.
    function batchOf(uint256 k) external view returns (uint48 at, uint208 supply) {
        AceVaultInKind.Batch storage b = AceVaultInKind.inKindLayout().batches[k];
        return (b.at, b.supply);
    }

    /// @notice The shares a batch closing now would count: every holder's balance and escrow.
    function trackedSupplyOf() external view returns (uint256) {
        return AceVaultInKind.inKindLayout().trackedSupply;
    }

    /// @notice A holder's latest tracked checkpoint: its shares plus its escrow.
    function heldTracked(address h) external view returns (uint256) {
        return Checkpoints.latest(AceVaultInKind.inKindLayout().bal[h]);
    }

    /// @notice A holder's next unsettled payout of a token.
    function cursorOf(address h, address t) external view returns (uint256) {
        return uint128(AceVaultInKind.inKindLayout().cursor[h][t]);
    }

    /// @notice The checkpoint index a holder's walk of a token reads next.
    function cursorCheckpointOf(address h, address t) external view returns (uint256) {
        return AceVaultInKind.inKindLayout().cursor[h][t] >> 128;
    }

    /// @notice How many payouts of a token there are.
    function payoutCount(address t) external view returns (uint256) {
        return AceVaultInKind.inKindLayout().payouts[t].length;
    }

    /// @notice Whether payout `i` of a token belongs to a batch still open; false past the list's end.
    function payoutOpen(address t, uint256 i) external view returns (bool) {
        AceVaultInKind.Layout storage s = AceVaultInKind.inKindLayout();
        if (i >= s.payouts[t].length) return false;
        return s.batches[s.payouts[t][i].batch].supply == 0;
    }
}
