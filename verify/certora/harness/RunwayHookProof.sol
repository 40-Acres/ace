// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../../contracts/vendor/launcher/BaseHook.sol";
import {RunwayHook} from "../../../src/entities/launch/RunwayHook.sol";

/// @title RunwayHookProof
/// @notice RunwayHook at any address, its roll, its window read, its swap callback and its registration gate reached by key fields.
/// @notice A spec cannot name the file-level PoolKey or PoolId, so each entry takes the key's four fields and builds the key this hook would see.
/// @dev Adds no storage, so its layout is the hook's; the swap and initialize legs reach the hook's own internals through a calldata self-call.
contract RunwayHookProof is RunwayHook {
    using PoolIdLibrary for PoolKey;

    /// @param poolManager_ The PoolManager.
    /// @param strategy_ The LBP strategy.
    constructor(IPoolManager poolManager_, address strategy_) RunwayHook(poolManager_, strategy_) {}

    /// @dev Any address: BaseHook leaves this virtual so a proof can deploy the hook off its permission bits.
    function validateHookAddress(BaseHook) internal pure override {}

    /// @notice The hook's slot roll.
    /// @param w The stored window.
    /// @param k The slot index.
    /// @param t The block-start tick.
    /// @return The window with `t` folded in at slot `k`.
    function roll(Window memory w, uint32 k, int24 t) external pure returns (Window memory) {
        return _roll(w, k, t);
    }

    /// @notice The pool id of the key these fields name.
    /// @param c0 The pool's currency0.
    /// @param c1 The pool's currency1.
    /// @param fee The pool's fee.
    /// @param ts The pool's tick spacing.
    /// @return The id as its word.
    function keyId(address c0, address c1, uint24 fee, int24 ts) external view returns (bytes32) {
        return PoolId.unwrap(_key(c0, c1, fee, ts).toId());
    }

    /// @notice The stored window of the key these fields name.
    /// @param c0 The pool's currency0.
    /// @param c1 The pool's currency1.
    /// @param fee The pool's fee.
    /// @param ts The pool's tick spacing.
    /// @return The stored window.
    function windowOfKey(address c0, address c1, uint24 fee, int24 ts) external view returns (Window memory) {
        return _windows[_key(c0, c1, fee, ts).toId()];
    }

    /// @notice The hook's own `windowOf` read, on the key these fields name.
    /// @param c0 The pool's currency0.
    /// @param c1 The pool's currency1.
    /// @param fee The pool's fee.
    /// @param ts The pool's tick spacing.
    /// @return lo The window's low.
    /// @return hi The window's high.
    /// @return spot The pool's tick now.
    function readOfKey(address c0, address c1, uint24 fee, int24 ts) external view returns (int24 lo, int24 hi, int24 spot) {
        return this.windowOf(_key(c0, c1, fee, ts).toId());
    }

    /// @notice The swap callback on the key these fields name, the key arriving as calldata, as the PoolManager's does.
    /// @param c0 The pool's currency0.
    /// @param c1 The pool's currency1.
    /// @param fee The pool's fee.
    /// @param ts The pool's tick spacing.
    function swapOn(address c0, address c1, uint24 fee, int24 ts) external {
        this.beforeSwapCalldata(_key(c0, c1, fee, ts), SwapParams(true, -1, 0), "");
    }

    /// @notice `_beforeSwap` with no PoolManager check, for the wrapper above.
    /// @param key The pool key.
    /// @param params The swap.
    /// @param data The hook data.
    function beforeSwapCalldata(PoolKey calldata key, SwapParams calldata params, bytes calldata data) external {
        _beforeSwap(msg.sender, key, params, data);
    }

    /// @notice The registration gate for `sender` initializing the key these fields name.
    /// @param sender The initializer the PoolManager reports.
    /// @param c0 The pool's currency0.
    /// @param c1 The pool's currency1.
    /// @param fee The pool's fee.
    /// @param ts The pool's tick spacing.
    /// @param sqrtPriceX96 The initial price.
    /// @return The hook's answer.
    function initializeOn(address sender, address c0, address c1, uint24 fee, int24 ts, uint160 sqrtPriceX96) external view returns (bytes4) {
        return this.beforeInitializeCalldata(sender, _key(c0, c1, fee, ts), sqrtPriceX96);
    }

    /// @notice `_beforeInitialize` with no PoolManager check, for the wrapper above.
    /// @param sender The initializer.
    /// @param key The pool key.
    /// @param sqrtPriceX96 The initial price.
    /// @return The hook's answer.
    function beforeInitializeCalldata(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external view returns (bytes4) {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @dev The key these fields name, with this hook as its hook.
    function _key(address c0, address c1, uint24 fee, int24 ts) internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, ts, IHooks(address(this)));
    }
}
