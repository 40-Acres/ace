// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultFlows} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {Extension, IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @title AceVaultConsentGas
/// @notice MEASURE: the vault's roll-policy answer on a lengthening extension, every address it touches cold, in the exit gate's states.
/// @notice MEASURE: a cold crank with and without a standing drawdown, the trough hold's leg of every sync.
/// @dev The hub hands the policy a fixed budget, so the base's own share of it is logged per state; nothing here pins a figure.
contract AceVaultConsentGasTest is AceVaultBaseRig {
    /// @dev A loan of the rig's ask, a day old, so the holder's own-tenor extension lengthens it and the exit gate is asked.
    function _lengthening() internal returns (Extension memory e) {
        uint256 loanId = _borrow();
        _warpBy(1 days);
        e = _ext(loanId);
        assertGt(e.newExpiry, e.expiry, "premise: the extension lengthens the loan");
    }

    function _coolAll() internal {
        vm.cool(address(vault));
        vm.cool(address(terms));
        vm.cool(address(ace));
        vm.cool(address(usdc));
        vm.cool(address(record));
    }

    /// @dev The cold answer's gas.
    function _measure(Extension memory e) internal returns (uint256 used, bytes4 answer) {
        _coolAll();
        uint256 g = gasleft();
        answer = vault.admitsExtension(e, "");
        used = g - gasleft();
    }

    /// @notice MEASURE: no request standing.
    function test_Measure_ColdConsent_NoRequest() public {
        Extension memory e = _lengthening();
        (uint256 used, bytes4 answer) = _measure(e);
        emit log_named_uint("cold admitsExtension gas, no request", used);
        assertEq(answer, IRollPolicy.admitsExtension.selector, "premise: the vault consents");
    }

    /// @notice MEASURE: a request standing that idle covers.
    function test_Measure_ColdConsent_CoveredRequestStanding() public {
        Extension memory e = _lengthening();
        uint256 tenth = vault.balanceOf(alice) / 10;
        vm.prank(alice);
        vault.requestExit(tenth);
        (uint256 used, bytes4 answer) = _measure(e);
        emit log_named_uint("cold admitsExtension gas, a covered request standing", used);
        assertEq(answer, IRollPolicy.admitsExtension.selector, "premise: the covered request lets the vault consent");
    }

    /// @notice MEASURE: a request standing that idle does not cover, and no hold: the gate refuses.
    function test_Measure_ColdConsent_UncoveredRequestRefuses() public {
        Extension memory e = _lengthening();
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(all);
        assertGt(vault.previewRedeem(vault.balanceOf(address(vault))), vault.idle(), "premise: the request outweighs idle");
        (uint256 used, bytes4 answer) = _measure(e);
        emit log_named_uint("cold admitsExtension gas, an uncovered request standing", used);
        assertEq(answer, bytes4(0), "premise: the uncovered request refuses the roll");
    }

    /// @dev A standing drawdown of `dd` written into the high-water, as a write-off or a short sale leaves one: nothing unsold, nothing marked.
    function _standingDrawdown(uint256 dd) internal {
        bytes32 slot = bytes32(uint256(AceVaultFlows.ROOT) + 8);
        vm.store(address(vault), slot, bytes32(uint256(vm.load(address(vault), slot)) + dd));
        assertEq(vlens.drawdown(address(vault)), dd, "premise: the drawdown stands");
    }

    /// @notice MEASURE: no request standing, under a standing drawdown of a percent of NAV.
    function test_Measure_ColdConsent_NoRequestUnderADrawdown() public {
        Extension memory e = _lengthening();
        _standingDrawdown(LP_CASH / 100);
        (uint256 used, bytes4 answer) = _measure(e);
        emit log_named_uint("cold admitsExtension gas, no request, a standing drawdown", used);
        assertEq(answer, IRollPolicy.admitsExtension.selector, "premise: the vault consents");
    }

    /// @notice MEASURE: a covered request standing, under the same drawdown.
    function test_Measure_ColdConsent_CoveredRequestUnderADrawdown() public {
        Extension memory e = _lengthening();
        uint256 tenth = vault.balanceOf(alice) / 10;
        vm.prank(alice);
        vault.requestExit(tenth);
        _standingDrawdown(LP_CASH / 100);
        (uint256 used, bytes4 answer) = _measure(e);
        emit log_named_uint("cold admitsExtension gas, a covered request, a standing drawdown", used);
        assertEq(answer, IRollPolicy.admitsExtension.selector, "premise: the covered request lets the vault consent");
    }

    function _coldCrank() internal returns (uint256 used) {
        _coolAll();
        uint256 g = gasleft();
        vault.crank();
        used = g - gasleft();
    }

    /// @notice MEASURE: a cold crank that sees no fall, under the same drawdown: the trough hold's leg of every sync.
    function test_Measure_ColdCrank_UnderADrawdown() public {
        _borrow();
        _warpBy(1 days);
        vault.crank();
        _standingDrawdown(LP_CASH / 100);
        emit log_named_uint("cold crank gas, a standing drawdown", _coldCrank());
    }

    /// @notice MEASURE: the same crank with no drawdown, the control.
    function test_Measure_ColdCrank_NoDrawdown() public {
        _borrow();
        _warpBy(1 days);
        vault.crank();
        emit log_named_uint("cold crank gas, no drawdown", _coldCrank());
    }
}
