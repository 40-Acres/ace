// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {DummyERC20} from "./DummyERC20.sol";

/// @title MockSaleBuyer
/// @notice A door sale's buyer: told the least the door takes, it approves the door a stored amount and states a stored figure.
/// @notice So it meets a buyer that states enough, too little, or more than it approved, and a pull past the approval reverts in the token.
/// @dev LINKED `cash` to the terms' asset; it records what the door told it, and never re-enters.
contract MockSaleBuyer {
    DummyERC20 public cash; // the asset the door pulls
    uint256 internal stated; // what onDoorSale answers
    uint256 internal approved; // what onDoorSale approves the door to pull
    uint256 public calls; // how many times the door called back
    uint256 public lastOwed; // the owed figure of the latest call

    /// @notice Record the owed figure, approve the caller the stored amount, and state the stored figure.
    function onDoorSale(address, uint256, uint256 owed, bytes calldata) external returns (uint256) {
        calls += 1;
        lastOwed = owed;
        cash.approve(msg.sender, approved);
        return stated;
    }

    /// @notice The figure this buyer states, for a spec.
    function statedView() external view returns (uint256) {
        return stated;
    }

    /// @notice The amount this buyer approves, for a spec.
    function approvedView() external view returns (uint256) {
        return approved;
    }
}
