// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice The two reads an entry gate would take mid-transfer: the hub's unsold count and the lens's clearing quote.
interface IUnresolvedReads {
    function lenderUnresolved(address lender, address quote) external view returns (uint256);
    function clearingBudget(bytes32 id, uint256 loanId) external view returns (uint256);
}

/// @title UnresolvedProbeToken
/// @notice Collateral stand-in that asks the hub for a lender's unsold count WHILE the custodian is paying it out.
/// @notice The read-only reentrancy surface of the entry gate: a view is not stopped by a write guard, only by `nonReentrantView`.
/// @dev Each read is caught and its revert data kept, so a test asserts WHICH refusal answered rather than that one did.
contract UnresolvedProbeToken {
    string public constant name = "Unresolved Probe";
    string public constant symbol = "UPROBE";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public hub;
    address public lens;
    address public payer; // the custodian: settled inventory leaves from there
    address public lender;
    address public quote;
    bytes32 public market;
    uint256 public loanId;
    bool public armed;

    uint256 public snaps;
    bool public countAnswered; // the count read returned instead of reverting
    bytes public countRevert; // its revert data when it did not
    bool public budgetAnswered;
    bytes public budgetRevert;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Free mint, as every collateral stand-in in this suite offers.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Point the probe at one pair and one pot, and start reading on transfers out of `payer`.
    function arm(address hub_, address lens_, address payer_, address lender_, address quote_, bytes32 market_, uint256 loanId_) external {
        (hub, lens, payer, lender, quote, market, loanId) = (hub_, lens_, payer_, lender_, quote_, market_, loanId_);
        armed = true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Standard ERC20 transfer; when armed and paid out by `payer`, it reads the hub back before returning.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        if (armed && msg.sender == payer) _snap();
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

    /// @dev Taken after balances settle, which is when a real hook would run.
    function _snap() internal {
        snaps++;
        try IUnresolvedReads(hub).lenderUnresolved(lender, quote) {
            countAnswered = true;
        } catch (bytes memory r) {
            countRevert = r;
        }
        if (lens == address(0)) return;
        try IUnresolvedReads(lens).clearingBudget(market, loanId) {
            budgetAnswered = true;
        } catch (bytes memory r) {
            budgetRevert = r;
        }
    }
}
