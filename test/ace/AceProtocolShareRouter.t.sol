// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ace, NotTreasury, ShareOverCeiling} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {RevenueRouter} from "../../src/ace/treasury/RevenueRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceProtocolShareRouter
/// @notice The hub's one admin power reaches it through its treasury: the router's owner sets a named hub's share.
/// @notice In production that owner is a 72h timelock two Safes propose to and cancel, so every change waits and can be stopped.
/// @dev A renounce or a handover of the router carries the share with the sink: both are ruled, and pinned here.
contract AceProtocolShareRouterTest is Test {
    RevenueRouter internal router;
    Ace internal ace;

    address internal owner = makeAddr("owner");
    address internal sink = makeAddr("sink");
    address internal stranger = makeAddr("stranger");
    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");

    uint256 internal constant DELAY = 72 hours;

    function setUp() public {
        vm.warp(1_000_000);
        router = new RevenueRouter(owner, sink);
        ace = _hubOn(address(router));
    }

    function _hubOn(address treasury) internal returns (Ace) {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockStakeVault vault = new MockStakeVault(42);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(new MockPersistenceRecord(address(usdc), address(vault)));
        return AceFixtures.deployWithTreasury(p, treasury).ace;
    }

    /* ============================== the forwarding verb ============================== */

    function test_TheRouterOwnerSetsTheNamedHubsShare() public {
        vm.prank(owner);
        router.setProtocolShareBps(address(ace), 400);
        assertEq(ace.protocolShareBps(), 400, "the hub took the router's call as its treasury's");
    }

    function test_AStrangerCannotUseTheRouter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setProtocolShareBps(address(ace), 0);
        assertEq(ace.protocolShareBps(), 1000, "unchanged");
    }

    /// @notice One router, many hubs: it reaches only a hub whose treasury it is, and another hub's refusal bubbles whole.
    function test_AHubBoundToAnotherTreasuryRefusesTheRouter() public {
        Ace other = _hubOn(makeAddr("another-treasury"));
        vm.prank(owner);
        vm.expectRevert(NotTreasury.selector);
        router.setProtocolShareBps(address(other), 0);
        assertEq(other.protocolShareBps(), 1000, "the other hub did not move");
    }

    function test_TheHubsCeilingRefusalBubblesThroughTheRouter() public {
        vm.prank(owner);
        vm.expectRevert(ShareOverCeiling.selector);
        router.setProtocolShareBps(address(ace), 1001);
    }

    function test_OneRouterSetsTwoHubsApart() public {
        Ace second = _hubOn(address(router));
        vm.startPrank(owner);
        router.setProtocolShareBps(address(ace), 0);
        router.setProtocolShareBps(address(second), 700);
        vm.stopPrank();
        assertEq(ace.protocolShareBps(), 0, "the first hub");
        assertEq(second.protocolShareBps(), 700, "and the second, independently");
    }

    /* ============================== what an ownership change carries ============================== */

    /// @notice Ruled: renouncing the router makes the sink AND the share final.
    function test_ARenounceFreezesTheShareWithTheSink() public {
        vm.startPrank(owner);
        router.setProtocolShareBps(address(ace), 250);
        router.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        router.setProtocolShareBps(address(ace), 0);
        vm.stopPrank();
        assertEq(ace.protocolShareBps(), 250, "final at the value it held");
    }

    /// @notice Ruled: a handover of the router hands over the share with the sink.
    function test_AHandoverCarriesTheShare() public {
        address heir = makeAddr("heir");
        vm.prank(owner);
        router.transferOwnership(heir);
        vm.prank(heir);
        router.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        router.setProtocolShareBps(address(ace), 0);

        vm.prank(heir);
        router.setProtocolShareBps(address(ace), 0);
        assertEq(ace.protocolShareBps(), 0, "the heir holds the share power");
    }

    /* ============================== through the 72h timelock ============================== */

    function _timelocked() internal returns (TimelockController tl, Ace hub) {
        address[] memory proposers = new address[](2);
        (proposers[0], proposers[1]) = (safe, guardian);
        address[] memory executors = new address[](1); // address(0): anyone executes
        tl = new TimelockController(DELAY, proposers, executors, address(0));
        RevenueRouter r = new RevenueRouter(address(tl), sink);
        hub = _hubOn(address(r));
        router = r;
    }

    function _call(Ace hub, uint256 s) internal pure returns (bytes memory) {
        return abi.encodeCall(RevenueRouter.setProtocolShareBps, (address(hub), s));
    }

    /// @notice A queued change cannot run before 72h, and runs for anyone after.
    function test_ATimelockedChangeWaitsTheDelay_ThenAnyoneRunsIt() public {
        (TimelockController tl, Ace hub) = _timelocked();
        bytes memory data = _call(hub, 0);
        vm.prank(safe);
        tl.schedule(address(router), 0, data, bytes32(0), bytes32(0), DELAY);

        bytes32 opId = tl.hashOperation(address(router), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, opId, _readyBit()));
        tl.execute(address(router), 0, data, bytes32(0), bytes32(0));
        assertEq(hub.protocolShareBps(), 1000, "nothing moved inside the delay");

        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        tl.execute(address(router), 0, data, bytes32(0), bytes32(0));
        assertEq(hub.protocolShareBps(), 0, "the change landed once the delay ran out");
    }

    /// @notice Either Safe can cancel the other's queued change, which then never runs.
    function test_TheGuardianCancelsTheSafesChange() public {
        (TimelockController tl, Ace hub) = _timelocked();
        bytes memory data = _call(hub, 0);
        vm.prank(safe);
        tl.schedule(address(router), 0, data, bytes32(0), bytes32(0), DELAY);
        bytes32 opId = tl.hashOperation(address(router), 0, data, bytes32(0), bytes32(0));

        vm.prank(guardian);
        tl.cancel(opId);

        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, opId, _readyBit()));
        tl.execute(address(router), 0, data, bytes32(0), bytes32(0));
        assertEq(hub.protocolShareBps(), 1000, "a cancelled change never lands");
    }

    /// @dev The state bitmap `execute` demands: Ready, the timelock's third state.
    function _readyBit() internal pure returns (bytes32) {
        return bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready));
    }

    /// @notice Neither Safe can skip the queue: the router answers only its owner, which is the timelock.
    function test_NeitherSafeCanCallTheRouterDirectly() public {
        (, Ace hub) = _timelocked();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        router.setProtocolShareBps(address(hub), 0);
        assertEq(hub.protocolShareBps(), 1000, "unchanged");
    }
}
