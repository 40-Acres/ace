// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../src/vault/AceVault.sol";
import {AceVaultBaseRig} from "../curator/vault/AceVaultBaseRig.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title AceVaultBaseHooks
/// @notice B1: in-kind mode reports every share move to the tracker once, with its exact value: mint, burn, transfer, escrow and release.
/// @notice Read through the tracker's own view of each move, `trackedOf` and `trackedSupply`; an escrow leg moves no tracked share.
/// @notice B2: an in-kind vault refuses a deposit while the hub reports an uncollected pot of its own.
contract AceVaultBaseHooksTest is InKindRig {
    /// @notice A deposit reports its mint: the depositor's tracked balance and the tracked supply hold exactly the shares minted.
    function test_B1_aDepositReportsTheMint() public {
        uint256 sh = _lp(alice, 1_000e6);
        assertEq(_tracked(alice), sh, "deposit: the mint landed on the depositor at its exact value");
        assertEq(_tracked(alice), vault.balanceOf(alice), "deposit: one move reported, the mint's");
        assertEq(_trackedSupply(), sh, "deposit: the tracked supply took the mint at once");
    }

    /// @notice A transfer reports both sides: the sender's tracked balance loses exactly the value and the receiver's gains it.
    function test_B1_aTransferReportsBothSides() public {
        uint256 sh = _lp(alice, 1_000e6);
        vm.prank(alice);
        vault.transfer(bob, sh / 3);
        assertEq(_tracked(alice), sh - sh / 3, "transfer: the sender's side, at the exact value");
        assertEq(_tracked(bob), sh / 3, "transfer: the receiver's side, at the exact value");
        assertEq(_tracked(alice) + _tracked(bob), vault.totalSupply() - vault.SEED_SHARES(), "transfer: no other share moved; the seed is untracked");
    }

    /// @notice A redeem reports its burn: the owner's tracked shares fall by exactly the shares burned.
    function test_B1_aRedeemReportsTheBurn() public {
        uint256 sh = _lp(alice, 1_000e6);
        _lp(bob, 1_000e6);
        vm.prank(alice);
        vault.redeem(sh / 2, alice, alice);
        assertEq(_tracked(alice), sh - sh / 2, "redeem: the burn, at its exact value");
        assertEq(_tracked(alice), vault.balanceOf(alice), "redeem: the tracker follows the balance");
    }

    /// @notice A request and a cancel move no tracked share, as their legs touch only the escrow; a claim's burn is charged to its requester.
    function test_B1_aRequestCancelAndClaimReportTheEscrowLegs() public {
        uint256 sh = _lp(alice, 1_000e6);
        _lp(bob, 1_000e6);
        vm.prank(alice);
        vault.requestExit(sh / 2);
        assertEq(_tracked(alice), sh, "request: the escrow leg moves no tracked share");
        assertEq(_tracked(address(vault)), 0, "request: and the vault's own address tracks nothing");
        vm.prank(alice);
        vault.cancelExit(sh / 4);
        assertEq(_tracked(alice), sh, "cancel: the release leg moves none either");
        vm.prank(alice);
        vault.claimExit(sh / 4, alice, 0);
        assertEq(_tracked(alice), sh - sh / 4, "claim: the escrow's burn, charged to the requester at its exact value");
    }

    /// @notice A fee mint reports the curator: its tracked balance holds exactly the fee shares, counted in the tracked supply at once.
    function test_B1_aFeeMintReportsTheCurator() public {
        vault = _deploy(_cfg(1000), _ik(), _listings());
        uint256 sa = _lp(alice, 1_000_000e6);
        usdc.mint(address(vault), 100_000e6);
        vault.crank();
        _warpBy(VEST_W + 1);
        vault.collectFee();
        uint256 fee = vault.balanceOf(curator);
        assertGt(fee, 0, "premise: a fee minted");
        assertEq(_tracked(curator), fee, "fee mint: the curator, at the exact value");
        assertEq(_trackedSupply(), sa + fee, "fee mint: counted in the tracked supply at the mint");
    }

    /// @notice An in-kind vault refuses a deposit while the hub reports this vault's pot, settled by a stranger, uncollected, as a hub-ask vault does.
    function test_B2_anInKindVaultRefusesTheDepositWhileAPotIsUnsold() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(unsold, 1, "premise: the hub reports an uncollected pot");
        _expectEntryShut(bob, 1_000e6, "an in-kind entry over an uncollected pot");
    }
}

/// @title AceVaultBaseHooksHubAsk
/// @notice B2: a hub-ask AceVault shuts entry while the hub reports an unsold pot of its own.
contract AceVaultBaseHooksHubAskTest is AceVaultBaseRig {
    /// @notice The stock gate: a pot a stranger settled and nobody bought refuses the next deposit `InventoryUnsold`.
    function test_B2_theStockGateShutsEntryOnAnUnsoldPot() public {
        uint256 loanId = _borrow();
        _warpAtLeastTo(read.loan(loanId).expiry);
        vm.prank(stranger);
        ace.forceClose(loanId);
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(unsold, 1, "premise: the hub reports an uncollected pot");
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(AceVault.InventoryUnsold.selector);
        vault.deposit(1_000e6, bob);
        vm.stopPrank();
    }
}
