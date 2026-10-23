// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Bid, Checkpoint} from "../../src/interfaces/ILaunchAuction.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {MockLaunchAuction} from "./MockLaunchAuction.sol";
import {RunwayFixture} from "./RunwayFixture.sol";

/// @title LaunchOpsBudgetHardening
/// @notice The budget rows a mutation pass found unpinned; each row names the mutant it kills.
/// @notice The exit arithmetic: a hint clause, the partial-fill gate, the zero-demand guard, both round-ups and the start offsets.
/// @notice Settlement: a live read no token donation flips, a raise of nothing, and the recorded donation-latch residual.
/// @notice Refunds against the team's side on a live launch, fuzzed; and an implementation nobody can drive.
/// @dev The start offsets were pinned only by the fork suite, which skips without an RPC key; these rows pin them on the unit rig.
contract LaunchOpsBudgetHardeningTest is RunwayFixture {
    uint24 internal constant MPS = 1e7;
    uint256 internal constant Q = 1 << 96;
    uint160 internal constant PRICE = 1 << 96;
    uint256 internal constant ODD = 7_000 * Q + 3; // a seventh of it is 1000Q and 3/7 of a wei, so every spend on it has a rounding to make
    address internal o1 = address(0x0B1);
    address internal o2 = address(0x0B2);
    address internal o3 = address(0x0B3);

    Made internal m;
    uint64 internal end;

    function setUp() public override {
        super.setUp();
        m = _launch();
        end = m.auction.endBlock();
    }

    // ---- the auction's state, set by hand ----

    function _bid(address owner, uint64 start, uint24 startMps, uint256 maxPrice, uint256 amountQ96) internal pure returns (Bid memory) {
        return Bid({startBlock: start, startCumulativeMps: startMps, exitedBlock: 0, maxPrice: maxPrice, owner: owner, amountQ96: amountQ96, tokensFilled: 0});
    }

    function _cp(uint256 clearing, uint24 cumMps, uint64 prev, uint64 next, uint256 raisedAtClearingX7) internal pure returns (Checkpoint memory c) {
        (c.clearingPrice, c.cumulativeMps, c.prev, c.next, c.currencyRaisedAtClearingPriceQ96X7) = (clearing, cumMps, prev, next, raisedAtClearingX7);
    }

    /// @dev The unit suite's consistent three-bid auction, raising 3000: #1 above the final price 5, #2 at it, #3 at 4, outbid at the end.
    function _bids(MockLaunchAuction a) internal {
        uint64 e = a.endBlock();
        a.setBid(1, _bid(o1, 10, 0, 10, 1_000 * Q));
        a.setBid(2, _bid(o2, 10, 0, 5, 2_000 * Q));
        a.setBid(3, _bid(o3, 10, 0, 4, 1_000 * Q));
        a.setCheckpoint(10, _cp(3, 0, 0, 20, 0));
        a.setCheckpoint(20, _cp(3, 5e6, 10, e, 0));
        a.setCheckpoint(e, _cp(5, MPS, 20, type(uint64).max, 500 * Q * MPS));
        a.setTick(5, 2_000 * Q);
        a.setState(e, true, 3_000 * Q * MPS);
    }

    /// @dev Bids 4 and 5 enter at block 20, three tenths into the schedule: #4 above the final price, #5 at it and fully filled to block 30.
    /// @dev The clearing raise at the end is 2000Q over the seven tenths #5 was alive for, plus one wei, so its share has a rounding to make.
    function _lateBids() internal {
        MockLaunchAuction a = m.auction;
        a.setCheckpoint(10, _cp(3, 0, 0, 20, 0));
        a.setCheckpoint(20, _cp(3, 3e6, 10, 30, 0));
        a.setCheckpoint(30, _cp(3, 4e6, 20, end, 0));
        a.setCheckpoint(end, _cp(5, MPS, 30, type(uint64).max, 2_000 * Q * 7e6 + 1));
        a.setBid(4, _bid(o1, 20, 3e6, 10, ODD));
        a.setBid(5, _bid(o2, 20, 3e6, 5, ODD));
        a.setTick(5, ODD);
        a.setState(end, true, 2 * ODD * MPS);
    }

    /// @dev Move the clock a second past launchBy, where settlement opens.
    function _open(Made memory x) internal {
        _warpTo(x.launchBy + 1);
    }

    /// @dev A successful migration, then launchBy passing: the pool opens, the budget gets `quote` of the raise and `left` of the reserve.
    function _migrate(Made memory x, uint256 quote, uint256 left) internal {
        strat.openPool(x.key, PRICE);
        usdc.mint(address(x.budget), quote);
        strat.send(x.token, address(x.budget), left);
        _open(x);
    }

    /// @dev A failed migration, then launchBy passing: no pool, and the strategy's catch sends the budget `quote` and the WHOLE reserve.
    function _fail(Made memory x, uint256 quote) internal {
        usdc.mint(address(x.budget), quote);
        strat.send(x.token, address(x.budget), SUPPLY);
        _open(x);
    }

    // ---- what a bid spent: the auction's own exit arithmetic ----

    /// @notice A last-fully-filled hint that already clears AT the bid's price is refused, even when the checkpoint after it clears there too.
    /// @notice Kills dropping `last.clearingPrice >= b.maxPrice`: bid 2 would count the stretch it was only partly filled in as fully filled.
    function test_AFullyFilledHintAtTheBidsPriceIsRefused() public {
        _bids(m.auction);
        m.auction.setCheckpoint(20, _cp(3, 5e6, 10, 30, 0));
        m.auction.setCheckpoint(30, _cp(5, 7e6, 20, end, 0));
        m.auction.setCheckpoint(end, _cp(5, MPS, 30, type(uint64).max, 500 * Q * MPS));
        assertEq(m.budget.spentOf(2, 20, 0), 1_500 * Q, "fixture: block 20 is bid 2's last fully-filled checkpoint");
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        m.budget.spentOf(2, 30, 0);
    }

    /// @notice An outbid bid whose last checkpoint before the outbid cleared BELOW its price spent its fully-filled stretch and nothing more.
    /// @notice Kills `upper.clearingPrice == b.maxPrice` -> true: the demand at its own tick and a raise at the lower price must add nothing.
    function test_AnOutbidBidNeverFilledAtItsPriceSpentOnlyItsFullFill() public {
        _bids(m.auction);
        m.auction.setCheckpoint(20, _cp(3, 5e6, 10, end, 300 * Q * MPS));
        m.auction.setTick(4, 1_000 * Q);
        assertEq(m.budget.spentOf(3, 20, end), 500 * Q, "bid 3 was charged a partial fill at a price it never cleared at");
    }

    /// @notice A bid at the final price whose tick reads no demand adds no partial fill, as the auction's own exit returns, and it still refunds.
    /// @notice Kills dropping the `tickDemand != 0` guard: the division by zero would brick that bid's refund for good.
    function test_AZeroTickDemandAddsNoPartialFill() public {
        _bids(m.auction);
        m.auction.setTick(5, 0);
        assertEq(m.budget.spentOf(2, 20, 0), 1_000 * Q, "bid 2: its fully-filled half alone");
        _fail(m, 300);
        m.budget.settle();
        assertEq(m.budget.refund(2, 20, 0), 100, "300 * 1000 / 3000");
    }

    /// @notice A bid that entered mid-auction and cleared above the final price spent exactly its amount: its schedule starts where it entered.
    /// @notice Kills either start offset in the full fill, `- start.cumulativeMps` or `MPS - b.startCumulativeMps`; every other unit bid starts at 0.
    function test_ALateBidAboveTheFinalPriceSpentItsWholeAmount() public {
        _lateBids();
        assertEq(m.budget.spentOf(4, 0, 0), ODD, "a late bid above the final price did not spend exactly its amount");
    }

    /// @notice A late bid at the final price: a seventh of its amount fully filled, then the clearing raise over its own demand, each rounded UP.
    /// @notice ODD / 7 is 1000Q + 3/7, and the raise over seven tenths is 2000Q + 1/7e6; each rounds up a wei, so 3000Q + 2.
    /// @notice Kills Floor in either term, and the start offsets in the partial path.
    function test_ALateBidAtTheFinalPriceRoundsEachSpendUp() public {
        _lateBids();
        assertEq(m.budget.spentOf(5, 30, 0), 3_000 * Q + 2, "the spend is not the auction's own, rounded up in both terms");
    }

    // ---- settlement ----

    /// @notice A live pool reads live whatever a donor sends first: even the whole reserve again in tokens cannot flip a success to failure.
    /// @notice Kills the cheap fix code review row 3 rejected (`isLive` also needing under ops + reserve), whose donation flip took the team's share.
    function test_ATokenDonationCannotFlipALivePool() public {
        m.auction.setState(end, true, 10_000e6 * Q * MPS);
        _migrate(m, 2_000e6, 400_000e18);
        strat.send(m.token, address(m.budget), SUPPLY);
        uint256 supply = IERC20(m.token).totalSupply();
        m.budget.settle();
        assertTrue(m.budget.live(), "a donation flipped a live pool to failure");
        assertEq(usdc.balanceOf(m.budget.wallet()), 2_000e6, "the donation cost the team its share");
        assertEq(IERC20(m.token).totalSupply(), supply - 400_000e18 - SUPPLY, "the donation and the leftover did not both burn");
    }

    /// @notice An auction nobody bid in raised nothing: it settles failed, and a refund marks its bid with zero instead of dividing by the raise.
    /// @notice Kills dropping `_share`'s early return: with a zero raise every refund would revert, even with a mistaken send in the pool.
    function test_AnAuctionThatRaisedNothingRefundsZero() public {
        m.auction.setState(end, false, 0);
        _fail(m, 100);
        m.budget.settle();
        assertFalse(m.budget.live(), "fixture: no pool");
        assertEq(m.budget.refundPool(), 100, "fixture: the mistaken send is the pool");
        assertEq(m.budget.owed(1, 0, 0), 0, "a bid of an auction that raised nothing is owed something");
        assertEq(m.budget.refund(1, 0, 0), 0, "a bid of an auction that raised nothing was paid");
        assertTrue(m.budget.refunded(1), "the bid was not marked");
    }

    /// @notice THE RECORDED DONATION LATCH, code review row 21, kept as a residual by user ruling ().
    /// @notice A whole-reserve donation before a late migration latches failure on an empty pool; the late raise and reserve then move nothing.
    /// @notice Pinned so a fix that changes it changes this row on purpose; the defence is a `migrate` before `settle`.
    function test_TheRecordedDonationLatchStrandsALateRecovery() public {
        _bids(m.auction);
        strat.send(m.token, address(m.budget), SUPPLY);
        _open(m);
        m.budget.settle();
        assertFalse(m.budget.live(), "fixture: the donation latched failure");
        assertEq(m.budget.refundPool(), 0, "fixture: nothing had arrived to refund");
        usdc.mint(address(m.budget), 3_000);
        strat.send(m.token, address(m.budget), SUPPLY);
        assertEq(m.budget.owed(1, 0, 0), 0, "the late raise reached a bid");
        assertEq(m.budget.refund(2, 20, 0), 0, "the late raise was refunded");
        address w = m.budget.wallet();
        assertEq(usdc.balanceOf(w), 0, "the late raise reached the team");
        assertEq(IERC20(m.token).balanceOf(w), OPS, "the late reserve reached the ops wallet");
        assertEq(usdc.balanceOf(address(m.budget)), 3_000, "the late raise left the budget");
        assertEq(IERC20(m.token).balanceOf(address(m.budget)), SUPPLY, "the late reserve left the budget");
    }

    // ---- refunds against the team's side ----

    /// @notice ON A LIVE LAUNCH the bids' pool is what arrived past the team's capped share, and refunds never reach the team's side.
    /// @notice However far the spends run over the raise (set short by hand, up to half), every refund pays and their sum stays in the pool.
    /// @notice The wallet holds the team's currency whole, and the budget exactly what the refunds left of the pool.
    function testFuzz_LiveRefundsNeverReachTheTeamsShare(uint64 donation, uint8 count, uint64 short, uint64 seed) public {
        uint256 n = bound(count, 2, 30);
        MockLaunchAuction a = m.auction;
        a.setCheckpoint(10, _cp(3, 0, 0, end, 0));
        a.setCheckpoint(end, _cp(5, MPS, 10, type(uint64).max, 0));
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 amountQ96 = (1e6 + uint256(keccak256(abi.encode(seed, i))) % 1e9) * Q + uint256(keccak256(abi.encode(i, seed))) % Q;
            a.setBid(i, _bid(address(uint160(0x1000 + i)), 10, 0, 10, amountQ96));
            total += amountQ96;
        }
        uint256 raised = total - Math.mulDiv(total, bound(short, 0, 5_000), 10_000);
        a.setState(end, true, raised * MPS);
        uint256 extra = bound(donation, 1, type(uint64).max);
        _migrate(m, raised * SHARE / (10_000 * Q) + extra, 400_000e18);
        m.budget.settle();
        (uint256 team, uint256 pool) = (usdc.balanceOf(m.budget.wallet()), m.budget.refundPool());
        assertTrue(m.budget.live(), "fixture: the pool is live");
        assertGe(pool, extra, "the bids' pool is short of what arrived past the share");
        assertEq(team, raised * SHARE / (10_000 * Q), "the wallet does not hold the capped share whole");

        uint256 paid;
        for (uint256 i; i < n; ++i) {
            paid += m.budget.refund(i, 0, 0);
        }
        assertLe(paid, pool, "refunds paid past the bids' pool");
        assertEq(usdc.balanceOf(m.budget.wallet()), team, "a refund reached the team's share");
        assertEq(usdc.balanceOf(address(m.budget)), pool - paid, "the team's share and the refunds overlapped");
    }

    // ---- the implementation ----

    /// @notice The implementation every launch clones cannot be driven: settle, refund, fee collection and spent all refuse, and nothing is marked.
    /// @notice It has no clone args, so `terms` cannot decode them and reverts with no data, and settle and spent revert there, before any call.
    function test_TheImplementationRefusesEveryVerb() public {
        LaunchOpsBudget impl = LaunchOpsBudget(factory.BUDGET_IMPL());
        vm.startPrank(stranger);
        vm.expectRevert(bytes(""));
        impl.terms();
        vm.expectRevert(bytes(""));
        impl.settle();
        vm.expectRevert(LaunchOpsBudget.NotSettled.selector);
        impl.refund(1, 0, 0);
        vm.expectRevert(LaunchOpsBudget.NotLive.selector);
        impl.collectFees(1);
        vm.expectRevert(bytes(""));
        impl.spentOf(1, 0, 0);
        vm.stopPrank();
        assertFalse(impl.refunded(1), "the implementation marked a bid");
        assertEq(impl.wallet(), address(0), "the implementation made a wallet");
    }
}
