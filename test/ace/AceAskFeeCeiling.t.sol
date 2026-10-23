// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceAskFeeCeiling
/// @notice `Lender._askLeg` sizes a fill off an all-in unit price whose fee is CEILED, and that ceiling is what keeps the charge inside the budget.
/// @notice The charge is `gross + ceil(gross * fee / 1e4)`, so the sizing price must be at least `price * (1 + fee / 1e4)` for the charge to fit.
/// @notice A FLOORED fee under-prices each unit by `(price * fee mod 1e4) / 1e4` of an atom, and a fill of `n` units over-spends by `n` times that.
/// @dev The overshoot is `budget * r / (1e4 * effPrice)` with `r = price * fee mod 1e4`, so it reaches an atom once the budget passes the Q96 price.
/// @dev In the Q96 frame that is a cheap-unit collateral at a large fill, which is why the fee-free fixtures of every other ask suite never saw it.
/// @dev Every deterministic row asserts its REMAINDER premise: where `x * fee` is a multiple of 1e4 the ceiling and the floor agree and nothing is pinned.
/// @dev The two fuzz rows assert none, as samplers: each holds its property across the whole range, so no run needs a premise to bite.
/// @dev A floored charge fee fails the exact-law fuzz on any run with a remainder; a floored sizing fee fails the budget fuzz once its overshoot is an atom.
contract AceAskFeeCeilingTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal coin; // 18 decimals, priced near a hundred-thousandth of a dollar
    bytes32 internal id;

    address internal alice = AceFixtures.LENDER;
    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB0FF);
    address internal keeper = address(0xCAFE);

    uint256 internal constant UNIT_SCALE = 1 << 96;
    /// @dev ~1e-5 quote per whole token, chosen `== 399 mod 400` so `price * 25 mod 1e4` is 9975, the largest remainder a 25 bps fee can leave.
    uint256 internal constant PRICE = 792_281_625_199;
    uint256 internal constant FEE_BPS = 25;
    uint256 internal constant PRINCIPAL = 5_000_000e6;
    uint256 internal constant COLL = 1e30; // 1e12 whole tokens, about twice the principal at the price, so the open clears its line
    uint256 internal constant BUDGET = 5_000_000e6; // under the pot's ask value, so the leg is budget-limited

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coin = new MockERC20("Coin", "COIN", 18);
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(PRICE, FEE_BPS));
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    /// @dev Recordless, so the ask floor is zero and the ask prices at the market's own price; no sliver diverts a unit.
    function _params(uint256 price, uint256 feeBps) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coin));
        p.record = address(0);
        p.baseBps = 1;
        p.settleBountyBps = 0;
        p.fillFeeBps = feeBps;
        p.price = price;
    }

    /// @dev A settled loan's pot on market `mid`, rested past the ask hold; the collateral posts twice the principal's value.
    function _settledPot(bytes32 mid, uint256 price, uint256 principal) internal returns (uint256 loanId, uint256 pot) {
        usdc.mint(alice, principal);
        vm.startPrank(alice);
        usdc.approve(address(ace), principal);
        ace.deposit(mid, principal);
        vm.stopPrank();
        uint256 coll = (2 * principal * UNIT_SCALE) / price;
        coin.mint(borrower, coll);
        vm.startPrank(borrower);
        coin.approve(address(positionManager), coll);
        loanId = ace.open(mid, coll, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpBy(7 days + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _warpTo(read.inventoryAskOpensAt(loanId));
        pot = read.invPotOf(mid, loanId);
        assertGt(pot, 0, "fixture: settlement pooled inventory into the pot");
    }

    /// @dev A buyer holding twice the budget under an UNLIMITED allowance, so an overcharge lands as a debit rather than a failed pull.
    function _buy(uint256 loanId, uint256 budget) internal returns (uint256 unitsOut, uint256 paid, uint256 spent) {
        usdc.mint(buyer, 2 * budget);
        uint256 held = usdc.balanceOf(buyer);
        vm.startPrank(buyer);
        usdc.approve(address(ace), type(uint256).max);
        (unitsOut, paid) = ace.buyInventory(loanId, budget, 0, buyer);
        vm.stopPrank();
        spent = held - usdc.balanceOf(buyer);
    }

    /// @notice A large budget-limited fill of a cheap-unit collateral is charged no more than its budget.
    /// @notice This is the row a floored fee fails: it sizes about 6e-12 of an atom too cheap per quote atom, and $5M of budget carries ~4 atoms over.
    /// @dev The charge is also never below the ask value of what left the pot, so the budget bound is not met by under-charging.
    function test_BuyInventory_TheCeiledFeeKeepsALargeFillInsideItsBudget() public {
        assertEq((PRICE * FEE_BPS) % 10000, 9975, "premise: the fee leaves a remainder, so a ceiling and a floor differ");
        (uint256 loanId, uint256 pot) = _settledPot(id, PRICE, PRINCIPAL);

        (uint256 unitsOut, uint256 paid, uint256 spent) = _buy(loanId, BUDGET);

        assertGt(unitsOut, 0, "premise: the leg filled");
        assertLt(unitsOut, pot, "premise: the leg is budget-limited, the pot outlasts it");
        assertEq(spent, paid, "the buyer is debited exactly the reported charge");
        assertLe(paid, BUDGET, "the charge never exceeds the caller's budget");
        assertGe(paid * UNIT_SCALE, unitsOut * PRICE, "and never falls below the ask value of what left the pot");
        assertGe(paid + 8, BUDGET, "the budget is spent to within a few atoms, so the bound is binding here");
    }

    /// @notice The budget bound, fuzzed over the price, the fee and the budget, on a budget-limited leg.
    /// @dev Cheap Q96 prices on purpose: the floored fee's overshoot scales with `budget / price`, so this is where the ceiling carries weight.
    function testFuzz_BuyInventory_TheChargeNeverExceedsTheBudget(uint256 priceSeed, uint256 feeSeed, uint256 budgetSeed) public {
        uint256 price = bound(priceSeed, 1e4, 1e12);
        uint256 feeBps = bound(feeSeed, 1, 50);
        uint256 budget = bound(budgetSeed, 1, PRINCIPAL);
        bytes32 mid = price == PRICE && feeBps == FEE_BPS ? id : ace.createMarket(_params(price, feeBps)); // the params are the id preimage
        (uint256 loanId, uint256 pot) = _settledPot(mid, price, PRINCIPAL);

        (uint256 unitsOut, uint256 paid, uint256 spent) = _buy(loanId, budget);

        assertLt(unitsOut, pot, "premise: the leg is budget-limited");
        assertEq(spent, paid, "the buyer is debited exactly the reported charge");
        assertLe(paid, budget, "the charge never exceeds the caller's budget");
        assertGe(paid * UNIT_SCALE, unitsOut * price, "and never falls below the ask value of what left the pot");
    }

    /// @notice The fee on the charge rounds UP, so the mc3 venue-fills buy spends its 2,000 USDC budget to the atom.
    /// @notice A floored fee leaves that charge one atom short, at 1_999_999_999.
    /// @dev The lender's pool is credited exactly the charge: the whole fill fee is the lender's.
    function test_BuyInventory_TheFeeRoundsUpAndSpendsTheBudgetToTheAtom() public {
        uint256 price = 95_073_795_017_117_205;
        uint256 feeBps = 30;
        uint256 budget = 2_000e6;
        bytes32 mid = ace.createMarket(_params(price, feeBps));
        (uint256 loanId, uint256 pot) = _settledPot(mid, price, PRINCIPAL);
        uint256 owedBefore = read.poolOwed(mid);

        (uint256 unitsOut, uint256 paid, uint256 spent) = _buy(loanId, budget);

        uint256 g = (unitsOut * price + UNIT_SCALE - 1) / UNIT_SCALE; // the ask value of what left, ceiled as the hub prices it
        assertGt(unitsOut, 0, "premise: the leg filled");
        assertLt(unitsOut, pot, "premise: the leg is budget-limited, the pot outlasts it");
        assertGt((g * feeBps) % 10000, 0, "premise: the fee leaves a remainder, so a ceiling and a floor differ");
        assertEq(paid, g + (g * feeBps + 9999) / 10000, "the fee on the charge rounds up");
        assertEq(paid, budget, "so the charge spends the budget to the atom");
        assertEq(spent, paid, "the buyer is debited exactly the reported charge");
        assertEq(read.poolOwed(mid) - owedBefore, paid, "the lender's pool is credited the whole charge");
    }

    /// @notice The exact charge law, fuzzed: the fee rides on the re-priced gross and rounds UP.
    /// @dev `g` is recomputed from the units delivered, so a fee ceiled on the pre-reprice gross fails this as a floored one does.
    function testFuzz_BuyInventory_TheFeeIsCeiledOnTheChargeItRidesOn(uint256 priceSeed, uint256 feeSeed, uint256 budgetSeed) public {
        uint256 price = bound(priceSeed, 1e4, 1e12);
        uint256 feeBps = bound(feeSeed, 1, 50);
        uint256 budget = bound(budgetSeed, 1, PRINCIPAL);
        bytes32 mid = price == PRICE && feeBps == FEE_BPS ? id : ace.createMarket(_params(price, feeBps)); // the params are the id preimage
        (uint256 loanId,) = _settledPot(mid, price, PRINCIPAL);

        (uint256 unitsOut, uint256 paid,) = _buy(loanId, budget);

        uint256 g = (unitsOut * price + UNIT_SCALE - 1) / UNIT_SCALE; // recomputed from what left, never read off the hub
        assertEq(paid, g + (g * feeBps + 9999) / 10000, "the charge is the ask value of what left plus its fee, rounded up");
        assertLe(paid, budget, "and never exceeds the caller's budget");
    }

    /// @notice Zeroing eps off-channel did not bring back the old fill-fee coupling: a band-off market keeps its whole fee.
    /// @notice At the absolute fill-fee ceiling, with eps and target both zero, genesis admits it and the ask charges the fee.
    /// @dev No rail couples the fill fee to eps: band on or off, `fillFeeBps` answers only its own absolute bound.
    function test_Genesis_ABandOffMarketAtTheFillFeeCeilingCreatesAndItsAskChargesTheFee() public {
        MarketParams memory p = _params(PRICE, Constants.MAX_FILL_FEE_BPS);
        assertEq(p.deleverageBandBps, 0, "fixture: the decline channel is off");
        assertEq(p.deleverageFloorEpsBps, 0, "fixture: no eps");
        assertEq(p.deleverageTargetBps, 0, "fixture: no target");
        bytes32 mid = ace.createMarket(p);
        assertEq(ace.idToMarketParams(mid).fillFeeBps, Constants.MAX_FILL_FEE_BPS, "genesis stored the ceiling fee");
        assertEq(ace.idToMarketParams(mid).deleverageFloorEpsBps, 0, "beside a zero eps");

        (uint256 loanId,) = _settledPot(mid, PRICE, PRINCIPAL);
        (uint256 unitsOut, uint256 paid,) = _buy(loanId, BUDGET);
        uint256 gross = (unitsOut * PRICE + UNIT_SCALE - 1) / UNIT_SCALE; // the ask value of what left, ceiled as the hub prices it
        assertGt(unitsOut, 0, "premise: the leg filled");
        assertGt((gross * Constants.MAX_FILL_FEE_BPS) % 10000, 0, "premise: the fee leaves a remainder, so a ceiling and a floor differ");
        assertEq(paid, gross + (gross * Constants.MAX_FILL_FEE_BPS + 9999) / 10000, "the ask charges the full fill fee on top of the value");
        assertGt(paid, gross, "and the fee is not zero");
    }
}
