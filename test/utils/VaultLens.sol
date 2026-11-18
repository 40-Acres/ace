// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {BorrowRequest, Terms} from "../../src/curator/AceVaultFlows.sol";

/// @title IAceVaultLens
/// @notice The surface of `AceVaultLens`: the door's preview, the in-kind tracker's views and the vault's stored figures, each taking the vault first.
interface IAceVaultLens {
    function previewTerms(address vault, address borrower, BorrowRequest calldata r, bytes calldata data)
        external
        view
        returns (bytes32 id, MarketParams memory mp, Terms memory t);
    function claimable(address vault, address holder, address token) external view returns (uint256);
    function trackedOf(address vault, address holder) external view returns (uint256);
    function trackedSupply(address vault) external view returns (uint256);
    function rewardTokens(address vault) external view returns (address[] memory);
    function requestedShares(address vault) external view returns (uint256);
    function requestOf(address vault, address holder) external view returns (uint256 shares, uint64 expiresAt);
    function capOf(address vault, address key) external view returns (uint192 cap, bool listed);
    function pendingCapOf(address vault, address key) external view returns (uint192 cap, bool listed, uint64 validAt);
    function navHigh(address vault) external view returns (uint256);
    function drawdown(address vault) external view returns (uint256);
    function holds(address vault) external view returns (uint256 exitable, uint256 heldReq);
    function roomOf(address vault, address collateral) external view returns (uint256);
    function seizedOf(address vault, address collateral) external view returns (uint256 value, bool open, uint64 writeOffAt);
    function openSeized(address vault) external view returns (uint256);
}

/// @notice One `AceVaultLens`, built from its artifact, so a suite compiles before the lens's source exists and turns red at deploy.
library VaultLens {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant ARTIFACT = "AceVaultLens.sol:AceVaultLens";

    /// @notice A lens, stateless, for any vault, created from the caller.
    function deploy() internal returns (IAceVaultLens lens) {
        bytes memory code = vm.getCode(ARTIFACT);
        assembly ("memory-safe") {
            lens := create(0, add(code, 0x20), mload(code))
        }
        require(address(lens) != address(0), "VaultLens: the lens did not deploy");
    }
}
