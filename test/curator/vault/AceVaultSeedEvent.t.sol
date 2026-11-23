// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/vault/AceVault.sol";
import {CapListing, ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {VaultConfig} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultSeedEvent
/// @notice The constructor reports the genesis seed as an ERC-4626 deposit to the vault itself: every unit found at the address, at par.
contract AceVaultSeedEventTest is AceVaultBaseRig {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice A vault built by plain `new` onto more than its config's seed emits one deposit of the whole balance, its deployer the sender.
    function test_Seed_TheConstructorEmitsTheWholeSeedAsADepositToTheVault() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockTerms t = new MockTerms(predicted, address(ace));
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        uint256 held = 3 * VaultSeed.SEED + 7;
        usdc.mint(predicted, held);
        CapListing[] memory c = _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED));
        VaultConfig memory cfg = _cfg();
        vm.expectEmit(true, true, false, true, predicted);
        emit Deposit(address(this), predicted, held, held * 1e6);
        AceVault v = new AceVault(cfg, pc, c, "Seed", "sVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
        assertEq(v.SEED_SHARES(), held * 1e6, "the event's shares are not the seed's");
    }
}
