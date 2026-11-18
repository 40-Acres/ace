// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {DummyERC20} from "./DummyERC20.sol";

/// @title MockDoorReceipt
/// @notice A seized receipt as `SAeroTerms`' door calls it: `settle` and `sweep` pay a stored amount and report another, and its claim and sweep flag are free.
/// @notice So the door meets a receipt that pays what it reports, pays short, pays over, or refuses; the real receipt only narrows that.
/// @dev It arrives as a call argument, so the spec DISPATCHES to it; `cash` is LINKED to the terms' asset, so the pay moves real balances.
contract MockDoorReceipt {
    DummyERC20 public cash; // the asset settle and sweep pay
    uint256 internal pays; // what settle and sweep move to the caller
    uint256 internal reports; // what settle and sweep return
    bool internal refuses; // whether settle and sweep revert
    uint256 internal debt; // what seniorDebt answers
    bool internal sweptFlag; // what swept answers

    /// @notice Pay the stored amount to the caller and report the stored figure, or refuse.
    /// @return The reported figure.
    function settle() external returns (uint256) {
        require(!refuses, "refused");
        cash.transfer(msg.sender, pays);
        return reports;
    }

    /// @notice As settle.
    /// @return The reported figure.
    function sweep() external returns (uint256) {
        require(!refuses, "refused");
        cash.transfer(msg.sender, pays);
        return reports;
    }

    /// @notice The vault's open claim.
    /// @return The stored claim.
    function seniorDebt() external view returns (uint256) {
        return debt;
    }

    /// @notice Whether a sweep sold the receipt.
    /// @return The stored flag.
    function swept() external view returns (bool) {
        return sweptFlag;
    }

    /// @notice The claim, for a spec.
    /// @return The stored claim.
    function debtView() external view returns (uint256) {
        return debt;
    }

    /// @notice The sweep flag, for a spec.
    /// @return The stored flag.
    function sweptView() external view returns (bool) {
        return sweptFlag;
    }
}
