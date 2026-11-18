// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AceVault, VaultConfig} from "../../../src/curator/AceVault.sol";
import {Listing} from "../../../src/entities/curated/CuratorTerms.sol";
import {CuratedVaults} from "../../utils/CuratedVaults.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultFeeMarkPerShare
/// @notice The fee high-water is stored in assets and moves per virtual share on every flow, so the gap per share is what no flow changes.
/// @notice An entry raises it by the larger of its cash and the high-water's own price; an exit scales it by the shares left, down, never under NAV.
/// @dev The virtual frame is the vault's: `supply + 1e6`, the offset every 4626 conversion prices against.
contract AceVaultFeeMarkPerShareTest is AceVaultRig {
    uint256 internal constant V = 1e6;
    uint256 internal constant P = 150_000e6;
    uint256 internal constant BIG_UNITS = 300_000e18;
    uint16 internal constant FEE = 2000;

    function _feeVault(uint16 bps) internal returns (AceVault v) {
        VaultConfig memory c = VaultConfig({
            ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: bps, vestWindow: VEST_W, seed: VaultSeed.SEED
        });
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: _row(address(record))});
        v = CuratedVaults.viaFactory(vaultFactory, bytes32(++vaultSalt), c, _curated(), l, "Fee", "fVLT");
    }

    /// @dev A fee vault seeded by alice, and by bob when `bobCash` is nonzero; a loan of P defaults and its pot is exempted, so a real gap stands.
    function _gapStanding(uint256 bobCash) internal returns (uint256 gap) {
        vault = _feeVault(FEE);
        _lp(alice, LP_CASH);
        if (bobCash != 0) _lp(bob, bobCash);
        uint256 loanId = _borrowAs(borrower, BIG_UNITS, P, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vault.crank();
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
        gap = vault.feeHighWater() - vault.totalAssets();
        assertGt(gap, P / 2, "premise: the loss stands as a gap under the high-water");
        assertEq(vault.balanceOf(curator), 0, "premise: the curator holds no shares");
    }

    function _sv() internal view returns (uint256) {
        return vault.totalSupply() + V;
    }

    /// @dev The high-water `h0` over virtual supply `sv0` carried to the vault's virtual supply now, rounded down.
    function _carried(uint256 h0, uint256 sv0) internal view returns (uint256) {
        return Math.mulDiv(h0, _sv(), sv0);
    }

    /// @dev Assert the high-water moved per virtual share across one flow, to an atom, and the gap per share with it, to its 4626 rounding.
    function _assertPerShare(uint256 h0, uint256 a0, uint256 sv0, string memory flow) internal view {
        uint256 sv1 = _sv();
        assertApproxEqAbs(vault.feeHighWater(), _carried(h0, sv0), 1, string.concat(flow, ": the mark did not move per virtual share"));
        uint256 tol = 2 + (sv1 > sv0 ? sv1 - sv0 : sv0 - sv1) / sv0;
        uint256 gap1 = vault.feeHighWater() - vault.totalAssets();
        assertApproxEqAbs(gap1, Math.mulDiv(h0 - a0, sv1, sv0), tol, string.concat(flow, ": the gap per virtual share moved"));
    }

    function _mintAs(address who, uint256 shares) internal {
        uint256 cost = vault.previewMint(shares);
        usdc.mint(who, cost);
        vm.startPrank(who);
        usdc.approve(address(vault), cost);
        vault.mint(shares, who);
        vm.stopPrank();
    }

    /// @notice FUZZ: deposit, mint, redeem, withdraw and claim each move the mark per virtual share to an atom, over a real gap.
    function testFuzz_FeeMark_EveryFlowKeepsTheGapPerVirtualShare(uint8[10] memory ops, uint64[10] memory amts) public {
        _gapStanding(500_000e6);
        for (uint256 i; i < ops.length; ++i) {
            uint256 amt = bound(amts[i], 1e6, 400_000e6);
            (uint256 h0, uint256 a0, uint256 sv0) = (vault.feeHighWater(), vault.totalAssets(), _sv());
            uint8 op = ops[i] % 5;
            if (op == 0) {
                _lp(bob, amt);
                _assertPerShare(h0, a0, sv0, "deposit");
            } else if (op == 1) {
                _mintAs(stranger, vault.previewDeposit(amt));
                _assertPerShare(h0, a0, sv0, "mint");
            } else if (op == 2) {
                uint256 sh = Math.min(vault.balanceOf(alice) / 2, vault.previewWithdraw(amt));
                if (sh == 0 || vault.previewRedeem(sh) == 0) continue;
                vm.prank(alice);
                vault.redeem(sh, alice, alice);
                _assertPerShare(h0, a0, sv0, "redeem");
            } else if (op == 3) {
                uint256 cash = Math.min(vault.maxWithdraw(bob) / 2, amt);
                if (cash == 0) continue;
                vm.prank(bob);
                vault.withdraw(cash, bob, bob);
                _assertPerShare(h0, a0, sv0, "withdraw");
            } else {
                uint256 sh = Math.min(vault.balanceOf(alice) / 2, vault.previewWithdraw(amt));
                if (sh == 0 || vault.previewRedeem(sh) == 0) continue;
                vm.prank(alice);
                vault.requestExit(sh);
                (h0, a0, sv0) = (vault.feeHighWater(), vault.totalAssets(), _sv());
                vm.prank(alice);
                vault.claimExit(sh, alice, 0);
                _assertPerShare(h0, a0, sv0, "claim");
            }
        }
    }

    /// @notice FUZZ: an entrant of any size leaves alice fee-free up to her own high-water, and the fee resumes only on growth past it.
    function testFuzz_FeeMark_AnEntrantOfAnySizeLeavesIncumbentsFeeFreeToTheirHighWater(uint256 entry) public {
        entry = bound(entry, 1e6, 100_000_000e6);
        _gapStanding(0);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 h = vault.feeHighWater();
        uint256 sv0 = _sv();
        _lp(bob, entry);
        uint256 h1 = vault.feeHighWater();
        assertGt(h1, h + entry, "premise: below the high-water the entry's scaled leg wins");
        uint256 lift = h1 - vault.totalAssets();
        usdc.mint(address(vault), lift);
        vault.crank();
        _warpBy(VEST_W + 1);
        vault.collectFee();
        assertEq(vault.balanceOf(curator), 0, "earning back to the high-water minted fee");
        assertApproxEqAbs(vault.previewRedeem(aliceShares), Math.mulDiv(h, aliceShares, sv0), 2, "alice is not back at her own high-water");
        uint256 delta = 10_000e6;
        usdc.mint(address(vault), delta);
        vault.crank();
        _warpBy(VEST_W + 1);
        vault.collectFee();
        uint256 paid = vault.previewRedeem(vault.balanceOf(curator));
        emit log_named_uint("fee paid on growth past the high-water", paid);
        assertApproxEqRel(paid, Math.mulDiv(delta, FEE, 10_000), 0.001e18, "the fee past the high-water is not f of the growth");
    }

    /// @notice THE DUST RATCHET: a near-sole holder exiting to one atom of NAV and re-entering, cycle after cycle, never widens the gap per share.
    /// @dev The price itself rises at dust, as the exit's rounding lands on the share left, and the mark may follow it; it may never pass it by more.
    function test_FeeMark_ExitToDustAndReEntryNeverRaisesTheGapPerShare() public {
        _gapStanding(0);
        for (uint256 c; c < 8; ++c) {
            (uint256 gap0, uint256 sv0) = (vault.feeHighWater() - vault.totalAssets(), _sv());
            uint256 bal = vault.balanceOf(alice);
            uint256 keep = Math.mulDiv(_sv(), 1, vault.totalAssets() + 1, Math.Rounding.Ceil);
            assertLt(keep, bal, "premise: alice holds more than one atom's shares");
            vm.prank(alice);
            vault.redeem(bal - keep, alice, alice);
            assertLe(vault.totalAssets(), vault.MIN_SEED() + 3, "premise: the exit left NAV at dust and the genesis seed");
            _lp(alice, LP_CASH);
            uint256 bound1 = Math.mulDiv(gap0, _sv(), sv0, Math.Rounding.Ceil) + 1;
            uint256 gap1 = vault.feeHighWater() - vault.totalAssets();
            emit log_named_uint("gap after the cycle", gap1);
            emit log_named_uint("the cycle's start gap carried to the new supply", bound1);
            assertLe(gap1, bound1, "an exit to dust and a re-entry widened the gap per share");
        }
    }

    /// @notice NO GAP: every flow moves the high-water exactly as an asset high-water does, its cash in or out, and fee lands as before.
    function testFuzz_FeeMark_WithNoGapEveryFlowIsTheAssetRuleToTheAtom(uint8[10] memory ops, uint64[10] memory amts) public {
        vault = _feeVault(FEE);
        _lp(alice, LP_CASH);
        _lp(bob, LP_CASH);
        for (uint256 i; i < ops.length; ++i) {
            uint256 amt = bound(amts[i], 1, 300_000e6);
            uint8 op = ops[i] % 6;
            if (op == 5) {
                usdc.mint(address(vault), amt / 10 + 1);
                vault.crank();
                _warpBy(VEST_W + 1);
                vault.collectFee();
                assertEq(vault.feeHighWater(), vault.totalAssets(), "a collection did not lift the mark to NAV");
                continue;
            }
            uint256 h0 = vault.feeHighWater();
            assertEq(h0, vault.totalAssets(), "premise: no gap stands");
            if (op == 0) {
                _lp(bob, amt);
                assertEq(vault.feeHighWater(), h0 + amt, "a no-gap deposit moved the mark by other than its cash");
            } else if (op == 1) {
                uint256 cost = vault.previewMint(vault.previewDeposit(amt));
                _mintAs(stranger, vault.previewDeposit(amt));
                assertEq(vault.feeHighWater(), h0 + cost, "a no-gap mint moved the mark by other than its cash");
            } else if (op == 2) {
                uint256 sh = Math.min(vault.balanceOf(alice) / 2, vault.previewWithdraw(amt));
                if (sh == 0 || vault.previewRedeem(sh) == 0) continue;
                vm.prank(alice);
                uint256 out = vault.redeem(sh, alice, alice);
                assertEq(vault.feeHighWater(), h0 - out, "a no-gap redeem moved the mark by other than its cash");
            } else if (op == 3) {
                uint256 cash = Math.min(vault.maxWithdraw(bob) / 2, amt);
                if (cash == 0) continue;
                vm.prank(bob);
                vault.withdraw(cash, bob, bob);
                assertEq(vault.feeHighWater(), h0 - cash, "a no-gap withdraw moved the mark by other than its cash");
            } else {
                uint256 sh = Math.min(vault.balanceOf(alice) / 2, vault.previewWithdraw(amt));
                if (sh == 0 || vault.previewRedeem(sh) == 0) continue;
                vm.startPrank(alice);
                vault.requestExit(sh);
                uint256 out = vault.claimExit(sh, alice, 0);
                vm.stopPrank();
                assertEq(vault.feeHighWater(), h0 - out, "a no-gap claim moved the mark by other than its cash");
            }
            assertEq(vault.feeHighWater(), vault.totalAssets(), "a no-gap flow opened a gap");
        }
    }

    /// @notice A no-gap deposit and a no-gap mint each raise the high-water by exactly the cash they took.
    function test_FeeMark_ANoGapEntryRaisesTheMarkByExactlyItsCash() public {
        vault = _feeVault(FEE);
        _lp(alice, LP_CASH);
        usdc.mint(address(vault), 50_000e6);
        vault.crank();
        _warpBy(VEST_W + 1);
        vault.collectFee();
        assertGt(vault.balanceOf(curator), 0, "premise: a fee was collected, so the price sits off par");
        uint256 h0 = vault.feeHighWater();
        assertEq(h0, vault.totalAssets(), "premise: no gap");
        _lp(bob, 123_456_789);
        assertEq(vault.feeHighWater(), h0 + 123_456_789, "a no-gap deposit raised the mark by other than its cash");
        uint256 h1 = vault.feeHighWater();
        uint256 cost = vault.previewMint(7e15);
        _mintAs(stranger, 7e15);
        assertEq(vault.feeHighWater(), h1 + cost, "a no-gap mint raised the mark by other than its cash");
    }
}
