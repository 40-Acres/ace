// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice What the probe asks the hub, mid-transfer, on behalf of a read-only reentrant observer.
/// @dev `balanceOf`/`unitIdOf` went with the receipt ledger, and a lender's resting cash is the market's.
interface IProbeViews {
    function restingOf(bytes32 id) external view returns (uint256);
}

/// @notice What the probe asks the storage reader, mid-transfer, for the pots a view cannot reach.
interface IProbeReader {
    function invPotOf(bytes32 id, uint256 loanId) external view returns (uint256);
    function claimOf(bytes32 id, uint256 loanId) external view returns (uint256);
    function poolOwed(bytes32 id) external view returns (uint256);
}

/// @title ReadProbeVault
/// @notice Collateral stand-in that READS the hub back while the hub is paying it out.
/// @notice The read-only reentrancy surface: a view call is not stopped by the reentrancy guard.
/// @dev Serves lending-review mitigation 4: the pot must be debited BEFORE any token moves, so an
/// @dev observer inside the transfer can never see a stale pot, a live balance, or an unpaid owed.
contract ReadProbeVault {
    string public constant name = "Read Probe Vault";
    string public constant symbol = "PROBE";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public hub;
    address public payer; // a second trigger address: settled inventory is delivered by the custodian
    address public reader;
    bytes32 public market;
    uint256 public loanId;
    address public holder;
    bool public armed;

    uint256 public potSeen;
    uint256 public owedSeen;
    uint256 public unitsSeen;
    uint256 public restingSeen;
    uint256 public snaps;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice A flat growth index; this probe exists to watch writes, never to move a price.
    function rate() external pure returns (uint256) {
        return 1e18;
    }

    /// @notice Free mint, as every collateral stand-in in this suite offers.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Point the probe at one LOAN and start snapshotting on outbound transfers.
    /// @dev It took a TICK: a loan's position was a class per funded tick, and there is one position now.
    function arm(address _hub, address _reader, bytes32 _market, uint256 _loanId, address _holder) external {
        (hub, reader, market, loanId, holder) = (_hub, _reader, _market, _loanId, _holder);
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    /// @notice Also snapshot on outbound transfers from `_payer`, for a delivery the hub does not make itself.
    function armPayer(address _payer) external {
        payer = _payer;
    }

    /// @dev The snapshot: taken after balances settle, which is when a real hook would run.
    /// @dev `unitsSeen` WAS the observer's receipt balance in the loan's class; the ledger is gone, so what
    /// @dev stands in is the loan's live CLAIM -- the word a payout retires, and the one a stale read shows.
    function _snap() internal {
        potSeen = IProbeReader(reader).invPotOf(market, loanId);
        owedSeen = IProbeReader(reader).poolOwed(market);
        unitsSeen = IProbeReader(reader).claimOf(market, loanId);
        restingSeen = IProbeViews(hub).restingOf(market);
        snaps++;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Standard ERC20 transfer; when armed, it reads the hub back before returning.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        if (armed && (msg.sender == hub || (payer != address(0) && msg.sender == payer))) _snap();
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
