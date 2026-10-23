// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LAUNCH_DEAD} from "../../interfaces/ILaunchAuction.sol";

/// @title LaunchToken
/// @notice A fixed-supply ERC-20: the whole supply is minted once, to its deployer, in the constructor.
/// @notice No owner, no mint, no burn function, no fee, no blocklist, no rebase; 18 decimals.
/// @notice A transfer to 0x...dEaD burns: it lowers totalSupply, so the supply a tracker reads is the true one.
/// @dev Its deployer is the launch token factory, which hands the whole supply out in the same call.
contract LaunchToken is ERC20 {
    /// @param name_ The token's name.
    /// @param symbol_ The token's symbol.
    /// @param supply The whole supply, minted to the deployer.
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    /// @dev A transfer to LAUNCH_DEAD is a burn, so a burn path that can only transfer, such as a pool's fee take, still destroys supply.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to == LAUNCH_DEAD ? address(0) : to, value);
    }
}
