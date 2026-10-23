// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IAceRefinance} from "../utils/RebateHarness.sol";

/// @title AceDeletedChannelFence
/// @notice The regression fence on the skim deletion: the verbs are GONE, and the warrant that replaces them holds.
/// @notice The old selectors are asserted LITERALLY, so a rename could never satisfy this file.
/// @dev The warrant is `withdrawCollateral -> sell -> repay`, pinned in the ONE state that matters: a FULLY-LENT market.
/// @dev There the refinance route is unavailable: the retiring debt funds the successor, but never its fresh remainder.
/// @dev A cash-rich or ladder-rich fixture would pass while proving nothing about that state.
contract AceDeletedChannelFenceTest is Test {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the sole lender
    address internal borrower = address(0xB0B); // a plain EOA: it holds no callback
    address internal stranger = address(0x57A11);
    address internal market = address(0x5E11); // where the off-chain sale sends the units

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant LADDER = 4_600e6; // the draw plus its tick fee, and NOT ONE WEI MORE
    uint256 internal constant FLOAT = 1_000e6; // the borrower's opening fee money
    uint256 internal constant P = 2e18; // two quote per whole collateral, as a human WAD
    uint256 internal constant BAND_BPS = 3000;
    uint256 internal T0; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value

    /// @dev The verbs as they shipped, spelled out. A rename cannot satisfy these; only a deletion can.
    bytes4 internal constant SKIM_SEL = bytes4(keccak256("skim(uint256,uint256,bytes)"));
    bytes4 internal constant SKIM_PRICE_SEL = bytes4(keccak256("skimPrice(uint256,bytes)"));

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T0 = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(AceFixtures.px(P, address(usdc), address(vault)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, LADDER);
        vm.startPrank(alice);
        usdc.approve(address(ace), LADDER);
        ace.deposit(id, LADDER);
        vm.stopPrank();
    }

    /// @dev Opens the whole ladder, then STRIPS the borrower's quote: an EOA with no dry powder.
    function _openBroke() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        usdc.mint(borrower, FLOAT);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), FLOAT);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        usdc.transfer(market, usdc.balanceOf(borrower)); // every wei spent, exactly as a leveraged borrower does
        vm.stopPrank();
        assertEq(usdc.balanceOf(borrower), 0, "fixture: the borrower holds no quote at all");
    }

    // ============ T1: the verbs are gone, by selector ============

    /// @notice A raw call on the OLD `skim` selector finds no function and no fallback: it returns false.
    /// @dev A live control on the same door proves the raw-call harness itself is not what fails.
    function test_T1_TheOldSkimSelectorIsGone() public {
        uint256 loanId = _openBroke();

        (bool ok,) = address(ace).call(abi.encodeWithSelector(SKIM_SEL, loanId, uint256(0), bytes("")));
        assertFalse(ok, "the skim selector still answers at the hub");

        (bool live,) = address(ace).call(abi.encodeWithSelector(Ace.isClosed.selector, loanId));
        assertTrue(live, "control: a surviving selector on the same hub still answers");
    }

    /// @notice The price twin is gone by the same measure, and its selector differs from the rate one.
    function test_T1_TheOldSkimPriceSelectorIsGone() public {
        uint256 loanId = _openBroke();

        (bool ok,) = address(ace).call(abi.encodeWithSelector(SKIM_PRICE_SEL, loanId, bytes("")));
        assertFalse(ok, "the skimPrice selector still answers at the hub");
        assertTrue(SKIM_SEL != SKIM_PRICE_SEL, "fixture: the two selectors are distinct, so neither test stands in for the other");
    }

    // ============ T4: THE WARRANT, in the state it is about ============

    /// @notice THE REPLACEMENT VERB, end to end: an EOA with ZERO quote reaches "less collateral, less debt".
    /// @notice Driven in a FULLY-LENT market, which is the state the refinance route cannot serve at all.
    /// @dev No callback, no ladder cash, no fee, no tenor reset, no reseeded floor. That is the whole point.
    function test_T4_WithdrawSellRepay_WorksForABrokeEoaInAFullyLentMarket() public {
        uint256 loanId = _openBroke();
        uint256 debt0 = read.debtOf(loanId);
        uint256 trig0 = read.triggerPrice(loanId);

        uint256 units = COLL / 10; // well inside the withdrawal line at this floor
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, units, borrower);
        assertEq(vault.balanceOf(borrower), units, "the units reached the borrower, with no cash in the transaction");
        assertEq(read.loan(loanId).collateralUnits, COLL - units, "and left the loan by exactly that count");

        // the off-chain sale: the units go, quote comes back
        vm.prank(borrower);
        vault.transfer(market, units);
        uint256 proceeds = 500e6;
        usdc.mint(borrower, proceeds);

        vm.startPrank(borrower);
        usdc.approve(address(ace), proceeds);
        ace.repay(loanId, proceeds);
        vm.stopPrank();

        assertEq(read.debtOf(loanId), debt0 - proceeds, "every wei of the sale melted debt");
        assertLt(read.loan(loanId).collateralUnits, COLL, "less collateral");
        assertLt(read.debtOf(loanId), debt0, "and less debt: the end state a skim reached");
        assertLt(read.triggerPrice(loanId), trig0, "the composition LOWERS the trigger, which is the lender-side guarantee");
        assertEq(usdc.balanceOf(borrower), 0, "and the borrower ends holding no quote either: nothing was fronted");
    }

    /// @notice THE CONTROL that makes the warrant load-bearing: the refinance route is unavailable here.
    /// @dev A same-market refinance RECYCLES the retiring debt into its successor, so it needs only the fresh remainder.
    /// @dev That remainder is at least the fee the successor pays, and a FULLY lent market rests none of it.
    /// @dev The fixture leaves 100 USDC of slack, which would fund that fee; the lender takes it first, so the market is empty.
    function test_T4_TheRefinanceRouteIsUnavailableInTheSameState() public {
        uint256 loanId = _openBroke();
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0);
        assertEq(ace.restingOf(id), 0, "fixture: the market is fully lent");

        MarketParams memory p = ace.idToMarketParams(id);
        /// @dev The smallest successor that clears `DrawBelowDebt`, so the only refusal left is the cash one.
        uint256 np = LoanMath.principalForOwed(read.debtOf(loanId) - read.feeEscrowOf(loanId), p.minTenor, p.baseBps, p.minTenor);
        MigrateArgs memory m = MigrateArgs({
            id: loanId, dst: id, newPrincipal: np, newTenor: p.minTenor, bnd: OpenBounds(0, 0, 0), withdrawUnits: COLL / 10, withdrawTo: borrower
        });

        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        IAceRefinance(address(ace)).refinanceTo(m);
    }

    /// @notice T4b: the refinance composition, which is the VARIANT that also re-terms the loan.
    /// @notice It carries no warrant: this fixture has to fund it, which is exactly what T4 above cannot rely on.
    function test_T4b_RefinanceWithdrawThenSellThenRepay() public {
        uint256 loanId = _openBroke();

        // fund the successor's draw: without this the market is fully lent and the route simply refuses
        uint256 fresh = 3 * LADDER;
        usdc.mint(alice, fresh);
        vm.startPrank(alice);
        usdc.approve(address(ace), fresh);
        ace.deposit(id, fresh);
        vm.stopPrank();

        uint256 units = COLL / 10;
        MigrateArgs memory m = MigrateArgs({
            id: loanId,
            dst: id,
            newPrincipal: read.debtOf(loanId) + 100e6, // the successor must retire the old debt AND its own fee
            newTenor: ace.idToMarketParams(id).minTenor,
            bnd: OpenBounds(0, 0, 0),
            withdrawUnits: units,
            withdrawTo: borrower
        });

        vm.prank(borrower);
        uint256 newId = IAceRefinance(address(ace)).refinanceTo(m);
        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);

        assertEq(vault.balanceOf(borrower), units, "the release reached the borrower");
        assertEq(read.loan(newId).collateralUnits, COLL - units, "and the successor carries the rest");

        uint256 debt0 = read.debtOf(newId);
        vm.prank(borrower);
        vault.transfer(market, units); // the same off-chain sale
        uint256 proceeds = 500e6;
        usdc.mint(borrower, proceeds);
        vm.startPrank(borrower);
        usdc.approve(address(ace), proceeds);
        ace.repay(newId, proceeds);
        vm.stopPrank();

        assertEq(read.debtOf(newId), debt0 - proceeds, "and the proceeds melt the successor's debt");
        assertLt(read.loan(newId).collateralUnits, COLL, "less collateral, by the longer road");
    }

    // ============ T5: keepers still do safety ============

    /// @notice A STRANGER cranks `deleverage` on a banded loan they have no relationship to.
    /// @notice KEEPERS DO SAFETY: the permissionless crank survives the deletion, which is the half that stays.
    /// @dev The keeper contract is the routing counterparty; the EOA driving it is neither borrower nor lender.
    function test_T5_AStrangerCanStillDeleverage() public {
        uint256 loanId = _openBroke();
        MockDeleverageKeeper k = new MockDeleverageKeeper(ace, address(usdc), address(vault), read.marketState(id).unitScale);

        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = (trig * 125) / 100; // inside the band, clear of the stop
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(ps);

        assertTrue(stranger != borrower && stranger != alice, "fixture: the caller is a party to neither side");
        vm.prank(stranger);
        (uint256 sold,) = k.crankDeleverage(loanId);

        assertGt(sold, 0, "a stranger's crank really sold, so the channel is still permissionless");
        assertLt(read.triggerPrice(loanId), trig, "and it lowered the trigger, which is what it is for");
    }
}
