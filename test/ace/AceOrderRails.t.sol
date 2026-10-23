// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower, BelowMinDebt, OpenExpired, TenorOutOfRange} from "../../src/ace/hub/Borrower.sol";
import {Cfg, MarketParams, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @dev The order-layer refusals, named here rather than imported.
/// @dev A test binds the SELECTOR, which is the name and signature alone, so where they land is free.
error FillUnderCollateralized();
error OrderClosed();
error FillOverOrder();
error FillBelowMin();
error FillOverCollateralized();
error RemainderBelowMin();
error MinFillOutOfRange();
error NotMaker();

/// @title AceOrderRails
/// @notice The refusal rails on credit orders: post, fill and close. One row per leg, each on its OWN selector.
/// @dev An order's collateral is DERIVED at post from the band's LOW end; the escrow shrinks as fills consume it.
/// @dev The band sits below the ladder's funding floor here, so the escrow is deliberately fat.
/// @dev That is what makes a residue large enough to see, and it is the shape a real maker posts.
abstract contract AceOrderFixture is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id;

    address internal lender = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);
    address internal stranger = address(0x57A1);
    address internal rescue = address(0x5A7E); // a `to` that is not the maker; the blacklist escape hatch

    uint64 internal constant TEN = ProtocolPolicy.MIN_TENOR; // the fixture ships minTenor == maxTenor
    uint256 internal constant LADDER = 5_000_000e6;
    uint256 internal constant P = 1_000e6; // order principal
    uint256 internal constant MINFILL = 250e6; // four fills at most
    uint256 internal LIQ; // the band's LOW end, where the escrow is sized; half the par funding floor
    uint256 internal LIQ_HIGH; // the band's HIGH end: the worst trigger a fill may hand the maker
    uint256 internal T; // par for this pair; assigned in setUp, since par is not a compile-time value

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
        T = _price(0);
        LIQ = AceFixtures.px(0.5e18, address(usdc), address(vault));
        LIQ_HIGH = AceFixtures.px(0.6e18, address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        _deposit(LADDER);

        vault.mint(maker, 1e36);
        vm.prank(maker);
        vault.approve(address(pm), type(uint256).max);

        usdc.mint(filler, 1_000_000e6);
        vm.prank(filler);
        usdc.approve(address(ace), type(uint256).max);
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

    function _minDebt() internal view returns (uint256) {
        return ace.idToMarketParams(id).minDebt;
    }

    /// @dev The funding floor the walk WOULD produce for these terms, read off the hub's own preview.
    /// @dev The collateral argument is deliberately enormous: it clears every admission gate so the walk reports.
    function _floorFor(uint256 principal, uint64 tenor) internal view returns (uint256) {
        return ace.previewOpen(id, 1e30, principal, tenor, maker, OpenBounds(0, 0, 0)).postDrawFloor;
    }

    /// @dev The smallest holding a loan of `principal` may open with at `floor`. THE oracle; never re-spelled here.
    function _coverage(uint256 principal, uint256 floor) internal view returns (uint256) {
        return Borrower.coverageLine(_cfg(), principal, floor);
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

    /// @dev The units a debt needs to trigger at `price`, read off the hub's own rail. THE oracle; never re-spelled here.
    function _requiredAt(uint256 principal, uint256 price) internal view returns (uint256) {
        return Borrower.requiredAt(_cfg(), principal, price);
    }

    function _fill(uint256 orderId, uint256 principalOut, uint256 unitsOut) internal returns (uint256) {
        vm.prank(filler);
        return ace.fillOrder(orderId, principalOut, unitsOut);
    }
}

/* ====== STAGE 1: the thin-fill defect, which is what shapes the fill signature ====== */

/// @title AceOrderExhaustion
/// @notice A fill may not hand the maker a trigger worse than the band's high end, however much principal it takes.
/// @notice The market's own coverage line is no defence: it is priced against the FUNDING FLOOR, which sits far above the band.
/// @dev Leg 4 (the over-collateralization bound) is VACUOUS at `principalOut == principal`, so only the high leg catches this.
/// @dev A rational filler takes pro rata; a griefer takes exactly the coverage line and walks, at gas cost only.
contract AceOrderExhaustionTest is AceOrderFixture {
    /// @notice THE DEFECT, reproduced: full principal against the minimum collateral that still clears coverage.
    /// @notice Refused by the band's HIGH end, which is the leg that exists because of exactly this take.
    /// @dev The take is sized off `Borrower.coverageLine` at the walk's own floor, so it tracks the market's parameters.
    /// @dev One unit of slack over the line, because the line is the refusal boundary and a griefer sits just inside it.
    function testRevert_fill_ExhaustingWithMinimumCollateral_IsUnderCollateralized() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        uint256 floor = _floorFor(o.principal, o.tenor);
        uint256 minUnits = _coverage(o.principal, floor) + 1;
        assertLt(minUnits, o.collateralUnits, "guard: the griefer's take is strictly under the posted escrow");

        vm.prank(filler);
        vm.expectRevert(FillUnderCollateralized.selector);
        ace.fillOrder(orderId, o.principal, minUnits);
    }

    /// @notice The gap the high leg spans, stated as the quantity a coverage-line take would have left the maker exposed by.
    /// @dev A whole coverage line's worth of collateral between the band and the floor the market alone would have admitted.
    function test_witness_TheBandSitsFarBelowTheCoverageLine_NotDust() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 floor = _floorFor(o.principal, o.tenor);

        assertGt(floor, LIQ_HIGH, "guard: the whole band sits below the funding floor");
        assertGt(o.collateralUnits - _coverage(o.principal, floor), _coverage(o.principal, floor) / 2, "the gap is not dust");
    }

    /// @notice The legal twin: full principal, full collateral, and the escrow is empty afterwards.
    function test_fill_ExhaustingWithAllCollateral_EmptiesTheEscrow() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        uint256 loanId = _fill(orderId, o.principal, o.collateralUnits);

        assertEq(pm.collateralOf(orderId), 0, "nothing is left behind the exhausted order");
        assertEq(pm.collateralOf(loanId), o.collateralUnits, "and every unit of it reached the loan");
        assertEq(read.loan(loanId).borrower, maker, "the loan is titled to the MAKER, not the filler");
        assertEq(ace.orderOf(orderId).principal, 0, "the record's principal is spent");
        assertEq(ace.orderOf(orderId).collateralUnits, 0, "and its escrow with it, since this take left no residue");
    }

    /// @notice A fill taking the LAST of the principal leaves the order OPEN, holding whatever escrow it did not need.
    /// @notice `closed` is the MAKER's act alone now: no fill sets it, because under a band the last fill may legitimately leave a residue.
    /// @dev Forcing that fill to swallow the residue would push it fatter than the band's low end admits, which is why the old rail went.
    /// @dev The residue is inert rather than stranded: `fill` refuses a spent order, and `closeOrder` is the way back out.
    function test_fill_TakingTheLastPrincipalLeavesTheOrderOpenWithItsResidue() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 lean = _requiredAt(o.principal, LIQ_HIGH);
        assertLt(lean, o.collateralUnits, "guard: the take is inside the band and strictly under the escrow, so a residue is left");
        uint256 makerBefore = vault.balanceOf(maker);

        _fill(orderId, o.principal, lean);

        Order memory after_ = ace.orderOf(orderId);
        assertFalse(after_.closed, "no fill closes an order any more");
        assertEq(after_.principal, 0, "the principal is spent");
        assertEq(after_.collateralUnits, o.collateralUnits - lean, "and the residue rests behind it");
        assertGt(after_.collateralUnits, 0, "guard: there really is a residue to reclaim");

        vm.prank(maker);
        uint256 returned = ace.closeOrder(orderId, maker);

        assertEq(returned, o.collateralUnits - lean, "the maker reclaimed the whole residue");
        assertEq(vault.balanceOf(maker) - makerBefore, returned, "and it landed with them");
        assertEq(pm.collateralOf(orderId), 0, "and the pot no longer holds any of it");
    }

    /// @notice A spent order is INERT without being closed: every principal a fill could name is refused.
    /// @dev This is what makes DELETING the auto-close safe -- nothing can draw against a zero-principal order.
    function testRevert_fill_OnAnOrderWhosePrincipalIsSpent() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        _fill(orderId, o.principal, _requiredAt(o.principal, LIQ_HIGH));
        assertFalse(ace.orderOf(orderId).closed, "guard: the order is open, so these refusals are not OrderClosed in disguise");

        vm.prank(filler);
        vm.expectRevert(FillOverOrder.selector);
        ace.fillOrder(orderId, 1, 1);

        vm.prank(filler);
        vm.expectRevert(FillBelowMin.selector);
        ace.fillOrder(orderId, 0, 0);
    }

    /// @notice A partial fill leaves the order OPEN, so `closed` names the maker's retirement and never merely "was filled".
    function test_fill_APartialFillLeavesTheOrderOpen() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        _fill(orderId, MINFILL, _proRata(o, MINFILL));

        Order memory after_ = ace.orderOf(orderId);
        assertFalse(after_.closed, "a partial fill does not close the order");
        assertEq(after_.principal, P - MINFILL, "the principal remainder shrank by exactly the fill");
    }
}

/* ====== STAGE 2: the custody seam an order shares with a loan ====== */

/// @title AceOrderCustody
/// @notice An order id is a CUSTODY id: it resolves a market, it is never a live loan, and it carries a real pot balance.
/// @notice The regression that matters is the partial fill: `carryIn` reads `isLiveLoan(orderId)` and must see FALSE.
/// @dev Order ids come from the loan counter, so `escrowConfigOf` falls back to the order record when no loan owns the id.
/// @dev Without that fallback the very first `pull` at post would revert, since the custodian resolves the token by id.
contract AceOrderCustodyTest is AceOrderFixture {
    /// @notice The custodian resolves an ORDER id to its market's own token pair.
    function test_escrowConfigOf_AnOrderIdResolvesItsMarketsPair() public {
        uint256 orderId = _postDefault();
        MarketParams memory p = ace.idToMarketParams(id);

        (address collateral, address quote) = ace.escrowConfigOf(orderId);

        assertEq(collateral, p.collateral, "the order's collateral is the market's own");
        assertEq(quote, p.quote, "and so is its quote");
    }

    /// @notice `isLiveLoan` on all four ids: live loan, closed loan, order, and one that was never allocated.
    /// @dev The carry gate rides on this, so an order answering TRUE would make every partial fill revert.
    function test_isLiveLoan_AnswersAllFourCases() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 liveId = _fill(orderId, MINFILL, _proRata(o, MINFILL));

        assertTrue(ace.isLiveLoan(liveId), "a live loan is live");

        vm.prank(filler);
        ace.repay(liveId, type(uint256).max);
        assertFalse(ace.isLiveLoan(liveId), "a closed loan is not");
        assertFalse(ace.isLiveLoan(orderId), "an order never is");
        assertFalse(ace.isLiveLoan(999_999), "and neither is an id that was never allocated");
    }

    /// @notice THE REGRESSION: a PARTIAL fill carries through `carryOut` + `carryIn` with the order still resting.
    /// @dev The original design error made every fill against a still-resting order revert `CarryFromLiveLoan`.
    /// @dev The gate reads the ORDER id, so only a fill leaving the order open exercises it.
    function test_fill_APartialFillCarriesWhileTheOrderIsStillLive() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 take = _proRata(o, MINFILL);

        uint256 loanId = _fill(orderId, MINFILL, take);

        assertFalse(ace.orderOf(orderId).closed, "guard: the order is still resting at the moment of the carry");
        assertGt(ace.orderOf(orderId).collateralUnits, 0, "guard: escrow remains behind it");
        assertEq(pm.collateralOf(loanId), take, "the carry credited the successor loan");
        assertEq(pm.collateralOf(orderId), o.collateralUnits - take, "and debited the order by the same units");
    }

    /// @notice The pot ledger tracks the pot balance across post, partial fill, exhaustion and close.
    /// @dev Asserted after EACH verb rather than once at the end: a compensating pair of errors would net out.
    function test_custody_LedgerTracksThePotAcrossEveryOrderVerb() public {
        uint256 orderA = _postDefault();
        _assertPotBalances("post");

        Order memory a = ace.orderOf(orderA);
        _fill(orderA, MINFILL, _proRata(a, MINFILL));
        _assertPotBalances("partial fill");

        Order memory rest = ace.orderOf(orderA);
        _fill(orderA, rest.principal, rest.collateralUnits);
        _assertPotBalances("exhaustion");

        uint256 orderB = _postDefault();
        vm.prank(maker);
        ace.closeOrder(orderB, maker);
        _assertPotBalances("close");
    }

    function _assertPotBalances(string memory why) internal view {
        assertEq(pm.custodiedOf(address(vault)), vault.balanceOf(address(pm)), string.concat(why, ": ledger equals pot"));
    }
}

/* ====== STAGE 3: the fill rail, one test per leg ====== */

/// @title AceOrderFillRail
/// @notice One test per fill leg, each asserting its OWN selector: a shared refusal tells a filler nothing.
/// @dev The takes here are sized off the ORDER's own posted ratio, never off the derivation that produced it.
contract AceOrderFillRailTest is AceOrderFixture {
    /// @notice Leg 1: an order the maker has taken their escrow back from is not fillable.
    /// @dev The `closed` flag is the refusal, not the zeroed escrow: an arithmetic panic would name no fact.
    function testRevert_fill_OnAClosedOrder() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 take = _proRata(o, MINFILL);

        vm.prank(maker);
        ace.closeOrder(orderId, maker);

        vm.prank(filler);
        vm.expectRevert(OrderClosed.selector);
        ace.fillOrder(orderId, MINFILL, take);
    }

    /// @notice Leg 2a: more principal than the order has left.
    function testRevert_fill_PrincipalOverTheOrder() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        vm.prank(filler);
        vm.expectRevert(FillOverOrder.selector);
        ace.fillOrder(orderId, o.principal + 1, o.collateralUnits);
    }

    /// @notice Leg 2b: more collateral than the order has left. Same fact, same selector.
    function testRevert_fill_UnitsOverTheOrder() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        vm.prank(filler);
        vm.expectRevert(FillOverOrder.selector);
        ace.fillOrder(orderId, MINFILL, o.collateralUnits + 1);
    }

    /// @notice Leg 3: this fill is under the maker's own fragmentation floor.
    /// @dev Everything else about the fill is legal, so this leg is the only thing that can refuse it.
    function testRevert_fill_BelowTheMakersFloor() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 small = MINFILL / 10;
        assertGe(small, _minDebt(), "guard: the fill still clears the market's own dust floor");

        vm.prank(filler);
        vm.expectRevert(FillBelowMin.selector);
        ace.fillOrder(orderId, small, _proRata(o, small));
    }

    /// @notice Leg 3 again, at the maker's all-or-nothing setting: `minFillPrincipal == principal` admits one fill only.
    function testRevert_fill_AllOrNothingOrderRefusesAPartial() public {
        uint256 orderId = _post(P, LIQ, LIQ_HIGH, P, TEN, _far());
        Order memory o = ace.orderOf(orderId);

        vm.prank(filler);
        vm.expectRevert(FillBelowMin.selector);
        ace.fillOrder(orderId, P / 2, _proRata(o, P / 2));
    }

    /// @notice Leg 4: taking more collateral per unit of principal than the order's own posted ratio.
    /// @dev One unit past the pro-rata line, which is where the bound sits by construction.
    function testRevert_fill_OverCollateralized() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 overTake = _proRata(o, MINFILL) + 1;
        assertLe(overTake, o.collateralUnits, "guard: the take is still inside the escrow, so leg 2 cannot fire first");

        vm.prank(filler);
        vm.expectRevert(FillOverCollateralized.selector);
        ace.fillOrder(orderId, MINFILL, overTake);
    }

    /// @notice Leg 5: a fill that would strand a remainder under the maker's floor, leaving the order unfillable.
    /// @dev A different fact from leg 3: this fill is legal in isolation and it is the NEXT one that becomes impossible.
    function testRevert_fill_LeavingASubFloorRemainder() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 pOut = o.principal - (MINFILL / 2);
        assertGt(o.principal - pOut, 0, "guard: the remainder is non-zero, so leg 5b is not the fact under test");
        assertLt(o.principal - pOut, MINFILL, "guard: and it is strictly under the maker's floor");

        vm.prank(filler);
        vm.expectRevert(RemainderBelowMin.selector);
        ace.fillOrder(orderId, pOut, _proRata(o, pOut));
    }

    /// @notice PROPERTY, not a refusal: no legal fill ever leaves a principal remainder under the market's dust floor.
    /// @dev It follows from the post rail plus leg 5, which is why it needs no leg of its own.
    function testFuzz_property_NoLegalFillLeavesARemainderUnderMinDebt(uint256 seed) public {
        uint256 orderId = _postDefault();
        uint256 floorDebt = _minDebt();

        for (uint256 k; k < 4; k++) {
            Order memory o = ace.orderOf(orderId);
            if (o.principal == 0) break;
            uint256 pOut = _legalPrincipalOut(o, seed, k);
            _fill(orderId, pOut, pOut == o.principal ? o.collateralUnits : _proRata(o, pOut));

            Order memory rest = ace.orderOf(orderId);
            assertTrue(rest.principal == 0 || rest.principal >= floorDebt, "a remainder is zero or above minDebt");
            assertTrue(rest.principal == 0 || rest.principal >= rest.minFillPrincipal, "and never under the maker's own floor");
        }
    }

    /// @notice PROPERTY: a legal fill leaving principal behind never leaves the escrow empty behind it.
    /// @notice ONE DIRECTION ONLY, and this harness DEMONSTRATES the other is gone rather than asserting it away.
    /// @notice Its last leg takes the whole principal LEAN, at the band's high end, which strands a residue on purpose.
    /// @dev The surviving half is what keeps a live remainder fundable; an empty escrow would make it dead but not closed.
    /// @dev It follows from the low leg: the pro-rata bound forces `unitsOut < collateralUnits` whenever principal is left behind.
    /// @dev The lean exhausting leg is a shape the deleted `ExhaustMustTakeAll` rail forbade, so no test could express it before the band.
    function testFuzz_property_NoLegalPartialFillEmptiesTheEscrow(uint256 seed) public {
        uint256 orderId = _postDefault();
        uint256 makerBefore = vault.balanceOf(maker);
        bool leanExhaustingLeg;

        for (uint256 k; k < 4; k++) {
            Order memory o = ace.orderOf(orderId);
            if (o.principal == 0) break;
            uint256 pOut = _legalPrincipalOut(o, seed, k);
            uint256 uOut = _proRata(o, pOut);
            if (pOut == o.principal) {
                uOut = _requiredAt(o.principal, LIQ_HIGH); // the leanest take the band admits, so the residue is maximal
                assertLt(uOut, o.collateralUnits, "guard: the exhausting leg really is lean, so a residue survives it");
                leanExhaustingLeg = true;
            }
            _fill(orderId, pOut, uOut);

            Order memory rest = ace.orderOf(orderId);
            assertTrue(rest.principal == 0 || rest.collateralUnits > 0, "a live remainder always keeps escrow behind it");
            assertEq(rest.collateralUnits, pm.collateralOf(orderId), "and the record agrees with the pot");
        }

        assertTrue(leanExhaustingLeg, "guard: the sequence reached the lean exhausting leg this harness exists to exercise");
        Order memory end = ace.orderOf(orderId);
        assertEq(end.principal, 0, "the sequence spent the principal");
        assertGt(end.collateralUnits, 0, "and left a residue behind it, which the deleted biconditional called impossible");

        vm.prank(maker);
        uint256 returned = ace.closeOrder(orderId, maker);
        assertEq(returned, end.collateralUnits, "the residue is reclaimable in one call");
        assertEq(vault.balanceOf(maker) - makerBefore, returned, "and it lands with the maker");
    }

    /// @notice PROPERTY: a fill after the order's expiry refuses at the HUB, through `bnd.deadline`, not at the order layer.
    /// @dev The selector is the assertion. Two refusals for one fact would drift apart the moment either moves.
    function test_property_AFillAfterExpiryRefusesWithOpenExpired() public {
        uint64 expiry = uint64(_now() + 1 hours);
        uint256 orderId = _post(P, LIQ, LIQ_HIGH, MINFILL, TEN, expiry);
        Order memory o = ace.orderOf(orderId);
        _warpTo(uint256(expiry) + 1);

        vm.prank(filler);
        vm.expectRevert(OpenExpired.selector);
        ace.fillOrder(orderId, o.principal, o.collateralUnits);
    }

    /// @dev A principal draw inside the legal band: at least the maker's floor, and never stranding a sub-floor remainder.
    function _legalPrincipalOut(Order memory o, uint256 seed, uint256 k) internal pure returns (uint256) {
        uint256 pOut = o.minFillPrincipal + (uint256(keccak256(abi.encode(seed, k))) % (o.principal - o.minFillPrincipal + 1));
        return (o.principal - pOut < o.minFillPrincipal) ? o.principal : pOut;
    }
}

/* ====== STAGE 4: the post rail and the close rail ====== */

/// @title AceOrderPostRail
/// @notice What a maker may rest. The point of every leg is that an order which can never fill must never post.
/// @notice One row here asserts a WRITE and not a refusal: the zero sentinel resolves in calldata and never reaches storage.
/// @dev The expiry is deliberately unbounded in both directions; a TTL floor or ceiling would be a new rule, not a rail.
contract AceOrderPostRailTest is AceOrderFixture {
    /// @notice A fragmentation floor above the principal advertises a fill the order can never take.
    /// @dev Refused at post: no fill could ever reach a floor above the principal.
    function testRevert_post_MinFillAboveThePrincipal() public {
        vm.prank(maker);
        vm.expectRevert(MinFillOutOfRange.selector);
        ace.postOrder(id, P, LIQ, LIQ_HIGH, P + 1, TEN, _far());
    }

    /// @notice A fragmentation floor under the market's dust floor advertises a fill the hub then refuses with BelowMinDebt.
    function testRevert_post_MinFillBelowMinDebt() public {
        uint256 tooSmall = _minDebt() - 1;

        vm.prank(maker);
        vm.expectRevert(MinFillOutOfRange.selector);
        ace.postOrder(id, P, LIQ, LIQ_HIGH, tooSmall, TEN, _far());
    }

    /// @notice Both ends of the band are legal, which is what makes the two refusals above a band and not a floor.
    function test_post_BothEndsOfTheMinFillBandAreLegal() public {
        uint256 atMinDebt = _post(P, LIQ, LIQ_HIGH, _minDebt(), TEN, _far());
        uint256 atPrincipal = _post(P, LIQ, LIQ_HIGH, P, TEN, _far());

        assertEq(ace.orderOf(atMinDebt).minFillPrincipal, _minDebt(), "the lower end rests as posted");
        assertEq(ace.orderOf(atPrincipal).minFillPrincipal, P, "and so does all-or-nothing");
    }

    /// @notice A principal under the market's dust floor can never open, so it must never rest either.
    /// @dev The open path's own selector, raised early: a maker learns at post rather than at a fill that never comes.
    function testRevert_post_PrincipalBelowMinDebt() public {
        uint256 tooSmall = _minDebt() - 1;

        vm.prank(maker);
        vm.expectRevert(BelowMinDebt.selector);
        ace.postOrder(id, tooSmall, LIQ, LIQ_HIGH, tooSmall, TEN, _far());
    }

    /// @notice A tenor above the market's ceiling can never open, so it must never rest.
    function testRevert_post_TenorAboveTheCeiling() public {
        vm.prank(maker);
        vm.expectRevert(TenorOutOfRange.selector);
        ace.postOrder(id, P, LIQ, LIQ_HIGH, MINFILL, TEN + 1, _far());
    }

    /// @notice And a tenor below the market's floor, which on this fixture is the same grid step.
    function testRevert_post_TenorBelowTheFloor() public {
        vm.prank(maker);
        vm.expectRevert(TenorOutOfRange.selector);
        ace.postOrder(id, P, LIQ, LIQ_HIGH, MINFILL, TEN - 1, _far());
    }

    /// @notice THE SENTINEL, and it is a WRITE: `minFillPrincipal == 0` resolves to `minDebt` and the RESOLVED value stores.
    /// @dev The shape `open` already uses for `tenor == 0`, so no read site ever branches on a sentinel.
    /// @dev It must resolve BEFORE the derivation, which divides the principal by it to bound the fill count.
    function test_post_ZeroMinFillResolvesToMinDebt_AndStoresTheResolvedValue() public {
        uint256 orderId = _post(P, LIQ, LIQ_HIGH, 0, TEN, _far());

        assertEq(ace.orderOf(orderId).minFillPrincipal, _minDebt(), "the sentinel resolved before it reached storage");
    }

    /// @notice A one-second expiry posts. The expiry is wholly the maker's, and no TTL floor exists to add.
    /// @dev This row exists to fail loudly if a bound is ever introduced, since the near-atomic order is a design target.
    function test_post_AOneSecondExpiryIsLegal() public {
        uint64 expiry = uint64(_now() + 1);
        uint256 orderId = _post(P, LIQ, LIQ_HIGH, MINFILL, TEN, expiry);

        assertEq(ace.orderOf(orderId).expiry, expiry, "the maker's one-second expiry rested exactly as stated");
    }

    /// @notice And a ten-year one. There is no ceiling either.
    function test_post_ATenYearExpiryIsLegal() public {
        uint64 expiry = uint64(_now() + 3650 days);
        uint256 orderId = _post(P, LIQ, LIQ_HIGH, MINFILL, TEN, expiry);

        assertEq(ace.orderOf(orderId).expiry, expiry, "the maker's decade rested exactly as stated");
    }
}

/// @title AceOrderPostGridRail
/// @notice The off-grid tenor row, which needs a market whose grid has more than one rung to be a distinct fact.
/// @notice On a market with `minTenor == maxTenor` an off-grid tenor and an out-of-range tenor are the same input.
/// @dev THE OPEN PATH HAS NO GRID CHECK: `_preChecks` tests the RANGE only, so post is STRICTER than the open it mirrors.
/// @dev `Ladder.isOnTenorGrid` is otherwise read by the deposit horizon alone.
contract AceOrderPostGridRailTest is AceOrderFixture {
    bytes32 internal gridId;

    uint64 internal constant SHORT = 7 days;
    uint64 internal constant LONG = 30 days;
    uint64 internal constant OFF_GRID = 14 days; // between the two named terms; it was on no rung and is legal now

    function setUp() public override {
        super.setUp();
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.minTenor = SHORT;
        p.maxTenor = LONG;
        gridId = ace.createMarket(p);
    }

    // DELETED WITH THE TENOR GRID: testRevert_post_TenorInRangeButOffTheGrid made `postOrder` stricter than the open; every second in range is issuable now

    /// @notice Both ENDS of the range post, and so does a term between them: the band is continuous.
    /// @dev RENAMED from `..._BothGridRungsAreLegal`. What it pinned -- that the two named terms work -- is
    /// @dev unchanged; what is NEW is the middle, which used to be the refusal the row above tested.
    function test_post_EveryTenorInTheRangeIsLegal() public {
        vm.prank(maker);
        uint256 shortId = ace.postOrder(gridId, P, LIQ, LIQ_HIGH, MINFILL, SHORT, _far());
        vm.prank(maker);
        uint256 longId = ace.postOrder(gridId, P, LIQ, LIQ_HIGH, MINFILL, LONG, _far());
        vm.prank(maker);
        uint256 midId = ace.postOrder(gridId, P, LIQ, LIQ_HIGH, MINFILL, OFF_GRID, _far());

        assertEq(ace.orderOf(shortId).tenor, SHORT, "the lower end rested");
        assertEq(ace.orderOf(longId).tenor, LONG, "and so did the upper one");
        assertEq(ace.orderOf(midId).tenor, OFF_GRID, "and a term between them, which no grid issues any more");
    }
}

/// @title AceOrderCloseRail
/// @notice Closing is the maker's alone, it is idempotent-refusing rather than idempotent, and its `to` is load-bearing.
/// @dev `to` is NOT a simplification waiting to happen: a push to `order.maker` bricks the close on a collateral that blacklists them.
contract AceOrderCloseRailTest is AceOrderFixture {
    /// @notice Only the maker may retire their own order.
    function testRevert_close_ByANonMaker() public {
        uint256 orderId = _postDefault();

        vm.prank(stranger);
        vm.expectRevert(NotMaker.selector);
        ace.closeOrder(orderId, stranger);
    }

    /// @notice A second close refuses rather than releasing nothing quietly.
    function testRevert_close_Twice() public {
        uint256 orderId = _postDefault();
        vm.prank(maker);
        ace.closeOrder(orderId, maker);

        vm.prank(maker);
        vm.expectRevert(OrderClosed.selector);
        ace.closeOrder(orderId, maker);
    }

    /// @notice A close on a resting order returns the whole remaining escrow, exactly, and marks it closed.
    function test_close_ReturnsTheRemainingEscrowExactly() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 before = vault.balanceOf(maker);

        vm.prank(maker);
        uint256 units = ace.closeOrder(orderId, maker);

        assertEq(units, o.collateralUnits, "the close reported the whole remainder");
        assertEq(vault.balanceOf(maker) - before, o.collateralUnits, "and delivered it");
        assertEq(pm.collateralOf(orderId), 0, "the pot no longer holds any of it");
        assertTrue(ace.orderOf(orderId).closed, "and the order is marked closed");
    }

    /// @notice A close AFTER a partial fill returns only what the fills left, which is the shrunk remainder.
    function test_close_AfterAPartialFillReturnsOnlyTheResidue() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 take = _proRata(o, MINFILL);
        _fill(orderId, MINFILL, take);
        uint256 before = vault.balanceOf(maker);

        vm.prank(maker);
        uint256 units = ace.closeOrder(orderId, maker);

        assertEq(units, o.collateralUnits - take, "the residue is the escrow less what the fill carried");
        assertEq(vault.balanceOf(maker) - before, units, "and it landed with the maker");
    }

    /// @notice A `to` that is not the maker SUCCEEDS. The parameter is the escape hatch, not an oversight.
    function test_close_ToAnAddressThatIsNotTheMakerSucceeds() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        vm.prank(maker);
        ace.closeOrder(orderId, rescue);

        assertEq(vault.balanceOf(rescue), o.collateralUnits, "the escrow reached the maker's chosen address");
        assertEq(vault.balanceOf(maker), 1e36 - o.collateralUnits, "and none of it went back to the maker");
    }
}
