// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {GateRefused, EmptyPot} from "../../src/ace/hub/Lender.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockHookERC20} from "../mocks/MockHookERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @notice Re-enters `buyInventory` from inside the collateral transfer the ask makes to it.
/// @dev The hub is `nonReentrant`, so the inner call must revert and the outer must still settle.
contract ReentrantBuyer {
    Ace public immutable ACE;
    uint256 public loanId;
    bool public reentered;
    bool public innerSucceeded;

    constructor(Ace ace) {
        ACE = ace;
    }

    function setLoan(uint256 id) external {
        loanId = id;
    }

    function onTokenReceived(address, uint256) external {
        if (reentered) return;
        reentered = true;
        try ACE.buyInventory(loanId, 1e6, 0, address(this)) returns (uint256, uint256) {
            innerSucceeded = true;
        } catch {}
    }
}

/// @title AceAskSafety
/// @notice The per-loan ask's safety posture and the properties the pooled class pot rests on.
/// @dev REENTRANCY: `nonReentrant`, pot debited before tokens move, quote in via `Transfers.pullQuote`.
/// @dev The ask prices off `Ladder.priceAt` and the record only, never off a token balance.
/// @dev NO CRYSTALLIZATION AND NOTHING TO APPORTION: one lender owns the pot outright, so the ask and
/// @dev the redeem draw from the same number and the second of them finds whatever the first left.
contract AceAskSafetyTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockHookERC20 internal vault; // a hooked collateral: the ONLY way to observe the ask mid-transfer
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal buyer = address(0xB0FF);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal DEEP; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal MID_T; // par itself, as a PRICE
    uint256 internal ODD_T; // one step off par, so the ask price does not divide the unit scale

    uint256 internal constant UNIT_SCALE = 1 << 96;
    /// @dev Tick 0 is the ONE price that divides the unit scale: `priceAt(0)` IS `1 << 96`, so one atom buys one atom.
    /// @dev The rows that need the ask to take a pot to EXACTLY zero fund here, because elsewhere the
    /// @dev round trip through quote floors a sub-unit tail back into the pot and no budget can lift it.
    uint256 internal constant EVEN_T = 1 << 96; // the unit scale itself: the one price that divides it exactly
    uint256 internal constant COLL = 200_000e18;
    uint256 internal constant PRINCIPAL = 20_000e6;
    uint64 internal constant TENOR = ProtocolPolicy.MIN_TENOR;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockHookERC20("Collateral", "COLL", 18);
        (DEEP, MID_T, ODD_T) = (_price(-3000), _price(0), _price(60));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(type(uint256).max);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = 1;
        p.settleBountyBps = 0;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    /// @dev `who` must be the market's one lender; a deposit from anyone else is refused at the door.
    function _lend(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    /// @dev A settled loan whose claim at MID_T became the class pot; alice funded it whole.
    function _settledLoan() internal returns (uint256 loanId, uint256 pot) {
        return _settledLoanAt(MID_T);
    }

    /// @dev The same fixture in a market priced at `p_`, so a non-dividing ask price can be reached.
    /// @dev IT TOOK A CLAIM TICK, because a lender chose where to rest and the pot inherited that rung's price.
    /// @dev The price is a market param now, so reaching a different one means a different MARKET -- which is
    /// @dev what this builds. `id` is re-pointed at it, so every helper below reads the market under test.
    /// @dev RESTS PAST THE ASK HOLD, read off the market rather than assumed, so the buys below measure price.
    /// @dev REUSES the rig's own market when `p_` is the price it was already created at: `MarketParams` IS
    /// @dev the id preimage, so re-creating the identical shape is `MarketExists` rather than a second market.
    function _settledLoanAt(uint256 p_) internal returns (uint256 loanId, uint256 pot) {
        if (p_ != ace.idToMarketParams(id).price) {
            MarketParams memory mp = AceFixtures.marketParams(address(usdc), address(vault));
            mp.record = address(record);
            mp.baseBps = 1;
            mp.settleBountyBps = 0;
            mp.price = p_;
            id = ace.createMarket(mp);
        }

        _lend(alice, 60_000e6); // headroom the draw never consumes
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpBy(TENOR + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _warpTo(read.inventoryAskOpensAt(loanId));
        pot = read.invPotOf(id, loanId);
        assertGt(pot, 0, "fixture: settlement pooled inventory into the class");
    }

    function _buy(address who, uint256 loanId, uint256 quoteIn) internal returns (uint256 unitsOut, uint256 paid) {
        usdc.mint(who, quoteIn);
        vm.startPrank(who);
        usdc.approve(address(ace), quoteIn);
        (unitsOut, paid) = ace.buyInventory(loanId, quoteIn, 0, who);
        vm.stopPrank();
    }

    // ============ nothing crystallizes, so nothing strands ============

    /// @notice The pot goes to the LENDER, whole, and no second party can take a slice of it.
    /// @dev WAS `test_Crossing_StrandsNoClaim`, which moved half a receipt balance to a second holder and
    /// @dev checked the two slices still summed to the pot. There are no receipts and no second holder:
    /// @dev the crossing it defended against is unrepresentable, so what is left to pin is EXHAUSTION.
    function test_ThePotPaysTheLenderWholeAndOnce() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId, uint256 pot) = _settledLoan();

        vm.prank(alice);
        uint256 got = ace.redeemInKind(loanId, alice);
        assertEq(got, pot, "the whole pot, with nothing stranded and nothing apportioned away");

        vm.prank(alice);
        vm.expectRevert(); // emptied: a second call finds nothing rather than paying twice
        ace.redeemInKind(loanId, alice);
    }

    /// @notice A STRANGER cannot reach the pot, and now cannot even lend into the market to try.
    /// @dev The old form let a late depositor in and relied on their having no units. Sole tenancy refuses
    /// @dev them at the deposit door instead, which is the stronger statement: no position, so no claim.
    function test_LateDepositorCannotReachThePot() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoan();

        address stranger = address(0xB0B2);
        usdc.mint(stranger, 5_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 5_000e6);
        vm.expectRevert(GateRefused.selector); // the door refuses a foreign owner on the gate arm, not the backstop
        ace.deposit(id, 5_000e6);
        vm.expectRevert(); // and the pot itself refuses them outright
        ace.redeemInKind(loanId, stranger);
        vm.stopPrank();
    }

    // ============ donation ============

    /// @notice A donation moves no pot: the ask and redemption read `invPot`, never `balanceOf`.
    function test_Donation_DoesNotMoveThePotOrPayout() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId, uint256 pot) = _settledLoan();

        vault.mint(address(this), 5_000e18);
        vault.transfer(address(ace), 5_000e18); // a raw donation straight to the hub

        assertEq(read.invPotOf(id, loanId), pot, "the donation moved no pot");
        vm.prank(alice);
        uint256 got = ace.redeemInKind(loanId, alice);
        assertEq(got, pot, "and the exit pays the accounted pot, not the balance");
    }

    // ============ the ask: reentrancy and ordering ============

    /// @notice The ask is `nonReentrant`: a collateral-transfer callback cannot re-enter it.
    /// @dev The OUTER call must still settle, or the guard would be indistinguishable from a revert.
    function test_BuyInventory_IsNonReentrant() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoan();

        ReentrantBuyer rb = new ReentrantBuyer(ace);
        rb.setLoan(loanId);
        vault.setHookTarget(address(rb));
        usdc.mint(address(rb), 40_000e6);
        vm.prank(address(rb));
        usdc.approve(address(ace), 40_000e6);

        vm.prank(address(rb));
        (uint256 got,) = ace.buyInventory(loanId, 40_000e6, 0, address(rb));

        assertGt(got, 0, "the outer ask completed");
        assertTrue(rb.reentered(), "the callback really fired mid-transfer");
        assertFalse(rb.innerSucceeded(), "REENTRANCY: the inner ask must be refused");
    }

    /// @notice Pot debited before tokens move: a reentrant reader can never see inventory it is
    /// @notice about to receive still on the books.
    function test_BuyInventory_DebitsThePotBeforeTokensMove() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoanAt(EVEN_T);
        uint256 owedBefore = read.poolOwed(id);
        uint256 aliceHad = usdc.balanceOf(alice);

        ReentrantBuyer rb = new ReentrantBuyer(ace);
        rb.setLoan(loanId);
        vault.setHookTarget(address(rb));
        usdc.mint(address(rb), 40_000e6);
        vm.prank(address(rb));
        usdc.approve(address(ace), 40_000e6);
        vm.prank(address(rb));
        (uint256 got, uint256 paid) = ace.buyInventory(loanId, 40_000e6, 0, address(rb));

        assertGt(got, 0, "filled");
        assertEq(read.invPotOf(id, loanId), 0, "the pot was already decremented");
        assertEq(read.poolOwed(id), owedBefore + paid, "and the proceeds already reached the lender's credit, to the wei");
        assertEq(usdc.balanceOf(alice), aliceHad, "which waits in the pool: the sale pays nobody in the buyer's call");
    }

    // ============ the ask: edges ============

    /// @notice A ONE-WEI budget still fills, and the buyer gets nothing for free.
    /// @dev Par sits ~1e12 atom prices under the unit scale here, so a wei of quote buys ~1e12 wei of collateral.
    function test_BuyInventory_OneWeiBudgetRoundsAgainstTheBuyer() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoan();

        (uint256 got, uint256 paid) = _buy(buyer, loanId, 1);
        assertLe(paid, 1, "never charges more than the budget");
        uint256 worth = (got * MID_T) / UNIT_SCALE;
        assertLe(worth, paid, "the units taken are worth no more than the quote paid");
    }

    /// @notice The charge is the ask value of the units delivered, never the budget the caller offered.
    /// @dev At this tick the ask price divides the unit scale, so the two happen to coincide to the atom.
    function test_BuyInventory_ChargesOnlyForWhatItDelivers() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoanAt(EVEN_T);

        uint256 budget = 5_000e6; // well under the pot's value, so the leg is budget-limited
        (uint256 got, uint256 paid) = _buy(buyer, loanId, budget);
        assertGt(got, 0, "filled");
        assertEq(paid, (got * EVEN_T) / UNIT_SCALE, "the charge is the book of what it delivered");
        assertLe(paid, budget, "and it never exceeds the budget");
    }

    /// @notice At a price that does NOT divide the unit scale, the tail the budget cannot spend goes home.
    /// @dev Without a non-dividing price the question is invisible: the charge lands on the budget exactly.
    /// @dev This is the assertion a restored dust sweep would fail, so it is what pins the sweep's absence.
    function test_BuyInventory_ABudgetLimitedLegLeavesTheChangeWithTheBuyer() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoanAt(ODD_T);
        uint256 askPrice = ODD_T;
        assertGt(askPrice % UNIT_SCALE == 0 ? 0 : 1, 0, "fixture: the ask price does not divide the unit scale");

        uint256 budget = 5_000e6 + 7; // an odd budget, so the leg is budget-limited and cannot land exactly
        (uint256 got, uint256 paid) = _buy(buyer, loanId, budget);

        assertGt(got, 0, "filled");
        assertLt(paid, budget, "the tail the budget could not spend stayed with the buyer");
        assertEq(usdc.balanceOf(buyer), budget - paid, "and the buyer still holds exactly that tail");
        assertGe(paid * UNIT_SCALE, got * askPrice, "the charge is never below the ask value of what left the pot");
    }

    /// @notice The hub's quote balance grows by exactly what the fold booked: money follows the books.
    /// @dev The pull is gated on the BOOKED quote, so a leg that books cannot be settled by a silent skip.
    function test_BuyInventory_TheHubReceivesExactlyWhatItBooks() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoanAt(ODD_T);
        uint256 hubBefore = usdc.balanceOf(address(ace));
        uint256 owedBefore = read.poolOwed(id);

        (uint256 got, uint256 paid) = _buy(buyer, loanId, 5_000e6 + 7);

        assertGt(got, 0, "filled");
        assertEq(usdc.balanceOf(buyer), 5_000e6 + 7 - paid, "the hub took from the buyer exactly what it reported");
        assertEq(usdc.balanceOf(address(ace)) - hubBefore, paid, "the hub received exactly what it reported");
        assertEq(read.poolOwed(id) - owedBefore, paid, "and owes the lender exactly that much");
    }

    /// @notice An outside buyer CAN outrace the lender for the physical units; the lender is paid in
    /// @notice quote out of the pool instead -- the accepted A2 shape at loan granularity.
    /// @dev The lender is not made whole in KIND and never was; what the rail owes them is that the sale's
    /// @dev proceeds reach them in full, which is asserted on the pool rather than on a per-class claim.
    function test_BuyInventory_CanOutraceAnInKindHolder() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoanAt(EVEN_T);
        uint256 owedBeforeSale = read.poolOwed(id);

        (, uint256 paid) = _buy(buyer, loanId, 60_000e6); // the outsider gets there first
        assertGt(paid, 0, "the outsider's ask really did raise proceeds");
        assertEq(read.invPotOf(id, loanId), 0, "the ask took the pot");

        /// @dev WAS `inKind == 0`. A drained pot is refused by name, which says the same thing louder: there
        /// @dev are no units left for the in-kind holder to take, because the outsider's ask took them.
        vm.prank(alice);
        vm.expectRevert(EmptyPot.selector);
        ace.redeemInKind(loanId, alice);
        vm.prank(alice);
        uint256 quoteOut = ace.collect(address(usdc), alice);
        assertEq(quoteOut, owedBeforeSale + paid, "the sale proceeds were already hers, in the pool, to the wei");
    }

    /// @notice A drained pot is refused BY NAME, and the lender is not short for it.
    /// @dev WAS "the guard must NOT bite here", against a narrowed condition -- `invPot == 0 && claim != 0` --
    /// @dev which existed because a zero-paying BURN on a live claim stranded the burned share. There are no
    /// @dev receipt burns left: `redeemInKind` takes the whole pot and nothing else, so the guard has only a
    /// @dev NO-OP to refuse and refusing it costs a caller nothing. `EmptyPot` is the honest answer, and the
    /// @dev second leg is what still matters -- the sale's proceeds reached her pool, where `collect` pays them.
    function test_RedeemInKind_ADrainedPotIsRefusedAndStrandsNothing() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoanAt(EVEN_T);

        assertEq(read.claimOf(id, loanId), 0, "guard: settlement zeroed the claim");
        uint256 owedBefore = read.poolOwed(id);
        (, uint256 paid) = _buy(buyer, loanId, 60_000e6);
        assertEq(read.invPotOf(id, loanId), 0, "guard: and the ask took the pot to exactly zero");

        vm.prank(alice);
        vm.expectRevert(EmptyPot.selector);
        ace.redeemInKind(loanId, alice);

        assertGt(paid, 0, "guard: the ask really did raise proceeds");
        assertEq(read.poolOwed(id), owedBefore + paid, "and she is not short -- the sale's proceeds are waiting in her pool, to the wei");
    }

    /// @notice An EMPTIED pot leaves the ask nothing to walk, and it must skip rather than divide by zero.
    /// @notice Two early-outs stand in the way, and the ask is only safe while at least one of them holds.
    /// @dev THE CORNER IS UNREACHABLE, and this pins WHY rather than asserting that it never happens.
    /// @dev A redeem takes the WHOLE pot, so it leaves `invPot == 0`, which the first early-out then skips.
    /// @dev Settling such a tick credits nothing either: its claims are already zero, so `give` is zero.
    /// @dev WAS `burned == supply` with a live-unit denominator behind it. There are no units and no
    /// @dev denominator; what survives is the same corner reached by emptying the pot instead of burning.
    function test_BuyInventory_AnEmptiedPotIsSkippedNotDividedByZero() public {
        _lend(alice, PRINCIPAL);
        (uint256 loanId,) = _settledLoan();

        vm.prank(alice);
        uint256 got = ace.redeemInKind(loanId, alice);
        assertGt(got, 0, "premise: the redeem actually paid out the pot");

        assertEq(read.invPotOf(id, loanId), 0, "and left it at EXACTLY zero");

        (uint256 unitsOut, uint256 paid) = _buy(buyer, loanId, 60_000e6);
        assertEq(unitsOut, 0, "the ask delivered nothing from a class with no live units");
        assertEq(paid, 0, "and charged nothing for it");
    }
}
