// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {DummyERC20} from "./DummyERC20.sol";

/// @title DeleverageKeeper
/// @notice Stands in for a keeper whose sale fills only partly, handing `giveBack` units back to the hub.
/// @dev Never deployed: the prover dispatches the hub's keeper callback here, with `giveBack` arbitrary.
contract DeleverageKeeper {
    DummyERC20 public token; // the collateral model, linked
    uint256 public giveBack; // units the sale did not fill, returned to the hub

    /// @notice Returns the unfilled units to the caller, the hub.
    function onAceDeleverage(uint256, uint256, bytes calldata) external {
        token.transfer(msg.sender, giveBack);
    }
}
