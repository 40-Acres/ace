// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {DummyERC20} from "./DummyERC20.sol";

/// @title MockDoorVault
/// @notice The vault as `SAeroTerms`' door calls it: its curator, and `returnProceeds`, which pulls the cash named and records the call.
/// @dev LINKED to the terms' `VAULT` immutable; `cash` is LINKED to the terms' asset, so the pull moves real balances.
contract MockDoorVault {
    DummyERC20 public cash; // the asset returnProceeds pulls
    address internal curator; // what CURATOR answers
    uint256 internal calls; // how many returns have landed
    address internal lastKey; // the key of the latest return
    uint256 internal lastCash; // the cash of the latest return
    bool internal lastCloses; // whether the latest return closed its key

    /// @notice The vault's curator.
    /// @return The stored curator.
    function CURATOR() external view returns (address) {
        return curator;
    }

    /// @notice Take `amount` of the caller's cash back against `key`, recording the call.
    /// @param key The seized collateral, or the asset for lender income.
    /// @param amount The cash returned.
    /// @param closes Whether the return closes the key.
    function returnProceeds(address key, uint256 amount, bool closes) external {
        (calls, lastKey, lastCash, lastCloses) = (calls + 1, key, amount, closes);
        cash.transferFrom(msg.sender, address(this), amount);
    }

    /// @notice How many returns have landed, for a spec.
    /// @return The stored count.
    function callsView() external view returns (uint256) {
        return calls;
    }

    /// @notice The latest return's key, for a spec.
    /// @return The stored key.
    function lastKeyView() external view returns (address) {
        return lastKey;
    }

    /// @notice The latest return's cash, for a spec.
    /// @return The stored cash.
    function lastCashView() external view returns (uint256) {
        return lastCash;
    }

    /// @notice Whether the latest return closed its key, for a spec.
    /// @return The stored flag.
    function lastClosesView() external view returns (bool) {
        return lastCloses;
    }

    /// @notice The curator, for a spec.
    /// @return The stored curator.
    function curatorView() external view returns (address) {
        return curator;
    }
}
