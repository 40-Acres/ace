// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";

/// @title CuratorVaultRedeemQueue
/// @notice The escrowed request: a share count held on the vault, never a position of the vault's, and never more than its holder escrowed.
/// @dev EVERY VAULT HERE IS FEE-ZERO, so `convertToAssets` is the exact price a claim at that instant pays.
contract CuratorVaultRedeemQueueTest is CuratorVaultBase {
    uint256 internal constant SEED = 40_000e6;
    uint256 internal constant SMALL = 4_000e6;
    uint256 internal constant DRAW = 20_000e6;

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    uint256 internal extraLoan; // the second draw `_thinIdle` takes, so idle stays thin past the first repayment

    /// @dev Alice big, bob small, nearly all the cash lent out, and one class holding real claimable quote.
    function _thinIdle(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SMALL);
        loanId = _open(DRAW);
        extraLoan = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, DRAW / 2); // quote owed to the vault at the hub, uncollected
    }

    function _escrow(CuratorVault v, address who) internal view returns (uint256 shares) {
        (shares,) = v.requestOf(who);
    }

    /// @notice THE ESCROW IS NOT A POSITION, AND THE VAULT'S OWN BALANCE IS NOT ANYBODY'S TO REDEEM.
    /// @dev `redeem` and `withdraw` spend the owner's allowance to the caller, and the vault approves nobody, so naming it is refused.
    function testRevert_Exit_AStrangerCannotBurnTheEscrowByNamingTheVault() public {
        CuratorVault v = _newVault(0);
        _thinIdle(v);
        uint256 held = v.balanceOf(bob);
        vm.prank(bob);
        v.requestExit(held);
        assertEq(v.balanceOf(address(v)), held, "PREMISE: the escrow is real shares, standing on the vault");

        address mallory = address(0xBAD);
        uint256 burnOne = v.previewWithdraw(1); // BEFORE the prank: a read is a call, and a call would eat it
        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, mallory, 0, held / 2));
        v.redeem(held / 2, mallory, address(v));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, mallory, 0, burnOne));
        v.withdraw(1, mallory, address(v));
        vm.stopPrank();

        assertEq(_escrow(v, bob), held, "bob's request is untouched");
        assertEq(v.balanceOf(address(v)), held, "and every escrowed share is still behind it");
        assertEq(usdc.balanceOf(mallory), 0, "and not one wei reached the stranger");
    }

    /// @notice NO DOUBLE REDEEM: every requested share is an escrowed share, across a request, a top-up, a claim and a cancel.
    function test_Request_TheEscrowEqualsTheRequestsThroughEveryVerb() public {
        CuratorVault v = _newVault(0);
        _thinIdle(v);
        uint256 held = v.balanceOf(bob);
        uint256 half = held / 2;
        vm.prank(bob);
        v.requestExit(half);
        assertEq(v.balanceOf(address(v)), v.requestedShares(), "after a request");

        vm.prank(bob);
        v.requestExit(half); // ADDITIVE: a second request stands beside the first
        assertEq(_escrow(v, bob), half * 2, "the requests added rather than replaced");
        assertEq(v.balanceOf(address(v)), v.requestedShares(), "after a second request");

        uint256 part = v.maxClaim(bob) / 2; // BEFORE the prank: a read is a call, and a call would eat it
        assertGt(part, 0, "PREMISE: exitable covers part of the request");
        vm.prank(bob);
        v.claimExit(part, bob, 0);
        assertEq(v.balanceOf(address(v)), v.requestedShares(), "after a claim, which burns exactly what it paid for");

        uint256 back = _escrow(v, bob) / 2; // BEFORE the prank, for the same reason
        vm.prank(bob);
        v.cancelExit(back);
        assertEq(v.balanceOf(address(v)), v.requestedShares(), "after a cancel, which hands exactly its shares back");
        assertEq(_escrow(v, bob), v.requestedShares(), "and the requests are bob's alone");
    }
}
