// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title AceLenderView
/// @notice Stands in for the hub in the vault's split spec: the hub reads entry makes, answered from storage.
/// @dev Never deployed. Storage rather than a ghost, so a rule's `at init` rolls it back with the rest of the scene.
contract AceLenderView {
    mapping(address lender => mapping(address quote => uint256)) public lenderAssets; // the hub's pooled figure per (lender, quote)
    mapping(address lender => mapping(address quote => uint256)) internal unsoldPotsOf; // settled pots not yet sold
    mapping(address lender => mapping(address quote => uint256)) internal settledPotsOf; // pots ever settled

    /// @notice The entry gate's read, as the hub answers it: the pair's unsold pots, and its pots ever settled.
    function lenderUnresolved(address lender, address quote) external view returns (uint256 unsoldPots, uint256 settledPots) {
        return (unsoldPotsOf[lender][quote], settledPotsOf[lender][quote]);
    }
}
