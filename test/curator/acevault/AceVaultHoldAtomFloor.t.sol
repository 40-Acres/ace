// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceReader} from "../../utils/AceReader.sol";
import {CuratedVaults} from "../../utils/CuratedVaults.sol";
import {VaultLens} from "../../utils/VaultLens.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultHoldAtomFloor
/// @notice The hold's absolute floor is counted in atoms, not in whole asset units: on an eight-decimal asset a recovery under one unit still holds.
/// @dev The rig's vault, on an eight-decimal cash: one hundred units of NAV, so one basis point is a hundredth of a unit and the floor is 1e4 atoms.
contract AceVaultHoldAtomFloorTest is AceVaultRig {
    uint48 internal constant MARKED = type(uint48).max;
    uint256 internal constant NAV = 100e8;

    function setUp() public override {
        _warpTo(1_000_000);
        usdc = new MockERC20("Wrapped BTC", "WBTC", 8);
        coll = new MockStakeVault(42);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        vaultFactory = CuratedVaults.factory(address(ace));
        record = _record(address(coll), 2e18);
        vault = _newVault(_row(address(record)));
        _lp(alice, NAV);
        vlens = VaultLens.deploy();
    }

    function _hold() internal view returns (uint48) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint48(uint256(vault.extsload(s)[0]) >> 200);
    }

    /// @notice A minimum-ticket default of a tenth of a unit, sold: the pile is under one unit and far over the atom floor, and entry is held.
    function test_AtomFloor_ARecoveryUnderOneUnitOfAnEightDecimalAssetHolds() public {
        uint256 loanId = _borrowAs(borrower, 9e16, MIN_PRINCIPAL, MIN_TENOR);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(keeper);
        ace.forceClose(loanId);
        vault.crank();
        assertEq(_hold(), MARKED, "premise: a fall of a tenth of a unit is material on a hundred-unit vault");
        _warpBy(1 hours);
        usdc.mint(stranger, 1e8);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 1e8);
        ace.buyInventory(loanId, 1e8, 0, stranger);
        vm.stopPrank();
        vault.crank();
        uint256 pile = vault.unvested();
        assertLt(pile, vault.VEST_FLOOR(), "premise: the recovery is under one whole unit");
        assertGt(pile, 1e4, "premise: and over the atom floor");
        assertGt(pile * 10_000, vault.grossNav(), "premise: and over one basis point of gross");
        assertGt(uint256(_hold()), _now(), "the clear stored no hold over a material pile under one unit");
        assertEq(vault.maxDeposit(bob), 0, "the view opened over the hold");
        usdc.mint(bob, 1e8);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1e8);
        vm.expectRevert(AceVault.RecoveryVesting.selector);
        vault.deposit(1e8, bob);
        vm.stopPrank();
    }
}
