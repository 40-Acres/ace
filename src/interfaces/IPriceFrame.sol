// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IPriceFrame
/// @notice The pair-affirmation every directional price source answers; genesis binds against it.
/// @dev The affirming half of IPersistenceRecord, kept separate so genesis can bind orientation on its own.
/// @dev SELF-ASSERTED: it catches wiring mistakes, never malice -- the creator owns the source choice.
interface IPriceFrame {
    function supportsPair(address quote, address collateral) external view returns (bool);
}
