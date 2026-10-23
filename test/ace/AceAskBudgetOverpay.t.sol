// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceAskBudgetOverpay
/// @notice The per-loan ask's two roundings disagree, and `Lender._askLeg` returns both answers.
/// @notice `gross` floors quote out of units, then `deliver` floors units back out of `gross`.
/// @notice So a one-atom leg can deliver ZERO, and the charge has to follow `deliver`, never `take`.
/// @notice A budget-limited leg leaves the tail it cannot spend with the buyer rather than sweeping it.
/// @dev Both bite only where one collateral ATOM is worth more than one quote atom.
/// @dev `MarketInit` bounds decimals from ABOVE and bounds BOTH gaps; nothing bounds `cd` from below.
/// @dev The fixture below uses a 0-decimal collateral against USDC, which genesis admits today.
contract AceAskBudgetOverpayTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal unitToken; // 0 decimals
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B2);
    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB0FF);
    address internal attacker = address(0xBAD);
    address internal keeper = address(0xCAFE);

    uint256 internal TICK; // 76020 ticks over this pair's par, on the 60 grid: ~2001 quote per whole collateral token
    uint256 internal constant UNIT_SCALE = 1 << 96; // the hub's fixed frame, which no decimal pair moves
    uint256 internal constant DEPOSIT = 6000e6;
    uint256 internal constant PRINCIPAL = 5000e6;
    uint256 internal constant COLL = 36; // the coverage line: requiredAt is 4 whole tokens, plus the 32-tick cap

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        unitToken = new MockERC20("Unit", "UNIT", 0);

        TICK = AceFixtures.priceAt(address(usdc), address(unitToken), 76020);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(unitToken));
        p.record = address(0); // record-less leaves the ask floor at zero, and it forfeits the coverage line into the pot
        p.baseBps = 1;
        p.settleBountyBps = 0; // no sliver, so no unit is diverted to a keeper before the market's own bound
        /// @dev THE PRICE IS THE FIXTURE'S SUBJECT, so the market is created AT it rather than lent at it.
        /// @dev It was a tick a lender chose per deposit; it is a market param now, which is why `setUp`
        /// @dev has to compute it before `createMarket` rather than after.
        p.price = TICK;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        assertEq(read.marketState(id).unitScale, UNIT_SCALE, "fixture: a 0-decimal collateral is admitted");
    }

    function _lend(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    /// @dev A settled loan whose single claim tick became the class pot; alice funded it whole.
    /// @dev `COLL` IS the coverage line, so this recordless settlement forfeits the lot: the pot is the claim plus that excess.
    /// @dev RESTS PAST THE ASK HOLD, read off the market rather than assumed, so the legs below measure rounding.
    function _settledLoan() internal returns (uint256 loanId, uint256 pot) {
        _lend(alice, DEPOSIT);
        unitToken.mint(borrower, COLL);
        vm.startPrank(borrower);
        unitToken.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpBy(7 days + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _warpTo(read.inventoryAskOpensAt(loanId));
        pot = read.invPotOf(id, loanId);
        assertGt(pot, 1, "fixture: settlement pooled at least two atoms into the class");
    }

    /// @dev The quote the hub's books say it holds: resting cash + revenue + the lender's uncollected credit + quote owed to claimants.
    /// @dev The one loan here is settled, so its fee escrow is zero and no term is left to refund.
    function _booked() internal view returns (uint256) {
        return read.poolResting(id) + read.protocolRevenue(id) + read.poolOwed(id) + read.quoteOwedTotal(id);
    }

    /// @notice A leg that delivers ZERO units books nothing: the charge is a function of what left the pot.
    /// @notice The books and the hub's balance move together, so neither may grow without the other.
    /// @dev The caller holds no quote and grants no allowance, so a pull could not have succeeded.
    /// @dev Nothing about the class changes either, so the call cannot accumulate anything by repetition.
    function test_ZeroDeliverLeg_ChargesAndBooksNothing() public {
        (uint256 loanId,) = _settledLoan();
        uint256 price = TICK;
        uint256 stableIn = (2 * price) / UNIT_SCALE - 1; // affords one atom and very nearly a second

        uint256 hubBefore = usdc.balanceOf(address(ace));
        uint256 bookedBefore = _booked();

        vm.prank(attacker);
        (uint256 unitsOut, uint256 stableFilled) = ace.buyInventory(loanId, stableIn, 0, attacker);

        assertEq(unitsOut, 0, "the leg delivered nothing");
        assertEq(usdc.balanceOf(address(ace)), hubBefore, "and the hub pulled no quote");
        emit log_named_uint("quote the fold reported filled", stableFilled);
        emit log_named_uint("quote the hub actually received", 0);
        assertEq(_booked(), bookedBefore, "so the books must not have grown");
    }

    /// @notice Whatever the ask books is real money on the way out: the market's lender collects it in quote.
    /// @dev The collect is capped only by the hub's balance, which also holds that lender's resting cash.
    function test_ZeroDeliverLeg_LeavesRestingCashBacked() public {
        /// @dev WAS BOB'S, a second lender's cash beside alice's. Sole tenancy admits exactly one lender, so
        /// @dev the bystander cash is alice's own -- the property is that RESTING cash stays backed, and it
        /// @dev never depended on whose it was.
        _lend(alice, 20_000e6);
        (uint256 loanId,) = _settledLoan();
        uint256 price = TICK;
        uint256 stableIn = (2 * price) / UNIT_SCALE - 1;

        vm.prank(attacker);
        ace.buyInventory(loanId, stableIn, 0, attacker); // free: nothing is pulled

        vm.prank(alice);
        ace.collect(address(usdc), alice);

        assertGe(usdc.balanceOf(address(ace)), read.poolResting(id), "resting cash must still be backed by real quote");
    }

    /// @notice `invPot -= deliver` subtracts zero here, so nothing depletes and the call is endlessly repeatable.
    /// @dev Three calls off the same undepleted pot must therefore credit three times nothing.
    function test_ZeroDeliverLeg_RepeatedCallsBookNothing() public {
        (uint256 loanId, uint256 pot) = _settledLoan();
        uint256 price = TICK;
        uint256 stableIn = (2 * price) / UNIT_SCALE - 1;
        uint256 bookedBefore = _booked();

        for (uint256 i; i < 3; i++) {
            vm.prank(attacker);
            ace.buyInventory(loanId, stableIn, 0, attacker);
        }

        assertEq(read.invPotOf(id, loanId), pot, "the pot never depleted");
        emit log_named_uint("books grew by", _booked() - bookedBefore);
        assertEq(_booked(), bookedBefore, "three free calls must not have grown the books");
    }

    /// @notice A budget-limited leg is charged for what it delivered, never for what the budget could reach.
    /// @dev Sized so the leg takes two atoms and delivers one; the third atom's budget goes home unspent.
    /// @dev The re-price rounds UP, so `paid` sits at the book price or exactly one quote atom above it.
    /// @dev `minUnitsOut` could never have bounded this: it counts atoms, and the buyer does receive one.
    function test_BudgetLimitedLeg_ChargesOnlyTheBookOfWhatItDelivered() public {
        (uint256 loanId,) = _settledLoan();
        uint256 price = TICK;
        uint256 stableIn = (3 * price) / UNIT_SCALE - 1; // affords two atoms and very nearly a third

        usdc.mint(buyer, stableIn);
        vm.startPrank(buyer);
        usdc.approve(address(ace), stableIn);
        (uint256 unitsOut, uint256 paid) = ace.buyInventory(loanId, stableIn, 1, buyer);
        vm.stopPrank();

        uint256 book = (unitsOut * price) / UNIT_SCALE;
        uint256 fair = book + ((book + 1) * ace.idToMarketParams(id).fillFeeBps + 9999) / 10000; // ceiled fee, on the ceiled gross it rides on
        emit log_named_uint("units delivered (whole collateral tokens)", unitsOut);
        emit log_named_uint("quote paid", paid);
        emit log_named_uint("quote those units are worth at the tick's own book price", fair);
        assertLe(paid, fair + 1, "the ask charged more than the book of what it delivered plus the rounding atom");
        assertGe(paid * UNIT_SCALE, unitsOut * price, "the ask charged LESS than the value of what left the pot");
        assertLt(paid, stableIn, "the unspendable tail of the budget went home with the buyer");
    }
}
