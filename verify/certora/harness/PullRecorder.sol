// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title PullRecorder
/// @notice Stands in for the custodian's `pull` in the payer spec, recording every payer the hub names.
/// @dev Never deployed: the prover dispatches the hub's custodian `pull` calls here, resolved or not.
contract PullRecorder {
    mapping(address => bool) public paid; // some pull named this address as payer
    uint256 public pulls; // pulls recorded

    /// @notice Records `from` as a payer; moves nothing.
    function pull(uint256, address from, uint256) external {
        paid[from] = true;
        pulls++;
    }
}
