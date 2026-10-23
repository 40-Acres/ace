// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {LoanClosed, RollWindowOpen} from "../../src/ace/hub/Settlement.sol";
import {MarketParams, MarketState, OpenBounds, Storage} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ReenterOnRetireManager} from "../mocks/ReenterOnRetireManager.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceSettleExpiredHardening
/// @notice The unpaid backstop's REFUSALS and its ACCOUNTING, which `AceFoldWindow` leaves open.
/// @notice That suite pins the clock and the liveness; this one pins what the door says NO to, and what it moves.
/// @dev THE CENTRAL PROPERTY HERE: paid and unpaid settlement of the same loan differ by the sliver and nothing else.
/// @dev SCOPED to a loan holding more than its coverage line, which this fixture does by a wide margin.
/// @dev At a maxed draw the market's bound is the whole lot, so the sliver comes out of the claims' pot instead.
/// @dev `pay == false` suppresses one credit; every other pot -- claims, burns, bad debt, lent -- must be untouched.
/// @dev A door that skipped the shortfall record or double-counted a burn would still pass the sliver assertion alone.
contract AceSettleExpiredHardeningTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;

    MockERC20 internal usdc; // quote, 6 decimals
    MockERC20 internal coll; // collateral, 18 decimals
    bytes32 internal mid; // no gate, no record: dependency-free, and it settles to the coverage line rather than the claims' need

    address internal alice = address(0xA11CE); // the lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5); // any third party running the crank

    uint256 internal TOP; // the ladder's top, named as a distance from this pair's par; assigned in setUp
    int24 internal constant SPACING = 60;
    uint256 internal constant TICKS = 16; // a ladder wide enough that a settlement walks several claims
    uint256 internal constant PER_TICK = 1_000_000; // over `10e6` == 312_500
    uint256 internal constant PRINCIPAL = 11_000_000; // over the fixture's 10e6 minDebt, and across most of the ladder
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint64 internal constant TEN7 = 7 days;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    event SettledUnpaid(uint256 indexed id, uint256 collateralUnits, uint256 badDebt, address indexed executor);

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
        TOP = _price(0);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0); // the market the backstop is FOR: nothing external to ask, and the forfeit rule applies
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
    }

    /* ============================ what the door refuses ============================ */

    /// @notice The pre-window refusal has a NAME, and `AceFoldWindow` asserts only that the call failed.
    /// @notice A raw `!ok` would pass on `NotExpired`, on `NoMarket`, or on an out-of-gas -- none of which is the rule.
    /// @dev Three instants, all before the window: before expiry, at expiry, and one second short of it.
    function test_RollWindowOpen_IsTheNameAtEveryInstantBeforeTheWindow() public {
        uint256 loanId = _ladderLoan();
        uint256 expiry = read.loan(loanId).expiry;
        uint64 w = _window(loanId);
        assertGt(w, 1, "fixture: a one-second window cannot separate the instants below");

        vm.prank(keeper);
        vm.expectRevert(RollWindowOpen.selector);
        ace.settleExpired(loanId); // still inside the term

        _warpTo(expiry);
        vm.prank(keeper);
        vm.expectRevert(RollWindowOpen.selector);
        ace.settleExpired(loanId);

        _warpTo(expiry + w - 1);
        vm.prank(keeper);
        vm.expectRevert(RollWindowOpen.selector);
        ace.settleExpired(loanId);

        _warpTo(expiry + w);
        vm.prank(keeper);
        ace.settleExpired(loanId);
        assertTrue(ace.isClosed(loanId), "and the same call at the window must go through");
    }

    /// @notice A LIVE loan inside its term reads `RollWindowOpen`, never `NotExpired`: the backstop has one clock.
    /// @dev Pinned because the paid door's `NotExpired` is the neighbouring selector and would look right.
    function test_TheBackstopHasOneClock_AndItIsNotThePaidDoors() public {
        uint256 loanId = _ladderLoan();
        vm.prank(keeper);
        (, bytes memory ret) = _trySettleExpired(loanId);
        assertEq(_selectorOf(ret), RollWindowOpen.selector, "the backstop refused under the paid door's clock");
    }

    /// @notice Settling twice must refuse by name, not settle a second time into an empty ledger.
    /// @dev The second call finds `closedAt != 0`, which is the guard every terminal verb shares.
    function test_LoanClosed_ADoubleSettleRefusesByName() public {
        uint256 loanId = _settledLoan();
        uint256 owed = read.unitsOwedOf(loanId, borrower);

        vm.prank(keeper);
        vm.expectRevert(LoanClosed.selector);
        ace.settleExpired(loanId);
        assertEq(read.unitsOwedOf(loanId, borrower), owed, "and nothing was credited a second time");
    }

    /// @notice A loan the PAID door already closed is closed for the backstop too.
    /// @dev The two doors share one terminal flag, so neither can re-settle the other's loan.
    function test_LoanClosed_AfterThePaidDoorRefusesByName() public {
        uint256 loanId = _ladderLoan();
        _warpTo(read.loan(loanId).expiry + _window(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);

        vm.prank(keeper);
        vm.expectRevert(LoanClosed.selector);
        ace.settleExpired(loanId);
    }

    /// @notice A REPAID loan is retired without ever settling, and the backstop must not reopen it.
    /// @dev The sharp case: `closeClean` already credited the borrower the whole lot, so a settle here would double-credit.
    function test_LoanClosed_AfterAFullRepayRefusesByName() public {
        uint256 loanId = _ladderLoan();
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertTrue(ace.isClosed(loanId), "fixture: a full repay retires the loan");
        uint256 owed = read.unitsOwedOf(loanId, borrower);
        assertGt(owed, 0, "fixture: the repay credited the borrower their whole lot");

        _warpTo(read.loan(loanId).expiry + _window(loanId));
        vm.prank(keeper);
        vm.expectRevert(LoanClosed.selector);
        ace.settleExpired(loanId);
        assertEq(read.unitsOwedOf(loanId, borrower), owed, "and the borrower's credit is untouched");
    }

    /* ============================== the reentrancy guard ============================== */

    /// @notice The hub's guard must be HELD across the custody hop, which is the backstop's one external call.
    /// @dev The custodian is the natural seat for a hostile re-entry and it moves no token here, so no
    /// @dev token-side guard covers this door. That is the near-miss shape `retireCustody` was written into once.
    function test_SettleExpired_HoldsTheGuardAcrossTheCustodyHop() public {
        (Ace hub, ReenterOnRetireManager manager, AceLens lens, uint256 loanId) = _reentrantFixture();
        manager.arm(loanId, abi.encodeCall(Ace.settleExpired, (loanId)));
        _warpTo(lens.loan(loanId).expiry + MarketInit.autoRefinanceWindow(TEN7));

        vm.prank(keeper);
        hub.settleExpired(loanId);
        assertEq(manager.attempts(), 1, "the custody hop must actually have fired, or nothing was attempted");
        assertFalse(manager.lastOk(), "GUARD: a re-entrant settleExpired got through the custody hop");
        assertEq(manager.lastSelector(), GUARD_TRIP, "and the GUARD must be what refused it");
        assertTrue(hub.isClosed(loanId), "while the outer settlement still completed");
    }

    /// @notice The lock is the HUB's, not this verb's: an unrelated hub call re-entered from the hop is refused too.
    /// @dev `sweepRevenue` is the control because it is permissionless and succeeds on its own from outside.
    function test_SettleExpired_TheGuardCoversTheWholeHubSurface() public {
        (Ace hub, ReenterOnRetireManager manager, AceLens lens, uint256 loanId) = _reentrantFixture();
        bytes32 m = lens.loan(loanId).market;
        manager.arm(loanId, abi.encodeCall(Ace.sweepRevenue, (m)));
        _warpTo(lens.loan(loanId).expiry + MarketInit.autoRefinanceWindow(TEN7));

        vm.prank(keeper);
        hub.settleExpired(loanId);
        assertEq(manager.attempts(), 1, "the custody hop must actually have fired");
        assertFalse(manager.lastOk(), "GUARD: an unrelated hub verb ran from inside the backstop's custody hop");
        assertEq(manager.lastSelector(), GUARD_TRIP, "and the guard must be what refused it");

        vm.prank(keeper);
        hub.sweepRevenue(m); // control: the same call succeeds from outside, so the refusal above is the guard
    }

    /* ============================ conservation: paid vs unpaid ============================ */

    /// @notice THE CONSERVATION CLAIM: the two doors differ by the sliver and by NOTHING else.
    /// @notice Every pot the settlement touches is captured on both paths over the same loan, under a snapshot.
    /// @dev The sweep is stamped out first, so the paid door's revenue piggyback cannot show up as a difference.
    /// @dev Without that, `totalCash` and the treasury balance would differ for a reason that is not the sliver.
    function test_Conservation_PaidAndUnpaidDifferByExactlyTheSliver() public {
        uint256 loanId = _ladderLoan();
        ace.sweepRevenue(mid); // stamps `lastSweptAt`, so the paid door's piggyback is a no-op below
        uint256 at = read.loan(loanId).expiry + _window(loanId);
        _warpTo(at);
        assertEq(read.claimCount(mid, loanId), 1, "fixture: the loan must hold its claim for a conservation claim to mean anything");

        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        ace.forceClose(loanId);
        Settled memory paid = _capture(loanId);
        vm.revertToState(snap);
        _warpTo(at);

        vm.prank(keeper);
        ace.settleExpired(loanId);
        Settled memory unpaid = _capture(loanId);

        assertGt(paid.keeperUnits, 0, "fixture: the paid door must credit a real sliver, or there is nothing to suppress");
        assertEq(unpaid.keeperUnits, 0, "STEERING: the backstop credited its caller a sliver");
        assertEq(unpaid.borrowerUnits, paid.borrowerUnits + paid.keeperUnits, "the suppressed sliver must land on the borrower");
        assertEq(unpaid.potUnits, paid.potUnits, "the claims' pots must not move with the sliver");
        assertEq(unpaid.burns, paid.burns, "nor the backed burns");
        assertEq(unpaid.totalLent, paid.totalLent, "nor what the market reports as lent");
        assertEq(unpaid.realizedLoss, paid.realizedLoss, "nor the market's realized loss");
        assertEq(unpaid.shortUnits, paid.shortUnits, "nor the per-loan shortfall");
        assertEq(unpaid.shortQuote, paid.shortQuote, "nor its quote leg");
        assertEq(unpaid.treasury, paid.treasury, "and neither door may move a token here");
        assertEq(
            unpaid.keeperUnits + unpaid.borrowerUnits + unpaid.potUnits,
            paid.keeperUnits + paid.borrowerUnits + paid.potUnits,
            "TOTAL: the same lot is distributed either way, only the shares differ"
        );
    }

    /// @notice The same loan settled unpaid puts the sliver's units where the claims can reach them.
    /// @notice On a SHORT settlement that is a strictly better outcome for the lenders, and it must show up as one.
    /// @dev The paid door spends the sliver before the claims are served, so its bad debt is larger by the sliver at book.
    /// @dev A backstop that suppressed the sliver but ALSO failed to pass the units on would read identical to the paid door.
    function test_Conservation_ShortSettlement_TheSuppressedSliverReachesTheClaims() public {
        uint256 loanId = _ladderLoan();
        ace.sweepRevenue(mid);
        uint256 need = _needNow(loanId);
        _shortenTo(loanId, (need * 60) / 100);
        uint256 at = read.loan(loanId).expiry + _window(loanId);
        _warpTo(at);

        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        ace.forceClose(loanId);
        Settled memory paid = _capture(loanId);
        vm.revertToState(snap);
        _warpTo(at);

        vm.prank(keeper);
        ace.settleExpired(loanId);
        Settled memory unpaid = _capture(loanId);

        assertGt(paid.keeperUnits, 0, "fixture: the paid door must credit a sliver here too");
        assertGt(paid.shortUnits, 0, "fixture: the settlement must really be short, or the two doors cannot diverge");
        assertEq(unpaid.borrowerUnits, 0, "a short settlement leaves the borrower nothing, on either door");
        assertEq(paid.borrowerUnits, 0, "including the paid one, so the sliver cannot have gone there");
        assertEq(unpaid.potUnits, paid.potUnits + paid.keeperUnits, "the suppressed sliver must reach the CLAIMS, not vanish");
        assertEq(unpaid.burns, paid.burns + paid.keeperUnits, "and be credited as backed burns, unit for unit");
        assertLt(unpaid.shortUnits, paid.shortUnits, "so the lenders are short by less through the unpaid door");
        assertLt(unpaid.realizedLoss, paid.realizedLoss, "and the market's realized loss is smaller by the sliver at book");
        assertEq(unpaid.totalLent, paid.totalLent, "while what the claims retired is the same either way");
    }

    /* ============================ the rest of the surface ============================ */

    /// @notice The event carries the settlement's own numbers, and the caller as executor although it is unpaid.
    /// @dev `collateralUnits` here is the post-sliver figure, which on this door is the WHOLE lot.
    function test_SettledUnpaid_CarriesTheSettlementsOwnNumbers() public {
        uint256 loanId = _ladderLoan();
        uint256 units = read.loan(loanId).collateralUnits;
        _warpTo(read.loan(loanId).expiry + _window(loanId));

        vm.expectEmit(true, true, true, true);
        emit SettledUnpaid(loanId, units, 0, keeper);
        vm.prank(keeper);
        ace.settleExpired(loanId);
    }

    /// @notice The backstop's own market: no gate, no record, nothing external to ask. It must settle whole.
    /// @notice Recordlessness is an economic rule here too, not only a dependency fact: this class forfeits its coverage.
    /// @dev The claims really convert here, so a door that merely flipped `closedAt` would not pass.
    function test_ARecordlessGatelessMarket_SettlesWhole() public {
        assertEq(ace.idToMarketParams(mid).record, address(0), "fixture: no record");
        assertEq(ace.idToMarketParams(mid).borrower, address(0), "fixture: no gate");
        uint256 loanId = _ladderLoan();
        uint256 lentBefore = read.poolLent(mid);
        _warpTo(read.loan(loanId).expiry + _window(loanId));

        vm.prank(keeper);
        ace.settleExpired(loanId);
        assertTrue(ace.isClosed(loanId), "the loan must close");
        assertEq(read.loan(loanId).collateralUnits, 0, "and leave the live ledger");
        assertLt(read.poolLent(mid), lentBefore, "the claims must have converted, not merely been abandoned");
        assertEq(read.claimOf(mid, loanId), 0, "the claim must be zeroed");
        assertGt(read.invPotOf(mid, loanId), 0, "and the pot must hold the units it converted into");
        assertEq(read.fundingFloor(mid, loanId), 0, "a closed loan carries no funding floor");
    }

    /// @notice A market with NO record still refuses the backstop before the window: the clock is not a dependency.
    /// @dev The window is arithmetic on the loan's own tenor, so nothing external can move it either way.
    function test_TheWindowIsArithmetic_NotADependencyRead() public {
        uint256 loanId = _ladderLoan();
        assertEq(_window(loanId), MarketInit.autoRefinanceWindow(TEN7), "the window is the loan's tenor, nothing else");
        _warpTo(read.loan(loanId).expiry + _window(loanId) - 1);
        vm.prank(keeper);
        vm.expectRevert(RollWindowOpen.selector);
        ace.settleExpired(loanId);
    }

    /* ================================= fixture ================================= */

    /// @notice Every pot one settlement touched, captured so two doors can be compared field for field.
    struct Settled {
        uint256 keeperUnits;
        uint256 borrowerUnits;
        uint256 potUnits;
        uint256 burns;
        uint256 totalLent;
        uint256 realizedLoss;
        uint256 shortUnits;
        uint256 shortQuote;
        uint256 treasury;
    }

    /// @dev One reading of everything a settlement moves, taken after the close has emitted.
    /// @dev The tick list is gone with the ladder: one claim means one pot, and the LENT leg moved to the
    /// @dev lender's pool, so it is read from there rather than off `MarketState`.
    function _capture(uint256 loanId) internal view returns (Settled memory s) {
        s.keeperUnits = read.unitsOwedOf(loanId, keeper);
        s.borrowerUnits = read.unitsOwedOf(loanId, borrower);
        s.potUnits = read.invPotOf(mid, loanId);
        MarketState memory m = read.marketState(mid);
        (s.burns, s.totalLent, s.realizedLoss) = (m.cumulativeBackedBurns, read.poolLent(mid), m.realizedLossAtBook);
        (s.shortUnits, s.shortQuote) = read.shortfallOf(loanId);
        s.treasury = usdc.balanceOf(AceFixtures.TREASURY);
    }

    /// @dev The loan's own backstop window, which is what the door's clock reads.
    function _window(uint256 loanId) internal view returns (uint64) {
        return MarketInit.autoRefinanceWindow(read.loan(loanId).tenor);
    }

    /// @dev Units this loan's live claim needs at its pre-committed price, ceiled as settlement ceils.
    /// @dev WAS a per-tick sum with a ceiling each; one claim at one price leaves one ceiling.
    function _needNow(uint256 loanId) internal view returns (uint256) {
        uint256 amt = read.claimOf(mid, loanId);
        if (amt == 0) return 0;
        uint256 price = read.fundingFloor(mid, loanId);
        return (amt * UNIT_SCALE + price - 1) / price;
    }

    /// @dev Stages collateral scarcity directly, as `AceShortfallReentrancy` does: no admitted loan reaches it.
    /// @dev Writing `collateralUnits` touches no other field and leaves the custodian's real balance alone.
    function _shortenTo(uint256 loanId, uint256 units) internal {
        uint256 loanSlot = uint256(keccak256(abi.encode(loanId, uint256(Storage.BOOK) + 1)));
        vm.store(address(ace), bytes32(loanSlot + 2), bytes32(units)); // word 2 == collateralUnits
    }

    /// @dev The raw form, for the rows that read a selector rather than expecting one.
    function _trySettleExpired(uint256 loanId) internal returns (bool ok, bytes memory ret) {
        return address(ace).call(abi.encodeCall(Ace.settleExpired, (loanId)));
    }

    /// @dev The custom-error selector a raw call came back with; zero when the revert carried no selector.
    function _selectorOf(bytes memory ret) internal pure returns (bytes4 sel) {
        if (ret.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(ret, 32))
        }
    }

    /// @dev Rests what the `TICKS`-rung ladder held IN TOTAL, in the one balance a market now keeps.
    /// @dev The per-rung leg is refused `BelowMinLot`: the deposit floor is `minDebt` itself, and `PER_TICK`
    /// @dev was sized against the old `ceil(minDebt / maxClaimTicks)`, which was a small fraction of it.
    function _ladderLoan() internal returns (uint256 loanId) {
        uint256 total = PER_TICK * TICKS;
        usdc.mint(alice, total);
        vm.startPrank(alice);
        usdc.approve(address(ace), total);
        ace.deposit(mid, total);
        vm.stopPrank();

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, TEN7, borrower, OFF);
        vm.stopPrank();
    }

    /// @dev A loan already put through the backstop, for the rows that act on a settled one.
    function _settledLoan() internal returns (uint256 loanId) {
        loanId = _ladderLoan();
        _warpTo(read.loan(loanId).expiry + _window(loanId));
        vm.prank(keeper);
        ace.settleExpired(loanId);
    }

    /// @dev A hub whose custodian re-enters it from inside `retireCustody`; the manager comes first, at the predicted hub.
    function _reentrantFixture() internal returns (Ace hub, ReenterOnRetireManager manager, AceLens lens, uint256 loanId) {
        address predictedHub = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        manager = new ReenterOnRetireManager(predictedHub);
        hub = new Ace(AceFixtures.TREASURY, address(manager), AceFixtures.PUSH_GAS);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0);
        bytes32 m = hub.createMarket(p);
        lens = new AceLens(address(hub));

        usdc.mint(alice, 20_000e6);
        vm.startPrank(alice);
        usdc.approve(address(hub), 20_000e6);
        hub.deposit(m, 20_000e6);
        vm.stopPrank();

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(manager), COLL);
        loanId = hub.open(m, COLL, 4_500e6, TEN7, borrower, OFF);
        vm.stopPrank();
    }
}
