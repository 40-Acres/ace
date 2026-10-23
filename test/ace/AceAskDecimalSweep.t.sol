// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceAskDecimalSweep
/// @notice The zero-deliver ask leg, measured across collateral decimals against a 6-decimal quote.
/// @notice `r` is the quote-atom value of ONE collateral atom: `priceAt(t) / unitScale`.
/// @notice `priceAt` is the WHOLE-token price in WAD, so `r == P * 10 ** (qd - cd)` for a whole-token price `P`.
/// @notice A leg delivers nothing only where `take == 1`, `r > 1`, and `r` is not a whole number.
/// @notice At `r < 1` the `gross == 0` guard returns first, so nothing is credited and nothing is charged.
/// @dev Severity is a PRICE question as much as a decimals one: `r` carries both.
/// @dev The cd = 0 proof lives in AceAskBudgetOverpay.t.sol and is left untouched; this file is the sweep.
/// @dev Every fixture asserts its own unit scale and price band before it asserts anything about the ask.
contract AceAskDecimalSweepTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc; // the quote, 6 decimals in every shape
    MockERC20 internal coll; // the collateral, decimals vary per shape
    bytes32 internal id;
    uint256 internal unitScale; // the market's genesis scale, read back from storage
    uint256 internal price; // PriceFrame.priceAtStep(tick): the whole-token price in WAD

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB0FF);
    address internal attacker = address(0xBAD);
    address internal keeper = address(0xCAFE);

    int24 internal constant TICK_ONE = 60; // ~1.006 quote per whole token: a stablecoin one tick off par
    int24 internal constant TICK_2K = 76020; // ~2001 quote per whole token: ETH-shaped
    int24 internal constant TICK_60K = 110040; // ~60081 quote per whole token: BTC-shaped
    /// @dev The one integral-`r` tick, and it is ABSOLUTE rather than par-relative: `priceAt(0)` IS the unit
    /// @dev scale, so the ratio is exactly one there whatever the pair's decimals. Par is floored onto the
    /// @dev grid and lands a fraction of a rung under true par, so the ratio there is never a whole number.
    int24 internal constant TICK_UNIT_RATIO = 0;

    uint256 internal constant DEPOSIT = 6000e6;
    uint256 internal constant PRINCIPAL = 5000e6;
    uint256 internal constant COLL_VALUE = 12000e6; // collateral sized by VALUE, so every shape gets the same 2.4x

    function setUp() public {
        _warpTo(1_000_000);
    }

    // --- fixtures ---

    /// @notice Stands up a market whose collateral carries `cd` decimals, priced `offset` steps OVER ITS PAR.
    /// @notice Naming the price against par is what keeps a shape a HUMAN price, so the decimals move `r` under it.
    /// @dev The pair has to exist before its par can be read, so the tokens are built twice: once to measure
    /// @dev par against, once inside `_deployShape`. Cheap, and it keeps the price a market param rather than
    /// @dev something a later deposit chooses.
    function _shape(uint8 cd, int24 offset) internal {
        MockERC20 q = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 c = new MockERC20("Collateral", "COLL", cd);
        _deployShape(cd, AceFixtures.priceAt(address(q), address(c), offset));
    }

    /// @notice The same, at an ABSOLUTE step, which the integral-`r` row needs.
    function _shapeAtTick(uint8 cd, int24 t) internal {
        _deployShape(cd, PriceFrame.priceAtStep(t));
    }

    /// @dev The market, created AT the price the shape is about. It used to be created first and a rung
    /// @dev picked after, because a lender chose the rung per deposit; the price is a market param now.
    function _deployShape(uint8 cd, uint256 p_) private {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", cd);

        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(type(uint256).max); // sentinel: leaves the ask floor at zero, as a missing record does
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec); // for the SETTLEMENT rule alone: recordless forfeits the coverage into the pots
        p.baseBps = 1;
        p.settleBountyBps = 0; // no sliver, so every unit reaches the claim conversion
        p.price = p_;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        price = p_;
        unitScale = read.marketState(id).unitScale;
        assertEq(unitScale, 1 << 96, "fixture: genesis admitted this collateral at the atom frame's scale");
        assertEq(ace.idToMarketParams(id).fillFeeBps, 0, "fixture: no fill fee, so effPrice == askPrice");
    }

    /// @dev A human whole-token price in this shape's own frame, so a premise reads as the price it means.
    function _human(uint256 wad) internal view returns (uint256) {
        return AceFixtures.px(wad, address(usdc), address(coll));
    }

    function _lend(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    /// @dev A settled loan whose claim became the inventory pot; alice funded it whole.
    function _settledLoan() internal returns (uint256 loanId, uint256 pot) {
        /// @dev The value leg is the subject; the coverage epsilon rides on top because the LINE demands it.
        /// @dev It is `requiredAt + 1`, where it was `requiredAt + maxClaimTicks` and the cap could dwarf the
        /// @dev value leg at coarse decimals. One atom cannot, which is a simplification the fixture inherits.
        /// @dev That extra atom is returned to the borrower at settlement, so no pot below changes size.
        uint256 units = (COLL_VALUE * unitScale) / price + 1; // the coverage line is requiredAt plus ONE atom
        assertGe(units, 2, "fixture: the shape escrows at least two collateral atoms");
        _lend(alice, DEPOSIT);
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        loanId = ace.open(id, units, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpBy(7 days + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _warpTo(read.inventoryAskOpensAt(loanId)); // the ask rests after settlement; the probes measure rounding
        pot = read.invPotOf(id, loanId);
        assertGt(pot, 1, "fixture: settlement pooled at least two atoms into the class");
    }

    /// @dev The quote the hub's books say it holds: cash + revenue + owed to unit holders.
    function _booked() internal view returns (uint256) {
        return read.poolResting(id) + read.protocolRevenue(id) + read.poolOwed(id) + read.quoteOwedTotal(id);
    }

    // --- the shared probes ---

    /// @notice The zero-deliver call: a leg that hands over nothing is charged nothing and books nothing.
    /// @dev Asserts WHICH branch produced it first, so a green run cannot be mistaken for a guarded shape.
    function _probeZeroDeliver() internal {
        (uint256 loanId,) = _settledLoan();
        assertGt(price / unitScale, 0, "shape: one collateral atom is worth at least one quote atom");
        assertGt(price % unitScale, 0, "shape: r is not a whole number, so the two floors disagree");

        uint256 stableIn = (2 * price) / unitScale; // the largest budget that still affords exactly one atom
        assertEq((stableIn * unitScale) / price, 1, "leg: the budget affords exactly one collateral atom");
        assertEq((price / unitScale * unitScale) / price, 0, "leg: one atom's gross buys back zero atoms");

        uint256 hubBefore = usdc.balanceOf(address(ace));
        uint256 bookedBefore = _booked();

        uint256 g0 = gasleft();
        vm.prank(attacker);
        (uint256 unitsOut, uint256 stableFilled) = ace.buyInventory(loanId, stableIn, 0, attacker);
        uint256 spent = g0 - gasleft();

        emit log_named_uint("r, quote atoms per collateral atom (floor)", price / unitScale);
        emit log_named_uint("credit per call, quote atoms", stableFilled);
        emit log_named_uint("gas for the call, intrinsic 21k excluded", spent);
        emit log_named_uint("quote the hub actually received", usdc.balanceOf(address(ace)) - hubBefore);
        assertEq(unitsOut, 0, "the leg delivered nothing");
        assertEq(stableFilled, 0, "and was charged nothing, because it delivered nothing");
        assertEq(usdc.balanceOf(address(ace)), hubBefore, "the hub pulled no quote");
        assertEq(_booked(), bookedBefore, "so the books must not have grown");
    }

    /// @notice The same call shape where `r < 1`: the `gross == 0` guard returns before anything is booked.
    function _probeGuardedByGross() internal {
        (uint256 loanId, uint256 pot) = _settledLoan();
        assertLt(price, unitScale, "shape: one collateral atom is worth less than one quote atom");

        uint256 stableIn = 1; // the smallest budget that reaches a leg at all
        uint256 affordable = (stableIn * unitScale) / price;
        uint256 take = affordable < pot ? affordable : pot;
        assertGt(take, 0, "guard: `take == 0` is NOT what stops this shape");
        assertEq((take * price) / unitScale, 0, "guard: `gross == 0` is what stops it");

        uint256 hubBefore = usdc.balanceOf(address(ace));
        uint256 bookedBefore = _booked();

        vm.prank(attacker);
        (uint256 unitsOut, uint256 stableFilled) = ace.buyInventory(loanId, stableIn, 0, attacker);

        assertEq(unitsOut, 0, "nothing was delivered");
        assertEq(stableFilled, 0, "and nothing was booked");
        assertEq(usdc.balanceOf(address(ace)), hubBefore, "the hub pulled nothing");
        assertEq(_booked(), bookedBefore, "the books did not grow");
    }

    /// @notice Liveness: the same fixture DOES fill on a real budget, so a quiet probe is the branch, not the market.
    function _probeAskIsLive() internal {
        (uint256 loanId, uint256 pot) = _settledLoan();
        uint256 want = pot / 2;
        uint256 budget = (want * price) / unitScale + 1;
        usdc.mint(buyer, budget);
        uint256 hubBefore = usdc.balanceOf(address(ace));

        vm.startPrank(buyer);
        usdc.approve(address(ace), budget);
        (uint256 unitsOut, uint256 paid) = ace.buyInventory(loanId, budget, 1, buyer);
        vm.stopPrank();

        assertGt(unitsOut, 0, "the fixture's ask delivers on a real budget");
        assertEq(coll.balanceOf(buyer), unitsOut, "and the buyer holds exactly what it reported");
        assertEq(usdc.balanceOf(address(ace)) - hubBefore, paid, "and the hub pulled exactly what it booked");
        assertGe(paid * unitScale, unitsOut * price, "the charge is never below the ask value of what left the pot");
    }

    // --- cd = 0: the control, a whole-token atom at an ETH-shaped price ---

    /// @notice Reproduces the known PoC shape inside this sweep, so the table's control is measured, not cited.
    function test_Cd0_EthShaped_ZeroDeliverChargesAndBooksNothing() public {
        _shape(0, TICK_2K);
        assertApproxEqRel(price, _human(2000e18), 0.01e18, "fixture: ~2000 quote per whole collateral token");
        _probeZeroDeliver();
    }

    /// @notice THE MULTI-LEG ROW IS GONE, and the compounding it measured cannot occur.
    /// @notice It funded one loan at TWO ticks so a single `buyInventory` call walked two legs, and asked
    /// @notice whether N zero-delivering legs credited N times something instead of nothing. The per-leg skip
    /// @notice had to be all-or-nothing, and the walk continued past a leg whose whole pot was one atom.
    /// @notice A settled loan has ONE pot at ONE price, so a call is one leg and there is nothing to compound.
    /// @dev The single-leg property is unchanged and is what the rows either side of this measure.

    // --- cd = 2: GUSD / EURS shaped ---

    /// @notice A 2-decimal stablecoin one tick off par: one atom is a cent, so the credit is ~2 cents a call.
    function test_Cd2_StableShaped_ZeroDeliverChargesAndBooksNothing() public {
        _shape(2, TICK_ONE);
        assertGt(price, _human(1e18), "fixture: one tick above par");
        assertLt(price, _human(1.01e18), "fixture: still a stablecoin price");
        _probeZeroDeliver();
    }

    /// @notice At the frame's one-to-one tick the ratio is a whole number, so both floors agree and the leg delivers its atom.
    /// @dev Not protection: it is ONE tick of the grid, and a neighbouring rung is the test above.
    function test_Cd2_AtPar_IntegralRatioDeliversTheAtom() public {
        _shapeAtTick(2, TICK_UNIT_RATIO);
        assertEq(price, unitScale, "fixture: tick 0 prices one collateral atom at one quote atom");
        assertEq(price % unitScale, 0, "shape: r is a whole number here");
        (uint256 loanId,) = _settledLoan();

        uint256 stableIn = (2 * price) / unitScale;
        uint256 bookedBefore = _booked();
        usdc.mint(buyer, stableIn);
        vm.startPrank(buyer);
        usdc.approve(address(ace), stableIn);
        (uint256 unitsOut, uint256 paid) = ace.buyInventory(loanId, stableIn, 0, buyer);
        vm.stopPrank();

        assertEq(unitsOut, 2, "an integral r delivers every atom the budget buys");
        assertEq(_booked() - bookedBefore, paid, "and the hub booked exactly the quote it received");
    }

    /// @notice The 2-decimal fixture fills normally, so its zero-deliver result is about the branch.
    function test_Cd2_StableShaped_AskDeliversOnARealBudget() public {
        _shape(2, TICK_ONE);
        _probeAskIsLive();
    }

    // --- cd = 6: USDC-shaped, at both a stablecoin and a high price ---

    /// @notice Collateral decimals equal to quote decimals: r is the whole-token price itself.
    /// @notice At a stablecoin price r is barely above one, so the credit is ~2 quote atoms a call.
    function test_Cd6_StableShaped_ZeroDeliverChargesAndBooksNothing() public {
        _shape(6, TICK_ONE);
        assertEq(unitScale, 1 << 96, "fixture: equal decimals carry the same scale as every other layout");
        _probeZeroDeliver();
    }

    /// @notice The same 6-decimal shape at an ETH-shaped price: the credit tracks the price, not the decimals.
    function test_Cd6_HighPriced_ZeroDeliverChargesAndBooksNothing() public {
        _shape(6, TICK_2K);
        assertApproxEqRel(price, _human(2000e18), 0.01e18, "fixture: ~2000 quote per whole collateral token");
        _probeZeroDeliver();
    }

    /// @notice The 6-decimal fixture fills normally.
    function test_Cd6_StableShaped_AskDeliversOnARealBudget() public {
        _shape(6, TICK_ONE);
        _probeAskIsLive();
    }

    // --- cd = 8: WBTC-shaped ---

    /// @notice One WBTC atom is ~6 hundredths of a cent, so the whole credit per call is dust.
    function test_Cd8_WbtcShaped_ZeroDeliverChargesAndBooksNothing() public {
        _shape(8, TICK_60K);
        assertApproxEqRel(price, _human(60_000e18), 0.01e18, "fixture: ~60k quote per whole collateral token");
        _probeZeroDeliver();
    }

    /// @notice The 8-decimal fixture fills normally.
    function test_Cd8_WbtcShaped_AskDeliversOnARealBudget() public {
        _shape(8, TICK_60K);
        _probeAskIsLive();
    }

    /// @notice `invPot -= deliver` subtracts zero at every decimals, so a zero-deliver call can be repeated endlessly.
    /// @dev Three calls off the same undepleted pot must therefore book three times nothing.
    function test_Cd8_WbtcShaped_ZeroDeliverRepeatedCallsBookNothing() public {
        _shape(8, TICK_60K);
        (uint256 loanId, uint256 pot) = _settledLoan();
        uint256 stableIn = (2 * price) / unitScale;
        uint256 bookedBefore = _booked();

        for (uint256 i; i < 3; i++) {
            vm.prank(attacker);
            ace.buyInventory(loanId, stableIn, 0, attacker);
        }

        assertEq(read.invPotOf(id, loanId), pot, "the pot never depleted");
        emit log_named_uint("books grew over three calls, quote atoms", _booked() - bookedBefore);
        assertEq(_booked(), bookedBefore, "three free calls must not have grown the books");
    }

    // --- cd = 18: WETH-shaped, the shape the branch cannot reach ---

    /// @notice One WETH atom is worth ~2e-9 quote atoms, so `gross` floors to zero before `deliver` ever runs.
    function test_Cd18_WethShaped_ZeroDeliverIsUnreachable() public {
        _shape(18, TICK_2K);
        assertApproxEqRel(price, _human(2000e18), 0.01e18, "fixture: ~2000 quote per whole collateral token");
        _probeGuardedByGross();
    }

    /// @notice Across the budget range the 18-decimal ask charges the book of what it delivered, or one atom above.
    /// @dev The one atom IS the re-price's ceiling, and the two bounds below bracket it from both sides.
    function test_Cd18_WethShaped_ChargeStaysAtTheBookOfWhatItDelivered() public {
        _shape(18, TICK_2K);
        (uint256 loanId,) = _settledLoan();
        uint256[6] memory budgets = [uint256(1), 2, 999, 1e6, 12_345_678, 3000e6];

        for (uint256 i; i < budgets.length; i++) {
            usdc.mint(buyer, budgets[i]);
            uint256 hubBefore = usdc.balanceOf(address(ace));
            vm.startPrank(buyer);
            usdc.approve(address(ace), budgets[i]);
            (uint256 unitsOut, uint256 paid) = ace.buyInventory(loanId, budgets[i], 0, buyer);
            vm.stopPrank();
            uint256 book = (unitsOut * price) / unitScale;
            assertEq(usdc.balanceOf(address(ace)) - hubBefore, paid, "the hub pulled exactly what it booked");
            assertLe(paid, book + 1, "the 18-decimal ask overcharged by more than the one rounding atom");
            assertGe(paid * unitScale, unitsOut * price, "the charge fell below the ask value of what left the pot");
        }
    }

    /// @notice The 18-decimal fixture fills normally.
    function test_Cd18_WethShaped_AskDeliversOnARealBudget() public {
        _shape(18, TICK_2K);
        _probeAskIsLive();
    }

    // --- the standing detector across the whole admitted decimals set ---

    /// @notice No admitted decimals and tick pair may book quote for a leg that delivered no units.
    /// @notice The hub's quote balance and its books must move by the same amount on every fill.
    /// @dev The fixed shapes above are one tick each; this is the same law against a fuzzed tick.
    /// @dev `AceInvariants` runs 18-decimal collateral alone, where `r < 1` hides this regime; `AceAskDecimalsInvariants` walks it.
    /// @dev The upper tick bound is where a 0-decimal shape stops settling two whole atoms into the pot.
    function testFuzz_AskBooksNothingWithoutDelivering(uint256 cdSeed, int24 tickSeed, uint256 budget) public {
        uint8[5] memory admitted = [0, 2, 6, 8, 18];
        int24 t = int24(bound(int256(tickSeed), -3000, 76020) / 60) * 60;
        _shape(admitted[cdSeed % 5], t);
        (uint256 loanId,) = _settledLoan();

        budget = bound(budget, 1, 24_000e6);
        usdc.mint(buyer, budget);
        uint256 hubBefore = usdc.balanceOf(address(ace));
        uint256 bookedBefore = _booked();

        vm.startPrank(buyer);
        usdc.approve(address(ace), budget);
        (uint256 unitsOut, uint256 stableFilled) = ace.buyInventory(loanId, budget, 0, buyer);
        vm.stopPrank();

        assertTrue(stableFilled == 0 || unitsOut > 0, "quote was booked for a leg that delivered nothing");
        assertEq(usdc.balanceOf(address(ace)) - hubBefore, stableFilled, "the hub received exactly what it reported");
        assertEq(_booked() - bookedBefore, stableFilled, "and the books grew by exactly that much, never more");
        assertLe(stableFilled, budget, "and the charge never exceeded the budget");
        assertGe(stableFilled * unitScale, unitsOut * price, "the charge fell below the ask value of what left the pot");
    }
}
