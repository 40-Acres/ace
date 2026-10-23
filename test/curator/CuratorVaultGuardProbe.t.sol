// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing, Row} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {BorrowRequest} from "../../src/curator/AceVaultFlows.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {MockSendHookERC20} from "../mocks/MockSendHookERC20.sol";
import {ITokenReceiveHook} from "../mocks/MockHookERC20.sol";
import {GuardProbeList} from "../utils/GuardProbeList.sol";

/// @title CuratorVaultGuardProbe
/// @notice Every guarded vault verb refuses a call made from inside another guarded vault body.
/// @notice The enumeration behind `test_Reentrancy_TheCrankAndRequestVerbsAreBehindTheMutex`, which probes six of nineteen.
/// @dev The seam is the asset's SENDER hook: this contract deposits, and the pull out of it calls it back mid-`deposit`.
/// @dev Probes are kept rather than bubbled, so one deposit runs all nineteen and a failure names the verb that answered.
/// @dev Deleting any ONE of the nineteen probed modifiers turns this red, the outer `deposit`'s included, since every probe then reaches a body.
contract CuratorVaultGuardProbeTest is CuratorVaultBase, GuardProbeList, ITokenReceiveHook {
    MockSendHookERC20 internal tok;
    CuratorVault internal v;

    uint256 internal constant GUARDED_VAULT_VERBS = 19; // the 19 verbs probed below; the drain's guardian path is pinned in CuratorVaultDrainGuard
    uint256 internal constant FUND = 10_000e6;

    /// @dev The vault lists nothing: the guard answers before any body, so no row or market need exist.
    function setUp() public override {
        super.setUp();
        tok = new MockSendHookERC20("Hooked", "HOOK", 6);
        VaultConfig memory cfg = _cfg(0);
        cfg.asset = address(tok);
        v = new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, new Listing[](0), "Hooked", "cHOOK");
        tok.mint(address(this), FUND);
        tok.approve(address(v), type(uint256).max);
        tok.setHookTarget(address(this));
    }

    /// @dev The asset's sender hook: fired as the vault pulls this contract's deposit, inside the vault's guarded body.
    function onTokenReceived(address, uint256) external override {
        _runProbes();
    }

    /// @notice The nineteen guarded vault verbs listed here, called mid-`deposit`, refuse as the guard and move nothing.
    /// @dev A zeroed argument set throughout: the guard runs before the body, so no market or share need exist.
    /// @dev The control is the deposit before arming, which proves the seam fires without refusing a plain entry.
    function test_EveryGuardedVaultVerbRefusesReentryMidDeposit() public {
        address me = address(this);
        BorrowRequest memory r;
        Row memory row;
        uint256 control = v.deposit(1_000e6, me);
        assertGt(control, 0, "the control: an unarmed hooked deposit mints normally");

        _probe("deposit", address(v), abi.encodeCall(AceVault.deposit, (0, me)));
        _probe("mint", address(v), abi.encodeCall(AceVault.mint, (0, me)));
        _probe("withdraw", address(v), abi.encodeCall(AceVault.withdraw, (0, me, me)));
        _probe("redeem", address(v), abi.encodeCall(AceVault.redeem, (0, me, me)));
        _probe("requestExit", address(v), abi.encodeCall(AceVault.requestExit, (1)));
        _probe("cancelExit", address(v), abi.encodeCall(AceVault.cancelExit, (0)));
        _probe("lapseExit", address(v), abi.encodeCall(AceVault.lapseExit, (me)));
        _probe("claimExit", address(v), abi.encodeCall(AceVault.claimExit, (1, me, 0)));
        _probe("setDrain", address(v), abi.encodeCall(AceVault.setDrain, (true)));
        _probe("exemptDeadPots", address(v), abi.encodeCall(AceVault.exemptDeadPots, (0)));
        _probe("crank", address(v), abi.encodeWithSignature("crank()"));
        _probe("crank(closed)", address(v), abi.encodeWithSignature("crank(uint256[])", new uint256[](0)));
        _probe("collectFee", address(v), abi.encodeCall(AceVault.collectFee, ()));
        _probe("borrow", address(v), abi.encodeCall(AceVault.borrow, (r, "", "")));
        _probe("roll", address(v), abi.encodeCall(AceVault.roll, (0, "")));
        _probe("submitCollateral", address(v), abi.encodeCall(CuratorVault.submitCollateral, (address(0), row)));
        _probe("submitCap", address(v), abi.encodeCall(CuratorVault.submitCap, (address(0), 0)));
        _probe("accept", address(v), abi.encodeCall(CuratorVault.accept, (address(0))));
        _probe("revokePending", address(v), abi.encodeCall(CuratorVault.revokePending, (address(0))));

        probesArmed = true;
        uint256 minted = v.deposit(1_000e6, me);

        _assertEveryProbeTripped(GUARDED_VAULT_VERBS);
        assertGt(minted, 0, "the outer deposit completed around the refused probes");
        assertEq(v.balanceOf(me), control + minted, "and no probe minted, burned or escrowed a share");
        assertEq(tok.balanceOf(me), FUND - 2_000e6, "nor moved any of the depositor's cash");
    }
}
