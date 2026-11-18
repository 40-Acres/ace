// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice The buyer's routing callback: a vault's door hands over seized goods, and the buyer states what it will pay.
/// @dev The callee is named by whoever sells at the door, so a buyer authenticates nothing: it is chosen, not admitted.
/// @dev APPROVE THE DOOR FOR WHAT YOU RETURN AND RETURN IT: the door PULLS that figure, it does not watch its balance.
/// @dev DO NOT ALSO TRANSFER: approving AND pushing pays TWICE, silently, because the push lands before the pull is sized.
/// @dev A STATED FIGURE IS THE PAYMENT OF RECORD, so a buyer that leaves more behind has donated the difference.
/// @dev Returning more than the approval covers reverts the sale, and the goods go back with it.
/// @dev Any unsold units of `asset` belong to the door, so a buyer that routes a partial fill must send them back.
/// @dev The goods leave BEFORE this call and the pull runs AFTER it returns, so the SALE'S OWN legs move NAV by nothing.
/// @dev That is the sale's legs alone: what a callback cranks at the hub is separate, and a close there does move NAV.
interface IDoorSaleCallback {
    /// @param asset The item transferred to the buyer.
    /// @param units How much of it arrived.
    /// @param owed The minimum quote the door will accept back.
    /// @param data Opaque routing payload the seller passed to `sell`.
    /// @return paid The quote this buyer has approved the door to take.
    function onDoorSale(address asset, uint256 units, uint256 owed, bytes calldata data) external returns (uint256 paid);
}
