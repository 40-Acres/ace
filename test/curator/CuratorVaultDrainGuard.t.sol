// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {VaultConfig} from "../../src/curator/AceVault.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {MockSendHookERC20} from "../mocks/MockSendHookERC20.sol";
import {ITokenReceiveHook} from "../mocks/MockHookERC20.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";

/// @title CuratorVaultDrainGuard
/// @notice `setDrain` holds the vault's guard: called from inside a guarded vault body, it refuses and switches nothing.
/// @dev The seam is the asset's SENDER hook, fired as the vault pulls this contract's deposit; this contract is the guardian.
/// @dev The drain's keys, hold and entry rows live in `CuratorVaultDrain.t.sol`.
contract CuratorVaultDrainGuardTest is CuratorVaultBase, ITokenReceiveHook {
    MockSendHookERC20 internal tok;
    CuratorVault internal v;
    bool internal armed;
    bool internal reentered;
    bytes internal reentryErr;

    /// @dev A vault on the hooked asset with no collateral listed: the row's subject is entry and the drain, which no row reads.
    function setUp() public override {
        super.setUp();
        tok = new MockSendHookERC20("Hooked", "HOOK", 6);
        VaultConfig memory cfg = _cfg(0);
        cfg.asset = address(tok);
        cfg.guardian = address(this);
        v = new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, new Listing[](0), "Hooked", "cHOOK");
        tok.mint(address(this), 10_000e6);
        tok.approve(address(v), type(uint256).max);
        tok.setHookTarget(address(this));
    }

    function onTokenReceived(address, uint256) external override {
        if (!armed) return;
        try v.setDrain(true) {
            reentered = true;
        } catch (bytes memory err) {
            reentryErr = err;
        }
    }

    /// @notice MID-DEPOSIT, THE GUARDIAN'S DRAIN REFUSES AS THE GUARD, and the drain stays off.
    function test_Drain_TheSwitchRefusesReentryMidDeposit() public {
        armed = true;
        v.deposit(1_000e6, address(this));
        assertFalse(reentered, "the switch ran inside a guarded vault body");
        assertEq(bytes4(reentryErr), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, "the refusal was not the guard's");
        assertFalse(v.draining(), "a refused switch still stood");
        armed = false;
        v.setDrain(true);
        assertTrue(v.draining(), "the control: outside a body the guardian's switch stands");
    }
}
