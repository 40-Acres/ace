// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Storage} from "../../src/ace/hub/Types.sol";

/// @title AceStorageRootsTest
/// @notice Pins each ERC-7201 root constant to the formula its namespace id derives it from, so no constant can silently leave the standard derivation.
contract AceStorageRootsTest is Test {
    function _root(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_MarketsRoot_MatchesTheFormula() public pure {
        assertEq(Storage.MARKETS, _root("ace.storage.markets"), "erc7201:ace.storage.markets");
    }

    function test_BookRoot_MatchesTheFormula() public pure {
        assertEq(Storage.BOOK, _root("ace.storage.book"), "erc7201:ace.storage.book");
    }

    /// @dev The THIRD root is `lenders` now, not `receipts`: the receipt ledger went with the ERC-6909 units,
    /// @dev and what took its namespace is the pooled per-(lender, quote) position that replaced them.
    function test_LendersRoot_MatchesTheFormula() public pure {
        assertEq(Storage.LENDERS, _root("ace.storage.lenders"), "erc7201:ace.storage.lenders");
    }
}
