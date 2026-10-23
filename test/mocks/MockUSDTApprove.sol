// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice USDT-style ERC20 that ALSO enforces the "reset allowance to 0 before a new non-zero approve"
/// @notice rule (real USDT reverts on a non-zero -> non-zero approve), on top of the no-bool return.
/// @notice MockNoReturnERC20 only exercises the no-bool half of forceApprove; this mock exercises the
/// @notice reset-to-0 half, so recurring-approve sites (Loans/Portfolio/DistributedFloor) are
/// @notice covered end-to-end. decimals=6 stands in for USDT.
contract MockUSDTApprove {
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

    // USDT-style: no bool return AND the non-zero->non-zero approve-race guard; only forceApprove satisfies both
    function approve(address spender, uint256 amount) external {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "USDT: approve from non-zero");
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
