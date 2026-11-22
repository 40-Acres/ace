// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AceVaultFlows} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title Suite_TroughAfterSale
/// @notice RS-2 PoC, fixed: the unsold-pot gate lifts at the sale, and the trough hold then keeps entry shut until the sale's cash has vested.
/// @notice Row (a) is the trough raid with its legs reordered, the pot's buyer entering after its own purchase: it is held, and nets nothing after.
/// @notice Row (b) is a recovery past the band: entry stays shut past the second the band alone would reopen it, until the whole recovery vests.
contract Suite_TroughAfterSale is AceVaultRig {
    uint256 internal constant ENTRY = 1_000_000e6;
    bytes4 internal constant RECOVERY_VESTING = bytes4(keccak256("RecoveryVesting()"));

    /// @dev A loan of `p` on `units` runs to expiry unpaid and is force-closed; a crank marks the trough; the pot waits out the hub's hold.
    function _defaultToPot(uint256 units, uint256 p) internal returns (uint256 loanId) {
        loanId = _borrowAs(borrower, units, p, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(bob);
        vault.crank();
        _warpBy(1 hours); // the hub's inventory hold for a week-long minTenor
    }

    /// @dev `who` buys the whole settled pot at the hub's ask; returns the units it took and what it paid.
    function _buyPot(address who, uint256 loanId) internal returns (uint256 units, uint256 paid) {
        uint256 budget = 10_000_000e6;
        usdc.mint(who, budget);
        vm.startPrank(who);
        usdc.approve(address(ace), budget);
        (units, paid) = ace.buyInventory(loanId, budget, 0, who);
        vm.stopPrank();
    }

    function _enterAs(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _worth(address who) internal view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(who));
    }

    /// @dev `units` of the rig collateral at the record's last print, 2 USDC, in the asset.
    function _mark(uint256 units) internal view returns (uint256) {
        return Math.mulDiv(units, AceFixtures.px(2e18, address(usdc), address(coll)), 1 << 96);
    }

    /// @dev The second entry reopens, from the vest word's bits 200-247.
    function _hold() internal view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint48(uint256(vault.extsload(s)[0]) >> 200);
    }

    /// @dev Entry is held: both max views read zero and a deposit refuses `RecoveryVesting`.
    function _assertHeld(address who) internal {
        assertEq(vault.maxDeposit(who), 0, "maxDeposit advertised an entry over the vesting recovery");
        assertEq(vault.maxMint(who), 0, "and so did maxMint");
        usdc.mint(who, 1_000e6);
        vm.startPrank(who);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(RECOVERY_VESTING);
        vault.deposit(1_000e6, who);
        vm.stopPrank();
    }

    /// @notice (a) The pot's buyer is held out in the sale's block, and an entry at the hold's second takes back nothing of its price.
    /// @dev The hold now lets go once the pile is at or under VEST_FLOOR, which can be seconds before the stored second.
    function test_RS2a_theBuyerCannotEnterUntilTheSalesCashHasVested() public {
        uint256 loanId = _defaultToPot(60_000e18, 40_000e6);
        (uint256 units, uint256 paid) = _buyPot(stranger, loanId);
        vault.crank();
        uint256 trough = vault.totalAssets();
        uint256 pile = vault.unvested();
        uint256 saleAt = _now();
        assertLe(pile * 10_000, trough * vault.GATE_BPS(), "premise: the recovery sits inside the band");
        _assertHeld(stranger);
        uint256 hold = _hold();
        _warpTo(hold - 1 hours);
        assertEq(vault.maxDeposit(stranger), 0, "entry reopened an hour before the hold");
        _warpTo(hold);
        assertEq(vault.unvested(), 0, "premise: the recovery has vested at the hold");
        uint256 snap = vm.snapshotState();

        uint256 sx = _enterAs(stranger, ENTRY);
        _warpBy(VEST_W);
        vault.crank();
        vm.prank(stranger);
        uint256 out = vault.redeem(sx, stranger, stranger);
        uint256 aliceAttacked = _worth(alice);
        vm.revertToState(snap);

        _warpBy(VEST_W);
        vault.crank();
        uint256 aliceClean = _worth(alice);

        uint256 m = _mark(units);
        int256 net = int256(out) - int256(ENTRY) - int256(paid) + int256(m);
        emit log_named_uint("A, paid at the ask", paid);
        emit log_named_uint("M, the units at the record's print", m);
        emit log_named_uint("T, NAV right after the sale", trough);
        emit log_named_uint("pile right after the sale", pile);
        emit log_named_uint("seconds entry was held after the sale", hold - saleAt);
        emit log_named_uint("buyer's redemption after one window", out);
        emit log_named_int("buyer's net, M - A + out - D", net);

        assertLe(out, ENTRY, "an entrant at the hold took back part of the recovery");
        assertApproxEqAbs(out, ENTRY, 2, "the entrant at the hold was not paid its entry back to two atoms");
        assertLe(net, 0, "the buyer came out ahead");
        assertGe(aliceAttacked + 1, aliceClean, "the stayers lost more than an atom to the entrant");
    }

    /// @dev The borrower's raid with `entry`: borrow, lapse, settle, buy its pot back after the hold, enter at the trough hold, exit a window on.
    /// @return net The borrower's cash net, every pledged unit having come home.
    /// @return keep What alice is worth over her pre-loan worth plus the sale's price less the claim, which she would keep with no raid.
    function _selfRaid(uint256 entry) internal returns (int256 net, int256 keep) {
        uint256 units0 = 60_000e18;
        uint256 p = 40_000e6;
        uint256 aliceStart = _worth(alice);
        uint256 loanId = _borrowAs(borrower, units0, p, MIN_TENOR);
        uint256 payout = usdc.balanceOf(borrower);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(bob);
        vault.crank();
        _warpBy(1 hours);
        vm.prank(borrower);
        (uint256 residual,) = ace.claimOwed(loanId, borrower);
        (uint256 potUnits, uint256 paid) = _buyPot(borrower, loanId);
        vault.crank();
        _assertHeld(borrower);
        _warpTo(_hold());
        uint256 sx = _enterAs(borrower, entry);
        _warpBy(VEST_W);
        vault.crank();
        vm.prank(borrower);
        uint256 out = vault.redeem(sx, borrower, borrower);
        assertEq(residual + potUnits, units0, "every unit the borrower pledged came home");
        net = int256(payout) + int256(out) - int256(entry) - int256(paid);
        keep = int256(_worth(alice)) - int256(aliceStart) - int256(paid) + int256(p);
        emit log_named_uint("entry D", entry);
        emit log_named_uint("payout kept", payout);
        emit log_named_uint("A, paid for its own pot", paid);
        emit log_named_uint("redemption after one window", out);
        emit log_named_int("raider's cash net, all units home", net);
        emit log_named_int("alice over her pre-loan worth plus A less the claim", keep);
        assertLe(out, entry, "the entry leg took part of the recovery");
        assertApproxEqAbs(out, entry, 2, "the entry leg was not paid its cash back to two atoms");
    }

    /// @notice (a2) The borrower's own raid at D = T: entry is held over its sale, and entering at the hold nets it nothing.
    function test_RS2a2_theBorrowerRaidsItsOwnDefaultAtDEqualT() public {
        (int256 net, int256 keep) = _selfRaid(ENTRY);
        assertLe(net, 0, "the raid paid the raider");
        assertGe(keep, -1, "the stayers did not keep the whole recovery");
    }

    /// @notice (a3) The same raid at D = 9T: still held, still nothing.
    function test_RS2a3_theBorrowerRaidsItsOwnDefaultAtDNineT() public {
        (int256 net, int256 keep) = _selfRaid(ENTRY * 9);
        assertLe(net, 0, "the raid paid the raider");
        assertGe(keep, -1, "the stayers did not keep the whole recovery");
    }

    /// @notice (b) Over the band: entry stays shut past the second the band alone would reopen it, until the hold; an entrant then takes nothing.
    function test_RS2b_overTheBandEntryWaitsPastTheGateForTheWholeRecovery() public {
        uint256 loanId = _defaultToPot(150_000e18, 100_000e6);
        (, uint256 paid) = _buyPot(keeper, loanId);
        vault.crank();
        uint256 troughAtSale = vault.totalAssets();
        uint256 saleAt = _now();
        assertGt(paid * 10_000, troughAtSale * vault.GATE_BPS(), "premise: the recovery is past the band");
        assertEq(vault.maxDeposit(bob), 0, "premise: a recovery past the band shuts entry");
        uint256 hold = _hold();
        while (vault.unvested() * 10_000 > vault.totalAssets() * vault.GATE_BPS()) {
            _warpBy(10 minutes);
        }
        _assertHeld(bob);
        assertLt(_now(), hold, "premise: the pile reaches the band before the hold");
        _warpTo(hold);
        assertEq(vault.unvested(), 0, "premise: the whole recovery has vested at the hold");
        uint256 a = vault.totalAssets();

        uint256 snap = vm.snapshotState();
        uint256 sb = _enterAs(bob, ENTRY);
        _warpBy(VEST_W);
        vault.crank();
        vm.prank(bob);
        uint256 out = vault.redeem(sb, bob, bob);
        uint256 aliceAttacked = _worth(alice);
        vm.revertToState(snap);
        _warpBy(VEST_W);
        vault.crank();
        uint256 aliceClean = _worth(alice);

        emit log_named_uint("R, paid at the ask", paid);
        emit log_named_uint("T at the sale", troughAtSale);
        emit log_named_uint("seconds entry stayed shut after the sale", hold - saleAt);
        emit log_named_uint("NAV at the reopening", a);
        emit log_named_uint("entrant's redemption after the window", out);

        assertEq(hold - saleAt, VEST_W, "the hold is not one window from the sale");
        assertLe(out, ENTRY, "the entrant took a share of the recovery");
        assertApproxEqAbs(out, ENTRY, 2, "the entrant was not paid its entry back to two atoms");
        assertGe(aliceAttacked + 1, aliceClean, "the stayers lost more than an atom to the entrant");
    }
}
