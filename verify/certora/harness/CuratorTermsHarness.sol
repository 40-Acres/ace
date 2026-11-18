// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorTerms, CuratorTermsConfig, Listing} from "../../../src/entities/curated/CuratorTerms.sol";

/// @title CuratorTermsHarness
/// @notice `CuratorTerms` with one view: whether its transient reentrancy guard is entered. It adds no state.
/// @dev A rule starts from arbitrary transient storage, and every transaction starts with the guard clear, so a liveness rule states that.
contract CuratorTermsHarness is CuratorTerms {
    constructor(CuratorTermsConfig memory c, Listing[] memory listings) CuratorTerms(c, listings) {}

    /// @notice Whether the reentrancy guard is entered.
    function entered() external view returns (bool) {
        return _reentrancyGuardEntered();
    }
}
