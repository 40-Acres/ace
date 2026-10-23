// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title AceDeleverageCoverageErosion
/// @notice THE PROPERTY UNDER TEST: an admitted loan that is then DELEVERAGED still covers settlement.
/// @notice `AceCoverageGuarantee` proves the no-sale half; this file is the sale half its header names.
/// @notice IT HOLDS, and these rows were written to prove it did not: the fixtures are unchanged reproductions.
/// @dev THE MECHANISM: settlement CEILS the claim into units, so its requirement floors at ONE ATOM while the claim lives.
/// @dev That floor is a CLAIM-EXISTENCE term, so it stands however small the claim itself gets.
/// @dev `deleverage` sizes against `LoanAccounting.securedBase`, whose CAP is bare `requiredAt`.
/// @dev The cap is proportional to DEBT alone, so it never sees that floor by itself.
/// @dev As the melt shrinks the debt, `requiredAt` falls under that atom while the claim stays live.
/// @dev THE RESERVE IS WHAT CLOSES IT: `securedBase` subtracts `collateralNeeded + sliverUnits` before capping.
/// @dev So a sale can never take an atom settlement is going to need, whatever the cap alone would allow.
/// @dev Both terms are monotone in the debt, so the pre-sale reading bounds every post-sale value.
/// @dev THE GENESIS SELL-MAX RAIL WAS NEVER THE THING HOLDING IT: that rail bounds `u < C` on ONE crank.
/// @dev The route is a SEQUENCE, and the shipped-shape row clears that rail by a wide margin regardless.
/// @dev The rail is pinned separately, for the job it actually does.
/// @dev THE FIXTURES ARE HONEST DECLINES: every crank is armed one wei above the loan's own stop level.
/// @dev `rises` asserts the armed level never moves UP across the sequence.
/// @dev THE FIXTURES SIT AT THE LEAST `minDebt` GENESIS ADMITS: at a real floor `deleverage`'s `minDebt` cap ends the walk first.
/// @dev That would leave the reserve with nothing to guard, so one row pins the cap at a real floor and the rest keep the reserve's subject.
/// @dev WHAT THEY DO NOT MODEL is the persistence WINDOW -- every crank fires at one timestamp here.
/// @dev `AceDeleverageRestoreRace` models the clock and measures the restore rate against a real decline.
contract AceDeleverageCoverageErosionTest is Test, DeleverageCrank {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    bytes32 internal mid;
    uint256 internal unitScale;
    uint256 internal lastPs; // the record level the previous crank was armed at
    uint256 internal rises; // cranks whose armed level sat ABOVE the previous one
    uint256 internal reached; // fuzz runs that got past the fixture and settled a real loan
    uint256 internal firstPs; // the record level the FIRST crank was armed at
    uint256 internal cranksSold; // cranks that actually moved units
    uint256 internal gasSpent; // gas the whole crank sequence burned, which is the extractor's real cost

    uint256 internal constant TENOR = 7 days;
    uint256 internal constant MIN_DEBT_FLOOR = 2; // the least genesis admits: the minDebt cap never ends a decline before the reserve does

    /// @dev One market shape, so a fuzz seed and a hand-written row build through the same door.
    struct Shape {
        uint256 k;
        uint256 eps;
        uint256 cut;
        uint256 band;
        uint256 target;
        uint256 stop;
        uint8 cDec;
        uint8 qDec;
        uint256 lots; // WAS `maxClaimTicks`: the same number, now counting LOTS of cash rather than rungs
        uint256 lot;
        uint256 minDebt;
    }

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function setUp() public {
        vm.warp(1_000_000);
    }

    /* ============================== the fixture ============================== */

    /// @dev A market with the decline channel live at the fuzzed dials, built through `createMarket`.
    /// @dev So genesis itself decides admissibility: nothing here restates a rail the hub already enforces.
    function _market(Shape memory sh, int24 top) internal {
        usdc = new MockERC20("Quote", "Q", sh.qDec);
        coll = new MockERC20("Collateral", "C", sh.cDec);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(type(uint256).max); // seeding and the draw run uncapped; the decline arrives after

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.price = AceFixtures.priceAt(address(usdc), address(coll), top); // WAS the ladder's top rung, relative to par
        p.minCoverageWad = sh.k;
        p.minDebt = sh.minDebt;
        p.deleverageFloorEpsBps = sh.eps;
        p.deleverageProtocolBps = sh.cut;
        p.deleverageBandBps = sh.band;
        p.deleverageTargetBps = sh.target;
        p.deleverageStopBps = sh.stop;
        p.fillFeeBps = 0;

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(d.ace));
        unitScale = read.marketState(mid).unitScale;
    }

    /// @dev Rest `n` lots of `lot` in the market. WAS `n` adjacent ticks at `lot` each, walking down from `top`.
    /// @dev The market's price carries `top` now, set at creation; the lots are CASH and the totals are unchanged.
    function _seed(uint256 n, uint256 lot) internal {
        uint256 total = n * lot;
        usdc.mint(alice, total);
        vm.startPrank(alice);
        usdc.approve(address(ace), total);
        ace.deposit(mid, total);
        vm.stopPrank();
    }

    /// @dev The largest principal `units` admits, by bisection on the hub's OWN preview.
    /// @dev Never a restated gate: a loosened admission door moves this number with it.
    function _maxPrincipal(uint256 units, uint256 hi) internal view returns (uint256) {
        uint256 lo;
        while (lo < hi) {
            uint256 m = (lo + hi + 1) / 2;
            if (_admits(units, m)) lo = m;
            else hi = m - 1;
        }
        return lo;
    }

    function _admits(uint256 units, uint256 principal) internal view returns (bool) {
        try ace.previewOpen(mid, units, principal, uint64(TENOR), borrower, OpenBounds(0, 0, 0)) {
            return true;
        } catch {
            return false;
        }
    }

    function _open(uint256 units, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        loanId = ace.open(mid, units, principal, uint64(TENOR), borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /* ========================= the adversarial decline ========================= */

    /// @notice Park the record ONE WEI above the loan's own stop level: the cheapest fill the channel admits.
    /// @dev The floor IS that same number, so nothing can lift the keeper's price off the cheapest admitted fill.
    /// @dev Returns false once the corridor closes, which is the channel refusing rather than the test giving up.
    /// @param loanId The loan whose stop level sets the level.
    /// @return armed Whether an admissible fill level exists.
    function _armWorstFill(uint256 loanId) internal returns (bool armed) {
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 trig = read.triggerPrice(loanId);
        if (trig == 0) return false;
        uint256 stopLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - p.deleverageStopBps * 1e14);
        uint256 bandLevel = FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - p.deleverageBandBps * 1e14);
        uint256 ps = stopLevel + 1;
        if (ps >= bandLevel) return false;
        if (lastPs != 0 && ps > lastPs) rises++;
        if (firstPs == 0) firstPs = ps;
        lastPs = ps;
        record.setBandPrice(ps);
        record.setMinPrice(ps);
        return true;
    }

    /// @dev Open at the coverage line, then crank the decline to its stop up to `cranks` times.
    /// @dev The live invariant is checked after EVERY crank, so a breach names the crank that caused it.
    function _decline(Shape memory sh, int24 top, uint256 lots, uint256 units, uint256 cranks) internal returns (uint256 loanId) {
        _market(sh, top);
        _seed(lots, sh.lot);
        uint256 principal = _maxPrincipal(units, lots * sh.lot);
        assertGe(principal, sh.minDebt, "fixture: the position must admit a real draw");
        loanId = _open(units, principal);
        assertEq(_liveClaims(loanId), 1, "fixture: the draw must hold its claim to be the subject");
        assertLe(_need(loanId), read.loan(loanId).collateralUnits, "fixture: an admitted loan starts covered");

        for (uint256 i; i < cranks; i++) {
            if (read.loan(loanId).closedAt != 0) break;
            if (!_armWorstFill(loanId)) break;
            uint256 before = gasleft();
            uint256 sold = _crank(loanId);
            gasSpent += before - gasleft();
            if (sold == 0) break;
            cranksSold++;
        }
        assertEq(rises, 0, "fixture: the armed record level must be a MONOTONE decline");
        emit log_named_uint("cranks that sold", cranksSold);
        emit log_named_uint("first armed record level", firstPs);
        emit log_named_uint("last armed record level", lastPs);
        emit log_named_uint("decline factor, firstPs / lastPs", lastPs == 0 ? 0 : firstPs / lastPs);
    }

    function _crank(uint256 loanId) internal returns (uint256 sold) {
        (sold,) = ace.deleverage(loanId, 0, "");
    }

    /// @dev Settle at tenor with no armed policy, and report what the hub itself recorded.
    function _settleShortfall(uint256 loanId) internal returns (uint256 shortUnits, uint256 badDebt) {
        if (read.loan(loanId).closedAt != 0) return (0, 0);
        vm.warp(uint256(read.loan(loanId).expiry) + 1);
        ace.forceClose(loanId);
        (shortUnits, badDebt) = read.shortfallOf(loanId);
    }

    /* ================================ readers ================================ */

    /// @dev What settlement would need: the live claim at its OWN price, ceiled as `collateralNeeded` ceils.
    /// @dev WAS a sum over the funded ticks, each ceiled separately; there is one claim at one price now.
    function _need(uint256 loanId) internal view returns (uint256) {
        uint256 amt = read.claimOf(mid, loanId);
        if (amt == 0) return 0;
        uint256 price = read.fundingFloor(mid, loanId);
        return (amt * unitScale + price - 1) / price;
    }

    /// @dev Live claims on this loan: ONE while it is funded, zero once it retires.
    function _liveClaims(uint256 loanId) internal view returns (uint256) {
        return read.claimCount(mid, loanId);
    }

    /* ===================== the shipped-shape reproduction ===================== */

    /// @notice THE HEADLINE, INVERTED: at SHIPPED-shape dials a 400-crank decline stops ON the claim-tick floor.
    /// @notice k = 1.4, eps = 100 bps, no protocol cut, band 3000 / target 4000 / stop 1000.
    /// @notice This row was written to prove the breach and its fixture is unchanged; only its subject moved.
    /// @dev The genesis sell-max rail clears by ~0.486e18 here, so no rail margin is doing the holding.
    /// @dev What used to run out is the position's ATOM COUNT, a decimals fact no rail bounds.
    /// @dev EXACT TO THE EPSILON: the need floors at ONE ATOM now -- it was `maxClaimTicks` atoms, one per funded rung.
    /// @dev The walk stops one atom clear of it, and the debt melts to dust on the way: under one collateral atom's first armed worth.
    /// @dev What stops it is the SIZING, not the reserve: at the worst fill `u = floor(C * 0.3 / 0.786)`, which is zero at `C = 2`.
    /// @dev With ONE claim this walk never brings the need near the position, so the reserve never binds on it.
    /// @dev Measured: with the reserve AND the `minDebt` cap both mutated out this row stays green; the bind, rail-edge and sliver rows guard it.
    /// @dev `_shipped` sets the least `minDebt` genesis admits, so the `minDebt` cap does not end the walk before the sizing does.
    /// @dev Asserted on `shortfallOf`, which `_settle` itself writes: no mirrored arithmetic decides it.
    function test_ShippedShape_DeclineStopsOneAtomClearOfTheCoverageFloor() public {
        uint256 loanId = _decline(_shipped(), 0, 32, 60_000, 400);

        uint256 held = read.loan(loanId).collateralUnits;
        uint256 need = _need(loanId);
        assertEq(need, lens.collateralNeeded(mid, loanId), "the shipped view and this file's derivation must agree");
        assertEq(need, _liveClaims(loanId), "the need has bottomed out at ONE ATOM, THE LIVE CLAIM");
        assertEq(held, need + 1, "and the walk stopped one atom clear of it: the whole coverage-line epsilon");
        assertLt(read.debtOf(loanId), _oneAtomOfQuote(), "the debt melted to dust: under what ONE collateral atom fetched when the decline began");

        (uint256 shortUnits,) = _settleShortfall(loanId);
        assertEq(shortUnits, 0, "an admitted loan must not settle short after a decline it survived");
    }

    /// @notice The SAME sequence at the SHIPPED claim-tick cap, which is 10 and not the 32 ceiling.
    /// @notice `Defaults.MAX_CLAIM_TICKS` is 10, so 32 is creator-admissible rather than what ships.
    /// @dev The floor `need` bottoms out at is the LIVE TICK COUNT, so a lower cap lowers the floor with it.
    /// @dev That made the breach EASIER to reach before the reserve, so the cap is worth pinning both ways.
    function test_ShippedTickCap_TenClaimTicks_AlsoStopsOnTheFloor() public {
        Shape memory sh = _shipped();
        uint256 loanId = _decline(sh, 0, 10, 60_000, 400);

        assertEq(_need(loanId), _liveClaims(loanId), "the need has bottomed out at ONE ATOM, THE LIVE CLAIM");
        assertLe(_need(loanId), read.loan(loanId).collateralUnits, "and the position still holds that floor");
        (uint256 shortUnits,) = _settleShortfall(loanId);
        assertEq(shortUnits, 0, "an admitted loan must not settle short at the SHIPPED tick cap either");
    }

    /// @notice The SAME decline at a REAL `minDebt` of 1,000 USDC: the `minDebt` cap ends the walk on the floor, long before the reserve binds.
    /// @notice So at a realistic floor the one-atom regime above is unreachable by cranking, and the loan still settles whole.
    /// @dev The erosion rows above sit at the least `minDebt` genesis admits exactly so this cap stays out of their way.
    function test_ShippedShape_AtARealMinDebt_TheCapEndsTheDeclineOnTheFloor() public {
        Shape memory sh = _shipped();
        sh.minDebt = 1_000e6;
        uint256 loanId = _decline(sh, 0, 32, 60_000, 400);

        uint256 debt = read.debtOf(loanId);
        uint256 need = _need(loanId);
        assertGe(debt, sh.minDebt, "the decline bottomed out at the minDebt floor, never under it");
        assertLt(debt - sh.minDebt, _oneAtomOfQuote(), "and within one collateral atom's worth of it");
        assertGt(need, _liveClaims(loanId), "so the need never reached the one-atom floor the reserve guards");
        assertGt(read.loan(loanId).collateralUnits, need + 1, "and the reserve never bound");
        (uint256 shortUnits,) = _settleShortfall(loanId);
        assertEq(shortUnits, 0, "an admitted loan must not settle short after a decline it survived");
    }

    /// @dev The quote one collateral atom fetched at the decline's HIGHEST armed price, ceiled: the coarsest the cap can land.
    /// @dev The armed level only falls, so every capped crank in the sequence stopped within this of the floor.
    function _oneAtomOfQuote() internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(firstPs, 1, unitScale);
    }

    /// @notice The SAME dials, the SAME crank budget, at 18-decimal collateral: the control.
    /// @notice It stays covered, because the row measures how many ATOMS a position holds, not settlement.
    /// @dev A 1e18-atom position cannot be walked under a 32-atom floor inside any usable crank budget.
    /// @dev So this passing while the row above fails is the decimals dependence stated as a measurement.
    function test_EighteenDecimalCollateral_SurvivesTheSameDecline() public {
        Shape memory sh = _shipped();
        sh.cDec = 18;
        uint256 loanId = _decline(sh, 0, 32, 60_000e18, 400);

        assertLe(_need(loanId), read.loan(loanId).collateralUnits, "an 18-decimal position is still covered");
        (uint256 shortUnits,) = _settleShortfall(loanId);
        assertEq(shortUnits, 0, "and it settles whole");
    }

    /// @notice The two cranks that used to reach the breach, and the row that pins the KEEPER SLIVER term.
    /// @notice k at MIN_COVERAGE_WAD, eps and the cut at their ceilings, stop one bps above the rail's edge.
    /// @notice Debt is still MATERIAL here, so the sliver is non-zero and the reserve's second term is live.
    /// @dev Settlement takes the sliver OFF THE TOP before it pays a claim, so coverage needs `held - sliver >= need`.
    /// @dev That is strictly stronger than `held >= need`, which is why the reserve carries a sliver term at all.
    /// @dev The erosion rows above cannot see it: their debt melts to dust, so their sliver floors to zero.
    /// @dev The sliver is read from `unitsOwedOf`, which `_settle` itself credited, never from a restated formula.
    function test_TightSellMaxRail_TwoCranks_LeaveTheSliverCoveredToo() public {
        uint256 loanId = _decline(_tightRail(), 0, 32, 71_412, 2);

        uint256 held = read.loan(loanId).collateralUnits;
        uint256 need = _need(loanId);
        assertLe(need, held, "two cranks at the rail's edge leave the claims covered");

        (uint256 shortUnits,) = _settleShortfall(loanId);
        uint256 sliver = read.unitsOwedOf(loanId, address(this)); // the settling keeper is this contract
        assertGt(sliver, 0, "fixture: the debt must be material enough to pay a real sliver, or the term is untested");
        assertGe(held - sliver, need, "POST-SLIVER coverage: the reserve carries the bounty settlement takes first");
        assertEq(shortUnits, 0, "an admitted loan must not settle short after a decline it survived");
    }

    /* ============================== the fuzz ============================== */

    /// @notice THE PROPERTY, fuzzed over every dial that moves the sale's arithmetic.
    /// @notice Coverage, all five decline dials, both decimals, the funded span and the position's ATOM COUNT.
    /// @dev Every market is built through `createMarket`, so genesis alone decides admissibility.
    /// @dev A seed genesis refuses is DISCARDED rather than clamped: clamping would invent an inadmissible market.
    /// @dev The position is fuzzed in ATOMS, not tokens, because the atom count is exactly what the defect spends.
    /// @dev The lot is DERIVED from that count, so a seed opens a real loan at any decimals; `minDebt` is the least genesis admits.
    /// @dev Asserted on `shortfallOf`, the hub's own write, so no restated arithmetic can agree with the bug.
    function testFuzz_DeleveragedLoan_IsAlwaysCoveredAtSettlement(uint256 dialSeed, uint256 decSeed, uint256 unitSeed) public {
        uint256 units = bound(unitSeed, 8, 4_000);
        Shape memory sh = _fuzzShape(dialSeed, decSeed, units);
        if (units <= 4 * sh.lots) return; // too few atoms to carry one atom per funded tick

        uint256 loanId = _declineOrSkip(sh, units, 200);
        if (loanId == 0) return; // the fixture could not open a loan at this shape
        reached++;

        (uint256 shortUnits,) = _settleShortfall(loanId);
        assertEq(shortUnits, 0, "an admitted loan must not settle short after a decline it survived");
    }

    /// @notice The SINGLE-CRANK half of the property, stated separately so it cannot hide inside a sequence.
    /// @dev One crank is bounded by `securedBase` off a full-sized debt, so this is the half expected to hold.
    /// @dev It is worth pinning: it is what makes the sequence, and not the sale, the thing to fix.
    function testFuzz_OneCrank_LeavesTheLoanCovered(uint256 dialSeed, uint256 decSeed, uint256 unitSeed) public {
        uint256 units = bound(unitSeed, 8, 4_000);
        Shape memory sh = _fuzzShape(dialSeed, decSeed, units);
        if (units <= 4 * sh.lots) return;

        uint256 loanId = _declineOrSkip(sh, units, 1);
        if (loanId == 0) return;
        reached++;

        (uint256 shortUnits,) = _settleShortfall(loanId);
        assertEq(shortUnits, 0, "ONE deleverage crank must leave an admitted loan covered");
    }

    /// @notice THE ANTI-VACUITY GUARD: the fuzz body must actually reach its subject, not skip past it.
    /// @dev A prior version of this suite passed while every run skipped, which is the trap the sibling names.
    /// @dev Deterministic seeds, so the count is a fact about the fixture rather than a fuzzer's luck.
    function test_FuzzBody_ActuallyReachesItsSubject() public {
        uint256 opened;
        for (uint256 i; i < 24; i++) {
            uint256 units = 1_000 + i * 97;
            Shape memory sh = _fuzzShape(uint256(keccak256(abi.encode("dial", i))), uint256(keccak256(abi.encode("dec", i))), units);
            if (units <= 4 * sh.lots) continue;
            if (_declineOrSkip(sh, units, 4) != 0) opened++;
            (lastPs, rises) = (0, 0);
        }
        emit log_named_uint("seeds that opened a loan", opened);
        assertGe(opened, 8, "the fuzz body must open a real loan on a decent share of seeds");
    }

    /// @dev The decline, with the fixture's own preconditions turned into a skip rather than a failure.
    /// @dev Only the SUBJECT may fail here: a seed that funds nothing is a fixture miss, not a defect.
    function _declineOrSkip(Shape memory sh, uint256 units, uint256 cranks) internal returns (uint256 loanId) {
        if (sh.lot == 0 || sh.minDebt == 0) return 0;
        if (!_creatable(sh)) return 0; // genesis refused the dials: not an admissible market, so not a subject
        _market(sh, 0);
        _seed(sh.lots, sh.lot);
        uint256 principal = _maxPrincipal(units, sh.lots * sh.lot);
        if (principal < sh.minDebt) return 0;
        loanId = _open(units, principal);
        if (_liveClaims(loanId) == 0) return 0; // the draw funded nothing: a fixture miss, not a subject
        assertLe(_need(loanId), read.loan(loanId).collateralUnits, "fixture: an admitted loan starts covered");

        for (uint256 i; i < cranks; i++) {
            if (read.loan(loanId).closedAt != 0) break;
            if (!_armWorstFill(loanId)) break;
            if (_crank(loanId) == 0) break;
        }
        assertEq(rises, 0, "fixture: the armed record level must be a MONOTONE decline");
    }

    /// @dev A shape over the legal envelope; genesis is left to refuse the combinations it refuses.
    /// @dev `lot` is sized off the position's own quote value, so no decimal pair goes vacuous; `minDebt` stays at the floor.
    function _fuzzShape(uint256 dialSeed, uint256 decSeed, uint256 units) internal pure returns (Shape memory sh) {
        sh.k = bound(dialSeed, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        sh.eps = bound(uint256(keccak256(abi.encode(dialSeed, uint256(1)))), 1, Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS);
        sh.cut = bound(uint256(keccak256(abi.encode(dialSeed, uint256(2)))), 0, Constants.MAX_DELEVERAGE_PROTOCOL_BPS);
        sh.band = bound(uint256(keccak256(abi.encode(dialSeed, uint256(3)))), Constants.MIN_DELEVERAGE_BAND_BPS, 9_000);
        sh.target = bound(uint256(keccak256(abi.encode(dialSeed, uint256(4)))), sh.band + 1, 9_999);
        sh.stop = bound(uint256(keccak256(abi.encode(dialSeed, uint256(5)))), 1, sh.band - 1);
        (sh.cDec, sh.qDec) = _decimals(decSeed);
        /// @dev WAS a FUZZED rung count, which is what `maxClaimTicks` bounded. A market has one price, so
        /// @dev its whole depth is one balance -- and left unset this field defaulted to ZERO, which seeded
        /// @dev the market with nothing and made every run refuse `BelowMinLot` before reaching its subject.
        sh.lots = 1;
        (sh.minDebt, sh.lot) = _sizes(sh, units);
    }

    /// @dev The draw this position can carry at the market's price, and the deposit that funds it.
    /// @dev An ESTIMATE on purpose: the bisection above finds the real admissible draw against the real floor.
    /// @dev IT PRICED AT THE SPAN'S LOWEST TICK -- `maxClaimTicks - 1` rungs under par -- and split the draw
    /// @dev into one lot per funded tick, because a draw walked down and the floor was wherever it stopped.
    /// @dev A market has one price, so par IS the floor and the whole draw funds from one balance.
    function _sizes(Shape memory sh, uint256 units) internal pure returns (uint256 minDebt, uint256 lot) {
        uint256 us = 1 << 96; // the hub's frame is a constant now, so no decimal pair moves it
        uint256 price = PriceFrame.priceAtStep(PriceFrame.parStep(sh.qDec, sh.cDec));
        uint256 draw = FullMath.mulDiv(FullMath.mulDiv(units, price, us), 1e18, sh.k);
        lot = draw;
        minDebt = MIN_DEBT_FLOOR; // WAS `draw / 4`, which the minDebt cap turned into a floor every decline stopped on
        if (draw < 16) (minDebt, lot) = (0, 0); // the position is worth too little quote to open anything
    }

    /// @dev A legal `(collateral, quote)` decimal pair, over exactly the envelope MarketInit admits.
    /// @dev `MAX_DECIMALS` on each end is the whole of it: no relative gap term bounds either side now.
    function _decimals(uint256 seed) internal pure returns (uint8 cd, uint8 qd) {
        cd = uint8(bound(seed, 0, Constants.MAX_DECIMALS));
        qd = uint8(bound(uint256(keccak256(abi.encode(seed))), 0, Constants.MAX_DECIMALS));
    }

    /// @dev Whether genesis admits these dials, asked of `createMarket` on a throwaway hub.
    function _creatable(Shape memory sh) internal returns (bool) {
        MockERC20 q = new MockERC20("Quote", "Q", sh.qDec);
        MockERC20 c = new MockERC20("Collateral", "C", sh.cDec);
        MarketParams memory p = AceFixtures.marketParams(address(q), address(c));
        p.record = address(new MockPersistenceRecord(address(q), address(c)));
        p.minCoverageWad = sh.k;
        p.minDebt = sh.minDebt;
        p.deleverageFloorEpsBps = sh.eps;
        p.deleverageProtocolBps = sh.cut;
        p.deleverageBandBps = sh.band;
        p.deleverageTargetBps = sh.target;
        p.deleverageStopBps = sh.stop;
        p.fillFeeBps = 0;
        Ace probe = AceFixtures.newAce();
        try probe.createMarket(p) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev DELETED: the priority-payout section, two rows and four readers. `_finalizeClaims` rationed a SHORT
    /// @dev close across a loan's funded ticks in DESCENDING tick order, so a lender resting high got paid first
    /// @dev and the rows measured whether an adversary could stage that extraction. They already reported that it
    /// @dev could not be staged -- the settlement reserve makes a short close unreachable from the sale path.
    /// @dev A loan holds ONE claim: there is no queue to order and no sort to be inert. The reserve property the
    /// @dev rows were really standing on is the subject of this whole file and is asserted after every crank above.

    /* ===================== what the genesis rail holds ===================== */

    /// @notice THE RAIL PIN. `MarketInit`'s sell-max exclusion is `k(1-eps)(1-cut) + stop > 1e18`.
    /// @notice What it holds is SELL-MAX EXCLUSION and nothing else: at the lowest admitted fill, `u < C`.
    /// @notice So every admitted crank fully restores, and the protocol cut is taken and borrower-borne.
    /// @notice It does NOT hold the coverage property -- the sibling rows break that with the rail satisfied.
    /// @dev The violating market is unreachable through `createMarket`, so the stop is poked in storage.
    /// @dev The slot is FOUND by scanning for the value rather than derived, and read back through the ABI.
    /// @dev A hand-derived offset reads a plausible number and reverts nothing, which is how it goes wrong.
    /// @dev WHAT THE SETTLEMENT RESERVE CHANGED HERE, and it is the rail's own edge that causes it.
    /// @dev The rail is `k(1-eps)(1-cut) > 1 - stop`, so at its EDGE the margin is a fraction of a bps.
    /// @dev The sized sale is `C (theta - t) / (k m (1-cut) - t)`, and the lowest admitted fill is `theta = 1 - stop`.
    /// @dev Numerator and denominator then differ by exactly that margin, so `u` comes out at ~0.9996 C.
    /// @dev MEASURED at 60% of the admissible principal: sized ~71,380 of 71,412 held, reserve-capped to 31,656.
    /// @dev So NO openable slack outruns it -- `(c - 1 - b)/c` would need `c` past 2,000 -- and the cut is not observable here.
    /// @dev The rail's `u < C` is subsumed by a tighter bound at this corner.
    /// @dev Asserted at BOTH openings on purpose: a single leg would read as an artefact of sitting on the line.
    /// @dev The rail's OWN property is pinned by the sibling pair below, on a stop clear of the onset.
    function test_SellMaxRail_Edge_TheReserveBindsBeforeTheRailDoes() public {
        (uint256 lineLoan, uint256 soldLine, uint256 heldLine, uint256 revLine) = _oneCrank(_tightRail(), 71_412, 100);
        assertGt(soldLine, 0, "fixture: the sale must actually run on the line");
        assertLt(soldLine, heldLine, "the reserve keeps the position off the sell-max edge the rail also bounds");
        assertEq(revLine, 0, "a reserve-capped crank does not restore, so it takes no cut");
        assertLe(_need(lineLoan), read.loan(lineLoan).collateralUnits, "and the loan still covers every live claim");
        _assertSecuredBaseBoundNotTheMinDebtCap(lineLoan);

        (lastPs, rises, firstPs) = (0, 0, 0);
        (uint256 slackLoan, uint256 soldSlack, uint256 heldSlack, uint256 revSlack) = _oneCrank(_tightRail(), 71_412, 60);
        assertLt(soldSlack, heldSlack, "and slack above the line does not change it at the rail's edge");
        assertEq(revSlack, 0, "the reserve still binds at 60% of the admissible principal, so still no cut");
        assertLe(_need(slackLoan), read.loan(slackLoan).collateralUnits, "covered there too");
        _assertSecuredBaseBoundNotTheMinDebtCap(slackLoan);
    }

    /// @dev Near the rail the sized sale's proceeds reach the whole debt, so the `minDebt` cap would ALSO stop it short.
    /// @dev A cap-bound crank lands within one collateral atom's worth of quote of the floor; a `securedBase`-bound one lands far above.
    /// @dev So a debt clear of that band names `securedBase` as the cap that bound, which the no-cut and hold-back asserts cannot.
    /// @dev At the edge that is the RESERVE term (mutating it out lands the crank on the floor); under a violated rail it is bare `requiredAt`.
    function _assertSecuredBaseBoundNotTheMinDebtCap(uint256 loanId) internal view {
        assertGt(read.debtOf(loanId), MIN_DEBT_FLOOR + _oneAtomOfQuote(), "securedBase bound, not the minDebt cap: the debt stayed clear of the floor");
    }

    /// @notice THE RAIL PIN PROPER: with the rail HELD, the lowest admitted fill leaves the position.
    /// @notice The crank then fully restores, so the protocol cut is taken and is borrower-borne.
    /// @dev THE FIXTURE REPAIR, and it is a fixture change only: the stop sits 1131 bps clear of the sell-max onset.
    /// @dev The loan also opens at 50% of the admissible principal rather than on its line.
    /// @dev At the ONSET the sized sale is ~0.9996 C by construction, so no openable slack clears the reserve.
    /// @dev The cut cannot be observed there -- that is the sibling row above, measured, not assumed.
    /// @dev Away from the onset the sized sale is a real fraction of the position and slack clears it.
    /// @dev That is what lets the rail's own behaviour still be pinned under the settlement reserve.
    function test_SellMaxRail_IsWhatMarketInitActuallyHolds() public {
        (uint256 loanId, uint256 sold, uint256 held, uint256 revDelta) = _oneCrank(_railHeld(), 71_412, 50);
        assertGt(sold, 0, "fixture: the sale must actually run");
        assertLt(sold, held, "RAIL HELD: the lowest admitted fill leaves the position, so the crank fully restores");
        assertGt(revDelta, 0, "and a fully-restoring crank is where the cut is taken");
        assertLe(_need(loanId), read.loan(loanId).collateralUnits, "and the loan still covers every live claim");
    }

    /// @notice The SAME market with the rail VIOLATED: the crank cannot restore, so it takes no cut.
    /// @dev This is the loss the rail prevents, so it is the rail's job stated as its own failure mode.
    /// @dev The violating market is unreachable through `createMarket`, so the stop is poked in storage.
    /// @dev The slot is FOUND by scanning for the value rather than derived, and read back through the ABI.
    /// @dev A hand-derived offset reads a plausible number and reverts nothing, which is how it goes wrong.
    /// @dev THE NAME IS STALE: the crank no longer sells the WHOLE position, because the reserve refuses that.
    /// @dev It refuses it even on a market genesis would not admit, which is what this row establishes.
    /// @dev This is the one place an assertion moved rather than a fixture; the rail's own half is unchanged.
    function test_SellMaxRail_Violated_SellsTheWholePositionAndSkipsTheCut() public {
        Shape memory sh = _railHeld();
        _market(sh, 0);
        _seed(32, sh.lot);
        uint256 loanId = _open(71_412, (_maxPrincipal(71_412, 32 * sh.lot) * 50) / 100);
        _pokeStop(sh.stop, 1); // below the onset: unreachable through createMarket, which is the point

        assertTrue(_armWorstFill(loanId), "fixture: the corridor must be open under the violated rail");
        uint256 held = read.loan(loanId).collateralUnits;
        uint256 rev = read.protocolRevenue(mid);
        uint256 sold = _crank(loanId);
        assertGt(sold, 0, "fixture: the sale must actually run");
        assertLt(sold, held, "the reserve holds units back even under a rail genesis would have refused");
        assertEq(read.protocolRevenue(mid) - rev, 0, "RAIL VIOLATED: the crank cannot restore, so no cut is taken");
        assertLe(_need(loanId), read.loan(loanId).collateralUnits, "and the loan still covers every live claim");
        _assertSecuredBaseBoundNotTheMinDebtCap(loanId);
    }

    /// @notice A RESERVE-CAPPED crank takes NO protocol cut, and this is a revenue consequence of the reserve.
    /// @notice `Deleverage` leaves `charge` false when the scope cap binds, and `_meltAll` gates the cut on `charge`.
    /// @notice So a market whose loans sit on their coverage line stops paying the deleverage cut entirely.
    /// @dev DIFFERENTIAL, on ONE set of PoC dials: the only thing that moves between the legs is the OPENING SIZE.
    /// @dev At 100% of the admissible principal the loan sits on its line and the reserve binds: no cut.
    /// @dev At 55% it carries slack, the reserve does not bind, the identical crank fully restores and pays the cut.
    /// @dev A single-leg row could not tell the reserve apart from a market that simply never pays a cut.
    /// @dev It has to be PoC dials rather than the rail's edge: at the edge the sized sale is ~0.9996 C.
    /// @dev No openable slack clears it there, which the sibling row above measures.
    function test_ReserveCappedCrank_TakesNoProtocolCut() public {
        (, uint256 soldSlack,, uint256 revSlack) = _oneCrank(_pocDials(), 60_000, 55);
        (lastPs, rises, firstPs) = (0, 0, 0);
        (uint256 lineLoan, uint256 soldLine,, uint256 revLine) = _oneCrank(_pocDials(), 60_000, 100);

        assertGt(revSlack, 0, "control: with slack above the line the same crank fully restores and pays the cut");
        assertGt(soldLine, 0, "fixture: the capped crank must still sell something, or the row proves nothing");
        assertLt(soldLine, soldSlack, "the reserve is what shrank the sale, so the two legs must differ in size");
        assertEq(revLine, 0, "A RESERVE-CAPPED CRANK TAKES NO PROTOCOL CUT");
        assertLe(_need(lineLoan), read.loan(lineLoan).collateralUnits, "and the capped crank left the loan covered");
    }

    /* ================= where in the band does the reserve start binding? ================= */

    /// @notice THE BIND THRESHOLD, measured: the shallowest margin at which the reserve caps a crank.
    /// @notice On a loan sitting ON its coverage line `requiredAt` is `k X` and the reserve leaves only `(k - 1 - b) X`.
    /// @notice So the reserve is the binding cap by a wide margin, and `charge` going false means the RESERVE bound.
    /// @dev Read off the protocol cut, which `_meltAll` gates on `charge`: a crank whose restore does not fit pays none.
    /// @dev So the observable is the hub's own revenue delta, never a restated sizing.
    /// @dev The closed form is `c (theta - t) > (c - 1 - b)(k m (1-cut) - t)`; this measures it instead.
    /// @dev FLAT BOOK, one funded tick, so every claim prices at the funding floor and `collateralNeeded` is `requiredAt / k`.
    /// @dev That is the case the closed form describes, and the measurement lands on it.
    function test_ClampBindThreshold_PocDials_FlatBook() public {
        uint256 t = _bindThreshold(_pocDials(), 100, 1);
        emit log_named_uint("PoC bind threshold on a flat book, theta 1e18", t);
        assertApproxEqAbs(t, 0.7304e18, 0.002e18, "the reserve starts capping a line-hugging PoC loan at theta 0.7304");
    }

    // DELETED with the ladder: test_ClampBindThreshold_PocDials_SpreadBookBindsLater needed 32 rungs; one price makes both spreads one number

    /// @notice At the corner the threshold sits UNDER the band floor, so every crank the band admits is capped.
    /// @dev Not measurable below `1 - band`, because the channel does not open there.
    /// @dev The row asserts the reachable half: the shallowest margin the band admits is already capped.
    function test_ClampBindThreshold_Corner_BindsAcrossTheWholeBand() public {
        Shape memory sh = _tightRail();
        uint256 t = _bindThreshold(sh, 100, 32);
        emit log_named_uint("corner bind threshold, theta 1e18", t);
        assertLe(t, 1e18 - sh.band * 1e14, "at the corner the reserve caps every crank the band admits");
    }

    /// @dev Bisect the in-band margin for the shallowest point at which the crank stops taking the cut.
    /// @dev Each probe is a FRESH market and loan: a crank mutates the state the next probe would read.
    function _bindThreshold(Shape memory sh, uint256 pct, uint256 ticks) internal returns (uint256) {
        uint256 lo = 1e18 - sh.band * 1e14; // band entry, the shallowest margin the channel opens at
        uint256 hi = 1e18 - sh.stop * 1e14; // the stop edge, the deepest
        if (_bindsAt(sh, pct, lo + 1e12, ticks)) return lo; // already capped at band entry: the whole band binds
        for (uint256 i; i < 12; i++) {
            uint256 mid_ = (lo + hi) / 2;
            if (_bindsAt(sh, pct, mid_, ticks)) hi = mid_;
            else lo = mid_;
        }
        return hi;
    }

    /// @dev Does a crank at exactly this margin get capped? Answered by whether the protocol cut was taken.
    function _bindsAt(Shape memory sh, uint256 pct, uint256 thetaWad, uint256 ticks) internal returns (bool) {
        _market(sh, 0);
        _seed(ticks, (32 * sh.lot) / ticks);
        uint256 loanId = _open(71_412, (_maxPrincipal(71_412, 32 * sh.lot) * pct) / 100);
        _armAtTheta(loanId, thetaWad);
        uint256 rev = read.protocolRevenue(mid);
        _crank(loanId);
        return read.protocolRevenue(mid) - rev == 0;
    }

    /// @dev Park the record at an exact margin `theta = trigger / ps`, anywhere the band admits.
    /// @dev The worst-fill helper arms at the stop edge only, which is one point of the band and not a sweep.
    function _armAtTheta(uint256 loanId, uint256 thetaWad) internal {
        uint256 ps = FullMath.mulDiv(read.triggerPrice(loanId), 1e18, thetaWad);
        record.setBandPrice(ps);
        record.setMinPrice(ps);
    }

    /// @dev One market, one loan opened at `pctOfMax` of the admissible principal, one crank at the worst fill.
    function _oneCrank(Shape memory sh, uint256 units, uint256 pctOfMax) internal returns (uint256 loanId, uint256 sold, uint256 held, uint256 revDelta) {
        _market(sh, 0);
        _seed(32, sh.lot);
        loanId = _open(units, (_maxPrincipal(units, 32 * sh.lot) * pctOfMax) / 100);
        assertTrue(_armWorstFill(loanId), "fixture: the corridor must be open at the lowest admitted fill");
        held = read.loan(loanId).collateralUnits;
        uint256 rev = read.protocolRevenue(mid);
        sold = _crank(loanId);
        revDelta = read.protocolRevenue(mid) - rev;
    }

    /// @dev Rewrite `deleverageStopBps` in place, finding its slot by its value and reading the result back.
    function _pokeStop(uint256 from, uint256 to) internal {
        uint256 hits;
        uint256 at;
        for (uint256 i; i < 24; i++) {
            uint256 slot = read.marketSlot(mid, i);
            if (uint256(ace.extsload(bytes32(slot))) != from) continue;
            hits++;
            at = slot;
        }
        assertEq(hits, 1, "fixture: the stop's value must identify exactly one param slot");
        vm.store(address(ace), bytes32(at), bytes32(to));
        assertEq(ace.idToMarketParams(mid).deleverageStopBps, to, "fixture: the poke landed on the stop");
    }

    /* ========================= the shipped shapes ========================= */

    function _shipped() internal pure returns (Shape memory sh) {
        sh = Shape({k: 1.4e18, eps: 100, cut: 0, band: 3000, target: 4000, stop: 1000, cDec: 0, qDec: 6, lots: 32, lot: 2_200e6, minDebt: MIN_DEBT_FLOOR});
    }

    /// @dev k, eps and the cut at the corner where the sell-max rail is one bps from refusing the market.
    function _tightRail() internal pure returns (Shape memory sh) {
        sh = _shipped();
        (sh.k, sh.eps, sh.cut, sh.stop) = (Constants.MIN_COVERAGE_WAD, 200, 2000, 1769);
    }

    /// @dev The same corner `k`, eps and cut, with the stop clear of the sell-max onset and the target near the band.
    /// @dev The rail is still the thing holding `u < C`: at the lowest admitted fill `theta` is `1 - stop`.
    /// @dev The rail says `k m (1-cut) > 1 - stop`, so the sizing's numerator stays under its denominator.
    /// @dev What these two moves buy is a SIZED SALE a slack opening can clear.
    /// @dev That is what lets the rail's own restore-and-take-the-cut behaviour still be observed under the reserve.
    /// @dev `u/C` is `(theta - t)/(k m (1-cut) - t)`, so a target just above the band raises `t` and shrinks it.
    /// @dev At 0.15 C the sale clears BOTH caps -- the reserve and bare `requiredAt` -- over a wide slack window.
    /// @dev Poking the stop to 1 violates the rail from here exactly as it does from the onset.
    function _railHeld() internal pure returns (Shape memory sh) {
        sh = _tightRail();
        (sh.stop, sh.target) = (2900, 3100); // stop 1131 bps clear of the onset, target one notch over the band
    }

    /// @dev `PocMarkets`' own decline dials, which are the shipped shape plus a live protocol cut.
    /// @dev The cut is what makes a taken-or-not-taken assertion mean anything: `_shipped` sets it to zero.
    function _pocDials() internal pure returns (Shape memory sh) {
        sh = _shipped();
        (sh.cut, sh.target) = (500, 5000);
    }
}
