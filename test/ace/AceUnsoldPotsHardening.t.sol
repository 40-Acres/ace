// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, NoRecordPrice} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {AceInventoryLens, TornRead} from "../../src/ace/lens/AceInventoryLens.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {UnresolvedProbeToken} from "../mocks/UnresolvedProbeToken.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";

/// @title AceUnsoldPotsHardening
/// @notice The hardening pass over the unsold-pot count and the whole-pot sale (#803 half b), beside `AceUnsoldPots`.
/// @notice 1. `clearingBudget` is EXACT over collateral decimals {0,6,8,18}, quote {6,18}, fees {0,25,50} and a record floor at or above book.
/// @notice 2. The whole-pot charge is within the budget, never under the exact all-in value, and a split buy never pays less.
/// @notice 3. The count through a recordless coverage pot, the unpaid backstop, an armed roll and two markets in one pair.
/// @notice 4. The count and the clearing quote refuse a read from inside the collateral release of a buy and of a redeem.
/// @dev Expected values come from the hub's own reads or are spelled here; the count under test is never an input to them.
contract AceUnsoldPotsHardeningTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    AceLens internal lens;
    AceInventoryLens internal inv;
    MockERC20 internal usdc;

    address internal lender = address(0x1E4D);
    address internal borrower = address(0xB0BA);
    address internal buyer = address(0xB04E5);
    address internal keeper = address(0xCAFE);

    uint256 internal constant SCALE = 1 << 96; // the hub's fixed price frame

    struct Mkt {
        bytes32 id;
        MockERC20 quote;
        address coll;
        MockPersistenceRecord record; // zero on a recordless market
        uint256 one; // one whole quote token, in atoms
    }

    function setUp() public {
        _warpTo(1_000_000);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = new AceLens(address(ace));
        inv = new AceInventoryLens(address(ace), address(lens));
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    // ---- fixtures ----

    /// @dev A market at `price`, its record's floor at `floor_` (zero builds a RECORDLESS market), lent by `lender`.
    function _market(MockERC20 quote, address coll, uint16 fee, uint256 price, uint256 floor_) internal returns (Mkt memory m) {
        (m.quote, m.coll, m.one) = (quote, coll, 10 ** quote.decimals());
        MarketParams memory p = AceFixtures.marketParams(address(quote), coll);
        if (floor_ != 0) {
            m.record = new MockPersistenceRecord(address(quote), coll);
            m.record.setObserved(price);
            m.record.setMinPrice(floor_);
            p.record = address(m.record);
        }
        p.price = price;
        p.lender = lender;
        p.fillFeeBps = fee;
        p.minDebt = 10 * m.one;
        m.id = ace.createMarket(p);
    }

    /// @dev A fuzzed pair: collateral decimals from {0,6,8,18}, quote from {6,18}, the price par moved by up to ~30% either way.
    /// @dev Moved by a tick offset, so the per-atom ratio is almost never integral and every ceiling is observable.
    function _fuzzMarket(uint256 cdSeed, uint256 qdSeed, uint16 fee, uint256 offsetSeed, uint256 floorSeed) internal returns (Mkt memory m) {
        uint8[4] memory cds = [uint8(0), 6, 8, 18];
        MockERC20 quote = qdSeed % 2 == 0 ? usdc : new MockERC20("Dai", "DAI", 18);
        MockERC20 coll = new MockERC20("Collateral", "COLL", cds[cdSeed % 4]);
        uint256 price = AceFixtures.priceAt(address(quote), address(coll), int24(int256(bound(offsetSeed, 0, 5200))) - 2600);
        uint256 floorBps = floorSeed % 2 == 0 ? 0 : bound(floorSeed, 1, 20_000); // an even seed puts the floor AT book; above it the floor is the ask
        m = _market(quote, address(coll), fee, price, price + FullMath.mulDiv(price, floorBps, 10_000));
    }

    /// @dev One named frame, deterministically: collateral `cd`, quote `qd`, fee, and the floor at book or 37% over it.
    function _gridMarket(uint8 cd, uint8 qd, uint16 fee, bool above) internal returns (Mkt memory m) {
        MockERC20 quote = qd == 6 ? usdc : new MockERC20("Dai", "DAI", 18);
        MockERC20 coll = new MockERC20("Collateral", "COLL", cd);
        uint256 price = AceFixtures.priceAt(address(quote), address(coll), 777); // ~8% over par: a non-integral ratio in every frame
        m = _market(quote, address(coll), fee, price, above ? price + FullMath.mulDiv(price, 3_700, 10_000) : price);
    }

    /// @dev Lend `principal` and a margin, and draw `principal` against collateral worth three times it at the market's price.
    function _loan(Mkt memory m, uint256 principal) internal returns (uint256 loanId) {
        uint256 cash = principal + 100 * m.one;
        m.quote.mint(lender, cash);
        vm.startPrank(lender);
        m.quote.approve(address(ace), cash);
        ace.deposit(m.id, cash);
        vm.stopPrank();
        uint256 units = FullMath.mulDivRoundingUp(3 * principal, SCALE, ace.idToMarketParams(m.id).price) + 2;
        MockERC20(m.coll).mint(borrower, units);
        vm.startPrank(borrower);
        MockERC20(m.coll).approve(address(pm), units);
        loanId = ace.open(m.id, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Settle by distress, then warp to the moment the pot's ask opens.
    function _finalize(Mkt memory m, uint256 loanId) internal {
        m.record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        m.record.setBelow(false);
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
    }

    function _buy(Mkt memory m, uint256 loanId, uint256 budget) internal returns (uint256 unitsOut, uint256 filled) {
        m.quote.mint(buyer, budget);
        vm.startPrank(buyer);
        m.quote.approve(address(ace), budget);
        (unitsOut, filled) = ace.buyInventory(loanId, budget, 0, buyer);
        vm.stopPrank();
    }

    /// @dev The ask the hub quotes a pot at: the market's price, lifted to the record's floor, read off the lens.
    function _ask(Mkt memory m) internal view returns (uint256) {
        (, uint256 cap) = lens.recordStateOf(m.id);
        return Math.max(ace.idToMarketParams(m.id).price, cap == type(uint256).max ? 0 : cap);
    }

    /// @dev The ruled whole-pot charge ( at `deliver = inv`): the value ceiled, plus its fee ceiled.
    function _wholeCharge(Mkt memory m, uint256 units) internal view returns (uint256) {
        uint256 g = FullMath.mulDivRoundingUp(units, _ask(m), SCALE);
        return g + Math.ceilDiv(g * ace.idToMarketParams(m.id).fillFeeBps, 10000);
    }

    function _count(Mkt memory m) internal view returns (uint256 n) {
        (n,) = ace.lenderUnresolved(lender, address(m.quote));
    }

    function _fee(uint256 seed) internal pure returns (uint16) {
        uint16[3] memory fees = [uint16(0), 25, 50];
        return fees[seed % 3];
    }

    // ============ 1. the clearing quote is exact ============

    /// @notice The lens's budget empties the pot, and one atom less does not, in every decimal frame, fee and floor.
    /// @notice A fee of 50 bps is the genesis ceiling, and a floor at book takes the other branch of `max(book, floor)`.
    function testFuzz_ClearingBudget_IsExactAcrossDecimalsFeesAndFloors(
        uint256 cdSeed,
        uint256 qdSeed,
        uint256 feeSeed,
        uint256 offsetSeed,
        uint256 floorSeed,
        uint256 principalSeed
    ) public {
        Mkt memory m = _fuzzMarket(cdSeed, qdSeed, _fee(feeSeed), offsetSeed, floorSeed);
        uint256 loanId = _loan(m, bound(principalSeed, 100, 4_500) * m.one);
        _finalize(m, loanId);
        _assertClearingExact(m, loanId);
    }

    /// @notice THE NAMED GRID, every cell pinned rather than sampled: 4 collateral decimals x 2 quotes x 3 fees x 2 floors, 48 markets.
    /// @notice Each cell's quote is exact, and its whole-pot charge sits on the exact all-in value within the two ceilings.
    /// @dev The fuzz rows above sample around this grid; this row is what a known-good cell is held to by argument.
    function test_ClearingBudget_IsExactOnEveryNamedFrame() public {
        uint8[4] memory cds = [uint8(0), 6, 8, 18];
        uint8[2] memory qds = [uint8(6), 18];
        uint16[3] memory fees = [uint16(0), 25, 50];
        for (uint256 a; a < 4; a++) {
            for (uint256 b; b < 2; b++) {
                for (uint256 c; c < 3; c++) {
                    for (uint256 d; d < 2; d++) {
                        Mkt memory m = _gridMarket(cds[a], qds[b], fees[c], d == 1);
                        uint256 loanId = _loan(m, 1_234 * m.one);
                        _finalize(m, loanId);
                        _assertChargeBounds(m, loanId);
                        _assertClearingExact(m, loanId);
                    }
                }
            }
        }
    }

    /// @dev The whole-pot charge against the exact all-in value `pot * ask * (1 + fee)`, before the clearing check spends the pot.
    function _assertChargeBounds(Mkt memory m, uint256 loanId) internal view {
        uint256 pot = read.invPotOf(m.id, loanId);
        uint256 fee = ace.idToMarketParams(m.id).fillFeeBps;
        uint256 charge = _wholeCharge(m, pot);
        uint256 allInCeil = FullMath.mulDivRoundingUp(pot, _ask(m) * (10_000 + fee), SCALE * 10_000);
        assertGe(charge, allInCeil, "grid: never under the exact all-in value");
        assertLe(charge, FullMath.mulDiv(pot, _ask(m) * (10_000 + fee), SCALE * 10_000) + 2, "grid: at most two atoms over it");
        assertGe(inv.clearingBudget(m.id, loanId), charge, "grid: the quote covers the charge");
    }

    /// @notice The same, in the CHEAP-ATOM regime: a price of a few Q96 units, where the sizing price's per-atom fee ceiling dominates.
    /// @dev There the floor-priced take, not the whole-pot charge, is the binding term; a quote dropping it is short by up to the pot's ceilings.
    function testFuzz_ClearingBudget_IsExactWhereAnAtomIsNearlyFree(uint256 priceSeed, uint256 feeSeed, uint256 principalSeed) public {
        MockERC20 coll = new MockERC20("Dust", "DUST", 18);
        uint16 fee = feeSeed % 2 == 0 ? 25 : 50;
        uint256 price = bound(priceSeed, 50, 1_999); // under 2,000 Q96 units: `ceil(price * fee / 1e4)` is a whole unit or more of the fee
        if ((price * fee) % 10000 == 0) price += 1; // a remainder, so the per-atom ceiling really lifts the sizing price
        Mkt memory m = _market(usdc, address(coll), fee, price, price);
        uint256 loanId = _loan(m, bound(principalSeed, 100, 4_500) * m.one);
        _finalize(m, loanId);
        uint256 pot = read.invPotOf(m.id, loanId);
        uint256 eff = price + Math.ceilDiv(price * fee, 10000);
        assertGt(FullMath.mulDivRoundingUp(pot, eff, SCALE), _wholeCharge(m, pot), "PREMISE: the floor-priced take is the binding term here");
        _assertClearingExact(m, loanId);
    }

    /// @notice The quote is zero where nothing can be bought: a record that answers no price, though the pot is full.
    /// @dev The buy refuses `NoRecordPrice` in the same state, so the zero is the hub's own answer and not a lens default.
    function test_ClearingBudget_IsZeroWhileTheRecordCannotPrice() public {
        Mkt memory m = _market(usdc, address(new MockERC20("C", "C", 18)), 25, _par(18), 2 * _par(18));
        uint256 loanId = _loan(m, 4_500e6);
        _finalize(m, loanId);
        assertGt(inv.clearingBudget(m.id, loanId), 0, "PREMISE: a priced pot quotes");
        m.record.setMinPrice(0);
        assertGt(read.invPotOf(m.id, loanId), 0, "PREMISE: the pot is still full");
        assertEq(inv.clearingBudget(m.id, loanId), 0, "a record that cannot price quotes zero");
        m.quote.mint(buyer, 1_000_000e6);
        vm.startPrank(buyer);
        m.quote.approve(address(ace), 1_000_000e6);
        vm.expectRevert(NoRecordPrice.selector);
        ace.buyInventory(loanId, 1_000_000e6, 0, buyer);
        vm.stopPrank();
    }

    function _assertClearingExact(Mkt memory m, uint256 loanId) internal {
        uint256 pot = read.invPotOf(m.id, loanId);
        assertGt(pot, 0, "PREMISE: the settlement left a pot");
        assertEq(_count(m), 1, "PREMISE: and it counts");
        uint256 budget = inv.clearingBudget(m.id, loanId);
        uint256 charge = _wholeCharge(m, pot);
        assertGe(budget, charge, "the quote covers the whole-pot charge");

        uint256 snap = vm.snapshotState();
        (uint256 u1, uint256 f1) = _buy(m, loanId, budget - 1);
        assertLt(u1, pot, "one atom under the quote buys a part at most");
        assertLe(f1, budget - 1, "and is charged within it");
        assertEq(read.invPotOf(m.id, loanId), pot - u1, "so the pot keeps the rest");
        assertEq(_count(m), 1, "and stays counted");
        vm.revertToState(snap);

        (uint256 u2, uint256 f2) = _buy(m, loanId, budget);
        assertEq(u2, pot, "the quote buys every atom");
        assertEq(read.invPotOf(m.id, loanId), 0, "so the pot is empty");
        assertEq(f2, charge, "at the whole-pot charge");
        assertEq(_count(m), 0, "and the count clears");
    }

    // ============ 2. the whole-pot charge ============

    /// @notice A whole buy at any budget past the quote: within `stableIn`, never under the exact all-in value, at most two atoms over it.
    /// @notice "Exact all-in" is `pot * ask * (1 + fee)` with no rounding; the bound is the two ceilings, one per term.
    /// @dev The fee here is ANY genesis-legal value, not the three named ones: the at-most-two form below is the ceiled one, which holds for all.
    function testFuzz_WholePotCharge_IsBoundedByTheExactValue(
        uint256 cdSeed,
        uint256 qdSeed,
        uint256 feeSeed,
        uint256 offsetSeed,
        uint256 floorSeed,
        uint256 principalSeed,
        uint256 overSeed
    ) public {
        uint16 fee = uint16(bound(feeSeed, 0, 50));
        Mkt memory m = _fuzzMarket(cdSeed, qdSeed, fee, offsetSeed, floorSeed);
        uint256 loanId = _loan(m, bound(principalSeed, 100, 4_500) * m.one);
        _finalize(m, loanId);
        uint256 pot = read.invPotOf(m.id, loanId);
        uint256 budget = inv.clearingBudget(m.id, loanId);
        budget += bound(overSeed, 0, budget);

        (uint256 units, uint256 charge) = _buy(m, loanId, budget);
        assertEq(units, pot, "a budget at or past the quote takes the whole pot");
        assertLe(charge, budget, "never past stableIn");
        uint256 allInCeil = FullMath.mulDivRoundingUp(pot, _ask(m) * (10_000 + fee), SCALE * 10_000);
        uint256 allInFloor = FullMath.mulDiv(pot, _ask(m) * (10_000 + fee), SCALE * 10_000);
        assertGe(charge, allInCeil, "the lender is never short of the exact all-in value of what left");
        assertLe(charge, allInCeil + 2, "and the buyer pays at most two atoms over it, ceiled");
        if (10_000 % uint256(fee == 0 ? 1 : fee) == 0) assertLe(charge, allInFloor + 2, "two atoms over the exact value, where the fee divides 1e4");
    }

    /// @notice Clearing a pot in two buys, or three, never costs less than one whole buy: each piece's charge ceils on its own.
    function testFuzz_WholePotCharge_ASplitNeverPaysLess(
        uint256 cdSeed,
        uint256 qdSeed,
        uint256 feeSeed,
        uint256 offsetSeed,
        uint256 floorSeed,
        uint256 principalSeed,
        uint256 splitSeed
    ) public {
        Mkt memory m = _fuzzMarket(cdSeed, qdSeed, _fee(feeSeed), offsetSeed, floorSeed);
        uint256 loanId = _loan(m, bound(principalSeed, 100, 4_500) * m.one);
        _finalize(m, loanId);
        uint256 pot = read.invPotOf(m.id, loanId);
        uint256 budget = inv.clearingBudget(m.id, loanId);
        uint256 snap = vm.snapshotState();
        (, uint256 whole) = _buy(m, loanId, budget);
        assertEq(read.invPotOf(m.id, loanId), 0, "PREMISE: one buy at the quote clears it");
        vm.revertToState(snap);

        (uint256 units, uint256 paid) = _threePieces(m, loanId, bound(splitSeed, 0, budget - 1));
        assertEq(units, pot, "the pieces delivered the pot between them");
        assertEq(read.invPotOf(m.id, loanId), 0, "and emptied it");
        assertGe(paid, whole, "and together paid at least the one-buy charge");
        assertEq(_count(m), 0, "the last piece cleared the count, once");
    }

    /// @dev A part, half of that part again, then whatever the lens quotes for the rest.
    function _threePieces(Mkt memory m, uint256 loanId, uint256 first) internal returns (uint256 units, uint256 paid) {
        (uint256 u, uint256 f) = _buy(m, loanId, first);
        (units, paid) = (u, f);
        (u, f) = _buy(m, loanId, first / 2);
        (units, paid) = (units + u, paid + f);
        (u, f) = _buy(m, loanId, inv.clearingBudget(m.id, loanId));
        (units, paid) = (units + u, paid + f);
    }

    // ============ 3. the count through every door ============

    /// @notice A RECORDLESS market forfeits the whole coverage line into the pot, spread first; the settlement still counts ONCE.
    /// @notice Through both expiry doors, and each pot clears at the lens's quote, which prices a recordless pot at book.
    function test_Count_ARecordlessCoveragePotCountsOnceThroughEitherExpiryDoor() public {
        Mkt memory m = _market(usdc, address(new MockERC20("C", "C", 18)), 25, _par(18), 0);
        uint256 a = _loan(m, 4_500e6);
        uint256 b = _loan(m, 4_500e6);
        uint256 needA = FullMath.mulDivRoundingUp(read.claimOf(m.id, a), SCALE, _par(18));

        _warpAtLeastTo(read.loan(a).expiry + 1);
        vm.prank(keeper);
        ace.forceClose(a);
        assertGt(read.invPotOf(m.id, a), needA, "PREMISE: the coverage spread landed in the pot beside the claim's need");
        assertEq(_count(m), 1, "the spread and the claim are ONE settlement, so one count");

        _warpAtLeastTo(read.loan(b).expiry + 1 days);
        vm.prank(keeper);
        ace.settleExpired(b);
        assertGt(read.invPotOf(m.id, b), 0, "PREMISE: the unpaid backstop left a pot");
        assertEq(_count(m), 2, "and the backstop's counts beside it");

        _warpAtLeastTo(read.inventoryAskOpensAt(b));
        _buy(m, a, inv.clearingBudget(m.id, a));
        assertEq(_count(m), 1, "a buy at the quote clears the forceClose pot");
        _buy(m, b, inv.clearingBudget(m.id, b));
        assertEq(read.invPotOf(m.id, b), 0, "PREMISE: and the backstop's");
        assertEq(_count(m), 0, "so the count is clear");
    }

    /// @notice The unpaid backstop on a RECORD market: its pot counts, and the in-kind redeem and a buy each take one off.
    function test_Count_SettleExpiredOnARecordMarketCountsAndBothExitsClear() public {
        Mkt memory m = _market(usdc, address(new MockERC20("C", "C", 18)), 25, _par(18), 2 * _par(18));
        uint256 a = _loan(m, 4_500e6);
        uint256 b = _loan(m, 4_500e6);
        _warpAtLeastTo(read.loan(b).expiry + 1 days);
        vm.startPrank(keeper);
        ace.settleExpired(a);
        ace.settleExpired(b);
        vm.stopPrank();
        assertEq(_count(m), 2, "two backstop settlements, two counts");
        vm.prank(lender);
        ace.redeemInKind(a, lender);
        assertEq(_count(m), 1, "the lender's redeem takes one off");
        _warpAtLeastTo(read.inventoryAskOpensAt(b));
        _buy(m, b, inv.clearingBudget(m.id, b));
        assertEq(_count(m), 0, "and the buy at the quote the other");
    }

    /// @notice An ARMED loan at expiry rolls into a successor: the fold closes it with no pot, so the count stands.
    /// @notice A buy on the rolled loan then meets an empty pot and takes nothing; the successor counts when it settles.
    function test_Count_AnArmedRollAtExpiryLeavesItUnchanged() public {
        Mkt memory m = _market(usdc, address(new MockERC20("C", "C", 18)), 25, _par(18), 2 * _par(18));
        uint256 settled = _loan(m, 4_500e6);
        _finalize(m, settled);
        assertEq(_count(m), 1, "PREMISE: one unsold pot");

        uint256 armed = _loan(m, 4_500e6);
        _lend(m, 20_000e6); // the successor draws afresh, so the market must still fund it
        uint64 tenor = read.loan(armed).tenor; // read before the prank, which the next external call spends
        vm.prank(borrower);
        ace.setAutoRefinance(armed, tenor, 0, 0);
        _warpAtLeastTo(read.loan(armed).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(armed);
        assertEq(read.loanCount(), n + 1, "PREMISE: the fold rolled into a successor rather than settling");
        assertTrue(read.loan(armed).closedAt != 0, "PREMISE: and retired the armed loan");
        assertEq(read.invPotOf(m.id, armed), 0, "with no pot");
        assertEq(_count(m), 1, "so the count stands at the one settled pot");

        _warpAtLeastTo(read.inventoryAskOpensAt(armed));
        (uint256 none,) = _buy(m, armed, 1_000e6);
        assertEq(none, 0, "PREMISE: the rolled loan's pot is empty");
        assertEq(_count(m), 1, "and a buy on it takes no other pot's count");

        _finalize(m, n + 1);
        assertEq(_count(m), 2, "the successor's own settlement counts");
    }

    /// @notice ONE PAIR, TWO MARKETS: the count is the lender's in a quote, so settlements in different markets add and each sale takes one.
    function test_Count_AggregatesAcrossTheLendersMarketsInOneQuote() public {
        Mkt memory x = _market(usdc, address(new MockERC20("X", "X", 18)), 25, _par(18), 2 * _par(18));
        Mkt memory y = _market(usdc, address(new MockERC20("Y", "Y", 0)), 0, _par(0), 0);
        uint256 a = _loan(x, 4_500e6);
        uint256 b = _loan(y, 4_500e6);
        _finalize(x, a);
        _warpAtLeastTo(read.loan(b).expiry + 1);
        vm.prank(keeper);
        ace.forceClose(b);
        assertEq(_count(x), 2, "a record market's pot and a recordless market's pot, one pair, two counts");
        _warpAtLeastTo(read.inventoryAskOpensAt(b));
        _buy(y, b, inv.clearingBudget(y.id, b));
        assertEq(_count(x), 1, "a sale in one market takes one off the pair");
        _buy(x, a, inv.clearingBudget(x.id, a));
        assertEq(_count(y), 0, "and the other the last");
    }

    // ============ 4. read-only reentrancy ============

    /// @notice A gate reading the count from inside a SALE's collateral release is refused by the hub's guard, never answered.
    /// @notice The lens's clearing quote refuses on its own account at the same moment, so neither read sees a torn sale.
    function test_Reentrancy_TheCountRefusesAReadFromInsideABuy() public {
        (Mkt memory m, UnresolvedProbeToken probe, uint256 loanId) = _probedPot();
        (uint256 units,) = _buy(m, loanId, inv.clearingBudget(m.id, loanId));
        assertGt(units, 0, "PREMISE: the sale delivered, so the release ran");
        _assertProbeRefused(probe);
        assertEq(_count(m), 0, "and once the body returns the count answers, cleared");
    }

    /// @notice The same from inside the lender's in-kind redeem, the pot's other exit.
    function test_Reentrancy_TheCountRefusesAReadFromInsideARedeem() public {
        (Mkt memory m, UnresolvedProbeToken probe, uint256 loanId) = _probedPot();
        vm.prank(lender);
        uint256 out = ace.redeemInKind(loanId, lender);
        assertGt(out, 0, "PREMISE: the redeem delivered, so the release ran");
        _assertProbeRefused(probe);
        assertEq(_count(m), 0, "and once the body returns the count answers, cleared");
    }

    function _probedPot() internal returns (Mkt memory m, UnresolvedProbeToken probe, uint256 loanId) {
        probe = new UnresolvedProbeToken();
        uint256 price = AceFixtures.priceAt(address(usdc), address(probe), 0);
        m = _market(usdc, address(probe), 25, price, 2 * price);
        uint256 cash = 4_600e6;
        usdc.mint(lender, cash);
        vm.startPrank(lender);
        usdc.approve(address(ace), cash);
        ace.deposit(m.id, cash);
        vm.stopPrank();
        uint256 units = FullMath.mulDivRoundingUp(3 * 4_500e6, SCALE, price) + 2;
        probe.mint(borrower, units);
        vm.startPrank(borrower);
        probe.approve(address(pm), units);
        loanId = ace.open(m.id, units, 4_500e6, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _finalize(m, loanId);
        assertEq(_count(m), 1, "PREMISE: the probed pot counts");
        probe.arm(address(ace), address(inv), address(pm), lender, address(usdc), m.id, loanId);
    }

    function _assertProbeRefused(UnresolvedProbeToken probe) internal view {
        assertEq(probe.snaps(), 1, "the release fired the observer exactly once");
        assertFalse(probe.countAnswered(), "the count did not answer mid-body");
        assertEq(bytes4(probe.countRevert()), GUARD_TRIP, "it refused as the hub's guard");
        assertFalse(probe.budgetAnswered(), "the clearing quote did not answer mid-body");
        assertEq(bytes4(probe.budgetRevert()), TornRead.selector, "it refused as the lens's torn-read rail");
    }

    // ---- helpers ----

    function _par(uint8 cd) internal returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(new MockERC20("P", "P", cd)), 0);
    }

    function _lend(Mkt memory m, uint256 amount) internal {
        m.quote.mint(lender, amount);
        vm.startPrank(lender);
        m.quote.approve(address(ace), amount);
        ace.deposit(m.id, amount);
        vm.stopPrank();
    }
}
