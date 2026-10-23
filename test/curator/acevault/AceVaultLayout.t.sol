// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The vault's ERC-7201 namespace keeps its string and its first words; the roll state is appended after them.
/// @dev Words from the root: fee high-water 0, mark 1, vest and drain 2, requested shares 3, requests 4, exemption 5, roll hold 6, dust floor 7, rollOf 8.
contract AceVaultLayoutTest is AceVaultRig {
    bytes32 internal constant ROOT = 0xb7a4de03362d20465bcc8b45bb9625cb4abe76f109b674085f908e1bc61c7000;

    /// @notice The root is the ERC-7201 slot of `ace.curatorvault`.
    function test_TheRootIsTheNamespace() public pure {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("ace.curatorvault")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(slot, ROOT, "the namespace string is kept");
    }

    /// @notice The appended roll words read back through the public views.
    function test_TheRollStateReadsBack() public {
        uint256 loanId = _borrow(MAX_TENOR, true);
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(ROOT) + 6))), vault.rollHold(), "word 6 is the roll hold");
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(ROOT) + 7))), MIN_DEBT, "word 7 is the dust floor");
        uint256 word = uint256(vm.load(address(vault), keccak256(abi.encode(loanId, uint256(ROOT) + 8))));
        (uint128 need, bool funded) = vault.rollOf(loanId);
        assertEq(uint128(word), need, "rollOf packs the need low");
        assertEq(word >> 128 == 1, funded, "and the promise above it");
    }

    /// @notice The first words keep their order: the mark sits at word 1 and tracks gross after a sync.
    function test_TheMarkKeepsItsWord() public {
        vault.crank();
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(ROOT) + 1))), vault.grossNav(), "word 1 is the mark");
    }
}
