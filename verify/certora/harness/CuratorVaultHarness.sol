// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault, Listing, VaultConfig} from "../../../src/curator/CuratorVault.sol";

/// @title CuratorVaultHarness
/// @notice CuratorVault plus two views, so a spec reads the vest maturity and the NAV mark through code rather than a raw slot.
/// @notice Under via-IR the prover cannot analyse this constructor's storage, and a raw-slot read in a spec needs that.
/// @notice It adds getters and no state, so the layout is CuratorVault's and every method under test is its own.
contract CuratorVaultHarness is CuratorVault {
    constructor(
        VaultConfig memory cfg,
        uint256 minDebt,
        uint256 coverageWad,
        uint64 timelock,
        Listing[] memory listings,
        string memory name_,
        string memory symbol_
    ) CuratorVault(cfg, minDebt, coverageWad, timelock, listings, name_, symbol_) {}

    /// @notice When the deferred pile finishes vesting.
    function vestMaturity() external view returns (uint64) {
        return AceVaultFlows.layout().vestMaturity;
    }

    /// @notice The gross NAV the last sync observed, which every stamp is capped at.
    function navMark() external view returns (uint256) {
        return AceVaultFlows.layout().navMark;
    }
}
