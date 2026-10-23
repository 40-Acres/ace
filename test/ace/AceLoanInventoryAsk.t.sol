// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace, InventoryHeld} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {UnitsBelowCallerFloor} from "../../src/ace/hub/Lender.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceLoanInventoryAsk
/// @notice The tombstone property at loan granularity: settlement inventory pools per (loan, tick),
/// @notice `redeemInKind` and the per-loan ask draw from ONE pot and can never sell the same units
/// @notice twice -- and with one lender per market, no per-holder quantity is even representable.
/// @dev Failing-first for the loan-unit receipts rebuild; the design record.
contract AceLoanInventoryAskTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal buyer = address(0xB04E5);
    address internal borrower = address(0xB0BA);
    address internal keeper = address(0xCAFE);

    uint256 internal T4; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T4 = _price(960);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(vault)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (d.ace, d.positionManager, d.read, d.id);
    }

    /// @dev Settled, then rested past the ask hold, which is read off the market rather than assumed.
    /// @dev The in-kind legs never wait on it; only the stranger's ask does, so the warp changes nothing they see.
    /// @dev ONE DEPOSITOR, because the market names one lender: the two-depositor form this replaces would
    /// @dev now revert `NotTheLender` at the second call, and there are no per-holder unit balances to return.
    function _settledLoan() internal returns (uint256 id) {
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 5_000e6);
        ace.deposit(mid, 5_000e6);
        vm.stopPrank();

        vault.mint(borrower, COLL);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), 100e6);
        id = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(id);
        record.setBelow(false);
        vm.warp(read.inventoryAskOpensAt(id));
    }

    /// @dev A funded, still-open loan: the same ladder and draw as `_settledLoan`, minus the finalize.
    function _openLoan() internal returns (uint256 id) {
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 5_000e6);
        ace.deposit(mid, 5_000e6);
        vm.stopPrank();

        vault.mint(borrower, COLL);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), 100e6);
        id = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice The lender takes the WHOLE pot in kind, and a second call finds it empty.
    /// @dev WAS a pro-rata-by-units property across two holders. Sole tenancy leaves one claimant, so the
    /// @dev pot is theirs outright -- there is no share to compute, which is the tombstone this file names.
    /// @dev What still has teeth is EXHAUSTION: the pot pays once and cannot pay the same units twice.
    function test_RedeemInKindPaysTheWholePotOnce() public {
        uint256 id = _settledLoan();
        uint256 pot = read.invPotOf(mid, id);
        assertGt(pot, 0, "fixture: the settlement really left inventory");

        vm.prank(alice);
        uint256 out = ace.redeemInKind(id, alice);

        assertEq(out, pot, "the whole pot pays in kind, with nothing apportioned away");
        assertEq(vault.balanceOf(alice), out, "delivered");
        assertEq(read.invPotOf(mid, id), 0, "and the pot is empty behind it");
    }

    /// @dev The lens's exit mark must refuse wherever the buy leg refuses; it used to clamp to book on NoPrice.
    /// @dev Book is the HIGH clamp, so that answer was optimistic: a mark for a pot nobody could buy.
    /// @dev A REAL pot: an empty one answers zero before consulting the record, so the check would be vacuous.
    function test_InventoryMark_RefusesWhereBuyInventoryRefuses() public {
        uint256 id = _settledLoan();
        AceLens lens = new AceLens(address(ace));
        assertGt(read.invPotOf(mid, id), 0, "the fixture really holds inventory");
        assertGt(lens.inventoryMark(mid, id), 0, "and it marks while the record proves a price");

        record.setMinPrice(0); // the record can no longer price: the buy leg closes

        usdc.mint(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), 1_000e6);
        vm.expectRevert(NoRecordPrice.selector);
        ace.buyInventory(id, 1_000e6, 0, buyer);
        vm.stopPrank();

        vm.expectRevert(NoRecordPrice.selector);
        lens.inventoryMark(mid, id);
    }

    /// @notice Every wei a sale raises reaches the lender, whole: the ask credits the pool and `collect` pays it.
    /// @dev WAS a pro-rata-by-units split between two holders. What survives, and is the half that ever had
    /// @dev teeth, is CONSERVATION: the fill is neither shaved nor stranded on its way to the one claimant.
    function test_AskProceedsAccrueToTheLenderWhole() public {
        uint256 id = _settledLoan();
        vm.prank(alice);
        ace.collect(address(usdc), alice); // flush the fee accrual, isolating the sale proceeds

        usdc.mint(buyer, 2_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), 2_000e6);
        (uint256 unitsOut, uint256 stableFilled) = ace.buyInventory(id, 2_000e6, 1, buyer);
        vm.stopPrank();
        assertGt(unitsOut, 0, "the ask fills");
        assertEq(vault.balanceOf(buyer), unitsOut, "collateral delivered to the buyer");
        assertEq(read.poolOwed(mid), stableFilled, "the whole fill entered the lender's credit, to the wei");

        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), stableFilled, "and all of it pays out on one collect");
    }

    /// @notice A pot already taken in kind raises NOTHING on a later ask: the units are gone, not merely spoken for.
    /// @dev The old form asserted this as "a burned-out holder shares in nothing", which needed two holders to
    /// @dev state. The underlying rail is about the POT, not about who holds what, so it states cleanly here:
    /// @dev an emptied pot has no units left to sell, and the ask must find that rather than credit a phantom.
    function test_AskFindsNothingOnceThePotIsRedeemed() public {
        uint256 id = _settledLoan();
        vm.prank(alice);
        ace.collect(address(usdc), alice);

        vm.prank(alice);
        ace.redeemInKind(id, alice); // the lender exits in kind: the pot is now empty
        assertEq(read.invPotOf(mid, id), 0, "fixture: nothing is left to sell");

        usdc.mint(buyer, 800e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), 800e6);
        (uint256 unitsOut, uint256 stableFilled) = ace.buyInventory(id, 800e6, 0, buyer);
        vm.stopPrank();

        assertEq(unitsOut, 0, "an emptied pot fills nothing");
        assertEq(stableFilled, 0, "so no quote leaves the buyer");
        assertEq(read.poolOwed(mid), 0, "and nothing is credited that no one could ever claim");
    }

    /// @dev An OPEN loan has no pot at all, and the ask says so BY NAME rather than settling empty.
    /// @dev The live arm is `InventoryHeld` too: a loan still running has no pot, on any chain's clock.
    /// @dev The outcome the old silent zero proved is unchanged, and the balances below are what still pin it.
    /// @dev Nothing moves in either direction: no quote leaves the buyer, no collateral arrives, the hub books none.
    function test_AskOnOpenLoanFillsNothing() public {
        uint256 id = _openLoan();
        usdc.mint(buyer, 1_000e6);
        uint256 hubQuote = usdc.balanceOf(address(ace));
        vm.startPrank(buyer);
        usdc.approve(address(ace), 1_000e6);
        vm.expectRevert(InventoryHeld.selector);
        ace.buyInventory(id, 1_000e6, 0, buyer);
        vm.stopPrank();
        assertEq(usdc.balanceOf(buyer), 1_000e6, "the buyer's quote never left their wallet");
        assertEq(vault.balanceOf(buyer), 0, "nor did any collateral arrive");
        assertEq(usdc.balanceOf(address(ace)), hubQuote, "and the hub took nothing for a sale it refused");
    }

    /// @dev ORDERING: the hold is read BEFORE the caller's own bound and before the fill walk.
    /// @dev `minUnitsOut` is 1 and stays 1, so the bound is present and is NOT the selector that fires.
    /// @dev A live loan is therefore refused on the missing pot, never on a walk that found nothing to sell.
    /// @dev `UnitsBelowCallerFloor` keeps its own home on the SETTLED path, in the over-ask test below.
    function test_AskOnOpenLoanRefusesOnTheHoldBeforeTheCallerBound() public {
        uint256 id = _openLoan();
        usdc.mint(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), 1_000e6);
        vm.expectRevert(InventoryHeld.selector);
        ace.buyInventory(id, 1_000e6, 1, buyer);
        vm.stopPrank();
    }

    /// @dev The bound really binds after settlement too: an over-ask reverts and moves nothing.
    function test_SettledAskRefusesOverAskAndLeavesThePotWhole() public {
        uint256 id = _settledLoan();
        uint256 pot0 = read.invPotOf(mid, id);
        usdc.mint(buyer, 500e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), 500e6);
        vm.expectRevert(UnitsBelowCallerFloor.selector);
        ace.buyInventory(id, 500e6, COLL, buyer);
        vm.stopPrank();
        assertEq(read.invPotOf(mid, id), pot0, "a refused ask leaves the pot exactly as it was");
    }

    // DELETED WITH THE TICK COORDINATE: test_RedeemOnUnfundedTickReverts aimed at a tick; a redeem names the LOAN, and the empty-pot refusal is the row below

    /// @dev A second redeem of the same pot finds it empty and refuses cleanly rather than paying twice.
    /// @dev THIS IS THE FILE'S TOMBSTONE PROPERTY, and it is the one that outlived the receipt layer intact:
    /// @dev the pot cannot sell the same units twice, and it never needed a per-holder quantity to say so.
    function test_RedeemTwiceReverts() public {
        uint256 id = _settledLoan();
        vm.prank(alice);
        assertGt(ace.redeemInKind(id, alice), 0, "the first redeem takes the pot");
        assertEq(read.invPotOf(mid, id), 0, "leaving no stranded collateral");
        vm.prank(alice);
        vm.expectRevert();
        ace.redeemInKind(id, alice);
    }

    /// @dev The no-double-sell interleaving: whichever of redeem and the ask runs first, collateral out
    /// @dev never exceeds the pot at settlement, and the pot conserves exactly.
    /// @dev The ask runs FIRST here, so the redeem takes a pot the sale has already partly drained --
    /// @dev which is the corner an ordering bug hides in, and the one the two verbs share a pot for.
    function test_InterleavedRedeemAndAskConserveThePot() public {
        uint256 id = _settledLoan();
        /// @dev The units rest on the LOAN'S RETIRED LEDGER: the hub never custodies settled inventory
        uint256 pot0 = positionManager.retiredOf(id);
        /// @dev It also carries the keeper sliver and the borrower's residual, so it EXCEEDS the tick pot
        uint256 potStart = read.invPotOf(mid, id);

        usdc.mint(buyer, 500e6);
        vm.startPrank(buyer);
        usdc.approve(address(ace), 500e6);
        (uint256 sold,) = ace.buyInventory(id, 500e6, 0, buyer);
        vm.stopPrank();
        assertGt(sold, 0, "fixture: the ask really took part of the pot");

        vm.prank(alice);
        uint256 redeemed = ace.redeemInKind(id, alice);

        assertLe(sold + redeemed, pot0, "deliveries never exceed what the loan had retired");
        assertEq(read.invPotOf(mid, id), 0, "no pot outlives its units");
        assertEq(sold + redeemed, potStart, "conservation: the whole tick pot left, and no more");
    }
}
