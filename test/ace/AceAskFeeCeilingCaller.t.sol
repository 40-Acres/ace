// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice A 6-decimal OpenZeppelin ERC20, so a short pull reverts naming what it needed rather than as a bare underflow.
contract OzQuote6 is ERC20 {
    constructor() ERC20("OZ Quote", "OZQ") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title AceAskFeeCeilingCaller
/// @notice The ceiled fill fee as a caller meets it: the pull it must fund, and the charge at both ends of the fee's genesis range.
/// @notice Approving or holding `stableIn` always covers the charge; a caller sized off the floored-fee law can be one atom short.
/// @dev Every deterministic row asserts a fee REMAINDER, so the floored law and the ceiled one name different charges.
/// @dev The quote is an OpenZeppelin ERC20, so a short pull names its spender, what it had, and what the hub needed.
contract AceAskFeeCeilingCallerTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    OzQuote6 internal quote;
    MockERC20 internal coin; // 18 decimals
    bytes32 internal id; // the mc3 venue-fills market

    address internal alice = AceFixtures.LENDER;
    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB0FF);
    address internal keeper = address(0xCAFE);

    uint256 internal constant UNIT_SCALE = 1 << 96;
    uint256 internal constant PRINCIPAL = 5_000_000e6;
    uint256 internal constant MC3_PRICE = 95_073_795_017_117_205;
    uint256 internal constant MC3_FEE_BPS = 30;
    uint256 internal constant MC3_BUDGET = 2_000e6;
    uint256 internal constant MC3_FLOORED = 1_999_999_999; // what the floored fee charged this buy, measured on the old line
    uint256 internal constant RAIL_BUDGET = 1_234_567_779; // budget-limited at the mc3 price, its fee remainder under half an atom at 1 and 50 bps
    uint256 internal constant CHEAP_PRICE = 792_281_625_199; // ~1e-5 quote per whole token, the regime where the sizing fee's ceiling binds
    uint256 internal constant CHEAP_FEE_BPS = 25;
    uint256 internal constant CHEAP_BUDGET = 5_000_000e6;

    function setUp() public {
        _warpTo(1_000_000);
        quote = new OzQuote6();
        coin = new MockERC20("Coin", "COIN", 18);
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(MC3_PRICE, MC3_FEE_BPS));
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    /// @dev Recordless and band-off: the ask prices at the market's own price, and no sliver diverts a unit.
    function _params(uint256 price, uint256 feeBps) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(quote), address(coin));
        p.record = address(0);
        p.baseBps = 1;
        p.settleBountyBps = 0;
        p.fillFeeBps = feeBps;
        p.price = price;
    }

    /// @dev The band ON at the widest eps genesis admits; the record answers the max sentinel, which the ask reads as no floor.
    function _bandedParams(uint256 price, uint256 feeBps) internal returns (MarketParams memory p) {
        p = _params(price, feeBps);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(quote), address(coin));
        rec.setMinPrice(type(uint256).max);
        p.record = address(rec);
        p.deleverageFloorEpsBps = Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
    }

    /// @dev A settled loan's pot on market `mid`, rested past the ask hold; the collateral posts twice the principal's value.
    function _settledPot(bytes32 mid, uint256 price) internal returns (uint256 loanId, uint256 pot) {
        quote.mint(alice, PRINCIPAL);
        vm.startPrank(alice);
        quote.approve(address(ace), PRINCIPAL);
        ace.deposit(mid, PRINCIPAL);
        vm.stopPrank();
        uint256 coll = (2 * PRINCIPAL * UNIT_SCALE) / price;
        coin.mint(borrower, coll);
        vm.startPrank(borrower);
        coin.approve(address(positionManager), coll);
        loanId = ace.open(mid, coll, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpBy(7 days + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _warpTo(read.inventoryAskOpensAt(loanId));
        pot = read.invPotOf(mid, loanId);
        assertGt(pot, 0, "fixture: settlement pooled inventory into the pot");
    }

    /// @dev The buyer gains `held` and sets its allowance to the hub at `approved`.
    function _fund(uint256 held, uint256 approved) internal {
        quote.mint(buyer, held);
        vm.prank(buyer);
        quote.approve(address(ace), approved);
    }

    function _buy(uint256 loanId, uint256 budget) internal returns (uint256 unitsOut, uint256 paid) {
        vm.prank(buyer);
        (unitsOut, paid) = ace.buyInventory(loanId, budget, 0, buyer);
    }

    /// @dev What a buy on `budget` delivers and charges, from a dry run whose state is rolled back.
    function _dryRun(uint256 loanId, uint256 budget) internal returns (uint256 unitsOut, uint256 paid) {
        uint256 snap = vm.snapshotState();
        _fund(budget, type(uint256).max);
        (unitsOut, paid) = _buy(loanId, budget);
        vm.revertToState(snap);
    }

    /// @dev The ask value of `units` at `price`, ceiled as the hub re-prices what left the pot.
    function _gross(uint256 units, uint256 price) internal pure returns (uint256) {
        return (units * price + UNIT_SCALE - 1) / UNIT_SCALE;
    }

    /// @dev The mc3 pot, with the premise both laws rest on proven from the DELIVERY, never from the hub's charge.
    /// @return loanId The settled loan.
    /// @return ceiled The ceiled law's charge on that delivery, one atom over `MC3_FLOORED`.
    function _mc3Premise() internal returns (uint256 loanId, uint256 ceiled) {
        (loanId,) = _settledPot(id, MC3_PRICE);
        (uint256 unitsOut,) = _dryRun(loanId, MC3_BUDGET);
        uint256 g = _gross(unitsOut, MC3_PRICE);
        assertGt(unitsOut, 0, "premise: the leg fills");
        assertGt((g * MC3_FEE_BPS) % 10000, 0, "premise: the fee leaves a remainder, so a floor and a ceiling differ");
        assertEq(g + (g * MC3_FEE_BPS) / 10000, MC3_FLOORED, "premise: the floored law names the old charge on this delivery");
        ceiled = g + (g * MC3_FEE_BPS + 9999) / 10000;
        assertEq(ceiled, MC3_FLOORED + 1, "premise: the ceiled law is one atom over it");
    }

    // ============ the pull: what a caller must fund ============

    /// @notice A caller approving exactly the floored-law charge is one atom short: the buy reverts AT THE PULL.
    /// @notice The token names the hub as spender and the ceiled-law charge as what it needed.
    function test_BuyInventory_AnApprovalAtTheFlooredChargeFailsThePullByOneAtom() public {
        (uint256 loanId, uint256 ceiled) = _mc3Premise();
        _fund(MC3_BUDGET, MC3_FLOORED);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(ace), MC3_FLOORED, ceiled));
        _buy(loanId, MC3_BUDGET);
    }

    /// @notice The HOLDING half of the same caller: an unlimited allowance over a balance of the floored charge fails on the balance.
    function test_BuyInventory_ABalanceAtTheFlooredChargeFailsThePullByOneAtom() public {
        (uint256 loanId, uint256 ceiled) = _mc3Premise();
        _fund(MC3_FLOORED, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, buyer, MC3_FLOORED, ceiled));
        _buy(loanId, MC3_BUDGET);
    }

    /// @notice A caller approving and holding exactly `stableIn` is covered, here where the charge IS `stableIn`.
    /// @notice The pull takes every atom approved and held, and the hub and the lender's pool gain exactly that.
    function test_BuyInventory_ApprovingStableInCoversAChargeOfExactlyStableIn() public {
        (uint256 loanId, uint256 pot) = _settledPot(id, MC3_PRICE);
        uint256 hubBefore = quote.balanceOf(address(ace));
        uint256 owedBefore = read.poolOwed(id);
        _fund(MC3_BUDGET, MC3_BUDGET);

        (uint256 unitsOut, uint256 paid) = _buy(loanId, MC3_BUDGET);

        uint256 g = _gross(unitsOut, MC3_PRICE);
        assertGt(unitsOut, 0, "premise: the leg filled");
        assertLt(unitsOut, pot, "premise: the leg is budget-limited, the pot outlasts it");
        assertGt((g * MC3_FEE_BPS) % 10000, 0, "premise: the fee leaves a remainder, so the floored law would leave an atom");
        assertEq(paid, MC3_BUDGET, "the charge is the whole budget");
        assertEq(quote.balanceOf(buyer), 0, "the pull took every atom the caller held");
        assertEq(quote.allowance(buyer, address(ace)), 0, "and every atom it approved");
        assertEq(quote.balanceOf(address(ace)), hubBefore + MC3_BUDGET, "the hub received exactly stableIn");
        assertEq(read.poolOwed(id), owedBefore + MC3_BUDGET, "and credited all of it to the lender's pool");
        assertEq(coin.balanceOf(buyer), unitsOut, "the buyer received the units reported");
    }

    /// @notice The same exact funding on a large fill of a cheap-unit collateral, where the SIZING price's ceiled fee is what keeps it covered.
    /// @notice A floored sizing fee sizes this fill a few atoms past the budget, so an exact approval would fail at the pull.
    function test_BuyInventory_ApprovingStableInCoversALargeCheapUnitFill() public {
        bytes32 mid = ace.createMarket(_params(CHEAP_PRICE, CHEAP_FEE_BPS));
        assertEq((CHEAP_PRICE * CHEAP_FEE_BPS) % 10000, 9975, "premise: the sizing fee leaves the widest remainder 25 bps can");
        (uint256 loanId, uint256 pot) = _settledPot(mid, CHEAP_PRICE);
        _fund(CHEAP_BUDGET, CHEAP_BUDGET);

        (uint256 unitsOut, uint256 paid) = _buy(loanId, CHEAP_BUDGET);

        assertGt(unitsOut, 0, "premise: the leg filled");
        assertLt(unitsOut, pot, "premise: the leg is budget-limited, the pot outlasts it");
        assertLe(paid, CHEAP_BUDGET, "the charge fits the budget");
        assertEq(quote.balanceOf(buyer), CHEAP_BUDGET - paid, "and the pull took exactly the charge");
        assertEq(quote.allowance(buyer, address(ace)), CHEAP_BUDGET - paid, "out of an allowance of exactly stableIn");
    }

    /// @notice Sampler over price, fee and budget, pot-limited fills included: the floored-law approval fails the pull by one atom.
    /// @notice Re-approving `stableIn` over the same balance then fills, pulling exactly the ceiled-law charge.
    function testFuzz_BuyInventory_TheFlooredChargeIsOneAtomShortAndStableInCovers(uint256 priceSeed, uint256 feeSeed, uint256 budgetSeed) public {
        uint256 price = bound(priceSeed, 1e4, 1e18);
        uint256 fee = bound(feeSeed, 1, Constants.MAX_FILL_FEE_BPS);
        uint256 budget = bound(budgetSeed, 2, 3 * PRINCIPAL); // past the pot's ~2x-principal value, so pot-limited fills are sampled
        bytes32 mid = price == MC3_PRICE && fee == MC3_FEE_BPS ? id : ace.createMarket(_params(price, fee)); // the params are the id preimage
        (uint256 loanId,) = _settledPot(mid, price);
        (uint256 unitsOut,) = _dryRun(loanId, budget);
        uint256 g = _gross(unitsOut, price);
        vm.assume(unitsOut > 0 && (g * fee) % 10000 != 0);
        uint256 floored = g + (g * fee) / 10000;

        _fund(budget, floored);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(ace), floored, floored + 1));
        _buy(loanId, budget);

        vm.prank(buyer);
        quote.approve(address(ace), budget);
        (uint256 units2, uint256 paid) = _buy(loanId, budget);
        assertEq(units2, unitsOut, "the funded buy delivers what the dry run did");
        assertEq(paid, floored + 1, "and charges the ceiled law, one atom over the floored one");
        assertEq(quote.balanceOf(buyer), budget - paid, "the pull took exactly the charge");
    }

    // ============ the fee at both ends of its genesis range ============

    /// @dev One budget-limited buy on a fresh pot, its premise asserted: a fill, and a fee remainder under half an atom.
    /// @dev Under half, not merely nonzero: a half-up rounding then differs from the ceiling too, so the row pins the direction exactly.
    /// @return g The ask value of what left, ceiled.
    /// @return paid The charge, which must be `g` plus its fee, ceiled.
    function _lawRow(bytes32 mid, uint256 price, uint256 fee, uint256 budget) internal returns (uint256 g, uint256 paid) {
        (uint256 loanId, uint256 pot) = _settledPot(mid, price);
        _fund(budget, budget);
        uint256 unitsOut;
        (unitsOut, paid) = _buy(loanId, budget);
        g = _gross(unitsOut, price);
        assertEq(ace.idToMarketParams(mid).fillFeeBps, fee, "premise: genesis stored the fee this row names");
        assertGt(unitsOut, 0, "premise: the leg filled");
        assertLt(unitsOut, pot, "premise: the leg is budget-limited");
        assertGt((g * fee) % 10000, 0, "premise: the fee leaves a remainder, so a floor and a ceiling differ");
        assertLt((g * fee) % 10000, 5000, "premise: under half an atom, so a half-up rounding and a ceiling differ too");
        assertEq(paid, g + (g * fee + 9999) / 10000, "the charge is the ask value of what left plus its fee, rounded up");
        assertLe(paid, budget, "and never exceeds the caller's budget");
    }

    /// @notice The charge law at the genesis maximum fee on a band-off market, where only the absolute rail binds.
    function test_ChargeLaw_AtTheMaximumFeeWithTheBandOff() public {
        bytes32 mid = ace.createMarket(_params(MC3_PRICE, Constants.MAX_FILL_FEE_BPS));
        assertEq(ace.idToMarketParams(mid).deleverageBandBps, 0, "premise: the band is off");
        _lawRow(mid, MC3_PRICE, Constants.MAX_FILL_FEE_BPS, RAIL_BUDGET);
    }

    /// @notice The same law with the band ON and the fee at its absolute ceiling: no ratio to eps binds it any more.
    function test_ChargeLaw_AtTheMaximumFeeWithTheBandOn() public {
        bytes32 mid = ace.createMarket(_bandedParams(MC3_PRICE, Constants.MAX_FILL_FEE_BPS));
        MarketParams memory s = ace.idToMarketParams(mid);
        assertGt(s.deleverageBandBps, 0, "premise: the band is on");
        assertEq(s.deleverageFloorEpsBps, Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS, "premise: at the widest eps genesis admits");
        assertEq(s.fillFeeBps, Constants.MAX_FILL_FEE_BPS, "premise: the fee sits at its own ceiling");
        assertEq(MockPersistenceRecord(s.record).minPrice(address(quote), address(coin)), type(uint256).max, "premise: no ask floor, the ask is the price");
        _lawRow(mid, MC3_PRICE, Constants.MAX_FILL_FEE_BPS, RAIL_BUDGET);
    }

    /// @notice The charge law at the smallest nonzero fee, 1 bp, where the floor and the ceiling differ on any gross off a multiple of 1e4.
    function test_ChargeLaw_AtTheSmallestFee() public {
        bytes32 mid = ace.createMarket(_params(MC3_PRICE, 1));
        _lawRow(mid, MC3_PRICE, 1, RAIL_BUDGET);
    }

    /// @notice A fill too small for a floored fee to reach an atom still pays one: under a gross of 1e4 at 1 bp, of 200 at 50 bps.
    /// @notice Under the floor such a fill paid NO fee, so a buyer splitting a pot into them paid the lender none at all.
    function test_ChargeLaw_ASubThresholdFillPaysOneAtomOfFeeAtBothEnds() public {
        _subThresholdRow(1, 4_000);
        _subThresholdRow(Constants.MAX_FILL_FEE_BPS, 80);
    }

    function _subThresholdRow(uint256 fee, uint256 budget) internal {
        bytes32 mid = ace.createMarket(_params(MC3_PRICE, fee));
        (uint256 g, uint256 paid) = _lawRow(mid, MC3_PRICE, fee, budget);
        assertLt(g * fee, 10000, "premise: a floored fee on this gross is zero");
        assertEq(paid, g + 1, "the ceiled fee is exactly one atom");
    }
}
