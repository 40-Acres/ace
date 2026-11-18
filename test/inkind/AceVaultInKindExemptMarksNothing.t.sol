// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVault} from "../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title AceVaultInKindExemptMarksNothing
/// @notice In kind no sync weighs the trough hold, so the dead-pot exemption writes none: a mark there would never clear.
contract AceVaultInKindExemptMarksNothingTest is InKindRig {
    /// @dev The trough hold's field, the top of the vest's word.
    function _hold() internal view returns (uint48) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(AceVaultFlows.ROOT) + 2);
        return uint48(uint256(vault.extsload(s)[0]) >> 200);
    }

    /// @notice In kind, a material fall no sync saw, then the exemption: it writes no hold, and a later gain inside the band leaves entry open.
    function test_Exempt_InKindAnUnseenMaterialFallWritesNoHold() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 before = vault.grossNav();
        vm.prank(stranger);
        ace.forceClose(loanId);
        assertGt((before - vault.grossNav()) * 10_000, before, "PREMISE: the settle's fall is material against the gross");
        (uint256 u, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(u, 1, "PREMISE: its pot is unsold at the exemption");
        vm.prank(guardian);
        vault.exemptDeadPots(s);
        assertEq(_hold(), 0, "in kind the exemption wrote a trough hold that no in-kind sync clears");
        usdc.mint(address(vault), 5_000e6);
        vault.crank();
        assertGt(vault.unvested() * 10_000, vault.grossNav(), "PREMISE: the gain's pile is material, so a standing mark would shut entry");
        uint256 gate = AceVault(address(vault)).GATE_BPS();
        assertLe(vault.unvested() * 10_000, vault.totalAssets() * gate, "PREMISE: the gain vests inside the band, so only a hold could shut entry");
        assertEq(_hold(), 0, "the sync after the exemption wrote a trough hold");
        assertGt(vault.maxDeposit(bob), 0, "entry is shut over a pile no in-kind hold covers");
        assertGt(_lp(bob, 1_000e6), 0, "a deposit over the exempted pot and the vesting gain minted nothing");
    }
}
