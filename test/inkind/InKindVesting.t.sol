// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {InKindRig} from "./InKindRig.sol";

/// @title InKindVesting
/// @notice The tracker with no vesting age: a holder's shares and its escrow are tracked from the block they arrive, whatever their age.
/// @dev The NAV vest of a gain is the base's and is not read here.
contract InKindVestingTest is InKindRig {
    /// @notice The vault reports its tenors and cap timelock as deployed, and the terms their write-once figures.
    function test_theDeployedFiguresAreTheOnesNamed() public view {
        assertEq(vault.MIN_TENOR(), MIN_TENOR, "the minimum term as deployed");
        assertEq(vault.MAX_TENOR(), MAX_TENOR, "the maximum term as deployed");
        assertEq(vault.CAP_TIMELOCK(), TIMELOCK, "the timelock as deployed");
        assertEq(terms.MIN_PRINCIPAL(), MIN_PRINCIPAL, "the minimum principal as deployed");
        assertEq(terms.COVERAGE_WAD(), COVERAGE, "the coverage as deployed");
        assertEq(terms.APPRAISER(), appraiser, "the appraiser as deployed");
    }

    /// @notice Fee shares are tracked to the curator from their mint, like any other share.
    function test_feeSharesAreTrackedFromTheirMint() public {
        vault = _deploy(_cfg(1000), _ik(), _listings());
        _lp(alice, LP_CASH);
        usdc.mint(address(vault), 100_000e6);
        vault.crank();
        _warpBy(VEST_W + 1);
        vault.collectFee();
        uint256 fee = vault.balanceOf(curator);
        assertGt(fee, 0, "premise: the curator was paid fee shares");
        assertEq(_tracked(curator), fee, "every fee share is tracked to the curator at its mint");
        assertEq(_trackedSupply(), vault.totalSupply() - vault.SEED_SHARES(), "and counts in the tracked supply at once");
    }

    /// @notice The tracked supply is the sum of tracked balances through deposits, transfers and exits.
    function test_theTrackedSupplyIsTheSumOfTracked() public {
        _lp(alice, 1_000e6);
        _lp(bob, 2_000e6);
        _warpBy(MIN_TENOR);
        _lp(carol, 3_000e6);
        vm.prank(bob);
        vault.transfer(carol, 1e14);
        vm.prank(alice);
        vault.redeem(1e14, alice, alice);
        uint256 sum = _tracked(alice) + _tracked(bob) + _tracked(carol);
        assertEq(_trackedSupply(), sum, "the tracked supply is exactly the tracked balances");
    }

    /// @notice A raw share transfer TO the vault leaves the tracker as a burn would: the donor stops counting the shares it gave away.
    function test_aRawShareTransferToTheVaultLeavesTheTracker() public {
        uint256 sh = _lp(alice, 1_000e6);
        vm.prank(alice);
        vault.transfer(address(vault), sh / 4);
        assertEq(_tracked(alice), sh - sh / 4, "the donor's tracked shares fell by the gift");
        assertEq(_tracked(address(vault)), 0, "and nothing for the vault itself");
    }
}
