// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultFlows} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultHoldMateriality
/// @notice The trough hold, hub-ask mode, sized against the mark: a loss marks only past one basis point of the mark and the atom floor.
/// @notice The loss is the fall a sync sees, and with it the drawdown, so defaults split under the floor still mark once they add up.
/// @notice A clear stores the pile's maturity only over a material pile, and a stored second binds only while the pile stays material.
/// @notice While a stored second alone shuts entry, a lengthening roll is not refused for an uncovered request; while marked it still is.
contract AceVaultHoldMaterialityTest is AceVaultRig {
    uint48 internal constant MARKED = type(uint48).max;
    uint256 internal constant DUST_UNITS = 9e18;
    uint256 internal constant ENTRY = 1_000_000e6;
    address internal griefer = address(0x6121EF);

    // ---- reads ----

    function _word(uint256 k) internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + k);
        return uint256(vault.extsload(s)[0]);
    }

    function _hold() internal view returns (uint48) {
        return uint48(_word(2) >> 200);
    }

    function _maturity() internal view returns (uint64) {
        return uint64(_word(2) >> 128);
    }

    function _navMark() internal view returns (uint256) {
        return _word(1);
    }

    function _navHighStored() internal view returns (uint256) {
        return _word(8);
    }

    function _unsold() internal view returns (uint256 u) {
        (u,) = ace.lenderUnresolved(address(vault), address(usdc));
    }

    // ---- moves ----

    function _buyPot(address who, uint256 loanId) internal returns (uint256 paid) {
        uint256 budget = 10_000_000e6;
        usdc.mint(who, budget);
        vm.startPrank(who);
        usdc.approve(address(ace), budget);
        (, paid) = ace.buyInventory(loanId, budget, 0, who);
        vm.stopPrank();
    }

    function _enterAs(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

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

    function _assertOpen(address who) internal {
        assertGt(vault.maxDeposit(who), 0, "the view held entry");
        assertGt(vault.maxMint(who), 0, "and so did maxMint");
        assertGt(_enterAs(who, 1_000e6), 0, "the verb refused entry");
    }

    /// @dev The griefer's minimum-ticket loan on the rig's row, for the row's shortest term.
    function _dust() internal returns (uint256 loanId) {
        loanId = _borrowAs(griefer, DUST_UNITS, MIN_PRINCIPAL, MIN_TENOR);
    }

    /// @dev Settle an expired loan at the hub, then sync the vault.
    function _settleAndSync(uint256 loanId) internal {
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(keeper);
        vault.crank();
    }

    /// @dev The griefer buys its own pot back at the hub's ask, takes its residue, and syncs the vault.
    function _buyBack(uint256 loanId) internal returns (uint256 paid) {
        paid = _buyPot(griefer, loanId);
        vm.startPrank(griefer);
        ace.claimOwed(loanId, griefer);
        vault.crank();
        vm.stopPrank();
    }

    /// @dev A loan of `p` on `units` lapses and is settled and synced: a material one marks the vault.
    function _defaultToPot(uint256 units, uint256 p) internal returns (uint256 loanId) {
        loanId = _borrowAs(borrower, units, p, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        _settleAndSync(loanId);
        _warpBy(1 hours);
    }

    // ---- T7: a dust default rents no hold ----

    /// @notice A minimum-ticket default on a million-USDC vault marks nothing, and once its pot is bought back entry is open.
    function test_Hold_AMinimumTicketDefaultHoldsNothingOnceSold() public {
        uint256 loanId = _dust();
        _warpAtLeastTo(_expiry(loanId));
        _settleAndSync(loanId);
        assertEq(_hold(), 0, "a fall under a basis point of the mark marked the vault");
        assertEq(vault.maxDeposit(bob), 0, "premise: the unsold pot itself shuts entry");
        _warpBy(1 hours);
        _buyBack(loanId);
        assertEq(_unsold(), 0, "premise: no pot is unsold after the buy-back");
        assertGt(vault.unvested(), vault.VEST_FLOOR(), "premise: the recovery vests over one asset unit");
        assertEq(_hold(), 0, "the clear stored a hold over a pile under a basis point");
        _assertOpen(bob);
    }

    /// @notice CONTROL: with no sync between the settle and the sale nothing is marked, as before.
    function test_Hold_Control_WithNoSyncBetweenTheSettleAndTheSaleNothingIsHeld() public {
        uint256 loanId = _dust();
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(griefer);
        ace.forceClose(loanId);
        _warpBy(1 hours);
        _buyBack(loanId);
        assertEq(_unsold(), 0, "premise: the pot sold");
        assertGt(vault.maxDeposit(bob), 0, "entry is held though no sync saw the fall");
    }

    /// @notice Two staggered minimum-ticket loans: entry is open in every hour between the first sale and the second loan's expiry.
    function test_Hold_TwoStaggeredDustLoansLeaveEntryOpenBetweenThem() public {
        uint256 a = _dust();
        _warpBy(20 hours);
        uint256 b = _dust();
        _warpAtLeastTo(_expiry(a));
        _settleAndSync(a);
        _warpBy(1 hours);
        _buyBack(a);
        while (_now() + 1 hours <= _expiry(b)) {
            _warpBy(1 hours);
            assertGt(vault.maxDeposit(bob), 0, "an hour shut between the two dust defaults");
        }
        _warpAtLeastTo(_expiry(b));
        _settleAndSync(b);
        _warpBy(1 hours);
        _buyBack(b);
        assertEq(_hold(), 0, "the second dust default stored a hold");
        _assertOpen(bob);
    }

    /// @notice With a dust default cleared, the exit gate's round trip lands: a deposit covers the request, then the honest roll is admitted.
    function test_Hold_TheRoundTripLandsAfterADustDefault() public {
        uint256 honest = _borrow(MAX_TENOR);
        uint256 dust = _dust();
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(all);
        _warpAtLeastTo(_expiry(dust));
        _settleAndSync(dust);
        _warpBy(1 hours);
        _buyBack(dust);
        assertEq(_unsold(), 0, "premise: no pot is unsold");
        (bool ok, bytes4 reason,) = ace.tryExtend(honest, 0, "", borrower);
        assertFalse(ok, "premise: the uncovered request refuses the roll");
        assertEq(reason, PolicyRefused.selector, "premise: the vault's policy refused");
        uint256 shortfall = vault.totalAssets();
        assertGt(_enterAs(borrower, shortfall), 0, "the round trip's deposit leg refused");
        (ok,,) = ace.tryExtend(honest, 0, "", borrower);
        assertTrue(ok, "the roll was refused once idle covered the request");
    }

    /// @notice CONTROL: a 1,000 USDC default on the same vault is material, marks, and holds entry after its sale.
    function test_Hold_Control_AMaterialDefaultStillHolds() public {
        uint256 loanId = _defaultToPot(UNITS, PRINCIPAL);
        assertEq(_hold(), MARKED, "a material fall over an unsold pot did not mark the vault");
        _buyPot(stranger, loanId);
        vault.crank();
        assertEq(_hold(), _maturity(), "the clear did not store the material pile's maturity");
        _assertHeld(bob);
    }

    // ---- T8: the boundaries ----

    /// @dev A 1,000 USDC loan lapses and settles unsynced; a donation then nets its loss to `over` atoms past one basis point of the mark.
    function _lossAtTheBoundary(int256 over) internal {
        uint256 loanId = _borrowAs(borrower, UNITS, PRINCIPAL, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vault.crank();
        _warpBy(VEST_W);
        vault.crank();
        assertEq(vault.unvested(), 0, "premise: nothing vests before the settle");
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 m = _navMark();
        uint256 g = vault.grossNav();
        uint256 loss = _navHighStored() - g;
        assertGe(loss, m - g, "premise: the drawdown is the larger leg");
        uint256 target = uint256(int256(m / 10_000) + over);
        assertGt(loss, target, "premise: the settle's loss is over the boundary");
        usdc.mint(address(vault), loss - target);
        assertEq(_navHighStored() - vault.grossNav(), target, "premise: the netted loss sits at the target");
        vault.crank();
        assertEq(_unsold(), 1, "premise: the pot stands unsold");
    }

    /// @notice A loss of exactly one basis point of the mark does not mark the vault.
    function test_Hold_ALossOfExactlyOneBasisPointDoesNotMark() public {
        _lossAtTheBoundary(0);
        assertEq(_hold(), 0, "a loss of exactly one basis point marked the vault");
    }

    /// @notice CONTROL: one atom over one basis point marks it.
    function test_Hold_ALossOneAtomOverOneBasisPointMarks() public {
        _lossAtTheBoundary(1);
        assertEq(_hold(), MARKED, "a loss one atom over one basis point did not mark the vault");
    }

    /// @dev Loan A defaults and sells, storing a hold; the clock runs to a minute before the stored second, where the sale's pile is immaterial.
    function _storedHoldOverAVestedDownPile(uint256 unitsA, uint256 pA) internal returns (uint48 held) {
        uint256 a = _borrowAs(borrower, unitsA, pA, MIN_TENOR);
        _warpAtLeastTo(_expiry(a));
        _settleAndSync(a);
        assertEq(_hold(), MARKED, "PREMISE: the material fall marked the vault");
        _warpBy(1 hours);
        _buyPot(stranger, a);
        vault.crank();
        held = _hold();
        assertEq(held, _maturity(), "PREMISE: the sale's sync stored the hold");
        _warpTo(uint256(held) - 1 minutes);
        uint256 r = vault.unvested();
        assertGt(r, 0, "PREMISE: a residue of the sale's pile still vests");
        assertFalse(r > 1e4 && r * 10_000 > vault.grossNav(), "PREMISE: the residue has vested under the floor");
        assertEq(_hold(), held, "PREMISE: the stored second still stands");
    }

    /// @dev The largest pile `u` not material against the gross it leaves at NAV `a`: `u <= floor((a + u) / 1e4)`.
    function _relativeFloor() internal view returns (uint256 u) {
        u = vault.totalAssets() / 9_999;
    }

    /// @dev Mint the rise that tops the residue standing now up to a pile of exactly `pile`, asserting the next sync leaves just that.
    function _topUpTo(uint256 pile) internal {
        usdc.mint(address(vault), pile - vault.unvested());
        assertEq(vault.grossNav() - vault.totalAssets(), pile, "PREMISE: the next sync leaves the residue and the rise as the pile, exactly");
    }

    /// @notice Under a stored hold a pile at one basis point of gross does not hold entry; the view opens and the verb lands before the second.
    function test_Hold_AStoredHoldReleasesAtTheRelativeFloor() public {
        uint48 held = _storedHoldOverAVestedDownPile(60_000e18, 40_000e6);
        uint256 u = _relativeFloor();
        assertGt(u, 1e4, "premise: the relative floor binds on this vault");
        _topUpTo(u);
        _assertOpen(bob);
        assertLt(_now(), uint256(held), "PREMISE: entry landed before the stored second");
        assertEq(_hold(), held, "PREMISE: the stored second still stands");
    }

    /// @notice CONTROL: one atom over the relative floor, the same stored hold shuts entry.
    function test_Hold_AStoredHoldBindsOneAtomOverTheRelativeFloor() public {
        _storedHoldOverAVestedDownPile(60_000e18, 40_000e6);
        _topUpTo(_relativeFloor() + 1);
        _assertHeld(bob);
    }

    /// @dev A vault of `cash` from carol, alone, with the rig's row, replacing the rig's vault.
    function _smallVault(uint256 cash) internal {
        vault = _newVault(_row(address(record)));
        _lp(carol(), cash);
    }

    function carol() internal pure returns (address) {
        return address(0xCA201);
    }

    /// @notice On a small vault the absolute floor binds: a pile of exactly 1e4 atoms under a stored hold opens entry.
    function test_Hold_ASmallVaultUsesTheAtomFloor() public {
        _smallVault(80e6);
        _storedHoldOverAVestedDownPile(DUST_UNITS, MIN_PRINCIPAL);
        assertLt(vault.grossNav() / 10_000, 1e4, "premise: one basis point is under the atom floor here");
        _topUpTo(1e4);
        assertGt(vault.maxDeposit(bob), 0, "a pile of exactly the atom floor held entry");
    }

    /// @notice CONTROL: on the same small vault one atom over the floor holds entry.
    function test_Hold_ASmallVaultHoldsOneAtomOverTheAtomFloor() public {
        _smallVault(80e6);
        _storedHoldOverAVestedDownPile(DUST_UNITS, MIN_PRINCIPAL);
        _topUpTo(1e4 + 1);
        assertEq(vault.maxDeposit(bob), 0, "a pile one atom over the atom floor did not hold entry");
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(AceVault.RecoveryVesting.selector);
        vault.deposit(1e6, bob);
        vm.stopPrank();
    }

    // ---- T13: a stored second against later defaults ----

    /// @notice A dust default inside a stored hold leaves the stored second where it was.
    function test_Hold_AStoredSecondSurvivesALaterDustDefault() public {
        uint256 a = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        uint256 d = _dust();
        _warpAtLeastTo(_expiry(a));
        _settleAndSync(a);
        _warpBy(1 hours);
        _buyPot(stranger, a);
        vault.crank();
        uint48 held = _hold();
        assertEq(held, _maturity(), "PREMISE: the sale stored the hold");
        assertEq(vlens.drawdown(address(vault)), 0, "PREMISE: the sale recovered the drawdown");
        _settleAndSync(d);
        assertEq(_hold(), held, "a dust default inside the hold moved the stored second");
    }

    /// @notice A second material default inside a stored hold marks the vault, and its own sale stores a later second.
    function test_Hold_ASecondMaterialDefaultStoresALaterSecond() public {
        uint256 a = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpBy(12 hours);
        uint256 c = _borrowAs(borrower, 60_000e18, 40_000e6, MIN_TENOR);
        _warpAtLeastTo(_expiry(a));
        _settleAndSync(a);
        _warpBy(1 hours);
        _buyPot(stranger, a);
        vault.crank();
        uint48 first = _hold();
        assertEq(first, _maturity(), "PREMISE: the first sale stored the hold");
        _warpAtLeastTo(_expiry(c));
        assertLt(_now(), uint256(first), "PREMISE: the second default lands inside the first hold");
        _settleAndSync(c);
        assertEq(_hold(), MARKED, "a material default inside a stored hold did not mark the vault");
        _warpBy(1 hours);
        _buyPot(stranger, c);
        vault.crank();
        assertGt(_hold(), first, "the second sale did not store a later second");
        assertLt(_hold(), MARKED, "the second sale left the vault marked");
    }

    // ---- LR-1: defaults split under the floor still mark ----

    /// @notice About 450 defaults of nine tenths of a basis point each: the drawdown marks the vault at the second, and the sales are held.
    function test_Hold_SplitSubFloorDefaultsMarkThroughTheDrawdown() public {
        uint256 n = 450;
        uint256 p = 90e6;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _borrowAs(griefer, 81e18, p, MIN_TENOR);
        }
        assertLt(p * 10_000, _navMark(), "premise: each loan is under one basis point of the mark");
        _warpAtLeastTo(_expiry(ids[n - 1]));
        _settleAndSync(ids[0]);
        assertEq(_hold(), 0, "premise: one piece alone is immaterial");
        _settleAndSync(ids[1]);
        assertEq(_hold(), MARKED, "two pieces' drawdown did not mark the vault");
        for (uint256 i = 2; i < n; ++i) {
            _settleAndSync(ids[i]);
        }
        _warpBy(1 hours);
        for (uint256 i; i < n; ++i) {
            _buyPot(griefer, ids[i]);
        }
        vault.crank();
        assertEq(_unsold(), 0, "premise: every pot sold");
        assertGt(uint256(_hold()), _now(), "the raid's clear stored no hold");
        assertLt(_hold(), MARKED, "the raid's clear left the vault marked");
        _assertHeld(bob);
    }

    // ---- T11: the exit gate during a hold ----

    /// @notice While a stored hold alone shuts entry, an uncovered request does not refuse a lengthening roll; while marked it does.
    function test_Hold_DuringAStoredHoldAnUncoveredRequestDoesNotRefuseARoll() public {
        uint256 honest = _borrowAs(borrower, 1_200_000e18, 600_000e6, MAX_TENOR);
        uint256 a = _borrowAs(borrower, 30_000e18, 20_000e6, MIN_TENOR);
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(all);
        _warpAtLeastTo(_expiry(a));
        _settleAndSync(a);
        assertEq(_hold(), MARKED, "premise: marked over the unsold pot");
        (bool ok, bytes4 reason,) = ace.tryExtend(honest, 0, "", borrower);
        assertFalse(ok, "while marked, the uncovered request did not refuse the roll");
        assertEq(reason, PolicyRefused.selector, "the vault's policy is what refused");
        _warpBy(1 hours);
        _buyPot(stranger, a);
        vault.crank();
        uint48 held = _hold();
        assertEq(held, _maturity(), "premise: the sale stored the hold");
        assertGt(vault.previewRedeem(all), vault.idle(), "premise: the request still outweighs idle");
        _assertHeld(bob);
        (ok,,) = ace.tryExtend(honest, 0, "", borrower);
        assertTrue(ok, "during a stored hold the uncovered request refused the roll");
        _warpTo(held);
        vault.crank();
        (ok, reason,) = ace.tryExtend(honest, 0, "", borrower);
        assertFalse(ok, "once the hold lifted, the uncovered request no longer refused the roll");
        assertEq(reason, PolicyRefused.selector, "by the vault's policy");
    }

    // ---- the drawdown leg asks the hub only on a loss the sync sees ----

    /// @dev A standing drawdown of a percent of the entry, written into the stored high-water after a sync: nothing unsold, nothing marked.
    function _standingDrawdown() internal returns (bytes memory ask) {
        vault.crank();
        vm.store(address(vault), bytes32(uint256(AceVaultFlows.ROOT) + 8), bytes32(_navHighStored() + ENTRY / 100));
        assertEq(_unsold(), 0, "premise: nothing unsold");
        ask = abi.encodeCall(ace.lenderUnresolved, (address(vault), address(usdc)));
    }

    /// @notice Under a standing drawdown, a sync that sees no fall asks the hub nothing about pots.
    function test_HoldMateriality_AStandingDrawdownAsksTheHubNothingWithoutAFall() public {
        bytes memory ask = _standingDrawdown();
        vm.expectCall(address(ace), ask, 0);
        vault.crank();
        assertEq(_hold(), 0, "premise: nothing marked");
    }

    /// @notice CONTROL: a one-atom fall under the same drawdown weighs the drawdown, so the sync asks the hub; nothing unsold, it marks nothing.
    function test_HoldMateriality_AFallUnderAStandingDrawdownAsksTheHub() public {
        bytes memory ask = _standingDrawdown();
        vm.store(address(vault), bytes32(uint256(AceVaultFlows.ROOT) + 1), bytes32(_navMark() + 1));
        vm.expectCall(address(ace), ask);
        vault.crank();
        assertEq(_hold(), 0, "with nothing unsold the drawdown marked nothing");
    }
}
