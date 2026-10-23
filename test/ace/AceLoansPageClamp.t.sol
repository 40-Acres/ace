// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceLoansPageClampTest
/// @notice The MAX_PAGE ceiling, the one leg of `Lender.slice` no other fixture reaches.
/// @dev Every other suite caps out at five loans, so `take` never approaches 256.
/// @dev Deleting the clamp leaves all of them green; this file exists to make that deletion fail.
/// @dev The clamp is the OOG brake on an immutable hub's read surface: no second chance to add it.
/// @dev Loans here are minDebt-sized: the ceiling is about list length, not loan size.
contract AceLoansPageClampTest is Test {
    /// @dev Mirrors `Lender.MAX_PAGE`, restated so a silent change to the constant fails here.
    uint256 internal constant MAX_PAGE = 256;

    /// @dev Four past the clamp: enough to prove the ceiling bites and that a tail page still walks.
    uint256 internal constant N = 260;

    Ace internal ace;
    AceLens internal lens;
    PositionManager internal positionManager;
    MockPersistenceRecord internal record;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id_;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 constant COLL = 200e18;
    uint256 constant PRINCIPAL = 10e6; // the fixture's minDebt

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
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(vault)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, id_) = (d.ace, d.positionManager, d.id);
        lens = new AceLens(address(ace));

        usdc.mint(alice, 60_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 60_000e6);
        ace.deposit(id_, 20_000e6);
        ace.deposit(id_, 20_000e6);
        ace.deposit(id_, 20_000e6);
        vm.stopPrank();

        vault.mint(borrower, N * COLL);
        usdc.mint(borrower, N * PRINCIPAL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
    }

    function _openMany(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            vm.prank(borrower);
            ids[i] = ace.open(id_, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        }
    }

    /// @notice The ceiling itself: a caller asking for the whole list gets MAX_PAGE and no revert.
    /// @dev The entries must also be the FIRST MAX_PAGE in order.
    /// @dev A clamp that lost its place would return a silently wrong page rather than a short one.
    function test_MaxPage_ClampsAWideRequestAndKeepsItsPlace() public {
        uint256[] memory ids = _openMany(N);
        assertEq(ace.marketLoansLength(id_), N, "the list itself is not clamped");

        uint256[] memory wide = ace.marketLoans(id_, 0, type(uint256).max);
        assertEq(wide.length, MAX_PAGE, "an unbounded ask yields exactly MAX_PAGE");
        for (uint256 i; i < wide.length; i++) {
            assertEq(wide[i], ids[i], "the clamped page is still the head of the list, in order");
        }

        assertEq(ace.marketLoans(id_, 0, MAX_PAGE - 1).length, MAX_PAGE - 1, "under the ceiling, limit rules");
        assertEq(ace.marketLoans(id_, 0, MAX_PAGE).length, MAX_PAGE, "exactly at the ceiling, both agree");
        assertEq(ace.marketLoans(id_, 0, MAX_PAGE + 1).length, MAX_PAGE, "one past it, the ceiling rules");
    }

    /// @notice A clamped page is NOT the end of the list: the hazard the silent clamp creates.
    /// @dev The caller's only honest terminator is `marketLoansLength`.
    /// @dev Resuming at `offset + page.length` must reach the tail rather than stalling.
    function test_MaxPage_ShortPageIsNotTheEnd_TheTailStillWalks() public {
        uint256[] memory ids = _openMany(N);

        uint256 offset;
        uint256 seen;
        while (offset < ace.marketLoansLength(id_)) {
            uint256[] memory page = ace.marketLoans(id_, offset, type(uint256).max);
            assertGt(page.length, 0, "a page inside the list must make progress");
            for (uint256 i; i < page.length; i++) {
                assertEq(page[i], ids[offset + i], "every page lands at its own offset");
                seen++;
            }
            offset += page.length;
        }
        assertEq(seen, N, "the clamped walk still reaches every member exactly once");
        assertEq(ace.marketLoans(id_, MAX_PAGE, type(uint256).max).length, N - MAX_PAGE, "and the tail is short");
    }

    /// @notice The lens inherits the hub's ceiling: it cannot be talked into an unbounded scan.
    /// @dev It reports what it actually examined, never what the caller asked for.
    function test_FundedLoans_CannotScanPastTheHubClamp() public {
        _openMany(N);
        (, uint256 scanned, uint256 next) = lens.fundedLoans(id_, 0, type(uint256).max);
        assertEq(scanned, MAX_PAGE, "the scan window is the hub's page, not the caller's limit");
        assertEq(next, MAX_PAGE, "and nextOffset advances by what was examined");
    }
}
