// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NotBorrower} from "../../src/ace/hub/Borrower.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {IAceDrawMore} from "../utils/DrawMoreRig.sol";
import {LaunchVaultBase} from "./LaunchVault.t.sol";

/// @title LaunchVaultDrawMoreTest
/// @notice B-3: a LaunchVault reservation rests cash across calls, yet no top-up can reach it.
/// @notice The borrower rule admits only the market's named lock account, and the account has no top-up door and moves no title.
/// @notice B-8: a stranger's units added to an account's loan are a donation, and come home to the account at the close.
contract LaunchVaultDrawMoreTest is LaunchVaultBase {
    /// @dev A reservation half drawn by alice's account, so cash still rests in its market beside a live loan.
    function _halfDrawn() internal returns (LockAccount acct, bytes32 mid, uint256 loanId) {
        acct = _ready();
        uint256 got;
        (mid, got) = _reserve(vault, alice, type(uint256).max);
        loanId = _borrow(m, alice, mid, got / 2, 30 days);
        assertGe(ace.restingOf(mid), ace.idToMarketParams(mid).minPrincipal, "PREMISE: a top-up's worth of cash rests");
    }

    /// @notice The resting cash of a live reservation is out of every caller's reach: each is refused `NotBorrower`, and nothing draws.
    function test_AReservationsRestingCashIsUnreachableByAnyTopUp() public {
        (LockAccount acct, bytes32 mid, uint256 loanId) = _halfDrawn();
        uint256 resting = ace.restingOf(mid);
        address[4] memory who = [stranger, alice, curator, address(vault)];
        for (uint256 i; i < who.length; i++) {
            vm.prank(who[i]);
            vm.expectRevert(NotBorrower.selector);
            IAceDrawMore(address(ace)).drawMore(loanId, resting, OpenBounds(0, 0, 0));
        }
        (bool ok,) = address(acct).call(abi.encodeCall(IAceDrawMore.drawMore, (loanId, resting, OpenBounds(0, 0, 0))));
        assertFalse(ok, "the account answers no top-up selector: it has no door to the verb");
        assertEq(ace.restingOf(mid), resting, "nothing drew the reservation's cash");
    }

    /// @notice A stranger's tokens added to the account's loan land as a donation, and a clean close credits the whole lot to the account.
    function test_AStrangersAddIsADonationThatComesHomeToTheAccount() public {
        (LockAccount acct,, uint256 loanId) = _halfDrawn();
        uint256 units0 = read.loan(loanId).collateralUnits;
        uint256 gift = 1e18;
        strat.send(m.token, stranger, gift);
        vm.startPrank(stranger);
        IERC20(m.token).approve(ace.POSITION_MANAGER(), gift);
        IAceDrawMore(address(ace)).addCollateral(loanId, gift, "");
        vm.stopPrank();
        assertEq(read.loan(loanId).collateralUnits, units0 + gift, "the donation is under the loan");
        _repay(loanId);
        assertEq(read.unitsOwedOf(loanId, address(acct)), units0 + gift, "the close credits the account the whole lot, the donation with it");
        assertEq(read.unitsOwedOf(loanId, stranger), 0, "and the donor nothing");
    }
}
