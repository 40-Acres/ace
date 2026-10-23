// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {BelowWithdrawLine} from "../../src/ace/hub/Ace.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title AceCoverageGuarantee
/// @notice THE PROPERTY: a loan admitted by `open` covers every claim it created at those claims' own tick prices.
/// @notice So a loan settled with no prior EROSION cannot be short, and shortfall needs post-open unit removal.
/// @notice THE SECOND HALF: a loan withdrawn to the WITHDRAWAL GATE's own line is covered too.
/// @dev WHY IT HOLDS: claims sum to the principal, and every funding tick prices at or above the floor.
/// @dev The floor IS the lowest funding tick, and admission requires `trigger <= floor`.
/// @dev So settlement needs `SUM(claim_t x unitScale / price_t) <= units / k`: at most `1/k` of it.
/// @dev At the shipped k = 1.4 that is ~71.4% of the position, leaving a ~29% margin.
/// @dev Drawing across HIGHER ticks only shrinks the need, so the bound is worst-case, not typical.
/// @dev WHY IT IS WORTH PROVING RATHER THAN ASSUMING: it was found by accident.
/// @dev Bounding `settleBountyBps` needed a 6,000 bps bounty to reach the bad-debt tests at all.
/// @dev The reason was that nothing else CAN make an admitted loan short.
/// @dev The ceiling it was blocking is now ARMED: MAX_SETTLE_BOUNTY_BPS = 200, derived as `b <= k - 1`.
/// @dev So the margin is load-bearing for a SHIPPED bound, and this suite is what keeps it honest.
/// @dev It fails if `k` or the draw gate ever moves against that bound.
/// @dev A SALE cannot take this margin either: `securedBase` reserves settlement's own requirement before sizing.
/// @dev That half is pinned by `AceDeleverageCoverageErosion`; this suite owns the no-sale half alone.
/// @dev THE FIXTURE IS PARAMETERIZED over the pair's decimals and the funded tick triple.
/// @dev Both move the margin, which is measured in COLLATERAL WEI rather than in quote.
/// @dev One collateral wei buys `omega = priceAt(t) / unitScale`, and each per-tick ceiling costs under one wei.
/// @dev So the margin is thin exactly where `omega` is large, and no single decimal point can show that.
/// @dev At the old hardcoded point (18-dec collateral, 6-dec quote) `omega ~ 1e-12` and no ceiling can bite.
/// @dev That is how a live withdrawal-gate defect passed this suite 4/4.
contract AceCoverageGuaranteeTest is Test {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal positionManager;
    MockERC20 internal usdc; // the quote, at qDec
    MockERC20 internal coll; // the collateral, at cDec
    MockPersistenceRecord internal record;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint8 internal cDec; // this market's collateral decimals
    uint8 internal qDec; // this market's quote decimals
    uint256 internal unitScale; // read off the market, never a literal
    uint256 internal perTick; // the seed each of the three ticks carries
    uint256 internal tLo; // THIS MARKET PRICE; it was the lowest of three seeded rungs
    uint256 internal tMid;
    uint256 internal tHi;

    uint8 internal constant DEF_C = 18; // the pair the fixed-point legs below keep
    uint8 internal constant DEF_Q = 6;
    int24 internal constant SPACING = 60;
    uint256 internal constant SEED_TOKENS = 20_000; // the seed a tick carries, in whole quote tokens
    uint256 internal constant MIN_DEBT_DIVISOR = 2_000; // 20_000 / 2_000 == 10 tokens, the fixture's old literal
    uint256 internal constant MAX_TICK_SEED = uint256(type(uint128).max) / 8; // per-tick cash is a uint128
    uint256 internal constant TICK_CAP = 32; // re-spelled, not imported: the fixture's own maxClaimTicks, and the coverage line's slack

    function setUp() public {
        vm.warp(1_000_000);
    }

    /* ============================ the fixture ============================ */

    /// @dev The suite's original point: 18-dec collateral, 6-dec quote, ticks spanning the grid.
    function _market(uint256 k) internal returns (bytes32 id) {
        return _market(k, DEF_C, DEF_Q, -960, 0, 960);
    }

    /// @dev A market at a fuzzed k, decimals and tick triple, funded across all three ticks.
    /// @dev `lo`/`mid`/`hi` are OFFSETS FROM PAR, which is where the decimal pair puts them: par moves with the gap.
    function _market(uint256 k, uint8 cd, uint8 qd, int24 lo, int24 mid, int24 hi) internal returns (bytes32 id) {
        cDec = cd;
        qDec = qd;
        usdc = new MockERC20("Quote", "Q", qd);
        coll = new MockERC20("Collateral", "C", cd);
        /// @dev THE THREE RUNGS ARE THREE PRICES A MARKET COULD BE MADE AT, not three the draw walks down.
        /// @dev The market is created at the LOWEST, which is where the draw's floor landed when it spanned
        /// @dev all three -- so the worst case this suite measures is unchanged and is now the only case.
        /// @dev `tMid` and `tHi` survive because rows below still compare against them as prices.
        (tLo, tMid, tHi) =
        (
            PriceFrame.priceAt(address(usdc), address(coll), lo),
            PriceFrame.priceAt(address(usdc), address(coll), mid),
            PriceFrame.priceAt(address(usdc), address(coll), hi)
        );
        record = new MockPersistenceRecord(address(usdc), address(coll));
        perTick = _seedPerTick(qd);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.minCoverageWad = k;
        p.minDebt = perTick / MIN_DEBT_DIVISOR;
        p.price = tLo;

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(d.ace)); // the shipped views are the second oracle this file checks against
        unitScale = read.marketState(id).unitScale;

        usdc.mint(alice, 3 * perTick);
        vm.startPrank(alice);
        usdc.approve(address(ace), 3 * perTick);
        ace.deposit(id, 3 * perTick);
        vm.stopPrank();
    }

    /// @dev 20k whole quote tokens, clamped so three ticks of it still fit the per-tick uint128 cash cap.
    function _seedPerTick(uint8 qd) internal pure returns (uint256) {
        uint256 one = 10 ** qd;
        return one > MAX_TICK_SEED / SEED_TOKENS ? MAX_TICK_SEED : one * SEED_TOKENS;
    }

    /// @dev Whole quote tokens in this market's own wei.
    function _q(uint256 whole) internal view returns (uint256) {
        return whole * 10 ** qDec;
    }

    /// @dev Whole collateral tokens in this market's own wei.
    function _c(uint256 whole) internal view returns (uint256) {
        return whole * 10 ** cDec;
    }

    /// @dev The largest principal the gate can admit for `(k, units)` at the CONSERVATIVE floor.
    /// @dev Conservative because the real floor is whichever tick the top-down walk reaches, never lower.
    /// @dev The COVERAGE LINE spends `maxClaimTicks` of the position before the trigger sees any of it.
    /// @dev So the tick cap comes off the units first, and the `1/k` bound is taken on what backs the debt.
    function _maxDebtAt(uint256 k, uint256 units) internal view returns (uint256) {
        uint256 backing = units > 1 ? units - 1 : 0; // the coverage line spends ONE atom before the trigger sees any
        return FullMath.mulDiv(FullMath.mulDiv(tLo, backing, unitScale), 1e18, k);
    }

    /// @dev The units that make `debt` exactly admissible at the lowest seeded tick.
    /// @dev The COVERAGE LINE is `requiredAt + maxClaimTicks`, so the tick cap rides on the trigger's ceiling.
    /// @dev Without it the admission fuzz would refuse every draw again and go vacuous, which is the trap it names.
    function _unitsFor(uint256 k, uint256 debt) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(k * debt, unitScale, tLo * 1e18) + 1;
    }

    /// @dev What settlement would need: the live claim at the market's price, ceiled as `collateralNeeded` ceils.
    /// @dev IT SUMMED A CEILING PER FUNDED TICK, each at that tick's OWN price, and the sum of those ceilings
    /// @dev exceeding the ceiling of the sum is the whole coverage gap this file measures. One claim, one ceiling.
    function _need(bytes32 id, uint256 loanId) internal view returns (uint256) {
        uint256 amt = read.claimOf(id, loanId);
        if (amt == 0) return 0;
        uint256 price = ace.idToMarketParams(id).price;
        return (amt * unitScale + price - 1) / price;
    }

    /// @dev Claims carrying a live balance: the count `collateralNeeded` pays a ceiling for. One or zero.
    function _liveTicks(bytes32 id, uint256 loanId) internal view returns (uint256) {
        return read.claimCount(id, loanId);
    }

    /// @notice Take everything the HUB will part with, whichever line it is compiled against.
    /// @dev The lens's answer first, then a halving descent over the tick cap for whatever is left.
    /// @dev It must not read the line off the lens alone, or a hub gated LOWER would never be driven to its edge.
    /// @dev The coverage assertion below would then be checking a position the hub does not actually allow.
    /// @param loanId The loan to drain.
    /// @param maxClaimTicks The market's tick cap, which bounds the residual the descent has to clear.
    /// @return held The units the loan is left holding.
    function _drainToHubLine(uint256 loanId, uint256 maxClaimTicks) internal returns (uint256 held) {
        bytes32 id = read.loan(loanId).market;
        uint256 w = lens.withdrawableUnits(id, loanId);
        held = read.loan(loanId).collateralUnits;
        if (w != 0 && w < held) {
            vm.prank(borrower);
            ace.withdrawCollateral(loanId, w, borrower);
        }
        for (uint256 step = maxClaimTicks; step != 0; step >>= 1) {
            held = read.loan(loanId).collateralUnits;
            if (step >= held) continue; // a full drain is refused by name; never spend a step on it
            vm.prank(borrower);
            try ace.withdrawCollateral(loanId, step, borrower) {} catch {}
        }
        held = read.loan(loanId).collateralUnits;
    }

    /* ===================== the admission-edge guarantee ===================== */

    /// @notice THE GUARANTEE, fuzzed along the ADMISSIBLE EDGE rather than at random.
    /// @dev The draw is a percentage of the largest principal the gate can admit for the fuzzed `(k, units)`.
    /// @dev It is computed against the LOWEST tick's price, which is conservative: the real floor is never lower.
    /// @dev So every run opens a real loan, and `pct = 100` sits exactly on the boundary the property is about.
    /// @dev An earlier version fuzzed `principal` freely and was VACUOUS: almost every draw was refused.
    /// @dev The catch swallowed it, and loosening the admission gate 3x did not fail the test.
    /// @dev That is the failure mode this shape exists to avoid: a fuzz that never reaches its own subject.
    /// @dev `units` is derived from the market's own dust floor rather than fuzzed in raw wei.
    /// @dev So the draw lands inside the seeded cash at EVERY decimal pair, instead of being assumed away at most.
    function testFuzz_AdmittedLoan_IsAlwaysCoveredAtSettlement(uint256 k, uint256 unitsSeed, uint256 pct, uint256 decSeed, uint256 tickSeed, uint256 spanSeed)
        public
    {
        k = bound(k, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD); // the margin is exactly 1/k
        pct = bound(pct, 1, 100);

        // scoped so the decimal pair and tick triple leave the frame: same market, a legacy stack budget
        bytes32 id;
        {
            (uint8 cd, uint8 qd) = _decimals(decSeed);
            (int24 lo, int24 mid, int24 hi) = _ticks(tickSeed, spanSeed);
            id = _market(k, cd, qd, lo, mid, hi);
        }
        uint256 minDebt = ace.idToMarketParams(id).minDebt;
        uint256 units = bound(unitsSeed, _unitsFor(k, minDebt), _unitsFor(k, 20_000 * minDebt));
        uint256 principal = (_maxDebtAt(k, units) * pct) / 100;
        vm.assume(principal >= minDebt && principal <= 3 * perTick);

        _assertAdmittedLoanIsCovered(id, k, units, principal);
    }

    /// @dev The admit-then-settle half of the fuzz above, verbatim.
    /// @dev Extracted only for the frame: six live seeds plus the draw's own locals overrun the legacy stack.
    function _assertAdmittedLoanIsCovered(bytes32 id, uint256 k, uint256 units, uint256 principal) internal {
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        // MUST be admitted; a revert is a real failure
        uint256 loanId = ace.open(id, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 held = read.loan(loanId).collateralUnits;
        uint256 need = _need(id, loanId);
        assertEq(need, lens.collateralNeeded(id, loanId), "the shipped view and this file's derivation must agree");
        assertLe(need, held, "an admitted loan cannot be short at settlement");

        // and the margin is the k margin, not luck: need <= units / k, up to per-tick ceiling dust
        uint256 ceilingDust = read.claimCount(id, loanId);
        assertLe(need, FullMath.mulDiv(held, 1e18, k) + ceilingDust, "coverage margin is exactly the 1/k bound");
    }

    /// @dev A legal `(collateral, quote)` decimal pair, over exactly the envelope MarketInit admits.
    /// @dev `MAX_DECIMALS` on each end is the WHOLE envelope: there is no gap term on either side.
    /// @dev So the sweep reaches the widest pairs, gap 18 included, which no relative rail excludes any more.
    function _decimals(uint256 seed) internal pure returns (uint8 cd, uint8 qd) {
        cd = uint8(bound(seed, 0, Constants.MAX_DECIMALS));
        qd = uint8(bound(uint256(keccak256(abi.encode(seed))), 0, Constants.MAX_DECIMALS));
    }

    /// @dev Three distinct grid OFFSETS FROM PAR, low to high, every price under the two-quote draw cap.
    /// @dev THE PRICE DIMENSION: the exposure lives in `priceAt(t) / unitScale`, which price also moves.
    function _ticks(uint256 tickSeed, uint256 spanSeed) internal pure returns (int24 lo, int24 mid, int24 hi) {
        hi = int24(int256(bound(tickSeed, 0, 200)) - 100) * SPACING; // -6000 .. +6000 off par; 2x par is +6931
        int24 span = int24(int256(bound(spanSeed, 2, 60)));
        lo = hi - span * SPACING;
        mid = lo + (span / 2) * SPACING;
    }

    /* ============ past admission: the withdrawal gate's own line ============ */

    /// @notice THE HALF ADMISSION NEVER REACHED: a loan withdrawn to the gate's line, then settled.
    /// @notice The gate leaves ONE ceiling over the whole debt; settlement takes one per funded tick.
    /// @dev A sum of ceilings is not the ceiling of a sum, so the gate has to carry the tick count too.
    /// @dev The debt melts to a FUZZED POWER OF TWO rather than to a fuzzed fraction.
    /// @dev The exposure is `(k - 1) x debt / omega < n`, which lives in the bottom decades of the debt.
    /// @dev A uniform residual never visits them, so this is the dimension the old suite had no axis for.
    /// @dev Asserted on `shortfallOf`, which `_settle` itself writes: no mirrored arithmetic decides it.
    function testFuzz_WithdrawnToTheLine_IsAlwaysCoveredAtSettlement(uint256 decSeed, uint256 tickSeed, uint256 spanSeed, uint256 dustSeed, uint256 kSeed)
        public
    {
        uint256 k = bound(kSeed, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        (uint8 cd, uint8 qd) = _decimals(decSeed);
        (int24 lo, int24 mid, int24 hi) = _ticks(tickSeed, spanSeed);
        bytes32 id = _market(k, cd, qd, lo, mid, hi);

        uint256 principal = 2 * perTick + perTick / 2; // WAS sized to span three seeded rungs; it is one draw now
        uint256 units = _unitsFor(k, principal) * 2; // cushion, so the draw is admitted at any price the seed picks
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        uint256 loanId = ace.open(id, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        /// @dev WAS `> 1`: the subject was a draw spanning several rungs, because the per-tick ceiling gap
        /// @dev grew with the count. A draw holds ONE claim, so the premise is simply that it funded at all.
        assertEq(_liveTicks(id, loanId), 1, "fixture: the draw funded, and a draw holds exactly one claim");

        _meltTo(loanId, 1 << bound(dustSeed, 0, 120)); // 1 wei .. ~1.3e36 of residual debt
        uint256 held = _drainToHubLine(loanId, 1);
        assertLe(lens.collateralNeeded(id, loanId), held, "a loan on the hub's withdrawal line still covers settlement");

        vm.warp(read.loan(loanId).expiry + 1);
        ace.forceClose(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "fixture: the expiry fold must actually settle the loan");
        (uint256 short,) = read.shortfallOf(loanId);
        assertEq(short, 0, "a loan settled off the withdrawal line must leave its lenders whole");
    }

    /// @dev Repay down to `target`, the route into the dust window that needs no melt channel wired.
    /// @dev A no-op when the debt is already at or under it, so the whole dust range stays reachable.
    function _meltTo(uint256 loanId, uint256 target) internal {
        uint256 debt = read.loan(loanId).debt;
        if (debt <= target) return;
        uint256 pay = debt - target;
        usdc.mint(borrower, pay);
        vm.startPrank(borrower);
        usdc.approve(address(ace), pay);
        ace.repay(loanId, pay);
        vm.stopPrank();
    }

    /// @notice The lens's line IS the hub's line, pinned by a one-wei-past refusal at the 8/18 regime.
    /// @dev Without this the drain above cannot tell a lens that over-reports from a hub that under-gates.
    /// @dev BY SELECTOR: a bare expectRevert would accept any refusal and leave the line unpinned.
    function test_LensWithdrawLine_IsExactlyTheHubGate() public {
        bytes32 id = _market(1.4e18, 8, 18, -960, 0, 960);
        uint256 principal = 2 * perTick;
        uint256 units = _unitsFor(1.4e18, principal) * 2;
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        uint256 loanId = ace.open(id, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 w = lens.withdrawableUnits(id, loanId);
        assertGt(w, 0, "fixture: the loan must hold more than its line for the probe to mean anything");

        vm.prank(borrower);
        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(loanId, w + 1, borrower);

        vm.prank(borrower);
        ace.withdrawCollateral(loanId, w, borrower);
        assertEq(lens.withdrawableUnits(id, loanId), 0, "the loan now sits exactly on the line the lens reported");
    }

    /* ======================= the fixed-point legs ======================= */

    /// @notice THE OTHER HALF OF THE PROPERTY: the gate must actually REFUSE past the boundary.
    /// @dev Without this the coverage fuzz is one-sided and cannot see a loosened gate.
    /// @dev It derives its draw from the envelope it expects, so a wider gate admits loans it never asks for.
    /// @dev Verified by mutation: `trig > floor` to `trig > floor * 3` leaves the fuzz green and fails THIS.
    /// @dev The 2x probe is safely past the conservative floor used above.
    /// @dev Drawing top-down, the real floor exceeds `priceAt(tLo)` by at most the tHi/tLo price ratio (~1.21).
    function test_Gate_RefusesJustPastTheCoverageBoundary() public {
        uint256 k = 1.4e18;
        bytes32 id = _market(k);
        uint256 units = _c(20_000);

        uint256 maxDebt = _maxDebtAt(k, units);
        assertLt(maxDebt * 2, 3 * perTick, "the probe must fail on the GATE, not on available cash");

        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        /// @dev BY SELECTOR, deliberately. A bare `vm.expectRevert()` accepts ANY revert.
        /// @dev It stays green when a loosened gate lets the draw through and something else refuses it.
        /// @dev Which is exactly what happened on the first attempt at this test.
        vm.expectRevert(TriggerAboveFloor.selector);
        ace.open(id, units, maxDebt * 2, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice The margin at the SHIPPED k, stated as a number rather than a bound: ~29% spare.
    function test_ShippedK_LeavesTheMarginTheBountyWouldHaveToEat() public {
        bytes32 id = _market(1.4e18);
        uint256 units = _c(100_000); // sized so a 30k draw clears trigger <= floor at both k values
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        uint256 loanId = ace.open(id, units, _q(30_000), 0, borrower, OpenBounds(0, 0, 0)); // spans tHi through tMid
        vm.stopPrank();

        uint256 held = read.loan(loanId).collateralUnits;
        uint256 need = _need(id, loanId);
        assertLe(need, held, "covered");
        assertGt(held - need, (held * 20) / 100, "at least 20% of the position is spare at settlement");
    }

    /// @notice MIN_K is where the guarantee is thinnest, and it must still hold there.
    function test_MinK_StillCovers() public {
        bytes32 id = _market(1.05e18);
        uint256 units = _c(100_000); // sized so a 30k draw clears trigger <= floor at both k values
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        uint256 loanId = ace.open(id, units, _q(30_000), 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        assertLe(_need(id, loanId), read.loan(loanId).collateralUnits, "covered even at MIN_K");
    }
}
