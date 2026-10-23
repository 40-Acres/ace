// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";

/// @title AceWindowHelperLiterals
/// @notice The two tenor-derived windows, pinned to written-out numbers on BOTH legs of their clamp and at the seam where the legs cross.
/// @dev Most suites warp to an instant they derive by CALLING these helpers, so a changed helper moves the expectation with it.
/// @dev Every expectation here is a literal, so each leg of `min(minTenor / divisor, cap)` can fail on its own.
/// @dev Each helper also gets a truncation control: a floor that the divisor does not divide exactly.
contract AceWindowHelperLiteralsTest is Test {
    /// @notice The roll window is a fifth of the market floor, capped at two hours.
    function test_AutoRefinanceWindow_IsAFifthOfTheFloorCappedAtTwoHours() public pure {
        assertEq(MarketInit.autoRefinanceWindow(10), 2, "at the genesis floor the fifth binds");
        assertEq(MarketInit.autoRefinanceWindow(14), 2, "the fifth truncates: fourteen seconds still opens two out");
        assertEq(MarketInit.autoRefinanceWindow(10 minutes), 2 minutes, "a ten-minute floor opens its window two minutes out");
        assertEq(MarketInit.autoRefinanceWindow(7 days), 2 hours, "a week-long floor is capped at two hours");
        assertEq(MarketInit.autoRefinanceWindow(10 hours - 5), 2 hours - 1, "just under the seam the fifth still binds");
        assertEq(MarketInit.autoRefinanceWindow(10 hours), 2 hours, "at the seam the two legs agree");
        assertEq(MarketInit.autoRefinanceWindow(10 hours + 5), 2 hours, "just past it the cap binds");
        assertEq(MarketInit.autoRefinanceWindow(type(uint64).max), 2 hours, "and holds at the widest floor a uint64 names");
    }

    /// @notice Settled inventory rests half the market floor, capped at one hour.
    function test_InventoryHold_IsHalfTheFloorCappedAtOneHour() public pure {
        assertEq(MarketInit.inventoryHold(10), 5, "at the genesis floor the half binds");
        assertEq(MarketInit.inventoryHold(11), 5, "the half truncates: eleven seconds still rests five");
        assertEq(MarketInit.inventoryHold(10 minutes), 5 minutes, "a ten-minute floor rests five minutes");
        assertEq(MarketInit.inventoryHold(7 days), 1 hours, "a week-long floor is capped at one hour");
        assertEq(MarketInit.inventoryHold(2 hours - 2), 1 hours - 1, "just under the seam the half still binds");
        assertEq(MarketInit.inventoryHold(2 hours), 1 hours, "at the seam the two legs agree");
        assertEq(MarketInit.inventoryHold(2 hours + 2), 1 hours, "just past it the cap binds");
        assertEq(MarketInit.inventoryHold(type(uint64).max), 1 hours, "and holds at the widest floor a uint64 names");
    }
}
