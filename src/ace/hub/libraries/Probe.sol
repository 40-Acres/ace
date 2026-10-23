// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title Probe
/// @notice The hub's shape for asking a creator-chosen contract a one-word question.
/// @notice A borrower's own ERC-1271 wallet is asked through OpenZeppelin's SignatureChecker, which bounds the copy the same way.
/// @notice Bounds the RETURNDATA COPY, never the answer: a return-bomb source cannot inflate the caller's frame.
/// @dev `ok == false` IS NOT AN ANSWER. It means the call failed, returned short, or the address has no code.
/// @dev NEVER fold `!ok` into an in-band value -- not `false`, and not `0`. Both are real answers elsewhere.
/// @dev A permissive `false` inverts a safety guard; a `0` sentinel inverts an admission gate. Refuse instead.
/// @dev A caller that reverts today on a sick dependency must still revert on `!ok`, by name.
/// @dev Forwards all gas, so a callee that burns its allowance leaves this frame EIP-150's remainder.
/// @dev Prior art for the bound: Nomad's `ExcessivelySafeCall`, Curve's `max_outsize`; this is the one-word static case.
library Probe {
    /// @notice Ask `target` for one word, copying at most 32 bytes of whatever it returns.
    /// @param target The creator-chosen contract being asked.
    /// @param data The ABI-encoded call.
    /// @return ok True only if the call succeeded AND returned at least one word.
    /// @return word The first returned word, zero when `ok` is false.
    function askWord(address target, bytes memory data) internal view returns (bool ok, uint256 word) {
        if (target.code.length == 0) return (false, 0);
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 0x20), mload(data), 0, 0)
            if lt(returndatasize(), 0x20) { ok := 0 }
            if ok {
                returndatacopy(0, 0, 0x20)
                word := mload(0)
            }
        }
    }
}
