// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {RebateMath, RebateReader} from "../utils/RebateHarness.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";

/// @title AceEarlyExitRebate
/// @notice The early-exit fee rebate: what `open` withholds and what a clean close returns.
/// @notice Written failing-first when nothing here passed; the rebate shipped and this suite is green.
/// @dev The escrow is measured as MONEY, not storage, so the assertion never names a slot layout.
/// @dev `balanceOf(hub) - totalCash - protocolRevenue` IS the pot by the solvency identity.
/// @dev `RebateReader` cross-checks the same number against the `LoanBook` slot in hub storage.
/// @dev THE LAUNCH LADDER IS THE FIXTURE: 7d/30d rungs, 40 bps to the LENDER at the short rung.
/// @dev The borrower's all-in is 44 bps there: the protocol's 10% is charged ON TOP, never carved out.
/// @dev PRINCIPAL divides EXACTLY, so the assertions are literal integers, never a re-derivation.
contract AceEarlyExitRebateTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    RebateReader internal esc;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0BB);
    address internal borrowerA = address(0xB0B0A); // 30d, held to maturity
    address internal borrowerB = address(0xB0B0B); // 30d, exited early
    address internal borrowerC = address(0xB0B0C); // 7d, held to maturity
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;

    uint256 internal constant P = 70_000e6; // every number below is exact at this size
    uint256 internal constant COLL = 100_000e18; // trigger 0.98e18, just under the tick-0 floor
    uint256 internal constant FLOAT = 1_000_000e6; // working capital, so cost is a balance delta

    uint256 internal constant FEE30 = 1_320e6; // 70_000 * 44 bps all-in * 30/7
    uint256 internal constant PROTO30 = 120e6; // FEE30 / 11: the take does not move, only who bears it
    uint256 internal constant LENDER30 = 1_200e6; // 70_000 * 40 bps * 30/7, the lender's whole rate
    uint256 internal constant ESCROW30 = 600e6; // phi = 0.5 of the lender share
    uint256 internal constant REFUND30_AT15 = 300e6; // half the escrow at the midpoint

    uint256 internal constant FEE7 = 308e6; // 70_000 * 44 bps all-in
    uint256 internal constant ESCROW7 = 140e6; // phi = 0.5 of the 280 lender share

    uint256 internal T; // par itself; every draw in this file floors here, and setUp assigns it
    uint256 internal DEEP; // a price the draws in this file never reach; kept as the second market cash lot

    uint256 internal constant TOP = 300_000e6;
    uint256 internal constant DEEP_CASH = 100_000e6;

    uint256 internal t0;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T, DEEP) = (_price(0), _price(-6000));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        esc = new RebateReader(address(ace));

        _deposit(alice, TOP);
        _deposit(alice, DEEP_CASH);
        usdc.mint(borrowerA, FLOAT);
        usdc.mint(borrowerB, FLOAT);
        usdc.mint(borrowerC, FLOAT);
    }

    // ---- fixture ----

    /// @dev The LAUNCH tenor ladder on the shared fixture; everything else is the fixture default.
    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _deposit(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(address who, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(who, COLL);
        vm.startPrank(who);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, P, tenor, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Repays the whole debt and returns what came BACK, which is the refund.
    /// @dev The close CREDITS the unearned escrow rather than pushing it, so the pull is the exit's second half.
    function _repayFull(address who, uint256 loanId) internal returns (uint256 refund) {
        uint256 debt = read.debtOf(loanId);
        uint256 before = usdc.balanceOf(who);
        vm.startPrank(who);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        ace.claimOwed(loanId, who);
        vm.stopPrank();
        refund = usdc.balanceOf(who) + debt - before;
    }

    /// @dev All-in cost, measured as the borrower's own working-capital drawdown from FLOAT.
    /// @dev Independent of every fee formula: it is simply what is missing at the end.
    function _cost(address who) internal view returns (uint256) {
        return FLOAT - usdc.balanceOf(who);
    }

    /// @dev What the LENDER is owed in quote, pooled over every loan and tick in this market.
    /// @dev WAS a per-class figure, `qIndex * classSupply`. Pooling deletes both terms: there is one credit
    /// @dev bucket per (lender, quote), so a per-loan or per-tick share of it is not representable at all.
    /// @dev SOUND AT EVERY CALL SITE BELOW because each opens exactly ONE loan, or measures a DELTA across
    /// @dev one event -- so the pooled figure answers the question the per-class one did. Read it as the
    /// @dev lender's total regardless: a second live loan would fold into it silently.
    /// @dev IT COUNTS THE LENDER'S WALLET TOO, and that is the whole of the change the push forced. A terminal
    /// @dev close now PUSHES the pool to the lender, so `poolOwed` reads zero exactly where these rows used to
    /// @dev read the figure they were measuring -- and three of them underflowed on it rather than merely
    /// @dev disagreeing. The money is the same money; only its location moved, so the sum is what the rows
    /// @dev always meant. Read it as the lender's quote position OUTSIDE resting cash.
    /// @dev SOUND BECAUSE ALICE'S WALLET MOVES FOR NO OTHER REASON inside these rows: she deposits only in
    /// @dev `setUp` and in the one top-up row, which measures resting cash rather than this.
    function _lenderOwed() internal view returns (uint256) {
        return read.poolOwed(id) + usdc.balanceOf(alice);
    }

    function _escrowPot() internal view returns (uint256) {
        MarketState memory s = read.marketState(id);
        (uint256 resting,, uint256 owed) = read.poolOf(id); // the LENDER legs; one market here, so it spans nothing else
        return usdc.balanceOf(address(ace)) - resting - s.protocolRevenue - owed - s.quoteOwedTotal;
    }

    /// @dev Plan test 29: hub balance == cash + revenue + unit-owed + the escrow LEDGER, on every op.
    /// @dev The ledger side is read from storage, so this is storage against money.
    function _assertSolvency() internal view {
        MarketState memory s = read.marketState(id);
        (uint256 resting,, uint256 owed) = read.poolOf(id); // the LENDER legs; one market here, so it spans nothing else
        uint256 pot;
        for (uint256 i = 1; i <= read.loanCount(); i++) {
            pot += esc.feeEscrowOf(i);
        }
        assertEq(
            usdc.balanceOf(address(ace)),
            resting + s.protocolRevenue + pot + owed + s.quoteOwedTotal,
            "solvency: escrow pot, unit-owed and claimant-owed booked exactly"
        );
    }

    // ============ what open withholds ============

    /// @notice `open` withholds phi of the LENDER share, off the tick credit, never off the protocol cut.
    /// @dev FAILS TODAY: the funding tick takes the whole 1,140 lender share and the pot reads 0.
    function test_Open_WithholdsHalfTheLenderShare_OffTheTickCreditOnly() public {
        uint256 cash0 = read.restingOf(id);
        uint256 loanId = _open(borrowerA, TEN30);

        assertEq(esc.feeEscrowOf(loanId), ESCROW30, "the loan's escrow ledger");
        assertEq(_escrowPot(), ESCROW30, "and the hub really holds it, unbooked");
        assertEq(read.protocolRevenue(id), PROTO30, "the protocol cut is untouched by the rebate");
        assertEq(read.restingOf(id), cash0 - P, "the tick lost exactly the draw; the fee is not cash");
        assertApproxEqAbs(_lenderOwed(), LENDER30 - ESCROW30, 1, "the class took the lender share NET");
        assertEq(read.claimOf(id, loanId), P, "and the draw itself is unchanged");
        assertEq(usdc.balanceOf(borrowerA), FLOAT + P - FEE30, "the borrower still pays the whole fee up front");
        _assertSolvency();
    }

    /// @notice Plan test 6: the escrow is a strict subset of the lender share at the split a market ships.
    /// @notice ONE split is reachable now -- the share is a hub constant, so no market can express another.
    /// @dev A real market, not arithmetic over a helper; the all-splits property is the fuzz below.
    function test_Escrow_NeverExceedsTheLenderShare() public {
        uint256 shareBps = Constants.PROTOCOL_SHARE_BPS;
        MarketParams memory p = _params();
        // distinct id: settleBountyBps 51 keeps this market from colliding with setUp's
        p.settleBountyBps = 51;
        bytes32 mid = ace.createMarket(p);
        _depositTo(mid, TOP + DEEP_CASH); // WAS two ticks; the market bids at one price, so the cash is one balance

        vault.mint(borrowerA, COLL);
        vm.startPrank(borrowerA);
        vault.approve(address(positionManager), COLL);
        uint256 loanId = ace.open(mid, COLL, P, TEN30, borrowerA, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 lenderShare = FEE30 - RebateMath.protocolCut(FEE30, shareBps);
        assertEq(esc.feeEscrowOf(loanId), RebateMath.escrow(FEE30, shareBps), "escrow is phi of the lender share");
        assertLe(esc.feeEscrowOf(loanId), lenderShare, "and never exceeds it, at any split");
    }

    /// @notice The all-splits half of the row above, which a market can no longer reach.
    /// @notice Hardcoding the share removed the input, not the property: the FORMULA still holds everywhere.
    /// @dev Pure arithmetic over `RebateMath`, which takes the share as an argument rather than reading a market.
    /// @dev Deleting this instead would have quietly narrowed coverage from a range to a point.
    function testFuzz_Escrow_NeverExceedsTheLenderShare_Algebraic(uint256 shareSeed, uint256 feeSeed) public pure {
        uint256 shareBps = bound(shareSeed, 0, 10000);
        uint256 fee = bound(feeSeed, 0, type(uint128).max);

        assertLe(RebateMath.escrow(fee, shareBps), fee - RebateMath.protocolCut(fee, shareBps), "escrow exceeds the lender share");
    }

    // ============ what a clean close returns ============

    /// @notice Plan test 1: a 30d loan repaid at its midpoint returns a quarter of the lender share.
    /// @dev FAILS TODAY: the refund is 0, so the cost is the whole 1,200.
    function test_Repay_At15Days_RefundsAQuarterOfTheLenderShare() public {
        uint256 loanId = _open(borrowerA, TEN30);
        _warpTo(t0 + 15 days);
        uint256 refund = _repayFull(borrowerA, loanId);

        assertEq(refund, REFUND30_AT15, "half the escrow, which is a quarter of the lender share");
        assertEq(refund, LENDER30 / 4, "stated the other way, as the plan does");
        assertEq(_cost(borrowerA), FEE30 - REFUND30_AT15, "all-in cost is the fee net of the refund");
        assertEq(esc.feeEscrowOf(loanId), 0, "the escrow ledger is emptied by the close");
        assertEq(_escrowPot(), 0, "and no quote is stranded");
        _assertSolvency();
    }

    /// @notice The headline identity, as integers, to the wei.
    /// @dev cost/P = (baseBps / minTenor) * [ (T + t)/2 + s * T ], s = Constants.PROTOCOL_SHARE_BPS/10000.
    /// @dev The borrower pays the midpoint of term booked and used, PLUS the share on the WHOLE term.
    /// @dev Denominators cleared: 2*cost*1e8*minTenor == P*baseBps*(1e4*(T+t) + 2*shareBps*T).
    /// @dev Restating it in a form the source never takes is the point: this is not a mirror.
    function test_Identity_MidpointPricing_HoldsToTheWei() public {
        uint256 loanId = _open(borrowerA, TEN30);
        _warpTo(t0 + 15 days);
        _repayFull(borrowerA, loanId);

        uint256 elapsed = 15 days;
        uint256 lhs = 2 * _cost(borrowerA) * 10000 * 10000 * uint256(TEN7);
        uint256 rhs = P * PocDeployConfig.BASE_BPS * (10000 * (uint256(TEN30) + elapsed) + 2 * Constants.PROTOCOL_SHARE_BPS * uint256(TEN30));
        assertEq(lhs, rhs, "the midpoint identity does not hold");
    }

    /// @notice Plan test 2: a 7d loan at 40 bps to the lender, exited at 3.5d, costs 34 bps and refunds 10.
    /// @dev 10 bps is HALF the 20 bps escrow pool, which is what phi = 0.5 means here.
    function test_Repay_ShortRungAtHalfTerm_Refunds10Bps() public {
        uint256 loanId = _open(borrowerC, TEN7);
        _warpTo(t0 + 3.5 days);
        uint256 refund = _repayFull(borrowerC, loanId);

        assertEq(refund, 70_000_000, "10 bps of 70,000 USDC");
        assertEq(refund * 10000, P * 10, "stated as bps: refund/P == 10/10000");
        assertEq(refund, ESCROW7 / 2, "which is half the 7d escrow");
        assertEq(_cost(borrowerC), FEE7 - 70_000_000, "cost is 34 bps");
    }

    /// @notice Plan tests 3 and 31: closing in the opening block returns the escrow, still at a loss.
    /// @dev The strict-loss leg is what stops the rebate becoming a free option on the ladder.
    function test_Repay_SameBlock_RefundsTheWholeEscrow_AndIsStillAStrictLoss() public {
        uint256 loanId = _open(borrowerA, TEN30);
        uint256 refund = _repayFull(borrowerA, loanId);

        assertEq(refund, ESCROW30, "the whole fee escrow comes back");
        assertEq(refund, LENDER30 / 2, "which is half the lender share");
        assertEq(_cost(borrowerA), PROTO30 + (LENDER30 - ESCROW30), "the protocol cut and half the lender share stay");
        assertGt(_cost(borrowerA), 0, "an instant round trip is never free");
    }

    /// @notice Plan test 4: at expiry the refund is exactly zero and the cost is the whole fee.
    function test_Repay_AtExpiry_RefundsNothing() public {
        uint256 loanId = _open(borrowerA, TEN30);
        _warpTo(t0 + uint256(TEN30));
        uint256 refund = _repayFull(borrowerA, loanId);

        assertEq(refund, 0, "no calendar time is left to rebate");
        assertEq(_cost(borrowerA), FEE30, "hold-to-maturity pays the posted fee, unchanged");
    }

    /// @notice Past expiry the remaining term clamps at zero rather than underflowing.
    function test_Repay_PastExpiry_RefundsNothing_NoUnderflow() public {
        uint256 loanId = _open(borrowerA, TEN30);
        _warpTo(t0 + uint256(TEN30) + 3 days);
        uint256 refund = _repayFull(borrowerA, loanId);

        assertEq(refund, 0, "an overdue close rebates nothing, and does not revert");
        assertEq(_cost(borrowerA), FEE30, "and costs the posted fee");
    }

    /// @notice Plan test 5: the refund rounds DOWN and never exceeds what was withheld.
    /// @dev Rounding UP would pay out more than the escrow holds and break solvency by dust per close.
    function testFuzz_Refund_RoundsDown_AndNeverExceedsTheEscrow(uint256 elapsedSeed) public {
        uint256 elapsed = bound(elapsedSeed, 0, uint256(TEN30));
        uint256 loanId = _open(borrowerA, TEN30);
        _warpTo(t0 + elapsed);
        uint256 refund = _repayFull(borrowerA, loanId);

        assertEq(refund, RebateMath.refund(ESCROW30, uint256(TEN30) - elapsed, TEN30), "floor(escrow*remaining/tenor)");
        assertLe(refund, ESCROW30, "and can never exceed what was withheld");
        assertEq(_escrowPot(), 0, "the close leaves nothing behind at any exit time");
        _assertSolvency();
    }

    // ============ the ladder ordering: the whole justification for phi = 0.5 ============

    /// @notice THE PIN. A 30d rung held to maturity undercuts five 7d rungs.
    /// @notice And a 30d rung exited at 28d still costs MORE than four 7d rungs.
    /// @dev Every figure is a measured borrower drawdown, not a formula, and every one is exact.
    /// @dev AT PHI = 1 the 28d exit prices at 1,240 instead of 1,280: above 1,232 by 8 USDC, not 48.
    /// @dev The equalities are what kill a phi = 1 mutant; the inequalities are the doctrine.
    /// @dev Three loans open in one block and close on their own clocks, so no snapshot is needed.
    function test_Ladder_LongRungUndercutsFiveShort_ButAnEarlyExitDoesNotUndercutFour() public {
        uint256 idA = _open(borrowerA, TEN30);
        uint256 idB = _open(borrowerB, TEN30);
        uint256 idC = _open(borrowerC, TEN7);

        _warpTo(t0 + 7 days);
        _repayFull(borrowerC, idC);
        _warpTo(t0 + 28 days);
        _repayFull(borrowerB, idB);
        _warpTo(t0 + 30 days);
        _repayFull(borrowerA, idA);

        uint256 short7 = _cost(borrowerC);
        uint256 long30 = _cost(borrowerA);
        uint256 exit28 = _cost(borrowerB);

        assertEq(short7, 308e6, "7d held to maturity: 44 bps all-in");
        assertEq(long30, 1_320e6, "30d held to maturity: 188.57 bps");
        assertEq(exit28, 1_280e6, "30d exited at 28d: 182.86 bps");

        assertLt(long30, 5 * short7, "term must beat rolling five short rungs: 1320 < 1540");
        assertGt(exit28, 4 * short7, "and an early exit must not beat four of them: 1280 > 1232");
        _assertSolvency();
    }

    // ============ the escrow is invisible to share pricing ============

    /// @notice The withheld escrow never enters the class index; only the EARNED remainder reaches it.
    function test_Escrow_NeverEntersTheClassIndex_UntilTheCloseEarnsIt() public {
        uint256 loanId = _open(borrowerA, TEN30);

        uint256 held = _lenderOwed();
        assertApproxEqAbs(held, LENDER30 - ESCROW30, 1, "at open the class is owed the share NET of escrow");

        _warpTo(t0 + 15 days);
        assertEq(_lenderOwed(), held, "time alone earns nothing into the class");

        _repayFull(borrowerA, loanId);
        assertApproxEqAbs(_lenderOwed(), LENDER30 - REFUND30_AT15 + P, 3, "the close credits exactly the UNREFUNDED remainder, on top of par");
    }

    /// @notice Cash that arrives after the draw and leaves before the close touches no escrow.
    /// @dev The round trip is EXACT: fresh cash joins no live loan, so nothing can leak into or out of it.
    /// @dev ONE LENDER NOW, so this is alice topping up and taking it back rather than a second party
    /// @dev arriving. The property is unchanged -- it was always about the CASH's vintage, not its owner.
    function test_Escrow_MidLifeTopUpRoundTrip_LeavesThePotExactlyIntact() public {
        _open(borrowerA, TEN30);
        assertEq(_escrowPot(), ESCROW30, "fixture: the pot is funded");

        uint256 restBefore = read.poolResting(id);
        _deposit(alice, 10_000e6);
        assertEq(_escrowPot(), ESCROW30, "a deposit into the funded tick sees no escrow");

        vm.prank(alice);
        uint256 out = ace.withdraw(id, 10_000e6, alice, 0);

        assertEq(_escrowPot(), ESCROW30, "and neither does the exit");
        assertEq(out, 10_000e6, "a same-block round trip is exact: no windfall and no haircut");
        assertEq(read.poolResting(id), restBefore, "and the pool is bit-unchanged either side of it");
        _assertSolvency();
    }

    /// @notice Plan test 34, rewritten with the lock's deletion: the close-time credit lands in the
    /// @notice class index immediately -- there is no share price left to defend, so nothing vests.
    function test_Close_EarnedRemainder_CreditsTheClassImmediately() public {
        uint256 loanId = _open(borrowerA, TEN30);
        _warpTo(t0 + 15 days);
        uint256 owedBefore = _lenderOwed();

        _repayFull(borrowerA, loanId);

        uint256 earned = ESCROW30 - REFUND30_AT15;
        assertApproxEqAbs(_lenderOwed() - owedBefore, earned + P, 3, "the earned remainder and par enter the index");
    }

    // ============ which exits qualify ============

    /// @notice Plan test 10: a pre-expiry `finalize` pays the borrower nothing.
    /// @dev The lender bears the outcome there and may eat a write-down, so the whole fee escrow is earned.
    function test_Finalize_PreExpiry_PaysTheBorrowerNothing_AndEarnsTheEscrowFully() public {
        uint256 loanId = _open(borrowerA, TEN30);
        uint256 quoteBefore = usdc.balanceOf(borrowerA);
        record.setBelowBand(read.triggerPrice(loanId));
        assertTrue(read.settleable(loanId), "fixture: the loan is settleable");

        _warpTo(t0 + 1 days);
        vm.prank(keeper);
        ace.finalize(loanId);

        assertEq(usdc.balanceOf(borrowerA), quoteBefore, "a settled borrower is rebated nothing, ever");
        assertEq(esc.feeEscrowOf(loanId), 0, "the ledger is cleared");
        assertEq(_escrowPot(), 0, "and the whole fee escrow was earned, not stranded");
        _assertSolvency();
    }

    /// @notice Plan test 11: `forceClose` rebates nothing, and needs no rule to say so.
    /// @dev `remaining` is 0 at expiry by construction, so the formula returns 0 with no special case.
    function test_ForceClose_AtExpiry_RebatesNothing_ByArithmeticAlone() public {
        uint256 loanId = _open(borrowerA, TEN30);
        uint256 quoteBefore = usdc.balanceOf(borrowerA);

        _warpTo(t0 + uint256(TEN30) + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertEq(usdc.balanceOf(borrowerA), quoteBefore, "no quote reaches the borrower on a force close");
        assertEq(esc.feeEscrowOf(loanId), 0, "the ledger is cleared");
        assertEq(_escrowPot(), 0, "and nothing is stranded");
        _assertSolvency();
    }

    // ============ conservation ============

    /// @notice Every wei of the fee has exactly one home, over a full life.
    /// @dev The classes' owed quote includes PAR after a full repay, so the fee leg is owed minus P.
    function test_FeeConservation_OverAFullLifecycle_IsExact() public {
        uint256 revBefore = read.protocolRevenue(id);

        uint256 loanId = _open(borrowerA, TEN30);
        _warpTo(t0 + 11 days);
        uint256 refund = _repayFull(borrowerA, loanId);

        uint256 credited = _lenderOwed() - P;
        uint256 toProtocol = read.protocolRevenue(id) - revBefore;

        assertApproxEqAbs(credited + toProtocol + refund, FEE30, 4, "fee conservation: credit + revenue + refund == fee");
        assertGt(refund, 0, "non-vacuity: the refund leg actually ran");
        _assertSolvency();
    }

    /// @notice Plan test 32: a self-funded loop nets exactly the protocol cut, whenever it exits.
    /// @dev The rebate moves WHEN the lender share is paid, never WHO ends up with it.
    function test_SelfFundedLoop_NetsTheProtocolCut_InvariantInExitTiming() public {
        uint256 early = _selfFundedLoss(0);
        uint256 late = _selfFundedLoss(uint256(TEN30));
        assertEq(early, late, "exit timing must not change a self-funded loop's net");
        assertApproxEqAbs(early, PROTO30, 2, "and the net is the protocol cut, to share-rounding dust");
    }

    /// @dev One self-funded loop on its own market: one party lends the whole tick and borrows it back.
    function _selfFundedLoss(uint256 holdFor) private returns (uint256) {
        MarketParams memory p = _params();
        // inert here; only makes the two markets distinct ids, and both differ from the fixture default
        p.fillFeeBps = holdFor == 0 ? 2 : 3;
        address solo = address(uint160(uint256(keccak256(abi.encode("solo", holdFor)))));
        p.lender = solo; // the loop lends and borrows as ONE party, and only the named lender may rest
        bytes32 mid = ace.createMarket(p);

        usdc.mint(solo, FLOAT);
        vault.mint(solo, COLL);
        vm.startPrank(solo);
        usdc.approve(address(ace), type(uint256).max);
        vault.approve(address(positionManager), COLL);
        ace.deposit(mid, TOP);
        uint256 loanId = ace.open(mid, COLL, P, TEN30, solo, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 start = _now();
        _warpTo(start + holdFor);
        vm.startPrank(solo);
        ace.repay(loanId, read.debtOf(loanId));
        ace.claimOwed(loanId, solo); // the close credits the unearned escrow; the loop's net needs it pulled
        ace.collect(address(usdc), solo); // par plus the fee she earned, straight out of the pool: no vesting
        ace.withdraw(mid, type(uint256).max, solo, 0);
        vm.stopPrank();
        _warpTo(start);

        return FLOAT - usdc.balanceOf(solo);
    }

    // ============ preview parity ============

    function _depositTo(bytes32 mid, uint256 amt) private {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _previewAdmits(bytes32 mid, uint256 principal) private view returns (bool) {
        try ace.previewOpen(mid, COLL, principal, TEN7, address(this), OpenBounds(0, 0, 0)) returns (Borrower.Quote memory) {
            return true;
        } catch {
            return false;
        }
    }
}
