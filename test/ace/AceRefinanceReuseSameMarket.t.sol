// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {IRollPolicy} from "../../src/interfaces/IRollPolicy.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {NoPolicy, YesPolicy} from "../utils/RollPolicyMocks.sol";

/// @title AceRefinanceReuseSameMarketTest
/// @notice A refinance reuses the retiring claim only inside the loan's own market, and only on its lender's roll policy's yes.
/// @notice A market a stranger builds naming the same lender reuses nothing and asks nobody: it draws the whole principal, or refuses `InsufficientCash`.
/// @notice Anyone may create a market naming any lender, so that lender's resting cash is its only consent to the market.
/// @dev Reasoning: the design record; the defect is HIGH 1 of audit/findings/manual-renewal-code-review.md.
contract AceRefinanceReuseSameMarketTest is ExtendRig {
    YesPolicy internal yes;

    function setUp() public override {
        super.setUp();
        _deposit(id, alice, 3 * P);
        yes = new YesPolicy();
        _setPolicy(alice, address(yes));
    }

    /// @dev A market a stranger builds naming `alice` on the rig's pair and record, at a weaker coverage multiple: another id, resting nothing.
    function _strangersMarket() internal returns (bytes32 b) {
        MarketParams memory p = _params(alice);
        p.minCoverageWad = 1.2e18;
        vm.prank(stranger);
        b = ace.createMarket(p);
    }

    function _args(uint256 loanId, bytes32 dst, uint256 principal) internal pure returns (MigrateArgs memory) {
        return MigrateArgs(loanId, dst, principal, TEN7, OpenBounds(0, 0, 0), 0, address(0));
    }

    /// @dev The borrower's refinance as a low-level call, so a hub that lands it is reported by name rather than as a missing revert.
    function _try(MigrateArgs memory m) internal returns (bool ok, bytes memory ret) {
        vm.prank(borrower);
        (ok, ret) = address(ace).call(abi.encodeCall(Ace.refinanceTo, (m)));
    }

    /// @notice A stranger's market naming the lender, resting nothing, cannot take the loan on the reused claim: it refuses `InsufficientCash`.
    /// @dev A 28-day loan re-termed at once to 7 days: its unearned escrow covers the new fee, so a reuse would draw nothing fresh.
    function test_AStrangersMarketNamingTheLenderWithNoCashRefusesInsufficientCash() public {
        uint256 loanId = _open(P, MAX_T, 5000);
        bytes32 b = _strangersMarket();
        assertEq(_mp(b).lender, alice, "PREMISE: the stranger's market names the loan's lender");
        assertEq(ace.restingOf(b), 0, "PREMISE: the lender rests nothing there");
        (bool ok, bytes memory ret) = _try(_args(loanId, b, P));
        assertFalse(ok, "the claim was reused: a market the lender never funded took its loan");
        assertEq(ret, abi.encodeWithSelector(InsufficientCash.selector), "refused for want of the lender's cash");
        assertTrue(ace.isLiveLoan(loanId), "the loan stays in its own market");
    }

    /// @notice Cash the lender rests in that market funds the move whole: the old claim is repaid, not reused, and the policy is never asked.
    function test_AStrangersMarketTheLenderFundsDrawsTheWholePrincipalAndAsksNobody() public {
        uint256 loanId = _open(P, TEN7, 5000);
        bytes32 b = _strangersMarket();
        _deposit(b, alice, 2 * P);
        uint256 claim = read.claimOf(id, loanId);
        uint256 principal = P + P / 2;
        uint256 cash0 = ace.restingOf(b);
        (,, uint256 owed0) = read.lenderPools(alice, address(usdc));
        vm.expectCall(address(yes), abi.encodePacked(IRollPolicy.admitsExtension.selector), 0);
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(_args(loanId, b, principal));
        assertEq(ace.restingOf(b), cash0 - principal, "the destination lends the whole principal from its resting cash");
        (,, uint256 owed1) = read.lenderPools(alice, address(usdc));
        assertEq(owed1, owed0 + claim + LoanMath.tickCut(_fee(principal, TEN7)), "the old claim is repaid to the lender whole");
        assertEq(read.claimOf(b, newId), principal, "the successor's claim is its principal");
        _assertSolventOver(id, b, alice);
    }

    /// @notice The loan's own market on a yes still reuses the claim: the zero-fresh re-term lands with nothing resting, asking the policy once.
    function test_TheOwnMarketWithAYesStillReusesTheClaim() public {
        uint256 loanId = _open(P, MAX_T, 5000);
        _drain(id, alice);
        (,, uint256 owed0) = read.lenderPools(alice, address(usdc));
        vm.expectCall(address(yes), abi.encodePacked(IRollPolicy.admitsExtension.selector), 1);
        (bool ok,) = _try(_args(loanId, id, P));
        assertTrue(ok, "the own-market re-term lands on the reused claim");
        assertEq(ace.restingOf(id), 0, "it drew nothing fresh");
        (,, uint256 owed1) = read.lenderPools(alice, address(usdc));
        assertEq(owed1, owed0 + LoanMath.tickCut(_fee(P, TEN7)), "owed takes only the new tick cut: the claim was reused, not repaid");
        _assertSolvent();
    }

    /// @notice The loan's own market on a no draws the whole principal fresh: the old claim is repaid to the lender whole.
    function test_TheOwnMarketWithANoDrawsTheWholePrincipal() public {
        _setPolicy(alice, address(new NoPolicy()));
        uint256 loanId = _open(P, MAX_T, 5000);
        uint256 claim = read.claimOf(id, loanId);
        uint256 cash0 = ace.restingOf(id);
        (,, uint256 owed0) = read.lenderPools(alice, address(usdc));
        (bool ok,) = _try(_args(loanId, id, P));
        assertTrue(ok, "PREMISE: the re-term lands on resting cash");
        assertEq(ace.restingOf(id), cash0 - P, "a no draws the whole principal from resting cash");
        (,, uint256 owed1) = read.lenderPools(alice, address(usdc));
        assertEq(owed1, owed0 + claim + LoanMath.tickCut(_fee(P, TEN7)), "and the old claim is repaid to the lender whole");
        _assertSolvent();
    }
}
