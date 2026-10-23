// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceMarketParamsShape
/// @notice Pins two facts every market id rests on: the preimage's width, and that the hub answers for no pool.
/// @dev The preimage width is the FIELD count, never the slot count: abi.encode pads every field to a full word.
/// @dev Storage packs the two uint64 tenors and what fits beside them; the hash preimage packs nothing.
/// @dev So the field count and the slot count differ, and reading either number for the other is the trap.
contract AceMarketParamsShapeTest is Test {
    uint256 internal constant PREIMAGE_FIELDS = 19; // MarketParams field count, one encoded word each

    Ace internal ace;

    function setUp() public {
        ace = AceFixtures.newAce();
    }

    /// @notice One word per field is the whole of a market's identity, and it is why every id moves here.
    /// @dev Not tautological: it pins the preimage width independently of any hash pasted into PocMarketsConfig.
    function test_MarketParams_PreimageIsOneWordPerField() public {
        MarketParams memory p;
        assertEq(abi.encode(p).length, PREIMAGE_FIELDS * 32, "market id preimage is one word per field");
    }

    /// @notice The hub answers no PoolManager getter: the coupling is deleted, not merely left unread.
    /// @dev A RAW staticcall on purpose -- a typed call would accept whatever 32 bytes the hub returned.
    function test_Hub_ExposesNoPoolManagerGetter() public {
        (bool ok,) = address(ace).staticcall(abi.encodeWithSignature("POOL_MANAGER()"));
        assertFalse(ok, "hub still answers POOL_MANAGER()");
    }
}
