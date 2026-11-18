// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../../../src/ace/hub/Types.sol";

/// @title MockCuratedHub
/// @notice The hub as `CuratorTerms` reads it: a lender's position per collateral, a loan's market, and the market's collateral and record.
/// @notice Every answer is storage the prover sets, keyed by every argument, so a read with its arguments swapped reads another answer.
/// @dev LINKED to the terms' `ACE` immutable; it writes nothing.
contract MockCuratedHub {
    mapping(address => mapping(address => mapping(address => uint256))) internal lent; // lender, quote, collateral
    mapping(address => mapping(address => mapping(address => uint256))) internal unsold; // lender, quote, collateral
    mapping(uint256 => bytes32) internal market; // what loanMarket answers
    mapping(bytes32 => address) internal collateralOf; // the market's collateral
    mapping(bytes32 => address) internal recordOf; // the market's record

    /// @notice The stored lent amount and unsold units.
    function lenderByCollateral(address lender, address quote, address collateral) external view returns (uint256, uint256) {
        return (lent[lender][quote][collateral], unsold[lender][quote][collateral]);
    }

    /// @notice The loan's stored market id.
    function loanMarket(uint256 id) external view returns (bytes32) {
        return market[id];
    }

    /// @notice The market's params, its collateral and record set and the rest zero.
    function idToMarketParams(bytes32 m) external view returns (MarketParams memory mp) {
        mp.collateral = collateralOf[m];
        mp.record = recordOf[m];
    }

    /// @notice The collateral of the loan's market, for a spec.
    function collateralOfLoan(uint256 id) external view returns (address) {
        return collateralOf[market[id]];
    }

    /// @notice The record of the loan's market, for a spec.
    function recordOfLoan(uint256 id) external view returns (address) {
        return recordOf[market[id]];
    }
}
