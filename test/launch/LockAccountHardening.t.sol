// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LaunchFixture, LaunchMarketParams} from "./LaunchFixture.sol";
import {ReenteringQuote} from "./ReenteringQuote.sol";
import {LaunchLock, Schedule} from "../../src/entities/launch/LaunchLock.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";

/// @notice A plain token that withholds a fixed cut from every transfer OUT of one armed address, so a release from custody lands short.
/// @dev The cut is burned, so the sender is debited in full: the custodian's books stay whole and only the recipient sees the shortfall.
contract TaxedFromToken {
    string public name = "Taxed";
    string public symbol = "TAX";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public taxedFrom; // the one sender whose transfers land short
    uint256 public tax; // units withheld, and burned, per transfer out of `taxedFrom`

    function arm(address from, uint256 cut) external {
        (taxedFrom, tax) = (from, cut);
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 cut = from == taxedFrom ? Math.min(tax, amount) : 0;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - cut;
        totalSupply -= cut;
    }
}

/// @title LockAccountHardening
/// @notice The account's edges no other row reaches: the tenor sentinel, the saturating views, the zero release, the cash delta.
/// @notice Short deliveries on both exits, the views' own reentrancy guard, and every event.
/// @notice Plus a fuzzed capacity and release boundary, judged against a curve read off the LOCK's schedule, never off the account.
contract LockAccountHardeningTest is LaunchFixture {
    uint256 internal constant MIN_UNITS = 150e18; // the least that covers a minimum ticket at $0.10 and k = 1.4

    /// @dev V(t) from the lock's own record of schedule `sid`, over `total`: the account's curve is the thing under test.
    function _v(uint256 sid, uint256 total, uint256 t) internal view returns (uint256) {
        Schedule memory s;
        (s.start, s.cliff, s.duration) = lock.schedules(sid);
        if (t < uint256(s.start) + s.cliff) return 0;
        if (t >= uint256(s.start) + s.duration) return total;
        return total * (t - s.start) / s.duration;
    }

    function _borrowFrom(LockAccount a, uint256 units, uint64 tenor) internal returns (uint256) {
        vm.prank(alice);
        return a.borrow(id, units, MIN_DEBT, tenor, _noBounds());
    }

    // ---- borrow ----

    /// @notice A zero tenor is the market's min tenor: the capacity check, the booked expiry and the hub's expiry all use it.
    function test_TenorZeroBooksTheMarketsMinTenor() public {
        uint256 cap = _v(0, ALLOC, T0 + WEEK);
        assertEq(acct.capacity(uint64(T0 + WEEK)), cap, "fixture: capacity at the min tenor");
        vm.prank(alice);
        vm.expectRevert(LockAccount.OverCapacity.selector);
        acct.borrow(id, cap + 1, _maxPrincipal(cap), 0, _noBounds());

        uint256 loanId = _borrow(cap, _maxPrincipal(cap), 0);
        (uint256 units, uint64 expiry) = acct.pledgeOf(loanId);
        assertEq(units, cap, "the pledge is booked at its units");
        assertEq(expiry, T0 + WEEK, "a zero tenor booked something other than the min tenor");
        assertEq(expiry, read.loan(loanId).expiry, "the booked expiry is not the hub's");
    }

    /// @notice A borrow forwards the payout it received and nothing else: quote already waiting in the account stays for the sweep.
    function test_BorrowForwardsOnlyTheNewCash() public {
        usdc.mint(address(acct), 55e6);
        uint256 u = 1_000e18;
        uint256 p = _maxPrincipal(u);
        uint256 loanId = _borrow(u, p, WEEK);
        assertEq(usdc.balanceOf(alice), p - read.loan(loanId).lastFee, "the beneficiary got more or less than the payout");
        assertEq(usdc.balanceOf(address(acct)), 55e6, "the waiting quote was forwarded with the payout");
    }

    /// @notice A borrow says what it booked, and the ledger keeps each loan under its own id, at its own units and expiry.
    function test_BorrowEmitsPledgedAndBooksEachLoanApart() public {
        uint256 u = 1_000e18;
        vm.expectEmit(false, true, false, true, address(acct));
        emit LockAccount.Pledged(0, id, u, uint64(T0 + WEEK));
        uint256 first = _borrow(u, _maxPrincipal(u), WEEK);
        uint256 second = _borrow(MIN_UNITS, MIN_DEBT, 2 * WEEK);
        assertTrue(first != second, "two borrows booked one loan");
        (uint256 u1, uint64 e1) = acct.pledgeOf(first);
        (uint256 u2, uint64 e2) = acct.pledgeOf(second);
        assertEq(abi.encode(u1, e1), abi.encode(u, uint64(T0 + WEEK)), "first loan");
        assertEq(abi.encode(u2, e2), abi.encode(MIN_UNITS, uint64(T0 + 2 * WEEK)), "second loan");
        assertEq(acct.pledged(), u + MIN_UNITS, "the pledged total is not both loans");
    }

    // ---- the views saturate rather than revert ----

    /// @notice A pledge against a later, fully vested expiry leaves no room at an earlier one and nothing releasable now: both read zero.
    function test_CapacityAndReleasableSaturateUnderALaterPledge() public {
        _warpTo(T0 + 16 days);
        assertEq(_v(0, ALLOC, _now()), ALLOC / 2, "fixture: half has vested now");
        _borrow(ALLOC, _maxPrincipal(ALLOC), 30 days); // expires past the curve's end, where V is the whole allocation
        assertEq(acct.releasable(), 0, "releasable is not zero under the later pledge");
        assertEq(acct.capacity(uint64(_now() + WEEK)), 0, "an earlier expiry still shows room");
        vm.prank(alice);
        vm.expectRevert(LockAccount.OverRelease.selector);
        acct.release(1);
        vm.prank(alice);
        vm.expectRevert(LockAccount.OverCapacity.selector);
        acct.borrow(id, MIN_UNITS, MIN_DEBT, WEEK, _noBounds());
    }

    // ---- release ----

    /// @notice A release of nothing is refused by name, even with the whole allocation vested.
    function test_ReleaseOfZeroReverts() public {
        _warpTo(T0 + 31 days);
        vm.prank(alice);
        vm.expectRevert(LockAccount.ZeroAmount.selector);
        acct.release(0);
    }

    /// @notice At the curve's end the whole allocation releases, and a later donation is releasable at once and to the atom.
    function test_ReleaseEverythingThenADonationVestsAtOnce() public {
        _warpTo(T0 + 31 days);
        vm.expectEmit(address(acct));
        emit LockAccount.Released(ALLOC);
        vm.prank(alice);
        acct.release(ALLOC);
        assertEq(token.balanceOf(alice), ALLOC, "the beneficiary did not get the allocation");
        assertEq(acct.spent(), ALLOC, "spent");
        assertEq(acct.totalAllocation(), ALLOC, "total moved on a release");
        assertEq(acct.releasable(), 0, "releasable after everything left");

        _land(address(acct), 7e18);
        assertEq(acct.releasable(), 7e18, "a donation past the end is not releasable at once");
        vm.prank(alice);
        vm.expectRevert(LockAccount.OverRelease.selector);
        acct.release(7e18 + 1);
        vm.prank(alice);
        acct.release(7e18);
        assertEq(token.balanceOf(address(acct)), 0, "the account kept some");
    }

    // ---- the curve at its edges ----

    /// @notice A single tranche is nothing a second before its date and everything AT it, where a release of the whole lands.
    function test_CliffTrancheIsWholeAtExactlyItsDate() public {
        address carol = address(0xCA401);
        LockAccount team = LockAccount(lock.account(carol, TEAM_CLIFF));
        _land(address(team), ALLOC);
        uint64 at = uint64(T0 + 90 days);
        assertEq(team.vestedAmount(at - 1), 0, "a second before the tranche");
        assertEq(team.vestedAmount(at), ALLOC, "the tranche at its date");
        _warpTo(at);
        assertEq(team.releasable(), ALLOC, "releasable at the date");
        vm.prank(carol);
        team.release(ALLOC);
        assertEq(token.balanceOf(carol), ALLOC, "the tranche did not release at its date");
    }

    /// @notice The linear curve rounds DOWN between its ends and reaches the whole allocation exactly at its end.
    function test_LinearCurveFloorsBetweenItsEnds() public view {
        uint64 start = uint64(T0 + 1 days);
        uint64 end = start + 30 days;
        assertEq(acct.vestedAmount(start + 1), ALLOC / 30 days, "one second in, floored");
        assertGt(ALLOC % 30 days, 0, "fixture: the one-second share is not a whole number");
        assertEq(acct.vestedAmount(end - 1), ALLOC * (30 days - 1) / 30 days, "a second before the end, floored");
        assertLt(acct.vestedAmount(end - 1), ALLOC, "the curve was whole before its end");
        assertEq(acct.vestedAmount(end), ALLOC, "the curve is not whole at its end");
    }

    // ---- reclaim ----

    /// @notice A full-ticket default forfeits almost the whole pledge: the forfeit is spent, the residual lands, and total stays whole.
    /// @notice What is left then releases only as the curve allows, net of the forfeit.
    function test_FullTicketDefaultBooksTheForfeitAndEmits() public {
        uint256 u = 2_000e18;
        uint256 loanId = _borrow(u, _maxPrincipal(u), WEEK);
        uint256 taken = _default(loanId);
        uint256 owed = read.unitsOwedOf(loanId, address(acct));
        assertEq(taken + owed, u, "fixture: the pot and the residual are the pledge");
        assertGt(taken, u * 9 / 10, "fixture: a full ticket forfeits most of the pledge");

        uint256 held = token.balanceOf(address(acct));
        assertEq(acct.reclaim(loanId), owed, "landed");
        assertEq(token.balanceOf(address(acct)), held + owed, "the residual did not land in the account");
        (uint256 left,) = acct.pledgeOf(loanId);
        assertEq(left, 0, "the pledge's units were not retired");
        assertEq(acct.spent(), taken, "the forfeit is not booked as spent");
        assertEq(acct.pledged(), 0, "the pledge did not retire");
        assertEq(acct.totalAllocation(), ALLOC, "a default moved the allocation");
        assertEq(acct.releasable(), Math.saturatingSub(_v(0, ALLOC, _now()), taken), "releasable is not V(now) net of the forfeit");
    }

    // ---- short deliveries: a token that lands less than the custodian sent ----

    function _taxedAccount() internal returns (TaxedFromToken tt, LockAccount ta, bytes32 m) {
        tt = new TaxedFromToken();
        LaunchLock tl = _newLock(address(tt));
        ta = LockAccount(tl.account(alice, 0));
        LaunchMarketParams.Ctx memory c = _ctx(address(usdc), alt);
        c.token = address(tt);
        m = ace.createMarket(LaunchMarketParams.launchParams(c));
        _restIn(m, address(usdc), alt, CASH);
        tt.mint(address(ta), ALLOC);
    }

    /// @notice Units booked out of a pledge that land short on the reclaim are spent: total never shrinks.
    function test_ShortDeliveriesAreBookedSpent() public {
        (TaxedFromToken tt, LockAccount ta, bytes32 m) = _taxedAccount();
        uint256 u = 2_000e18;
        vm.prank(alice);
        uint256 loanId = ta.borrow(m, u, _maxPrincipal(u) / 4, WEEK, _noBounds());
        tt.arm(address(pm), 7e18);

        _repayAll(loanId);
        assertEq(ta.reclaim(loanId), u - 7e18, "landed");
        assertEq(tt.balanceOf(address(ta)), ALLOC - 7e18, "fixture: the custodian's release landed seven short");
        assertEq(ta.spent(), 7e18, "a short reclaim is not booked as spent");
        assertEq(ta.pledged(), 0, "the pledge did not retire");
        assertEq(ta.totalAllocation(), ALLOC, "a short reclaim shrank total");
    }

    // ---- sweep ----

    /// @notice A sweep of an empty balance moves nothing and returns zero; a sweep of a balance returns, and pays, what it moved.
    function test_SweepReturnsAndPaysWhatItMoved() public {
        assertEq(acct.sweep(address(usdc)), 0, "an empty sweep moved something");
        assertEq(usdc.balanceOf(alice), 0, "an empty sweep paid the beneficiary");
        usdc.mint(address(acct), 9e6);
        assertEq(acct.sweep(address(usdc)), 9e6, "the sweep returned other than what it moved");
        assertEq(usdc.balanceOf(alice), 9e6, "the sweep did not pay the beneficiary");
        assertEq(usdc.balanceOf(address(acct)), 0, "the sweep left some behind");
    }

    // ---- the views' own guard ----

    /// @notice A quote calling back mid-borrow cannot read any of the four books views: each trips the account's guard.
    function test_ViewsRefuseReentryDuringABorrow() public {
        ReenteringQuote rq = new ReenteringQuote();
        bytes32 m = _market(address(rq), alt);
        _restIn(m, address(rq), alt, CASH);
        uint256 u = 1_000e18;
        uint256 p = _maxPrincipal(u);
        bytes[4] memory peeks = [
            abi.encodeCall(LockAccount.totalAllocation, ()),
            abi.encodeCall(LockAccount.vestedAmount, (uint64(T0 + WEEK))),
            abi.encodeCall(LockAccount.releasable, ()),
            abi.encodeCall(LockAccount.capacity, (uint64(T0 + WEEK)))
        ];
        for (uint256 i; i < peeks.length; ++i) {
            rq.arm(address(acct), peeks[i]);
            vm.prank(alice);
            vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
            acct.borrow(m, u, p, WEEK, _noBounds());
        }
        rq.arm(address(0), "");
        vm.prank(alice);
        acct.borrow(m, u, p, WEEK, _noBounds());
        assertEq(acct.pledged(), u, "fixture: unarmed, the borrow lands");
    }

    // ---- the implementation ----

    /// @notice The account implementation answers no verb: its code carries no clone args, so even a sweep of a stray donation reverts.
    function test_TheImplementationAnswersNoVerb() public {
        LockAccount impl = LockAccount(lock.IMPLEMENTATION());
        usdc.mint(address(impl), 1e6);
        (bool ok,) = address(impl).call(abi.encodeCall(LockAccount.sweep, (address(usdc))));
        assertFalse(ok, "the implementation swept");
        vm.prank(alice);
        (ok,) = address(impl).call(abi.encodeCall(LockAccount.release, (1)));
        assertFalse(ok, "the implementation released");
        assertEq(usdc.balanceOf(address(impl)), 1e6, "the donation moved");
    }

    // ---- the boundary, fuzzed ----

    /// @notice On the buyer or the team-linear curve, at any time, after any first pledge and any donation:
    /// @notice capacity and releasable are the lock's curve less what is booked, one atom past capacity is refused, and capacity itself opens.
    /// @notice One atom past releasable is refused and releasable itself lands.
    function testFuzz_BoundaryMatchesTheCurve(uint256 sidSeed, uint256 atSeed, uint256 donSeed, uint256 t1Seed, uint256 u1Seed, uint256 t2Seed) public {
        uint256 sid = sidSeed % 2 == 0 ? 0 : TEAM_LINEAR;
        LockAccount a = sid == 0 ? acct : LockAccount(lock.account(alice, TEAM_LINEAR));
        if (sid != 0) _land(address(a), ALLOC);
        uint256 total = ALLOC + bound(donSeed, 0, 5_000e18);
        if (total > ALLOC) _land(address(a), total - ALLOC);
        _warpTo(T0 + bound(atSeed, 0, 400 days));

        uint256 booked;
        uint64 t1 = uint64(bound(t1Seed, 7 days, 30 days));
        uint256 room1 = _v(sid, total, _now() + t1);
        if (room1 >= MIN_UNITS) {
            booked = bound(u1Seed, MIN_UNITS, room1);
            _borrowFrom(a, booked, t1);
        }

        uint64 t2 = uint64(bound(t2Seed, 7 days, 30 days));
        uint64 e2 = uint64(_now()) + t2;
        uint256 room2 = Math.saturatingSub(_v(sid, total, e2), booked);
        assertEq(a.capacity(e2), room2, "capacity is not the curve at expiry less what is booked");
        vm.prank(alice);
        vm.expectRevert(LockAccount.OverCapacity.selector);
        a.borrow(id, room2 + 1, MIN_DEBT, t2, _noBounds());
        if (room2 >= MIN_UNITS) {
            uint256 loanId = _borrowFrom(a, room2, t2);
            (uint256 units, uint64 expiry) = a.pledgeOf(loanId);
            assertEq(units, room2, "booked units");
            assertEq(expiry, e2, "booked expiry");
            assertEq(read.loan(loanId).expiry, e2, "the hub's expiry is not the booked one");
            assertEq(a.capacity(e2), 0, "the boundary pledge left room");
            booked += room2;
        }

        uint256 rel = Math.saturatingSub(_v(sid, total, _now()), booked);
        assertEq(a.releasable(), rel, "releasable is not the curve now less what is booked");
        vm.prank(alice);
        vm.expectRevert(LockAccount.OverRelease.selector);
        a.release(rel + 1);
        if (rel == 0) return;
        vm.prank(alice);
        a.release(rel);
        assertEq(a.spent(), rel, "the release was not booked as spent");
        assertEq(a.releasable(), 0, "a release at the boundary left some releasable");
    }
}
