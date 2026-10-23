// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title DummyERC20
/// @notice A plain ERC-20 for the prover to link where a contract holds an asset: exact transfers, no fee, no hooks.
/// @notice That is the asset CuratorVault and the hub's markets require, so it models the token they are allowed to hold.
contract DummyERC20 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

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
