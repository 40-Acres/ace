// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {BalancePolicy, LiveLoanPolicy} from "../utils/RollPolicyMocks.sol";

/// @title AceExtendAsksFirstTest
/// @notice EVERY VERB ASKS THE LENDER'S POLICY BEFORE ANY WRITE (review E-11's checklist, CEI): the policy is a foreign frame.
/// @notice Each row installs a policy that consents only while the state the verb is about to write still reads as before.
/// @notice So an ask moved after a write turns the verb's yes into a no, and the row's landing assertion fails.
/// @dev Two verbs ask now, `refinanceTo` and `extend`: `forceClose` only settles, so it asks no policy at all.
/// @dev Reasoning: docs/ai/audit/findings/extend-in-place-lending-review.md, code-logic checklist row "CEI".
contract AceExtendAsksFirstTest is ExtendRig {
    function setUp() public override {
        super.setUp();
        _deposit(id, alice, P + P / 10);
    }

    /// @notice `refinanceTo` asks before it closes the retiring loan: a re-term in the loan's own market reuses the claim only on that yes.
    function test_RefinanceTo_AsksBeforeTheClose() public {
        _setPolicy(alice, address(new LiveLoanPolicy(address(ace))));
        _deposit(id, alice, P);
        uint256 loanId = _open(P, TEN7, 5000);
        uint256 claim = read.claimOf(id, loanId);
        uint256 principal = P + P / 2;
        uint256 cash0 = ace.restingOf(id);
        vm.prank(borrower);
        ace.refinanceTo(MigrateArgs(loanId, id, principal, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        assertEq(ace.restingOf(id), cash0 - (principal - claim), "the policy saw the retiring loan live and the claim was reused");
    }

    /// @notice A cash `extend` asks before it pulls the fee: the caller's and the hub's balances are still the pre-call ones inside the ask.
    function test_CashExtend_AsksBeforeThePull() public {
        BalancePolicy p = new BalancePolicy();
        _setPolicy(alice, address(p));
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        _fund(borrower, _fee(read.debtOf(loanId), TEN7));
        p.expect(IERC20(address(usdc)), borrower, address(ace));
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "the policy saw no fee moved yet and consented");
    }
}
