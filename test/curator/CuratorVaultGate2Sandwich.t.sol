// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVault} from "../../src/curator/AceVault.sol";

/// @title CuratorVaultGate2Sandwich
/// @notice GATE 2: the sandwich around a pot sale the ATTACKER can fire alone, where `buyInventory` lets him time AND supply the arrival.
/// @notice While the pot is unsold the unsold-pot gate refuses his deposit; once the guardian exempts it, the vest alone leaves him nothing.
/// @dev The sandwich rows in `CuratorVaultVesting.t.sol` wait on a BORROWER, so they measure a shorter reach.
/// @dev the design record.
contract CuratorVaultGate2SandwichTest is CuratorVaultBase {
    uint256 internal constant SEED = 20_000e6;
    uint256 internal constant DRAW = 800e6; // a trough of about four percent
    uint256 internal constant DEEP_DRAW = 12_000e6; // the original size, a trough of sixty percent
    uint256 internal constant BUY = 40_000e6;

    /// @dev A settled pot standing at the hub with NOTHING deferred: `unvested()` is 0 when the run starts.
    /// @dev Deferral already standing would flatter the defence, so the empty start is asserted, not assumed.
    /// @dev The 800 draw keeps the trough shallow; `test_Gate2_ADeepSandwichCapturesNothing` runs the original 12,000.
    function _settledPot(CuratorVault v) internal returns (uint256 loanId) {
        loanId = _settledPotOf(v, DRAW);
    }

    function _settledPotOf(CuratorVault v, uint256 draw) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        loanId = _open(draw);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);
        _warpBy(3 * uint256(VEST_W));
        assertEq(v.unvested(), 0, "LIVENESS: the run must start with NOTHING deferred, not a helpful pile");
    }

    /// @notice A DEEP TROUGH REFUSES THE SANDWICH'S DEPOSIT: there is no trough gate, but the settled pot is unsold.
    function test_Gate2_ADeepSandwichCapturesNothing() public {
        CuratorVault v = _newVault(0);
        _settledPotOf(v, DEEP_DRAW);
        _assertSandwichRefused(v, 5_000e6);
    }

    /// @dev DELETED: `_leg(loanId)`, which built a one-entry (loan, tick, lot) list for the crank. The crank
    /// @dev takes no list: it sweeps the vault's whole pool, which the hub keys by (lender, quote).

    /// @dev Deposit, buy the pot, and exit -- one block, no time passing, all by the attacker's own hand.
    /// @param v The vault under attack.
    /// @param loanId The settled loan whose pot supplies the arrival.
    /// @param stake The size of the sandwich deposit.
    /// @return held Cash out plus the value of whatever shares the exit rail left him.
    /// @return baseline The same wallet if he had bought the pot and skipped the vault entirely.
    function _sandwich(CuratorVault v, uint256 loanId, uint256 stake) internal returns (uint256 held, uint256 baseline) {
        usdc.mint(bob, stake + BUY);

        vm.startPrank(bob);
        usdc.approve(address(v), stake);
        v.deposit(stake, bob);
        _approveCash(mid, BUY); // the hub pulls the asset straight from the buyer

        (uint256 unitsOut, uint256 filled) = ace.buyInventory(loanId, BUY, 0, bob);
        /// @dev WAS one `redeemFromClaims` call. That verb is deleted, so the crank and the exit are two
        /// @dev calls -- still the SAME BLOCK and the same prank, so the sandwich stays atomic and the
        /// @dev subject is untouched. The exit takes the smaller of the old half-position and the rail.
        v.crank();
        uint256 sh = v.balanceOf(bob) / 2; // halved for rail headroom; the measure below is VALUE, not size
        /// @dev THE EXIT IS INSTANT, in the same block, so the sandwich is atomic; `held` prices the shares it leaves him.
        v.redeem(sh, bob, bob);
        vm.stopPrank();

        assertGt(unitsOut, 0, "LIVENESS: no fill means no arrival and the run proves nothing");
        assertGt(filled, 0, "LIVENESS: the attacker really did pay the pot");
        held = usdc.balanceOf(bob) + v.convertToAssets(v.balanceOf(bob));
        baseline = stake + BUY - filled; // he still owns the collateral in BOTH worlds, so it cancels
        emit log_named_uint("stake", stake);
        emit log_named_uint("filled into the pot", filled);
        emit log_named_uint("held after the round trip", held);
        emit log_named_uint("baseline having never deposited", baseline);
    }

    /// @dev The sandwich's first leg, refused: the settled pot is unsold, so the deposit reverts `InventoryUnsold` and no share is minted.
    function _assertSandwichRefused(CuratorVault v, uint256 stake) internal {
        usdc.mint(bob, stake);
        vm.startPrank(bob);
        usdc.approve(address(v), stake);
        vm.expectRevert(AceVault.InventoryUnsold.selector);
        v.deposit(stake, bob);
        vm.stopPrank();
        assertEq(v.balanceOf(bob), 0, "the attacker holds no share to sandwich the sale with");
    }

    /// @dev THE GATE. The attacker-triggered rebate must not be collectable: the deposit that would stand in the vault is refused.
    function test_Gate2_TheAttackerTriggeredSandwichCapturesNothing() public {
        CuratorVault v = _newVault(0);
        _settledPot(v);
        _assertSandwichRefused(v, 5_000e6);
    }

    /// @dev The same attack with D >> V, which is where `filled * D/(V+D)` approaches the whole payment.
    /// @dev Flash-sized, because deposit, buy and exit are one transaction and nothing here needs a block.
    function test_Gate2_TheFlashSizedAttackerTriggeredSandwichCapturesNothing() public {
        CuratorVault v = _newVault(0);
        _settledPot(v);
        _assertSandwichRefused(v, 40 * SEED);
    }

    /// @dev UNDER AN EXEMPTION THE VEST IS THE DEFENCE: the guardian exempts a pot that then sells, so entry is open over the sale.
    /// @dev The curve, because the profit scales in the stake and a single size cannot show a slope.
    /// @dev MUTATION TARGET: neuter `_stampVest` and the attacker extracts a share of the payment the sale rebates.
    function test_Gate2_UnderAnExemptionTheVestLeavesTheSandwichNothing() public {
        uint256[4] memory sizes = [uint256(5_000e6), 50_000e6, 200_000e6, 40 * SEED];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            CuratorVault v = _newVault(0);
            uint256 loanId = _settledPot(v);
            _waivePots(v);
            (uint256 held, uint256 baseline) = _sandwich(v, loanId, sizes[i]);
            emit log_named_uint("EXTRACTED", held > baseline ? held - baseline : 0);
            assertLe(held, baseline, "the rebate must stay uncollectable at every size, not just one");
            vm.revertToState(snap);
        }
    }

    /// @dev The curve, because the profit scales in the stake and a single size cannot show a slope: refused at every size.
    function test_Gate2_TheExtractionIsZeroAtEveryStakeSize() public {
        uint256[4] memory sizes = [uint256(5_000e6), 50_000e6, 200_000e6, 40 * SEED];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            CuratorVault v = _newVault(0);
            _settledPot(v);
            _assertSandwichRefused(v, sizes[i]);
            vm.revertToState(snap);
        }
    }

    /// @dev What the attacker is really buying: the pot's collateral, at a price his own shares refund.
    /// @dev Pinned because the extraction ceiling is the FILL, and the fill is what the class is owed.
    function test_Gate2_TheFillIsCappedAtWhatTheClassIsOwedSoTheCeilingIsThePot() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _settledPot(v);
        usdc.mint(bob, BUY);
        vm.startPrank(bob);
        _approveCash(mid, BUY); // the hub is the spender, exactly as it is on the sandwich path
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(loanId, BUY, 0, bob);
        vm.stopPrank();
        assertGt(unitsOut, 0, "LIVENESS: the pot really did have collateral in it");
        assertLt(filled, BUY, "the hub caps the fill, so the rebate has a ceiling and it is the pot");
        emit log_named_uint("the ceiling on any one round trip", filled);
    }
}
