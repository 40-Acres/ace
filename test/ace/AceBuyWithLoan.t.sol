// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @notice OUR flash-loan callback: the one the buy logic is written against, whoever lends the cash.
/// @dev A provider that calls its own callback name reaches the same logic through a shim on the borrower.
interface IAceFlashBorrower {
    /// @notice Called mid-loan; the lender pulls `assets + fee` of `token` back once this returns.
    function onAceFlashLoan(address token, uint256 assets, uint256 fee, bytes calldata data) external;
}

/// @notice The lender's door. Morpho Blue's `flashLoan` has this exact signature, so one call reaches either kind.
interface IFlashLender {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

/// @notice Morpho Blue's callback, implemented only by the borrower's shim.
interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

/// @notice A flash lender that calls OUR callback and may charge a fee, as Aave does and Morpho does not.
contract AceFlashLender is IFlashLender {
    using SafeERC20 for IERC20;

    uint256 public immutable FEE_BPS;

    constructor(uint256 feeBps) {
        FEE_BPS = feeBps;
    }

    /// @notice Lend `assets` of `token` for the length of the callback, then pull back `assets` plus the fee.
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        uint256 fee = assets * FEE_BPS / 10_000;
        IERC20(token).safeTransfer(msg.sender, assets);
        IAceFlashBorrower(msg.sender).onAceFlashLoan(token, assets, fee, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets + fee);
    }
}

/// @notice Morpho Blue's exact flow, zero fee: the production lender on Ethereum, Base and Robinhood Chain.
contract MorphoShapedLender is IFlashLender {
    using SafeERC20 for IERC20;

    /// @notice Send, call back Morpho's callback, pull the same amount back.
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20(token).safeTransfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }
}

/// @notice A seller with one fixed ask: the stand-in for a DEX, an OTC desk or a marketplace listing.
contract FixedPriceSeller {
    using SafeERC20 for IERC20;

    IERC20 public immutable ITEM;
    IERC20 public immutable CASH;
    uint256 public cashPerItem; // cash atoms per WHOLE item (1e18 atoms); the test moves it to tell the story

    constructor(IERC20 item, IERC20 cash, uint256 price) {
        (ITEM, CASH, cashPerItem) = (item, cash, price);
    }

    /// @notice Reprice the ask; the market only, never a loan, reads this.
    function setPrice(uint256 price) external {
        cashPerItem = price;
    }

    /// @notice What `units` cost at the current ask, rounded up so a buyer never underpays.
    function costOf(uint256 units) public view returns (uint256) {
        return (units * cashPerItem + 1e18 - 1) / 1e18;
    }

    /// @notice Take the cash from the caller and deliver the item to `to`.
    function buy(uint256 units, address to) external returns (uint256 cost) {
        cost = costOf(units);
        CASH.safeTransferFrom(msg.sender, address(this), cost);
        ITEM.safeTransfer(to, units);
    }
}

/// @title LeveragedBuyer
/// @notice Buy an item with a loan against that same item, in one transaction: flash, buy, pledge, draw, repay.
/// @notice The buyer puts down only what the loan does not cover: the ask, less the loan's payout.
/// @notice The loan is titled to the BUYER; this contract holds the item and the cash for the length of the call only.
/// @dev A FLASH LOAN IS NEEDED because the hub's `open` pulls collateral before it pays, with no callback between.
/// @dev The logic is written once, behind OUR callback; each provider's own callback is a shim forwarding to it.
/// @dev The buyer must first grant this contract `setCreditOperator`, which is what lets it open in their name.
/// @dev The down payment is pulled from `msg.sender` alone, so nobody can make this spend another party's cash.
contract LeveragedBuyer is IAceFlashBorrower, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;

    error NotFlashLender();
    error NotInBuy(); // a callback arrived outside a buy this contract started
    error WrongToken(); // the lender sent a token other than the one this buy borrowed
    error DownPaymentOverMax(uint256 needed, uint256 max); // the loan covers less of the ask than the buyer allowed for

    struct BuyArgs {
        bytes32 market;
        FixedPriceSeller seller;
        uint256 units;
        uint256 principal;
        address buyer;
        uint256 maxDown;
    }

    Ace public immutable ACE;
    IFlashLender public immutable LENDER;
    address private _cash; // the token the running buy borrowed; zero outside a buy
    uint256 private _loanId; // handed from the callback back to `buyWithLoan`
    uint256 private _down; // likewise

    constructor(Ace ace, IFlashLender lender) {
        (ACE, LENDER) = (ace, lender);
    }

    /// @notice Buy `units` from `seller` and open a loan of `principal` against them, titled to the caller.
    /// @param market The ACE market to draw from; its collateral must be the seller's item.
    /// @param seller Who sells the item.
    /// @param units How much of the item to buy and pledge.
    /// @param principal What to draw against it.
    /// @param maxDown The most cash the caller will put down; the call reverts rather than take more.
    /// @return loanId The loan, titled to the caller.
    /// @return down The cash the caller actually put down.
    function buyWithLoan(bytes32 market, FixedPriceSeller seller, uint256 units, uint256 principal, uint256 maxDown)
        external
        returns (uint256 loanId, uint256 down)
    {
        uint256 cost = seller.costOf(units);
        address cash = ACE.idToMarketParams(market).quote;
        _cash = cash;
        LENDER.flashLoan(cash, cost, abi.encode(BuyArgs(market, seller, units, principal, msg.sender, maxDown)));
        _cash = address(0);
        (loanId, down) = (_loanId, _down);
        (_loanId, _down) = (0, 0);
    }

    /// @notice OUR callback, and the only place the buy is written.
    function onAceFlashLoan(address token, uint256 assets, uint256 fee, bytes calldata data) external {
        _buyPledgeDraw(token, assets, fee, data);
    }

    /// @notice The Morpho shim: Morpho names no token and charges no fee, so it forwards the buy's own token and a zero.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        _buyPledgeDraw(_cash, assets, 0, data);
    }

    /// @dev Buy with the flashed cash, pledge, draw, top up from the buyer, and leave the lender its pull.
    function _buyPledgeDraw(address token, uint256 assets, uint256 fee, bytes calldata data) private {
        if (msg.sender != address(LENDER)) revert NotFlashLender();
        if (_cash == address(0)) revert NotInBuy();
        if (token != _cash) revert WrongToken();
        BuyArgs memory a = abi.decode(data, (BuyArgs));
        MarketParams memory p = ACE.idToMarketParams(a.market);

        IERC20(token).forceApprove(address(a.seller), assets);
        a.seller.buy(a.units, address(this));

        uint256 held = IERC20(token).balanceOf(address(this));
        IERC20(p.collateral).forceApprove(ACE.POSITION_MANAGER(), a.units);
        _loanId = ACE.open(a.market, a.units, a.principal, 0, a.buyer, OpenBounds(0, 0, 0));
        uint256 payout = IERC20(token).balanceOf(address(this)) - held;

        uint256 owed = assets + fee;
        if (payout < owed) {
            uint256 down = owed - payout;
            if (down > a.maxDown) revert DownPaymentOverMax(down, a.maxDown);
            IERC20(token).safeTransferFrom(a.buyer, address(this), down);
            _down = down;
        } else if (payout > owed) {
            IERC20(token).safeTransfer(a.buyer, payout - owed); // a loan worth more than the ask pays the surplus out
        }
        IERC20(token).forceApprove(msg.sender, owed);
    }
}

/// @title AceBuyWithLoan
/// @notice Simulates buying an item with a loan against it on an oracle-free market, with no change to the hub.
/// @notice The buyer puts down the ask less the loan's payout, owns the upside for the term, and can walk away.
/// @dev The market is RECORDLESS, the pawn shop's shape: the lender's bid is the only price and expiry the only ending.
/// @dev Headline numbers: a $1,000 item, a lender bidding 90 cents on the dollar, a 1.4x coverage line, a $600 loan.
contract AceBuyWithLoanTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    bytes32 internal mid;

    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal item; // 18 decimals
    FixedPriceSeller internal seller;
    AceFlashLender internal flash; // calls OUR callback, fee-free
    LeveragedBuyer internal helper;

    address internal lender = AceFixtures.LENDER;
    address internal buyer = address(0xB0B);
    address internal keeper = address(0xCA11E5);

    uint256 internal constant UNITS = 1_000e18; // the item, 1,000 whole tokens
    uint256 internal constant ASK = 1e6; // $1.00 each, so the whole lot costs $1,000
    uint256 internal constant COST = 1_000e6;
    uint256 internal constant PRINCIPAL = 600e6; // under the $642.86 the 1.4x line admits at a 90-cent bid
    uint256 internal constant LENDER_CASH = 10_000e6;
    uint256 internal constant FLASH_CASH = 1_000_000e6;
    uint256 internal constant BUYER_CASH = 1_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        item = new MockERC20("Item", "ITEM", 18);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(item));
        p.record = address(0); // oracle-free: no record, so nothing can end the loan before expiry
        p.price = AceFixtures.px(0.9e18, address(usdc), address(item)); // the lender bids 90 cents per item
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(lender, LENDER_CASH);
        vm.startPrank(lender);
        usdc.approve(address(ace), LENDER_CASH);
        ace.deposit(mid, LENDER_CASH);
        vm.stopPrank();

        seller = new FixedPriceSeller(IERC20(address(item)), IERC20(address(usdc)), ASK);
        item.mint(address(seller), UNITS);
        flash = new AceFlashLender(0);
        usdc.mint(address(flash), FLASH_CASH);
        helper = new LeveragedBuyer(ace, flash);

        usdc.mint(buyer, BUYER_CASH);
        _arm(helper);
    }

    /// @notice One call buys the item, pledges it, draws the loan and repays the flash, and the buyer pays only the gap.
    function test_OneTransaction_TheBuyerPaysOnlyTheAskLessThePayout() public {
        Borrower.Quote memory q = ace.previewOpen(mid, UNITS, PRINCIPAL, 0, buyer, OFF);

        (uint256 loanId, uint256 down) = _buy(PRINCIPAL);

        assertEq(down, COST - q.payout, "the down payment is the ask less the payout, to the atom");
        assertEq(BUYER_CASH - usdc.balanceOf(buyer), down, "the buyer's cash moved by exactly the down payment");
        Loan memory l = read.loan(loanId);
        assertEq(l.borrower, buyer, "the loan is titled to the buyer, never the helper");
        assertEq(l.collateralUnits, UNITS, "the whole purchase is the collateral");
        assertEq(l.debt, PRINCIPAL, "the debt is the principal drawn");
        assertEq(usdc.balanceOf(address(helper)), 0, "the helper keeps no cash");
        assertEq(item.balanceOf(address(helper)), 0, "the helper keeps no item");
        assertEq(usdc.balanceOf(address(flash)), FLASH_CASH, "the flash lender is whole");
        assertEq(usdc.balanceOf(address(seller)), COST, "the seller was paid the full ask");

        emit log_named_decimal_uint("ask ($)", COST, 6);
        emit log_named_decimal_uint("loan principal ($)", PRINCIPAL, 6);
        emit log_named_decimal_uint("all-in fee ($)", q.fee, 6);
        emit log_named_decimal_uint("payout ($)", q.payout, 6);
        emit log_named_decimal_uint("down payment ($)", down, 6);
        emit log_named_decimal_uint("down payment (% of ask)", down * 1e6 / COST, 4);
    }

    /// @notice The item moons: the buyer repays early, takes the whole item back, and gets the unearned fee back.
    function test_ItMoons_RepayEarlyAndKeepTheWholeItem() public {
        (uint256 loanId, uint256 down) = _buy(PRINCIPAL);
        seller.setPrice(3e6); // the item triples; nothing on the loan reads this

        _warpBy(1 days);
        usdc.mint(buyer, PRINCIPAL); // the buyer finds the cash to repay, from any source
        vm.startPrank(buyer);
        usdc.approve(address(ace), PRINCIPAL);
        ace.repay(loanId, PRINCIPAL);
        (uint256 units, uint256 refund) = ace.claimOwed(loanId, buyer);
        vm.stopPrank();

        assertTrue(ace.isClosed(loanId), "a full repay closes the loan");
        assertEq(units, UNITS, "the buyer takes back every unit");
        assertEq(item.balanceOf(buyer), UNITS, "and holds them");
        assertGt(refund, 0, "repaying on day one of seven returns the fee the term did not earn");
        uint256 paid = down + PRINCIPAL - refund;
        assertLt(paid, COST + 3e6, "all in, the buyer paid under the ask plus the fee");

        emit log_named_decimal_uint("total paid for the item ($)", paid, 6);
        emit log_named_decimal_uint("item value at the new ask ($)", seller.costOf(UNITS), 6);
    }

    /// @notice The item dumps: the buyer walks away, loses the down payment and nothing more, and keeps what sits above the line.
    function test_ItDumps_WalkAwayLosingOnlyTheDownPayment() public {
        (uint256 loanId, uint256 down) = _buy(PRINCIPAL);
        seller.setPrice(0.1e6); // the item falls 90%; the lender still cannot act before expiry

        Loan memory l = read.loan(loanId);
        _warpTo(l.expiry + MarketInit.autoRefinanceWindow(l.tenor));
        vm.prank(keeper);
        ace.settleExpired(loanId);

        uint256 kept = read.unitsOwedOf(loanId, buyer);
        uint256 pot = read.invPotOf(mid, loanId);
        assertTrue(ace.isClosed(loanId), "the loan is over and the buyer owes nothing");
        assertEq(kept + pot, UNITS, "every unit went either to the lender's pot or back to the buyer");
        assertGt(kept, 0, "a loan drawn under the line leaves the buyer the units above it");

        vm.prank(buyer);
        ace.claimOwed(loanId, buyer);
        vm.prank(lender);
        ace.redeemInKind(loanId, lender);
        assertEq(item.balanceOf(buyer), kept, "the buyer walks with the units above the line");
        assertEq(item.balanceOf(lender), pot, "the lender takes the coverage line in kind");
        assertEq(BUYER_CASH - usdc.balanceOf(buyer), down, "and the buyer's whole cash loss is the down payment");

        emit log_named_decimal_uint("buyer's cash lost ($)", down, 6);
        emit log_named_decimal_uint("items the buyer keeps", kept, 18);
        emit log_named_decimal_uint("items the lender takes", pot, 18);
    }

    /// @notice A loan the market will not write moves nothing: the buyer, seller and flash lender end exactly as they began.
    function test_AllOrNothing_ALoanTheMarketRefusesMovesNothing() public {
        uint256 tooMuch = 700e6; // over the $642.86 the line admits
        vm.prank(buyer);
        vm.expectRevert();
        helper.buyWithLoan(mid, seller, UNITS, tooMuch, type(uint256).max);

        assertEq(usdc.balanceOf(buyer), BUYER_CASH, "the buyer's cash is untouched");
        assertEq(item.balanceOf(address(seller)), UNITS, "the seller still holds the item");
        assertEq(usdc.balanceOf(address(flash)), FLASH_CASH, "the flash lender is whole");
    }

    /// @notice The buyer's cap on the down payment binds: a thinner loan than they allowed for reverts the whole buy.
    function test_TheDownPaymentCapBinds() public {
        Borrower.Quote memory q = ace.previewOpen(mid, UNITS, PRINCIPAL, 0, buyer, OFF);
        uint256 needed = COST - q.payout;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LeveragedBuyer.DownPaymentOverMax.selector, needed, needed - 1));
        helper.buyWithLoan(mid, seller, UNITS, PRINCIPAL, needed - 1);
    }

    /// @notice Without the buyer's grant the hub refuses to open in their name, so the helper cannot borrow for anyone.
    function test_WithoutTheGrant_TheHubRefuses() public {
        vm.prank(buyer);
        ace.setCreditOperator(address(helper), false);
        vm.prank(buyer);
        vm.expectRevert();
        helper.buyWithLoan(mid, seller, UNITS, PRINCIPAL, type(uint256).max);
    }

    /// @notice The Morpho shim runs the same buy through a Morpho-shaped lender, to the same atom.
    function test_MorphoShim_TheSameBuyThroughMorphosCallback() public {
        MorphoShapedLender morpho = new MorphoShapedLender();
        usdc.mint(address(morpho), FLASH_CASH);
        LeveragedBuyer viaMorpho = new LeveragedBuyer(ace, morpho);
        _arm(viaMorpho);
        Borrower.Quote memory q = ace.previewOpen(mid, UNITS, PRINCIPAL, 0, buyer, OFF);

        vm.prank(buyer);
        (uint256 loanId, uint256 down) = viaMorpho.buyWithLoan(mid, seller, UNITS, PRINCIPAL, type(uint256).max);

        assertEq(down, COST - q.payout, "the shim changes nothing about what the buyer pays");
        assertEq(read.loan(loanId).borrower, buyer, "the loan is still titled to the buyer");
        assertEq(usdc.balanceOf(address(morpho)), FLASH_CASH, "Morpho is whole");
        assertEq(usdc.balanceOf(address(viaMorpho)), 0, "the helper keeps no cash");
    }

    /// @notice A lender that charges a fee is paid out of the down payment, not by anyone else.
    function test_AFlashFeeLandsOnTheDownPayment() public {
        AceFlashLender charging = new AceFlashLender(5); // 5 bps, Aave's flash premium
        usdc.mint(address(charging), FLASH_CASH);
        LeveragedBuyer viaCharging = new LeveragedBuyer(ace, charging);
        _arm(viaCharging);
        Borrower.Quote memory q = ace.previewOpen(mid, UNITS, PRINCIPAL, 0, buyer, OFF);
        uint256 fee = COST * 5 / 10_000;

        vm.prank(buyer);
        (, uint256 down) = viaCharging.buyWithLoan(mid, seller, UNITS, PRINCIPAL, type(uint256).max);

        assertEq(down, COST + fee - q.payout, "the buyer's down payment carries the flash fee");
        assertEq(usdc.balanceOf(address(charging)), FLASH_CASH + fee, "the lender is repaid with its fee");
        assertEq(usdc.balanceOf(address(viaCharging)), 0, "the helper keeps no cash");
    }

    /// @notice Neither callback runs for a stranger, nor for the lender outside a buy the helper started.
    function test_TheCallbacksRefuseStrangersAndStrayCalls() public {
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(LeveragedBuyer.NotFlashLender.selector);
        helper.onAceFlashLoan(address(usdc), 1, 0, "");

        vm.prank(stranger);
        vm.expectRevert(LeveragedBuyer.NotFlashLender.selector);
        helper.onMorphoFlashLoan(1, "");

        vm.prank(address(flash));
        vm.expectRevert(LeveragedBuyer.NotInBuy.selector);
        helper.onAceFlashLoan(address(usdc), 1, 0, "");
    }

    function _buy(uint256 principal) internal returns (uint256 loanId, uint256 down) {
        vm.prank(buyer);
        (loanId, down) = helper.buyWithLoan(mid, seller, UNITS, principal, type(uint256).max);
    }

    /// @dev The buyer's two one-time steps before any buy: approve the helper's pull and grant it the right to open.
    function _arm(LeveragedBuyer h) internal {
        vm.startPrank(buyer);
        usdc.approve(address(h), type(uint256).max);
        ace.setCreditOperator(address(h), true);
        vm.stopPrank();
    }
}
