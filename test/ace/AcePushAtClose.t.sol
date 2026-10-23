// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {Ace, PushGasShort, PushRefused} from "../../src/ace/hub/Ace.sol";
import {Lender} from "../../src/ace/hub/Lender.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockHostileGasERC20} from "../mocks/MockHostileGasERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AcePushAtClose
/// @notice RED BY DESIGN, written before the push exists: at a TERMINAL close the hub attempts one transfer
/// @notice of the market lender's pooled QUOTE credit to them, fenced so the attempt cannot fail the HUB VERB.
/// @notice On failure `pool.owed` is restored and a fixed-size event fires, leaving today's state byte-for-byte.
/// @dev THE PROPERTY IS "the attempt cannot fail the HUB VERB": the push is handed a fixed budget and its tail is reserved.
/// @dev The caller's own limit can still fail it, by name (`PushGasShort`); `AcePushGasBudget` owns that side.
/// @dev What follows the verb in a caller's chain is funded against the budget, and the exposure row documents that.
/// @dev QUOTE ONLY: collateral units stay credited-then-pulled.
/// @dev EVERY HOSTILITY IS ARMED AFTER THE DRAW. The open pays the borrower by `safeTransfer`, so a quote
/// @dev armed at setUp would kill the fixture rather than the door under test.
contract AcePushAtCloseTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockHostileGasERC20 internal usdc; // the QUOTE, armable as reverter / gas burner / return bomb
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE); // the market's one lender, so the pool is wholly hers
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant DEPOSIT = 400_000e6;
    uint256 internal constant PRINCIPAL = 40_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant ONE_MIB_WORDS = 32_768; // the design record measures this at ~2,200,984 gas to copy

    /// @dev TOPICS TAKEN FROM THE DECLARED EVENTS, never from a signature string. These rows were written
    /// @dev before the push existed and MIRRORED `LenderPushFailed` locally, with a hand-written keccak of its
    /// @dev signature; `src` carries it now. A mirrored copy plus a string literal is the hazard the rows are
    /// @dev least able to survive: re-shape the library event and BOTH keep compiling while every log
    /// @dev assertion quietly stops matching, so the fallback rows would go green against an event the hub no
    /// @dev longer emits. Derived from the type, a re-shape moves these constants with it.
    /// @dev THE SHAPE IS STILL THE REQUIREMENT it always was -- two indexed addresses and the amount, never the
    /// @dev revert reason, because carrying the reason as `bytes` makes the tail a function of the callee's
    /// @dev returndata again, which is the one thing a fixed tail cannot be sized against.
    bytes32 internal constant PUSH_FAILED_SIG = Lender.LenderPushFailed.selector;
    bytes32 internal constant COLLECTED_SIG = Lender.Collected.selector;
    bytes32 internal constant SWEEP_FAILED_SIG = Ace.RevenueSweepFailed.selector;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockHostileGasERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(address(usdc), address(coll));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = alice;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(ace), DEPOSIT);
        ace.deposit(mid, DEPOSIT);
        vm.stopPrank();
    }

    /* ------------------------------- helpers ------------------------------- */

    /// @dev The lender's uncollected QUOTE credit: what a push moves and what a fallback must restore exactly.
    function _owed() internal view returns (uint256) {
        (,, uint256 owed) = read.lenderPools(alice, address(usdc));
        return owed;
    }

    /// @dev Whether the hub emitted `sig` during the recorded window, scanned rather than matched by POSITION.
    /// @dev `vm.expectEmit` binds to the NEXT event, and a terminal close emits several -- the piggyback sweep's
    /// @dev among them -- so ordering would make these rows assert the hub's event sequence by accident.
    function _sawFromHub(bytes32 sig) internal returns (bool, uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != sig) continue;
            return (true, abi.decode(logs[i].data, (uint256)));
        }
        return (false, 0);
    }

    /// @dev The same scan for `Collected`, whose recipient is its third indexed topic and whose data is the amount.
    function _sawCollectedFromHub() internal returns (bool, address, uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != COLLECTED_SIG) continue;
            address to = address(uint160(uint256(logs[i].topics[3])));
            return (true, to, abi.decode(logs[i].data, (uint256)));
        }
        return (false, address(0), 0);
    }

    /// @dev The same scan without decoding, for an event whose non-indexed half is not one word.
    function _sawSigFromHub(bytes32 sig) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ace) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    /// @dev The whole roll window has to be out before `settleExpired` will take a loan: inside it the door
    /// @dev answers `RollWindowOpen()`, because a paid roll still has standing. Expiry alone is NOT enough.
    function _warpPastTheRollWindow(uint256 loanId) internal {
        uint64 tenor = read.loan(loanId).tenor;
        vm.warp(uint256(read.loan(loanId).expiry) + MarketInit.autoRefinanceWindow(tenor) + 1);
    }

    function _open(uint64 tenor) internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Repay the whole debt, which is the CLOSING repay and one of the four terminal doors.
    function _repayInFull(uint256 loanId) internal {
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    /// @dev An UNARMED loan one second past expiry: `forceClose` takes its settle branch, `settleExpired` settles.
    function _expiredUnarmed() internal returns (uint256 loanId) {
        loanId = _open(TEN30);
        vm.warp(uint256(read.loan(loanId).expiry) + 1);
    }

    /// @dev An ARMED loan past expiry whose continuation the gate admits: `forceClose` ROLLS rather than settling.
    function _expiredArmed() internal returns (uint256 loanId) {
        loanId = _open(TEN30);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN30, 0, 0);
        vm.warp(uint256(read.loan(loanId).expiry) + 1);
    }

    /* ====================== 1. THE SUCCESS PATH, ONE ROW PER DOOR ====================== */

    /// @notice THE CLOSING REPAY pays the lender's whole pooled credit out, in the same call that closes the loan.
    /// @dev WHOLE POOL, never the close's delta: no arithmetic, no rounding direction, no new ledger field, and
    /// @dev a fallback that is a pure zero-then-restore. So the assertion is on the POOL going to zero.
    /// @dev `Collected` is the SUCCESS event, the same one `collect` emits, so an indexer sees one event
    /// @dev whichever route moved the money.
    function test_Repay_TheClosingRepayPushesTheWholePoolToTheLender() public {
        uint256 loanId = _open(TEN30);
        uint256 before = usdc.balanceOf(alice);

        _repayInFull(loanId);

        uint256 paid = usdc.balanceOf(alice) - before;
        assertGt(paid, 0, "the closing repay paid the lender nothing: the push did not happen");
        assertEq(_owed(), 0, "and the pool it should have emptied still carries credit");
        assertTrue(read.loan(loanId).closedAt != 0, "premise: the repay really closed the loan");
        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), 0, "a collect afterwards must be a no-op, the money having gone home");
    }

    /// @notice And the success path announces itself with `Collected`, the verb's own event.
    function test_Repay_TheSuccessfulPushEmitsCollected() public {
        uint256 loanId = _open(TEN30);
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);

        vm.recordLogs();
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();

        /// @dev The amount is the pool AT THE CLOSE, which the repay itself raises, so it is checked as
        /// @dev non-zero rather than predicted here; the row above pins the figure through the balance.
        (bool saw, address to, uint256 amount) = _sawCollectedFromHub();
        assertTrue(saw, "the successful push emitted no `Collected`, so an indexer sees no payout at all");
        assertEq(to, alice, "the push names the lender as its recipient: a close never pays anyone else");
        assertGt(amount, 0, "and it announced a zero, which is not what moved");
    }

    /// @notice `settleExpired` pushes, which FALSIFIES this door's own doctrine sentence, by ruling.
    /// @dev "this door must not acquire a token transfer it can fail on" was the text; the user ruled the push
    /// @dev anyway, because the UNITS leg stays a pure ledger write, so settleability at tenor survives by
    /// @dev construction rather than by the door staying token-free. The hostile rows below are that claim's proof.
    function test_SettleExpired_PushesTheWholePool() public {
        uint256 loanId = _open(TEN30);
        _warpPastTheRollWindow(loanId);
        uint256 before = usdc.balanceOf(alice);

        vm.prank(keeper);
        ace.settleExpired(loanId);

        assertGt(usdc.balanceOf(alice) - before, 0, "the unpaid settle door paid the lender nothing");
        assertEq(_owed(), 0, "and left the pool it should have emptied");
        assertTrue(read.loan(loanId).closedAt != 0, "premise: the loan really settled");
    }

    /// @notice `forceClose`'s SETTLE branch pushes. Its roll branch does not, which the exclusion row pins.
    function test_ForceClose_TheSettleBranchPushesTheWholePool() public {
        uint256 loanId = _expiredUnarmed();
        uint256 before = usdc.balanceOf(alice);

        vm.prank(keeper);
        ace.forceClose(loanId);

        assertGt(usdc.balanceOf(alice) - before, 0, "the paid settle door paid the lender nothing");
        assertEq(_owed(), 0, "and left the pool it should have emptied");
        assertTrue(read.loan(loanId).closedAt != 0, "premise: the loan really settled rather than rolling");
    }

    /// @notice `finalize` pushes. It ALWAYS settles, so the implementation needs no terminal detection here at all.
    function test_Finalize_PushesTheWholePool() public {
        uint256 loanId = _open(TEN30);
        record.setBelow(true);
        assertTrue(read.settleable(loanId), "premise: the record proves the distress `finalize` requires");
        uint256 before = usdc.balanceOf(alice);

        vm.prank(keeper);
        ace.finalize(loanId);

        assertGt(usdc.balanceOf(alice) - before, 0, "the distress door paid the lender nothing");
        assertEq(_owed(), 0, "and left the pool it should have emptied");
        assertTrue(read.loan(loanId).closedAt != 0, "premise: the loan really settled");
    }

    /* ====================== 2. THE EXCLUSIONS, EACH PAIRED WITH ITS POSITIVE ====================== */

    /// @notice A PARTIAL repay does not push; the CLOSING one does. The pair is the whole row.
    /// @dev PAIRED DELIBERATELY, AND THE PAIRING IS LOAD-BEARING -- do not split these two legs into separate
    /// @dev rows once the push lands. "No push on a partial repay" is true of today's tree for the trivial
    /// @dev reason that nothing pushes anywhere, so alone it passes green against an empty implementation and
    /// @dev pins nothing. The closing leg is what makes the partial leg mean "excluded" rather than "absent",
    /// @dev and an edit that drops the positive half silently re-vacuums the exclusion it was guarding.
    /// @dev THE THIRD LEG IS THE COUPLING, and it is the same class of trap as the sweep row's gas assertion.
    /// @dev "Terminal ends only" is defensible ONLY because the push takes the WHOLE POOL: the partial's credit
    /// @dev is not stranded, it is QUEUED, and the close delivers it along with its own. Narrow the push to the
    /// @dev close's DELTA and both rulings break at once -- every partial repay's credit strands -- and without
    /// @dev the `paid >= owedAfterPartial` leg below nothing here would go red to say so.
    function test_Repay_APartialRepayDoesNotPush_ButTheClosingOneDeliversBoth() public {
        uint256 loanId = _open(TEN30);
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt * 2);
        uint256 before = usdc.balanceOf(alice);

        vm.startPrank(borrower);
        usdc.approve(address(ace), debt * 2);
        ace.repay(loanId, debt / 2);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), before, "EXCLUDED: a partial repay is not a close and must move no quote");
        uint256 owedAfterPartial = _owed();
        assertGt(owedAfterPartial, 0, "and the credit it booked stays pooled, waiting for the close or a collect");
        assertEq(read.loan(loanId).closedAt, 0, "premise: the loan is still live, which is what makes it partial");

        vm.startPrank(borrower);
        ace.repay(loanId, read.loan(loanId).debt);
        vm.stopPrank();

        uint256 paid = usdc.balanceOf(alice) - before;
        assertGt(paid, 0, "and the CLOSING repay pays the pool out");
        assertGe(paid, owedAfterPartial, "INCLUDING the partial's credit: the push takes the WHOLE POOL, never the close's delta");
        assertEq(_owed(), 0, "in full, leaving nothing queued behind it");
    }

    /// @notice A ROLL does not push; the settle branch of the same verb does. The pair is the whole row.
    /// @dev THE ROLL IS A CONTINUATION, and the push rides terminal closes only; no roll door pushes at all.
    /// @dev NOT because a push would starve the successor: it pays `owed`, the draw debits `cash`, and the roll has drawn already.
    /// @dev PAIRED, as above: the exclusion leg is vacuous alone on a tree where nothing pushes, so the settle leg stays in this row.
    function test_ForceClose_TheRollBranchDoesNotPush_ButTheSettleBranchDoes() public {
        uint256 rolled = _expiredArmed();
        uint256 n = read.loanCount();
        uint256 before = usdc.balanceOf(alice);

        vm.prank(keeper);
        ace.forceClose(rolled);
        assertEq(read.loanCount(), n + 1, "premise: this really took the ROLL branch and minted a successor");
        assertEq(usdc.balanceOf(alice), before, "EXCLUDED: a roll is a continuation and must move no quote to the lender");

        uint256 settled = _expiredUnarmed();
        vm.prank(keeper);
        ace.forceClose(settled);

        assertGt(usdc.balanceOf(alice) - before, 0, "and the SETTLE branch of the same verb does pay the pool out");
    }

    /* ====================== 3. THE FALLBACK IS BYTE-FOR-BYTE TODAY'S STATE ====================== */

    /// @notice THE WHOLE SAFETY CLAIM: a quote that refuses cannot fail the close, and costs the lender nothing.
    /// @dev THIS ROW GOES RED ON THE EVENT ALONE, and that is correct rather than weak -- DO NOT DELETE THE
    /// @dev EVENT ASSERTION AS NOISE. Every other assertion here describes TODAY's tree, because the fallback
    /// @dev IS today's tree; that is the design, not a gap in the row. What the event proves is that an attempt
    /// @dev was MADE and swallowed, which is the only externally visible difference between "the push failed
    /// @dev safely" and "the push was never built". Drop it and this row stops testing anything at all.
    function test_Fallback_ARefusingQuoteLeavesTheCloseAndTheCreditIntact() public {
        uint256 loanId = _open(TEN30);
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.prank(borrower);
        usdc.approve(address(ace), debt);
        usdc.setReverting(true);

        uint256 owedBefore = _owed();
        vm.recordLogs();
        vm.prank(borrower);
        ace.repay(loanId, debt);

        (bool saw, uint256 amount) = _sawFromHub(PUSH_FAILED_SIG);
        assertTrue(saw, "the swallowed failure announced nothing, so a lender cannot tell it is owed a collect");
        assertGe(amount, owedBefore, "and the event must name what was left behind");
        assertTrue(read.loan(loanId).closedAt != 0, "the close SUCCEEDS: a refusing quote cannot fail the hub verb");
        assertEq(_owed(), amount, "and the credit is restored rather than burned, exactly what the event names");

        usdc.setReverting(false);
        vm.prank(alice);
        assertGt(ace.collect(address(usdc), alice), 0, "and `collect` is still the recovery door, paying in full");
        assertEq(_owed(), 0, "which empties the pool the fallback preserved");
    }

    /* ====================== 4. THE FENCE, AGAINST THE TWO SHAPES A REVERTER IS NOT ====================== */

    /// @notice A GAS BURNER cannot fail the hub verb, and this is the row that distinguishes this fence from
    /// @notice the one #383 rejected: the callee is not required to SUCCEED, so failure is a first-class outcome.
    /// @dev A reverter returns cheaply and leaves the caller its whole retained allowance -- the easy case.
    /// @dev This quote consumes every unit of its fixed budget and dies, so the tail the pre-check reserved is the whole
    /// @dev of what the restore, the event and the epilogue may run on.
    /// @dev The event is what makes this row a test of the budget rather than of an absence: a close with no push completes too.
    function test_Fence_AGasBurningQuoteCannotFailTheHubVerb() public {
        uint256 loanId = _expiredUnarmed();
        uint256 owedBefore = _owed();
        usdc.setBurnAll(true);

        vm.recordLogs();
        vm.prank(keeper);
        ace.forceClose{gas: 8_000_000}(loanId);

        (bool saw, uint256 amount) = _sawFromHub(PUSH_FAILED_SIG);
        assertTrue(saw, "no failure event: the push was never attempted, so nothing here tested a fence");
        assertGe(amount, owedBefore, "and the event must name what was left behind");
        assertTrue(read.loan(loanId).closedAt != 0, "a quote that burns its whole allowance must not fail the close");
        assertEq(_owed(), amount, "and the credit survives the burn, restored whole inside the reserved tail");
    }

    /// @notice A RETURN BOMB CANNOT FAIL THE HUB VERB: the callee cannot build one inside its budget, and the window is ONE WORD.
    /// @dev A megabyte of returndata costs the callee ~2.2M to expand, so under a 100k budget it runs dry before it returns.
    /// @dev The one-word window still matters: a plain `(bool, bytes memory) = call{gas}` would bill our tail for whatever it got.
    /// @dev So this row is also a test that the implementation used a bounded-window transfer helper.
    function test_Fence_AReturnBombCannotFailTheHubVerb() public {
        uint256 loanId = _expiredUnarmed();
        uint256 owedBefore = _owed();
        usdc.setBombWords(ONE_MIB_WORDS);

        vm.recordLogs();
        vm.prank(keeper);
        ace.forceClose{gas: 8_000_000}(loanId);

        (bool saw, uint256 amount) = _sawFromHub(PUSH_FAILED_SIG);
        assertTrue(saw, "no failure event: the push was never attempted, so nothing here tested the budget");
        assertGe(amount, owedBefore, "and the event must name what was left behind");
        assertTrue(read.loan(loanId).closedAt != 0, "a megabyte of returndata must not fail the close");
        assertEq(_owed(), amount, "and the credit survives it whole");
    }

    /// @notice SETTLEABILITY AT TENOR SURVIVES EVERY HOSTILE QUOTE, which is the property the doctrine sentence
    /// @notice protects and the reason the user could rule the push onto this door at all.
    /// @dev The claim is that the UNITS leg never calls out, so title still moves however the quote behaves.
    /// @dev PROVED PER SHAPE rather than assumed: a reverter, a burner and a bomb, each on a fresh loan.
    function test_SettleExpired_StillSettlesUnderEveryHostileQuoteShape() public {
        uint256 a = _open(TEN30);
        uint256 b = _open(TEN30);
        uint256 c = _open(TEN30);
        _warpPastTheRollWindow(c);

        usdc.setReverting(true);
        vm.prank(keeper);
        ace.settleExpired{gas: 8_000_000}(a);
        assertTrue(read.loan(a).closedAt != 0, "a refusing quote must not block settlement at tenor");
        usdc.setReverting(false);

        usdc.setBurnAll(true);
        vm.prank(keeper);
        ace.settleExpired{gas: 8_000_000}(b);
        assertTrue(read.loan(b).closedAt != 0, "nor may a quote that burns its whole allowance");
        usdc.setBurnAll(false);

        usdc.setBombWords(ONE_MIB_WORDS);
        vm.recordLogs();
        vm.prank(keeper);
        ace.settleExpired{gas: 8_000_000}(c);
        assertTrue(read.loan(c).closedAt != 0, "nor a megabyte of returndata");

        (bool saw, uint256 amount) = _sawFromHub(PUSH_FAILED_SIG);
        assertTrue(saw, "no failure event on any shape: the push is absent, so settleability was never at risk here");
        assertEq(_owed(), amount, "and all three fallbacks kept the credit whole, which is what `collect` recovers");
    }

    /* ====================== 5. THE EXPOSURE: EACH PUSH COSTS ITS BUDGET, AND THE TAIL SURVIVES ====================== */

    /// @notice A BURNING QUOTE COSTS EACH PUSH ITS FIXED BUDGET, and the caller's next leg still runs.
    /// @notice `forceClose` makes two pushes here, the lender's and then the due sweep; each is handed `PUSH_GAS` and no more.
    /// @dev The lender push runs first and the sweep after, on what it left, so a burning sweep cannot starve the push.
    /// @dev Both land in their fallbacks, the credit is restored whole, and `collect` still pays it: nobody's money is at risk.
    /// @dev THE CALLER'S TAIL survives because the burn is bounded: 8M less two budgets is plenty for the second leg.
    /// @dev A caller whose chain is funded against the push's NEED rather than its budget is the residual, and it is recorded.
    /// @dev The quote spins until it is under a 1,000-gas floor, then cannot afford the transfer, so each push fails.
    function test_Exposure_ABurningQuoteCostsEachPushItsBudgetAndTheTailSurvives() public {
        uint256 loanId = _expiredUnarmed();
        uint256 owedBefore = _owed();
        assertGt(owedBefore, 0, "premise: there was a pool to push, or the burn was never triggered");
        usdc.setBurnToFloor(1_000); // spins through its whole budget and cannot then afford the transfer

        bytes[] memory legs = new bytes[](2);
        legs[0] = abi.encodeCall(Ace.forceClose, (loanId));
        /// @dev The tail is a cheap hub write. It was `sweepRevenue`, which is uncapped now: under a burning quote it spends the rest.
        legs[1] = abi.encodeCall(Ace.setCreditOperator, (address(0xBEEF), false));

        /// @dev CAPPED AT A REAL BUDGET. Uncapped, the burn eats the whole test frame and measures nothing a
        /// @dev transaction would ever see -- 8M is roughly a fat mainnet tx, which is the frame under test.
        uint256 g = gasleft();
        vm.recordLogs();
        vm.prank(keeper);
        bool tailSurvived;
        try ace.multicall{gas: 8_000_000}(legs) {
            tailSurvived = true;
        } catch {}
        emit log_named_uint("two-leg multicall gas spent", g - gasleft());
        emit log_named_uint("the caller's second leg survived (1 = yes)", tailSurvived ? 1 : 0);

        assertTrue(tailSurvived, "the caller's second leg ran dry: a burning quote cost more than its budgets");
        assertTrue(read.loan(loanId).closedAt != 0, "whatever the tail cost, the hub verb itself completed");
        assertGt(_owed(), 0, "the burned lender push took its FALLBACK, so the credit is restored rather than lost");
        (bool saw,) = _sawFromHub(PUSH_FAILED_SIG);
        assertTrue(saw, "and said so, which is how a lender learns a `collect` is owed");

        /// @dev Against the pool AS IT STANDS, not `owedBefore`: the close itself credits the settlement's own
        /// @dev proceeds, so the restored pool is strictly larger than what the push was carrying when it failed.
        uint256 stranded = _owed();
        assertGt(stranded, owedBefore, "premise: the close credited its own proceeds on top of what the push held");
        usdc.setBurnToFloor(0);
        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), stranded, "and `collect` is still the recovery door, paying in full");
        assertEq(_owed(), 0, "which empties the pool the fallback preserved");
    }

    /* ====================== 6. WHAT EACH DOOR DEMANDS UNDER A FULL BURN ====================== */

    /// @notice EACH DOOR DEMANDS ONE LENDER BUDGET, and this row measures the floor under a quote burning every unit.
    /// @notice `forceClose` sweeps BEST-EFFORT, so its floor is the lender push's alone: the sweep is skipped there, never paid.
    /// @dev MEASURED ON THE SHIPPED BUILD too: run it under `FOUNDRY_PROFILE=deploy` via `scripts/test-ir.sh`.
    /// @dev THE METHOD IS A BISECTION FROM OUTSIDE: the least outer budget at which the verb completes while the quote burns its whole budget.
    /// @dev Below it the verb reverts, `PushGasShort` or dry in its own body; at and above it the lender push lands in its fallback.
    /// @dev THE TWO-PUSH PREMISE IS GONE: the sweep runs after the push and its floor is the higher, so it never binds the least budget.
    function test_Floor_EachDoorDemandsOneLenderBudgetUnderAFullBurn() public {
        uint256 fc = _floorFor(true);
        uint256 se = _floorFor(false);

        emit log_named_uint("forceClose    completes a full burn from", fc);
        emit log_named_uint("settleExpired completes a full burn from", se);
        emit log_named_uint("  the fixed budget each demands on top of its body", AceFixtures.PUSH_GAS);

        assertGe(fc, AceFixtures.PUSH_GAS, "forceClose completed under ONE budget: the lender push was not funded");
        assertGe(se, AceFixtures.PUSH_GAS, "settleExpired completed under ONE budget: the lender push was not funded");
        assertLt(fc, 8_000_000, "the floor is inside an ordinary transaction budget, which is what makes the door usable");
        /// @dev THE BINDING DEMAND IS THE PUSH'S: just under each floor the door refuses by name, not dry in its own body.
        /// @dev The two bounds above hold for any door whose body alone costs a budget; this one fails if the push never demanded.
        assertEq(bytes4(_revertAt(fc - 1_000, true)), PushGasShort.selector, "forceClose's floor is not the lender push's");
        assertEq(bytes4(_revertAt(se - 1_000, false)), PushGasShort.selector, "settleExpired's floor is not the lender push's");

        uint256 snap = vm.snapshotState();
        uint256 loanId = _open(TEN30);
        vm.warp(uint256(read.loan(loanId).expiry) + 1);
        uint64 stamped = read.marketState(mid).lastSweptAt;
        usdc.setBurnAll(true);
        vm.recordLogs();
        vm.prank(keeper);
        ace.forceClose{gas: fc}(loanId);
        assertFalse(_sawSigFromHub(SWEEP_FAILED_SIG), "forceClose's floor paid for a sweep: the best-effort gate bound it");
        assertEq(read.marketState(mid).lastSweptAt, stamped, "and stamped a sweep it never ran");
        usdc.setBurnAll(false);
        vm.revertToState(snap);
    }

    /// @dev Bisect the least outer budget at which the door completes while the quote burns every unit it is handed.
    /// @dev `twoPush` picks `forceClose` over `settleExpired`; the interval is a guard, not a tuning knob.
    function _floorFor(bool twoPush) internal returns (uint256) {
        uint256 lo = 60_000; // under the cheapest door's own body, so it is below either floor
        uint256 hi = 8_000_000;
        assertTrue(_survivesAt(hi, twoPush), "the verb cannot complete even at 8M: something other than the push budget binds");
        assertFalse(_survivesAt(lo, twoPush), "premise: the low bound is not below the floor, so there is no interval to search");
        while (hi - lo > 1_000) {
            uint256 probe = (lo + hi) / 2;
            if (_survivesAt(probe, twoPush)) hi = probe;
            else lo = probe;
        }
        return hi;
    }

    /// @dev The revert data of one full-burn close at `cap`, on a fresh loan; empty when it completed. Snapshotted.
    function _revertAt(uint256 cap, bool twoPush) internal returns (bytes memory ret) {
        uint256 snap = vm.snapshotState();
        uint256 loanId = _open(TEN30);
        if (twoPush) vm.warp(uint256(read.loan(loanId).expiry) + 1);
        else _warpPastTheRollWindow(loanId);
        usdc.setBurnAll(true);
        bytes memory data = twoPush ? abi.encodeCall(Ace.forceClose, (loanId)) : abi.encodeCall(Ace.settleExpired, (loanId));
        vm.prank(keeper);
        bool ok;
        (ok, ret) = address(ace).call{gas: cap}(data);
        if (ok) ret = "";
        usdc.setBurnAll(false);
        vm.revertToState(snap);
    }

    /// @dev One bisection probe, on a fresh loan each time. Snapshotted, so a probe leaves the chain as it found it.
    function _survivesAt(uint256 cap, bool twoPush) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        uint256 loanId = _open(TEN30);
        if (twoPush) vm.warp(uint256(read.loan(loanId).expiry) + 1);
        else _warpPastTheRollWindow(loanId);
        usdc.setBurnAll(true);
        vm.prank(keeper);
        if (twoPush) {
            try ace.forceClose{gas: cap}(loanId) {
                ok = read.loan(loanId).closedAt != 0;
            } catch {}
        } else {
            try ace.settleExpired{gas: cap}(loanId) {
                ok = read.loan(loanId).closedAt != 0;
            } catch {}
        }
        usdc.setBurnAll(false);
        vm.revertToState(snap);
    }

    /* ====================== 7. THE SWEEP FIX THAT RIDES ALONG ====================== */

    /// @notice A RETURN BOMB AT THE STRICT SWEEP REVERTS IT, `PushRefused`, and the revenue stays banked whole for a later sweep.
    /// @dev The standalone door is uncapped: the callee expands its megabyte on the caller's gas, which that caller chose to forward.
    /// @dev What stays bounded is the COPY: `trySafeTransfer` reads one word of returndata, so the hub never copies the bomb.
    function test_SweepRevenue_AReturnBombRevertsTheStrictSweepAndKeepsTheRevenue() public {
        uint256 loanId = _open(TEN30);
        uint256 banked = read.protocolRevenue(mid);
        assertGt(banked, 0, "premise: origination banked a protocol cut to sweep");
        assertGt(loanId, 0, "premise: the loan is real");
        usdc.setBombWords(ONE_MIB_WORDS);

        uint256 g = gasleft();
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.sweepRevenue, (mid)));
        uint256 spent = g - gasleft();

        emit log_named_uint("gas a 1 MiB return bomb costs the strict sweeper", spent);
        assertFalse(ok, "the strict sweep refused the bomb");
        assertEq(bytes4(ret), PushRefused.selector, "by name, as a bare selector");
        assertEq(read.protocolRevenue(mid), banked, "and the revert left the revenue whole");
    }
}

/// @title AcePushAtCloseDeleverage
/// @notice THE DOOR THAT WAS RULED OUT, in its own fixture because it is the only one needing a decline channel.
/// @notice The plan had a fifth door here: a full melt zeroing the debt, which `_meltAll` then handed to `Settlement.closeClean`.
/// @notice That hand-off is DELETED: a crank never melts under `minDebt`, so it can never zero a loan at all.
/// @notice The ruling is FOUR close doors, and `deleverage` pushes nothing.
/// @notice These rows are what that ruling rests on -- a crank CREDITS the pool, and the next close delivers it.
/// @dev SEPARATE CONTRACT rather than a branch of the suite above: a market with a band, a target and a stop is a
/// @dev different market, and reconfiguring the shared one would change what the other twelve rows are asking.
/// @dev `closedAt` DETECTION IS THE REPAY DOOR'S ALONE now: `finalize` and `settleExpired` always settle, and
/// @dev `forceClose` cannot re-read it at all, because its ROLL branch sets `closedAt` on the old loan too.
contract AcePushAtCloseDeleverageTest is Test, DeleverageCrank {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockHostileGasERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint16 internal constant BAND_BPS = 3000;
    uint256 internal constant DEPOSIT = 400_000e6;
    uint256 internal constant PRINCIPAL = 40_000e6;
    uint256 internal constant COLL = 100_000e18;

    /// @dev From the declared event, never a signature string; see the note in the suite above for why.
    bytes32 internal constant PUSH_FAILED_SIG = Lender.LenderPushFailed.selector;

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockHostileGasERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = alice;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(ace), DEPOSIT);
        ace.deposit(mid, DEPOSIT);
        vm.stopPrank();
    }

    function _owed() internal view returns (uint256) {
        (,, uint256 owed) = read.lenderPools(alice, address(usdc));
        return owed;
    }

    function _open() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Repay the whole debt, which is the CLOSING repay and one of the four terminal doors.
    function _repayInFull(uint256 loanId) internal {
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    /// @dev One crank, with the record told the band is broken at the loan's CURRENT trigger.
    /// @dev Re-derived per crank: the melt lowers the debt, which lowers the trigger, which moves the band.
    function _crank(uint256 loanId) internal {
        uint256 trig = read.triggerPrice(loanId);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - uint256(BAND_BPS) * 1e14));
        record.setMinPrice(trig + trig / 20);
        ace.deleverage(loanId, 0, "");
    }

    /// @notice DELEVERAGE NEEDS NO DOOR OF ITS OWN: a crank credits the pool, and the next TERMINAL CLOSE
    /// @notice delivers that credit -- including a close on a DIFFERENT LOAN. Queued, never stranded.
    /// @dev THIS IS THE CLAIM THE FOUR-DOOR RULING RESTS ON, and it is why `deleverage` is not the fifth.
    /// @dev `Deleverage.sol` calls `meltLoan` UNCONDITIONALLY -- it has no `L.debt == 0` branch left -- and
    /// @dev `LoanAccounting.meltLoan` does `pool.owed += amount`. So a crank credits exactly as a partial
    /// @dev repay does, and the pool is keyed `(lender, quote)` rather than per loan.
    /// @dev THE CROSS-LOAN LEG IS THE POINT. A same-loan test would only show that a loan eventually closes;
    /// @dev what has to hold is that the pool SPANS loans, so any terminal close carries every crank's credit.
    /// @dev THE COUPLING, same class of trap as the sweep row's gas assertion: this holds ONLY because the push
    /// @dev takes the WHOLE POOL. Narrow it to the close's DELTA and loan A's melt strands for good -- there is
    /// @dev no deleverage door to catch it -- and without the cross-loan leg nothing would go red to say so.
    function test_Deleverage_CreditsThePoolAndAnotherLoansCloseDeliversIt() public {
        uint256 melted = _open();
        uint256 closing = _open(); // a SECOND loan, same lender and same quote, so one pool holds both
        uint256 before = usdc.balanceOf(alice);

        _crank(melted);

        assertEq(read.loan(melted).closedAt, 0, "premise: one crank restores the margin, it does not close the loan");
        assertGt(read.debtOf(melted), 0, "premise: and debt survives it, which is what makes the melt partial");
        assertEq(usdc.balanceOf(alice), before, "EXCLUDED: a crank is not a close and must move no quote itself");
        uint256 owedFromTheMelt = _owed();
        assertGt(owedFromTheMelt, 0, "the melt credited the pool, which is what makes a door unnecessary");

        _repayInFull(closing);

        uint256 paid = usdc.balanceOf(alice) - before;
        assertGt(paid, 0, "the other loan's close paid nothing, so the melt's credit is stranded");
        assertGe(paid, owedFromTheMelt, "INCLUDING the melt's credit: a close on ANOTHER loan carries the whole pool out");
        assertEq(_owed(), 0, "leaving nothing queued behind it");
        assertEq(read.loan(melted).closedAt, 0, "and the melted loan is still live: its credit left without it");
    }

    /// @notice FINDING: THE FULL MELT IS UNREACHABLE, so the plan's fifth terminal door cannot be driven at all.
    /// @notice Forty cranks take the debt from 1.39e10 to 2.78e7 and it never reaches zero -- it asymptotes.
    /// @dev It is now unreachable TWICE: no crank melts under `minDebt`, so `_meltAll`'s full-repayment legs were deleted with the cap.
    /// @dev The fixture's 10e6 `minDebt` sits under where this row's debt converges, so the cap never binds here and the row is the sizing's.
    /// @dev WHY IT IS STRUCTURAL rather than a fixture artefact: each crank restores margin to TARGET, and the
    /// @dev genesis relation `MIN_COVERAGE_WAD * (10000 - MAX_DELEVERAGE_FLOOR_EPS_BPS) > 1e22` is exactly what
    /// @dev makes the melt per unit smaller than that unit's contribution to the trigger. So the sequence is
    /// @dev geometric with a ratio under one, at EVERY point in the admitted parameter range, not just this one.
    /// @dev CONSEQUENCE FOR THE PLAN: a push placed on this door is unreachable code until a rail changes.
    /// @dev GREEN BY DESIGN. It pins the reachability fact, so an implementer who believes they have driven a
    /// @dev full melt has to come here and delete a measurement first.
    function test_Finding_TheFullMeltIsUnreachableUnderTheSizingRails() public {
        uint256 loanId = _open();
        uint256 first;

        for (uint256 i; i < 40 && read.loan(loanId).closedAt == 0; i++) {
            _crank(loanId);
            if (i == 0) first = read.debtOf(loanId);
        }

        uint256 last = read.debtOf(loanId);
        emit log_named_uint("debt after the first crank ", first);
        emit log_named_uint("debt after forty cranks    ", last);
        emit log_named_uint("collateral units left      ", read.loan(loanId).collateralUnits);

        assertEq(read.loan(loanId).closedAt, 0, "the melt CLOSED the loan: the door is reachable and this finding is stale");
        assertGt(last, 0, "and debt never reached zero, which a close by melt would need");
        assertLt(last, first, "the melt is real and monotone, so this is convergence rather than a stuck crank");
    }
}
