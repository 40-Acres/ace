// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Lender} from "../../src/ace/hub/Lender.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ITokenReceiveHook, MockHookERC20} from "../mocks/MockHookERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";

/// @dev The three calls every quote mock here answers, so one rig drives both quote shapes.
interface IRehomeQuote {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title AcePushAtCloseRehomeRig
/// @notice A funded market whose one lender is `alice`, so the pool a close pushes is wholly hers.
/// @dev These rows carry push coverage the sale used to hold: the least budget that settles, and a lender re-entering mid-push.
/// @dev Green on the tree they were written against, by design: the push is the close's, and the close doors are unchanged.
abstract contract AcePushAtCloseRehomeRig is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    IRehomeQuote internal quote;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE); // the market's one lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant DEPOSIT = 400_000e6;
    uint256 internal constant PRINCIPAL = 40_000e6;
    uint256 internal constant COLL = 100_000e18;

    bytes32 internal constant COLLECTED_SIG = Lender.Collected.selector; // from the declared event, so a re-shape moves it
    bytes32 internal constant PUSH_FAILED_SIG = Lender.LenderPushFailed.selector; // likewise

    function _newQuote() internal virtual returns (address);

    function setUp() public {
        vm.warp(1_000_000);
        quote = IRehomeQuote(_newQuote());
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(address(quote), address(coll));

        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.record = address(record);
        p.lender = alice;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        quote.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        quote.approve(address(ace), DEPOSIT);
        ace.deposit(mid, DEPOSIT);
        vm.stopPrank();
    }

    function _owed() internal view returns (uint256) {
        (,, uint256 owed) = read.lenderPools(alice, address(quote));
        return owed;
    }

    function _open(uint64 tenor) internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Past the whole roll window, which is what `settleExpired` requires; expiry alone is not enough.
    function _warpPastTheRollWindow(uint256 loanId) internal {
        uint64 tenor = read.loan(loanId).tenor;
        vm.warp(uint256(read.loan(loanId).expiry) + MarketInit.autoRefinanceWindow(tenor) + 1);
    }

    /// @dev Whether the hub emitted `sig` in `logs`, and that event's one-word amount.
    function _seen(Vm.Log[] memory logs, bytes32 sig) internal view returns (bool saw, uint256 amount) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0 || logs[i].topics[0] != sig) continue;
            return (true, abi.decode(logs[i].data, (uint256)));
        }
    }
}

/// @title AcePushAtCloseLeastBudget
/// @notice THE LEAST BUDGET THAT SETTLES PAYS THE LENDER: an estimate lands on a close whose push is funded, never skipped.
contract AcePushAtCloseLeastBudgetTest is AcePushAtCloseRehomeRig {
    function _newQuote() internal override returns (address) {
        return address(new MockERC20("USD Coin", "USDC", 6));
    }

    /// @notice At the least budget that settles, the push is called once and pays the whole pool.
    /// @dev The pre-check refuses any limit that cannot hand the push its fixed budget, so the least settling one funds it.
    /// @dev `expectCall(..., 1)` pins the one attempt; the old starved branch, which called nothing, is gone.
    function test_SettleExpired_TheLeastBudgetThatSettlesPaysTheLender() public {
        uint256 loanId = _open(TEN30);
        _warpPastTheRollWindow(loanId);
        uint256 cap = _leastBudgetThatSettles(loanId);
        uint256 aliceHad = quote.balanceOf(alice);
        uint256 owedBefore = _owed();

        vm.expectCall(address(ace), abi.encodeWithSelector(Ace.pushToken.selector), 1);
        vm.recordLogs();
        vm.prank(keeper);
        ace.settleExpired{gas: cap}(loanId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool failed,) = _seen(logs, PUSH_FAILED_SIG);
        (bool paid, uint256 amount) = _seen(logs, COLLECTED_SIG);

        assertTrue(read.loan(loanId).closedAt != 0, "the loan settled on the least budget that settles it");
        assertTrue(paid, "and the push paid the lender at that budget");
        assertFalse(failed, "without a fallback");
        assertGe(amount, owedBefore, "the whole pool, the close's own credit on top");
        assertEq(_owed(), 0, "leaving it empty");
        assertEq(quote.balanceOf(alice) - aliceHad, amount, "delivered");
    }

    /// @dev Bisect the least outer budget at which `settleExpired` settles. The bounds are guards, never tuning knobs.
    function _leastBudgetThatSettles(uint256 loanId) internal returns (uint256) {
        uint256 lo = 60_000; // under the door's own body, so below the floor on either build profile
        uint256 hi = 8_000_000;
        assertTrue(_settlesAt(loanId, hi), "premise: the door settles at 8M");
        assertFalse(_settlesAt(loanId, lo), "premise: the low bound is under the floor, so there is an interval to search");
        while (hi - lo > 1_000) {
            uint256 probe = (lo + hi) / 2;
            if (_settlesAt(loanId, probe)) hi = probe;
            else lo = probe;
        }
        return hi;
    }

    /// @dev One probe, snapshotted, so every probe settles the same loan.
    function _settlesAt(uint256 loanId, uint256 cap) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        try ace.settleExpired{gas: cap}(loanId) {
            ok = read.loan(loanId).closedAt != 0;
        } catch {}
        vm.revertToState(snap);
    }
}

/// @notice A contract lender whose receive hook re-enters the hub while a close's push is paying it.
/// @dev SWALLOW mode records each re-entry's revert and lets the push land; BUBBLE mode lets the first refusal fail the transfer.
/// @dev THE RECORD IS PRE-SEEDED at `arm`, so the hook's own writes are nonzero-to-nonzero: the push is handed a fixed budget,
/// @dev and six fresh slots written inside it would make this row about storage pricing rather than about the guard.
contract PushReentryLender is ITokenReceiveHook {
    uint256 internal constant SEED = 1; // `fired` and `cursor` start here, so their first write is not from zero
    bytes4 internal constant UNSET = 0xffffffff; // the seeded slot value for a re-entry not yet recorded

    Ace public hub;
    address public token;
    bytes32 public market;
    uint256 public loanId;
    bool public bubble;
    uint256 public fired; // SEED plus how many pushes reached the hook
    uint256 public cursor; // SEED plus the next `errs` index to record
    bytes4[] public errs; // the revert selector of each re-entry, 0 when it did not revert; UNSET until recorded

    function arm(Ace h, address t, bytes32 m, uint256 id, bool b) external {
        (hub, token, market, loanId, bubble) = (h, t, m, id, b);
        (fired, cursor) = (SEED, SEED);
        for (uint256 i; i < 4; i++) {
            errs.push(UNSET);
        }
    }

    function onTokenReceived(address, uint256) external {
        fired++;
        if (bubble) {
            hub.collect(token, address(this)); // reverts under the guard, and the revert fails the transfer
            return;
        }
        _try(abi.encodeCall(Ace.collect, (token, address(this))));
        _try(abi.encodeCall(Ace.withdraw, (market, type(uint256).max, address(this), 0)));
        _try(abi.encodeCall(Ace.buyInventory, (loanId, 1, 0, address(this))));
        _try(abi.encodeCall(Ace.lenderOwed, (address(this), token)));
    }

    /// @notice How many re-entries ran.
    function errCount() external view returns (uint256) {
        return cursor - SEED;
    }

    /// @notice How many pushes reached the hook.
    function pushes() external view returns (uint256) {
        return fired - SEED;
    }

    function _try(bytes memory data) internal {
        (bool ok, bytes memory ret) = address(hub).call(data);
        errs[cursor - SEED] = ok ? bytes4(0) : bytes4(ret);
        cursor++;
    }
}

/// @title AcePushAtCloseReentry
/// @notice A HOOK-CARRYING QUOTE lets the lender re-enter the hub mid-push; the close holds the guard, so every re-entry is refused.
/// @dev The push runs after every state write, under `finalize`'s `nonReentrant`: a re-entered exit or ledger read sees the lock.
/// @dev The lender is `alice`'s address with probe code etched on it, so the rig's market needs no change.
/// @dev NO RECORDED-LOG DECODING in these rows: the pool's figure is measured by a plain close in a snapshot instead.
contract AcePushAtCloseReentryTest is AcePushAtCloseRehomeRig {
    function _newQuote() internal override returns (address) {
        return address(new MockHookERC20("USD Coin", "USDC", 6));
    }

    function _probe() internal view returns (PushReentryLender) {
        return PushReentryLender(alice);
    }

    /// @dev The probe code at the lender's address, a live loan, then the hook armed AFTER the open and the distress proved.
    function _armedClose(bool bubble) internal returns (uint256 loanId) {
        vm.etch(alice, type(PushReentryLender).runtimeCode);
        loanId = _open(TEN30);
        _probe().arm(ace, address(quote), mid, loanId, bubble);
        MockHookERC20(address(quote)).setHookTarget(alice);
        record.setBelow(true);
        assertTrue(read.settleable(loanId), "premise: the record proves the distress `finalize` requires");
    }

    /// @dev What an unmolested `finalize` pushes, measured with the hook disarmed inside a snapshot.
    function _plainPush(uint256 loanId) internal returns (uint256 pushed) {
        uint256 snap = vm.snapshotState();
        MockHookERC20(address(quote)).setHookTarget(address(0));
        uint256 had = quote.balanceOf(alice);
        vm.prank(keeper);
        ace.finalize(loanId);
        pushed = quote.balanceOf(alice) - had;
        vm.revertToState(snap);
    }

    /// @notice EVERY RE-ENTRY MID-PUSH IS REFUSED BY THE GUARD, and the push still pays the lender exactly once.
    /// @dev Four doors: the lender's own `collect` and `withdraw`, a `buyInventory` on the closing loan, and the guarded `lenderOwed` read.
    function test_Finalize_AReentryDuringTheLenderPushIsRefusedByTheGuard_AndThePushPaysOnce() public {
        uint256 loanId = _armedClose(false);
        uint256 expected = _plainPush(loanId);
        assertGt(expected, 0, "premise: an unmolested close pushes real credit");
        uint256 aliceHad = quote.balanceOf(alice);

        vm.prank(keeper);
        ace.finalize(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "premise: the loan settled");
        assertEq(_probe().pushes(), 1, "the push reached the lender's hook once");
        assertEq(_probe().errCount(), 4, "and every re-entry ran");
        for (uint256 i; i < 4; i++) {
            assertEq(_probe().errs(i), GUARD_TRIP, "each re-entry was refused by the hub's guard");
        }
        assertEq(quote.balanceOf(alice) - aliceHad, expected, "the lender was paid the whole pool exactly once");
        assertEq(_owed(), 0, "and the pool is empty");
    }

    /// @notice A RE-ENTRY THAT BUBBLES FAILS ONLY THE PUSH: the close lands, the credit is restored whole, and `collect` pays it.
    /// @dev `LenderPushFailed` is expected by its lender and quote topics and its amount: the whole pool the plain close would pay.
    function test_Finalize_ABubblingReentryFailsOnlyThePush_TheCloseLands() public {
        uint256 loanId = _armedClose(true);
        uint256 expected = _plainPush(loanId);
        assertGt(expected, 0, "premise: an unmolested close pushes real credit");
        uint256 aliceHad = quote.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(ace));
        emit Lender.LenderPushFailed(alice, address(quote), expected);
        vm.prank(keeper);
        ace.finalize(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the close landed");
        assertEq(quote.balanceOf(alice), aliceHad, "nothing reached the lender");
        assertEq(_owed(), expected, "the credit is restored whole");

        MockHookERC20(address(quote)).setHookTarget(address(0));
        vm.prank(alice);
        assertEq(ace.collect(address(quote), alice), expected, "and the lender's own collect pays it");
        assertEq(_owed(), 0, "leaving the pool empty");
    }
}
