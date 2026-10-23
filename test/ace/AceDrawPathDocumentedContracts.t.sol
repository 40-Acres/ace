// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DrawBelowDebt, PayoutBelowMin} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IAceRefinance} from "../utils/RebateHarness.sol";

/// @title AceDrawPathDocumentedContracts
/// @notice Two contracts the draw/repay path's NatSpec states, each now pinned by the rows below.
/// @dev Row 1: `minPayout` binds the NET out. It once read only on the payout branch, and a top-up
/// @dev refinance slipped past it; deleting that branch makes the single remaining bound total.
/// @dev Row 2: a partial repay retires exactly the claim it paid for, to the wei.
contract AceDrawPathDocumentedContractsTest is WarpClock {
    Ace internal ace;
    IAceRefinance internal fin;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant GRID = 23 days;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 200_000e18;
    uint256 internal constant FEE30 = 1_320e6; // 70_000 * 44 bps all-in * 30d/7d, ceiled
    uint256 internal constant REFUND30_AT15 = 300e6; // half the lender fee, half the term left
    uint256 internal constant TOPUP_AT15 = FEE30 - REFUND30_AT15;

    uint256 internal HIGH; // this pair's par price, assigned in setUp: par is not a compile-time value
    uint256 internal constant HIGH_CASH = 50_000e6;
    uint256 internal constant LOW_CASH = 50_000e6;
    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        HIGH = AceFixtures.priceAt(address(usdc), address(vault), 0);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        fin = IAceRefinance(address(ace));

        /// @dev WAS two ticks with their own lots; the market bids at HIGH and the cash is one balance.
        _deposit(alice, HIGH_CASH + LOW_CASH);
        usdc.mint(borrower, 1_000_000e6);
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
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, COLL, principal, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    // ---- row 1: minPayout binds the net out, on the only branch there is ----

    /// @notice A refinance whose draw cannot retire the old debt is refused, by the shortfall's own name.
    /// @dev The verb has no pull leg, so an underfunded draw is a refusal rather than a request for cash.
    function test_Refinance_WhoseDrawCannotCoverTheOldDebt_IsRefused() public {
        uint256 oldId = _open(P, TEN30);
        _deposit(alice, 400_000e6); // a melt pays unit holders, never the ladder: the successor needs fresh resting cash
        _warpTo(t0 + 15 days);
        uint256 before = usdc.balanceOf(borrower);
        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        fin.refinance(oldId, P, TEN30, OpenBounds(1, 0, 0));
        assertEq(usdc.balanceOf(borrower), before, "and nothing was pulled from the borrower");
    }

    /// @notice `minPayout` binds the NET out, exactly as `refinance`'s NatSpec promises.
    /// @notice With one branch left, the net out is the only thing the netting can produce, so the bound is total.
    /// @dev A draw big enough to clear the old debt but leaving less than the floor must be refused BY NAME.
    function test_Refinance_MinPayout_BindsTheNetOut() public {
        uint256 oldId = _open(P, TEN30);
        _deposit(alice, 400_000e6);
        _warpTo(t0 + 15 days);
        uint256 before = usdc.balanceOf(borrower);

        MarketParams memory p = ace.idToMarketParams(id);
        uint256 pNew = 80_000e6;
        uint256 out = pNew - LoanMath.originationFee(pNew, TEN30, p.baseBps, p.minTenor) + read.earlyExitRefund(oldId) - P;
        assertGt(out, 0, "fixture: this refinance really does pay the borrower a net out");

        vm.prank(borrower);
        vm.expectRevert(PayoutBelowMin.selector);
        fin.refinance(oldId, pNew, TEN30, OpenBounds(out + 1, 0, 0));

        assertEq(usdc.balanceOf(borrower), before, "a refused refinance moves nothing");
        assertEq(read.debtOf(oldId), P, "and leaves the old loan whole");

        vm.prank(borrower);
        uint256 newId = fin.refinance(oldId, pNew, TEN30, OpenBounds(out, 0, 0));
        assertTrue(read.loan(oldId).closedAt != 0, "at the floor exactly the same refinance is admitted");
        assertFalse(read.loan(newId).closedAt != 0, "and its successor is live");
    }

    /// @notice The composition recovers the capability the top-up branch used to carry, in one transaction.
    /// @dev `multicall` delegatecalls, so both legs see the borrower and the borrower-only gate holds.
    function test_Refinance_UnderfundedDraw_IsRecoveredByMulticallRepayThenRefinance() public {
        uint256 oldId = _open(P, TEN30);
        _deposit(alice, 400_000e6);
        _warpTo(t0 + 15 days);
        uint256 before = usdc.balanceOf(borrower);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (oldId, TOPUP_AT15));
        calls[1] = abi.encodeCall(Ace.refinance, (oldId, P, TEN30, OpenBounds(0, 0, 0)));
        vm.prank(borrower);
        uint256 newId = abi.decode(ace.multicall(calls)[1], (uint256));

        assertGt(newId, oldId, "the successor opened");
        assertTrue(read.loan(oldId).closedAt != 0, "and the old loan closed");
        assertEq(before - usdc.balanceOf(borrower), TOPUP_AT15, "the borrower paid exactly the gap, and no more");
    }

    // ---- row 2: the melt ----

    /// @dev DELETED: `test_Control_TwoTickLoan_CarriesTwoClaims` and `test_PartialRepay_MeltsProRataAcrossTheFundedTicks`.
    /// @dev FORK C's ruling was that a partial repay retires every funded tick PRO RATA rather than lowest-first, because
    /// @dev the melt order decides who a repayment removes from default exposure. A loan holds ONE claim: there is no
    /// @dev order left to choose and no share to apportion, so the ruling is DISCHARGED STRUCTURALLY rather than tested.
    /// @dev The half that still has teeth is the exactness, which the fuzz row below keeps.

    /// @notice CONTROL: the loan carries its claim, and it opens level with the debt.
    function test_Control_ALoanCarriesItsClaim() public {
        uint256 loanId = _open(80_000e6, TEN30);
        assertEq(read.claimOf(id, loanId), 80_000e6, "the market funded the whole draw");
        assertEq(read.claimOf(id, loanId), read.debtOf(loanId), "and the claim opens level with the debt");
    }

    /// @notice The retirement is EXACT at any repay size, including the ones a flooring pass would round away.
    /// @dev Every wei repaid must retire a wei of claim, or the borrower's payment and the lender's book diverge.
    function testFuzz_PartialRepay_RetiresExactlyWhatWasPaid(uint256 amount) public {
        uint256 loanId = _open(80_000e6, TEN30);
        amount = bound(amount, 1, 80_000e6 - ace.idToMarketParams(id).minDebt); // a repay to dust is refused
        uint256 before = read.claimOf(id, loanId);
        vm.prank(borrower);
        ace.repay(loanId, amount);
        assertEq(before - read.claimOf(id, loanId), amount, "the claim retired must equal the quote paid, to the wei");
    }
}
