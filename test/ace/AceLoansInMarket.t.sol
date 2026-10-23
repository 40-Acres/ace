// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceLoansInMarketTest
/// @notice The market's APPEND-ONLY loan list: pushed once at open, never removed, read through a paginated getter that never returns unbounded.
/// @dev MEMBERSHIP IS "EVER OPENED", NOT "LIVE" -- the whole point of the append-only ruling.
/// @dev Removal is what created the desync class: two ledgers to keep in lockstep across a call.
/// @dev It also created the swap-pop page skip, where a close moved the tail past a reader's cursor.
/// @dev With nothing ever removed, an index is stable and membership cannot contradict `Loan.closedAt`.
/// @dev Liveness is a separate `isClosed` read, which is what these tests assert.
contract AceLoansInMarketTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockPersistenceRecord internal record;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id_;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 constant COLL = 10_000e18;
    uint256 constant PRINCIPAL = 4_500e6;
    uint256 constant FEE_FLOAT = 100e6;

    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3; // the rung above T2
    uint256 internal T4; // the rung above T3

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

        usdc.mint(alice, 60_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 60_000e6);
        ace.deposit(id_, 20_000e6);
        ace.deposit(id_, 20_000e6);
        ace.deposit(id_, 20_000e6);
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

    function _open() internal returns (uint256) {
        vm.prank(borrower);
        return ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
    }

    function _repayFully(uint256 id) internal {
        uint256 debt = read.loan(id).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(id, debt);
        vm.stopPrank();
    }

    // ---- I1': appended once at open, keyed to the market that opened it ----

    function test_Open_AppendsToTheList() public {
        assertEq(ace.marketLoansLength(id_), 0, "empty before the first open");
        _arm(borrower, 1);
        uint256 id = _open();

        assertEq(ace.marketLoansLength(id_), 1, "one entry");
        uint256[] memory page = ace.marketLoans(id_, 0, 10);
        assertEq(page.length, 1, "one page entry");
        assertEq(page[0], id, "and it is the loan just opened");
        assertEq(read.loan(id).market, id_, "I1': the entry's loan names this market");
    }

    function test_Open_AppendsInDrawOrder() public {
        _arm(borrower, 3);
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            ids[i] = _open();
        }

        uint256[] memory page = ace.marketLoans(id_, 0, 10);
        assertEq(page.length, 3, "three entries");
        for (uint256 i; i < 3; i++) {
            assertEq(page[i], ids[i], "ids are monotone, so order is draw order");
        }
    }

    // ---- I3': append-only. The list NEVER shrinks, on any close path ----

    function test_CleanClose_LeavesTheEntryInPlace() public {
        _arm(borrower, 1);
        uint256 id = _open();
        _repayFully(id);

        assertTrue(ace.isClosed(id), "repaid to zero closes the loan");
        assertEq(ace.marketLoansLength(id_), 1, "the LIST does not shrink: membership is ever-opened");
        assertEq(ace.marketLoans(id_, 0, 10)[0], id, "and the entry is still at its original index");
    }

    function test_Finalize_LeavesTheEntryInPlace() public {
        _arm(borrower, 1);
        uint256 id = _open();
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(id);

        assertTrue(ace.isClosed(id), "settled");
        assertEq(ace.marketLoansLength(id_), 1, "settlement removes nothing");
    }

    function test_ForceClose_LeavesTheEntryInPlace() public {
        _arm(borrower, 1);
        uint256 id = _open();
        _warpBy(30 days + 1);
        vm.prank(keeper);
        ace.forceClose(id);

        assertTrue(ace.isClosed(id), "backstop closed");
        assertEq(ace.marketLoansLength(id_), 1, "the backstop close removes nothing either");
    }

    /// @notice On an append-only array an entry's index is fixed for the life of the market, so a paginated walk is gap-free by construction.
    /// @notice The page-skip hazard a removable set had is not mitigated here, it is absent.
    function test_I3_IndexIsStableAcrossCloses() public {
        _arm(borrower, 3);
        uint256 idA = _open();
        uint256 idB = _open();
        uint256 idC = _open();

        _repayFully(idA); // close the HEAD: the case swap-pop would have disturbed

        uint256[] memory page = ace.marketLoans(id_, 0, 10);
        assertEq(page.length, 3, "length unchanged by a close");
        assertEq(page[0], idA, "the closed head stayed at index 0");
        assertEq(page[1], idB, "nothing shifted");
        assertEq(page[2], idC, "and nothing moved into a hole, because there is no hole");
    }

    /// @notice The reader's actual flow: page the list, then filter on `isClosed`.
    /// @notice Liveness is a separate read by design -- the list is the index, the flag is the truth.
    function test_LiveLoansAreTheListMinusTheClosed() public {
        _arm(borrower, 3);
        uint256 idA = _open();
        uint256 idB = _open();
        uint256 idC = _open();
        _repayFully(idB);

        uint256[] memory page = ace.marketLoans(id_, 0, 10);
        uint256 live;
        for (uint256 i; i < page.length; i++) {
            if (!ace.isClosed(page[i])) live++;
        }
        assertEq(live, 2, "two of the three are still live");
        assertTrue(ace.isClosed(idB), "and the closed one is the one that was repaid");
        assertTrue(!ace.isClosed(idA) && !ace.isClosed(idC), "the others are untouched");
    }

    // ---- pagination: stable, clamped, never unbounded ----

    function test_Pagination_WalksTheWholeList() public {
        _arm(borrower, 5);
        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            ids[i] = _open();
        }

        assertEq(ace.marketLoansLength(id_), 5, "five entries");
        uint256[] memory p1 = ace.marketLoans(id_, 0, 2);
        uint256[] memory p2 = ace.marketLoans(id_, 2, 2);
        uint256[] memory p3 = ace.marketLoans(id_, 4, 2);
        assertEq(p1.length, 2, "full first page");
        assertEq(p2.length, 2, "full second page");
        assertEq(p3.length, 1, "short final page: the list ran out, not the limit");
        assertEq(p1[0], ids[0], "pages line up with the underlying order");
        assertEq(p3[0], ids[4], "including the tail");
    }

    function test_Pagination_OffsetPastEnd_ReturnsEmpty_NeverReverts() public {
        _arm(borrower, 1);
        _open();
        assertEq(ace.marketLoans(id_, 99, 10).length, 0, "past the end is empty, not a revert");
    }

    function test_Pagination_EmptyList_ReturnsEmpty() public view {
        assertEq(ace.marketLoansLength(id_), 0, "no loans yet");
        assertEq(ace.marketLoans(id_, 0, 10).length, 0, "an empty list pages to nothing");
    }

    /// @notice The cap is silent by design: asking for more than MAX_PAGE yields MAX_PAGE, not a
    /// @dev A short page therefore does NOT mean the end of the list -- `marketLoansLength` does.
    function test_Pagination_LimitIsClampedNotReverted() public {
        _arm(borrower, 3);
        for (uint256 i; i < 3; i++) {
            _open();
        }
        assertEq(ace.marketLoans(id_, 0, type(uint256).max).length, 3, "an absurd limit clamps to what exists");
    }

    /// @notice `limit == 0` is a legal ask that yields nothing.
    /// @notice It is also INDISTINGUISHABLE from past-the-end: both return an empty page.
    /// @dev A pager that derives its terminator from page length alone stops on its first call.
    /// @dev Pinned as behaviour, not endorsed: `marketLoansLength` is the only honest terminator.
    function test_Pagination_ZeroLimit_ReturnsEmpty_AndLooksLikeTheEnd() public {
        _arm(borrower, 3);
        for (uint256 i; i < 3; i++) {
            _open();
        }

        assertEq(ace.marketLoans(id_, 0, 0).length, 0, "a zero limit yields nothing");
        assertEq(ace.marketLoans(id_, 99, 0).length, 0, "and is shaped exactly like past-the-end");
        assertEq(ace.marketLoansLength(id_), 3, "while the list plainly still has three members");
    }

    /// @notice The boundary the past-the-end guard sits on: `offset == length` exactly.
    /// @dev One below must still return a member, or the guard is off by one and hides the tail.
    function test_Pagination_OffsetAtExactlyLength_IsTheFirstEmptyOffset() public {
        _arm(borrower, 3);
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            ids[i] = _open();
        }

        uint256[] memory last = ace.marketLoans(id_, 2, 10);
        assertEq(last.length, 1, "offset length-1 still yields the final member");
        assertEq(last[0], ids[2], "and it is the final member, not some other");
        assertEq(ace.marketLoans(id_, 3, 10).length, 0, "offset == length is the first empty page");
    }

    /// @notice `offset + limit` must never be computed as a sum: at these values it would overflow.
    /// @dev The implementation subtracts instead (`n - offset`), never forming an end index.
    /// @dev This is the guard on anyone rewriting the clamp as `min(offset + limit, n)`.
    function test_Pagination_OffsetPlusLimitOverflows_StillAnswers() public {
        _arm(borrower, 3);
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            ids[i] = _open();
        }

        uint256[] memory tail = ace.marketLoans(id_, 1, type(uint256).max);
        assertEq(tail.length, 2, "offset 1 with a max limit returns the remaining two");
        assertEq(tail[0], ids[1], "starting at the right place");
        assertEq(tail[1], ids[2], "and running to the end");
        assertEq(ace.marketLoans(id_, type(uint256).max, type(uint256).max).length, 0, "max offset is empty");
        assertEq(ace.marketLoans(id_, type(uint256).max, 10).length, 0, "and does not underflow either");
    }

    /// @notice A market id that was never created reads as an empty list rather than reverting.
    /// @dev The hub keys markets by hash with no existence check, so an unknown id hits a zero struct.
    /// @dev A revert here would break a batched multicall over a speculative id set.
    function test_UnknownMarketId_ReadsEmpty_NeverReverts() public {
        _arm(borrower, 1);
        _open();

        bytes32 ghost = keccak256("no such market");
        assertTrue(ghost != id_, "the ghost id is genuinely not the fixture's market");
        assertEq(ace.marketLoansLength(ghost), 0, "an uncreated market has opened nothing");
        assertEq(ace.marketLoans(ghost, 0, 10).length, 0, "and pages to nothing rather than reverting");
        assertEq(ace.marketLoans(ghost, 99, 10).length, 0, "at any offset");
        assertEq(ace.marketLoansLength(id_), 1, "and the real market is unaffected by the lookup");
    }

    // ---- cross-market isolation ----

    /// @notice Isolation under the singleton is LOGICAL, per market id.
    /// @notice No second contract enforces it, and both markets now custody through the SAME positionManager.
    /// @notice So the list must be shown not to leak across markets, never assumed not to.
    function test_TwoMarketsDoNotShareLoanLists() public {
        MockStakeVault vault2 = new MockStakeVault(43);
        MockPersistenceRecord record2 = new MockPersistenceRecord(address(usdc), address(vault2));
        record2.setObserved(AceFixtures.px(1e18, address(usdc), address(vault2)));
        record2.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault2)));

        MarketParams memory p2 = AceFixtures.marketParams(address(usdc), address(vault2));
        p2.record = address(record2); // the differentiator: a second pair and its own record hash distinct
        bytes32 id2 = ace.createMarket(p2);

        usdc.mint(alice, 20_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 20_000e6);
        ace.deposit(id2, 20_000e6);
        vm.stopPrank();

        _arm(borrower, 1);
        uint256 idA = _open();

        vault2.mint(borrower, COLL);
        usdc.mint(borrower, FEE_FLOAT);
        vm.startPrank(borrower);
        vault2.approve(address(positionManager), COLL); // the one positionManager, second collateral
        usdc.approve(address(ace), FEE_FLOAT);
        uint256 idB = ace.open(id2, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        assertEq(ace.marketLoansLength(id_), 1, "market A holds only its own");
        assertEq(ace.marketLoansLength(id2), 1, "market B holds only its own");
        assertEq(ace.marketLoans(id_, 0, 10)[0], idA, "A's list names A's loan");
        assertEq(ace.marketLoans(id2, 0, 10)[0], idB, "B's list names B's loan");
        assertEq(read.loan(idA).market, id_, "and each loan agrees about its market");
        assertEq(read.loan(idB).market, id2, "in both directions");
    }
}
