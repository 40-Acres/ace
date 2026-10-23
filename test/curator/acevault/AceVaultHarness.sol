// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault, VaultConfig} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../../src/curator/AceVaultFlows.sol";

/// @notice A test product on the base: its terms, its two roll legs and its cap room are whatever a row sets.
/// @dev It lets a row hand the core door a market no shipped product would build, so the core's own refusals are what answers.
/// @dev `settle` is a product settle door, the shape PawnShop, SetVault and NftVault run, over the base's promise split.
contract AceVaultHarness is AceVault {
    MarketParams internal _mp;
    Terms internal _t;
    bool public priceOk = true;
    bool public rollOk = true;
    uint256 public roomLeft = type(uint256).max;

    constructor(VaultConfig memory cfg) AceVault(cfg, "Harness", "HRN") {}

    function setTerms(MarketParams calldata mp, Terms calldata t) external {
        _mp = mp;
        _t = t;
    }

    function setLegs(bool price, bool roll_) external {
        (priceOk, rollOk) = (price, roll_);
    }

    function setRoom(uint256 r) external {
        roomLeft = r;
    }

    /// @notice A product settle door: end the loan by the base's promise split, then take the pot home.
    function settle(uint256 loanId) external nonReentrant door {
        AceVaultFlows.endLoan(ACE, loanId);
    }

    function _borrowTerms(BorrowRequest calldata, bytes calldata) internal view override returns (MarketParams memory, Terms memory) {
        return (_mp, _t);
    }

    function _priceAdmits(MarketParams memory, uint256, bytes calldata) internal view override returns (bool) {
        return priceOk;
    }

    function _rollAdmits(MarketParams memory) internal view override returns (bool) {
        return rollOk;
    }

    function _room(MarketParams memory) internal view override returns (uint256) {
        return roomLeft;
    }
}
