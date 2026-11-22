// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {AceVaultCaps} from "../../../src/curator/libraries/AceVaultCaps.sol";
import {Terms, VaultConfig} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @title AceVaultDrawdownTest
/// @notice F1 hardening: the drawdown is gross NAV's fall below a high-water that moves with deposits and exits, and the total bounds lent plus it.
/// @notice Every value-neutral verb leaves it where it was: the vest, a fee mint, the drain, the crank, requests, claims and share moves.
/// @notice A gain reopens room one for one up to the high, never past it once a sync has seen the new high; an honest round trip leaves none.
/// @dev THE MODEL: a gross rise is a gain that cuts the drawdown, floored at zero; a gross fall at the hub is a loss that adds to it.
/// @dev The open's lender fee is a gain the borrow's own sync sees, so a default's loss is measured from the open's level, not before it.
/// @dev Every expected figure comes from measured gross NAV, never from the vault's own storage.
contract AceVaultDrawdownTest is AceVaultBaseRig {
    uint192 internal constant WILDCARD = 10_000e6; // over the total, so a fresh collateral's room is the total's
    uint192 internal constant TOTAL = 5_000e6;

    address internal accomplice = address(0xBAD);

    function setUp() public override {
        super.setUp();
        (vault, terms) = _deploy(_cfg(), _pc(), _caps(UNCAPPED, WILDCARD, TOTAL));
        _setTerms(address(coll), record);
        _lp(alice, LP_CASH);
    }

    /// @dev Point the product at a fresh collateral under the wildcard and open `p` for the accomplice, pledging the rig's ratio.
    function _openFresh(uint256 p) internal returns (uint256 loanId, address c) {
        MockStakeVault junk = new MockStakeVault(42);
        c = address(junk);
        uint256 units = (UNITS * p) / PRINCIPAL;
        terms.setTerms(_market(c, _record(c)), Terms({units: units, principal: p, tenor: 0, minBufferWad: 0}));
        junk.mint(accomplice, units);
        vm.startPrank(accomplice);
        junk.approve(address(vault), units);
        loanId = vault.borrow(_req(c, units, p, 0), "", "");
        vm.stopPrank();
    }

    /// @dev One default of `p` on a fresh collateral: the gross the open added, and the gross the settlement then took.
    function _default(uint256 p) internal returns (uint256 openGain, uint256 settleLoss) {
        uint256 g0 = vault.grossNav();
        (uint256 loanId,) = _openFresh(p);
        uint256 g1 = vault.grossNav();
        _finalize(loanId);
        (openGain, settleLoss) = (g1 - g0, g1 - vault.grossNav());
    }

    /// @dev The model's step for one default: the open's gain cuts the drawdown, floored, then the settlement's loss adds.
    function _modelDefault(uint256 model, uint256 p) internal returns (uint256) {
        (uint256 openGain, uint256 settleLoss) = _default(p);
        return (openGain >= model ? 0 : model - openGain) + settleLoss;
    }

    /// @dev Collect the hub's credit, then exempt every pot standing now, so entry reopens over the loss.
    function _waivePots() internal {
        vault.crank();
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
    }

    function _freshRoom() internal returns (uint256) {
        return vlens.roomOf(address(vault), address(new MockStakeVault(42)));
    }

    function _repayAll(uint256 loanId) internal {
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    // ---- an honest loan never consumes the brake ----

    /// @notice AN HONEST ROUND TRIP leaves no drawdown: a loan repaid in full a day in, its cash collected, frees the whole total.
    function test_AnEarlyFullRepayLeavesNoDrawdown() public {
        uint256 loanId = _borrow();
        _warpBy(1 days);
        _repayAll(loanId);
        assertFalse(ace.isLiveLoan(loanId), "premise: the loan closed");
        vault.crank();
        assertEq(vlens.drawdown(address(vault)), 0, "an honest early repay left a drawdown");
        assertGe(vault.grossNav(), LP_CASH, "an honest early repay lost the LPs cash");
        assertEq(_freshRoom(), TOTAL, "an honest round trip did not free the whole total");
    }

    /// @notice AN HONEST LOAN REPAID IN ITS LAST SECOND leaves no drawdown either.
    function test_AFullRepayAtTheEndLeavesNoDrawdown() public {
        uint256 loanId = _borrow();
        _warpTo(read.loan(loanId).expiry - 1);
        _repayAll(loanId);
        vault.crank();
        assertEq(vlens.drawdown(address(vault)), 0, "a repay at the end left a drawdown");
        assertEq(_freshRoom(), TOTAL, "a repay at the end did not free the whole total");
    }

    /// @notice A DEFAULT counts the claim from the open's level: the lender fee the open booked is a gain the borrow's sync saw.
    function test_ADefaultCountsTheClaimFromTheOpensLevel() public {
        (uint256 openGain, uint256 settleLoss) = _default(PRINCIPAL);
        assertGt(openGain, 0, "premise: the open booked a lender fee");
        assertEq(vlens.drawdown(address(vault)), settleLoss, "the drawdown is not the settlement's fall from the open's level");
        assertEq(_freshRoom(), TOTAL - settleLoss, "the total's room is not the total less that fall");
    }

    // ---- value-neutral verbs leave the drawdown ----

    /// @notice THE VEST moves NAV and never gross: a gain stamped before a loss vests out over the window, and the drawdown stays the loss.
    /// @dev A gain landing inside a drawdown is a smaller fall and stamps nothing, so the pile is stamped first, above the old high.
    function test_TheVestLeavesTheDrawdown() public {
        usdc.mint(address(vault), 2 * PRINCIPAL);
        vault.crank();
        (, uint256 loss) = _default(PRINCIPAL);
        uint256 d0 = vlens.drawdown(address(vault));
        assertEq(d0, loss, "premise: the drawdown is the loss from the gain's high");
        assertGt(vault.unvested(), 0, "premise: what the loss left of the gain still vests");
        _warpBy(VEST_W / 2);
        assertEq(vlens.drawdown(address(vault)), d0, "half the vest moved the drawdown");
        _warpBy(VEST_W);
        vault.crank();
        assertEq(vault.unvested(), 0, "premise: the vest ran out");
        assertEq(vlens.drawdown(address(vault)), d0, "the whole vest moved the drawdown");
    }

    /// @notice THE DRAIN moves no value: switching it on and off, each with its sync, leaves the drawdown.
    function test_TheDrainLeavesTheDrawdown() public {
        _default(PRINCIPAL);
        uint256 d0 = vlens.drawdown(address(vault));
        assertGt(d0, 0, "premise: a drawdown stands");
        vm.prank(guardian);
        vault.setDrain(true);
        assertEq(vlens.drawdown(address(vault)), d0, "the drain's switch-on moved the drawdown");
        vm.prank(curator);
        vault.setDrain(false);
        assertEq(vlens.drawdown(address(vault)), d0, "the drain's switch-off moved the drawdown");
    }

    /// @notice THE CRANK moves the hub's credit, here a pot's sale proceeds, into idle: gross, the drawdown and the total's room all stand.
    /// @dev A room that counted the hub's uncollected credit as lent would grow at the crank: that mutant dies here.
    function test_ACrankLeavesTheDrawdownAndTheRoom() public {
        MockStakeVault junk = new MockStakeVault(42);
        terms.setTerms(_market(address(junk), _record(address(junk))), Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        uint256 loanId = _borrowAs(accomplice, address(junk), UNITS, PRINCIPAL);
        _finalize(loanId);
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(stranger, 100e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 100e6);
        ace.buyInventory(loanId, 100e6, 0, stranger);
        vm.stopPrank();
        assertGt(ace.lenderOwed(address(vault), address(usdc)), 0, "premise: the sale left credit at the hub");
        uint256 d0 = vlens.drawdown(address(vault));
        uint256 room0 = _freshRoom();
        assertEq(room0, TOTAL - d0, "the total's room is not the total less the drawdown, nothing being lent");
        vault.crank();
        assertEq(ace.lenderOwed(address(vault), address(usdc)), 0, "premise: the crank collected the credit");
        assertEq(vlens.drawdown(address(vault)), d0, "the crank moved the drawdown");
        assertEq(_freshRoom(), room0, "the crank moved the total's room");
    }

    /// @notice A REQUEST, its renewal, its cancel, its lapse and a share move all leave the drawdown.
    function test_RequestsAndShareMovesLeaveTheDrawdown() public {
        _default(PRINCIPAL);
        uint256 d0 = vlens.drawdown(address(vault));
        uint256 shares = vault.balanceOf(alice) / 4;
        vm.startPrank(alice);
        vault.requestExit(shares);
        assertEq(vlens.drawdown(address(vault)), d0, "a request moved the drawdown");
        vault.requestExit(0);
        assertEq(vlens.drawdown(address(vault)), d0, "a renewal moved the drawdown");
        vault.cancelExit(shares / 2);
        assertEq(vlens.drawdown(address(vault)), d0, "a cancel moved the drawdown");
        assertTrue(vault.transfer(bob, shares), "premise: the share move landed");
        vm.stopPrank();
        assertEq(vlens.drawdown(address(vault)), d0, "a share move moved the drawdown");
        _warpBy(vault.REQUEST_LEASE());
        vault.lapseExit(alice);
        assertEq(vlens.drawdown(address(vault)), d0, "a lapse moved the drawdown");
    }

    /// @notice A FEE MINT moves only supply: collecting the fee on a vested gain while a loss stands leaves the drawdown.
    function test_AFeeMintLeavesTheDrawdown() public {
        VaultConfig memory cfg = _cfg();
        cfg.perfFeeBps = 2000;
        (vault, terms) = _deploy(cfg, _pc(), _caps(UNCAPPED, WILDCARD, TOTAL));
        _setTerms(address(coll), record);
        _lp(alice, LP_CASH);
        usdc.mint(address(vault), 2 * PRINCIPAL);
        vault.crank();
        _warpBy(VEST_W + 1);
        _default(PRINCIPAL);
        uint256 d0 = vlens.drawdown(address(vault));
        assertGt(d0, 0, "premise: a loss stands under the new high");
        assertGt(vault.pendingFeeShares(), 0, "premise: the net gain past the fee high-water owes a fee");
        uint256 supply0 = vault.totalSupply();
        vault.collectFee();
        assertGt(vault.totalSupply(), supply0, "premise: the fee minted");
        assertEq(vlens.drawdown(address(vault)), d0, "the fee mint moved the drawdown");
    }

    // ---- gains reopen room one for one, and only up to the high ----

    /// @notice A GAIN SHORT OF THE LOSS reopens exactly its amount, and the rest of the loss still holds room.
    function test_APartialGainReopensExactlyItsAmount() public {
        (, uint256 loss) = _default(PRINCIPAL);
        assertEq(vlens.drawdown(address(vault)), loss, "premise: the drawdown is the measured loss");
        uint256 room0 = _freshRoom();
        uint256 gift = loss / 7 + 3;
        usdc.mint(address(vault), gift);
        assertEq(vlens.drawdown(address(vault)), loss - gift, "a partial gain did not cut the drawdown by its amount");
        assertEq(_freshRoom(), room0 + gift, "a partial gain reopened other than its amount");
        vault.crank();
        assertEq(vlens.drawdown(address(vault)), loss - gift, "the sync after a partial gain moved the drawdown");
    }

    /// @notice A GAIN PAST THE HIGH reopens only the loss; once a sync has seen the new high, the next loss counts in full.
    function test_AGainPastTheHighLiftsItAndTheNextLossCountsInFull() public {
        (, uint256 loss) = _default(PRINCIPAL);
        usdc.mint(address(vault), loss + 500e6);
        assertEq(vlens.drawdown(address(vault)), 0, "a gain past the loss left a drawdown");
        assertEq(vlens.navHigh(address(vault)), vault.grossNav(), "the high-water view does not stand at the new high");
        vault.crank();
        (, uint256 loss2) = _default(PRINCIPAL);
        assertEq(vlens.drawdown(address(vault)), loss2, "a gain over the old high absorbed a loss counted after the high was seen");
    }

    /// @notice THE TOTAL ADMITS EXACTLY ITS ROOM: lent plus the drawdown plus the draw at the total lands, one unit more refuses by its name.
    /// @dev The draw at the room books its own lender fee, a gain under the high, so it reopens exactly that much.
    function test_TheTotalAdmitsExactlyItsRoom() public {
        (, uint256 loss) = _default(PRINCIPAL);
        uint256 g0 = vault.grossNav();
        _openFresh(PRINCIPAL);
        uint256 dd = loss - (vault.grossNav() - g0);
        uint256 p = TOTAL - PRINCIPAL - dd;
        assertEq(_freshRoom(), p, "the total's room is not the total less lent and the drawdown");
        MockStakeVault junk = new MockStakeVault(42);
        uint256 units = (UNITS * (p + 1)) / PRINCIPAL;
        terms.setTerms(_market(address(junk), _record(address(junk))), Terms({units: units, principal: p + 1, tenor: 0, minBufferWad: 0}));
        junk.mint(accomplice, units);
        vm.startPrank(accomplice);
        junk.approve(address(vault), units);
        vm.expectRevert(AceVaultCaps.OverTotal.selector);
        vault.borrow(_req(address(junk), units, p + 1, 0), "", "");
        vm.stopPrank();
        uint256 g1 = vault.grossNav();
        (uint256 atId,) = _openFresh(p);
        assertTrue(ace.isLiveLoan(atId), "a draw exactly at the total's room was refused");
        assertEq(_freshRoom(), vault.grossNav() - g1, "a draw at the total's room reopened other than its own fee");
    }

    // ---- the brake over many cycles, and across a full exit ----

    /// @notice MANY CYCLES, NO DRIFT: defaults, odd-sized gains, deposits, exits and time, and the drawdown is always the model's to the wei.
    function test_ManyCyclesKeepTheDrawdownToTheWei() public {
        _waivePots();
        uint256 model;
        for (uint256 i; i < 12; i++) {
            model = _modelDefault(model, PRINCIPAL / 10 + i * 7_777);
            assertEq(vlens.drawdown(address(vault)), model, "a default did not move the drawdown as the model");
            uint256 gift = (model * (i + 1)) / 17 + i;
            if (gift > model) gift = model;
            usdc.mint(address(vault), gift);
            model -= gift;
            assertEq(vlens.drawdown(address(vault)), model, "a gain did not cut the drawdown by its amount");
            _waivePots();
            _lp(bob, 1_234_567 + i * 31);
            assertEq(vlens.drawdown(address(vault)), model, "a deposit moved the drawdown");
            uint256 out = vault.maxRedeem(bob) / 3 + 1;
            vm.prank(bob);
            vault.redeem(out, bob, bob);
            assertEq(vlens.drawdown(address(vault)), model, "an exit moved the drawdown");
            _warpBy(VEST_W / 3 + i);
            assertEq(vlens.drawdown(address(vault)), model, "time moved the drawdown");
        }
        assertEq(_freshRoom(), TOTAL - model, "the room left is not the total less the modelled drawdown");
    }

    /// @notice N2: EMPTY AND REFILL, THEN LOSE AGAIN: the new loss adds to the old one, and the total binds on their sum.
    function test_AFullExitThenARefillKeepsCountingFromTheOldHigh() public {
        uint256 model = _modelDefault(0, PRINCIPAL);
        _warpBy(VEST_W);
        _waivePots();
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vault.totalSupply(), vault.SEED_SHARES(), "premise: the vault emptied of every live share");
        assertEq(vlens.drawdown(address(vault)), model, "the full exit moved the drawdown");
        _lp(bob, 200_000e6);
        assertEq(vlens.drawdown(address(vault)), model, "the refill moved the drawdown");
        uint256 first = model;
        model = _modelDefault(model, PRINCIPAL);
        assertGt(model, first, "premise: the second loss stands on the first");
        assertEq(vlens.drawdown(address(vault)), model, "a loss after the refill did not add to the one before the exit");
        assertEq(_freshRoom(), TOTAL - model, "the total does not bind on both losses");
    }

    /// @notice A CLAIM BY THE LAST REQUESTER, its release included, also leaves the drawdown, and so does the refill after it.
    function test_TheLastRequestersClaimLeavesTheDrawdown() public {
        (, uint256 loss) = _default(PRINCIPAL);
        _waivePots();
        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.requestExit(shares);
        vault.claimExit(vault.maxClaim(alice), alice, 0);
        vm.stopPrank();
        assertLt(vault.totalSupply() - vault.SEED_SHARES(), shares / 1e9, "premise: the claim took all but dust and the genesis seed");
        assertEq(vlens.drawdown(address(vault)), loss, "the last requester's claim moved the drawdown");
        _lp(bob, 50_000e6);
        assertEq(vlens.drawdown(address(vault)), loss, "the refill after the claim moved the drawdown");
    }

    // ---- fuzz: any order of neutral verbs between two losses ----

    /// @notice FUZZ: between two defaults, any mix of deposits, exits, requests, claims, crank and time leaves the drawdown as the model has it.
    function testFuzz_NeutralVerbsBetweenLossesNeverMoveTheDrawdown(uint256 seed) public {
        uint256 model = _modelDefault(0, PRINCIPAL);
        _waivePots();
        for (uint256 i; i < 8; i++) {
            uint256 op = uint256(keccak256(abi.encode(seed, i))) % 6;
            uint256 amt = uint256(keccak256(abi.encode(seed, i, "amt")));
            (uint256 redeemable, uint256 held, uint256 claimable) = (vault.maxRedeem(alice), vault.balanceOf(bob), vault.maxClaim(bob));
            if (op == 0) {
                _lp(bob, bound(amt, 1e6, 100_000e6));
            } else if (op == 1 && redeemable > 1e7) {
                vm.prank(alice);
                vault.redeem(bound(amt, 1e7, redeemable), alice, alice);
            } else if (op == 2 && held > 1) {
                vm.prank(bob);
                vault.requestExit(bound(amt, 1, held));
            } else if (op == 3 && claimable > 1e7) {
                vm.prank(bob);
                vault.claimExit(bound(amt, 1e7, claimable), bob, 0);
            } else if (op == 4) {
                vault.crank();
            } else {
                _warpBy(bound(amt, 1, 3 days));
            }
            assertEq(vlens.drawdown(address(vault)), model, "a neutral verb moved the drawdown");
        }
        (uint256 req,) = vlens.requestOf(address(vault), bob);
        vm.prank(bob);
        vault.cancelExit(req);
        _lp(bob, PRINCIPAL);
        assertEq(vlens.drawdown(address(vault)), model, "the cancel or the deposit before the second loss moved the drawdown");
        model = _modelDefault(model, PRINCIPAL / 2);
        assertEq(vlens.drawdown(address(vault)), model, "the second loss did not move the drawdown as the model");
    }

    /// @notice CONTROL: the high-water view never sits under gross, the drawdown is the gap, and a gain past the high reads no drawdown.
    function test_TheHighWaterViewNeverSitsUnderGross() public {
        _default(PRINCIPAL);
        assertGe(vlens.navHigh(address(vault)), vault.grossNav(), "the high-water view sits under gross");
        assertEq(vlens.navHigh(address(vault)) - vault.grossNav(), vlens.drawdown(address(vault)), "the drawdown is not the high-water less gross");
        usdc.mint(address(vault), 2 * vlens.drawdown(address(vault)) + 1);
        assertEq(vlens.navHigh(address(vault)), vault.grossNav(), "past the high, the view does not follow gross");
        assertEq(vlens.drawdown(address(vault)), 0, "past the high, a drawdown still reads");
    }
}
