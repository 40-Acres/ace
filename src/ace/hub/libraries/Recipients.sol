// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

error ZeroWithdrawTo(); // an exit named no recipient, for units or quote alike; burning them is never the intent
error ExitToHub(); // an exit named the hub, which would retain tokens after their claim was cleared
error ExitToCustodian(); // an exit named the positionManager, which sweeps nothing: what lands there beyond its ledgers is lost

/// @title Recipients
/// @notice The one recipient rule, for every hub exit that pays quote or collateral to an address its caller names.
/// @notice Refused alike on either asset: zero, the hub itself, and the positionManager.
/// @dev A destination rule only: SafeERC20 asks whether a transfer succeeded, never where it went, and no library knows this hub's addresses.
/// @dev Every caller runs it before its first state write and first external call; its place among a verb's other refusals is the verb's own.
library Recipients {
    /// @dev Each refusal names itself; a caller that reads zero as "skip this leg" decides that before calling.
    function check(address to, address custodian) internal view {
        if (to == address(0)) revert ZeroWithdrawTo();
        if (to == address(this)) revert ExitToHub();
        if (to == custodian) revert ExitToCustodian();
    }
}
