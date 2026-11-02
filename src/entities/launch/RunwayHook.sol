// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../../vendor/launcher/BaseHook.sol";
import {IInitializerHook} from "../../../vendor/launcher/IInitializerHook.sol";

/// @notice The two reads the hook makes of the launch factory: a pool's last second to open, and whether a launch is registering now.
interface ILaunchPools {
    function launchByOf(PoolId id) external view returns (uint64);
    function launching() external view returns (bool);
}

/// @title RunwayHook
/// @notice Uniswap's InitializerHook sender check, plus two gates: registration only inside a factory launch, and the key only by its launchBy.
/// @notice The strategy registers a distribution only while its hook's authorized() names it, and this hook names it only inside a launch.
/// @notice So no outside distribution can reserve a launch's pool id or open its key; past launchBy not even the launch's own can.
/// @notice It also keeps each pool's block-start price: on a block's first swap, the pre-swap tick goes into three 12-hour slots.
/// @dev It never touches fees or swap amounts: no delta flag, a zero delta, no fee override.
/// @dev The swap path and windowOf must never revert, since a pool's hook is permanent: unchecked, one extsload, no other call, no divisor but SLOT.
/// @dev Its one reader is the launch lending vault, through windowOf; no hub code reads it.
/// @dev The strategy initializes inside its migration's try, so a refusal here fails that migration into the strategy's recovery.
/// @dev Deployed by the factory's constructor at a salt mined for exactly the before-initialize and before-swap bits, so FACTORY is its deployer.
contract RunwayHook is BaseHook, IInitializerHook {
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

    error InvalidInitializer(address caller, address expected); // the stock sender check: only the strategy initializes
    error NotALaunchPool(); // the key is no launch's recorded pool, or that launch's launchBy has passed

    uint256 public constant SLOT = 12 hours; // one window slot
    ILaunchPools public immutable FACTORY; // the launch factory that deployed this hook and records each launch's pool
    address public immutable STRATEGY; // the LBP strategy: the only initializer, and the only registrar while a launch runs
    mapping(PoolId => Window) internal _windows; // each pool's block-start window

    /// @param poolManager_ The v4 PoolManager on this chain.
    /// @param strategy_ The LBP strategy, the only address that may initialize a pool naming this hook.
    constructor(IPoolManager poolManager_, address strategy_) BaseHook(poolManager_) {
        (FACTORY, STRATEGY) = (ILaunchPools(msg.sender), strategy_);
    }

    /// @notice The strategy while the factory is registering a launch, else zero: the strategy registers no distribution naming the hook but a launch's.
    /// @dev A function, not the stock InitializerHook's immutable: that is why this hook restates its sender check instead of inheriting it.
    function authorized() external view returns (address) {
        return FACTORY.launching() ? STRATEGY : address(0);
    }

    /// @notice Before-initialize and before-swap, and nothing else.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        (p.beforeInitialize, p.beforeSwap) = (true, true);
    }

    /// @notice The InitializerHook interface the strategy checks, and ERC-165 itself, as the stock hook answers.
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IInitializerHook).interfaceId || interfaceId == type(IERC165).interfaceId;
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
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != STRATEGY) revert InvalidInitializer(sender, STRATEGY);
        if (block.timestamp > FACTORY.launchByOf(key.toId())) revert NotALaunchPool();
        return IHooks.beforeInitialize.selector;
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
