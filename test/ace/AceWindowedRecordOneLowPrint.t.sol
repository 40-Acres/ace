// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceWindowedRecordOneLowPrint
/// @notice The hub against a REAL windowed record when ONE full-volume bucket prints low: finalize, roll refusal, fold flip.
/// @notice The hub admits any windowed record.
/// @dev The test contract is the record's writer, so each bucket is one `observe` rather than a swap.
/// @dev Shipped truncation cap and windows; no depth feed, so the volume floor is the whole full-cap denominator.
/// @dev Both tokens are 18-decimal and the record opens at par, so P0 is 2^96 and a quote atom values a unit atom.
contract AceWindowedRecordOneLowPrintTest is WarpClock {
    uint256 internal constant P0 = 1 << 96; // par
    uint64 internal constant INTERVAL = 60; // one bucket a minute
    uint256 internal constant VOL_FLOOR = 1e18; // the full-cap denominator, since nothing feeds depth
    uint256 internal constant HONEST = 1e14; // honest flow at par: a ten-thousandth of the full-cap volume per bucket
    uint256 internal constant WASH = 1e18; // the low bucket's volume: exactly the full-cap denominator
    uint256 internal constant WASH_TARGET = (P0 * 80) / 100; // the low bucket's VWAP; the cap clamps the print to 95%
    uint256 internal constant LOW = P0 - (P0 * 500) / 10000; // the clamped print: par less a floored 5% step, so it rounds UP
    uint256 internal constant D = 1e22; // a 10,000-quote loan
    uint256 internal constant U = 14583333333333333333333; // 1.4 * D / 0.96: the trigger sits at 96% of par

    PersistenceRecord internal record;
    MockERC20 internal quote;
    MockERC20 internal unitTok;
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    bytes32 internal mid;

    address internal alice = AceFixtures.LENDER;
    address internal bob = address(0xB0B);
    address internal stranger = address(0xBAD);

    function setUp() public {
        _warpTo(1_800_000_000);
        quote = new MockERC20("Quote", "QUO", 18);
        unitTok = new MockERC20("Unit", "UNIT", 18);
        record = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: PocDeployConfig.TRUNC_BPS,
                initialPrice: P0,
                obsInterval: INTERVAL,
                volRefFloor: VOL_FLOOR,
                obsCap: 300,
                unitScale: 1 << 96,
                volRefBps: 5000,
                depthWindow: PocDeployConfig.PERSISTENCE_WINDOW,
                quote: address(quote),
                collateral: address(unitTok),
                persistenceWindow: PocDeployConfig.PERSISTENCE_WINDOW,
                pendingWindow: PocDeployConfig.PENDING_WINDOW
            })
        );
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(unitTok));
        p.price = (P0 * 99) / 100;
        p.record = address(record);
        p.minCoverageWad = 1.4e18;
        p.baseBps = 40;
        p.minTenor = 7 days;
        p.maxTenor = 7 days;
        p.settleBountyBps = 50;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        quote.mint(alice, 3 * D);
        vm.startPrank(alice);
        quote.approve(address(ace), type(uint256).max);
        ace.deposit(mid, 3 * D);
        vm.stopPrank();
    }

    /// @dev One honest bucket: a fresh interval, then one small print at par.
    function _honestBucket() internal {
        _warpBy(INTERVAL);
        record.observe(P0, HONEST);
    }

    function _warm(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _honestBucket();
        }
    }

    /// @dev The one low bucket: a fresh interval and a full-volume print far under par, clamped by the cap.
    function _lowBucket() internal {
        _warpBy(INTERVAL);
        record.observe(WASH_TARGET, WASH);
    }

    function _minPrice() internal view returns (uint256) {
        return record.minPrice(address(quote), address(unitTok));
    }

    function _open(bool armed) internal returns (uint256 loanId) {
        unitTok.mint(bob, U);
        vm.startPrank(bob);
        unitTok.approve(address(pm), U);
        loanId = ace.open(mid, U, D, 7 days, bob, OpenBounds(0, 0, 0));
        if (armed) ace.setAutoRefinance(loanId, 7 days, 0, 0);
        vm.stopPrank();
    }

    /// @dev Silence for the term, then an honest ring re-warmed across expiry, so the fold reads a live record.
    function _warmAcrossExpiry(uint256 loanId) internal {
        uint256 expiry = read.loan(loanId).expiry;
        _warpTo(expiry - PocDeployConfig.PERSISTENCE_WINDOW - 600);
        _warm((PocDeployConfig.PERSISTENCE_WINDOW + 600) / INTERVAL + 1);
        assertGe(_now(), expiry, "fixture: the ring is warm and the loan has expired");
    }

    /// @notice PREMISE: the low bucket prints exactly the cap's 5% step, and honest flow lifts it barely at all.
    function test_Premise_OneLowBucketPrintsTheFullCapStepAndOutlivesTheSettleWindow() public {
        _warm(40);
        assertEq(_minPrice(), P0, "an honest ring at par answers par");
        _lowBucket();
        assertEq(record.lastObserved(address(quote), address(unitTok)), LOW, "one bucket moves the whole 5% cap");
        _warm((PocDeployConfig.PERSISTENCE_WINDOW + PocDeployConfig.PENDING_WINDOW) / INTERVAL + 2);
        uint256 last = record.lastObserved(address(quote), address(unitTok));
        assertLt(last, (P0 * 9600) / 10000, "a settle window of honest prints at par later the record is still over 4% low");
        assertGt(last, LOW, "while having moved up, so the honest prints are being folded in");
    }

    /// @notice CONTROL: the loan opens healthy at 96% of par, and an honest ring never makes it finalizable.
    function test_Control_AnHonestRingNeverFinalizesTheHealthyLoan() public {
        _warm(40);
        uint256 loanId = _open(false);
        assertApproxEqRel(read.triggerPrice(loanId), (P0 * 96) / 100, 1e12, "fixture: trigger at 96% of par");
        _warm((PocDeployConfig.PERSISTENCE_WINDOW + PocDeployConfig.PENDING_WINDOW) / INTERVAL + 2);
        vm.prank(stranger);
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanId);
    }

    /// @notice ONE LOW BUCKET then a settle window of honest prints at par: a stranger finalizes the healthy loan.
    /// @dev The record's below-ness is real -- every bucket since sits under the trigger -- though every input after one sat at par.
    function test_OneLowBucketMakesAHealthyLoanFinalizable() public {
        _warm(40);
        uint256 loanId = _open(false);
        uint256 trig = read.triggerPrice(loanId);
        _lowBucket();
        vm.prank(stranger);
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanId); // the settle window has not yet elapsed
        _warm((PocDeployConfig.PERSISTENCE_WINDOW + PocDeployConfig.PENDING_WINDOW) / INTERVAL + 2);
        assertTrue(record.persistedBelowSettle(address(quote), address(unitTok), trig), "the record answers settle-distress");
        vm.prank(stranger);
        ace.finalize(loanId);
        assertTrue(ace.isClosed(loanId), "title moved");
        assertGt(read.unitsOwedOf(loanId, stranger), 0, "and the stranger who printed it is credited the sliver");
    }

    /// @notice CONTROL: on an honest ring the armed loan rolls at expiry.
    function test_Control_AnHonestRingRollsTheArmedLoan() public {
        _warm(40);
        uint256 loanId = _open(true);
        _warmAcrossExpiry(loanId);
        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "the fold admits the roll");
        uint256 before = read.loanCount();
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the parent closed");
        assertEq(read.loanCount(), before + 1, "and a successor opened");
    }

    /// @notice ONE LOW BUCKET at expiry refuses the roll on the record leg, while the record calls the successor undistressed.
    function test_OneLowBucketRefusesTheRollTheRecordCallsHealthy() public {
        _warm(40);
        uint256 loanId = _open(true);
        _warmAcrossExpiry(loanId);
        _lowBucket();
        assertEq(_minPrice(), LOW, "the windowed minimum is the one low bucket");
        (bool ok, bytes4 reason,) = ace.tryContinue(loanId);
        assertFalse(ok, "the roll is refused");
        assertEq(reason, TriggerAboveFloor.selector, "on the record leg: the successor's trigger clears min(price, record)");
        uint256 over = (read.triggerPrice(loanId) * 102) / 100; // above the successor's trigger
        assertFalse(record.persistedBelowDistress(address(quote), address(unitTok), over), "while the record calls the successor undistressed");
    }

    /// @notice KNOWN, accepted: one low bucket flips an armed fold to a settlement, with no successor written.
    /// @dev The home roll's record leg is a one-read test; the fix belongs to the record, not the hub.
    function test_Known_OneLowBucketFlipsAnArmedFold() public {
        _warm(40);
        uint256 loanId = _open(true);
        _warmAcrossExpiry(loanId);
        _lowBucket();
        uint256 before = read.loanCount();
        vm.prank(stranger);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the fold ended the loan");
        assertEq(read.loanCount(), before, "and wrote no successor: the one-read record leg settled it");
    }

    /// @notice KNOWN: the refusal OUTLIVES the low bucket's window, because sub-reference honest flow cannot lift the head.
    /// @dev The bucket itself has aged out; what refuses now is the truncated climb back, every step of it under the trigger.
    function test_Known_TheRefusalOutlivesTheLowBucketsWindow() public {
        _warm(40);
        uint256 loanId = _open(true);
        _warmAcrossExpiry(loanId);
        _lowBucket();
        _warm(PocDeployConfig.PERSISTENCE_WINDOW / INTERVAL + 2);
        uint256 last = record.lastObserved(address(quote), address(unitTok));
        assertLt(last, (P0 * 9600) / 10000, "PREMISE: the record's head is still low");
        assertGt(_minPrice(), LOW, "and the windowed minimum is the recovering head, not under it");
        (bool ok, bytes4 reason,) = ace.tryContinue(loanId);
        assertFalse(ok, "the slow climb back still sits under the successor's trigger, so the roll stays refused");
        assertEq(reason, TriggerAboveFloor.selector, "for the same reason");
    }
}
