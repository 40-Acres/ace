// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockZeroRefusingERC20
/// @notice A mintable ERC20 that REVERTS on every zero-value transfer, as some live tokens do.
/// @dev Stands in for a collateral that bricks any verb which transfers nothing.
contract MockZeroRefusingERC20 {
    error ZeroValueTransfer();

    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    /// @notice Free mint for tests.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @notice Standard ERC20 approval.
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Standard ERC20 transfer, refusing a zero amount.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (amount == 0) revert ZeroValueTransfer();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @notice Standard ERC20 transferFrom, refusing a zero amount; an infinite allowance is never spent down.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (amount == 0) revert ZeroValueTransfer();
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
