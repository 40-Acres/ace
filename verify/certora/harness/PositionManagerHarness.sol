// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PositionManager} from "../../../src/ace/positions/PositionManager.sol";

/// @title PositionManagerHarness
/// @notice The custodian plus one view: whether its reentrancy guard is clear, as the hub exposes for itself.
/// @notice A liveness rule needs it, since the prover starts a transient slot anywhere and a transaction starts it at zero.
/// @notice It adds a view and no state, so the layout is the custodian's and every method under test is its own.
contract PositionManagerHarness is PositionManager {
    constructor(address loanManager) PositionManager(loanManager) {}

    /// @notice True when no guarded custodian call is in progress.
    function notEntered() external view returns (bool) {
        return !_reentrancyGuardEntered();
    }
}
