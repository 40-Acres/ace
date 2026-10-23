// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockRateERC20
/// @notice `MockERC20` plus a settable `rate()`: a growth-bearing collateral at ANY decimals.
/// @dev `MockStakeVault` is the tree's other rate-bearing collateral and its `decimals` is a constant 18.
/// @dev So no existing mock can stand as collateral in a market whose decimal pair is the subject.
contract MockRateERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    uint256 private _rate = 1e18; // growth index, 1:1 at genesis

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    /// @notice The collateral's growth index; no hub verb reads it, so it moves nothing on its own.
    function rate() external view returns (uint256) {
        return _rate;
    }

    /// @notice Reward accrual (rate up) or a validator slash (rate down).
    function setRate(uint256 v) external {
        _rate = v;
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
