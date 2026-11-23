// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault, VaultConfig} from "../../../src/vault/AceVault.sol";
import {Listing} from "../../../src/vault/curated/CuratorTerms.sol";
import {CuratedVaults} from "../../utils/CuratedVaults.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultDustNav
/// @notice A vest stamp reads back exactly the pile it was handed plus the rise it observed, so a donation never lowers `totalAssets`.
/// @notice The ACE16 dust-NAV walk (a one-atom donation stamped onto a live pile read back two atoms) is inverted here: it moves no NAV.
/// @dev Each stamp is a one-atom donation and a sync in the same second; between stamps the pile only decays.
contract AceVaultDustNavTest is AceVaultRig {
    uint16 internal constant FEE = 2000;

    /// @dev One atom donated by the stranger, then a sync.
    function _stamp() internal {
        usdc.mint(stranger, 1);
        vm.prank(stranger);
        usdc.transfer(address(vault), 1);
        vault.collectFee();
    }

    function _tryDeposit(address who, uint256 amt) internal returns (bool ok, bytes memory reason) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        try vault.deposit(amt, who) returns (uint256) {
            ok = true;
        } catch (bytes memory err) {
            reason = err;
        }
        vm.stopPrank();
    }

    function _feeVault() internal returns (AceVault v) {
        VaultConfig memory c = _cfg();
        c.perfFeeBps = FEE;
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: _row(address(record))});
        v = CuratedVaults.viaFactory(vaultFactory, bytes32(++vaultSalt), c, _curated(), l, "Fee", "fVLT");
    }

    // ---- T1: the supply crush, inverted ----

    /// @notice A one-atom stamp onto a live pile leaves `totalAssets` exactly where it stood, and moves no share.
    function test_DustNav_AStampOnALivePileLeavesNavWhole() public {
        vault = _newVault(_row(address(record)));
        _lp(stranger, 10);
        _stamp();
        _warpBy(1);
        uint256 a0 = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        for (uint256 i = 1; i <= 5; ++i) {
            _stamp();
            assertEq(vault.totalAssets(), a0, "a one-atom stamp moved NAV");
        }
        assertEq(vault.totalSupply(), supply, "premise: no share moved");
    }

    /// @notice Two hundred and twenty-five rounds of the walk leave the share price where it was: a one-USDC and the rig's LP deposit both land.
    function test_DustNav_AStrangersStampsCannotInflateSupply() public {
        vault = _newVault(_row(address(record)));
        _lp(stranger, 3);
        _stamp();
        _warpBy(1);
        uint256 a0 = vault.totalAssets();
        uint256 s0 = vault.totalSupply();
        for (uint256 r; r < 225; ++r) {
            for (uint256 j; j < 10 && vault.totalAssets() > 1; ++j) {
                _stamp();
            }
            _lp(stranger, 2);
        }
        assertEq(vault.totalAssets(), a0 + 2 * 225, "the stamps moved NAV: only the deposits may");
        assertLe(vault.totalSupply(), s0 + 2 * 225 * 1e6 + 225, "the walk inflated the share count past par");
        (bool ok, bytes memory reason) = _tryDeposit(alice, 1e6);
        assertTrue(ok, "a one-USDC deposit refused after the walk");
        assertEq(reason.length, 0, "premise: no refusal");
        _warpBy(VEST_W + 1);
        vault.collectFee();
        (ok,) = _tryDeposit(bob, LP_CASH);
        assertTrue(ok, "the rig's LP deposit refused after the walk vested");
        assertGt(vault.maxDeposit(bob), 0, "the max view reads shut");
    }

    // ---- T3: the manufactured fee gap, inverted ----

    /// @notice Stamps that cannot lower NAV cannot open a fee gap: the honest deposit after them carries none, and a doubling pays the fee.
    function test_DustNav_StampsManufactureNoFeeGap() public {
        vault = _feeVault();
        _lp(stranger, 40);
        _stamp();
        _warpBy(1);
        for (uint256 i; i < 40; ++i) {
            _stamp();
        }
        assertLe(vault.feeHighWater(), vault.totalAssets(), "the stamps left the high-water over NAV with no loss");
        _lp(bob, LP_CASH);
        uint256 h = vault.feeHighWater();
        uint256 a = vault.totalAssets();
        assertApproxEqAbs(h, a, 2, "the honest deposit carried a fee gap no loss made");
        usdc.mint(address(vault), LP_CASH);
        vault.crank();
        _warpBy(VEST_W + 1);
        vault.collectFee();
        uint256 paid = vault.previewRedeem(vault.balanceOf(curator));
        assertApproxEqRel(paid, LP_CASH / 5, 0.01e18, "a doubling did not pay the curator its 20% of the gain");
    }

    // ---- T4: a stamp reads back exactly ----

    /// @notice Fuzz: a rise of `d2` onto a pile of `u` reads back exactly `u + d2` and leaves `totalAssets` where it stood, in the view and the verb.
    function testFuzz_DustNav_AStampReadsBackExactlyItsRise(uint256 entry, uint256 d1, uint256 dt, uint256 d2) public {
        entry = bound(entry, 1, 1e30);
        d1 = bound(d1, 1, 1e24);
        dt = bound(dt, 0, VEST_W - 1);
        d2 = bound(d2, 1, 1e24);
        vault = _newVault(_row(address(record)));
        _lp(alice, entry);
        usdc.mint(address(vault), d1);
        vault.crank();
        _warpBy(dt);
        uint256 u0 = vault.unvested();
        uint256 a0 = vault.totalAssets();
        usdc.mint(address(vault), d2);
        assertEq(vault.totalAssets(), a0, "the view lowered NAV over an unsynced rise");
        vault.crank();
        assertEq(vault.unvested(), u0 + d2, "the stamp did not read back exactly the pile plus the rise");
        assertEq(vault.totalAssets(), a0, "the stamp lowered NAV");
    }

    /// @notice The walk's own case: a one-atom pile, a second later, takes one atom and reads back exactly two.
    function test_DustNav_TheWalksOwnStampReadsBackExactly() public {
        vault = _newVault(_row(address(record)));
        _lp(alice, 3);
        _stamp();
        _warpBy(1);
        assertEq(vault.unvested(), 1, "premise: a one-atom pile, read up");
        uint256 a0 = vault.totalAssets();
        _stamp();
        assertEq(vault.unvested(), 2, "the stamp read back over the pile plus the rise");
        assertEq(vault.totalAssets(), a0, "the stamp lowered NAV");
    }

    // ---- T6: the measure row ----

    /// @notice MEASURE: two hundred one-atom stamps on a seeded vault with no LP move its NAV by nothing.
    /// @dev With the stamp's basis rounded up again, the same run lowers NAV one atom a stamp, so halving a seed of N atoms takes about N/2 stamps.
    function test_Measure_DustNav_StampsOnASeededVaultMoveNoNav() public {
        vault = _newVault(_row(address(record)));
        _stamp();
        _warpBy(1);
        uint256 a0 = vault.totalAssets();
        for (uint256 i; i < 200; ++i) {
            _stamp();
        }
        uint256 fell = a0 - vault.totalAssets();
        emit log_named_uint("atoms of NAV 200 stamps took", fell);
        assertEq(fell, 0, "the stamps walked NAV down");
    }
}
