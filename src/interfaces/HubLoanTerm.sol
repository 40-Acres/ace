// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Storage} from "../ace/hub/Types.sol";

/// @title HubLoanTerm
/// @notice Where the hub keeps a loan's term, and how to read it: one packed word of open time, tenor, expiry and close, 64 bits each.
/// @notice For a contract reading the term through `extsload`, since the hub keeps no view of it; an immutable hub's layout never moves.
library HubLoanTerm {
    uint256 internal constant LOANS = uint256(Storage.BOOK) + 1; // the hub's loans mapping, the loan book's second member
    uint256 internal constant TERM_WORD = 4; // a loan's packed word of open, tenor, expiry and close, 64 bits each

    /// @notice The hub storage slot holding `loanId`'s term word.
    /// @param loanId The loan.
    /// @return The slot to `extsload`.
    function slot(uint256 loanId) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(loanId, LOANS))) + TERM_WORD);
    }

    /// @notice A term word's open time, tenor and expiry; the close, its top 64 bits, is `closedAt`'s.
    /// @param word The word `extsload` returned for the loan's slot.
    /// @return openTime The second the loan's current term opened.
    /// @return tenor The loan's tenor.
    /// @return expiry The second the loan's current term ends.
    function decode(bytes32 word) internal pure returns (uint64 openTime, uint64 tenor, uint64 expiry) {
        uint256 w = uint256(word);
        return (uint64(w), uint64(w >> 64), uint64(w >> 128));
    }

    /// @notice A term word's close: the second the loan closed, zero while it is live.
    /// @param word The word `extsload` returned for the loan's slot.
    /// @return The close second.
    function closedAt(bytes32 word) internal pure returns (uint64) {
        return uint64(uint256(word) >> 192);
    }
}
