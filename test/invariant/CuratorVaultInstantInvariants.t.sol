// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {CuratorVaultInstantHandler} from "./CuratorVaultInstantHandler.sol";

/// @title CuratorVaultInstantInvariants
/// @notice THE STATEFUL CAMPAIGN OVER THE PRODUCTION VAULT'S INSTANT EXIT, beside its exit request and its drain.
/// @notice J2. An instant exit while lending never pays into the exitable cash the standing requests hold.
/// @notice J3. An exit pays its own preview, leaves the stayers' price, and takes at most its shares' part of the NAV, plus a wei.
/// @notice J4. `redeem(maxRedeem)`, `withdraw(maxWithdraw)` and `claimExit(maxClaim)` always land, and a claim never pays past exitable cash.
/// @notice J5. No exit takes its exiter's last free shares while a gain vests, an LP counted without the curator's: the last free holder requests.
/// @notice J8. The max views stay inside the holding and exitable cash less the requests' hold, or all of exitable under the drain; entry is shut then.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false.
/// @dev The curator is an exiting party, judged against the whole free supply; its fee shares make an LP's LP-only count differ from it.
/// @dev `afterInvariant` guards that a run which tried a claim or the drain landed one.
contract CuratorVaultInstantInvariantsTest is StdInvariant, Test {
    CuratorVaultInstantHandler internal handler;
    CuratorVault internal vault;

    function setUp() public {
        handler = new CuratorVaultInstantHandler();
        vault = handler.vault();
        /// @dev DUPLICATES ARE WEIGHTS: the exits are the subject.
        bytes4[] memory sel = new bytes4[](25);
        sel[0] = CuratorVaultInstantHandler.deposit.selector;
        sel[1] = CuratorVaultInstantHandler.redeem.selector;
        sel[2] = CuratorVaultInstantHandler.redeem.selector;
        sel[3] = CuratorVaultInstantHandler.redeemMax.selector;
        sel[4] = CuratorVaultInstantHandler.withdrawMax.selector;
        sel[5] = CuratorVaultInstantHandler.requestExit.selector;
        sel[6] = CuratorVaultInstantHandler.claimMax.selector;
        sel[7] = CuratorVaultInstantHandler.drainOn.selector;
        sel[8] = CuratorVaultInstantHandler.drainOff.selector;
        sel[9] = CuratorVaultInstantHandler.claimMax.selector;
        sel[10] = CuratorVaultInstantHandler.crank.selector;
        sel[11] = CuratorVaultInstantHandler.warp.selector;
        sel[12] = CuratorVaultInstantHandler.openLoan.selector;
        sel[13] = CuratorVaultInstantHandler.repayLoan.selector;
        sel[14] = CuratorVaultInstantHandler.settleLoan.selector;
        sel[15] = CuratorVaultInstantHandler.gain.selector;
        sel[16] = CuratorVaultInstantHandler.redeem.selector;
        sel[17] = CuratorVaultInstantHandler.redeemMax.selector;
        sel[18] = CuratorVaultInstantHandler.requestExit.selector;
        sel[19] = CuratorVaultInstantHandler.warp.selector;
        sel[20] = CuratorVaultInstantHandler.redeemAll.selector;
        sel[21] = CuratorVaultInstantHandler.redeemAll.selector;
        sel[22] = CuratorVaultInstantHandler.repayLoan.selector;
        sel[23] = CuratorVaultInstantHandler.settleLoan.selector;
        sel[24] = CuratorVaultInstantHandler.withdrawMax.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice The control: each exit channel the campaign weighs really lands from the seed state, the drain's exit included.
    /// @dev The drained exit is paid from exitable cash, which the drain leaves wholly to exits, first come.
    function test_TheHandlerLandsEveryExitChannel() public {
        handler.redeem(0, 1e15);
        handler.redeemMax(1);
        handler.withdrawMax(2);
        handler.drainOn(true);
        handler.repayLoan(0);
        handler.redeem(3, 1e12);
        assertEq(handler.exitsPaid(), 4, "an exit channel landed nothing from the seed state");
        assertEq(handler.maxExitsPaid(), 2, "a max ask landed nothing from the seed state");
        assertEq(handler.drainsOn(), 1, "the guardian's drain did not land");
        assertEq(handler.drainedExitsPaid(), 1, "the drain refused an instant exit");
    }

    /// @notice The control for J5: with the loan repaid and a gain vesting, every LP and then the curator try to leave whole.
    /// @notice The curator holds no share here, so the fourth LP, last, holds the whole free supply, and the refusal it counts is that LP's.
    function test_TheHandlerReachesTheLastFreeHolder() public {
        handler.repayLoan(0);
        handler.gain(100e6);
        handler.crank();
        for (uint256 i; i < 4; i++) {
            handler.redeemAll(i);
        }
        handler.redeemAll(4);
        assertEq(handler.lastOutRefused(), 1, "the fourth LP, last free holder over a vesting gain, was not refused");
        assertFalse(handler.pileTaken(), "PREMISE: no exit took the pile");
    }

    /// @notice The control for J4's claim leg: a request, which holds exitable cash at once, a repayment, and the claim of exactly `maxClaim`.
    function test_TheHandlerLandsARequestAndAClaim() public {
        handler.requestExit(1, type(uint256).max);
        handler.repayLoan(0);
        handler.claimMax(1);
        assertEq(handler.requestsStood(), 1, "the request did not stand");
        assertEq(handler.claimsPaid(), 1, "the claim of maxClaim did not land");
        assertFalse(handler.maxAskReverted(), "a max ask reverted");
    }

    /// @notice Coverage: a run that tried a claim or the drain landed one.
    function afterInvariant() public view {
        if (handler.claimTries() != 0) assertGt(handler.claimsPaid(), 0, "a run tried claims of maxClaim and none landed");
        if (handler.drainTries() != 0) assertGt(handler.drainsOn(), 0, "a run tried the drain by its keys and none landed");
    }

    /// @notice J2: an instant exit while lending left the requests' hold standing in exitable cash.
    function invariant_J2_AnExitWhileLendingLeavesTheHold() public view {
        assertFalse(handler.holdTouched(), "an instant exit while lending paid into the cash the requests hold");
    }

    /// @notice J3: an exit paid its preview, kept the stayers' price, and took no more than its shares' part of NAV.
    function invariant_J3_AnExitPaysItsQuoteAndLeavesThePrice() public view {
        assertFalse(handler.quoteMissed(), "an exit paid other than its preview");
        assertFalse(handler.priceFell(), "an exit lowered the stayers' price");
        assertFalse(handler.overpaid(), "an exit took more than its shares' part of NAV");
    }

    /// @notice J4: the max asks land, and a claim stays inside exitable cash.
    function invariant_J4_TheMaxAsksLand() public view {
        assertFalse(handler.maxAskReverted(), "redeem(maxRedeem), withdraw(maxWithdraw) or claimExit(maxClaim) reverted");
        assertFalse(handler.claimPastExitable(), "a claim paid past exitable cash");
    }

    /// @notice J5: no exit emptied its exiter's free count while a gain vested.
    function invariant_J5_TheLastFreeHolderNeverTakesThePile() public view {
        assertFalse(handler.pileTaken(), "the last free holder took a vesting pile");
    }

    /// @notice J8: every exiting party's max views sit within its holding and exitable cash less the requests' hold, or all of exitable under the drain.
    /// @notice Entry is shut while the drain stands, and the vault's own balance never reads as exitable.
    function invariant_J8_TheMaxViewsStayInsideTheHoldingAndThePot() public view {
        bool draining = vault.draining();
        (uint256 exitable, uint256 held) = vault.holds();
        uint256 cash = draining ? exitable : exitable - held;
        for (uint256 i; i < 5; i++) {
            address who = i < 4 ? handler.actors(i) : vault.CURATOR();
            (uint256 r, uint256 w) = (vault.maxRedeem(who), vault.maxWithdraw(who));
            assertLe(r, vault.balanceOf(who), "maxRedeem offered past the holding");
            assertLe(w, cash, "maxWithdraw offered past the cash an exit may take");
            (uint256 req,) = vault.requestOf(who);
            assertLe(vault.maxClaim(who), req, "maxClaim offered past the request");
        }
        if (draining) assertEq(vault.maxDeposit(handler.actors(0)), 0, "entry stood open under the drain");
        assertEq(vault.maxRedeem(address(vault)) + vault.maxWithdraw(address(vault)), 0, "the vault's own escrow read as exitable");
    }
}
