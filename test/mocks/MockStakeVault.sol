// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockStakeVault
/// @notice PoC stand-in for the real StakeVault: mints vMON and reports a test-settable exchange rate.
/// @dev No real delegation; mint and setRate are open and unsafe.
/// @dev Replace with the real vault before anything holds real funds.
contract MockStakeVault {
    string public constant name = "Staked MON";
    string public constant symbol = "vMON";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    uint64 public immutable VALIDATOR_ID; // cosmetic: which validator this stands in for
    uint256 private _rate = 1e18; // MON per vMON share, starts 1:1

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event RateSet(uint256 rate);
    event Deposited(address indexed to, uint256 monIn, uint256 shares);

    constructor(uint64 _validatorId) {
        VALIDATOR_ID = _validatorId;
    }

    /// @notice The mock's exchange rate, MON per vMON share at 1e18.
    function rate() external view returns (uint256) {
        return _rate;
    }

    // --- mock controls (stand-in only) ---

    /// @notice Free mint of vMON for tests and demo wiring.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Simulates reward accrual (rate up) or a validator slash (rate down).
    function setRate(uint256 newRate) external {
        _rate = newRate;
        emit RateSet(newRate);
    }

    /// @notice Send MON, receive vMON minted at the current rate; the real deposit UX.
    function deposit() external payable returns (uint256 shares) {
        shares = (msg.value * 1e18) / _rate;
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
        emit Transfer(address(0), msg.sender, shares);
        emit Deposited(msg.sender, msg.value, shares);
    }

    // --- two-step exit stand-in (receiver-directed, mirrors the real vault's seam) ---

    struct Request {
        address owner;
        uint256 shares;
    }

    Request[] public requests;

    event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 shares);

    /// @notice Burns the caller's shares and books the queued exit under `receiver`; zero receiver reverts.
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 requestId) {
        require(receiver != address(0), "zero receiver");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        requests.push(Request(receiver, shares));
        requestId = requests.length - 1;
        emit Transfer(msg.sender, address(0), shares);
        emit RedeemRequested(requestId, receiver, shares);
    }

    // --- minimal ERC20 ---

    /// @notice Standard ERC20 approval.
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Standard ERC20 transfer.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Standard ERC20 transferFrom; an infinite allowance is never spent down.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
