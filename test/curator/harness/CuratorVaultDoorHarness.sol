// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultConfig} from "../../../src/curator/AceVault.sol";
import {CuratorVault, Listing} from "../../../src/curator/CuratorVault.sol";

/// @notice A CuratorVault product whose doors each do ONE thing a builder might, so the base's door checks can be measured.
/// @dev Every door realizes; the `bool` the doors take is ignored and kept so a row reads as the same call under either close.
contract CuratorVaultDoorHarness is CuratorVault {
    using SafeERC20 for IERC20;

    constructor(VaultConfig memory cfg, Listing[] memory listings) CuratorVault(cfg, 10e6, 1.4e18, 1 days, listings, "Door", "cDOOR") {}

    /// @notice A door with an empty body.
    function step(bool) external nonReentrant door {}

    /// @notice A door with no reentrancy guard around it.
    function unguarded() external door {}

    /// @notice A door that pays `amt` of the vault's own asset balance to `to`.
    function spend(bool, address to, uint256 amt) external nonReentrant door {
        IERC20(asset()).safeTransfer(to, amt);
    }

    /// @notice A door that returns early on `early`, so the close must still run on the early branch.
    function earlyReturn(bool early) external nonReentrant door returns (uint256) {
        if (early) return 1;
        return 2;
    }

    /// @notice NOT A DOOR: the asset leaves the vault as a fee-charging or rebasing token's would, outside any bracket.
    function leak(address to, uint256 amt) external {
        IERC20(asset()).safeTransfer(to, amt);
    }

    /// @notice NOT A DOOR: the delegate hook alone, so its bubbling can be read off one call.
    function delegateTo(address lib, bytes calldata data) external returns (bytes memory) {
        return _delegate(lib, data);
    }
}

/// @notice A stand-in linked library: one member answers, one reverts with a custom error, one reverts with nothing.
contract DelegateTarget {
    error Boom(uint256 code);

    /// @notice Answer a fixed word.
    function answer() external pure returns (uint256) {
        return 42;
    }

    /// @notice Revert with a custom error carrying `code`.
    function boom(uint256 code) external pure {
        revert Boom(code);
    }

    /// @notice Revert with no data at all.
    function empty() external pure {
        revert();
    }
}
