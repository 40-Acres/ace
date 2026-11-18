// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";

/// @notice What left the lens with the venue: a view a revival would bring back unnoticed, pinned by its selector.
contract AceLensRemovalsTest is Test {
    /// @notice The venue-dependency disclosure is gone; its inputs are the hub's params and the record's own answers.
    function test_TheVenueExposureViewIsGone() public {
        Ace ace = AceFixtures.newAce();
        AceLens lens = new AceLens(address(ace));
        bytes memory call = abi.encodeWithSignature("venueExposure(address,address,address,bytes32[])", address(0), address(0), address(0), new bytes32[](0));
        (bool ok,) = address(lens).staticcall(call);
        assertFalse(ok, "venueExposure is deleted");
        (ok,) = address(lens).staticcall(abi.encodeWithSignature("loanCount()"));
        assertTrue(ok, "control: the lens answers a view it still carries");
    }

    /// @notice The same absence read off the bytecode, so a revival that refuses all-zero arguments cannot pass for absent.
    /// @dev The dispatcher matches a selector with a PUSH4 of it; the control finds `loanCount` the same way.
    function test_TheVenueExposureSelectorIsNotDispatched() public {
        AceLens lens = new AceLens(address(AceFixtures.newAce()));
        bytes memory code = address(lens).code;
        assertTrue(_pushes(code, AceLens.loanCount.selector), "control: the scan finds a selector the lens still dispatches");
        assertFalse(_pushes(code, bytes4(keccak256("venueExposure(address,address,address,bytes32[])"))), "venueExposure is dispatched");
    }

    /// @dev Whether `code` holds PUSH4 `sel`; a chance match fails loud, never passes quietly.
    function _pushes(bytes memory code, bytes4 sel) internal pure returns (bool) {
        uint256 want = (uint256(0x63) << 32) | uint256(uint32(sel));
        for (uint256 i; i + 5 <= code.length; i++) {
            uint256 w;
            assembly ("memory-safe") {
                w := shr(216, mload(add(add(code, 32), i)))
            }
            if (w == want) return true;
        }
        return false;
    }
}
