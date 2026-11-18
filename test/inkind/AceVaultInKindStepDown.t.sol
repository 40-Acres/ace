// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultCaps} from "../../src/curator/AceVaultCaps.sol";
import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";
import {InKindVaults} from "../utils/InKindVaults.sol";
import {Listing, Quote} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title AceVaultInKindStepDown
/// @notice Rule IK: an in-kind vault's room under its total steps down by each default's unrecovered claim and comes back only by premium or a raise.
/// @notice Per-token rows still reopen at the settle, and the drawdown survives a full exit and a refill.
/// @dev Every figure is read off the hub: the claim is the lent the settle retires, the escrow the loan's fee escrow just before it.
contract AceVaultInKindStepDownTest is InKindRig {
    uint192 internal constant TOTAL = 10_000e6;

    function setUp() public override {
        super.setUp();
        total = TOTAL;
        vault = _deploy(_cfg(0), _ik(), _listings());
        _lp(alice, LP_CASH);
    }

    /// @dev What the vault has lent against `coll`, from the hub.
    function _lent(address coll) internal view returns (uint256 lent) {
        (lent,) = ace.lenderByCollateral(address(vault), address(usdc), coll);
    }

    /// @dev Default `loanId` at expiry and collect it; returns the claim the settle retired and the escrow it credited, both from hub reads.
    function _defaultMeasured(uint256 loanId) internal returns (uint256 claim, uint256 escrow) {
        _toExpiry(loanId);
        address coll = _mp(loanId).collateral;
        uint256 lent0 = _lent(coll);
        escrow = read.feeEscrowOf(loanId);
        _collect(loanId);
        claim = lent0 - _lent(coll);
        assertGt(claim, 0, "premise: the settle retired the loan's claim");
    }

    /// @notice A default raises the drawdown by its claim less the unearned escrow the settle credits, and the total's room falls by the same.
    function test_aDefaultStepsTheTotalDownByItsClaimLessTheEscrow() public {
        uint256 loanId = _open(address(tokA));
        assertEq(lens.drawdown(address(vault)), 0, "premise: no loss before the default");
        assertEq(lens.roomOf(address(vault), address(tokB)), TOTAL - _lent(address(tokA)), "premise: the total's room is the total less what is lent");
        (uint256 claim, uint256 escrow) = _defaultMeasured(loanId);
        assertGt(escrow, 0, "premise: the settle credited a fee escrow");
        assertEq(lens.drawdown(address(vault)), claim - escrow, "the drawdown is the claim less the escrow");
        assertEq(lens.roomOf(address(vault), address(tokB)), TOTAL - (claim - escrow), "the total's room fell by the drawdown, not back to the whole total");
    }

    /// @notice Later premium refills the drawdown exactly: each unit of gross the vault earns back lowers it by that unit.
    function test_laterPremiumRefillsTheDrawdownExactly() public {
        (uint256 claim, uint256 escrow) = _defaultMeasured(_open(address(tokA)));
        uint256 dd0 = lens.drawdown(address(vault));
        assertEq(dd0, claim - escrow, "premise: the default left a drawdown");
        uint256 gross0 = vault.grossNav();
        uint256 loanId = _open(address(tokB));
        _warpAtLeastTo(_expiry(loanId) - 1);
        _repayAll(loanId);
        uint256 premium = vault.grossNav() - gross0;
        assertGt(premium, 0, "premise: the repaid loan's fee raised gross");
        assertLt(premium, dd0, "premise: and by less than the drawdown, so none of it is a new high");
        assertEq(lens.drawdown(address(vault)), dd0 - premium, "the premium refilled the drawdown unit for unit");
        assertEq(lens.roomOf(address(vault), address(tokB)), TOTAL - (dd0 - premium), "and the total's room by the same");
    }

    /// @notice A timelocked raise of the total restores the room the drawdown holds.
    function test_aTimelockedRaiseOfTheTotalRestoresCapacity() public {
        total = uint192(PRINCIPAL * 3 / 2);
        vault = _deploy(_cfg(0), _ik(), _listings());
        _lp(alice, LP_CASH);
        _defaultMeasured(_open(address(tokA)));
        uint256 dd = lens.drawdown(address(vault));
        assertGt(dd, PRINCIPAL / 2, "premise: the drawdown leaves less room than a loan");
        Quote memory q = _quote(address(tokB), PRICE);
        bytes memory data = _data(q);
        _fund(address(tokB), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(AceVaultCaps.OverTotal.selector);
        vault.borrow(_req(address(tokB), UNITS, PRINCIPAL, MIN_TENOR), data, "");
        uint192 raised = uint192(PRINCIPAL * 3 / 2 + dd);
        vm.prank(curator);
        vault.submitCap(address(vault), raised);
        (uint192 pending,, uint64 validAt) = lens.pendingCapOf(address(vault), address(vault));
        assertEq(pending, raised, "the raise pends");
        assertEq(validAt, _now() + TIMELOCK, "for the cap timelock");
        _warpBy(TIMELOCK);
        vault.acceptCap(address(vault));
        assertEq(lens.roomOf(address(vault), address(tokB)), PRINCIPAL * 3 / 2, "the raise gave back exactly the room the drawdown held");
        assertGt(_open(address(tokB)), 0, "and the vault lends again");
    }

    /// @notice Per-token rows reopen at the settle: the claim leaves the row, and the seized pot is never counted against it.
    function test_perTokenRowsReopenAtSettlement() public {
        Listing[] memory l = _listings();
        l[0].cap = uint192(PRINCIPAL);
        total = InKindVaults.UNCAPPED;
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        uint256 first = _open(address(tokA));
        assertEq(lens.roomOf(address(vault), address(tokA)), 0, "premise: the row is full");
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _data(q);
        _fund(address(tokA), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, "");
        _defaultMeasured(first);
        assertGt(tokA.balanceOf(address(vault)), 0, "premise: the vault holds the seized pot");
        assertEq(lens.roomOf(address(vault), address(tokA)), PRINCIPAL, "the row's room is whole again at the settle");
        assertGt(_open(address(tokA)), 0, "and it lends");
    }

    /// @notice The drawdown survives a full exit and a refill: emptying the vault never erases its losses.
    function test_theDrawdownSurvivesAFullExitAndRefill() public {
        _defaultMeasured(_open(address(tokA)));
        uint256 dd = lens.drawdown(address(vault));
        assertGt(dd, 0, "premise: a default left a drawdown");
        _warpBy(VEST_W + 1);
        uint256 all = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(all, alice, alice);
        assertEq(vault.totalSupply(), vault.SEED_SHARES(), "premise: every live share left");
        assertEq(lens.drawdown(address(vault)), dd, "the drawdown is unchanged by the full exit");
        _nextBlock(); // entry stays shut for the rest of the collect's block
        _lp(bob, LP_CASH);
        assertEq(lens.drawdown(address(vault)), dd, "and by the refill");
        assertEq(lens.roomOf(address(vault), address(tokB)), TOTAL - dd, "so the total's room is still held by it");
    }
}
