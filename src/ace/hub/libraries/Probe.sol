// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Constants} from "../Constants.sol";

error PolicyGasShort(); // the caller's limit leaves the roll-policy ask less than its fixed budget past EIP-150's 1/64: resend with more gas

/// @title Probe
/// @notice The hub's shape for asking a creator-chosen contract a one-word question.
/// @notice A borrower's own ERC-1271 wallet is asked through OpenZeppelin's SignatureChecker, which bounds the copy the same way.
/// @notice Bounds the RETURNDATA COPY, never the answer: a return-bomb source cannot inflate the caller's frame.
/// @dev `askWord`'s `ok == false` IS NOT AN ANSWER. It means the call failed, returned short, or the address has no code.
/// @dev NEVER fold `!ok` into an in-band value -- not `false`, and not `0`. Both are real answers elsewhere.
/// @dev A permissive `false` inverts a safety guard; a `0` sentinel inverts an admission gate. Refuse instead.
/// @dev A caller that reverts today on a sick dependency must still revert on `!ok`, by name.
/// @dev `askWord` forwards all gas, so a callee that burns its allowance leaves this frame EIP-150's remainder.
/// @dev `askBool` is the one CONSENT question, where every failure IS the answer no, under a fixed budget it must hand over whole.
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

    /// @notice Ask `target` a yes-or-no question with exactly `gasCap` gas: yes only for a success returning exactly the one word `yes`.
    /// @notice A codeless target, a revert, a short or long return, or any other word is a no; a limit that cannot hand over `gasCap` reverts `PolicyGasShort`.
    /// @dev The code probe runs FIRST and warms the target, so its cold-access charge never lands between the floor check and the opcode.
    /// @dev The floor is the budget past EIP-150's 1/64 plus `POLICY_TAIL`, the gas between the check and the opcode, and is checked LAST.
    /// @param target The contract being asked.
    /// @param data The ABI-encoded call, built before the check so its memory is paid for.
    /// @param gasCap The gas the callee receives.
    /// @param yes The one word that consents.
    /// @return ok Whether the target consented.
    function askBool(address target, bytes memory data, uint256 gasCap, bytes32 yes) internal view returns (bool ok) {
        if (target.code.length == 0) return false;
        uint256 floor = (gasCap * 64 + 62) / 63 + Constants.POLICY_TAIL;
        bytes4 short = PolicyGasShort.selector;
        assembly ("memory-safe") {
            if lt(gas(), floor) {
                mstore(0, short)
                revert(0, 4)
            }
            ok := staticcall(gasCap, target, add(data, 0x20), mload(data), 0, 0x20)
            ok := and(ok, and(eq(returndatasize(), 0x20), eq(mload(0), yes)))
        }
    }
}
