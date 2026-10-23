// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

interface ITokenReceiveHook {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @notice ERC20 with an ERC777-style recipient callback fired on ONE registered address only.
/// @dev A plain mock ERC20 has no transfer hook, so an observer of a revenue push runs only after the call returns, proving nothing about ordering.
/// @dev Registering ONE hook target lets a probe read market state MID-transfer while every other transfer in the fixture stays a plain ERC20 move.
/// @dev The callback fires AFTER balances settle (tokensReceived shape), so the probe sees exactly the state an untrusted recipient would see.
contract MockHookERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public hookTarget; // only transfers TO this address invoke the callback

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
        _fire(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _fire(from, to, amount);
        return true;
    }

    function _fire(address from, address to, uint256 amount) internal {
        if (to != address(0) && to == hookTarget) ITokenReceiveHook(to).onTokenReceived(from, amount);
    }
}
