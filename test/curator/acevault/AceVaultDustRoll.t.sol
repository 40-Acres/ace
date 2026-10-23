// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice A dust-band loan's roll: the hub floors the successor at minDebt, and the vault treats the floor's excess as new lending.
/// @dev The promised part of the fresh draw is the recorded need; the rest must fit lendable, the cap room and the curator's legs, or the roll is refused.
contract AceVaultDustRollTest is AceVaultRig {
    uint256 internal constant SMALL = 100e6; // a ticket whose recorded need sits well under the minDebt gap
    uint256 internal constant DUST = 1e6; // what the borrower leaves after a repay into the dust band
    uint256 internal loanId;

    function setUp() public override {
        super.setUp();
        loanId = _borrowAs(borrower, 200e18, SMALL, MIN_TENOR, true);
        _repayAs(borrower, loanId, SMALL - DUST);
        assertEq(ace.debtOf(loanId), DUST, "premise: the debt sits in the dust band");
        uint256 fresh = _succUp(_mp(loanId), DUST) - DUST;
        assertGt(fresh, _need(loanId), "premise: the minDebt floor draws past the recorded need");
    }

    /// @notice With the legs open and room to place it, the excess is lent from lendable and the roll runs.
    function test_TheExcessIsLentFromLendable() public {
        uint256 lend0 = vault.lendable();
        _toWindow(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertEq(ace.debtOf(newId), MIN_DEBT, "the hub floored the successor at minDebt");
        assertLt(vault.lendable(), lend0, "the excess came out of lendable");
        _assertNothingRests(_mid(newId));
    }

    /// @notice The drain is a curator leg: a dust roll's excess is new lending, so the drain refuses it.
    function test_TheDrainRefusesTheExcess() public {
        vm.prank(curator);
        vault.setDrain(true);
        _toWindow(loanId);
        vm.expectRevert(AceVaultFlows.RollNotLendable.selector);
        vault.roll(loanId, "");
    }

    /// @notice A cap cut to zero refuses the excess.
    function test_ACapCutRefusesTheExcess() public {
        vm.prank(guardian);
        vault.submitCap(address(coll), 0);
        _toWindow(loanId);
        vm.expectRevert(AceVaultFlows.RollNotLendable.selector);
        vault.roll(loanId, "");
    }

    /// @notice When the requests hold everything exitable, nothing is lendable and the excess is refused.
    function test_NoLendableRefusesTheExcess() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(shares);
        assertEq(vault.lendable(), 0, "premise: the request holds every exitable unit");
        _toWindow(loanId);
        vm.expectRevert(AceVaultFlows.RollNotLendable.selector);
        vault.roll(loanId, "");
    }
}
