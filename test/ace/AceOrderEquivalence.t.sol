// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower, GateRefused} from "../../src/ace/hub/Borrower.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BadLiquidationBand, FillBelowMin, FillUnderCollateralized} from "../../src/ace/hub/Orders.sol";
import {Cfg, MarketParams, MarketState, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AceOrderFixture} from "./AceOrderRails.t.sol";

/// @title AceOrderEquivalence
/// @notice The band's price promise, fee equivalence with a direct open, and the cross-cutting order rails.
/// @notice GREEN BY DESIGN. Every row here pins behaviour the shipped rails already produce.
/// @notice A red row is therefore a defect in `Orders.sol` or in the row itself, never a rail waiting to land.
/// @dev The one deliberate exception is the WITNESS row, which records a gap rather than a guarantee; it says so in its own name.

/* ====== STAGE 5: the stated liquidation price, swept across decimal layouts ====== */

/// @title AceOrderStatedPrice
/// @notice A maker states a BAND of liquidation prices; the escrow is derived from its LOW end and nothing else.
/// @notice THE property the field collapse rests on: a fill taking the whole escrow triggers at or below that low end.
/// @dev `Borrower.requiredAt` ceils, so the derived units land at or above the exact requirement and the trigger lands at or below.
/// @dev Swept across quote/collateral decimal pairs because `unitScale` is the one term that carries the layout into the trigger.
contract AceOrderStatedPriceTest is WarpClock {
    /// @dev One sweep row. Bundled because the sweep body would otherwise carry eight locals past the stack limit.
    struct Case {
        uint8 quoteDec;
        uint8 collDec;
        uint256 minCoverageWad;
        uint256 principal;
        uint256 liqLow;
        uint256 liqHigh;
        uint256 minFill;
        uint256 ladder;
        string why;
    }

    address internal lender = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);

    uint64 internal constant TEN = ProtocolPolicy.MIN_TENOR;

    function setUp() public {
        _warpTo(1_000_000);
    }

    /// @notice Six layouts, one property: fill the whole order and the resulting trigger sits at or below the band's LOW end.
    /// @notice The escrow is sized at the low end, so a fill taking all of it lands there and never at the high end.
    /// @dev Every row builds its OWN hub, so no row's ladder or counter can colour another's numbers.
    function test_fill_TriggerNeverExceedsTheBandsLowEnd() public {
        _sweep(Case(6, 18, 1.4e18, 1_000e6, 0.5e18, 0.6e18, 250e6, 5_000_000e6, "6/18: the fixture's own layout"));
        _sweep(Case(18, 18, 1.4e18, 1_000e18, 0.9e18, 0.9e18, 1_000e18, 50_000e18, "18/18: a RIGID band, all-or-nothing"));
        _sweep(Case(6, 8, 2e18, 777e6, 0.333e18, 0.5e18, 100e6, 100_000e6, "6/8: the WBTC/USDC layout, indivisible numbers"));
        _sweep(Case(6, 18, 1.05e18, 5_000e6, 0.999999e18, 0.999999e18, 1_000e6, 100_000e6, "6/18: a rigid band one hair under the floor"));
        _sweep(Case(18, 18, 3e18, 12_345e18, 0.25e18, 0.4e18, 4_000e18, 100_000e18, "18/18: deep coverage, an indivisible fill floor"));
        _sweep(Case(6, 18, 20e18, 1_000e6, 0.05e18, 0.9e18, 10e6, 100_000e6, "6/18: the coverage ceiling under a very wide band"));
    }

    /// @dev Builds the market, rests the ladder, posts at the stated price, fills WHOLE, and asserts the trigger.
    function _sweep(Case memory k) internal {
        MockERC20 quote = new MockERC20("Quote", "Q", k.quoteDec);
        MockERC20 coll = new MockERC20("Collateral", "C", k.collDec);
        uint256 rungPrice = AceFixtures.priceAt(address(quote), address(coll), 0);
        /// @dev Each row states its band as a FRACTION OF THE RUNG IT WILL FUND AT, which is what a row saying
        /// @dev "one hair under the floor" means. The market bids at par here, so that is the price it funds at.
        k.liqLow = FullMath.mulDiv(rungPrice, k.liqLow, 1e18);
        k.liqHigh = FullMath.mulDiv(rungPrice, k.liqHigh, 1e18);

        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.minCoverageWad = k.minCoverageWad;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);

        quote.mint(lender, k.ladder);
        vm.startPrank(lender);
        quote.approve(address(d.ace), k.ladder);
        d.ace.deposit(d.id, k.ladder);
        vm.stopPrank();

        coll.mint(maker, type(uint128).max);
        vm.prank(maker);
        coll.approve(address(d.positionManager), type(uint256).max);

        vm.prank(maker);
        uint256 orderId = d.ace.postOrder(d.id, k.principal, k.liqLow, k.liqHigh, k.minFill, TEN, uint64(_now() + 30 days));
        Order memory o = d.ace.orderOf(orderId);
        assertEq(o.liqHigh, k.liqHigh, string.concat(k.why, ": the high end rested as stated; the low end is the escrow's own ratio"));

        vm.prank(filler);
        uint256 loanId = d.ace.fillOrder(orderId, o.principal, o.collateralUnits);

        uint256 trig = d.read.triggerPrice(loanId);
        assertGt(trig, 0, string.concat(k.why, ": guard: the trigger is a real number, not a degenerate zero"));
        assertLe(trig, k.liqLow, string.concat(k.why, ": the loan triggers at or below the band's low end"));
        assertEq(d.read.loan(loanId).borrower, maker, string.concat(k.why, ": and the loan is the maker's"));
    }

    /// @notice The derivation is not merely SAFE, it is TIGHT: one unit less collateral would break the promise.
    /// @dev Without this the row above would pass on an escrow ten times too fat, which is a different contract.
    function test_fill_TheDerivedEscrowIsTightAgainstTheBandsLowEnd() public {
        MockERC20 quote = new MockERC20("Quote", "Q", 6);
        MockERC20 coll = new MockERC20("Collateral", "C", 18);
        uint256 low = AceFixtures.px(0.5e18, address(quote), address(coll));
        uint256 high = AceFixtures.px(0.6e18, address(quote), address(coll));

        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);

        quote.mint(lender, 5_000_000e6);
        vm.startPrank(lender);
        quote.approve(address(d.ace), 5_000_000e6);
        d.ace.deposit(d.id, 5_000_000e6);
        vm.stopPrank();

        coll.mint(maker, type(uint128).max);
        vm.prank(maker);
        coll.approve(address(d.positionManager), type(uint256).max);

        vm.prank(maker);
        uint256 orderId = d.ace.postOrder(d.id, 1_000e6, low, high, 1_000e6, TEN, uint64(_now() + 30 days));
        Order memory o = d.ace.orderOf(orderId);

        vm.prank(filler);
        uint256 loanId = d.ace.fillOrder(orderId, o.principal, o.collateralUnits);

        uint256 exact = d.read.triggerPrice(loanId);
        assertLe(exact, low, "the escrow honours the band's low end");
        assertGt(exact, (low * 98) / 100, "and it is not fat: the trigger sits within a percent of the end it was sized at");
    }
}

/// @title AceOrderPartialFillPrice
/// @notice The band survives FRAGMENTATION: three unequal legal fills, three loans, one promise.
/// @dev The take is the order's own posted ratio at each leg, which is the largest the low-end rail admits.
/// @dev That is the SAFEST case for this loan and the tightest for the remainder, which is why the monotonicity row sits beside it.
contract AceOrderPartialFillPriceTest is AceOrderFixture {
    /// @notice Every loan a three-way split produces triggers at or below the band's low end.
    function test_fill_ThreeUnequalPartsEachHonourTheBandsLowEnd() public {
        uint256 orderId = _postDefault();

        uint256 a = _fillProRata(orderId, 300e6);
        uint256 b = _fillProRata(orderId, 250e6);
        Order memory rest = ace.orderOf(orderId);
        assertEq(rest.principal, 450e6, "guard: the third leg takes the last of the principal and is a third distinct size");
        uint256 c = _fill(orderId, rest.principal, rest.collateralUnits);

        assertLe(read.triggerPrice(a), LIQ, "leg one triggers at or below the band's low end");
        assertLe(read.triggerPrice(b), LIQ, "leg two does too");
        assertLe(read.triggerPrice(c), LIQ, "and so does the last leg");
        assertGt(read.triggerPrice(a), 0, "guard: none of the three is a degenerate zero");
        assertEq(ace.orderOf(orderId).collateralUnits, 0, "and the three legs consumed the whole escrow");
    }

    /// @notice The trigger is SCALE-INVARIANT under a proportional fill: the legs land on the same number.
    /// @dev A derivation that re-derived collateral per fill would drift here rather than repeat.
    function test_fill_ProportionalLegsProduceTheSameTrigger() public {
        uint256 orderId = _postDefault();

        uint256 a = _fillProRata(orderId, 250e6);
        uint256 b = _fillProRata(orderId, 250e6);

        assertEq(read.triggerPrice(a), read.triggerPrice(b), "two equal proportional legs price the same trigger");
        assertLe(read.triggerPrice(a), LIQ, "and both sit under the band's low end");
    }

    /// @notice ALL-OR-NOTHING, the refusal half: the maker's own floor at the principal admits no partial.
    function testRevert_fill_AllOrNothingRefusesAnyPartial() public {
        uint256 orderId = _post(P, LIQ, LIQ_HIGH, P, TEN, _far());
        Order memory o = ace.orderOf(orderId);
        uint256 part = P - 1;
        assertGe(part, _minDebt(), "guard: the partial clears the market's own dust floor, so only the maker refuses it");

        vm.prank(filler);
        vm.expectRevert(FillBelowMin.selector);
        ace.fillOrder(orderId, part, _proRata(o, part));
    }

    /// @notice ALL-OR-NOTHING, the admission half: the exact size fills, so the refusal above is the maker's choice.
    function test_fill_AllOrNothingAdmitsTheExactSize() public {
        uint256 orderId = _post(P, LIQ, LIQ_HIGH, P, TEN, _far());
        Order memory o = ace.orderOf(orderId);

        uint256 loanId = _fill(orderId, o.principal, o.collateralUnits);

        assertEq(read.loan(loanId).debt, P, "the whole principal drew in one fill");
        assertLe(read.triggerPrice(loanId), LIQ, "at or below the band's low end");
        assertEq(ace.orderOf(orderId).principal, 0, "and the principal is spent");
    }

    /// @notice THE ROW THE HIGH LEG EXISTS FOR: a green witness before the band shipped, and a refusal now.
    /// @notice The old rail bounded a fill from ABOVE only, so a coverage-line take doubled the maker's trigger at gas cost alone.
    /// @dev Delete the high leg and this goes green again, which is precisely what it is here to prevent.
    function testRevert_fill_AThinFillIsRefusedByTheBandsHighEnd() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        uint256 thin = _coverage(MINFILL, _floorFor(MINFILL, o.tenor)) + 1;
        assertLt(thin, _proRata(o, MINFILL), "guard: the take is strictly under the order's own posted ratio");
        assertLe(thin, o.collateralUnits, "guard: it is inside the escrow, so FillOverOrder cannot fire first");

        vm.prank(filler);
        vm.expectRevert(FillUnderCollateralized.selector);
        ace.fillOrder(orderId, MINFILL, thin);
    }

    /// @notice The BOUNDARY, exactly: the collateral the high end requires fills, and one unit less does not.
    /// @dev Sized off `Borrower.requiredAt` at the high end, so the pair moves with the market's coverage rule rather than a literal.
    function test_fill_TheBandsHighEndAdmitsExactlyTheRequiredCollateral() public {
        uint256 orderId = _postDefault();
        uint256 atEdge = _requiredAt(MINFILL, LIQ_HIGH);

        uint256 loanId = _fill(orderId, MINFILL, atEdge);

        assertLe(read.triggerPrice(loanId), LIQ_HIGH, "a fill at the edge lands inside the band");
        assertGt(read.triggerPrice(loanId), LIQ, "and genuinely at the HIGH end, not back down at the low one");
    }

    /// @notice One unit under that edge is refused, which is what makes the row above a boundary and not a floor.
    function testRevert_fill_OneUnitUnderTheBandsHighEnd() public {
        uint256 orderId = _postDefault();
        uint256 underEdge = _requiredAt(MINFILL, LIQ_HIGH) - 1;

        vm.prank(filler);
        vm.expectRevert(FillUnderCollateralized.selector);
        ace.fillOrder(orderId, MINFILL, underEdge);
    }

    /// @notice A RIGID band, `liqLow == liqHigh`, is the single-price form: the pro-rata take is the only one admitted.
    /// @dev The two legs close on each other, so a take a whole unit-scale thinner is already out of band.
    function test_fill_ARigidBandAdmitsOnlyTheProRataTake() public {
        uint256 orderId = _post(P, LIQ, LIQ, MINFILL, TEN, _far());
        Order memory o = ace.orderOf(orderId);
        assertEq(o.liqHigh, LIQ, "guard: the band really is a point");

        uint256 loanId = _fill(orderId, MINFILL, _proRata(o, MINFILL));
        assertLe(read.triggerPrice(loanId), LIQ, "the pro-rata take fills at the pinned price");

        Order memory rest = ace.orderOf(orderId);
        vm.prank(filler);
        vm.expectRevert(FillUnderCollateralized.selector);
        ace.fillOrder(orderId, MINFILL, _proRata(rest, MINFILL) - 1e18);
    }

    /// @dev Fills at the order's own posted ratio, which is the largest take the low-end rail admits.
    function _fillProRata(uint256 orderId, uint256 principalOut) internal returns (uint256) {
        Order memory o = ace.orderOf(orderId);
        return _fill(orderId, principalOut, _proRata(o, principalOut));
    }
}

/// @title AceOrderBandRail
/// @notice The band at POST: it must be non-empty, right way up, and have a usable low end for the escrow to size against.
/// @dev The band check runs BEFORE the fill-floor check, so every row here passes a legal `minFillPrincipal`.
contract AceOrderBandRailTest is AceOrderFixture {
    /// @notice A zero low end would divide the escrow derivation by nothing and size an infinite position.
    function testRevert_post_ZeroLowEnd() public {
        vm.prank(maker);
        vm.expectRevert(BadLiquidationBand.selector);
        ace.postOrder(id, P, 0, LIQ_HIGH, MINFILL, TEN, _far());
    }

    /// @notice A zero high end is an inverted band against any usable low end, and is refused as one.
    function testRevert_post_ZeroHighEnd() public {
        vm.prank(maker);
        vm.expectRevert(BadLiquidationBand.selector);
        ace.postOrder(id, P, LIQ, 0, MINFILL, TEN, _far());
    }

    /// @notice An INVERTED band names a worst case better than its best case, which no fill could ever satisfy.
    function testRevert_post_InvertedBand() public {
        vm.prank(maker);
        vm.expectRevert(BadLiquidationBand.selector);
        ace.postOrder(id, P, LIQ_HIGH, LIQ, MINFILL, TEN, _far());
    }

    /// @notice Both ends may be equal, which is the rigid single-price form and the tightest legal band.
    function test_post_ARigidBandIsLegalAndRestsAsStated() public {
        uint256 orderId = _post(P, LIQ, LIQ, MINFILL, TEN, _far());

        assertEq(ace.orderOf(orderId).liqHigh, LIQ, "the pinned price rested as the high end");
        assertGt(ace.orderOf(orderId).collateralUnits, 0, "and the escrow sized against the same number");
    }

    /// @notice The low end is NOT stored: it is recoverable as the escrow's own implied trigger, and it lands where stated.
    /// @dev That recoverability is what lets the fill's low leg be division-free rather than reading a stored price.
    function test_post_TheLowEndIsRecoverableFromTheEscrowsOwnRatio() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);

        uint256 implied = LoanMath.triggerPrice(o.principal, o.collateralUnits, _cfg().p.minCoverageWad, _cfg().unitScale);

        assertLe(implied, LIQ, "the escrow's implied trigger is the low end the maker stated, or safer");
        assertGt(implied, (LIQ * 99) / 100, "and it is not merely safer: it sits within a percent of it");
    }
}

/* ====== STAGE 6: fee equivalence, and the three standing invariants ====== */

/// @title AceOrderFeeIdentity
/// @notice THE equivalence: an order fill and a direct `open` on the same terms price identically, to the wei.
/// @notice Same principal, same collateral, same tenor, same ladder: same fee, same protocol take, same escrow, same qIndex.
/// @dev Run on a MULTI-TICK draw, because the per-leg flooring residue is invisible when a draw touches one tick.
/// @dev Two IDENTICAL hub deployments rather than one hub twice: the market id is the params hash, so both carry the same id and the same ladder.
contract AceOrderFeeIdentityTest is WarpClock {
    Ace internal aceOrder;
    Ace internal aceOpen;
    PositionManager internal pmOrder;
    PositionManager internal pmOpen;
    AceReader internal readOrder;
    AceReader internal readOpen;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id;

    address internal lender = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);

    uint64 internal constant TEN = ProtocolPolicy.MIN_TENOR;
    uint256 internal constant DRAW = 3_000e6;
    uint256 internal LIQ; // the band's low end in the hub's frame; assigned in setUp
    uint256 internal LIQ_HIGH; // its high end
    uint256 internal T0; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal T1; // one rung above par
    uint256 internal T2; // two rungs above par

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    /// @dev ONE `MarketParams` deployed twice: the fixture fills the price reference once and reuses it, so both hubs hash the same id.
    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T0, T1, T2) = (_price(0), _price(60), _price(120));
        LIQ = AceFixtures.px(0.5e18, address(usdc), address(vault));
        LIQ_HIGH = AceFixtures.px(0.6e18, address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        AceFixtures.Deployment memory a = AceFixtures.deploy(p);
        AceFixtures.Deployment memory b = AceFixtures.deploy(p);
        (aceOrder, pmOrder, readOrder) = (a.ace, a.positionManager, a.read);
        (aceOpen, pmOpen, readOpen) = (b.ace, b.positionManager, b.read);
        assertEq(a.id, b.id, "guard: the two deployments carry the same market id, so their params are identical");
        id = a.id;

        _rest(aceOrder, 1_000e6);
        _rest(aceOrder, 1_000e6);
        _rest(aceOrder, 3_000e6);
        _rest(aceOpen, 1_000e6);
        _rest(aceOpen, 1_000e6);
        _rest(aceOpen, 3_000e6);

        vault.mint(maker, 1e36);
        vm.startPrank(maker);
        vault.approve(address(pmOrder), type(uint256).max);
        vault.approve(address(pmOpen), type(uint256).max);
        vm.stopPrank();
    }

    function _rest(Ace target, uint256 amt) internal {
        usdc.mint(lender, amt);
        vm.startPrank(lender);
        usdc.approve(address(target), amt);
        target.deposit(id, amt);
        vm.stopPrank();
    }

    /// @notice The whole fee path, wei for wei, on a draw that spans three ticks.
    function test_equivalence_AFillPricesExactlyLikeADirectOpen() public {
        vm.prank(maker);
        uint256 orderId = aceOrder.postOrder(id, DRAW, LIQ, LIQ_HIGH, DRAW, TEN, uint64(_now() + 30 days));
        Order memory o = aceOrder.orderOf(orderId);

        uint256 revenueBefore = readOrder.protocolRevenue(id);
        assertEq(revenueBefore, readOpen.protocolRevenue(id), "guard: the two hubs start from the same protocol pot");

        vm.prank(filler);
        uint256 filled = aceOrder.fillOrder(orderId, o.principal, o.collateralUnits);
        vm.prank(maker);
        uint256 opened = aceOpen.open(id, o.collateralUnits, DRAW, TEN, maker, OpenBounds(0, 0, 0));

        assertEq(readOrder.loan(filled).debt, readOpen.loan(opened).debt, "identical debt");
        assertEq(readOrder.loan(filled).collateralUnits, readOpen.loan(opened).collateralUnits, "identical collateral");
        assertEq(readOrder.loan(filled).lastFee, readOpen.loan(opened).lastFee, "IDENTICAL FEE");
        assertGt(readOrder.loan(filled).lastFee, 0, "guard: a real fee was charged, so the equality is not two zeroes");
        assertEq(readOrder.protocolRevenue(id) - revenueBefore, readOpen.protocolRevenue(id) - revenueBefore, "identical protocolRevenue delta");
        assertGt(readOrder.protocolRevenue(id) - revenueBefore, 0, "guard: the protocol took a real cut on both");
        assertEq(readOrder.feeEscrowOf(filled), readOpen.feeEscrowOf(opened), "identical refundable escrow");
        assertGt(readOrder.feeEscrowOf(filled), 0, "guard: the refundable half is non-zero");
    }

    /// @notice The per-class half of the identity: every funded tick carries the same claim, supply and qIndex.
    /// @dev Split from the row above so a failing class assertion names the tick rather than dying inside a loop of scalars.
    function test_equivalence_EveryFundedClassCarriesTheSameQIndex() public {
        vm.prank(maker);
        uint256 orderId = aceOrder.postOrder(id, DRAW, LIQ, LIQ_HIGH, DRAW, TEN, uint64(_now() + 30 days));
        Order memory o = aceOrder.orderOf(orderId);

        vm.prank(filler);
        uint256 filled = aceOrder.fillOrder(orderId, o.principal, o.collateralUnits);
        vm.prank(maker);
        uint256 opened = aceOpen.open(id, o.collateralUnits, DRAW, TEN, maker, OpenBounds(0, 0, 0));

        /// @dev The per-class supply and index are gone with the receipt ledger, and the funded-tick list went
        /// @dev with the ladder, so the whole comparison is the two loans' single claims. The FEE half moved to
        /// @dev the pool and is compared below, because it is one bucket per (lender, quote).
        assertEq(readOrder.claimCount(id, filled), 1, "guard: the order route really funded the loan");
        assertEq(readOpen.claimCount(id, opened), readOrder.claimCount(id, filled), "and so did the direct open");
        assertEq(readOrder.claimOf(id, filled), readOpen.claimOf(id, opened), "same claim, whichever door drew it");
        assertEq(readOrder.poolOwed(id), readOpen.poolOwed(id), "SAME credit reached the lender either way");
        assertGt(readOrder.poolOwed(id), 0, "guard: the tick fee really reached the pool on both sides");
    }

    /// @notice The market-level aggregates move identically too: nothing about a fill routes cash differently.
    function test_equivalence_TheMarketAggregatesMoveIdentically() public {
        vm.prank(maker);
        uint256 orderId = aceOrder.postOrder(id, DRAW, LIQ, LIQ_HIGH, DRAW, TEN, uint64(_now() + 30 days));
        Order memory o = aceOrder.orderOf(orderId);

        vm.prank(filler);
        uint256 filled = aceOrder.fillOrder(orderId, o.principal, o.collateralUnits);
        vm.prank(maker);
        uint256 opened = aceOpen.open(id, o.collateralUnits, DRAW, TEN, maker, OpenBounds(0, 0, 0));

        MarketState memory sa = readOrder.marketState(id);
        MarketState memory sb = readOpen.marketState(id);
        assertEq(sa.drawCount, sb.drawCount, "same draw count");
        assertEq(sa.cash, sb.cash, "same resting cash");
        assertEq(sa.quoteOwedTotal, sb.quoteOwedTotal, "same quote-owed pot");
        /// @dev The three lender legs left `MarketState` for the pooled root, so they are compared there.
        (uint256 ra, uint256 la, uint256 oa) = readOrder.poolOf(id);
        (uint256 rb, uint256 lb, uint256 ob) = readOpen.poolOf(id);
        assertEq(ra, rb, "same resting cash");
        assertEq(la, lb, "same lent");
        assertEq(oa, ob, "same credit owed the lender");
        assertEq(
            usdc.balanceOf(maker),
            (DRAW - readOrder.loan(filled).lastFee) + (DRAW - readOpen.loan(opened).lastFee),
            "the maker netted the same payout on both paths"
        );
    }
}

/// @title AceOrderStandingInvariants
/// @notice The two facts that must hold after EVERY order verb, fuzzed over sequences of legal fills.
/// @notice One: a live remainder is never under the maker's own floor. Two: a closed order holds no custody.
/// @dev `principal == 0 iff collateralUnits == 0` IS GONE. It existed only to make the auto-close safe, and both went together.
/// @dev Under a band the last fill may legitimately leave a residue, so a spent order rests holding escrow until the maker takes it back.
contract AceOrderStandingInvariantsTest is AceOrderFixture {
    /// @notice The invariants after every fill in a random legal sequence, and again after the close that ends it.
    function testFuzz_invariants_HoldAfterEveryFillAndAfterTheClose(uint256 seed) public {
        uint256 orderId = _postDefault();
        _assertInvariants(orderId, "at post");

        for (uint256 k; k < 4; k++) {
            Order memory o = ace.orderOf(orderId);
            if (o.principal == 0) break;
            uint256 pOut = _legalPrincipal(o, seed, k);
            _fill(orderId, pOut, pOut == o.principal ? o.collateralUnits : _proRata(o, pOut));
            _assertInvariants(orderId, "after a fill");
        }

        vm.prank(maker);
        ace.closeOrder(orderId, maker);
        _assertInvariants(orderId, "after the close");
        Order memory end = ace.orderOf(orderId);
        assertTrue(end.closed, "only the maker's own close ends an order now");
        assertEq(end.principal, 0, "and zeroed principal");
        assertEq(end.collateralUnits, 0, "and zeroed escrow");
    }

    /// @notice MONOTONICITY, and it is the property the whole band rests on.
    /// @notice A fill thinner than pro rata leaves the REMAINDER safer, never worse, so no sequence walks an order out of its band.
    /// @dev It follows from the low leg alone: `u*P <= p*C` rearranges to `(P-p)/(C-u) <= P/C`, and the trigger's ceil is monotone.
    /// @dev So the rail that bounds one fill's fatness is the same one that keeps every later fill inside the band.
    function testFuzz_property_AThinnerFillLeavesTheRemainderSafer(uint256 seed) public {
        uint256 orderId = _postDefault();
        uint256 previous = _impliedTrigger(ace.orderOf(orderId));
        assertLe(previous, LIQ, "guard: the escrow starts at or under the band's low end");
        uint256 thinLegs;

        for (uint256 k; k < 4; k++) {
            Order memory o = ace.orderOf(orderId);
            if (o.principal == 0) break;
            uint256 pOut = _legalPrincipal(o, seed, k);
            uint256 uOut = _legalUnits(o, pOut, seed, k);
            if (uOut < _proRata(o, pOut)) thinLegs++;
            _fill(orderId, pOut, uOut);

            uint256 now_ = _impliedTrigger(ace.orderOf(orderId));
            assertLe(now_, LIQ, "the remainder never drifts above the band's low end");
            assertLe(now_, previous, "and never rises at all: a fill can only leave what is behind it safer");
            previous = now_;
        }
        assertGt(thinLegs, 0, "guard: the sequence really took a THINNER-than-pro-rata leg, which is the case under test");
    }

    /// @notice The CLOSE path: it zeroes BOTH sides, which is what makes a spent order's residue reclaimable in one call.
    /// @dev A close that zeroed only the escrow would leave a live-looking principal behind a dead record.
    function test_close_ZeroesPrincipalAndEscrowTogether() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        _fill(orderId, MINFILL, _proRata(o, MINFILL));
        Order memory mid = ace.orderOf(orderId);
        assertGt(mid.principal, 0, "guard: the close is acting on a live remainder, not an already-spent order");
        assertGt(mid.collateralUnits, 0, "guard: and on a live escrow");

        vm.prank(maker);
        ace.closeOrder(orderId, rescue);

        _assertInvariants(orderId, "after a close over a partial");
        Order memory end = ace.orderOf(orderId);
        assertEq(end.principal, 0, "the close zeroed the principal");
        assertEq(end.collateralUnits, 0, "and the escrow with it");
        assertEq(pm.collateralOf(orderId), 0, "and a closed order holds no custody");
    }

    /// @dev The surviving invariants, asserted as one block so no call site can check just one of them.
    function _assertInvariants(uint256 orderId, string memory why) internal view {
        Order memory o = ace.orderOf(orderId);
        assertTrue(o.principal == 0 || o.principal >= o.minFillPrincipal, string.concat(why, ": principal is zero or at the maker's floor"));
        if (o.closed) {
            assertEq(pm.collateralOf(orderId), 0, string.concat(why, ": a closed order holds no custody"));
        }
        assertEq(o.collateralUnits, pm.collateralOf(orderId), string.concat(why, ": the record agrees with the pot"));
    }

    /// @dev What the order's remaining escrow implies as a trigger; the band's low end is not stored, so this is how it reads back.
    function _impliedTrigger(Order memory o) internal view returns (uint256) {
        return LoanMath.triggerPrice(o.principal, o.collateralUnits, _cfg().p.minCoverageWad, _cfg().unitScale);
    }

    /// @dev A principal draw inside the legal band: at least the maker's floor, never stranding a sub-floor remainder.
    function _legalPrincipal(Order memory o, uint256 seed, uint256 k) internal pure returns (uint256) {
        uint256 pOut = o.minFillPrincipal + (uint256(keccak256(abi.encode(seed, k))) % (o.principal - o.minFillPrincipal + 1));
        return (o.principal - pOut < o.minFillPrincipal) ? o.principal : pOut;
    }

    /// @dev A take somewhere inside the band: between the high end's requirement and the order's own pro-rata ratio.
    /// @dev Deliberately NOT always pro rata, because a thinner take is exactly what the monotonicity claim is about.
    function _legalUnits(Order memory o, uint256 pOut, uint256 seed, uint256 k) internal view returns (uint256) {
        uint256 top = _proRata(o, pOut);
        uint256 bottom = _requiredAt(pOut, o.liqHigh);
        if (bottom >= top) return top;
        return bottom + (uint256(keccak256(abi.encode(seed, k, "units"))) % (top - bottom + 1));
    }
}

/// @title AceOrderRestingWritesNothing
/// @notice INVARIANT ONE: a resting order writes NO market state. Not approximately none: none.
/// @dev The escrow is the ONE coupling, and it lands in the custodian rather than in the ladder, which is the whole design claim.
contract AceOrderRestingWritesNothingTest is AceOrderFixture {
    uint256 internal NEIGHBOUR_UP; // one step either side of the market price, named relative to par
    uint256 internal NEIGHBOUR_DOWN;

    /// @dev The pair exists only once the base fixture has run, so the neighbours are named after it.
    function setUp() public override {
        super.setUp();
        (NEIGHBOUR_UP, NEIGHBOUR_DOWN) = (_price(60), _price(-60));
    }

    /// @notice Every scalar of `MarketState` is BIT-IDENTICAL across a large post, and so is the lender's pool.
    /// @dev The pool is checked here rather than left out: a post that touched it would be exactly as wrong,
    /// @dev and the three legs it holds are the ones that used to live in `MarketState` itself.
    function test_post_WritesNoMarketStateScalar() public {
        MarketState memory before = read.marketState(id);
        (uint256 restBefore, uint256 lentBefore, uint256 owedBefore) = read.poolOf(id);

        _post(1_000_000e6, LIQ, LIQ_HIGH, 10e6, TEN, _far());

        MarketState memory now_ = read.marketState(id);
        (uint256 restNow, uint256 lentNow, uint256 owedNow) = read.poolOf(id);
        assertEq(restNow, restBefore, "resting cash is untouched");
        assertEq(lentNow, lentBefore, "lent is untouched");
        assertEq(owedNow, owedBefore, "the credit owed the lender is untouched");
        assertEq(now_.quoteOwedTotal, before.quoteOwedTotal, "quoteOwedTotal is untouched");
        assertEq(now_.drawCount, before.drawCount, "drawCount is untouched: a resting order is not a draw");
        assertEq(now_.netSyntheticOutflow, before.netSyntheticOutflow, "netSyntheticOutflow is untouched");
        assertEq(now_.protocolRevenue, before.protocolRevenue, "protocolRevenue is untouched: resting costs nothing");
        assertEq(now_.cumulativeBackedBurns, before.cumulativeBackedBurns, "cumulativeBackedBurns is untouched");
        assertEq(now_.realizedLossAtBook, before.realizedLossAtBook, "realizedLossAtBook is untouched");
        assertEq(now_.cash, before.cash, "resting cash is untouched: a resting order draws none of it");
        assertEq(now_.lastSweptAt, before.lastSweptAt, "lastSweptAt is untouched");
        assertEq(now_.unitScale, before.unitScale, "unitScale is untouched");
    }

    /// @notice And the market's resting cash: a resting order draws none of it.
    /// @dev IT COMPARED THREE BUCKETS -- the funded tick and both untouched neighbours, field for field --
    /// @dev because a write could land at one tick and not another. There is one balance to compare now,
    /// @dev and the neighbours it guarded against have no successor: a market holds cash at one price.
    function test_post_WritesNoRestingCash() public {
        uint256 before = read.restingOf(id);
        assertGt(before, 0, "guard: the market really holds cash, so the comparison is not two zeroes");

        _post(1_000_000e6, LIQ, LIQ_HIGH, 10e6, TEN, _far());

        assertEq(read.restingOf(id), before, "a resting order writes no resting cash");
    }

    /// @notice The ONE legitimate coupling, stated as the pair it actually is.
    /// @notice `custodiedOf` and the pot balance rise TOGETHER by the escrow, so the uncredited surplus does not move.
    /// @dev `PositionManager.pull` measures the incoming transfer and credits the measured delta, which is why the surplus is flat.
    /// @dev A rise in the surplus here would mean units reached the pot that no order is credited with.
    function test_post_MovesCustodyAndNothingElse() public {
        uint256 custodiedBefore = pm.custodiedOf(address(vault));
        uint256 potBefore = vault.balanceOf(address(pm));
        uint256 surplusBefore = pm.uncreditedSurplus(address(vault));
        uint256 hubBefore = usdc.balanceOf(address(ace));

        uint256 orderId = _post(1_000_000e6, LIQ, LIQ_HIGH, 10e6, TEN, _far());
        uint256 escrow = ace.orderOf(orderId).collateralUnits;

        assertGt(escrow, 0, "guard: a real escrow was derived, so the deltas below are not three zeroes");
        assertEq(pm.custodiedOf(address(vault)) - custodiedBefore, escrow, "custodiedOf rose by exactly the escrow");
        assertEq(vault.balanceOf(address(pm)) - potBefore, escrow, "and so did the pot it accounts for");
        assertEq(pm.uncreditedSurplus(address(vault)), surplusBefore, "so the uncredited surplus did not move");
        assertEq(pm.collateralOf(orderId), escrow, "the order's own custody row holds it");
        assertEq(usdc.balanceOf(address(ace)), hubBefore, "and the hub's quote balance is untouched: resting draws no cash");
    }
}

/* ====== STAGE 7: the cross-cutting rails ====== */

/// @title AceOrderEscrowIsolation
/// @notice WHY the escrow lives in the custodian and not in the hub: the hub's own balance IS the ladder's quote pot.
/// @notice One token, two markets: collateral in A and quote in B. B's draw must never reach A's order escrow.
/// @dev The rejected design is checkable rather than merely argued: had the escrow been hub-held, B's ladder would have spent it.
contract AceOrderEscrowIsolationTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockERC20 internal x; // A's collateral AND B's quote: the token both markets touch
    MockERC20 internal y;
    bytes32 internal idA;
    bytes32 internal idB;

    address internal lender = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal drawer = address(0xB0B);
    address internal thief = address(0x7415F);

    uint64 internal constant TEN = ProtocolPolicy.MIN_TENOR;
    uint256 internal constant B_LADDER = 1_000e18;
    uint256 internal TA; // par for market A's pair; the two markets have DIFFERENT pairs, so each names its own
    uint256 internal TB; // par for market B's pair

    function setUp() public {
        _warpTo(1_000_000);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        x = new MockERC20("Shared", "X", 18);
        y = new MockERC20("Other", "Y", 18);
        TA = AceFixtures.priceAt(address(usdc), address(x), 0);
        TB = AceFixtures.priceAt(address(x), address(y), 0);

        MarketParams memory pa = AceFixtures.marketParams(address(usdc), address(x));
        idA = ace.createMarket(pa);

        MarketParams memory pb = AceFixtures.marketParams(address(x), address(y));
        idB = ace.createMarket(pb);

        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(idA, 1_000_000e6);
        vm.stopPrank();

        x.mint(lender, B_LADDER);
        vm.startPrank(lender);
        x.approve(address(ace), type(uint256).max);
        ace.deposit(idB, B_LADDER);
        vm.stopPrank();

        x.mint(maker, 1e30);
        vm.prank(maker);
        x.approve(address(pm), type(uint256).max);

        y.mint(drawer, 1e30);
        vm.prank(drawer);
        y.approve(address(pm), type(uint256).max);
    }

    function _postInA() internal returns (uint256) {
        uint256 low = AceFixtures.px(0.5e18, address(usdc), address(x));
        uint256 high = AceFixtures.px(0.6e18, address(usdc), address(x));
        vm.prank(maker);
        return ace.postOrder(idA, 1_000e6, low, high, 250e6, TEN, uint64(_now() + 30 days));
    }

    /// @notice A draw in B that exceeds B's OWN resting cash refuses; it never reaches the escrow sitting behind A's order.
    /// @dev The escrow is the same token B lends, and it is larger than B's whole ladder, so an unpartitioned pot would have served this draw.
    function test_draw_InBCannotReachTheOrderEscrowInA() public {
        uint256 orderId = _postInA();
        uint256 escrow = ace.orderOf(orderId).collateralUnits;
        assertGt(escrow, B_LADDER, "guard: the escrow is bigger than B's whole ladder, so a shared pot would have covered the draw");

        vm.prank(drawer);
        vm.expectRevert(InsufficientCash.selector);
        ace.open(idB, 1e30 / 2, B_LADDER + 1e18, TEN, drawer, OpenBounds(0, 0, 0));

        assertEq(x.balanceOf(address(pm)), escrow, "the custodian still holds every unit of the escrow");
        assertEq(pm.custodiedOf(address(x)), escrow, "and the ledger still says so");
        assertEq(pm.collateralOf(orderId), escrow, "and the order's own row is intact");
        assertEq(ace.orderOf(orderId).collateralUnits, escrow, "and so is the record");
    }

    /// @notice A LEGAL draw in B leaves the escrow alone too, so the refusal above is about partitioning and not about failure.
    function test_draw_ALegalDrawInBLeavesTheEscrowUntouched() public {
        uint256 orderId = _postInA();
        uint256 escrow = ace.orderOf(orderId).collateralUnits;
        uint256 hubBefore = x.balanceOf(address(ace));

        vm.prank(drawer);
        uint256 loanId = ace.open(idB, 1_000e18, 500e18, TEN, drawer, OpenBounds(0, 0, 0));

        assertEq(read.loan(loanId).debt, 500e18, "guard: B really drew");
        assertEq(x.balanceOf(address(ace)), hubBefore - 500e18 + read.loan(loanId).lastFee, "the draw came out of the HUB's own quote pot");
        assertEq(x.balanceOf(address(pm)), escrow, "the custodian's balance never moved");
        assertEq(pm.custodiedOf(address(x)), escrow, "and neither did its ledger");
        assertEq(pm.uncreditedSurplus(address(x)), 0, "no stray shared-token units rest in the custodian");
    }

    /// @notice And the maker still gets the whole escrow back afterwards, which is what "untouched" has to mean.
    function test_close_ReturnsTheWholeEscrowAfterADrawInTheOtherMarket() public {
        uint256 orderId = _postInA();
        uint256 escrow = ace.orderOf(orderId).collateralUnits;
        uint256 makerBefore = x.balanceOf(maker);

        vm.prank(drawer);
        ace.open(idB, 1_000e18, 500e18, TEN, drawer, OpenBounds(0, 0, 0));

        vm.prank(maker);
        uint256 returned = ace.closeOrder(orderId, maker);

        assertEq(returned, escrow, "the close returned the whole escrow");
        assertEq(x.balanceOf(maker) - makerBefore, escrow, "and delivered it");
    }

    /// @notice The other half of the partition: the custodian moves for the HUB alone, so no outside caller can drain an order.
    function testRevert_release_ByAnyoneButTheHub() public {
        uint256 orderId = _postInA();

        vm.prank(thief);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        pm.release(orderId, thief, 1);
    }
}

/// @title AceOrderBorrowerPresentation
/// @notice The open behind a fill presents the MAKER to the market's named borrower, never the filler.
/// @notice Both halves are written: the market naming the maker must pass, and the one naming the filler must fail.
/// @dev The second row is what stops a later simplification presenting `msg.sender`: it would turn green exactly when the design broke.
/// @dev TWO MARKETS, not one arranged twice: `MarketParams.borrower` is write-once and sits in the id preimage.
contract AceOrderBorrowerPresentationTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id; // names the MAKER
    bytes32 internal idFiller; // names the FILLER, so the maker's own fill is refused there

    address internal lender = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);

    uint64 internal constant TEN = ProtocolPolicy.MIN_TENOR;
    uint256 internal constant P = 1_000e6;
    uint256 internal LIQ; // the band's low end in the hub's frame; assigned in setUp
    uint256 internal LIQ_HIGH; // its high end
    uint256 internal T; // par for this pair; assigned in setUp, since par is not a compile-time value

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = AceFixtures.priceAt(address(usdc), address(vault), 0);
        LIQ = AceFixtures.px(0.5e18, address(usdc), address(vault));
        LIQ_HIGH = AceFixtures.px(0.6e18, address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.borrower = maker;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        p.borrower = filler;
        idFiller = ace.createMarket(p);

        usdc.mint(lender, 10_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 5_000_000e6);
        ace.deposit(idFiller, 5_000_000e6); // both ladders fundable, so a refusal is never a dry tick
        vm.stopPrank();

        vault.mint(maker, 1e36);
        vm.prank(maker);
        vault.approve(address(pm), type(uint256).max);
    }

    function _postIn(bytes32 market) internal returns (uint256) {
        vm.prank(maker);
        return ace.postOrder(market, P, LIQ, LIQ_HIGH, P, TEN, uint64(_now() + 30 days));
    }

    /// @notice A market naming the MAKER admits the fill even though the filler is a stranger to it.
    function test_fill_SucceedsWhenTheMarketNamesTheMakerAndNotTheFiller() public {
        uint256 orderId = _postIn(id);

        Order memory o = ace.orderOf(orderId);
        vm.prank(filler);
        uint256 loanId = ace.fillOrder(orderId, o.principal, o.collateralUnits);

        assertEq(read.loan(loanId).borrower, maker, "the loan is the maker's, and the market admitted them");
    }

    /// @notice The inverse, and it must FAIL: a market naming only the filler refuses the fill.
    /// @dev If this ever passes, the open is presenting `msg.sender` and a named market has been opened to anyone with a maker's order.
    function testRevert_fill_WhenTheMarketNamesOnlyTheFiller() public {
        uint256 orderId = _postIn(idFiller);

        Order memory o = ace.orderOf(orderId);
        vm.prank(filler);
        vm.expectRevert(GateRefused.selector);
        ace.fillOrder(orderId, o.principal, o.collateralUnits);
    }

    /// @notice POST is unchecked: the named borrower is an ENTRY control on the draw, and resting escrow draws nothing.
    /// @dev The maker is refused in this market, and the post still rests: the refusal arrives at the fill.
    function test_post_RestsEvenInAMarketThatRefusesTheMaker() public {
        uint256 orderId = _postIn(idFiller);

        assertEq(ace.orderOf(orderId).maker, maker, "the order rested in a market that will not admit its maker");
        assertGt(ace.orderOf(orderId).collateralUnits, 0, "with its escrow in hand");
    }
}

/// @title AceOrderEnumeration
/// @notice `orderCount` and `marketOrders` mirror `marketLoansLength` and `marketLoans`, clamp for clamp.
/// @notice A closed order STAYS in the array: removal is what makes two ledgers disagree, and `openedLoans` refuses it for the same reason.
contract AceOrderEnumerationTest is AceOrderFixture {
    /// @notice The count tracks posts and NEVER decreases, closes included.
    function test_orderCount_CountsPostsAndNeverFalls() public {
        assertEq(ace.orderCount(id), 0, "a fresh market has posted nothing");

        uint256 a = _postDefault();
        assertEq(ace.orderCount(id), 1, "one post, one entry");
        _postDefault();
        _postDefault();
        assertEq(ace.orderCount(id), 3, "three posts, three entries");

        vm.prank(maker);
        ace.closeOrder(a, maker);
        assertEq(ace.orderCount(id), 3, "a close removes nothing");

        Order memory o = ace.orderOf(ace.marketOrders(id, 1, 1)[0]);
        _fill(ace.marketOrders(id, 1, 1)[0], o.principal, o.collateralUnits);
        assertEq(ace.orderCount(id), 3, "and neither does exhaustion");
    }

    /// @notice The page is oldest-first, in post order, and the ids are the ones `postOrder` returned.
    function test_marketOrders_PagesInPostOrder() public {
        uint256 a = _postDefault();
        uint256 b = _postDefault();
        uint256 c = _postDefault();

        uint256[] memory page = ace.marketOrders(id, 0, 10);

        assertEq(page.length, 3, "the whole list came back");
        assertEq(page[0], a, "oldest first");
        assertEq(page[1], b, "then the second");
        assertEq(page[2], c, "then the newest");
    }

    /// @notice `limit` CLAMPS silently, so a short page is not the end of the list.
    function test_marketOrders_LimitClampsSilently() public {
        _postDefault();
        _postDefault();
        _postDefault();

        assertEq(ace.marketOrders(id, 0, 2).length, 2, "a limit under the length clamps to the limit");
        assertEq(ace.marketOrders(id, 1, 2).length, 2, "and does so from an offset too");
        assertEq(ace.marketOrders(id, 0, type(uint256).max).length, 3, "a limit over the length clamps to the length");
        assertEq(ace.marketOrders(id, 2, 10).length, 1, "and the tail page is short without being empty");
    }

    /// @notice An offset past the end returns EMPTY rather than reverting; batched multicalls rest on it.
    function test_marketOrders_OffsetPastTheEndIsEmpty() public {
        _postDefault();
        _postDefault();

        assertEq(ace.marketOrders(id, 2, 10).length, 0, "exactly at the end is empty");
        assertEq(ace.marketOrders(id, 99, 10).length, 0, "and far past it is too");
        assertEq(ace.marketOrders(id, type(uint256).max, 10).length, 0, "and so is the extreme");
    }

    /// @notice A CLOSED order stays in the array, at the same index, for good.
    /// @dev Removal is what makes two ledgers disagree across an external call, which is why `Market.openedLoans` refuses it.
    function test_marketOrders_AClosedOrderStaysInTheArray() public {
        uint256 a = _postDefault();
        uint256 b = _postDefault();

        vm.prank(maker);
        ace.closeOrder(a, maker);

        uint256[] memory page = ace.marketOrders(id, 0, 10);
        assertEq(page.length, 2, "the closed order still occupies its entry");
        assertEq(page[0], a, "at its original index");
        assertEq(page[1], b, "so the newer order did not shift");
        assertTrue(ace.orderOf(a).closed, "guard: it really is closed, so this is not a stale read");
    }

    /// @notice The loan mirror, asserted rather than assumed: the two enumerations behave the same way.
    function test_marketLoans_MirrorsTheOrderEnumeration() public {
        uint256 orderId = _postDefault();
        Order memory o = ace.orderOf(orderId);
        _fill(orderId, MINFILL, _proRata(o, MINFILL));
        Order memory rest = ace.orderOf(orderId);
        _fill(orderId, rest.principal, rest.collateralUnits);

        assertEq(ace.marketLoansLength(id), 2, "two fills, two loans");
        assertEq(ace.marketLoans(id, 0, 1).length, 1, "limit clamps on the loan page too");
        assertEq(ace.marketLoans(id, 2, 10).length, 0, "an offset at the end is empty on the loan page too");
        assertEq(ace.marketLoans(id, 0, type(uint256).max).length, 2, "and an over-large limit clamps to the length");
        assertEq(ace.orderCount(id), 1, "and the order enumeration is separate: one post, whatever the fills did");
    }
}
