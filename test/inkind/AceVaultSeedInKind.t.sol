// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../src/vault/AceVault.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title AceVaultSeedInKind
/// @notice In kind the seed's shares sit at the vault untracked: no payout credits them, and the batch tracker counts only the holders' shares.
contract AceVaultSeedInKindTest is InKindRig {
    /// @notice A fresh in-kind vault holds the seed at par and tracks none of it; the first LP's shares are all the tracked supply.
    function test_SeedInKind_TheSeedIsUntracked() public {
        AceVault v = AceVault(address(vault));
        assertEq(v.totalSupply(), v.SEED_SHARES(), "premise: the seed is the whole supply");
        assertGt(v.SEED_SHARES(), 0, "premise: a seed was booked");
        assertEq(_trackedSupply(), 0, "the seed's shares are tracked");
        assertEq(_tracked(address(vault)), 0, "the vault itself is a tracked holder");
        uint256 shares = _lp(alice, 1_000e6);
        assertEq(_trackedSupply(), shares, "the tracked supply is not the first LP's shares alone");
        assertEq(_tracked(alice), shares, "the first LP is not tracked whole");
    }
}
