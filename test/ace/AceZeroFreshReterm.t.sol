// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BufferBelowMin, InsufficientCash, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {LendingAbovePrice} from "../../src/ace/hub/Lender.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceZeroFreshReterm
/// @notice Run 251533 Y-9 leg B: a home re-term that draws NO fresh cash is judged at `min(price, record)`, as the home roll is.
/// @notice A fresh draw keeps the draw cap; a zero-fresh one reads the record for admissibility, so a distressed loan still refuses.
/// @notice Ruling B1's bounded exposure: such a re-term is funded only by the old escrow refund, so the chain it buys decays.
/// @dev Par price, `k = 1.4`, 40 bps per one-day `minTenor`, terms to 28 days; the loan's trigger sits at 0.7 of the price.
contract AceZeroFreshRetermTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint64 internal constant DAY = 1 days;
    uint64 internal constant TEN28 = 28 days;
    uint256 internal constant BASE_BPS = 40;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18; // trigger at 0.7 of the price

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(_px(1.1e18));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = BASE_BPS;
        p.minTenor = DAY;
        p.maxTenor = TEN28;
        p.minCoverageWad = 1.4e18;
        p.minDebt = 5_000e6; // the shipped floor
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    function _px(uint256 human) internal view returns (uint256) {
        return AceFixtures.px(human, address(usdc), address(coll));
    }

    /// @dev A fully lent market and a 28-day loan one hour in, with the record moved under the price to `recordWad`.
    function _bookUnder(uint256 recordWad) internal returns (uint256 loanId) {
        usdc.mint(alice, P);
        vm.startPrank(alice);
        usdc.approve(address(ace), P);
        ace.deposit(id, P);
        vm.stopPrank();
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, TEN28, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(ace.restingOf(id), 0, "PREMISE: fully lent, so nothing fresh can be drawn");
        _warpBy(1 hours);
        rec.setMinPrice(_px(recordWad));
    }

    function _reterm(uint256 loanId, uint256 principal, uint64 tenor, uint256 minBufferWad) internal returns (uint256) {
        vm.prank(borrower);
        return ace.refinance(loanId, principal, tenor, OpenBounds(0, minBufferWad, 0));
    }

    /// @notice A record under the loan's trigger refuses the zero-fresh re-term by the trigger leg: no distressed loan re-terms out.
    function test_ADistressedLoansZeroFreshRetermRefusesTriggerAboveFloor() public {
        uint256 loanId = _bookUnder(0.6e18);
        vm.prank(borrower);
        vm.expectRevert(TriggerAboveFloor.selector);
        ace.refinance(loanId, P, 7 days, OpenBounds(0, 0, 0));
    }

    /// @notice The buffer is measured from the RECORD: at 0.9 the gap to a 0.7 trigger is 22.2%, not the price's 30%.
    function test_ARecordUnderThePriceIsTheFloorTheRetermIsJudgedAt() public {
        uint256 loanId = _bookUnder(0.9e18);
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(BufferBelowMin.selector);
        ace.refinance(loanId, P, 7 days, OpenBounds(0, 0.25e18, 0)); // met at the price, not at the record
        vm.revertToState(snap);
        uint256 newId = _reterm(loanId, P, 7 days, 0.2e18);
        assertEq(read.debtOf(newId), P, "a buffer the record meets lands, drawing nothing fresh");
        assertEq(ace.restingOf(id), 0, "and the market stays fully lent");
    }

    /// @notice A fresh draw keeps the cap: a re-term to a principal past the old debt still refuses at the record under the price.
    function test_AFreshDrawStillMeetsTheDrawCap() public {
        uint256 loanId = _bookUnder(0.9e18);
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 10_000e6);
        vm.stopPrank();
        rec.setMinPrice(_px(1.1e18));
        vm.prank(alice);
        ace.deposit(id, 10_000e6);
        rec.setMinPrice(_px(0.9e18));
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinance(loanId, P + 1_000e6, 7 days, OpenBounds(0, 0, 0));
    }

    /// @notice THE BOUNDARY of leg B: ONE atom of fresh cash is a fresh draw, so it meets the cap; the zero-fresh twin lands.
    /// @dev Cash for the atom rests beside the loan, so the only thing that can refuse it is the cap.
    function test_OneAtomOfFreshCashMeetsTheDrawCap() public {
        uint256 loanId = _bookUnder(0.9e18);
        _depositAtARecordOverThePrice(10_000e6);
        rec.setMinPrice(_px(0.9e18));
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinance(loanId, P + 1, 7 days, OpenBounds(0, 0, 0));
        vm.revertToState(snap);
        uint256 newId = _reterm(loanId, P, 7 days, 0);
        assertEq(read.debtOf(newId), P, "the zero-fresh twin lands under the same record");
        assertEq(ace.restingOf(id), 10_000e6, "and draws nothing of the resting cash");
    }

    /// @notice The cap refuses only a price STRICTLY over it: at a record exactly at the price, a fresh re-term lands.
    function test_AFreshDrawAtARecordExactlyAtThePriceLands() public {
        uint256 loanId = _bookUnder(0.9e18);
        _depositAtARecordOverThePrice(10_000e6);
        rec.setMinPrice(ace.idToMarketParams(id).price);
        uint256 newId = _reterm(loanId, P + 1_000e6, 7 days, 0);
        assertEq(read.debtOf(newId), P + 1_000e6, "a draw at a cap equal to the price is admitted");
    }

    /// @notice A record OVER the price leaves the floor at the price: `min(price, record)`, never the record alone.
    /// @dev The trigger sits at 0.7: a 30% gap at the price, 46% at a 1.3 record, so a 35% buffer separates the two.
    function test_AZeroFreshRetermUnderARecordOverThePriceIsJudgedAtThePrice() public {
        uint256 loanId = _bookUnder(1.3e18);
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(BufferBelowMin.selector);
        ace.refinance(loanId, P, 7 days, OpenBounds(0, 0.35e18, 0));
        vm.revertToState(snap);
        uint256 newId = _reterm(loanId, P, 7 days, 0.25e18);
        assertEq(read.debtOf(newId), P, "a buffer the price meets lands");
    }

    /// @dev Rests `amount` beside the loan: a deposit at a record under the price is refused, so the record is lifted for it.
    function _depositAtARecordOverThePrice(uint256 amount) internal {
        rec.setMinPrice(_px(1.1e18));
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(ace), amount);
        ace.deposit(id, amount);
        vm.stopPrank();
    }

    /// @notice A withdrawal leg on a zero-fresh re-term meets its buffer at the same fold the admission used.
    /// @dev 5,000 units off a 100,000 lot moves the trigger to ~0.737: 18.1% under a 0.9 record, 26.3% under the price.
    function test_AWithdrawLegIsGatedAtTheFoldOfFundingFloorAndRecord() public {
        uint256 loanId = _bookUnder(0.9e18);
        MigrateArgs memory m = MigrateArgs(loanId, id, P, 7 days, OpenBounds(0, 0.2e18, 0), 5_000e18, borrower);
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(BufferBelowMin.selector);
        ace.refinanceTo(m);
        vm.revertToState(snap);
        m.withdrawUnits = 1_000e18; // trigger ~0.707: 21.4% under the record
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(m);
        assertEq(read.loan(newId).collateralUnits, UNITS - 1_000e18, "the leg the record's buffer allows lands");
    }

    /// @notice Leg C's boundary: only a lot WITHIN the deficit is exempt from the price leg; one clearing a floor past it is still a bid.
    function test_ALotPastTheDeficitStillRefusesAtARecordUnderThePrice() public {
        usdc.mint(alice, 4 * P);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 2 * P);
        vm.stopPrank();
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        uint256 loanId = ace.open(id, UNITS, P, 7 days, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, 7 days, 0, 0);
        vm.stopPrank();
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        uint256 deficit = read.rollReserve(id);
        rec.setMinPrice(_px(0.9e18));
        vm.prank(alice);
        vm.expectRevert(LendingAbovePrice.selector);
        ace.deposit(id, deficit + 5_000e6);
        vm.prank(alice);
        ace.deposit(id, deficit);
        assertEq(ace.restingOf(id), deficit, "the refill itself lands");
    }

    /// @notice RULING B1, one step: a zero-fresh re-term that lands buys at most ~5/11 of the remaining exposure, `P * tenor`.
    /// @dev Its fee is funded only by the escrow refund, half the lender's share of the old fee pro rata: `11 P' T' <= 5 P_old rem`.
    /// @dev The slack is ONE fee atom's worth of exposure, `1e5 * minTenor / baseBps`: the fee's ceil and the escrow's floors each move under one.
    /// @dev Each run tries three re-terms in snapshots, the fuzzed pair, `(P, nt)` and `(P, DAY)`, and asserts the bound on every landing.
    /// @dev With 3 days left the refund, ~300, covers `(P, DAY)`'s 220 fee, so such a run must land at least once or the row asserts nothing.
    function testFuzz_AZeroFreshRetermBuysAtMostFiveEleventhsOfTheRemainingExposure(uint256 elapsedSeed, uint256 principalSeed, uint256 tenorSeed) public {
        uint256 loanId = _bookUnder(0.9e18);
        _warpBy(bound(elapsedSeed, 0, TEN28 - 2 hours));
        uint256 np = bound(principalSeed, 5_000e6, P);
        uint64 nt = uint64(bound(tenorSeed, DAY, TEN28));
        uint256 remaining = read.loan(loanId).expiry - _now();
        uint256 landed = _boundIfLands(loanId, np, nt, remaining) + _boundIfLands(loanId, P, nt, remaining) + _boundIfLands(loanId, P, DAY, remaining);
        if (remaining >= 3 days) assertGe(landed, 1, "a re-term the refund covers did not land");
    }

    /// @dev One snapshotted zero-fresh re-term: asserts B1's bound if it lands and returns 1, else returns 0.
    function _boundIfLands(uint256 loanId, uint256 np, uint64 nt, uint256 remaining) internal returns (uint256 landed) {
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        try ace.refinance(loanId, np, nt, OpenBounds(0, 0, 0)) {
            assertLe(11 * np * nt, 5 * P * remaining + 1e5 * DAY / BASE_BPS, "a zero-fresh re-term bought more than its refund can fund");
            landed = 1;
        } catch {}
        vm.revertToStateAndDelete(snap);
    }

    /// @notice RULING B1, the chain: re-terming each successor at once, at the longest term that lands, decays geometrically.
    /// @notice Old remaining plus every successor's exposure stays under `1/(1 - 5/11)`, about 1.83x the first remaining exposure.
    function test_AZeroFreshRetermChainDecaysGeometrically() public {
        uint256 loanId = _bookUnder(0.9e18);
        uint256 e0 = P * (read.loan(loanId).expiry - _now());
        uint256 total = e0;
        uint256 steps;
        while (true) {
            uint64 t = _longestLanding(loanId);
            if (t == 0) break;
            uint256 rem = read.loan(loanId).expiry - _now();
            loanId = _reterm(loanId, P, t, 0);
            assertLe(11 * uint256(t), 5 * rem + 1e5 * DAY / BASE_BPS / P + 1, "a step bought more than 5/11 of what remained");
            total += P * t;
            steps++;
        }
        emit log_named_uint("zero-fresh re-terms in the chain", steps);
        emit log_named_uint("total exposure over the first remaining (x1000)", total * 1000 / e0);
        assertGt(steps, 0, "the first zero-fresh re-term lands under a record below the price");
        assertLe(total * 1000, e0 * 1834, "the chain bought more than 1/(1 - 5/11) of the first remaining exposure");
    }

    /// @dev The longest term a zero-fresh re-term of `loanId` lands at, searched in snapshots; zero when even `minTenor` refuses.
    function _longestLanding(uint256 loanId) internal returns (uint64) {
        if (!_landsAt(loanId, DAY)) return 0;
        uint64 lo = DAY;
        uint64 hi = TEN28 + 1;
        while (hi - lo > 1) {
            uint64 mid = lo + (hi - lo) / 2;
            if (_landsAt(loanId, mid)) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    function _landsAt(uint256 loanId, uint64 tenor) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        try ace.refinance(loanId, P, tenor, OpenBounds(0, 0, 0)) {
            ok = true;
        } catch {}
        vm.revertToStateAndDelete(snap);
    }
}
