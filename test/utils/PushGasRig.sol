// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Ace, PushGasOutOfRange, PushGasShort} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceFixtures} from "./AceFixtures.sol";

/// @title PushGasRig
/// @notice Every symbol the push-budget suites need from the hub, in ONE place: the budget, its rail, its floors and its errors.
/// @dev The suites were written red-first against a hub without the budget; keeping these reads here is what let one
/// @dev small stand-in replace them there while the suites themselves stayed byte-for-byte the ones that ship.
library PushGasRig {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant PUSH_GAS = AceFixtures.PUSH_GAS; // the fixture's budget, which is mainnet's
    uint256 internal constant MIN_PUSH_GAS = Constants.MIN_PUSH_GAS;
    uint256 internal constant MAX_PUSH_GAS = Constants.MAX_PUSH_GAS;

    function shortSelector() internal pure returns (bytes4) {
        return PushGasShort.selector;
    }

    function outOfRangeSelector() internal pure returns (bytes4) {
        return PushGasOutOfRange.selector;
    }

    function pushGasOf(Ace ace) internal view returns (uint256) {
        return ace.PUSH_GAS();
    }

    /// @notice A hub with one market at the named budget and treasury.
    function deploy(MarketParams memory p, address treasury, uint256 pushGas) internal returns (AceFixtures.Deployment memory) {
        return AceFixtures.deployWith(p, treasury, pushGas);
    }

    /// @notice A bare hub at `pushGas`, or the constructor's revert data when it refuses.
    function tryHub(address treasury, uint256 pushGas) internal returns (address hub, bytes memory err) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        PositionManager pm = new PositionManager(predicted);
        try new Ace(treasury, address(pm), pushGas) returns (Ace a) {
            hub = address(a);
        } catch (bytes memory e) {
            err = e;
        }
    }
}
