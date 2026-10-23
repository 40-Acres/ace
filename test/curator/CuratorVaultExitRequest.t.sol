// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {CuratorVaultExitsRig, ICuratorVaultExits} from "./CuratorVaultExitsRig.sol";

/// @notice A product whose NAV override LOWERS the base's figure by a set cut, as an override is allowed to.
contract CutNavVault is CuratorVault {
    uint256 public cut;

    constructor(VaultConfig memory cfg, Listing[] memory l) CuratorVault(cfg, 10e6, 1.4e18, 1 days, l, "Cut", "cCUT") {}

    function setCut(uint256 amount) external {
        cut = amount;
    }

    function totalAssets() public view override returns (uint256) {
        return Math.saturatingSub(super.totalAssets(), cut);
    }
}

/// @title CuratorVaultExitRequest
/// @notice The exit request: escrowed shares whose worth holds exitable cash from placements and instant exits, claimed first come at the claim's own price.
/// @notice The hold is computed at read time: it fences existing idle at once, up to the requests' worth, whatever landed when.
/// @notice No queue, no close and no forced fill: a request locks no price, cancels at will, and lapses past its lease.
/// @dev The MEASURE rows pin what first come costs, so a change to who is paid turns one red.
contract CuratorVaultExitRequestTest is CuratorVaultExitsRig {
    uint256 internal constant DUST = 1e4; // asset-wei: rounding across a few prices and claims

    /// @dev The hold the requests take now: their escrow's worth at this NAV, capped by exitable.
    function _expectedHold(CuratorVault v) internal view returns (uint256) {
        return Math.min(_exitable(v), _worth(v, _x(v).requestedShares()));
    }

    // ---- the request ----

    /// @notice A REQUEST ESCROWS THE SHARES ON THE VAULT, renews the lease, and holds exitable cash up to the request's worth.
    function test_Request_EscrowsTheSharesAndRaisesTheFence() public {
        (CuratorVault v,) = _lent(15_000e6);
        uint256 sh = v.balanceOf(bob) / 2;
        uint256 worth = _worth(v, sh);
        vm.expectEmit(true, false, false, true, address(v));
        emit ExitRequested(bob, sh, uint64(_now()) + LEASE);
        _request(v, bob, sh);
        (uint256 esc, uint64 exp) = _x(v).requestOf(bob);
        assertEq(esc, sh, "the request did not record its shares");
        assertEq(exp, uint64(_now()) + LEASE, "the lease is not thirty days from the request");
        assertEq(_x(v).REQUEST_LEASE(), LEASE, "the lease constant moved");
        assertEq(v.balanceOf(address(v)), sh, "the shares were not escrowed on the vault");
        assertEq(_x(v).requestedShares(), sh, "the aggregate does not count the request");
        assertEq(_heldReq(v), Math.min(_exitable(v), worth), "the requests' hold is not the request's worth at this NAV, capped by exitable");
    }

    /// @notice A REQUEST HOLDS THE CASH ALREADY IN THE VAULT AT ONCE: lendable and every other holder's instant bound fall by the hold.
    function test_Request_HoldsTheCashAlreadyInTheVaultAtOnce() public {
        (CuratorVault v,) = _lent(15_000e6);
        uint256 lend0 = v.lendable();
        uint256 aliceMax0 = v.maxWithdraw(alice);
        assertEq(aliceMax0, lend0, "PREMISE: alice is worth more than the instant bound");
        _request(v, bob, v.balanceOf(bob));
        uint256 held = _heldReq(v);
        assertGt(held, 0, "PREMISE: the request holds cash");
        assertEq(held, _expectedHold(v), "the hold is not the request's worth capped by exitable");
        assertEq(v.lendable(), lend0 - held, "the request did not take its hold out of lendable at once");
        assertEq(v.maxWithdraw(alice), aliceMax0 - held, "the request did not take its hold out of another holder's instant bound at once");
    }

    /// @notice A REPAYMENT IS HELD FOR THE REQUEST UP TO ITS WORTH, and what lands past the worth stays lendable.
    /// @dev Bob's whole request is worth more than exitable, so the hold takes all of it until repayments pass the worth.
    function test_Fence_ARepaymentIsHeldUpToTheRequestsWorth() public {
        (CuratorVault v, uint256 loanId) = _lent(15_000e6);
        _request(v, bob, v.balanceOf(bob));
        assertEq(v.lendable(), 0, "PREMISE: the request is worth more than exitable, so it holds all of it");
        _repay(loanId, 1_000e6);
        v.crank(); // the repayment reaches idle at the crank
        assertEq(_heldReq(v), _expectedHold(v), "the hold is not the request's worth capped by exitable");
        assertEq(v.lendable(), 0, "a repayment under the request's worth reached lendable");
        _repay(loanId, 6_000e6);
        v.crank();
        uint256 worth = _worth(v, _escrow(v, bob));
        assertLt(worth, _exitable(v), "PREMISE: exitable now passes the request's worth");
        assertEq(_heldReq(v), worth, "the hold passed the request's worth");
        assertEq(v.lendable(), _exitable(v) - worth, "the repayment past the worth was not left lendable");
    }

    /// @notice CASH HELD FOR A REQUEST IS NOT LENT AGAIN: a borrow past lendable is refused while the hold stands.
    function test_Fence_ADrawPastTheFreePotIsRefused() public {
        (CuratorVault v, uint256 loanId) = _lent(15_000e6);
        _request(v, bob, v.balanceOf(bob));
        _repay(loanId, 2_000e6);
        v.crank();
        uint256 free = v.lendable();
        assertGt(_heldReq(v), free + 1_000e6, "PREMISE: the request holds the cash the draw would take");
        _expectBorrowPastLendable(v, free + 1_000e6);
    }

    // ---- first come ----

    /// @notice FIRST COME: the first claimer takes all of exitable, and the next requester waits for the next inflow, which it may claim first.
    function test_FirstCome_TheFirstClaimerTakesThePotAndTheNextWaits() public {
        (CuratorVault v, uint256 loanId) = _lent(19_000e6);
        _request(v, alice, v.balanceOf(alice));
        _request(v, bob, v.balanceOf(bob));
        _repay(loanId, 3_000e6);
        v.crank(); // the repayment reaches idle at the crank
        uint256 pot = _exitable(v);
        assertLt(pot, _worth(v, _escrow(v, alice)), "PREMISE: exitable covers less than the first request");
        uint256 got = _claim(v, alice, _x(v).maxClaim(alice));
        assertApproxEqAbs(got, pot, 2, "the first claimer did not take all of exitable");
        assertEq(_x(v).maxClaim(bob), 0, "the second requester was offered cash the first had taken");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, bob, 1e12, 0));
        _x(v).claimExit(1e12, bob, 0);
        _repay(loanId, 2_000e6);
        v.crank();
        uint256 bobGot = _claim(v, bob, _x(v).maxClaim(bob));
        assertApproxEqAbs(bobGot, 2_000e6, 2, "the next repayment did not go to whoever claimed it first");
        assertEq(_x(v).maxClaim(alice), 0, "the first claimer still had a claim on cash the second took");
    }

    // ---- the claim ----

    /// @notice A CLAIM PAYS AT ITS OWN NAV: a fall between the request and the claim passes through.
    function test_Claim_PricesAtTheClaimsOwnNavAfterAFall() public {
        (CuratorVault v, uint256 loanId) = _lent(6_000e6);
        uint256 sh = v.balanceOf(bob);
        _request(v, bob, sh);
        uint256 before = _worth(v, sh);
        _finalize(loanId);
        v.crank();
        uint256 fallen = _worth(v, sh);
        assertLt(fallen * 10, before * 8, "PREMISE: the settle took a fifth or more off the price");
        assertEq(_claim(v, bob, sh), fallen, "the claim paid other than its own NAV after the fall");
    }

    /// @notice A GAIN AFTER THE REQUEST VESTS AS IT DOES FOR A FREE SHARE: a claim inside the vest pays the net price.
    function test_Claim_AGainAfterTheRequestVestsAsForAFreeShare() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 sh = v.balanceOf(bob);
        _request(v, bob, sh);
        uint256 p0 = _worth(v, sh);
        _gift(v, 2_000e6);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: the gain is vesting");
        uint256 snap = vm.snapshotState();
        assertApproxEqAbs(_claim(v, bob, sh), p0, 1, "a claim inside the vest took the vesting gain");
        vm.revertToState(snap);
        _warpBy(VEST_W);
        assertApproxEqAbs(_claim(v, bob, sh), p0 + 1_000e6, 2, "a claim after the vest missed its half of the gain");
    }

    /// @notice A CLAIM TAKES EXITABLE CASH, and the hold recomputes to what the rest of the request is worth.
    function test_Claim_PaysHeldCashFirstThenFreeCash() public {
        (CuratorVault v, uint256 loanId) = _lent(15_000e6);
        uint256 sh = v.balanceOf(bob);
        _request(v, bob, sh);
        _repay(loanId, 1_000e6);
        v.crank(); // the repayment reaches idle at the crank
        uint256 exit0 = _exitable(v);
        uint256 w = _worth(v, sh / 2);
        assertLe(w, exit0, "PREMISE: exitable covers the claim");
        assertEq(_claim(v, bob, sh / 2), w, "the claim paid other than its worth");
        assertEq(_exitable(v), exit0 - w, "the claim took other than its worth from exitable");
        assertEq(_heldReq(v), Math.min(_exitable(v), _worth(v, sh - sh / 2)), "the hold did not recompute to the rest of the request");
    }

    /// @notice A DEPOSIT AFTER A REQUEST WORTH MORE THAN IDLE IS HELD FOR IT, and a claim reaches it at once.
    function test_Claim_ReachesADepositLandedAfterTheRequest() public {
        (CuratorVault v,) = _lent(19_000e6);
        _request(v, bob, v.balanceOf(bob));
        uint256 exit0 = _exitable(v);
        _lpDeposit(v, carol, 5_000e6);
        assertEq(_exitable(v), exit0 + 5_000e6, "the deposit did not land in exitable");
        assertLt(_exitable(v), _worth(v, _escrow(v, bob)), "PREMISE: the request is worth more than exitable");
        assertEq(_heldReq(v), _exitable(v), "the entrant's deposit was not held for the request");
        uint256 got = _claim(v, bob, _x(v).maxClaim(bob));
        assertApproxEqAbs(got, exit0 + 5_000e6, 2, "the claim did not reach the entrant's cash");
    }

    /// @notice `minAssets` BINDS: a claim paying a wei less than it is refused `ClaimUnderMin`, and at it the claim pays.
    function test_Claim_UnderMinAssetsRefuses() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 sh = v.balanceOf(bob) / 3;
        _request(v, bob, sh);
        uint256 w = _worth(v, sh);
        vm.prank(bob);
        vm.expectRevert(ICuratorVaultExits.ClaimUnderMin.selector);
        _x(v).claimExit(sh, bob, w + 1);
        vm.prank(bob);
        assertEq(_x(v).claimExit(sh, bob, w), w, "a claim at its own minimum did not pay it");
    }

    /// @notice A CLAIM WORTH NOTHING IS REFUSED `ZeroAssets`, and burns nothing.
    function test_Claim_AClaimWorthNothingRefuses() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        _request(v, bob, 1e12);
        vm.prank(bob);
        vm.expectRevert(AceVault.ZeroAssets.selector);
        _x(v).claimExit(1, bob, 0);
        assertEq(_escrow(v, bob), 1e12, "the refused claim moved the request");
    }

    /// @notice A CLAIM IS THE HOLDER'S OWN: a stranger has no request to claim, and the holder may name any receiver.
    function test_Claim_IsTheHoldersOwnAndPaysTheNamedReceiver() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 sh = v.balanceOf(bob) / 2;
        _request(v, bob, sh);
        vm.prank(carol);
        vm.expectRevert(ICuratorVaultExits.OverRequest.selector);
        _x(v).claimExit(1, carol, 0);
        uint256 w = _worth(v, sh);
        vm.expectEmit(true, true, true, true, address(v));
        emit Withdraw(bob, carol, bob, w, sh);
        vm.prank(bob);
        _x(v).claimExit(sh, carol, 0);
        assertEq(usdc.balanceOf(carol), w, "the claim did not pay the receiver its holder named");
        assertEq(v.balanceOf(address(v)), 0, "the claim did not burn its escrow");
    }

    /// @notice A CLAIM PAST THE REQUEST IS REFUSED `OverRequest`.
    function test_Claim_PastTheRequestRefuses() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, bob, SEED);
        _lpDeposit(v, alice, SEED);
        _request(v, bob, 1_000e12);
        vm.prank(bob);
        vm.expectRevert(ICuratorVaultExits.OverRequest.selector);
        _x(v).claimExit(1_000e12 + 1, bob, 0);
    }

    // ---- the instant exit beside it ----

    /// @notice AN INSTANT EXIT NEVER REACHES HELD CASH: its max views stop at exitable less the hold, and a wei past refuses.
    function test_InstantExit_NeverReachesHeldCash() public {
        (CuratorVault v, uint256 loanId) = _lent(15_000e6);
        _request(v, bob, v.balanceOf(bob) / 4);
        _repay(loanId, 2_000e6);
        v.crank(); // the repayment reaches idle at the crank
        uint256 held = _heldReq(v);
        uint256 free = _exitable(v) - held;
        assertGt(held, 0, "PREMISE: the request holds cash for bob");
        assertGt(free, 0, "PREMISE: some exitable cash is not held");
        assertEq(v.maxWithdraw(alice), free, "an instant exit was offered the request's held cash");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, free + 1, free));
        v.withdraw(free + 1, alice, alice);
    }

    // ---- cancel, lapse and renew ----

    /// @notice A CANCEL RETURNS THE SHARES AT ONCE, and the hold falls to what the request still wants.
    function test_Cancel_ReturnsTheSharesAndFreesTheHold() public {
        (CuratorVault v, uint256 loanId) = _lent(15_000e6);
        uint256 sh = v.balanceOf(bob) / 2;
        uint256 keep = 1_000e12;
        _request(v, bob, sh);
        _repay(loanId, 3_000e6);
        v.crank(); // the repayment reaches idle at the crank
        assertEq(_heldReq(v), Math.min(_exitable(v), _worth(v, sh)), "PREMISE: the request holds its worth, capped by exitable");
        uint256 bal0 = v.balanceOf(bob);
        vm.expectEmit(true, false, false, true, address(v));
        emit ExitReleased(bob, sh - keep);
        vm.prank(bob);
        _x(v).cancelExit(sh - keep);
        assertEq(v.balanceOf(bob), bal0 + sh - keep, "the cancel did not return the shares");
        assertEq(_escrow(v, bob), keep, "the cancel left the wrong request");
        assertEq(_heldReq(v), Math.min(_exitable(v), _worth(v, keep)), "the cancel kept cash held past what the request still wants");
    }

    /// @notice A CANCEL PAST THE REQUEST IS REFUSED, and so is one with no request at all.
    function test_Cancel_PastTheRequestRefuses() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, bob, SEED);
        _request(v, bob, 1_000e12);
        vm.prank(bob);
        vm.expectRevert(ICuratorVaultExits.OverRequest.selector);
        _x(v).cancelExit(1_000e12 + 1);
        vm.prank(carol);
        vm.expectRevert(ICuratorVaultExits.OverRequest.selector);
        _x(v).cancelExit(1);
    }

    /// @notice A LAPSE INSIDE THE LEASE IS REFUSED `RequestLive`, at its last second too.
    function test_Lapse_RefusesInsideTheLease() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, bob, SEED);
        _request(v, bob, 1_000e12);
        _warpBy(LEASE - 1);
        vm.prank(stranger);
        vm.expectRevert(ICuratorVaultExits.RequestLive.selector);
        _x(v).lapseExit(bob);
    }

    /// @notice ANYONE LAPSES A REQUEST ONCE ITS LEASE HAS RUN: the whole escrow goes home and the fence goes with it.
    function test_Lapse_AnyoneLapsesAtTheLeasesEnd() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, bob, SEED);
        _lpDeposit(v, alice, SEED);
        uint256 all = v.balanceOf(bob);
        _request(v, bob, all);
        assertGt(_heldReq(v), 0, "PREMISE: the request holds cash");
        _warpBy(LEASE);
        vm.expectEmit(true, false, false, true, address(v));
        emit ExitReleased(bob, all);
        vm.prank(stranger);
        _x(v).lapseExit(bob);
        assertEq(v.balanceOf(bob), all, "the lapse did not send the shares home");
        assertEq(_escrow(v, bob), 0, "the lapse left a request standing");
        assertEq(_x(v).requestedShares(), 0, "the aggregate still counts the lapsed request");
        assertEq(_heldReq(v), 0, "the lapsed request still holds cash");
    }

    /// @notice A LAPSE OF AN EMPTY RECORD IS REFUSED `NoRequest`: one never made, and one already cancelled whole.
    function test_Lapse_AnEmptyRecordRefuses() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, bob, SEED);
        vm.expectRevert(ICuratorVaultExits.NoRequest.selector);
        _x(v).lapseExit(carol);
        _request(v, bob, 1_000e12);
        vm.prank(bob);
        _x(v).cancelExit(1_000e12);
        _warpBy(LEASE);
        vm.expectRevert(ICuratorVaultExits.NoRequest.selector);
        _x(v).lapseExit(bob);
    }

    /// @notice A REQUEST OF ZERO ONLY RENEWS THE LEASE: the escrow stands and the lapse moves a full lease out.
    function test_Renew_AZeroRequestOnlyRenewsTheLease() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, bob, SEED);
        _request(v, bob, 1_000e12);
        _warpBy(LEASE - 1);
        _request(v, bob, 0);
        (uint256 esc, uint64 exp) = _x(v).requestOf(bob);
        assertEq(esc, 1_000e12, "a renewal moved the escrow");
        assertEq(exp, uint64(_now()) + LEASE, "a renewal did not move the lapse a full lease out");
        _warpBy(LEASE - 1);
        vm.expectRevert(ICuratorVaultExits.RequestLive.selector);
        _x(v).lapseExit(bob);
    }

    /// @notice A TOP-UP RENEWS THE WHOLE REQUEST, not just its own part.
    function test_Renew_ATopUpRenewsTheWholeRequest() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, bob, SEED);
        _request(v, bob, 1_000e12);
        _warpBy(20 days);
        _request(v, bob, 500e12);
        assertEq(_escrow(v, bob), 1_500e12, "the top-up did not add to the request");
        _warpBy(LEASE - 1);
        vm.expectRevert(ICuratorVaultExits.RequestLive.selector);
        _x(v).lapseExit(bob);
        _warpBy(1);
        _x(v).lapseExit(bob);
        assertEq(v.balanceOf(bob), v.totalSupply(), "the lapse did not return the whole topped-up request");
    }

    // ---- the release at the claim ----

    /// @notice A SANDWICH CANNOT RELEASE THE PILE: an entrant's request and claim beside others' standing requests pays the net price.
    /// @notice Every share is escrow, but the claim is not the last requester's whole claim, so the pile stays to vest for those who held.
    function test_Release_AnEntrantBesideStandingRequestsClaimsAtNet() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        _request(v, alice, v.balanceOf(alice));
        _request(v, bob, v.balanceOf(bob));
        uint256 d = _lpDeposit(v, carol, SEED);
        _gift(v, 3_000e6);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a gain is vesting");
        _request(v, carol, d);
        assertEq(v.totalSupply(), v.balanceOf(address(v)), "PREMISE: every share is escrow");
        assertEq(_x(v).maxClaim(carol), d, "PREMISE: exitable covers the entrant's whole request");
        uint256 net = _worth(v, d);
        uint256 got = _claim(v, carol, d);
        assertApproxEqAbs(got, net, 2, "the entrant's claim was not paid at the net price");
        assertLe(got, SEED + 2, "the entrant took part of a gain it never held through the vest");
        assertGt(v.unvested(), 0, "the entrant's claim released the pile");
    }

    /// @notice ONLY THE LAST REQUESTER RELEASES THE PILE: a claim beside another request is paid net, and its share stays for whoever is last.
    function test_Release_OnlyTheLastRequesterReleasesThePile() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        _gift(v, 2_000e6);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a gain is vesting");
        (uint256 a0, uint256 b0) = (v.balanceOf(alice), v.balanceOf(bob));
        _request(v, alice, a0);
        _request(v, bob, b0);
        uint256 netA = _worth(v, a0);
        assertApproxEqAbs(_claim(v, alice, a0), netA, 2, "a claim beside another standing request released the pile");
        assertEq(_x(v).maxClaim(bob), b0, "maxClaim did not offer the last requester's whole request");
        assertApproxEqAbs(_claim(v, bob, b0), 2 * SEED + 2_000e6 - netA, 3, "the last requester's claim did not take the released pile");
        assertEq(v.totalSupply(), 0, "the last claim left supply standing");
    }

    /// @notice THE LAST REQUESTER'S `maxClaim` REPLAYS THE RELEASE where exitable binds, so its answer is priced as the claim pays it.
    function test_MaxClaim_TheLastRequestersAnswerReplaysTheReleaseSoItPays() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _crank(v, _open(6_000e6), T2, 0);
        _warpBy(VEST_W);
        v.crank();
        _gift(v, 1_000e6);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a gain is vesting");
        uint256 all = v.balanceOf(alice);
        _request(v, alice, all);
        uint256 pot = _exitable(v);
        uint256 m = _x(v).maxClaim(alice);
        assertLt(m, all, "PREMISE: exitable covers less than the last request");
        assertApproxEqAbs(_claim(v, alice, m), pot, 2, "the last requester's claim of maxClaim did not take all of exitable");
    }

    /// @notice `maxClaim`'S RELEASE REPLAY READS THE VIRTUAL NAV, as the claim does after its release: a lowered NAV is offered whole.
    function test_MaxClaim_TheReleaseReplayReadsAnOverriddenNav() public {
        CutNavVault v = new CutNavVault(_cfg(0), _listing());
        mid = _doorMarket(v, address(collateral));
        _lpDeposit(v, alice, SEED);
        _crank(v, _open(1_000e6), T2, 0);
        _gift(v, 500e6);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a gain is vesting");
        uint256 pot = usdc.balanceOf(address(v));
        v.setCut(v.grossNav() - pot + 1e6); // the override's NAV after the release sits a unit under the vault's cash
        uint256 all = v.balanceOf(alice);
        _request(v, alice, all);
        assertEq(_x(v).maxClaim(alice), all, "maxClaim did not price the release at the overridden NAV the claim pays");
        assertLe(_claim(v, alice, all), pot, "the whole claim paid past the vault's cash");
        assertEq(v.totalSupply(), 0, "the whole claim left supply standing");
    }

    /// @notice THE LAST FREE HOLDER IS REFUSED AN INSTANT EXIT WHILE A GAIN VESTS, requests, and the claim releases the pile to them.
    function test_Release_TheLastHolderRequestsAndTheClaimTakesThePile() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _gift(v, 500e6);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a gain is vesting");
        uint256 all = v.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(ICuratorVaultExits.LastOutVesting.selector);
        v.redeem(all, alice, alice);
        _request(v, alice, all);
        assertEq(_x(v).maxClaim(alice), all, "maxClaim did not offer the whole request");
        assertApproxEqAbs(_claim(v, alice, all), SEED + 500e6, 2, "the claim did not release the pile to the last holder out");
        assertEq(v.totalSupply(), 0, "the last claim left supply standing");
    }

    /// @notice BESIDE ANOTHER REQUEST `maxClaim` PRICES AT NET, as the claim does, so its answer takes all of exitable.
    function test_MaxClaim_BesideAnotherRequestItsAnswerTakesTheWholePot() public {
        (CuratorVault v,) = _lent(15_000e6);
        _request(v, bob, v.balanceOf(bob));
        _gift(v, 1_000e6);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a gain is vesting");
        _request(v, alice, v.balanceOf(alice));
        assertEq(v.totalSupply(), v.balanceOf(address(v)), "PREMISE: every share is escrow, yet bob is not the last requester");
        uint256 pot = _exitable(v);
        uint256 m = _x(v).maxClaim(bob);
        assertLt(m, _escrow(v, bob), "PREMISE: exitable covers less than bob's request");
        uint256 got = _claim(v, bob, m);
        assertApproxEqAbs(got, pot, 2, "the claim of maxClaim did not take all of exitable");
    }

    // ---- MEASURE ----

    /// @notice A TROUGH BURNS NOTHING: with requests standing through a settle, no share leaves until its holder claims.
    function test_Measure_ATroughBurnsNothing() public {
        (CuratorVault v, uint256 loanId) = _lent(6_000e6);
        _request(v, alice, v.balanceOf(alice));
        _request(v, bob, v.balanceOf(bob));
        uint256 supply = v.totalSupply();
        _finalize(loanId);
        v.crank();
        _warpBy(LEASE - 1);
        v.crank();
        assertEq(v.totalSupply(), supply, "a trough burned shares nobody claimed");
        assertEq(_escrow(v, alice) + _escrow(v, bob), supply, "or moved a request");
        assertGt(_x(v).maxClaim(alice), 0, "PREMISE: there was cash a forced fill could have taken");
    }

    /// @notice MEASURE, the plan's worked example at a hundredth: two 20% requesters, a default that recovers 60%, first come.
    /// @notice The first claimer is paid in full at the pre-loss price; the other requester and the stayers carry the loss it escaped.
    /// @notice The escape is `f * L`, the first holder's share of the loss; a request locks no price, so the other two carry it pro rata.
    function test_Measure_TheWorkedExampleFirstComeAmongTwoRequesters() public {
        CuratorVault v = _vault(0);
        _lpDeposit(v, alice, 2_000e6);
        _lpDeposit(v, bob, 2_000e6);
        _lpDeposit(v, carol, 6_000e6);
        uint256 doomed = _open(1_000e6);
        uint256 repaid = _open(1_000e6);
        _open(7_000e6);
        v.crank();
        _warpBy(VEST_W);
        v.crank();
        _request(v, alice, v.balanceOf(alice));
        _request(v, bob, v.balanceOf(bob));
        _repay(repaid, read.debtOf(repaid));
        v.crank();
        uint256 aGot = _claim(v, alice, _x(v).maxClaim(alice));
        assertEq(_escrow(v, alice), 0, "PREMISE: exitable covered alice's whole request before the settle");
        uint256 g = v.grossNav();
        _finalize(doomed);
        v.crank();
        uint256 drop = g - v.grossNav();
        g = v.grossNav();
        assertGt(_buyPot(keeper, doomed, Math.mulDiv(drop, 6, 10)), 0, "PREMISE: the inventory sold");
        v.crank();
        uint256 recovered = v.grossNav() - g;
        _warpBy(VEST_W);
        v.crank();
        uint256 loss = drop - recovered;
        uint256 bWorth = _worth(v, _escrow(v, bob));
        uint256 cWorth = _worth(v, v.balanceOf(carol));
        uint256 end = aGot + bWorth + cWorth;
        (uint256 fairA, uint256 fairC) = (Math.mulDiv(end, 2, 10), Math.mulDiv(end, 6, 10));
        emit log_named_uint("the loss after the sale", loss);
        emit log_named_uint("alice, the first claimer, paid", aGot);
        emit log_named_uint("bob, the second requester, worth", bWorth);
        emit log_named_uint("carol, the stayers, worth", cWorth);
        emit log_named_uint("a 20% holder's fair share", fairA);
        assertGt(aGot, fairA, "the first claimer did not escape the loss");
        assertLt(bWorth, fairA, "the second requester did not carry part of it");
        assertLt(cWorth, fairC, "nor did the stayers");
        assertApproxEqRel(aGot - fairA, Math.mulDiv(loss, 2, 10), 1e16, "the escape is not the first holder's share of the loss");
        assertApproxEqAbs((fairA - bWorth) * 3, fairC - cWorth, DUST, "the second requester and the stayers did not carry it pro rata");
    }
}
