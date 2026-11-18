// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockSAeroStakeReceipt
/// @notice The stake receipt as `SAeroTerms` reads it: its state, its backing and its supply, all storage.
/// @notice Distinct from `MockStakeAccount`, which serves the RECORD lane and carries revert switches the terms never need.
/// @dev DISPATCHED, not linked: the terms reach a receipt through a call ARGUMENT, which no `link` directive can bind.
/// @dev The state is a bare uint8 on purpose, so a spec can reach a value the real enum does not name and prove the gate.
contract MockSAeroStakeReceipt {
    uint8 internal st; // 0 None, 1 Holding, 2 Seized, 3 Sold
    uint256 internal back; // what backing answers
    uint256 internal supply; // what totalSupply answers

    /// @notice The receipt's state, as the terms' lending answer gates on.
    /// @return The stored state.
    function state() external view returns (uint8) {
        return st;
    }

    /// @notice The quote-side backing behind the whole receipt supply.
    /// @return The stored backing.
    function backing() external view returns (uint256) {
        return back;
    }

    /// @notice The receipt supply, read through IERC20 by the terms.
    /// @return The stored supply.
    function totalSupply() external view returns (uint256) {
        return supply;
    }

    /// @notice The state a spec compares the terms' gate against.
    /// @return The stored state.
    function stateView() external view returns (uint8) {
        return st;
    }

    /// @notice The backing a spec compares the terms' bid against.
    /// @return The stored backing.
    function backingView() external view returns (uint256) {
        return back;
    }

    /// @notice The supply a spec compares the terms' bid against.
    /// @return The stored supply.
    function supplyView() external view returns (uint256) {
        return supply;
    }
}
