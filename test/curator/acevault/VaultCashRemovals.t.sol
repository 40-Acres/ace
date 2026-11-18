// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {Ace} from "../../../src/ace/hub/Ace.sol";
import {AceLens} from "../../../src/ace/lens/AceLens.sol";

/// @notice What leaves with the credit line: the lens's line reads.
contract VaultCashRemovalsTest is Test {
    /// @notice The lens no longer reads a line's pot or counts markets per collateral.
    function test_TheLensLineReadsAreGone() public {
        Ace ace = AceFixtures.newAce();
        AceLens lens = new AceLens(address(ace));
        (bool ok,) = address(lens).staticcall(abi.encodeWithSignature("lineAvailable(bytes32)", bytes32(0)));
        assertFalse(ok, "lineAvailable is deleted");
        bytes32[] memory ids = new bytes32[](0);
        (ok,) = address(lens).staticcall(abi.encodeWithSignature("collateralExposure(address,bytes32[])", address(0), ids));
        assertFalse(ok, "collateralExposure is deleted");
    }
}
