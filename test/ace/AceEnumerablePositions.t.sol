// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/// @title AceEnumerablePositionsTest
/// @notice The ERC-721 ENUMERATION half of the title layer, over the one position collection.
/// @notice Each enumerated token is pinned back to `Loan.borrower`, the storage of record it mirrors.
/// @dev `PositionTitleNFT` is `ERC721Enumerable`, so this file pins the surface rather than its absence.
/// @dev Every enumeration selector answers, `supportsInterface(0x780e9d63)` is true, and the indexes agree.
/// @dev I4: `totalSupply()` is wrong as a live-loan count TWICE, so each axis gets its own test.
/// @dev It counts CLOSED loans (nothing is burned) and EVERY market's loans (one collection, global ids).
contract AceEnumerablePositionsTest is WarpClock {
    /// @dev ERC-165 id of IERC721Enumerable.
    bytes4 internal constant ENUMERABLE_ID = 0x780e9d63;

    Ace internal ace;
    PositionTitleNFT internal positions;
    AceReader internal read;
    PositionManager internal positionManager;
    MockPersistenceRecord internal record;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id_;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB0417);
    address internal keeper = address(0xCAFE);

    uint256 constant COLL = 10_000e18;
    uint256 constant PRINCIPAL = 4_500e6;
    uint256 constant FEE_FLOAT = 100e6;

    uint256 internal T2; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3; // one rung up
    uint256 internal T4; // two rungs up

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(vault)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id_) = (d.ace, d.positionManager, d.read, d.id);
        positions = PositionTitleNFT(ace.POSITION_TITLE());

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id_, 5_000e6);
        ace.deposit(id_, 5_000e6);
        ace.deposit(id_, 5_000e6);
        vm.stopPrank();
    }

    function _arm(address who, uint256 mult) internal {
        vault.mint(who, mult * COLL);
        usdc.mint(who, mult * FEE_FLOAT);
        vm.startPrank(who);
        vault.approve(address(positionManager), mult * COLL);
        usdc.approve(address(ace), mult * FEE_FLOAT);
        vm.stopPrank();
    }

    function _open(address who) internal returns (uint256) {
        vm.prank(who);
        return ace.open(id_, COLL, PRINCIPAL, 0, who, OpenBounds(0, 0, 0));
    }

    /// @dev A second market on the SAME hub: different collateral, so a different params hash and id.
    /// @dev Isolation under the singleton is LOGICAL, so it must be exercised rather than assumed.
    function _secondMarket() internal returns (bytes32 id2, MockStakeVault vault2) {
        vault2 = new MockStakeVault(43);
        MockPersistenceRecord record2 = new MockPersistenceRecord(address(usdc), address(vault2));
        record2.setObserved(AceFixtures.px(1e18, address(usdc), address(vault2)));
        record2.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault2)));

        MarketParams memory p2 = AceFixtures.marketParams(address(usdc), address(vault2));
        p2.record = address(record2); // the differentiator: a second pair and its own record hash distinct
        id2 = ace.createMarket(p2);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id2, 5_000e6);
        ace.deposit(id2, 5_000e6);
        ace.deposit(id2, 5_000e6);
        vm.stopPrank();
    }

    // ---- conformance ----

    /// @notice ERC-165: the enumeration interface is advertised alongside base ERC-721 and metadata.
    function test_ERC165_AdvertisesEnumerable() public view {
        assertTrue(positions.supportsInterface(ENUMERABLE_ID), "IERC721Enumerable advertised");
        assertTrue(positions.supportsInterface(0x80ac58cd), "base ERC-721 still advertised");
        assertTrue(positions.supportsInterface(0x5b5e139f), "metadata still advertised");
    }

    // ---- I4, axis one: totalSupply counts CLOSED loans ----

    function test_totalSupply_IncrementsPerOpen() public {
        assertEq(positions.totalSupply(), 0, "no positions before the first open");
        _arm(borrower, 2);
        _open(borrower);
        assertEq(positions.totalSupply(), 1, "one open, one position");
        _open(borrower);
        assertEq(positions.totalSupply(), 2, "two opens, two positions");
    }

    function test_totalSupply_SurvivesACleanClose() public {
        _arm(borrower, 1);
        uint256 id = _open(borrower);
        uint256 debt = read.loan(id).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(id, debt);
        vm.stopPrank();

        assertTrue(ace.isClosed(id), "the loan is closed");
        assertEq(positions.totalSupply(), 1, "totalSupply counts CLOSED loans: nothing is ever burned");
    }

    function test_totalSupply_SurvivesFinalizeAndForceClose() public {
        _arm(borrower, 2);
        uint256 idA = _open(borrower);
        uint256 idB = _open(borrower);

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(idA);
        record.setBelow(false);

        _warpBy(30 days + 1);
        vm.prank(keeper);
        ace.forceClose(idB);

        assertTrue(ace.isClosed(idA) && ace.isClosed(idB), "both closed");
        assertEq(positions.totalSupply(), 2, "settlement burns nothing either");
    }

    // ---- I4, axis two: totalSupply is GLOBAL, not per-market ----

    /// @notice The half of I4 a single-market fixture cannot see: one collection serves every market.
    /// @dev Loan ids are global, so `totalSupply()` is no more "this market's loans" than "open loans".
    function test_totalSupply_IsGlobalAcrossMarkets() public {
        (bytes32 id2, MockStakeVault vault2) = _secondMarket();

        _arm(borrower, 1);
        _open(borrower);

        vault2.mint(borrower, COLL);
        usdc.mint(borrower, FEE_FLOAT);
        vm.startPrank(borrower);
        vault2.approve(address(positionManager), COLL);
        usdc.approve(address(ace), FEE_FLOAT);
        ace.open(id2, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        assertEq(positions.totalSupply(), 2, "one collection spans every market on the hub");
    }

    // ---- I5: the enumeration mirrors Loan.borrower, never the reverse ----

    function test_tokenOfOwnerByIndex_AgreesWithBorrowerOf() public {
        _arm(borrower, 3);
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            ids[i] = _open(borrower);
        }

        assertEq(positions.balanceOf(borrower), 3, "three positions on one owner");
        for (uint256 i; i < 3; i++) {
            uint256 tok = positions.tokenOfOwnerByIndex(borrower, i);
            assertEq(ace.borrowerOf(tok), borrower, "every enumerated token answers to the hub's title");
        }
        assertEq(positions.tokenOfOwnerByIndex(borrower, 0), ids[0], "draw order preserved at index 0");
    }

    function test_tokenByIndex_EnumeratesEveryLoan() public {
        _arm(borrower, 2);
        uint256 idA = _open(borrower);
        uint256 idB = _open(borrower);

        assertEq(positions.tokenByIndex(0), idA, "global index 0 is the first loan");
        assertEq(positions.tokenByIndex(1), idB, "global index 1 is the second");
    }

    function test_tokenOfOwnerByIndex_OutOfBounds_Reverts() public {
        _arm(borrower, 1);
        _open(borrower);
        vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, borrower, 1));
        positions.tokenOfOwnerByIndex(borrower, 1);
    }

    /// @notice The global enumeration is bounded too, and it must REVERT rather than answer zero.
    /// @dev A silent zero reads as "loan 0", which is a live id, not a sentinel.
    function test_tokenByIndex_OutOfBounds_Reverts() public {
        _arm(borrower, 1);
        _open(borrower);
        assertEq(positions.totalSupply(), 1, "exactly one token exists");
        vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, address(0), 1));
        positions.tokenByIndex(1);
    }

    /// @notice The empty collection: both enumerations must refuse index 0, not answer it.
    function test_tokenByIndex_OnAnEmptyCollection_Reverts() public {
        assertEq(positions.totalSupply(), 0, "nothing minted yet");
        vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, address(0), 0));
        positions.tokenByIndex(0);
    }

    function test_tokenOfOwnerByIndex_OnAnEmptyOwner_Reverts() public {
        assertEq(positions.balanceOf(buyer), 0, "this address holds nothing");
        vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, buyer, 0));
        positions.tokenOfOwnerByIndex(buyer, 0);
    }

    /// @notice I5 where the per-owner index and the global index genuinely DIVERGE.
    /// @dev The existing owner test opens three loans for ONE borrower, so the two indexes coincide.
    /// @dev An implementation confusing them would pass it; interleaving two owners breaks the tie.
    function test_tokenOfOwnerByIndex_InterleavedOwners_DivergeFromGlobalIndex() public {
        usdc.mint(alice, 10_000e6); // four draws outrun the fixture's ladder; top it up rather than open fewer
        vm.startPrank(alice);
        usdc.approve(address(ace), 10_000e6);
        ace.deposit(id_, 10_000e6);
        vm.stopPrank();

        _arm(borrower, 2);
        _arm(buyer, 2);

        uint256 b0 = _open(borrower);
        uint256 y0 = _open(buyer);
        uint256 b1 = _open(borrower);
        uint256 y1 = _open(buyer);

        assertEq(positions.balanceOf(borrower), 2, "two on the borrower");
        assertEq(positions.balanceOf(buyer), 2, "two on the buyer");

        assertEq(positions.tokenOfOwnerByIndex(borrower, 0), b0, "borrower's own index 0");
        assertEq(positions.tokenOfOwnerByIndex(borrower, 1), b1, "borrower's index 1 skips the buyer's token");
        assertEq(positions.tokenOfOwnerByIndex(buyer, 0), y0, "buyer's own index 0");
        assertEq(positions.tokenOfOwnerByIndex(buyer, 1), y1, "buyer's own index 1");

        assertEq(positions.tokenByIndex(1), y0, "global index 1 is the OTHER owner's token");
        assertTrue(positions.tokenOfOwnerByIndex(borrower, 1) != positions.tokenByIndex(1), "the two indexes differ");

        for (uint256 i; i < 4; i++) {
            uint256 tok = positions.tokenByIndex(i);
            assertEq(ace.borrowerOf(tok), positions.ownerOf(tok), "I5 holds at every global index");
        }
    }

    /// @notice Opening in another's name: the operator funds and is paid, the BORROWER is titled.
    /// @dev `Borrower.open` mints to `a.borrower`, never to `msg.sender`.
    /// @dev Minting to the caller would hand an operator a transferable claim on someone's position.
    function test_open_OnBehalfOf_MintsToTheBorrower_NotTheOperator() public {
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);

        _arm(alice, 1);
        vm.prank(alice);
        uint256 id = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));

        assertEq(positions.ownerOf(id), borrower, "the position is the borrower's");
        assertEq(ace.borrowerOf(id), borrower, "and so is the hub's title");
        assertEq(positions.balanceOf(borrower), 1, "the borrower enumerates it");
        assertEq(positions.balanceOf(alice), 0, "the operator enumerates nothing");
        assertEq(positions.tokenOfOwnerByIndex(borrower, 0), id, "at the borrower's own index 0");
    }

    /// @notice A CLOSED position is still transferable, and the sale must move both ledgers.
    /// @dev What a closed loan still owes is credited to the CURRENT holder, so title must follow the sale.
    /// @dev A secondary sale that skipped `retitle` would send the residual to the wrong address.
    function test_Transfer_OfAClosedPosition_MovesBothLedgers() public {
        _arm(borrower, 1);
        uint256 id = _open(borrower);
        uint256 debt = read.loan(id).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(id, debt);
        vm.stopPrank();
        assertTrue(ace.isClosed(id), "closed before the sale");

        vm.prank(borrower);
        positions.transferFrom(borrower, buyer, id);

        assertEq(positions.ownerOf(id), buyer, "a closed position still transfers");
        assertEq(ace.borrowerOf(id), buyer, "and the hub retitled with it");
        assertEq(positions.balanceOf(borrower), 0, "seller's enumeration emptied");
        assertEq(positions.tokenOfOwnerByIndex(buyer, 0), id, "buyer enumerates the settled position");
        assertEq(positions.totalSupply(), 1, "still nothing burned");
    }

    /// @notice The two enumerations must agree with each other and with the hub, across markets.
    /// @dev The global walk is the only place a per-owner index leak surfaces as a duplicate.
    function test_GlobalEnumerationCoversEveryOwnerExactlyOnce() public {
        (bytes32 id2, MockStakeVault vault2) = _secondMarket();

        _arm(borrower, 2);
        _arm(buyer, 1);
        _open(borrower);
        _open(buyer);
        _open(borrower);

        vault2.mint(buyer, COLL);
        usdc.mint(buyer, FEE_FLOAT);
        vm.startPrank(buyer);
        vault2.approve(address(positionManager), COLL);
        usdc.approve(address(ace), FEE_FLOAT);
        ace.open(id2, COLL, PRINCIPAL, 0, buyer, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 n = positions.totalSupply();
        assertEq(n, 4, "four positions across two markets and two owners");

        uint256 matched;
        for (uint256 i; i < n; i++) {
            uint256 tok = positions.tokenByIndex(i);
            address o = positions.ownerOf(tok);
            assertEq(ace.borrowerOf(tok), o, "I5 holds for every globally enumerated token");
            bool found;
            for (uint256 j; j < positions.balanceOf(o); j++) {
                if (positions.tokenOfOwnerByIndex(o, j) == tok) found = true;
            }
            assertTrue(found, "every global token appears in its own owner's enumeration");
            // counts the owner-side HIT, not the loop trip: a silent owner mismatch drops the tally
            if (found && (o == borrower || o == buyer)) matched++;
        }
        assertEq(matched, 4, "all four resolved to an expected owner AND back through that owner's index");
        assertEq(positions.balanceOf(borrower) + positions.balanceOf(buyer), n, "and the balances sum to the supply");
    }

    // ---- transfer moves BOTH ledgers, or neither ----

    function test_Transfer_MovesOwnerEnumerationAndHubTitleTogether() public {
        _arm(borrower, 1);
        uint256 id = _open(borrower);

        vm.prank(borrower);
        positions.transferFrom(borrower, buyer, id);

        assertEq(positions.balanceOf(borrower), 0, "seller's enumeration emptied");
        assertEq(positions.balanceOf(buyer), 1, "buyer's enumeration filled");
        assertEq(positions.tokenOfOwnerByIndex(buyer, 0), id, "the buyer enumerates the position");
        assertEq(ace.borrowerOf(id), buyer, "the hub's title moved in the same transaction");
        assertEq(positions.totalSupply(), 1, "a transfer is not a mint");
    }

    /// @notice A self-transfer must not double-count.
    /// @dev OZ guards index writes on `previousOwner != to` and `Ace.retitle` early-returns on `from == to`.
    function test_SelfTransfer_DoesNotCorruptEnumeration() public {
        _arm(borrower, 1);
        uint256 id = _open(borrower);

        vm.prank(borrower);
        positions.transferFrom(borrower, borrower, id);

        assertEq(positions.balanceOf(borrower), 1, "still exactly one");
        assertEq(positions.tokenOfOwnerByIndex(borrower, 0), id, "index intact");
        assertEq(ace.borrowerOf(id), borrower, "title unchanged");
    }

    /// @notice Authorization still runs DEEPEST, so an unauthorized move must reach neither ledger.
    /// @dev `ERC721Enumerable._update` sits between `_checkAuthorized` and the `retitle` call.
    function test_UnauthorizedTransfer_Reverts_AndMovesNeitherLedger() public {
        _arm(borrower, 1);
        uint256 id = _open(borrower);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, buyer, id));
        positions.transferFrom(borrower, buyer, id);

        assertEq(ace.borrowerOf(id), borrower, "hub title untouched by a refused transfer");
        assertEq(positions.tokenOfOwnerByIndex(borrower, 0), id, "enumeration untouched too");
        assertEq(positions.balanceOf(buyer), 0, "and the caller gained nothing");
    }

    /// @notice Enumeration survives a close: the position is still owned, enumerated and tied to the hub's title.
    /// @notice What a settled loan still owes is paid to that holder, so the read must keep answering afterwards.
    function test_EnumerationSurvivesSettlement() public {
        _arm(borrower, 1);
        uint256 id = _open(borrower);
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(id);

        assertEq(positions.tokenOfOwnerByIndex(borrower, 0), id, "a settled position still enumerates");
        assertEq(ace.borrowerOf(id), borrower, "and still answers to its holder");
    }
}
