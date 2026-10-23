// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {LoanClosed} from "../../../src/ace/hub/Borrower.sol";
import {BelowMinLot} from "../../../src/ace/hub/Lender.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault} from "../../../src/curator/CuratorVault.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The core's edges on the shipped CuratorVault: a placement exactly at lendable, the market's cash cap, the dust band, a closed loan's roll.
/// @dev Each row sits on the boundary a comparison draws, so a strict test turned non-strict, or a dropped leg, fails here.
contract AceVaultBoundariesTest is AceVaultRig {
    address internal lp2 = address(0x1F2);

    /// @dev A fresh vault on the rig's row, holding exactly `cash` of one LP's deposit and nothing else.
    function _seeded(uint256 cash) internal returns (CuratorVault v) {
        v = _newVault(_row(address(record), type(uint192).max));
        usdc.mint(lp2, cash);
        vm.startPrank(lp2);
        usdc.approve(address(v), cash);
        v.deposit(cash, lp2);
        vm.stopPrank();
    }

    /// @dev Borrow on `v` as `who`, minted and approving exactly the units.
    function _borrowOn(CuratorVault v, address who, uint256 principal, bool arm) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(v), UNITS);
        loanId = v.borrow(_req(UNITS, principal, MAX_TENOR, arm), "", "");
        vm.stopPrank();
    }

    /// @dev The roll hold an armed draw of `principal` books on an empty book, read off the vault's own view in a throwaway state.
    function _holdOfArmed(uint256 principal) internal returns (uint256 h) {
        uint256 snap = vm.snapshotState();
        _borrowAs(borrower, UNITS, principal, MAX_TENOR, true);
        h = vault.rollHoldNow();
        vm.revertToState(snap);
    }

    // ---- the placement against lendable ----

    /// @notice An armed draw whose principal plus the hold it books is exactly lendable is admitted, and leaves idle exactly at the hold.
    function test_AnArmedDrawExactlyAtLendableLeavesIdleAtTheHold() public {
        uint256 h = _holdOfArmed(PRINCIPAL);
        assertGt(h, MIN_DEBT, "premise: arming books a hold past the dust term");
        CuratorVault v = _seeded(PRINCIPAL + h);
        assertEq(v.lendable(), PRINCIPAL + h, "premise: every unit of the fresh vault is lendable");
        uint256 loanId = _borrowOn(v, borrower, PRINCIPAL, true);
        (, bool funded) = v.rollOf(loanId);
        assertTrue(funded, "the door promised the roll");
        assertEq(v.rollHoldNow(), h, "the hold is what the probe read");
        assertEq(v.idle(), v.rollHoldNow(), "the door lent down to exactly the hold");
        assertEq(v.lendable(), 0, "and nothing is left to place");
        assertEq(ace.restingOf(ace.loanMarket(loanId)), 0, "nothing rests");
    }

    /// @notice One unit short of principal plus hold, the armed draw is refused, while the same draw unarmed fits.
    function test_AnArmedDrawOneUnitPastLendableIsRefused() public {
        uint256 h = _holdOfArmed(PRINCIPAL);
        CuratorVault v = _seeded(PRINCIPAL + h - 1);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(v), UNITS);
        vm.expectRevert(AceVaultFlows.OverLendable.selector);
        v.borrow(_req(UNITS, PRINCIPAL, MAX_TENOR, true), "", "");
        vm.stopPrank();
        assertEq(coll.balanceOf(address(v)), 0, "the refusal pulled nothing");
        uint256 loanId = _borrowOn(v, borrower, PRINCIPAL, false);
        assertTrue(ace.isLiveLoan(loanId), "CONTROL: the unarmed draw fits, so the hold's growth is what refused");
    }

    /// @notice Over a standing hold, an unarmed draw takes exactly the cash past it and not one unit more.
    function test_AnUnarmedDrawTakesExactlyTheCashPastTheHold() public {
        uint256 h = _holdOfArmed(PRINCIPAL);
        CuratorVault v = _seeded(PRINCIPAL + h);
        _borrowOn(v, borrower, PRINCIPAL, true);
        uint256 more = 500e6;
        usdc.mint(lp2, more);
        vm.startPrank(lp2);
        usdc.approve(address(v), more);
        v.deposit(more, lp2);
        vm.stopPrank();
        assertEq(v.lendable(), more, "premise: lendable is exactly the cash past the hold");
        uint256 snap = vm.snapshotState();
        coll.mint(bob, UNITS);
        vm.startPrank(bob);
        coll.approve(address(v), UNITS);
        vm.expectRevert(AceVaultFlows.OverLendable.selector);
        v.borrow(_req(UNITS, more + 1, MAX_TENOR, false), "", "");
        vm.stopPrank();
        vm.revertToState(snap);
        _borrowOn(v, bob, more, false);
        assertEq(v.idle(), v.rollHoldNow(), "the draw left idle exactly at the hold");
    }

    // ---- the market's cash cap ----

    /// @notice A vault holding more than a market can rest still lends: the rest stops at the market's cash cap, and every unit comes home.
    function test_AVaultPastTheMarketsCashCapStillLends() public {
        deal(address(usdc), address(vault), uint256(type(uint128).max) + LP_CASH);
        uint256 idle0 = vault.idle();
        uint256 loanId = _borrow(MIN_TENOR, false);
        assertEq(vault.idle(), idle0 - PRINCIPAL, "idle fell by the principal alone: the unrested tail and the rest both came home");
        _assertNothingRests(_mid(loanId));
        _assertNoAllowances();
    }

    /// @notice The same for a promised roll: past the cash cap the roll runs and nothing rests after it.
    function test_ARollPastTheMarketsCashCapStillRuns() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        _toWindow(loanId);
        deal(address(usdc), address(vault), uint256(type(uint128).max) + LP_CASH);
        uint256 idle0 = vault.idle();
        uint256 debt = ace.debtOf(loanId);
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "the roll ran");
        assertEq(vault.idle(), idle0 - (ace.debtOf(newId) - debt), "idle fell by the fresh draw alone");
        _assertNothingRests(_mid(newId));
        _assertNoAllowances();
    }

    // ---- the dust band, at both of its open ends ----

    /// @dev Set idle to `rr + over` with the armed loan in its window, then roll: true where it ran, the revert data where it did not.
    function _rollAt(uint256 loanId, uint256 rr, uint256 over) internal returns (bool ran, bytes memory why) {
        deal(address(usdc), address(vault), rr + over);
        try vault.roll(loanId, "") returns (uint256 newId) {
            ran = ace.isLiveLoan(newId);
        } catch (bytes memory e) {
            why = e;
        }
    }

    /// @notice Idle exactly at the market's reservations, or a whole minDebt past them, rolls; one atom past, or one short of minDebt past, is the dust band.
    function test_TheDustBandIsOpenAtBothEnds() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        _toWindow(loanId);
        uint256 rr = read.rollReserve(_mid(loanId));
        assertGt(rr, 1, "premise: the loan holds a reservation");
        uint256[4] memory over = [uint256(0), 1, MIN_DEBT - 1, MIN_DEBT];
        bool[4] memory runs = [true, false, false, true];
        for (uint256 i; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            (bool ran, bytes memory why) = _rollAt(loanId, rr, over[i]);
            if (runs[i]) {
                assertTrue(ran, "an end of the band rolls");
                _assertNothingRests(_mid(loanId));
            } else {
                assertEq(bytes4(why), BelowMinLot.selector, "inside the band the rest is refused as a dust lot");
            }
            vm.revertToState(snap);
        }
    }

    // ---- a closed loan's roll ----

    /// @notice A promised loan repaid in full is refused `LoanClosed` before any cash rests, and its record stands for a crank.
    function test_ARepaidPromisedLoanIsRefusedBeforeAnyRest() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        uint256 need = _need(loanId);
        _repayAs(borrower, loanId, ace.debtOf(loanId));
        _toWindow(loanId);
        uint256 idle0 = vault.idle();
        vm.expectCall(address(ace), abi.encodeWithSelector(ace.deposit.selector), 0);
        vm.expectRevert(LoanClosed.selector);
        vault.roll(loanId, "");
        assertEq(_need(loanId), need, "the record stands until a crank names the closed loan");
        assertEq(vault.idle(), idle0, "and no cash moved");
    }

    /// @notice A promised loan the hub's fold settled at expiry is refused by the same name.
    function test_AFoldedPromisedLoanIsRefusedLoanClosed() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        _warpAtLeastTo(_expiry(loanId));
        vm.prank(stranger);
        ace.forceClose(loanId);
        vm.expectRevert(LoanClosed.selector);
        vault.roll(loanId, "");
    }

    // ---- the claim against the roll hold ----

    /// @notice A claim one share-worth past `maxClaim` is refused as an over-redeem though idle covers it: only the roll hold stands in its way.
    function test_AClaimPastExitableIsRefusedWhereIdleCoversIt() public {
        _borrow(MAX_TENOR, true);
        uint256 hold = vault.rollHoldNow();
        vm.startPrank(alice);
        vault.requestExit(vault.balanceOf(alice));
        vm.stopPrank();
        uint256 m = vault.maxClaim(alice);
        uint256 over = m + vault.convertToShares(2);
        (uint256 req,) = vault.requestOf(alice);
        assertLt(over, req, "premise: exitable binds, so the over-claim is inside the request");
        assertLt(vault.previewRedeem(over), vault.idle(), "premise: idle alone would cover the over-claim");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, over, m));
        vault.claimExit(over, alice, 0);
        vm.prank(alice);
        vault.claimExit(m, alice, 0);
        assertGe(vault.idle(), hold, "law: the claim left the roll hold standing");
        assertLe(vault.idle() - hold, 2, "and took exitable to the atom");
    }

    // ---- CuratorVault's own legs at their edges ----

    /// @notice The price leg admits a record exactly at the market's price: the roll runs, and `wouldLend` agrees on both sides of it.
    function test_ARecordExactlyAtThePriceStillRolls() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        MarketParams memory mp = _mp(loanId);
        _toWindow(loanId);
        record.setMinPrice(mp.price - 1);
        (bool price,) = vault.wouldLend(_mid(loanId));
        assertFalse(price, "CONTROL: one atom under, the vault would not lend");
        record.setMinPrice(mp.price);
        (bool p2, bool rearm) = vault.wouldLend(_mid(loanId));
        assertTrue(p2 && rearm, "at the price both legs answer yes");
        uint256 newId = vault.roll(loanId, "");
        assertTrue(ace.isLiveLoan(newId), "and the roll runs");
    }

    /// @notice A request naming no tenor opens at the row's shortest, and an armed one arms at it.
    function test_AZeroTenorTakesTheRowsShortest() public {
        uint256 loanId = _borrowAs(borrower, UNITS, PRINCIPAL, 0, true);
        assertEq(read.loan(loanId).tenor, MIN_TENOR, "the loan runs the row's shortest term");
        (uint64 armed,,) = read.autoPolicyOf(loanId);
        assertEq(armed, MIN_TENOR, "and its roll is armed at it");
    }

    /// @notice A record answering nothing, or a price the buffer drops under the grid, is refused `PriceZero` before anything moves.
    function test_NoPriceIsRefusedByName() public {
        uint256[2] memory mins = [uint256(0), 1];
        for (uint256 i; i < 2; i++) {
            record.setMinPrice(mins[i]);
            coll.mint(bob, UNITS);
            vm.startPrank(bob);
            coll.approve(address(vault), UNITS);
            vm.expectRevert(CuratorVault.PriceZero.selector);
            vault.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR, false), "", "");
            vm.stopPrank();
        }
        assertEq(coll.balanceOf(address(vault)), 0, "nothing was pulled");
    }
}
