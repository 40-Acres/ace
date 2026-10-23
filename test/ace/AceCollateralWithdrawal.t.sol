// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Cfg, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {BelowWithdrawLine, LoanClosed, LoanMatured, NotBorrower, ZeroCollateral, ZeroWithdrawal} from "../../src/ace/hub/Ace.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceCollateralWithdrawal
/// @notice The singleton twin of the BORROWER EXIT: `withdrawCollateral` releases units above the withdrawal line.
/// @notice The gate is `collateralUnits >= withdrawLine(debt, min(fundingFloor, persistedPrice))`.
/// @notice ONE leg is frozen and one is live: the funding floor is written once at the draw, the cap is re-read.
/// @notice So the composite tracks the record downward but never rises above the floor the draw pinned.
/// @dev `open` enforces the ADMISSIBILITY predicate only, so the withdrawal line sits one atom above it.
/// @dev The asymmetry is deliberate: `minDebt` floors a principal at open and nothing floors debt afterwards.
/// @dev The verb exists because a live loan draws once (`AlreadyFunded`): without it the surplus needs a close-and-reopen.
/// @dev THE RECORD IS REAL, NOT MOCKED: `MockPersistenceRecord.minPriceOverWindow` ignores its window argument.
/// @dev Against that mock every draw-cap assertion is VACUOUS, so this fixture writes real observations.
/// @dev The line is recomputed locally so the fixture is a second opinion on `AceLens.withdrawableUnits`.
/// @dev `test/CollateralWithdrawal.t.sol` at `27a6187` is the spec.
abstract contract AceWithdrawalFixture is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    PersistenceRecord internal record;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id;
    // the ordered pair the record prices; every record read is parameterized by it
    address internal recQ;
    address internal recC;

    address internal alice = address(0xA11CE); // lender
    address internal borrower = address(0xB0B);
    address internal stranger = address(0x57A1);

    uint256 internal P0; // the record anchor every open runs under: this pair's PAR RUNG, assigned in `_deploy`
    uint256 internal constant LADDER = 40_000e6;
    uint256 internal constant DEBT = 4_500e6;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant UNIT_SCALE = 1 << 96; // the hub's fixed frame, which no decimal pair moves
    uint64 internal constant OBS_INTERVAL = 60;
    uint256 internal constant W = PocDeployConfig.PERSISTENCE_WINDOW;
    /// @dev The SETTLE window: what `finalize` reads over, and what the genesis span rail demands.
    uint256 internal constant SETTLE_W = W + PocDeployConfig.PENDING_WINDOW;
    /// @dev The smallest ring the rail admits, DERIVED so it moves with either window.
    uint256 internal constant MIN_OBS_CAP = SETTLE_W / OBS_INTERVAL + 1;

    uint256 internal ladderPrice; // the market this suite creates is priced here; it was the funded rung

    /// @dev `offset` is ticks OVER THIS PAIR'S PAR RUNG, which is also where the record's anchor sits.
    function _deploy(uint256 obsCap, int24 offset, uint256 ladderAmt) internal {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        P0 = AceFixtures.priceAt(address(usdc), address(vault), 0);
        ladderPrice = AceFixtures.priceAt(address(usdc), address(vault), offset);
        record = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 5000,
                initialPrice: P0,
                obsInterval: OBS_INTERVAL,
                volRefFloor: 1,
                obsCap: obsCap,
                unitScale: UNIT_SCALE,
                volRefBps: 5000,
                depthWindow: 1800,
                quote: address(usdc),
                collateral: address(vault),
                persistenceWindow: W,
                pendingWindow: uint64(PocDeployConfig.PENDING_WINDOW)
            })
        );
        (recQ, recC) = (address(usdc), address(vault));

        _spanWindowOn(record, W); // the ring must span W and have printed inside it, or every draw refuses

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.price = ladderPrice; // the rung this suite funded at is the MARKET's price now
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, ladderAmt);
        vm.startPrank(alice);
        usdc.approve(address(ace), ladderAmt);
        ace.deposit(id, ladderAmt);
        vm.stopPrank();
    }

    // ---- helpers ----

    function _open(uint256 coll, uint256 debt) internal returns (uint256 loanId) {
        vault.mint(borrower, coll);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), coll);
        loanId = ace.open(id, coll, debt, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The admissibility line in units at price `p`: CEIL, against the borrower.
    function _requiredAt(uint256 debt, uint256 p) internal pure returns (uint256) {
        if (p == 0) return type(uint256).max;
        return (_claimAt(debt) + p * 1e18 - 1) / (p * 1e18);
    }

    /// @dev The line's NUMERATOR: coverage times debt in the hub's frame, which the price then divides.
    function _claimAt(uint256 debt) internal pure returns (uint256) {
        return PocDeployConfig.MIN_COVERAGE_WAD * debt * UNIT_SCALE;
    }

    /// @dev The live withdrawal price, from the same public sources the hub reads, never lifted from it.
    function _withdrawalPrice(uint256 loanId) internal view returns (uint256) {
        uint256 floor = read.fundingFloor(id, loanId);
        uint256 cap = record.minPriceOverWindow(recQ, recC, W);
        return cap < floor ? cap : floor;
    }

    /// @dev What the loan could shed right now: everything above the live WITHDRAWAL line.
    /// @dev That line sits ONE ATOM above admissibility, because settlement takes its own ceiling.
    /// @dev Admissibility alone would over-report the free units by that atom and the gate would refuse.
    function _freeNow(uint256 loanId) internal view returns (uint256) {
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 required = _requiredAt(read.loan(loanId).debt, _withdrawalPrice(loanId)) + 1;
        return units > required ? units - required : 0;
    }

    function _withdraw(uint256 loanId, uint256 units) internal {
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, units, borrower);
    }

    /// @dev Print `p`, age past the window, then print `p` AGAIN, so the windowed min is exactly `p`.
    /// @dev The 5000bp cap admits one halving per bucket.
    /// @dev The SECOND print is required: a record that has fallen silent refuses the window entirely.
    /// @dev Re-printing the SAME price moves nothing: the truncation target equals its base.
    function _persistPrice(uint256 p) internal {
        _warpBy(OBS_INTERVAL);
        record.observe(p, 1);
        _warpBy(W + 1);
        record.observe(p, 1); // the head the window needs; the print above is the one at its far edge
        require(record.minPriceOverWindow(recQ, recC, W) == p, "fixture: the price did not persist as intended");
    }
}

/// @notice The gate, the boundary and the lifecycle refusals, at the 1.0 tick.
contract AceCollateralWithdrawalTest is AceWithdrawalFixture {
    function setUp() public {
        _deploy(MIN_OBS_CAP, int24(0), LADDER); // the par rung IS the anchor
    }

    /// @notice Fixture control: the loan opens where the test thinks, and the live composite EQUALS the floor.
    /// @dev So the boundary tests measure rounding and the line, not a price gap that happens to be there.
    function test_control_BaseStateHasTheLiveCompositeOnTheFrozenFloor() public {
        uint256 loanId = _open(COLL, DEBT);
        assertEq(read.fundingFloor(id, loanId), P0, "funded at the par rung");
        assertEq(record.minPriceOverWindow(recQ, recC, W), P0, "the venue sits at the anchor");
        assertEq(_withdrawalPrice(loanId), read.fundingFloor(id, loanId), "so the live gate IS the frozen floor");
        assertLt(read.triggerPrice(loanId), P0, "and the loan opens with real surplus");
        assertFalse(read.inDistress(loanId), "and out of distress");
    }

    /// @notice THE BOUNDARY: the last free unit leaves, the next one is refused.
    function test_WithdrawUpToTheLineSucceeds_OneWeiMoreIsRefused() public {
        uint256 loanId = _open(COLL, DEBT);
        uint256 free = _freeNow(loanId);
        assertGt(free, 0, "precondition: there is something to withdraw");

        vm.prank(borrower);
        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(loanId, free + 1, borrower);

        uint256 balBefore = vault.balanceOf(borrower);
        _withdraw(loanId, free);

        assertEq(read.loan(loanId).collateralUnits, COLL - free, "the loan is debited by exactly what left");
        assertEq(positionManager.collateralOf(loanId), COLL - free, "positionManager custody mirrors the loan");
        assertEq(vault.balanceOf(borrower), balBefore + free, "the units reached the BORROWER");
        assertEq(
            read.loan(loanId).collateralUnits,
            _requiredAt(DEBT, _withdrawalPrice(loanId)) + 1,
            "what is left is the required portion plus the settlement rounding slack"
        );
        assertLe(read.triggerPrice(loanId), read.fundingFloor(id, loanId), "and the loan is still admissible");
        assertEq(_freeNow(loanId), 0, "with nothing further to take");
    }

    /// @notice EXIT-SIDE ZERO: three refusals that must stay DISTINGUISHABLE, one selector each.
    /// @dev A bare loan must name itself: without this check the LINE would refuse it, under the wrong name.
    /// @dev A zero-unit REQUEST is a caller mistake touching no state, and carries its own selector.
    function test_WithdrawalRefusals_EachNameItself_StripBare_TriggerGate_ZeroRequest() public {
        uint256 loanId = _open(COLL, DEBT);
        assertGt(read.loan(loanId).debt, 0, "precondition: debt is live");

        vm.startPrank(borrower);
        vm.expectRevert(ZeroCollateral.selector);
        ace.withdrawCollateral(loanId, COLL, borrower); // strips the loan bare

        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(loanId, COLL - 1, borrower); // one wei short: the WITHDRAWAL LINE speaks instead

        vm.expectRevert(ZeroWithdrawal.selector);
        ace.withdrawCollateral(loanId, 0, borrower); // a zero-unit withdrawal is not a no-op, and is NOT ZeroCollateral
        vm.stopPrank();
    }

    /// @notice A distressed loan releases nothing.
    /// @dev Distress is the record persisted BELOW the trigger, so the windowed min is under it and the gate refuses.
    function test_DistressedLoanCannotWithdrawEvenOneWei() public {
        uint256 loanId = _open(COLL, DEBT);
        uint256 trig = read.triggerPrice(loanId);
        assertGt(_withdrawalPrice(loanId), trig, "precondition: the gate would admit before distress");

        _persistPrice((P0 * 6) / 10); // the venue falls to 60% of the anchor, under this loan's own trigger
        assertLt(record.minPriceOverWindow(recQ, recC, W), trig, "precondition: the venue persisted below the trigger");
        assertTrue(read.inDistress(loanId), "precondition: the loan is genuinely in distress");

        vm.prank(borrower);
        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(loanId, 1, borrower);
    }

    /// @notice Lifecycle and access refusals.
    /// @dev `LoanMatured` closes the window at expiry, past which any keeper may fire `forceClose`.
    /// @dev Withdrawing there would race settlement for units that would otherwise cover claims.
    function test_WithdrawalIsRefusedOnceMaturedOrClosed_AndOnlyEverByTheBorrower() public {
        uint256 loanId = _open(COLL, DEBT);
        uint256 take = 1_000e18; // comfortably inside the free portion: only the REFUSAL is under test

        vm.prank(stranger);
        vm.expectRevert(NotBorrower.selector);
        ace.withdrawCollateral(loanId, take, borrower);

        /// @dev the RECEIPT operator is not a drain key: opening in another's name is the only delegated entry
        vm.prank(borrower);
        ace.setCreditOperator(stranger, true);
        vm.prank(stranger);
        vm.expectRevert(NotBorrower.selector);
        ace.withdrawCollateral(loanId, take, borrower);

        _warpTo(read.loan(loanId).expiry);
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.withdrawCollateral(loanId, take, borrower);

        uint256 owed = read.loan(loanId).debt;
        usdc.mint(borrower, owed);
        vm.startPrank(borrower);
        usdc.approve(address(ace), owed);
        ace.repay(loanId, owed);
        vm.expectRevert(LoanClosed.selector);
        ace.withdrawCollateral(loanId, 1, borrower);
        vm.stopPrank();
    }

    /// @notice The gate never admits a position below the live ADMISSIBILITY line, at any size.
    /// @notice A weaker claim than the gate makes: the real line is a tick cap above this one.
    /// @dev The catch leg pins the REFUSAL to the same predicate, so a gate that refuses everything fails too.
    function testFuzz_GateNeverAdmitsBelowTheAdmissibilityLine(uint256 units) public {
        uint256 loanId = _open(COLL, DEBT);
        units = bound(units, 1, COLL);
        uint256 required = _requiredAt(DEBT, _withdrawalPrice(loanId)); // neither leg of it moves on withdrawal

        vm.prank(borrower);
        try ace.withdrawCollateral(loanId, units, borrower) {
            uint256 left = read.loan(loanId).collateralUnits;
            assertGt(left, 0, "an admitted withdrawal never zeroes the position");
            assertGe(left, required, "nor drops it under the line");
        } catch (bytes memory err) {
            uint256 left = COLL - units; // what the post state WOULD have been
            assertTrue(left == 0 || left < required, "the refusal must be forced by the line, not by nothing");
            bytes memory want = left == 0 ? abi.encodeWithSelector(ZeroCollateral.selector) : abi.encodeWithSelector(BelowWithdrawLine.selector);
            assertEq(err, want, "and refused for the reason the post state names");
            assertEq(read.loan(loanId).collateralUnits, COLL, "a refused withdrawal moves no units");
        }
    }
}

/// @notice Rounding direction, at a tick whose price leaves a remainder.
contract AceCollateralWithdrawalRoundingTest is AceWithdrawalFixture {
    function setUp() public {
        _deploy(MIN_OBS_CAP, int24(-60), LADDER); // one rung under par, whose price is not a round number
    }

    /// @notice Fixture control: this tick's price leaves a remainder, so the ceil direction is observable.
    /// @dev At the frame's ONE-TO-ONE tick every division is exact and the rounding test would pass under EITHER rule.
    function test_control_ThisTicksFloorLeavesARemainder() public {
        uint256 loanId = _open(COLL, DEBT);
        uint256 floor = read.fundingFloor(id, loanId);
        assertEq(floor, ladderPrice, "funded at the market price, which sits under par");
        assertLt(floor, P0, "below the anchor, so the draw cap never bound");
        assertTrue(_claimAt(DEBT) % (floor * 1e18) != 0, "the admissibility line divides unevenly");
        assertTrue(_claimAt(DEBT) % (PriceFrame.priceAtStep(0) * 1e18) == 0, "whereas at the frame's one-to-one tick it would have");
    }

    /// @notice The line rounds UP, so the borrower can never withdraw a wei admissibility needed.
    /// @dev Rounding the other way leaves the trigger a wei ABOVE the floor: inadmissible on arrival.
    function test_RequiredRoundsUp_SoTheLastWeiStaysWithTheLender() public {
        uint256 loanId = _open(COLL, DEBT);
        uint256 floor = read.fundingFloor(id, loanId);
        uint256 claim = _claimAt(DEBT);
        uint256 den = floor * 1e18; // the line divides by the price IN THE FRAME, which is what the hub does
        assertTrue(claim % den != 0, "precondition: this principal genuinely leaves a remainder");

        uint256 required = _requiredAt(DEBT, floor);
        assertEq(required, (claim + den - 1) / den, "required is the CEIL of the admissibility line");
        assertGt(required * den, claim, "so the rounded line strictly covers the claim");
        assertLt((required - 1) * den, claim, "and it is the minimum that does");

        /// @dev the hub agrees at the wei: shedding down to the line admits, one more does not
        /// @dev the GATE sits a tick cap above this, since settlement ceils per funded tick and this ceils once
        uint256 line = required + 1; // the coverage line is requiredAt plus ONE atom
        _withdraw(loanId, COLL - line);
        assertEq(read.loan(loanId).collateralUnits, line, "the position rests exactly on the line");
        vm.prank(borrower);
        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(loanId, 1, borrower);
    }
}

/// @notice The LIVE leg: the venue moves while the stored floor and the trigger stand still.
contract AceCollateralWithdrawalVenueTest is AceWithdrawalFixture {
    function setUp() public {
        _deploy(MIN_OBS_CAP, int24(0), LADDER);
    }

    /// @notice Fixture control: a venue fall moves NEITHER the loan's stored floor NOR its trigger.
    /// @dev That is what makes the next test about the live gate rather than about either of those.
    function test_control_VenueFallsWhileTheStoredFloorAndTriggerStandStill() public {
        uint256 loanId = _open(COLL, DEBT);
        uint256 floorBefore = read.fundingFloor(id, loanId);
        uint256 trigBefore = read.triggerPrice(loanId);

        _persistPrice((P0 * 8) / 10); // the venue falls to 80% of the anchor, which is under the stored floor

        assertEq(read.fundingFloor(id, loanId), floorBefore, "the stored floor is frozen at the draw");
        assertEq(read.triggerPrice(loanId), trigBefore, "and the trigger is pure debt arithmetic");
        assertLt(record.minPriceOverWindow(recQ, recC, W), floorBefore, "but the venue now sits under the floor");
    }

    /// @notice A fallen venue SHRINKS what may be withdrawn, where a frozen-floor gate would allow more.
    /// @dev That is the whole reason the composite re-reads both legs.
    function test_FallenVenueShrinksWhatAFrozenFloorGateWouldStillAllow() public {
        uint256 loanId = _open(COLL, DEBT);
        uint256 freeAtFloor = COLL - _requiredAt(DEBT, read.fundingFloor(id, loanId));

        _persistPrice((P0 * 8) / 10); // the venue falls to 80% of the anchor
        uint256 freeAtVenue = _freeNow(loanId);

        assertLt(freeAtVenue, freeAtFloor, "the fallen venue shrank the withdrawable amount");
        assertGt(freeAtVenue, 0, "but has not closed the window entirely");

        vm.prank(borrower);
        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(loanId, freeAtFloor, borrower); // what a frozen-floor gate would have allowed

        _withdraw(loanId, freeAtVenue); // what the LIVE composite allows
        assertEq(read.loan(loanId).collateralUnits, COLL - freeAtVenue, "the live gate is the binding one");
    }

    /// @notice The LENS reads the same live composite: after a venue fall it reports exactly what the hub then releases.
    /// @dev Kills `AceLens.withdrawableUnits` folding to the frozen floor alone: it would report the pre-fall amount, which the hub refuses.
    /// @dev The expectation is the fixture's own `_freeNow`, which reads the record directly and never the lens.
    function test_LensWithdrawable_TracksTheFallenVenue_AndTheHubReleasesExactlyThat() public {
        AceLens lens = new AceLens(address(ace));
        uint256 loanId = _open(COLL, DEBT);
        uint256 freeAtFloor = _freeNow(loanId);
        assertEq(lens.withdrawableUnits(id, loanId), freeAtFloor, "CONTROL: at the anchor the lens reads the fixture's line");

        _persistPrice((P0 * 8) / 10); // the venue falls to 80% of the anchor, under the frozen floor
        uint256 freeAtVenue = _freeNow(loanId);
        assertLt(freeAtVenue, freeAtFloor, "PREMISE: the fall shrank what may leave");
        assertGt(freeAtVenue, 0, "PREMISE: without closing the window");
        uint256 w = lens.withdrawableUnits(id, loanId);
        assertEq(w, freeAtVenue, "the lens prices the line at the fallen venue");

        vm.prank(borrower);
        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(loanId, w + 1, borrower);
        _withdraw(loanId, w);
        assertEq(lens.withdrawableUnits(id, loanId), 0, "and once it is taken, nothing is left");
    }

    /// @notice A loan the venue has pushed UNDER its line reads zero withdrawable: never a revert, never a wrapped number.
    /// @dev Kills `AceLens.withdrawableUnits` subtracting the line plainly, which underflows once the line passes the lot.
    function test_LensWithdrawable_ReadsZeroOnceTheLinePassesTheWholeLot() public {
        AceLens lens = new AceLens(address(ace));
        uint256 loanId = _open(COLL, DEBT);
        _persistPrice((P0 * 6) / 10); // the venue falls to 60% of the anchor
        assertGt(_requiredAt(DEBT, _withdrawalPrice(loanId)), COLL, "PREMISE: at the fallen venue the line sits above the whole lot");
        assertEq(lens.withdrawableUnits(id, loanId), 0, "so the lens reads zero");

        vm.prank(borrower);
        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(loanId, 1, borrower);
    }

    // ---- the destination is the caller's, because the caller IS the payee ----

    /// @notice The units go where the caller said, not to a destination the hub chose for them.
    /// @dev The gate is already `msg.sender == L.borrower`, so a `to` grants the caller nothing new.
    function test_WithdrawCollateral_PaysTheCallerChosenDestination() public {
        uint256 loanId = _open(COLL, DEBT);
        uint256 free = _freeNow(loanId);
        assertGt(free, 0, "precondition: there is something to withdraw");

        vm.prank(borrower);
        ace.withdrawCollateral(loanId, free, stranger);

        assertEq(vault.balanceOf(stranger), free, "the units landed at the named address");
        assertEq(vault.balanceOf(borrower), 0, "and not at the title holder's own");
        assertEq(read.loan(loanId).collateralUnits, COLL - free, "the loan record agrees");
    }

    /// @notice Still borrower-only: naming a destination is not a way past the authorization gate.
    function testRevert_WithdrawCollateral_ToADestinationIsStillBorrowerOnly() public {
        uint256 loanId = _open(COLL, DEBT);
        vm.prank(stranger);
        vm.expectRevert(NotBorrower.selector);
        ace.withdrawCollateral(loanId, 1, stranger);
    }
}

/// @notice Fail-closed against a record proving no price. RECUT 2026-08-13 when the genesis span rail landed.
/// @dev WHAT THIS SUITE USED TO DO: deploy a 2-BUCKET ring with a loan already open.
/// @dev A few observations evicted the anchor, `minPriceOverWindow` fell to 0, and the gate refused.
/// @dev `MarketInit`'s span rail now REFUSES that market outright, so the old `setUp` reverted.
/// @dev The eviction path is not merely harder to reach, it is UNREACHABLE while the rail holds.
/// @dev A ring guaranteed to span W still spans W after any number of maximally-dense writes.
/// @dev So the successor property is the rail's own purpose: activity cannot silence a record.
/// @dev The zero arithmetic is kept beside it, since it is what would still refuse if one ever did.
/// @dev The live causes of a zero read are genesis and a sick ORACLE feed; neither carries a loan.
contract AceCollateralWithdrawalFailClosedTest is AceWithdrawalFixture {
    /// @dev The SMALLEST ring the rail admits: exactly the settle window, no spare reach.
    /// @dev The worst admissible case is the one where "activity cannot silence it" must still hold.
    function setUp() public {
        _deploy(MIN_OBS_CAP, int24(0), LADDER);
    }

    /// @notice THE RAIL'S PURPOSE, pinned end to end on the real record with a live loan.
    /// @dev Writes at the tightest legal spacing are the worst case for reach.
    /// @dev Under the old 2-bucket ring this drove the windowed min to zero within four writes.
    function test_AdmittedRingCannotBeSilencedByDenseWrites() public {
        _open(COLL, DEBT);
        assertGt(record.minPriceOverWindow(recQ, recC, W), 0, "precondition: the record spans at first");
        for (uint256 i; i < 120; i++) {
            _warpBy(OBS_INTERVAL);
            record.observe(P0, 1);
            assertGt(record.minPriceOverWindow(recQ, recC, W), 0, "an admitted ring never falls silent");
        }
    }

    /// @notice Zero is SAFE and must be treated as such wherever it still arises.
    /// @dev `requiredAt` returns the max sentinel, so the gate refuses rather than admitting unpriced.
    function test_AZeroPriceMakesTheAdmissibilityLineUnreachable() public view {
        assertEq(_requiredAt(DEBT, 0), type(uint256).max, "a zero price makes the line unreachable");
    }

    /// @notice No debt is secured by nothing, whatever the price says: DEBT is answered before the sentinel.
    /// @notice Both readers agree there -- the withdrawal gate permits, and `securedBase` sizes an exact no-op.
    /// @dev The REAL function, not the local mirror: `requiredAt` is internal pure over memory, so it needs no market.
    function test_RequiredAt_ZeroDebtNeedsNoUnits_AtEveryPrice() public pure {
        Cfg memory c;
        c.p.minCoverageWad = 1.4e18;
        c.unitScale = UNIT_SCALE;
        assertEq(Borrower.requiredAt(c, 0, 0), 0, "a zero price cannot make a zero debt need units");
        assertEq(Borrower.requiredAt(c, 0, 1e18), 0, "nor can a live one");
        assertEq(Borrower.requiredAt(c, 1, 0), type(uint256).max, "a REAL debt at an unknown price still fails closed");
    }

    /// @notice The withdrawal line SATURATES at the sentinel: an unpriced line refuses by name, never wraps to zero or panics.
    /// @notice Priced, it sits exactly one atom above admissibility, the atom settlement's own ceiling takes.
    function test_CoverageLine_SaturatesAtTheSentinel_AndIsOneAtomAboveAdmissibility() public pure {
        Cfg memory c;
        c.p.minCoverageWad = 1.4e18;
        c.unitScale = UNIT_SCALE;
        assertEq(Borrower.coverageLine(c, DEBT, 0), type(uint256).max, "an unpriced line stays at the sentinel");
        // literals, not `requiredAt + 1`, so a regression in admissibility cannot move both sides; at price one it is 1.4 x debt, ceiled
        assertEq(Borrower.coverageLine(c, DEBT, UNIT_SCALE), 6_300_000_001, "an exact line is its admissibility plus one atom");
        assertEq(Borrower.coverageLine(c, DEBT + 1, UNIT_SCALE), 6_300_000_003, "a remainder ceils first, then takes its atom");
    }
}
