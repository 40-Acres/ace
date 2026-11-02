// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BufferBelowMin, NotBorrower} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan} from "../../src/ace/hub/Types.sol";
import {ExtendRig} from "../utils/ExtendRig.sol";
import {YesPolicy} from "../utils/RollPolicyMocks.sol";

/// @title AceExtendHardeningTest
/// @notice Rows an audit of the extension suites found missing: the draw counter, the previews' callers, the admitted figure, the buffer leg.
/// @notice Every row has its control in the same body, so a refusal is the named leg's and never an earlier one's.
/// @dev Reasoning: the design record (5, 6),.
contract AceExtendHardeningTest is ExtendRig {
    function setUp() public override {
        super.setUp();
        _setPolicy(alice, address(new YesPolicy()));
        _deposit(id, alice, 3 * P);
    }

    function _draws() internal view returns (uint256) {
        return read.marketState(id).drawCount;
    }

    /* ============================== the draw counter (step-2 ruling 5) ============================== */

    /// @notice Every landed extension bumps the market's draw counter exactly once: the holder's, and the granted lender's.
    function test_EveryExtensionBumpsTheDrawCounterOnce() public {
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        uint256 d0 = _draws();
        uint256 snap = vm.snapshotState();
        _extend(borrower, loanId);
        assertEq(_draws(), d0 + 1, "the holder's extension bumped the counter once");
        vm.revertToState(snap);
        _extend(alice, loanId);
        assertEq(_draws(), d0 + 1, "the granted lender's extension bumped it once");
    }

    /* ============================== the previews' callers (step-2 ruling 6) ============================== */

    /// @notice `tryExtend` answers for the caller it NAMES, never its sender: a keeper asks for the holder and for the granted lender.
    function test_ThePreviewAnswersForTheNamedCallerNotItsSender() public {
        uint256 loanId = _open(P, TEN7, 5000);
        vm.prank(borrower);
        ace.setCreditOperator(alice, true);
        _warpBy(1 days);
        uint256 fee = _feeNow(loanId);
        vm.startPrank(keeper);
        (bool hOk, bytes4 hWhy, uint256 hFee) = ace.tryExtend(loanId, 0, "", borrower);
        (bool lOk,, uint256 lFee) = ace.tryExtend(loanId, 0, "", alice);
        vm.stopPrank();
        assertTrue(hOk && hWhy == bytes4(0), "a keeper asking for the holder hears the holder's yes");
        assertEq(hFee, fee, "at the extension's fee");
        assertTrue(lOk, "and for the granted lender, the lender's yes");
        vm.prank(borrower);
        (bool sOk, bytes4 sWhy,) = ace.tryExtend(loanId, 0, "", stranger);
        assertFalse(sOk, "the holder asking for a stranger hears the stranger's no");
        assertEq(sWhy, NotBorrower.selector, "named as the caller leg's");
        assertEq(_extend(alice, loanId), lFee, "CONTROL: the lender's verb then charges the fee its preview named");
    }

    // the fold-preview row went with the fold

    /* ============================== the admitted figure ============================== */

    /// @notice An extension is admitted on the debt AS IT STANDS: a record between the loan's trigger and the trigger of its debt plus the fee admits it.
    function test_AnExtensionIsAdmittedOnTheDebtAsItStands() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        Loan memory l = read.loan(loanId);
        uint256 lowTrig = LoanMath.triggerPrice(l.debt, l.collateralUnits, K, S);
        uint256 highTrig = LoanMath.triggerPrice(l.debt + _feeNow(loanId), l.collateralUnits, K, S);
        uint256 mid = (lowTrig + highTrig) / 2;
        assertTrue(lowTrig < mid && mid < highTrig, "PREMISE: the fee would lift the trigger past a record between the two");
        rec.setMinPrice(mid);
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "the extension is admitted on the debt as it stands");
        assertEq(why, bytes4(0), "with no reason");
        _extend(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "and lands at the same record");
    }

    // the lot-on-the-extended-debt's-requirement row went with dues: a cash extension's debt is the debt the open already lined

    /* ============================== the caller's buffer ============================== */

    /// @notice `minBufferWad` binds the holder's extension: one wad over the loan's buffer refuses `BufferBelowMin`; exactly it lands.
    function test_TheCallersBufferBindsTheExtension() public {
        uint256 loanId = _open(P, TEN7, 5000);
        _warpBy(1 days);
        Loan memory l = read.loan(loanId);
        uint256 trig = LoanMath.triggerPrice(l.debt, l.collateralUnits, K, S);
        uint256 buf = FullMath.mulDiv(par - trig, 1e18, par);
        _fund(borrower, _fee(l.debt, TEN7));
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, buf + 1, "", borrower);
        assertFalse(ok, "one wad over the loan's buffer is refused");
        assertEq(why, BufferBelowMin.selector, "by the buffer leg");
        vm.prank(borrower);
        vm.expectRevert(BufferBelowMin.selector);
        ace.extend(loanId, buf + 1, "");
        vm.prank(borrower);
        ace.extend(loanId, buf, "");
        assertEq(read.loan(loanId).expiry, _now() + TEN7, "CONTROL: exactly the buffer lands");
    }
}
