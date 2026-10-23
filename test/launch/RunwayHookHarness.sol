// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../vendor/launcher/BaseHook.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";

/// @title RunwayHookHarness
/// @notice The Runway hook at any address, its slot roll, its swap callback and its stored windows exposed so a row can drive them directly.
/// @dev Its deployer is FACTORY, as the shipped hook's is; it adds no storage, so its layout is the hook's.
contract RunwayHookHarness is RunwayHook {
    constructor(IPoolManager poolManager_, address authorized_) RunwayHook(poolManager_, authorized_) {}

    /// @dev Any address: BaseHook leaves this virtual so a test can deploy a hook off its permission bits.
    function validateHookAddress(BaseHook) internal pure override {}

    function roll(Window memory w, uint32 k, int24 t) external pure returns (Window memory) {
        return _roll(w, k, t);
    }

    /// @dev The swap callback on the key these fields name, the key arriving as calldata through a self-call, as the PoolManager's does.
    /// @dev Primitive arguments, because the prover cannot name the file-level PoolKey.
    function beforeSwapOn(address currency0, address currency1, uint24 fee, int24 tickSpacing) external {
        PoolKey memory key = PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), fee, tickSpacing, IHooks(address(this)));
        this.beforeSwapCalldata(key, SwapParams(true, -1, 0), "");
    }

    /// @dev `_beforeSwap` with no PoolManager check, for the wrapper above.
    function beforeSwapCalldata(PoolKey calldata key, SwapParams calldata params, bytes calldata data) external {
        _beforeSwap(msg.sender, key, params, data);
    }

    function setWindow(PoolId id, Window memory w) external {
        _windows[id] = w;
    }

    function windowAt(PoolId id) external view returns (Window memory) {
        return _windows[id];
    }
}
