// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockBlockableStakeVault
/// @notice MockStakeVault plus the two refusal shapes real collateral ships with: per-address, and global.
/// @dev `setBlocked` is the Circle/USDC blacklist shape, the one a third party can arm after a loan opens.
/// @dev `setPaused` is the LST and yield-bearing-vault shape, which a large fraction of that class carries.
/// @dev Both refuse on the RECIPIENT, which is where a fixed-destination payout has no alternative.
contract MockBlockableStakeVault {
    string public constant name = "Blockable Staked MON";
    string public constant symbol = "bvMON";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked; // per-address refusal on the recipient, the blacklist shape
    uint256 public totalSupply;
    bool public paused; // global refusal, the pausable-token shape

    uint256 private _rate = 1e18; // quote per share, starts 1:1

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice The mock's exchange rate, quote per share at 1e18.
    function rate() external view returns (uint256) {
        return _rate;
    }

    /// @notice Sets the exchange rate; reward accrual up, a slash down.
    function setRate(uint256 newRate) external {
        _rate = newRate;
    }

    /// @notice Blocks or unblocks every transfer whose recipient is `who`.
    function setBlocked(address who, bool on) external {
        blocked[who] = on;
    }

    /// @notice Halts or resumes every transfer, whoever the recipient is.
    function setPaused(bool on) external {
        paused = on;
    }

    /// @notice Free mint for test wiring.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Standard ERC20 approval.
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice ERC20 transfer, refused when paused or when `to` is blocked.
    function transfer(address to, uint256 amount) external returns (bool) {
        _guard(to);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice ERC20 transferFrom, refused when paused or when `to` is blocked.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _guard(to);
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function _guard(address to) private view {
        require(!paused, "paused");
        require(!blocked[to], "blocked");
    }
}
