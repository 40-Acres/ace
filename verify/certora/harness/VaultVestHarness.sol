// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CapListing, ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {AceVaultFlows, VaultConfig} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVaultHarness} from "./CuratorVaultHarness.sol";

/// @title VaultVestHarness
/// @notice CuratorVaultHarness plus the vest's three write sites as entries, so a spec proves each write's bounds from any start.
/// @notice It adds a getter and three entries and no state, so the layout is AceVault's and each write is the vault's own.
/// @dev Never a parametric target: a bare stamp skips the sync's mark write, so a pile-within-mark rule would fail on it.
contract VaultVestHarness is CuratorVaultHarness {
    constructor(VaultConfig memory cfg, ProductConfig memory pc, CapListing[] memory caps, string memory name_, string memory symbol_)
        CuratorVaultHarness(cfg, pc, caps, name_, symbol_)
    {}

    /// @notice The vest's stored basis, read back as basis * (maturity - now) / VEST_WINDOW.
    function vestBasis() external view returns (uint128) {
        return AceVaultFlows.layout().vestBasis;
    }

    /// @notice The vault's own `_stampVest`, the only line of the vault that writes the vest maturity.
    function stampVest(uint256 amount) external {
        _stampVest(amount);
    }

    /// @notice The vault's own `_burnVest`, the sync's write on a NAV fall.
    function burnVest(uint256 amount) external {
        _burnVest(amount);
    }

    /// @notice The vault's own `_release`, the last requester's write: the pile vests whole and the mark takes `g`.
    function release(uint256 g) external {
        _release(g);
    }
}
