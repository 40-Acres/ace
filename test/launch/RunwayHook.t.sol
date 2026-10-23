// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {InitializerHook} from "../../vendor/launcher/InitializerHook.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";
import {RunwayFixture} from "./RunwayFixture.sol";
import {RunwaySalt} from "./RunwayMocks.sol";

/// @title RunwayHookTest
/// @notice The Runway hook against a local v4 PoolManager: the one pool a launch recorded opens for the strategy, and nothing else opens at all.
/// @dev The fork suite runs the same gate through the deployed strategy's own migration.
contract RunwayHookTest is RunwayFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant PRICE = 1 << 96;

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

    // ---- the address and the wiring ----

    /// @notice The hook's address carries the before-initialize and before-swap bits and no other, and its permissions say the same.
    /// @notice No delta door on either side, no after-swap: it cannot touch a swap's amounts.
    function test_TheAddressCarriesInitializeAndSwapAlone() public view {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, flags, "the address carries other permission bits");
        Hooks.Permissions memory p = hook.getHookPermissions();
        bool[12] memory others = [
            p.afterInitialize,
            p.beforeAddLiquidity,
            p.afterAddLiquidity,
            p.beforeRemoveLiquidity,
            p.afterRemoveLiquidity,
            p.afterSwap,
            p.beforeDonate,
            p.afterDonate,
            p.beforeSwapReturnDelta,
            p.afterSwapReturnDelta,
            p.afterAddLiquidityReturnDelta,
            p.afterRemoveLiquidityReturnDelta
        ];
        assertTrue(p.beforeInitialize, "no before-initialize permission");
        assertTrue(p.beforeSwap, "no before-swap permission");
        for (uint256 i; i < others.length; ++i) {
            assertFalse(others[i], "a permission past before-initialize and before-swap");
        }
    }

    /// @notice The factory made the hook: the hook names it, the strategy as its one initializer, and the strategy's PoolManager.
    function test_TheFactoryMadeTheHook() public view {
        assertEq(address(hook.FACTORY()), address(factory), "the hook names another factory");
        assertEq(hook.authorized(), address(strat), "the hook admits another initializer");
        assertEq(address(hook.poolManager()), address(manager), "the hook is on another PoolManager");
    }

    /// @notice A salt that does not land the hook on its two bits is refused by the hook's own address check, so no factory deploys without one.
    function test_AWrongSaltRefusesTheFactory() public {
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 good = RunwaySalt.mine(at, address(manager), address(strat));
        bytes32 bad = bytes32(uint256(good) + 1);
        address hookAt = RunwaySalt.hookAt(at, bad, address(manager), address(strat));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        assertTrue(uint160(hookAt) & Hooks.ALL_HOOK_MASK != flags, "fixture: the next salt lands on the bits too");
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, hookAt));
        new LaunchTokenFactory(address(ace), address(strat), address(usdc), BLOCK_SECONDS, FEE, SPACING, bad, cutSink, 0);
    }

    // ---- the gate ----

    /// @notice The strategy opens the pool a launch recorded, at its price.
    function test_TheStrategyOpensTheRecordedPool() public {
        Made memory m = _launch();
        assertEq(factory.launchByOf(m.key.toId()), m.launchBy, "fixture: the launch recorded its pool");
        strat.openPool(m.key, PRICE);
        assertEq(_sqrtP(m.key), PRICE, "the recorded pool did not open at the strategy's price");
    }

    /// @notice The recorded key closes after launchBy: a second past it the strategy itself is refused, and AT launchBy it still opens.
    function test_TheKeyClosesAfterLaunchBy() public {
        Made memory m = _launch();
        _warpTo(m.launchBy + 1);
        vm.expectRevert(_refused(abi.encodeWithSelector(RunwayHook.NotALaunchPool.selector)));
        strat.openPool(m.key, PRICE);
        _warpTo(m.launchBy);
        strat.openPool(m.key, PRICE);
        assertEq(_sqrtP(m.key), PRICE, "the key did not open at launchBy itself");
    }

    /// @notice A stranger cannot open the recorded pool first: the stock sender check refuses it, so no decoy price can sit at the key.
    function test_AStrangerCannotOpenTheRecordedPool() public {
        Made memory m = _launch();
        vm.prank(stranger);
        vm.expectRevert(_refused(abi.encodeWithSelector(InitializerHook.InvalidInitializer.selector, stranger, address(strat))));
        manager.initialize(m.key, PRICE);
        assertEq(_sqrtP(m.key), 0, "the stranger's pool opened");
        strat.openPool(m.key, PRICE);
        assertEq(_sqrtP(m.key), PRICE, "the strategy could not open it after the stranger's attempt");
    }

    /// @notice The strategy itself cannot open a pool naming this hook that no launch recorded: here, a launch token at another fee.
    function test_TheStrategyCannotOpenAnUnrecordedPool() public {
        Made memory m = _launch();
        PoolKey memory other = m.key;
        other.fee = 3_000;
        vm.expectRevert(_refused(abi.encodeWithSelector(RunwayHook.NotALaunchPool.selector)));
        strat.openPool(other, PRICE);
        assertEq(_sqrtP(other), 0, "an unrecorded pool opened behind the hook");
    }

    /// @notice A token the factory never launched gets no pool behind the hook, even opened by the strategy.
    /// @notice The hook admits only a key the factory recorded, until its launchBy.
    function test_ATokenBornElsewhereGetsNoPool() public {
        PoolKey memory k = _keyOf(address(0xD15C0));
        vm.expectRevert(_refused(abi.encodeWithSelector(RunwayHook.NotALaunchPool.selector)));
        strat.openPool(k, PRICE);
    }

    /// @notice Any one field changed from the recorded key, a currency, the fee or the spacing, names a pool the hook refuses.
    function testFuzz_OnlyTheRecordedKeyOpens(uint8 field, uint24 fee, int24 spacing, address currency) public {
        Made memory m = _launch();
        PoolKey memory k = m.key;
        field = uint8(bound(field, 0, 2));
        if (field == 0) {
            fee = uint24(bound(fee, 0, 1_000_000));
            vm.assume(fee != k.fee);
            k.fee = fee;
        } else if (field == 1) {
            spacing = int24(bound(spacing, 1, 32_767));
            vm.assume(spacing != k.tickSpacing);
            k.tickSpacing = spacing;
        } else {
            vm.assume(currency != address(0) && currency != Currency.unwrap(k.currency0) && currency != Currency.unwrap(k.currency1));
            (address c0, address c1) = currency < m.token ? (currency, m.token) : (m.token, currency);
            (k.currency0, k.currency1) = (Currency.wrap(c0), Currency.wrap(c1));
        }
        vm.expectRevert(_refused(abi.encodeWithSelector(RunwayHook.NotALaunchPool.selector)));
        strat.openPool(k, PRICE);
    }
}
