// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceHarness} from "./AceHarness.sol";
import {Market, Storage} from "../../../src/ace/hub/Types.sol";

/// @title DoorsHarness
/// @notice AceHarness plus the reads the door rules need: a credit grant and its nonce, and the dials a crank's gate reads.
/// @notice It adds views and no state, so the layout is the hub's and every method under test is its own.
/// @dev Its own contract, so these views leave every other hub conf's scene as it was.
contract DoorsHarness is AceHarness {
    constructor(address treasury, address positionManager, uint256 pushGas, uint256 policyGas) AceHarness(treasury, positionManager, pushGas, policyGas) {}

    /// @notice Whether `operator` may open loans in `borrower`'s name.
    function creditOperatorOf(address borrower, address operator) external view returns (bool) {
        return Storage.book().creditOperator[borrower][operator];
    }

    /// @notice The nonce `borrower`'s next signed grant must carry.
    function creditNonceOf(address borrower) external view returns (uint256) {
        return Storage.book().creditOperatorNonce[borrower];
    }

    /// @notice A market's deleverage band and stop, and its record: the dials a crank's gate reads.
    function marketGateOf(bytes32 id) external view returns (uint256 bandBps, uint256 stopBps, address record) {
        Market storage M = Storage.markets()[id];
        return (M.p.deleverageBandBps, M.p.deleverageStopBps, M.p.record);
    }
}
