// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";

/// @title MockPermit2, a SignatureTransfer stand-in with real EIP-712 recovery
/// @notice Enforces deadline, unordered nonces, amount cap and SPENDER BINDING exactly as Permit2 does.
/// @dev Etched at the canonical address; the domain separator is computed live so the etch keeps it right.
contract MockPermit2 is IPermit2 {
    using SafeERC20 for IERC20;

    error SignatureExpired();
    error InvalidNonce();
    error InvalidSigner();
    error InvalidAmount();

    bytes32 public constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 public constant PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)" "TokenPermissions(address token,uint256 amount)"
    );

    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"), keccak256("Permit2"), block.chainid, address(this))
        );
    }

    function permitTransferFrom(PermitTransferFrom memory permit, SignatureTransferDetails calldata transferDetails, address owner, bytes calldata signature)
        external
    {
        if (block.timestamp > permit.deadline) revert SignatureExpired();
        if (transferDetails.requestedAmount > permit.permitted.amount) revert InvalidAmount();
        _useUnorderedNonce(owner, permit.nonce);
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TRANSFER_FROM_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount)),
                msg.sender,
                permit.nonce,
                permit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        (bytes32 r, bytes32 s, uint8 v) = _split(signature);
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != owner) revert InvalidSigner();
        IERC20(permit.permitted.token).safeTransferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }

    function _useUnorderedNonce(address from, uint256 nonce) private {
        uint256 bit = 1 << (nonce & 0xff);
        uint256 flipped = nonceBitmap[from][nonce >> 8] ^= bit;
        if (flipped & bit == 0) revert InvalidNonce();
    }

    function _split(bytes calldata sig) private pure returns (bytes32 r, bytes32 s, uint8 v) {
        if (sig.length != 65) revert InvalidSigner();
        r = bytes32(sig[0:32]);
        s = bytes32(sig[32:64]);
        v = uint8(sig[64]);
    }
}
