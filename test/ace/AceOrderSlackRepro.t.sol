// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BelowCoverageLine, Borrower, InsufficientCash, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {FillBelowMin, FillOverCollateralized, FillOverOrder, FillUnderCollateralized, Orders, RemainderBelowMin} from "../../src/ace/hub/Orders.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Cfg, MarketParams, Order} from "../../src/ace/hub/Types.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceOrderSlackRepro
/// @notice Octane 2026-10-05 #17: `Orders.collateralFor` escrowed `requiredAt(D) + floor(D / minFill)`, one atom per possible fill.
/// @notice Each fill opens a loan needing `ceil(x * r) + 1`, and the band floors its pro-rata share of the REMAINING escrow.
/// @notice So that slack paid for N coverage atoms and not for N per-fill ceilings, and the floor made it bite on ONE fill.
/// @notice The escrow now reserves `ceil(2D / minFill)` atoms when the order can split, and one atom when it can only fill whole.
/// @notice The `test_RED_*` rows were written RED against the old formula and turned green with the fix; the names stay as the record.
/// @dev Every escrow, cap and line below is pinned EXACTLY to the fixed formula; the old values ride along in the labels.
/// @dev Each row asserts its fills FIRST and its exact figures LAST, so a broken slack reports the refusal rather than a number.
/// @dev Recordless markets throughout, so the funding floor is `MarketParams.price` and no cap can refuse first.
abstract contract AceOrderSlackBase is WarpClock {
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);

    uint64 internal constant TEN = ProtocolPolicy.MIN_TENOR;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant K = 1.4e18;

    /// @dev One market and its two tokens; each row builds its own, since price, k and minDebt are write-once.
    struct Rig {
        AceFixtures.Deployment d;
        MockERC20 quote;
        MockERC20 coll;
    }

    function setUp() public virtual {
        _warpTo(1_000_000);
    }

    /// @dev A fresh recordless market at `price`, its lender's ladder rested, the maker funded and approved.
    function _rig(uint8 qd, uint8 cd, uint256 price, uint256 minDebt, uint256 ladder) internal returns (Rig memory r) {
        r.quote = new MockERC20("Quote", "Q", qd);
        r.coll = new MockERC20("Collateral", "C", cd);
        MarketParams memory p = AceFixtures.marketParams(address(r.quote), address(r.coll));
        p.price = price;
        p.minCoverageWad = K;
        p.minDebt = minDebt;
        r.d = AceFixtures.deploy(p);

        r.quote.mint(AceFixtures.LENDER, ladder);
        vm.startPrank(AceFixtures.LENDER);
        r.quote.approve(address(r.d.ace), ladder);
        r.d.ace.deposit(r.d.id, ladder);
        vm.stopPrank();

        r.coll.mint(maker, type(uint128).max);
        vm.prank(maker);
        r.coll.approve(address(r.d.positionManager), type(uint256).max);
    }

    /// @dev The market's config cache, rebuilt from public reads so the coverage oracle needs no hub internals.
    function _cfg(Rig memory r) internal view returns (Cfg memory c) {
        c.p = r.d.ace.idToMarketParams(r.d.id);
        c.unitScale = r.d.read.marketState(r.d.id).unitScale;
    }

    function _post(Rig memory r, uint256 principal, uint256 liqLow, uint256 liqHigh, uint256 minFill) internal returns (uint256) {
        vm.prank(maker);
        return r.d.ace.postOrder(r.d.id, principal, liqLow, liqHigh, minFill, TEN, uint64(_now() + 30 days));
    }

    /// @dev The largest take the band's low leg admits: `floor(U_rem * x / D_rem)`, the remaining escrow's own ratio.
    function _proRata(Order memory o, uint256 principalOut) internal pure returns (uint256) {
        return (o.collateralUnits * principalOut) / o.principal;
    }

    /// @dev The verb reached raw, so its refusal is data the row can name rather than a test failure.
    function _tryFill(Rig memory r, uint256 orderId, uint256 pOut, uint256 uOut) internal returns (bool landed, bytes4 sel) {
        vm.prank(filler);
        (bool ok, bytes memory ret) = address(r.d.ace).call(abi.encodeCall(Ace.fillOrder, (orderId, pOut, uOut)));
        if (ok || ret.length < 4) return (ok, bytes4(0));
        sel = bytes4(ret[0]) | (bytes4(ret[1]) >> 8) | (bytes4(ret[2]) >> 16) | (bytes4(ret[3]) >> 24);
    }

    /// @dev A refusal's name, so a failing row's line says which leg refused without a trace.
    function _name(bytes4 s) internal pure returns (string memory) {
        if (s == BelowCoverageLine.selector) return "BelowCoverageLine";
        if (s == FillOverCollateralized.selector) return "FillOverCollateralized";
        if (s == FillUnderCollateralized.selector) return "FillUnderCollateralized";
        if (s == TriggerAboveFloor.selector) return "TriggerAboveFloor";
        if (s == FillBelowMin.selector) return "FillBelowMin";
        if (s == RemainderBelowMin.selector) return "RemainderBelowMin";
        if (s == FillOverOrder.selector) return "FillOverOrder";
        if (s == InsufficientCash.selector) return "InsufficientCash";
        if (s == bytes4(0)) return "none";
        return vm.toString(bytes32(s));
    }

    /// @dev The failure line: which leg refused a legal fill at the pro-rata cap, and the two numbers that decide it.
    function _refusal(string memory why, bytes4 sel, uint256 cap, uint256 line) internal pure returns (string memory) {
        return string.concat(why, "; refused by ", _name(sel), ": pro-rata cap ", vm.toString(cap), " vs coverage line ", vm.toString(line));
    }
}

/// @title AceOrderSlackReproTest
/// @notice The two worked examples from the triage, a 0-decimal-collateral row, and the shape that pins the slack's tightness.
contract AceOrderSlackReproTest is AceOrderSlackBase {
    uint256 internal constant EX1_PRICE = 3 * Q96; // a 6-decimal collateral worth 3.0 against a 6-decimal quote
    uint256 internal constant EX1_D = 10_000e6;
    uint256 internal constant EX1_HALF = 5_000e6; // the maker's floor, so exactly two fills: D == 2m
    uint256 internal constant EX2_PRICE = 2 * Q96; // r = 0.7 exactly at k 1.4
    uint256 internal constant EX2_D = 14_500_000_008; // not a multiple of the floor
    uint256 internal constant EX2_MIN = 5_000_000_003; // the maker's floor on one fill
    uint256 internal constant EX2_FIRST = 9_500_000_005; // leaves exactly EX2_MIN behind
    uint256 internal constant ZD_PRICE = 1e10 * Q96; // 10,000e6 quote atoms per 0-decimal collateral unit

    /// @notice Example 1: a maker set `minFill` to half and no half fill existed at all.
    /// @notice 6/6 decimals at 3.0, k 1.4: the old escrow 4,666,666,669 capped a half at 2,333,333,334 against a line of 2,333,333,335.
    /// @notice Fixed: the escrow is 4,666,666,671, the half cap lands EXACTLY on the line, and the other half clears it by one.
    /// @dev Cap equals line here, so this row is one of the suite's equality pins on the coverage check's `<`.
    function test_RED_AnExactHalfFillAtTheFloorRefuses() public {
        Rig memory r = _rig(6, 6, EX1_PRICE, 5_000e6, 100_000e6);
        Cfg memory c = _cfg(r);

        assertEq(Borrower.requiredAt(c, EX1_D, EX1_PRICE), 4_666_666_667, "PREMISE: requiredAt(10_000e6) at 3.0 is ceil(1.4e10 / 3)");
        uint256 line = Borrower.coverageLine(c, EX1_HALF, EX1_PRICE);
        assertEq(line, 2_333_333_335, "PREMISE: a half fill's coverage line is ceil(7e9 / 3) + 1");

        uint256 orderId = _post(r, EX1_D, EX1_PRICE, EX1_PRICE, EX1_HALF);
        Order memory o = r.d.ace.orderOf(orderId);
        emit log_named_uint("escrow U (old formula: 4,666,666,669)", o.collateralUnits);
        _assertTheWholeFillOpens(r, orderId, o);

        uint256 cap = _proRata(o, EX1_HALF);
        _assertOneOverTheCapIsTheBands(r, orderId, EX1_HALF, cap);

        (bool landed, bytes4 sel) = _tryFill(r, orderId, EX1_HALF, cap);
        assertTrue(landed, _refusal("a legal half fill at the pro-rata cap opens", sel, cap, line));
        Order memory rest = r.d.ace.orderOf(orderId);
        (landed, sel) = _tryFill(r, orderId, rest.principal, rest.collateralUnits);
        assertTrue(landed, _refusal("and the other half opens, whole", sel, rest.collateralUnits, line));

        assertEq(o.collateralUnits, 4_666_666_671, "the escrow is requiredAt + ceil(2D / m) = 4,666,666,667 + 4");
        assertEq(cap, line, "the half cap lands exactly on the line: 2,333,333,335, no atom to spare");
        assertEq(rest.collateralUnits, 2_333_333_336, "and the other half keeps one atom over its line");
    }

    /// @dev CONTROL, in a snapshot: the whole order fills in one piece, so the escrow is never short in aggregate.
    function _assertTheWholeFillOpens(Rig memory r, uint256 orderId, Order memory o) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(filler);
        uint256 loanId = r.d.ace.fillOrder(orderId, o.principal, o.collateralUnits);
        assertEq(r.d.read.loan(loanId).debt, o.principal, "CONTROL: the whole fill opens, so the escrow is not short in aggregate");
        vm.revertToState(snap);
    }

    /// @dev The upper endpoint: one unit over the pro-rata cap is the band's low leg, whatever the slack.
    function _assertOneOverTheCapIsTheBands(Rig memory r, uint256 orderId, uint256 pOut, uint256 cap) internal {
        (bool overLanded, bytes4 overSel) = _tryFill(r, orderId, pOut, cap + 1);
        assertFalse(overLanded, "one unit over the pro-rata cap never lands");
        assertEq(overSel, FillOverCollateralized.selector, "and it is the band's low leg that refuses it");
    }

    /// @notice Example 2: a filler takes the band's maximum on a first fill, which is the safest loan for a lender-filler.
    /// @notice The remainder is then EXACTLY `minFill`, so the only legal fill is the whole remainder.
    /// @notice Old: escrow 10,150,000,008, greedy 6,650,000,005, remainder 3,500,000,003 against a line of 3,500,000,004.
    /// @notice Fixed: escrow 10,150,000,012, greedy 6,650,000,007, remainder 3,500,000,005, which clears the line.
    /// @dev At 2.0 and k 1.4, `r = 0.7` exactly, so every requirement here is a decimal the reader can check by hand.
    function test_RED_AGreedyFillNeverStrandsALegalRemainder() public {
        Rig memory r = _rig(6, 6, EX2_PRICE, 5_000e6, 100_000e6);
        Cfg memory c = _cfg(r);

        assertEq(Borrower.requiredAt(c, EX2_D, EX2_PRICE), 10_150_000_006, "PREMISE: requiredAt(D) is ceil(10,150,000,005.6)");
        assertEq(EX2_D / EX2_MIN, 2, "PREMISE: the order can split, so it reserves ceil(2D / m) = 6 atoms");

        uint256 orderId = _post(r, EX2_D, EX2_PRICE, EX2_PRICE, EX2_MIN);
        Order memory o = r.d.ace.orderOf(orderId);
        emit log_named_uint("escrow U (old formula: 10,150,000,008)", o.collateralUnits);

        uint256 greedy = _proRata(o, EX2_FIRST);
        assertGe(greedy, Borrower.coverageLine(c, EX2_FIRST, EX2_PRICE), "PREMISE: the greedy first fill clears its own coverage line");
        vm.prank(filler);
        r.d.ace.fillOrder(orderId, EX2_FIRST, greedy);

        Order memory rest = r.d.ace.orderOf(orderId);
        assertEq(rest.principal, EX2_MIN, "PREMISE: the remainder is exactly the maker's floor");
        uint256 line = Borrower.coverageLine(c, rest.principal, EX2_PRICE);
        assertEq(line, 3_500_000_004, "PREMISE: the remainder's coverage line is ceil(3,500,000,002.1) + 1");
        _assertOnlyTheWholeRemainderIsLegal(r, orderId, rest);
        _assertCloseReturnsTheRest(r, orderId, rest.collateralUnits);

        (bool landed, bytes4 sel) = _tryFill(r, orderId, rest.principal, rest.collateralUnits);
        assertTrue(landed, _refusal("the only legal fill of the remainder opens", sel, rest.collateralUnits, line));

        assertEq(o.collateralUnits, 10_150_000_012, "the escrow is requiredAt + ceil(2D / m) = 10,150,000,006 + 6");
        assertEq(greedy, 6_650_000_007, "the greedy first take is floor(U * 9,500,000,005 / D)");
        assertEq(rest.collateralUnits, 3_500_000_005, "the remaining escrow (old formula: 3,500,000,003)");
    }

    /// @dev Anything under the whole remainder is under the maker's floor, so the whole remainder is the only legal fill.
    function _assertOnlyTheWholeRemainderIsLegal(Rig memory r, uint256 orderId, Order memory rest) internal {
        (bool small, bytes4 smallSel) = _tryFill(r, orderId, rest.principal - 1, rest.collateralUnits);
        assertFalse(small, "PREMISE: a fill one atom under the whole remainder never lands");
        assertEq(smallSel, FillBelowMin.selector, "PREMISE: it is refused by the maker's floor, so only the whole remainder is legal");
    }

    /// @dev CONTROL, in a snapshot: the maker's close returns every unit still escrowed, so nothing is locked.
    function _assertCloseReturnsTheRest(Rig memory r, uint256 orderId, uint256 units) internal {
        uint256 snap = vm.snapshotState();
        uint256 makerBefore = r.coll.balanceOf(maker);
        vm.prank(maker);
        uint256 returned = r.d.ace.closeOrder(orderId, maker);
        assertEq(returned, units, "CONTROL: the maker's close returns every unit still escrowed");
        assertEq(r.coll.balanceOf(maker) - makerBefore, units, "CONTROL: and delivers it");
        vm.revertToState(snap);
    }

    /// @notice Whole-unit collateral, the NFT/RWA regime: a 6-decimal quote against a 0-decimal unit worth 10,000.
    /// @notice The band's low end sits 5% under the price, so this is not the max-leverage corner.
    /// @notice Old: 15 + 4 = 19 units, a quarter cap of 4 against a line of 5. Fixed: 15 + 8 = 23, a quarter cap of 5 ON the line.
    /// @dev `D * r` at the price is exactly 14 units; at the low end it is 14.74, so `requiredAt` is 15 there.
    /// @dev Cap equals line here too: the second of the suite's equality pins on the coverage check's `<`.
    function test_RED_ZeroDecimalCollateralAQuarterFillRefusesWithTheBandBelowThePrice() public {
        uint256 low = (ZD_PRICE * 95) / 100;
        uint256 principal = 100_000e6;
        uint256 quarter = 25_000e6;
        Rig memory r = _rig(6, 0, ZD_PRICE, 5_000e6, 1_000_000e6);
        Cfg memory c = _cfg(r);

        assertEq(Borrower.requiredAt(c, principal, ZD_PRICE), 14, "PREMISE: the whole order needs exactly 14 units at the price");
        assertEq(Borrower.requiredAt(c, principal, low), 15, "PREMISE: and ceil(14.74) = 15 at the band's low end");
        uint256 line = Borrower.coverageLine(c, quarter, ZD_PRICE);
        assertEq(line, 5, "PREMISE: a quarter fill's coverage line is ceil(3.5) + 1");

        uint256 orderId = _post(r, principal, low, ZD_PRICE, quarter);
        Order memory o = r.d.ace.orderOf(orderId);
        uint256 cap = _proRata(o, quarter);
        _assertOneOverTheCapIsTheBands(r, orderId, quarter, cap);

        (bool landed, bytes4 sel) = _tryFill(r, orderId, quarter, cap);
        assertTrue(landed, _refusal("a legal quarter fill at the pro-rata cap opens", sel, cap, line));

        assertEq(o.collateralUnits, 23, "the escrow is requiredAt at the low end + ceil(2D / m) = 15 + 8 (old formula: 19)");
        assertEq(cap, line, "the quarter cap lands exactly on the line: 5 units, none to spare");
    }

    /// @notice An all-or-nothing order on whole units escrows exactly what a direct open of the same loan must hold.
    /// @notice It can only fill whole, so the slack is the line's one atom, and it pays no unit for a split it cannot make.
    function test_AllOrNothingEscrowIsTheLoansOwnCoverageLine() public {
        uint256 principal = 100_000e6;
        Rig memory r = _rig(6, 0, ZD_PRICE, 5_000e6, 1_000_000e6);
        Cfg memory c = _cfg(r);

        uint256 orderId = _post(r, principal, ZD_PRICE, ZD_PRICE, principal);
        Order memory o = r.d.ace.orderOf(orderId);
        uint256 line = Borrower.coverageLine(c, principal, ZD_PRICE);

        (bool landed, bytes4 sel) = _tryFill(r, orderId, principal, o.collateralUnits);
        assertTrue(landed, _refusal("the whole fill opens on the escrow", sel, o.collateralUnits, line));

        assertEq(o.collateralUnits, line, "the escrow IS the loan's coverage line: 14 + 1 units");
        assertEq(o.collateralUnits, 15, "fifteen whole units");
    }

    /// @notice TIGHTNESS: a shape where a minimum fill at its cap lands ON its line, so one atom less slack would refuse it.
    /// @notice D = 25,000,000,000 = 2m + rho with m = 10,000,000,003 and rho = 4,999,999,994, just under m/2; at 2.0, `D * r` is exactly 17.5e9.
    /// @notice `ceil(2D / m) = 5`: escrow 17,500,000,005, and a minimum fill's cap is floor(7,000,000,004.1) = 7,000,000,004 = its line.
    /// @dev With a slack of 4 the cap is floor(7,000,000,003.7) and the fill refuses: the fixed slack is the least that clears this shape.
    /// @dev Built to the four conditions: two fills fit, `D mod m` sits just under `m/2`, `frac(m * r)` is 0.1, and `D * r` is an integer.
    function test_ASlackOneAtomShortWouldRefuseThisMinimumFill() public {
        uint256 principal = 25_000_000_000;
        uint256 minFill = 10_000_000_003;
        Rig memory r = _rig(6, 6, EX2_PRICE, 5_000e6, 100_000e6);
        Cfg memory c = _cfg(r);

        assertEq(Borrower.requiredAt(c, principal, EX2_PRICE), 17_500_000_000, "PREMISE: D * r is exactly 17.5e9, so the total's ceiling adds nothing");
        uint256 line = Borrower.coverageLine(c, minFill, EX2_PRICE);
        assertEq(line, 7_000_000_004, "PREMISE: a minimum fill's line is ceil(7,000,000,002.1) + 1");

        uint256 orderId = _post(r, principal, EX2_PRICE, EX2_PRICE, minFill);
        Order memory o = r.d.ace.orderOf(orderId);
        uint256 cap = _proRata(o, minFill);

        (bool landed, bytes4 sel) = _tryFill(r, orderId, minFill, cap);
        assertTrue(landed, _refusal("a minimum fill at its cap opens", sel, cap, line));
        Order memory rest = r.d.ace.orderOf(orderId);
        (landed, sel) = _tryFill(r, orderId, rest.principal, rest.collateralUnits);
        assertTrue(landed, _refusal("and the whole remainder opens after it", sel, rest.collateralUnits, Borrower.coverageLine(c, rest.principal, EX2_PRICE)));

        assertEq(o.collateralUnits, 17_500_000_005, "the escrow is 17.5e9 + ceil(2D / m) = 17.5e9 + 5");
        assertEq(cap, line, "the minimum fill's cap lands exactly on its line");
    }
}

/// @title AceOrderSlackFuzzTest
/// @notice The fix's acceptance property: at ANY point in ANY legal fill sequence, a fill at the pro-rata cap opens.
/// @notice A legal fill is one at or over `minFill` that leaves zero or at least `minFill`; the cap is the most collateral the band admits.
/// @notice It was RED against the old formula at its 28th run; the two pinned rows below are the counterexamples it found.
/// @dev Domain: both decimals in [0, 18] with 0-decimal collateral forced on a quarter of runs; a human price in [0.01, 10,000].
/// @dev The low end is the price itself on half the runs and anywhere in [P/2, P] on the rest; the high end is the low end, rigid.
/// @dev Fills are biased to `minFill`, where the per-fill share of the slack is smallest; up to four fills per order.
/// @dev A fuzz row is a sampler, never a guard: the deterministic rows pin the counterexamples it exists to find.
contract AceOrderSlackFuzzTest is AceOrderSlackBase {
    /// @dev The fuzzed order's shape, bundled to keep the body under the stack limit.
    struct Shape {
        uint8 qd;
        uint8 cd;
        uint256 price;
        uint256 low;
        uint256 minDebt;
        uint256 principal;
        uint256 minFill;
    }

    function testFuzz_RED_EveryLegalFillIsAdmittedAtTheProRataCap(
        uint256 decSeed,
        uint256 priceSeed,
        uint256 lowSeed,
        uint256 principalSeed,
        uint256 minFillSeed,
        uint256 seqSeed
    ) public {
        _everyLegalFillLands(decSeed, priceSeed, lowSeed, principalSeed, minFillSeed, seqSeed);
    }

    /// @notice The fuzzer's first counterexample against the old formula, pinned so it survives a seed that stops finding it.
    /// @dev 14-decimal quote, 18-decimal collateral, low end at the price: fine collateral was hit too, at maximum leverage.
    function test_RED_FuzzCounterexampleAtSeedOne() public {
        _everyLegalFillLands(
            698952268459751886590533625587962006031116252936756861592834538,
            149882706624212818643829720182,
            146951840639585222416790312064683355078224293648662772554775179084,
            2850925501977310,
            508577854945761071244552139854,
            90175
        );
    }

    /// @notice A shape where `D` is not a multiple of `minFill`: a slack of `2 * floor(D / m) - 1` atoms leaves a min fill one atom short.
    /// @dev Found by the fuzz row with the escrow's slack temporarily set to `2N - 1`; `ceil(2D / minFill)` clears it.
    function test_RED_FuzzCounterexampleThatRefutesATwoNMinusOneSlack() public {
        _everyLegalFillLands(
            3258194976061, 34360511, 20265462147292086473320370060, 11709374391996842041440644053428769897700382809580, 65592394296890, 6129072
        );
    }

    /// @dev The property body, shared by the fuzz row and its pinned counterexamples.
    function _everyLegalFillLands(uint256 decSeed, uint256 priceSeed, uint256 lowSeed, uint256 principalSeed, uint256 minFillSeed, uint256 seqSeed) internal {
        Shape memory s = _shape(decSeed, priceSeed, lowSeed, principalSeed, minFillSeed);
        emit log_named_uint("quote decimals", s.qd);
        emit log_named_uint("collateral decimals", s.cd);
        emit log_named_uint("price", s.price);
        emit log_named_uint("band low end", s.low);
        emit log_named_uint("principal", s.principal);
        emit log_named_uint("minFill", s.minFill);
        Rig memory r = _rig(s.qd, s.cd, s.price, s.minDebt, 2 * s.principal);
        uint256 orderId = _post(r, s.principal, s.low, s.low, s.minFill);

        for (uint256 k; k < 4; k++) {
            Order memory o = r.d.ace.orderOf(orderId);
            if (o.principal == 0) break;
            uint256 x = _legalPrincipal(o, seqSeed, k);
            uint256 u = _proRata(o, x);
            uint256 line = Borrower.coverageLine(_cfg(r), x, s.price);
            (bool landed, bytes4 sel) = _tryFill(r, orderId, x, u);
            assertTrue(landed, _refusal(string.concat("a legal fill of ", vm.toString(x), " at the pro-rata cap opens"), sel, u, line));
        }
    }

    /// @dev The decimals pick the pair's frame, the human price is mapped into it, and every principal is named in whole quote units.
    function _shape(uint256 decSeed, uint256 priceSeed, uint256 lowSeed, uint256 principalSeed, uint256 minFillSeed) internal returns (Shape memory s) {
        s.qd = uint8(bound(decSeed % 19, 0, 18));
        s.cd = (decSeed >> 8) % 4 == 0 ? 0 : uint8(bound((decSeed >> 16) % 19, 0, 18));
        MockERC20 q = new MockERC20("Q", "Q", s.qd);
        MockERC20 cl = new MockERC20("C", "C", s.cd);
        s.price = AceFixtures.px(bound(priceSeed, 1e16, 1e22), address(q), address(cl));
        s.low = lowSeed % 2 == 0 ? s.price : bound(lowSeed >> 1, s.price / 2, s.price);
        uint256 one = 10 ** s.qd;
        s.minDebt = 100 * one;
        s.principal = bound(principalSeed, s.minDebt, 1_000_000 * one);
        s.minFill = bound(minFillSeed, s.minDebt, s.principal);
    }

    /// @dev A legal principal: `minFill` on odd draws, else anywhere legal; a sub-floor remainder is folded into the fill.
    function _legalPrincipal(Order memory o, uint256 seed, uint256 k) internal pure returns (uint256 x) {
        uint256 h = uint256(keccak256(abi.encode(seed, k)));
        uint256 m = o.minFillPrincipal;
        x = h % 2 == 1 ? m : m + ((h >> 1) % (o.principal - m + 1));
        if (o.principal - x < m) x = o.principal;
    }
}

/// @notice `Orders.collateralFor` reached through an external call, so a sizing refusal is data a fuzz row can skip.
contract OrderSlackSizingHarness {
    function size(uint256 coverage, uint256 principal, uint256 price, uint256 minFill) external pure returns (uint256) {
        Cfg memory c;
        c.p.minCoverageWad = coverage;
        c.unitScale = 1 << 96;
        return Orders.collateralFor(c, principal, price, minFill);
    }
}

/// @title AceOrderSlackSizingTest
/// @notice The escrow figure itself, off the hub: exact pins on both arms of the slack, and a full-width fuzz of the first fill.
/// @dev Every requirement is read off `Borrower.requiredAt` / `coverageLine`, the functions the hub's own doors call.
contract AceOrderSlackSizingTest is Test {
    OrderSlackSizingHarness internal h = new OrderSlackSizingHarness();
    uint256 internal constant Q = 1 << 96;
    uint256 internal constant LIMIT = type(uint256).max / 1e18;
    uint256 internal constant K = 1.4e18;

    /// @dev The one fixed shape the exact pins share: 3.0 at k 1.4, where a principal of `d` needs `ceil(1.4d / 3)` atoms.
    uint256 internal constant P3 = 3 * Q;

    function _required(uint256 principal) internal pure returns (uint256) {
        return Borrower.requiredAt(K, Q, principal, P3);
    }

    /// @notice An all-or-nothing order can only fill whole, so it reserves the line's one atom.
    function test_Pin_AllOrNothingSizesToRequiredPlusOne() public view {
        assertEq(h.size(K, 10_000e6, P3, 10_000e6), _required(10_000e6) + 1, "minFill == principal: requiredAt + 1");
    }

    /// @notice One atom under two minimum fills is still whole-only: a partial would strand a sub-floor remainder.
    function test_Pin_OneUnderTwoMinimumFillsSizesToRequiredPlusOne() public view {
        uint256 m = 5_000e6;
        assertEq(h.size(K, 2 * m - 1, P3, m), _required(2 * m - 1) + 1, "principal == 2m - 1: requiredAt + 1");
    }

    /// @notice Exactly two minimum fills is the first splittable order, and it reserves two atoms per minimum fill.
    function test_Pin_TwoMinimumFillsSizesToRequiredPlusFour() public view {
        uint256 m = 5_000e6;
        assertEq(h.size(K, 2 * m, P3, m), _required(2 * m) + 4, "principal == 2m: requiredAt + ceil(4m / m) = + 4");
    }

    /// @notice Example 1's shape, off the hub: 4,666,666,667 + 4.
    function test_Pin_ExampleOneSizesTo4666666671() public view {
        assertEq(h.size(K, 10_000e6, P3, 5_000e6), 4_666_666_671, "the example-1 escrow");
    }

    /// @notice FULL WIDTH: the first minimum fill at its cap, and the whole remainder after it, clear their coverage lines.
    /// @notice A whole-only order (`D < 2m`) holds at least the whole loan's line.
    /// @dev Coverage over [1.05, 20], both price branches including above `max / 1e18`, the low end in [P/2, P], sizes log-spread.
    /// @dev Inputs the sizing refuses are skipped: the rail's own refusals are `AceInputRefusals`' job, not this row's.
    /// @dev It checks the FIRST step of any sequence; the hub fuzz above and the split-order campaign cover longer ones.
    /// @dev The cap's trigger is also held at or under the low end, which is what keeps the band's high leg and the floor gate quiet.
    function testFuzz_SizingClearsTheMinimumFillAtTheCap(
        uint256 coverage,
        uint256 priceSeed,
        uint256 shift,
        bool highBranch,
        uint256 lowSeed,
        uint256 dSeed,
        uint256 mSeed
    ) public view {
        Shape memory s;
        s.coverage = bound(coverage, 1.05e18, 20e18);
        s.price = highBranch ? bound(priceSeed >> (shift % 60), LIMIT + 1, type(uint256).max) : bound(priceSeed >> (shift % 256), 1, LIMIT);
        s.low = bound(lowSeed, s.price / 2 == 0 ? 1 : s.price / 2, s.price);
        s.d = bound(dSeed >> ((dSeed >> 248) % 256), 1, type(uint256).max / s.coverage);
        s.m = bound(mSeed >> ((mSeed >> 248) % 256), 1, s.d);
        try h.size(s.coverage, s.d, s.low, s.m) returns (uint256 u) {
            _assertFirstFillClears(s, u);
        } catch {}
    }

    /// @dev One sized order: coverage, market price, band low end, principal and minimum fill.
    struct Shape {
        uint256 coverage;
        uint256 price;
        uint256 low;
        uint256 d;
        uint256 m;
    }

    /// @dev The fuzz row's assertions, in their own frame (stack).
    function _assertFirstFillClears(Shape memory s, uint256 u) internal pure {
        if (s.d < 2 * s.m) {
            assertGe(u, Borrower.coverageLine(s.coverage, Q, s.d, s.price), "a whole-only order holds its whole loan's line");
            return;
        }
        uint256 cap = FullMath.mulDiv(u, s.m, s.d);
        assertGe(cap, Borrower.coverageLine(s.coverage, Q, s.m, s.price), "the first minimum fill at its cap clears its line");
        assertLe(LoanMath.triggerPrice(s.m, cap, s.coverage, Q), s.low, "and triggers at or under the band's low end");
        assertGe(u - cap, Borrower.coverageLine(s.coverage, Q, s.d - s.m, s.price), "and the whole remainder after it clears its own line");
    }
}
