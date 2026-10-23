// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {ZeroLimit} from "../../src/ace/lens/AceLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceFundedLoansTest
/// @notice The view that REPLACES the stored loan set that was cut during planning.
/// @notice It scans the market's append-only list and keeps the loans holding a live claim.
/// @dev The cut is the point: a stored index would duplicate `claim`, which carries the amount too.
/// @dev It would also cost draw-path gas on every draw, forever.
/// @dev This file is the evidence the scan genuinely answers the same question.
/// @dev IT WAS `loansAtTick`, and the tick went with the ladder. Everything else here is unchanged: the
/// @dev scan, the self-filtering, and the scanned-is-not-matched pagination contract are all the same view.
contract AceFundedLoansTest is Test {
    Ace internal ace;
    AceLens internal lens;
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
        (ace, positionManager, read, id_) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));

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

    function _repayAll(uint256 loanId) internal {
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    /// @dev The whole list in one window; the fixture stays well under the hub's 256 clamp.
    function _scan() internal view returns (uint256[] memory ids, uint256 scanned) {
        (ids, scanned,) = lens.fundedLoans(id_, 0, 256);
    }

    /// @notice The anchor: the scan returns exactly the loans holding a nonzero claim.
    function test_MatchesTheClaimLedger() public {
        _arm(borrower, 2);
        uint256 idA = _open();
        uint256 idB = _open();
        assertGt(read.claimOf(id_, idA), 0, "the draw really funded");

        (uint256[] memory hits, uint256 scanned) = _scan();
        assertEq(scanned, 2, "both list members were examined");

        uint256 expected;
        if (read.claimOf(id_, idA) != 0) expected++;
        if (read.claimOf(id_, idB) != 0) expected++;
        assertEq(hits.length, expected, "the scan agrees with the claim ledger, loan for loan");
        assertGt(hits.length, 0, "VACUOUS: nothing in the market was funded");
    }

    /// @notice A RETIRED loan matches nothing but is still SCANNED -- the two are different.
    /// @notice Conflating them is how a pager decides it is finished when it is not.
    /// @dev WAS an untouched TICK, which is where an empty-but-scanned member used to come from.
    /// @dev The shape survives at the loan: the list is append-only, so a member can match nothing.
    function test_RetiredLoan_ScansButMatchesNothing() public {
        _arm(borrower, 1);
        uint256 loanId = _open();
        _repayAll(loanId);

        (uint256[] memory hits, uint256 scanned) = _scan();
        assertEq(hits.length, 0, "a retired loan holds no claim, so it matches nothing");
        assertGt(scanned, 0, "but the member was examined: empty result is not end of list");
    }

    /// @notice The append-only list keeps closed loans, so the view must drop them on its own.
    /// @notice It does, for free: a melt zeroes each claim, so the predicate stops matching.
    function test_ClosedLoansSelfFilter() public {
        _arm(borrower, 2);
        uint256 idA = _open();
        _open();

        (uint256[] memory before,) = _scan();
        uint256 hitsBefore = before.length;
        assertGt(hitsBefore, 0, "the tick funds something to begin with");

        uint256 debt = read.loan(idA).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(idA, debt);
        vm.stopPrank();

        (uint256[] memory afterHits, uint256 scanned) = _scan();
        assertEq(scanned, 2, "the closed loan is STILL a list member and still gets scanned");
        assertEq(afterHits.length, hitsBefore - 1, "but it no longer matches: its claim melted to zero");
        for (uint256 i; i < afterHits.length; i++) {
            assertTrue(afterHits[i] != idA, "the repaid loan is gone from the result");
        }
    }

    /// @notice The same self-filtering on the settlement path, which zeroes claims outright.
    function test_SettledLoanSelfFilters() public {
        _arm(borrower, 1);
        uint256 id = _open();

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(id);

        (uint256[] memory hits, uint256 scanned) = _scan();
        assertEq(scanned, 1, "still listed");
        assertEq(hits.length, 0, "settlement zeroed the claims, so nothing matches");
    }

    /// @notice Paging semantics: `scanned` advances the walk, NOT the result length.
    /// @notice A window that matches nothing still made progress; only `scanned == 0` means done.
    function test_Paging_ScannedDrivesProgress_NotResultLength() public {
        _arm(borrower, 3);
        uint256 idA = _open();
        _open();
        _open();

        uint256 offset;
        uint256 totalScanned;
        uint256 totalHits;
        while (true) {
            (uint256[] memory hits, uint256 scanned, uint256 next) = lens.fundedLoans(id_, offset, 1);
            if (scanned == 0) break;
            assertEq(next, offset + scanned, "nextOffset is offset plus what was examined");
            totalScanned += scanned;
            totalHits += hits.length;
            offset = next;
        }
        assertEq(totalScanned, 3, "a one-at-a-time walk examines every member exactly once");
        (uint256[] memory wide,) = _scan();
        assertEq(totalHits, wide.length, "and finds the same matches as a single wide window");
    }

    /// @dev True iff the loan's own funded-tick ARRAY names `t`.
    /// @dev A different storage structure from the `claim` mapping the two `claimAt` readers walk.
    /// @notice The anchor rebuilt on IDS rather than a count, against every member of the hub's own list.
    /// @dev `test_MatchesTheClaimLedger` compares only LENGTHS, so a scan returning the wrong ids satisfies it.
    /// @dev This walks `Ace.marketLoans` -- the hub's list, not the lens's copy of the predicate -- and asserts
    /// @dev membership BOTH WAYS loan by loan: every funded member present, every retired one absent.
    /// @dev WAS a cross-check against the per-loan funded-tick ARRAY, a different storage structure from the
    /// @dev `claim` mapping the view reads. That array is gone, so the independent ledger is the hub's list.
    function test_MatchesTheHubList_ByIdInBothDirections() public {
        _arm(borrower, 3);
        uint256 idA = _open();
        uint256 idB = _open();
        uint256 idC = _open();
        _repayAll(idB); // so the walk has a member on BOTH sides of the predicate

        uint256[] memory members = ace.marketLoans(id_, 0, 256);
        assertEq(members.length, 3, "three list members to check against");

        (uint256[] memory hits, uint256 scanned) = _scan();
        assertEq(scanned, 3, "every member was examined");

        uint256 asserted;
        for (uint256 i; i < members.length; i++) {
            bool inResult;
            for (uint256 j; j < hits.length; j++) {
                if (hits[j] == members[i]) inResult = true;
            }
            assertEq(inResult, read.claimOf(id_, members[i]) != 0, "scan membership matches the claim ledger");
            asserted++;
        }
        assertEq(asserted, 3, "VACUOUS: no loan was checked");
        assertEq(hits.length, 2, "and the retired member really was dropped, so both directions were exercised");
        assertTrue(idB != idA && idC != idA, "the ids are distinct, so this is not one loan checked thrice");
    }

    /// @notice `limit == 0` is REFUSED, because the hub and the lens read it oppositely.
    /// @dev INVERTED 2026-08-16 from `test_ZeroLimit_ReadsAsAFullPage_NotAsTheEnd`.
    /// @dev Same concern: a defaulted limit must never be mistaken for the `scanned == 0` terminator.
    /// @dev `Ace.marketLoans` answers 0 with an EMPTY page, so a silent full-page read here diverged.
    /// @dev Refusing is the only reading that cannot forge "done" through either door.
    function test_ZeroLimit_IsRefusedRatherThanGuessed() public {
        _arm(borrower, 2);
        uint256 idA = _open();
        _open();

        vm.expectRevert(ZeroLimit.selector);
        lens.fundedLoans(id_, 0, 0);

        (uint256[] memory wide,) = _scan();
        assertGt(wide.length, 0, "VACUOUS: the chosen tick funded nothing");
    }

    /// @notice The walk must HONOUR the limit, not merely make progress with it.
    /// @dev A view ignoring `limit` still terminates and still totals correctly.
    /// @dev So the totals in `test_Paging_ScannedDrivesProgress_NotResultLength` cannot see it.
    /// @dev Counting the steps and bounding each `scanned` can.
    function test_Paging_HonoursTheLimit_OneMemberPerStep() public {
        _arm(borrower, 3);
        uint256 idA = _open();
        _open();
        _open();

        uint256 offset;
        uint256 steps;
        while (true) {
            (, uint256 scanned, uint256 next) = lens.fundedLoans(id_, offset, 1);
            if (scanned == 0) break;
            assertLe(scanned, 1, "a limit of one may never examine more than one member");
            steps++;
            offset = next;
            assertLt(steps, 10, "the walk must terminate, not spin");
        }
        assertEq(steps, 3, "three members at one per step is exactly three steps");
    }

    /// @notice Past the end scans nothing, which is the only end-of-list signal callers may trust.
    function test_OffsetPastEnd_ScansNothing() public {
        _arm(borrower, 1);
        _open();
        (uint256[] memory hits, uint256 scanned, uint256 next) = lens.fundedLoans(id_, 99, 10);
        assertEq(hits.length, 0, "nothing matched");
        assertEq(scanned, 0, "and nothing was examined: this is the end-of-list signal");
        assertEq(next, 99, "nextOffset does not advance past the end");
    }
}
