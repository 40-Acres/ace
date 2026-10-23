// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {IAceLenderOps} from "../../src/interfaces/IAceLenderOps.sol";

/// @title CuratorVaultCashCap
/// @notice The MARKET cash cap meets the vault at its door's rest: idle past the hub's 128-bit width is clamped, never refused.
/// @notice The door rests the smaller of idle and what the market can still take, opens, then withdraws every resting unit.
/// @dev No try/catch stands between the vault and the hub, which is the repo's doctrine: the clamp is what keeps the rest from reverting.
contract CuratorVaultCashCapTest is CuratorVaultBase {
    uint256 internal constant HALF = uint256(1) << 127; // two of these are the smallest pair that outruns the width
    uint256 internal constant DRAW = 1_000e6;

    /// @notice A BORROW WITH IDLE PAST THE CASH CAP LANDS: the rest is clamped to the market's room, and nothing rests after the door.
    function test_Borrow_IdlePastTheCashCapRestsTheClampAndLands() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, HALF);
        _lpDeposit(v, alice, HALF);
        uint256 idle = v.idle();
        assertGt(idle, type(uint128).max, "PREMISE: idle outruns the hub's cash width");

        vm.expectCall(address(ace), abi.encodeCall(IAceLenderOps.deposit, (mid, type(uint128).max)));
        uint256 loanId = _open(DRAW);

        assertEq(ace.loanMarket(loanId), mid, "the borrow landed in the door's market");
        assertEq(read.restingOf(mid), 0, "and the door withdrew every unit it rested");
        assertEq(v.idle(), idle - DRAW, "so idle fell by the principal alone");
    }
}
