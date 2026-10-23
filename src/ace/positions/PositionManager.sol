// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

using SafeERC20 for IERC20;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice What this contract reads off its loan manager: an id's market config, and whether it is a live loan.
/// @dev Both are hub state, and hub state belongs to the loan manager, so they stay cross-contract.
/// @dev Liveness gates the carry, so units can never be carried out of a loan that is still live.
interface ILoanManagerCustody {
    function isLiveLoan(uint256 loanId) external view returns (bool);
    function escrowConfigOf(uint256 loanId) external view returns (address collateral, address quote);
}

/// @title PositionManager
/// @notice The one custodian for every loan of every market; collateral rests here for the loan's life.
/// @notice Liquidation is a title transfer, so custody never moves to change hands.
/// @notice UNSUPPORTED: a collateral whose holder balance can fall other than by this contract's own transfer.
/// @notice UNSUPPORTED: a collateral that pushes native value to its holder during a transfer.
/// @dev A balance fall past the uncredited surplus halts every pull and release of that collateral, in every market, until donated back.
/// @dev A native push reverts every `pull` on that market for its life, since this contract has no `receive()`.
/// @dev Per-loan custody is a LEDGER fact, not an address fact: one pot per collateral, split by `collateralOf`.
/// @dev Collateral leaves by `release` or `releaseRetired` and by nothing else, so the sizing base is pinned.
/// @dev NO foreign asset is recoverable from here, by anyone, ever: nothing sweeps, and there is no owner.
/// @dev I-A: over every loan on a collateral T, across every market whose collateral is T, `collateralOf + retiredOf` is at most the pot.
/// @dev I-B: the hub routes and never custodies; its balance is a ROUTING claim and never an equality, since anyone may donate.
/// @dev I-C: both ledgers move only through the verbs below, all loan-manager only; `pull` credits the MEASURED delta.
/// @dev `custodiedOf` is I-A's pot side at runtime: a `pull` over-credit reverts where it happens, not at a later victim's exit.
/// @dev A CARRY never touches `custodiedOf`, so no rail here sees one: I-A holds only while the hub pairs `carryOut` with `carryIn`.
/// @dev The getters are UNGUARDED: `collateralOf` moves mid-call by design, so a callback reader sees a real intermediate state.
contract PositionManager is ReentrancyGuardTransient {
    error NotLoanManager();
    error FeeOnTransferUnsupported();
    error CustodyUnderfunded(); // the ledger claims more of this collateral than the pot actually holds
    error CollateralMismatch(); // a carry named two loans whose markets hold different tokens
    error CarryFromLiveLoan(); // units may only be carried out of an id no live loan backs: a settled loan, or an order

    address public immutable LOAN_MANAGER;

    mapping(uint256 => uint256) public collateralOf; // id -> units backing a LIVE loan, or escrowed under a resting order
    mapping(uint256 => uint256) public retiredOf; // loanId -> units still held that back no loan any more
    mapping(address => uint256) public custodiedOf; // collateral -> units this contract owes across every loan

    modifier onlyLoanManager() {
        if (msg.sender != LOAN_MANAGER) revert NotLoanManager();
        _;
    }

    /// @param _loanManager The one hub this positionManager serves; that hub's constructor asserts the binding.
    constructor(address _loanManager) {
        LOAN_MANAGER = _loanManager;
    }

    /// @notice Takes collateral into custody when a loan opens, or when a credit order rests its escrow.
    /// @dev `from` is the payer; title is the loan manager's, written there at open.
    /// @dev Fee-on-transfer is refused at entry: the measured receipt must EQUAL the request, so an over-arrival fails too.
    /// @dev The measurement is exact on a shared pot, since one address takes one transfer within one call.
    /// @param loanId The loan being funded, or the order being escrowed.
    /// @param from The payer the units come from.
    /// @param units Collateral units to take into custody.
    function pull(uint256 loanId, address from, uint256 units) external onlyLoanManager nonReentrant {
        (address collateral,) = ILoanManagerCustody(LOAN_MANAGER).escrowConfigOf(loanId);
        uint256 pre = IERC20(collateral).balanceOf(address(this));
        IERC20(collateral).safeTransferFrom(from, address(this), units);
        uint256 post = IERC20(collateral).balanceOf(address(this));
        if (post - pre != units) revert FeeOnTransferUnsupported();
        collateralOf[loanId] += units;
        custodiedOf[collateral] += units;
        if (custodiedOf[collateral] > post) revert CustodyUnderfunded(); // the balance is already in hand: no second read
    }

    /// @notice Releases collateral out of a LIVE loan or a resting order: a disposal hand-off, a withdrawal, an order's retire.
    /// @dev Destination is the hub's `to`; no live-loan path fixes it, so a refused address is the caller's to avoid.
    /// @dev Ledger first, interaction last, and the solvency check after: both sides fall by `units`.
    /// @param loanId The loan or order being debited.
    /// @param to Recipient of the collateral.
    /// @param units Collateral units to send.
    function release(uint256 loanId, address to, uint256 units) external onlyLoanManager nonReentrant {
        (address collateral,) = ILoanManagerCustody(LOAN_MANAGER).escrowConfigOf(loanId);
        collateralOf[loanId] -= units;
        custodiedOf[collateral] -= units;
        IERC20(collateral).safeTransfer(to, units);
        if (custodiedOf[collateral] > IERC20(collateral).balanceOf(address(this))) revert CustodyUnderfunded();
    }

    /// @notice Retires units from the LIVE ledger without moving them: what a close hands to its claimants.
    /// @dev MOVES NO TOKEN, so a close is total under any pause, and the pot-level aggregate is unchanged.
    /// @dev The hub's own ledgers say WHOSE the retired units are: per-loan inventory pots, and per-claimant credits.
    /// @param loanId The loan being closed.
    /// @param units Units leaving the live ledger; the whole position at every close.
    function retireCustody(uint256 loanId, uint256 units) external onlyLoanManager nonReentrant {
        collateralOf[loanId] -= units;
        retiredOf[loanId] += units;
    }

    /// @notice Delivers retired units out of the pot, to a destination the caller named.
    /// @dev The delivery half of `retireCustody`: a claim, an inventory sale and an in-kind redemption all land here.
    /// @param loanId The retired loan being debited.
    /// @param to Recipient, named by the claimant, the buyer or the redeeming lender.
    /// @param units Units to deliver.
    function releaseRetired(uint256 loanId, address to, uint256 units) external onlyLoanManager nonReentrant {
        (address collateral,) = ILoanManagerCustody(LOAN_MANAGER).escrowConfigOf(loanId);
        retiredOf[loanId] -= units;
        custodiedOf[collateral] -= units;
        IERC20(collateral).safeTransfer(to, units);
        if (custodiedOf[collateral] > IERC20(collateral).balanceOf(address(this))) revert CustodyUnderfunded();
    }

    /// @notice Debits the source at a refinance close or an order fill; the units stay in the pot.
    /// @dev The debit half of the carry; it runs at the source, before the successor loan has an id to credit.
    /// @dev MOVES NO TOKEN and leaves the pot-level aggregate alone; paired with its `carryIn`, it cannot under-fund the pot.
    /// @dev An unpaired debit strands units rather than lending them twice: the residue is safe by direction.
    /// @param fromLoanId The retiring loan or resting order giving up its units.
    /// @param units Units leaving the source's ledger.
    function carryOut(uint256 fromLoanId, uint256 units) external onlyLoanManager nonReentrant {
        collateralOf[fromLoanId] -= units;
    }

    /// @notice Credits the successor loan with units the retiring loan has already given up.
    /// @dev The two configs are INDEPENDENT reads on two different ids, so this check compares two real values.
    /// @dev Without it a cross-collateral carry lets the successor release a token it was never funded in.
    /// @dev The source must not be a LIVE LOAN, so no carry can reach collateral a live loan still backs.
    /// @dev A settled loan and a resting credit order both pass: neither has a live loan's claim on the units.
    /// @dev NOTHING HERE CHECKS THE PAIRING: it trusts the caller debited `units` from the source in the same call.
    /// @param fromLoanId The retiring loan or resting order the units came from.
    /// @param toLoanId The successor loan being credited.
    /// @param units Units joining the successor's ledger.
    function carryIn(uint256 fromLoanId, uint256 toLoanId, uint256 units) external onlyLoanManager nonReentrant {
        (address fromCollateral,) = ILoanManagerCustody(LOAN_MANAGER).escrowConfigOf(fromLoanId);
        (address toCollateral,) = ILoanManagerCustody(LOAN_MANAGER).escrowConfigOf(toLoanId);
        if (fromCollateral != toCollateral) revert CollateralMismatch();
        if (ILoanManagerCustody(LOAN_MANAGER).isLiveLoan(fromLoanId)) revert CarryFromLiveLoan();
        collateralOf[toLoanId] += units;
    }

    /// @notice What the pot holds beyond what the ledger owes: donations and mistaken transfers, which no loan can claim.
    /// @dev Pot-level and never per-loan: no loan is ever credited with any of it.
    /// @dev REVERTS (arithmetic) while the pot is short of the ledger: the custody halt, readable here before any move fails.
    /// @param collateral The token to measure.
    /// @return The uncredited surplus, which no loan can ever claim.
    function uncreditedSurplus(address collateral) external view returns (uint256) {
        return IERC20(collateral).balanceOf(address(this)) - custodiedOf[collateral];
    }
}
