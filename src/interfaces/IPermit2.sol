// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IPermit2, the SignatureTransfer subset of canonical Permit2 the hub consumes
/// @notice Vendored interface only: the implementation is the immutable contract at the canonical address.
/// @dev AllowanceTransfer is deliberately absent: the hub never holds a standing Permit2 allowance.
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice Spends a SignatureTransfer permit; the signature binds the spender to msg.sender.
    function permitTransferFrom(PermitTransferFrom memory permit, SignatureTransferDetails calldata transferDetails, address owner, bytes calldata signature)
        external;
}
