// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";
import {IAceLenderOps} from "../../src/interfaces/IAceLenderOps.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title AceVaultInKindTroughHold
/// @notice In kind the trough hold never runs: no recovery reaches NAV, so a sync reads no unsold count and never marks the vault.
contract AceVaultInKindTroughHoldTest is InKindRig {
    /// @notice A stranger's settle and the sync after it: the fall is seen, the hub's unsold count is never read, and the hold stays zero.
    function test_InKindHold_ASyncAfterASettleNeverReadsTheUnsoldCountOrMarks() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        bytes32[] memory s = new bytes32[](2);
        (s[0], s[1]) = (bytes32(uint256(AceVaultFlows.ROOT) + 1), bytes32(uint256(AceVaultFlows.ROOT) + 2));
        uint256 markBefore = uint256(vault.extsload(s)[0]);
        vm.expectCall(address(ace), abi.encodeWithSelector(IAceLenderOps.lenderUnresolved.selector), 0);
        vault.crank();
        bytes32[] memory w = vault.extsload(s);
        assertLt(uint256(w[0]), markBefore, "premise: the sync saw the settle's fall");
        assertEq(uint48(uint256(w[1]) >> 200), 0, "an in-kind sync wrote the trough hold");
    }
}
