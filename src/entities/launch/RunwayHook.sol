// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {InitializerHook} from "../../../vendor/launcher/InitializerHook.sol";

/// @notice The one read the hook makes of the launch factory: the last second a launch's pool may open; zero for any other key.
interface ILaunchPools {
    function launchByOf(PoolId id) external view returns (uint64);
}

/// @title RunwayHook
/// @notice Uniswap's stock InitializerHook, plus one gate: the key must be a factory launch's recorded pool, opened by that launch's launchBy.
/// @notice No launch token is liquid before launchBy, so the one distribution that can open the key is the launch's.
/// @notice It also keeps each pool's block-start price: on a block's first swap, the pre-swap tick goes into three 12-hour slots.
/// @dev It never touches fees or swap amounts: no delta flag, a zero delta, no fee override.
/// @dev The swap path and windowOf must never revert, since a pool's hook is permanent: unchecked, one extsload, no other call, no divisor but SLOT.
/// @dev Its one reader is the launch lending vault, through windowOf; no hub code reads it.
/// @dev The strategy initializes inside its migration's try, so a refusal here fails that migration into the strategy's recovery.
/// @dev Deployed by the factory's constructor at a salt mined for exactly the before-initialize and before-swap bits, so FACTORY is its deployer.
contract RunwayHook is InitializerHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev One packed word per pool: the newest sample's slot and block, and each slot's lowest and highest block-start tick.
    struct Window {
        uint32 slot; // block.timestamp / SLOT at the newest sample
        uint48 lastBlock; // the newest block that sampled
        int24 lo0; // the current slot's lowest block-start tick
        int24 hi0; // the current slot's highest block-start tick
        int24 lo1; // the slot before
        int24 hi1;
        int24 lo2; // the slot before that
        int24 hi2;
        bool seeded; // the pool has sampled
    }

    error NotALaunchPool(); // the key is no launch's recorded pool, or that launch's launchBy has passed

    uint256 public constant SLOT = 12 hours; // one window slot
    ILaunchPools public immutable FACTORY; // the launch factory that deployed this hook and records each launch's pool
    mapping(PoolId => Window) internal _windows; // each pool's block-start window

    /// @param poolManager_ The v4 PoolManager on this chain.
    /// @param authorized_ The only address that may initialize a pool naming this hook: the LBP strategy.
    constructor(IPoolManager poolManager_, address authorized_) InitializerHook(poolManager_, authorized_) {
        FACTORY = ILaunchPools(msg.sender);
    }

    /// @notice Before-initialize and before-swap, and nothing else.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        (p.beforeInitialize, p.beforeSwap) = (true, true);
    }

    /// @notice The lowest and highest block-start tick over the current slot and the two before it, 24 to 36 hours, and spot apart.
    /// @dev Spot joins the window only while no swap has run this block, which is when spot is the block-start price.
    /// @dev A pool that never swapped reads as spot; a key never opened reads zero throughout.
    function windowOf(PoolId id) external view returns (int24 lo, int24 hi, int24 spot) {
        unchecked {
            (, spot,,) = poolManager.getSlot0(id);
            Window memory w = _windows[id];
            if (!w.seeded || w.lastBlock != uint48(block.number)) w = _roll(w, uint32(block.timestamp / SLOT), spot);
            (lo, hi) = (_min(_min(w.lo0, w.lo1), w.lo2), _max(_max(w.hi0, w.hi1), w.hi2));
        }
    }

    /// @dev The stock sender check, then the factory's launchBy for this exact key: an unknown key reads zero and is refused.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) internal view override returns (bytes4 selector) {
        selector = super._beforeInitialize(sender, key, sqrtPriceX96);
        if (block.timestamp > FACTORY.launchByOf(key.toId())) revert NotALaunchPool();
    }

    /// @dev A block's first swap samples the pre-swap tick, the price the block started at; a later swap in the block writes nothing.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        unchecked {
            PoolId id = key.toId();
            Window memory w = _windows[id];
            if (!w.seeded || w.lastBlock != uint48(block.number)) {
                (, int24 t,,) = poolManager.getSlot0(id);
                w = _roll(w, uint32(block.timestamp / SLOT), t);
                w.lastBlock = uint48(block.number);
                _windows[id] = w;
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev `w` with block-start tick `t` folded in at slot `k`: each slot crossed since the newest sample shifts once, up to three.
    /// @dev Only a swap moves a v4 price, so `t` stood at every block start since that sample: it fills each slot it crosses.
    /// @dev A stored slot ahead of `k` crosses none, and an unseeded window crosses all three, starting at `t`.
    function _roll(Window memory w, uint32 k, int24 t) internal pure returns (Window memory) {
        unchecked {
            uint32 j = !w.seeded ? 3 : k > w.slot ? k - w.slot : 0; // slots crossed
            (w.lo0, w.hi0) = (_min(w.lo0, t), _max(w.hi0, t));
            if (j > 0) {
                (w.lo2, w.hi2, w.lo1, w.hi1) = (w.lo1, w.hi1, w.lo0, w.hi0);
                (w.slot, w.seeded, w.lo0, w.hi0) = (k, true, t, t);
            }
            if (j > 1) (w.lo2, w.hi2, w.lo1, w.hi1) = (w.lo1, w.hi1, t, t);
            if (j > 2) (w.lo2, w.hi2) = (t, t);
            return w;
        }
    }

    function _min(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }

    function _max(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }
}
