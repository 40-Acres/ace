// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LaunchFixture, IMintable} from "./LaunchFixture.sol";
import {ReenteringQuote} from "./ReenteringQuote.sol";
import {BadSig} from "../../src/ace/hub/Ace.sol";
import {MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {MockBlacklistERC20} from "../mocks/MockBlacklistERC20.sol";

/// @title LockAccountPins
/// @notice B4: the account's surface is exactly its four verbs; every route the lending review closed stays closed.
/// @notice L1-L3: a blacklisted beneficiary, a foreign title and a reentrant quote each fail to move a locked unit.
contract LockAccountPinsTest is LaunchFixture {
    // ---- B4: no backdoor selectors ----

    /// @notice None of these selectors exists on the account: each reverts with EMPTY data, which is a missing function.
    /// @dev Sent BY the beneficiary with well-formed arguments, so an existing but guarded function would revert with data.
    function test_B4_NoBackdoorSelectors() public {
        bytes[] memory calls = _backdoors();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory ret) = address(acct).call(calls[i]);
            assertFalse(ok, string.concat("a backdoor answered, call #", vm.toString(i)));
            assertEq(ret.length, 0, string.concat("a backdoor exists behind a guard, call #", vm.toString(i)));
        }
    }

    /// @notice The verbs and views the account no longer carries answer nothing: each reverts with EMPTY data, a missing function.
    /// @notice A withdraw off a live loan, the loan list, and the schedule reads, which the lock's `schedules` now answers.
    function test_TheDeletedVerbsAnswerNothing() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("withdrawFromLoan(uint256,uint256)", uint256(1), uint256(1)),
            abi.encodeWithSignature("loanCount()"),
            abi.encodeWithSignature("loanAt(uint256)", uint256(0)),
            abi.encodeWithSignature("scheduleId()"),
            abi.encodeWithSignature("schedule()")
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory ret) = address(acct).call(calls[i]);
            assertFalse(ok, string.concat("a deleted verb answered, call #", vm.toString(i)));
            assertEq(ret.length, 0, string.concat("a deleted verb exists behind a guard, call #", vm.toString(i)));
        }
    }

    /// @notice The account has no fallback and no receive: a bare call and a bare value transfer both fail.
    function test_B4_NoFallbackNoReceive() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(acct).call("");
        assertFalse(ok, "an empty call landed");
        vm.prank(alice);
        (ok,) = address(acct).call{value: 1}("");
        assertFalse(ok, "native value landed");
    }

    /// @notice A relayed credit-operator grant naming the account fails: it validates no signature, so no third party opens in its name.
    function test_B4_RelayedGrantNamingTheAccountReverts() public {
        vm.prank(stranger);
        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(address(acct), stranger, true, 0, _now() + 1 hours, new bytes(65));
    }

    /// @notice Only the beneficiary borrows or releases; the permissionless verbs pay only the account or the beneficiary.
    function test_B4_BeneficiaryOnlyVerbs() public {
        vm.startPrank(stranger);
        vm.expectRevert(LockAccount.NotBeneficiary.selector);
        acct.borrow(id, 1_000e18, _maxPrincipal(1_000e18), WEEK, _noBounds());
        vm.expectRevert(LockAccount.NotBeneficiary.selector);
        acct.release(1);
        vm.stopPrank();
    }

    /// @notice A borrow's payout goes to the beneficiary in the same call, and nothing of it stays in the account.
    function test_B4_PayoutGoesToTheBeneficiary() public {
        uint256 u = 1_000e18;
        uint256 p = _maxPrincipal(u);
        uint256 loanId = _borrow(u, p, WEEK);
        uint256 fee = read.loan(loanId).lastFee;
        assertEq(usdc.balanceOf(alice), p - fee, "the beneficiary has the payout");
        assertEq(usdc.balanceOf(address(acct)), 0, "the account kept none of it");
    }

    /// @notice A sweep pays the beneficiary whatever non-token asset sits in the account, and refuses the token and the titles.
    function test_B4_SweepPaysOnlyTheBeneficiary() public {
        usdc.mint(address(acct), 123e6);
        vm.prank(stranger);
        assertEq(acct.sweep(address(usdc)), 123e6, "the sweep reports what it moved");
        assertEq(usdc.balanceOf(alice), 123e6, "to the beneficiary");

        address titles = ace.POSITION_TITLE();
        vm.prank(stranger);
        vm.expectRevert(LockAccount.LockedAsset.selector);
        acct.sweep(address(token));
        vm.prank(stranger);
        vm.expectRevert(LockAccount.LockedAsset.selector);
        acct.sweep(titles);
    }

    /// @notice The approval a borrow grants is exactly the pledge, and the pull consumes it whole.
    function test_B4_ExactApprovalConsumed() public {
        uint256 u = 1_000e18;
        _borrow(u, _maxPrincipal(u), WEEK);
        assertEq(token.allowance(address(acct), address(pm)), 0, "an allowance outlived the borrow");
    }

    // ---- L1: a blacklisted beneficiary ----

    /// @notice A quote that blacklists the beneficiary cannot hold the units back: reclaim pays the account, not her.
    function test_L1_BlacklistedBeneficiaryReclaimStillBooks() public {
        MockBlacklistERC20 bq = new MockBlacklistERC20("Blacklist USD", "BUSD", 6);
        bytes32 m = _market(address(bq), alt);
        _restIn(m, address(bq), alt, CASH);
        uint256 u = 1_000e18;
        vm.prank(alice);
        uint256 loanId = acct.borrow(m, u, _maxPrincipal(u), WEEK, _noBounds());

        bq.setBlacklisted(alice, true);
        uint256 debt = read.debtOf(loanId);
        IMintable(address(bq)).mint(payer, debt);
        vm.startPrank(payer);
        bq.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();

        vm.prank(stranger);
        assertEq(acct.reclaim(loanId), u, "every unit came home");
        assertEq(acct.pledged(), 0, "the pledge is retired");
        assertEq(token.balanceOf(address(acct)), ALLOC, "the units are in the account");

        vm.expectRevert(bytes("blacklisted"));
        acct.sweep(address(bq)); // the refund waits in the account; that is the beneficiary's to unblock
    }

    /// @notice A quote that refuses the ACCOUNT cannot hold the units back: they come home and the pledge retires.
    /// @notice The refused quote credit stays owed in the hub, and a later reclaim collects it once the refusal lifts.
    function test_ReclaimUnitsComeHomeWhenTheQuoteLegReverts() public {
        MockBlacklistERC20 bq = new MockBlacklistERC20("Blacklist USD", "BUSD", 6);
        bytes32 m = _market(address(bq), alt);
        _restIn(m, address(bq), alt, CASH);
        uint256 u = 1_000e18;
        vm.prank(alice);
        uint256 loanId = acct.borrow(m, u, _maxPrincipal(u), WEEK, _noBounds());
        uint256 debt = read.debtOf(loanId);
        IMintable(address(bq)).mint(payer, debt);
        vm.startPrank(payer);
        bq.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        uint256 refund = read.quoteOwedOf(loanId, address(acct));
        assertGt(refund, 0, "fixture: an early repay refunds part of the fee");

        bq.setBlacklisted(address(acct), true);
        vm.prank(stranger);
        assertEq(acct.reclaim(loanId), u, "the units came home past a refusing quote");
        assertEq(acct.pledged(), 0, "the pledge retired");
        assertEq(token.balanceOf(address(acct)), ALLOC, "every unit is in the account");
        assertEq(read.quoteOwedOf(loanId, address(acct)), refund, "the refused refund is still owed, not lost");

        bq.setBlacklisted(address(acct), false);
        assertEq(acct.reclaim(loanId), 0, "the second reclaim lands no units");
        assertEq(read.quoteOwedOf(loanId, address(acct)), 0, "it collected the refund");
        assertEq(bq.balanceOf(address(acct)), refund, "into the account, for the sweep");
        assertEq(acct.spent(), 0, "nothing was booked as forfeited");
    }

    // ---- L2: a foreign title ----

    /// @notice A title pushed in from outside books nothing: reclaim ignores it.
    function test_L2_ForeignTitleBooksNothing() public {
        uint256 u = 1_000e18;
        token.mint(bob, u);
        vm.startPrank(bob);
        token.approve(address(pm), u);
        uint256 foreign = ace.open(id, u, _maxPrincipal(u), WEEK, bob, _noBounds());
        IERC721(ace.POSITION_TITLE()).transferFrom(bob, address(acct), foreign);
        vm.stopPrank();
        assertEq(ace.borrowerOf(foreign), address(acct), "fixture: the account now holds the foreign title");

        (uint256 total, uint256 rel, uint256 cap) = (acct.totalAllocation(), acct.releasable(), acct.capacity(uint64(_now() + WEEK)));
        _repayAll(foreign);
        assertEq(acct.reclaim(foreign), 0, "reclaim acted on a loan outside its ledger");
        assertEq(token.balanceOf(address(acct)), ALLOC, "no unit of the foreign loan reached the account");
        assertEq(acct.totalAllocation(), total, "the allocation moved");
        assertEq(acct.releasable(), rel, "releasable moved");
        assertEq(acct.capacity(uint64(_now() + WEEK)), cap, "capacity moved");
    }

    /// @notice Reclaim's quote leg acts only on the account's own ledger: a foreign loan's credit is never claimed.
    function test_ReclaimLeavesAForeignLoansQuoteAlone() public {
        uint256 u = 1_000e18;
        token.mint(bob, u);
        vm.startPrank(bob);
        token.approve(address(pm), u);
        uint256 foreign = ace.open(id, u, _maxPrincipal(u), WEEK, bob, _noBounds());
        IERC721(ace.POSITION_TITLE()).transferFrom(bob, address(acct), foreign);
        vm.stopPrank();
        _repayAll(foreign);
        uint256 owed = read.quoteOwedOf(foreign, address(acct));
        assertGt(owed, 0, "fixture: the foreign loan credited the account a refund");
        acct.reclaim(foreign);
        assertEq(read.quoteOwedOf(foreign, address(acct)), owed, "reclaim claimed a foreign loan's quote");
        assertEq(usdc.balanceOf(address(acct)), 0, "a foreign refund reached the account");
    }

    // ---- L3: a reentrant quote ----

    /// @notice A quote that calls back into the account mid-payout reverts the borrow on the account's own guard.
    function test_L3_ReentrantQuoteRevertsTheBorrow() public {
        ReenteringQuote rq = new ReenteringQuote();
        bytes32 m = _market(address(rq), alt);
        _restIn(m, address(rq), alt, CASH);
        rq.arm(address(acct), abi.encodeCall(LockAccount.release, (1)));
        uint256 u = 1_000e18;
        uint256 p = _maxPrincipal(u);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        acct.borrow(m, u, p, WEEK, _noBounds());
    }

    /// @notice The same quote calling back during a reclaim's refund trips the guard INSIDE the best-effort quote leg.
    /// @notice The units still come home and the pledge retires; the refund stays owed in the hub rather than landing.
    function test_L3_ReentrantQuoteCannotHoldTheReclaimBack() public {
        ReenteringQuote rq = new ReenteringQuote();
        bytes32 m = _market(address(rq), alt);
        _restIn(m, address(rq), alt, CASH);
        uint256 u = 1_000e18;
        vm.prank(alice);
        uint256 loanId = acct.borrow(m, u, _maxPrincipal(u), WEEK, _noBounds());
        uint256 debt = read.debtOf(loanId);
        rq.mint(payer, debt);
        vm.startPrank(payer);
        rq.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();

        uint256 refund = read.quoteOwedOf(loanId, address(acct));
        assertGt(refund, 0, "fixture: an early repay refunds part of the fee, so the quote leg moves a token");
        rq.arm(address(acct), abi.encodeCall(LockAccount.reclaim, (loanId)));
        assertEq(acct.reclaim(loanId), u, "the units came home");
        assertEq(acct.pledged(), 0, "the pledge retired");
        assertEq(read.quoteOwedOf(loanId, address(acct)), refund, "the reentered refund stayed owed, not lost and not doubled");
        assertEq(rq.balanceOf(address(acct)), 0, "no refund landed through the reentry");

        rq.arm(address(0), ""); // the quote stops calling back
        assertEq(acct.reclaim(loanId), 0, "the later claim lands no units: they were booked once");
        assertEq(read.quoteOwedOf(loanId, address(acct)), 0, "the later claim collected the refund");
        assertEq(rq.balanceOf(address(acct)), refund, "and paid it out, whole, to the account");
        assertEq(acct.pledged(), 0, "nothing re-booked");
        assertEq(token.balanceOf(address(acct)), ALLOC, "no unit moved twice");
    }

    function _backdoors() internal view returns (bytes[] memory c) {
        OpenBounds memory b = _noBounds();
        c = new bytes[](22);
        c[0] = abi.encodeWithSignature("multicall(bytes[])", new bytes[](0));
        c[1] = abi.encodeWithSignature("refinance(uint256,uint256,uint64,(uint256,uint256,uint64))", uint256(1), uint256(1), WEEK, b);
        c[2] = abi.encodeWithSignature(
            "refinanceTo((uint256,bytes32,uint256,uint64,(uint256,uint256,uint64),uint256,address))", MigrateArgs(1, id, 1, WEEK, b, 0, address(0))
        );
        c[3] = abi.encodeWithSignature("setAutoRefinance(uint256,uint64,uint16,uint16)", uint256(1), WEEK, uint16(0), uint16(0));
        c[4] = abi.encodeWithSignature("setCreditOperator(address,bool)", stranger, true);
        c[5] = abi.encodeWithSignature(
            "setCreditOperatorWithSig(address,address,bool,uint256,uint256,bytes)", address(acct), stranger, true, uint256(0), uint256(0), ""
        );
        c[6] = abi.encodeWithSignature(
            "postOrder(bytes32,uint256,uint256,uint256,uint256,uint64,uint64)", id, uint256(1), uint256(1), uint256(1), uint256(1), WEEK, uint64(0)
        );
        c[7] = abi.encodeWithSignature("approve(address,uint256)", stranger, uint256(1));
        c[8] = abi.encodeWithSignature("approve(address,address,uint160,uint48)", address(token), stranger, uint160(1), uint48(0));
        c[9] = abi.encodeWithSignature("setApprovalForAll(address,bool)", stranger, true);
        c[10] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(acct), stranger, uint256(1));
        c[11] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(acct), stranger, uint256(1));
        c[12] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", address(acct), stranger, uint256(1), "");
        c[13] = abi.encodeWithSignature("transfer(address,uint256)", stranger, uint256(1));
        c[14] = abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), "");
        c[15] = abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", stranger, stranger, uint256(1), "");
        c[16] = abi.encodeWithSignature("execute(address,uint256,bytes)", stranger, uint256(0), "");
        c[17] = abi.encodeWithSignature("withdrawCollateral(uint256,uint256,address)", uint256(1), uint256(1), stranger);
        c[18] = abi.encodeWithSignature("claimOwed(uint256,address)", uint256(1), stranger);
        c[19] = abi.encodeWithSignature("claimOwed(uint256,address,address)", uint256(1), stranger, stranger);
        c[20] = abi.encodeWithSignature(
            "permit(address,uint256,uint256,uint8,bytes32,bytes32)", stranger, uint256(1), uint256(0), uint8(0), bytes32(0), bytes32(0)
        );
        c[21] = abi.encodeWithSignature("fillOrder(uint256,uint256,uint256)", uint256(1), uint256(1), uint256(1));
    }
}
