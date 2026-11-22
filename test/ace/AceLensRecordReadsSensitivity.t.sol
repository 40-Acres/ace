// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowWithdrawLine, NoRecordPrice, RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {DeleverageDisabled, DeleverageStopped, Distressed, LoanClosed, NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {NoRecord, NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice A record whose two below-questions answer off two independent levels, so the window a reader asks is observable.
/// @dev `persistedBelowDistress(x)` answers `x > distressBand` and `persistedBelowSettle(x)` answers `x > settleBand`.
/// @dev A below-question asked strictly above `dirtyAbove` answers the word 2, so one read can be made unreadable alone.
contract SplitRecord is IPersistenceRecord {
    address public immutable QUOTE; // the ordered pair genesis binds against
    address public immutable COLLATERAL; // its collateral half
    uint256 public windowMin; // the minimum it answers
    uint256 public distressBand = type(uint256).max; // distress below-ness holds at any level above this
    uint256 public settleBand = type(uint256).max; // settle below-ness holds at any level above this
    uint256 public dirtyAbove = type(uint256).max; // a below-question asked above this answers 2

    constructor(address quote, address collateral) {
        QUOTE = quote;
        COLLATERAL = collateral;
    }

    function setMinPrice(uint256 v) external {
        windowMin = v;
    }

    function setDistressBand(uint256 v) external {
        distressBand = v;
    }

    function setSettleBand(uint256 v) external {
        settleBand = v;
    }

    function setDirtyAbove(uint256 v) external {
        dirtyAbove = v;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256 x) external view returns (bool below) {
        _answer(x, x > distressBand);
    }

    function persistedBelowSettle(address, address, uint256 x) external view returns (bool below) {
        _answer(x, x > settleBand);
    }

    function lastObserved(address, address) external view returns (uint256) {
        return windowMin;
    }

    function minPrice(address, address) external view returns (uint256) {
        return windowMin;
    }

    /// @dev Halts the frame with one word: 2 above `dirtyAbove`, else the bool.
    function _answer(uint256 x, bool below) private view {
        uint256 w = x > dirtyAbove ? 2 : (below ? 1 : 0);
        assembly ("memory-safe") {
            mstore(0, w)
            return(0, 32)
        }
    }
}

/// @title AceLensRecordReadsSensitivityTest
/// @notice Pins what each rewired lens read ASKS: which window, at which level, against which gate, and when it asks nothing.
/// @notice Every eligibility row is anchored to the hub verb asking the same question, never to the lens itself.
/// @notice `requiredAtFloor` is pinned by value against an independent ceil and by its minimality bracket, then against the withdraw door.
contract AceLensRecordReadsSensitivityTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    SplitRecord internal rec;
    MockDeleverageKeeper internal keeper;
    bytes32 internal mid;
    uint256 internal loanId;

    address internal alice = address(0xA11CE); // the fixture's default lender
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant UNIT_SCALE = 1 << 96;
    uint256 internal constant DEBT_FLOOR = 5e6; // half the fixture's 10e6 minPrincipal
    uint256 internal P; // the record's healthy minimum, above the market's par bid; assigned in setUp

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        P = AceFixtures.px(2e18, address(usdc), address(coll));
        rec = new SplitRecord(address(usdc), address(coll));
        rec.setMinPrice(P);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(coll), UNIT_SCALE);

        _deposit(mid, 15_000e6);
        loanId = _open(mid);
    }

    /* ====== requiredAtFloor: a value pinned against arithmetic the lens does not share ====== */

    /// @notice A live loan's value, against a ceil written here in plain integer arithmetic, and against its human scale.
    function test_RequiredAtFloor_LiveLoan_EqualsTheIndependentCeil() public view {
        assertGt(read.claimOf(mid, loanId), 0, "PREMISE: the claim is live, so the loan's floor IS the market's price");
        assertEq(read.marketState(mid).unitScale, UNIT_SCALE, "PREMISE: the market runs the atom frame");
        uint256 debt = read.loan(loanId).debt;
        (uint256 want,) = _ceilRequired(debt, ace.idToMarketParams(mid).price);

        uint256 got = lens.requiredAtFloor(loanId);
        assertEq(got, want, "requiredAtFloor is ceil(k * debt * scale / (floor * 1e18))");
        assertApproxEqRel(got, (14 * debt * 1e12) / 10, 1e13, "and in human terms 1.4x the debt in collateral at a par bid"); // par lands ~2.6ppm high
    }

    /// @notice A debt the ceil really rounds: equality plus the minimality bracket, so a floor or a plus-one both fail.
    function test_RequiredAtFloor_RoundsUp_TheSmallestLotWorthTheCoveredDebt() public {
        _repay(1_234_567_891);
        uint256 debt = read.loan(loanId).debt;
        uint256 price = ace.idToMarketParams(mid).price;
        (uint256 want, uint256 rem) = _ceilRequired(debt, price);
        assertTrue(rem != 0, "fixture: this debt must leave a remainder, or the ceil is unobservable");

        uint256 got = lens.requiredAtFloor(loanId);
        assertEq(got, want, "the ceiled quotient");
        _assertMinimalCover(got, debt, price);
    }

    /// @notice Over any surviving debt the answer is the smallest lot whose value at the floor covers `k` times the debt.
    function testFuzz_RequiredAtFloor_IsTheMinimalCover(uint256 amt) public {
        amt = bound(amt, 1, read.loan(loanId).debt - DEBT_FLOOR);
        _repay(amt);
        uint256 debt = read.loan(loanId).debt;
        uint256 price = ace.idToMarketParams(mid).price;
        (uint256 want,) = _ceilRequired(debt, price);

        uint256 got = lens.requiredAtFloor(loanId);
        assertEq(got, want, "the ceiled quotient");
        _assertMinimalCover(got, debt, price);
    }

    /// @notice Anchored to the real withdraw door: it admits a holding of exactly this plus one atom, and refuses one atom less.
    /// @dev The record's minimum sits above the market's bid, so the door prices at the floor this view reads.
    function test_RequiredAtFloor_IsOneAtomUnderTheWithdrawDoorsLine() public {
        uint256 req = lens.requiredAtFloor(loanId);
        uint256 units = read.loan(loanId).collateralUnits;
        assertGt(units, req + 1, "PREMISE: the loan holds above its line");

        vm.startPrank(borrower);
        ace.withdrawCollateral(loanId, units - req - 1, borrower);
        assertEq(read.loan(loanId).collateralUnits, req + 1, "the door admits a holding of requiredAt plus one atom");
        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(loanId, 1, borrower);
        vm.stopPrank();
    }

    /// @notice An id never opened carries no debt and no market, so it needs no units: zero, never the max sentinel.
    function test_RequiredAtFloor_UnopenedIdReadsZero() public view {
        assertEq(read.loan(loanId + 1000).debt, 0, "PREMISE: nothing was opened there");
        assertEq(lens.requiredAtFloor(loanId + 1000), 0, "no debt needs no units, whatever its floor");
    }

    /* ====== the two windows: settleable asks SETTLE, inDistress asks DISTRESS, each at the trigger ====== */

    /// @notice Distress holds at the trigger and settle does not: the straddle a real ring passes through on the way down.
    function test_Windows_DistressWithoutSettle_InDistressYes_SettleableNo() public {
        uint256 trig = read.triggerPrice(loanId);
        rec.setDistressBand(trig - 1);
        rec.setSettleBand(trig);

        assertTrue(lens.inDistress(loanId), "inDistress asks the distress window, which holds");
        assertFalse(lens.settleable(loanId), "settleable asks the settle window, which does not");
        vm.expectRevert(Distressed.selector);
        keeper.crankDeleverage(loanId);
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanId);
    }

    /// @notice The opposite answer pair, which no ring gives: the only shape that shows each view asks its own window.
    function test_Windows_SettleWithoutDistress_SettleableYes_InDistressNo() public {
        uint256 trig = read.triggerPrice(loanId);
        rec.setDistressBand(trig);
        rec.setSettleBand(trig - 1);

        assertFalse(lens.inDistress(loanId), "inDistress asks the distress window, which does not hold");
        assertTrue(lens.settleable(loanId), "settleable asks the settle window, which holds");
        uint256 snap = vm.snapshotState();
        assertTrue(_crankError(loanId) != Distressed.selector, "the crank's distress guard agrees: no distress");
        vm.revertToState(snap);
        ace.finalize(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "and finalize agrees by settling");
    }

    /* ====== deleverageEligible: the band read at the band level, the stop gate strict ====== */

    /// @notice The band gate opens a wei under the band level and is shut at it, in the view as in the crank.
    /// @dev The settle window never holds here, so a band read asked through it would also read shut.
    function test_DeleverageEligible_BandReadBracketsTheBandLevel_AsTheCrankDoes() public {
        uint256 band = lens.deleverageBandLevel(loanId);
        rec.setMinPrice(band); // above the stop, so only the band gate decides
        assertGt(band, read.triggerPrice(loanId) + 1, "PREMISE: the band sits above the trigger, so distress stays off");

        rec.setDistressBand(band);
        assertFalse(lens.deleverageEligible(loanId), "at the band level the view says shut");
        assertEq(_crankError(loanId), NotInBand.selector, "and the crank refuses NotInBand");

        rec.setDistressBand(band - 1);
        assertTrue(lens.deleverageEligible(loanId), "a wei under it the view says open");
        assertTrue(_crankError(loanId) != NotInBand.selector, "and the crank passes the band gate");
    }

    /// @notice The stop gate is strict: a minimum AT the stop level is ineligible, one wei above it is eligible.
    function test_DeleverageEligible_StopGateIsStrict_AsTheCranksIs() public {
        uint256 stop = lens.deleverageStopLevel(loanId);
        rec.setDistressBand(lens.deleverageBandLevel(loanId) - 1); // in the band, and not distressed

        rec.setMinPrice(stop);
        assertFalse(lens.deleverageEligible(loanId), "at the stop level the view says no");
        assertEq(_crankError(loanId), DeleverageStopped.selector, "and the crank refuses DeleverageStopped");

        rec.setMinPrice(stop + 1);
        assertTrue(lens.deleverageEligible(loanId), "one wei above it the view says yes");
        assertTrue(_crankError(loanId) != DeleverageStopped.selector, "and the stop no longer binds the crank");
    }

    /// @notice A minimum answered as zero is ineligible, where the crank refuses `NoRecordPrice`.
    function test_DeleverageEligible_ZeroMinimumIsIneligible_AsTheCrankRefuses() public {
        rec.setDistressBand(lens.deleverageBandLevel(loanId) - 1);
        rec.setMinPrice(0);
        assertFalse(lens.deleverageEligible(loanId), "a zero minimum reads ineligible, never reverts");
        assertEq(_crankError(loanId), NoRecordPrice.selector, "and the crank refuses NoRecordPrice");
    }

    /// @notice An unreadable answer at the band level ALONE: the crank's band read refuses, and so does the view's.
    /// @dev The distress and settle reads at the trigger stay clean, so the refusal is the band read's own.
    function test_DeleverageEligible_UnreadableBandAnswerAlone_RefusesAsTheCrankDoes() public {
        uint256 trig = read.triggerPrice(loanId);
        rec.setDirtyAbove(trig);

        assertFalse(lens.inDistress(loanId), "PREMISE: the distress read at the trigger answers cleanly");
        assertFalse(lens.settleable(loanId), "PREMISE: so does the settle read");
        assertEq(_crankError(loanId), RecordUnreadable.selector, "the crank's band read refuses the dirty word");
        vm.expectRevert(RecordUnreadable.selector);
        lens.deleverageEligible(loanId);
    }

    /// @notice A live loan on a record with no code: each verb refuses `RecordUnreadable`, and each view that mirrors one says the same.
    /// @notice `isHealthy` alone reads false instead, as no verb asks it.
    function test_Unreadable_CodelessRecordOnALiveLoan_EachViewRefusesAsItsVerbDoes() public {
        assertFalse(lens.settleable(loanId), "PREMISE: with code, the settle read answers");
        vm.etch(address(rec), bytes(""));

        vm.expectRevert(RecordUnreadable.selector);
        ace.finalize(loanId);
        vm.expectRevert(RecordUnreadable.selector);
        lens.settleable(loanId);
        assertEq(_crankError(loanId), RecordUnreadable.selector, "the crank's distress guard refuses a codeless record");
        vm.expectRevert(RecordUnreadable.selector);
        lens.inDistress(loanId);
        vm.expectRevert(RecordUnreadable.selector);
        lens.deleverageEligible(loanId);
        assertFalse(lens.isHealthy(loanId), "the informational predicate reads false rather than reverting");
    }

    /* ====== the arms that ask nothing: no record, and a closed loan ====== */

    /// @notice A record-less market: every risk view answers false and asks nothing, as `finalize` refuses `NoRecord`.
    /// @dev Genesis refuses a band with no record, so the eligibility view's band-off guard is the arm under test there.
    function test_NoRecordMarket_RiskViewsAnswerFalse_AsTheVerbsRefuse() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0);
        bytes32 bare = ace.createMarket(p);
        _deposit(bare, 15_000e6);
        uint256 id = _open(bare);

        assertFalse(lens.settleable(id), "no record: never settleable");
        assertFalse(lens.inDistress(id), "no record: never distressed");
        assertFalse(lens.isHealthy(id), "no record: never provably healthy");
        assertFalse(lens.deleverageEligible(id), "no record means no band: never eligible");
        vm.expectRevert(NoRecord.selector);
        ace.finalize(id);
        assertEq(_crankError(id), DeleverageDisabled.selector, "and the crank refuses on the band");

        (uint256 want,) = _ceilRequired(read.loan(id).debt, p.price);
        assertEq(lens.requiredAtFloor(id), want, "requiredAtFloor reads no record, so it prices a record-less loan too");
    }

    /// @notice A closed loan on a record with no code: the eligibility view answers false without asking, as the crank refuses first.
    function test_DeleverageEligible_ClosedLoanAsksTheRecordNothing() public {
        _repay(read.loan(loanId).debt);
        assertTrue(read.loan(loanId).closedAt != 0, "PREMISE: the repay closed the loan");
        vm.etch(address(rec), bytes(""));

        assertFalse(lens.deleverageEligible(loanId), "a closed loan is never eligible, and the record is never asked");
        assertEq(lens.requiredAtFloor(loanId), 0, "nor does it need units");
        assertEq(_crankError(loanId), LoanClosed.selector, "the crank refuses LoanClosed before any record read");
    }

    /* ================================= fixture ================================= */

    function _deposit(bytes32 id, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(bytes32 id) internal returns (uint256 l) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        l = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _repay(uint256 amt) internal {
        usdc.mint(borrower, amt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), amt);
        ace.repay(loanId, amt);
        vm.stopPrank();
    }

    /// @dev The ceil in plain integer arithmetic, no library: the quotient, and the remainder that says whether it rounded.
    function _ceilRequired(uint256 debt, uint256 price) internal view returns (uint256 req, uint256 rem) {
        uint256 num = ace.idToMarketParams(mid).minCoverageWad * debt * UNIT_SCALE;
        uint256 den = price * 1e18;
        req = num / den;
        rem = num % den;
        if (rem != 0) req += 1;
    }

    /// @dev The defining property, stated without a division: `u` covers `k * debt` at `price`, and `u - 1` does not.
    function _assertMinimalCover(uint256 u, uint256 debt, uint256 price) internal view {
        uint256 need = ace.idToMarketParams(mid).minCoverageWad * debt * UNIT_SCALE;
        assertGe(u * price * 1e18, need, "the lot covers k times the debt at the floor");
        assertLt((u - 1) * price * 1e18, need, "and one unit less does not: no unit is asked for beyond the cover");
    }

    /// @dev The crank's error, or `bytes4(0)` when it did not revert; a selector-less revert fails loudly rather than reading as success.
    function _crankError(uint256 id) internal returns (bytes4) {
        try keeper.crankDeleverage(id) returns (uint256, uint256) {
            return bytes4(0);
        } catch (bytes memory err) {
            require(err.length >= 4, "crank reverted with no selector");
            return bytes4(err);
        }
    }
}
