// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AceVault, VaultConfig} from "../../../src/curator/AceVault.sol";
import {Listing} from "../../../src/entities/curated/CuratorTerms.sol";
import {CuratedVaults} from "../../utils/CuratedVaults.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title Suite_FeeShieldDilution
/// @notice RB-1 PoC, fixed: after a realized loss an entrant's cash raises the fee high-water at the high-water's own price per virtual share.
/// @notice World A has no entrant; world B has the curator's second address enter at the post-loss price; both end at the incumbents' pre-loss price.
/// @notice So the incumbents earn their own loss back fee-free in both worlds, and the curator's second address gains nothing for its entry.
/// @dev The loss is a defaulted pot the guardian exempts: on a record market a sold pot recovers about its claim, so a standing loss needs the exemption.
contract Suite_FeeShieldDilution is AceVaultRig {
    uint256 internal constant P = 150_000e6; // the loss, less the escrow the settle lands
    uint256 internal constant BIG_UNITS = 300_000e18; // the line is about 117,000 units at the buffered 1.8 price
    uint256 internal constant ENTRY = 8_500_000e6; // lens B's entrant: about ten times the incumbents' shares at the post-loss price
    uint256 internal constant DUST = 10; // atoms of rounding a world may differ by
    uint256 internal constant V = 1e6; // the vault's virtual shares
    address internal second = address(0xC0A12); // the curator's second address

    struct World {
        uint256 alice; // alice's shares' worth after the recovery and a collection
        uint256 feeShares; // the curator's fee shares minted by then
        int256 extra; // what the curator's two addresses hold past the entry's own pro-rata share of NAV
    }

    /// @dev A curated hub-ask vault charging `bps`, listing the rig collateral, through the rig's factory.
    function _feeVault(uint16 bps) internal returns (AceVault v) {
        VaultConfig memory c = VaultConfig({
            ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: bps, vestWindow: VEST_W, seed: VaultSeed.SEED
        });
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: _row(address(record))});
        v = CuratedVaults.viaFactory(vaultFactory, bytes32(++vaultSalt), c, _curated(), l, "Fee", "fVLT");
    }

    /// @dev alice seeds a fresh vault at `bps`; a loan of P defaults and settles; the guardian exempts the dead pot, so entry reopens over the loss.
    /// @return g The fee-free gap at the reopening, `feeHighWater - totalAssets`.
    function _lossStanding(uint16 bps) internal returns (uint256 g) {
        vault = _feeVault(bps);
        _lp(alice, LP_CASH);
        uint256 loanId = _borrowAs(borrower, BIG_UNITS, P, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vault.crank();
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
        assertGt(vault.maxDeposit(second), 0, "premise: the exemption reopened entry over the standing loss");
        assertEq(vault.pendingFeeShares(), 0, "premise: under the high-water nothing is owed");
        g = vault.feeHighWater() - vault.totalAssets();
    }

    /// @dev One world from the reopening: an entry of `entry` (none at zero), earnings putting the per-share gross back at the high-water's, a collection.
    /// @dev The earnings are read off the pre-entry high-water in the vault's own virtual frame, never off the mark the entry left.
    function _world(uint256 entry) internal returns (World memory w) {
        uint256 s = vault.totalSupply();
        uint256 h0 = vault.feeHighWater();
        uint256 n = entry == 0 ? 0 : _lp(second, entry);
        uint256 e = Math.mulDiv(h0, s + n + V, s + V) - vault.totalAssets(); // the earnings returning the gross per virtual share to its pre-loss level
        usdc.mint(address(vault), e);
        vault.crank();
        _warpBy(VEST_W + 1);
        vault.collectFee();
        w.alice = vault.previewRedeem(vault.balanceOf(alice));
        w.feeShares = vault.balanceOf(curator);
        uint256 own = Math.mulDiv(n, vault.totalAssets(), s + n); // the entry's pro-rata share of NAV, had no fee minted
        w.extra = int256(vault.previewRedeem(vault.balanceOf(second)) + vault.previewRedeem(w.feeShares)) - int256(own);
    }

    /// @dev Both worlds at `bps` with an entry of `entry`; returns the gap, alice's loss in B against A, the old closed form, and world B.
    function _run(uint16 bps, uint256 entry) internal returns (uint256 g, int256 loss, uint256 old, World memory b) {
        g = _lossStanding(bps);
        uint256 s = vault.totalSupply();
        uint256 snap = vm.snapshotState();
        World memory a = _world(0);
        assertEq(a.feeShares, 0, "world A: earning back the loss charges no fee");
        assertApproxEqAbs(a.alice, LP_CASH, 10, "world A: alice ends at her pre-loss value");
        vm.revertToState(snap);
        b = _world(entry);
        uint256 n = vault.balanceOf(second);
        loss = int256(a.alice) - int256(b.alice);
        old = Math.mulDiv(Math.mulDiv(g, bps, 10_000), n, s + n);
        emit log_named_uint("fee bps", bps);
        emit log_named_uint("gap G at the reopening", g);
        emit log_named_uint("incumbent shares s", s);
        emit log_named_uint("entrant shares n", n);
        emit log_named_uint("world A alice", a.alice);
        emit log_named_uint("world B alice", b.alice);
        emit log_named_int("alice's loss, B against A", loss);
        emit log_named_uint("f * G * n / (s + n), the take under an asset high-water", old);
        emit log_named_int("curator two-address extra in B", b.extra);
    }

    /// @dev World B charged nothing and moved nothing: no fee shares, alice and the curator's two addresses within dust of world A.
    function _assertNoTake(int256 loss, World memory b) internal pure {
        assertEq(b.feeShares, 0, "world B: the incumbents' own recovery minted fee");
        assertLe(loss, int256(DUST), "alice paid for the entrant's climb");
        assertGe(loss, -int256(DUST), "alice gained past rounding");
        assertLe(b.extra, int256(DUST), "the curator's two addresses gained from the entry");
    }

    /// @notice Lens B's run: 20% fee, a 150,000 loss, the curator's second address enters 8,500,000 at 0.85; alice pays no fee on her own recovery.
    function test_RB1_anEntrantAfterALossLeavesTheIncumbentsFeeFreeOnTheirOwnRecovery() public {
        (uint256 g, int256 loss, uint256 old, World memory b) = _run(2000, ENTRY);
        assertGt(old, Math.mulDiv(g, 2000, 10_000) / 2, "premise: an asset high-water would have taken over half of f * G");
        _assertNoTake(loss, b);
    }

    /// @notice The same run at the 50% ceiling: still nothing.
    function test_RB1_atTheFeeCeilingTheSameRunTakesNothing() public {
        (, int256 loss,, World memory b) = _run(5000, ENTRY);
        _assertNoTake(loss, b);
    }

    /// @notice A hundredfold entry, where the old take neared f * G: alice's loss stays at dust.
    function test_RB1_asTheEntryGrowsTheLossStaysAtDust() public {
        (uint256 g, int256 loss, uint256 old, World memory b) = _run(2000, ENTRY * 100);
        assertGt(old, Math.mulDiv(Math.mulDiv(g, 2000, 10_000), 99, 100), "premise: an asset high-water would have taken within 1% of f * G");
        _assertNoTake(loss, b);
    }
}
