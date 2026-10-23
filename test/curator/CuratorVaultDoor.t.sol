// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVaultDoorHarness, DelegateTarget} from "./harness/CuratorVaultDoorHarness.sol";

error DoorBroke(); // the base's door refusal, bound by selector

/// @title CuratorVaultDoor
/// @notice The door bracket and the delegate hook, measured on a product whose doors each do one thing a builder might.
/// @notice The bracket's one base check is the guard: a door run without the vault's reentrancy guard held is refused.
/// @dev Each refusal row has a control beside it, so a row that reverts for some other reason cannot pass as this one.
contract CuratorVaultDoorTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;

    event Collected(uint256 amount);

    CuratorVaultDoorHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new CuratorVaultDoorHarness(_cfg(0), _listing());
        mid = _doorMarket(h, address(collateral));
        _lpDeposit(h, alice, SEED);
    }

    // ---- the guard, an early return ----

    /// @notice A DOOR WITHOUT THE REENTRANCY GUARD BREAKS.
    function test_Door_AnUnguardedDoorBreaks() public {
        vm.expectRevert(DoorBroke.selector);
        h.unguarded();
        h.step(false); // CONTROL: the same empty body under the guard passes
    }

    /// @notice AN EARLY `return` STILL RUNS THE CLOSE: the realizing sweep collects the hub's owed credit on the early branch too.
    /// @dev A door borrow leaves the lender's fee share owed at the hub, so the close has something to collect.
    function test_Door_AnEarlyReturnStillRunsTheClose() public {
        _open(1_000e6);
        uint256 owed = ace.lenderOwed(address(h), address(usdc));
        assertGt(owed, 0, "PREMISE: the hub owes the vault its fee share");
        uint256 idle0 = h.idle();

        vm.expectEmit(address(h));
        emit Collected(owed);
        assertEq(h.earlyReturn(true), 1, "the early branch answers");
        assertEq(ace.lenderOwed(address(h), address(usdc)), 0, "and its close collected the whole credit");
        assertEq(h.idle(), idle0 + owed, "into idle");

        assertEq(h.earlyReturn(false), 2, "CONTROL: the late return passes and answers");
    }

    // ---- the delegate hook ----

    /// @notice THE DELEGATE HOOK RETURNS THE LIBRARY'S ANSWER AND BUBBLES ITS CUSTOM ERROR VERBATIM.
    function test_Delegate_ReturnsTheAnswerAndBubblesACustomError() public {
        DelegateTarget t = new DelegateTarget();
        bytes memory ret = h.delegateTo(address(t), abi.encodeCall(DelegateTarget.answer, ()));
        assertEq(abi.decode(ret, (uint256)), 42, "the answer comes back whole");
        vm.expectRevert(abi.encodeWithSelector(DelegateTarget.Boom.selector, 7));
        h.delegateTo(address(t), abi.encodeCall(DelegateTarget.boom, (7)));
    }

    /// @notice AN EMPTY REVERT SURFACES AS `FailedCall()`, never as nothing.
    function test_Delegate_AnEmptyRevertIsFailedCall() public {
        DelegateTarget t = new DelegateTarget();
        vm.expectRevert(Errors.FailedCall.selector);
        h.delegateTo(address(t), abi.encodeCall(DelegateTarget.empty, ()));
    }
}
