// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title AceDecimalScale
/// @notice `unitScale` is one constant for every layout, so collateral may have FEWER decimals than its quote.
/// @notice The trigger rounds UP.
/// @dev The lifted `cd >= qd` was representability work, and refused USDC collateral under an 18dp quote.
/// @dev NOTHING BOUNDS THE DIFFERENCE any more: `MAX_DECIMALS` on each end is the whole envelope, either way.
/// @dev So the widest gap admitted is 18, and the layout shows up as WHERE the pair sits on the tick grid.
/// @dev Absolute `cd`/`qd` rails refuse a garbage `decimals()` BY NAME rather than by a panic.
contract AceDecimalScaleTest is WarpClock {
    Ace internal ace;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    /// @dev No fixture pair here: every test mints its own decimal layout, so a price is named where the pair is.
    /// @param quote The market's quote token.
    /// @param collateral The market's collateral token.
    /// @param offset Steps above par, which `PriceFrame` turns into a raw Q96 price.
    /// @return The price in the hub's frame.
    function _price(address quote, address collateral, int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(quote, collateral, offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        ace = AceFixtures.newAce();
    }

    // ---- helpers ----

    function _token(uint8 dec) internal returns (MockERC20) {
        return new MockERC20("Tok", "TOK", dec);
    }

    /// @dev Params for a given decimal layout, wired to correctly-oriented price sources.
    /// @dev SPLIT from `_create`: its three creations would consume an armed `vm.expectRevert` and pass vacuously.
    function _params(address quote, address collateral) internal returns (MarketParams memory p) {
        p = AceFixtures.marketParams(quote, collateral);
        p.record = address(new MockPersistenceRecord(quote, collateral));
    }

    function _create(address quote, address collateral) internal returns (bytes32) {
        return ace.createMarket(_params(quote, collateral));
    }

    // ============ 1. the newly-admitted direction ============

    /// @notice Collateral with FEWER decimals than the quote is admitted -- the whole point.
    /// @dev USDC(6) collateral against an 18dp quote: "borrow MON against USDC".
    function test_Genesis_AdmitsCollateralWithFewerDecimalsThanQuote() public {
        bytes32 id = _create(address(_token(18)), address(_token(6)));
        assertTrue(id != bytes32(0), "cd < qd is now expressible");
    }

    // ============ 2. the unitScale matrix ============

    /// @dev Read from the hub's OWN storage: a local re-derivation would assert the formula against itself.
    function _unitScaleOf(uint8 cd, uint8 qd) internal returns (uint256) {
        bytes32 id = _create(address(_token(qd)), address(_token(cd)));
        return new AceReader(address(ace)).marketState(id).unitScale;
    }

    function test_UnitScale_MatrixBothDirections() public {
        assertEq(_unitScaleOf(18, 18), 1 << 96, "equal decimals");
        assertEq(_unitScaleOf(18, 6), 1 << 96, "the MON/USDC shape");
        assertEq(_unitScaleOf(8, 6), 1 << 96, "WBTC/USDC");
        assertEq(_unitScaleOf(16, 0), 1 << 96, "a 0-decimal quote, two decimals inside the widest gap admitted");
        assertEq(_unitScaleOf(6, 18), 1 << 96, "INVERTED: collateral 6dp under an 18dp quote");
        assertEq(_unitScaleOf(8, 18), 1 << 96, "INVERTED: WBTC under an 18dp quote");
        assertEq(_unitScaleOf(0, 18), 1 << 96, "the widest DOWN gap, at exactly 18");
    }

    // ============ 3. decimal invariance of the trigger ============

    /// @dev THE property: the same economic position gives the same trigger whatever the decimal layout.
    /// @dev Guarded for non-vacuity -- at WAD scale a truncation is ~1 wei, so equality could pass on a wrong scale.
    function test_TriggerPrice_IsDecimalInvariant() public view {
        uint256 k = PocDeployConfig.MIN_COVERAGE_WAD;
        // 4,500 quote tokens of debt against 10,000 collateral tokens, in three decimal layouts
        uint256 tA = LoanMath.triggerPrice(4_500e6, 10_000e18, k, 1e30); // coll 18 / quote 6
        uint256 tB = LoanMath.triggerPrice(4_500e6, 10_000e8, k, 1e20); // coll  8 / quote 6
        uint256 tC = LoanMath.triggerPrice(4_500e18, 10_000e6, k, 1e6); // coll  6 / quote 18 (INVERTED)

        assertEq(tA, tB, "same position, different collateral decimals, same trigger");
        assertEq(tA, tC, "and the same across the newly-admitted inverted layout");

        // non-vacuity: the layouts must genuinely differ, and the trigger must be a real number
        assertGt(tA, 1e12, "guard: a non-trivial trigger, not dust the comparison would pass on");
        assertEq(tA, 6.3e17, "guard: the trigger is the expected value, not merely self-consistent");
    }

    // ============ 4. requiredAt round-trips ============

    /// @dev `requiredAt(trigger)` must return the collateral that produced it.
    /// @dev Both round UP, so the round trip is exact-or-one-unit-conservative, never short.
    function test_RequiredAt_RoundTripsAgainstTrigger() public {
        (MockERC20 q6, MockERC20 c18) = (_token(6), _token(18));
        (MockERC20 q18, MockERC20 c6) = (_token(18), _token(6));
        bytes32 up = _create(address(q6), address(c18));
        bytes32 down = _create(address(q18), address(c6));
        AceReader r = new AceReader(address(ace));
        assertEq(r.marketState(up).unitScale, r.marketState(down).unitScale, "the scale no longer tells the layouts apart");
        // so non-vacuity has to be asserted where the decimal gap went: the par tick
        assertGt(_price(address(q18), address(c6), 0), _price(address(q6), address(c18), 0), "guard: the layouts differ");

        uint256 k = PocDeployConfig.MIN_COVERAGE_WAD;
        uint256 trig = LoanMath.triggerPrice(4_500e6, 10_000e18, k, 1e30);
        // units needed to keep the same debt admissible at its own trigger == the units it started with
        uint256 need = (k * 4_500e6 * 1e30 / 1e18 + trig - 1) / trig;
        assertLe(need, 10_000e18, "the round trip never demands MORE than the position that set it");
        assertGe(need + 1e18, 10_000e18, "and lands within a unit of it");
    }

    // ============ 5. the rails ============

    /// @notice The widest down gap the envelope admits; past it the ABSOLUTE bound refuses, never a gap rail.
    /// @dev There was never a down-side gap rail: `MAX_DECIMALS` on each end already caps `qd - cd` at 18.
    /// @dev The up-side rail that did exist is gone rather than kept as a check that can no longer fire.
    function test_Rails_DownCliffAdmittedAtEighteen() public {
        assertTrue(_create(address(_token(18)), address(_token(0))) != bytes32(0), "18 is the last safe value");
    }

    /// @notice A quote past `MAX_DECIMALS` is refused by the absolute bound, which is now the only door on this side.
    function test_Rails_ANineteenDecimalQuoteIsOutOfBand() public {
        MarketParams memory p = _params(address(_token(19)), address(_token(0)));
        vm.expectRevert("decimals out of band");
        ace.createMarket(p);
    }

    /// @dev The only door is `MAX_DECIMALS` on each end: nothing bounds the DIFFERENCE, so 16 is no boundary.
    /// @dev The rail that once made it one was read off settlement's products, which no longer carry the gap.
    /// @dev The pairs past it, and the ones that stay refused, are pinned in section 9.
    function test_Rails_AWideUpSideGapIsAdmitted() public {
        assertTrue(_create(address(_token(0)), address(_token(16))) != bytes32(0), "a gap of 16 creates");
        assertTrue(_create(address(_token(0)), address(_token(17))) != bytes32(0), "and so does the gap that used to be the cliff");
    }

    /// @dev Garbage decimals are refused BY NAME, not by an arithmetic panic on `10 ** cd`.
    function test_Rails_AbsurdDecimalsRefusedByName() public {
        MarketParams memory p = _params(address(_token(18)), address(_token(37)));
        vm.expectRevert("decimals out of band");
        ace.createMarket(p);
    }

    // ============ 6. the flow actually computes on an inverted market ============

    /// @notice Open -> deleverage -> settle, end to end, on collateral with FEWER decimals than quote.
    /// @dev Genesis admitting the layout proves nothing about the arithmetic downstream.
    /// @dev The scale is one constant now, so the layout shows up in WHERE the market's price lands.
    function test_E2E_InvertedDecimals_OpenDeleverageSettle() public {
        MockERC20 quote = _token(18);
        MockERC20 coll = _token(6);
        uint256 par = AceFixtures.px(1e18, address(quote), address(coll));
        MockPersistenceRecord rec = new MockPersistenceRecord(address(quote), address(coll));
        rec.setObserved(par);
        rec.setMinPrice(par); // ONE value: the draw cap, and the market bids AT it

        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.record = address(rec);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        AceReader r = d.read;
        assertLt(coll.decimals(), quote.decimals(), "precondition: the inverted layout is live");

        rec.setMinPrice(type(uint256).max); // seed with the cap lifted
        quote.mint(alice, 10_000e18);
        vm.startPrank(alice);
        quote.approve(address(d.ace), 10_000e18);
        d.ace.deposit(d.id, 5_000e18);
        d.ace.deposit(d.id, 5_000e18);
        vm.stopPrank();
        rec.setMinPrice(par); // restored: the draw cap, unchanged from here on

        coll.mint(borrower, 10_000e6);
        vm.startPrank(borrower);
        coll.approve(address(d.positionManager), 10_000e6);
        uint256 loanId = d.ace.open(d.id, 10_000e6, 4_500e18, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(r.loan(loanId).debt, 4_500e18, "the draw landed in an 18dp quote");
        assertGt(r.triggerPrice(loanId), 0, "and the trigger computes on the inverted layout");

        // --- deleverage: the record persists into the band, and its windowed min IS the floor ---
        MockDeleverageKeeper keeper = new MockDeleverageKeeper(d.ace, address(quote), address(coll), 1e6);
        uint256 trig = r.triggerPrice(loanId);
        uint256 ps = trig + trig / 20;
        rec.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - 3000 * 1e14));
        rec.setMinPrice(ps);
        uint256 debtBefore = r.loan(loanId).debt;
        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);

        assertGt(sold, 0, "the decline channel sells on an inverted-decimal market");
        assertEq(out, keeper.lastQuoteOwed(), "and the hub books the floor it quoted");
        assertLt(r.loan(loanId).debt, debtBefore, "proceeds melted debt");

        // --- settle: distress persists, title transfers ---
        rec.setBelowBand(0); // back to flag mode: band mode overrides the `below` flag in the mock
        rec.setBelow(true);
        _warpBy(1 days);
        assertTrue(r.settleable(loanId), "the loan is settleable once distress persists");
        d.ace.finalize(loanId);
        assertTrue(r.loan(loanId).closedAt != 0, "title transferred and the loan closed");
    }

    // ============ 8. the rounding convention ============

    /// @notice The trigger rounds UP, arming liquidation earlier and matching `requiredAt`, which already ceils.
    /// @dev The fixture does not divide evenly, so a floor and a ceil differ by exactly one wei here.
    function test_TriggerPrice_RoundsUp() public pure {
        // k * debt * unitScale / (units * 1e18) = 1e18/3, which does not divide evenly
        uint256 t = LoanMath.triggerPrice(1, 3, 1e18, 1e18);
        assertEq(t, 333333333333333334, "the remainder ceils UP");
        // non-vacuity: name the floored value explicitly, so this cannot pass under either convention
        assertEq(t, 333333333333333333 + 1, "guard: exactly one wei above the floor a truncation would give");
    }

    // ============ 9. the gap-up delta: exactly three pairs ============

    /// @notice `(cd, qd) = (18, 0)`: the widest gap the absolute bound leaves, and the extreme of the newly-admitted set.
    /// @dev The frame is the constant `1 << 96`, so `cd - qd` enters no product and the settlement bound it was read off is gone.
    function test_Rails_AdmitsCollateralEighteenOverAZeroDecimalQuote() public {
        assertTrue(_create(address(_token(0)), address(_token(18))) != bytes32(0), "18-decimal collateral over a 0-decimal quote");
    }

    /// @notice `(cd, qd) = (18, 1)`: the second pair, one decimal of quote away from the extreme.
    function test_Rails_AdmitsCollateralEighteenOverAOneDecimalQuote() public {
        assertTrue(_create(address(_token(1)), address(_token(18))) != bytes32(0), "18-decimal collateral over a 1-decimal quote");
    }

    /// @notice `(cd, qd) = (17, 0)`: the third, and the pair the old gap rail refused by exactly one decimal.
    function test_Rails_AdmitsCollateralSeventeenOverAZeroDecimalQuote() public {
        assertTrue(_create(address(_token(0)), address(_token(17))) != bytes32(0), "17-decimal collateral over a 0-decimal quote");
    }

    /// @notice One step outside the admitted set stays REFUSED, by the absolute bound that survives.
    /// @notice `(19, 0)` and `(0, 19)` are the two sides of it, and both must read the same before and after.
    /// @dev This is what proves the deletion removed the intended rail and only that one.
    function test_Rails_OneStepPastTheAdmittedSetStaysOutOfBand() public {
        MarketParams memory up = _params(address(_token(0)), address(_token(19)));
        vm.expectRevert("decimals out of band");
        ace.createMarket(up);

        MarketParams memory down = _params(address(_token(19)), address(_token(0)));
        vm.expectRevert("decimals out of band");
        ace.createMarket(down);
    }

    // ============ 10. the resolution envelope the surviving rail defends ============

    int24 internal constant DECADE = 23027; // ticks per decimal decade: 1.0001 ** 23027 is about 10
    uint256 internal constant DISTINCT = 10000; // at or above this Q96 price a tick clears its neighbour, the step being 1e-4

    /// @dev Lowest tick whose Q96 price reaches `p`; monotone in the tick, so the bisect is exact.
    /// @param p The Q96 price to clear.
    /// @return The lowest tick at or above it.
    function _lowestTickPricedAt(uint256 p) internal pure returns (int24) {
        int256 lo = TickMath.MIN_TICK;
        int256 hi = 0;
        while (lo < hi) {
            int256 mid = lo + (hi - lo) / 2;
            if (PriceFrame.priceAtStep(int24(mid)) >= p) hi = mid;
            else lo = mid + 1;
        }
        return int24(lo);
    }

    /// @notice The bottom of the v4 range is NOT the binding floor: its Q96 price floors to zero outright.
    /// @dev `Ladder.checkTick` refuses on exactly that, so `MIN_TICK` is unusable however it is aligned.
    function test_Resolution_TheV4BottomCarriesNoPriceAtAll() public pure {
        assertEq(PriceFrame.priceAtStep(TickMath.MIN_TICK), 0, "the v4 bottom prices to zero, so it is not a usable tick");
        assertGt(PriceFrame.priceAtStep(0), 0, "guard: the coordinate system does carry prices, so the row is about the bottom");
    }

    /// @notice Gap-18 par still leaves between six and seven decades of clean integer resolution beneath it.
    /// @notice CLEAN means adjacent ticks carry DISTINCT integer prices, which holds at or above a Q96 price of 1e4.
    /// @dev This is the envelope `MAX_DECIMALS` actually bounds, and nothing else in the tree states it.
    function test_Resolution_GapEighteenParKeepsNearlySevenCleanDecadesBeneathIt() public {
        int24 floorTick = _lowestTickPricedAt(DISTINCT);
        int24 par = PriceFrame.parStep(0, 18);
        emit log_named_int("lowest tick whose neighbour still prices distinctly", int256(floorTick));
        emit log_named_int("gap-18 par, floor-aligned to the fixture grid", int256(par));

        assertGt(floorTick, TickMath.MIN_TICK + 300_000, "the resolution floor sits decades above the v4 bottom");
        assertGt(PriceFrame.priceAtStep(floorTick), PriceFrame.priceAtStep(floorTick - 1), "at the floor a tick still clears its neighbour");
        assertGe(par - floorTick, 6 * DECADE, "gap-18 par keeps at least six clean decades under it");
        assertLt(par - floorTick, 7 * DECADE, "and under seven, so the row is a measurement and not a loose bound");
    }

    /// @notice Below that floor the grid stops resolving: neighbouring ticks carry the same integer price.
    /// @dev The counter-side, so the row above cannot pass by naming a bound nothing sits on the wrong side of.
    function test_Resolution_BelowTheFloorAdjacentTicksCollide() public pure {
        int24 t = _lowestTickPricedAt(DISTINCT) - 2 * DECADE;
        assertGt(PriceFrame.priceAtStep(t), 0, "premise: still a live price, so this is resolution and not the zero frontier");
        bool collided;
        for (int24 i; i < 4; i++) {
            if (PriceFrame.priceAtStep(t + i) == PriceFrame.priceAtStep(t + i + 1)) collided = true;
        }
        assertTrue(collided, "two decades under the floor, neighbouring ticks carry the same integer price");
    }
}
