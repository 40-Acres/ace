// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CREATE3} from "../../vendor/solady/CREATE3.sol";
import {HubRatePeriod} from "../interfaces/HubRatePeriod.sol";
import {CapListing, ProductConfig} from "./libraries/AceVaultCaps.sol";
import {VaultConfig} from "./libraries/AceVaultFlows.sol";

/// @title AceVaultFactory
/// @notice Deploys AceVaults from ONE pinned creation code against ONE hub and registers each, so whether a vault runs that code is checkable on chain.
/// @notice A vault's address is CREATE3 over its deployer and a salt the deployer picks: products deploy first against `predict`, and nobody else lands there.
/// @dev The LINKED creation code arrives as calldata, as embedding it would pass EIP-170, so the pin also fixes every library a registered vault calls.
/// @dev `isAceVault` is only as good as this factory instance, since `CODE_HASH` and `HUB` are its constructor's: trust the one a chain's book names.
contract AceVaultFactory {
    using SafeERC20 for IERC20;

    error WrongCode(); // the creation code is not the one this factory pins
    error WrongHub(); // the vault names a hub other than this factory's
    error HubHasNoCode(); // raised by `HubRatePeriod.requirePerYear`

    bytes32 public immutable CODE_HASH; // keccak256 of the linked AceVault creation code every vault here runs
    address public immutable HUB; // the one hub every vault here lends through

    mapping(address vault => bool) public isAceVault; // set only by `deploy`

    /// @notice A vault was deployed from the pinned code and registered.
    event VaultCreated(address indexed vault, address indexed deployer, bytes32 indexed userSalt, address terms);

    /// @param codeHash The hash of the linked creation code every vault here must run.
    /// @param hub The hub every vault here must name.
    constructor(bytes32 codeHash, address hub) {
        HubRatePeriod.requirePerYear(hub); // a hub with no code reverts `HubHasNoCode` there, a hub quoting no year `HubRateNotPerYear`
        (CODE_HASH, HUB) = (codeHash, hub);
    }

    /// @notice Deploy and register one vault at `predict(msg.sender, userSalt)`, its seed pulled from the caller to that address first.
    /// @notice The caller approves this factory for `cfg.seed` of `cfg.asset`; a short allowance or balance deploys nothing.
    /// @param creationCode The vault's linked creation code, which must hash to `CODE_HASH`.
    /// @param cfg The base's write-once config, naming `HUB`.
    /// @param pc The product, whose contracts must already name the predicted address as their vault.
    /// @param caps The caps live from the first block.
    /// @param userSalt Any salt; the address is bound to the caller as well, so no other sender can take it.
    /// @return vault The vault.
    function deploy(
        bytes calldata creationCode,
        VaultConfig calldata cfg,
        ProductConfig calldata pc,
        CapListing[] calldata caps,
        string calldata name,
        string calldata symbol,
        bytes32 userSalt
    ) external returns (address vault) {
        if (keccak256(creationCode) != CODE_HASH) revert WrongCode();
        if (cfg.ace != HUB) revert WrongHub();
        bytes32 salt = _salt(msg.sender, userSalt);
        IERC20(cfg.asset).safeTransferFrom(msg.sender, CREATE3.predictDeterministicAddress(salt), cfg.seed);
        vault = CREATE3.deployDeterministic(abi.encodePacked(creationCode, abi.encode(cfg, pc, caps, name, symbol)), salt);
        isAceVault[vault] = true;
        emit VaultCreated(vault, msg.sender, userSalt, pc.terms);
    }

    /// @notice The address `deploy` lands at for this deployer and salt, so its products can be deployed against it first.
    function predict(address deployer, bytes32 userSalt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(_salt(deployer, userSalt));
    }

    /// @dev The CREATE3 salt, bound to the deployer so a second sender with the same salt lands elsewhere.
    function _salt(address deployer, bytes32 userSalt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, userSalt));
    }
}
