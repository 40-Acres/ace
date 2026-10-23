// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LaunchFixture} from "./LaunchFixture.sol";
import {NotExpired} from "../../src/ace/hub/Settlement.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";

/// @title LockAccountCapacity
/// @notice B1, C1 and D2: the capacity rule against the real hub, on a recordless launch market whose lender is the beneficiary's own wallet.
/// @dev The buyer schedule vests linearly over 30 days from T0 + 1 day, so V(T0 + 7 days) is 6/30 of the allocation.
contract LockAccountCapacityTest is LaunchFixture {
    /// @dev V(t) for the fixture's buyer schedule over `total`, computed here rather than read off the account.
    function _vBuyer(uint256 total, uint256 t) internal view returns (uint256) {
        uint256 start = T0 + 1 days;
        if (t < start) return 0;
        if (t >= start + 30 days) return total;
        return total * (t - start) / 30 days;
    }

    // ---- B1: the alt-wallet lender ----

    /// @notice A pledge past what vests by the loan's own expiry is refused, at the first atom over.
    function test_B1_PledgePastVestedAtExpiryReverts() public {
        uint256 cap = _vBuyer(ALLOC, T0 + WEEK);
        assertEq(cap, ALLOC * 6 / 30, "fixture: six of thirty days vest by the week's end");
        vm.prank(alice);
        vm.expectRevert(LockAccount.OverCapacity.selector);
        acct.borrow(id, cap + 1, _maxPrincipal(cap), WEEK, _noBounds());
    }

    /// @notice Exactly what vests by expiry opens, and the ledger books it against that expiry.
    function test_B1_PledgeAtExactlyVestedAtExpiryOpens() public {
        uint256 cap = _vBuyer(ALLOC, T0 + WEEK);
        uint256 loanId = _borrow(cap, _maxPrincipal(cap), WEEK);
        (uint256 units, uint64 expiry) = acct.pledgeOf(loanId);
        assertEq(units, cap, "the pledge is booked at its units");
        assertEq(expiry, read.loan(loanId).expiry, "and at the hub's own expiry");
        assertEq(acct.pledged(), cap, "pledged carries it");
        assertEq(ace.borrowerOf(loanId), address(acct), "the account holds title");
    }

    /// @notice The bypass, run end to end: alice walks, her own second wallet collects, and it gets no more than V(E).
    function test_B1_AltWalletLenderTakesNoMoreThanVestedAtExpiry() public {
        uint256 e = T0 + WEEK;
        uint256 cap = _vBuyer(ALLOC, e);
        uint256 loanId = _borrow(cap, _maxPrincipal(cap), WEEK);

        _warpTo(e - 1);
        vm.prank(alt);
        vm.expectRevert(NotExpired.selector); // nothing moves title a second early
        ace.forceClose(loanId);
        assertEq(token.balanceOf(alt), 0, "nothing reached the second wallet before expiry");

        uint256 taken = _default(loanId);
        assertGt(taken, 0, "the default did pay the lender");
        assertLe(taken, _vBuyer(ALLOC, e), "the second wallet took more than had vested at E");
    }

    /// @notice A second pledge is bounded by what the first one left: capacity counts everything already pledged.
    function test_B1_SecondPledgeCountsTheFirst() public {
        uint256 first = _vBuyer(ALLOC, T0 + WEEK);
        _borrow(first, _maxPrincipal(first), WEEK);
        uint64 e2 = uint64(T0 + 2 * WEEK);
        uint256 room = _vBuyer(ALLOC, e2) - first;
        assertEq(acct.capacity(e2), room, "the view states the room left");
        vm.prank(alice);
        vm.expectRevert(LockAccount.OverCapacity.selector);
        acct.borrow(id, room + 1, _maxPrincipal(room), 2 * WEEK, _noBounds());
        _borrow(room, _maxPrincipal(room), 2 * WEEK);
    }

    /// @notice A release counts what is pledged: vested-now less pledged is the whole of it.
    function test_B1_ReleaseCountsPledged() public {
        _warpTo(T0 + 16 days);
        uint256 pledgeUnits = 1_000e18;
        _borrow(pledgeUnits, _maxPrincipal(pledgeUnits), WEEK);
        uint256 room = _vBuyer(ALLOC, T0 + 16 days) - pledgeUnits;
        assertEq(acct.releasable(), room, "the view states it");
        vm.prank(alice);
        vm.expectRevert(LockAccount.OverRelease.selector);
        acct.release(room + 1);
        vm.prank(alice);
        acct.release(room);
        assertEq(token.balanceOf(alice), room, "the release reached the beneficiary");
        assertEq(acct.spent(), room, "and is booked as spent");
    }

    // ---- C1: the curve, the cliff, the books ----

    /// @notice The account's own V(t) is the VestingWalletCliff curve over everything it holds, has pledged and has spent.
    function test_C1_LinearCurve() public view {
        assertEq(acct.vestedAmount(uint64(T0)), 0, "before start");
        assertEq(acct.vestedAmount(uint64(T0 + 1 days)), 0, "at start");
        assertEq(acct.vestedAmount(uint64(T0 + 16 days)), ALLOC / 2, "midway");
        assertEq(acct.vestedAmount(uint64(T0 + 31 days)), ALLOC, "at the end");
        assertEq(acct.vestedAmount(uint64(T0 + 400 days)), ALLOC, "after it");
        assertEq(acct.totalAllocation(), ALLOC, "the allocation is what landed");
        assertEq(acct.capacity(uint64(T0 + WEEK)), ALLOC * 6 / 30, "capacity at E is V(E) before anything is pledged");
    }

    /// @notice A cliff tranche locks every unit until its date: no pledge expiring before it, no release before it.
    function test_C1_CliffTrancheLocksUntilItsDate() public {
        address carol = address(0xCA401);
        LockAccount team = LockAccount(lock.account(carol, TEAM_CLIFF));
        _land(address(team), ALLOC);

        vm.prank(carol);
        vm.expectRevert(LockAccount.OverCapacity.selector);
        team.borrow(id, 1_000e18, _maxPrincipal(1_000e18), 30 days, _noBounds()); // expires T0 + 30d, before the tranche

        _warpTo(T0 + 61 days); // a 30-day loan now expires a day past the tranche
        vm.prank(carol);
        team.borrow(id, ALLOC, _maxPrincipal(ALLOC), 30 days, _noBounds());

        vm.prank(carol);
        vm.expectRevert(LockAccount.OverRelease.selector);
        team.release(1);
    }

    /// @notice The year-long team vest pays nothing inside its 30-day cliff and the linear share at it.
    function test_C1_TeamLinearCliff() public {
        address dave = address(0xDA7E);
        LockAccount team = LockAccount(lock.account(dave, TEAM_LINEAR));
        _land(address(team), ALLOC);
        assertEq(team.vestedAmount(uint64(T0 + 30 days - 1)), 0, "inside the cliff");
        assertEq(team.vestedAmount(uint64(T0 + 30 days)), ALLOC * 29 days / 364 days, "the linear share at the cliff");
        _warpTo(T0 + 30 days);
        vm.prank(dave);
        team.release(ALLOC * 29 days / 364 days);
        assertEq(token.balanceOf(dave), ALLOC * 29 days / 364 days, "released at the cliff");
    }

    /// @notice A partial default: the lender takes the coverage line, the account books the rest back and the gap as spent.
    function test_C1_PartialDefaultBooksTheForfeitAsSpent() public {
        uint256 u = 2_000e18;
        uint256 loanId = _borrow(u, _maxPrincipal(u) / 2, WEEK);
        _default(loanId);
        uint256 owed = read.unitsOwedOf(loanId, address(acct));
        assertGt(owed, 0, "fixture: half a ticket leaves a residual above the line");

        uint256 pre = token.balanceOf(address(acct));
        uint256 landed = acct.reclaim(loanId);
        assertEq(landed, owed, "the residual is what landed");
        assertEq(token.balanceOf(address(acct)) - pre, owed, "and it is in the account");
        assertEq(acct.spent(), u - owed, "the forfeit is booked as spent");
        assertEq(acct.pledged(), 0, "the pledge is retired");
        assertEq(acct.totalAllocation(), ALLOC, "the allocation is unchanged by a default");
    }

    /// @notice Reclaim zeroes its pledge on first use: a second call books nothing and moves nothing.
    function test_C1_ReclaimIsIdempotent() public {
        uint256 u = 1_000e18;
        uint256 loanId = _borrow(u, _maxPrincipal(u), WEEK);
        _repayAll(loanId);
        acct.reclaim(loanId);
        (uint256 spent, uint256 pledged, uint256 bal) = (acct.spent(), acct.pledged(), token.balanceOf(address(acct)));
        assertEq(acct.reclaim(loanId), 0, "a second reclaim lands nothing");
        assertEq(acct.spent(), spent, "spent unchanged");
        assertEq(acct.pledged(), pledged, "pledged unchanged");
        assertEq(token.balanceOf(address(acct)), bal, "balance unchanged");
    }

    /// @notice A live loan cannot be reclaimed, by anyone.
    function test_C1_ReclaimBeforeCloseReverts() public {
        uint256 u = 1_000e18;
        uint256 loanId = _borrow(u, _maxPrincipal(u), WEEK);
        vm.prank(stranger);
        vm.expectRevert(LockAccount.LoanLive.selector);
        acct.reclaim(loanId);
    }

    /// @notice A repaid loan returns every unit; reclaim is permissionless and only ever pays the account.
    function test_C1_RepaidLoanReturnsEveryUnit() public {
        uint256 u = 1_000e18;
        uint256 loanId = _borrow(u, _maxPrincipal(u), WEEK);
        _repayAll(loanId);
        vm.prank(stranger);
        uint256 landed = acct.reclaim(loanId);
        assertEq(landed, u, "every unit came back");
        assertEq(token.balanceOf(address(acct)), ALLOC, "into the account");
        assertEq(acct.spent(), 0, "nothing was forfeited");
        assertEq(acct.pledged(), 0, "nothing is pledged");
    }

    /// @notice A donation only locks more: the locked quantity grows and no capacity shrinks.
    function test_C1_DonationOnlyLocksMore() public {
        _warpTo(T0 + 10 days);
        uint256 u = 1_000e18;
        _borrow(u, _maxPrincipal(u), WEEK);
        uint64 now64 = uint64(_now());
        uint256 lockedBefore = acct.totalAllocation() - acct.vestedAmount(now64);
        uint256 relBefore = acct.releasable();
        uint256 capBefore = acct.capacity(now64 + uint64(WEEK));

        uint256 d = 777e18;
        _land(address(acct), d);

        assertEq(acct.totalAllocation(), ALLOC + d, "the donation is counted");
        assertGe(acct.totalAllocation() - acct.vestedAmount(now64), lockedBefore, "the locked quantity did not fall");
        assertGe(acct.releasable(), relBefore, "releasable did not fall");
        assertLe(acct.releasable() - relBefore, d, "and rose by no more than the donation");
        assertGe(acct.capacity(now64 + uint64(WEEK)), capBefore, "capacity did not fall");
    }

    // ---- D2: what a recordless default takes ----

    /// @notice A recordless default takes the coverage line, not the claim's need, and credits the account the rest.
    function test_D2_RecordlessDefaultTakesTheCoverageLine() public {
        uint256 u = 2_000e18;
        uint256 loanId = _borrow(u, _maxPrincipal(u) / 2, WEEK);
        uint256 line = u - lens.withdrawableUnits(id, loanId);
        uint256 need = lens.collateralNeeded(id, loanId);
        assertGt(line, need, "fixture: the line must exceed the need, or there is no forfeit to see");

        uint256 taken = _default(loanId);
        assertApproxEqAbs(taken, line, 1, "the lender's pot is the coverage line");
        assertEq(read.unitsOwedOf(loanId, address(acct)) + taken, u, "the account is owed the rest, to the atom");
    }
}
