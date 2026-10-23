// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPermit2} from "../../../interfaces/IPermit2.sol";

error NotPermitOwner(); // unreachable from every entry point: binds a future caller that would pass an owner other than msg.sender
error Permit2TokenMismatch(); // the permit names a token other than the one this pull moves
error Permit2Missing(); // no code at the canonical Permit2 address on this chain: fail by name

/// @title Permits, the hub's one Permit2 pull primitive
/// @notice Internal: it deploys nothing of its own.
/// @dev SignatureTransfer only: Permit2 owns nonces, deadline and spender binding; the hub stores nothing.
library Permits {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // canonical on every target chain

    /// @notice Pulls exactly `amount` of `token` from `owner` to the hub by spending a signed permit.
    /// @dev `blob` is abi.encode(PermitTransferFrom, signature); destination and amount are pinned HERE.
    function pull(address token, address owner, uint256 amount, bytes calldata blob) internal {
        if (owner != msg.sender) revert NotPermitOwner();
        if (PERMIT2.code.length == 0) revert Permit2Missing();
        (IPermit2.PermitTransferFrom memory p, bytes memory sig) = abi.decode(blob, (IPermit2.PermitTransferFrom, bytes));
        if (p.permitted.token != token) revert Permit2TokenMismatch();
        IPermit2(PERMIT2).permitTransferFrom(p, IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: amount}), owner, sig);
    }
}
