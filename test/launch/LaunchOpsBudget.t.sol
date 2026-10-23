// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletUpgradeable} from "../../vendor/oz-upgradeable/VestingWalletUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Bid, Checkpoint} from "../../src/interfaces/ILaunchAuction.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {MockLaunchAuction} from "./MockLaunchAuction.sol";
import {ReenteringQuote} from "./ReenteringQuote.sol";
import {RunwayFixture} from "./RunwayFixture.sol";
import {RunwaySalt} from "./RunwayMocks.sol";

/// @notice A bid owner that reads the budget from inside the refund paying it.
contract BudgetPeeker {
    LaunchOpsBudget internal immutable B;

    constructor(LaunchOpsBudget b) {
        B = b;
    }

    function spent() external view {
        B.spentOf(1, 0, 0);
    }

    function owed() external view {
        B.owed(1, 0, 0);
    }
}

/// @title LaunchOpsBudgetTest
/// @notice UNIT rows for the ops budget against a settable auction: settlement's one-shot split and the operator's wallet, refunds, fees.
/// @dev The deployed auction and strategy run the same budget in the fork suite; these pin the numbers by hand.
/// @dev Bids: #1 above the final clearing price (spent whole), #2 at it (half fully filled, then a share of the clearing raise), #3 outbid.
contract LaunchOpsBudgetTest is RunwayFixture {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant MPS = 1e7;
    uint256 internal constant Q = 1 << 96;
    uint160 internal constant PRICE = 1 << 96;
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

    function _bid(address owner, uint64 start, uint256 maxPrice, uint256 amountQ96) internal pure returns (Bid memory) {
        return Bid({startBlock: start, startCumulativeMps: 0, exitedBlock: 0, maxPrice: maxPrice, owner: owner, amountQ96: amountQ96, tokensFilled: 0});
    }

    function _cp(uint256 clearing, uint24 cumMps, uint64 prev, uint64 next, uint256 raisedAtClearingX7) internal pure returns (Checkpoint memory c) {
        (c.clearingPrice, c.cumulativeMps, c.prev, c.next, c.currencyRaisedAtClearingPriceQ96X7) = (clearing, cumMps, prev, next, raisedAtClearingX7);
    }

    /// @dev The three bids on auction `a`, a consistent auction: their spends, 1000 + 1500 + 500, are its whole raise of 3000.
    /// @dev Bid 2 is the only demand at the final price, 2000, and gets 500 of the clearing raise: it spends 1500 and keeps 500.
    function _bids(MockLaunchAuction a) internal {
        uint64 e = a.endBlock();
        a.setBid(1, _bid(o1, 10, 10, 1_000 * Q));
        a.setBid(2, _bid(o2, 10, 5, 2_000 * Q));
        a.setBid(3, _bid(o3, 10, 4, 1_000 * Q));
        a.setCheckpoint(5, _cp(3, 0, 0, e, 0));
        a.setCheckpoint(10, _cp(3, 0, 0, 20, 0));
        a.setCheckpoint(20, _cp(3, 5e6, 10, e, 0));
        a.setCheckpoint(e, _cp(5, MPS, 20, type(uint64).max, 500 * Q * MPS));
        a.setTick(5, 2_000 * Q);
        a.setState(e, true, 3_000 * Q * MPS);
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

    /// @dev The fixture launch's auction, final at a raise of `raised` whole units and no bids.
    function _final(uint256 raised) internal {
        m.auction.setState(end, true, raised * Q * MPS);
    }

    /// @dev The operator's wallet settlement made.
    function _wallet() internal view returns (VestingWallet) {
        return VestingWallet(payable(m.budget.wallet()));
    }

    // ---- settlement ----

    /// @notice Nothing settles until launchBy has passed, even with the pool live and everything else final: up to and AT launchBy it reverts.
    function test_SettleWaitsForLaunchBy() public {
        _final(10_000e6);
        strat.openPool(m.key, PRICE);
        strat.send(m.token, address(m.budget), 400_000e18);
        vm.expectRevert(LaunchOpsBudget.TooEarly.selector);
        m.budget.settle();
        _warpTo(m.launchBy);
        vm.expectRevert(LaunchOpsBudget.TooEarly.selector);
        m.budget.settle();
        _warpTo(m.launchBy + 1);
        m.budget.settle();
        assertTrue(m.budget.live(), "a second past launchBy, settlement did not run");
    }

    /// @notice Nothing settles before the auction's end is checkpointed: the raise the team's cap reads is not final.
    function test_SettleWaitsForTheFinalCheckpoint() public {
        m.auction.setState(end - 1, true, 10_000e6 * Q * MPS);
        _migrate(m, 2_000e6, 400_000e18);
        vm.expectRevert(LaunchOpsBudget.NotFinal.selector);
        m.budget.settle();
    }

    /// @notice Before the migration the pool is not live and the reserve is not back, so settlement is pending, whoever asks.
    function test_SettleIsPendingBeforeTheMigration() public {
        _final(10_000e6);
        _open(m);
        vm.prank(stranger);
        vm.expectRevert(LaunchOpsBudget.Pending.selector);
        m.budget.settle();
    }

    /// @notice A currency donation cannot latch failure: only the token side reads failure, and only at the whole reserve.
    function test_ACurrencyDonationCannotLatchFailure() public {
        _final(10_000e6);
        usdc.mint(address(m.budget), 1_000_000e6);
        _open(m);
        vm.expectRevert(LaunchOpsBudget.Pending.selector);
        m.budget.settle();
    }

    /// @notice A token donation an atom short of the reserve cannot latch failure; the whole reserve does, since only a failure returns it.
    function test_ATokenDonationBelowTheReserveCannotLatchFailure() public {
        _final(10_000e6);
        strat.send(m.token, address(m.budget), SUPPLY - 1);
        _open(m);
        vm.expectRevert(LaunchOpsBudget.Pending.selector);
        m.budget.settle();
        strat.send(m.token, address(m.budget), 1);
        m.budget.settle();
        assertFalse(m.budget.live(), "the whole reserve did not read as a failure");
    }

    /// @notice A live launch: the wallet takes the team's share of the raise and the ops tokens, and the rest of the reserve burns.
    function test_ALiveLaunchGivesTheTeamItsShare() public {
        _final(10_000e6);
        _migrate(m, 2_000e6, 400_000e18);
        uint256 supply = IERC20(m.token).totalSupply();
        vm.expectEmit(address(m.budget));
        emit LaunchOpsBudget.Settled(true, 2_000e6, 0, 0, 400_000e18);
        vm.prank(stranger);
        m.budget.settle();
        assertTrue(m.budget.live(), "live");
        assertTrue(m.budget.wallet() != address(0), "settlement made no wallet, so it reads unsettled");
        assertEq(usdc.balanceOf(address(_wallet())), 2_000e6, "the wallet does not hold the team's share");
        assertEq(m.budget.refundPool(), 0, "nothing left for the bids");
        assertEq(IERC20(m.token).totalSupply(), supply - 400_000e18, "the reserve's leftover did not burn");
        assertEq(IERC20(m.token).balanceOf(address(_wallet())), OPS, "the wallet does not hold exactly the ops tokens");
        assertEq(IERC20(m.token).balanceOf(address(m.budget)), 0, "the budget kept launch tokens");
    }

    /// @notice The cap holds against a currency donation before settlement: the team gets its share of the raise, the excess goes to the bids.
    function test_TheCapHoldsAgainstADonation() public {
        _final(10_000e6);
        _migrate(m, 2_000e6, 400_000e18);
        usdc.mint(address(m.budget), 500e6);
        m.budget.settle();
        assertEq(usdc.balanceOf(address(_wallet())), 2_000e6, "the donation raised the team's share");
        assertEq(m.budget.refundPool(), 500e6, "the donation did not go to the bids");
        assertEq(usdc.balanceOf(address(m.budget)), 500e6, "the budget does not hold exactly the bids' pool");
    }

    /// @notice A live launch that paid the budget less than the share (the strategy's fee) gives the team all of it and the bids nothing.
    function test_ShortOfTheShareTheTeamTakesAll() public {
        _final(10_000e6);
        _migrate(m, 1_900e6, 400_000e18);
        m.budget.settle();
        assertEq(usdc.balanceOf(address(_wallet())), 1_900e6, "the team's currency is the balance");
        assertEq(m.budget.refundPool(), 0, "the bids got some");
    }

    /// @notice A failed launch: the wallet gets no currency, the bids share the whole raise, and the returned reserve burns.
    function test_AFailedLaunchRefundsTheBidsAndBurnsTheReserve() public {
        _bids(m.auction);
        _fail(m, 250);
        uint256 supply = IERC20(m.token).totalSupply();
        m.budget.settle();
        assertFalse(m.budget.live(), "a failure read live");
        assertEq(usdc.balanceOf(address(_wallet())), 0, "the team got currency from a failure");
        assertEq(m.budget.refundPool(), 250, "the bids do not share the whole raise");
        assertEq(usdc.balanceOf(address(m.budget)), 250, "the bids' pool left the budget");
        assertEq(IERC20(m.token).totalSupply(), supply - SUPPLY, "the reserve did not burn");
        assertEq(IERC20(m.token).balanceOf(address(_wallet())), OPS, "the wallet does not hold exactly the ops tokens");
    }

    /// @notice An auction that never graduated refunded its bids itself: settlement reads failure and the bids are owed nothing.
    /// @notice The whole auction supply is swept into the budget and burns with the returned reserve: 2S in all.
    function test_AnUngraduatedAuctionOwesNothing() public {
        _bids(m.auction);
        m.auction.setState(end, false, 2_500 * Q * MPS);
        strat.send(m.token, address(m.auction), SUPPLY);
        m.auction.setUnsold(address(m.budget), SUPPLY);
        strat.send(m.token, address(m.budget), SUPPLY);
        _open(m);
        uint256 supply = IERC20(m.token).totalSupply();
        m.budget.settle();
        assertFalse(m.budget.live(), "an ungraduated auction read live");
        assertEq(m.budget.refundPool(), 0, "a refund pool with no currency");
        assertEq(m.budget.spentOf(1, 0, 0), 0, "an ungraduated bid spent something");
        assertEq(m.budget.refund(1, 0, 0), 0, "an ungraduated bid was paid");
        assertEq(IERC20(m.token).totalSupply(), supply - 2 * uint256(SUPPLY), "the reserve and the unsold supply did not both burn");
    }

    /// @notice Settlement sweeps the auction's unsold tokens into the budget and burns them with the reserve's leftover.
    /// @notice It reads live or failed BEFORE the sweep, so unsold tokens can never latch a failure.
    function test_SettleSweepsAndBurnsTheUnsold() public {
        _final(10_000e6);
        strat.send(m.token, address(m.auction), 300_000e18);
        m.auction.setUnsold(address(m.budget), 300_000e18);
        _migrate(m, 2_000e6, 400_000e18);
        uint256 supply = IERC20(m.token).totalSupply();
        vm.expectEmit(address(m.budget));
        emit LaunchOpsBudget.Settled(true, 2_000e6, 0, 0, 700_000e18);
        m.budget.settle();
        assertTrue(m.auction.swept(), "the budget did not sweep");
        assertEq(IERC20(m.token).balanceOf(address(m.auction)), 0, "the unsold stayed in the auction");
        assertEq(IERC20(m.token).totalSupply(), supply - 700_000e18, "the unsold and the leftover did not burn");
        assertEq(IERC20(m.token).balanceOf(address(_wallet())), OPS, "the wallet does not hold exactly the ops tokens");
        assertEq(IERC20(m.token).balanceOf(address(m.budget)), 0, "the budget kept launch tokens");
    }

    /// @notice A sweep that would bring the budget to the whole reserve does not latch a failure: with no pool and no reserve back, still pending.
    function test_TheUnsoldNeverLatchAFailure() public {
        _final(10_000e6);
        strat.send(m.token, address(m.auction), SUPPLY);
        m.auction.setUnsold(address(m.budget), SUPPLY);
        _open(m);
        vm.expectRevert(LaunchOpsBudget.Pending.selector);
        m.budget.settle();
        assertFalse(m.auction.swept(), "a pending settlement swept");
    }

    /// @notice A sweep that reverts never blocks settlement, so refunds can never be bricked by it; the unsold just stay in the auction.
    function test_ARevertingSweepDoesNotBlockSettlement() public {
        _bids(m.auction);
        strat.send(m.token, address(m.auction), 300_000e18);
        m.auction.setUnsold(stranger, 300_000e18);
        _fail(m, 300);
        m.budget.settle();
        assertFalse(m.budget.live(), "a failure read live");
        assertEq(IERC20(m.token).balanceOf(address(m.auction)), 300_000e18, "fixture: the sweep was refused");
        assertEq(m.budget.refund(1, 0, 0), 100, "a refused sweep blocked the refunds");
    }

    /// @notice Settlement runs once.
    function test_SettleRunsOnce() public {
        _final(10_000e6);
        _migrate(m, 2_000e6, 400_000e18);
        m.budget.settle();
        vm.expectRevert(LaunchOpsBudget.AlreadySettled.selector);
        m.budget.settle();
    }

    /// @notice Settlement fixes the split for good: currency arriving after it reaches neither the bids' pool nor any refund.
    function test_LaterInflowMovesNothing() public {
        _bids(m.auction);
        _fail(m, 300);
        m.budget.settle();
        usdc.mint(address(m.budget), 1_000);
        assertEq(m.budget.refundPool(), 300, "the pool moved");
        assertEq(m.budget.refund(1, 0, 0), 100, "300 * 1000 / 3000, the late inflow ignored");
    }

    // ---- refunds: what each bid spent, and its share ----

    /// @notice Above the final clearing price a bid spent all of it; at it, its fully-filled half plus its share of the clearing raise.
    function test_SpentOfFullAndPartial() public {
        _bids(m.auction);
        assertEq(m.budget.spentOf(1, 0, 0), 1_000 * Q, "bid 1 spent its whole amount");
        assertEq(m.budget.spentOf(2, 20, 0), 1_500 * Q, "bid 2: 1000 fully filled, plus 2000/2000 of the 500 raised at clearing");
    }

    /// @notice An outbid bid spent only its fully-filled stretch: nothing at the price it was outbid at.
    function test_SpentOfOutbid() public {
        _bids(m.auction);
        assertEq(m.budget.spentOf(3, 20, end), 500 * Q, "bid 3 filled half the schedule, then was outbid");
    }

    /// @notice A hint the auction itself would refuse is refused here too, in each direction.
    function test_BadHintsRevert() public {
        _bids(m.auction);
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        m.budget.spentOf(2, 10, 0); // the next checkpoint still clears under the bid's price
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        m.budget.spentOf(2, end, 0); // too late: already clearing at the bid's price
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        m.budget.spentOf(2, 5, 0); // a hint before the bid existed
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        m.budget.spentOf(3, 20, 20); // an outbid hint that does not clear above the bid's price
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        m.budget.spentOf(3, 20, 0); // no outbid hint, yet the final price is not the bid's
    }

    /// @dev Bid 3 (price 4) outbid at the end, with a checkpoint at block 30 between: its clearing price is `at30`, raising `raised30` there.
    function _outbidAt(uint256 at30, uint256 raised30) internal {
        _bids(m.auction);
        m.auction.setCheckpoint(20, _cp(3, 5e6, 10, 30, 0));
        m.auction.setCheckpoint(30, _cp(at30, 7e6, 20, end, raised30));
        m.auction.setCheckpoint(end, _cp(5, MPS, 30, type(uint64).max, 500 * Q * MPS));
    }

    /// @notice An outbid hint whose previous checkpoint ALREADY cleared above the bid's price is refused: it would skip the bid's partial fill.
    function test_AnOutbidHintPastThePartialFillIsRefused() public {
        _outbidAt(5, 0);
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        m.budget.spentOf(3, 20, end);
    }

    /// @notice An outbid bid that cleared AT its own price before it was outbid spent its fully-filled stretch plus its share there.
    function test_AnOutbidBidPartlyFilledAtItsPrice() public {
        _outbidAt(4, 200 * Q * MPS);
        m.auction.setTick(4, 1_000 * Q);
        assertEq(m.budget.spentOf(3, 20, end), 700 * Q, "bid 3: 500 fully filled, plus 1000/1000 of the 200 raised at its price");
    }

    /// @notice Nothing a bid spent is final before the auction's end is checkpointed.
    function test_SpentWaitsForTheFinalCheckpoint() public {
        _bids(m.auction);
        m.auction.setState(end - 1, true, 2_500 * Q * MPS);
        vm.expectRevert(LaunchOpsBudget.NotFinal.selector);
        m.budget.spentOf(1, 0, 0);
    }

    /// @notice Nothing is refunded or owed before settlement fixes the pool.
    function test_NothingIsRefundedBeforeSettlement() public {
        _bids(m.auction);
        _fail(m, 250);
        vm.expectRevert(LaunchOpsBudget.NotSettled.selector);
        m.budget.refund(1, 0, 0);
        vm.expectRevert(LaunchOpsBudget.NotSettled.selector);
        m.budget.owed(1, 0, 0);
    }

    /// @notice Each bid is owed its spent share of the pool, paid to the bid's owner, never to the caller; all three together take it all.
    function test_RefundsSplitBySpentShare() public {
        _bids(m.auction);
        _fail(m, 300);
        m.budget.settle();
        assertEq(m.budget.owed(1, 0, 0), 100, "owed");
        vm.prank(stranger);
        assertEq(m.budget.refund(1, 0, 0), 100, "300 * 1000 / 3000");
        vm.prank(stranger);
        assertEq(m.budget.refund(2, 20, 0), 150, "300 * 1500 / 3000");
        vm.prank(stranger);
        assertEq(m.budget.refund(3, 20, end), 50, "300 * 500 / 3000");
        assertEq(usdc.balanceOf(o1), 100, "to bid 1's owner");
        assertEq(usdc.balanceOf(o2), 150, "to bid 2's owner");
        assertEq(usdc.balanceOf(o3), 50, "to bid 3's owner");
        assertEq(usdc.balanceOf(stranger), 0, "never to the caller");
        assertEq(m.budget.refundedOut(), 300, "every unit booked as refunded");
        assertEq(usdc.balanceOf(address(m.budget)), 0, "the pool is not exhausted by its three bids");
    }

    /// @notice Each bid is refunded once; its owed falls to zero, and a second refund reverts.
    function test_EachBidRefundsOnce() public {
        _bids(m.auction);
        _fail(m, 300);
        m.budget.settle();
        vm.expectEmit(address(m.budget));
        emit LaunchOpsBudget.Refunded(1, o1, 100);
        m.budget.refund(1, 0, 0);
        assertTrue(m.budget.refunded(1), "not marked");
        assertEq(m.budget.owed(1, 0, 0), 0, "owed after its refund");
        vm.expectRevert(LaunchOpsBudget.AlreadyRefunded.selector);
        m.budget.refund(1, 0, 0);
    }

    /// @notice A refunded bid reads zero owed whatever hints it is asked with, even ones its spent arithmetic would refuse.
    function test_ARefundedBidOwesZeroOnStaleHints() public {
        _bids(m.auction);
        _fail(m, 300);
        m.budget.settle();
        m.budget.refund(2, 20, 0);
        assertEq(m.budget.owed(2, 10, 0), 0, "a refunded bid read with a stale hint");
        assertEq(m.budget.owed(2, 5, 0), 0, "a refunded bid read with a hint from before it existed");
    }

    /// @notice When the bids' spent sum runs over the raise (here set short of it by hand), the last payer is clamped to what the pool holds.
    function test_TheLastRefundIsClampedToThePool() public {
        _bids(m.auction);
        m.auction.setState(end, true, 2_000 * Q * MPS);
        _fail(m, 250);
        m.budget.settle();
        assertEq(m.budget.refund(1, 0, 0), 125, "250 * 1000 / 2000");
        assertEq(m.budget.owed(2, 20, 0), 125, "187 by share, clamped to the 125 left");
        assertEq(m.budget.refund(2, 20, 0), 125, "and paid the clamp");
        assertEq(usdc.balanceOf(address(m.budget)), 0, "drained, never overdrawn");
    }

    /// @notice Shares round DOWN, so the dust stays behind rather than overpaying anyone, with every bid refunded.
    function test_RoundingLeavesDustBehind() public {
        _bids(m.auction);
        _fail(m, 7);
        m.budget.settle();
        assertEq(m.budget.refund(1, 0, 0), 2, "floor(7 * 1000 / 3000)");
        assertEq(m.budget.refund(2, 20, 0), 3, "floor(7 * 1500 / 3000)");
        assertEq(m.budget.refund(3, 20, end), 1, "floor(7 * 500 / 3000)");
        assertEq(usdc.balanceOf(address(m.budget)), 1, "one unit of dust stays");
    }

    /// @notice MANY BIDS: every spend rounds up, so their sum can exceed the raise by up to a Q96-wei per bid.
    /// @notice No refund ever reverts, none pays past its share, and the shortfall is dust: at most a wei per bid.
    function testFuzz_ManyBidsLeaveOnlyDustAndNeverRevert(uint64 inflow, uint8 count, uint8 excess, uint64 seed) public {
        uint256 n = bound(count, 2, 40);
        MockLaunchAuction a = m.auction;
        a.setCheckpoint(10, _cp(3, 0, 0, end, 0));
        a.setCheckpoint(end, _cp(5, MPS, 10, type(uint64).max, 0));
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 amountQ96 = (1 + uint256(keccak256(abi.encode(seed, i))) % 1e12) * Q + uint256(keccak256(abi.encode(i, seed))) % Q;
            a.setBid(i, _bid(address(uint160(0x1000 + i)), 10, 10, amountQ96));
            total += amountQ96;
        }
        uint256 raised = total - bound(excess, 0, n);
        a.setState(end, true, raised * MPS);
        uint256 received = bound(inflow, 1, type(uint64).max);
        _fail(m, received);
        m.budget.settle();

        uint256 paidSum;
        uint256 lastShort;
        for (uint256 i; i < n; ++i) {
            uint256 share = Math.mulDiv(received, m.budget.spentOf(i, 0, 0), raised);
            uint256 got = m.budget.refund(i, 0, 0);
            assertLe(got, share, "a refund paid past its share");
            lastShort = share - got;
            paidSum += got;
        }
        assertLe(paidSum, received, "paid out more than received");
        assertLe(lastShort, n, "the last refunder was short by more than a wei per bid");
        assertLe(received - paidSum, n, "more than a wei per bid was left behind");
    }

    /// @notice A refund's transfer cannot read the budget mid-refund: `spentOf` and `owed` both refuse a re-entry from inside it.
    function test_ViewsRefuseReentryDuringARefund() public {
        ReenteringQuote rq = new ReenteringQuote();
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(manager), address(strat));
        LaunchTokenFactory f = new LaunchTokenFactory(address(ace), address(strat), address(rq), BLOCK_SECONDS, FEE, SPACING, salt, cutSink, 0);
        MockLaunchAuction a = new MockLaunchAuction();
        strat.setNext(address(a));
        vm.prank(team);
        address t = f.launch(_input());
        (address lock,, address b) = f.launchOf(t);
        LaunchOpsBudget budget = LaunchOpsBudget(b);
        BudgetPeeker peeker = new BudgetPeeker(budget);
        a.set(t, address(rq), lock, end);
        a.setBid(1, _bid(address(peeker), 10, 10, 1_000 * Q));
        a.setCheckpoint(10, _cp(3, 0, 0, end, 0));
        a.setCheckpoint(end, _cp(5, MPS, 10, type(uint64).max, 0));
        a.setState(end, true, 1_000 * Q * MPS);
        rq.mint(b, 100);
        strat.send(t, b, SUPPLY);
        _open(m);
        budget.settle();

        rq.arm(address(peeker), abi.encodeCall(BudgetPeeker.spent, ()));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        budget.refund(1, 0, 0);
        rq.arm(address(peeker), abi.encodeCall(BudgetPeeker.owed, ()));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        budget.refund(1, 0, 0);

        rq.arm(address(0), "");
        assertEq(budget.refund(1, 0, 0), 100, "fixture: unarmed, the refund pays");
    }

    // ---- the operator's wallet ----

    /// @notice A live settlement makes the operator a VestingWallet from launchBy over a year, holding the capped share and the ops tokens.
    /// @notice The budget keeps exactly the bids' pool.
    function test_ALiveSettleSendsTheShareAndOpsToAWalletFromLaunchBy() public {
        _final(10_000e6);
        _migrate(m, 2_500e6, 400_000e18);
        m.budget.settle();
        VestingWallet w = _wallet();
        assertTrue(address(w) != address(0) && address(w).code.length > 0, "no wallet was made");
        assertEq(w.owner(), operator, "the wallet vests to another");
        assertEq(abi.encode(w.start(), w.duration()), abi.encode(m.launchBy, 365 days), "the wallet runs another curve");
        assertEq(usdc.balanceOf(address(w)), 2_000e6, "the wallet does not hold the capped share");
        assertEq(IERC20(m.token).balanceOf(address(w)), OPS, "the wallet does not hold the ops tokens");
        assertEq(usdc.balanceOf(address(m.budget)), m.budget.refundPool(), "the budget holds more or less than the bids' pool");
        assertEq(m.budget.refundPool(), 500e6, "the excess past the share is not the bids' pool");
    }

    /// @notice A failed settlement still makes the wallet, and sends it only the ops tokens: no currency.
    function test_AFailedSettleSendsOnlyTheOpsToTheWallet() public {
        _bids(m.auction);
        _fail(m, 300);
        m.budget.settle();
        VestingWallet w = _wallet();
        assertEq(w.owner(), operator, "the wallet vests to another");
        assertEq(w.start(), m.launchBy, "a failure's wallet starts elsewhere");
        assertEq(usdc.balanceOf(address(w)), 0, "the wallet got currency from a failure");
        assertEq(IERC20(m.token).balanceOf(address(w)), OPS, "the wallet does not hold the ops tokens");
        assertEq(usdc.balanceOf(address(m.budget)), 300, "the bids' pool left the budget");
    }

    /// @notice The wallet releases both assets linearly to the operator from launchBy: half at mid-year, whole at a year, and nothing more.
    function test_TheWalletReleasesLinearlyToTheOperator() public {
        _final(10_000e6);
        _migrate(m, 2_000e6, 400_000e18);
        m.budget.settle();
        VestingWallet w = _wallet();
        _warpTo(m.launchBy + 365 days / 2);
        w.release(address(usdc));
        w.release(m.token);
        assertEq(usdc.balanceOf(operator), 1_000e6, "currency at mid-year");
        assertEq(IERC20(m.token).balanceOf(operator), OPS / 2, "tokens at mid-year");
        _warpTo(m.launchBy + 365 days);
        w.release(address(usdc));
        w.release(m.token);
        assertEq(usdc.balanceOf(operator), 2_000e6, "currency at a year");
        assertEq(IERC20(m.token).balanceOf(operator), OPS, "tokens at a year");
        assertEq(w.releasable(address(usdc)) + w.releasable(m.token), 0, "more than the whole vests");
    }

    /// @notice Before settlement there is no wallet, and nothing has left the budget for one.
    function test_NoWalletBeforeSettlement() public {
        _final(10_000e6);
        _migrate(m, 2_000e6, 400_000e18);
        assertEq(m.budget.wallet(), address(0), "a wallet before settlement");
        assertEq(IERC20(m.token).balanceOf(address(m.budget)), OPS + 400_000e18, "launch tokens left the budget before settlement");
        assertEq(usdc.balanceOf(address(m.budget)), 2_000e6, "currency left the budget before settlement");
    }

    /// @notice Settlement clones the wallet rather than deploying one: a failed launch's whole settle costs less than one wallet deploy alone.
    function test_SettleClonesTheWalletCheaply() public {
        _bids(m.auction);
        _fail(m, 300);
        uint256 g = gasleft();
        m.budget.settle();
        uint256 settleGas = g - gasleft();
        g = gasleft();
        new VestingWallet(operator, uint64(m.launchBy), 365 days);
        uint256 deployGas = g - gasleft();
        assertLt(settleGas, deployGas, "settle still pays for a full wallet deploy");
    }

    /// @notice A settled launch's wallet is initialized once: a second initialize, from the operator or anyone, is refused.
    function test_AWalletCannotBeInitializedTwice() public {
        _bids(m.auction);
        _fail(m, 300);
        m.budget.settle();
        address w = m.budget.wallet();
        vm.prank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        VestingWalletUpgradeable(payable(w)).initialize(stranger, 0, 0);
        vm.prank(operator);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        VestingWalletUpgradeable(payable(w)).initialize(operator, 0, 0);
        assertEq(VestingWallet(payable(w)).owner(), operator, "a re-initialize moved the wallet");
    }

    /// @notice The wallet implementation every settlement clones refuses initialize: it was locked at construction, so nobody owns it.
    function test_TheWalletImplementationRefusesInitialize() public {
        address impl = LaunchOpsBudget(factory.BUDGET_IMPL()).WALLET_IMPL();
        assertTrue(impl.code.length > 0, "fixture: the budget implementation made a wallet implementation");
        assertEq(m.budget.WALLET_IMPL(), impl, "a clone of the budget names another wallet implementation");
        vm.prank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        VestingWalletUpgradeable(payable(impl)).initialize(stranger, 0, 0);
        assertEq(VestingWallet(payable(impl)).owner(), address(0), "the implementation has an owner");
    }

    /// @notice Two launches get two wallets: distinct, each with its own launch's operator, start and balances; a release from one leaves the other.
    function test_TwoLaunchesGetTwoIndependentWallets() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        (p.endBlock, p.operator) = (p.startBlock + 2 * BLOCKS, address(0x0E2)); // a later end, so a later launchBy, and another operator
        Made memory n = _launch(p);
        assertGt(n.launchBy, m.launchBy, "fixture: the second launch ends later");
        _bids(m.auction);
        _fail(m, 300);
        n.auction.setState(p.endBlock, true, 10_000e6 * Q * MPS);
        _migrate(n, 2_000e6, 400_000e18); // the second pool opens after the first launchBy and before its own
        m.budget.settle();
        n.budget.settle();
        VestingWallet a = VestingWallet(payable(m.budget.wallet()));
        VestingWallet b = VestingWallet(payable(n.budget.wallet()));
        assertTrue(address(a) != address(b), "two launches share a wallet");
        assertEq(abi.encode(a.owner(), a.start(), a.duration()), abi.encode(operator, m.launchBy, 365 days), "the first wallet's terms");
        assertEq(abi.encode(b.owner(), b.start(), b.duration()), abi.encode(p.operator, n.launchBy, 365 days), "the second wallet's terms");
        assertEq(abi.encode(IERC20(m.token).balanceOf(address(a)), usdc.balanceOf(address(a))), abi.encode(OPS, 0), "the first wallet's balances");
        assertEq(abi.encode(IERC20(n.token).balanceOf(address(b)), usdc.balanceOf(address(b))), abi.encode(OPS, 2_000e6), "the second wallet's balances");
        _warpTo(m.launchBy + 365 days);
        assertEq(b.releasable(n.token), OPS * (m.launchBy + 365 days - n.launchBy) / 365 days, "the second wallet vests on the first's curve");
        a.release(m.token);
        assertEq(a.released(m.token), OPS, "the first wallet did not release");
        assertEq(b.released(n.token), 0, "a release from the first wallet moved the second");
        assertEq(IERC20(n.token).balanceOf(address(b)), OPS, "the second wallet's tokens moved");
    }

    /// @notice On a failure the currency side is empty, while the ops tokens still vest to the operator from launchBy.
    function test_AFailureLeavesOnlyTheOpsTokensToStream() public {
        _bids(m.auction);
        _fail(m, 250);
        m.budget.settle();
        VestingWallet w = _wallet();
        assertEq(w.start(), m.launchBy, "the ops vest from somewhere other than launchBy");
        _warpTo(m.launchBy + 365 days);
        assertEq(w.releasable(address(usdc)), 0, "currency from a failure");
        assertEq(w.releasable(m.token), OPS, "the ops tokens stopped vesting");
    }

    /// @notice The team's currency never reaches the bids' pool: the wallet holds exactly the share, the budget exactly the pool, and every bid refunds whole.
    function test_TheTeamNeverPaysOutOfTheBidsPool() public {
        _bids(m.auction); // a raise of 3000, so the share is 600
        strat.openPool(m.key, PRICE);
        usdc.mint(address(m.budget), 600 + 300);
        strat.send(m.token, address(m.budget), 400_000e18);
        _open(m);
        m.budget.settle();
        assertEq(usdc.balanceOf(address(_wallet())), 600, "the wallet does not hold exactly the share");
        assertEq(usdc.balanceOf(address(m.budget)), m.budget.refundPool(), "the budget does not hold exactly the pool");
        uint256 paid = m.budget.refund(1, 0, 0) + m.budget.refund(2, 20, 0) + m.budget.refund(3, 20, end);
        assertEq(paid, 300, "the bids did not refund the whole pool");
        assertEq(usdc.balanceOf(address(_wallet())), 600, "a refund reached the team's share");
    }

    // ---- the LP's fees ----

    /// @dev A position in the launch pool, registered at the stand-in PositionManager, and its next fees.
    function _position(uint256 id, PoolKey memory k, uint256 quoteFee, uint256 tokenFee) internal {
        posm.setPosition(id, k);
        usdc.mint(address(posm), quoteFee);
        strat.send(m.token, address(posm), tokenFee);
        posm.setFee(address(usdc), quoteFee);
        posm.setFee(m.token, tokenFee);
    }

    /// @notice Fees are collected only from a pool that went live: not before settlement, and never after a failure.
    function test_FeesNeedALivePool() public {
        _position(7, m.key, 10e6, 1e18);
        vm.expectRevert(LaunchOpsBudget.NotLive.selector);
        m.budget.collectFees(7);
        _bids(m.auction);
        _fail(m, 250);
        m.budget.settle();
        vm.expectRevert(LaunchOpsBudget.NotLive.selector);
        m.budget.collectFees(7);
    }

    /// @notice The collection moves no liquidity, pays the currency to the operator at once and burns the token side.
    function test_FeesCollectAndPayAtOnce() public {
        _final(10_000e6);
        _migrate(m, 2_000e6, 400_000e18);
        m.budget.settle();
        _position(7, m.key, 10e6, 3e18);
        uint256 supply = IERC20(m.token).totalSupply();
        vm.prank(stranger);
        m.budget.collectFees(7);
        assertEq(posm.collections(), 1, "the PositionManager was not asked once");
        assertEq(usdc.balanceOf(operator), 10e6, "the operator did not get the fees at once");
        assertEq(supply - IERC20(m.token).totalSupply(), 3e18, "the token side did not burn");
        assertEq(IERC20(m.token).balanceOf(DEAD), 0, "DEAD holds the fee tokens");
        assertEq(IERC20(m.token).balanceOf(address(m.budget)), 0, "the budget kept fee tokens");
    }

    /// @notice Whoever calls it, the collection's currency lands at the operator and nowhere else: not the caller, not the budget, not the wallet.
    function test_FeesGoToTheOperator() public {
        _final(10_000e6);
        _migrate(m, 2_000e6, 400_000e18);
        m.budget.settle();
        _position(7, m.key, 10e6, 0);
        uint256 before = usdc.balanceOf(address(m.budget));
        vm.prank(stranger);
        m.budget.collectFees(7);
        assertEq(usdc.balanceOf(operator), 10e6, "the operator did not get the fees");
        assertEq(usdc.balanceOf(stranger), 0, "the caller got the fees");
        assertEq(usdc.balanceOf(address(m.budget)), before, "the fees reached the budget");
        assertEq(usdc.balanceOf(address(_wallet())), 2_000e6, "the fees reached the wallet");
    }

    /// @notice Fees never mix with the bids' pool: after a collection the budget holds exactly the pool, and every refund pays its share of it.
    function test_FeesNeverTouchTheRefundPool() public {
        _bids(m.auction); // a raise of 3000, so the share is 600
        strat.openPool(m.key, PRICE);
        usdc.mint(address(m.budget), 600 + 300);
        strat.send(m.token, address(m.budget), 400_000e18);
        _open(m);
        m.budget.settle();
        _position(7, m.key, 10e6, 1e18);
        m.budget.collectFees(7);
        assertEq(usdc.balanceOf(address(m.budget)), m.budget.refundPool(), "the fees joined the bids' pool");
        assertEq(m.budget.refund(1, 0, 0), 100, "300 * 1000 / 3000, the fees ignored");
        assertEq(m.budget.refund(2, 20, 0), 150, "300 * 1500 / 3000, the fees ignored");
        assertEq(m.budget.refund(3, 20, end), 50, "300 * 500 / 3000, the fees ignored");
        assertEq(usdc.balanceOf(address(m.budget)), 0, "the pool did not drain to the atom");
    }

    /// @notice A position outside the launch pool is refused, before the PositionManager is asked to touch it.
    function test_AForeignPositionIsRefused() public {
        _final(10_000e6);
        _migrate(m, 2_000e6, 400_000e18);
        m.budget.settle();
        PoolKey memory other = m.key;
        other.fee = 3_000;
        _position(8, other, 10e6, 1e18);
        vm.expectRevert(LaunchOpsBudget.NotOurPosition.selector);
        m.budget.collectFees(8);
        assertEq(posm.collections(), 0, "the PositionManager was asked");
    }

    // ---- the surface ----

    /// @notice The budget answers no approve, transfer, multicall, NFT-receiver or signature selector, and takes no ETH.
    /// @notice Nor the payment door and stream the wallet replaced, nor the getters `terms` replaced, even from the operator after settlement.
    function test_TheSurfaceHasNoOtherDoor() public {
        _final(10_000e6);
        _migrate(m, 2_000e6, 400_000e18);
        m.budget.settle();
        bytes[] memory calls = new bytes[](17);
        calls[0] = abi.encodeWithSignature("approve(address,uint256)", stranger, 1);
        calls[1] = abi.encodeWithSignature("transfer(address,uint256)", stranger, 1);
        calls[2] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(m.budget), stranger, 7);
        calls[3] = abi.encodeWithSignature("multicall(bytes[])", new bytes[](0));
        calls[4] = abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", stranger, stranger, 7, "");
        calls[5] = abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), "");
        calls[6] = abi.encodeWithSignature("setApprovalForAll(address,bool)", stranger, true);
        calls[7] = abi.encodeWithSignature("execute(address,bytes)", stranger, "");
        calls[8] = abi.encodeWithSignature("pay(address,address,uint256,string)", address(usdc), operator, 1, "");
        calls[9] = abi.encodeWithSignature("available(address)", address(usdc));
        calls[10] = abi.encodeWithSignature("token()");
        calls[11] = abi.encodeWithSignature("poolId()");
        calls[12] = abi.encodeWithSignature("operator()");
        calls[13] = abi.encodeWithSignature("opsAllocation()");
        calls[14] = abi.encodeWithSignature("teamShareBps()");
        calls[15] = abi.encodeWithSignature("reserve()");
        calls[16] = abi.encodeWithSignature("auction()");
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(operator);
            (bool ok,) = address(m.budget).call(calls[i]);
            assertFalse(ok, string.concat("the budget answered a selector it must not have, call #", vm.toString(i)));
        }
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool sent,) = address(m.budget).call{value: 1}("");
        assertFalse(sent, "the budget took ETH");
    }

    /// @notice `terms` reads back exactly the clone's args, as the factory wrote them for this launch.
    function test_TermsDecodeTheCloneArgs() public view {
        LaunchOpsBudget.Terms memory t = m.budget.terms();
        assertEq(t.token, m.token, "token");
        assertEq(PoolId.unwrap(t.pool), PoolId.unwrap(m.key.toId()), "pool");
        assertEq(t.operator, operator, "operator");
        assertEq(t.opsAllocation, OPS, "ops allocation");
        assertEq(t.shareBps, SHARE, "share");
        assertEq(t.reserve, SUPPLY, "reserve");
        assertEq(t.launchBy, m.launchBy, "launchBy");
    }
}
