// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice Fee-on-transfer ERC20: a transfer debits the sender `amount` but credits the recipient `amount - fee`, the fee going to a sink.
/// @notice The call SUCCEEDS and returns true, satisfying SafeERC20, so the only tell is the recipient's balance rising by less than requested.
/// @dev That is exactly the case a balance-delta guard catches, and the reason this mock is hostile.
contract MockFeeOnTransferERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public immutable feeBps; // fee skimmed on every transfer, in basis points
    address public constant SINK = address(0xFEE);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s, uint8 d, uint256 _feeBps) {
        name = n;
        symbol = s;
        decimals = d;
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        balanceOf[SINK] += fee;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }
}
