// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockGoods
/// @notice A plain ERC-20 standing for a seized good at the door: exact transfers, no fee, no hooks.
/// @notice A copy of `DummyERC20` under its own name, so a dispatched call reaches the goods or the cash by address, never both.
contract MockGoods {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
