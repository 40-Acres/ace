// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockFortyAcresFactory
/// @notice The one read `SAeroStakeReceiptFactory.make` takes off the 40 Acres saero-fixed factory, answered from storage the prover sets.
/// @dev LINKED to the factory's `PORTFOLIO_FACTORY` immutable. The answer is free, so `make` meets portfolios and strangers alike.
contract MockFortyAcresFactory {
    mapping(address => bool) internal portfolios; // what isPortfolio answers

    /// @notice Whether `portfolio` is one of this factory's portfolios.
    /// @param portfolio The address asked about.
    /// @return The stored flag.
    function isPortfolio(address portfolio) external view returns (bool) {
        return portfolios[portfolio];
    }
}
