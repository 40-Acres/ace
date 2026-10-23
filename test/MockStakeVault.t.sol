// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {MockStakeVault} from "./mocks/MockStakeVault.sol";

// The PoC stand-in for the StakeVault: mints vMON and exposes a movable exchange rate.
contract MockStakeVaultTest is Test {
    MockStakeVault internal vault;
    address internal user = address(0xA11CE);

    function setUp() public {
        vault = new MockStakeVault(42); // validatorId 42
    }

    function test_Rate_StartsAtOne() public view {
        assertEq(vault.rate(), 1e18, "1 vMON == 1 MON at genesis");
        assertEq(vault.decimals(), 18);
    }

    function test_Mint_IncreasesBalanceAndSupply() public {
        vault.mint(user, 1000e18);
        assertEq(vault.balanceOf(user), 1000e18);
        assertEq(vault.totalSupply(), 1000e18);
    }

    function test_SetRate_Up_SimulatesRewards() public {
        vault.setRate(1.05e18);
        assertEq(vault.rate(), 1.05e18, "rate rises as staking rewards accrue");
    }

    function test_SetRate_Down_SimulatesSlash() public {
        vault.setRate(0.9e18);
        assertEq(vault.rate(), 0.9e18, "rate can fall on a slash");
    }

    function test_Deposit_MintsAtRate() public {
        vault.setRate(1.25e18);
        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 shares = vault.deposit{value: 1 ether}();
        // 1 MON / 1.25 = 0.8 vMON
        assertEq(shares, 0.8e18);
        assertEq(vault.balanceOf(user), 0.8e18);
    }

    function test_UsableAsExchangeRateSource() public view {
        assertEq(vault.rate(), 1e18);
    }
}
