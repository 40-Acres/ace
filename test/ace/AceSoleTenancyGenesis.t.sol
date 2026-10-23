// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceSoleTenancyGenesis
/// @notice Every market names ONE lender at genesis, and the hub refuses one that does not.
/// @notice That single fact is what lets the attribution machinery go: `b.cash` IS the lender's balance.
/// @dev WRITTEN FAILING-FIRST: `MarketParams.lender` does not exist yet.
/// @dev The field is APPENDED LAST so no existing field's offset moves; it still changes every market id.
/// @dev Reasoning: the design record and
/// @dev -- the two rulings that made option A the direction.
contract AceSoleTenancyGenesisTest is Test {
    Ace internal ace;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(alice));
        ace = d.ace;
    }

    function _params(address lender) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.lender = lender;
    }

    /// @notice A market naming no lender is refused at genesis: sole tenancy is legislated, never optional.
    /// @dev The whole deletion rests on this rail. Without it the hub must still compile the multi-lender path.
    function test_Genesis_RefusesAMarketWithNoLender() public {
        MarketParams memory p = _params(address(0));
        p.baseBps = 41; // a fresh id, so the refusal is the lender rail and not a duplicate
        vm.expectRevert(bytes("lender required"));
        ace.createMarket(p);
    }

    /// @notice The named lender is readable back off the market, so a vault can verify what it adopted.
    function test_Genesis_NamesTheLenderAndReadsItBack() public {
        MarketParams memory p = _params(bob);
        p.baseBps = 42;
        bytes32 id = ace.createMarket(p);
        assertEq(ace.idToMarketParams(id).lender, bob, "the market carries its one lender");
    }

    /// @notice The lender is IN THE ID PREIMAGE: two markets identical but for their lender are two markets.
    /// @dev Required, not incidental -- outside the preimage they would collide on `keccak256(abi.encode(p))`
    /// @dev and the second creation would revert `MarketExists`, making the field unusable.
    function test_Genesis_TheLenderIsPartOfTheMarketId() public {
        MarketParams memory a = _params(alice);
        a.baseBps = 43;
        MarketParams memory b = _params(bob);
        b.baseBps = 43;
        assertTrue(ace.createMarket(a) != ace.createMarket(b), "two lenders, two markets");
    }
}
