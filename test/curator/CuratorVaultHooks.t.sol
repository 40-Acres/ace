// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVault} from "../../src/vault/AceVault.sol";
import {CuratorTerms, Row} from "../../src/vault/curated/CuratorTerms.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../src/vault/libraries/AceVaultFlows.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {MockTerms} from "./vault/MockTerms.sol";

/// @title CuratorVaultHooks
/// @notice A product answers the borrow terms; whatever market they name, the door's core still refuses the vault's own two tokens.
/// @notice And on a curated vault the table answers first: an own token can be neither listed nor borrowed against.
contract CuratorVaultHooksTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;

    // ---- the base refuses its own two tokens as collateral, whatever the product's terms name ----

    /// @dev This vault's own cash and its own share, and the refusal each one meets at the door's core.
    function _own(address v) internal view returns (address[2] memory own, bytes4[2] memory why) {
        own = [address(usdc), v];
        why = [AceVaultFlows.CashIsNotCollateral.selector, AceVaultFlows.SharesAreNotCollateral.selector];
    }

    /// @notice THE DOOR REFUSES THE VAULT'S CASH AND ITS SHARES even where the product's terms name them, and creates no market.
    function test_OwnTokens_TheDoorRefusesTheCashAndTheShares() public {
        (AceVault h, MockTerms t) = _onMockTerms(0);
        _lpDeposit(h, alice, SEED);
        (address[2] memory own, bytes4[2] memory why) = _own(address(h));
        for (uint256 i; i < 2; ++i) {
            MarketParams memory p = AceFixtures.marketParams(address(usdc), address(collateral));
            p.collateral = own[i];
            p.lender = address(h);
            p.settleBountyBps = 0;
            t.setTerms(p, Terms({units: 1e6, principal: 100e6, tenor: 0, minBufferWad: 0}));
            vm.prank(borrower);
            vm.expectRevert(why[i]);
            h.borrow(BorrowRequest(own[i], 1e6, 100e6, 0, 0, 0, 0), "", "");
            assertEq(ace.idToMarketParams(keccak256(abi.encode(p))).lender, address(0), "no market was created");
        }
    }

    /// @notice ON THE SHIPPED VAULT THE TABLE ANSWERS FIRST: an own token is never listed, so a borrow naming it is `NotListed` before any core check.
    /// @dev And the table refuses to list either own token at all, so no timelock can ever make one borrowable.
    function test_OwnTokens_AnUnlistedOwnTokenIsRefusedByTheTableFirst() public {
        AceVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        CuratorTerms t = _terms(v);
        (address[2] memory own,) = _own(address(v));
        for (uint256 i; i < 2; ++i) {
            vm.prank(borrower);
            vm.expectRevert(CuratorTerms.NotListed.selector);
            v.borrow(BorrowRequest(own[i], 1e6, 100e6, 0, 0, 0, 0), "", "");
            Row memory row = _row(address(collateral));
            vm.prank(curator);
            vm.expectRevert(CuratorTerms.BadRow.selector);
            t.submitCollateral(own[i], row);
        }
    }

    // ---- the sealed members still do what they did ----

    /// @notice THE ASSET IS THE CONFIGURED CASH, and a deposit pulls exactly the assets it names into the vault's own balance.
    function test_Seal_TheAssetIsTheCash_ADepositPullsExactlyItsAssets() public {
        AceVault v = _newVault(0);
        assertEq(v.asset(), address(usdc), "the asset is the configured cash");
        uint256 held0 = usdc.balanceOf(address(v));
        usdc.mint(alice, SEED + 7);
        vm.startPrank(alice);
        usdc.approve(address(v), SEED + 7);
        v.deposit(SEED, alice);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 7, "exactly the named assets left the depositor");
        assertEq(usdc.balanceOf(address(v)) - held0, SEED, "and all of them reached the vault");
    }

    /// @notice A SHARE TRANSFER MOVES THE TWO BALANCES AND NOTHING ELSE: AceVault adds no share-move hook.
    function test_Seal_AShareTransferMovesBalancesAndNothingElse() public {
        AceVault v = _newVault(0);
        uint256 shares = _lpDeposit(v, alice, SEED);
        uint256 nav = v.totalAssets();
        uint256 supply = v.totalSupply();
        vm.prank(alice);
        v.transfer(bob, shares / 3);
        assertEq(v.balanceOf(bob), shares / 3, "the receiver holds what was sent");
        assertEq(v.balanceOf(alice), shares - shares / 3, "the sender holds the rest");
        assertEq(v.totalSupply(), supply, "no share was minted or burned");
        assertEq(v.totalAssets(), nav, "and NAV did not move");
    }
}
