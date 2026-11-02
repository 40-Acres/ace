// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The vault's ERC-7201 namespace keeps its string and its first words.
/// @dev Words from the root: fee high-water 0, mark 1, vest and drain 2, requested shares 3, requests 4, exemption 5.
/// @dev The promise map that sat at word 6 is deleted with the vault's roll: harmless, as a vault never upgrades.
contract AceVaultLayoutTest is AceVaultRig {
    bytes32 internal constant ROOT = 0xb7a4de03362d20465bcc8b45bb9625cb4abe76f109b674085f908e1bc61c7000;

    /// @notice The root is the ERC-7201 slot of `ace.curatorvault`.
    function test_TheRootIsTheNamespace() public pure {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("ace.curatorvault")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(slot, ROOT, "the namespace string is kept");
    }

    /// @notice The first words keep their order: the mark sits at word 1 and tracks gross after a sync.
    function test_TheMarkKeepsItsWord() public {
        vault.crank();
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(ROOT) + 1))), vault.grossNav(), "word 1 is the mark");
    }
}
