// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVaultExitsRig, ICuratorVaultExits} from "./CuratorVaultExitsRig.sol";

/// @title CuratorVaultExitsHardening
/// @notice The exit surface where its branches meet: `maxClaim` against the claim wherever exitable binds beside a fee or a donation.
/// @notice Also the requests' hold each verb leaves, the drain's refusal of a borrow, and the last holders out.
contract CuratorVaultExitsHardeningTest is CuratorVaultExitsRig {
    uint256 internal constant GIFT = 1_000e6;

    function _drain(CuratorVault v, address by, bool on) internal {
        vm.prank(by);
        _x(v).setDrain(on);
    }

    /// @dev A fee vault: two LPs, `lent` drawn, the open's fee collected, then a gift vested unsynced, so a fee is pending.
    function _feeLent(uint256 lent) internal returns (CuratorVault v, uint256 loanId) {
        v = _vault(2000);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        loanId = _open(lent);
        _crank(v, loanId, T2, 0);
        _warpBy(VEST_W);
        v.crank();
        _gift(v, GIFT);
        v.crank();
        _warpBy(VEST_W);
        assertGt(v.pendingFeeShares(), 0, "PREMISE: a fee is pending on the vested gift");
    }

    // ---- maxClaim against the claim ----

    /// @notice A DONATION DOES NOT STOP THE REPLAY WHERE EXITABLE BINDS: the last requester's answer prices the release and takes all of exitable.
    function test_MaxClaim_ADonationStandingTheLastRequestersAnswerTakesTheWholePot() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _crank(v, _open(6_000e6), T2, 0);
        _warpBy(VEST_W);
        v.crank();
        _gift(v, GIFT);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a gain is vesting");
        vm.prank(alice);
        v.transfer(address(v), 1e12);
        uint256 own = v.balanceOf(alice);
        _request(v, alice, own);
        uint256 pot = _exitable(v);
        uint256 m = _x(v).maxClaim(alice);
        assertLt(m, own, "PREMISE: exitable covers less than the last request");
        assertApproxEqAbs(_claim(v, alice, m), pot, 2, "the last requester's claim of maxClaim beside a donation did not take all of exitable");
        assertEq(v.unvested(), 0, "the donation stopped the release");
    }

    /// @notice A PENDING FEE PRICES `maxClaim` AS THE CLAIM PAYS: its answer, over the supply the claim's own fee leaves, takes all of exitable.
    function test_MaxClaim_APendingFeeWhereThePotBindsItsAnswerTakesTheWholePot() public {
        (CuratorVault v,) = _feeLent(15_000e6);
        uint256 own = v.balanceOf(bob);
        _request(v, bob, own);
        uint256 pot = _exitable(v);
        uint256 m = _x(v).maxClaim(bob);
        assertLt(m, own, "PREMISE: exitable covers less than the request");
        assertApproxEqAbs(_claim(v, bob, m), pot, 2, "the claim of maxClaim under a pending fee did not take all of exitable");
        assertEq(v.pendingFeeShares(), 0, "PREMISE: the claim collected the fee");
    }

    /// @notice THE CLAIM'S OWN FEE SHARES NO LONGER STOP THE RELEASE WHERE EXITABLE BINDS: the sole requester's `maxClaim` prices it and takes it all.
    function test_MaxClaim_ASoleRequesterUnderAPendingFeeReleasesAndTakesTheWholePot() public {
        CuratorVault v = _vault(2000);
        _lpDeposit(v, alice, 2 * SEED);
        _crank(v, _open(12_000e6), T2, 0);
        _warpBy(VEST_W);
        v.crank();
        uint256 fee0 = v.balanceOf(curator); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(curator);
        v.transfer(alice, fee0);
        _gift(v, 2 * GIFT);
        v.crank();
        _warpBy(VEST_W / 2);
        assertGt(v.pendingFeeShares(), 0, "PREMISE: a fee is pending on the vested half");
        assertGt(v.unvested(), 0, "PREMISE: the other half still vests");
        uint256 all = v.balanceOf(alice);
        assertEq(all, v.totalSupply(), "PREMISE: alice holds every share");
        _request(v, alice, all);
        uint256 pot = _exitable(v);
        uint256 m = _x(v).maxClaim(alice);
        assertLt(m, all, "PREMISE: exitable covers less than the request");
        assertApproxEqAbs(_claim(v, alice, m), pot, 2, "the sole requester's claim of maxClaim did not take all of exitable");
        assertGt(v.balanceOf(curator), 0, "PREMISE: the claim minted the curator in");
        assertEq(v.unvested(), 0, "the claim did not release the pile beside the curator's fee shares");
    }

    /// @notice FOR ANY FEE, DONATION, LENT BOOK, GAIN AND HOLDER MIX, a claim of `maxClaim` lands and takes either the whole request or all of exitable.
    function testFuzz_MaxClaim_ItsAnswerPaysAndTakesTheWholeRequestOrThePot(uint256 seed) public {
        CuratorVault v = _vault(seed % 2 == 0 ? 0 : 2000);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 lent = bound(uint256(keccak256(abi.encode(seed, 1))), 0, 19_000e6);
        if (lent >= 100e6) _crank(v, _open(lent), T2, 0);
        _warpBy(VEST_W);
        v.crank();
        uint256 gift = bound(uint256(keccak256(abi.encode(seed, 2))), 0, 3 * GIFT);
        if (gift >= 100e6) {
            _gift(v, gift);
            v.crank();
        }
        _warpBy(bound(uint256(keccak256(abi.encode(seed, 3))), 0, VEST_W));
        uint256 mode = (seed >> 1) % 3; // 0: alice stays free, 1: alice requests too, 2: alice hands bob her shares
        uint256 aShares = v.balanceOf(alice); // BEFORE the prank: a read is a call, and a call would eat it
        if ((seed >> 3) % 2 == 0) {
            vm.prank(alice);
            v.transfer(address(v), 1e12);
            aShares -= 1e12;
        }
        if (mode == 1) _request(v, alice, aShares);
        if (mode == 2) {
            vm.prank(alice);
            v.transfer(bob, aShares);
        }
        _request(v, bob, v.balanceOf(bob));
        uint256 pot = _exitable(v);
        uint256 m = _x(v).maxClaim(bob);
        assertGt(m, 0, "PREMISE: exitable pays a share");
        uint256 got = _claim(v, bob, m);
        assertLe(got, pot, "the claim paid past exitable");
        assertTrue(_escrow(v, bob) == 0 || _exitable(v) <= 2, "maxClaim's answer took neither the whole request nor all of exitable");
    }

    // ---- the requests' hold each verb leaves ----

    /// @notice A REQUEST HOLDS ITS WORTH AT THE FEE-INCLUSIVE PRICE, capped by exitable: the fee its claim mints first is already priced in.
    function test_Demand_UnderAPendingFeeIsTheFeeInclusiveWorth() public {
        (CuratorVault v,) = _feeLent(15_000e6);
        uint256 sh = v.balanceOf(bob) / 2;
        _request(v, bob, sh);
        uint256 naive = Math.mulDiv(sh, v.totalAssets() + 1, v.totalSupply() + V_OFF);
        assertGt(naive, _worth(v, sh), "PREMISE: the pending fee lowers the price");
        assertEq(_heldReq(v), Math.min(_exitable(v), _worth(v, sh)), "the hold is not the request's worth at the fee-inclusive price");
    }

    /// @notice A CLAIM RE-PRICES THE HOLD TO WHAT THE REQUESTS STILL WANT, so a later repayment is held only for the shares left.
    function test_Demand_AClaimRePricesItToTheSharesLeft() public {
        (CuratorVault v, uint256 loanId) = _lent(15_000e6);
        uint256 sh = v.balanceOf(bob);
        _request(v, bob, sh);
        _repay(loanId, 2_000e6);
        v.crank(); // the repayment reaches idle at the crank
        _claim(v, bob, sh / 4);
        uint256 left = _escrow(v, bob);
        assertEq(left, sh - sh / 4, "PREMISE: the claim took its quarter");
        assertEq(_heldReq(v), Math.min(_exitable(v), _worth(v, left)), "the claim left the hold at the claimed shares' worth");
        _repay(loanId, 8_000e6);
        v.crank();
        assertLt(_worth(v, left), _exitable(v), "PREMISE: exitable now passes what the request still wants");
        assertEq(_heldReq(v), _worth(v, left), "a repayment after the claim was held past what the request still wants");
    }

    // ---- the drain ----

    /// @notice THE GUARDIAN'S DRAIN REFUSES A BORROW BY NAME, the guardian cannot lift it, and the curator's lift lets the door lend again.
    function test_Drain_ABorrowIsRefusedUnderTheGuardiansDrainUntilTheCuratorLiftsIt() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _drain(v, guardian, true);
        assertEq(v.lendable(), 0, "lendable is not zero under the drain");
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(v), COLL);
        vm.expectRevert(ICuratorVaultExits.Draining.selector);
        v.borrow(_request(address(collateral), COLL, 1_000e6), "", "");
        vm.stopPrank();
        vm.prank(guardian);
        vm.expectRevert(AceVault.NotCurator.selector);
        v.setDrain(false);
        _drain(v, curator, false);
        uint256 loanId = _borrow(v, 1_000e6);
        assertEq(ace.loanMarket(loanId), mid, "the curator's lift did not let the door lend again");
        assertGt(read.debtOf(loanId), 0, "the lifted door opened no debt");
    }

    // ---- the claim's receiver and floor ----

    /// @notice A CLAIM NAMING ANOTHER RECEIVER AT EXACTLY ITS PAYOUT, under a pending fee: the floor binds to the wei, and only the receiver is paid.
    function test_Claim_AnotherReceiverAtExactlyTheFeeInclusivePayout() public {
        (CuratorVault v, uint256 loanId) = _feeLent(15_000e6);
        uint256 sh = v.balanceOf(bob) / 4;
        _request(v, bob, sh);
        _repay(loanId, 1_000e6);
        v.crank(); // the repayment reaches idle at the crank
        assertGt(_heldReq(v), 0, "PREMISE: exitable cash is held for the request");
        uint256 w = _worth(v, sh);
        vm.prank(bob);
        vm.expectRevert(ICuratorVaultExits.ClaimUnderMin.selector);
        _x(v).claimExit(sh, carol, w + 1);
        uint256 bobCash = usdc.balanceOf(bob);
        vm.expectEmit(true, true, true, true, address(v));
        emit Withdraw(bob, carol, bob, w, sh);
        vm.prank(bob);
        assertEq(_x(v).claimExit(sh, carol, w), w, "a claim at its own fee-inclusive floor did not pay it");
        assertEq(usdc.balanceOf(carol), w, "the receiver was not paid the claim");
        assertEq(usdc.balanceOf(bob), bobCash, "the holder was paid though another receiver was named");
        assertEq(_escrow(v, bob), 0, "the claim did not burn the request");
    }

    // ---- the last holders out ----

    /// @notice EVERY HOLDER LEAVES AND THE PILE REACHES THEM, even under the entry gate's share: the last free holder is refused at once and claims it.
    /// @notice Nothing is left for an entrant to buy: the vault empties to the wei, and a later entry holds no more than it brought.
    function test_LastOut_EveryHolderLeavesAndThePileReachesThem() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        _gift(v, 100e6); // half a percent of NAV: a pile under the entry gate's share
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a pile vests");
        assertGt(v.maxDeposit(carol), 0, "PREMISE: the pile is under the gate, so entry stays open");
        uint256 aPaid = _redeem(v, alice, v.balanceOf(alice));
        uint256 bAll = v.balanceOf(bob);
        assertEq(v.maxRedeem(bob), 0, "the max view offered the last free holder an exit the verb refuses");
        vm.prank(bob);
        vm.expectRevert(ICuratorVaultExits.LastOutVesting.selector);
        v.redeem(bAll, bob, bob);
        _request(v, bob, bAll);
        uint256 bPaid = _claim(v, bob, bAll);
        assertEq(v.totalSupply(), 0, "a share outlived the last holder");
        assertLe(v.grossNav(), 2, "a pile was stranded behind the last holder");
        assertApproxEqAbs(aPaid + bPaid, 2 * SEED + 100e6, 3, "the holders were not paid every wei");
        assertGt(bPaid, aPaid, "the stayer did not keep the leaver's share of the pile");
        uint256 d = _lpDeposit(v, carol, 1_000e6);
        _warpBy(VEST_W);
        assertLe(v.convertToAssets(d), 1_000e6, "an entrant took value the holders left behind");
    }
}
