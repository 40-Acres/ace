// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultCaps} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {AceVaultFlows} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @title AceVaultCapsTest
/// @notice The vault's caps, keyed by collateral, the wildcard at `address(0)` and the total at the vault's own address.
/// @notice EVERY CHANGE IS JUDGED AGAINST THE EFFECTIVE CAP: a listed collateral's own row, else the wildcard's.
/// @notice A cut, or a listing at or under it, lands at once by the curator or the guardian; anything above waits the timelock, by the curator alone.
/// @dev A listed collateral cut to zero stays zero under a higher wildcard: a cut can never fall back to a raise.
contract AceVaultCapsTest is AceVaultBaseRig {
    uint192 internal constant WILD = 1_000e6;
    address internal c;

    function setUp() public override {
        super.setUp();
        (vault, terms) = _deploy(_cfg(), _pc(), _caps(UNCAPPED, WILD, UNCAPPED));
        _setTerms(address(coll), record);
        _lp(alice, LP_CASH);
        c = address(new MockStakeVault(42));
    }

    function _listed(address key) internal view returns (bool listed) {
        (, listed) = vlens.capOf(address(vault), key);
    }

    function _pending(address key) internal view returns (uint64 validAt) {
        (,, validAt) = vlens.pendingCapOf(address(vault), key);
    }

    /// @notice The deploy's caps are live from the first block: the row listed, the wildcard and the total at their figures.
    function test_TheDeployCapsAreLiveFromTheFirstBlock() public view {
        (uint192 row, bool listed) = vlens.capOf(address(vault), address(coll));
        assertEq(row, UNCAPPED, "the rig collateral's row");
        assertTrue(listed, "is listed");
        assertEq(vault.effectiveCap(c), WILD, "an unlisted collateral takes the wildcard");
        assertEq(vault.effectiveCap(address(0)), WILD, "the wildcard is its own");
        assertEq(vault.effectiveCap(address(vault)), UNCAPPED, "the total is its own");
    }

    /// @notice F4: a listed collateral cut to zero stays zero under a higher wildcard, and borrows against it are refused.
    function test_AListedCollateralCutToZeroStaysZeroUnderAHigherWildcard() public {
        vm.prank(curator);
        vault.submitCap(c, 100e6);
        assertEq(vault.effectiveCap(c), 100e6, "premise: listing under the wildcard landed at once");
        vm.prank(guardian);
        vault.submitCap(c, 0);
        assertEq(vault.effectiveCap(c), 0, "a cut to zero fell back to the wildcard");
        assertTrue(_listed(c), "and the collateral stays listed");
        _setTerms(c, _record(c));
        _expectBorrowRevert(c, AceVaultFlows.OverCap.selector);
    }

    /// @notice Listing above the effective cap is a raise: it waits the timelock, and lands only once anyone accepts it after.
    function test_ListingAboveTheEffectiveCapWaits() public {
        vm.prank(curator);
        vault.submitCap(c, 2 * WILD);
        assertEq(vault.effectiveCap(c), WILD, "a listing above the wildcard landed at once");
        assertFalse(_listed(c), "and listed the collateral before the timelock");
        assertEq(_pending(c), _now() + CAP_LOCK, "the listing does not wait the timelock");
        vm.expectRevert(AceVaultCaps.NothingDue.selector);
        vault.acceptCap(c);
        _warpBy(CAP_LOCK);
        vm.prank(stranger);
        vault.acceptCap(c);
        assertEq(vault.effectiveCap(c), 2 * WILD, "the accepted listing did not land");
        assertTrue(_listed(c), "or did not list");
    }

    /// @notice Listing at or under the effective cap is no raise: it lands at once.
    function test_ListingAtOrUnderTheEffectiveCapLands() public {
        address d = address(new MockStakeVault(42));
        vm.prank(curator);
        vault.submitCap(c, WILD);
        vm.prank(guardian);
        vault.submitCap(d, WILD / 2);
        assertTrue(_listed(c) && _listed(d), "a listing at or under the wildcard did not land at once");
        assertEq(vault.effectiveCap(c), WILD, "listing at the wildcard moved the cap");
        assertEq(vault.effectiveCap(d), WILD / 2, "listing under the wildcard did not cut it");
        assertEq(_pending(c) + _pending(d), 0, "a listing that landed left something pending");
    }

    /// @notice Delisting while the wildcard sits above the row is a raise: it waits the timelock.
    function test_DelistingUnderAHigherWildcardWaits() public {
        vm.prank(curator);
        vault.submitCap(c, WILD / 2);
        vm.prank(curator);
        vault.submitDelist(c);
        assertTrue(_listed(c), "a delisting to a higher wildcard landed at once");
        assertEq(vault.effectiveCap(c), WILD / 2, "and lifted the cap");
        _warpBy(CAP_LOCK);
        vault.acceptCap(c);
        assertFalse(_listed(c), "the accepted delisting did not delist");
        assertEq(vault.effectiveCap(c), WILD, "the delisted collateral does not take the wildcard");
    }

    /// @notice Delisting while the wildcard sits at or under the row is a cut: it lands at once, by the guardian too.
    function test_DelistingAtOrUnderTheWildcardLands() public {
        vm.prank(curator);
        vault.submitCap(c, WILD);
        vm.prank(guardian);
        vault.submitDelist(c);
        assertFalse(_listed(c), "a delisting to an equal wildcard did not land at once");
        vm.expectRevert(AceVaultCaps.NotListed.selector);
        vm.prank(curator);
        vault.submitDelist(c);
    }

    /// @notice The wildcard and the total are their own rows and never delist.
    function test_TheWildcardAndTheTotalNeverDelist() public {
        vm.startPrank(curator);
        vm.expectRevert(AceVaultCaps.NotListed.selector);
        vault.submitDelist(address(0));
        vm.expectRevert(AceVaultCaps.NotListed.selector);
        vault.submitDelist(address(vault));
        vm.stopPrank();
    }

    /// @notice A cut of the wildcard drops its pending raise, so no earlier submission can lift it back.
    function test_ACutOfTheWildcardDropsItsPendingRaise() public {
        vm.prank(curator);
        vault.submitCap(address(0), 2 * WILD);
        assertGt(_pending(address(0)), 0, "premise: the wildcard raise waits");
        vm.prank(guardian);
        vault.submitCap(address(0), WILD / 2);
        assertEq(_pending(address(0)), 0, "the cut left the wildcard's raise pending");
        assertEq(vault.effectiveCap(c), WILD / 2, "the cut did not land");
        _warpBy(CAP_LOCK);
        vm.expectRevert(AceVaultCaps.NothingDue.selector);
        vault.acceptCap(address(0));
    }

    /// @notice A cut of the total drops its pending raise.
    function test_ACutOfTheTotalDropsItsPendingRaise() public {
        vm.prank(curator);
        vault.submitCap(address(vault), 0);
        vm.prank(curator);
        vault.submitCap(address(vault), 10_000e6);
        assertGt(_pending(address(vault)), 0, "premise: the total's raise waits");
        vm.prank(guardian);
        vault.submitCap(address(vault), 0);
        assertEq(_pending(address(vault)), 0, "the cut left the total's raise pending");
        _expectBorrowRevert(address(coll), AceVaultCaps.OverTotal.selector);
    }

    /// @notice A pending raise never expires: accepted a year later it still lands, having been visible the whole time.
    function test_APendingRaiseAcceptedAYearLaterStillLands() public {
        vm.prank(curator);
        vault.submitCap(address(0), 2 * WILD);
        _warpBy(365 days);
        vault.acceptCap(address(0));
        assertEq(vault.effectiveCap(c), 2 * WILD, "a year-old raise did not land");
    }

    /// @notice The guardian may cut and revoke, never raise; a stranger may do none of these.
    function test_TheGuardianMayCutAndNotRaise() public {
        vm.startPrank(guardian);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.submitCap(address(0), 2 * WILD);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.submitCap(c, 2 * WILD);
        vault.submitCap(address(0), WILD / 2);
        vm.stopPrank();
        assertEq(vault.effectiveCap(c), WILD / 2, "the guardian's cut did not land");
        vm.prank(curator);
        vault.submitCap(address(0), WILD);
        vm.prank(guardian);
        vault.revokePendingCap(address(0));
        assertEq(_pending(address(0)), 0, "the guardian could not revoke a pending raise");
        vm.startPrank(stranger);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.submitCap(address(0), 0);
        vm.expectRevert(AceVaultCaps.NotCurator.selector);
        vault.revokePendingCap(address(0));
        vm.stopPrank();
    }

    /// @notice A row bounds what is lent against its collateral: a second borrow past it is refused, and repaying reopens it.
    function test_ARowBoundsWhatIsOutstanding() public {
        vm.prank(curator);
        vault.submitCap(c, uint192(PRINCIPAL));
        _setTerms(c, _record(c));
        uint256 loanId = _borrowAs(borrower, c, UNITS, PRINCIPAL);
        assertEq(vlens.roomOf(address(vault), c), 0, "the row's room did not fall by the loan");
        _expectBorrowRevert(c, AceVaultFlows.OverCap.selector);
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertEq(vlens.roomOf(address(vault), c), PRINCIPAL, "repaying did not reopen the row");
    }

    /// @notice The cap verbs move no value and are guarded: a re-entry from the product's write call is refused by the lock.
    function test_TheCapVerbsAreGuarded() public {
        terms.setReentry(address(vault), abi.encodeCall(AceVault.acceptCap, (c)), true, false);
        _borrow();
        assertFalse(terms.reentryOk(), "a cap verb ran under the lock");
        assertEq(bytes4(terms.reentryError()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, "the cap verb was refused, but not by the lock");
    }
}
