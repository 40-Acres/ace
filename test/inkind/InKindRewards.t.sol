// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IInKindVault} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindRewards
/// @notice Rulings 3 and 4 as amended: a seized pot is credited pro rata to every tracked share, claimable from the block AFTER the collect.
/// @notice Eligibility is the tracked balances at the end of the collect's block, whatever their age.
/// @notice A zero tracked supply leaves the pot pending for the first holder; entry shuts while a pot is uncollected.
contract InKindRewardsTest is InKindRig {
    /// @dev Alice deposits the LP cash and holds it one minimum term.
    function _aliceIn() internal returns (uint256 shares) {
        shares = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        assertEq(_trackedSupply(), shares, "premise: alice is the whole tracked supply");
    }

    // ---- the block boundary ----

    /// @notice Nothing is claimable in the collect's own block, and a claim there pays nothing; the next block the whole pot is.
    function test_credit_isClaimableTheBlockAfterTheCollect() public {
        _aliceIn();
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        assertEq(_claimable(alice, address(tokA)), 0, "the collect's block credits nobody yet");
        assertEq(_claim(alice, address(tokA)), 0, "a claim in that block pays nothing");
        assertEq(tokA.balanceOf(alice), 0, "and moves nothing");
        _nextBlock();
        uint256 c = _claimable(alice, address(tokA));
        assertApproxEqAbs(c, pot, 1, "the sole holder is credited the whole pot, floored");
        assertLe(c, pot, "never more than came home");
        vm.expectEmit(true, true, false, true, address(vault));
        emit IInKindVault.Claimed(alice, address(tokA), alice, c);
        assertEq(_claim(alice, address(tokA)), c, "the claim pays what the view showed");
        assertEq(tokA.balanceOf(alice), c, "into the holder's own wallet, without exiting");
        assertEq(_claimable(alice, address(tokA)), 0, "and leaves nothing claimable");
        assertEq(_claim(alice, address(tokA)), 0, "a second claim pays nothing");
    }

    /// @notice Two tokens collected in one batch both credit from the next block.
    function test_credit_twoTokensInOneBatch() public {
        _aliceIn();
        uint256 a = _open(address(tokA));
        uint256 b = _open(address(tokB));
        _toExpiry(a);
        (uint256 potA, uint256 potB) = (_expectedPot(a), _expectedPot(b));
        vm.prank(keeper);
        vault.collectForfeited(_ids(a, b));
        _nextBlock();
        assertApproxEqAbs(_claimable(alice, address(tokA)), potA, 1, "token A credited");
        assertApproxEqAbs(_claimable(alice, address(tokB)), potB, 1, "token B credited");
        vm.prank(alice);
        uint256[] memory paid = vault.claim(_toks(address(tokA), address(tokB)), alice);
        assertEq(tokA.balanceOf(alice), paid[0], "token A paid");
        assertEq(tokB.balanceOf(alice), paid[1], "token B paid");
    }

    /// @notice The fold lands BEFORE a later block's first move: shares moved in the block after the collect keep its pot with the sender.
    function test_fold_landsBeforeTheNextBlocksFirstMove() public {
        uint256 sb = _lp(bob, LP_CASH);
        _warpBy(MIN_TENOR);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        vm.prank(bob);
        vault.transfer(carol, sb);
        assertEq(_tracked(carol), sb, "premise: carol received bob's shares in the block after the collect");
        _nextBlock();
        assertEq(_claimable(carol, address(tokA)), 0, "carol held them only after the collect's block, so its pot is not hers");
        assertApproxEqAbs(_claimable(bob, address(tokA)), pot, 1, "the end-of-block holder keeps it all");
    }

    // ---- who is credited ----

    /// @notice An exit neither pays seized tokens nor forfeits ones already credited.
    function test_exit_neitherPaysNorForfeitsAccruedTokens() public {
        _aliceIn();
        _lp(bob, 1_000e6);
        _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        uint256 c = _claimable(alice, address(tokA));
        assertGt(c, 0, "premise: alice is credited");
        uint256 sh = vault.maxRedeem(alice);
        assertGt(sh, 0, "premise: alice can exit");
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertEq(tokA.balanceOf(alice), 0, "the exit paid no seized tokens");
        assertEq(_claimable(alice, address(tokA)), c, "and forfeited none");
        assertEq(_claim(alice, address(tokA)), c, "they stay claimable after the exit");
    }

    /// @notice Holders before the settle share the pot pro rata to their tracked balances.
    function test_holdersShareProRata() public {
        uint256 sa = _lp(alice, 600_000e6);
        uint256 sc = _lp(carol, 400_000e6);
        _warpBy(MIN_TENOR);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        uint256 ca = _claimable(alice, address(tokA));
        uint256 cc = _claimable(carol, address(tokA));
        assertApproxEqAbs(ca, Math.mulDiv(pot, sa, sa + sc), 1, "alice's slice is her tracked share");
        assertApproxEqAbs(cc, Math.mulDiv(pot, sc, sa + sc), 1, "carol's slice is hers");
        assertLe(ca + cc, pot, "the slices never sum past the pot");
    }

    /// @notice A holder who entered during the loan, however late, shares its pot pro rata: no age is asked of a share.
    function test_aHolderEnteringDuringTheLoanSharesProRata() public {
        uint256 sa = _aliceIn();
        uint256 loanId = _open(address(tokA));
        _warpBy(1 hours);
        uint256 sb = _lp(bob, LP_CASH);
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        _collect(loanId);
        _nextBlock();
        assertApproxEqAbs(_claimable(bob, address(tokA)), Math.mulDiv(pot, sb, sa + sb), 1, "bob, in for the loan's last stretch, shares the pot");
        assertApproxEqAbs(_claimable(alice, address(tokA)), Math.mulDiv(pot, sa, sa + sb), 1, "and alice takes only her own slice");
    }

    /// @notice No entrant buys in after a third-party settle: entry refuses until the collect, and one admitted after it gets none of that pot.
    function test_aPostSettleEntrantGetsNothingOfThatPot() public {
        _aliceIn();
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        _expectEntryShut(bob, LP_CASH, "a post-settle entrant before the collect");
        _warpBy(1 hours);
        _collect(loanId);
        _nextBlock();
        _lp(bob, LP_CASH);
        _nextBlock();
        assertEq(_claimable(bob, address(tokA)), 0, "the entrant admitted after the collect's block gets none of that pot");
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot, 1, "the pre-settle holder takes the pot");
    }

    /// @notice A holder in before a third-party settle counts at the collect, however long after the settle the collect lands.
    function test_aHolderInBeforeTheSettleCounts() public {
        uint256 sa = _aliceIn();
        uint256 loanId = _open(address(tokA));
        _warpBy(1 hours);
        uint256 sc = _lp(carol, 500_000e6);
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        _warpBy(1 hours);
        _nextBlock();
        assertEq(_tracked(carol), sc, "premise: carol holds her shares across the settle-to-collect gap");
        _warpBy(30 minutes);
        _collect(loanId);
        _nextBlock();
        assertApproxEqAbs(_claimable(carol, address(tokA)), Math.mulDiv(pot, sc, sa + sc), 1, "carol held at the collect, so she shares");
    }

    /// @notice A holder nobody touched still earns: its slice is waiting the block after the collect.
    function test_anUntouchedHolderEarnsItsSlice() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 sc = _lp(carol, LP_CASH);
        _warpBy(MIN_TENOR);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        assertApproxEqAbs(_claimable(carol, address(tokA)), Math.mulDiv(pot, sc, sa + sc), 1, "carol's untouched shares earned her slice");
        assertApproxEqAbs(_claimable(alice, address(tokA)), Math.mulDiv(pot, sa, sa + sc), 1, "and alice hers");
    }

    // ---- the zero path ----

    /// @notice With nothing tracked the pot is credited to nobody; it waits, and the first holder whose shares hold to a block's end takes it.
    function test_zeroTrackedSupplyLeavesThePotForTheFirstHolder() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        vm.prank(alice);
        vault.transfer(address(vault), sa);
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        _collect(loanId);
        assertEq(_trackedSupply(), 0, "premise: alice gifted every share to the vault, so nothing is tracked at the collect");
        _nextBlock();
        assertEq(_claimable(alice, address(tokA)), 0, "nobody is credited");
        _warpBy(1 hours);
        _lp(bob, 1_000e6);
        _nextBlock();
        _collect(loanId);
        _nextBlock();
        assertApproxEqAbs(_claimable(bob, address(tokA)), pot, 1, "the pot waited and the first holder took it");
    }

    // ---- entry shuts on an uncollected pot ----

    /// @notice A deposit and a mint refuse while the hub reports this vault's settled pot uncollected: an entrant would share a loss it never carried.
    function test_aDepositAfterAThirdPartySettleRefuses() public {
        _aliceIn();
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(unsold, 1, "premise: the hub reports an uncollected pot of this vault's");
        _expectEntryShut(bob, 10_000e6, "a deposit after the settle");
        uint256 assets = vault.previewMint(1e12);
        _armDeposit(carol, assets);
        vm.prank(carol);
        vm.expectRevert(IInKindVault.InventoryUnsold.selector);
        vault.mint(1e12, carol);
    }

    // ---- claim hygiene ----

    /// @notice A claim to the vault itself is refused: tokens landing there would be uncredited and stranded.
    function testRevert_claim_toTheVault() public {
        _aliceIn();
        vm.prank(alice);
        vm.expectRevert(IInKindVault.ClaimToVault.selector);
        vault.claim(_toks(address(tokA)), address(vault));
    }

    /// @notice A raw transfer of a listed token to the vault is never credited: only a measured redeem is.
    function test_aRawDonationIsNeverCredited() public {
        _aliceIn();
        tokA.mint(address(vault), 1_000_000e18);
        _nextBlock();
        _nextBlock();
        assertEq(_claimable(alice, address(tokA)), 0, "a donation credits nobody");
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot, 1, "a later collect credits its own pot and not the donation");
    }

    /// @notice A claim may name another wallet of the holder's as `to`.
    function test_claim_paysToTheNamedWallet() public {
        _aliceIn();
        _defaultAndCollect(_open(address(tokA)));
        _nextBlock();
        uint256 c = _claimable(alice, address(tokA));
        vm.prank(alice);
        vault.claim(_toks(address(tokA)), dave);
        assertEq(tokA.balanceOf(dave), c, "paid where the holder pointed");
        assertEq(tokA.balanceOf(alice), 0, "and not to the holder");
    }
}
