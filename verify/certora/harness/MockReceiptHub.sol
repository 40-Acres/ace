// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {DummyERC20} from "./DummyERC20.sol";

/// @title MockReceiptHub
/// @notice The hub as `SAeroStakeReceipt` reads it, answers from storage the prover sets, and `repay`, which lowers the debt and pulls the cash.
/// @notice A loan's market carries only the three fields the receipt reads: the collateral, the price and the smallest loan.
/// @dev LINKED to the receipt's `ACE` immutable; `cash` is LINKED to the receipt's asset, so the pull moves real balances.
/// @dev Its `repay` enforces no floor of its own, so a rule about the debt left reads the receipt's bound alone.
contract MockReceiptHub {
    DummyERC20 public cash; // the asset the repay pulls
    address public POSITION_MANAGER; // what the receipt's constructor reads
    mapping(uint256 => bool) internal live; // what isLiveLoan answers
    mapping(uint256 => uint256) internal debt; // what debtOf answers, lowered by repay
    mapping(uint256 => bytes32) internal market; // what loanMarket answers
    mapping(bytes32 => address) internal collateral; // the market's collateral
    mapping(bytes32 => uint256) internal price; // the market's price
    mapping(bytes32 => uint256) internal minPrincipal; // the market's smallest loan
    mapping(uint256 => mapping(address => uint256)) internal owedUnits; // what owedOf answers
    mapping(uint256 => bool) internal extendOk; // whether tryExtend admits the roll
    mapping(uint256 => uint256) internal extendFee; // the fee tryExtend quotes

    /// @notice Whether `id` is a live loan.
    /// @param id The loan.
    /// @return The stored flag.
    function isLiveLoan(uint256 id) external view returns (bool) {
        return live[id];
    }

    /// @notice The loan's debt.
    /// @param id The loan.
    /// @return The stored debt.
    function debtOf(uint256 id) external view returns (uint256) {
        return debt[id];
    }

    /// @notice The loan's market id.
    /// @param id The loan.
    /// @return The stored market id.
    function loanMarket(uint256 id) external view returns (bytes32) {
        return market[id];
    }

    /// @notice The market's params, the three fields the receipt reads set and the rest zero.
    /// @param m The market id.
    /// @return mp The params.
    function idToMarketParams(bytes32 m) external view returns (MarketParams memory mp) {
        mp.collateral = collateral[m];
        mp.price = price[m];
        mp.minPrincipal = minPrincipal[m];
    }

    /// @notice The units and amount owed to `claimant` on `id`; the amount is zero.
    /// @param id The loan.
    /// @param claimant The claimant.
    /// @return units The stored units.
    /// @return amount Zero.
    function owedOf(uint256 id, address claimant) external view returns (uint256 units, uint256 amount) {
        return (owedUnits[id][claimant], 0);
    }

    /// @notice Whether a roll of `id` would land, and its fee.
    /// @param id The loan.
    /// @return ok The stored admission.
    /// @return reason Zero.
    /// @return fee The stored fee.
    function tryExtend(uint256 id, uint256, bytes calldata, address) external view returns (bool ok, bytes4 reason, uint256 fee) {
        return (extendOk[id], bytes4(0), extendFee[id]);
    }

    /// @notice Lower `id`'s debt by `amount` and pull `amount` of the cash from the caller.
    /// @param id The loan.
    /// @param amount The repayment.
    function repay(uint256 id, uint256 amount) external {
        debt[id] -= amount;
        cash.transferFrom(msg.sender, address(this), amount);
    }

    /// @notice The debt a spec compares the receipt against.
    /// @param id The loan.
    /// @return The stored debt.
    function debtView(uint256 id) external view returns (uint256) {
        return debt[id];
    }

    /// @notice Whether the loan is live, for a spec.
    /// @param id The loan.
    /// @return The stored flag.
    function liveView(uint256 id) external view returns (bool) {
        return live[id];
    }

    /// @notice The collateral of the loan's market, for a spec.
    /// @param id The loan.
    /// @return The stored collateral.
    function collateralOfLoan(uint256 id) external view returns (address) {
        return collateral[market[id]];
    }

    /// @notice The price of the loan's market, for a spec.
    /// @param id The loan.
    /// @return The stored price.
    function priceOfLoan(uint256 id) external view returns (uint256) {
        return price[market[id]];
    }

    /// @notice The smallest loan of the loan's market, for a spec.
    /// @param id The loan.
    /// @return The stored smallest loan.
    function minPrincipalOfLoan(uint256 id) external view returns (uint256) {
        return minPrincipal[market[id]];
    }

    /// @notice Whether tryExtend admits a roll of `id`, for a spec.
    /// @param id The loan.
    /// @return The stored admission.
    function extendOkView(uint256 id) external view returns (bool) {
        return extendOk[id];
    }

    /// @notice The fee tryExtend quotes for `id`, for a spec.
    /// @param id The loan.
    /// @return The stored fee.
    function extendFeeView(uint256 id) external view returns (uint256) {
        return extendFee[id];
    }
}
