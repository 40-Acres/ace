// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Bid, Checkpoint, LiquidityAllocationBracket} from "../../src/interfaces/ILaunchAuction.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {MockBlacklistERC20} from "../mocks/MockBlacklistERC20.sol";
import {MockLaunchAuction} from "./MockLaunchAuction.sol";
import {ReenteringQuote} from "./ReenteringQuote.sol";
import {RunwayFixture} from "./RunwayFixture.sol";
import {RunwaySalt} from "./RunwayMocks.sol";

/// @notice A cut recipient or bid owner that, called back by a ReenteringQuote, makes one armed call and bubbles its revert.
contract CutReenterer {
    function poke(address target, bytes calldata data) external {
        Address.functionCall(target, data);
    }
}

/// @title RunwayProtocolCutTest
/// @notice UNIT rows for the protocol's cut of a live launch's raise: carved beside the team's share, booked at settlement, paid on demand.
/// @notice A failed launch owes nothing, the team is senior to the cut, and a recipient that refuses never blocks settlement or a refund.
/// @dev Every launch here comes from a factory taking CUT; the deployed strategy runs the same split in the fork suite.
contract RunwayProtocolCutTest is RunwayFixture {
    uint24 internal constant MPS = 1e7;
    uint256 internal constant Q = 1 << 96;
    uint160 internal constant PRICE = 1 << 96;
    uint256 internal constant CUT = 100; // 1% of the raise

    Made internal m;
    uint64 internal end;

    function setUp() public override {
        super.setUp();
        factory = _factory(BLOCK_SECONDS, FEE, SPACING, CUT);
        m = _launch();
        end = m.auction.endBlock();
    }

    // ---- the auction's state, set by hand ----

    function _bid(address owner, uint256 maxPrice, uint256 amountQ96) internal pure returns (Bid memory) {
        return Bid({startBlock: 10, startCumulativeMps: 0, exitedBlock: 0, maxPrice: maxPrice, owner: owner, amountQ96: amountQ96, tokensFilled: 0});
    }

    function _cp(uint256 clearing, uint24 cumMps, uint64 prev, uint64 next, uint256 raisedAtClearingX7) internal pure returns (Checkpoint memory c) {
        (c.clearingPrice, c.cumulativeMps, c.prev, c.next, c.currencyRaisedAtClearingPriceQ96X7) = (clearing, cumMps, prev, next, raisedAtClearingX7);
    }

    /// @dev Three bids spending 1000 + 1500 + 500, the auction's whole raise of 3000: the same shape the budget's own unit rows use.
    function _bids(MockLaunchAuction a) internal {
        uint64 e = a.endBlock();
        a.setBid(1, _bid(address(0x0B1), 10, 1_000 * Q));
        a.setBid(2, _bid(address(0x0B2), 5, 2_000 * Q));
        a.setBid(3, _bid(address(0x0B3), 4, 1_000 * Q));
        a.setCheckpoint(10, _cp(3, 0, 0, 20, 0));
        a.setCheckpoint(20, _cp(3, 5e6, 10, e, 0));
        a.setCheckpoint(e, _cp(5, MPS, 20, type(uint64).max, 500 * Q * MPS));
        a.setTick(5, 2_000 * Q);
        a.setState(e, true, 3_000 * Q * MPS);
    }

    /// @dev The fixture launch's auction, final at a raise of `raised` atoms and no bids.
    function _final(uint256 raised) internal {
        m.auction.setState(end, true, raised * Q * MPS);
    }

    /// @dev A successful migration, then launchBy passing: the pool opens, the budget gets `quote` of the raise and `left` of the reserve.
    function _migrate(Made memory x, uint256 quote, uint256 left) internal {
        strat.openPool(x.key, PRICE);
        usdc.mint(address(x.budget), quote);
        strat.send(x.token, address(x.budget), left);
        _warpTo(x.launchBy + 1);
    }

    /// @dev A failed migration, then launchBy passing: no pool, and the budget gets `quote` and the WHOLE reserve.
    function _fail(Made memory x, uint256 quote) internal {
        usdc.mint(address(x.budget), quote);
        strat.send(x.token, address(x.budget), SUPPLY);
        _warpTo(x.launchBy + 1);
    }

    function _wallet(Made memory x) internal view returns (address) {
        return x.budget.wallet();
    }

    /// @dev A launch on a factory of its own, raising in `quote` and paying CUT to `recipient`: the three bids, and the pool opened live.
    /// @dev The raise is 3000, so the share is 600 and the cut 30; the caller funds the budget in `quote` and warps past launchBy.
    function _liveOn(address quote, address recipient) internal returns (LaunchOpsBudget budget, MockLaunchAuction a) {
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(manager), address(strat));
        LaunchTokenFactory f = new LaunchTokenFactory(address(ace), address(strat), quote, BLOCK_SECONDS, FEE, SPACING, salt, recipient, CUT);
        a = new MockLaunchAuction();
        strat.setNext(address(a));
        vm.prank(team);
        address t = f.launch(_input());
        (address lock,, address b) = f.launchOf(t);
        budget = LaunchOpsBudget(b);
        a.set(t, quote, lock, end);
        a.setUnsold(b, 0);
        _bids(a);
        (address c0, address c1) = t < quote ? (t, quote) : (quote, t);
        strat.openPool(PoolKey(Currency.wrap(c0), Currency.wrap(c1), FEE, SPACING, IHooks(address(f.HOOK()))), PRICE);
        strat.send(t, b, 400_000e18);
    }

    // ---- settlement books the cut ----

    /// @notice A live launch: the team's share whole, the cut booked beside it and kept in the budget, never pushed by settlement.
    function test_ALiveSettleBooksTheCutBesideTheTeamShare() public {
        _final(10_000e6);
        _migrate(m, 2_100e6, 400_000e18);
        vm.expectEmit(address(m.budget));
        emit LaunchOpsBudget.Settled(true, 2_000e6, 100e6, 0, 400_000e18);
        vm.prank(stranger);
        m.budget.settle();
        assertEq(usdc.balanceOf(_wallet(m)), 2_000e6, "the cut came out of the team's share");
        assertEq(m.budget.protocolOwed(), 100e6, "the cut is not a hundredth of the raise");
        assertEq(m.budget.refundPool(), 0, "the cut reached the bids");
        assertEq(usdc.balanceOf(address(m.budget)), 100e6, "the budget does not hold exactly the cut");
        assertEq(usdc.balanceOf(cutSink), 0, "settlement pushed the cut");
    }

    /// @notice Currency past the share and the cut still goes to the bids: the cut reads the recorded raise, never the balance.
    function test_ASurplusStillGoesToTheBids() public {
        _final(10_000e6);
        _migrate(m, 2_600e6, 400_000e18);
        m.budget.settle();
        assertEq(usdc.balanceOf(_wallet(m)), 2_000e6, "the team's share moved with the surplus");
        assertEq(m.budget.protocolOwed(), 100e6, "the cut grew with the surplus");
        assertEq(m.budget.refundPool(), 500e6, "the surplus did not go to the bids");
    }

    /// @notice The team is senior: a balance between the share and the share plus the cut pays the share whole and the cut what is left.
    function test_TheTeamIsSeniorToTheCutOnAShortBalance() public {
        _final(10_000e6);
        _migrate(m, 2_050e6, 400_000e18);
        m.budget.settle();
        assertEq(usdc.balanceOf(_wallet(m)), 2_000e6, "the team's share was cut short");
        assertEq(m.budget.protocolOwed(), 50e6, "the cut is not what was left past the share");
        assertEq(m.budget.refundPool(), 0, "the bids got some");
    }

    /// @notice A balance short of the share pays the team all of it and the protocol nothing.
    function test_ShortOfTheShareTheCutIsNothing() public {
        _final(10_000e6);
        _migrate(m, 1_900e6, 400_000e18);
        m.budget.settle();
        assertEq(usdc.balanceOf(_wallet(m)), 1_900e6, "the team's currency is not the balance");
        assertEq(m.budget.protocolOwed(), 0, "a cut out of a short share");
    }

    /// @notice A failed launch owes the protocol nothing: the bids share the whole raise and `payProtocol` moves nothing.
    function test_AFailedSettleOwesTheProtocolNothing() public {
        _final(10_000e6);
        _fail(m, 10_000e6);
        vm.expectEmit(address(m.budget));
        emit LaunchOpsBudget.Settled(false, 0, 0, 10_000e6, SUPPLY);
        m.budget.settle();
        assertEq(m.budget.protocolOwed(), 0, "a failure owes a cut");
        assertEq(m.budget.refundPool(), 10_000e6, "the bids do not share the whole raise");
        assertEq(m.budget.payProtocol(), 0, "a failure paid a cut");
        assertEq(usdc.balanceOf(cutSink), 0, "the recipient got currency from a failure");
    }

    // ---- payment ----

    /// @notice Anyone may pay the booked cut, and it lands at the recipient once: a second call pays nothing and leaves the bids' pool whole.
    function test_PayProtocolPaysTheRecipientOnce() public {
        _final(10_000e6);
        _migrate(m, 2_600e6, 400_000e18);
        m.budget.settle();
        vm.prank(stranger);
        assertEq(m.budget.payProtocol(), 100e6, "the payment is not the booked cut");
        assertEq(usdc.balanceOf(cutSink), 100e6, "the cut did not land at the recipient");
        assertEq(usdc.balanceOf(stranger), 0, "the caller got the cut");
        assertEq(m.budget.protocolOwed(), 0, "the paid cut is still owed");
        assertEq(m.budget.payProtocol(), 0, "the cut was paid twice");
        assertEq(usdc.balanceOf(cutSink), 100e6, "a second call moved currency");
        assertEq(usdc.balanceOf(address(m.budget)), m.budget.refundPool(), "the budget does not hold exactly the bids' pool");
    }

    /// @notice Before settlement nothing is owed, so `payProtocol` moves nothing, and settlement still books the cut afterwards.
    function test_PayProtocolMovesNothingBeforeSettlement() public {
        _final(10_000e6);
        _migrate(m, 2_100e6, 400_000e18);
        assertEq(m.budget.payProtocol(), 0, "a payment before settlement");
        assertEq(usdc.balanceOf(address(m.budget)), 2_100e6, "currency left the budget before settlement");
        m.budget.settle();
        assertEq(m.budget.protocolOwed(), 100e6, "an early call cost the cut");
    }

    /// @notice A recipient the quote refuses never blocks settlement or a refund: only the cut waits, and pays once the recipient is cleared.
    function test_ARefusingRecipientNeverBlocksSettleOrRefunds() public {
        MockBlacklistERC20 bq = new MockBlacklistERC20("USD Coin", "USDC", 6);
        (LaunchOpsBudget budget,) = _liveOn(address(bq), cutSink);
        address b = address(budget);
        bq.mint(b, 600 + 30 + 300);
        _warpTo(m.launchBy + 1);

        bq.setBlacklisted(cutSink, true);
        budget.settle();
        assertTrue(budget.live(), "fixture: the launch read failed");
        assertEq(bq.balanceOf(budget.wallet()), 600, "a refusing recipient cost the team its share");
        assertEq(budget.protocolOwed(), 30, "the cut was not booked");
        assertEq(budget.refund(1, 0, 0) + budget.refund(2, 20, 0) + budget.refund(3, 20, end), 300, "a refusing recipient blocked the refunds");
        vm.expectRevert("blacklisted");
        budget.payProtocol();
        assertEq(budget.protocolOwed(), 30, "a refused payment lost the cut");

        bq.setBlacklisted(cutSink, false);
        assertEq(budget.payProtocol(), 30, "the cleared recipient was not paid");
        assertEq(bq.balanceOf(cutSink), 30, "the cut did not land");
        assertEq(bq.balanceOf(b), 0, "the budget kept currency past the bids and the cut");
    }

    /// @notice With nothing owed, `payProtocol` never calls the quote: before settlement, once paid, and after a failure, it returns zero.
    /// @notice The quote here refuses a zero transfer to the recipient, as Circle's does to a blacklisted address, so a call would revert.
    /// @notice Kills dropping the nothing-owed early return, which no balance can see: a zero transfer moves nothing.
    function test_PayProtocolNeverCallsTheQuoteWhenNothingIsOwed() public {
        vm.mockCallRevert(address(usdc), abi.encodeCall(IERC20.transfer, (cutSink, 0)), "a zero transfer to the recipient");
        _final(10_000e6);
        _migrate(m, 2_100e6, 400_000e18);
        assertEq(m.budget.payProtocol(), 0, "a payment before settlement");
        m.budget.settle();
        assertEq(m.budget.payProtocol(), 100e6, "fixture: the booked cut pays");
        assertEq(m.budget.payProtocol(), 0, "a payment once paid");
        Made memory x = _launch();
        x.auction.setState(x.auction.endBlock(), true, 10_000e6 * Q * MPS);
        _fail(x, 10_000e6);
        x.budget.settle();
        assertEq(x.budget.payProtocol(), 0, "a payment after a failure");
        assertEq(usdc.balanceOf(cutSink), 100e6, "the recipient got more than the one live cut");
    }

    /// @notice The cut's own transfer cannot re-enter the budget: a recipient calling refund, payProtocol or owed from inside it reverts the payment.
    /// @notice The cut stays owed through every refused payment and pays once the recipient stops re-entering.
    /// @notice Kills dropping `nonReentrant` from `payProtocol`: each re-entry would then run, and the payment land.
    function test_PayProtocolRefusesReentryFromTheRecipient() public {
        ReenteringQuote rq = new ReenteringQuote();
        CutReenterer r = new CutReenterer();
        (LaunchOpsBudget budget,) = _liveOn(address(rq), address(r));
        rq.mint(address(budget), 600 + 30 + 300);
        _warpTo(m.launchBy + 1);
        budget.settle();
        assertEq(budget.protocolOwed(), 30, "fixture: the cut was not booked");

        bytes[3] memory reentries = [
            abi.encodeCall(LaunchOpsBudget.refund, (1, 0, 0)), abi.encodeCall(LaunchOpsBudget.payProtocol, ()), abi.encodeCall(LaunchOpsBudget.owed, (1, 0, 0))
        ];
        for (uint256 i; i < reentries.length; ++i) {
            rq.arm(address(r), abi.encodeCall(CutReenterer.poke, (address(budget), reentries[i])));
            vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
            budget.payProtocol();
            assertEq(budget.protocolOwed(), 30, "a refused payment lost the cut");
        }
        assertFalse(budget.refunded(1), "a re-entered refund was marked");

        rq.arm(address(0), "");
        assertEq(budget.payProtocol(), 30, "fixture: unarmed, the payment lands");
        assertEq(rq.balanceOf(address(r)), 30, "the recipient does not hold the cut");
    }

    /// @notice A refund's transfer cannot reach `payProtocol`: a bid owner calling it from inside its refund reverts the refund, and the cut stays owed.
    /// @notice Kills dropping `nonReentrant` from `payProtocol`, which would pay the cut from inside another verb's transfer.
    function test_ARefundCannotReenterPayProtocol() public {
        ReenteringQuote rq = new ReenteringQuote();
        CutReenterer r = new CutReenterer();
        (LaunchOpsBudget budget, MockLaunchAuction a) = _liveOn(address(rq), cutSink);
        a.setBid(1, _bid(address(r), 10, 1_000 * Q));
        rq.mint(address(budget), 600 + 30 + 300);
        _warpTo(m.launchBy + 1);
        budget.settle();

        rq.arm(address(r), abi.encodeCall(CutReenterer.poke, (address(budget), abi.encodeCall(LaunchOpsBudget.payProtocol, ()))));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        budget.refund(1, 0, 0);
        assertEq(budget.protocolOwed(), 30, "a re-entered payment cleared the cut");
        assertEq(rq.balanceOf(cutSink), 0, "a re-entered payment reached the recipient");

        rq.arm(address(0), "");
        assertEq(budget.refund(1, 0, 0), 100, "fixture: unarmed, the refund pays");
        assertEq(budget.payProtocol(), 30, "fixture: unarmed, the payment lands");
    }

    /// @notice Settlement conserves the balance, live or failed: team + cut + bids' pool is the whole balance, each term as the split defines it.
    /// @notice Once the cut is paid, the budget holds exactly the bids' pool.
    function testFuzz_SettleConservesTheBalance(uint64 raise, uint64 received, uint16 share, bool fails) public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.teamShareBps = bound(share, 0, factory.MAX_TEAM_SHARE_BPS());
        Made memory x = _launch(p);
        uint256 raised = bound(raise, 0, type(uint64).max);
        x.auction.setState(p.endBlock, true, raised * Q * MPS);
        uint256 bal = bound(received, 0, type(uint64).max);
        if (fails) _fail(x, bal);
        else _migrate(x, bal, 400_000e18);
        x.budget.settle();

        uint256 team = usdc.balanceOf(_wallet(x));
        uint256 cut = x.budget.protocolOwed();
        assertEq(team + cut + x.budget.refundPool(), bal, "the split does not add up to the balance");
        assertEq(team, fails ? 0 : Math.min(bal, raised * p.teamShareBps / 10_000), "the team's currency");
        assertEq(cut, fails ? 0 : Math.min(bal - team, raised * CUT / 10_000), "the cut");
        assertGe(usdc.balanceOf(address(x.budget)), x.budget.refundPool() - x.budget.refundedOut() + cut, "the budget holds less than it owes");
        x.budget.payProtocol();
        assertEq(usdc.balanceOf(cutSink), cut, "the recipient did not get the cut");
        assertEq(usdc.balanceOf(address(x.budget)), x.budget.refundPool(), "the budget does not hold exactly the bids' pool after the cut");
    }

    /// @notice A factory deployed at a zero cut settles exactly as Runway did before the cut: nothing booked, nothing paid, the whole bracket's rest.
    function test_AZeroCutIsTodaysSettle() public {
        factory = _factory(BLOCK_SECONDS, FEE, SPACING, 0);
        LaunchTokenFactory.LaunchInput memory p = _input();
        Made memory x = _launch(p);
        LiquidityAllocationBracket[] memory b = abi.decode(strat.initializers(address(x.auction)).lpAllocationSchedule, (LiquidityAllocationBracket[]));
        assertEq(b[0].rate, MPS * (10_000 - SHARE) / 10_000, "a zero cut moved the bracket");
        x.auction.setState(p.endBlock, true, 10_000e6 * Q * MPS);
        _migrate(x, 2_000e6, 400_000e18);
        vm.expectEmit(address(x.budget));
        emit LaunchOpsBudget.Settled(true, 2_000e6, 0, 0, 400_000e18);
        x.budget.settle();
        assertEq(x.budget.protocolOwed(), 0, "a zero cut booked something");
        assertEq(x.budget.payProtocol(), 0, "a zero cut paid something");
    }

    // ---- refunds never reach the cut ----

    /// @notice Refunds never reach the booked cut: with the bids' spends set past the raise by hand, the last refunds clamp to the bids' pool.
    /// @notice The cut then pays whole and the budget is left with nothing; the clamp is what keeps the cut, since the balance still holds it.
    /// @notice Kills a clamp to the balance, which would hand the cut to the bids, and no clamp, whose overdraw reverts.
    function test_RefundsNeverReachTheBookedCut() public {
        _bids(m.auction);
        m.auction.setState(end, true, 2_000 * Q * MPS); // the bids spent 3000 of a raise of 2000: the share is 400 and the cut 20
        _migrate(m, 400 + 20 + 250, 400_000e18);
        m.budget.settle();
        assertEq(abi.encode(m.budget.protocolOwed(), m.budget.refundPool()), abi.encode(20, 250), "fixture: the cut and the bids' pool");
        assertEq(m.budget.refund(1, 0, 0), 125, "250 * 1000 / 2000");
        assertEq(m.budget.refund(2, 20, 0), 125, "187 by share, clamped to the 125 left of the pool");
        assertEq(m.budget.refund(3, 20, end), 0, "62 by share, clamped to the empty pool");
        assertEq(m.budget.protocolOwed(), 20, "a refund reduced the booked cut");
        assertEq(m.budget.payProtocol(), 20, "the cut did not pay whole after the refunds");
        assertEq(usdc.balanceOf(address(m.budget)), 0, "the budget kept currency past the pool and the cut");
    }

    /// @notice However far the bids' spends run past the raise (set short by hand, up to half), every refund pays and their sum stays in the pool.
    /// @notice The booked cut is untouched by every refund and pays whole afterwards, leaving the budget exactly what the refunds left of the pool.
    function testFuzz_RefundsNeverReachTheBookedCut(uint64 surplus, uint8 count, uint64 short, uint64 seed) public {
        uint256 n = bound(count, 2, 30);
        MockLaunchAuction a = m.auction;
        a.setCheckpoint(10, _cp(3, 0, 0, end, 0));
        a.setCheckpoint(end, _cp(5, MPS, 10, type(uint64).max, 0));
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 amountQ96 = (1e6 + uint256(keccak256(abi.encode(seed, i))) % 1e9) * Q + uint256(keccak256(abi.encode(i, seed))) % Q;
            a.setBid(i, _bid(address(uint160(0x1000 + i)), 10, amountQ96));
            total += amountQ96;
        }
        uint256 raised = total - Math.mulDiv(total, bound(short, 0, 5_000), 10_000);
        a.setState(end, true, raised * MPS);
        uint256 cut = Math.mulDiv(raised, CUT, 10_000 * Q);
        uint256 pool = bound(surplus, 1, type(uint64).max);
        _migrate(m, Math.mulDiv(raised, SHARE, 10_000 * Q) + cut + pool, 400_000e18);
        m.budget.settle();
        assertEq(abi.encode(m.budget.protocolOwed(), m.budget.refundPool()), abi.encode(cut, pool), "fixture: the cut and the bids' pool");

        uint256 paid;
        for (uint256 i; i < n; ++i) {
            paid += m.budget.refund(i, 0, 0);
        }
        assertLe(paid, pool, "refunds paid past the bids' pool");
        assertEq(m.budget.protocolOwed(), cut, "a refund reduced the booked cut");
        assertEq(m.budget.payProtocol(), cut, "the cut did not pay whole after the refunds");
        assertEq(usdc.balanceOf(cutSink), cut, "the recipient does not hold the cut");
        assertEq(usdc.balanceOf(address(m.budget)), pool - paid, "the budget holds other than what the refunds left of the pool");
    }

    // ---- the factory fixes the cut ----

    /// @notice The share and the cut together set the one bracket: the pool gets the raise less both, at every share the cap allows.
    function test_TheBracketLeavesTheShareAndTheCutToTheBudget() public {
        uint256[3] memory shares = [uint256(0), 1_234, 5_000];
        uint24[3] memory rates = [uint24(9_900_000), 8_666_000, 4_900_000];
        for (uint256 i; i < 3; ++i) {
            LaunchTokenFactory.LaunchInput memory p = _input();
            p.teamShareBps = shares[i];
            Made memory x = _launch(p);
            LiquidityAllocationBracket[] memory b = abi.decode(strat.initializers(address(x.auction)).lpAllocationSchedule, (LiquidityAllocationBracket[]));
            assertEq(b[0].rate, rates[i], "the bracket is not one less the share and the cut");
        }
    }

    /// @notice The cut is capped at 3%: one basis point over is refused at construction, the cap itself is accepted.
    function test_TheConstructorRefusesACutOverTheCap() public {
        assertEq(factory.MAX_CUT_BPS(), 300, "the cap");
        vm.expectRevert(LaunchTokenFactory.CutOverCap.selector);
        new LaunchTokenFactory(address(ace), address(strat), address(usdc), BLOCK_SECONDS, FEE, SPACING, bytes32(0), cutSink, 301);
        assertEq(_factory(BLOCK_SECONDS, FEE, SPACING, 300).CUT_BPS(), 300, "the cap itself was refused");
    }

    /// @notice A cut owed to a zero recipient is refused at construction, since it could never be paid.
    /// @notice With no cut there is nothing to pay, so a zero recipient is accepted and every launch settles as before.
    function test_TheConstructorRefusesAZeroRecipientOnlyWithACut() public {
        vm.expectRevert(LaunchTokenFactory.ZeroCutRecipient.selector);
        new LaunchTokenFactory(address(ace), address(strat), address(usdc), BLOCK_SECONDS, FEE, SPACING, bytes32(0), address(0), CUT);
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(manager), address(strat));
        LaunchTokenFactory f = new LaunchTokenFactory(address(ace), address(strat), address(usdc), BLOCK_SECONDS, FEE, SPACING, salt, address(0), 0);
        assertEq(LaunchOpsBudget(f.BUDGET_IMPL()).CUT_RECIPIENT(), address(0), "a zero-cut factory refused a zero recipient");
    }

    /// @notice Every budget the factory makes carries the factory's cut and recipient: the implementation's, which no launch input can change.
    function test_TheBudgetCarriesTheFactorysCut() public view {
        assertEq(factory.CUT_BPS(), CUT, "the factory's cut");
        LaunchOpsBudget impl = LaunchOpsBudget(factory.BUDGET_IMPL());
        assertEq(abi.encode(impl.CUT_BPS(), impl.CUT_RECIPIENT()), abi.encode(CUT, cutSink), "the implementation's cut and recipient");
        assertEq(abi.encode(m.budget.CUT_BPS(), m.budget.CUT_RECIPIENT()), abi.encode(CUT, cutSink), "a clone reads another cut or recipient");
    }
}
