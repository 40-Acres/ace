// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {_extended} from "../../utils/Extended.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice An extension is gated by the curator's legs alone: no cash or room edge refuses it, and a switched-off row does.
/// @notice Ported from the retired vault-roll edges: the vault is its own roll policy, and its loans extend in place at the hub.
/// @dev Every row starts an hour before a loan's expiry, with every idle unit exited.
contract VaultExtensionEdgesTest is AceVaultRig {
    uint256 internal loanId;
    uint256 internal newId;

    function setUp() public override {
        super.setUp();
        loanId = _borrow(MAX_TENOR);
        _toWindow(loanId);
        vm.startPrank(alice);
        vault.withdraw(vault.maxWithdraw(alice), alice, alice);
        vm.stopPrank();
        newId = loanId;
        assertEq(vault.idle(), 0, "premise: and nothing sits idle");
    }

    /// @dev Cut the collateral's cap to `cap`, which lands at once.
    function _cutCap(uint256 cap) internal {
        vm.prank(curator);
        vault.submitCap(address(coll), uint192(cap));
    }

    /// @dev The hub's exposure the room is cut against: lent, with no pot parked.
    function _lent() internal view returns (uint256 lent) {
        uint256 unsold;
        (lent, unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(unsold, 0, "premise: no pot is parked against the collateral");
        assertGt(lent, 0, "premise: the loan is lent");
    }

    /// @dev Mint the holder exactly the fee an extension of `newId` costs now, on the time it adds, and approve the hub for it.
    function _fundFee() internal {
        Loan memory l = read.loan(newId);
        MarketParams memory mp = ace.idToMarketParams(l.market);
        uint256 fee = LoanMath.originationFee(l.debt, uint64(_now()) + l.tenor - l.expiry, mp.baseBps, mp.minTenor);
        usdc.mint(borrower, fee);
        vm.prank(borrower);
        usdc.approve(address(ace), fee);
    }

    /// @dev The holder extends `newId` by the row's shortest term in cash; true when it extended in place.
    function _extend() internal returns (bool) {
        uint64 expiry = read.loan(newId).expiry;
        _fundFee();
        vm.prank(borrower);
        ace.extend(newId, 0, "");
        return _extended(read, newId, expiry);
    }

    /// @notice Zero idle refuses nothing: the holder's extension of the loan draws no vault cash, the holder paying the fee.
    function test_AnExtension_ZeroIdleStillExtends() public {
        assertEq(vault.idle(), 0, "premise: nothing sits idle");
        assertTrue(_extend(), "the loan extends in place from nothing idle");
    }

    /// @notice A cap cut under exposure but over zero keeps the legs up, so the holder's extension still lands.
    function test_AnExtension_ACapCutUnderExposureStillExtends() public {
        _cutCap(_lent() / 2);
        assertTrue(_extend(), "an exposure cap is not a leg, so the extension lands");
    }

    /// @notice A cap cut to zero switches the row off, and the hub's extension is refused by the vault's policy.
    function test_AnExtension_ACapCutToZeroRefuses() public {
        _cutCap(0);
        _fundFee();
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(newId, 0, "");
    }
}
