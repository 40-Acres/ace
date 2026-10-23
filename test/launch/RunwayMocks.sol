// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MigratorParameters} from "../../src/interfaces/ILaunchAuction.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";

/// @notice The salt that lands a Runway hook, deployed by `deployer`, at an address carrying exactly the before-initialize and before-swap bits.
/// @dev HookMiner re-hashes the creation code every try; this hashes it once, so a fixture can mine in every setUp.
library RunwaySalt {
    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG; // the hook's two permission bits

    function mine(address deployer, address poolManager, address strategy) internal pure returns (bytes32) {
        bytes32 initHash = keccak256(abi.encodePacked(type(RunwayHook).creationCode, abi.encode(poolManager, strategy)));
        for (uint256 s;; ++s) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, s, initHash)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == FLAGS) return bytes32(s);
        }
    }

    /// @notice Where `deployer` lands a Runway hook on these args with `salt`.
    function hookAt(address deployer, bytes32 salt, address poolManager, address strategy) internal pure returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(RunwayHook).creationCode, abi.encode(poolManager, strategy)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
    }
}

/// @notice A settable stand-in for the LBP strategy, for the UNIT rows: what the factory reads, and a distribution that pulls as the real one does.
/// @dev It is its own auction factory: the oracle names the auction the next distribution registers, unless a row points it elsewhere.
/// @dev The knobs make it misbehave one way at a time: pull short, hand some back, register another token, or name another auction.
contract MockRunwayStrategy {
    mapping(address => MigratorParameters) internal _params;
    address public positionManager; // the PositionManager the factory reads the PoolManager from
    address public nextAuction; // the auction the next distribution registers
    address public oracleSays; // nonzero: the auction the oracle names instead of `nextAuction`
    uint256 public shortBy; // the pull falls this far short of the amount
    uint256 public giveBack; // returned to the caller after the pull
    address public registerAs; // nonzero: the token the registration names instead of the one pulled
    bytes public lastConfig; // the last distribution's configData, for a row to decode
    uint256 public lastAmount;
    bytes32 public lastSalt;
    uint256 public distributions;

    constructor(address posm) {
        positionManager = posm;
    }

    function initializerFactory() external view returns (address) {
        return address(this);
    }

    function getAddress(address, uint256, bytes calldata, bytes32, address) external view returns (address) {
        return oracleSays == address(0) ? nextAuction : oracleSays;
    }

    function setNext(address auction) external {
        nextAuction = auction;
    }

    function setOracle(address auction) external {
        oracleSays = auction;
    }

    function misbehave(uint256 short, uint256 back, address asToken) external {
        (shortBy, giveBack, registerAs) = (short, back, asToken);
    }

    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32 salt) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount - shortBy);
        if (giveBack != 0) IERC20(token).transfer(msg.sender, giveBack);
        (MigratorParameters memory m,) = abi.decode(configData, (MigratorParameters, bytes));
        m.token = registerAs == address(0) ? token : registerAs;
        _params[nextAuction] = m;
        (lastConfig, lastAmount, lastSalt) = (configData, amount, salt);
        ++distributions;
    }

    function initializers(address auction) external view returns (MigratorParameters memory) {
        return _params[auction];
    }

    /// @notice Open `key` at `sqrtPriceX96` as the strategy's migration does, so the hook sees the strategy as the sender.
    function openPool(PoolKey calldata key, uint160 sqrtPriceX96) external {
        MockPositions(positionManager).poolManager().initialize(key, sqrtPriceX96);
    }

    /// @notice Hand `amount` of a token it holds to `to`, as a migration hands its recipient the reserve's leftover.
    function send(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}

/// @notice A stand-in for v4's PositionManager: the PoolManager its pools live in, a position's pool, and a fee collection that pays set amounts.
/// @dev Its collection refuses any shape but DECREASE_LIQUIDITY by zero then two TAKEs, and pays each TAKE's recipient what `feeOf` holds for it.
contract MockPositions {
    IPoolManager public poolManager;
    mapping(uint256 => PoolKey) internal _keys;
    mapping(address => uint256) public feeOf; // what the next collection pays out in each currency, from this mock's own balance
    uint256 public collections;

    constructor(IPoolManager pm) {
        poolManager = pm;
    }

    function setPosition(uint256 tokenId, PoolKey calldata key) external {
        _keys[tokenId] = key;
    }

    function setFee(address currency, uint256 amount) external {
        feeOf[currency] = amount;
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256) {
        return (_keys[tokenId], 0);
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        require(actions.length == 3 && uint8(actions[0]) == 0x01 && uint8(actions[1]) == 0x0e && uint8(actions[2]) == 0x0e, "mock: not decrease-take-take");
        (, uint256 liquidity,,,) = abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
        require(liquidity == 0, "mock: the collection moved liquidity");
        for (uint256 i = 1; i < 3; ++i) {
            (address currency, address to,) = abi.decode(params[i], (address, address, uint256));
            uint256 fee = feeOf[currency];
            feeOf[currency] = 0;
            if (fee != 0) IERC20(currency).transfer(to, fee);
        }
        ++collections;
    }
}
