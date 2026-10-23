// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {BelowMinDebt, LoanClosed, NotBorrower, TenorOutOfRange, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IAceRefinance, RebateReader} from "../utils/RebateHarness.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {DrawBelowDebt} from "../../src/ace/hub/Borrower.sol";

/// @title AceRefinance
/// @notice `refinance`: close and reopen atomically, borrower-only, no health gate on the old loan.
/// @notice Written failing-first; the verb SHIPPED and this suite is green against it.
/// @dev The verb is reached through `IAceRefinance`, declared in `test/utils/RebateHarness.sol`.
/// @dev The happy path is also the M1 probe: every `Ace.open` is `external nonReentrant`.
/// @dev They share ONE transient slot, so the shipped body calls `_refinance`, never the hub entry.
contract AceRefinanceTest is WarpClock {
    Ace internal ace;
    IAceRefinance internal fin;
    AceReader internal read;
    RebateReader internal esc;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal mallory = address(0xBAD);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant FLOAT = 1_000_000e6;

    uint256 internal constant FEE30 = 1_320e6; // the borrower's ALL-IN: 40 bps to the lender, 10% on top
    uint256 internal constant REFUND30_AT15 = 300e6; // half the escrow, which is phi of the 1,200 lender share
    uint256 internal constant TOPUP_AT15 = 1_020e6; // the repay gap the composition covers: FEE30 - REFUND30_AT15 at P_new == D_old

    uint256 internal T; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal DEEP;
    uint256 internal constant TOP = 400_000e6;
    uint256 internal constant DEEP_CASH = 200_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);
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
        fin = IAceRefinance(address(ace));
        esc = new RebateReader(address(ace));

        _deposit(alice, TOP);
        _deposit(alice, DEEP_CASH);
        usdc.mint(borrower, FLOAT);
    }

    // ---- fixture ----

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

    function _open(uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, COLL, principal, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _refi(uint256 oldId, uint256 principal, uint64 tenor) internal returns (uint256) {
        vm.prank(borrower);
        return fin.refinance(oldId, principal, tenor, OFF);
    }

    /// @notice Repay the shortfall and refinance in ONE transaction: what a top-up used to do inside the verb.
    /// @notice Rows using this exercise the COMPOSITION rather than a single verb -- a deliberate change of subject.
    /// @dev `multicall` delegatecalls, so `msg.sender` is the borrower on both legs and the borrower-only gate holds.
    function _refiViaMulticall(uint256 oldId, uint256 principal, uint64 tenor) internal returns (uint256) {
        uint256 gap = _gap(oldId, principal, tenor);
        if (gap == 0) return _refi(oldId, principal, tenor);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (oldId, gap));
        calls[1] = abi.encodeCall(Ace.refinance, (oldId, principal, tenor, OFF));
        vm.prank(borrower);
        bytes[] memory res = ace.multicall(calls);
        return abi.decode(res[1], (uint256));
    }

    /// @dev The old debt less what the fresh draw nets: exactly the shortfall the deleted branch pulled.
    function _gap(uint256 oldId, uint256 principal, uint64 tenor) internal view returns (uint256) {
        return _gapIn(read.loan(oldId).market, oldId, principal, tenor);
    }

    /// @dev The same shortfall on a named market, for rows that build their own.
    function _gapIn(bytes32 mid, uint256 oldId, uint256 principal, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 feeNew = LoanMath.originationFee(principal, tenor, p.baseBps, p.minTenor);
        uint256 credit = principal - feeNew + read.earlyExitRefund(oldId);
        uint256 debtOld = read.loan(oldId).debt;
        return credit >= debtOld ? 0 : debtOld - credit;
    }

    function _pot() internal view returns (uint256) {
        MarketState memory s = read.marketState(id);
        (uint256 resting,, uint256 owed) = read.poolOf(id); // the LENDER legs; one market here, so it spans nothing else
        return usdc.balanceOf(address(ace)) - resting - s.protocolRevenue - owed - s.quoteOwedTotal;
    }

    // ============ 17. the happy path, and the M1 wiring probe ============

    /// @notice A borrower closes one loan and opens a fresh one in a single call.
    /// @dev The new loan is a NEW id with its own funding floor, claim ticks and escrow.
    function test_Refinance_HappyPath_ClosesTheOldAndOpensAFresh() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);

        uint256 newId = _refiViaMulticall(oldId, P, TEN30);

        assertGt(newId, oldId, "a refinance allocates a NEW loan id, never reuses one");
        assertTrue(read.loan(oldId).closedAt != 0, "the old loan is retired");
        assertEq(read.debtOf(oldId), 0, "and its debt is retired in FULL");
        assertFalse(read.loan(newId).closedAt != 0, "the new loan is live");
        assertEq(read.debtOf(newId), P, "at the requested principal");
        assertEq(read.loan(newId).expiry, _now() + TEN30, "with a fresh term from now");
        assertEq(read.loan(newId).borrower, borrower, "titled to the same borrower");
        assertGt(read.fundingFloor(id, newId), 0, "and a funding floor of its own");
        assertEq(read.fundingFloor(id, oldId), 0, "while the old floor retires with the old loan");
    }

    /// @notice The retired loan carries the REFINANCE instant, and its successor carries no stamp at all.
    /// @dev `_closeForRefinance` is its own close site, sharing no line with settlement or a clean close.
    /// @dev Without this row `L.closedAt = 1` there survives the whole `test/ace` tree.
    /// @dev The instant is 15 days off `t0`, so it collides with none of openTime, tenor or expiry beside it.
    function test_Refinance_StampsTheRetiredLoanWithTheRefinanceInstant() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        uint64 when = uint64(_now());

        uint256 newId = _refiViaMulticall(oldId, P, TEN30);

        assertEq(read.loan(oldId).closedAt, when, "the retired loan carries the refinance instant");
        assertEq(read.loan(newId).closedAt, 0, "while the successor is live and stamp-free");
        assertTrue(when != read.loan(oldId).openTime, "guard: the stamp is not the openTime beside it");
        assertTrue(when != read.loan(oldId).tenor, "guard: nor the tenor");
        assertTrue(when != read.loan(oldId).expiry, "guard: nor the expiry");
    }

    /// @notice The old loan's collateral ends credited to the NEW loan, with no orphan left behind.
    /// @dev Pooled, the carry is TWO LEDGER WRITES and no transfer, so the custodian's balance cannot move.
    /// @dev That bit-identical balance is a stronger claim than the old vault-to-vault round trip could make.
    function test_Refinance_CollateralCustody_MovesWholeAndLeavesNoOrphan() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 potBefore = vault.balanceOf(address(positionManager));
        uint256 custodiedBefore = positionManager.custodiedOf(address(vault));

        uint256 newId = _refiViaMulticall(oldId, P, TEN30);

        assertEq(positionManager.collateralOf(newId), COLL, "the positionManager ledger credits the new id");
        assertEq(positionManager.collateralOf(oldId), 0, "and the old id is emptied");
        assertEq(vault.balanceOf(address(positionManager)), potBefore, "a refinance moves ZERO tokens");
        assertEq(positionManager.custodiedOf(address(vault)), custodiedBefore, "and the pot-level aggregate is invariant");
        assertEq(vault.balanceOf(address(ace)), 0, "and nothing is stranded at the hub");
        assertEq(read.loan(newId).collateralUnits, COLL, "the loan record agrees");
    }

    // ============ 20 / 21 / 22 / 24b. the money ============

    /// @notice The rebate composes: the borrower nets `P_new - fee_new + refund_old - D_old`, once.
    /// @dev At `P_new == D_old` that reduces to the new fee net of the old refund, paid IN.
    function test_Refinance_NetsOnce_AndTheOldRebateIsInTheNetting() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 quote0 = usdc.balanceOf(borrower);

        uint256 newId = _refiViaMulticall(oldId, P, TEN30);

        assertEq(quote0 - usdc.balanceOf(borrower), TOPUP_AT15, "one net movement: fee_new less refund_old");
        assertEq(esc.feeEscrowOf(oldId), 0, "the old escrow is settled and cleared");
        assertEq(esc.feeEscrowOf(newId), 600e6, "and the new loan gets a fresh full-term escrow");
        assertEq(_pot(), 600e6, "the hub holds exactly the new loan's escrow");
    }

    /// @notice Plan test 21: the borrower moves the NET, never the gross legs.
    /// @dev Proven by starvation, not by counting logs: `MockERC20` emits no events at all.
    /// @dev The borrower is stripped to EXACTLY the top-up before the call.
    /// @dev A gross implementation would pay out `P_new - fee_new` and then pull the whole `D_old`.
    /// @dev It would therefore need 70,000 on hand and revert here; only a netted one can succeed.
    function test_Refinance_MovesTheNetWithTheBorrower_NeverTheGrossLegs() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);

        // read the balance BEFORE the prank: a call in the argument list consumes the one-shot prank
        uint256 excess = usdc.balanceOf(borrower) - TOPUP_AT15;
        vm.prank(borrower);
        usdc.transfer(address(0xDEAD), excess);
        assertEq(usdc.balanceOf(borrower), TOPUP_AT15, "fixture: the borrower holds the net and not a wei more");

        _refiViaMulticall(oldId, P, TEN30);

        assertEq(usdc.balanceOf(borrower), 0, "the whole net moved, and nothing gross ever had to");
    }

    /// @notice A refinance whose fresh draw cannot retire the old debt is REFUSED, and moves nothing.
    /// @notice The verb never pulls: a borrower who wants to pay a shortfall repays it, in the open.
    /// @dev Carries the post-conditions of the deleted top-up-cap row: old loan untouched, debt intact.
    function test_Refinance_WhoseDrawCannotCoverTheOldDebt_IsRefused() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 quote0 = usdc.balanceOf(borrower);

        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        fin.refinance(oldId, P, TEN30, OFF);

        assertFalse(read.loan(oldId).closedAt != 0, "a refused refinance leaves the old loan untouched");
        assertEq(read.debtOf(oldId), P, "with its debt intact");
        assertEq(usdc.balanceOf(borrower), quote0, "and not a wei was pulled from the borrower");
    }

    /// @notice Plan test 24b, inverted: every draw short of the old debt by ANY margin is refused.
    /// @dev Fuzzed over the new principal, so the refusal boundary is pinned as a formula, not one number.
    /// @dev Same formula the deleted branch used to size its pull; it is now where the verb says no.
    function testFuzz_Refinance_AnyDrawShortOfTheOldDebtIsRefused(uint256 principalSeed) public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 pNew = bound(principalSeed, 40_000e6, P);
        /// @dev the ALL-IN fee, re-spelled: a carve-era factor here narrows the fuzz without failing
        uint256 feeNew = (pNew * 40 * 30 * 11000 + (10000 * 10000 * 7 - 1)) / (10000 * 10000 * 7);
        vm.assume(P + feeNew > pNew + REFUND30_AT15); // the shortfall is real at this principal

        uint256 quote0 = usdc.balanceOf(borrower);
        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        fin.refinance(oldId, pNew, TEN30, OFF);
        assertEq(usdc.balanceOf(borrower), quote0, "a refused refinance is a no-op on the borrower's balance");
        assertEq(read.debtOf(oldId), P, "and on the old loan");
    }

    /// @notice The capability survives as a COMPOSITION: repay the gap and refinance in one transaction.
    /// @dev This is what replaces the deleted branch, and it moves the same net in the same direction.
    function test_Refinance_UnderfundedDraw_IsRecoveredByMulticallRepayThenRefinance() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 quote0 = usdc.balanceOf(borrower);

        uint256 newId = _refiViaMulticall(oldId, P, TEN30);

        assertGt(newId, oldId, "the successor opened");
        assertTrue(read.loan(oldId).closedAt != 0, "and the old loan closed");
        assertEq(quote0 - usdc.balanceOf(borrower), TOPUP_AT15, "the borrower paid exactly the old shortfall");
    }

    /// @notice THE COMPOSITION HELPER IS PINNED TO THE HUB: `_gap` is the exact wei the verb stops refusing at.
    /// @notice One wei short is still `DrawBelowDebt`; the last wei of the gap opens the successor.
    /// @dev `_gap` re-derives `LoanMath.originationFee` and the escrow refund test-side, so every row
    /// @dev that composes through it inherits a SECOND copy of the hub's netting arithmetic.
    /// @dev Drift too small already fails loudly (the inner refinance reverts inside the multicall).
    /// @dev Drift too large is the silent direction, and this row is what closes it.
    function test_RefiGapHelper_IsExactlyTheHubsRefusalBoundary() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 gap = _gap(oldId, P, TEN30);
        assertEq(gap, TOPUP_AT15, "the helper agrees with the named constant, not merely with itself");

        vm.startPrank(borrower);
        ace.repay(oldId, gap - 1);
        vm.expectRevert(DrawBelowDebt.selector);
        fin.refinance(oldId, P, TEN30, OFF);
        ace.repay(oldId, 1);
        uint256 newId = fin.refinance(oldId, P, TEN30, OFF);
        vm.stopPrank();

        assertGt(newId, oldId, "the last wei of the gap is what opens the successor");
        assertTrue(read.loan(oldId).closedAt != 0, "and the old loan retires on it");
        assertEq(read.debtOf(newId), P, "at the full requested principal");
    }

    // ============ 18 / 19. every open() gate is live, and nothing half-executes ============

    /// @notice A new principal under `minDebt` is refused by `open`'s own floor.
    function test_Refinance_RevertsBelowMinDebt() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        vm.prank(borrower);
        vm.expectRevert(BelowMinDebt.selector);
        fin.refinance(oldId, 1e6, TEN30, OFF);
    }

    /// @notice A tenor off the market's grid is refused by `open`'s own range check.
    function test_Refinance_RevertsOnOutOfRangeTenor() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        vm.prank(borrower);
        vm.expectRevert(TenorOutOfRange.selector);
        fin.refinance(oldId, P, 60 days, OFF);
    }

    /// @notice Plan tests 24c and 27: refinance is not a rescue verb.
    /// @dev The new loan must clear `trigger <= funding floor`, so nobody opens their way out.
    function test_Refinance_RevertsWhenTheNewTriggerSitsAboveTheNewFloor() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        vm.prank(borrower);
        vm.expectRevert(TriggerAboveFloor.selector);
        fin.refinance(oldId, 200_000e6, TEN30, OFF);
    }

    /// @notice Plan test 19: a failing draw gate leaves the OLD loan open, funded and untouched.
    /// @dev All-or-nothing is EVM-native here, which is why no try/catch may appear inside.
    function test_Refinance_AllOrNothing_AFailedDrawLeavesTheOldLoanWhole() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 floorBefore = read.fundingFloor(id, oldId);
        uint256 claimsBefore = read.claimCount(id, oldId);
        uint256 quote0 = usdc.balanceOf(borrower);

        vm.prank(borrower);
        vm.expectRevert(TriggerAboveFloor.selector);
        fin.refinance(oldId, 200_000e6, TEN30, OFF);

        assertFalse(read.loan(oldId).closedAt != 0, "the old loan is still open");
        assertEq(read.debtOf(oldId), P, "with its debt intact");
        assertEq(read.loan(oldId).collateralUnits, COLL, "and its collateral still recorded");
        assertEq(positionManager.collateralOf(oldId), COLL, "custody never left the old vault");
        assertEq(read.fundingFloor(id, oldId), floorBefore, "its funding floor is unmoved");
        assertEq(read.claimCount(id, oldId), claimsBefore, "its claims are unmoved");
        assertEq(usdc.balanceOf(borrower), quote0, "and the borrower is neither charged nor funded");
    }

    // ============ 24 / 24d / 24e. distress, which is NOT a gate ============

    /// @notice THE INVERTED RULING: a loan in a live trigger breach CAN refinance into health.
    /// @dev The old debt is retired in FULL, so old lenders receive cash at par rather than title.
    /// @dev The trip then dissolves by arithmetic: a smaller debt is a lower trigger.
    function test_Refinance_FromALiveTriggerBreach_Succeeds_AndDissolvesTheTrip() public {
        uint256 oldId = _open(P, TEN30);
        record.setBelowBand(read.triggerPrice(oldId));
        assertTrue(read.settleable(oldId), "fixture: the old loan is settleable right now");
        _warpTo(t0 + 15 days);

        uint256 newId = _refiViaMulticall(oldId, 35_000e6, TEN30);

        assertTrue(read.loan(oldId).closedAt != 0, "the breached loan retired");
        assertEq(read.debtOf(newId), 35_000e6, "into a genuinely delevered position");
        assertFalse(read.settleable(newId), "and the trip dissolved: a lower debt is a lower trigger");
        assertFalse(read.inDistress(newId), "no distress survives the delever");
    }

    /// @notice Plan test 24d: a repeat refinance is not free -- each one charges a whole new fee.
    /// @dev Compounded with the fresh admissibility check, that is what forces progressive delevering.
    function test_Refinance_Repeated_ChargesAFreshFeeEachTime() public {
        uint256 rev0 = read.protocolRevenue(id);
        uint256 a = _open(P, TEN30);
        assertEq(read.protocolRevenue(id) - rev0, 120e6, "fixture: the first open banked one protocol cut");

        _warpTo(t0 + 15 days);
        uint256 b = _refiViaMulticall(a, P, TEN30);
        _warpTo(t0 + 30 days);
        uint256 c = _refiViaMulticall(b, P, TEN30);

        assertEq(read.protocolRevenue(id) - rev0, 360e6, "three originations, three protocol cuts");
        assertGt(c, b, "and three distinct loans");
    }

    /// @notice Plan test 24e: whichever verb lands first closes the loan and the other reverts.
    function test_Refinance_LosesTheRaceToFinalize_AndRevertsLoanClosed() public {
        uint256 oldId = _open(P, TEN30);
        record.setBelowBand(read.triggerPrice(oldId));
        _warpTo(t0 + 15 days);
        vm.prank(keeper);
        ace.finalize(oldId);

        vm.prank(borrower);
        vm.expectRevert(LoanClosed.selector);
        fin.refinance(oldId, 35_000e6, TEN30, OFF);
    }

    /// @notice The same race the other way: a refinanced loan can no longer be finalized.
    function test_Finalize_LosesTheRaceToRefinance_AndRevertsLoanClosed() public {
        uint256 oldId = _open(P, TEN30);
        record.setBelowBand(read.triggerPrice(oldId));
        _warpTo(t0 + 15 days);
        _refiViaMulticall(oldId, 35_000e6, TEN30);

        vm.prank(keeper);
        vm.expectRevert(LoanClosed.selector);
        ace.finalize(oldId);
    }

    // ============ 25. authorization ============

    /// @notice Only the loan's own borrower may refinance it.
    /// @dev A credit operator may `open` in the borrower's name, but it may never refinance.
    function test_Refinance_OnlyTheBorrower() public {
        uint256 oldId = _open(P, TEN30);
        _warpTo(t0 + 15 days);

        vm.prank(mallory);
        vm.expectRevert(NotBorrower.selector);
        fin.refinance(oldId, P, TEN30, OFF);

        vm.prank(borrower);
        ace.setCreditOperator(mallory, true);
        vm.prank(mallory);
        vm.expectRevert(NotBorrower.selector);
        fin.refinance(oldId, P, TEN30, OFF);
    }

    /// @notice A closed loan cannot be refinanced, which is the ONLY status gate there is.
    function test_Refinance_RevertsOnAClosedLoan() public {
        uint256 oldId = _open(P, TEN30);
        vm.startPrank(borrower);
        ace.repay(oldId, P);
        vm.expectRevert(LoanClosed.selector);
        fin.refinance(oldId, P, TEN30, OFF);
        vm.stopPrank();
    }

    // ============ 26. the gas curve ============

    /// @notice Plan test 26: the refinance gas curve at 1 / 8 / 25 / 32 claim ticks.
    /// @dev A MEASUREMENT, logged, not a bound: the plan's ~4.6M is an extrapolation from one point.
    /// @dev The only assertion is the operational one -- a refinance must fit inside a block.
    /// @dev It measures the repay-then-refinance COMPOSITION, since a same-block roll is always short.
    function test_Refinance_GasCurve_AcrossClaimTickCounts() public {
        _gasAt(1);
        _gasAt(8);
        _gasAt(25);
        _gasAt(32); // the genesis rail: the widest spread any market may legally reach
    }

    /// @dev One measurement point on its own market, so the ladders never share a tick.
    function _gasAt(uint256 n) private {
        MarketParams memory p = _params();
        p.minDebt = 10e6 + n; // inert here; it only makes each measurement point a distinct market id
        bytes32 mid = ace.createMarket(p);

        usdc.mint(alice, n * 1_000e6 + DEEP_CASH);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(mid, DEEP_CASH);
        for (uint256 i; i < n; i++) {
            ace.deposit(mid, 1_000e6);
        }
        vm.stopPrank();

        uint256 units = 400_000e18;
        vault.mint(borrower, units);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), units);
        usdc.approve(address(ace), type(uint256).max);
        uint256 loanId = ace.open(mid, units, n * 1_000e6, TEN7, borrower, OpenBounds(0, 0, 0));
        assertEq(read.claimCount(mid, loanId), 1, "fixture: the draw holds exactly one claim");

        // same principal, same block: the fresh fee outruns the full refund, so this is the composition
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (loanId, _gapIn(mid, loanId, n * 1_000e6, TEN7)));
        calls[1] = abi.encodeCall(Ace.refinance, (loanId, n * 1_000e6, TEN7, OFF));
        uint256 g = gasleft();
        ace.multicall(calls);
        uint256 used = g - gasleft();
        vm.stopPrank();

        console2.log(n, used);
        assertLt(used, 30_000_000, "a refinance must fit inside a mainnet block");
    }
}
