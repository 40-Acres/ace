// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IExtendRefusals
/// @notice The extension refusals the hub raises only as a bare selector, declared here so an ABI carries them and a caller can decode them.
/// @notice `tryExtend` returns either as its reason, and `extend` reverts with it; the hub's own declarations sit in `Borrower.sol`.
interface IExtendRefusals {
    error PolicyRefused(); // the market lender's roll policy did not consent: none set, a revert, or any answer but the selector
    error ExtensionAddsNoTime(); // the loan's own tenor from now ends no later than it already does
}
