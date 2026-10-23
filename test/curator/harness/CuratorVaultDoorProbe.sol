// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultConfig} from "../../../src/curator/AceVault.sol";
import {Listing} from "../../../src/curator/CuratorVault.sol";
import {CuratorVaultDoorHarness} from "./CuratorVaultDoorHarness.sol";

/// @notice The door harness plus the bodies its edge rows need: a mid-body payment and an unsynced loss.
contract CuratorVaultDoorProbe is CuratorVaultDoorHarness {
    using SafeERC20 for IERC20;

    constructor(VaultConfig memory cfg, Listing[] memory listings) CuratorVaultDoorHarness(cfg, listings) {}

    /// @notice A door whose body is paid `amtIn` by `from` mid-body, as a buyer pays, then pays `amtOut` on to `to`.
    function inAndOut(bool, address from, uint256 amtIn, address to, uint256 amtOut) external nonReentrant door {
        IERC20(asset()).safeTransferFrom(from, address(this), amtIn);
        IERC20(asset()).safeTransfer(to, amtOut);
    }

    /// @notice NOT A DOOR: `amt` of the asset leaves to `to` with no sync, so NAV falls and the mark has not seen it.
    function bleed(address to, uint256 amt) external {
        IERC20(asset()).safeTransfer(to, amt);
    }
}
