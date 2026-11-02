// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IInitializerHook} from "../../vendor/launcher/IInitializerHook.sol";
import {MigratorParameters} from "../../src/interfaces/ILaunchAuction.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";
import {ScheduleLock} from "../../src/entities/vesting/ScheduleLock.sol";
import {MockLaunchAuction} from "./MockLaunchAuction.sol";
import {RunwayFixture} from "./RunwayFixture.sol";
import {MockRunwayStrategy, RunwaySalt} from "./RunwayMocks.sol";

/// @notice Two launches in ONE call, reading the gate between them and after, and trying an outside registration between them.
/// @dev One call is one transaction even under `--isolate`, where each top-level call of a test is its own and transient storage resets.
contract TwinLauncher {
    LaunchTokenFactory internal immutable F;
    MockRunwayStrategy internal immutable S;
    address public first;
    address public second;
    bool public launchingBetween;
    address public authorizedBetween;
    bool public outsideLanded; // an outside registration naming the hook landed between the two launches
    bytes public outsideRevert; // what the strategy answered that registration
    bool public launchingAfter;
    address public authorizedAfter;

    constructor(LaunchTokenFactory f, MockRunwayStrategy s) {
        (F, S) = (f, s);
    }

    /// @notice Launch `p`, probe the gate and try an outside registration of `outsideToken`, then launch `p` again onto `secondAuction`.
    function run(LaunchTokenFactory.LaunchInput calldata p, address secondAuction, address outsideToken) external {
        RunwayHook h = F.HOOK();
        first = F.launch(p);
        (launchingBetween, authorizedBetween) = (F.launching(), h.authorized());
        MigratorParameters memory m;
        m.poolParameters.hook = address(h);
        try S.initializeDistribution(outsideToken, 0, abi.encode(m, bytes("")), bytes32(0)) {
            outsideLanded = true;
        } catch (bytes memory reason) {
            outsideRevert = reason;
        }
        S.setNext(secondAuction);
        second = F.launch(p);
        (launchingAfter, authorizedAfter) = (F.launching(), h.authorized());
    }
}

/// @notice A strategy whose auction factory is a SEPARATE contract, unlike the fixture's, so a row can tell which one the fee check reads.
contract SplitStrategy {
    address public positionManager;
    address public initializerFactory;
    address public protocolFeeController; // the strategy's own, which the launch factory must never read as the auction factory's

    constructor(address posm, address auctions, address feeController) {
        (positionManager, initializerFactory, protocolFeeController) = (posm, auctions, feeController);
    }
}

/// @notice An auction factory with a fixed fee controller and nothing else the launch factory's constructor reads.
contract FeeAuctionFactory {
    address public protocolFeeController;

    constructor(address controller) {
        protocolFeeController = controller;
    }
}

/// @notice An auction factory older than the fee controller: it answers the address oracle and has no protocolFeeController at all.
contract LegacyAuctionFactory {
    function getAddress(address, uint256, bytes calldata, bytes32, address) external pure returns (address) {
        return address(0);
    }
}

/// @title RunwayGateHardening
/// @notice The edges of the registration gate, the fee check, the operator sentinels and DEAD; a row's Kills line names the mutant it catches.
/// @dev The stand-in strategy refuses an unauthorizing hook as the deployed one does; the fork suite runs the gate through the real strategy.
contract RunwayGateHardeningTest is RunwayFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant PRICE = 1 << 96;
    bytes4 internal constant AUTHORIZED_ID = bytes4(keccak256("authorized()")); // the InitializerHook id, derived here from its one selector
    bytes4 internal constant ERC165_ID = 0x01ffc9a7; // supportsInterface(bytes4)

    RunwayHook internal hook;

    function setUp() public override {
        super.setUp();
        hook = factory.HOOK();
    }

    /// @dev The PoolManager's wrap of a hook's refusal of `initialize`, carrying the hook's own error.
    function _refused(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, address(hook), IHooks.beforeInitialize.selector, reason, abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    function _sqrtP(PoolKey memory k) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = IPoolManager(address(manager)).getSlot0(k.toId());
    }

    /// @dev A factory on `strategy`, its hook salt mined against the address it is about to land at.
    function _factoryOn(address strategy) internal returns (LaunchTokenFactory f) {
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(manager), strategy);
        f = new LaunchTokenFactory(address(ace), strategy, address(usdc), BLOCK_SECONDS, FEE, SPACING, salt, cutSink, 0);
        require(address(f) == at, "fixture: the factory landed off its prediction");
    }

    /// @dev The construction `_factoryOn` would run, expecting `err` instead; the salt is mined, so only the fee read can refuse it.
    function _refusesFactoryOn(address strategy, bytes memory err) internal {
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(manager), strategy);
        vm.expectRevert(err);
        new LaunchTokenFactory(address(ace), strategy, address(usdc), BLOCK_SECONDS, FEE, SPACING, salt, cutSink, 0);
    }

    /// @dev As `_refusesFactoryOn`, for any revert: forge rewrites a codeless call's empty revert into a string when it traces, so no data is stable.
    function _refusesFactoryOnAnyRevert(address strategy) internal {
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(manager), strategy);
        vm.expectRevert();
        new LaunchTokenFactory(address(ace), strategy, address(usdc), BLOCK_SECONDS, FEE, SPACING, salt, cutSink, 0);
    }

    // ---- the registration gate across one transaction ----

    /// @notice Two launches in one transaction both land, each on its own auction, key and launchBy, and both keys open for the strategy.
    /// @notice Between them and after them the factory reads not launching and the hook authorizes no one.
    /// @notice An outside registration naming the hook between them is refused, so the first launch leaves no window for the next caller.
    /// @notice Kills a flag never cleared after registration: the between-probe reads the strategy and the outside registration lands.
    function test_TwoLaunchesInOneTransactionLeaveNoWindowOpen() public {
        TwinLauncher twin = new TwinLauncher(factory, strat);
        (MockLaunchAuction a1, MockLaunchAuction a2) = (new MockLaunchAuction(), new MockLaunchAuction());
        strat.setNext(address(a1));
        LaunchTokenFactory.LaunchInput memory p = _input();
        uint256 launchBy = _launchBy(p);
        twin.run(p, address(a2), address(usdc));

        (address t1, address t2) = (twin.first(), twin.second());
        assertTrue(t1 != address(0) && t2 != address(0) && t1 != t2, "the two launches did not make two tokens");
        (, address auction1,) = factory.launchOf(t1);
        (, address auction2,) = factory.launchOf(t2);
        assertEq(auction1, address(a1), "the first launch recorded another auction");
        assertEq(auction2, address(a2), "the second launch recorded another auction");
        assertEq(strat.distributions(), 2, "the strategy did not register exactly the two launches");
        assertEq(factory.launchByOf(_keyOf(t1).toId()), launchBy, "the first key was not recorded");
        assertEq(factory.launchByOf(_keyOf(t2).toId()), launchBy, "the second key was not recorded");

        assertFalse(twin.launchingBetween(), "the factory reads launching between two launches");
        assertEq(twin.authorizedBetween(), address(0), "the hook authorizes a registration between two launches");
        assertFalse(twin.outsideLanded(), "an outside registration naming the hook landed between two launches");
        assertEq(twin.outsideRevert(), abi.encodeWithSelector(MockRunwayStrategy.InvalidHook.selector, address(hook)), "refused for another reason");
        assertFalse(twin.launchingAfter(), "the factory reads launching after the second launch");
        assertEq(twin.authorizedAfter(), address(0), "the hook authorizes a registration after the second launch");

        strat.openPool(_keyOf(t1), PRICE);
        strat.openPool(_keyOf(t2), PRICE);
        assertEq(_sqrtP(_keyOf(t1)), PRICE, "the first launch's key did not open");
        assertEq(_sqrtP(_keyOf(t2)), PRICE, "the second launch's key did not open");
    }

    // ---- the hook's order: the sender check, then the key ----

    /// @notice A stranger on a key no launch recorded meets the sender check, not the key gate: InvalidInitializer, never NotALaunchPool.
    /// @notice Kills the two checks swapped: the stranger would read NotALaunchPool, the gate answering a caller it should never have consulted.
    function test_AStrangerOnAnUnrecordedKeyMeetsTheSenderCheckFirst() public {
        PoolKey memory k = _keyOf(address(0xD15C0));
        assertEq(factory.launchByOf(k.toId()), 0, "fixture: the key is unrecorded");
        vm.prank(stranger);
        vm.expectRevert(_refused(abi.encodeWithSelector(RunwayHook.InvalidInitializer.selector, stranger, address(strat))));
        manager.initialize(k, PRICE);
        assertEq(_sqrtP(k), 0, "the stranger's pool opened");
    }

    /// @notice A stranger on a recorded key past its launchBy also meets the sender check first, though the key has closed.
    function test_AStrangerPastLaunchByMeetsTheSenderCheckFirst() public {
        Made memory m = _launch();
        _warpTo(m.launchBy + 1);
        vm.prank(stranger);
        vm.expectRevert(_refused(abi.encodeWithSelector(RunwayHook.InvalidInitializer.selector, stranger, address(strat))));
        manager.initialize(m.key, PRICE);
        assertEq(_sqrtP(m.key), 0, "the stranger's pool opened");
    }

    /// @notice Any sender but the strategy, on a recorded or unrecorded key, open or closed, is refused by the sender check by name.
    function testFuzz_EveryOtherSenderMeetsTheSenderCheck(address sender, bool recorded, bool late) public {
        assumeNotForgeAddress(sender);
        vm.assume(sender != address(strat));
        Made memory m = _launch();
        PoolKey memory k = m.key;
        if (!recorded) k.fee = 3_000;
        if (late) _warpTo(m.launchBy + 1);
        vm.prank(sender);
        vm.expectRevert(_refused(abi.encodeWithSelector(RunwayHook.InvalidInitializer.selector, sender, address(strat))));
        manager.initialize(k, PRICE);
    }

    // ---- the fee check ----

    /// @notice The fee check reads the strategy's AUCTION FACTORY, never the strategy: the fixture's strategy is its own, so it cannot tell.
    /// @notice A charging auction factory behind a strategy reading fee-free is refused; a free one behind a strategy reading charging is not.
    /// @notice Kills a check pointed at the strategy: the first factory deploys and the second is refused.
    function test_TheFeeCheckReadsTheAuctionFactoryNotTheStrategy() public {
        FeeAuctionFactory charging = new FeeAuctionFactory(address(0xFEE));
        FeeAuctionFactory free = new FeeAuctionFactory(address(0));
        SplitStrategy quiet = new SplitStrategy(address(posm), address(charging), address(0));
        _refusesFactoryOn(address(quiet), abi.encodeWithSelector(LaunchTokenFactory.FeeChargingAuction.selector));
        SplitStrategy loud = new SplitStrategy(address(posm), address(free), address(0xFEE));
        LaunchTokenFactory f = _factoryOn(address(loud));
        assertEq(f.AUCTION_FACTORY(), address(free), "the factory pinned another auction factory");
        assertEq(f.STRATEGY(), address(loud), "the factory pinned another strategy");
    }

    /// @notice An auction factory that cannot say it charges nothing is refused, fail-closed: one with no protocolFeeController, or no code.
    /// @notice The salt is mined, so the fee read is the only thing that can refuse; the legacy one reverts with no data, the failed call's own.
    /// @notice Kills a dropped fee check, and any check that reads a failed call as fee-free.
    function test_AnAuctionFactoryWithNoFeeControllerIsRefused() public {
        SplitStrategy legacy = new SplitStrategy(address(posm), address(new LegacyAuctionFactory()), address(0));
        _refusesFactoryOn(address(legacy), bytes(""));
        SplitStrategy codeless = new SplitStrategy(address(posm), address(0), address(0));
        _refusesFactoryOnAnyRevert(address(codeless));
    }

    // ---- the operator sentinels ----

    /// @notice The sentinel bound is on the WHOLE address: an operator whose low bits are a sentinel, with any high bit set, launches.
    /// @notice Every one lands with the budget paying that exact operator.
    /// @notice Kills the bound read through a narrowing cast, which would refuse 0x100 to 0x102 and the top-bit addresses.
    function test_TheSentinelBoundIsOnTheWholeAddress() public {
        address[6] memory ok =
            [address(0x100), address(0x101), address(0x102), address(uint160(1) << 159), address((uint160(1) << 159) | 2), address(type(uint160).max)];
        for (uint256 i; i < ok.length; ++i) {
            LaunchTokenFactory.LaunchInput memory p = _input();
            p.operator = ok[i];
            Made memory m = _launch(p);
            assertEq(m.budget.terms().operator, ok[i], string.concat("the budget pays another operator than #", vm.toString(i)));
        }
    }

    /// @notice Any operator past the two TAKE sentinels launches, and the budget pays exactly it.
    function testFuzz_AnyOperatorPastTheSentinelsLaunches(uint160 raw) public {
        address op = address(uint160(bound(raw, 3, type(uint160).max)));
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.operator = op;
        Made memory m = _launch(p);
        assertEq(m.budget.terms().operator, op, "the budget pays another operator");
    }

    // ---- ERC-165 ----

    /// @notice The ids the hook answers are the upstream ones, derived here rather than read off the vendored interface.
    /// @notice The InitializerHook id is its one selector, authorized(), since an interface id leaves out what it inherits.
    /// @notice The zero id, and the id XORed with the inherited supportsInterface, are refused: the fuzz row's known counterexamples, pinned.
    function test_TheHookAnswersTheUpstreamIds() public view {
        assertEq(type(IInitializerHook).interfaceId, AUTHORIZED_ID, "the vendored InitializerHook id drifted from authorized()");
        assertEq(type(IERC165).interfaceId, ERC165_ID, "the ERC-165 id");
        assertTrue(hook.supportsInterface(AUTHORIZED_ID), "the hook does not answer authorized()");
        assertTrue(hook.supportsInterface(ERC165_ID), "the hook does not answer ERC-165");
        assertFalse(hook.supportsInterface(bytes4(0)), "the hook answers the zero id");
        assertFalse(hook.supportsInterface(AUTHORIZED_ID ^ ERC165_ID), "the hook answers an id with the inherited selector XORed in");
    }

    /// @notice The hook answers true for exactly the two ids and false for every other.
    function testFuzz_TheHookAnswersExactlyTwoIds(bytes4 id) public view {
        assertEq(hook.supportsInterface(id), id == AUTHORIZED_ID || id == ERC165_ID, "the hook's answer for an id");
    }

    // ---- DEAD through the launch's own paths ----

    /// @notice A team leg to DEAD refuses the whole launch at the lock: its account would hold tokens no key releases.
    /// @notice Kills DEAD dropped from the shared refusal: the launch lands and funds an account nobody can ever release.
    function test_ALegToDeadRefusesTheLaunch() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.legs[0].beneficiary = DEAD;
        strat.setNext(address(new MockLaunchAuction()));
        vm.prank(team);
        vm.expectRevert(ScheduleLock.BadBeneficiary.selector);
        factory.launch(p);
    }

    /// @notice A bid naming DEAD as its beneficiary is refused at the gate, so no auction token can be paid into DEAD's account.
    function test_ABidNamingDeadIsRefusedAtTheGate() public {
        Made memory m = _launch();
        address owner = m.lock.predict(DEAD, m.lock.BUYER());
        vm.expectRevert(ScheduleLock.BadBeneficiary.selector);
        m.lock.validate(1, 1, owner, alice, abi.encode(DEAD));
    }
}
