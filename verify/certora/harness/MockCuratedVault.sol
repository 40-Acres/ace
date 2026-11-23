// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultFlows} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {DummyERC20} from "./DummyERC20.sol";

/// @title MockCuratedVault
/// @notice The AceVault as `CuratorTerms` calls it: its keys, its mode, its copies, a cap, raw slot reads, the collect and the return.
/// @notice Every answer is storage the prover sets; `returnProceeds` pulls the named cash from the caller, so cash moves for real.
/// @notice The seized ledger is read the way the vault lays it out: key `c` at `keccak256(abi.encode(c, ROOT + 9))`, the open flag at bit 248.
/// @dev LINKED to the terms' `VAULT` immutable; `cash` is LINKED to the terms' asset.
/// @dev It enforces none of the real vault's door checks, so a rule about the terms reads the terms' own checks alone.
contract MockCuratedVault {
    DummyERC20 public cash; // the asset returnProceeds pulls
    address internal curator; // what CURATOR answers
    address internal guardian; // what GUARDIAN answers
    address internal door; // what DOOR answers
    bool internal inKind; // what IN_KIND answers
    address internal ace; // what ACE answers
    address internal assetAddr; // what asset answers
    uint64 internal minTenor; // what MIN_TENOR answers
    uint64 internal maxTenor; // what MAX_TENOR answers
    mapping(address => uint256) internal caps; // what effectiveCap answers
    mapping(bytes32 => bytes32) internal words; // what extsload answers, slot by slot
    mapping(uint256 => uint256) internal collected; // the units collectForfeited reports for each loan id
    uint256 public returnCount; // how many times returnProceeds ran
    address public lastKey; // the key of the latest return
    uint256 public lastCash; // the cash of the latest return
    bool public lastCloses; // the close flag of the latest return

    function CURATOR() external view returns (address) {
        return curator;
    }

    function GUARDIAN() external view returns (address) {
        return guardian;
    }

    function DOOR() external view returns (address) {
        return door;
    }

    function IN_KIND() external view returns (bool) {
        return inKind;
    }

    function ACE() external view returns (address) {
        return ace;
    }

    function asset() external view returns (address) {
        return assetAddr;
    }

    function MIN_TENOR() external view returns (uint64) {
        return minTenor;
    }

    function MAX_TENOR() external view returns (uint64) {
        return maxTenor;
    }

    /// @notice The stored cap for `collateral`.
    function effectiveCap(address collateral) external view returns (uint256) {
        return caps[collateral];
    }

    /// @notice The stored word at each slot asked.
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory out) {
        out = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            out[i] = words[slots[i]];
        }
    }

    /// @notice The stored units for each id, one answer per id.
    function collectForfeited(uint256[] calldata loanIds) external view returns (uint256[] memory out) {
        out = new uint256[](loanIds.length);
        for (uint256 i; i < loanIds.length; ++i) {
            out[i] = collected[loanIds[i]];
        }
    }

    /// @notice Pull `amount` of the cash from the caller and record the return.
    function returnProceeds(address key, uint256 amount, bool closes) external {
        cash.transferFrom(msg.sender, address(this), amount);
        returnCount += 1;
        (lastKey, lastCash, lastCloses) = (key, amount, closes);
    }

    /// @notice The seized ledger's word for `c`, at the slot the vault's layout gives it, for a spec.
    function seizedWordOf(address c) public view returns (bytes32) {
        return words[keccak256(abi.encode(c, uint256(AceVaultFlows.ROOT) + 9))];
    }

    /// @notice Whether `c`'s key is open, bit 248 of its seized word, for a spec.
    function keyOpenView(address c) external view returns (bool) {
        return (uint256(seizedWordOf(c)) >> 248) & 1 != 0;
    }

    /// @notice `c`'s booked value, bits 0-183 of its seized word, for a spec.
    function bookedView(address c) external view returns (uint256) {
        return uint256(seizedWordOf(c)) & type(uint184).max;
    }

    /// @notice The units the collect reports for `id`, for a spec.
    function collectedView(uint256 id) external view returns (uint256) {
        return collected[id];
    }
}
