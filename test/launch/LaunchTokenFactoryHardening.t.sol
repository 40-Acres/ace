// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Leg} from "../../src/entities/launch/LaunchLock.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {RunwayFixture} from "./RunwayFixture.sol";

/// @title LaunchTokenFactoryHardening
/// @notice The full-supply accounting as a property: any number of legs, any split, beneficiaries repeating, every unit found again.
/// @notice Plus the edges no row reached: no allocation at all, and legs whose sum overflows before a token exists.
contract LaunchTokenFactoryHardeningTest is RunwayFixture {
    address internal carol = address(0xCA401);

    /// @dev The default launch with no ops amount, so any split of team legs stays under the ops cap.
    function _bare() internal view returns (LaunchTokenFactory.LaunchInput memory p) {
        p = _input();
        p.opsAmount = 0;
    }

    /// @dev A leg to `who` of `amount` on the minimum curve.
    function _leg(address who, uint256 amount) internal pure returns (Leg memory) {
        return Leg({beneficiary: who, amount: amount, cliff: 30 days, duration: 90 days});
    }

    /// @notice Up to eight legs over three beneficiaries, so a beneficiary often has several: leg i's account, on schedule i + 1,
    /// @notice holds exactly its amount, deployed, and the strategy plus the accounts hold the whole supply.
    function testFuzz_AnySplitIsFoundAgainAccountByAccount(uint256 seed, uint8 count) public {
        uint256 n = bound(count, 1, 8);
        address[3] memory who = [team, alice, carol];
        LaunchTokenFactory.LaunchInput memory p = _bare();
        p.legs = new Leg[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            p.legs[i] = _leg(who[r % 3], 1 + (r >> 16) % 1e30);
        }
        uint256 supply = _supplyOf(p);
        Made memory m = _launch(p);
        IERC20 t = IERC20(m.token);

        uint256 found = t.balanceOf(address(strat));
        assertEq(found, 2 * uint256(SUPPLY), "the strategy holds other than its amount");
        for (uint256 i; i < n; ++i) {
            address a = m.lock.predict(p.legs[i].beneficiary, i + 1);
            assertEq(t.balanceOf(a), p.legs[i].amount, "a leg's account holds other than its amount");
            assertTrue(m.lock.isAccount(a) && a.code.length != 0, "a paid account is not deployed");
            found += t.balanceOf(a);
        }
        assertEq(t.totalSupply(), supply, "supply is not the strategy amount plus the legs");
        assertEq(found, supply, "a unit of the supply is somewhere else");
        assertEq(t.balanceOf(address(factory)) + t.balanceOf(team) + t.balanceOf(address(m.budget)), 0, "the factory, the caller or the budget kept some");
    }

    /// @notice Two legs to one beneficiary never share an account: each lands in its own, on its own schedule, and holds its own amount.
    function test_LegsForOneBeneficiaryNeverShareAnAccount() public {
        LaunchTokenFactory.LaunchInput memory p = _bare();
        p.legs = new Leg[](3);
        (p.legs[0], p.legs[1], p.legs[2]) = (_leg(team, 10e18), _leg(carol, 5e18), _leg(team, 20e18));
        Made memory m = _launch(p);
        assertEq(IERC20(m.token).balanceOf(m.lock.predict(team, 1)), 10e18, "the first leg's account");
        assertEq(IERC20(m.token).balanceOf(m.lock.predict(carol, 2)), 5e18, "the other beneficiary's account");
        assertEq(IERC20(m.token).balanceOf(m.lock.predict(team, 3)), 20e18, "the third leg's own account");
    }

    /// @notice A launch with no team leg and no ops amount is the strategy's amount alone, every unit at the strategy, recorded.
    function test_NoAllocationSendsTheWholeSupplyToTheStrategy() public {
        LaunchTokenFactory.LaunchInput memory p = _bare();
        p.legs = new Leg[](0);
        Made memory m = _launch(p);
        assertEq(IERC20(m.token).totalSupply(), 2 * uint256(SUPPLY), "supply");
        assertEq(IERC20(m.token).balanceOf(address(strat)), 2 * uint256(SUPPLY), "the strategy does not hold the whole supply");
        assertTrue(address(m.lock) != address(0) && address(m.budget) != address(0), "an allocation-free launch went unrecorded");
    }

    /// @notice Legs whose sum overflows revert before any token is born: the supply is checked arithmetic, never a wrapped small number.
    function test_LegsThatOverflowTheSupplyRevert() public {
        LaunchTokenFactory.LaunchInput memory p = _bare();
        p.legs = new Leg[](2);
        p.legs[0] = _leg(team, type(uint256).max - 2 * uint256(SUPPLY));
        p.legs[1] = _leg(team, 1);
        vm.prank(team);
        vm.expectRevert(stdError.arithmeticError);
        factory.launch(p);
    }

    /// @notice A bad leg anywhere in the list sinks the launch: the third of three, after two good ones, unlocks inside the minimum cliff.
    function test_ABadLastLegSinksTheLaunch() public {
        LaunchTokenFactory.LaunchInput memory p = _bare();
        p.legs = new Leg[](3);
        (p.legs[0], p.legs[1], p.legs[2]) = (_leg(team, 1e18), _leg(carol, 1e18), _leg(carol, 1e18));
        p.legs[2].cliff = 30 days - 1;
        vm.prank(team);
        vm.expectRevert(LaunchTokenFactory.BadLeg.selector);
        factory.launch(p);
    }
}
