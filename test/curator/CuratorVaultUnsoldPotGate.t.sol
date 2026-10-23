// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {UnsoldPotRig} from "./CuratorVaultUnsoldPotRig.sol";

/// @title CuratorVaultUnsoldPotGate
/// @notice Entry waits while the hub shows this vault a settled pot that has not sold, at any supply, after the price gates.
/// @notice The pot's sale reopens it; the views read zero while it is shut; the trough raid (E4) is refused at its deposit.
/// @dev Every default here is SHALLOW, so no price gate stands, the price gates admit the entrant, and only the new gate refuses.
contract CuratorVaultUnsoldPotGateTest is UnsoldPotRig {
    uint256 internal constant RAID = 90_000e6; // nine times the stayer's stake: the raider's deposit at the trough

    /// @dev Set the record's minimum to the market's own price, so the hub's ask sits at book and a sale's rise stays under the pile gate.
    function _askAtBook() internal {
        rec1.setMinPrice(ace.idToMarketParams(mid).price);
    }

    /// @notice WITH SHARES OUTSTANDING, AN UNSOLD POT SHUTS ENTRY: both views read zero, and both verbs refuse `InventoryUnsold`.
    function test_Gate_AnUnsoldPotShutsEntryWithSharesOutstanding() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        _shallowDefault(v);
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u, 1, "PREMISE: the hub counts one unsold pot");
        assertEq(s, 1, "PREMISE: and one ever settled");
        assertGt(v.totalSupply(), 0, "PREMISE: shares are outstanding");
        _assertShut(v, bob);
    }

    /// @notice AT SUPPLY ZERO TOO: the empty vault skips the price gates, and the unsold pot still refuses the entrant.
    /// @dev Without it the entrant would own the whole recovery as the pot sells, bought at whatever the residue prices.
    function test_Gate_AnUnsoldPotShutsEntryAtSupplyZero() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        _shallowDefault(v);
        uint256 all = v.balanceOf(alice);
        (uint256 exitable,) = v.holds();
        /// @dev The payout, not `maxRedeem`: at an all-cash NAV under par the share bound floors one atom's sliver short of the balance.
        assertLe(v.previewRedeem(all), exitable, "PREMISE: exitable cash covers the stayer's whole exit");
        vm.prank(alice);
        v.redeem(all, alice, alice);
        assertEq(v.totalSupply(), 0, "PREMISE: the vault is empty");
        (uint256 u,) = _counts(v);
        assertEq(u, 1, "PREMISE: the pot is still unsold");
        _assertShut(v, bob);
    }

    /// @notice THE SALE REOPENS ENTRY: the buy that empties the pot takes it off the count, and the next deposit lands.
    /// @dev The ask is set at book first, so the sale's rise sits under the pile gate and the reopening is the count's alone.
    function test_Gate_ThePotSellsAndEntryReopens() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _shallowDefault(v);
        _assertShut(v, bob);
        _askAtBook();
        _sellPot(mid, loanId);
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u, 0, "PREMISE: the emptying buy took the pot off the count");
        assertEq(s, 1, "PREMISE: and the settled count never falls");
        _assertOpen(v, bob);
    }

    /// @notice A PARTIAL BUY LEAVES ENTRY SHUT: only the buy that empties the pot reopens it.
    function test_Gate_APartialBuyLeavesEntryShut() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _shallowDefault(v);
        _askAtBook();
        uint256 budget = inv.clearingBudget(mid, loanId);
        _buyPot(keeper, loanId, budget / 2);
        assertGt(read.invPotOf(mid, loanId), 0, "PREMISE: half the budget leaves a pot");
        _assertShut(v, bob);
    }

    /// @notice A LOAN REPAID IN FULL LEAVES NO POT AND SHUTS NOTHING: only a settlement moves the count.
    function test_Gate_ARepaidLoanLeavesEntryOpen() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(SHALLOW);
        _repay(loanId, read.debtOf(loanId));
        v.crank();
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u + s, 0, "PREMISE: a clean close counts no pot");
        _assertOpen(v, bob);
    }

    /// @notice E4, THE TROUGH RAID, MEASURED AS REFUSED: the borrower defaults, then enters at the trough to buy the recovery cheap.
    /// @notice Refused at the deposit; so the stayer keeps the whole recovery once the pot sells, and the raider holds no share.
    /// @dev Were the deposit admitted, this row runs the raid out and fails with the raider's capture in the log.
    function test_E4_TheTroughRaidIsRefusedAtItsDeposit() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        uint256 aliceShares = v.balanceOf(alice);
        uint256 loanId = _shallowDefault(v);
        uint256 trough = v.convertToAssets(aliceShares);
        usdc.mint(borrower, RAID);
        vm.prank(borrower);
        usdc.approve(address(v), RAID);
        vm.prank(borrower);
        try v.deposit(RAID, borrower) returns (uint256 shares) {
            _sellPot(mid, loanId);
            v.crank();
            _warpBy(VEST_W + 1);
            uint256 worth = v.convertToAssets(shares);
            emit log_named_uint("E4 ADMITTED, the raider's capture", worth > RAID ? worth - RAID : 0);
            emit log_named_uint("E4 ADMITTED, the stayer's value after the recovery", v.convertToAssets(aliceShares));
            assertTrue(false, "E4: the trough raid was admitted");
        } catch (bytes memory err) {
            assertEq(bytes4(err), InventoryUnsold.selector, "E4: the raid is refused by the unsold pot");
        }
        assertEq(v.balanceOf(borrower), 0, "the raider holds no share");
        _sellPot(mid, loanId);
        v.crank();
        _warpBy(VEST_W + 1);
        uint256 back = v.convertToAssets(aliceShares);
        assertGt(back, trough, "the recovery came back to the stayer");
        assertApproxEqAbs(back, v.totalAssets(), 2, "and all of it: no entrant shares it");
    }

    /// @notice THE PRICE GATES ANSWER FIRST: a vesting gain over the band and an unsold pot together refuse by the pile.
    /// @notice Once the gain vests the pot still stands, and entry still waits for it.
    function test_Gate_RunsAfterThePileGate() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        _shallowDefault(v);
        _gift(v, SEED / 5);
        v.crank();
        assertGt(v.unvested() * 10_000, v.totalAssets() * v.GATE_BPS(), "PREMISE: a gain over the band is vesting");
        usdc.mint(bob, ENTRY);
        vm.startPrank(bob);
        usdc.approve(address(v), ENTRY);
        vm.expectRevert(AceVault.GainVesting.selector);
        v.deposit(ENTRY, bob);
        vm.stopPrank();
        _warpBy(VEST_W + 1);
        assertEq(v.unvested(), 0, "PREMISE: the gain has vested");
        _assertShut(v, carol);
    }

    /// @notice THE DOOR'S MARKET CARRIES THE ASK, with no curator input, so its pot sells and entry reopens.
    function test_AskOn_TheDoorsMarketCarriesTheAskSoThePotSells() public {
        CuratorVault v = _gateVault();
        assertTrue(ace.idToMarketParams(mid).inventoryAsk, "the door's market sells its pots");
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _shallowDefault(v);
        assertTrue(ace.idToMarketParams(ace.loanMarket(loanId)).inventoryAsk, "and so does the market the loan opened in");
        _assertShut(v, bob);
        _askAtBook();
        _sellPot(mid, loanId);
        _assertOpen(v, bob);
    }
}
