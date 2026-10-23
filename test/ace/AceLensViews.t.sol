// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace, LoanClosed, LoanMatured} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash, NoRecordPrice, RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Loan, MarketParams, MarketState, OpenBounds, RecordState} from "../../src/ace/hub/Types.sol";
import {NoMarket} from "../../src/ace/lens/AceLens.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceLensViewsTest
/// @notice The shipped lens against the proven reader on MUTATED state, so a drift in either fails loudly.
/// @notice Plus the behavior anchors: eligibility asserted against the real crank, never against itself.
contract AceLensViewsTest is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB04E5);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal P; // the record's windowed minimum, in the hub's frame; assigned in setUp
    uint256 internal PS_BAND; // the in-band price the crank fixture drives to, in the hub's frame
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal T_PAR; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal T_HI; // books above par, so a cap between the two is observable
    uint256 internal T_UNCAPPED; // books near 1000x par: a tick only the None sentinel admits

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T_PAR, T_HI, T_UNCAPPED) = (_price(0), _price(960), _price(69_060));
        P = AceFixtures.px(2e18, address(usdc), address(vault));
        PS_BAND = AceFixtures.px(0.7e18, address(usdc), address(vault));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(P);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1; // tiny: keeps the near-trigger fixture admitted past the new stop rail
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        keeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id, 15_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Parity on LIVE, mutated state: a deposit, a draw, and a crank have all run before the
    /// @dev two slot maps are compared, so agreement is about real storage, not zero-initialized slots.
    /// @dev The reader is a byte-identical mirror, not an independent derivation, so what this catches
    /// @dev is a ONE-SIDED edit -- one copy of the slot map updated and the other left behind.
    function test_Parity_LensAgreesWithTheProvenReader_OnMutatedState() public {
        uint256 loanId = _open();
        record.setBelowBand(lens.deleverageBandLevel(loanId));
        record.setMinPrice(PS_BAND);
        keeper.crankDeleverage(loanId); // a real crank: collateral debited, debt melted, revenue accrued

        MarketState memory ls = lens.marketState(id);
        MarketState memory rs = read.marketState(id);
        assertEq(ls.protocolRevenue, rs.protocolRevenue, "protocolRevenue");
        assertEq(ls.unitScale, rs.unitScale, "unitScale");
        assertEq(ls.lastSweptAt, rs.lastSweptAt, "lastSweptAt");
        assertEq(ls.quoteOwedTotal, rs.quoteOwedTotal, "quoteOwedTotal");

        (uint256 lr, uint256 ll_, uint256 lo) = lens.lenderPools(alice, address(usdc));
        (uint256 rr, uint256 rl_, uint256 ro) = read.lenderPools(alice, address(usdc));
        assertEq(lr, rr, "pool resting");
        assertEq(ll_, rl_, "pool lent");
        assertEq(lo, ro, "pool owed");

        Loan memory ll = lens.loan(loanId);
        Loan memory rl = read.loan(loanId);
        assertEq(ll.borrower, rl.borrower, "borrower");
        assertEq(ll.collateralUnits, rl.collateralUnits, "collateralUnits");
        assertEq(ll.debt, rl.debt, "debt");
        assertEq(ll.expiry, rl.expiry, "expiry");

        assertEq(lens.triggerPrice(loanId), read.triggerPrice(loanId), "triggerPrice");
        assertEq(lens.fundingFloor(id, loanId), read.fundingFloor(id, loanId), "fundingFloor");
        assertEq(lens.utilization(alice, address(usdc)), read.utilization(alice, address(usdc)), "utilization");
        assertEq(lens.restingOf(id), read.restingOf(id), "resting cash");
        assertEq(lens.claimOf(id, loanId), read.claimOf(id, loanId), "the loan's one claim");
    }

    /// @dev The quote path forwards from the hub's own preview, so quoting then executing must agree.
    /// @dev That anchors the lens to behavior rather than to a restated formula.
    function test_QuoteOpen_MatchesTheRealOpen() public {
        (uint256 fee, uint256 payout,,,,) = lens.quoteOpen(id, COLL, PRINCIPAL, 7 days, borrower);

        vault.mint(borrower, COLL);
        uint256 cash = usdc.balanceOf(borrower);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        uint256 loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(borrower) - cash, payout, "the quoted payout is the paid payout");
        assertEq(read.loan(loanId).lastFee, fee, "the quoted fee is the charged fee");
    }

    /// @dev The eligibility anchor, both directions: the lens must match what the REAL crank does.
    /// @dev The mirror is pinned to the hub, never to itself.
    function test_DeleverageEligible_AnchoredToTheRealCrank_BothDirections() public {
        uint256 loanId = _open();

        assertFalse(lens.deleverageEligible(loanId), "healthy: the lens says no");
        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);

        record.setBelowBand(lens.deleverageBandLevel(loanId)); // the lens's OWN level arms the mock
        record.setMinPrice(PS_BAND);

        assertTrue(lens.deleverageEligible(loanId), "in the band: the lens says yes");
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "and the real crank agrees by succeeding");
    }

    /// @dev The eligibility anchor at the tenor's edge: from the expiry second the crank refuses, and the mirror must say so.
    function test_DeleverageEligible_AnchoredToTheRealCrank_AtExpiry() public {
        uint256 loanId = _open();
        record.setBelowBand(lens.deleverageBandLevel(loanId));
        record.setMinPrice(PS_BAND);
        uint256 expiry = read.loan(loanId).expiry;

        _warpTo(expiry - 1);
        assertTrue(lens.deleverageEligible(loanId), "PREMISE: in the band in the last live second, the lens says yes");

        _warpTo(expiry);
        assertFalse(lens.deleverageEligible(loanId), "from the expiry second the lens says no");
        vm.expectRevert(LoanMatured.selector);
        keeper.crankDeleverage(loanId);
    }

    /// @dev recordLive anchored to behavior: a record proving nothing means draws answer closed.
    function test_RecordLive_AnchoredToTheDrawGate() public {
        assertTrue(lens.recordLive(id), "the record proves a price");

        record.setMinPrice(0); // the record no longer proves anything
        assertFalse(lens.recordLive(id), "the lens sees it");

        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        vm.expectRevert(NoRecordPrice.selector); // the lens and the door now name one state alike
        ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev `recordFitFor` agrees with genesis on the supported pair and never reverts on anything else.
    /// @dev An unsupported pair, an EOA and a reverting source all answer `(false, 0)`.
    function test_RecordFitFor_AgreesWithGenesisAndNeverReverts() public {
        (bool ok, uint256 price) = lens.recordFitFor(address(record), address(usdc), address(vault));
        assertTrue(ok, "the pair genesis admitted is the pair the lens affirms");
        assertEq(price, record.minPrice(address(usdc), address(vault)), "live price surfaced: the windowed minimum the draw reads");

        (ok, price) = lens.recordFitFor(address(record), address(vault), address(usdc));
        assertFalse(ok, "the inverse pair is not affirmed");
        assertEq(price, 0, "no price for an unsupported pair");

        (ok, price) = lens.recordFitFor(address(0xDEAD), address(usdc), address(vault));
        assertFalse(ok, "an EOA source answers unfit, not a revert");

        (ok,) = lens.recordFitFor(address(0), address(usdc), address(vault));
        assertFalse(ok, "the zero source answers unfit");
    }

    /// @dev A second market with NO record, so `None` is reachable.
    /// @dev Params are content-addressed, so dropping the record alone already makes this a different id.
    /// @dev The band must be off with it: `MarketInit` refuses band-on with no record.
    function _recordlessMarket() internal returns (bytes32 mid) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(0);
        p.price = T_UNCAPPED; // WAS the tick the recordless draw walked to; the market bids there now
        p.deleverageBandBps = 0;
        p.deleverageTargetBps = 0;
        p.deleverageStopBps = 0;
        p.deleverageProtocolBps = 0;
        mid = ace.createMarket(p);
    }

    /// @dev THE anchor: every state the lens reports is asserted against what the real draw door does.
    /// @dev Never lens-vs-lens: a mirror agreeing with itself is what `lens-mirror-proves-nothing` forbids.
    function test_RecordStateOf_AnchoredToTheDrawDoor_AllThreeStates() public {
        (RecordState s, uint256 cap) = lens.recordStateOf(id);
        assertEq(uint256(s), uint256(RecordState.Live), "a proving record is Live");
        assertEq(cap, P, "and the cap is the windowed minimum");
        _openExpecting(id, bytes4(0)); // Live: the door opens

        record.setMinPrice(0);
        (s, cap) = lens.recordStateOf(id);
        assertEq(uint256(s), uint256(RecordState.NoPrice), "a record proving nothing is NoPrice");
        assertEq(cap, 0, "and NoPrice carries no cap");
        _openExpecting(id, NoRecordPrice.selector); // NoPrice: the door refuses

        record.setMinPrice(P);
        bytes32 mid = _recordlessMarket();
        (s, cap) = lens.recordStateOf(mid);
        assertEq(uint256(s), uint256(RecordState.None), "no record wired is None");
        assertEq(cap, type(uint256).max, "and None is UNCAPPED, which is not the safe answer");
    }

    /// @dev The sick record: a feed that REVERTS rather than answering zero.
    /// @dev The hub's own `recordState` bubbles it, so the lens must not be built on that one.
    /// @dev Without the try twin the market-level question is unanswerable in the state it exists to report.
    function test_RecordStateOf_SickRecord_IsReportedNotThrown() public {
        record.setSick(true);

        (RecordState s, uint256 cap) = lens.recordStateOf(id);
        assertEq(uint256(s), uint256(RecordState.NoPrice), "a reverting record reports NoPrice");
        assertEq(cap, 0, "and carries no cap");
        assertFalse(lens.recordLive(id), "recordLive answers false rather than reverting");
    }

    /// @dev The guard. Without it a never-created id answers None -- UNCAPPED -- which is the fail-OPEN state.
    function test_RecordStateOf_UnknownMarket_Reverts() public {
        vm.expectRevert(NoMarket.selector);
        lens.recordStateOf(bytes32(uint256(0xDEAD)));
    }

    /// @dev `cap` IS the draw cap, pinned through a real open bracketed either side of the returned value.
    /// @dev The record sits at a NON-ROUND price so the comparison is observable rather than lost to rounding.
    function test_RecordStateOf_CapIsTheDrawCap() public {
        uint256 odd = P - 1; // one wei under P, so the cap binds somewhere real
        record.setMinPrice(odd);

        (, uint256 cap) = lens.recordStateOf(id);
        assertEq(cap, odd, "the lens reports the record's own windowed minimum, unrounded");

        record.setMinPrice(0);
        _openExpecting(id, NoRecordPrice.selector);
        record.setMinPrice(odd);
        _openExpecting(id, bytes4(0)); // and at the reported cap the door still opens
    }

    /// @dev The fold's equivalence control: `recordLive` must stay exactly `state == Live`, every state.
    function test_RecordLive_StillAgreesWithRecordStateOf() public {
        assertEq(lens.recordLive(id), _liveByState(id), "Live agrees");

        record.setMinPrice(0);
        assertEq(lens.recordLive(id), _liveByState(id), "NoPrice agrees");

        record.setMinPrice(P);
        bytes32 mid = _recordlessMarket();
        assertEq(lens.recordLive(mid), _liveByState(mid), "None agrees");
        assertFalse(lens.recordLive(mid), "and None is not live: draws are uncapped, not proven");
    }

    /// @dev Ties `MarketInit`'s rail to the lens: band-on with no record is UNCONSTRUCTIBLE.
    /// @dev That rail is why `deleverageEligible`'s record reads stay raw rather than being sentinelled.
    /// @dev If anyone ever loosens it this fails, and the raw reads are revisited then.
    function test_DeleverageBandImpliesRecord_ForbidsTheZeroRecordRead() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(0);
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;

        vm.expectRevert(bytes("record required"));
        ace.createMarket(p);
    }

    /// @dev An EMPTY pot answers zero without ever asking the record: no inventory, no price needed.
    /// @dev The refusal on a REAL pot is pinned in the inventory-ask suite, which has a settled loan to hold one.
    function test_InventoryMark_EmptyPotNeedsNoRecord() public {
        uint256 loanId = _open();
        record.setMinPrice(0);
        assertEq(lens.inventoryMark(id, loanId), 0, "an empty pot marks zero on any record state");
    }

    /// @dev What "cap" MEANS: whether a market's own price is fundable, bracketed one wei either side of it.
    /// @dev One wei under, the market is over the cap and funds nothing; at the cap itself it funds in full.
    /// @dev WAS the same bracket over the TICKS one walk anchored at, with the skipped tick's draw falling to
    /// @dev par. There is no walk and nothing to fall to: the market is admitted whole or refused whole.
    /// @dev `test_RecordStateOf_CapIsTheDrawCap` cannot see this: its market prices well under a ~2e18 cap.
    /// @dev There the cap never binds, so both of its opens turn on Live-vs-NoPrice instead.
    function test_RecordStateOf_CapBoundsWhetherTheMarketFunds() public {
        MarketParams memory hp = ace.idToMarketParams(id);
        hp.price = T_HI;
        bytes32 hi = ace.createMarket(hp);
        _depositAt(hi, 12_000e6);
        uint256 restingHi = read.restingOf(hi);
        assertGt(restingHi, PRINCIPAL, "the high market alone can fund the whole draw");

        record.setMinPrice(T_HI - 1);
        (, uint256 cap) = lens.recordStateOf(hi);
        assertEq(cap, T_HI - 1, "the lens reports a cap one wei under the market's own price");
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        vm.expectRevert(InsufficientCash.selector);
        ace.open(hi, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(read.restingOf(hi), restingHi, "one wei under, the market is over the cap and funds nothing");

        record.setMinPrice(T_HI);
        (, cap) = lens.recordStateOf(hi);
        assertEq(cap, T_HI, "one wei more and the lens reports the market's own price");
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        uint256 loanId = ace.open(hi, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertLt(read.restingOf(hi), restingHi, "at the cap the market is admitted and its cash goes to work");
        assertEq(read.fundingFloor(hi, loanId), T_HI, "and the loan's floor is the capped price itself");
    }

    /// @dev The OTHER unusable-record shape: a source whose call SUCCEEDS but answers fewer than 32 bytes.
    /// @dev `tryPersistedPrice` is a raw staticcall precisely so this decodes to NoPrice instead of blowing up.
    /// @dev The draw door has no such absorber, so this is where a view answering beats a crank refusing.
    function test_RecordStateOf_ShortReturn_IsReportedNotThrown() public {
        record.setShortAnswer(true);

        (RecordState s, uint256 cap) = lens.recordStateOf(id);
        assertEq(uint256(s), uint256(RecordState.NoPrice), "a record answering short reports NoPrice");
        assertEq(cap, 0, "and carries no cap");
        assertFalse(lens.recordLive(id), "recordLive answers false rather than reverting");

        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        vm.expectRevert(); // the hub's own decode BUBBLES here, which is the divergence the lens exists to cover
        ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The lens's `NoMarket` is deliberately the hub's selector, so one catch covers both.
    /// @dev Only a REAL hub revert proves it: comparing the two declarations would compare a name to itself.
    function test_NoMarket_IsTheSelectorTheHubThrows() public {
        bytes32 ghost = bytes32(uint256(0xDEAD));

        vm.expectRevert(NoMarket.selector); // the LENS's error, thrown by the HUB
        ace.deposit(ghost, 1e6);

        vm.expectRevert(NoMarket.selector);
        lens.recordStateOf(ghost);
    }

    /// @dev The `None` branch of the exit mark, on a REAL pot: no record reads the max sentinel.
    /// @dev The fold must turn that into NO floor rather than an unpayable one, so the mark is book.
    /// @dev Anchored to a real `buyInventory` over the same pot: the mark is the quote the hub charges.
    /// @dev The draw itself is the None behaviour anchor -- it funds a ~1000e18 tick no record would admit.
    /// @dev Reachable only through `forceClose`: finalize demands a record, and a band implies one.
    function test_InventoryMark_NoRecord_MarksAtBook_AnchoredToARealBuy() public {
        bytes32 mid = _recordlessMarket();
        (uint256 loanId, uint256 price) = _forceClosedLoanOn(mid);
        assertEq(price, T_UNCAPPED, "a recordless draw funded at a price far above any windowed minimum");

        uint256 pot = read.invPotOf(mid, loanId);
        assertGt(pot, 0, "the fixture really holds inventory on a market with no record");
        (RecordState s, uint256 cap) = lens.recordStateOf(mid);
        assertEq(uint256(s), uint256(RecordState.None), "and the market has no record");
        assertEq(cap, type(uint256).max, "so the mark meets the sentinel the fold has to absorb");

        uint256 mark = lens.inventoryMark(mid, loanId);
        assertGt(mark, 0, "a recordless pot marks at book: it neither reverts nor floors at the sentinel");

        uint256 budget = mark * 2;
        usdc.mint(buyer, budget);
        vm.startPrank(buyer);
        usdc.approve(address(ace), budget);
        (uint256 unitsOut, uint256 stableFilled) = ace.buyInventory(loanId, budget, 0, buyer);
        vm.stopPrank();

        /// @dev The ask leg prices the pot into quote and back and BOTH legs floor, so the units it cannot
        /// @dev deliver are strictly under what one quote atom buys -- `unitScale / ask`, the ask here being
        /// @dev book, since no record means no floor to lift it. The row below uses the same bound at its own ask.
        /// @dev A HARDCODED 1 stood here and was never the bound: the round-trip loses `take mod (unitScale/ask)`,
        /// @dev which is a function of the pot's exact value rather than its size, so 1 held by fixture luck alone.
        uint256 dust = read.marketState(mid).unitScale / price + 1;
        assertApproxEqAbs(unitsOut, pot, dust, "the budget clears the pot but for the documented sub-unit dust");
        assertApproxEqAbs(stableFilled, mark, 1, "and the mark is the quote the hub actually charged for it");
    }

    /// @dev The codeless record, and why the lens never has to answer for one.
    /// @dev Genesis INTERVIEWS the record, an address with no code cannot answer, so the market is unconstructible.
    /// @dev `recordStateOf` would report NoPrice on one, which fails closed, but the state is unreachable.
    /// @dev The control is the same struct with the real record, so the refusal is the ADDRESS and nothing else.
    function test_CodelessRecord_IsRefusedAtGenesis() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.deleverageBandBps = 0;
        p.deleverageTargetBps = 0;
        p.deleverageStopBps = 0;
        p.deleverageProtocolBps = 0;

        p.record = address(0xDEAD); // non-zero, no code: every interview call reverts on the codesize check
        vm.expectRevert();
        ace.createMarket(p);

        p.record = address(record);
        assertTrue(ace.createMarket(p) != bytes32(0), "the control: the identical struct with a real record is admitted");
    }

    /// @dev The OTHER half of the mark's ask, which nothing in the tree pinned before this.
    /// @dev A windowed minimum ABOVE the tick's book price floors the ask there, so the mark is not book alone.
    /// @dev The lift is bracketed against the same pot read with the record dropped to book.
    /// @dev The floored number is anchored to a real `buyInventory`, which prices off the identical floor.
    /// @dev Drop the clamp and the mark under-reports a pot by the whole book-to-record gap.
    function test_InventoryMark_FloorsAtTheCapAboveBook_AnchoredToARealBuy() public {
        uint256 loanId = _forceClosedLoan();
        uint256 pot = read.invPotOf(id, loanId);
        assertGt(pot, 0, "the fixture really holds inventory");
        assertGt(P, T_PAR, "and the record's windowed minimum really sits above the tick's book");

        uint256 markFloored = lens.inventoryMark(id, loanId);
        record.setMinPrice(T_PAR); // the record drops to book: the floor stops binding
        uint256 markAtBook = lens.inventoryMark(id, loanId);
        assertGt(markFloored, markAtBook, "a record above book lifts the ask off book, it does not mark at book");

        record.setMinPrice(P);
        uint256 budget = markFloored * 2;
        usdc.mint(buyer, budget);
        vm.startPrank(buyer);
        usdc.approve(address(ace), budget);
        (uint256 unitsOut, uint256 stableFilled) = ace.buyInventory(loanId, budget, 0, buyer);
        vm.stopPrank();

        /// @dev The ask leg prices the pot into quote and back, and both legs FLOOR, so what it cannot
        /// @dev deliver is strictly under the units ONE quote atom buys -- `unitScale / ask`, the ask here
        /// @dev being the record's own minimum, which the row above proved sits over book.
        assertApproxEqAbs(unitsOut, pot, read.marketState(id).unitScale / P + 1, "the budget clears the pot but for the documented sub-unit dust");
        assertApproxEqAbs(stableFilled, markFloored, 1, "and the floored mark is the quote the hub charged");
    }

    /// @dev A settled loan on the fixture market, holding a pot at par.
    /// @dev `forceClose` needs no distress and no price, so the record stays free to vary over the mark itself.
    /// @dev Then rested past the ask hold, read off the market: the mark reports value, the buy needs the clock.
    function _forceClosedLoan() internal returns (uint256 loanId) {
        loanId = _open();
        _warpBy(8 days); // past the fixture's 7-day tenor, so the backstop is armed
        ace.forceClose(loanId);
        _warpTo(read.inventoryAskOpensAt(loanId));
    }

    /// @dev A settled loan holding inventory on a market with NO record.
    /// @dev The market BIDS at a price no record would ever cap to, which is what makes None visible.
    /// @dev `forceClose` is the only door into it: settlement there reads no price at all.
    function _forceClosedLoanOn(bytes32 mid) internal returns (uint256 loanId, uint256 price) {
        _depositAt(mid, 15_000e6);

        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        price = read.fundingFloor(mid, loanId);
        _warpBy(8 days); // past the fixture's 7-day tenor, so the backstop is armed
        ace.forceClose(loanId);
        _warpTo(read.inventoryAskOpensAt(loanId));
    }

    function _depositAt(bytes32 mid, uint256 assets) internal {
        usdc.mint(alice, assets);
        vm.startPrank(alice);
        usdc.approve(address(ace), assets);
        ace.deposit(mid, assets);
        vm.stopPrank();
    }

    function _liveByState(bytes32 mid) internal view returns (bool) {
        (RecordState s,) = lens.recordStateOf(mid);
        return s == RecordState.Live;
    }

    /// @dev A real draw against the real door. `want == 0` asserts it opens; otherwise it must revert with it.
    function _openExpecting(bytes32 mid, bytes4 want) internal {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        if (want != bytes4(0)) vm.expectRevert(want);
        ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev restingOf anchored to a real withdraw: the resting the lens reports must be the cash a
    /// @dev withdraw actually pays, through a REAL payout and never a restated formula.
    /// @dev WAS `restingLots`, an array over one owner's lots at the tick. There is one lender and no lots,
    /// @dev so the tick's cash IS their position there and the array had exactly one entry to return.
    function test_RestingOf_AnchoredToARealWithdraw() public {
        uint256 resting = ace.restingOf(id);
        assertGt(resting, 0, "the fixture's cash really rests");

        vm.prank(alice);
        uint256 out = ace.withdraw(id, type(uint256).max, alice, 0);

        assertEq(out, resting, "the reported resting figure is the real payout");
        assertEq(ace.restingOf(id), 0, "and the tick is empty behind it");
    }

    function _repayAll(uint256 loanId) internal {
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    /// @dev A repay that CREDITS without closing, which is the only kind that leaves a `claimable` to preview.
    /// @dev A closing repay is a terminal door and the hub pushes the whole pool to the lender there, so a
    /// @dev preview row built on one would compare two zeros and assert nothing at all.
    function _repayPart(uint256 loanId) internal {
        uint256 part = read.loan(loanId).debt / 2;
        usdc.mint(borrower, part);
        vm.startPrank(borrower);
        usdc.approve(address(ace), part);
        ace.repay(loanId, part);
        vm.stopPrank();
        assertEq(read.loan(loanId).closedAt, 0, "fixture: the loan is live, so nothing was pushed out from under the preview");
    }

    /// @dev The one-slot form of the market field, for an on-chain caller that keys claimTicks off it.
    /// @dev Anchored to the full record rather than to a constant: one slot map, two readers of it.
    function test_LoanMarket_MatchesTheFullRecord() public {
        uint256 loanId = _open();
        assertEq(lens.loanMarket(loanId), lens.loan(loanId).market, "slot 0 is the record's market field");
        assertEq(lens.loanMarket(loanId), id, "and it names the market the loan was opened in");
    }

    /// @dev Zero for an id nobody opened: a derived-registration caller reads that as "no such loan".
    function test_LoanMarket_IsZeroForAnUnopenedId() public {
        assertEq(lens.loanMarket(999_999), bytes32(0), "an unopened id names no market, and never reverts");
        _open();
        assertEq(lens.loanMarket(999_999), bytes32(0), "still zero once real loans exist beside it");
    }

    /// @dev Loan ids are GLOBAL and markets are not, so this must name the loan's OWN market.
    /// @dev A read that always answered the first market would pass every single-market test ever written.
    function test_LoanMarket_NamesEachLoansOwnMarket() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.minDebt = 11e6; // the one field that gives it a distinct id
        bytes32 other = ace.createMarket(p);
        assertTrue(other != id, "two markets, two ids");

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(other, 15_000e6);
        vm.stopPrank();

        uint256 here = _open();
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        uint256 there = ace.open(other, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        assertEq(lens.loanMarket(here), id, "the first loan names the first market");
        assertEq(lens.loanMarket(there), other, "and the second names the second, never the first");
        assertEq(lens.loanMarket(there), lens.loan(there).market, "both readers agree on the second market too");
    }

    /// @dev The market field outlives the loan, which is what lets a lender contract book a closed class late.
    function test_LoanMarket_SurvivesRepayment() public {
        uint256 loanId = _open();
        _repayAll(loanId);
        assertTrue(lens.loan(loanId).closedAt != 0, "the loan closed");
        assertEq(lens.loanMarket(loanId), id, "and slot 0 still names the market it drew from");
    }

    /// @dev claimable anchored to a real collect: the preview IS the payout, to the wei, and zero after.
    function test_Claimable_IsTheRealClaimToTheWei() public {
        uint256 loanId = _open();
        uint256 atOpen = lens.claimable(alice, address(usdc));
        _repayPart(loanId);

        /// @dev THE MAGNITUDE CLAIM IS NOW A DELTA. It used to read `> PRINCIPAL` off a closing repay; the
        /// @dev hub pushes at a close, so the figure to preview is whatever a LIVE loan has credited so far.
        /// @dev What the row is for -- the preview is the collect's exact payout -- is untouched.
        uint256 preview = lens.claimable(alice, address(usdc));
        assertGt(preview, atOpen, "the repaid principal joined the figure the fee had already opened");
        vm.prank(alice);
        uint256 paid = ace.collect(address(usdc), alice);
        assertEq(preview, paid, "the lens preview is the collect's exact payout");
        assertEq(lens.claimable(alice, address(usdc)), 0, "and it reads zero once collected");
    }

    /// @notice IT IS ONE FIGURE OVER EVERY LOAN, which is what one pool per (lender, quote) buys.
    /// @dev The per-(loan, tick) preview family it replaces -- `claimablesOf`, `claimables`, and the
    /// @dev holder-keyed `claimable` -- went with the receipt ledger: with one claimant per market and one
    /// @dev pool per pair there is no plan to build, so a dead-entry-free row list has nothing to enumerate.
    function test_Claimable_IsOneFigureOverEveryLoan() public {
        uint256 a = _open();
        uint256 oneLoan = lens.claimable(alice, address(usdc));
        _open(); // stays open, so it contributes its origination fee alone
        uint256 twoLoans = lens.claimable(alice, address(usdc));
        _repayPart(a);

        /// @dev PROVED AS TWO DELTAS RATHER THAN ONE MAGNITUDE, and it is a sharper way to say the same thing:
        /// @dev the second loan's fee joins the SAME figure, and so does the first loan's repaid principal.
        /// @dev The old form read `> PRINCIPAL` off a closing repay, which the push now empties before the read.
        uint256 preview = lens.claimable(alice, address(usdc));
        assertGt(twoLoans, oneLoan, "a second loan's fee joins the SAME figure rather than opening its own");
        assertGt(preview, twoLoans, "and the repaid principal joins it too: one figure over every loan");
        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), preview, "and one collect pays all of it");
        assertEq(lens.claimable(alice, address(usdc)), 0, "leaving nothing behind for a second call");
    }

    /// @dev A pair that never lent reads ZERO rather than reverting, exactly as the raw getters do.
    function test_Claimable_AnUnknownPairReadsZeroAndNeverReverts() public view {
        assertEq(lens.claimable(address(0xBEEF), address(usdc)), 0, "a stranger is owed nothing");
        assertEq(lens.claimable(alice, address(0xBEEF)), 0, "and a quote she never lent in reads zero too");
    }

    // ---- a view answers what its verb would do ----

    /// @dev A repaid loan has no collateral, so no trigger, and a record holds above zero: only the closed check refuses it.
    function test_IsHealthy_RepaidLoanIsNeverHealthy() public {
        uint256 loanId = _open();
        record.setAbove(true);
        assertTrue(lens.isHealthy(loanId), "PREMISE: live, and the record holds above the trigger");

        _repayAll(loanId);
        assertTrue(lens.loan(loanId).closedAt != 0, "PREMISE: the repay closed the loan");
        assertEq(lens.triggerPrice(loanId), 0, "PREMISE: a closed loan has no trigger left, which any record holds above");
        assertFalse(lens.inDistress(loanId), "the sibling predicate answers false on a closed loan");
        assertFalse(lens.isHealthy(loanId), "and so does this one: a closed loan is neither healthy nor distressed");
    }

    /// @dev The same predicate on a loan that closed by settlement rather than by repayment.
    function test_IsHealthy_SettledLoanIsNeverHealthy() public {
        uint256 loanId = _forceClosedLoan();
        record.setAbove(true);
        assertTrue(lens.loan(loanId).closedAt != 0, "PREMISE: forceClose closed the loan");
        assertFalse(lens.isHealthy(loanId), "a settled loan is never healthy");
    }

    /// @dev Anchored to the real verb at the tenor's edge: `withdrawCollateral` refuses `LoanMatured` from the expiry second.
    function test_WithdrawableUnits_ZeroFromTheExpirySecond_AsTheVerbRefuses() public {
        uint256 loanId = _open();
        uint256 expiry = read.loan(loanId).expiry;

        _warpTo(expiry - 1);
        uint256 w = lens.withdrawableUnits(id, loanId);
        assertGt(w, 0, "PREMISE: in the last live second the loan sits above its line");
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, w, borrower); // the verb takes the whole offer one second early
        vm.revertToState(snap);

        _warpTo(expiry);
        assertEq(lens.withdrawableUnits(id, loanId), 0, "from the expiry second the view offers nothing");
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        ace.withdrawCollateral(loanId, w, borrower);
    }

    /// @dev The verb refuses `ZeroCollateral` on a withdrawal that strips the lot bare; the view never offers one.
    /// @dev Aimed at the smallest line this market admits, a loan at `minDebt`; a live loan carries debt, so its ceiled line is never zero.
    function test_WithdrawableUnits_AlwaysLeavesAUnit_SoTheVerbNeverRefusesZeroCollateral() public {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        uint256 loanId = ace.open(id, COLL, 10e6, 0, borrower, OpenBounds(0, 0, 0));
        uint256 w = lens.withdrawableUnits(id, loanId);
        assertLt(w, COLL, "the view never offers the whole lot");
        ace.withdrawCollateral(loanId, w, borrower); // the verb takes the whole offer
        vm.stopPrank();

        uint256 left = lens.loan(loanId).collateralUnits;
        assertEq(left, COLL - w, "the verb took exactly the offer");
        assertGe(left, 1, "and at least one unit stays, which is what ZeroCollateral requires");
        assertEq(lens.withdrawableUnits(id, loanId), 0, "nothing further is offered");
    }

    /// @dev A cold venue record's head is its constructor anchor while its windowed minimum is zero.
    /// @dev The draw door reads the minimum and refuses `NoRecordPrice`, so the pre-flight must price it at zero.
    function test_RecordFitFor_ColdRecordPricesZero_AsTheDrawDoorRefuses() public {
        PersistenceRecord cold = AceFixtures.venueRecord(address(this), P, address(usdc), address(vault));
        assertEq(cold.lastObserved(address(usdc), address(vault)), P, "PREMISE: the cold head is the anchor");

        (bool ok, uint256 price) = lens.recordFitFor(address(cold), address(usdc), address(vault));
        assertTrue(ok, "the pair is affirmed, so genesis admits the record");
        assertEq(price, 0, "a cold record pre-flights at zero, the price the draw door reads");

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(cold);
        bytes32 mid = ace.createMarket(p);
        _depositAt(mid, 15_000e6);
        _openExpecting(mid, NoRecordPrice.selector);
    }

    /// @dev The pre-flight prices what the draw reads, the windowed minimum, never a head printing above it.
    function test_RecordFitFor_PricesTheWindowedMinimum_NotTheHead() public {
        record.setObserved(3 * P);
        (bool ok, uint256 price) = lens.recordFitFor(address(record), address(usdc), address(vault));
        assertTrue(ok, "the fixture pair is affirmed");
        assertEq(price, record.minPrice(address(usdc), address(vault)), "the price is the windowed minimum the draw reads");
        assertEq(price, P, "which sits under the head");
    }

    /// @dev A sick or zero-byte minimum is a source genesis refuses: the pre-flight reads it unfit, and still never reverts.
    function test_RecordFitFor_UnreadableMinimum_PricesZeroAndNeverReverts() public {
        record.setSick(true);
        (bool ok, uint256 price) = lens.recordFitFor(address(record), address(usdc), address(vault));
        assertFalse(ok, "a reverting minimum is unfit, as genesis refuses it");
        assertEq(price, 0, "and prices zero");
        _openExpecting(id, RecordUnreadable.selector);

        record.setSick(false);
        record.setShortAnswer(true);
        (ok, price) = lens.recordFitFor(address(record), address(usdc), address(vault));
        assertFalse(ok, "a minimum answered in zero bytes is unfit too");
        assertEq(price, 0, "and prices zero");
        _openExpecting(id, RecordUnreadable.selector);
    }

    /// @dev A source whose minimum reverts is one genesis refuses, so the pre-flight must not call it supported.
    function test_RecordFitFor_SickRecordIsUnsupported_AsGenesisRefuses() public {
        record.setSick(true);
        (bool ok, uint256 price) = lens.recordFitFor(address(record), address(usdc), address(vault));
        assertFalse(ok, "a source genesis refuses is not supported");
        assertEq(price, 0, "and carries no price");

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        vm.expectRevert(bytes("record sick"));
        ace.createMarket(p);
    }

    /// @dev `finalize` refuses a closed loan before it reads the record, so the view must answer without asking it.
    function test_Settleable_ClosedLoanAsksTheRecordNothing() public {
        uint256 loanId = _open();
        _repayAll(loanId);
        assertTrue(lens.loan(loanId).closedAt != 0, "PREMISE: the repay closed the loan");
        vm.etch(address(record), bytes(""));

        vm.expectRevert(LoanClosed.selector);
        ace.finalize(loanId);
        assertFalse(lens.inDistress(loanId), "the sibling predicates answer false without the record");
        assertFalse(lens.isHealthy(loanId), "both of them");
        assertFalse(lens.settleable(loanId), "and so does settleable, rather than reverting on a record with no code");
    }
}
