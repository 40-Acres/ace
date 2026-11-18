// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {DummyERC20} from "./DummyERC20.sol";

/// @title MockReceiptDoor
/// @notice The vault's door as `SAeroStakeReceipt` calls it: its operator, its seizure map, and `returnClaimed`.
/// @notice `returnClaimed` refuses on a stored switch, else pulls a stored amount from the caller, whatever it was offered.
/// @notice So it meets a door that takes the whole offer, takes short, takes nothing, or refuses; a pull over the approval reverts in the token.
/// @dev LINKED to the receipt's `DOOR` immutable; `cash` is LINKED to the receipt's asset, so the pull moves real balances.
contract MockReceiptDoor {
    DummyERC20 public cash; // the asset returnClaimed pulls
    address internal op; // what operator answers
    mapping(uint256 => address) internal seized; // what seizedReceiptOf answers
    bool internal refuse; // whether returnClaimed reverts
    uint256 internal take; // what returnClaimed pulls

    /// @notice The terms' operator.
    /// @return The stored operator.
    function operator() external view returns (address) {
        return op;
    }

    /// @notice The receipt the latest seizure of `stakeId` took.
    /// @param stakeId The stake.
    /// @return The stored receipt.
    function seizedReceiptOf(uint256 stakeId) external view returns (address) {
        return seized[stakeId];
    }

    /// @notice Take the stored amount of the caller's cash, or refuse.
    function returnClaimed(uint256) external {
        require(!refuse, "refused");
        cash.transferFrom(msg.sender, address(this), take);
    }

    /// @notice The operator, for a spec.
    /// @return The stored operator.
    function operatorView() external view returns (address) {
        return op;
    }
}
