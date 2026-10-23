// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {VmSafe} from "forge-std/Vm.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Lender} from "../../src/ace/hub/Lender.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {RevenueRouter} from "../../src/ace/treasury/RevenueRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockHookERC20} from "../mocks/MockHookERC20.sol";
import {MockHostileGasERC20} from "../mocks/MockHostileGasERC20.sol";
import {MockProxyERC20, MockUsdcImpl} from "../mocks/MockProxyERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {PushGasRig} from "../utils/PushGasRig.sol";

/// @dev The calls every quote shape here answers, so one rig drives them all.
interface IRigQuote {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice A contract lender whose receive hook costs a chosen amount of gas, or every unit it is handed.
contract GasHookLender {
    uint256 public cost; // gas the hook spends before returning
    bool public forever; // spin until the frame runs dry

    function setCost(uint256 c) external {
        cost = c;
    }

    function setForever(bool f) external {
        forever = f;
    }

    function onTokenReceived(address, uint256) external view {
        if (forever) {
            while (true) {}
        }
        uint256 start = gasleft();
        while (start - gasleft() < cost) {}
    }
}

/// @title PushGasDoorRig
/// @notice A funded market whose one lender is `alice`, and the four terminal doors driven at a chosen gas limit.
/// @dev Every probe runs from a snapshot and is classified, then the chain is put back: a bisection never moves state.
/// @dev THE LEAST LIMIT a door completes at is what an estimator lands on, so it is the number these rows reason about.
abstract contract PushGasDoorRig is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    address internal quote;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;
    address internal treasury;

    address internal alice = address(0xA11CE); // the market's one lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal constant DEPOSIT = 400_000e6;
    uint256 internal constant PRINCIPAL = 40_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant LO = 60_000; // under every door's own body
    uint256 internal constant HI = 8_000_000; // a fat mainnet transaction
    uint256 internal constant FROM_ZERO_MARGIN = 20_000; // SSTORE_SET: what one credit slot emptied before inclusion can add

    uint8 internal constant REPAY = 0; // the closing repay
    uint8 internal constant FINALIZE = 1;
    uint8 internal constant FORCE = 2; // forceClose's settle branch
    uint8 internal constant SETTLE = 3; // settleExpired

    uint8 internal constant OK = 0; // completed, no sweep event
    uint8 internal constant OK_SWEPT = 1; // completed with a sweep event
    uint8 internal constant SHORT = 2; // reverted PushGasShort
    uint8 internal constant OTHER = 3; // reverted anything else

    uint8 internal constant P_DONE = 0; // completed, swept or not
    uint8 internal constant P_SWEPT = 1; // completed with a sweep event of either kind
    uint8 internal constant P_NOT_OK = 2; // anything but a sweepless completion
    uint8 internal constant P_NOT_SHORT = 3; // anything but PushGasShort
    uint8 internal constant P_DELIVERED = 4; // completed with RevenueSwept

    bytes32 internal constant COLLECTED_SIG = Lender.Collected.selector;
    bytes32 internal constant PUSH_FAILED_SIG = Lender.LenderPushFailed.selector;
    bytes32 internal constant SWEPT_SIG = Ace.RevenueSwept.selector;
    bytes32 internal constant SWEEP_FAILED_SIG = Ace.RevenueSweepFailed.selector;

    /// @dev What one probe saw, read before the snapshot is restored.
    struct Run {
        uint8 out;
        bool collected;
        uint256 collectedAmount;
        bool pushFailed;
        bool swept;
        bool sweepFailed;
        uint256 pushCalls; // self-calls to `pushToken`: one per attempted transfer
        uint256 owed; // the lender's pool after
        uint64 stamp; // the market's `lastSweptAt` after
        uint256 revenue; // the market's protocol revenue after
        bool closed;
        uint256 debt;
        uint256 used; // gas the call consumed, from outside
        bytes ret;
    }

    function _newQuote() internal virtual returns (address);

    function _params(MarketParams memory p) internal virtual {}

    function _treasury() internal virtual returns (address) {
        return AceFixtures.TREASURY;
    }

    function setUp() public virtual {
        _warpTo(1_000_000);
        quote = _newQuote();
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(quote, address(coll));
        MarketParams memory p = AceFixtures.marketParams(quote, address(coll));
        p.record = address(record);
        p.lender = alice;
        p.minTenor = 7 days;
        p.maxTenor = TEN30;
        _params(p);
        treasury = _treasury();
        AceFixtures.Deployment memory d = PushGasRig.deploy(p, treasury, PushGasRig.PUSH_GAS);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        _lend(DEPOSIT);
    }

    function _lend(uint256 amount) internal {
        IRigQuote(quote).mint(alice, amount);
        vm.startPrank(alice);
        IRigQuote(quote).approve(address(ace), amount);
        ace.deposit(mid, amount);
        vm.stopPrank();
    }

    function _open(uint64 tenor) internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _owed() internal view returns (uint256 owed) {
        (,, owed) = read.lenderPools(alice, quote);
    }

    function _name(uint8 door) internal pure returns (string memory) {
        if (door == REPAY) return "repay";
        if (door == FINALIZE) return "finalize";
        if (door == FORCE) return "forceClose";
        return "settleExpired";
    }

    /// @dev A fresh loan positioned for `door`, with its caller and calldata. Arm any hostility AFTER this: the open pays out.
    function _door(uint8 door) internal returns (uint256 loanId, address who, bytes memory data) {
        record.setBelow(false);
        loanId = _open(TEN30);
        if (door == REPAY) {
            uint256 debt = read.loan(loanId).debt;
            IRigQuote(quote).mint(borrower, debt);
            vm.prank(borrower);
            IRigQuote(quote).approve(address(ace), debt);
            return (loanId, borrower, abi.encodeCall(Ace.repay, (loanId, debt)));
        }
        if (door == FINALIZE) {
            record.setBelow(true);
            return (loanId, keeper, abi.encodeCall(Ace.finalize, (loanId)));
        }
        if (door == FORCE) {
            _warpTo(uint256(read.loan(loanId).expiry) + 1);
            return (loanId, keeper, abi.encodeCall(Ace.forceClose, (loanId)));
        }
        _warpTo(uint256(read.loan(loanId).expiry) + MarketInit.autoRefinanceWindow(read.loan(loanId).tenor) + 1);
        return (loanId, keeper, abi.encodeCall(Ace.settleExpired, (loanId)));
    }

    /// @dev One probe at `g` from `who`, classified, with the chain restored after.
    function _run(address who, bytes memory data, uint256 g, uint256 loanId) internal returns (Run memory r) {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.prank(who);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = address(ace).call{gas: g}(data);
        r.used = g0 - gasleft();
        r.pushCalls = _pushCalls();
        _readLogs(r, vm.getRecordedLogs());
        _classify(r, ok, ret, loanId);
        vm.revertToState(snap);
    }

    /// @dev The hub's self-calls to `pushToken` since recording began: one per attempted transfer.
    function _pushCalls() internal returns (uint256 n) {
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i; i < acc.length; i++) {
            if (acc[i].kind != VmSafe.AccountAccessKind.Call || acc[i].account != address(ace) || acc[i].accessor != address(ace)) continue;
            if (acc[i].data.length >= 4 && bytes4(acc[i].data) == Ace.pushToken.selector) n++;
        }
    }

    /// @dev The outcome and the ledger after the call, read before the snapshot is restored.
    function _classify(Run memory r, bool ok, bytes memory ret, uint256 loanId) internal view {
        if (ok) r.out = (r.swept || r.sweepFailed) ? OK_SWEPT : OK;
        else r.out = ret.length >= 4 && bytes4(ret) == PushGasRig.shortSelector() ? SHORT : OTHER;
        r.ret = ret;
        r.owed = _owed();
        r.stamp = read.marketState(mid).lastSweptAt;
        r.revenue = read.protocolRevenue(mid);
        r.closed = read.loan(loanId).closedAt != 0;
        r.debt = read.debtOf(loanId);
    }

    function _readLogs(Run memory r, VmSafe.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0) continue;
            bytes32 t = logs[i].topics[0];
            if (t == COLLECTED_SIG) (r.collected, r.collectedAmount) = (true, abi.decode(logs[i].data, (uint256)));
            if (t == PUSH_FAILED_SIG) r.pushFailed = true;
            if (t == SWEPT_SIG) r.swept = true;
            if (t == SWEEP_FAILED_SIG) r.sweepFailed = true;
        }
    }

    function _holds(Run memory r, uint8 pred) internal pure returns (bool) {
        bool done = r.out == OK || r.out == OK_SWEPT;
        if (pred == P_DONE) return done;
        if (pred == P_SWEPT) return r.out == OK_SWEPT;
        if (pred == P_NOT_OK) return r.out != OK;
        if (pred == P_NOT_SHORT) return r.out != SHORT;
        return done && r.swept;
    }

    /// @dev The least limit in (lo, hi] at which `pred` holds, given it fails at lo and holds at hi.
    function _least(address who, bytes memory data, uint256 loanId, uint256 lo, uint256 hi, uint8 pred) internal returns (uint256) {
        assertTrue(_holds(_run(who, data, hi, loanId), pred), "bisection: the predicate is false at the top of the search");
        assertFalse(_holds(_run(who, data, lo, loanId), pred), "bisection: the predicate is already true at the bottom");
        while (hi - lo > 1) {
            uint256 m = (lo + hi) / 2;
            if (_holds(_run(who, data, m, loanId), pred)) hi = m;
            else lo = m;
        }
        return hi;
    }

    /// @dev Step down from `from` until a probe's outcome is `want`.
    function _down(address who, bytes memory data, uint256 loanId, uint256 from, uint256 step, uint8 want) internal returns (uint256 g) {
        g = from;
        for (uint256 i; i < 200 && g > step; i++) {
            g -= step;
            if (_run(who, data, g, loanId).out == want) return g;
        }
        revert("step-down: the outcome never appeared under the start");
    }
}

/// @title AcePushGasBudget
/// @notice THE FIXED PUSH BUDGET at the four terminal closes: strict on the caller, lenient on the callee.
/// @notice A limit that cannot hand the lender push its whole budget plus the tail reverts `PushGasShort`, so an estimate includes the push.
/// @notice Once admitted, no quote, hook or drift INSIDE the push can revert the close: the callee spends at most the budget.
/// @notice Drift in the close's own work before the check can still cost a from-zero write each; that residual is pinned below.
/// @dev The quote is armable, so one market answers every hostile shape; every hostility is armed AFTER the draw.
contract AcePushGasBudgetTest is PushGasDoorRig {
    MockHostileGasERC20 internal usdc;

    function _newQuote() internal override returns (address) {
        usdc = new MockHostileGasERC20("USD Coin", "USDC", 6);
        return address(usdc);
    }

    /* ============ THE PRE-CHECK: the limit is the budget's, and under it the close refuses by name ============ */

    /// @notice ONE GAS UNDER THE LEAST LIMIT IS `PushGasShort`, and so is every limit in the band beneath it.
    /// @dev Never a success under the least limit, and never a silent skip: the estimate cannot land on a close that does not pay.
    /// @dev The revert is the bare selector, so a wrapper forwarding it copies four bytes.
    function test_PreCheck_UnderTheFloorRevertsPushGasShort() public {
        for (uint8 door; door < 4; door++) {
            (uint256 id, address who, bytes memory data) = _door(door);
            uint256 g = _least(who, data, id, LO, HI, P_DONE);
            Run memory under = _run(who, data, g - 1, id);
            assertEq(under.out, SHORT, string.concat(_name(door), ": one gas under the least limit is not PushGasShort"));
            assertEq(under.ret.length, 4, "the refusal is a bare selector");
            for (uint256 k = 1; k <= 12; k++) {
                assertEq(_run(who, data, g - k * 5_000, id).out, SHORT, string.concat(_name(door), ": a limit in the band under it is not PushGasShort"));
            }
        }
    }

    /* ============ THE TAIL: no out-of-gas window above the pre-check ============ */

    /// @notice WITH A QUOTE BURNING ITS WHOLE BUDGET, THE LEAST LIMIT THE CHECK ADMITS COMPLETES ON THE FALLBACK.
    /// @dev PINS `PUSH_TAIL`: short of it, the check passes and the catch path runs dry, so the least non-short limit would revert.
    /// @dev The fallback's restore is the dear leg: a pool empty at the transaction's start makes it a from-zero write.
    /// @dev Run it under both profiles; the IR build is the one that ships.
    function test_Tail_NoOutOfGasWindowAboveThePreCheck() public {
        _tailRows(true);
    }

    /// @notice THE SAME ON THE SUCCESS PATH: a callee that spends all but a sliver of its budget and succeeds.
    function test_Tail_NoOutOfGasWindowAboveThePreCheck_OnTheSuccessPath() public {
        _tailRows(false);
    }

    function _tailRows(bool burn) internal {
        for (uint8 door; door < 4; door++) {
            (uint256 id, address who, bytes memory data) = _door(door);
            if (burn) usdc.setBurnAll(true);
            else usdc.setSpinFloor(300);
            uint256 okAt = _least(who, data, id, LO, HI, P_DONE);
            uint256 lo = _down(who, data, id, okAt, 2_000, SHORT);
            uint256 chk = _least(who, data, id, lo, okAt, P_NOT_SHORT);
            assertEq(chk, okAt, string.concat(_name(door), ": an out-of-gas window sits above the pre-check, so the tail is short"));
            Run memory r = _run(who, data, chk, id);
            assertEq(r.out, OK, string.concat(_name(door), ": the least admitted limit did not complete"));
            assertTrue(burn ? r.pushFailed : r.collected, "and it took the path the callee chose");
            assertEq(r.pushCalls, 1, "with the push really attempted, once");
            assertTrue(r.closed, "and the loan closed");
            for (uint256 x = chk; x <= chk + 2_000; x += 50) {
                assertTrue(_holds(_run(who, data, x, id), P_DONE), string.concat(_name(door), ": a limit just above the check reverted"));
            }
            usdc.setBurnAll(false);
            usdc.setSpinFloor(0);
        }
    }

    /* ============ THE SWEEP: best-effort, gated before its stamp, and run after the lender push ============ */

    /// @notice A SWEEP BURNING ITS WHOLE BUDGET NEVER STARVES THE LENDER PUSH: it runs after it, and at its gate both land.
    /// @dev PINS `SWEEP_TAIL`: short of it, the gate admits a burning sweep whose own fallback then runs dry and reverts the close.
    /// @dev A treasury-only burn keeps the lender's push honest, so the row is about the sweep's cost alone.
    function test_Sweep_ABudgetBurningSweepNeverStarvesTheLenderPush() public {
        (uint256 id, address who, bytes memory data) = _door(FORCE);
        usdc.setBurnOnlyTo(treasury);
        usdc.setBurnAll(true);
        uint256 okSwept = _least(who, data, id, LO, HI, P_SWEPT);
        uint256 plain = _down(who, data, id, okSwept, 5_000, OK);
        uint256 admit = _least(who, data, id, plain, okSwept, P_NOT_OK);
        assertEq(admit, okSwept, "the gate admitted a sweep whose own fallback could not then complete: SWEEP_TAIL is short");
        Run memory r = _run(who, data, admit, id);
        assertTrue(r.sweepFailed, "the burning sweep took its fallback");
        assertEq(r.revenue, read.protocolRevenue(mid), "and restored the revenue whole");
        assertTrue(r.collected, "and the lender push in front of it paid");
        assertEq(r.owed, 0, "the whole pool");
        assertEq(r.pushCalls, 2, "two transfers attempted, one each");
    }

    /// @notice NO REVERT BAND BETWEEN THE LENDER-ONLY THRESHOLD AND THE LENDER-PLUS-SWEEP ONE, stepped down across the gap.
    /// @dev Every limit from the least completing one up past the sweep's gate completes, sweeping or not.
    /// @dev The sweep follows the push, so a band could only come from a gate admitting a sweep its own tail cannot finish.
    function test_Sweep_NoRevertBandBetweenTheLenderAndTheSweepThresholds() public {
        (uint256 id, address who, bytes memory data) = _door(FORCE);
        usdc.setBurnOnlyTo(treasury);
        usdc.setBurnAll(true);
        uint256 okSwept = _least(who, data, id, LO, HI, P_SWEPT);
        uint256 plain = _down(who, data, id, okSwept, 5_000, OK);
        uint256 gStar = _least(who, data, id, LO, plain, P_DONE);
        emit log_named_uint("forceClose completes from (lender push only)", gStar);
        emit log_named_uint("and sweeps from (lender push plus sweep)    ", okSwept);
        for (uint256 x = okSwept + 5_000; x >= gStar; x -= 1_000) {
            assertTrue(_holds(_run(who, data, x, id), P_DONE), "a revert band sits between the two thresholds");
        }
        for (uint256 x = okSwept - 1_500; x <= okSwept + 1_500; x += 50) {
            assertTrue(_holds(_run(who, data, x, id), P_DONE), "a revert band sits at the sweep's gate");
        }
    }

    /// @notice forceClose PAYS THE LENDER BEFORE IT SWEEPS: the strict push runs first, the best-effort sweep spends what is left.
    /// @dev So no sweep, however it behaves, can starve the push in front of it, and the sweep needs no reserve to leave behind.
    /// @dev Read off the hub's own log order under a fat limit, where both legs run: `Collected` precedes `RevenueSwept`.
    function test_ForceClose_PaysTheLenderBeforeItSweeps() public {
        (uint256 id, address who, bytes memory data) = _door(FORCE);
        vm.recordLogs();
        vm.prank(who);
        (bool ok,) = address(ace).call{gas: HI}(data);
        assertTrue(ok, "premise: the close landed");
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        uint256 paidAt = type(uint256).max;
        uint256 sweptAt = type(uint256).max;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == COLLECTED_SIG) paidAt = i;
            if (logs[i].topics[0] == SWEPT_SIG || logs[i].topics[0] == SWEEP_FAILED_SIG) sweptAt = i;
        }
        assertTrue(paidAt != type(uint256).max && sweptAt != type(uint256).max, "premise: both legs ran");
        assertLt(paidAt, sweptAt, "the sweep ran ahead of the lender push, so a sweep could still starve it");
    }

    /// @notice A STARVED SWEEP WRITES NOTHING: no event, no stamp, the counter stays, and a later funded sweep delivers.
    /// @dev At forceClose's least limit the sweep is due and cannot be funded; skipping it must not spend the period.
    function test_Sweep_AStarvedSweepSkipsWritesNoStampStaysDue() public {
        (uint256 id, address who, bytes memory data) = _door(FORCE);
        uint64 stamp = read.marketState(mid).lastSweptAt;
        uint256 banked = read.protocolRevenue(mid);
        assertGt(banked, 0, "premise: origination banked revenue to sweep");
        assertGe(_now(), stamp + 1 days, "premise: the piggyback is due");
        uint256 g = _least(who, data, id, LO, HI, P_DONE);

        vm.recordLogs();
        vm.prank(who);
        (bool ok,) = address(ace).call{gas: g}(data);
        assertTrue(ok, "the close landed at its least limit");
        Run memory seen;
        _readLogs(seen, vm.getRecordedLogs());
        assertFalse(seen.swept || seen.sweepFailed, "a starved sweep emitted a revenue event");
        assertTrue(seen.collected, "while the lender push paid");
        assertEq(read.marketState(mid).lastSweptAt, stamp, "and stamped a period it never swept");
        assertEq(read.protocolRevenue(mid), banked, "and moved the counter");

        uint256 had = IRigQuote(quote).balanceOf(treasury);
        ace.sweepRevenue(mid);
        assertEq(IRigQuote(quote).balanceOf(treasury) - had, banked, "a later funded sweep delivers every wei");
        assertEq(read.protocolRevenue(mid), 0, "and empties the counter");
    }

    /// @notice STANDALONE `sweepRevenue` IS STRICT AND UNCAPPED: the transfer takes the caller's gas, and under its need the call REVERTS.
    /// @dev Never a silent no-op and never `PushGasShort`: there is no budget gate, so what fails is the transfer itself, by revert.
    /// @dev Its two early returns stay free: with nothing banked it demands nothing at all.
    function test_SweepRevenue_UnderItsLeastLimitTheStrictSweepRevertsNotSkips() public {
        uint256 id = _open(TEN30);
        uint256 banked = read.protocolRevenue(mid);
        assertGt(banked, 0, "premise: revenue to sweep");
        bytes memory data = abi.encodeCall(Ace.sweepRevenue, (mid));
        uint256 g = _least(keeper, data, id, 1_000, HI, P_DELIVERED);
        Run memory under = _run(keeper, data, g - 1, id);
        assertEq(under.out, OTHER, "one gas under the least delivering limit reverts, and never as PushGasShort");
        assertEq(under.pushCalls, 0, "with no self-call: the strict transfer is inline");
        assertEq(under.revenue, banked, "and nothing moved");
        Run memory at = _run(keeper, data, g, id);
        assertTrue(at.swept, "the least limit delivers");
        assertEq(at.revenue, 0, "the whole counter");

        ace.sweepRevenue(mid);
        assertEq(read.protocolRevenue(mid), 0, "premise: nothing left to sweep");
        vm.prank(keeper);
        (bool ok,) = address(ace).call{gas: LO}(data);
        assertTrue(ok, "an empty sweep demands no budget: it returns before the gate");
    }

    /* ============ THE CAP: a hostile quote burns at most the budget per push ============ */

    /// @notice A BURNING QUOTE COSTS A CLOSE AT MOST ONE BUDGET PER PUSH, measured against a quote that refuses at once.
    /// @dev Both shapes take the same catch path, so the difference is what the callee consumed and nothing else.
    function test_Hostile_ABurningQuoteBurnsAtMostTheBudgetPerPush() public {
        uint256 budget = PushGasRig.PUSH_GAS;
        (uint256 a, address w1, bytes memory settle) = _door(SETTLE);
        uint256 one = _burnOverRefusal(w1, settle, a);
        emit log_named_uint("settleExpired: a full burn over a refusal (one push)", one);
        assertLe(one, budget, "a burning quote spent more than the budget on the one push");
        assertGe(one, (budget * 9) / 10, "and the push was really handed the budget");

        (uint256 b, address w2, bytes memory force) = _door(FORCE);
        uint256 two = _burnOverRefusal(w2, force, b);
        emit log_named_uint("forceClose: a full burn over a refusal (sweep and push)", two);
        assertLe(two, 2 * budget, "the two pushes spent more than two budgets");
        assertGe(two, (2 * budget * 9) / 10, "and both were really handed a budget");
    }

    function _burnOverRefusal(address who, bytes memory data, uint256 id) internal returns (uint256) {
        usdc.setReverting(true);
        Run memory refused = _run(who, data, HI, id);
        usdc.setReverting(false);
        usdc.setBurnAll(true);
        Run memory burned = _run(who, data, HI, id);
        usdc.setBurnAll(false);
        assertTrue(refused.closed && burned.closed, "premise: both closes landed");
        assertTrue(refused.pushFailed && burned.pushFailed, "premise: both took the fallback");
        return burned.used - refused.used;
    }

    /* ============ THE WRAPPERS: a multicall leg forwards the refusal verbatim ============ */

    /// @notice A STARVED LEG BUBBLES `PushGasShort` THROUGH `multicall`, the four bytes and nothing else.
    function test_Multicall_AStarvedLegBubblesPushGasShort() public {
        (uint256 id,, bytes memory leg) = _door(SETTLE);
        bytes[] memory legs = new bytes[](1);
        legs[0] = leg;
        bytes memory data = abi.encodeCall(Ace.multicall, (legs));
        uint256 g = _least(keeper, data, id, LO, HI, P_DONE);
        Run memory r = _run(keeper, data, g - 1, id);
        assertEq(r.out, SHORT, "the starved leg's refusal did not reach the caller by name");
        assertEq(r.ret.length, 4, "a bare selector, verbatim");
        assertFalse(r.closed, "and nothing landed");
    }

    /* ============ THE RAIL: the budget is a constructor argument inside fixed bounds ============ */

    /// @notice THE CONSTRUCTOR REFUSES A BUDGET OUTSIDE THE RAIL, admits both ends, and publishes what it was given.
    function test_Rail_TheConstructorRefusesOutOfRangeAndPublishesPushGas() public {
        uint256 min = PushGasRig.MIN_PUSH_GAS;
        uint256 max = PushGasRig.MAX_PUSH_GAS;
        (address h, bytes memory e) = PushGasRig.tryHub(treasury, min - 1);
        assertEq(h, address(0), "a budget under the floor constructed");
        assertEq(bytes4(e), PushGasRig.outOfRangeSelector(), "and refused by some other name");
        (h, e) = PushGasRig.tryHub(treasury, max + 1);
        assertEq(h, address(0), "a budget over the ceiling constructed");
        assertEq(bytes4(e), PushGasRig.outOfRangeSelector(), "and refused by some other name");
        (h,) = PushGasRig.tryHub(treasury, min);
        assertEq(PushGasRig.pushGasOf(Ace(h)), min, "the floor constructs and publishes itself");
        (h,) = PushGasRig.tryHub(treasury, max);
        assertEq(PushGasRig.pushGasOf(Ace(h)), max, "the ceiling constructs and publishes itself");
        assertEq(PushGasRig.pushGasOf(ace), PushGasRig.PUSH_GAS, "and the fixture hub runs the fixture budget");
        assertGe(ace.PUSH_FLOOR(), (ace.PUSH_GAS() * 64) / 63, "the published push floor leaves the callee less than its budget");
        assertGt(ace.SWEEP_FLOOR(), ace.PUSH_FLOOR(), "the sweep's floor does not sit over the push's, so a close at its estimate could sweep");
    }

    /// @notice THE PUBLISHED FLOOR IS THE DEMAND, AND IT ROUNDS UP BY ONE GAS where 64/63 has a remainder.
    /// @dev 63,000 x 64/63 is exactly 64,000; 63,001 x 64/63 is 64,001.02, which the shipped ceil takes to 64,002.
    /// @dev floor(64p/63) would already make EIP-150 forward exactly p (64,001 less 64,001/64 is 63,001): the ceil is one gas of margin.
    /// @dev Nothing else differs between the two hubs, so their least limits differ by exactly their published floors' difference.
    function test_Floor_ThePublishedFloorIsTheDemandAndRoundsUpByOneGas() public {
        (uint256 exact, uint256 floorExact) = _leastSettleOnAHubAt(63_000);
        (uint256 over, uint256 floorOver) = _leastSettleOnAHubAt(63_001);
        emit log_named_uint("settleExpired least limit at a 63,000 budget", exact);
        emit log_named_uint("settleExpired least limit at a 63,001 budget", over);
        assertEq(over - exact, floorOver - floorExact, "the least limit does not track the published PUSH_FLOOR");
        assertEq(floorOver - floorExact, 2, "the floor no longer takes the ruled ceil on 63,001 x 64/63");
    }

    /// @dev A fresh hub at `pushGas` with this rig's market, one loan past its roll window, its least settling limit and its floor.
    function _leastSettleOnAHubAt(uint256 pushGas) internal returns (uint256 g, uint256 floor) {
        uint256 snap = vm.snapshotState();
        (Ace saved, PositionManager savedPm, AceReader savedRead, bytes32 savedMid) = (ace, pm, read, mid);
        MarketParams memory p = AceFixtures.marketParams(quote, address(coll));
        p.record = address(record);
        p.lender = alice;
        p.minTenor = 7 days;
        p.maxTenor = TEN30;
        AceFixtures.Deployment memory d = PushGasRig.deploy(p, treasury, pushGas);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        _lend(DEPOSIT);
        (uint256 id, address who, bytes memory data) = _door(SETTLE);
        g = _least(who, data, id, LO, HI, P_DONE);
        floor = ace.PUSH_FLOOR();
        (ace, pm, read, mid) = (saved, savedPm, savedRead, savedMid);
        vm.revertToState(snap);
    }

    /* ============ THE DEMAND IS STATE-STABLE AT FIXTURE SIZE: every close credits what it pushes ============ */

    /// @notice AT FIXTURE SIZE EVERY TERMINAL CLOSE CREDITS THE POOL IT PUSHES, so whether it pushes does not turn on a stranger.
    /// @dev The lender collects first, so the pool is empty when the close starts; the close alone must fill it.
    /// @dev A close that credits nothing pushes only when someone else has credited the pair, and demands the budget only then.
    /// @dev That close EXISTS: a dust loan whose origination fee rounds to 1 escrows nothing. A recorded residual, not a fixture.
    function test_Close_EveryTerminalCloseCreditsThePoolItPushes() public {
        for (uint8 door; door < 4; door++) {
            (uint256 id, address who, bytes memory data) = _door(door);
            vm.prank(alice);
            ace.collect(quote, alice);
            assertEq(_owed(), 0, "premise: the pool is empty as the close starts");
            Run memory r = _run(who, data, HI, id);
            assertTrue(r.collected, string.concat(_name(door), ": the close credited nothing, so it pushed nothing"));
            assertGt(r.collectedAmount, 0, "and announced a zero");
        }
    }

    /* ============ DRIFT: inside the push it cannot revert a funded close; in the close's own work before the check it can ============ */

    /// @notice A LENDER EMPTYING ITS BALANCE AFTER THE ESTIMATE CANNOT REVERT A CLOSING REPAY: that drift is INSIDE the push.
    /// @dev The estimate priced a nonzero-to-nonzero credit; inclusion meets a from-zero write, 17,100 dearer, inside the budget.
    function test_Drift_ALenderZeroingItsBalanceCannotRevertAClosingRepay() public {
        IRigQuote(quote).mint(alice, 1_000e6);
        (uint256 id, address who, bytes memory data) = _door(REPAY);
        uint256 g = _least(who, data, id, LO, HI, P_DONE);
        assertTrue(_run(who, data, g, id).collected, "premise: at the estimate the push paid");
        vm.prank(alice);
        IRigQuote(quote).transfer(address(0xDEAD), 1_000e6);
        assertEq(IRigQuote(quote).balanceOf(alice), 0, "premise: the lender now holds none");
        Run memory r = _run(who, data, g, id);
        assertEq(r.out, OK, "the drift reverted the close at its estimate");
        assertTrue(r.collected, "and the push still paid");
        assertEq(r.owed, 0, "the whole pool");
    }

    /// @notice RESIDUAL, PINNED: drift in the close's OWN work before the check CAN revert a close sent at its exact estimate.
    /// @dev The lender's `collect` between estimate and inclusion empties the pool, so the repay's credit becomes a from-zero write.
    /// @dev That lands ahead of the pre-check: +19,900 here (the setUp value is the original), +17,100 on mainnet.
    /// @dev So the exact estimate reverts `PushGasShort`, and the same close resent with the from-zero margin lands and pays.
    /// @dev Not a regression: the old least limit also sat at the end of the body, and the same drift ran it out of gas.
    function test_Drift_ACollectBeforeInclusionCanRevertAnExactEstimate() public {
        (uint256 id, address who, bytes memory data) = _door(REPAY);
        uint256 g = _least(who, data, id, LO, HI, P_DONE);
        assertTrue(_run(who, data, g, id).collected, "premise: at the estimate the push paid");
        vm.prank(alice);
        ace.collect(quote, alice);
        assertEq(_owed(), 0, "premise: the lender emptied the pool between estimate and inclusion");
        assertEq(_run(who, data, g, id).out, SHORT, "the close's own from-zero credit no longer moves the demand: pin is stale");
        Run memory resent = _run(who, data, g + FROM_ZERO_MARGIN, id);
        assertEq(resent.out, OK, "the from-zero margin did not cover the drift");
        assertTrue(resent.collected, "and the resent close pays the lender");
        assertEq(resent.owed, 0, "the whole pool, its own credit included");
    }
}

/// @title AcePushGasShapes
/// @notice THE LEAST LIMIT IS SET BY THE BUDGET, NOT BY THE TOKEN: a plain ERC-20 and a USDC-shaped proxy in one hub.
/// @dev The USDC shape walks a proxy, an implementation slot, a pause flag and two blacklist words: near the measured need.
contract AcePushGasShapesTest is PushGasDoorRig {
    address internal plain; // a MockERC20 quote, the second market's
    bytes32 internal plainMid;
    MockPersistenceRecord internal plainRecord;

    function _newQuote() internal override returns (address) {
        return address(new MockProxyERC20(address(new MockUsdcImpl())));
    }

    function setUp() public override {
        super.setUp();
        plain = address(new MockERC20("Plain", "PLN", 6));
        plainRecord = new MockPersistenceRecord(plain, address(coll));
        MarketParams memory p = AceFixtures.marketParams(plain, address(coll));
        p.record = address(plainRecord);
        p.lender = alice;
        p.minTenor = 7 days;
        p.maxTenor = TEN30;
        plainMid = ace.createMarket(p);
        _swap();
        _lend(DEPOSIT);
        _swap();
    }

    /// @dev Point the rig at the other market: its id, its quote and its record.
    function _swap() internal {
        (mid, plainMid) = (plainMid, mid);
        (quote, plain) = (plain, quote);
        (record, plainRecord) = (plainRecord, record);
    }

    /// @notice AT EVERY DOOR'S LEAST LIMIT THE LENDER IS PAID, on both shapes: one push, `Collected`, the pool empty.
    /// @dev forceClose's due sweep is skipped there, stamp and counter untouched: the least limit funds the lender alone.
    function test_Estimate_EveryDoorPushesAtItsLeastLimit() public {
        for (uint8 shape; shape < 2; shape++) {
            for (uint8 door; door < 4; door++) {
                (uint256 id, address who, bytes memory data) = _door(door);
                uint64 stamp = read.marketState(mid).lastSweptAt;
                uint256 banked = read.protocolRevenue(mid);
                uint256 g = _least(who, data, id, LO, HI, P_DONE);
                Run memory r = _run(who, data, g, id);
                string memory tag = string.concat(shape == 0 ? "usdc shape " : "plain erc20 ", _name(door));
                emit log_named_uint(tag, g);
                assertEq(r.out, OK, string.concat(tag, ": the least limit did not complete sweepless"));
                assertTrue(r.collected, string.concat(tag, ": the least limit did not pay the lender"));
                assertEq(r.owed, 0, "the whole pool");
                assertEq(r.pushCalls, 1, "one transfer, the lender's");
                assertTrue(r.closed, "and the loan closed");
                if (door == FORCE) {
                    assertEq(r.stamp, stamp, "a skipped sweep stamped a period");
                    assertEq(r.revenue, banked, "or moved the counter");
                }
            }
            _swap();
        }
    }

    /// @notice THE TWO SHAPES' LEAST LIMITS AGREE at the doors whose path to the push touches no quote.
    /// @dev The demand is the fixed floor, so a dearer token moves nothing an estimator sees; only the paying frame costs more.
    function test_PreCheck_TheLimitIsSetByTheBudgetNotTheNeed() public {
        uint8[3] memory doors = [FINALIZE, FORCE, SETTLE];
        for (uint256 i; i < 3; i++) {
            (uint256 a, address wa, bytes memory da) = _door(doors[i]);
            uint256 gUsdc = _least(wa, da, a, LO, HI, P_DONE);
            assertTrue(_run(wa, da, gUsdc, a).collected, "premise: the usdc shape pays at its least limit");
            _swap();
            (uint256 b, address wb, bytes memory db) = _door(doors[i]);
            uint256 gPlain = _least(wb, db, b, LO, HI, P_DONE);
            assertTrue(_run(wb, db, gPlain, b).collected, "premise: the plain token pays at its least limit");
            _swap();
            uint256 d = gUsdc > gPlain ? gUsdc - gPlain : gPlain - gUsdc;
            emit log_named_uint(string.concat(_name(doors[i]), ": usdc shape least limit"), gUsdc);
            emit log_named_uint(string.concat(_name(doors[i]), ": plain token least limit"), gPlain);
            assertLe(d, 1_000, string.concat(_name(doors[i]), ": the least limit follows the token's need, not the budget"));
        }
    }
}

/// @title AcePushGasHook
/// @notice A LENDER HOOK IS A CALLEE LIKE ANY OTHER: over the budget it takes the fallback, and it cannot revert the close.
/// @dev The lender is `alice`'s address with hook code etched on it, so the market needs no change.
contract AcePushGasHookTest is PushGasDoorRig {
    function _newQuote() internal override returns (address) {
        return address(new MockHookERC20("USD Coin", "USDC", 6));
    }

    function _hook() internal view returns (GasHookLender) {
        return GasHookLender(alice);
    }

    /// @notice A HOOK THAT BURNS AT INCLUSION, OFF AT THE ESTIMATE, CANNOT REVERT THE CLOSE: one attempt, the fallback, `collect` later.
    function test_Drift_AHookThatBurnsAtInclusionCannotRevertTheClose() public {
        vm.etch(alice, type(GasHookLender).runtimeCode);
        (uint256 id, address who, bytes memory data) = _door(SETTLE);
        uint256 g = _least(who, data, id, LO, HI, P_DONE);
        assertTrue(_run(who, data, g, id).collected, "premise: with the hook off the estimate pays");

        MockHookERC20(quote).setHookTarget(alice);
        _hook().setForever(true);
        Run memory r = _run(who, data, g, id);
        assertEq(r.out, OK, "a hook turned on after the estimate reverted the close");
        assertEq(r.pushCalls, 1, "the push was attempted once");
        assertTrue(r.pushFailed, "and took its fallback");
        assertGt(r.owed, 0, "keeping the credit");

        vm.prank(who);
        (bool ok,) = address(ace).call{gas: g}(data);
        assertTrue(ok, "premise: the close lands for real");
        uint256 kept = _owed();
        MockHookERC20(quote).setHookTarget(address(0));
        vm.prank(alice);
        assertEq(ace.collect(quote, alice), kept, "the lender's own collect pays what the push could not");
    }

    /// @notice A HOOK DEARER THAN THE BUDGET TAKES THE FALLBACK even under a fat limit, and a cheap one is paid under the same limit.
    /// @dev The budget caps what the callee spends whatever the caller sent, which is what bounds a hostile hook's burn.
    function test_Hook_ALenderHookOverTheBudgetTakesTheFallback() public {
        vm.etch(alice, type(GasHookLender).runtimeCode);
        (uint256 id, address who, bytes memory data) = _door(FINALIZE);
        MockHookERC20(quote).setHookTarget(alice);
        _hook().setCost((PushGasRig.PUSH_GAS * 3) / 2);
        Run memory dear = _run(who, data, HI, id);
        assertTrue(dear.closed, "the close landed");
        assertTrue(dear.pushFailed, "a hook over the budget was paid anyway: the budget does not cap the callee");
        assertGt(dear.owed, 0, "and the credit is kept");
        _hook().setCost(20_000);
        Run memory cheap = _run(who, data, HI, id);
        assertTrue(cheap.collected, "a hook inside the budget is paid");
    }
}

/// @title AcePushGasRouter
/// @notice THE TREASURY IS A ROUTER WHOSE BALANCE EMPTIES ON EVERY SWEEP OF ITS OWN, so a front-run can raise the sweep's cost.
contract AcePushGasRouterTest is PushGasDoorRig {
    function _newQuote() internal override returns (address) {
        return address(new MockERC20("USD Coin", "USDC", 6));
    }

    function _treasury() internal override returns (address) {
        return address(new RevenueRouter(address(0xAD), address(0x5117)));
    }

    /// @notice A ROUTER SWEEP FRONT-RUNNING forceClose CANNOT REVERT IT OR STARVE EITHER LEG: at the least sweeping limit both land.
    /// @dev The estimate paid a funded router; inclusion pays an emptied one, a from-zero write dearer INSIDE the sweep's budget.
    /// @dev The lender push runs first and the router is only the sweep's callee, so the drift never reaches the lender's pre-check.
    function test_Drift_ARouterSweepFrontRunCannotStarveForceCloseLenderPush() public {
        _open(TEN30);
        ace.sweepRevenue(mid);
        assertGt(IRigQuote(quote).balanceOf(treasury), 0, "premise: the router holds revenue");
        (uint256 id, address who, bytes memory data) = _door(FORCE);
        assertGt(read.protocolRevenue(mid), 0, "premise: fresh revenue is due");
        uint256 s = _least(who, data, id, LO, HI, P_DELIVERED);

        address[] memory t = new address[](1);
        t[0] = quote;
        RevenueRouter(treasury).sweep(t);
        assertEq(IRigQuote(quote).balanceOf(treasury), 0, "premise: the front-run emptied the router");
        Run memory r = _run(who, data, s, id);
        assertEq(r.out, OK_SWEPT, "the front-run reverted the close at its estimate");
        assertTrue(r.swept, "or starved the sweep");
        assertTrue(r.collected, "or the lender push in front of it");
        assertEq(r.owed, 0, "the whole pool");
    }
}

/// @title AcePushGasDeleverage
/// @notice `deleverage`'s trailing sweep: best-effort, gated on the same budget, and never a reason for the crank to revert.
contract AcePushGasDeleverageTest is PushGasDoorRig, DeleverageCrank {
    uint16 internal constant BAND_BPS = 3000;

    function _newQuote() internal override returns (address) {
        return address(new MockERC20("USD Coin", "USDC", 6));
    }

    function _treasury() internal override returns (address) {
        return address(new RevenueRouter(address(0xAD), address(0x5117)));
    }

    function _deleverageQuote() internal view override returns (address) {
        return quote;
    }

    function _params(MarketParams memory p) internal pure override {
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
    }

    function setUp() public override {
        super.setUp();
        record.setMinPrice(AceFixtures.px(2e18, quote, address(coll)));
    }

    /// @dev The record told the band is broken at the loan's CURRENT trigger, and the crank's calldata.
    function _crankData(uint256 id) internal returns (bytes memory) {
        uint256 trig = read.triggerPrice(id);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - uint256(BAND_BPS) * 1e14));
        record.setMinPrice(trig + trig / 20);
        return abi.encodeCall(Ace.deleverage, (id, 0, ""));
    }

    /// @notice A DUE SWEEP RIDES A FUNDED CRANK AND IS SKIPPED BY A STARVED ONE, and the starved crank still lands.
    function test_Deleverage_ADueSweepRidesAFundedCrankAndSkipsAStarvedOne() public {
        uint256 id = _open(0);
        _warpBy(1 days);
        bytes memory data = _crankData(id);
        uint64 stamp = read.marketState(mid).lastSweptAt;
        uint256 banked = read.protocolRevenue(mid);
        uint256 debt = read.debtOf(id);
        assertGt(banked, 0, "premise: revenue is due");
        uint256 g = _least(address(this), data, id, LO, HI, P_DONE);
        Run memory starved = _run(address(this), data, g, id);
        assertEq(starved.out, OK, "the least crank emitted a sweep event");
        assertLt(starved.debt, debt, "premise: the crank sold");
        assertEq(starved.stamp, stamp, "a skipped sweep stamped a period");
        assertEq(starved.revenue, banked, "or moved the counter");
        Run memory funded = _run(address(this), data, HI, id);
        assertTrue(funded.swept, "a funded crank did not sweep what was due");
        assertEq(funded.revenue, 0, "the whole counter");
    }

    /// @notice A ROUTER SWEEP FRONT-RUNNING A CRANK CANNOT REVERT IT, and the sweep still delivers at the estimate.
    function test_Drift_ARouterSweepFrontRunCannotRevertDeleverage() public {
        uint256 id = _open(0);
        ace.sweepRevenue(mid);
        assertGt(IRigQuote(quote).balanceOf(treasury), 0, "premise: the router holds revenue");
        _open(0); // a second draw banks fresh revenue
        _warpBy(1 days);
        bytes memory data = _crankData(id);
        uint256 s = _least(address(this), data, id, LO, HI, P_DELIVERED);

        address[] memory t = new address[](1);
        t[0] = quote;
        RevenueRouter(treasury).sweep(t);
        assertEq(IRigQuote(quote).balanceOf(treasury), 0, "premise: the front-run emptied the router");
        Run memory r = _run(address(this), data, s, id);
        assertEq(r.out, OK_SWEPT, "the front-run reverted the crank at its estimate");
        assertTrue(r.swept, "or starved the sweep");
    }
}
