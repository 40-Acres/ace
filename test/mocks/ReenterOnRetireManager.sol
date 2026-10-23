// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";

/// @notice The per-loan config read the real custodian makes; this stand-in resolves collateral the same way.
interface IReenterLoanManager {
    function escrowConfigOf(uint256 loanId) external view returns (address collateral, address quote);
}

/// @title ReenterOnRetireManager
/// @notice A position manager stand-in that calls the hub BACK from inside `retireCustody`.
/// @notice That hop is settlement's one external call, and it is where a hostile custodian would sit.
/// @dev It swallows the re-entrant call's outcome rather than bubbling it, so the outer verb still finishes.
/// @dev A guard that only ever rode on a token movement would be silently absent here: this moves no token.
contract ReenterOnRetireManager is IPositionManager {
    error NotLoanManager();

    address public immutable LOAN_MANAGER; // the hub, verified by `Ace`'s constructor against this getter

    mapping(uint256 => uint256) public collateralOf; // units under LIVE custody for a loan
    mapping(uint256 => uint256) public retiredOf; // units a close took off the live ledger
    mapping(address => uint256) public custodiedOf; // collateral -> units owed across every loan here

    uint256 public watch; // the loan whose hop re-enters; zero leaves the probe disarmed
    bytes public reentry; // the hub call attempted from inside that hop
    uint256 public attempts; // times the re-entrant call actually fired, so a silent no-op cannot pass
    bool public lastOk; // whether the hub let it through
    bytes4 public lastSelector; // and how it refused, when it did

    modifier onlyLoanManager() {
        if (msg.sender != LOAN_MANAGER) revert NotLoanManager();
        _;
    }

    constructor(address loanManager) {
        LOAN_MANAGER = loanManager;
    }

    /// @notice Point the probe at one loan and name the hub call its custody hop should attempt.
    /// @param loanId The loan to watch.
    /// @param call The ABI-encoded hub call to make from inside the hop.
    function arm(uint256 loanId, bytes calldata call) external {
        watch = loanId;
        reentry = call;
    }

    /// @notice The loan's collateral, resolved through the hub exactly as the real custodian resolves it.
    /// @param id The loan to resolve.
    /// @return The market's collateral token.
    function collateralFor(uint256 id) public view returns (address) {
        (address c,) = IReenterLoanManager(LOAN_MANAGER).escrowConfigOf(id);
        return c;
    }

    /// @notice Takes collateral into custody at open.
    /// @param id The loan.
    /// @param from The payer.
    /// @param units Units taken.
    function pull(uint256 id, address from, uint256 units) external onlyLoanManager {
        address collateral = collateralFor(id);
        collateralOf[id] += units;
        custodiedOf[collateral] += units;
        IERC20(collateral).transferFrom(from, address(this), units);
    }

    /// @notice Releases collateral out of a live loan.
    /// @param id The loan.
    /// @param to Recipient.
    /// @param units Units released.
    function release(uint256 id, address to, uint256 units) external onlyLoanManager {
        address collateral = collateralFor(id);
        collateralOf[id] -= units;
        custodiedOf[collateral] -= units;
        IERC20(collateral).transfer(to, units);
    }

    /// @notice Retires units from the live ledger, then re-enters the hub before returning.
    /// @param id The loan being closed.
    /// @param units Units leaving the live ledger.
    function retireCustody(uint256 id, uint256 units) external onlyLoanManager {
        collateralOf[id] -= units;
        retiredOf[id] += units;
        if (watch != 0 && id == watch) _reenter();
    }

    /// @notice Delivers retired units to a destination the claimant named.
    /// @param id The retired loan.
    /// @param to Recipient.
    /// @param units Units delivered.
    function releaseRetired(uint256 id, address to, uint256 units) external onlyLoanManager {
        address collateral = collateralFor(id);
        retiredOf[id] -= units;
        custodiedOf[collateral] -= units;
        IERC20(collateral).transfer(to, units);
    }

    /// @notice Debits the retiring loan at a refinance close; the units never leave the pot.
    /// @param id The retiring loan.
    /// @param units Units leaving its ledger.
    function carryOut(uint256 id, uint256 units) external onlyLoanManager {
        collateralOf[id] -= units;
    }

    /// @notice Credits the successor with units the retiring loan has already given up.
    /// @param toId The successor loan.
    /// @param units Units joining its ledger.
    function carryIn(uint256, uint256 toId, uint256 units) external onlyLoanManager {
        collateralOf[toId] += units;
    }

    /// @dev One re-entrant attempt, recorded and swallowed: the outer settlement must survive a hostile hop.
    function _reenter() private {
        attempts++;
        (bool ok, bytes memory ret) = LOAN_MANAGER.call(reentry);
        lastOk = ok;
        bytes4 sel;
        if (ret.length >= 4) {
            assembly ("memory-safe") {
                sel := mload(add(ret, 32))
            }
        }
        lastSelector = sel;
    }
}
