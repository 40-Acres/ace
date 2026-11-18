// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultCaps} from "./AceVaultCaps.sol";
import {AceVaultFlows} from "./AceVaultFlows.sol";
import {AceVaultInKind} from "./AceVaultInKind.sol";

/// @title AceVaultMunged
/// @notice PROVER COPY ONLY: scripts/certora-munge-vault.sh writes it into the munged tree, never into src.
/// @notice It is the vault's forward as typed internal calls: the verb the selector names, in the library the vault named, on the vault's storage.
/// @dev It first stashes the vault's five suffix words in transient storage, where the copy's AceVaultTail reads them.
/// @dev The words are never cleared: they are the vault's constants, the same on every dispatch, so a stale read equals a fresh one.
library AceVaultMunged {
    uint256 internal constant SLOT = 0xd1441af45b27613188b5d9a7dc0ea3f4aeef1fb960ef8c3a120619d445c13b00; // erc7201:ace.certora.munged.tail, transient

    bytes4 private constant SUBMIT_CAP = bytes4(keccak256("submitCap(address,uint192)"));
    bytes4 private constant SUBMIT_DELIST = bytes4(keccak256("submitDelist(address)"));
    bytes4 private constant ACCEPT_CAP = bytes4(keccak256("acceptCap(address)"));
    bytes4 private constant REVOKE_PENDING_CAP = bytes4(keccak256("revokePendingCap(address)"));
    bytes4 private constant COLLECT = bytes4(keccak256("collectForfeited(uint256[])"));
    bytes4 private constant CLAIM = bytes4(keccak256("claim(address[],address)"));
    bytes4 private constant RETURN_PROCEEDS = bytes4(keccak256("returnProceeds(address,uint256,bool)"));
    bytes4 private constant SUBMIT_WRITE_OFF = bytes4(keccak256("submitWriteOff(address)"));
    bytes4 private constant ACCEPT_WRITE_OFF = bytes4(keccak256("acceptWriteOff(address)"));
    bytes4 private constant REVOKE_WRITE_OFF = bytes4(keccak256("revokeWriteOff(address)"));
    bytes4 private constant EXTEND_FOR = bytes4(keccak256("extendFor(uint256,uint256,uint256,bytes,bytes)"));
    bytes4 private constant REFINANCE_FOR = bytes4(keccak256("refinanceFor(uint256,address,uint256,uint64,uint256,uint256,uint64,uint256,address,bytes)"));
    bytes4 private constant DRAW_MORE_FOR = bytes4(keccak256("drawMoreFor(uint256,uint256,uint256,uint256,uint64,bytes)"));

    error NoForward(); // the copy has no forward for this selector into this library, so the deployed vault would not reach here either

    /// @notice `refinanceFor`'s nine static head words, which a static struct decodes in the same places as the flat arguments.
    struct RefinanceArgs {
        uint256 loanId;
        address collateral;
        uint256 principal;
        uint64 tenor;
        uint256 minPayout;
        uint256 minBufferWad;
        uint64 deadline;
        uint256 withdrawUnits;
        address withdrawTo;
    }

    /// @notice Run the verb this call's selector names in `lib`, as the deployed vault's DELEGATECALL into `lib` would, and answer its return data.
    function forward(address lib, bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3, bytes32 w4) internal returns (bytes memory) {
        assembly ("memory-safe") {
            tstore(SLOT, w0)
            tstore(add(SLOT, 1), w1)
            tstore(add(SLOT, 2), w2)
            tstore(add(SLOT, 3), w3)
            tstore(add(SLOT, 4), w4)
        }
        bytes4 s = msg.sig;
        if (lib == address(AceVaultCaps)) return _caps(s);
        if (lib == address(AceVaultInKind)) return _inKind(s);
        if (lib == address(AceVaultFlows)) return _flows(s);
        revert NoForward();
    }

    function _caps(bytes4 s) private returns (bytes memory) {
        if (s == SUBMIT_CAP) {
            (address key, uint192 cap) = abi.decode(msg.data[4:], (address, uint192));
            AceVaultCaps.submitCap(key, cap);
        } else if (s == SUBMIT_DELIST) {
            AceVaultCaps.submitDelist(abi.decode(msg.data[4:], (address)));
        } else if (s == ACCEPT_CAP) {
            AceVaultCaps.acceptCap(abi.decode(msg.data[4:], (address)));
        } else if (s == REVOKE_PENDING_CAP) {
            AceVaultCaps.revokePendingCap(abi.decode(msg.data[4:], (address)));
        } else {
            revert NoForward();
        }
        return "";
    }

    function _inKind(bytes4 s) private returns (bytes memory) {
        if (s == COLLECT) return abi.encode(AceVaultInKind.collectForfeited(abi.decode(msg.data[4:], (uint256[]))));
        if (s == CLAIM) {
            (address[] memory tokens, address to) = abi.decode(msg.data[4:], (address[], address));
            return abi.encode(AceVaultInKind.claim(tokens, to));
        }
        revert NoForward();
    }

    function _flows(bytes4 s) private returns (bytes memory) {
        if (s == COLLECT) return abi.encode(AceVaultFlows.collectForfeited(abi.decode(msg.data[4:], (uint256[]))));
        if (s == RETURN_PROCEEDS) {
            (address c, uint256 cash, bool closes) = abi.decode(msg.data[4:], (address, uint256, bool));
            AceVaultFlows.returnProceeds(c, cash, closes);
        } else if (s == SUBMIT_WRITE_OFF) {
            AceVaultFlows.submitWriteOff(abi.decode(msg.data[4:], (address)));
        } else if (s == ACCEPT_WRITE_OFF) {
            AceVaultFlows.acceptWriteOff(abi.decode(msg.data[4:], (address)));
        } else if (s == REVOKE_WRITE_OFF) {
            AceVaultFlows.revokeWriteOff(abi.decode(msg.data[4:], (address)));
        } else if (s == EXTEND_FOR) {
            return _extendFor();
        } else if (s == REFINANCE_FOR) {
            return _refinanceFor();
        } else if (s == DRAW_MORE_FOR) {
            return _drawMoreFor();
        } else {
            revert NoForward();
        }
        return "";
    }

    /// @dev `extendFor`'s three words, then its two `bytes` as slices of msg.data, which the vault's decoder already bounded.
    function _extendFor() private returns (bytes memory) {
        (uint256 loanId, uint256 maxFee, uint256 minBufferWad) = abi.decode(msg.data[4:100], (uint256, uint256, uint256));
        return abi.encode(AceVaultFlows.extendFor(loanId, maxFee, minBufferWad, _bytesArg(3), _bytesArg(4)));
    }

    /// @dev `refinanceFor`'s nine head words, then its `bytes` as a slice of msg.data, which the vault's decoder already bounded.
    function _refinanceFor() private returns (bytes memory) {
        RefinanceArgs memory a = abi.decode(msg.data[4:292], (RefinanceArgs));
        (uint256 newId, uint256 out) = AceVaultFlows.refinanceFor(
            a.loanId, a.collateral, a.principal, a.tenor, a.minPayout, a.minBufferWad, a.deadline, a.withdrawUnits, a.withdrawTo, _bytesArg(9)
        );
        return abi.encode(newId, out);
    }

    /// @dev `drawMoreFor`'s five head words, then its `bytes` as a slice of msg.data, which the vault's decoder already bounded.
    function _drawMoreFor() private returns (bytes memory) {
        (uint256 loanId, uint256 amount, uint256 minPayout, uint256 minBufferWad, uint64 deadline) =
            abi.decode(msg.data[4:164], (uint256, uint256, uint256, uint256, uint64));
        return abi.encode(AceVaultFlows.drawMoreFor(loanId, amount, minPayout, minBufferWad, deadline, _bytesArg(5)));
    }

    /// @dev Argument `i` of this call, a `bytes`, as the calldata slice the ABI places it at.
    function _bytesArg(uint256 i) private pure returns (bytes calldata b) {
        uint256 at = 4 + uint256(bytes32(msg.data[4 + 32 * i:36 + 32 * i]));
        uint256 len = uint256(bytes32(msg.data[at:at + 32]));
        b = msg.data[at + 32:at + 32 + len];
    }
}
