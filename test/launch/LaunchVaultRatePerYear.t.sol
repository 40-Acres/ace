// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LaunchVault} from "../../src/entities/launch/LaunchVault.sol";
import {MockMonthlyHub, MockPerTermHub, RatePeriodProbe} from "../mocks/MockRatePeriodHubs.sol";
import {LaunchVaultFixture} from "./LaunchVaultFixture.sol";

/// @notice The three reads a launch vault's constructor takes off its factory, naming any hub.
contract MockLaunchFactory {
    address public immutable HUB;
    address public constant QUOTE = address(0x05DC);
    address public constant HOOK = address(0x400C);

    constructor(address hub) {
        HUB = hub;
    }
}

/// @title LaunchVaultRatePerYear
/// @notice A launch vault's rate is bps a year, railed at its fixed 30-day longest term: 27,651 makes a vault and 27,652 does not.
/// @notice The implementation refuses, at construction, a factory whose hub names no 365-day rate period.
/// @dev The refusals are named by selector, so these rows compile against a vault that does not yet probe.
contract LaunchVaultRatePerYearTest is LaunchVaultFixture {
    bytes4 internal constant BAD_TERMS = bytes4(keccak256("BadTerms()"));

    /// @notice THE CEILING IS 27,651 A YEAR at the vault's 30-day longest term, whatever its seven-day shortest.
    function test_TheRateCeilingIsWhatGenesisTakesAtThirtyDays() public {
        address at = impl.predictVault(m.token, curator, D, 27_651);
        assertEq(impl.vaultFor(m.token, curator, D, 27_651), at, "a vault at 27,651 a year is made where it was predicted");
        vm.expectRevert(BAD_TERMS);
        impl.predictVault(m.token, curator, D, 27_652);
        vm.expectRevert(BAD_TERMS);
        impl.predictVault(m.token, curator, D, 0);
    }

    /// @notice THE FLOOR IS ONE BP A YEAR: a vault at 1 is made where it was predicted, and zero, above, is refused.
    /// @dev Killed: a floor of two, which the zero row cannot see.
    function test_TheFloorRateMakesAVault() public {
        address at = impl.predictVault(m.token, curator, D, 1);
        assertEq(impl.vaultFor(m.token, curator, D, 1), at, "a vault at one bp a year is made where it was predicted");
    }

    /// @notice THE IMPLEMENTATION REFUSES A HUB THAT NAMES NO 365-DAY PERIOD: one with no `RATE_PERIOD()`, and one naming another period.
    function test_TheImplementationRefusesAHubWithoutAYearPeriod() public {
        address perTerm = address(new MockLaunchFactory(address(new MockPerTermHub())));
        vm.expectRevert(RatePeriodProbe.NOT_PER_YEAR);
        new LaunchVault(perTerm);
        address monthly = address(new MockLaunchFactory(address(new MockMonthlyHub())));
        vm.expectRevert(RatePeriodProbe.NOT_PER_YEAR);
        new LaunchVault(monthly);
        assertEq(new LaunchVault(address(factory)).HUB(), address(ace), "CONTROL: the fixture factory's hub binds");
    }
}
