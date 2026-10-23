// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IPersistenceRecord
/// @notice Read surface of a price record, pair-parameterized so one may serve many pairs.
/// @notice A market names its record freely; the record's only obligation to ACE is this interface.
/// @notice THE RECORD OWNS ITS WINDOWS: no answer here takes one, and the hub carries none to pass.
/// @dev THE IMPLEMENTER'S CONTRACT, stated here because ACE cannot verify it from outside.
/// @dev Every answer is quote ATOMS per collateral ATOM at 2^96, for the pair AS PASSED.
/// @dev The pair is ORDERED: (quote, collateral) is a different pair than its inverse.
/// @dev An inverse-held source answers `minPrice` as `1/max(p)`, never as `1/min(p)`.
/// @dev A pair not served must answer `supportsPair` false, and reads on it should revert.
/// @dev The two below-questions are DISTINCT FUNCTIONS even where one body answers both.
/// @dev A source with no persistence layer answers them identically; that is a property of the source, not of ACE.
/// @dev SILENCE IS THE IMPLEMENTER'S CHOICE and ACE constrains it neither way: a dark price channel implies nothing about below-ness.
/// @dev `OracleRecord` drops below-ness with the price; a windowed venue record may keep it off the last print, so a quiet venue still settles.
interface IPersistenceRecord {
    /// @notice Whether this record prices the ORDERED pair (quote per collateral). Genesis refuses false.
    function supportsPair(address quote, address collateral) external view returns (bool);

    /// @notice Whether the price held strictly below `price` for the whole DISTRESS window.
    /// @dev Gates the guards: distress, and the decline channel's band.
    function persistedBelowDistress(address quote, address collateral, uint256 price) external view returns (bool);

    /// @notice Whether the price held strictly below `price` for the whole SETTLE window.
    /// @dev Gates the verb that moves title, so it is the longer patience and never the same question as distress.
    function persistedBelowSettle(address quote, address collateral, uint256 price) external view returns (bool);

    /// @notice The last recorded price; silence leaves it standing. 0 when unfit to referee.
    function lastObserved(address quote, address collateral) external view returns (uint256);

    /// @notice Minimum price observed over the DISTRESS window; 0 when the record cannot answer over it.
    /// @dev Wick-spoof resistant: the draw cap and the deleverage floor size off what HELD, never off a print.
    /// @dev THE ONE NUMBER a decline sale turns on: it admits the crank, sizes it, and IS the floor the keeper pays.
    function minPrice(address quote, address collateral) external view returns (uint256);
}
