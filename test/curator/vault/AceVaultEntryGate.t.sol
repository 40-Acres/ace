// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @dev The two lens views this suite pins, called on the lens the rig built from its artifact.
interface IEntryGateLens {
    function entryGate(address vault) external view returns (bytes4 reason, uint256 until);
    function troughHoldOf(address vault) external view returns (uint48);
}

/// @title AceVaultEntryGate
/// @notice `AceVaultLens.entryGate` names why entry is shut in the order `deposit` refuses, and reads OPEN exactly when `maxDeposit` is nonzero.
/// @notice `troughHoldOf` reads the stored hold: zero none, all ones marked, else its second.
contract AceVaultEntryGateTest is AceVaultBaseRig {
    uint48 internal constant MARKED = type(uint48).max;

    function _gate() internal view returns (IEntryGateLens) {
        return IEntryGateLens(address(vlens));
    }

    function _storedHold() internal view returns (uint48) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint48(uint256(vault.extsload(s)[0]) >> 200);
    }

    /// @dev The gate's reason, checked against `maxDeposit` for a receiver the product caps nowhere, and against the verb's own refusal.
    function _parity(bytes4 want) internal returns (uint256 until) {
        bytes4 reason;
        (reason, until) = _gate().entryGate(address(vault));
        assertEq(reason, want, "the gate named another reason");
        assertEq(reason == bytes4(0), vault.maxDeposit(bob) > 0, "the gate's OPEN disagreed with maxDeposit");
        assertEq(_gate().troughHoldOf(address(vault)), _storedHold(), "troughHoldOf is not the stored hold");
        uint256 snap = vm.snapshotState();
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000e6);
        (bool ok, bytes memory err) = address(vault).call(abi.encodeCall(vault.deposit, (1_000e6, bob)));
        vm.stopPrank();
        vm.revertToState(snap);
        assertEq(ok, reason == bytes4(0), "the verb disagreed with the gate");
        if (!ok && reason != AceVault.Draining.selector) assertEq(bytes4(err), reason, "the verb refused with another reason");
    }

    /// @dev A loan of the rig's ask lapses and settles at the hub; a crank marks the material fall over its unsold pot.
    function _defaulted() internal returns (uint256 loanId) {
        loanId = _borrow();
        _warpTo(read.loan(loanId).expiry + 1);
        ace.forceClose(loanId);
        vault.crank();
    }

    function _buyPot(uint256 loanId) internal {
        usdc.mint(stranger, 10_000_000e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 10_000_000e6);
        ace.buyInventory(loanId, 10_000_000e6, 0, stranger);
        vm.stopPrank();
    }

    /// @notice OPEN on a live vault with nothing standing.
    function test_EntryGate_OpenOnAQuietVault() public {
        assertEq(_parity(bytes4(0)), 0, "an open gate named a second");
    }

    /// @notice A gain over the band reads `GainVesting`, lifting by the vest's maturity at the latest.
    function test_EntryGate_GainVesting() public {
        usdc.mint(address(vault), LP_CASH / 10);
        vault.crank();
        uint256 until = _parity(AceVault.GainVesting.selector);
        assertEq(until, _now() + VEST_W, "the gain gate's second is not the vest's maturity");
    }

    /// @notice A pot unsold at the hub reads `InventoryUnsold`, with no knowable second; so does the mark over it.
    function test_EntryGate_InventoryUnsold() public {
        _defaulted();
        assertEq(_storedHold(), MARKED, "premise: the vault is marked");
        assertEq(_parity(AceVault.InventoryUnsold.selector), 0, "an unsold pot named a second");
    }

    /// @notice The pot sold: the stored hold reads `RecoveryVesting`, lifting by its stored second.
    function test_EntryGate_RecoveryVesting() public {
        uint256 loanId = _defaulted();
        _warpBy(1 hours);
        _buyPot(loanId);
        vault.crank();
        uint48 held = _storedHold();
        assertGt(uint256(held), _now(), "premise: a stored hold");
        assertLt(held, MARKED, "premise: a second, not the mark");
        assertEq(_parity(AceVault.RecoveryVesting.selector), held, "the hold's second is not the stored one");
    }

    /// @notice A sale no sync has seen over a marked vault reads `RecoveryVesting` with a second to come, as the next sync would hold.
    function test_EntryGate_RecoveryVestingWhileStillMarked() public {
        uint256 loanId = _defaulted();
        _warpBy(1 hours);
        _buyPot(loanId);
        assertEq(_storedHold(), MARKED, "premise: still marked, the sale unsynced");
        assertGt(_parity(AceVault.RecoveryVesting.selector), _now(), "a mark over a cleared pot named no second to come");
    }

    /// @notice A sale no sync has seen over a marked vault names the second the next sync stores, the pile's maturity once the sale is stamped.
    function test_EntryGate_StillMarkedNamesTheSecondTheNextSyncStores() public {
        uint256 loanId = _defaulted();
        _warpBy(1 hours);
        _buyPot(loanId);
        assertEq(_storedHold(), MARKED, "premise: still marked, the sale unsynced");
        uint256 until = _parity(AceVault.RecoveryVesting.selector);
        vault.crank();
        assertGt(uint256(_storedHold()), _now(), "premise: the sync stored a second to come");
        assertEq(until, _storedHold(), "the gate named another second than the sync stored");
    }

    /// @notice A drain reads `Draining`, where the verb refuses on the product's zero cap.
    function test_EntryGate_Draining() public {
        vm.prank(curator);
        vault.setDrain(true);
        assertEq(_parity(AceVault.Draining.selector), 0, "a drain named a second");
    }

    /// @notice Live shares over a NAV of zero read `EndOfLife`, first of all.
    function test_EntryGate_EndOfLife() public {
        deal(address(usdc), address(vault), 0);
        assertEq(vault.totalAssets(), 0, "premise: NAV is zero");
        assertEq(_parity(AceVault.EndOfLife.selector), 0, "end of life named a second");
    }

    /// @notice At its stored second the hold reads OPEN again; the pile has vested by then, so this row cannot tell `<` from `<=` at the edge.
    function test_EntryGate_OpenOnceTheHoldLifts() public {
        uint256 loanId = _defaulted();
        _warpBy(1 hours);
        _buyPot(loanId);
        vault.crank();
        _warpTo(_storedHold());
        _parity(bytes4(0));
    }
}
