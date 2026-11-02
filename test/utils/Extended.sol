// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Loan} from "../../src/ace/hub/Types.sol";
import {AceReader} from "./AceReader.sol";

/// @notice THE shared detector for "the loan extended": the same id, still live, its expiry later than it was.
/// @notice It replaces every `loanCount() == n + 1` roll check: an extension mints no successor, so a count proves nothing.
/// @dev Reads through `AceReader`, never a guarded view, so it runs anywhere a suite asks it, a hook included.
/// @param read The suite's reader over the hub.
/// @param id The loan.
/// @param expiryBefore The loan's expiry before the act under test.
/// @return Whether `id` extended in place.
function _extended(AceReader read, uint256 id, uint64 expiryBefore) view returns (bool) {
    Loan memory l = read.loan(id);
    return l.market != bytes32(0) && l.closedAt == 0 && l.expiry > expiryBefore;
}
