// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {CuratorVaultExitsRig, ICuratorVaultExits} from "./CuratorVaultExitsRig.sol";

/// @title CuratorVaultLastOutUnderAFee
/// @notice The last-out refusal and the last requester's release under a live fee: the curator's own shares are not a holder the pile vests to.
/// @notice Written RED against the code that counted the curator's fee shares as free supply, where neither bound for an LP.
/// @dev The release now runs before the claim's fee collection, so the fee is charged on the pile and `maxClaim` replays both.
contract CuratorVaultLastOutUnderAFeeTest is CuratorVaultExitsRig {
    uint16 internal constant BPS = 1000; // a 10% fee: the curator holds shares and a fee is pending at every verb
    uint256 internal constant EARNED = 1_000e6; // a first gain, vested and charged, so the curator holds fee shares
    uint256 internal constant PILE = 2_000e6; // a second gain, a quarter vested at the exit, so a fee is pending on that quarter
    uint256 internal constant LENT = 6_000e6; // drawn in the binding rig, so exitable covers less than the last request

    /// @dev A fee vault: alice its one LP, bob a second when `second`, the curator holding the fee on a vested gain, and a pile a quarter vested.
    function _rig(bool lend, bool second) internal returns (CuratorVault v) {
        v = _vault(BPS);
        _lpDeposit(v, alice, SEED);
        if (second) _lpDeposit(v, bob, SEED); // before the pile: the gate shuts entry while it vests
        if (lend) _crank(v, _open(LENT), T2, 0);
        _gift(v, EARNED);
        v.crank();
        _warpBy(VEST_W);
        v.collectFee();
        _gift(v, PILE);
        v.crank();
        _warpBy(VEST_W / 4);
        assertGt(v.balanceOf(curator), 0, "PREMISE: the curator holds fee shares");
        assertGt(v.pendingFeeShares(), 0, "PREMISE: a fee is pending on the vested quarter");
        assertGt(v.unvested(), 0, "PREMISE: three quarters of the pile still vest");
    }

    /// @dev The fee on the whole rise past the high-water at the gross book, the pile included.
    function _feeOnRise(CuratorVault v) internal view returns (uint256) {
        return Math.mulDiv(v.grossNav() - v.feeHighWater(), BPS, 10_000);
    }

    /// @notice REPRO: THE LAST LP'S INSTANT FULL EXIT IS REFUSED UNDER A FEE, and both max views read zero for it.
    /// @dev RED before: the curator's fee shares were free supply, so alice's shares were never all of it and she left at net.
    function test_LastOutUnderAFee_TheLastLpsInstantFullExitIsRefused() public {
        CuratorVault v = _rig(false, false);
        uint256 all = v.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(ICuratorVaultExits.LastOutVesting.selector);
        v.redeem(all, alice, alice);
        assertEq(v.maxRedeem(alice), 0, "maxRedeem offered the last LP an exit the verb refuses");
        assertEq(v.maxWithdraw(alice), 0, "and so did maxWithdraw");
    }

    /// @notice REPRO: THE LAST LP'S CLAIM RELEASES THE PILE UNDER A FEE: alice is paid her share of the book, and the curator keeps only its own.
    /// @dev RED before: the claim's fee mint made the curator a free holder, no release ran, and the pile vested to the fee shares.
    function test_LastOutUnderAFee_TheLastLpsClaimReleasesThePileAndTheCuratorKeepsItsShare() public {
        CuratorVault v = _rig(false, false);
        uint256 book = v.grossNav();
        uint256 cut = Math.mulDiv(v.balanceOf(curator), book, v.totalSupply()) + _feeOnRise(v); // its shares' cut of the book, plus the fee
        uint256 all = v.balanceOf(alice);
        _request(v, alice, all);
        uint256 paid = _claim(v, alice, all);
        assertEq(v.unvested(), 0, "the last LP's claim did not release the pile beside the curator's fee shares");
        _warpBy(VEST_W);
        uint256 curatorWorth = v.convertToAssets(v.balanceOf(curator));
        emit log_named_uint("the book", book);
        emit log_named_uint("alice paid", paid);
        emit log_named_uint("the curator's worth a window later", curatorWorth);
        assertLe(curatorWorth, cut + 2, "the curator's fee shares kept more than their cut of the book and the fee");
        assertApproxEqAbs(paid + curatorWorth, book, 3, "the book was not split between the leaving LP and the curator");
    }

    /// @notice A SECOND LP KEEPS THE RELEASE SHUT: alice's claim beside bob's free shares is paid net, and her share of the pile stays with him.
    /// @dev The sandwich guard: only the last holder besides the curator releases. A CONTROL, green before the fix as after it.
    function test_LastOutUnderAFee_ASecondLpKeepsTheReleaseShut() public {
        CuratorVault v = _rig(false, true);
        uint256 all = v.balanceOf(alice);
        uint256 net = _worth(v, all);
        _request(v, alice, all);
        assertEq(_x(v).maxClaim(alice), all, "PREMISE: exitable covers the whole request");
        uint256 paid = _claim(v, alice, all);
        assertGt(v.unvested(), 0, "a claim beside a second LP released the pile");
        assertApproxEqAbs(paid, net, 1, "a claim beside a second LP was not paid at the net price");
    }

    /// @notice REPRO: `maxClaim` IS WHAT THE CLAIM PAYS WHERE EXITABLE BINDS: it replays the release and the fee on the pile, and takes it all.
    /// @dev RED before: neither the view nor the verb released beside the curator's fee shares.
    function test_LastOutUnderAFee_MaxClaimReplaysTheReleaseAndTheFeeOnIt() public {
        CuratorVault v = _rig(true, false);
        uint256 all = v.balanceOf(alice);
        _request(v, alice, all);
        uint256 pot = _exitable(v);
        uint256 m = _x(v).maxClaim(alice);
        assertLt(m, all, "PREMISE: exitable covers less than the last request");
        uint256 paid = _claim(v, alice, m);
        assertEq(v.unvested(), 0, "the last LP's claim of maxClaim did not release");
        assertLe(paid, pot, "the claim paid past exitable");
        assertGe(paid + 2, pot, "maxClaim's answer did not take all of exitable at the released, fee-charged price");
    }

    /// @notice THE RELEASING CLAIM CHARGES THE FEE ON THE PILE: the release runs before the claim's collection, so the leaver pays the fee on it.
    /// @dev The fee shares the claim mints are worth the fee on the whole rise past the high-water, the unvested pile included.
    function test_LastOutUnderAFee_TheReleasingClaimChargesTheFeeOnThePile() public {
        CuratorVault v = _rig(false, false);
        uint256 fee = _feeOnRise(v);
        uint256 held = v.balanceOf(curator);
        _request(v, alice, v.balanceOf(alice));
        _claim(v, alice, _escrow(v, alice));
        assertEq(v.unvested(), 0, "PREMISE: the claim released the pile");
        uint256 minted = v.convertToAssets(v.balanceOf(curator) - held);
        emit log_named_uint("the fee on the rise past the high-water, the pile included", fee);
        emit log_named_uint("what the releasing claim's fee shares are worth", minted);
        assertApproxEqAbs(minted, fee, 2, "the releasing claim did not charge the fee on the pile");
    }

    /// @notice A VAULT NAMING ITSELF CURATOR IS REFUSED AT DEPLOY: its escrow would also be the curator's balance, counted out of an LP's free twice.
    /// @dev RED before: only a zero curator was refused, so the deploy landed, and an LP's count then lost the vault's balance twice.
    /// @dev That count is wrong at any escrow, and it underflows every LP exit and claim once escrow and donations pass half the supply.
    function test_LastOutUnderAFee_AVaultNamingItselfCuratorIsRefused() public {
        Listing[] memory l = _listing(); // FIRST: building the row's record spends a nonce
        VaultConfig memory c = _cfg(BPS);
        c.curator = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(AceVault.ZeroCurator.selector);
        new CuratorVault(c, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, l, "Self", "cSELF");
    }

    /// @notice THE CURATOR'S OWN FREE SHARES KEEP ITS CLAIM FROM RELEASING: as the last requester it is paid net, and `maxClaim` takes all of exitable.
    /// @dev A CONTROL, green before the fix as after it: the curator's release test counts its own free shares, the view's as the verb's.
    function test_LastOutUnderAFee_TheCuratorsOwnFreeSharesKeepItsClaimFromReleasing() public {
        CuratorVault v = _vault(BPS);
        _lpDeposit(v, curator, SEED); // the curator is the vault's one LP
        _crank(v, _open(LENT), T2, 0);
        _gift(v, EARNED);
        v.crank();
        _warpBy(VEST_W);
        v.collectFee();
        _gift(v, PILE);
        v.crank();
        _warpBy(VEST_W / 4);
        uint256 asked = (v.balanceOf(curator) * 3) / 4;
        _request(v, curator, asked);
        uint256 pot = _exitable(v);
        uint256 m = _x(v).maxClaim(curator);
        assertLt(m, asked, "PREMISE: exitable covers less than the curator's request");
        uint256 paid = _claim(v, curator, m);
        assertGt(v.unvested(), 0, "the curator's claim released the pile beside its own free shares");
        assertLe(paid, pot, "the claim paid past exitable");
        assertGe(paid + 2, pot, "maxClaim's answer did not take all of exitable at the net price the claim pays");
    }

    /// @notice THE CURATOR HOLDING THE WHOLE FREE SUPPLY IS REFUSED AS THE LAST OUT: with the LP's shares requested, it may not leave the pile at net.
    /// @notice With a fee pending it may leave its balance, as the exit's own mint leaves fresh fee shares free; both views say which.
    /// @dev A CONTROL, green before the fix as after it: the curator's own exit keeps the whole-free-supply test, its pending fee counted.
    function test_LastOutUnderAFee_TheCuratorHoldingTheWholeFreeSupplyIsRefused() public {
        CuratorVault v = _rig(false, false);
        _request(v, alice, v.balanceOf(alice));
        uint256 snap = vm.snapshotState();
        uint256 held = v.balanceOf(curator);
        assertEq(v.maxRedeem(curator), held, "with a fee pending, maxRedeem refused the curator a balance its exit's mint leaves short of all");
        vm.prank(curator);
        v.redeem(held, curator, curator);
        assertGt(v.balanceOf(curator), 0, "PREMISE: the exit's own fee shares stayed free behind it");
        vm.revertToState(snap);
        v.collectFee();
        assertEq(v.pendingFeeShares(), 0, "PREMISE: no fee is pending, so the curator's balance is the whole free supply");
        uint256 own = v.balanceOf(curator);
        assertEq(v.maxRedeem(curator), 0, "maxRedeem offered the curator, the last free holder, its whole balance over a vesting pile");
        vm.prank(curator);
        vm.expectRevert(ICuratorVaultExits.LastOutVesting.selector);
        v.redeem(own, curator, curator);
    }

    /// @notice THE CURATOR'S OWN EXIT IS TESTED AGAINST THE WHOLE FREE SUPPLY: at a balance equal to the last LP's it exits whole, as its views say.
    /// @dev An LP's test leaves the curator's shares out, so set against it the curator's own shares could match only by coincidence.
    function test_LastOutUnderAFee_TheCuratorsExitIsTestedAgainstTheWholeFreeSupply() public {
        CuratorVault v = _rig(false, false);
        uint256 a = v.balanceOf(alice);
        uint256 c = v.balanceOf(curator);
        if ((a - c) % 2 == 1) {
            vm.prank(alice);
            v.transfer(address(v), 1); // a donated share-wei, so the two balances can meet
            a -= 1;
        }
        vm.prank(alice);
        v.transfer(curator, (a - c) / 2);
        uint256 own = v.balanceOf(curator);
        assertEq(own, v.balanceOf(alice), "PREMISE: the curator holds exactly the last LP's free supply");
        assertEq(v.maxRedeem(curator), own, "maxRedeem tested the curator's whole balance against the LP free supply");
        vm.prank(curator);
        assertGt(v.redeem(own, curator, curator), 0, "the curator's whole exit was not paid");
        assertEq(v.balanceOf(alice), own, "and the last LP's shares stayed where they were");
    }
}
