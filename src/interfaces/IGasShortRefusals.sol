// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IGasShortRefusals
/// @notice The two gas refusals the hub raises only from assembly, by selector, declared here so an ABI carries them and a caller can decode them.
/// @notice Each means the caller's gas limit could not hand a capped ask its whole fixed budget: resend with more gas.
interface IGasShortRefusals {
    error PolicyGasShort(); // short of the roll-policy ask's budget, on an extension or a same-market refinance's reuse ask
    error RecordGasShort(); // short of a band-on settlement's price read, on `finalize` or `forceClose`
}
