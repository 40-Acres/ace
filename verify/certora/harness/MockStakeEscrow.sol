// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IStakedAeroEscrow} from "../../../src/interfaces/IStakedAeroEscrow.sol";

/// @title MockStakeEscrow
/// @notice The two reads `SAeroStakeReceiptFactory.make` takes off the Aerodrome V3 staking escrow, answered from storage the prover sets.
/// @dev LINKED to the factory's `ESCROW` immutable. Every answer is free, so `make` meets every owner, permanence and amount.
contract MockStakeEscrow {
    mapping(uint256 => address) internal owners; // what ownerOf answers
    mapping(uint256 => IStakedAeroEscrow.StakedBalance) internal stakes; // what staked answers

    /// @notice Who holds `id`.
    /// @param id The stake.
    /// @return The stored owner.
    function ownerOf(uint256 id) external view returns (address) {
        return owners[id];
    }

    /// @notice The stake's balance: amount, end and permanence.
    /// @param id The stake.
    /// @return The stored balance.
    function staked(uint256 id) external view returns (IStakedAeroEscrow.StakedBalance memory) {
        return stakes[id];
    }

    /// @notice The amount a spec compares `make` against.
    /// @param id The stake.
    /// @return The stored amount.
    function amountView(uint256 id) external view returns (uint128) {
        return stakes[id].amount;
    }

    /// @notice The permanence a spec compares `make` against.
    /// @param id The stake.
    /// @return The stored flag.
    function permanentView(uint256 id) external view returns (bool) {
        return stakes[id].isPermanent;
    }
}
