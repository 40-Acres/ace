// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, NoMarket, NotBorrower, NotPositionTitle} from "../../src/ace/hub/Ace.sol";
import {ArmNeedsRecord} from "../../src/ace/hub/Borrower.sol";
import {NotTheLender} from "../../src/ace/hub/Lender.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The per-leg door alone: `abi.encodeCall` and typed calls cannot resolve an overloaded member.
interface IClaimOwedPerLeg {
    function claimOwed(uint256 loanId, address toUnits, address toQuote) external returns (uint256, uint256);
}

/// @title AceUnknownIdFailsClosed
/// @notice EVERY loan-keyed hub verb refuses an id that names no loan, before any body runs.
/// @notice STRUCTURAL: a loan verb resolves its market off the loan record, which reads zero for an unallocated id.
/// @notice Caching the zero market reverts `NoMarket`, because that market's quote token is the zero address.
/// @dev Nothing here remembers to block anything: the market read is the FIRST thing every verb does.
/// @dev So the property survives a new verb being added, provided that verb also resolves its market first.
/// @dev THREE verbs fail closed under a DIFFERENT selector, each because an earlier gate binds; rows below.
/// @dev The control test is load-bearing: without it every row could pass on a fixture where nothing works.
contract AceUnknownIdFailsClosedTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id;

    uint256 internal liveLoan; // a real, open loan, so the ghost sits PAST the allocated range
    uint256 internal ghost; // the id under test: the next the counter would hand out, never written

    address internal alice = address(0xA11CE); // lender
    address internal bob = address(0xB0B); // borrower of the one real loan
    address internal mallory = address(0xBAD); // the caller who names an id that is not a loan

    uint256 internal T; // par for this pair, 1.00 quote per collateral; assigned in setUp
    uint64 internal constant TEN = ProtocolPolicy.MIN_TENOR;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant PRINCIPAL = 50_000e6;
    uint256 internal constant DEPTH = 400_000e6;

    /// @dev An id far past anything this fixture could allocate; the second witness for the same path.
    uint256 internal constant FAR_ID = 2 ** 128;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = _price(0);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, DEPTH);
        vm.startPrank(alice);
        usdc.approve(address(ace), DEPTH);
        ace.deposit(id, DEPTH);
        vm.stopPrank();

        liveLoan = _openReal();
        ghost = read.loanCount() + 1; // BOUND HERE: an external read between prank and expectRevert eats both
    }

    // ---- helpers ----

    function _openReal() internal returns (uint256 loanId) {
        vault.mint(bob, COLL);
        vm.startPrank(bob);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, COLL, PRINCIPAL, TEN, bob, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _bounds() internal pure returns (OpenBounds memory) {
        return OpenBounds(0, 0, 0);
    }

    // ============ the id names nothing ============

    /// @notice The premise every row below rests on: the id resolves to no market, no borrower, no record.
    function test_UnknownId_NamesNoLoanAtAll() public view {
        assertGt(ghost, liveLoan, "the ghost sits past every id the counter has handed out");
        assertEq(ace.loanMarket(ghost), bytes32(0), "no market behind the id");
        assertEq(ace.borrowerOf(ghost), address(0), "no borrower behind the id");
        assertEq(read.loan(ghost).debt, 0, "no debt behind the id");
        assertEq(read.loan(ghost).collateralUnits, 0, "no collateral behind the id");
        assertEq(ace.loanMarket(FAR_ID), bytes32(0), "and the same for an id far past the counter");
    }

    // ============ THE case: a zero-amount repay ============

    /// @notice A ZERO-AMOUNT REPAY IS THE ONE THAT MUST REFUSE, and it has its own row for that reason.
    /// @notice On a LIVE loan `repay(id, 0)` is a legal no-op that reverts nothing -- the control pins that.
    /// @notice So it is the cheapest probe at a non-loan record: it clears any amount-shaped gate and finds no debt.
    /// @dev This row is what keeps the rejected "an order is a zero-debt loan record" design rejected.
    /// @dev Under it this exact call cleared the liveness gate and reached the clean-close path, for gas.
    function test_UnknownId_RepayZeroAmount_Refuses() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.repay(ghost, 0);
    }

    /// @notice The same probe at a far constant, so the refusal is not an artifact of `count + 1`.
    function test_UnknownId_RepayZeroAmount_RefusesAtAFarId() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.repay(FAR_ID, 0);
    }

    /// @notice The rest of the amount domain refuses identically: zero is not a special case here.
    function test_UnknownId_RepayEveryAmount_Refuses() public {
        vm.startPrank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.repay(ghost, 1);
        vm.expectRevert(NoMarket.selector);
        ace.repay(ghost, PRINCIPAL);
        vm.expectRevert(NoMarket.selector);
        ace.repay(ghost, type(uint256).max);
        vm.expectRevert(NoMarket.selector);
        ace.repayWithPermit2(ghost, 0, "");
        vm.stopPrank();
    }

    // ============ the borrower verbs ============

    function test_UnknownId_WithdrawCollateral_Refuses() public {
        vm.startPrank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.withdrawCollateral(ghost, 1, mallory);
        /// @dev the zero-units twin: the cache is built BEFORE `ZeroWithdrawal`, so the market refuses first
        vm.expectRevert(NoMarket.selector);
        ace.withdrawCollateral(ghost, 0, mallory);
        vm.stopPrank();
    }

    function test_UnknownId_Refinance_Refuses() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.refinance(ghost, PRINCIPAL, TEN, _bounds());
    }

    /// @notice `refinanceTo` names a REAL destination market, so only the source id is unknown.
    /// @dev Both caches are built in one argument list; the source's is the one that cannot resolve.
    function test_UnknownId_RefinanceTo_RefusesEvenIntoALiveMarket() public {
        MigrateArgs memory m = MigrateArgs(ghost, id, PRINCIPAL, TEN, _bounds(), 0, address(0));
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.refinanceTo(m);
    }

    function test_UnknownId_RefinanceByPolicy_Refuses() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.refinanceByPolicy(ghost);
    }

    /// @notice The batched form refuses on the same read, so one unknown id takes the whole batch.
    function test_UnknownId_RefinanceByPolicies_Refuses() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = ghost;
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.refinanceByPolicies(ids);
    }

    // ============ the keeper verbs ============

    function test_UnknownId_Deleverage_Refuses() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.deleverage(ghost, 0, "");
    }

    function test_UnknownId_Finalize_Refuses() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.finalize(ghost);
    }

    function test_UnknownId_ForceClose_Refuses() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.forceClose(ghost);
    }

    /// @notice The unpaid backstop reads no gate and no record, so the market lookup is ALL that stands here.
    /// @dev A ghost carries tenor zero, hence window zero, so its clock admits at once: only `NoMarket` refuses it.
    function test_UnknownId_SettleExpired_Refuses() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.settleExpired(ghost);
    }

    function test_UnknownId_BuyInventory_Refuses() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.buyInventory(ghost, 1, 0, mallory);
    }

    // ============ the loan-keyed claim surface ============

    /// @notice Claims are loan-keyed too, so an id that names no loan must buy no payout path either.
    function test_UnknownId_ClaimSurface_Refuses() public {
        vm.startPrank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.claimOwed(ghost, mallory);
        vm.expectRevert(NoMarket.selector); // the per-leg door builds the same cache, so a ghost id refuses there too
        IClaimOwedPerLeg(address(ace)).claimOwed(ghost, mallory, mallory);
        vm.expectRevert(NoMarket.selector); // and a skipped leg does not buy a ghost id a silent zero either
        IClaimOwedPerLeg(address(ace)).claimOwed(ghost, mallory, address(0));
        vm.expectRevert(NoMarket.selector);
        ace.redeemInKind(ghost, mallory);
        vm.stopPrank();
    }

    /// @dev DELETED WITH THE REARM POLICY: `test_UnknownId_RearmRefusalView_AnswersDisarmed` and
    /// @dev `test_UnknownMarket_SetRearm_Refuses`, and before them `test_UnknownId_RearmCrankSurface_Refuses`.
    /// @dev The crank, the door and the view are all gone; there is no surface left for a ghost id to aim at.

    /// @notice The lender's CREDIT read answers zero on a pair nobody lent in, rather than reverting over a lookup.
    /// @dev Stated as a VALUE rather than a refusal, which is the same fail-closed fact: the pool is keyed by
    /// @dev (lender, quote) and an unwritten one holds nothing. A keeper reading it learns there is nothing to take.
    /// @dev IT IS THE GUARDED READ, so a torn answer here would misprice a share -- zero is the only safe default.
    function test_UnknownQuote_LenderAssets_AnswersZero() public view {
        assertEq(ace.lenderAssets(alice, address(0)), 0, "nothing is pooled on a quote nobody lent in");
        (,, uint256 owed) = read.lenderPools(alice, address(0));
        assertEq(owed, 0, "and the credit leg a collect would pay is zero on it too");
    }

    // ============ the three that fail closed under ANOTHER selector ============

    /// @notice `setAutoRefinance` refuses, but as `NotBorrower`: the title check runs before any market read.
    /// @notice Still closed -- an unwritten record's borrower is the zero address and no caller can be it.
    /// @dev Recorded because a caller catching `NoMarket` alone would not recognise this refusal.
    function test_UnknownId_SetAutoRefinance_RefusesAsNotBorrower() public {
        vm.prank(mallory);
        vm.expectRevert(NotBorrower.selector);
        ace.setAutoRefinance(ghost, TEN, 0, 0);
    }

    /// @notice `redeemInKind` refuses as `NotTheLender`: identity binds before any pot is read.
    /// @dev An unallocated loan resolves a zero-lender market, so no caller can ever be its lender.
    /// @dev `NoMarket`, not `NotTheLender`: the verb resolves the loan's MARKET before it asks who the lender
    /// @dev is, and a ghost loan names market zero. That is the earlier and more precise of the two refusals.
    function test_UnknownId_RedeemInKind_RefusesAsNoMarket() public {
        vm.prank(mallory);
        vm.expectRevert(NoMarket.selector);
        ace.redeemInKind(ghost, alice);
    }

    /// @notice `retitle` refuses as `NotPositionTitle`: it answers only the hub's own title collection.
    /// @dev Loan-keyed, so it is in scope here, but identity binds before the id is ever resolved.
    function test_UnknownId_Retitle_RefusesAsNotPositionTitle() public {
        vm.prank(mallory);
        vm.expectRevert(NotPositionTitle.selector);
        ace.retitle(ghost, bob, mallory);
    }

    // ============ the control ============

    /// @notice WITHOUT THIS ROW every assertion above could pass on a fixture where nothing works.
    /// @notice The same calls against a REAL live loan do not revert `NoMarket`; the zero-amount repay is a legal no-op.
    function test_control_TheSameVerbsReachALiveLoan() public {
        assertEq(ace.loanMarket(liveLoan), id, "guard: the real id resolves to this market");
        assertFalse(ace.isClosed(liveLoan), "guard: the real loan is live");

        uint256 debtBefore = read.loan(liveLoan).debt;
        vm.prank(mallory);
        ace.repay(liveLoan, 0); // no revert: the live-loan twin of the probe above
        assertEq(read.loan(liveLoan).debt, debtBefore, "a zero repay moves nothing");
        assertFalse(ace.isClosed(liveLoan), "and it does NOT close the loan");

        /// @dev The fixture market is recordless, so the verb passes the borrower gate and reaches the market's record.
        /// @dev A refusal by NAME from that far in still proves the refusal above was the id and not the verb.
        vm.prank(bob);
        vm.expectRevert(ArmNeedsRecord.selector);
        ace.setAutoRefinance(liveLoan, TEN, 0, 0);
    }
}
