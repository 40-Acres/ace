// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {InstantExitRig} from "./CuratorVaultInstantExit.t.sol";

/// @title CuratorVaultInstantExitEdges
/// @notice The instant exit's boundary rows: an exactly-emptied vault, the rounding of each verb against its max view.
/// @notice Also the auth on `withdraw`, the event's sender, the escrow's safety, and the drain's keys at their edges.
contract CuratorVaultInstantExitEdgesTest is InstantExitRig {
    address internal dave = address(0xDA7E);

    event DrainSet(address indexed by, bool on);

    function _seeded() internal returns (CuratorVault v) {
        v = _instantVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _lpDeposit(v, bob, 10_000e6);
    }

    /// @dev The instant bound: exitable cash the requests do not hold.
    function _instantBound(CuratorVault v) internal view returns (uint256) {
        (uint256 exitable, uint256 heldReq) = v.holds();
        return exitable - heldReq;
    }

    // ---- boundaries ----

    /// @notice THE SOLE HOLDER OF AN UNLENT VAULT TAKES ITS CASH EXACTLY: both max views name the whole of it, each verb empties it to zero.
    /// @notice The emptied vault then re-opens at par, with nothing stranded for the next entrant.
    function test_Boundary_TheSoleHolderOfAnUnlentVaultEmptiesThePotExactly() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 20_000e6);
        uint256 free = _instantBound(v);
        uint256 all = v.balanceOf(alice);
        assertEq(free, 20_000e6, "PREMISE: the whole deposit sits free in the vault");
        assertEq(v.maxWithdraw(alice), free, "the sole holder's cash bound is not exactly the vault's cash");
        assertEq(v.maxRedeem(alice), all, "the sole holder's share bound is not exactly the holding");

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        assertEq(v.withdraw(free, alice, alice), all, "withdrawing the exact cash did not burn exactly the holding");
        assertEq(usdc.balanceOf(address(v)), 0, "withdrawing the exact cash left cash in the vault");
        vm.revertToState(snap);

        assertEq(_redeem(v, alice, all), free, "redeeming the whole holding did not pay exactly the vault's cash");
        assertEq(usdc.balanceOf(address(v)), 0, "redeeming the whole holding left cash in the vault");
        assertEq(v.totalSupply(), 0, "redeeming the whole holding left a share");
        assertEq(_lpDeposit(v, bob, 1_000e6), 1_000e12, "a vault emptied by an instant exit re-opened off par");
    }

    // ---- rounding: the views against the verbs ----

    /// @notice A WITHDRAW ROUNDS ITS BURN UP AGAINST THE EXITER, and the preview names that exact ceiling.
    /// @dev The price is made non-integral first, so a floor and a ceiling differ and a flipped rounding cannot hide.
    function test_Rounding_AWithdrawBurnsTheCeilingAndARedeemPaysTheFloor() public {
        CuratorVault v = _grownFeeVault();
        uint256 want = 1_234_567_891;
        (uint256 a, uint256 q) = (v.totalAssets(), _quoteSupply(v));
        uint256 lo = Math.mulDiv(want, q, a + 1);
        assertTrue(mulmod(want, q, a + 1) != 0, "PREMISE: the burn is not integral, so its floor and ceiling differ");
        assertEq(v.previewWithdraw(want), lo + 1, "previewWithdraw is not the ceiling");
        vm.prank(alice);
        assertEq(v.withdraw(want, alice, alice), lo + 1, "the withdraw burned other than the ceiling");

        uint256 sh = 777_777_777_777;
        (a, q) = (v.totalAssets(), _quoteSupply(v));
        assertTrue(mulmod(sh, a + 1, q) != 0, "PREMISE: the payment is not integral");
        uint256 floor_ = Math.mulDiv(sh, a + 1, q);
        assertEq(v.previewRedeem(sh), floor_, "previewRedeem is not the floor");
        assertEq(_redeem(v, bob, sh), floor_, "the redeem paid other than the floor");
    }

    /// @notice SAMPLER: the max views never offer more than the verbs accept, each max ask pays its preview, and one wei more is refused.
    /// @dev Two LPs, an optional fee, an optional loan and an optional counted rise, read at a fuzzed later time.
    function testFuzz_MaxViewsNeverPromiseMoreThanTheVerbsPay(uint256 d1, uint256 d2, uint256 lendSeed, uint256 giftSeed, uint256 dt, bool fee) public {
        CuratorVault v = _instantVault(fee ? FEE : 0);
        uint256 a1 = bound(d1, 1e6, 50_000e6);
        uint256 a2 = bound(d2, 1e6, 50_000e6);
        _lpDeposit(v, alice, a1);
        _lpDeposit(v, bob, a2);
        uint256 lend = bound(lendSeed, 0, Math.min((a1 + a2) * 9 / 10, 15_000e6));
        if (lend >= 20e6) {
            _open(lend);
            v.crank();
        }
        uint256 g = bound(giftSeed, 0, 2_000e6);
        if (g >= 10e6) {
            _gift(v, g);
            v.crank();
        }
        _warpBy(bound(dt, 0, 2 * uint256(VEST_W)));
        _checkMaxes(v, alice);
        _checkMaxes(v, bob);
    }

    function _checkMaxes(CuratorVault v, address who) internal {
        uint256 bal = v.balanceOf(who);
        uint256 free = _instantBound(v);
        (uint256 r, uint256 w) = (v.maxRedeem(who), v.maxWithdraw(who));
        assertLe(r, bal, "maxRedeem offered past the holding");
        assertLe(w, free, "maxWithdraw offered past the instant bound");
        uint256 snap = vm.snapshotState();
        if (w != 0) {
            uint256 quote = v.previewWithdraw(w);
            vm.prank(who);
            assertEq(v.withdraw(w, who, who), quote, "withdraw(maxWithdraw) burned other than its preview");
            assertLe(quote, bal, "withdraw(maxWithdraw) burned past the holding");
            vm.revertToState(snap);
            vm.prank(who);
            vm.expectRevert();
            v.withdraw(w + 1, who, who);
        }
        if (r != 0) {
            uint256 quote = v.previewRedeem(r);
            vm.prank(who);
            assertEq(v.redeem(r, who, who), quote, "redeem(maxRedeem) paid other than its preview");
            assertLe(quote, free, "redeem(maxRedeem) paid past the instant bound");
            assertGt(quote, 0, "maxRedeem offered a redeem that pays nothing");
            vm.revertToState(snap);
        }
    }

    // ---- auth and the event ----

    /// @notice A SPENDER'S WITHDRAW SPENDS THE CEILING BURN from the allowance: one share-wei short is refused, by the standard error.
    function test_Auth_AWithdrawBySpenderSpendsTheCeilingBurn() public {
        CuratorVault v = _grownFeeVault();
        uint256 want = 1_234_567_891;
        uint256 burn = v.previewWithdraw(want);
        vm.prank(bob);
        v.approve(carol, burn - 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, burn - 1, burn));
        v.withdraw(want, carol, bob);

        vm.prank(bob);
        v.approve(carol, burn + 7);
        vm.prank(carol);
        assertEq(v.withdraw(want, carol, bob), burn, "the spender's withdraw burned other than its preview");
        assertEq(v.allowance(bob, carol), 7, "the spender's withdraw spent other than the burn");
        assertEq(usdc.balanceOf(carol), want, "the spender was not paid the asked cash");
    }

    /// @notice A SPENDER EXITS FOR THE OWNER, the event names the spender as sender, and a spent allowance is refused.
    function test_Auth_ASpenderExitsForTheOwnerAndTheEventNamesIt() public {
        CuratorVault v = _grownFeeVault();
        uint256 want = 1_000e6;
        uint256 burn = v.previewWithdraw(want);
        uint256 sh = 1_000e12;
        vm.prank(alice);
        v.approve(carol, burn + sh);

        uint256 bal0 = v.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(v));
        emit Withdraw(carol, dave, alice, want, burn);
        vm.prank(carol);
        v.withdraw(want, dave, alice);
        assertEq(bal0 - v.balanceOf(alice), burn, "the spender's withdraw burned other than the owner's preview");
        assertEq(usdc.balanceOf(dave), want, "the spender's withdraw did not pay the named receiver");

        uint256 quote = v.previewRedeem(sh);
        vm.expectEmit(true, true, true, true, address(v));
        emit Withdraw(carol, dave, alice, quote, sh);
        vm.prank(carol);
        v.redeem(sh, dave, alice);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, sh));
        v.redeem(sh, carol, alice);
    }

    // ---- the holding and the escrow ----

    /// @notice A REDEEM PAST THE HOLDING REVERTS by the share token's own error, and pays nothing.
    function test_Instant_ARedeemPastTheHoldingReverts() public {
        CuratorVault v = _seeded();
        uint256 bal = v.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, bal, bal + 1));
        v.redeem(bal + 1, alice, alice);
    }

    /// @notice NOBODY EXITS THE VAULT'S OWN ESCROW: naming the vault as owner needs an allowance it never grants.
    function test_Instant_NoCallerExitsTheVaultsOwnEscrow() public {
        CuratorVault v = _seeded();
        _request(v, bob, 5_000e12);
        uint256 escrow = v.balanceOf(address(v));
        assertEq(escrow, 5_000e12, "PREMISE: the vault holds bob's escrow");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1e12));
        v.redeem(1e12, carol, address(v));
        uint256 burn = v.previewWithdraw(1e6);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, burn));
        v.withdraw(1e6, carol, address(v));
        assertEq(v.balanceOf(address(v)), escrow, "a stranger moved the vault's escrow");
    }

    /// @notice THE LAST FREE HOLDER'S `withdraw` IS REFUSED TOO when it would burn the whole free supply over a vesting gain.
    /// @notice One asset-wei less burns less than the whole, and pays: the refusal is the exact predicate, not a band.
    function test_LastOut_AWithdrawOfTheWholeFreeSupplyIsRefused() public {
        CuratorVault v = _instantVault(0);
        _lpDeposit(v, alice, 10_000e6);
        _gift(v, 500e6);
        v.crank();
        assertGt(v.unvested(), 0, "PREMISE: a gain is vesting");
        uint256 all = v.balanceOf(alice);
        uint256 want = v.previewRedeem(all);
        assertEq(v.previewWithdraw(want), all, "PREMISE: that cash burns exactly the whole holding");
        assertEq(v.maxWithdraw(alice), 0, "maxWithdraw quoted the last free holder over a vesting gain");
        vm.prank(alice);
        vm.expectRevert(AceVault.LastOutVesting.selector);
        v.withdraw(want, alice, alice);

        assertLt(v.previewWithdraw(want - 1), all, "PREMISE: one asset-wei less burns less than the whole");
        vm.prank(alice);
        v.withdraw(want - 1, alice, alice);
        assertEq(usdc.balanceOf(alice), want - 1, "a withdraw leaving a share behind was not paid");
    }

    // ---- the drain's keys at their edges ----

    /// @notice SWITCHING ON A STANDING DRAIN IS A NO-OP THAT STILL SPEAKS: it stays on, names the second key, and one curator off lifts it.
    function test_Drain_SwitchingOnWhileItStandsStillSpeaks() public {
        CuratorVault v = _seeded();
        vm.prank(curator);
        v.setDrain(true);
        vm.expectEmit(true, true, true, true, address(v));
        emit DrainSet(guardian, true);
        vm.prank(guardian);
        v.setDrain(true);
        assertTrue(v.draining(), "a second switch-on lifted the standing drain");
        vm.prank(curator);
        v.setDrain(false);
        assertFalse(v.draining(), "one switch-off did not lift a twice-switched drain");
    }

    /// @notice THE GUARDIAN'S SWITCH-OFF IS REFUSED BY ITS KEY, whatever the state: an undrained vault reads `NotCurator` too.
    function test_Drain_TheGuardiansOffIsRefusedOnAnUndrainedVault() public {
        CuratorVault v = _seeded();
        vm.prank(guardian);
        vm.expectRevert(AceVault.NotCurator.selector);
        v.setDrain(false);
    }

    /// @notice A VAULT WITH NO GUARDIAN LEAVES THE CURATOR THE ONLY KEY: the zero address names nobody a stranger can be.
    function test_Drain_NoGuardianLeavesTheCuratorTheOnlyKey() public {
        VaultConfig memory cfg = _cfg(0);
        cfg.guardian = address(0);
        CuratorVault v = _deploy(cfg, "Keyless", "cKEY");
        assertEq(v.GUARDIAN(), address(0), "PREMISE: no guardian");
        vm.prank(guardian);
        vm.expectRevert(AceVault.NotCurator.selector);
        v.setDrain(true);
        vm.prank(curator);
        v.setDrain(true);
        assertTrue(v.draining(), "the curator could not switch a guardian-less vault");
    }
}
