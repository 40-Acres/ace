// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AceVaultFlows, VaultConfig} from "../../src/vault/libraries/AceVaultFlows.sol";

/// @dev A test asset's own mint, which every mock cash in this tree carries.
interface ISeedMint {
    function mint(address to, uint256 amount) external;
}

/// @notice The genesis seed every rig vault takes: `MIN_SEED` atoms, pre-funded at the vault's address-to-be before its constructor runs.
/// @dev The constructor books the whole balance it finds there, so a rig that funds more than the seed books more.
library VaultSeed {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant SEED = AceVaultFlows.MIN_SEED; // the seed a rig's config names

    /// @notice Mint `cfg.seed` of the config's asset to `vault`, the address a `new AceVault` is about to take; one already funded is left alone.
    /// @dev The skip lets a suite on a real asset with no mint fund the address itself, by `deal`, before a shared deploy helper runs.
    function fund(VaultConfig memory cfg, address vault) internal {
        if (IERC20(cfg.asset).balanceOf(vault) >= cfg.seed) return;
        ISeedMint(cfg.asset).mint(vault, cfg.seed);
    }

    /// @notice `fund` at the address the caller's next create takes; call it before any expectation the deploy is armed with.
    function fundNext(VaultConfig memory cfg) internal returns (address next) {
        next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        fund(cfg, next);
    }

    /// @notice The factory path: mint the caller `cfg.seed` and approve `factory` for it, which `deploy` pulls to the vault's address.
    function approve(VaultConfig memory cfg, address factory) internal {
        ISeedMint(cfg.asset).mint(address(this), cfg.seed);
        IERC20(cfg.asset).approve(factory, cfg.seed);
    }
}
