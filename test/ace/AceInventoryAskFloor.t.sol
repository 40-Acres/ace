// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, NoRecordPrice, InventoryHeld} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceInventoryAskFloor
/// @notice THE ASK FLOOR in `Ace._buyInventoryFold`: settled inventory never sells at book while the record proves more.
/// @notice Live, cap above book -- the fill prices at the CAP. The pot is holder money, and the gap is the arb's.
/// @notice None, cap == max -- the fill prices at BOOK. The max sentinel is not read as an infinite floor.
/// @notice Two arms because they are different claims: a floor that always reads `cap` bricks every recordless market.
/// @dev ONE hub, TWO markets differing ONLY in `record`, so the differential has a single cause.
/// @dev `Settlement._collateralNeeded` prices per funded tick off `Ladder.priceAt` alone, so both pots settle equal.
/// @dev Anchored to a real `buyInventory`: the hub's own bytecode, never a lens read or a re-derived preview.
/// @dev Coverage for issue #350, and the sole home of the recordless ask after the #370 ruling.
contract AceInventoryAskFloorTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc; // the quote, 6 decimals
    MockERC20 internal coll; // the collateral, 18 decimals
    MockPersistenceRecord internal record;
    bytes32 internal midLive; // record wired: recordState answers Live
    bytes32 internal midNone; // record == 0: recordState answers None, cap == type(uint256).max

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB0FF);
    address internal keeper = address(0xCAFE);

    uint256 internal TICK; // 16 rungs above par, ~1.1007x it; assigned in setUp, since par is not a compile-time value
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal CAP; // the record's windowed minimum, in the hub's frame: ~1.8x the tick's book price
    uint256 internal constant DEPOSIT = 5_000e6;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant BUDGET = 20_000e6; // above either pot's ask value at the CAP, so the POT is what binds
    uint64 internal constant HOLD = 1 hours; // min(1 hours, minTenor / 2) at the fixture's 7-day minTenor

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        TICK = _price(960);
        CAP = AceFixtures.px(2e18, address(usdc), address(coll));
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(coll)));
        record.setMinPrice(CAP);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        /// @dev BOOK IS THE MARKET'S OWN BID. `TICK` was the rung the rig rested at and the ask priced off it;
        /// @dev the price is a market param now, so the market has to BE at `TICK` for book to mean that.
        p.price = TICK;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, midLive) = (d.ace, d.positionManager, d.read, d.id);

        /// @dev The recordless twin: every other field carried over from storage, so `record` is the ONLY cause.
        MarketParams memory q = ace.idToMarketParams(midLive);
        q.record = address(0); // legal with the deleverage band off, which the fixture leaves at zero
        midNone = ace.createMarket(q);

        assertTrue(midNone != midLive, "fixture: the twin markets hash apart, so the hub holds both");
        assertEq(read.marketState(midLive).unitScale, UNIT_SCALE, "fixture: 18-dec collateral over 6-dec quote");
        assertEq(read.marketState(midNone).unitScale, UNIT_SCALE, "fixture: the twin shares the frame");
        assertGt(CAP, TICK, "fixture: the record proves a price ABOVE book, or the floor is inert");
    }

    // --- fixture ---

    function _lend(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev A loan past its tenor whose claim is NOT settled yet, so the class pot does not exist until someone cranks.
    function _expiredLoan(bytes32 mid) internal returns (uint256 loanId) {
        _lend(mid, DEPOSIT);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpBy(7 days + 1);
    }

    /// @dev A settled loan on one funded tick, whose claim became the class pot. Reads NO price.
    /// @dev `forceClose` rather than `finalize` deliberately: finalize needs a record, so only this verb runs in both.
    /// @dev WARPS PAST THE HOLD, so the price arms below measure the ask and never the clock.
    /// @dev The hold itself is pinned by the two tests that drive time by hand, never by this helper.
    function _settledLoan(bytes32 mid) internal returns (uint256 loanId, uint256 pot) {
        loanId = _expiredLoan(mid);
        vm.prank(keeper);
        ace.forceClose(loanId);
        pot = read.invPotOf(mid, loanId);
        assertGt(pot, 0, "fixture: settlement pooled the claim into the class");
        _warpBy(HOLD);
    }

    /// @dev A real buy against the whole pot: the budget never binds, so the two arms clear the same inventory.
    /// @dev That is what makes them comparable -- a fixed budget would buy FEWER units at the higher price.
    function _buy(uint256 loanId) internal returns (uint256 unitsOut, uint256 stableFilled) {
        usdc.mint(buyer, BUDGET);
        vm.startPrank(buyer);
        usdc.approve(address(ace), BUDGET);
        (unitsOut, stableFilled) = ace.buyInventory(loanId, BUDGET, 0, buyer);
        vm.stopPrank();
    }

    /// @dev What `units` cost at `price`, in quote atoms. Floors, matching the leg's own gross before its ceil.
    function _quoteAt(uint256 units, uint256 price) internal pure returns (uint256) {
        return (units * price) / UNIT_SCALE;
    }

    /// @dev The most a leg may charge for `units` at `price`: the re-price ceils, then the fill fee rides on top, ceiled too.
    function _mostAt(bytes32 mid, uint256 units, uint256 price) internal view returns (uint256) {
        uint256 ceiled = _quoteAt(units, price) + 1;
        return ceiled + (ceiled * ace.idToMarketParams(mid).fillFeeBps + 9999) / 10000;
    }

    // --- the two arms ---

    /// @notice LIVE: the ask floors at the record's windowed minimum, so the buyer pays the cap and not book.
    /// @notice Deleting the floor hands the difference to whoever calls `buyInventory` first, out of holder money.
    /// @dev The `assertGe` below is the one with money on it: it is what `floorPrice = 0` breaks.
    function test_LiveRecord_AskFloorsAtTheRecordCapNotBook() public {
        (uint256 loanId, uint256 pot) = _settledLoan(midLive);
        uint256 book = TICK;
        (uint256 unitsOut, uint256 stableFilled) = _buy(loanId);

        assertApproxEqRel(unitsOut, pot, 1e12, "fixture: the POT bound the fill, so the price is not a budget artefact");
        assertLt(stableFilled, BUDGET, "fixture: the buyer's budget was never the binding constraint");
        uint256 atBook = _quoteAt(unitsOut, book);
        uint256 atCap = _quoteAt(unitsOut, CAP);
        assertGt(atCap, atBook, "fixture: those units are worth strictly more at the cap than at book");
        emit log_named_uint("quote paid", stableFilled);
        emit log_named_uint("what those units cost at the tick's book price", atBook);
        emit log_named_uint("what the record proves those units are worth", atCap);
        assertGe(stableFilled, atCap, "THE ASK FLOOR IS GONE: settled inventory sold at book while the record proved more");
        assertLe(stableFilled, _mostAt(midLive, unitsOut, CAP), "and the floor is the ask, not a surcharge on top of it");
    }

    /// @notice NONE: no record wired, so `recordState` answers the max sentinel and the ask has NO floor at all.
    /// @notice A floor that read the sentinel literally would price every recordless fill out of reach.
    /// @dev `assertGt(unitsOut, 0)` is what `floorPrice = cap` breaks: at max the leg affords zero units.
    function test_NoRecord_MaxSentinelIsNoFloorAndTheAskPricesAtBook() public {
        (uint256 loanId, uint256 pot) = _settledLoan(midNone);
        uint256 book = TICK;
        (uint256 unitsOut, uint256 stableFilled) = _buy(loanId);

        assertGt(unitsOut, 0, "THE MAX SENTINEL WAS READ AS A FLOOR: a recordless market can no longer sell its inventory");
        assertApproxEqRel(unitsOut, pot, 1e12, "the pot cleared: an absent record gates nothing at all");
        uint256 atBook = _quoteAt(unitsOut, book);
        emit log_named_uint("quote paid", stableFilled);
        emit log_named_uint("what those units cost at the tick's book price", atBook);
        assertGe(stableFilled, atBook, "a recordless fill still pays the book value of what left the pot");
        assertLe(stableFilled, _mostAt(midNone, unitsOut, book), "and with no record it pays book, never a sentinel-derived price");
    }

    // --- the hold: the settling transaction may not also be the buying one ---

    /// @notice THE HOLD: a stranger's `forceClose` + `buyInventory` multicall is refused by NAME.
    /// @notice Nobody could win that race at any diligence -- the pot did not exist until the settle leg ran.
    /// @dev The refusal is the clock's, never the price's: the same pot clears at book once the hold lapses.
    function test_NoRecord_TheSettlingTransactionCannotAlsoBuyThePot() public {
        uint256 loanId = _expiredLoan(midNone);
        usdc.mint(buyer, BUDGET);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.forceClose, (loanId));
        calls[1] = abi.encodeCall(Ace.buyInventory, (loanId, BUDGET, 0, buyer));
        vm.startPrank(buyer);
        usdc.approve(address(ace), BUDGET);
        vm.expectRevert(InventoryHeld.selector);
        ace.multicall(calls);
        vm.stopPrank();
    }

    /// @notice THE EDGE, both sides: refused one second early, admitted exactly on it.
    /// @notice The ask OPENS rather than closing -- what the hold buys the holder is time, not a veto.
    /// @dev Anchored to the loan's own `closedAt`, so a change to the window's arithmetic reds this row.
    function test_NoRecord_TheHoldRefusesUntilItsLastSecondAndAdmitsOnIt() public {
        uint256 loanId = _expiredLoan(midNone);
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 closedAt = _now(); // the settling block, off the clock: a raw read is hoistable under via-IR

        usdc.mint(buyer, BUDGET);
        vm.startPrank(buyer);
        usdc.approve(address(ace), BUDGET);

        _warpTo(closedAt + HOLD - 1);
        vm.expectRevert(InventoryHeld.selector);
        ace.buyInventory(loanId, BUDGET, 0, buyer);

        _warpTo(closedAt + HOLD);
        (uint256 unitsOut, uint256 stableFilled) = ace.buyInventory(loanId, BUDGET, 0, buyer);
        vm.stopPrank();

        assertGt(unitsOut, 0, "the hold lapsed and the ask still refused: it closes the exit rather than delaying it");
        assertGe(stableFilled, _quoteAt(unitsOut, TICK), "the reopened ask cleared under the book value of what left the pot");
        assertLe(stableFilled, _mostAt(midNone, unitsOut, TICK), "the reopened ask is still book plus the fill fee, not a new price");
    }

    /// @notice WHAT THE HOLD IS FOR: the holder takes their own goods in kind while the ask is shut.
    /// @notice `materialize` then `redeemInKind`, inside the window, by the lender who never held a unit.
    /// @dev Neither verb reads the clock, so the window gates the stranger's ask and nothing the holder does.
    /// @dev The pot is emptied here, which is why the stranger has nothing to buy when the hold lapses.
    function test_NoRecord_TheHolderRedeemsInKindDuringTheHold() public {
        uint256 loanId = _expiredLoan(midNone);
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(alice);
        uint256 out = ace.redeemInKind(loanId, alice); // no mint first: the pot is the lender's outright

        assertGt(out, 0, "the in-kind exit paid nothing inside the hold");
        assertEq(coll.balanceOf(alice), out, "the collateral did not reach the lender");
        assertLt(read.invPotOf(midNone, loanId), 2, "the pot survived a full in-kind redemption");
    }

    /// @notice The record raises the realized ask above book, measured PER UNIT so pot size cannot flatter it.
    /// @notice IT ALSO SIZES THE POT NOW: the recordless arm forfeits the coverage into its classes at settlement.
    /// @dev So the two arms no longer hold the same inventory, and only a per-unit price can compare them.
    /// @dev Per-unit rather than per-fill anyway, because the two arms round their whole-unit deliveries at different prices.
    /// @dev The pot ratio is pinned rather than its direction: a spread of the WRONG size still points the right way.
    function test_TheRecordRaisesTheRealizedAskAboveBook() public {
        (uint256 liveLoan, uint256 livePot) = _settledLoan(midLive);
        (uint256 noneLoan, uint256 nonePot) = _settledLoan(midNone);
        uint256 k = ace.idToMarketParams(midNone).minCoverageWad;
        assertApproxEqRel(nonePot, (livePot * k) / 1e18, 1e12, "the recordless pot is the record-backed one plus the forfeited coverage");

        (uint256 liveUnits, uint256 liveFilled) = _buy(liveLoan);
        (uint256 noneUnits, uint256 noneFilled) = _buy(noneLoan);
        assertGt(liveUnits, 0, "fixture: the Live pot cleared");
        assertGt(noneUnits, 0, "THE MAX SENTINEL WAS READ AS A FLOOR: the recordless twin sold nothing");

        uint256 livePrice = (liveFilled * UNIT_SCALE) / liveUnits;
        uint256 nonePrice = (noneFilled * UNIT_SCALE) / noneUnits;
        emit log_named_uint("realized ask, market with a record", livePrice);
        emit log_named_uint("realized ask, market without one", nonePrice);
        assertApproxEqRel(livePrice, CAP, 1e12, "THE ASK FLOOR IS GONE: the Live market's realized ask is not the record's cap");
        assertApproxEqRel(nonePrice, TICK, 1e12, "the recordless market's realized ask is book, exactly as intended");
        assertGt(livePrice, nonePrice, "the record is the only difference between these two markets, and it must move the ask");
    }

    /// @notice NOPRICE: a record answering zero is refused BEFORE the fold, so no floor of zero is ever built.
    /// @dev The third `recordState` arm, pinned here so the sentinel decode is covered end to end hub-side.
    function test_NoPriceRecord_RefusesBeforeTheFoldRatherThanAskingAtBook() public {
        (uint256 loanId,) = _settledLoan(midLive);
        record.setMinPrice(0);
        usdc.mint(buyer, BUDGET);
        vm.startPrank(buyer);
        usdc.approve(address(ace), BUDGET);
        vm.expectRevert(NoRecordPrice.selector);
        ace.buyInventory(loanId, BUDGET, 0, buyer);
        vm.stopPrank();
    }
}
