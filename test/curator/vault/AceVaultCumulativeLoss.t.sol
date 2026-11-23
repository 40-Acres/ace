// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {AceVaultCaps} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @title AceVaultCumulativeLossTest
/// @notice THE TOTAL bounds cumulative loss, not only what is outstanding: a default moves value from lent into the drawdown and frees nothing.
/// @notice The attack it answers: a hostile product lends a fresh collateral under the wildcard each cycle, on a record that reports distress so
/// @notice `finalize` settles before tenor, to an accomplice who keeps the principal. Room reopening at settlement would drain the vault cycle by cycle.
/// @dev Only gains reopen room, one for one, donations and returned cash alike; deposits and exits never move the drawdown, a full exit included.
contract AceVaultCumulativeLossTest is AceVaultBaseRig {
    uint192 internal constant WILDCARD = 10_000e6; // over the total, so a fresh collateral's room is the total's
    uint192 internal constant TOTAL = 5_000e6;
    uint256 internal constant MAX_CYCLES = 20;

    address internal accomplice = address(0xBAD);
    bytes internal lastErr;
    uint256[] internal defaulted;

    function setUp() public override {
        super.setUp();
        (vault, terms) = _deploy(_cfg(), _pc(), _caps(0, WILDCARD, TOTAL));
        _lp(alice, LP_CASH);
    }

    /// @dev One hostile cycle: a fresh collateral under the wildcard, the accomplice borrows and keeps the cash, and the record's distress settles it.
    /// @return ok Whether the vault lent this cycle; a refusal's reason is kept in `lastErr`.
    function _cycle() internal returns (bool ok) {
        uint256 loanId;
        (loanId, ok) = _open();
        if (!ok) return false;
        _finalize(loanId);
        defaulted.push(loanId);
    }

    /// @dev Open one loan on a fresh collateral for the accomplice, without settling it.
    function _open() internal returns (uint256 loanId, bool ok) {
        MockStakeVault junk = new MockStakeVault(42);
        MockPersistenceRecord r = _record(address(junk));
        terms.setTerms(_market(address(junk), r), Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        junk.mint(accomplice, UNITS);
        vm.startPrank(accomplice);
        junk.approve(address(vault), UNITS);
        try vault.borrow(_req(address(junk), UNITS, PRINCIPAL, 0), "", "") returns (uint256 id) {
            (loanId, ok) = (id, true);
        } catch (bytes memory err) {
            lastErr = err;
        }
        vm.stopPrank();
    }

    /// @dev Cycle until the vault refuses, or `MAX_CYCLES` pass; returns how many lent.
    function _exhaust() internal returns (uint256 n) {
        while (n < MAX_CYCLES && _cycle()) n++;
    }

    /// @dev The guardian exempts every pot standing now, so entry reopens over the loss for the rows whose subject is entry and exit.
    /// @dev The crank first brings the hub's credit into idle, so an exit can reach all of NAV.
    function _waivePots() internal {
        vault.crank();
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
    }

    /// @notice OVER N CYCLES the vault loses at most the total, and the next borrow refuses by the total's name.
    function test_OverNCyclesTheVaultLosesAtMostTheTotal() public {
        uint256 n = _exhaust();
        assertGt(n, 0, "premise: the hostile product lent at least once");
        assertLt(n, MAX_CYCLES, "the vault kept lending past the total");
        assertEq(bytes4(lastErr), AceVaultCaps.OverTotal.selector, "the brake that stopped it was not the total");
        assertLe(vlens.drawdown(address(vault)), TOTAL, "the drawdown passed the total");
        assertLe(LP_CASH, vault.grossNav() + TOTAL, "the LPs lost more than the total");
        assertLe(usdc.balanceOf(accomplice), TOTAL, "the accomplice kept more than the total");
    }

    /// @notice A default frees no room: the claim moves from lent into the drawdown, and room moves only by the cash the settlement credits.
    /// @dev The settlement credits the vault a fee's worth, a real gain, so the drawdown is the claim less it: the LPs' loss net of income.
    function test_ADefaultFreesNoRoom() public {
        address fresh = address(new MockStakeVault(42));
        uint256 room0 = vlens.roomOf(address(vault), fresh);
        (uint256 loanId, bool ok) = _open();
        assertTrue(ok, "premise: the cycle lent");
        uint256 roomLent = vlens.roomOf(address(vault), fresh);
        assertEq(room0 - roomLent, PRINCIPAL, "premise: the loan holds its principal under the total");
        uint256 gLent = vault.grossNav();
        _finalize(loanId);
        uint256 credited = vault.grossNav() + PRINCIPAL - gLent;
        assertLt(credited, PRINCIPAL / 10, "premise: the settlement credited at most a fee's worth");
        assertEq(vlens.roomOf(address(vault), fresh), roomLent + credited, "the default reopened room beyond the cash it credited");
        assertEq(vlens.drawdown(address(vault)), PRINCIPAL - credited, "the drawdown did not take the defaulted claim");
    }

    /// @notice A GAIN, a donation here, reopens exactly its amount under the total.
    function test_AGainReopensExactlyItsAmount() public {
        _exhaust();
        address fresh = address(new MockStakeVault(42));
        uint256 before = vlens.roomOf(address(vault), fresh);
        assertLt(before, PRINCIPAL, "premise: the brake holds");
        uint256 gift = 300e6;
        usdc.mint(address(vault), gift);
        assertEq(vlens.roomOf(address(vault), fresh) - before, gift, "the gain reopened other than its amount");
    }

    /// @notice RETURNED CASH, a pot sold at the hub's ask here, reopens exactly what it credits the vault.
    function test_ReturnedCashReopensExactlyItsAmount() public {
        _exhaust();
        address fresh = address(new MockStakeVault(42));
        uint256 before = vlens.roomOf(address(vault), fresh);
        uint256 g0 = vault.grossNav();
        uint256 loanId = defaulted[0];
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(stranger, 100e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 100e6);
        ace.buyInventory(loanId, 100e6, 0, stranger);
        vm.stopPrank();
        uint256 credited = vault.grossNav() - g0;
        assertGt(credited, 0, "premise: the sale credited the vault");
        assertEq(vlens.roomOf(address(vault), fresh) - before, credited, "the returned cash reopened other than its amount");
    }

    /// @notice FUZZ: deposits and exits never move the drawdown; each adds or takes its cash on both sides.
    function testFuzz_DepositsAndExitsNeverMoveTheDrawdown(uint256 depSeed, uint256 exitSeed) public {
        assertTrue(_cycle(), "premise: one default");
        _warpBy(VEST_W);
        _waivePots();
        uint256 d0 = vlens.drawdown(address(vault));
        assertGt(d0, 0, "premise: the default stands as a drawdown");
        _lp(bob, bound(depSeed, 1e6, 1e12));
        assertEq(vlens.drawdown(address(vault)), d0, "a deposit moved the drawdown");
        uint256 shares = bound(exitSeed, 1e7, vault.maxRedeem(alice)); // ten asset atoms at least, so the redeem pays something
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vlens.drawdown(address(vault)), d0, "an instant exit moved the drawdown");
        vm.startPrank(bob);
        vault.requestExit(vault.balanceOf(bob) / 2);
        vault.claimExit(vault.maxClaim(bob), bob, 0);
        vm.stopPrank();
        assertEq(vlens.drawdown(address(vault)), d0, "a claim moved the drawdown");
    }

    /// @notice THE DRAWDOWN SURVIVES A FULL EXIT: emptying a vault and refilling it does not erase its losses.
    function test_TheDrawdownSurvivesAFullExit() public {
        assertTrue(_cycle(), "premise: one default");
        _warpBy(VEST_W);
        _waivePots();
        uint256 d0 = vlens.drawdown(address(vault));
        assertGt(d0, 0, "premise: the default stands as a drawdown");
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vault.totalSupply(), vault.SEED_SHARES(), "premise: the vault emptied of every live share");
        assertEq(vlens.drawdown(address(vault)), d0, "the full exit erased the drawdown");
        _lp(bob, 50_000e6);
        assertEq(vlens.drawdown(address(vault)), d0, "a refill at zero supply erased the drawdown");
    }

    /// @notice A ZERO TOTAL refuses extensions too: for a vault without the drain it is the guardian's only full brake.
    function test_AZeroTotalRefusesExtensions() public {
        (uint256 loanId, bool ok) = _open();
        assertTrue(ok, "premise: a loan opened");
        _warpBy(1 days);
        _fundFee(accomplice);
        assertEq(vault.admitsExtension(_ext(loanId), ""), IRollPolicy.admitsExtension.selector, "premise: the extension is a yes");
        vm.prank(guardian);
        vault.submitCap(address(vault), 0);
        assertEq(vault.admitsExtension(_ext(loanId), ""), bytes4(0), "a zero total consented to an extension");
        vm.prank(accomplice);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }
}
