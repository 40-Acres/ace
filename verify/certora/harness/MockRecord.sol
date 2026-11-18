// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockRecord
/// @notice The price record as `SAeroTerms` reads it: one price and one credit flag, both storage the prover sets, read apart or together.
/// @notice The record itself is PROVEN separately, so the terms lane takes it as an input rather than re-deriving it.
/// @dev LINKED, never summarized: the terms read it through `derivedPrice`, `listFloor` and the one read, and every read must answer the same state.
/// @dev A zero price is the DARK record, which is what `derivedPrice` and `listFloor` answer zero on.
contract MockRecord {
    uint256 internal price; // what minPrice answers, zero meaning dark
    bool internal open; // what creditOpen answers
    address public FACTORY; // the wiring the terms' `initialize` checks
    address public QUOTE; // the wiring the terms' `initialize` checks
    uint16 public haircutBps; // the record's three dials, which the terms' `dials()` reads back; no rule constrains them
    uint32 public maxStaleness;
    uint32 public grace;

    /// @notice The windowed minimum, which for the oracle class is the current price.
    /// @return The stored price.
    function minPrice(address, address) external view returns (uint256) {
        return price;
    }

    /// @notice The current price, the same read as `minPrice` for this class.
    /// @return The stored price.
    function lastObserved(address, address) external view returns (uint256) {
        return price;
    }

    /// @notice Whether new credit may open.
    /// @return The stored flag.
    function creditOpen() external view returns (bool) {
        return open;
    }

    /// @notice The price and the credit flag from one read, as the terms ask them on a roll and a new loan.
    /// @return The stored price.
    /// @return The stored flag.
    function minPriceAndCreditOpen(address, address) external view returns (uint256, bool) {
        return (price, open);
    }

    /// @notice Every pair this mock is asked about is one it prices; the terms check the account through their factory.
    /// @return Always true.
    function supportsPair(address, address) external pure returns (bool) {
        return true;
    }

    /// @notice The price a spec compares the terms' bid against.
    /// @return The stored price.
    function priceView() external view returns (uint256) {
        return price;
    }

    /// @notice Whether this mock reports credit open, for a spec reasoning about the door.
    /// @return The stored flag.
    function creditOpenView() external view returns (bool) {
        return open;
    }
}
