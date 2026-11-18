// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IFortyAcresMarketplace} from "../../../src/interfaces/IFortyAcres.sol";

/// @title MockPortfolioOwners
/// @notice The one read `SAeroStakeReceipt` takes off the 40 Acres saero-fixed factory: a portfolio's owner, storage the prover sets.
/// @dev LINKED to the receipt's `PORTFOLIO_FACTORY` immutable.
contract MockPortfolioOwners {
    mapping(address => address) internal owners; // what ownerOf answers

    /// @notice Who owns `portfolio`.
    /// @param portfolio The portfolio.
    /// @return The stored owner.
    function ownerOf(address portfolio) external view returns (address) {
        return owners[portfolio];
    }

    /// @notice The owner, for a spec.
    /// @param portfolio The portfolio.
    /// @return The stored owner.
    function ownerView(address portfolio) external view returns (address) {
        return owners[portfolio];
    }
}

/// @title MockSeizedCustody
/// @notice The one read `SAeroStakeReceipt` takes off its custody portfolio: the receipt a stake is mapped to, storage the prover sets.
/// @dev LINKED to the receipt's `CUSTODY` immutable.
contract MockSeizedCustody {
    mapping(uint256 => address) internal receipts; // what receiptOf answers

    /// @notice The receipt `stakeId` is mapped to.
    /// @param stakeId The stake.
    /// @return The stored receipt.
    function receiptOf(uint256 stakeId) external view returns (address) {
        return receipts[stakeId];
    }
}

/// @title MockListings
/// @notice The one read `SAeroStakeReceipt` takes off the 40 Acres marketplace: the row for a token, storage the prover sets.
/// @dev LINKED to the receipt's `MARKETPLACE` immutable.
contract MockListings {
    mapping(uint256 => IFortyAcresMarketplace.Listing) internal rows; // what getListing answers

    /// @notice The row for `tokenId`.
    /// @param tokenId The token.
    /// @return The stored row.
    function getListing(uint256 tokenId) external view returns (IFortyAcresMarketplace.Listing memory) {
        return rows[tokenId];
    }
}
