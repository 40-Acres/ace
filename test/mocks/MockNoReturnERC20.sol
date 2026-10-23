// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice USDT-style ERC20: transfer/transferFrom/approve return NOTHING (no bool). Faithful to legacy
/// @notice tokens (USDT, old BNB) whose ABI omits the bool return; used to prove the hook's raw
/// @notice bool-decoding transfer bricks on such tokens (N18). decimals=6 stands in for USDT.
contract MockNoReturnERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    // no return value on purpose (USDT-style): a caller ABI-decoding a bool reverts
    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
