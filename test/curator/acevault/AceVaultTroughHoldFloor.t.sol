// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultTroughHoldFloor
/// @notice The trough hold's two floors at their exact boundary: a pile of exactly one basis point of gross neither stores a hold nor is held by one.
/// @notice Each row stamps a rise onto an empty pile or a vested-down residue, which reads back exactly, so the pile sits on the floor to the atom.
/// @notice Each has a one-atom-over control.
/// @notice On these vaults the basis point is far above `MIN_SEED`, so it is the leg that binds; the atom floor's own boundary has its own suite.
/// @notice And the stored second is the pile's blended maturity at the clear, not a fresh window from it.
contract AceVaultTroughHoldFloorTest is AceVaultRig {
    uint48 internal constant MARKED = type(uint48).max;

    /// @dev The vest word, ROOT + 2: basis low, maturity at 128, the drain at 192, the hold at 200.
    function _vestWord() internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint256(vault.extsload(s)[0]);
    }

    function _hold() internal view returns (uint48) {
        return uint48(_vestWord() >> 200);
    }

    function _maturity() internal view returns (uint64) {
        return uint64(_vestWord() >> 128);
    }

    /// @dev The pile the next sync would leave: gross less `totalAssets`, which prices on it.
    function _pendingPile() internal view returns (uint256) {
        return vault.grossNav() - vault.totalAssets();
    }

    /// @dev The largest rise onto an empty pile that stays immaterial: `p == (a + p) * HOLD_BPS / 1e4` at NAV `a`, as a one-bp hold solves it.
    function _floorPile() internal view returns (uint256 p) {
        p = vault.totalAssets() * vault.HOLD_BPS() / (10_000 - vault.HOLD_BPS());
    }

    /// @dev Mint `p` onto the vault as a rise, asserting it is pending and sits exactly on (or `over` atoms past) the bp floor of the gross it makes.
    function _riseOnTheFloor(uint256 over) internal returns (uint256 p) {
        assertEq(_pendingPile(), 0, "PREMISE: no rise is pending before the mint");
        p = _floorPile() + over;
        usdc.mint(address(vault), p);
        assertEq(_pendingPile(), p, "PREMISE: the next sync leaves exactly the minted pile");
        assertEq(vault.grossNav() * vault.HOLD_BPS() / 10_000, p - over, "PREMISE: the pile sits on one basis point of the gross it makes");
        assertGt(p, vault.MIN_SEED(), "PREMISE: the basis point binds, not the atom floor");
    }

    /// @dev Top a vested-down residue up, by a rise, to exactly the bp floor of the gross it makes, or `over` atoms past it; returns the whole pile.
    function _topUpToTheFloor(uint256 over) internal returns (uint256 p) {
        uint256 r = _pendingPile();
        p = _floorPile() + over;
        assertGt(p, r, "PREMISE: the residue sits under the floor");
        usdc.mint(address(vault), p - r);
        assertEq(_pendingPile(), p, "PREMISE: the next sync leaves the residue and the rise, exactly");
        assertEq(vault.grossNav() * vault.HOLD_BPS() / 10_000, p - over, "PREMISE: the pile sits on one basis point of the gross it makes");
        assertGt(p, vault.MIN_SEED(), "PREMISE: the basis point binds, not the atom floor");
    }

    function _buyPot(address who, uint256 loanId) internal {
        uint256 budget = 10_000_000e6;
        usdc.mint(who, budget);
        vm.startPrank(who);
        usdc.approve(address(ace), budget);
        ace.buyInventory(loanId, budget, 0, who);
        vm.stopPrank();
    }

    function _enterAs(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev Entry is held: both max views read zero, and a deposit refuses `RecoveryVesting` and nothing else.
    function _assertHeld(address who) internal {
        assertEq(vault.maxDeposit(who), 0, "maxDeposit advertised an entry the hold shuts");
        assertEq(vault.maxMint(who), 0, "and so did maxMint");
        usdc.mint(who, 1_000e6);
        vm.startPrank(who);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(AceVault.RecoveryVesting.selector);
        vault.deposit(1_000e6, who);
        vm.stopPrank();
    }

    /// @dev Exempt every pot standing now, as the guardian, with no sync.
    function _exemptAll() internal {
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
    }

    /// @dev Loan A defaults and sells, storing a hold; the clock runs to a minute before the stored second, where the sale's pile has vested under the floor.
    function _storedHoldOverAVestedDownPile() internal returns (uint48 held) {
        uint256 a = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(a));
        vm.prank(keeper);
        ace.forceClose(a);
        vault.crank();
        _warpBy(1 hours);
        _buyPot(stranger, a);
        vault.crank();
        held = _hold();
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "PREMISE: the sale's cash vests under a stored hold");
        assertEq(held, _maturity(), "PREMISE: the sale's sync stored the hold");
        _warpTo(uint256(held) - 1 minutes);
        uint256 r = vault.unvested();
        assertGt(r, 0, "PREMISE: a residue of the sale's pile still vests");
        assertLt(r, _floorPile(), "PREMISE: and it has vested under the floor");
        assertEq(_hold(), held, "PREMISE: the stored second still stands");
    }

    /// @dev A default marks the vault with no pile standing, and the guardian exempts its pot with no sync.
    function _markedAndExemptedOverNoPile() internal {
        uint256 loanId = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: the fall over the unsold pot marked the vault");
        assertEq(vault.unvested(), 0, "PREMISE: no pile stands");
        _exemptAll();
        assertEq(_hold(), MARKED, "PREMISE: the exemption wrote no hold");
    }

    // ---- `_troughHeld`: a stored hold binds only over a pile above the floor ----

    /// @notice Under a stored hold, a pile exactly on the floor does not hold entry: the view opens and the verb lands, before the stored second.
    function test_HoldFloor_APileExactlyOnTheOneBpFloorDoesNotHoldEntry() public {
        uint48 held = _storedHoldOverAVestedDownPile();
        uint256 p = _topUpToTheFloor(0);
        assertGt(vault.maxDeposit(bob), 0, "the view held entry over a pile exactly on the floor");
        assertGt(vault.maxMint(bob), 0, "and so did maxMint");
        assertGt(_enterAs(bob, 1_000e6), 0, "the verb held entry over a pile exactly on the floor");
        assertEq(vault.unvested(), p, "PREMISE: the entry's own sync left the pile exactly on the floor");
        assertLt(_now(), uint256(held), "PREMISE: entry landed before the stored second");
        assertEq(_hold(), held, "PREMISE: the stored second still stands");
    }

    /// @notice CONTROL: one atom over the floor, the same stored hold shuts entry in the view and the verb.
    function test_HoldFloor_APileOneAtomOverTheOneBpFloorIsHeld() public {
        _storedHoldOverAVestedDownPile();
        _topUpToTheFloor(1);
        _assertHeld(bob);
    }

    // ---- `_markTrough`: a clear over a pile on the floor stores no hold ----

    /// @notice A clear whose sync leaves a pile exactly on the floor stores zero, so a later rise is gated by the vest band alone.
    function test_HoldFloor_AClearOverAPileExactlyOnTheOneBpFloorStoresNoHold() public {
        _markedAndExemptedOverNoPile();
        uint256 p = _riseOnTheFloor(0);
        vault.crank();
        assertEq(vault.unvested(), p, "PREMISE: the clearing sync left the pile exactly on the floor");
        assertEq(_hold(), 0, "a clear over a pile exactly on the floor stored a hold");
        usdc.mint(address(vault), 10e6);
        assertGt(_pendingPile(), vault.VEST_FLOOR(), "PREMISE: the later rise vests over the floor");
        assertLe(_pendingPile() * 10_000, vault.totalAssets() * vault.GATE_BPS(), "PREMISE: inside the band, so the vest gate opens");
        assertGt(vault.maxDeposit(bob), 0, "the view held entry after a clear that stored no hold");
        assertGt(_enterAs(bob, 1_000e6), 0, "the verb held entry after a clear that stored no hold");
    }

    /// @notice CONTROL: a clear whose sync leaves one atom over the floor stores the pile's maturity, and entry waits for it.
    function test_HoldFloor_AClearOverAPileOneAtomOverTheOneBpFloorStoresTheMaturity() public {
        _markedAndExemptedOverNoPile();
        uint256 p = _riseOnTheFloor(1);
        vault.crank();
        assertEq(vault.unvested(), p, "PREMISE: the clearing sync left a pile one atom over the floor");
        assertEq(_hold(), _maturity(), "a clear over a pile above the floor did not store its maturity");
        assertEq(uint256(_hold()), _now() + VEST_W, "a fresh pile's maturity is one window from the clear");
        _assertHeld(bob);
    }

    // ---- the stored second is the pile's own maturity ----

    /// @notice A clear over a pile already vesting stores the blended maturity, earlier than a fresh window; entry reopens there whatever vests after.
    function test_HoldFloor_AClearOverAStandingPileStoresItsBlendedMaturity() public {
        uint256 loanId = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: the fall over the unsold pot marked the vault");
        usdc.mint(address(vault), 20_000e6);
        vault.crank();
        assertEq(_hold(), MARKED, "PREMISE: a rise over a pot still unsold keeps the mark");
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "PREMISE: the rise vests");
        _warpBy(1 hours);
        _buyPot(stranger, loanId);
        vault.crank();
        uint48 held = _hold();
        assertEq(held, _maturity(), "the clear did not store the pile's own maturity");
        assertLt(uint256(held), _now() + VEST_W, "PREMISE: the standing pile blended the maturity earlier than a fresh window");
        assertEq(vault.maxDeposit(bob), 0, "entry opened at the clear over a pile still vesting");
        _warpTo(uint256(held) - 1 hours);
        usdc.mint(address(vault), 1_000e6);
        vault.crank();
        assertGt(_maturity(), held, "PREMISE: the later rise blended the maturity past the stored second");
        _warpTo(held);
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "PREMISE: a pile over the floor still vests at the stored second");
        assertGt(vault.maxDeposit(bob), 0, "entry stayed shut past the blended second the clear stored");
        assertGt(_enterAs(bob, 1_000e6), 0, "a deposit at the stored second did not land");
    }
}
