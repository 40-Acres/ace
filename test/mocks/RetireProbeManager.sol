// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {Loan} from "../../src/ace/hub/Types.sol";

/// @notice What the probe asks the lens from inside the hub's own settlement call.
interface IProbeLens {
    function loan(uint256 loanId) external view returns (Loan memory);
    function shortfallOf(uint256 loanId) external view returns (uint256 units, uint256 quoteAtBook);
    function claimOf(bytes32 id, uint256 loanId) external view returns (uint256);
}

/// @notice The per-loan config read the real custodian makes; the probe resolves collateral the same way.
interface IProbeLoanManager {
    function escrowConfigOf(uint256 loanId) external view returns (address collateral, address quote);
}

/// @title RetireProbeManager
/// @notice A position manager stand-in that READS the hub back from inside `retireCustody`.
/// @notice That hop is the ONE external call a settlement makes before it records its shortfall.
/// @dev Re-entrant WRITES are already blocked by the hub's guard; a view is not, which is the surface here.
/// @dev Custody is flat here as it is in the real custodian: units rest on this contract, one pot per token.
/// @dev It is a probe, not a fidelity model of `PositionManager` -- the real custody rails are pinned elsewhere.
contract RetireProbeManager is IPositionManager {
    error NotLoanManager();

    address public immutable LOAN_MANAGER; // the hub, verified by `Ace`'s constructor against this getter

    mapping(uint256 => uint256) public collateralOf; // units under LIVE custody for a loan
    mapping(uint256 => uint256) public retiredOf; // units a close took off the live ledger
    mapping(address => uint256) public custodiedOf; // collateral -> units owed across every loan here

    address public lens; // the view surface the probe re-enters; zero leaves the probe disarmed
    bytes32 public market;
    uint256 public loanId;

    bool public closedSeen; // the loan's own `closed` flag, mid-settlement
    uint256 public unitsSeen; // its `collateralUnits`, mid-settlement
    uint256 public claimSeen; // the loan's live claim, mid-settlement
    uint256 public shortUnitsSeen; // `shortfallOf().units`, mid-settlement
    uint256 public shortQuoteSeen; // `shortfallOf().quoteAtBook`, mid-settlement
    uint256 public snaps; // times the hop actually fired, so a silent no-op cannot pass

    modifier onlyLoanManager() {
        if (msg.sender != LOAN_MANAGER) revert NotLoanManager();
        _;
    }

    constructor(address loanManager) {
        LOAN_MANAGER = loanManager;
    }

    /// @notice Point the probe at one settling loan and start snapshotting inside `retireCustody`.
    /// @param _lens The lens to re-enter.
    /// @param _market The loan's market.
    /// @param _loanId The loan to watch.
    function arm(address _lens, bytes32 _market, uint256 _loanId) external {
        (lens, market, loanId) = (_lens, _market, _loanId);
    }

    /// @notice The loan's collateral, resolved through the hub exactly as the real custodian resolves it.
    /// @param id The loan to resolve.
    /// @return The market's collateral token.
    function collateralFor(uint256 id) public view returns (address) {
        (address c,) = IProbeLoanManager(LOAN_MANAGER).escrowConfigOf(id);
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

    /// @notice Retires units from the live ledger, then reads the hub back before returning.
    /// @dev The snapshot is the point: it is taken exactly where a hostile custodian would get control.
    /// @param id The loan being closed.
    /// @param units Units leaving the live ledger.
    function retireCustody(uint256 id, uint256 units) external onlyLoanManager {
        collateralOf[id] -= units;
        retiredOf[id] += units;
        if (lens != address(0) && id == loanId) _snap();
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

    /// @dev One read of every observable the settlement's ordering is supposed to guarantee.
    function _snap() private {
        Loan memory l = IProbeLens(lens).loan(loanId);
        closedSeen = l.closedAt != 0;
        unitsSeen = l.collateralUnits;
        claimSeen = IProbeLens(lens).claimOf(market, loanId);
        (shortUnitsSeen, shortQuoteSeen) = IProbeLens(lens).shortfallOf(loanId);
        snaps++;
    }
}
