// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";

import {Loan, MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {BelowMinLot} from "../../src/ace/hub/Lender.sol";
import {NothingResting, WouldLeaveDust} from "../../src/ace/hub/Lender.sol";
import {BelowCoverageLine, BelowMinDebt, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceMoneyPath
/// @notice The money paths under loan-unit receipts: deposit -> draw -> repay -> close on the lender
/// @notice side, and open -> escrow -> payout -> release on the borrower side.
/// @dev Rewritten 2026-08-18 for the loan-unit rebuild: lots replace shares, the origination fee and
/// @dev every repayment lands in the lender's credit pool (never resting cash), and a partial repay
/// @dev retires the loan's one claim by exactly what was paid -- FORK C's pro-rata ruling, discharged.
contract AceMoneyPathTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal borrower = address(0xB0110);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PROTOCOL_SHARE = Constants.PROTOCOL_SHARE_BPS;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    // ---- helpers ----

    /// @dev Returns 0 so call sites naming a "lot" still compile; there are no lots, and nothing reads it.
    function _deposit(address who, uint256 amt) internal returns (uint256) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
        return 0;
    }

    /// @dev This market's deposit floor, which IS `minDebt`: one price, so no claim cap to divide by.
    /// @dev Read back off the hub rather than written as a literal, so it tracks the fixture's params.
    function _minLot() internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(id);
        return p.minDebt;
    }

    /// @dev 15,000 resting, which is what the three-rung ladder this replaced held in total.
    /// @dev The NAME is kept so every call site still reads as "fund this market enough to draw against".
    function _fundLadder() internal {
        _deposit(alice, 15_000e6);
    }

    function _open(uint256 units, uint256 principal) internal returns (uint256 loanId) {
        vault.mint(borrower, units);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), units);
        loanId = ace.open(id, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _repay(uint256 loanId, uint256 amount) internal {
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
        vm.stopPrank();
    }

    /// @dev The lender share of the fee that reaches the credit pool at open.
    function _tickFee(uint256 principal) internal view returns (uint256) {
        uint256 lender = _lenderFee(principal);
        return lender - (lender * Constants.REBATE_PHI_BPS) / 10000;
    }

    /// @dev The refundable escrow the hub custodies outside `totalCash` for the life of the loan.
    function _escrow(uint256 principal) internal view returns (uint256) {
        return _lenderFee(principal) - _tickFee(principal);
    }

    /// @dev What the lender side keeps: the whole all-in less ACE's cut, which now rides ON TOP of it.
    function _lenderFee(uint256 principal) internal view returns (uint256) {
        uint256 fee = _fee(principal);
        return fee - _protocolFee(fee);
    }

    /// @dev ACE's cut, recovered from the ALL-IN by the inverse ratio; floors toward the lender.
    function _protocolFee(uint256 fee) internal pure returns (uint256) {
        return (fee * PROTOCOL_SHARE) / (10000 + PROTOCOL_SHARE);
    }

    /// @dev The borrower's ALL-IN cost: `baseBps` prices the lender and the protocol adds its share.
    function _fee(uint256 principal) internal view returns (uint256) {
        return LoanMath.originationFee(principal, ProtocolPolicy.MIN_TENOR, PocDeployConfig.BASE_BPS, ProtocolPolicy.MIN_TENOR);
    }

    /// @dev The solvency identity, EXACT: hub quote is the four booked pots and not a wei more.
    /// @dev `unitOwed` is the hub's own O(1) mirror of what the classes owe their unit holders.
    function _assertSolvency() internal view {
        MarketState memory s = read.marketState(id);
        (uint256 resting,, uint256 owed) = read.poolOf(id); // the LENDER legs; one market here, so it spans nothing else
        uint256 pot;
        for (uint256 i = 1; i <= read.loanCount(); i++) {
            pot += read.feeEscrowOf(i);
        }
        assertEq(usdc.balanceOf(address(ace)), resting + s.protocolRevenue + pot + owed + s.quoteOwedTotal, "solvency identity");
    }

    // ============ lender side: the market's resting cash ============

    function test_Deposit_CreditsTheMarket_SolvencyIdentityHolds() public {
        _deposit(alice, 1000e6);
        assertEq(ace.restingOf(id), 1000e6, "the deposit is the position, exactly");
        _assertSolvency();
    }

    /// @notice A draw takes from the market's resting cash, and the FEE IS NOT CASH -- it never rests.
    /// @dev IT WAS `test_Draw_ConsumesHighestTicksFirst`, and the ordering half is gone with the ladder:
    /// @dev four deposits used to build four rungs a top-down walk ate in order. They build one balance now.
    /// @dev What survives is the half that was never about ordering: the take leaves the market, the lender
    /// @dev fee lands in the pool rather than back in resting cash, and the borrower is paid net of it.
    function test_Draw_TakesFromRestingCash_AndTheFeeIsNotCash() public {
        _deposit(alice, 4000e6);
        uint256 fee = _fee(500e6);

        uint256 loanId = _open(COLL, 500e6);

        assertEq(read.claimOf(id, loanId), 500e6, "the loan holds a claim for what it drew");
        assertEq(ace.restingOf(id), 3500e6, "resting cash fell by the take; the fee is NOT cash");
        assertEq(usdc.balanceOf(borrower), 500e6 - fee, "borrower received principal net of fee");
        assertEq(read.poolOwed(id), _tickFee(500e6), "the credit pool carries exactly the lender fee");
        _assertSolvency();
    }

    /// @notice The funding floor IS the market's own price, which is the whole of what a loan funded at.
    /// @dev IT WAS `test_FundingFloor_IsLowestTickHoldingAClaim`: a draw spanning three rungs floored at the
    /// @dev lowest one it reached. A market has one price, so the floor is knowable before the draw happens.
    function test_FundingFloor_IsTheMarketsPrice() public {
        _fundLadder();
        uint256 loanId = _open(30_000e18, 12_000e6);
        assertEq(read.fundingFloor(id, loanId), ace.idToMarketParams(id).price, "the floor is the market's price");
    }

    /// @notice DOCTRINE: neither trades nor idle cash move a loan's funding floor.
    /// @dev It reads almost trivial now and is kept deliberately. The doctrine sentence is unchanged, and a
    /// @dev future change that made the floor track anything live -- resting depth, a record, a mark -- would
    /// @dev fail HERE and nowhere else. Cheap to keep, and the only witness that the rule still binds.
    function test_Deposit_NeverMovesFloor() public {
        _deposit(alice, 2000e6);
        uint256 loanId = _open(COLL, 1500e6);
        uint256 floorBefore = read.fundingFloor(id, loanId);
        assertEq(floorBefore, ace.idToMarketParams(id).price, "the loan funded at the market's price");

        _deposit(alice, 2000e6);
        assertEq(read.fundingFloor(id, loanId), floorBefore, "fresh deposits never move the floor");
    }

    function test_Withdraw_RestingCash_AlwaysFree() public {
        /// @dev WAS two lots at two ticks, with the draw taking bob's whole rung so alice's was untouched.
        /// @dev One market holds ONE balance, so what the draw leaves is the remainder of the whole of it --
        /// @dev which is the same property, stated without a second rung to hide behind.
        _deposit(alice, 1000e6);
        _deposit(alice, 9000e6);
        _open(20_000e18, 8900e6);

        vm.prank(alice);
        uint256 out = ace.withdraw(id, type(uint256).max, alice, 0);
        assertEq(out, 10_000e6 - 8900e6, "resting cash withdraws fully regardless of utilization");
        assertEq(usdc.balanceOf(alice), 10_000e6 - 8900e6);
    }

    /// @notice Lent principal is not recallable: the exit pays RESTING cash and never reaches a live claim.
    /// @dev THE FIXTURE GOT SIMPLER AND THE PROPERTY DID NOT MOVE. It used to rest at two ticks and rely on
    /// @dev the top-down walk consuming the upper one whole, so that the tick under test was spent and the
    /// @dev other was not. A draw now takes from one balance, so drawing ALL of it is the whole setup.
    function test_Withdraw_LentPrincipal_StructurallyImpossible() public {
        _deposit(alice, 1000e6);
        _open(COLL, 1000e6); // the whole resting balance goes out as principal

        assertEq(ace.restingOf(id), 0, "fixture: nothing rests, so anything paid out would be lent principal");
        /// @dev WAS `withdraw(max) == 0`, a silent no-op. The door FAILS CLOSED on an empty market now and
        /// @dev names the reason, which says the same thing louder: there is nothing here that is not lent.
        vm.prank(alice);
        vm.expectRevert(NothingResting.selector);
        ace.withdraw(id, type(uint256).max, alice, 0);
        assertEq(usdc.balanceOf(alice), 0, "and no quote moves");
    }

    /// @dev ONE LENDER, ONE BALANCE: it rests and exits through the same two verbs, with no lock of any kind.
    function test_Withdraw_UndrawnCash_ExitsWhole() public {
        uint256 amt = 1000e6;
        _deposit(alice, amt);

        vm.prank(alice);
        uint256 out = ace.withdraw(id, type(uint256).max, alice, 0);
        assertEq(out, amt, "undrawn cash exits whole and exact; no reserve, no share price, no lock");
        assertEq(ace.restingOf(id), 0, "and the market empties");
    }

    /// @dev With lots there is no share price at all, so there is nothing a donation can inflate.
    /// @dev The probe seats the attacker at the SMALLEST lot the market takes, which is the strongest case.
    /// @dev Re-based from one wei: the floor is DERIVED now, so the ticket is the cheapest seat on offer.
    function test_NoSharePrice_MeansNoInflationSurface() public {
        /// @dev WAS BOB'S SECOND LOT recovered while alice's first-depositor seat sat beside it. Sole tenancy
        /// @dev admits ONE lender, so the seat and the deposit are the same party's -- and the property is
        /// @dev unchanged: what comes back is what went in, because there is no share price to inflate.
        uint256 seat = _minLot();
        _deposit(alice, seat); // the classic first-depositor seat, and it still buys nothing
        _deposit(alice, 1000e6);

        usdc.mint(address(ace), 5000e6); // a raw donation must be invisible to the cash accounting

        vm.prank(alice);
        uint256 out = ace.withdraw(id, type(uint256).max, alice, 0);
        assertEq(out, seat + 1000e6, "the lender recovers their deposits EXACTLY; no share price exists to steal via");
    }

    /// @dev Undrawn round trips are exact now; only a draw can move a lot's value.
    function test_UndrawnRoundTrip_IsExact() public {
        _deposit(alice, 1000e6);
        vm.prank(alice);
        assertEq(ace.withdraw(id, type(uint256).max, alice, 0), 1000e6, "exact round trip");

        /// @dev WAS a SECOND LOT recalled whole beside a large first one. One market holds one balance, so a
        /// @dev floor-sized round trip is a floor-sized ASK against a deep balance, and the exactness is the
        /// @dev same claim: what the lender takes out is what they asked for, to the wei.
        _deposit(alice, 1_000_000e6);
        _deposit(alice, 10e6);
        vm.prank(alice);
        assertEq(ace.withdraw(id, 10e6, alice, 0), 10e6, "exact at the floor size too");
        assertEq(ace.restingOf(id), 1_000_000e6, "and the rest of the balance is untouched by it");
    }

    // ============ the lender floor is DERIVED: `ceil(minDebt / maxClaimTicks)`, a fraction of minDebt ============

    /// @notice THE LENDER FLOOR IS A SMALL FRACTION OF `minDebt` HERE, which is what this section rests on.
    /// @notice It is `ceil(minDebt / maxClaimTicks)`, so at the fixture's 10e6 over 32 it is 312,500 wei.
    /// @notice Where the floor bites at a real size, `AceN4Floors.t.sol` pins what it does.
    /// @notice `minDebt` gates the BORROWER directly, and reaches the lender only through that division.
    /// @notice A deposit AT the floor is admitted and books exactly; a second one joins it.
    /// @dev THE FLOOR IS `minDebt` ITSELF NOW. It was `ceil(minDebt / maxClaimTicks)`, a small fraction of it,
    /// @dev sized so a maximally FRAGMENTED ladder could still fund one minimum loan. With one price there is
    /// @dev nothing to fragment, so the fraction has no job and the floor is the admission quantum directly.
    /// @dev What survives is why a floor exists at all: cash under it is depth no draw can consume.
    function test_Deposit_ADepositAtTheFloorIsAdmittedAndBooksExactly() public {
        uint256 ticket = _minLot();
        assertEq(ticket, 10e6, "PREMISE: the floor IS the fixture's minDebt, with no cap left to divide by");
        _deposit(alice, ticket);
        assertEq(ace.restingOf(id), ticket, "a deposit AT the floor books, and books exactly");

        _deposit(alice, 10e6);
        assertEq(ace.restingOf(id), ticket + 10e6, "an ordinary deposit joins it, and the market carries the sum");
    }

    /// @notice With the floor at zero, the empty-lot rule is the whole of what is left on entry.
    function testRevert_Deposit_AZeroLotIsRefusedEvenWithTheFloorOff() public {
        usdc.mint(alice, 1);
        vm.startPrank(alice);
        usdc.approve(address(ace), 1);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(id, 0);
        vm.stopPrank();
        assertEq(ace.restingOf(id), 0, "and nothing was booked on the way to the refusal");
    }

    /// @notice THE SEPARATION, pinned here because this market is the extreme case of it.
    /// @notice The lender floor is zero and the BORROWER floor is still `minDebt`, in the same market.
    function testRevert_Open_TheBorrowerQuantumIsStillMinDebt() public {
        _fundLadder();
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        vm.expectRevert(BelowMinDebt.selector);
        ace.open(id, COLL, 10e6 - 1, 0, borrower, OpenBounds(0, 0, 0)); // sub-quantum LOAN: dust the book refuses
        vm.stopPrank();
    }

    /// @notice With the floor off, a partial may leave a dust REMAINDER at the tick and the lender keeps it.
    /// @notice Floor-or-zero still governs wherever the derived floor is nonzero; it is vacuous at zero.
    /// @dev The remainder is the TICK's now, not a fresh lot: one lender, so there is nothing to distinguish.
    /// @dev WAS "with the floor OFF a partial may leave a dust remainder". There is no floor-off market: the
    /// @dev lender floor WAS `ceil(minDebt / maxClaimTicks)` and derived to a fraction here, while `minDebt`
    /// @dev floors both doors directly now and genesis refuses a zero. So a sub-floor REMAINDER is refused,
    /// @dev and what survives is the other half this row carried: emptying is never gated.
    function test_Withdraw_ASubFloorRemainderIsRefusedAndEmptyingNeverIs() public {
        _deposit(alice, 30e6);
        vm.prank(alice);
        vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(id, 25e6, alice, 0); // would leave 5e6, under the market's own 10e6 quantum

        vm.prank(alice);
        assertEq(ace.withdraw(id, 20e6, alice, 0), 20e6, "a remainder that CLEARS the floor is paid in full");
        assertEq(ace.restingOf(id), 10e6, "and the floor-sized remainder rests");
        vm.prank(alice);
        assertEq(ace.withdraw(id, type(uint256).max, alice, 0), 10e6, "which the lender can still take whole");
    }

    /// @notice Every partial shape is legal now, so this pins the two ENDS rather than a floor-or-zero rule.
    /// @dev Renamed from `test_Withdraw_FloorOrZero_BothLegalShapes`; the assertions are unchanged.
    function test_Withdraw_PartialAndWholeBothPayExactly() public {
        _deposit(alice, 30e6);
        vm.prank(alice);
        assertEq(ace.withdraw(id, 20e6, alice, 0), 20e6, "a partial pays exactly what was asked");
        vm.prank(alice);
        assertEq(ace.withdraw(id, type(uint256).max, alice, 0), 10e6, "and the full exit is never gated");
    }

    // ============ borrower side: open, repay, close ============

    function test_Open_EscrowsCollateral_TransfersDraw() public {
        _fundLadder();
        uint256 fee = _fee(4_500e6);
        uint256 loanId = _open(COLL, 4_500e6);

        assertEq(positionManager.collateralOf(loanId), COLL, "collateral escrowed");
        assertEq(vault.balanceOf(address(positionManager)), COLL, "the custodian's pot holds it");
        assertEq(positionManager.custodiedOf(address(vault)), COLL, "and the pot-level aggregate agrees");
        assertEq(usdc.balanceOf(borrower), 4_500e6 - fee, "borrower received net principal");

        Loan memory l = read.loan(loanId);
        assertEq(l.borrower, borrower);
        assertEq(l.debt, 4_500e6, "debt is the principal");
        assertEq(l.market, id, "the loan carries its own market");
        assertEq(read.loanCount(), loanId, "ids are allocated globally by the hub");
    }

    function test_Open_ChargesFee_SplitLenderAndProtocol() public {
        _fundLadder();
        uint256 fee = _fee(4_500e6);
        uint256 protocolFee = _protocolFee(fee);

        uint256 loanId = _open(COLL, 4_500e6);

        assertEq(read.protocolRevenue(id), protocolFee, "protocol share to reserves");
        assertEq(ace.restingOf(id), 10_500e6, "the market keeps only its undrawn cash");
        vm.prank(alice);
        uint256 paid = ace.collect(address(usdc), alice);
        assertApproxEqAbs(paid, _tickFee(4_500e6), 1, "the lender share arrives through the class index");
        _assertSolvency();
    }

    /// @notice Every wei of an origination fee has a home: what the classes were owed, plus what the
    /// @notice protocol banked, IS the fee.
    /// @dev The draw credits each class `(tickFee * take) / amount`, FLOORED, so a draw spanning
    /// @dev several ticks leaves a remainder; this pins that it reaches the one pot with an exit.
    function test_Open_FeeIsFullyAccountedFor_NoDustEscapes() public {
        _fundLadder();
        uint256 principal = 12_345_678_901; // an awkward figure, so any flooring residue in the fee split shows
        uint256 fee = _fee(principal);
        uint256 protocolCut = _protocolFee(fee);
        uint256 tickFee = _tickFee(principal);

        _open(60_000e18, principal);

        /// @dev WAS A THREE-RUNG SUM with a floor per rung, and the REMAINDER of those floors swept to the
        /// @dev protocol as unplaceable dust. One claim takes the whole lender fee exactly, so there is no
        /// @dev split to floor and no residue to sweep: the cut is the cut, and the pool takes the rest.
        assertEq(read.protocolRevenue(id), protocolCut, "the protocol takes its cut and no dust beside it");
        assertEq(read.poolOwed(id), tickFee, "and the lender's whole share reaches the pool, unfloored");
        _assertSolvency();
    }

    function test_Open_RevertsWhenTriggerAboveFloor() public {
        _fundLadder();
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        vm.expectRevert(TriggerAboveFloor.selector); // floors at T2 (1.00), trigger 1.89 sits above it
        ace.open(id, COLL, 13_500e6, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice The admissibility gate AT ITS BOUNDARY: the coverage line admits, one unit less refuses.
    /// @notice The line is `requiredAt` plus ONE ATOM, so the trigger boundary sits strictly inside it.
    /// @dev The trigger leg keeps its own boundary and its own selector; both are asserted, so neither is assumed.
    /// @dev BY SELECTOR: one unit under the LINE still clears the trigger, so only `BelowCoverageLine` can name it.
    /// @dev THE EPSILON WAS `maxClaimTicks`, one atom per funded tick, because settlement ceiled per tick while
    /// @dev `requiredAt` ceils the whole debt once. A loan funds exactly one claim, so the derivation gives one.
    function test_Gate_CoverageLine_AdmitsAndOneUnitLessRefuses() public {
        _fundLadder();
        uint256 principal = 5_000e6;
        uint256 k = ace.idToMarketParams(id).minCoverageWad;
        uint256 us = read.marketState(id).unitScale;
        uint256 floorP = ace.idToMarketParams(id).price;
        uint256 den = floorP * 1e18;
        uint256 minColl = (k * principal * us + den - 1) / den; // ceil: the least collateral the trigger clears
        uint256 line = minColl + 1;

        assertLe(LoanMath.triggerPrice(principal, minColl, k, us), floorP, "fixture: minColl must clear the trigger");
        assertGt(LoanMath.triggerPrice(principal, minColl - 1, k, us), floorP, "fixture: minColl-1 must not");
        assertLe(LoanMath.triggerPrice(principal, line - 1, k, us), floorP, "fixture: one under the LINE still clears it");

        uint256 snap = vm.snapshotState();
        uint256 loanId = _open(line, principal);
        assertEq(read.fundingFloor(id, loanId), floorP, "the draw floored at the market's price");
        assertLe(read.triggerPrice(loanId), floorP, "admitted at the line: the trigger sits under the floor");
        vm.revertToState(snap);

        vault.mint(borrower, line - 1);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), line - 1);
        vm.expectRevert(BelowCoverageLine.selector);
        ace.open(id, line - 1, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function test_TriggerPrice_FallsAsDebtMelts() public {
        _fundLadder();
        uint256 loanId = _open(COLL, 4_500e6);
        _assertTrigger(loanId, 0.63e18, "1.4 * 4500 / 10000 = 0.63 quote per collateral");

        _repay(loanId, 2_250e6);
        _assertTrigger(loanId, 0.315e18, "trigger halves as debt halves");
    }

    /// @dev The trigger named as a HUMAN price, in the hub's frame; the hub ceils against the borrower.
    /// @dev So the answer sits on that price or one atom above it, and never anywhere else.
    function _assertTrigger(uint256 loanId, uint256 humanWad, string memory why) internal view {
        uint256 want = AceFixtures.px(humanWad, address(usdc), address(vault));
        uint256 got = read.triggerPrice(loanId);
        assertGe(got, want, why);
        assertLe(got, want + 1, why);
    }

    /// @notice A partial repay retires the loan's claim by EXACTLY what was paid, and never moves the floor.
    /// @dev FORK C IS DISCHARGED RATHER THAN DELETED. It ruled that a partial repay melt every funded tick
    /// @dev PRO RATA, so no tick was preferentially freed and the funded-tick list survived until the loan
    /// @dev fully retired. A loan holds ONE claim now, so the split has one part: the ruling's outcome is
    /// @dev what the arithmetic does on its own, and the flooring residue it had to sweep cannot arise.
    /// @dev The half that still needs a witness is the floor: a melt must never raise it, whatever it retires.
    function test_Repay_MeltsExactly_FloorUnchanged() public {
        _fundLadder();
        uint256 loanId = _open(30_000e18, 12_000e6);
        uint256 floorBefore = read.fundingFloor(id, loanId);
        assertEq(floorBefore, ace.idToMarketParams(id).price, "the loan funded at the market's price");
        assertEq(read.claimOf(id, loanId), 12_000e6, "the loan's whole claim");

        _repay(loanId, 2_400e6); // one fifth of the debt

        assertEq(read.claimOf(id, loanId), 9_600e6, "the claim fell by exactly what was paid: no residue to sweep");
        assertEq(read.fundingFloor(id, loanId), floorBefore, "a melt never raises the floor");
    }

    function test_Repay_Full_ClosesLoanAndReleasesCollateral() public {
        _fundLadder();
        uint256 loanId = _open(COLL, 4_500e6);

        _repay(loanId, 4_500e6);

        Loan memory l = read.loan(loanId);
        assertTrue(l.closedAt != 0, "full repayment closes the loan");
        assertEq(l.debt, 0);
        assertEq(l.collateralUnits, 0, "the loan holds no collateral once closed");
        assertEq(positionManager.collateralOf(loanId), 0, "custody left the live ledger");
        assertEq(positionManager.retiredOf(loanId), COLL, "and is credited, still sitting in the loan's own vault");
        assertEq(read.unitsOwedOf(loanId, borrower), COLL, "the whole position is the holder's to pull");
        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);
        assertEq(vault.balanceOf(borrower), COLL, "collateral back with the borrower once pulled");
        assertEq(positionManager.retiredOf(loanId), 0, "and the retired ledger clears");
        assertEq(read.fundingFloor(id, loanId), 0, "a fully melted loan has no floor");
        assertEq(read.poolLent(id), 0, "every claim retired");
    }

    /// @dev MEASURED AT THE WALLET. The full repay is a terminal door and the hub pushes the pool to the
    /// @dev lender there, so `collect` finds nothing and the bounds belong on what actually arrived.
    /// @dev The bounds themselves are untouched: par at the bottom, par plus the whole fee at the top.
    function test_Repay_Full_LenderCollectsParPlusFeeThroughTheIndex() public {
        _fundLadder();
        uint256 loanId = _open(COLL, 4_500e6);
        uint256 before = usdc.balanceOf(alice);
        _repay(loanId, 4_500e6);

        uint256 paid = usdc.balanceOf(alice) - before;
        assertGe(paid, 4_500e6, "par came back through the index");
        assertLe(paid, 4_500e6 + _fee(4_500e6), "and never more than par plus the whole fee");
        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), 0, "and the recovery door has nothing left to bring home");
    }

    /// @notice A paydown may land under `minDebt`: the floor gates what a market ISSUES, not what a loan carries.
    /// @dev The melt still tracks it -- claims retire by exactly the debt decrement, so the lender is paid either way.
    function test_Repay_LeavingDust_Stands() public {
        _fundLadder();
        uint256 loanId = _open(COLL, 4_500e6);
        uint256 owedBefore = read.poolOwed(id);

        _repay(loanId, 4_495e6); // leaves 5 USDC, under the 10 USDC floor

        assertEq(read.loan(loanId).debt, 5e6, "the loan carries the dust");
        assertFalse(read.loan(loanId).closedAt != 0, "and stays open on it");
        assertEq(read.poolOwed(id) - owedBefore, 4_495e6, "and the lender is owed every wei of it already");
    }

    function test_Repay_Overpay_ClampsToDebt() public {
        _fundLadder();
        uint256 loanId = _open(COLL, 4_500e6);

        _repay(loanId, 5_000e6); // more than owed

        assertEq(read.loan(loanId).debt, 0);
        // the clean close also refunds the WHOLE escrow: nothing of the term was used
        assertEq(read.quoteOwedOf(loanId, borrower), _escrow(4_500e6), "the whole escrow is credited, not pushed");
        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);
        uint256 want = 5_000e6 - 4_500e6 + (4_500e6 - _fee(4_500e6)) + _escrow(4_500e6);
        assertEq(usdc.balanceOf(borrower), want, "only the debt was pulled, and the unused escrow came back");
    }
}
