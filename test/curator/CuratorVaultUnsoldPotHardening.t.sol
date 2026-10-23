// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {NoRecordPrice} from "../../src/ace/hub/Ace.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {UnsoldPotRig, IDeadPotOverride} from "./CuratorVaultUnsoldPotRig.sol";

/// @title CuratorVaultUnsoldPotHardening
/// @notice The unsold-pot gate's two views against its two verbs in every gated state, at supply zero and above.
/// @notice And the guardian's exemption across its lifecycle: renewed, repeated, taken over nothing, and the event's two counts.
/// @dev Every default is SMALL, so no price gate stands unless a row builds one on purpose.
contract CuratorVaultUnsoldPotHardeningTest is UnsoldPotRig {
    address internal prober = address(0x9B0BE);

    /// @dev Set the rig market's record minimum to the market's own price, so the hub's ask sits at book; after any door borrow in it.
    function _askAtBook() internal {
        rec1.setMinPrice(ace.idToMarketParams(mid).price);
    }

    /// @dev Both views against both verbs at one atom, the state put back after each: a view reads zero exactly when its verb refuses.
    /// @dev Where `why` is set, both verbs must refuse by exactly that selector, so the gate answering is the one the row names.
    function _agree(CuratorVault v, bool shut, bytes4 why) internal {
        assertEq(v.maxDeposit(prober) == 0, shut, "maxDeposit read the wrong side of the gate");
        assertEq(v.maxMint(prober) == 0, shut, "maxMint read the wrong side of the gate");
        (bool okD, bytes memory errD) = _try(v, abi.encodeCall(v.deposit, (1, prober)));
        (bool okM, bytes memory errM) = _try(v, abi.encodeCall(v.mint, (1, prober)));
        assertEq(okD, !shut, "deposit disagreed with maxDeposit");
        assertEq(okM, !shut, "mint disagreed with maxMint");
        if (why == bytes4(0)) return;
        assertEq(bytes4(errD), why, "deposit was refused by another gate than the row names");
        assertEq(bytes4(errM), why, "mint was refused by another gate than the row names");
    }

    /// @dev One entry call by the prober from a snapshot, funded and approved; returns its outcome and leaves no trace.
    function _try(CuratorVault v, bytes memory call) internal returns (bool ok, bytes memory err) {
        uint256 snap = vm.snapshotState();
        usdc.mint(prober, 1e6);
        vm.prank(prober);
        usdc.approve(address(v), 1e6);
        vm.prank(prober);
        (ok, err) = address(v).call(call);
        vm.revertToState(snap);
    }

    /// @dev The snapshot word at ROOT + 5 of `ace.curatorvault`.
    function _snapshotWord(CuratorVault v) internal view returns (uint256) {
        uint256 root = uint256(keccak256(abi.encode(uint256(keccak256("ace.curatorvault")) - 1)) & ~bytes32(uint256(0xff)));
        return uint256(vm.load(address(v), bytes32(root + 5)));
    }

    /// @dev A default in the rig's market whose record then goes dark, so the pot cannot sell until the record is revived.
    function _deadPot(CuratorVault v) internal returns (uint256 loanId) {
        loanId = _defaultIn(v, mid, rec1, SMALL);
        rec1.setMinPrice(0);
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(keeper, SEED);
        vm.startPrank(keeper);
        _approveCash(ace.loanMarket(loanId), SEED);
        vm.expectRevert(NoRecordPrice.selector);
        ace.buyInventory(loanId, SEED, 0, keeper);
        vm.stopPrank();
    }

    /// @dev A second market of the vault's and a default in it, which settles a new pot.
    function _newDefault(CuratorVault v) internal returns (uint256 loanId) {
        (bytes32 m2, MockPersistenceRecord r2) = _secondMarket(v);
        loanId = _defaultIn(v, m2, r2, SMALL);
    }

    // ---- the view against the verb ----

    /// @notice VIEW AND VERB AGREE THROUGH THE GATE'S WHOLE LIFE AT SUPPLY ZERO AND ABOVE: open, a pot, empty, exempted, entered, voided.
    function test_Agree_EveryGatedStateAtSupplyZeroAndAbove() public {
        CuratorVault v = _gateVault();
        assertEq(v.totalSupply(), 0, "PREMISE: a fresh vault");
        _agree(v, false, 0);
        _lpDeposit(v, alice, SEED);
        _agree(v, false, 0);
        uint256 loanId = _deadPot(v);
        _agree(v, true, InventoryUnsold.selector);
        uint256 all = v.balanceOf(alice);
        vm.prank(alice);
        v.redeem(all, alice, alice);
        assertEq(v.totalSupply(), 0, "PREMISE: the stayer left, so the supply is zero");
        _agree(v, true, InventoryUnsold.selector);
        _exempt(v, 1);
        _agree(v, false, 0);
        _lpDeposit(v, bob, ENTRY);
        assertGt(v.totalSupply(), 0, "PREMISE: the entrant holds shares");
        _agree(v, false, 0);
        _newDefault(v);
        _agree(v, true, InventoryUnsold.selector);
        _exempt(v, 2);
        _agree(v, false, 0);
        _askAtBook();
        _sellPot(mid, loanId);
        v.crank();
        assertGt(v.unvested() * 10_000, v.totalAssets() * v.GATE_BPS(), "PREMISE: the late sale is a gain over the band on the small NAV left");
        _agree(v, true, AceVault.GainVesting.selector);
        _warpBy(VEST_W + 1);
        _agree(v, false, 0);
    }

    /// @notice WITH THE DRAIN ON, THE GATE ANSWERS FIRST: a pot refuses `InventoryUnsold`; exempted, the drain's zero cap refuses instead.
    /// @notice Both views read zero throughout, and the pot's sale under the drain still leaves entry shut by the drain alone.
    function test_Agree_TheGateUnderTheDrain() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _shallowDefault(v);
        vm.prank(curator);
        v.setDrain(true);
        _agree(v, true, InventoryUnsold.selector);
        _exempt(v, 1);
        _agree(v, true, ERC4626.ERC4626ExceededMaxDeposit.selector);
        _askAtBook();
        _sellPot(mid, loanId);
        (uint256 u,) = _counts(v);
        assertEq(u, 0, "PREMISE: the pot sold");
        _agree(v, true, ERC4626.ERC4626ExceededMaxDeposit.selector);
    }

    /// @notice A VESTING GAIN OVER THE BAND STILL REFUSES OVER AN EXEMPTED POT, by the pile; once it vests, entry opens.
    function test_Agree_AnExemptionLeavesThePileGateStanding() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        _shallowDefault(v);
        _exempt(v, 1);
        _agree(v, false, 0);
        _gift(v, SEED / 5);
        v.crank();
        assertGt(v.unvested() * 10_000, v.totalAssets() * v.GATE_BPS(), "PREMISE: a gain over the band is vesting");
        _agree(v, true, AceVault.GainVesting.selector);
        _warpBy(VEST_W + 1);
        _agree(v, false, 0);
    }

    // ---- the exemption's lifecycle ----

    /// @notice EXEMPT, SELL, SETTLE, EXEMPT AGAIN: each exemption names the live counts, the stale count is refused, and the word follows.
    function test_Exempt_ExemptSellSettleThenExemptAgain() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        uint256 dead = _deadPot(v);
        vm.expectEmit(address(v));
        emit DeadPotsExempted(1, 1);
        _exempt(v, 1);
        assertEq(_snapshotWord(v), 1, "the snapshot holds the settled count named");
        _assertOpen(v, bob);
        _askAtBook();
        _sellPot(mid, dead);
        _assertOpen(v, bob);
        _newDefault(v);
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u, 1, "PREMISE: one unsold pot, the new one");
        assertEq(s, 2, "PREMISE: over two ever settled");
        _assertShut(v, carol);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(PotsMoved.selector, 2));
        IDeadPotOverride(address(v)).exemptDeadPots(1);
        vm.expectEmit(address(v));
        emit DeadPotsExempted(1, 2);
        _exempt(v, 2);
        assertEq(_snapshotWord(v), 2, "the renewed snapshot holds the new settled count");
        _assertOpen(v, carol);
    }

    /// @notice THE EVENT CARRIES THE TWO LIVE COUNTS IN ORDER: one unsold over two settled, so a swapped pair cannot pass.
    function test_Exempt_TheEventCarriesUnsoldThenSettled() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        uint256 a = _defaultIn(v, mid, rec1, SMALL);
        _defaultIn(v, mid, rec1, SMALL);
        _askAtBook();
        _sellPot(mid, a);
        (uint256 u, uint256 s) = _counts(v);
        assertEq(u, 1, "PREMISE: one pot left unsold");
        assertEq(s, 2, "PREMISE: two ever settled");
        vm.expectEmit(address(v));
        emit DeadPotsExempted(1, 2);
        _exempt(v, 2);
    }

    /// @notice AN EXEMPTION WITH NOTHING STANDING LANDS AND COVERS NOTHING: at zero counts, then at a sold pot's count, the next pot shuts.
    function test_Exempt_WithNothingStandingCoversNoLaterPot() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        vm.expectEmit(address(v));
        emit DeadPotsExempted(0, 0);
        _exempt(v, 0);
        assertEq(_snapshotWord(v), 0, "the snapshot is the zero count named");
        _assertOpen(v, bob);
        uint256 loanId = _defaultIn(v, mid, rec1, SMALL);
        _assertShut(v, carol);
        _askAtBook(); // after the door borrow, which prices its market off the record
        _sellPot(mid, loanId);
        _assertOpen(v, carol);
        vm.expectEmit(address(v));
        emit DeadPotsExempted(0, 1);
        _exempt(v, 1);
        assertEq(_snapshotWord(v), 1, "the snapshot is the sold pot's settled count");
        _assertOpen(v, bob);
        _newDefault(v);
        _assertShut(v, alice);
    }

    /// @notice TWO EXEMPTIONS IN A ROW ARE ONE: the second lands and emits again, and a stale count after them is refused and moves nothing.
    function test_Exempt_TwoInARowAndAStaleThird() public {
        CuratorVault v = _gateVault();
        _lpDeposit(v, alice, SEED);
        _deadPot(v);
        _exempt(v, 1);
        vm.expectEmit(address(v));
        emit DeadPotsExempted(1, 1);
        _exempt(v, 1);
        assertEq(_snapshotWord(v), 1, "a repeated exemption leaves the same snapshot");
        _assertOpen(v, bob);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(PotsMoved.selector, 1));
        IDeadPotOverride(address(v)).exemptDeadPots(0);
        assertEq(_snapshotWord(v), 1, "the refused call moved no snapshot");
        _assertOpen(v, carol);
    }

    /// @notice THE CURATOR AS GUARDIAN HOLDS THE KEY: the override reads the guardian's address, never a role, so one key can be both.
    function test_Exempt_ACuratorNamedGuardianExempts() public {
        guardian = curator;
        CuratorVault v = _gateVault();
        assertEq(v.GUARDIAN(), curator, "PREMISE: one key is both");
        _lpDeposit(v, alice, SEED);
        _deadPot(v);
        _assertShut(v, bob);
        _exempt(v, 1);
        _assertOpen(v, bob);
    }
}
