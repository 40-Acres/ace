// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice An ERC20 quote that, on a transfer INTO one armed address, calls that address back with armed calldata.
/// @dev The callback's revert is bubbled, so a guard that trips inside it reverts the transfer and everything above it.
contract ReenteringQuote {
    string public name = "Reentering";
    string public symbol = "RQ";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public target; // the only recipient whose incoming transfer fires the callback
    bytes public data; // what the callback sends it

    function arm(address who, bytes calldata payload) external {
        (target, data) = (who, payload);
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
        _fire(to);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _fire(to);
        return true;
    }

    function _fire(address to) internal {
        if (to == address(0) || to != target) return;
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
