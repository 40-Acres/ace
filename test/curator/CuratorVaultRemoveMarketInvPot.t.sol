// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";

/// @title CuratorVaultRemoveMarketInvPot
/// @notice THE BLIND SPOT, still real: `lenderAssets` excludes `invPot`, so a market holding the whole
/// @notice recovery of a settled loan reads EMPTY on every aggregate the vault can see.
/// @notice The gate and the NAV identity share that spot, so no vault view can see such a removal.
/// @dev IT IS NO LONGER A GATE'S BLIND SPOT, and that is the change rather than a fix to the read. `removeMarket`
/// @dev took a `dust` tolerance and refused past an abandonment ceiling, both measured off `lenderAssets` -- which
/// @dev is what made this a hazard: the gate let a market carrying real inventory through as if it were empty.
/// @dev Removal moves no value under pooling, so the gate, the tolerance and the readmission ban all went. What
/// @dev is left is the blind spot as a DISCLOSURE: a curator reading NAV alone cannot see the pot, and the rows
/// @dev below say so and then show that every door back to the value stays open regardless.
/// @dev Row 1 MEASURES the blind spot; row 2 is what makes it survivable, and both pass.
contract CuratorVaultRemoveMarketInvPotTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;

    /// @dev One loan, cranked, settled, cranked again: the trough is open and the pot is full.
    function _settled(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);
    }

    /// @notice ROW 1, THE PREMISE: a settled market reads empty on the aggregates while holding real inventory.
    function test_Premise_ASettledMarketReadsEmptyWhileHoldingTheWholeRecovery() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _settled(v);

        uint256 la = ace.lenderAssets(address(v), v.asset());
        uint256 mark = lens.inventoryMark(mid, loanId);

        emit log_named_uint("lenderAssets -- every aggregate the vault can see", la);
        emit log_named_uint("inventoryMark of the pot -- what it does not see ", mark);
        emit log_named_uint("vault grossNav                                   ", v.grossNav());

        assertGt(mark, 0, "PREMISE: the settled class must actually hold recoverable inventory");
        assertLt(la, mark, "PREMISE: the aggregate is smaller than the value it does not count");
    }

    /// @notice ROW 2, THE RECOVERY: removal is silent on NAV, and every door back to the value stays open.
    /// @dev Removal is a cap cut to zero, which lands at once.
    /// @dev NAV not moving used to be the amplifier: `invPot` was never counted, so nothing signalled a loss.
    /// @dev It signals nothing still, and that is harmless: the recovery comes home through the crank, into the vault's own balance.
    /// @dev Only NEW LENDING stays shut, which is the whole of what removal ends.
    function test_Recovery_RemovalIsSilentButTheRecoveryStillComesHome() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _settled(v);
        uint256 mark = lens.inventoryMark(mid, loanId);
        uint256 navBefore = v.grossNav();

        vm.prank(curator);
        v.submitCap(address(collateral), 0);

        assertEq(v.rowOf(address(collateral)).cap, 0, "the row is capped at zero at once");
        assertEq(v.grossNav(), navBefore, "and took not a cent of NAV with it: removal is a zero-NAV event");
        emit log_named_uint("value uncounted   ", mark);

        // A stranger buys half the pot. The quote lands in the vault's pooled credit, addressed to it.
        _buyPot(keeper, loanId, mark / 2);
        assertGt(ace.lenderAssets(address(v), v.asset()), 0, "the recovery really did arrive, owed to this vault");

        /// @dev The sale credits the vault's pool at the hub, which NAV already counts; the crank then MOVES that credit into idle.
        uint256 navAtCrank = v.grossNav();
        uint256 idleBefore = v.idle();
        uint256 owed = ace.lenderAssets(address(v), v.asset());
        v.crank();
        assertEq(ace.lenderAssets(address(v), v.asset()), 0, "the crank reached a removed market and brought the value home");
        assertEq(v.grossNav(), navAtCrank, "moving no NAV: the pool counted it before the removal and after");
        assertEq(v.idle(), idleBefore + owed, "and the credit landed in idle, to the wei");
        assertGt(owed, 0, "LIVENESS: there really was credit at the hub for that lap to take");

        // The rest of the pot, taken by a second lap.
        _buyPot(keeper, loanId, mark / 2);
        navAtCrank = v.grossNav();
        idleBefore = v.idle();
        owed = ace.lenderAssets(address(v), v.asset());
        assertGt(owed, 0, "the second sale credits the vault again");
        v.crank();
        assertEq(ace.lenderAssets(address(v), v.asset()), 0, "and a second lap reaches it too: nothing is stranded at the hub");
        assertEq(v.grossNav(), navAtCrank, "NAV flat across that lap as well");
        assertEq(v.idle(), idleBefore + owed, "with idle up by the second credit");

        /// @dev NEW LENDING is what removal ends, and the only thing it ends: a borrow on the capped row is refused by name.
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(v), COLL);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        v.borrow(_request(address(collateral), COLL, 1_000e6), "", "");
        vm.stopPrank();
    }

    /// @notice THE RECOVERY-DOOR ROWS LIVE IN `CuratorVaultRemoveMarketRail.t.sol`.
    /// @dev This suite keeps only the blind spot itself: an aggregate read cannot see `invPot`, by design,
    /// @dev because valuing a pot needs a price and this vault reads none. Rows 1 and 2 pin that and stop.
}
