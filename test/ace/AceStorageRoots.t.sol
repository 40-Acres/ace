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

    /// @notice The fourth root holds the origination share; a root moved onto another's slot reads a share no test would notice.
    function test_ProtocolRoot_MatchesTheFormula() public pure {
        assertEq(Storage.PROTOCOL, _root("ace.storage.protocol"), "erc7201:ace.storage.protocol");
    }

    /// @notice No two roots share a slot, so no namespace can write over another's first member.
    function test_TheFourRootsAreDistinct() public pure {
        bytes32[4] memory r = [Storage.MARKETS, Storage.BOOK, Storage.LENDERS, Storage.PROTOCOL];
        for (uint256 i; i < r.length; ++i) {
            for (uint256 j = i + 1; j < r.length; ++j) {
                assertTrue(r[i] != r[j], "two roots share a slot");
            }
        }
    }
}
