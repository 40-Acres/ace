// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds, Order, Storage} from "../../src/ace/hub/Types.sol";
import {AlreadyFunded} from "../../src/ace/hub/Borrower.sol";
import {OrderClosed} from "../../src/ace/hub/Orders.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP3DrawBackstops
/// @notice Audit run 2026-09-13-670568 phase 3, register note on #387: which guard, if any, refuses each kind of re-used id.
/// @notice `AlreadyFunded` reads `M.claim`, which a full repay zeroes. The title mint is never undone: the collection has no burn.
/// @dev GREEN on purpose. `B.count` is rolled back with a cheat code, which is the only way to reach a re-used id at all.
/// @dev The one RAIL row forges a live claim instead: no rollback reaches `AlreadyFunded`, since the mint refuses first.
contract AceP3DrawBackstopsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal maker = address(0x3A4E);

    uint256 internal constant PRINCIPAL = 11e6;
    uint256 internal constant COLL = 10_000e18;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(0);
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 100e6);
        ace.deposit(mid, 100e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _repayInFull(uint256 loanId) internal {
        usdc.mint(borrower, PRINCIPAL);
        vm.startPrank(borrower);
        usdc.approve(address(ace), PRINCIPAL);
        ace.repay(loanId, PRINCIPAL);
        vm.stopPrank();
    }

    /// @dev `LoanBook.count` is member 0, so it sits AT the book root.
    function _rollCountBackTo(uint256 n) internal {
        vm.store(address(ace), Storage.BOOK, bytes32(n));
    }

    function _post() internal returns (uint256 orderId) {
        uint256 price = ace.idToMarketParams(mid).price;
        coll.mint(maker, COLL);
        vm.startPrank(maker);
        coll.approve(address(pm), COLL);
        orderId = ace.postOrder(mid, 20e6, price / 2, price, 0, 7 days, 0);
        vm.stopPrank();
    }

    /// @dev A second market on the same hub, securing a DIFFERENT collateral, funded by the same lender.
    function _otherMarket() internal returns (bytes32 other, MockERC20 coll2) {
        coll2 = new MockERC20("Other Collateral", "OTH", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll2));
        p.record = address(0);
        p.lender = alice;
        other = ace.createMarket(p);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 100e6);
        ace.deposit(other, 100e6);
        vm.stopPrank();
    }

    function _openIn(bytes32 market, MockERC20 token) internal returns (uint256 loanId) {
        token.mint(borrower, COLL);
        vm.startPrank(borrower);
        token.approve(address(pm), COLL);
        loanId = ace.open(market, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice CONTROL: a fresh open after a full repay takes the next id and succeeds.
    function test_Control_ANextOpenTakesAFreshId() public {
        uint256 first = _open();
        _repayInFull(first);
        assertEq(_open(), first + 1, "control: the counter moves on");
    }

    /// @notice PREMISE: on a closed loan the claim backstop is disarmed, and the title mint still refuses the re-used id.
    /// @dev The selector is the hub's guard: `_mint` runs `_update` first, and the override pushes `retitle` into a hub mid-`open`.
    /// @dev Were the hub not entered, `_mint`'s own check would refuse next with `ERC721InvalidSender`.
    function test_Premise_TheTitleMintRefusesAReusedLoanId_AfterTheClaimBackstopIsCleared() public {
        uint256 first = _open();
        _repayInFull(first);
        assertEq(read.claimOf(mid, first), 0, "the full repay zeroed the claim `AlreadyFunded` reads");
        _rollCountBackTo(first - 1);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        vm.expectRevert(GUARD_TRIP);
        ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice PREMISE: the mint covers LOAN ids only. An order id shares the counter, has no title, and is not protected by it.
    function test_Premise_TheTitleMintDoesNotCoverAnOrderId() public {
        uint256 orderId = _post();
        _rollCountBackTo(orderId - 1);
        uint256 loanId = _open();
        assertEq(loanId, orderId, "a rolled-back counter re-issues the order's id to a loan, and nothing refuses it");
        assertEq(ace.orderOf(orderId).maker, maker, "the id now names a live order");
        assertTrue(ace.isLiveLoan(loanId), "and a live loan at once");
    }

    /// @notice PREMISE: a LIVE loan's re-used id is refused at the mint, before `AlreadyFunded` reads its still-live claim.
    /// @dev Pins the ordering: were the mint moved after the draw, this row would revert `AlreadyFunded` instead.
    function test_Premise_ALiveLoansReusedIdIsRefusedAtTheMint() public {
        uint256 first = _open();
        assertEq(read.claimOf(mid, first), PRINCIPAL, "the claim `AlreadyFunded` reads is still live");
        _rollCountBackTo(first - 1);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        vm.expectRevert(GUARD_TRIP);
        ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice PREMISE: a loan's id re-issued to an order is refused by nothing; the counter alone keeps the two apart.
    function test_Premise_NothingRefusesALoanIdReissuedToAnOrder() public {
        uint256 loanId = _open();
        _rollCountBackTo(loanId - 1);
        uint256 orderId = _post();
        assertEq(orderId, loanId, "a rolled-back counter re-issues the loan's id to an order, and nothing refuses it");
        assertEq(ace.orderOf(orderId).maker, maker, "the id now names a live order");
        assertTrue(ace.isLiveLoan(loanId), "and a live loan at once");
    }

    /// @notice PREMISE: an order's id re-issued to an order inherits `closed`, because `post` never writes that flag.
    /// @dev The re-posted escrow is then stranded: fill and close both refuse a closed order.
    function test_Premise_AnOrderIdReissuedToAnOrderIsBornClosed() public {
        uint256 first = _post();
        vm.prank(maker);
        ace.closeOrder(first, maker);
        _rollCountBackTo(first - 1);
        uint256 again = _post();
        assertEq(again, first, "a rolled-back counter re-issues the order's id to an order, and nothing refuses it");
        assertTrue(ace.orderOf(again).closed, "the re-posted order is born closed");
        assertEq(pm.collateralOf(again), ace.orderOf(again).collateralUnits, "with exactly the fresh escrow under it");
        vm.expectRevert(OrderClosed.selector);
        vm.prank(maker);
        ace.closeOrder(again, maker);
    }

    /// @notice CONTROL: loans and orders draw from ONE counter, so interleaved they never share an id.
    /// @dev Pins `Orders.post`'s increment, which the loan-only control cannot see and every rollback row masks.
    /// @dev The first id is one: zero is the no-predecessor sentinel, so an order holding it would fill by pull, not carry.
    function test_Control_LoansAndOrdersInterleaveOnOneCounter() public {
        uint256 loanA = _open();
        uint256 orderId = _post();
        uint256 loanB = _open();
        assertEq(loanA, 1, "ids start at one");
        assertEq(orderId, loanA + 1, "an order takes the next id after a loan");
        assertEq(loanB, orderId + 1, "and a loan the next id after an order");
        assertEq(ace.orderOf(loanA).maker, address(0), "a loan's id names no order");
        assertEq(ace.orderOf(loanB).maker, address(0), "nor does the second loan's");
        assertFalse(ace.isLiveLoan(orderId), "an order's id names no loan");
    }

    /// @notice PREMISE: an order whose id is reissued to a live loan can no longer be filled.
    /// @dev The fill's `carryIn` refuses a source a live loan backs, and the reissued id now backs one.
    function test_Premise_AnOrderIdReissuedToALiveLoanCannotBeFilled() public {
        uint256 orderId = _post();
        _rollCountBackTo(orderId - 1);
        assertEq(_open(), orderId, "the order's id now names a live loan");
        Order memory o = ace.orderOf(orderId);
        vm.expectRevert(PositionManager.CarryFromLiveLoan.selector);
        ace.fillOrder(orderId, o.principal, o.collateralUnits);
        uint256 control = _post();
        assertTrue(ace.isLiveLoan(ace.fillOrder(control, o.principal, o.collateralUnits)), "control: the same fill on a fresh order opens");
    }

    /// @notice PREMISE: across two markets, an order whose id is reissued to a loan closes with the LOAN's token.
    /// @dev `escrowConfigOf` resolves the loan record first, so `release` pays the order's escrow out of the loan's collateral.
    function test_Premise_AnOrderIdReissuedToALoanElsewhere_ClosesWithTheLoansToken() public {
        (bytes32 other, MockERC20 coll2) = _otherMarket();
        uint256 orderId = _post();
        uint256 escrow = ace.orderOf(orderId).collateralUnits;
        assertLt(escrow, COLL, "the release fits under the loan's custody, so it pays rather than underflows");
        _rollCountBackTo(orderId - 1);
        assertEq(_openIn(other, coll2), orderId, "the order's id now names a loan in another market");
        uint256 makerColl = coll.balanceOf(maker);
        vm.prank(maker);
        ace.closeOrder(orderId, maker);
        assertEq(coll2.balanceOf(maker), escrow, "the maker is paid the order's escrow in the loan's token");
        assertEq(coll.balanceOf(maker), makerColl, "and none of the token it escrowed");
        assertEq(coll.balanceOf(address(pm)), escrow, "which stays in the pot");
        assertEq(pm.collateralOf(orderId), COLL, "the loan's ledger still reads its whole collateral");
        assertEq(coll2.balanceOf(address(pm)), COLL - escrow, "while the pot holds less of its token");
    }

    /// @notice PREMISE: across two markets, a loan id reissued to an order escrows the LOAN's token into the loan's own ledger.
    /// @dev `pull` resolves the config by id and the loan record wins; the maker holds none of the order market's token.
    function test_Premise_ALoanIdReissuedToAnOrderElsewhere_EscrowsTheLoansToken() public {
        (bytes32 other, MockERC20 coll2) = _otherMarket();
        uint256 loanId = _openIn(other, coll2);
        _rollCountBackTo(loanId - 1);
        uint256 price = ace.idToMarketParams(mid).price;
        coll2.mint(maker, COLL);
        vm.startPrank(maker);
        coll2.approve(address(pm), COLL);
        uint256 orderId = ace.postOrder(mid, 20e6, price / 2, price, 0, 7 days, 0);
        vm.stopPrank();
        assertEq(orderId, loanId, "a rolled-back counter re-issues the loan's id to an order in another market");
        Order memory o = ace.orderOf(orderId);
        assertEq(o.market, mid, "the order rests in the first market");
        assertEq(coll2.balanceOf(maker), COLL - o.collateralUnits, "its escrow was pulled in the loan's token");
        assertEq(coll.balanceOf(address(pm)), 0, "and none of its own market's token reached the pot");
        assertEq(pm.collateralOf(loanId), COLL + o.collateralUnits, "credited into the live loan's own ledger");
    }

    /// @notice PREMISE: the born-closed order refuses a fill as well as a close, so its fresh escrow has no exit.
    function test_Premise_ABornClosedOrderRefusesAFill() public {
        uint256 first = _post();
        vm.prank(maker);
        ace.closeOrder(first, maker);
        _rollCountBackTo(first - 1);
        uint256 again = _post();
        Order memory o = ace.orderOf(again);
        assertEq(o.principal, 20e6, "post rewrote the terms, so the fill is otherwise in range");
        vm.expectRevert(OrderClosed.selector);
        ace.fillOrder(again, o.principal, o.collateralUnits);
    }

    /// @notice RAIL: `AlreadyFunded` is live code that no rollback reaches; a forged live claim on the next fresh id does.
    /// @dev The id is fresh, so the mint passes and `_fund` is the first refusal. Deleting the rail was refused; this row pins that.
    function test_Rail_AlreadyFundedRefusesADrawOntoALiveClaim() public {
        uint256 next = _open() + 1;
        assertEq(read.claimOf(mid, next - 1), PRINCIPAL, "the slot the forge writes is the one a live draw fills");
        vm.store(address(ace), bytes32(read.claimSlot(mid, next)), bytes32(PRINCIPAL));
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        vm.expectRevert(AlreadyFunded.selector);
        ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }
}
