// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PositionTitleNFT} from "../../../src/ace/positions/PositionTitleNFT.sol";

/// @title PositionTitleNFTHarness
/// @notice The title collection plus two views OZ keeps internal, so a spec reads an unminted token without a revert.
/// @dev Views only: no state, so the layout and every method under test are the collection's own.
contract PositionTitleNFTHarness is PositionTitleNFT {
    constructor(address hub) PositionTitleNFT(hub) {}

    /// @notice The token's owner, or zero when it was never minted (`ownerOf` reverts there).
    function ownerOrZero(uint256 tokenId) external view returns (address) {
        return _ownerOf(tokenId);
    }

    /// @notice The token's single approval, read without `getApproved`'s existence check.
    function approvalOf(uint256 tokenId) external view returns (address) {
        return _getApproved(tokenId);
    }
}
