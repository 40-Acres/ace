// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";

/// @title CuratorVaultMaxCheck
/// @notice The base vault's ERC-4626 entry ceilings: unbounded while entry is open, and a deposit mints exactly its preview.
/// @dev A subclass that caps entry enforces it in its own `_deposit`; the base verbs read no subclass ceiling.
contract CuratorVaultMaxCheckTest is CuratorVaultBase {
    function test_BaseVault_MaxIsUnbounded() public {
        CuratorVault v = _newVault(0);
        assertEq(v.maxDeposit(bob), type(uint256).max, "base deposit ceiling");
        assertEq(v.maxMint(bob), type(uint256).max, "base mint ceiling");
    }

    /// @dev The base vault's deposit still mints exactly its preview.
    function testFuzz_BaseVault_DepositMatchesPreview(uint96 seed, uint96 amt) public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, bound(uint256(seed), 1e6, 1e15));
        uint256 a = bound(uint256(amt), 1, 1e15);
        uint256 preview = v.previewDeposit(a);
        uint256 shares = _lpDeposit(v, bob, a);
        assertEq(shares, preview, "deposit mints its preview");
    }
}
