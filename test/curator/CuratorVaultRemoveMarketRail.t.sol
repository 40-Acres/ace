// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";

/// @title CuratorVaultRemoveMarketRail
/// @notice THE RECOVERY DOOR: removing a collateral ends new lending on it, and the value behind its markets still comes home.
/// @dev HALF B, THE CEILING, IS DELETED with the mechanism it bounded -- five rows and the `_ceiling` helper.
/// @dev Removal took a caller-named `dust` tolerance that bounded nothing by itself, so a ceiling on
/// @dev `MAX_ABANDON_BPS` of gross NAV was added to bound how much one call could drop OUT OF THE COUNT.
/// @dev Under pooling a removal is a ZERO-NAV EVENT: the lender's aggregates are keyed by (lender, quote)
/// @dev across their markets, so ending lending on one moves nothing and there is no fall to bound.
/// @dev Removal is now a cap cut to zero on the collateral's row, which lands at once and moves no value.
/// @dev WHAT SURVIVES WHOLE is this file's other half, and it needed no ceiling to be true: the value behind
/// @dev a removed collateral's markets stays reachable through the crank.
contract CuratorVaultRemoveMarketRailTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint16 internal constant FEE = 2000; // never a zero-fee vault on the fee row: that habit hides the whole seam

    address internal stranger = address(0x57A2);

    /// @dev One loan, cranked, settled, cranked again: the trough is open and the pot holds the whole recovery.
    function _settled(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);
    }

    /// @dev Remove the rig collateral by capping its row at zero, and return what the vault still had at the hub when it did.
    function _remove(CuratorVault v) internal returns (uint256 left) {
        left = ace.lenderAssets(address(v), v.asset());
        vm.prank(curator);
        v.submitCap(address(collateral), 0);
        assertEq(v.rowOf(address(collateral)).cap, 0, "fixture: the row really is capped at zero");
    }

    // ---- HALF A: the recovery door, so a removal stops being terminal for value ----

    /// @dev The market this issue is about: `invPot` holds the whole recovery and no aggregate can see it.
    /// @dev So the removal is legal at ANY moment, and the crank is what makes that safe rather than fatal.
    function test_ARemovedMarketsRecoveryStillComesHome() public {
        CuratorVault v = _newVault(0);
        bytes32 id = mid;
        uint256 loanId = _settled(v);
        uint256 pot = lens.inventoryMark(id, loanId);
        _remove(v);

        _buyPot(keeper, loanId, pot);
        uint256 owed = ace.lenderAssets(address(v), v.asset());
        assertGt(owed, 0, "fixture: the recovery really did arrive, owed to this vault");
        uint256 idleBefore = v.idle();
        uint256 navBefore = v.grossNav();

        vm.prank(bob);
        v.crank();

        /// @dev The sale credited the vault's pool at the hub, which NAV already counts; the crank MOVES that credit into idle.
        assertEq(ace.lenderAssets(address(v), v.asset()), 0, "a removed market's recovery still comes home");
        assertEq(v.idle(), idleBefore + owed, "and it comes home into the vault's own balance, to the wei");
        assertEq(v.grossNav(), navBefore, "NAV never moved: pooling counted this market's value before the removal and after");
    }

    /// @dev DELETED: `test_ARemovedMarketCanStillBeCranked`. It drove the SAME recovery through the EXPLICIT
    /// @dev batch door -- `crank(ids, ticks, lots)` -- which was a second entry point with its own gate, so the
    /// @dev two rows were genuinely different calls. There is ONE sweeping crank and it takes no market, so this row
    /// @dev became a verbatim copy of the one above.

    // ---- the three the lending review requires ----

    /// @dev The plan's oscillation bound was on the FALL only, and under pooling there is no fall at all.
    /// @dev What bounds the rise is `_sync`'s deferral, so the recovery must arrive DEFERRED, never as a jump.
    function test_ARemovedMarketsRecoveryArrivesDeferred() public {
        CuratorVault v = _newVault(0);
        bytes32 id = mid;
        uint256 loanId = _settled(v);
        uint256 pot = lens.inventoryMark(id, loanId);
        assertGt(pot, 0, "fixture: the settled loan really is holding a pot for the recovery to come out of");
        uint256 navAtRemoval = v.grossNav();
        _remove(v);
        /// @dev `grossNav` reads the vault's balance and its (lender, quote) pool and never a row, so the fall is exactly zero.
        assertEq(v.grossNav(), navAtRemoval, "a removal is a ZERO-NAV event, not merely a small one");

        _warpBy(uint256(VEST_W) + 1); // clear any standing pile, so the rise below is the only thing deferred
        assertEq(v.unvested(), 0, "fixture: nothing is deferred when the recovery lands");
        uint256 navBefore = v.grossNav();
        uint256 taBefore = v.totalAssets();

        /// @dev MEASURED ACROSS THE SALE, not across the crank. Under pooling the proceeds are credited to
        /// @dev the vault's (lender, quote) position the moment the buyer pays, so THAT is where the rise
        /// @dev lands; the crank that follows only moves it home and is NAV-flat. The deferral is the
        /// @dev subject either way -- what must never happen is a rise reaching the share price in-block.
        _buyPot(keeper, loanId, pot);
        uint256 came = v.grossNav() - navBefore;
        assertGt(came, 0, "LIVENESS: the recovery really did come home");
        assertEq(v.totalAssets(), taBefore, "and NOT ONE WEI of it reaches the share price in the same block");

        vm.prank(bob);
        v.crank();

        v.collectFee(); // the cheapest permissionless sync: it stamps the observed rise onto the pile
        assertGe(v.unvested(), came - 1, "the pile is what is holding the whole of it");
        _warpBy(uint256(VEST_W) + 1);
        assertEq(v.unvested(), 0, "the deferral is a delay and never a haircut");
        assertGe(v.totalAssets(), taBefore + came - 1, "so the whole recovery reaches the LPs once it matures");
    }

    /// @dev `crank` is PERMISSIONLESS and ends in `_collectFeeAt`, so
    /// @dev anyone can move a removed market's value home with a fee collection right behind it.
    /// @dev It is safe for ONE reason: `feeHighWater` never follows a loss down, and the loss drove NAV under it.
    function test_RemoveThenRecoverMintsNoFeeBelowTheHighWaterMark() public {
        CuratorVault v = _newVault(FEE);
        _lpDeposit(v, alice, SEED);
        uint256 good = _open(DRAW);
        _crank(v, good, T2, 0);
        _warpBy(30 days);
        _repay(good, lens.loan(good).debt);
        _crankAll(v);
        _warpBy(uint256(VEST_W) + 1);
        v.collectFee(); // the high-water mark, stamped while the vault is at its best
        uint256 mark = v.feeHighWater();
        uint256 held = v.balanceOf(curator);
        assertGt(mark, 0, "fixture: a mark really was stamped");
        assertGt(held, 0, "fixture: and the curator really did earn under it");

        uint256 doomed = _open(DRAW);
        _crank(v, doomed, T2, 0);
        _finalize(doomed);
        _crankAll(v); // the write-off drives the share price far under the mark
        _remove(v);

        _buyPot(bob, doomed, 500e6); // a PARTIAL recovery: enough to matter, never enough to clear the mark
        uint256 owedBefore = ace.lenderOwed(address(v), v.asset());
        assertGt(owedBefore, 0, "fixture: the partial recovery is sitting at the hub, owed to this vault");
        vm.prank(stranger);
        v.crank();
        /// @dev NAV is flat across any lap, since the pool counts a removed market exactly as it counted a held one.
        /// @dev What a permissionless caller can be seen to do is take the credit OFF the hub, so measure that.
        assertEq(ace.lenderOwed(address(v), v.asset()), 0, "LIVENESS: a permissionless caller moved the whole recovery home");

        _warpBy(uint256(VEST_W) + 1); // give the recovery every chance to vest into a fee
        v.collectFee();
        assertLt(v.totalAssets(), mark, "LIVENESS: still under the high-water mark");
        assertEq(v.balanceOf(curator), held, "so the recovery mints the curator not one share");
        assertEq(v.feeHighWater(), mark, "and the mark never followed the loss down to meet it");
        assertEq(v.pendingFeeShares(), 0, "the view says the same thing");
    }
}
