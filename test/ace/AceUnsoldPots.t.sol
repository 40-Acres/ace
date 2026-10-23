// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds, RecordState} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {Loan, Storage} from "../../src/ace/hub/Types.sol";
import {BelowCoverageLine} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";

/// @dev The two-word read, spelled here so the settled-count rows decode it without trusting the hub's own type.
interface IUnresolvedPair {
    function lenderUnresolved(address lender, address quote) external view returns (uint256 unsoldPots, uint256 settledPots);
}

/// @title AceUnsoldPots
/// @notice The hub half of the unsold-pot entry gate (#803 half b): a per-(lender, quote) count of settled pots not yet empty.
/// @notice And the whole-pot sale it needs to be live: a buy that takes the whole pot leaves no atom behind.
/// @dev Every expectation is read off the hub's own reads or spelled independently here, never off the counter under test.
contract AceUnsoldPotsTest is WarpClock {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    AceLens internal lens;
    AceInventoryLens internal inv;
    MockERC20 internal usdc;
    MockERC20 internal dai;

    address internal lender = address(0x1E4D);
    address internal other = address(0x0711E2);
    address internal borrower = address(0xB0BA);
    address internal buyer = address(0xB04E5);
    address internal keeper = address(0xCAFE);

    uint16 internal constant FEE_BPS = 25; // a fill fee, so the whole-pot charge rounds two terms up
    uint256 internal constant SEED = 5_000e6;
    uint256 internal constant PRINCIPAL = 4_500e6;

    struct Mkt {
        bytes32 id;
        MockERC20 quote;
        MockERC20 coll;
        MockPersistenceRecord record;
        address lender;
        uint256 units; // collateral a loan posts
    }

    function setUp() public {
        _warpTo(1_000_000);
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = new AceLens(address(ace));
        inv = new AceInventoryLens(address(ace), address(lens));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 6);
    }

    // ---- fixtures ----

    /// @dev A market of `cd`-decimal collateral, its record's draw cap at `capWad` (a human price; 1e18 is par).
    function _market(MockERC20 quote, uint8 cd, address who, bool ask, uint256 capWad, uint256 minDebt) internal returns (Mkt memory m) {
        m.quote = quote;
        m.coll = new MockERC20("Collateral", "COLL", cd);
        m.lender = who;
        m.units = 10_000 * 10 ** cd; // ten thousand whole tokens at par: well over the coverage the draw needs
        m.record = new MockPersistenceRecord(address(quote), address(m.coll));
        m.record.setObserved(AceFixtures.px(1e18, address(quote), address(m.coll)));
        m.record.setMinPrice(AceFixtures.px(capWad, address(quote), address(m.coll)));
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(m.coll));
        p.record = address(m.record);
        p.lender = who;
        p.inventoryAsk = ask;
        p.fillFeeBps = ask ? FEE_BPS : 0;
        p.minDebt = minDebt;
        m.id = ace.createMarket(p);
    }

    /// @dev The default ask-on market: 18-decimal collateral against USDC, lent by `lender`.
    function _eighteen() internal returns (Mkt memory) {
        return _market(usdc, 18, lender, true, 2e18, 10e6);
    }

    /// @dev Lend `SEED` and draw `PRINCIPAL`; returns the loan.
    function _loan(Mkt memory m) internal returns (uint256 loanId) {
        m.quote.mint(m.lender, SEED);
        vm.startPrank(m.lender);
        m.quote.approve(address(ace), SEED);
        ace.deposit(m.id, SEED);
        vm.stopPrank();
        m.coll.mint(borrower, m.units);
        vm.startPrank(borrower);
        m.coll.approve(address(positionManager), m.units);
        loanId = ace.open(m.id, m.units, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Settle by distress through `finalize`, then warp to the moment the pot's ask opens.
    function _finalize(Mkt memory m, uint256 loanId) internal {
        m.record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        m.record.setBelow(false);
        uint256 opens = read.inventoryAskOpensAt(loanId);
        if (opens != type(uint256).max) _warpAtLeastTo(opens);
    }

    /// @dev The ask the hub quotes this market's pots at: its price, lifted to the record's floor.
    function _ask(Mkt memory m) internal view returns (uint256) {
        (, uint256 cap) = lens.recordStateOf(m.id);
        return Math.max(ace.idToMarketParams(m.id).price, cap == type(uint256).max ? 0 : cap);
    }

    /// @dev What today's floor-only leg delivers for a take of `units`: whole units the floored quote buys back.
    function _floorDeliver(Mkt memory m, uint256 units) internal view returns (uint256) {
        uint256 scale = read.marketState(m.id).unitScale;
        uint256 a = _ask(m);
        return FullMath.mulDiv(FullMath.mulDiv(units, a, scale), scale, a);
    }

    /// @dev The whole-pot charge, spelled here: the pot's value ceiled, plus its fee ceiled.
    function _wholeCharge(Mkt memory m, uint256 units) internal view returns (uint256) {
        uint256 g = FullMath.mulDivRoundingUp(units, _ask(m), read.marketState(m.id).unitScale);
        return g + Math.ceilDiv(g * ace.idToMarketParams(m.id).fillFeeBps, 10000);
    }

    function _buy(Mkt memory m, uint256 loanId, uint256 budget) internal returns (uint256 unitsOut, uint256 filled) {
        m.quote.mint(buyer, budget);
        vm.startPrank(buyer);
        m.quote.approve(address(ace), budget);
        (unitsOut, filled) = ace.buyInventory(loanId, budget, 0, buyer);
        vm.stopPrank();
    }

    /// @dev A budget past any rounding: twice the pot's value plus a margin, so the take is the whole pot.
    function _generous(Mkt memory m, uint256 units) internal view returns (uint256) {
        return 2 * _wholeCharge(m, units) + 10;
    }

    function _count(Mkt memory m) internal view returns (uint256 n) {
        (n,) = ace.lenderUnresolved(m.lender, address(m.quote));
    }

    // ============ 1. the whole-pot sale ============

    /// @notice A buy that takes a whole 18-decimal pot leaves NO tail: today's double floor stranded one under the ask quantum.
    function test_WholePot_AWholeBuyEmptiesAnEighteenDecimalPot() public {
        Mkt memory m = _eighteen();
        uint256 loanId = _loan(m);
        _finalize(m, loanId);
        uint256 pot = read.invPotOf(m.id, loanId);
        assertGt(pot, 0, "PREMISE: the settlement left a pot");
        assertLt(_floorDeliver(m, pot), pot, "PREMISE: a floor-only leg would strand a tail of this pot");

        (uint256 unitsOut, uint256 filled) = _buy(m, loanId, _generous(m, pot));
        assertEq(unitsOut, pot, "the whole pot was delivered");
        assertEq(read.invPotOf(m.id, loanId), 0, "and the pot is empty");
        assertEq(m.coll.balanceOf(buyer), pot, "the buyer holds every atom");
        assertEq(filled, _wholeCharge(m, pot), "charged the ceiled value plus the ceiled fee, and not one atom of the margin");
    }

    /// @notice On a 0-decimal collateral at a non-integral price the last atom never left a pot; a whole buy takes it.
    function test_WholePot_AWholeBuyEmptiesAZeroDecimalPot() public {
        Mkt memory m = _market(usdc, 0, lender, true, 1.234567891e18, 10e6);
        uint256 loanId = _loan(m);
        _finalize(m, loanId);
        uint256 pot = read.invPotOf(m.id, loanId);
        assertGt(pot, 1, "PREMISE: a multi-unit pot");
        assertEq(_floorDeliver(m, pot), pot - 1, "PREMISE: a floor-only leg leaves exactly the last unit");

        (uint256 unitsOut, uint256 filled) = _buy(m, loanId, _generous(m, pot));
        assertEq(unitsOut, pot, "every unit was delivered, the last one included");
        assertEq(read.invPotOf(m.id, loanId), 0, "and the pot is empty");
        assertEq(filled, _wholeCharge(m, pot), "at the ceiled whole-pot charge");
    }

    /// @notice One atom short of the whole-pot charge buys a PART, exactly as today: the floor leg, nothing over budget.
    function test_WholePot_ABudgetShortOfTheChargeTakesThePartialLeg() public {
        Mkt memory m = _eighteen();
        uint256 loanId = _loan(m);
        _finalize(m, loanId);
        uint256 pot = read.invPotOf(m.id, loanId);
        uint256 budget = _wholeCharge(m, pot) - 1;

        (uint256 unitsOut, uint256 filled) = _buy(m, loanId, budget);
        assertLe(filled, budget, "never charged past the budget");
        assertLt(unitsOut, pot, "a part, not the whole");
        assertGt(read.invPotOf(m.id, loanId), 0, "so the pot keeps a residue");
    }

    /// @notice A pot cleared in two buys never costs less than one whole buy: each piece's charge ceils on its own.
    function test_WholePot_ASplitBuyNeverCostsLessThanOneWholeBuy() public {
        Mkt memory m = _eighteen();
        uint256 loanId = _loan(m);
        _finalize(m, loanId);
        uint256 pot = read.invPotOf(m.id, loanId);
        uint256 whole = _wholeCharge(m, pot);

        (uint256 u1, uint256 f1) = _buy(m, loanId, whole / 2);
        uint256 rest = read.invPotOf(m.id, loanId);
        (uint256 u2, uint256 f2) = _buy(m, loanId, _generous(m, rest));
        assertEq(u1 + u2, pot, "the two buys delivered the pot between them");
        assertEq(read.invPotOf(m.id, loanId), 0, "and emptied it");
        assertGe(f1 + f2, whole, "and together paid at least the one-buy charge");
    }

    // ============ 2. the count ============

    /// @notice A distress settlement that leaves a pot counts ONE for the market's lender in its quote; a whole buy clears it.
    function test_Count_AFinalizeCountsOneAndAWholeBuyClearsIt() public {
        Mkt memory m = _eighteen();
        uint256 loanId = _loan(m);
        assertEq(_count(m), 0, "nothing settled, nothing counted");
        _finalize(m, loanId);
        assertGt(read.invPotOf(m.id, loanId), 0, "PREMISE: a pot");
        assertEq(_count(m), 1, "the settled pot counts one");

        _buy(m, loanId, _generous(m, read.invPotOf(m.id, loanId)));
        assertEq(read.invPotOf(m.id, loanId), 0, "PREMISE: the pot emptied");
        assertEq(_count(m), 0, "and the count cleared with it");
    }

    /// @notice An expiry settlement counts too, through either expiry door.
    function test_Count_AnExpirySettlementCountsThroughForceCloseAndSettleExpired() public {
        Mkt memory m = _eighteen();
        uint256 a = _loan(m);
        _warpTo(read.loan(a).expiry + 1);
        vm.prank(keeper);
        ace.forceClose(a);
        assertGt(read.invPotOf(m.id, a), 0, "PREMISE: forceClose left a pot");
        assertEq(_count(m), 1, "forceClose's pot counts");

        uint256 b = _loan(m);
        _warpTo(read.loan(b).expiry + 1 days);
        vm.prank(keeper);
        ace.settleExpired(b);
        assertGt(read.invPotOf(m.id, b), 0, "PREMISE: settleExpired left a pot");
        assertEq(_count(m), 2, "and settleExpired's counts beside it");
    }

    /// @notice A partial buy leaves the pot unsold, so the count holds; only the buy that empties it clears it.
    function test_Count_APartialBuyKeepsItAndOnlyTheEmptyingBuyClearsIt() public {
        Mkt memory m = _eighteen();
        uint256 loanId = _loan(m);
        _finalize(m, loanId);
        uint256 pot = read.invPotOf(m.id, loanId);

        _buy(m, loanId, _wholeCharge(m, pot) / 3);
        assertGt(read.invPotOf(m.id, loanId), 0, "PREMISE: a part remains");
        assertEq(_count(m), 1, "a partial buy leaves it counted");

        _buy(m, loanId, _generous(m, read.invPotOf(m.id, loanId)));
        assertEq(_count(m), 0, "the emptying buy clears it");
    }

    /// @notice On a market without the ask the lender's in-kind redeem is the pot's door, and it clears the count.
    function test_Count_ARedeemInKindClearsIt() public {
        Mkt memory m = _market(usdc, 18, lender, false, 2e18, 10e6);
        uint256 loanId = _loan(m);
        _finalize(m, loanId);
        assertEq(_count(m), 1, "the ask-off pot counts while the lender has not taken it");

        vm.prank(lender);
        ace.redeemInKind(loanId, lender);
        assertEq(read.invPotOf(m.id, loanId), 0, "PREMISE: the redeem took the whole pot");
        assertEq(_count(m), 0, "and cleared the count");
    }

    /// @notice Two settled pots count two, and each emptying takes one off.
    function test_Count_TwoPotsCountTwoAndClearOneAtATime() public {
        Mkt memory m = _eighteen();
        uint256 a = _loan(m);
        uint256 b = _loan(m);
        _finalize(m, a);
        _finalize(m, b);
        assertEq(_count(m), 2, "two unsold pots");

        _buy(m, a, _generous(m, read.invPotOf(m.id, a)));
        assertEq(_count(m), 1, "one emptied");
        _buy(m, b, _generous(m, read.invPotOf(m.id, b)));
        assertEq(_count(m), 0, "both emptied");
    }

    /// @notice The count is keyed by the lender AND the quote: another party's pot, or the same party's in another quote, never moves it.
    function test_Count_IsKeyedByLenderAndQuote() public {
        Mkt memory mine = _eighteen();
        Mkt memory theirs = _market(usdc, 18, other, true, 2e18, 11e6);
        Mkt memory myDai = _market(dai, 18, lender, true, 2e18, 12e6);
        uint256 t = _loan(theirs);
        uint256 d = _loan(myDai);
        _finalize(theirs, t);
        _finalize(myDai, d);

        assertEq(_count(mine), 0, "another lender's pot and another quote's pot leave this pair untouched");
        assertEq(_count(theirs), 1, "the other lender's pair counts its own");
        assertEq(_count(myDai), 1, "and this lender's DAI pair counts apart from its USDC pair");
    }

    /// @notice A buy on a pot that is already empty, or on a loan that closed clean, never takes another pot's count.
    /// @dev The decrement fires on a fill that EMPTIES a pot; one keyed on `unitsOut == pot` would fire on `0 == 0` here.
    function test_Count_ABuyOnAnEmptyPotNeverClearsAnotherPotsCount() public {
        Mkt memory m = _eighteen();
        uint256 a = _loan(m);
        uint256 b = _loan(m);
        uint256 clean = _loan(m);
        _finalize(m, a);
        _finalize(m, b);
        uint256 debt = read.debtOf(clean);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(clean, debt);
        vm.stopPrank();
        uint256 opens = read.inventoryAskOpensAt(clean);
        _warpAtLeastTo(opens);

        _buy(m, a, _generous(m, read.invPotOf(m.id, a)));
        assertEq(_count(m), 1, "PREMISE: A emptied, B still counted");
        (uint256 again,) = _buy(m, a, 1_000e6);
        (uint256 none,) = _buy(m, clean, 1_000e6);
        assertEq(again + none, 0, "PREMISE: both buys met an empty pot");
        assertEq(_count(m), 1, "and B's count stands");
    }

    /// @notice A buy that delivers nothing leaves the count where it was.
    function test_Count_AZeroDeliverBuyLeavesItUnchanged() public {
        Mkt memory m = _market(usdc, 0, lender, true, 1.234567891e18, 10e6);
        uint256 loanId = _loan(m);
        _finalize(m, loanId);
        (uint256 unitsOut,) = _buy(m, loanId, 1);
        assertEq(unitsOut, 0, "PREMISE: one quote atom buys no whole unit");
        assertEq(_count(m), 1, "and the pot stays counted");
    }

    /// @notice A loan repaid in full closes clean and leaves no pot, so nothing counts.
    function test_Count_ACleanCloseCountsNothing() public {
        Mkt memory m = _eighteen();
        uint256 loanId = _loan(m);
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertEq(read.invPotOf(m.id, loanId), 0, "PREMISE: no pot");
        assertEq(_count(m), 0, "and no count");
    }

    // ============ 3. the clearing-budget quote ============

    /// @notice The lens quotes the smallest budget that empties a pot: it empties it, and one atom less does not.
    function test_Lens_TheClearingBudgetIsExactOnAnEighteenDecimalPot() public {
        Mkt memory m = _eighteen();
        uint256 loanId = _loan(m);
        _finalize(m, loanId);
        _assertClearingExact(m, loanId);
    }

    /// @notice The same on a 0-decimal pot at a non-integral price.
    function test_Lens_TheClearingBudgetIsExactOnAZeroDecimalPot() public {
        Mkt memory m = _market(usdc, 0, lender, true, 1.234567891e18, 10e6);
        uint256 loanId = _loan(m);
        _finalize(m, loanId);
        _assertClearingExact(m, loanId);
    }

    /// @notice Nothing to buy quotes zero: an empty pot, and a pot on a market without the ask.
    function test_Lens_NothingToBuyQuotesZero() public {
        Mkt memory m = _eighteen();
        uint256 loanId = _loan(m);
        assertEq(inv.clearingBudget(m.id, loanId), 0, "a live loan has no pot");
        Mkt memory off = _market(usdc, 18, lender, false, 2e18, 13e6);
        uint256 o = _loan(off);
        _finalize(off, o);
        assertGt(read.invPotOf(off.id, o), 0, "PREMISE: the ask-off pot exists");
        assertEq(inv.clearingBudget(off.id, o), 0, "and nobody may buy it, so it quotes zero");
    }

    function _assertClearingExact(Mkt memory m, uint256 loanId) internal {
        uint256 budget = inv.clearingBudget(m.id, loanId);
        assertGe(budget, _wholeCharge(m, read.invPotOf(m.id, loanId)), "never under the whole-pot charge");
        uint256 snap = vm.snapshotState();
        _buy(m, loanId, budget - 1);
        assertGt(read.invPotOf(m.id, loanId), 0, "one atom under the quote does not empty the pot");
        vm.revertToState(snap);
        _buy(m, loanId, budget);
        assertEq(read.invPotOf(m.id, loanId), 0, "the quote empties it");
    }

    // ============ 4. the settled count: every pot ever settled, so a reader can tell a new pot from an old one ============

    function _pair(Mkt memory m) internal view returns (uint256 unsold, uint256 settled) {
        return IUnresolvedPair(address(ace)).lenderUnresolved(m.lender, address(m.quote));
    }

    function _repay(uint256 loanId) internal {
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    /// @notice A pot that empties and a NEW pot that settles leave the unsold count where it was; the settled count moves.
    /// @dev The override a vault's guardian takes snapshots both: the same unsold count over a higher settled count is a new pot.
    function test_Settled_TellsANewPotFromTheOneItReplaced() public {
        Mkt memory m = _eighteen();
        uint256 a = _loan(m);
        uint256 b = _loan(m);
        (uint256 u0, uint256 s0) = _pair(m);
        assertEq(u0 + s0, 0, "nothing settled yet");

        _finalize(m, a);
        (uint256 u1, uint256 s1) = _pair(m);
        assertEq(u1, 1, "PREMISE: A is unsold");
        assertEq(s1, 1, "and A counts as settled");

        _buy(m, a, _generous(m, read.invPotOf(m.id, a)));
        _finalize(m, b);
        (uint256 u2, uint256 s2) = _pair(m);
        assertEq(u2, u1, "PREMISE: A sold and B settled, so the unsold count reads as it did");
        assertEq(s2, 2, "the settled count rose, so the reader sees B is not A");
    }

    /// @notice Neither emptying door lowers the settled count: a whole buy, and the lender's in-kind redeem.
    function test_Settled_NoEmptyingDoorLowersIt() public {
        Mkt memory on = _eighteen();
        uint256 a = _loan(on);
        _finalize(on, a);
        _buy(on, a, _generous(on, read.invPotOf(on.id, a)));
        (uint256 u, uint256 s) = _pair(on);
        assertEq(u, 0, "PREMISE: the buy emptied the pot");
        assertEq(s, 1, "and the pot stays counted as settled");

        Mkt memory off = _market(usdc, 18, lender, false, 2e18, 13e6);
        uint256 o = _loan(off);
        _finalize(off, o);
        vm.prank(lender);
        ace.redeemInKind(o, lender);
        (u, s) = _pair(off);
        assertEq(u, 0, "PREMISE: the redeem emptied the pot");
        assertEq(s, 2, "and both pots in this lender's USDC pair stay counted as settled");
    }

    /// @notice Both expiry doors count a settled pot, as `finalize` does.
    function test_Settled_EachExpiryDoorCountsOne() public {
        Mkt memory m = _eighteen();
        uint256 a = _loan(m);
        _warpTo(read.loan(a).expiry + 1);
        vm.prank(keeper);
        ace.forceClose(a);
        (, uint256 s) = _pair(m);
        assertEq(s, 1, "forceClose counts");

        uint256 b = _loan(m);
        _warpTo(read.loan(b).expiry + 1 days);
        vm.prank(keeper);
        ace.settleExpired(b);
        (, s) = _pair(m);
        assertEq(s, 2, "settleExpired counts beside it");
    }

    /// @notice What leaves no new pot leaves the settled count alone: a clean close, a partial buy, a buy on an empty pot.
    function test_Settled_NothingButASettlementMovesIt() public {
        Mkt memory m = _eighteen();
        uint256 clean = _loan(m);
        uint256 a = _loan(m);
        _repay(clean);
        (, uint256 s) = _pair(m);
        assertEq(s, 0, "a clean close settles nothing");

        _finalize(m, a);
        uint256 pot = read.invPotOf(m.id, a);
        _buy(m, a, _wholeCharge(m, pot) / 3);
        assertGt(read.invPotOf(m.id, a), 0, "PREMISE: a part remains");
        (, s) = _pair(m);
        assertEq(s, 1, "a partial buy leaves it");

        _buy(m, a, _generous(m, read.invPotOf(m.id, a)));
        uint256 opens = read.inventoryAskOpensAt(clean);
        _warpAtLeastTo(opens);
        _buy(m, a, 1_000e6);
        _buy(m, clean, 1_000e6);
        (, s) = _pair(m);
        assertEq(s, 1, "the emptying buy and two buys on empty pots leave it");
    }

    /// @notice The settled count is keyed like the unsold one: by the lender AND the quote.
    function test_Settled_IsKeyedByLenderAndQuote() public {
        Mkt memory mine = _eighteen();
        Mkt memory theirs = _market(usdc, 18, other, true, 2e18, 11e6);
        Mkt memory myDai = _market(dai, 18, lender, true, 2e18, 12e6);
        _finalize(theirs, _loan(theirs));
        _finalize(myDai, _loan(myDai));

        (, uint256 s) = _pair(mine);
        assertEq(s, 0, "another lender's pot and another quote's pot leave this pair at zero");
        (, s) = _pair(theirs);
        assertEq(s, 1, "the other lender's pair counts its own");
        (, s) = _pair(myDai);
        assertEq(s, 1, "and this lender's DAI pair counts apart from its USDC pair");
    }

    // ============ 5. the no-pot arm: what the settled count must skip, and why no admitted loan reaches it ============

    /// @dev Zero a live loan's lot in place: word 2 of its record, the way `AceShortfallReentrancy` stages a short lot.
    function _forgeZeroLot(uint256 loanId) internal {
        uint256 loanSlot = uint256(keccak256(abi.encode(loanId, uint256(Storage.BOOK) + 1)));
        vm.store(address(ace), bytes32(loanSlot + 2), bytes32(0));
    }

    /// @dev The units a live claim of `amount` needs at this market's price, ceiled once, spelled here.
    function _need(Mkt memory m, uint256 amount) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(amount, read.marketState(m.id).unitScale, ace.idToMarketParams(m.id).price);
    }

    /// @dev A settled loan that left no pot: closed, empty, its claim retired, and the whole need written down as the shortfall.
    function _assertSettledBare(Mkt memory m, uint256 loanId) internal view {
        assertGt(read.loan(loanId).closedAt, 0, "PREMISE: the door settled the loan");
        assertEq(read.invPotOf(m.id, loanId), 0, "PREMISE: and left no pot");
        assertEq(read.claimOf(m.id, loanId), 0, "PREMISE: the claim retired, so settlement passed its no-claim return");
        (uint256 shortUnits, uint256 shortQuote) = read.shortfallOf(loanId);
        assertEq(shortUnits, _need(m, PRINCIPAL), "PREMISE: the claims got nothing, so the whole need is the shortfall");
        assertEq(shortQuote, PRINCIPAL, "PREMISE: written down at book, the whole claim");
    }

    /// @notice A settlement that leaves NO pot moves neither word: the raise is gated on the pot, never on the live claim alone.
    /// @dev No admitted loan reaches this arm, which is why the lot is FORGED: the fuzz row below pins that half.
    /// @dev Every live loan holds `claim == debt > 0`, and every door that lowers a lot keeps `units - sliver >= need >= 1`.
    function test_Settled_ASettlementThatLeavesNoPotMovesNeitherWord() public {
        Mkt memory m = _eighteen();
        uint256 a = _loan(m);
        uint256 paid = _loan(m);
        uint256 unpaid = _loan(m);
        _finalize(m, a);
        (uint256 u0, uint256 s0) = _pair(m);
        assertEq(u0, 1, "PREMISE: one real pot unsold");
        assertEq(s0, 1, "PREMISE: and settled, so a stray raise has a word to move");

        _forgeZeroLot(paid);
        _forgeZeroLot(unpaid);
        assertEq(read.loan(paid).collateralUnits + read.loan(unpaid).collateralUnits, 0, "PREMISE: the forged word is each loan's lot");
        assertEq(read.claimOf(m.id, paid) + read.claimOf(m.id, unpaid), 2 * PRINCIPAL, "PREMISE: and both claims are still live");

        Loan memory l = read.loan(unpaid);
        _warpTo(uint256(l.expiry) + MarketInit.autoRefinanceWindow(l.tenor));
        vm.prank(keeper);
        ace.forceClose(paid);
        _assertSettledBare(m, paid);
        (uint256 u1, uint256 s1) = _pair(m);
        assertEq(u1, u0, "the paid door left no pot, so nothing is unsold");
        assertEq(s1, s0, "and nothing is settled: the word counts pots, not settlements");

        vm.prank(keeper);
        ace.settleExpired(unpaid);
        _assertSettledBare(m, unpaid);
        (u1, s1) = _pair(m);
        assertEq(u1, u0, "nor did the unpaid door");
        assertEq(s1, s0, "so the settled count still reads the one real pot");
    }

    /// @dev `_market`, with the coverage and the keeper bounty named, so the fuzz row reaches the bounty's genesis ceiling.
    function _marketKB(uint8 cd, uint256 k, uint16 bounty) internal returns (Mkt memory m) {
        m.quote = usdc;
        m.coll = new MockERC20("Collateral", "COLL", cd);
        m.lender = lender;
        m.record = new MockPersistenceRecord(address(usdc), address(m.coll));
        m.record.setObserved(AceFixtures.px(1e18, address(usdc), address(m.coll)));
        m.record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(m.coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(m.coll));
        p.record = address(m.record);
        p.lender = lender;
        p.inventoryAsk = true;
        p.fillFeeBps = FEE_BPS;
        p.minCoverageWad = k;
        p.settleBountyBps = bounty;
        m.id = ace.createMarket(p);
    }

    /// @notice At the TIGHTEST admissible lot a settlement still leaves a pot, through every door: the no-pot arm is unreachable.
    /// @dev The corner: collateral exactly on the coverage line, the bounty anywhere up to its ceiling, coverage anywhere in its band.
    /// @dev Genesis holds the bounty at or under `k - 1`, so the paid sliver never reaches into the claims' need.
    /// @dev One unit fewer is refused first, so the row proves it sits ON the line rather than near it.
    function testFuzz_Settled_ALotOnTheCoverageLineAlwaysLeavesAPot(uint256 kSeed, uint256 bountySeed, uint256 principalSeed, uint256 shapeSeed) public {
        uint256 k = bound(kSeed, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        uint16 bounty = uint16(bound(bountySeed, 0, Constants.MAX_SETTLE_BOUNTY_BPS));
        uint8 cd = shapeSeed % 3 == 0 ? 0 : (shapeSeed % 3 == 1 ? 6 : 18);
        uint256 door = (shapeSeed / 3) % 3; // 0 finalize, 1 forceClose, 2 settleExpired
        Mkt memory m = _marketKB(cd, k, bounty);
        uint256 principal = bound(principalSeed, 10e6, SEED);
        uint256 scale = read.marketState(m.id).unitScale;
        uint256 price = ace.idToMarketParams(m.id).price;
        uint256 units = FullMath.mulDivRoundingUp(k * principal, scale, price * 1e18) + 1; // the coverage line, spelled here

        usdc.mint(lender, principal);
        vm.startPrank(lender);
        usdc.approve(address(ace), principal);
        ace.deposit(m.id, principal);
        vm.stopPrank();
        m.coll.mint(borrower, units);
        vm.startPrank(borrower);
        m.coll.approve(address(positionManager), units);
        vm.expectRevert(BelowCoverageLine.selector);
        ace.open(m.id, units - 1, principal, 0, borrower, OpenBounds(0, 0, 0));
        uint256 id = ace.open(m.id, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        Loan memory l = read.loan(id);
        if (door == 0) {
            m.record.setBelow(true);
        } else {
            _warpTo(uint256(l.expiry) + (door == 2 ? MarketInit.autoRefinanceWindow(l.tenor) : 0));
        }
        vm.prank(keeper);
        if (door == 0) ace.finalize(id);
        else if (door == 1) ace.forceClose(id);
        else ace.settleExpired(id);

        uint256 need = FullMath.mulDivRoundingUp(principal, scale, price);
        uint256 sliver = door == 2 ? 0 : FullMath.mulDiv(principal * bounty, scale, 10000 * price);
        assertEq(read.unitsOwedOf(id, keeper), sliver, "PREMISE: the keeper took exactly the sliver this door pays");
        assertGe(need, 1, "PREMISE: a live claim needs at least one unit");
        assertEq(read.invPotOf(m.id, id), need, "the pot is the claims' whole need, so it is never empty");
        (uint256 u, uint256 s) = _pair(m);
        assertEq(u, 1, "so the settlement counts one unsold");
        assertEq(s, 1, "and one settled");
    }
}
