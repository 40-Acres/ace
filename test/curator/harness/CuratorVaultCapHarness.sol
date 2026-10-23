// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {VaultConfig} from "../../../src/curator/AceVault.sol";
import {CuratorVault, Listing} from "../../../src/curator/CuratorVault.sol";

/// @notice A CuratorVault product whose entry cap is a settable number, and zero for one named receiver.
contract CuratorVaultCapHarness is CuratorVault {
    uint256 public cap = type(uint256).max; // what the cap answers for every receiver but `shut`
    address public shut; // the one receiver the cap refuses outright

    constructor(VaultConfig memory cfg, Listing[] memory listings) CuratorVault(cfg, 10e6, 1.4e18, 1 days, listings, "Cap", "cCAP") {}

    /// @notice Set the cap every receiver but `shut` reads.
    function setCap(uint256 c) external {
        cap = c;
    }

    /// @notice Name the one receiver the cap refuses.
    function setShut(address r) external {
        shut = r;
    }

    function _entryCap(address receiver) internal view override returns (uint256) {
        return receiver == shut ? 0 : cap;
    }
}
