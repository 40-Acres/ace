// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {NoRecordPrice} from "../../src/ace/hub/Ace.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {UnsoldPotRig, IDeadPotOverride} from "./CuratorVaultUnsoldPotRig.sol";

/// @title CuratorVaultDeadPotOverride
/// @notice The guardian's override for a pot that can never sell: it checks the hub's settled count against the one the guardian names.
/// @notice Entry is then admitted while the settled count equals the snapshot, which holds the unsold count at or under it.
/// @notice Any later settlement voids it until the guardian exempts again; a vault with no guardian has no override.
/// @dev Every default here is SMALL, so no price gate stands and only the unsold-pot gate decides.
contract CuratorVaultDeadPotOverrideTest is UnsoldPotRig {
    /// @dev Revive the rig market's record at the market's own price, so the hub's ask sits at book; after any door borrow in it.
    function _askAtBook() internal {
        rec1.setMinPrice(ace.idToMarketParams(mid).price);
    }

    /// @dev A default in the rig's market whose record then goes dark for good, so no buyer can take the pot.
    function _deadPot(CuratorVault v) internal returns (uint256 loanId) {
        loanId = _defaultIn(v, mid, rec1, SMALL);
        rec1.setMinPrice(0);
        _assertNoBuyer(loanId);
    }

    /// @dev Every buy of this pot is refused: the record cannot price its ask.
    function _assertNoBuyer(uint256 loanId) internal {
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(keeper, SEED);
        vm.startPrank(keeper);
        _approveCash(ace.loanMarket(loanId), SEED);
        vm.expectRevert(NoRecordPrice.selector);
        ace.buyInventory(loanId, SEED, 0, keeper);
        vm.stopPrank();
    }

    /// @dev A vault with its stayer in, and one dead pot standing.
    function _vaultWithADeadPot() internal returns (CuratorVault v, uint256 loanId) {
        v = _gateVault();
        _lpDeposit(v, alice, SEED);
        loanId = _deadPot(v);
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u, 1, "PREMISE: one unsold pot");
        assertEq(s, 1, "PREMISE: one ever settled");
        _assertShut(v, bob);
    }

    /// @dev A second default, in a second market of the vault's, which settles a new pot.
    function _newDefault(CuratorVault v) internal returns (bytes32 m2, uint256 loanId) {
        MockPersistenceRecord r2;
        (m2, r2) = _secondMarket(v);
        loanId = _defaultIn(v, m2, r2, SMALL);
    }

    // ---- the key ----

    /// @notice THE CURATOR AND A STRANGER HOLD NO KEY: each is refused `NotGuardian`, and entry stays shut.
    function test_Override_TheCuratorAndAStrangerHoldNoKey() public {
        (CuratorVault v,) = _vaultWithADeadPot();
        vm.prank(curator);
        vm.expectRevert(NotGuardian.selector);
        IDeadPotOverride(address(v)).exemptDeadPots(1);
        vm.prank(carol);
        vm.expectRevert(NotGuardian.selector);
        IDeadPotOverride(address(v)).exemptDeadPots(1);
        _assertShut(v, bob);
    }

    /// @notice A VAULT WITH NO GUARDIAN HAS NO OVERRIDE: even the zero address is refused, and so is the curator.
    function test_Override_AVaultWithNoGuardianHasNoKey() public {
        CuratorVault v = _keylessVault();
        _lpDeposit(v, alice, SEED);
        _deadPot(v);
        vm.prank(address(0));
        vm.expectRevert(NotGuardian.selector);
        IDeadPotOverride(address(v)).exemptDeadPots(1);
        vm.prank(curator);
        vm.expectRevert(NotGuardian.selector);
        IDeadPotOverride(address(v)).exemptDeadPots(1);
        _assertShut(v, bob);
    }

    // ---- the snapshot ----

    /// @notice THE OVERRIDE ADMITS ENTRY OVER THE DEAD POT IT SNAPSHOTTED, and says so in its event.
    function test_Override_AdmitsEntryOverTheSnapshottedDeadPot() public {
        (CuratorVault v,) = _vaultWithADeadPot();
        vm.expectEmit(address(v));
        emit DeadPotsExempted(1, 1);
        _exempt(v, 1);
        _assertOpen(v, bob);
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u, 1, "the dead pot still stands at the hub");
        assertEq(s, 1, "and nothing has settled since");
    }

    /// @notice THE GUARDIAN MUST NAME THE SETTLED COUNT IT SAW: any other is refused `PotsMoved`, which carries the live count to re-read.
    function test_Override_RefusesCountsTheGuardianDidNotName() public {
        (CuratorVault v,) = _vaultWithADeadPot();
        uint256[2] memory wrong = [uint256(0), 2];
        for (uint256 i; i < wrong.length; i++) {
            vm.prank(guardian);
            vm.expectRevert(abi.encodeWithSelector(PotsMoved.selector, 1));
            IDeadPotOverride(address(v)).exemptDeadPots(wrong[i]);
        }
        _assertShut(v, bob);
    }

    /// @notice A RAIDER WHO SETTLES AHEAD OF THE GUARDIAN VOIDS THE CALL: the settled count moved, so the override never lands over the raider's pot.
    function test_Override_ASettlementAheadOfTheGuardianIsRefused() public {
        (CuratorVault v,) = _vaultWithADeadPot();
        _newDefault(v);
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u, 2, "PREMISE: the raider's pot joined the dead one");
        assertEq(s, 2, "PREMISE: and the settled count moved");
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(PotsMoved.selector, 2));
        IDeadPotOverride(address(v)).exemptDeadPots(1);
        _assertShut(v, bob);
    }

    /// @notice A POT THAT SELLS BETWEEN THE GUARDIAN'S READ AND ITS CALL DOES NOT BOUNCE IT: a fall in the unsold count is benign.
    /// @dev Only a new settlement could put a raider's pot under the exemption, so only the settled count is checked.
    function test_Override_APotSellingBeforeTheCallStillLands() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        uint256 a = _defaultIn(v, mid, rec1, SMALL);
        _defaultIn(v, mid, rec1, SMALL);
        (uint256 u, uint256 s) = _counts(v); // the guardian's read
        assertEq(u, 2, "PREMISE: two pots stand when the guardian reads");
        _askAtBook();
        _sellPot(mid, a); // a buyer empties one before the guardian's call lands
        _exempt(v, s);
        _assertOpen(v, bob);
    }

    // ---- the void ----

    /// @notice A NEW SETTLEMENT VOIDS THE OVERRIDE, and it stays void until the guardian exempts again.
    function test_Override_ANewSettlementVoidsItUntilTheGuardianExemptsAgain() public {
        (CuratorVault v,) = _vaultWithADeadPot();
        _exempt(v, 1);
        _assertOpen(v, bob);
        _newDefault(v);
        _assertShut(v, carol);
        _exempt(v, 2);
        _assertOpen(v, carol);
    }

    /// @notice REVIVE THE DEAD POT, SELL IT, THEN DEFAULT: the unsold count is back where the snapshot stood, and entry stays shut.
    /// @dev The settled count is what tells this raid from the dead pot it replaced, which an unsold count alone cannot.
    function test_Override_ReviveSellThenANewDefaultStaysShut() public {
        (CuratorVault v, uint256 dead) = _vaultWithADeadPot();
        _exempt(v, 1);
        _askAtBook();
        _sellPot(mid, dead);
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u, 0, "PREMISE: the revived pot sold");
        _assertOpen(v, bob);
        _newDefault(v);
        (u, s) = _counts(v);
        assertEq(u, 1, "PREMISE: the unsold count is back at the snapshot's");
        assertEq(s, 2, "PREMISE: over a higher settled count");
        _assertShut(v, carol);
    }

    /// @notice A DEAD POT SELLING UNDER THE OVERRIDE LEAVES ENTRY OPEN: the unsold count falls under the snapshot, nothing new settled.
    /// @dev Two dead pots, revived one at a time, so the middle state reads one unsold under a snapshot of two.
    function test_Override_DeadPotsSellingUnderItLeaveEntryOpen() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        uint256 a = _defaultIn(v, mid, rec1, SMALL);
        uint256 b = _defaultIn(v, mid, rec1, SMALL);
        rec1.setMinPrice(0);
        _assertNoBuyer(a);
        _assertShut(v, bob);
        _exempt(v, 2);
        _assertOpen(v, bob);
        _askAtBook();
        _sellPot(mid, a);
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u, 1, "PREMISE: one dead pot sold, one stands");
        assertEq(s, 2, "PREMISE: nothing new settled");
        _assertOpen(v, carol);
        _sellPot(mid, b);
        (u,) = _counts(v);
        assertEq(u, 0, "PREMISE: both sold");
        _assertOpen(v, alice);
    }

    /// @notice THE SNAPSHOT IS ONE WORD APPENDED AFTER THE REQUESTS MAPPING, at ROOT + 5 of `ace.curatorvault`, so no earlier word moved.
    function test_Override_TheSnapshotIsTheWordAfterTheRequests() public {
        (CuratorVault v,) = _vaultWithADeadPot();
        uint256 root = uint256(keccak256(abi.encode(uint256(keccak256("ace.curatorvault")) - 1)) & ~bytes32(uint256(0xff)));
        assertEq(uint256(vm.load(address(v), bytes32(root + 5))), 0, "PREMISE: a never-exempted vault stores no snapshot");
        _exempt(v, 1);
        assertEq(uint256(vm.load(address(v), bytes32(root + 5))), 1, "the settled snapshot is not at ROOT + 5");
        vm.store(address(v), bytes32(root + 5), bytes32(0));
        _assertShut(v, bob);
    }

    /// @notice A NEVER-EXEMPTED VAULT IS NOT OPEN BY DEFAULT: its first pot shuts entry, the one-word snapshot being zero.
    /// @notice An exemption taken at zero is harmless too: a pot always moves the settled count off zero.
    function test_Override_ANeverExemptedVaultIsShutByItsFirstPot() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        _exempt(v, 0);
        _defaultIn(v, mid, rec1, SMALL);
        _assertShut(v, bob);
        CuratorVault w = _gateVault();
        _lpDeposit(w, alice, SEED);
        _defaultIn(w, mid, rec1, SMALL);
        _assertShut(w, bob);
    }
}
