// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {stdError} from "forge-std/Test.sol";
import {Ace, NoMarket} from "../../src/ace/hub/Ace.sol";
import {BelowCoverageLine, Borrower, GateRefused, NoRecordPrice, OpenExpired, TriggerAboveFloor, ZeroCollateral} from "../../src/ace/hub/Borrower.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {FillBelowMin, FillOverCollateralized, FillOverOrder, FillUnderCollateralized, OrderClosed, RemainderBelowMin} from "../../src/ace/hub/Orders.sol";
import {Cfg, MarketParams, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceOrderFillPredicate
/// @notice `AceLens.tryFillOrder` against `Ace.fillOrder`, one row per refusal, both asked on the SAME state.
/// @notice A predicate that can disagree with its verb is worse than none: a filler simulates green, sends, and reverts.
/// @notice So every row asserts BOTH halves -- the predicate names a fact, and the verb refuses on that same fact.
/// @dev A row asserting only the predicate would pass against a wrapper that agrees with itself and with nothing else.
/// @dev The order-layer legs and the open-path legs are separated because a naive wrapper covers the first and stops.
abstract contract AceFillPredicateBase is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id;

    address internal lender = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);

    uint64 internal constant TEN = ProtocolPolicy.MIN_TENOR; // the fixture ships minTenor == maxTenor
    uint256 internal T0; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal constant LADDER = 5_000_000e6;
    uint256 internal constant P = 1_000e6; // the table's order principal
    uint256 internal constant MINFILL = 250e6; // four fills at most
    uint256 internal LIQ; // the band's low end, where the escrow is sized; assigned in setUp
    uint256 internal LIQ_HIGH; // the band's high end: the worst trigger a fill may hand the maker
    uint256 internal NO_HIGH; // a band high end no fill can reach, so leg 5 never answers first

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public virtual {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T0 = _price(0);
        LIQ = AceFixtures.px(0.5e18, address(usdc), address(vault));
        LIQ_HIGH = AceFixtures.px(0.6e18, address(usdc), address(vault));
        NO_HIGH = AceFixtures.px(1e30, address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));

        vault.mint(maker, 1e36);
        vm.prank(maker);
        vault.approve(address(pm), type(uint256).max);

        _seed();
    }

    /// @dev The market the rows run against; a row exercising another seam overrides this.
    function _params() internal virtual returns (MarketParams memory) {
        return AceFixtures.marketParams(address(usdc), address(vault));
    }

    /// @dev The ladder the rows draw from; a row exercising the walk's own refusals overrides this.
    function _seed() internal virtual {
        _deposit(LADDER);
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(lender, amt);
        vm.startPrank(lender);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    /// @dev The market's config cache, rebuilt from public reads so the coverage oracle needs no hub internals.
    function _cfg() internal view returns (Cfg memory c) {
        c.p = ace.idToMarketParams(id);
        c.unitScale = read.marketState(id).unitScale;
    }

    /// @dev The funding floor the walk WOULD produce for these terms, read off the hub's own preview.
    /// @dev The collateral argument is deliberately enormous: it clears every admission gate so the walk reports.
    function _floorFor(uint256 principal, uint64 tenor) internal view returns (uint256) {
        return ace.previewOpen(id, 1e40, principal, tenor, maker, OpenBounds(0, 0, 0)).postDrawFloor;
    }

    /// @dev The smallest holding a loan of `principal` may open with at `floorPrice`. THE oracle; never re-spelled here.
    function _coverage(uint256 principal, uint256 floorPrice) internal view returns (uint256) {
        return Borrower.coverageLine(_cfg(), principal, floorPrice);
    }

    /// @dev The units a debt needs to trigger at `price`, read off the hub's own rail.
    function _requiredAt(uint256 principal, uint256 price) internal view returns (uint256) {
        return Borrower.requiredAt(_cfg(), principal, price);
    }

    /// @dev The order's own posted collateral-per-quote ratio, floored: the largest take leg 4 admits.
    function _proRata(Order memory o, uint256 principalOut) internal pure returns (uint256) {
        return (o.collateralUnits * principalOut) / o.principal;
    }

    function _far() internal view returns (uint64) {
        return uint64(_now() + 30 days);
    }

    function _post(uint256 principal, uint256 liqLow, uint256 liqHigh, uint256 minFill, uint64 tenor, uint64 expiry) internal returns (uint256) {
        vm.prank(maker);
        return ace.postOrder(id, principal, liqLow, liqHigh, minFill, tenor, expiry);
    }

    function _postDefault() internal returns (uint256) {
        return _post(P, LIQ, LIQ_HIGH, MINFILL, TEN, _far());
    }

    /// @notice THE assertion this file exists for: the predicate names a fact and the verb refuses on that same fact.
    /// @dev The predicate runs first because it is a view; the verb's revert rolls its own state back.
    function _bothRefuse(uint256 orderId, uint256 pOut, uint256 uOut, bytes4 sel, string memory why) internal {
        (bool ok, bytes4 reason) = lens.tryFillOrder(orderId, pOut, uOut);
        assertFalse(ok, why);
        assertTrue(reason != bytes4(0), "a refusal reported an UNSET reason, which names no fact at all");
        assertEq(reason, sel, why);
        vm.prank(filler);
        vm.expectRevert(sel);
        ace.fillOrder(orderId, pOut, uOut);
    }

    /// @notice The other half, and it is not optional: a predicate that refuses everything agrees with nothing.
    function _bothAdmit(uint256 orderId, uint256 pOut, uint256 uOut) internal returns (uint256 loanId) {
        (bool ok, bytes4 reason) = lens.tryFillOrder(orderId, pOut, uOut);
        assertTrue(ok, "the predicate refused a fill the verb takes");
        assertEq(reason, bytes4(0), "an admitted fill carries no reason");
        vm.prank(filler);
        loanId = ace.fillOrder(orderId, pOut, uOut);
        assertGt(loanId, 0, "the admitted fill opened a loan");
    }

    /// @dev The verb reached raw, so its refusal is data the fuzz row can compare rather than a test failure.
    function _tryVerb(uint256 orderId, uint256 pOut, uint256 uOut) internal returns (bool landed, bytes4 sel) {
        vm.prank(filler);
        (bool called, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.fillOrder, (orderId, pOut, uOut)));
        return (called, _selOf(ret));
    }

    function _selOf(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length < 4) return bytes4(0);
        s = bytes4(ret[0]) | (bytes4(ret[1]) >> 8) | (bytes4(ret[2]) >> 16) | (bytes4(ret[3]) >> 24);
    }
}

/* ====== the order layer: the six legs `Orders.fill` asks before it reaches the open ====== */

/// @title AceFillPredicateOrderLegs
/// @notice One row per order-layer refusal, in the order `Orders.fill` asks them.
/// @notice Ahead of all six sits the id itself: an id naming no order must come back as a selector, never a throw.
contract AceFillPredicateOrderLegsTest is AceFillPredicateBase {
    /// @notice An id nothing ever allocated. The hub resolves its market first, so `NoMarket` is the fact.
    function test_tryFillOrder_AnIdNamingNoOrder_IsARefusalNotARevert() public {
        _bothRefuse(999_999, MINFILL, 1, NoMarket.selector, "an unallocated id names no market");
    }

    /// @notice An id naming a LOAN. Ids come from one counter, so this is the collision the fail-closed rule exists for.
    function test_tryFillOrder_AnIdNamingALoan_IsARefusalNotARevert() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 loanId = _bothAdmit(orderId, o.principal, o.collateralUnits);
        assertTrue(loanId != orderId, "guard: the loan took a fresh id, so this row is not the order again");

        _bothRefuse(loanId, MINFILL, 1, NoMarket.selector, "a loan id names no order");
    }

    /// @notice Leg 1: the maker has taken their escrow back.
    function test_tryFillOrder_OnAClosedOrder_NamesOrderClosed() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 take = _proRata(o, MINFILL);

        vm.prank(maker);
        ace.closeOrder(orderId, maker);

        _bothRefuse(orderId, MINFILL, take, OrderClosed.selector, "a retired order is not fillable");
    }

    /// @notice Leg 2a: more principal than the order has left.
    function test_tryFillOrder_PrincipalOverTheOrder_NamesFillOverOrder() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        _bothRefuse(orderId, o.principal + 1, o.collateralUnits, FillOverOrder.selector, "over the resting principal");
    }

    /// @notice Leg 2b: more collateral than the order has left. Same fact, same selector.
    function test_tryFillOrder_UnitsOverTheOrder_NamesFillOverOrder() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        _bothRefuse(orderId, MINFILL, o.collateralUnits + 1, FillOverOrder.selector, "over the resting escrow");
    }

    /// @notice Leg 3: under the maker's own fragmentation floor.
    function test_tryFillOrder_BelowTheMakersFloor_NamesFillBelowMin() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 small = MINFILL / 10;
        assertGe(small, ace.idToMarketParams(id).minDebt, "guard: the fill still clears the market's own dust floor");

        _bothRefuse(orderId, small, _proRata(o, small), FillBelowMin.selector, "under the maker's fill floor");
    }

    /// @notice Leg 4: more collateral per unit of principal than the order's own posted ratio, by one unit.
    function test_tryFillOrder_OverCollateralized_NamesFillOverCollateralized() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 overTake = _proRata(o, MINFILL) + 1;
        assertLe(overTake, o.collateralUnits, "guard: the take is inside the escrow, so leg 2 cannot answer first");

        _bothRefuse(orderId, MINFILL, overTake, FillOverCollateralized.selector, "past the order's own ratio");
    }

    /// @notice Leg 5: the whole principal against the leanest collateral the market alone would admit.
    /// @dev Leg 4 is VACUOUS at a full take, so the band's high end is the only leg that catches this one.
    function test_tryFillOrder_ExhaustingWithMinimumCollateral_NamesFillUnderCollateralized() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 minUnits = _coverage(o.principal, _floorFor(o.principal, o.tenor)) + 1;
        assertLt(minUnits, o.collateralUnits, "guard: the griefer's take is strictly under the posted escrow");

        _bothRefuse(orderId, o.principal, minUnits, FillUnderCollateralized.selector, "a trigger past the band's high end");
    }

    /// @notice Leg 6: a fill that would strand a remainder no legal fill could ever take.
    function test_tryFillOrder_LeavingASubFloorRemainder_NamesRemainderBelowMin() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 pOut = o.principal - (MINFILL / 2);
        assertLt(o.principal - pOut, MINFILL, "guard: the remainder is non-zero and under the maker's floor");

        _bothRefuse(orderId, pOut, _proRata(o, pOut), RemainderBelowMin.selector, "a remainder nothing could take");
    }

    /// @notice The positive row: the predicate admits, and the verb opens the loan it promised.
    function test_tryFillOrder_AFullFill_IsAdmittedAndLands() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        uint256 loanId = _bothAdmit(orderId, o.principal, o.collateralUnits);

        assertEq(ace.orderOf(orderId).principal, 0, "the fill spent the whole order");
        assertEq(read.loan(loanId).borrower, maker, "and titled the loan to the maker, not the filler");
    }

    /// @notice The positive row again, partially: the predicate must admit the shape a filler actually sends.
    function test_tryFillOrder_APartialFill_IsAdmittedAndLands() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        _bothAdmit(orderId, MINFILL, _proRata(o, MINFILL));

        Order memory rest = ace.orderOf(orderId);
        assertEq(rest.principal, P - MINFILL, "the order kept its remainder");
        assertGt(rest.collateralUnits, 0, "and the escrow behind it");
    }

    /// @notice THE INPUT CLASS THIS FILE ONCE PINNED AS NOT TOTAL, now answered on both sides.
    /// @notice Leg 4 compares the two products exactly instead of forming them, so neither side has a word to overflow.
    /// @dev The old row asserted the predicate and the verb PANICKED together, and called a guard unaffordable.
    /// @dev That budget objection was real and is now paid: the exact compare costs the lens tens of bytes, not a branch.
    /// @dev A full fill sits ON the band rather than over it, so the honest answer here was always ADMIT.
    function test_tryFillOrder_AnOrderTooLargeForLegFoursProduct_IsAnsweredRatherThanPanicked() public {
        vault.mint(maker, 1e55);
        uint256 huge = 1e38;
        uint256 orderId = _post(huge, 1e18, NO_HIGH, huge, TEN, _far());
        Order memory o = ace.orderOf(orderId);
        assertGt(o.collateralUnits, type(uint256).max / o.principal, "guard: the leg-4 product really does not fit a word");

        (bool ok, bytes4 reason) = lens.tryFillOrder(orderId, o.principal, o.collateralUnits);
        assertTrue(ok || reason != bytes4(0), "the predicate must ANSWER this domain rather than panic in it");

        (bool landed, bytes4 sel) = _tryVerb(orderId, o.principal, o.collateralUnits);
        assertEq(landed, ok, "the predicate and the verb must still agree on the widest order the escrow admits");
        if (!landed) assertEq(sel, reason, "and when both refuse they must name the same leg");
    }

    /// @notice The whole claim, swept: over any pair inside the order's own bounds the two never disagree.
    /// @dev The bounds run ONE PAST the order on both axes, so leg 2 is inside the swept domain rather than outside it.
    function testFuzz_agreement_ThePredicateAndTheVerbNeverDisagree(uint256 pOut, uint256 uOut) public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        pOut = bound(pOut, 0, o.principal + 1);
        uOut = bound(uOut, 0, o.collateralUnits + 1);

        (bool ok, bytes4 reason) = lens.tryFillOrder(orderId, pOut, uOut);
        (bool landed, bytes4 thrown) = _tryVerb(orderId, pOut, uOut);

        assertEq(landed, ok, "the predicate and the verb disagree on whether this fill lands");
        if (!ok) assertEq(reason, thrown, "both refused, and named different facts");
    }
}

/* ====== the open path: a fill IS an open, so every gate the draw carries is the predicate's too ====== */

/// @title AceFillPredicateOpenLegs
/// @notice The refusals that live PAST the order layer, where a wrapper covering only `Orders.fill` stops and disagrees.
/// @notice Every row here is a fill that is legal against the order and still cannot be opened.
contract AceFillPredicateOpenLegsTest is AceFillPredicateBase {
    /// @notice The order's own expiry rides as the open's deadline, so the refusal lands at the HUB and carries its selector.
    function test_tryFillOrder_AfterTheOrdersExpiry_NamesOpenExpired() public {
        uint64 expiry = uint64(_now() + 1 hours);
        uint256 orderId = _post(P, LIQ, LIQ_HIGH, MINFILL, TEN, expiry);
        Order memory o = ace.orderOf(orderId);
        _warpTo(uint256(expiry) + 1);

        _bothRefuse(orderId, o.principal, o.collateralUnits, OpenExpired.selector, "a fill past the order's expiry");
    }

    /// @notice A take of zero collateral clears every order leg and is refused by the open: an unsecured loan is unfinalizable.
    /// @dev Leg 4 reads `0 > principalOut * collateralUnits`, which is false, and leg 5 reads a zero trigger. Both admit it.
    function test_tryFillOrder_WithNoCollateral_NamesZeroCollateral() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        _bothRefuse(orderId, o.principal, 0, ZeroCollateral.selector, "a fill carrying no collateral");
    }

    /// @notice A band posted ABOVE the ladder's funding floor: the order admits the take and the draw gate does not.
    function test_tryFillOrder_ATriggerAboveTheFundingFloor_NamesTriggerAboveFloor() public {
        uint256 orderId = _post(P, 4e18, 5e18, P, TEN, _far());
        Order memory o = ace.orderOf(orderId);
        assertLt(_floorFor(P, TEN), 4e18, "guard: the whole band sits ABOVE the funding floor, which is what this row needs");

        _bothRefuse(orderId, o.principal, o.collateralUnits, TriggerAboveFloor.selector, "liquidatable at birth");
    }

    /// @notice One unit under the coverage line, with a band high end no fill can reach, so leg 5 cannot answer first.
    /// @dev The line sits `maxClaimTicks` above the trigger requirement, so this take is under the line and over the trigger.
    function test_tryFillOrder_OneUnitUnderTheCoverageLine_NamesBelowCoverageLine() public {
        uint256 orderId = _post(P, LIQ, NO_HIGH, P, TEN, _far());
        Order memory o = ace.orderOf(orderId);
        uint256 units = _coverage(P, _floorFor(P, TEN)) - 1;
        assertLt(units, o.collateralUnits, "guard: the take is inside the escrow, so leg 2 cannot answer first");
        assertGe(units, _requiredAt(P, _floorFor(P, TEN)), "guard: it still clears the trigger, so the line is the leg under test");

        _bothRefuse(orderId, o.principal, units, BelowCoverageLine.selector, "a draw opening under the coverage line");
    }

    /// @notice The boundary above it: exactly the line is admitted, and lands.
    function test_tryFillOrder_AtTheCoverageLineExactly_IsAdmittedAndLands() public {
        uint256 orderId = _post(P, LIQ, NO_HIGH, P, TEN, _far());
        _bothAdmit(orderId, P, _coverage(P, _floorFor(P, TEN)));
    }

    /// @notice THE ROW A NAIVE WRAPPER FAILS: every order leg admits this fill and the market cannot fund it.
    /// @notice The order layer knows nothing about resting cash, so a predicate that stops there answers ok and the send reverts.
    function test_tryFillOrder_ALadderTooThinToFundIt_NamesInsufficientCash() public {
        uint256 big = LADDER + 1_000_000e6;
        uint256 orderId = _post(big, LIQ, NO_HIGH, big, TEN, _far());
        Order memory o = ace.orderOf(orderId);
        assertEq(o.principal, big, "guard: the take is the whole order, so legs 2, 3, 4 and 6 are all vacuous");
        assertGt(o.principal, read.poolResting(id), "guard: and the market's resting cash is strictly short of it");

        _bothRefuse(orderId, o.principal, o.collateralUnits, InsufficientCash.selector, "the market cannot fund this draw");
    }
}

/* ====== the seams a market chooses: the named borrower, the tick cap, and the price record ====== */

/// @title AceFillPredicateBorrowerRefused
/// @notice `post` never checks the market's named borrower and the fill always does, so a resting order can outlive its maker's admission.
/// @dev THE MARKET NAMES THE FILLER, so the maker is refused. The field is write-once, so the admitting
/// @dev twin below is its own contract rather than a second arrangement of one market.
contract AceFillPredicateBorrowerRefusedTest is AceFillPredicateBase {
    function _params() internal override returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.borrower = filler; // the filler IS admitted, which is what makes the refusal the maker's own
    }

    /// @notice The market refuses the MAKER, who holds the title and the debt; the filler's own standing is never asked.
    function test_tryFillOrder_WhenTheMarketRefusesTheMaker_NamesGateRefused() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        _bothRefuse(orderId, o.principal, o.collateralUnits, GateRefused.selector, "the market's named borrower refused the maker");
    }
}

/// @title AceFillPredicateBorrowerAdmitted
/// @notice The contrast that makes the refusal row load-bearing: name the maker and the same fill lands.
contract AceFillPredicateBorrowerAdmittedTest is AceFillPredicateBase {
    function _params() internal override returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.borrower = maker;
    }

    function test_tryFillOrder_WhenTheMarketNamesTheMaker_IsAdmittedAndLands() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        _bothAdmit(orderId, o.principal, o.collateralUnits);
    }
}

/// @title AceFillPredicateTickCap
/// @notice A draw spanning more ticks than the market's claim cap. Cash is sufficient; the SHAPE of the ladder is not.
/// @dev A cap of two against three seeded ticks, which is the smallest arrangement that separates this from a thin ladder.
contract AceFillPredicateTickCapTest is AceFillPredicateBase {
    uint256 internal constant PER_TICK = 50e6;

    function _params() internal override returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
    }

    function _seed() internal override {
        _deposit(PER_TICK);
        _deposit(PER_TICK);
        _deposit(PER_TICK);
    }

    /// @notice A draw the market's cash cannot cover: the predicate and the fill must name the same refusal.
    /// @dev IT ASKED `CapacityExceeded` -- a draw needing a third tick against a cap of two -- and the guard
    /// @dev above deliberately proved the cash WAS there, so the cap was the only thing refusing. Neither the
    /// @dev cap nor the third tick exists now, so the row asks the refusal that survived instead.
    function test_tryFillOrder_ADrawTheMarketCannotFund_NamesInsufficientCash() public {
        uint256 principal = read.restingOf(id) + 1e6;
        uint256 orderId = _post(principal, LIQ, NO_HIGH, principal, TEN, _far());
        Order memory o = ace.orderOf(orderId);
        assertLt(read.restingOf(id), principal, "guard: the market really is short of this draw");

        _bothRefuse(orderId, o.principal, o.collateralUnits, InsufficientCash.selector, "the market cannot fund the draw");
    }

    /// @notice The contrast: a draw that fits inside two ticks is admitted and lands.
    function test_tryFillOrder_ADrawInsideTheClaimCap_IsAdmittedAndLands() public {
        uint256 principal = PER_TICK + 30e6;
        uint256 orderId = _post(principal, LIQ, NO_HIGH, principal, TEN, _far());
        Order memory o = ace.orderOf(orderId);

        _bothAdmit(orderId, o.principal, o.collateralUnits);
    }
}

/// @title AceFillPredicateRecord
/// @notice A record that stops producing a windowed minimum closes the draw door, and the predicate has to say so.
/// @dev The market is born with a live record, because genesis refuses one that cannot price; it goes dark afterwards.
contract AceFillPredicateRecordTest is AceFillPredicateBase {
    MockPersistenceRecord internal record;

    function _params() internal override returns (MarketParams memory p) {
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault))); // above the seeded tick, so the cap admits
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
    }

    /// @notice The record answers zero: judgment-spending verbs fail closed rather than guess, and so does the predicate.
    function test_tryFillOrder_WhenTheRecordCannotPrice_NamesNoRecordPrice() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        record.setMinPrice(0);

        _bothRefuse(orderId, o.principal, o.collateralUnits, NoRecordPrice.selector, "the record cannot produce a windowed minimum");
    }

    /// @notice The contrast: with the record answering, the same fill lands.
    function test_tryFillOrder_WithALiveRecord_IsAdmittedAndLands() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        _bothAdmit(orderId, o.principal, o.collateralUnits);
    }
}
