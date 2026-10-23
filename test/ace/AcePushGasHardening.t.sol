// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace, PushGasOutOfRange} from "../../src/ace/hub/Ace.sol";
import {Lender} from "../../src/ace/hub/Lender.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockHostileGasERC20} from "../mocks/MockHostileGasERC20.sol";
import {BurnAllRecord} from "../mocks/UntrustedDependencyMocks.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {PushGasRig} from "../utils/PushGasRig.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {PushGasDoorRig, IRigQuote} from "./AcePushGasBudget.t.sol";

/// @title AcePushGasRail
/// @notice THE RAIL AND THE FLOORS AGAINST THE RULED NUMBERS, never against `Constants`: a row reading the constant moves with it.
/// @dev The ruled values: a budget in [60,000, 250,000], `PUSH_TAIL` 40,000, `SWEEP_TAIL` 47,000, the ceil of 64/63 ().
contract AcePushGasRailTest is Test {
    uint256 internal constant RULED_MIN = 60_000;
    uint256 internal constant RULED_MAX = 250_000;
    uint256 internal constant RULED_PUSH_TAIL = 40_000;
    uint256 internal constant RULED_SWEEP_TAIL = 47_000;

    /// @notice FOR EVERY BUDGET IN THE RAIL THE HUB PUBLISHES THE RULED FLOORS, derived here by a second formula (OZ `ceilDiv`).
    /// @dev And the published push floor, less its tail, is enough for EIP-150 to forward the whole budget: what a keeper relies on.
    function testFuzz_Rail_TheFloorsAreTheRuledFormulaAcrossTheRail(uint256 p) public {
        p = bound(p, RULED_MIN, RULED_MAX);
        (address h, bytes memory e) = PushGasRig.tryHub(AceFixtures.TREASURY, p);
        assertEq(e.length, 0, "an in-rail budget was refused");
        Ace a = Ace(h);
        uint256 whole = Math.ceilDiv(p * 64, 63);
        assertEq(a.PUSH_GAS(), p, "the hub publishes a budget it was not given");
        assertEq(a.PUSH_FLOOR(), whole + RULED_PUSH_TAIL, "PUSH_FLOOR is not ceil(64p/63) + the ruled 40,000");
        assertEq(a.SWEEP_FLOOR(), whole + RULED_SWEEP_TAIL, "SWEEP_FLOOR is not ceil(64p/63) + the ruled 47,000");
        uint256 w = a.PUSH_FLOOR() - RULED_PUSH_TAIL;
        assertGe(w - w / 64, p, "the published floor's whole part would not forward the budget under EIP-150");
    }

    /// @notice A BUDGET OUTSIDE THE RAIL IS REFUSED BY NAME, however far out: the rail is read before any arithmetic on it.
    /// @dev The high side runs to `type(uint256).max`, so a rail moved after the `* 64` would panic instead of naming the refusal.
    function testFuzz_Rail_ABudgetOutsideTheRailIsRefusedByName(uint256 p, bool high) public {
        p = high ? bound(p, RULED_MAX + 1, type(uint256).max) : bound(p, 0, RULED_MIN - 1);
        (address h, bytes memory e) = PushGasRig.tryHub(AceFixtures.TREASURY, p);
        assertEq(h, address(0), "a budget outside the ruled rail constructed");
        assertEq(e.length, 4, "the refusal is not a bare selector");
        assertEq(bytes4(e), PushGasOutOfRange.selector, "and not by the rail's own name");
    }

    /// @notice THE RULED ENDS, ONE GAS EITHER SIDE, AND THE MAINNET FLOORS THE DECISION PUBLISHES (141,588 and 148,588 at 100,000).
    /// @dev Pinned by argument because a fuzz row is a sampler: the four boundary points are the ones a rail mutation moves.
    function test_Rail_TheRuledEndsAndTheMainnetFloorsAreExact() public {
        (address h, bytes memory e) = PushGasRig.tryHub(AceFixtures.TREASURY, RULED_MIN - 1);
        assertTrue(h == address(0) && bytes4(e) == PushGasOutOfRange.selector, "59,999 constructed");
        (h,) = PushGasRig.tryHub(AceFixtures.TREASURY, RULED_MIN);
        assertEq(Ace(h).PUSH_GAS(), RULED_MIN, "60,000 did not construct");
        (h,) = PushGasRig.tryHub(AceFixtures.TREASURY, RULED_MAX);
        assertEq(Ace(h).PUSH_GAS(), RULED_MAX, "250,000 did not construct");
        (h, e) = PushGasRig.tryHub(AceFixtures.TREASURY, RULED_MAX + 1);
        assertTrue(h == address(0) && bytes4(e) == PushGasOutOfRange.selector, "250,001 constructed");

        assertEq(AceFixtures.PUSH_GAS, 100_000, "the fixture no longer runs the ruled mainnet budget");
        (h,) = PushGasRig.tryHub(AceFixtures.TREASURY, 100_000);
        assertEq(Ace(h).PUSH_FLOOR(), 141_588, "the mainnet push floor moved off the recorded 141,588");
        assertEq(Ace(h).SWEEP_FLOOR(), 148_588, "the mainnet sweep floor moved off the recorded 148,588");
    }
}

/// @title PushGasProbeRig
/// @notice `PushGasDoorRig` plus the balances and the failure amount a probe moves, read before the snapshot is restored.
abstract contract PushGasProbeRig is PushGasDoorRig {
    /// @dev A `Run` and the money it moved: what the lender and the treasury received, and what `LenderPushFailed` named.
    struct Seen {
        Run r;
        uint256 lenderGot;
        uint256 treasuryGot;
        bool failedSeen;
        uint256 failedAmount;
    }

    /// @dev The balances ride in `s` as the "before" figures and become the deltas after, which keeps the IR stack shallow.
    function _probe(address who, bytes memory data, uint256 g, uint256 loanId) internal returns (Seen memory s) {
        s.lenderGot = IRigQuote(quote).balanceOf(alice);
        s.treasuryGot = IRigQuote(quote).balanceOf(treasury);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.prank(who);
        (bool ok, bytes memory ret) = address(ace).call{gas: g}(data);
        s.r.pushCalls = _pushCalls();
        _readAll(s, vm.getRecordedLogs());
        _classify(s.r, ok, ret, loanId);
        s.lenderGot = IRigQuote(quote).balanceOf(alice) - s.lenderGot;
        s.treasuryGot = IRigQuote(quote).balanceOf(treasury) - s.treasuryGot;
        vm.revertToState(snap);
    }

    function _readAll(Seen memory s, VmSafe.Log[] memory logs) internal view {
        _readLogs(s.r, logs);
        _readFailure(s, logs);
    }

    function _readFailure(Seen memory s, VmSafe.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0 || logs[i].topics[0] != PUSH_FAILED_SIG) continue;
            (s.failedSeen, s.failedAmount) = (true, abi.decode(logs[i].data, (uint256)));
        }
    }

    function _done(Run memory r) internal pure returns (bool) {
        return r.out == OK || r.out == OK_SWEPT;
    }
}

/// @title AcePushGasRestore
/// @notice THE FALLBACK RESTORES THE POOL EXACTLY, AND A SHORT LIMIT MOVES NOTHING AND NEVER REACHES THE QUOTE.
/// @dev Here the pool is ZERO at the transaction's start (setUp only deposits), so every restore is the dear from-zero write.
/// @dev `AcePushGasRestoreFromCreditedPool` reruns both rows with the pool NONZERO at the start, where the restore is a dirty write.
contract AcePushGasRestoreTest is PushGasProbeRig {
    MockHostileGasERC20 internal usdc;

    function _newQuote() internal virtual override returns (address) {
        usdc = new MockHostileGasERC20("USD Coin", "USDC", 6);
        return address(usdc);
    }

    /// @notice AT EVERY DOOR A BURNED PUSH RESTORES THE WHOLE POOL IT WOULD HAVE PAID, to the wei, at the least admitted limit and at 8M.
    /// @dev The pool at the push is read off an honest run's `Collected`, so nothing here restates the close's own credit arithmetic.
    /// @dev `LenderPushFailed` names that same amount, the lender receives nothing, and the push was attempted.
    function test_Fallback_RestoresThePoolExactly_AtTheLeastAdmittedLimitAndAtAFatOne() public {
        for (uint8 door; door < 4; door++) {
            (uint256 id, address who, bytes memory data) = _door(door);
            Seen memory honest = _probe(who, data, HI, id);
            assertTrue(honest.r.collected, "premise: an honest close pays the lender");
            uint256 pool = honest.r.collectedAmount;
            assertEq(honest.lenderGot, pool, "premise: the push delivered what `Collected` named");

            usdc.setBurnAll(true);
            uint256 okAt = _least(who, data, id, LO, HI, P_DONE);
            _assertRestored(_probe(who, data, okAt, id), pool, _name(door));
            _assertRestored(_probe(who, data, HI, id), pool, _name(door));
            usdc.setBurnAll(false);
        }
    }

    function _assertRestored(Seen memory s, uint256 pool, string memory door) internal pure {
        assertTrue(s.r.closed, string.concat(door, ": the close did not land"));
        assertTrue(s.r.pushFailed && !s.r.collected, string.concat(door, ": the burned push did not take the fallback"));
        assertEq(s.r.owed, pool, string.concat(door, ": the fallback restored a different pool than the push would have paid"));
        assertEq(s.failedAmount, pool, string.concat(door, ": `LenderPushFailed` names another amount"));
        assertEq(s.lenderGot, 0, string.concat(door, ": a failed push moved quote to the lender"));
        assertGe(s.r.pushCalls, 1, string.concat(door, ": the push was never attempted"));
    }

    /// @notice UNDER THE LEAST LIMIT EVERY DOOR REVERTS `PushGasShort` HAVING NEVER CALLED THE QUOTE, and nothing it did survives.
    /// @dev `pushCalls == 0` pins the check AHEAD of the call: a post-check would also refuse, but only after the quote had run.
    /// @dev The CEI clear sits before the check, so the pool, the loan, the debt and the sweep's stamp and counter must all read as before.
    function test_PreCheck_AShortLimitNeverCallsTheQuoteAndMovesNothing() public {
        for (uint8 door; door < 4; door++) {
            _shortRows(door);
        }
    }

    /// @dev The ledger a refused close must leave exactly as it found it.
    struct Before {
        uint256 owed;
        uint256 debt;
        uint64 stamp;
        uint256 revenue;
    }

    function _shortRows(uint8 door) internal {
        (uint256 id, address who, bytes memory data) = _door(door);
        Before memory b = Before(_owed(), read.debtOf(id), read.marketState(mid).lastSweptAt, read.protocolRevenue(mid));
        uint256 least = _least(who, data, id, LO, HI, P_DONE);
        string memory tag = string.concat(_name(door), ": under the least limit");
        _assertShort(_probe(who, data, least - 1, id), b, tag);
        _assertShort(_probe(who, data, least - 50, id), b, tag);
        _assertShort(_probe(who, data, least - 1_000, id), b, tag);
        _assertShort(_probe(who, data, least - 10_000, id), b, tag);
    }

    function _assertShort(Seen memory s, Before memory b, string memory tag) internal pure {
        assertEq(s.r.out, SHORT, string.concat(tag, ", not PushGasShort"));
        assertEq(s.r.pushCalls, 0, string.concat(tag, ", the quote was called before the refusal"));
        assertEq(s.r.owed, b.owed, string.concat(tag, ", the CEI clear survived the revert"));
        assertFalse(s.r.closed, string.concat(tag, ", the loan closed"));
        assertEq(s.r.debt, b.debt, string.concat(tag, ", the debt moved"));
        assertEq(s.r.stamp, b.stamp, string.concat(tag, ", the sweep stamped"));
        assertEq(s.r.revenue, b.revenue, string.concat(tag, ", the revenue counter moved"));
        assertEq(s.lenderGot + s.treasuryGot, 0, string.concat(tag, ", quote moved"));
    }
}

/// @title AcePushGasRestoreFromCreditedPool
/// @notice THE SAME TWO ROWS WITH THE POOL NONZERO WHEN THE TRANSACTION STARTS: the restore is then a dirty write, not a from-zero one.
contract AcePushGasRestoreFromCreditedPoolTest is AcePushGasRestoreTest {
    function setUp() public override {
        super.setUp();
        _open(TEN30);
        assertGt(_owed(), 0, "premise: the open credited the pool, committed before any row's transaction starts");
    }
}

/// @title AcePushGasSweepGate
/// @notice THE STANDALONE SWEEP HAS NO GATE: it is strict and uncapped, demanding what its transfer costs and nothing when empty.
/// @dev Was the pin of the published `SWEEP_FLOOR` at the standalone door; that floor now gates the keeper piggyback alone.
contract AcePushGasSweepGateTest is PushGasProbeRig {
    function _newQuote() internal override returns (address) {
        return address(new MockERC20("USD Coin", "USDC", 6));
    }

    /// @notice THE STRICT SWEEP DEMANDS ITS TRANSFER, NOT THE PUBLISHED BUDGET: its least delivering limit sits under `SWEEP_FLOOR`.
    /// @dev The floor gates the keeper PIGGYBACK alone; the standalone door forwards the caller's gas and needs only what the transfer costs.
    function test_SweepRevenue_TheStrictDoorDemandsNoPublishedFloor() public {
        uint256 id = _open(TEN30);
        bytes memory data = abi.encodeCall(Ace.sweepRevenue, (mid));
        assertGt(read.protocolRevenue(mid), 0, "premise: revenue is banked");
        uint256 deliver = _least(keeper, data, id, 1_000, HI, P_DELIVERED);
        ace.sweepRevenue(mid);
        assertEq(read.protocolRevenue(mid), 0, "premise: nothing is banked now");
        uint256 empty = _least(keeper, data, id, 1_000, HI, P_DONE);
        emit log_named_uint("sweepRevenue delivers from       ", deliver);
        emit log_named_uint("sweepRevenue with nothing banked ", empty);
        emit log_named_uint("SWEEP_FLOOR                      ", ace.SWEEP_FLOOR());
        assertLt(empty, deliver, "an empty sweep demands less than a delivering one: the early return comes first");
        assertLt(deliver, ace.SWEEP_FLOOR(), "the strict door demanded the piggyback's budget: a gate still binds it");
    }
}

/// @title AcePushGasInertSweep
/// @notice A HUB WITH NO TREASURY SWEEPS NOTHING AND DEMANDS NOTHING: the strict sweep's first early return precedes its gate.
contract AcePushGasInertSweepTest is PushGasProbeRig {
    function _newQuote() internal override returns (address) {
        return address(new MockERC20("USD Coin", "USDC", 6));
    }

    function _treasury() internal pure override returns (address) {
        return address(0);
    }

    /// @notice WITH REVENUE BANKED AND NO TREASURY, `sweepRevenue` LANDS FAR UNDER THE FLOOR, calls nothing, stamps nothing, keeps the counter.
    function test_SweepRevenue_AnInertTreasuryDemandsNoBudgetAndMovesNothing() public {
        uint256 id = _open(TEN30);
        uint256 banked = read.protocolRevenue(mid);
        uint64 stamp = read.marketState(mid).lastSweptAt;
        assertGt(banked, 0, "premise: revenue is banked, so only the treasury check can return early");
        bytes memory data = abi.encodeCall(Ace.sweepRevenue, (mid));
        uint256 least = _least(keeper, data, id, 1_000, HI, P_DONE);
        emit log_named_uint("inert sweepRevenue lands from", least);
        assertLt(least, ace.SWEEP_FLOOR(), "an inert sweep demanded the budget: the treasury check does not come first");
        Seen memory s = _probe(keeper, data, least, id);
        assertEq(s.r.out, OK, "the inert sweep emitted a revenue event or reverted");
        assertEq(s.r.pushCalls, 0, "and it called the quote");
        assertEq(s.r.revenue, banked, "and it moved the counter");
        assertEq(s.r.stamp, stamp, "and it stamped a period");
    }
}

/// @title AcePushGasDemand
/// @notice AN EMPTY POOL DEMANDS NOTHING, AND A FUNDED ONE DEMANDS EXACTLY THE PUBLISHED `PUSH_FLOOR`, on ONE close in two states.
/// @dev The subject is a DUST loan whose close credits nothing (fee escrow rounds to zero), the recorded residual case.
/// @dev State A: the lender collected, so the close pushes nothing. State B: a stranger's partial repay credited the pair.
/// @dev The close's own work is the same in both, so their least limits differ by the floor, give or take the empty close's epilogue.
contract AcePushGasDemandTest is PushGasProbeRig {
    uint256 internal constant DUST = 9_000; // atoms: at baseBps 1 and tenor == minTenor the fee is 1 and its lender escrow 0
    uint256 internal constant EDGE_SLACK = 2_000; // the empty close's epilogue less the CEI clear: measured 988 under the floor
    bytes32 internal dustMid;

    function _newQuote() internal override returns (address) {
        return address(new MockERC20("USD Coin", "USDC", 6));
    }

    function setUp() public override {
        super.setUp();
        MarketParams memory p = AceFixtures.marketParams(quote, address(coll));
        p.record = address(record);
        p.lender = alice;
        p.minTenor = 7 days;
        p.maxTenor = TEN30;
        p.baseBps = 1;
        p.minDebt = 2;
        dustMid = ace.createMarket(p);
        IRigQuote(quote).mint(alice, DEPOSIT);
        vm.startPrank(alice);
        IRigQuote(quote).approve(address(ace), DEPOSIT);
        ace.deposit(dustMid, DEPOSIT);
        vm.stopPrank();
    }

    /// @notice THE DUST CLOSE PUSHES NOTHING FROM AN EMPTY POOL; FROM A CREDITED ONE IT PAYS, AND DEMANDS EXACTLY THE FLOOR MORE.
    /// @dev Kills a push that demands its floor with nothing owed, and a gate whose level drifts from the published getter either way.
    /// @dev The DIFFERENCE is the witness: an empty pool that demanded the floor would leave the two least limits a floor too close.
    /// @dev Not the empty close's own limit against the floor, which holds only while that close's body is lighter than the floor.
    function test_PushGate_AnEmptyPoolDemandsNothing_AndACreditedOneDemandsThePublishedFloor() public {
        uint256 other = _open(TEN30);
        uint256 dust = _openDust();
        bytes memory data = abi.encodeCall(Ace.settleExpired, (dust));
        uint256 leastA = _leastEmpty(dust, data);
        uint256 leastB = _leastCredited(other, dust, data);

        emit log_named_uint("dust settleExpired, empty pool, lands from   ", leastA);
        emit log_named_uint("dust settleExpired, credited pool, lands from", leastB);
        emit log_named_uint("PUSH_FLOOR                                   ", ace.PUSH_FLOOR());
        uint256 d = leastB - leastA;
        assertGe(d + EDGE_SLACK, ace.PUSH_FLOOR(), "the push demands less than its published floor");
        assertLe(d, ace.PUSH_FLOOR() + EDGE_SLACK, "the push demands more than its published floor");
        assertEq(_probe(keeper, data, leastB - 1, dust).r.out, SHORT, "one under the credited close's least limit is not PushGasShort");
    }

    /// @dev The dust loan, warped past its roll window, with the lender's pool collected to zero.
    function _openDust() internal returns (uint256 dust) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        dust = ace.open(dustMid, COLL, DUST, 7 days, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpTo(uint256(read.loan(dust).expiry) + MarketInit.autoRefinanceWindow(read.loan(dust).tenor) + 1);
        vm.prank(alice);
        ace.collect(quote, alice);
        assertEq(_owed(), 0, "premise: the pool is empty");
    }

    /// @dev State A: the empty pool. The dust close must push nothing, and its least limit is the body's alone.
    function _leastEmpty(uint256 dust, bytes memory data) internal returns (uint256) {
        Seen memory a = _probe(keeper, data, HI, dust);
        assertTrue(a.r.closed, "premise: the dust loan settles");
        assertFalse(a.r.collected && a.r.collectedAmount > 0, "premise: the dust close credits nothing");
        assertEq(a.r.pushCalls, 0, "an empty pool still called the quote: nothing owed must call and demand nothing");
        return _least(keeper, data, dust, LO, HI, P_DONE);
    }

    /// @dev State B: a stranger's partial repay on `other` credits the pair, so the same dust close pushes that credit.
    function _leastCredited(uint256 other, uint256 dust, bytes memory data) internal returns (uint256) {
        uint256 debt = read.loan(other).debt;
        IRigQuote(quote).mint(borrower, debt);
        vm.startPrank(borrower);
        IRigQuote(quote).approve(address(ace), debt);
        ace.repay(other, debt / 2);
        vm.stopPrank();
        uint256 credited = _owed();
        assertGt(credited, 0, "premise: a stranger's partial repay credited the pair");
        Seen memory b = _probe(keeper, data, HI, dust);
        assertTrue(b.r.collected && b.r.collectedAmount == credited, "premise: the same close now pays the stranger's credit");
        return _least(keeper, data, dust, LO, HI, P_DONE);
    }
}

/// @title AcePushGasDeleverageBand
/// @notice `deleverage`'s trailing sweep against a treasury-only BURN: the door the ruled `SWEEP_TAIL` was re-measured on.
/// @dev The forceClose band rows cannot see this door, and after the push-first reorder it is the binding one (23,320 against 23,194).
contract AcePushGasDeleverageBandTest is PushGasProbeRig, DeleverageCrank {
    uint16 internal constant BAND_BPS = 3000;
    MockHostileGasERC20 internal usdc;

    function _newQuote() internal override returns (address) {
        usdc = new MockHostileGasERC20("USD Coin", "USDC", 6);
        return address(usdc);
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

    /// @dev A due sweep, a crank's calldata, and the treasury-only burn armed.
    function _burningCrank() internal returns (uint256 id, bytes memory data) {
        id = _open(0);
        _warpBy(1 days);
        data = _crankData(id);
        assertGt(read.protocolRevenue(mid), 0, "premise: revenue is due");
        usdc.setBurnOnlyTo(treasury);
        usdc.setBurnAll(true);
    }

    /// @notice NO REVERT BAND ACROSS THE SWEEP'S GATE ON A CRANK: at the gate's least admitting limit the burned sweep fails and the crank lands.
    /// @dev Short of `SWEEP_TAIL` the gate would admit a sweep whose own fallback then runs dry, reverting a safety crank.
    function test_Deleverage_NoRevertBandAcrossTheSweepGate_UnderABudgetBurningTreasury() public {
        (uint256 id, bytes memory data) = _burningCrank();
        uint256 banked = read.protocolRevenue(mid);
        uint256 debt = read.debtOf(id);
        uint256 okSwept = _least(address(this), data, id, LO, HI, P_SWEPT);
        uint256 plain = _down(address(this), data, id, okSwept, 5_000, OK);
        uint256 admit = _least(address(this), data, id, plain, okSwept, P_NOT_OK);
        assertEq(admit, okSwept, "the gate admitted a sweep whose own fallback could not then complete: SWEEP_TAIL is short");
        uint256 gStar = _least(address(this), data, id, LO, plain, P_DONE);
        emit log_named_uint("deleverage completes from ", gStar);
        emit log_named_uint("and carries the sweep from", okSwept);

        Seen memory at = _probe(address(this), data, okSwept, id);
        assertTrue(at.r.sweepFailed, "the burned sweep took its fallback");
        assertEq(at.r.revenue, banked, "and restored the counter whole");
        assertEq(at.treasuryGot, 0, "and moved nothing to the treasury");
        assertLt(at.r.debt, debt, "while the crank sold");
        _scanNoBand(id, data, gStar, okSwept);
    }

    /// @dev Every limit 1,000 apart from the sweep's gate plus 5,000 down to the crank's least, and 50 apart across the gate.
    function _scanNoBand(uint256 id, bytes memory data, uint256 gStar, uint256 okSwept) internal {
        for (uint256 x = okSwept + 5_000; x >= gStar; x -= 1_000) {
            assertTrue(_done(_run(address(this), data, x, id)), "a revert band sits between the crank's and the sweep's thresholds");
        }
        for (uint256 x = okSwept - 1_500; x <= okSwept + 1_500; x += 50) {
            assertTrue(_done(_run(address(this), data, x, id)), "a revert band sits at the sweep's gate");
        }
    }

    // A CRANK AT ANY LIMIT FROM ITS LEAST COMPLETES, the burned sweep skipped or taken, and never reverts `PushGasShort`.
    /// forge-config: default.fuzz.runs = 16
    function testFuzz_Deleverage_NeverRevertsAtOrAboveItsLeastLimit(uint256 gSeed) public {
        (uint256 id, bytes memory data) = _burningCrank();
        uint256 least = _least(address(this), data, id, LO, HI, P_DONE);
        assertEq(_run(address(this), data, least, id).out, OK, "the least crank carried the sweep: the piggyback is not best-effort");
        uint256 g = bound(gSeed, least, least + 400_000);
        Run memory r = _run(address(this), data, g, id);
        assertTrue(_done(r), "a crank at or over its least limit reverted: the best-effort sweep is not best-effort");
    }
}

/// @title AcePushGasAnyLimit
/// @notice AT ANY LIMIT A CLOSE EITHER ACCOUNTS FOR ITS PUSH TO THE WEI OR REVERTS HAVING CALLED NOTHING, on every door and three quote shapes.
/// @dev The partition the bisection helpers assume is tested here too: no success under the least limit, no revert over it.
/// @dev A stamp without a sweep event, a cleared pool without a transfer, or a failure naming the wrong amount each break the row.
contract AcePushGasAnyLimitTest is PushGasProbeRig {
    MockHostileGasERC20 internal usdc;

    function _newQuote() internal override returns (address) {
        usdc = new MockHostileGasERC20("USD Coin", "USDC", 6);
        return address(usdc);
    }

    // One door, one quote shape (honest, burning, refusing) and one limit per run, each outcome checked against the money it moved.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_AnyLimit_ACloseAccountsForItsPushOrMovesNothing(uint8 doorSeed, uint8 shapeSeed, uint256 gSeed) public {
        (uint256 id, address who, bytes memory data) = _door(doorSeed % 4);
        uint8 shape = shapeSeed % 3;
        if (shape == 1) usdc.setBurnAll(true);
        if (shape == 2) usdc.setReverting(true);
        uint64 stamp0 = read.marketState(mid).lastSweptAt;
        uint256 rev0 = read.protocolRevenue(mid);
        uint256 least = _least(who, data, id, LO, HI, P_DONE);
        uint256 g = bound(gSeed, least - 50_000, least + 60_000); // the edges: the pre-check, and forceClose's sweep gate ~28k above it
        Seen memory s = _probe(who, data, g, id);

        if (g < least) {
            assertFalse(_done(s.r), "a limit under the least completing one completed: the outcome is not monotone in the limit");
            if (s.r.out == SHORT) assertEq(s.r.pushCalls, 0, "a PushGasShort run had already called the quote");
            return;
        }
        assertTrue(_done(s.r), "a limit at or over the least completing one reverted");
        assertTrue(s.r.closed, "and completed without closing the loan");
        _assertPushAccounted(s);
        _assertSweepAccounted(s, stamp0, rev0);
    }

    function _assertPushAccounted(Seen memory s) internal pure {
        assertTrue(s.r.collected != s.r.pushFailed, "the push neither paid nor announced its fallback, or did both");
        if (s.r.collected) {
            assertEq(s.lenderGot, s.r.collectedAmount, "`Collected` named an amount the lender did not receive");
            assertEq(s.r.owed, 0, "a paid push left credit in the pool");
        } else {
            assertEq(s.lenderGot, 0, "a failed push moved quote to the lender");
            assertEq(s.r.owed, s.failedAmount, "`LenderPushFailed` named an amount the pool does not hold");
            assertGt(s.failedAmount, 0, "and it announced a zero");
        }
    }

    function _assertSweepAccounted(Seen memory s, uint64 stamp0, uint256 rev0) internal pure {
        if (s.r.swept) {
            assertEq(s.treasuryGot, rev0, "a delivered sweep did not move the whole counter");
            assertEq(s.r.revenue, 0, "and left some of it banked");
        } else if (s.r.sweepFailed) {
            assertEq(s.treasuryGot, 0, "a failed sweep moved quote");
            assertEq(s.r.revenue, rev0, "and did not restore the counter whole");
        } else {
            assertEq(s.r.stamp, stamp0, "a sweep that announced nothing stamped a period");
            assertEq(s.r.revenue, rev0, "or moved the counter");
            assertEq(s.treasuryGot, 0, "or paid the treasury");
        }
    }
}

/// @title AcePushGasRailDemand
/// @notice THE DEMAND TRACKS THE PUBLISHED FLOOR ACROSS THE WHOLE RAIL: two hubs' least settling limits differ by their floors' difference.
/// @dev Generalizes the 63,000 / 63,001 rounding pair to any two budgets, and bounds the rail ceiling's close under the EIP-7825 tx cap.
contract AcePushGasRailDemandTest is PushGasDoorRig {
    uint256 internal constant TX_GAS_CAP = 1 << 24; // EIP-7825

    function _newQuote() internal override returns (address) {
        return address(new MockERC20("USD Coin", "USDC", 6));
    }

    /// @dev A fresh hub at `pushGas` with this rig's market, one loan past its roll window, its least settling limit and its floor.
    function _leastSettleAt(uint256 pushGas) internal returns (uint256 g, uint256 floor) {
        uint256 snap = vm.snapshotState();
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
        vm.revertToState(snap);
    }

    function _assertTracks(uint256 pushGas) internal {
        (uint256 gRef, uint256 fRef) = _leastSettleAt(AceFixtures.PUSH_GAS);
        (uint256 g, uint256 f) = _leastSettleAt(pushGas);
        assertEq(int256(g) - int256(gRef), int256(f) - int256(fRef), "the least settling limit does not track the published PUSH_FLOOR");
        assertLt(g, TX_GAS_CAP, "a close at this budget cannot fit a transaction");
    }

    /// @notice AT THE RAIL'S TWO ENDS, pinned by argument: the ends are where a rail or a formula mutation shows first.
    function test_Floor_TheDemandTracksThePublishedFloorAtTheRailEnds() public {
        _assertTracks(PushGasRig.MIN_PUSH_GAS);
        _assertTracks(PushGasRig.MAX_PUSH_GAS);
    }

    // ANY BUDGET IN THE RAIL, sampled.
    /// forge-config: default.fuzz.runs = 12
    function testFuzz_Floor_TheDemandTracksThePublishedFloorAcrossTheRail(uint256 p) public {
        _assertTracks(bound(p, PushGasRig.MIN_PUSH_GAS, PushGasRig.MAX_PUSH_GAS));
    }
}

/// @title AcePushGasFoldWindowPush
/// @notice `AcePushGasFoldWindow.test_A2b`'s scenario, asking the one thing that row does not: did the close actually push the lender?
/// @dev A2b asserts only that the fold settled at the tx cap; a close that pushed nothing would never have charged the lender floor it budgets.
contract AcePushGasFoldWindowPushTest is WarpClock {
    MockERC20 internal usdc;
    MockERC20 internal coll;
    BurnAllRecord internal burnRecord;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5);

    uint256 internal constant TX_GAS_CAP = 1 << 24;
    uint256 internal constant LEND = 400_000 * 32;
    uint256 internal constant PRINCIPAL = 11_000_000;
    uint256 internal constant COLL = 10_000e18;
    uint64 internal constant TEN7 = 7 days;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        burnRecord = new BurnAllRecord(address(usdc), address(coll));
    }

    /// @notice AT THE TX CAP, AT THE FIXTURE BUDGET AND AT THE RAIL'S CEILING, THE BURNING-RECORD FOLD SETTLES AND PAYS THE LENDER.
    function test_A2b_TheFoldAtTheTxCapPushesTheLender() public {
        _assertPushes(PushGasRig.PUSH_GAS);
        _assertPushes(PushGasRig.MAX_PUSH_GAS);
    }

    function _assertPushes(uint256 pushGas) internal {
        uint256 snap = vm.snapshotState();
        MarketParams memory q = AceFixtures.marketParams(address(usdc), address(coll));
        q.record = address(burnRecord);
        AceFixtures.Deployment memory d = PushGasRig.deploy(q, AceFixtures.TREASURY, pushGas);
        usdc.mint(alice, LEND);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), LEND);
        d.ace.deposit(d.id, LEND);
        vm.stopPrank();
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(d.positionManager), COLL);
        uint256 loanId = d.ace.open(d.id, COLL, PRINCIPAL, TEN7, borrower, OpenBounds(0, 0, 0));
        d.ace.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
        _warpTo(d.read.loan(loanId).expiry + 1);
        burnRecord.setBurning(true);
        uint256 had = usdc.balanceOf(alice);
        vm.recordLogs();
        vm.prank(keeper);
        (bool ok,) = address(d.ace).call{gas: TX_GAS_CAP}(abi.encodeCall(Ace.forceClose, (loanId)));
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok && d.read.loan(loanId).closedAt != 0, "premise: the fold settled at the tx cap");
        bool collected;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(d.ace) && logs[i].topics.length > 0 && logs[i].topics[0] == Lender.Collected.selector) collected = true;
        }
        assertTrue(collected, "the fold settled without pushing: A2b never charged the lender floor it budgets");
        assertGt(usdc.balanceOf(alice), had, "and the lender received nothing");
        burnRecord.setBurning(false);
        vm.revertToState(snap);
    }
}
