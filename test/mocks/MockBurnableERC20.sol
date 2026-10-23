// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice An ERC-20 whose issuer can burn any holder's balance, which the custodian's listing rails ban.
/// @dev Stands in for the whole banned class: admin burns, negative rebases, blacklists that zero a balance.
/// @dev Pooled, such a token turns a shortfall into first-come-first-served theft unless a rail catches it.
contract MockBurnableERC20 {
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

    /// @notice Destroys `amount` of `from`'s balance with no approval and no notice to the holder.
    /// @param from The holder being burned.
    /// @param amount Units destroyed.
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
