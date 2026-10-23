// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockUsdcImpl
/// @notice The logic half of a USDC-SHAPED quote: a pause flag and a blacklist read on both parties of every move.
/// @dev Behind `MockProxyERC20` it costs what the shape costs -- two cold accounts, an implementation-slot read, the flag,
/// @dev two blacklist words and two balances -- so a push through it prices near the measured Ethereum USDC need.
contract MockUsdcImpl {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;
    uint256 public totalSupply;
    bool public paused;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function decimals() external pure returns (uint8) {
        return 6;
    }

    /// @notice Free mint for test wiring.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
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

    function _move(address from, address to, uint256 amount) private {
        require(!paused, "paused");
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @title MockProxyERC20
/// @notice A delegating proxy in front of `MockUsdcImpl`: the account shape a real USDC push walks through.
/// @dev The implementation address sits at the EIP-1967 slot, so it cannot collide with the logic's own storage.
contract MockProxyERC20 {
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address impl) {
        assembly {
            sstore(IMPL_SLOT, impl)
        }
    }

    fallback() external {
        assembly {
            let impl := sload(IMPL_SLOT)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
