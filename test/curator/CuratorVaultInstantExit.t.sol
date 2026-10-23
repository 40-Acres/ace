// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";

/// @notice The instant-exit rig: a production CuratorVault, which exits at once by default, with a guardian key.
abstract contract InstantExitRig is CuratorVaultBase {
    uint256 internal constant V_OFF = 1e6; // the vault's virtual-share offset
    uint16 internal constant FEE = 1000; // a live performance fee, so a fee row prices against a supply the verb itself grows
    address internal guardian = address(0x6A2D);
    address internal carol = address(0xCA201);

    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    /// @dev A production vault, instant by default, with the rig collateral listed; `mid` is its door market.
    function _instantVault(uint16 fee) internal returns (CuratorVault v) {
        VaultConfig memory c = _cfg(fee);
        c.guardian = guardian;
        v = _deploy(c, "Instant", "cINST");
    }

    /// @dev The quote supply a verb prices against: the supply, the fee it would mint first, and the virtual offset.
    function _quoteSupply(CuratorVault v) internal view returns (uint256) {
        return v.totalSupply() + v.pendingFeeShares() + V_OFF;
    }

    /// @dev Whether the price after a move is at or above the price before it, cross-multiplied so no division rounds.
    function _notCheaper(uint256 a0, uint256 q0, uint256 a1, uint256 q1) internal pure returns (bool) {
        return (a1 + 1) * q0 >= (a0 + 1) * q1;
    }

    /// @dev The two prices differ by less than one asset-wei over either supply: `|(a1+1)/q1 - (a0+1)/q0| < 1/q0 + 1/q1`.
    /// @dev An exit's floor leaves the stayers up to one wei, which over the smaller supply is up to `q0 / q1` of a wei a share.
    function _samePrice(uint256 a0, uint256 q0, uint256 a1, uint256 q1) internal pure returns (bool) {
        (uint256 x, uint256 y) = ((a1 + 1) * q0, (a0 + 1) * q1);
        return x <= y + q0 + q1 && y <= x + q0 + q1;
    }

    function _redeem(CuratorVault v, address who, uint256 shares) internal returns (uint256) {
        vm.prank(who);
        return v.redeem(shares, who, who);
    }

    function _request(CuratorVault v, address who, uint256 shares) internal {
        vm.prank(who);
        v.requestExit(shares);
    }

    /// @dev Two LPs at par, a vested gain over the fee's high-water, so a collection is owed when the next verb runs.
    function _grownFeeVault() internal returns (CuratorVault v) {
        v = _instantVault(FEE);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        _gift(v, 1_000e6);
        v.crank();
        _warpBy(VEST_W);
        assertEq(v.unvested(), 0, "PREMISE: the gain has vested");
        assertGt(v.pendingFeeShares(), 0, "PREMISE: a fee is owed, so the verb collects before it prices");
    }
}

/// @title CuratorVaultInstantExit
/// @notice The base vault's default exit: ERC-4626 `redeem` and `withdraw` pay at once from exitable cash the requests do not hold.
/// @notice Priced over the fee-inclusive supply, bounded by that cash, refused for the last free holder while a gain vests.
/// @notice It never takes the requests' hold and never writes a request: the hold is computed at read time from them.
contract CuratorVaultInstantExitTest is InstantExitRig {
    // ---- the price ----

    /// @notice A REDEEM PAYS THE PREVIEW AT ONCE, priced over the supply the verb's own fee collection leaves.
    /// @notice The stayers' price, read after that collection, does not fall; the curator is paid the fee and nothing more.
    function test_Instant_RedeemPaysThePreviewAtTheFeeInclusivePrice() public {
        CuratorVault v = _grownFeeVault();
        uint256 sh = v.balanceOf(alice) / 2;
        uint256 quote = v.previewRedeem(sh);
        uint256 fee = v.pendingFeeShares();
        (uint256 a0, uint256 q0) = (v.totalAssets(), _quoteSupply(v));
        uint256 cash0 = usdc.balanceOf(alice);

        uint256 paid = _redeem(v, alice, sh);

        assertEq(paid, quote, "the redeem paid other than its own preview");
        assertEq(usdc.balanceOf(alice) - cash0, paid, "the cash did not reach the receiver");
        assertEq(v.balanceOf(curator), fee, "the verb did not collect the fee it priced in");
        assertEq(v.pendingFeeShares(), 0, "a fee still pends after the verb collected it");
        assertTrue(_notCheaper(a0, q0, v.totalAssets(), _quoteSupply(v)), "the exit lowered the stayers' price");
        assertTrue(_samePrice(a0, q0, v.totalAssets(), _quoteSupply(v)), "the exit moved the price by more than a wei");
        assertEq(paid, Math.mulDiv(sh, a0 + 1, q0), "the payment is not the floor of the shares at the fee-inclusive price");
    }

    /// @notice A WITHDRAW BURNS ITS PREVIEW, rounded UP, and pays exactly the asked cash to the named receiver.
    function test_Instant_WithdrawBurnsThePreviewAndPaysTheReceiver() public {
        CuratorVault v = _grownFeeVault();
        uint256 want = 3_333_333_333;
        uint256 burn = v.previewWithdraw(want);
        (uint256 a0, uint256 q0) = (v.totalAssets(), _quoteSupply(v));
        uint256 bal0 = v.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(v));
        emit Withdraw(alice, carol, alice, want, burn);
        vm.prank(alice);
        uint256 shares = v.withdraw(want, carol, alice);
        assertEq(shares, burn, "the withdraw burned other than its preview");
        assertEq(bal0 - v.balanceOf(alice), burn, "the burn left the owner's balance wrong");
        assertEq(usdc.balanceOf(carol), want, "the receiver was not paid the asked cash");
        assertEq(burn, Math.mulDiv(want, q0, a0 + 1, Math.Rounding.Ceil), "the burn is not the ceiling at the fee-inclusive price");
        assertTrue(_notCheaper(a0, q0, v.totalAssets(), _quoteSupply(v)), "the withdraw lowered the stayers' price");
    }

    /// @notice THE FEE-FREE GAP STAYS PUT ACROSS AN EXIT: below the high-water the exit's cash leaves both NAV and the mark.
    /// @dev Measured after the verb's own collection, which below the mark is none: the gap is the curator's loss to earn back.
    function test_Instant_TheFeeGapBelowTheHighWaterStaysPut() public {
        CuratorVault v = _instantVault(FEE);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        uint256 doomed = _open(2_000e6);
        v.crank();
        _finalize(doomed);
        v.crank();
        uint256 gap0 = v.feeHighWater() - v.totalAssets();
        assertGt(gap0, 0, "PREMISE: the loss sits the vault under its high-water");
        assertEq(v.pendingFeeShares(), 0, "PREMISE: under the mark no fee is owed");
        _redeem(v, alice, v.balanceOf(alice) / 3);
        assertEq(v.feeHighWater() - v.totalAssets(), gap0, "the exit moved the fee-free gap");
    }

    /// @notice OVER THE HIGH-WATER, AN EXIT IS NOT GROWTH: after the verb collects, a second collection mints nothing.
    function test_Instant_AnExitOverTheHighWaterChargesNoSecondFee() public {
        CuratorVault v = _grownFeeVault();
        _redeem(v, alice, v.balanceOf(alice) / 2);
        assertEq(v.feeHighWater(), v.totalAssets(), "the mark did not follow NAV down by the exit's cash");
        uint256 cur = v.balanceOf(curator);
        v.collectFee();
        assertEq(v.balanceOf(curator), cur, "the exit's own cash was billed as growth");
    }

    /// @notice AN EXIT LEAVES A VESTING PILE WHOLE: the mark falls with the cash, so the next sync reads no fall to burn the pile by.
    function test_Instant_AnExitLeavesTheVestingPileWhole() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        _gift(v, 500e6);
        v.crank();
        uint256 u0 = v.unvested();
        assertGt(u0, 0, "PREMISE: a gain is vesting");
        _redeem(v, alice, v.balanceOf(alice) / 2);
        assertEq(v.unvested(), u0, "the exit moved the pile");
        v.crank();
        assertEq(v.unvested(), u0, "the next sync read the exit as a fall and burned the pile");
    }

    // ---- zero, auth, receivers ----

    /// @notice A REDEEM WORTH NOTHING IS REFUSED `ZeroAssets`, as a claim is, and burns no share.
    /// @notice A withdraw of one wei still burns at least one share, so it pays.
    function test_Instant_ARedeemThatFloorsToNothingIsRefused() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 1_000e6);
        _lpDeposit(v, bob, 1_000e6);
        assertEq(v.previewRedeem(1), 0, "PREMISE: one share-wei is worth nothing at par");
        vm.prank(alice);
        vm.expectRevert(AceVault.ZeroAssets.selector);
        v.redeem(1, alice, alice);
        assertEq(v.balanceOf(alice), 1_000e12, "a refused redeem burned a share");
        vm.prank(alice);
        uint256 burned = v.withdraw(1, alice, alice);
        assertGe(burned, 1, "a one-wei withdraw burned nothing");
        assertEq(usdc.balanceOf(alice), 1, "the one-wei withdraw did not pay");
    }

    /// @notice A HOLDER WHOSE SHARES PAY NOTHING IS OFFERED NOTHING, so `redeem(maxRedeem)` never asks for a refused zero payout.
    function test_Instant_MaxRedeemOffersNoZeroPayout() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 1_000e6);
        _lpDeposit(v, bob, 1_000e6);
        vm.prank(alice);
        v.transfer(carol, 1);
        assertEq(v.previewRedeem(1), 0, "PREMISE: carol's one share-wei is worth nothing");
        assertEq(v.maxRedeem(carol), 0, "maxRedeem offered a redeem the verb refuses");
        assertEq(v.maxWithdraw(carol), 0, "maxWithdraw offered cash a share-wei cannot buy");
    }

    /// @notice A ZERO ASK IS A NO-OP, checked before anything else: it returns zero and moves nothing, the drain standing or not.
    function test_Instant_AZeroAskReturnsZeroEvenWhileDraining() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 1_000e6);
        vm.prank(curator);
        v.setDrain(true);
        vm.startPrank(alice);
        assertEq(v.redeem(0, alice, alice), 0, "a zero redeem did not return zero");
        assertEq(v.withdraw(0, alice, alice), 0, "a zero withdraw did not return zero");
        vm.stopPrank();
        assertEq(v.balanceOf(alice), 1_000e12, "a zero ask moved shares");
    }

    /// @notice THE CALLER NEEDS THE OWNER or an allowance it then spends; there is no operator surface.
    function test_Instant_AuthIsTheOwnerOrAnAllowance() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        uint256 sh = 1_000e12;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, sh));
        v.redeem(sh, carol, alice);

        vm.prank(alice);
        uint256 own = v.redeem(sh, alice, alice);
        assertGt(own, 0, "the owner could not exit their own shares");

        vm.prank(bob);
        v.approve(carol, sh);
        vm.prank(carol);
        uint256 paid = v.redeem(sh, carol, bob);
        assertEq(usdc.balanceOf(carol), paid, "the spender's exit paid someone else");
        assertEq(v.allowance(bob, carol), 0, "a spender's exit did not spend the allowance");
    }

    // ---- the cash bound ----

    /// @notice EXITABLE CASH THE REQUESTS DO NOT HOLD BOUNDS AN EXIT: the max views stop there, the max asks pay, and one wei past refuses.
    /// @dev No request and no armed loan stand, so the bound is the whole of idle.
    function test_Instant_TheFreePotBoundsTheExitAndTheMaxViewsAreExact() public {
        CuratorVault v = _instantVault(FEE);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        _open(15_000e6);
        v.crank();
        (uint256 exitable, uint256 heldReq) = v.holds();
        uint256 free = exitable - heldReq;
        assertEq(heldReq, 0, "PREMISE: no request holds cash");
        assertEq(free, v.idle(), "PREMISE: with no request and no armed loan the bound is all of idle");
        assertLt(free, v.previewRedeem(v.balanceOf(alice)), "PREMISE: alice is worth more than the bound");
        assertEq(v.maxWithdraw(alice), free, "maxWithdraw is not the bound");
        assertEq(v.maxRedeem(alice), Math.mulDiv(free, _quoteSupply(v), v.totalAssets() + 1), "maxRedeem is not the bound in shares");

        uint256 snap = vm.snapshotState();
        uint256 maxW = v.maxWithdraw(alice);
        vm.prank(alice);
        v.withdraw(maxW, alice, alice);
        assertEq(usdc.balanceOf(alice), free, "withdraw(maxWithdraw) did not pay the whole bound");
        vm.revertToState(snap);

        uint256 maxR = v.maxRedeem(alice);
        vm.prank(alice);
        uint256 got = v.redeem(maxR, alice, alice);
        assertLe(got, free, "redeem(maxRedeem) paid past the bound");
        vm.revertToState(snap);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, free + 1, free));
        v.withdraw(free + 1, alice, alice);
    }

    /// @notice WITH CASH TO SPARE THE MAX VIEWS ARE THE HOLDING, at the fee-inclusive price, and both max asks land.
    function test_Instant_MaxViewsAreTheHoldingWhenThePotCovers() public {
        CuratorVault v = _grownFeeVault();
        uint256 bal = v.balanceOf(alice);
        assertEq(v.maxRedeem(alice), bal, "maxRedeem is not the holding");
        assertEq(v.maxWithdraw(alice), v.previewRedeem(bal), "maxWithdraw is not the holding at the fee-inclusive price");
        uint256 snap = vm.snapshotState();
        uint256 maxW = v.maxWithdraw(alice);
        vm.prank(alice);
        v.withdraw(maxW, alice, alice);
        vm.revertToState(snap);
        uint256 maxR = v.maxRedeem(alice);
        vm.prank(alice);
        v.redeem(maxR, alice, alice);
        assertEq(v.balanceOf(alice), 0, "redeem(maxRedeem) left the holder a share");
    }

    /// @notice THE VAULT ITSELF CAN EXIT NOTHING: its balance is escrow and donations, and its max views read zero.
    function test_Instant_TheVaultItselfReadsZero() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        _request(v, bob, 1_000e12);
        assertGt(v.balanceOf(address(v)), 0, "PREMISE: the vault holds escrow");
        assertEq(v.maxRedeem(address(v)), 0, "the vault's own escrow reads as redeemable");
        assertEq(v.maxWithdraw(address(v)), 0, "the vault's own escrow reads as withdrawable");
    }

    // ---- the request beside it ----

    /// @notice AN EXIT NEVER TAKES THE REQUESTS' HOLD OR WRITES A REQUEST: it pays at most exitable less the hold, and the hold stands.
    /// @dev The hold is bob's request's worth capped by exitable, computed at read time; the exit moves its price by at most a wei.
    function test_Instant_AnExitWritesNoRequestState() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        uint256 loanId = _open(5_000e6);
        v.crank();
        _request(v, bob, 5_000e12);
        _repay(loanId, 1_000e6);
        v.crank(); // the repayment reaches idle at the crank
        (uint256 e0, uint256 h0) = v.holds();
        uint256 q0 = v.requestedShares();
        assertGt(h0, 0, "PREMISE: bob's request holds cash");
        uint256 paid = _redeem(v, alice, 2_000e12);
        assertLe(paid, e0 - h0, "the exit paid past exitable less the requests' hold");
        (, uint256 h1) = v.holds();
        assertApproxEqAbs(h1, h0, 1, "the exit moved the requests' hold");
        assertEq(v.requestedShares(), q0, "the exit moved the requests");
        (uint256 esc,) = v.requestOf(bob);
        assertEq(esc, 5_000e12, "the exit moved bob's request");
    }

    // ---- the last free holder ----

    /// @notice THE LAST FREE HOLDER REQUESTS WHILE A GAIN VESTS: escrow and donated shares on the vault do not count as holders.
    /// @notice The refusal is keyed on the FREE supply, so a vault-held share does not let the last holder take the pile.
    function test_LastOut_TheLastFreeHolderIsRefusedWithEscrowAndDonationsPresent() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
        _request(v, bob, v.balanceOf(bob) - 1e12); // bob requests all but one unit's worth
        vm.prank(bob);
        v.transfer(address(v), 1e12); // and donates the rest to the vault
        assertEq(v.balanceOf(bob), 0, "PREMISE: bob holds nothing free");
        assertGt(v.balanceOf(address(v)), 0, "PREMISE: the vault holds escrow and a donation");
        _gift(v, 500e6);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a gain is vesting");
        uint256 all = v.balanceOf(alice);
        assertEq(all, v.totalSupply() - v.balanceOf(address(v)), "PREMISE: alice is the whole free supply");
        assertLt(all, v.totalSupply(), "PREMISE: and not the whole supply");

        assertEq(v.maxRedeem(alice), 0, "maxRedeem quoted the last free holder past a vesting gain");
        assertEq(v.maxWithdraw(alice), 0, "maxWithdraw quoted the last free holder past a vesting gain");
        vm.prank(alice);
        vm.expectRevert(AceVault.LastOutVesting.selector);
        v.redeem(all, alice, alice);

        assertGt(_redeem(v, alice, all - 1), 0, "a holder leaving one share behind was refused");
    }

    /// @notice ONCE THE GAIN HAS VESTED THE LAST HOLDER LEAVES AT ONCE, with nothing deferred left to take.
    function test_LastOut_OnceVestedTheLastHolderLeaves() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _gift(v, 500e6);
        v.crank();
        uint256 all = v.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(AceVault.LastOutVesting.selector);
        v.redeem(all, alice, alice);
        _warpBy(VEST_W);
        uint256 got = _redeem(v, alice, v.balanceOf(alice));
        assertApproxEqAbs(got, 10_500e6, 2, "the vested last holder was not paid the whole vault");
    }

    // ---- in a dip ----

    /// @notice AN EXIT IN A DIP TAKES THE DIP'S PRICE AND LEAVES IT: the stayers' price stands.
    function test_Instant_AnExitInADipTakesTheDipPriceAndLeavesIt() public {
        CuratorVault v = _dipRig();
        (uint256 a0, uint256 q0) = (v.totalAssets(), _quoteSupply(v));
        uint256 sh = v.balanceOf(bob) / 4;
        uint256 quote = v.previewRedeem(sh);
        assertEq(_redeem(v, bob, sh), quote, "the exit in the dip paid other than the dip's price");
        assertTrue(_samePrice(a0, q0, v.totalAssets(), _quoteSupply(v)), "the exit moved the stayers' price");
    }

    /// @dev Two LPs and a loan, which then settles, so NAV sits in the dip with cash still free to exit against.
    function _dipRig() internal returns (CuratorVault v) {
        v = _instantVault(0);
        _lpDeposit(v, alice, 5_000e6);
        _lpDeposit(v, bob, 5_000e6);
        uint256 doomed = _open(6_000e6);
        v.crank();
        _warpBy(VEST_W);
        v.crank();
        uint256 g = v.grossNav();
        _finalize(doomed);
        v.crank();
        assertLt(v.grossNav(), g, "PREMISE: the settle stepped NAV down");
    }

    /// @notice AN INSTANT VAULT'S PREVIEWS QUOTE, at the fee-inclusive price, and a quote is what the verb pays.
    function test_Previews_AnInstantVaultQuotesBothExits() public {
        CuratorVault v = _grownFeeVault();
        uint256 a = v.totalAssets();
        uint256 q = _quoteSupply(v);
        assertEq(v.previewRedeem(1e12), Math.mulDiv(1e12, a + 1, q), "previewRedeem is not the floor at the fee-inclusive price");
        assertEq(v.previewWithdraw(1e6), Math.mulDiv(1e6, q, a + 1, Math.Rounding.Ceil), "previewWithdraw is not the ceiling");
    }
}
