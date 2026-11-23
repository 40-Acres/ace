// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";
import {AceVaultFlows} from "../../src/vault/libraries/AceVaultFlows.sol";
import {Listing, Quote} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindTokens
/// @notice Seized tokens never touch NAV, and an odd token breaks only its own claims.
contract InKindTokensTest is InKindRig {
    /// @notice A token paused after its credit blocks only its own claim: other tokens claim, deposits land, and its credit waits intact.
    function test_aPausedTokenBreaksOnlyItsOwnClaims() public {
        MockBlockableERC20 odd = new MockBlockableERC20("Odd", "ODD", 18);
        Listing[] memory l = _listings();
        l[1].collateral = address(odd);
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        uint256 a = _open(address(tokA));
        uint256 o = _open(address(odd));
        _toExpiry(a);
        vm.prank(keeper);
        vault.collectForfeited(_ids(a, o));
        _nextBlock();
        uint256 owedOdd = _claimable(alice, address(odd));
        assertGt(owedOdd, 0, "premise: alice is credited the odd token");
        odd.setPaused(true);
        assertGt(_claim(alice, address(tokA)), 0, "the healthy token still claims");
        vm.prank(alice);
        vm.expectRevert();
        vault.claim(_toks(address(odd)), alice);
        assertEq(_claimable(alice, address(odd)), owedOdd, "the paused token's credit waits intact");
        assertGt(_lp(bob, 1_000e6), 0, "deposits are unaffected");
        odd.setPaused(false);
        assertEq(_claim(alice, address(odd)), owedOdd, "and claims once the pause lifts");
    }

    /// @notice Bringing a seized pot home moves no NAV and no share price: seized tokens are never valued.
    function test_seizedTokensMoveNoNav() public {
        _lp(alice, LP_CASH);
        _lp(bob, 100_000e6);
        _warpBy(MIN_TENOR);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        vault.crank();
        (uint256 nav, uint256 gross, uint256 px) = (vault.totalAssets(), vault.grossNav(), vault.convertToAssets(1e18));
        uint256 out = _collect(loanId);
        assertGt(out, 0, "premise: units came home");
        assertEq(vault.totalAssets(), nav, "NAV is unmoved by the seized units");
        assertEq(vault.grossNav(), gross, "and gross NAV too");
        assertEq(vault.convertToAssets(1e18), px, "and the share price");
        _nextBlock();
        vm.prank(alice);
        vault.claim(new address[](0), alice); // an empty claim only folds: the batch is credited and nothing paid
        assertEq(vault.totalAssets(), nav, "nor by their credit");
    }

    /// @notice A fee-on-transfer token is refused at the pull, so a short pledge never opens.
    function testRevert_aFeeOnTransferPledgeIsRefused() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20("Fee", "FEE", 18, 100);
        Listing[] memory l = _listings();
        l[1].collateral = address(fot);
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        Quote memory q = _quote(address(fot), PRICE);
        bytes memory data = _data(q);
        fot.mint(borrower, UNITS);
        vm.prank(borrower);
        fot.approve(address(vault), UNITS);
        vm.prank(borrower);
        vm.expectRevert(AceVaultFlows.PledgeArrivedShort.selector);
        vault.borrow(_req(address(fot), UNITS, PRINCIPAL, MIN_TENOR), data, "");
    }
}
