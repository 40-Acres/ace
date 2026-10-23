// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace, PushGasShort} from "../../src/ace/hub/Ace.sol";
import {Lender} from "../../src/ace/hub/Lender.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {Loan, MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockHostileGasERC20} from "../mocks/MockHostileGasERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AcePushGasHandler
/// @notice Drives the four terminal closes, the strict uncapped `sweepRevenue` and `deleverage` at a BOUNDED limit, on a quote it can turn hostile.
/// @notice Each bounded action first bisects its own least completing limit in snapshots, then runs once for real near that edge.
/// @dev The latch trips on a pool that moved without its push or its fallback, a stamp without a sweep event, a refusal after the call,
/// @dev or an outcome that is not monotone in the limit. The support verbs share ONE selector so the bounded actions dominate the draw.
contract AcePushGasHandler is WarpClock, DeleverageCrank {
    Ace public immutable ace;
    PositionManager public immutable pm;
    AceReader public immutable read;
    MockHostileGasERC20 public immutable usdc;
    MockERC20 public immutable coll;
    MockPersistenceRecord public immutable record;
    bytes32 public immutable mid;
    address public immutable treasury;

    address public constant LENDER = address(0xA11CE);
    address public constant BORROWER = address(0xB0B);
    address public constant KEEPER = address(0xCAFE);
    uint256 public constant PRINCIPAL = 40_000e6;
    uint256 public constant COLL = 100_000e18;
    uint64 public constant TENOR = 30 days;
    uint16 public constant BAND_BPS = 3000; // the deleverage band the market is created with
    uint256 internal constant FLOOR_G = 1_000; // the bisection's bottom: under every verb's own body
    uint256 internal constant TOP_G = 3_000_000; // its top: a verb refused here is refused for a reason that is not gas
    uint256 internal constant STEP = 256; // the bisection's resolution
    uint256 internal constant UNDER = 15_000; // how far under its least limit a bounded action may be sent
    uint256 internal constant OVER = 200_000; // how far over: past a burned push's budget and the sweep gate behind it

    uint8 internal constant REPAY = 0;
    uint8 internal constant FINALIZE = 1;
    uint8 internal constant FORCE = 2;
    uint8 internal constant SETTLE = 3;

    uint256[] internal _loans;
    uint8 public mode; // 0 honest, 1 every transfer burns, 2 every transfer refuses, 3 only the treasury's transfer burns
    string public violation; // the FIRST latched violation, empty while the run is clean
    uint256 public violations;
    mapping(string => uint256) public tally;

    /// @dev What one real bounded call did, read off its revert data, its logs and the hub's self-calls.
    struct Obs {
        bool ok;
        bytes4 sel;
        uint256 pushCalls;
        bool collected;
        uint256 paid;
        bool pushFailed;
        uint256 kept;
        bool swept;
        uint256 sweptAmt;
        bool sweepFailed;
        uint256 sweepKept;
    }

    /// @dev The ledger and balances a bounded call may move, read on either side of it.
    struct Book {
        uint256 owed;
        uint256 lenderBal;
        uint64 stamp;
        uint256 revenue;
        uint256 treasuryBal;
    }

    /// @dev The bisected edge: `lo` refused, `hi` completed, at most `STEP` apart; `g` is the limit the real call carries.
    struct Edge {
        uint256 lo;
        uint256 hi;
        uint256 g;
    }

    constructor(Ace ace_, PositionManager pm_, AceReader read_, MockHostileGasERC20 usdc_, MockERC20 coll_, MockPersistenceRecord record_, bytes32 mid_) {
        (ace, pm, read, usdc, coll, record, mid) = (ace_, pm_, read_, usdc_, coll_, record_, mid_);
        treasury = AceFixtures.TREASURY;
    }

    /* ---- the support verbs, one selector ---- */

    /// @notice Open, partial repay, lender collect, warp, or re-arm the quote, by `kind`.
    function step(uint256 kind, uint256 a) external {
        uint256 k = kind % 5;
        if (k == 0) {
            _bump("step.open");
            _openLoan(TENOR);
        } else if (k == 1) {
            _bump("step.repayPartial");
            _repayPartial(a);
        } else if (k == 2) {
            _bump("step.collect");
            _collect();
        } else if (k == 3) {
            _bump("step.warp");
            _warpBy(bound(a, 1 hours, 3 days));
        } else {
            _bump("step.hostile");
            mode = uint8(a % 4);
            _apply(mode);
        }
    }

    /* ---- the bounded actions ---- */

    function closeRepay(uint256 loanSeed, uint256 gasSeed) external {
        _door(REPAY, loanSeed, gasSeed);
    }

    function closeFinalize(uint256 loanSeed, uint256 gasSeed) external {
        _door(FINALIZE, loanSeed, gasSeed);
    }

    function closeForce(uint256 loanSeed, uint256 gasSeed) external {
        _door(FORCE, loanSeed, gasSeed);
    }

    function closeSettle(uint256 loanSeed, uint256 gasSeed) external {
        _door(SETTLE, loanSeed, gasSeed);
    }

    /// @notice The strict standalone sweep at a bounded limit: it sweeps, returns early, or reverts; it has no fallback and no gate.
    /// @dev `b0` is read BEFORE the bisection: the uncapped transfer's edge is the token's own cost, and the read warms its slots.
    /// @dev Read between the bisection and the real call, it made the real call cheaper than every probe and tripped the partition.
    function sweepBounded(uint256 gasSeed) external {
        _bump("sweep.calls");
        bytes memory data = abi.encodeCall(Ace.sweepRevenue, (mid));
        Book memory b0 = _book();
        if (!_tryAt(KEEPER, data, TOP_G)) {
            _bump("sweep.refused");
            return;
        }
        Edge memory e = _edge(KEEPER, data, gasSeed);
        Obs memory o = _real(KEEPER, data, e.g);
        Book memory b1 = _book();
        if (!_judgeEdge(o, e, "sweep")) return;
        if (b0.revenue > 0 && !o.swept && !o.sweepFailed) _trip("sweep: the strict sweep succeeded having swept nothing");
        _judgeSweep(o, b0, b1, "sweep");
    }

    /// @notice A fresh loan cranked at a bounded limit: its piggyback sweep is best-effort, so no limit at or over the crank's least may revert.
    function deleverageBounded(uint256 gasSeed) external {
        _bump("lev.calls");
        uint256 id = _openLoan(0);
        if (id == 0) {
            _bump("lev.noSubject");
            return;
        }
        _warpBy(1 days);
        bytes memory data = _crankData(id);
        if (!_tryAt(address(this), data, TOP_G)) {
            _bump("lev.refused");
            _heal();
            return;
        }
        Edge memory e = _edge(address(this), data, gasSeed);
        Book memory b0 = _book();
        Obs memory o = _real(address(this), data, e.g);
        Book memory b1 = _book();
        _heal();
        if (!o.ok && o.sel == PushGasShort.selector) _trip("lev: deleverage reverted PushGasShort: its piggyback sweep is not best-effort");
        if (!_judgeEdge(o, e, "lev")) return;
        _judgeSweep(o, b0, b1, "lev");
    }

    /* ---- the door ---- */

    function _door(uint8 door, uint256 loanSeed, uint256 gasSeed) internal {
        _bump("door.calls");
        _bump(_doorTag(door));
        uint256 id = _subject(loanSeed, door == REPAY || door == FINALIZE);
        if (id == 0) {
            _bump("door.noSubject");
            return;
        }
        (address who, bytes memory data) = _prepare(door, id);
        if (!_tryAt(who, data, TOP_G)) {
            _bump("door.refused");
            record.setBelow(false);
            return;
        }
        Edge memory e = _edge(who, data, gasSeed);
        Book memory b0 = _book();
        Obs memory o = _real(who, data, e.g);
        Book memory b1 = _book();
        record.setBelow(false);
        if (!_judgeEdge(o, e, "door")) return;
        if (read.loan(id).closedAt == 0) _trip("door: a close completed without closing the loan");
        _judgePush(o, b0, b1);
        _judgeSweep(o, b0, b1, "door");
    }

    /// @dev The door's caller and calldata, with its precondition staged: the debt funded, distress proved, or the clock moved.
    function _prepare(uint8 door, uint256 id) internal returns (address who, bytes memory data) {
        Loan memory l = read.loan(id);
        if (door == REPAY) {
            usdc.mint(l.borrower, l.debt);
            vm.prank(l.borrower);
            usdc.approve(address(ace), l.debt);
            return (l.borrower, abi.encodeCall(Ace.repay, (id, l.debt)));
        }
        if (door == FINALIZE) {
            record.setBelow(true);
            return (KEEPER, abi.encodeCall(Ace.finalize, (id)));
        }
        if (door == FORCE) {
            _warpAtLeastTo(uint256(l.expiry) + 1);
            return (KEEPER, abi.encodeCall(Ace.forceClose, (id)));
        }
        _warpAtLeastTo(uint256(l.expiry) + MarketInit.autoRefinanceWindow(l.tenor) + 1);
        return (KEEPER, abi.encodeCall(Ace.settleExpired, (id)));
    }

    function _doorTag(uint8 door) internal pure returns (string memory) {
        if (door == REPAY) return "door.repay";
        if (door == FINALIZE) return "door.finalize";
        if (door == FORCE) return "door.forceClose";
        return "door.settleExpired";
    }

    /* ---- the judges: each latches its first violation ---- */

    /// @dev The partition around the bisected edge, then the refusal's shape. True when the call completed and has more to judge.
    function _judgeEdge(Obs memory o, Edge memory e, string memory verb) internal returns (bool) {
        if (e.g >= e.hi && !o.ok) _trip(string.concat(verb, ": reverted at or over its least completing limit", _at(e)));
        if (e.g < e.lo && o.ok) _trip(string.concat(verb, ": completed under a limit that had refused it", _at(e)));
        if (o.ok) {
            _bump(string.concat(verb, ".landed"));
            return true;
        }
        if (o.sel == PushGasShort.selector) {
            _bump(string.concat(verb, ".short"));
            if (o.pushCalls != 0) _trip(string.concat(verb, ": PushGasShort after the quote had already been called"));
        } else {
            _bump(string.concat(verb, ".dry"));
        }
        return false;
    }

    /// @dev The lender push: paid in full and emptied, kept exactly as named, or never due because the pool was empty throughout.
    function _judgePush(Obs memory o, Book memory b0, Book memory b1) internal {
        if (b1.lenderBal < b0.lenderBal) _trip("push: the lender's balance fell across a close");
        uint256 got = b1.lenderBal - b0.lenderBal;
        if (o.collected && o.pushFailed) _trip("push: one close both paid and announced a fallback");
        if (o.collected) {
            _bump("door.paid");
            if (got != o.paid || b1.owed != 0 || o.paid < b0.owed) _trip("push: Collected without its whole-pool transfer");
        } else if (o.pushFailed) {
            _bump("door.fallback");
            if (got != 0 || b1.owed != o.kept || o.kept == 0) _trip("push: a fallback that does not hold exactly what it named");
        } else {
            _bump("door.nopush");
            if (b0.owed != 0 || b1.owed != 0 || got != 0) _trip("push: a close moved or kept the pool without pushing or announcing a fallback");
        }
    }

    /// @dev The sweep: delivered in full, restored as named, or silent with no stamp and no payment.
    function _judgeSweep(Obs memory o, Book memory b0, Book memory b1, string memory verb) internal {
        if (b1.treasuryBal < b0.treasuryBal) _trip("sweep: the treasury's balance fell");
        uint256 tre = b1.treasuryBal - b0.treasuryBal;
        if (o.swept) {
            _bump(string.concat(verb, ".swept"));
            if (tre != o.sweptAmt || b1.revenue != 0) _trip("sweep: RevenueSwept without its whole-counter transfer");
        } else if (o.sweepFailed) {
            _bump(string.concat(verb, ".sweepFailed"));
            if (tre != 0 || b1.revenue != o.sweepKept) _trip("sweep: a failed sweep that does not hold exactly what it named");
        } else {
            if (b1.stamp != b0.stamp) _trip("sweep: a period was stamped without a revenue event");
            if (tre != 0) _trip("sweep: the treasury was paid without a revenue event");
            if (b0.revenue > 0 && _now() >= uint256(b0.stamp) + 1 days) _bump(string.concat(verb, ".sweepSkipped"));
        }
    }

    /// @dev The edge a partition violation was found at, so a red run names its limits without a replay.
    function _at(Edge memory e) internal pure returns (string memory) {
        return string.concat(" (g ", vm.toString(e.g), ", lo ", vm.toString(e.lo), ", hi ", vm.toString(e.hi), ")");
    }

    function _trip(string memory why) internal {
        violations++;
        if (bytes(violation).length == 0) violation = why;
    }

    function _bump(string memory tag) internal {
        tally[tag]++;
    }

    /* ---- the probes ---- */

    /// @dev One call at `g` from `who`, in a snapshot that is restored and freed, RECORDED exactly as `_real` records.
    /// @dev State-diff recording LOWERS the gas a call needs (measured: a crank landed 14k under its unrecorded least limit).
    /// @dev So a probe that did not record found edges the real call does not have, and the partition check tripped on the rig.
    function _tryAt(address who, bytes memory data, uint256 g) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(who);
        (ok,) = address(ace).call{gas: g}(data);
        vm.stopAndReturnStateDiff();
        vm.revertToStateAndDelete(snap);
    }

    /// @dev The least completing limit to `STEP`, then a limit drawn close around it (even seeds) or from it to `OVER` above it (odd).
    /// @dev The close draw is where a refusal's shape is judged; the wide one reaches the sweep gates a burned push pushes up.
    function _edge(address who, bytes memory data, uint256 gasSeed) internal returns (Edge memory e) {
        e.hi = TOP_G;
        if (_tryAt(who, data, FLOOR_G)) {
            e.hi = FLOOR_G;
        } else {
            e.lo = FLOOR_G;
            while (e.hi - e.lo > STEP) {
                uint256 m = (e.lo + e.hi) / 2;
                if (_tryAt(who, data, m)) e.hi = m;
                else e.lo = m;
            }
        }
        uint256 low = e.hi > FLOOR_G + UNDER ? e.hi - UNDER : FLOOR_G;
        e.g = gasSeed % 2 == 0 ? bound(gasSeed, low, e.hi + UNDER) : bound(gasSeed, e.hi, e.hi + OVER);
    }

    /// @dev The committed call: its revert selector, its self-calls to `pushToken`, and the push and sweep events it emitted.
    function _real(address who, bytes memory data, uint256 g) internal returns (Obs memory o) {
        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.prank(who);
        bytes memory ret;
        (o.ok, ret) = address(ace).call{gas: g}(data);
        o.pushCalls = _pushCalls();
        if (!o.ok && ret.length >= 4) o.sel = bytes4(ret);
        _readLogs(o, vm.getRecordedLogs());
    }

    function _pushCalls() internal returns (uint256 n) {
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i; i < acc.length; i++) {
            if (acc[i].kind != VmSafe.AccountAccessKind.Call || acc[i].account != address(ace) || acc[i].accessor != address(ace)) continue;
            if (acc[i].data.length >= 4 && bytes4(acc[i].data) == Ace.pushToken.selector) n++;
        }
    }

    function _readLogs(Obs memory o, VmSafe.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0) continue;
            bytes32 t = logs[i].topics[0];
            if (t == Lender.Collected.selector) (o.collected, o.paid) = (true, abi.decode(logs[i].data, (uint256)));
            if (t == Lender.LenderPushFailed.selector) (o.pushFailed, o.kept) = (true, abi.decode(logs[i].data, (uint256)));
            if (t == Ace.RevenueSwept.selector) (o.swept, o.sweptAmt) = (true, _firstWord(logs[i].data));
            if (t == Ace.RevenueSweepFailed.selector) (o.sweepFailed, o.sweepKept) = (true, _firstWord(logs[i].data));
        }
    }

    function _firstWord(bytes memory d) internal pure returns (uint256 w) {
        (w,) = abi.decode(d, (uint256, uint64));
    }

    function _book() internal view returns (Book memory b) {
        (,, b.owed) = read.lenderPools(LENDER, address(usdc));
        b.lenderBal = usdc.balanceOf(LENDER);
        b.stamp = read.marketState(mid).lastSweptAt;
        b.revenue = read.protocolRevenue(mid);
        b.treasuryBal = usdc.balanceOf(treasury);
    }

    /* ---- the state builders ---- */

    /// @dev The quote armed to `m`: every hostility cleared first, so no two shapes stack.
    function _apply(uint8 m) internal {
        usdc.setBurnAll(false);
        usdc.setReverting(false);
        usdc.setBurnOnlyTo(address(0));
        if (m == 1) usdc.setBurnAll(true);
        if (m == 2) usdc.setReverting(true);
        if (m == 3) {
            usdc.setBurnOnlyTo(treasury);
            usdc.setBurnAll(true);
        }
    }

    /// @dev An open pays the borrower by `transfer`, so the quote is honest for it and re-armed after. Zero when refused.
    function _openLoan(uint64 tenor) internal returns (uint256 id) {
        _apply(0);
        coll.mint(BORROWER, COLL);
        vm.startPrank(BORROWER);
        coll.approve(address(pm), COLL);
        try ace.open(mid, COLL, PRINCIPAL, tenor, BORROWER, OpenBounds(0, 0, 0)) returns (uint256 n) {
            id = n;
            _loans.push(n);
        } catch {}
        vm.stopPrank();
        _apply(mode);
    }

    /// @dev A stranger's credit to the pair: up to half a live loan's debt, which never pushes.
    function _repayPartial(uint256 a) internal {
        uint256 id = _subject(a, true);
        if (id == 0) return;
        uint256 debt = read.loan(id).debt;
        uint256 amt = bound(a, 1e6, debt / 2);
        usdc.mint(BORROWER, amt);
        vm.startPrank(BORROWER);
        usdc.approve(address(ace), amt);
        try ace.repay(id, amt) {} catch {}
        vm.stopPrank();
    }

    /// @dev The lender empties its pool, honest for the transfer, so the next close's pool starts from what it credits itself.
    function _collect() internal {
        _apply(0);
        vm.prank(LENDER);
        try ace.collect(address(usdc), LENDER) {} catch {}
        _apply(mode);
    }

    /// @dev A live loan from `seed`, unexpired when `fresh`; a new one when none qualifies. Zero when even that is refused.
    function _subject(uint256 seed, bool fresh) internal returns (uint256) {
        uint256 n = _loans.length;
        for (uint256 i; i < n; i++) {
            uint256 id = _loans[(seed + i) % n];
            Loan memory l = read.loan(id);
            if (l.closedAt == 0 && (!fresh || _now() < l.expiry)) return id;
        }
        return _openLoan(TENOR);
    }

    /// @dev The record told the band is broken at the loan's current trigger, and the crank's calldata.
    function _crankData(uint256 id) internal returns (bytes memory) {
        uint256 trig = read.triggerPrice(id);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - uint256(BAND_BPS) * 1e14));
        record.setMinPrice(trig + trig / 20);
        return abi.encodeCall(Ace.deleverage, (id, 0, ""));
    }

    /// @dev The record back to the fixture's answers: flag mode, not below, the default windowed min.
    function _heal() internal {
        record.setBelowBand(0);
        record.setBelow(false);
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
    }

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function loanCount() external view returns (uint256) {
        return _loans.length;
    }
}

/// @title AcePushGasInvariant
/// @notice THE PUSH BUDGET UNDER ARBITRARY SEQUENCES: every bounded close, sweep and crank accounts for what it moved, and the hub stays solvent.
/// @dev A dedicated campaign: its bounded actions bisect in snapshots, which would crowd the main campaign's selector budget.
contract AcePushGasInvariantTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockHostileGasERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;
    AcePushGasHandler internal handler;
    address internal constant LENDER = address(0xA11CE);
    uint256 internal constant DEPOSIT = 50_000_000e6; // cash for well over a campaign's opens: repaid principal returns to the pool, not to cash

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockHostileGasERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = LENDER;
        p.minTenor = 7 days;
        p.maxTenor = 30 days;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deployWith(p, AceFixtures.TREASURY, AceFixtures.PUSH_GAS);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        usdc.mint(LENDER, DEPOSIT);
        vm.startPrank(LENDER);
        usdc.approve(address(ace), DEPOSIT);
        ace.deposit(mid, DEPOSIT);
        vm.stopPrank();
        handler = new AcePushGasHandler(ace, pm, read, usdc, coll, record, mid);
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = AcePushGasHandler.step.selector;
        sel[1] = AcePushGasHandler.closeRepay.selector;
        sel[2] = AcePushGasHandler.closeFinalize.selector;
        sel[3] = AcePushGasHandler.closeForce.selector;
        sel[4] = AcePushGasHandler.closeSettle.selector;
        sel[5] = AcePushGasHandler.sweepBounded.selector;
        sel[6] = AcePushGasHandler.deleverageBounded.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice No bounded action moved the pool, the counter, the stamp or a balance without the event and the transfer that name it.
    function invariant_pushAndSweepAccountForWhatTheyMoved() public view {
        assertEq(handler.violations(), 0, handler.violation());
    }

    /// @notice The hub holds exactly the quote its books assign: resting cash, revenue, borrower credits, fee escrows and the lender's pool.
    /// @dev A cleared counter or pool whose tokens never left breaks this even when no event was checked.
    function invariant_hubHoldsExactlyWhatItsBooksAssign() public view {
        MarketState memory s = read.marketState(mid);
        uint256 booked = s.cash + s.protocolRevenue + s.quoteOwedTotal;
        uint256[] memory ids = ace.marketLoans(mid, 0, ace.marketLoansLength(mid));
        for (uint256 i; i < ids.length; ++i) {
            booked += read.feeEscrowOf(ids[i]);
        }
        (,, uint256 owed) = read.lenderPools(LENDER, address(usdc));
        assertEq(usdc.balanceOf(address(ace)), booked + owed, "the hub holds quote its books do not assign");
    }

    /// @notice THE HANDLER'S OWN WIRING: under every quote shape each bounded action returns rather than reverts, and lands.
    /// @dev A reverted handler call rolls back its own tallies, so an action that reverts would read as never driven.
    function test_Handler_EveryBoundedActionReturnsUnderEveryQuoteShape() public {
        for (uint256 m; m < 4; m++) {
            handler.step(4, m);
            for (uint256 s; s < 3; s++) {
                uint256 gasSeed = uint256(keccak256(abi.encode(m, s)));
                handler.closeRepay(s, gasSeed);
                handler.closeFinalize(s, gasSeed);
                handler.closeForce(s, gasSeed);
                handler.closeSettle(s, gasSeed);
                handler.sweepBounded(gasSeed);
                handler.deleverageBounded(gasSeed);
                handler.step(s, gasSeed);
            }
        }
        assertEq(handler.tally("door.calls"), 48, "a door call did not register");
        assertGt(handler.tally("door.landed"), 0, "no bounded close landed");
        assertGt(handler.tally("lev.landed"), 0, "no bounded crank landed");
        assertEq(handler.violations(), 0, handler.violation());
    }

    /// @notice The per-verb tally, and the anti-vacuity guard: in EVERY run a bounded terminal close was driven and completed.
    /// @dev Four of seven selectors are doors and each lands from its least limit up, so a run with no landing is not a seed's bad luck.
    function afterInvariant() public view {
        string[27] memory tags = [
            "step.open",
            "step.repayPartial",
            "step.collect",
            "step.warp",
            "step.hostile",
            "door.calls",
            "door.repay",
            "door.finalize",
            "door.forceClose",
            "door.settleExpired",
            "door.refused",
            "door.landed",
            "door.short",
            "door.dry",
            "door.paid",
            "door.fallback",
            "door.nopush",
            "door.swept",
            "door.sweepFailed",
            "door.sweepSkipped",
            "sweep.calls",
            "sweep.landed",
            "sweep.short",
            "sweep.swept",
            "lev.calls",
            "lev.landed",
            "lev.sweepSkipped"
        ];
        console2.log("=== AcePushGasHandler verb hits (LAST sequence only) ===");
        for (uint256 i; i < tags.length; i++) {
            console2.log(tags[i], handler.tally(tags[i]));
        }
        console2.log("lev.swept / lev.refused", handler.tally("lev.swept"), handler.tally("lev.refused"));
        console2.log("sweep.sweepFailed / sweep.dry", handler.tally("sweep.sweepFailed"), handler.tally("sweep.dry"));
        assertGt(handler.tally("door.calls"), 0, "VACUOUS: no bounded terminal close was driven in this run");
        assertGt(handler.tally("door.landed"), 0, "VACUOUS: no bounded terminal close completed in this run");
        assertEq(
            handler.tally("door.calls"),
            handler.tally("door.noSubject") + handler.tally("door.refused") + handler.tally("door.landed") + handler.tally("door.short")
                + handler.tally("door.dry"),
            "PARTITION: a bounded close landed in no outcome bucket"
        );
    }
}
