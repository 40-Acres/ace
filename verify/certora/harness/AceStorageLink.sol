// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Lenders, LoanBook, Markets} from "../../../src/ace/hub/Types.sol";

/// @title AceStorageLink
/// @notice Gives the prover names for the hub's three ERC-7201 roots, so a spec can hook their fields.
/// @notice The hub declares them on FILE-LEVEL structs, where the prover's annotation scan does not reach.
/// @notice Each slot is the constant `Storage` in Types.sol uses; a wrong one would hook the wrong words.
/// @dev Never deployed and never called: a conf's `storage_extension_harnesses` maps it onto the hub.
contract AceStorageLink {
    // forgefmt: disable-start
    /** @custom:certoralink 0x4030e81e32d47a504b7bed6a68d304bb4225c2a178237499266df5bb9e2a6400 */
    Markets markets;

    /** @custom:certoralink 0x5967bc156a810f41a39d095ae4d338aca94a8ee479836018170c1fc64c743a00 */
    LoanBook book;

    /** @custom:certoralink 0x6bd405d8488bcf8aea88b86961ffb3be4d6d2f3e4b297dab758f37bb87f80c00 */
    Lenders lenders;
    // forgefmt: disable-end
}
