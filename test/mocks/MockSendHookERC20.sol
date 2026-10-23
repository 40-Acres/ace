// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ITokenReceiveHook} from "./MockHookERC20.sol";

/// @notice ERC20 with an ERC777-style SENDER callback: it fires when the registered address PAYS.
/// @dev `MockHookERC20` fires on `to == hookTarget`.
/// @dev Inside `Borrower.open` that can only be the principal payout, the LAST external call there.
/// @dev Every earlier call moves tokens AWAY from the borrower, invisible to a receive-side hook.
/// @dev That leaves the mint-ordering ruling half-pinned.
/// @dev A mint relocated between `_record` and the payout is invisible to a receive-side probe.
/// @dev Firing on `from == hookTarget` opens the earliest window there is: `IPositionManager.pull`.
/// @dev The callback runs AFTER balances settle, so the positionManager's fee-on-transfer check sees a clean delta.
contract MockSendHookERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public hookTarget; // only transfers FROM this address invoke the callback

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function setHookTarget(address who) external {
        hookTarget = who;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        _fire(msg.sender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _fire(from, amount);
        return true;
    }

    function _fire(address from, uint256 amount) internal {
        if (from != address(0) && from == hookTarget) ITokenReceiveHook(from).onTokenReceived(from, amount);
    }
}
