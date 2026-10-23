// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";
import {LockAccountChecks} from "./LockAccountInvariants.t.sol";
import {LockAccountHandler} from "./LockAccountHandler.sol";

/// @title LockAccountGhostCheck
/// @notice The lending review's finding 9: the campaign's ghost loan list is filled only from `borrow`'s return value.
/// @notice A loan the account came to hold by any other path would be invisible to every property that walks that list.
/// @notice So the list is cross-checked against the HUB's own: the market's loans, their title of record, and the account's booked pledge.
/// @dev A title donated in from outside reads `borrowerOf == account` with no pledge booked, so a zero pledge expiry skips it.
abstract contract LockAccountGhostCheck is LockAccountChecks {
    /// @dev The loans the hub lists in the market whose title is the account and whose pledge the account booked.
    function _hubBooked() internal view returns (uint256 count) {
        Ace ace = handler.ace();
        bytes32 id = handler.id();
        uint256[] memory all = ace.marketLoans(id, 0, ace.marketLoansLength(id));
        for (uint256 i; i < all.length; ++i) {
            if (ace.borrowerOf(all[i]) != address(acct)) continue;
            (, uint64 expiry) = acct.pledgeOf(all[i]);
            if (expiry != 0) ++count;
        }
    }

    /// @dev The loans the hub lists in the market whose title is the account, booked or not.
    function _hubTitled() internal view returns (uint256 count) {
        Ace ace = handler.ace();
        bytes32 id = handler.id();
        uint256[] memory all = ace.marketLoans(id, 0, ace.marketLoansLength(id));
        for (uint256 i; i < all.length; ++i) {
            if (ace.borrowerOf(all[i]) == address(acct)) ++count;
        }
    }

    /// @dev The ghost list and the hub agree: as many entries as booked loans, and every entry is one of them.
    function _ghostListIsTheHubs() internal view {
        uint256 n = handler.loanCount();
        assertEq(_hubBooked(), n, "the hub holds a booked loan of the account's that the ghost list missed, or the reverse");
        for (uint256 i; i < n; ++i) {
            uint256 loanId = handler.loanAt(i);
            assertEq(handler.ace().borrowerOf(loanId), address(acct), "a ghost loan is not titled to the account");
            (, uint64 expiry) = acct.pledgeOf(loanId);
            assertGt(expiry, 0, "a ghost loan has no pledge booked");
        }
    }
}

/// @title LockAccountGhostListInvariants
/// @notice The buyer schedule's campaign, with the ghost list checked against the hub after every call.
/// @dev The same handler, selectors and config as `LockAccountBuyerInvariants`, so it walks the same sequences.
contract LockAccountGhostListInvariants is StdInvariant, LockAccountGhostCheck {
    function setUp() public {
        _build(0);
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = LockAccountHandler.pledge.selector;
        sel[1] = LockAccountHandler.release.selector;
        sel[2] = LockAccountHandler.repay.selector;
        sel[3] = LockAccountHandler.defaultLoan.selector;
        sel[4] = LockAccountHandler.reclaim.selector;
        sel[5] = LockAccountHandler.warp.selector;
        sel[6] = LockAccountHandler.donate.selector;
        sel[7] = LockAccountHandler.pledgeAtCapacity.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    function invariant_ghostListIsTheHubs() public view {
        _ghostListIsTheHubs();
    }
}

/// @title LockAccountGhostListScripted
/// @notice The cross-check on a scripted chain, against a title donated in from outside, and against a loan the handler never saw.
contract LockAccountGhostListScripted is LockAccountGhostCheck {
    address internal bob = address(0xB0B);

    /// @notice Pledge twice, default both ways, reclaim, donate and release: the ghost list is the hub's after every step.
    function test_TheGhostListIsTheHubsThroughTheDefaultChain() public {
        _build(0);
        handler.pledgeAtCapacity(0);
        _ghostListIsTheHubs();
        handler.pledgeAtCapacity(type(uint256).max);
        _ghostListIsTheHubs();
        handler.defaultLoan(0, false);
        _ghostListIsTheHubs();
        handler.reclaim(0);
        handler.donate(5_000e18);
        handler.release(type(uint256).max);
        _ghostListIsTheHubs();
        handler.defaultLoan(1, true);
        handler.reclaim(1);
        _ghostListIsTheHubs();
        assertEq(_hubBooked(), 2, "fixture: both pledges are the hub's loans, closed loans included");
    }

    /// @notice A title donated in from outside is the account's on the hub, but the account never booked it: skipped, never counted.
    function test_ADonatedTitleIsSkipped() public {
        _build(0);
        handler.pledgeAtCapacity(0);
        uint256 donated = _openAsBob();
        address title = handler.ace().POSITION_TITLE();
        vm.prank(bob);
        IERC721(title).transferFrom(bob, address(acct), donated);
        assertEq(handler.ace().borrowerOf(donated), address(acct), "fixture: the donated title is the account's on the hub");
        assertEq(_hubTitled(), handler.loanCount() + 1, "fixture: the hub lists one more loan titled to the account");
        _ghostListIsTheHubs();
    }

    /// @notice The control: a loan the account opens past the handler is on the hub and booked, and the check sees it missing.
    function test_ALoanOpenedPastTheHandlerIsCaught() public {
        _build(0);
        handler.pledgeAtCapacity(0);
        (uint256 units, bytes32 id, address alice) = (acct.capacity(uint64(handler.now_()) + 30 days), handler.id(), handler.alice());
        vm.prank(alice);
        acct.borrow(id, units, 10e6, 30 days, OpenBounds(0, 0, 0));
        assertEq(_hubBooked(), handler.loanCount() + 1, "the cross-check did not see the loan the ghost list missed");
    }

    /// @dev Bob, an outsider, opens his own loan in the account's market with his own tokens.
    function _openAsBob() internal returns (uint256 loanId) {
        Ace ace = handler.ace();
        handler.token().mint(bob, 1_000e18);
        vm.startPrank(bob);
        handler.token().approve(address(handler.pm()), 1_000e18);
        loanId = ace.open(handler.id(), 1_000e18, 10e6, 7 days, bob, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }
}
