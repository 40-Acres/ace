// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {InsufficientCash, WithdrawalExceedsCollateral} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {NoPolicy, YesPolicy} from "../utils/RollPolicyMocks.sol";

/// @title AceRefinanceToSameLenderTest
/// @notice A `refinanceTo` reuses the retiring claim only into the loan's OWN market, and only on its lender's policy's yes (review E-2, as amended).
/// @notice `recycle = (own market && policy yes) ? min(claim, principal) : 0`: anything else draws the whole principal, or refuses `InsufficientCash`.
/// @notice The same lender's sibling and another lender's market both reuse nothing; an over-asked withdrawal leg still refuses by name (D-10).
/// @dev Reasoning: the design record (E-2), amended by.
contract AceRefinanceToSameLenderTest is ExtendRig {
    function setUp() public override {
        super.setUp();
        _deposit(id, alice, 3 * P);
    }

    function _to(uint256 loanId, bytes32 dst, uint256 principal, uint64 tenor) internal returns (uint256 newId) {
        vm.prank(borrower);
        newId = ace.refinanceTo(MigrateArgs(loanId, dst, principal, tenor, OpenBounds(0, 0, 0), 0, address(0)));
    }

    /// @notice A sibling market of the same lender, even on its policy's yes, reuses nothing: exact pool, cash and payout figures.
    /// @dev What a same-lender move is measured against, held in memory so the row stays inside the legacy stack.
    struct Before {
        uint256 claim;
        uint256 escrow;
        uint256 cashSrc;
        uint256 cashDst;
        uint256 resting;
        uint256 lent;
        uint256 owed;
        uint256 revenue;
        uint256 balance;
    }

    function test_ASameLenderSiblingWithAYesReusesNothing() public {
        YesPolicy yes = new YesPolicy();
        _setPolicy(alice, address(yes));
        bytes32 sib = _siblingOf(alice, 2 * P);
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 principal = P + P / 2;
        uint256 fee = LoanMath.originationFee(principal, TEN7, BASE + 10, TEN7);
        Before memory b;
        (b.claim, b.escrow) = (read.claimOf(id, loanId), read.feeEscrowOf(loanId));
        (b.cashSrc, b.cashDst) = (ace.restingOf(id), ace.restingOf(sib));
        (b.resting, b.lent, b.owed) = read.lenderPools(alice, address(usdc));
        (b.revenue, b.balance) = (read.protocolRevenue(sib), usdc.balanceOf(borrower));

        vm.expectCall(address(yes), abi.encodePacked(IRollPolicy.admitsExtension.selector), 0);
        uint256 newId = _to(loanId, sib, principal, TEN7);

        assertEq(ace.restingOf(sib), b.cashDst - principal, "the destination draws the whole principal fresh");
        assertEq(ace.restingOf(id), b.cashSrc, "the source's resting cash is untouched");
        (uint256 resting1, uint256 lent1, uint256 owed1) = read.lenderPools(alice, address(usdc));
        assertEq(resting1, b.resting - principal, "the pooled resting falls by the whole principal");
        assertEq(lent1, b.lent - b.claim + principal, "lent swaps the old claim for the new one");
        assertEq(owed1, b.owed + b.claim + LoanMath.tickCut(fee), "owed takes the old claim back whole, plus the new tick cut: nothing was reused");
        assertEq(read.claimOf(sib, newId), principal, "the successor's claim is its principal");
        assertEq(read.feeEscrowOf(newId), LoanMath.escrowCut(fee), "its escrow is funded");
        assertEq(read.protocolRevenue(sib), b.revenue + LoanMath.protocolCut(fee), "the destination books the protocol cut");
        assertEq(usdc.balanceOf(borrower), b.balance + principal - fee + b.escrow - P, "the net out is paid in the call");
        _assertSolventOver(id, sib, alice);
    }

    /// @notice E-2: the lender's own market with a policy NO draws the whole principal from resting cash; the old claim is repaid whole.
    function test_TheOwnMarketWithANoDrawsTheWholePrincipal() public {
        _setPolicy(alice, address(new NoPolicy()));
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 claim = read.claimOf(id, loanId);
        uint256 principal = P + P / 2;
        uint256 fee = _fee(principal, TEN7);
        uint256 cash0 = ace.restingOf(id);
        (,, uint256 owed0) = read.lenderPools(alice, address(usdc));
        _to(loanId, id, principal, TEN7);
        assertEq(ace.restingOf(id), cash0 - principal, "a no draws the whole principal from resting cash");
        (,, uint256 owed1) = read.lenderPools(alice, address(usdc));
        assertEq(owed1, owed0 + claim + LoanMath.tickCut(fee), "and the old claim is repaid to the lender whole");
        _assertSolvent();
    }

    /// @notice E-2: a no with nothing resting refuses `InsufficientCash`; the same zero-fresh re-term lands on a yes.
    /// @dev A 28-day loan re-termed at once to 7 days: its unearned escrow covers the new fee, so the yes draws nothing fresh.
    function test_TheOwnMarketWithANoAndNoCashRefusesInsufficientCash() public {
        uint256 loanId = _open(P, MAX_T, 5000);
        _drain(id, alice);
        assertEq(ace.restingOf(id), 0, "PREMISE: nothing rests");
        uint256 snap = vm.snapshotState();
        _setPolicy(alice, address(new YesPolicy()));
        _to(loanId, id, P, TEN7);
        assertEq(ace.restingOf(id), 0, "CONTROL: on a yes the zero-fresh re-term lands, drawing nothing");
        vm.revertToState(snap);
        _setPolicy(alice, address(new NoPolicy()));
        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinanceTo(MigrateArgs(loanId, id, P, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
    }

    /// @notice A lender with no policy is a no: the whole principal is drawn, and the old claim is repaid to the lender whole.
    /// @dev No call-count leg: `Probe.askBool` refuses a codeless target without calling it, so the zero test is not observable here.
    function test_NoPolicyDrawsTheWholePrincipal() public {
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 claim = read.claimOf(id, loanId);
        uint256 principal = P + P / 2;
        uint256 cash0 = ace.restingOf(id);
        (,, uint256 owed0) = read.lenderPools(alice, address(usdc));
        _to(loanId, id, principal, TEN7);
        assertEq(ace.restingOf(id), cash0 - principal, "a zero policy draws the whole principal");
        (,, uint256 owed1) = read.lenderPools(alice, address(usdc));
        assertEq(owed1, owed0 + claim + LoanMath.tickCut(_fee(principal, TEN7)), "and the old claim is repaid to the lender whole");
    }

    /// @notice Another lender's market reuses nothing and asks nobody: the destination lends the whole principal, the source is repaid whole.
    function test_AnotherLendersMarketReusesNothingAndAsksNothing() public {
        YesPolicy yes = new YesPolicy();
        _setPolicy(alice, address(yes));
        bytes32 other = _siblingOf(bob, 2 * P);
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 claim = read.claimOf(id, loanId);
        uint256 principal = P + P / 2;
        uint256 cash0 = ace.restingOf(other);
        (,, uint256 owed0) = read.lenderPools(alice, address(usdc));
        vm.expectCall(address(yes), abi.encodePacked(IRollPolicy.admitsExtension.selector), 0);
        _to(loanId, other, principal, TEN7);
        assertEq(ace.restingOf(other), cash0 - principal, "the other lender lends the whole principal");
        (,, uint256 owed1) = read.lenderPools(alice, address(usdc));
        assertEq(owed1, owed0 + claim, "and the source lender is repaid its claim whole");
    }

    /// @notice D-10: an over-asked withdrawal leg on a same-lender re-term refuses `WithdrawalExceedsCollateral` by name, never a panic.
    function test_AnOverAskedWithdrawalRefusesByNameNotAPanic() public {
        _setPolicy(alice, address(new YesPolicy()));
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 units = read.loan(loanId).collateralUnits;
        vm.prank(borrower);
        vm.expectRevert(WithdrawalExceedsCollateral.selector);
        ace.refinanceTo(MigrateArgs(loanId, id, P + P / 2, TEN7, OpenBounds(0, 0, 0), units + 1, borrower));
    }
}
