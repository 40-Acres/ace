// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {BorrowRequest} from "../../src/curator/AceVaultFlows.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title CuratorVaultRollVeto
/// @notice THE VETO'S ABSENCE: the curator can no longer refuse an armed roll. Its legs gate only whether the SUCCESSOR's next roll is promised.
/// @notice Inside the window anyone runs the vault's `roll`; with the curator's legs closed it still rolls, and the successor is left unfunded.
/// @notice That unfunded successor is one tenor's notice, read off `rollOf`, rather than an ambush at expiry.
/// @dev Past expiry a promised loan nobody rolled is the hub fold's to settle, open to anyone; the settle branch pays the vault the buffer.
contract CuratorVaultRollVetoTest is CuratorVaultBase {
    uint256 internal constant SEED = 500_000e6;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant BIG = 200_000e18; // enough collateral that the draw fits the door's price at the coverage multiple
    uint256 internal constant UNIT_SCALE = 1 << 96;
    uint256 internal FLOOR; // the record's windowed minimum, 10% over par, never moving

    address internal stranger = address(0x5717);

    function setUp() public override {
        super.setUp();
        vaultMinPrice = AceFixtures.px(1.1e18, address(usdc), address(collateral));
        FLOOR = vaultMinPrice;
    }

    /// @dev The big loan, opened through the door ARMED, so the vault records its roll.
    function _openBig(CuratorVault v) internal returns (uint256 loanId) {
        collateral.mint(borrower, BIG);
        vm.startPrank(borrower);
        collateral.approve(address(v), BIG);
        BorrowRequest memory r = _request(address(collateral), BIG, P);
        r.arm = true;
        loanId = v.borrow(r, "", "");
        vm.stopPrank();
    }

    function _value(uint256 units) internal view returns (uint256) {
        return (units * FLOOR) / UNIT_SCALE;
    }

    function _lpValue(CuratorVault v, address who) internal view returns (uint256) {
        return v.convertToAssets(v.balanceOf(who));
    }

    /// @dev Both branches are read at the SAME clock: one vest window past the roll, then a fee collection.
    function _settleClock(CuratorVault v) internal {
        _warpBy(VEST_W + 1);
        v.collectFee();
    }

    struct Side {
        uint256 nav;
        uint256 curatorValue;
        uint256 aliceValue;
        uint256 borrowerEquity;
        bool successorFunded;
    }

    /// @dev The vault with a fee, an LP, the armed loan, the open's gain vested and collected, and the clock an hour before expiry.
    function _armedInTheWindow(uint16 fee) internal returns (CuratorVault v, uint256 loanId) {
        v = _newVault(fee);
        _lpDeposit(v, alice, SEED);
        loanId = _openBig(v);
        v.crank();
        _warpBy(VEST_W + 1);
        v.collectFee();
        _warpAtLeastTo(uint256(read.loan(loanId).expiry) - 1 hours);
    }

    /// @notice THE PRIZE IS GONE: a curator leg before the roll changes nothing the roll pays. Every branch rolls, to the wei.
    /// @notice What the legs change is the successor: promised with the legs open, unfunded after a cap of zero or the drain.
    function test_Veto_TheCuratorCanNoLongerRefuseAnArmedRoll() public {
        (CuratorVault v, uint256 loanId) = _armedInTheWindow(2000); // a 20% performance fee
        (bool price, bool rearm) = v.wouldLend(mid);
        assertTrue(price && rearm, "fixture: with the legs open, the vault lends at the price and promises the next roll");

        uint256 root = vm.snapshotState();
        Side memory a = _roll(v, loanId);
        vm.revertToState(root);
        vm.prank(curator);
        v.submitCap(address(collateral), 0);
        (price, rearm) = v.wouldLend(mid);
        assertTrue(price && !rearm, "B: a cap of zero leaves the price leg and drops the promise");
        Side memory b = _roll(v, loanId);
        vm.revertToState(root);
        vm.prank(curator);
        v.setDrain(true);
        Side memory c = _roll(v, loanId);

        emit log_named_decimal_uint("A  vault NAV, legs open        (USDC)", a.nav, 6);
        emit log_named_decimal_uint("B  vault NAV, cap of zero      (USDC)", b.nav, 6);
        emit log_named_decimal_uint("C  vault NAV, draining         (USDC)", c.nav, 6);

        Side[2] memory closed = [b, c];
        for (uint256 i; i < 2; ++i) {
            assertEq(closed[i].nav, a.nav, "the leg buys the vault nothing: NAV is the open branch's to the wei");
            assertEq(closed[i].curatorValue, a.curatorValue, "nor the curator's fee");
            assertEq(closed[i].aliceValue, a.aliceValue, "nor any LP's stake");
            assertEq(closed[i].borrowerEquity, a.borrowerEquity, "and the borrower loses nothing to it");
            assertFalse(closed[i].successorFunded, "with a leg closed, the successor's next roll is not promised");
        }
        assertTrue(a.successorFunded, "A: with the legs open, the successor's next roll is promised");
    }

    /// @dev The vault's roll, run by a keeper inside the window, then the credit cranked home and the clock settled.
    function _roll(CuratorVault v, uint256 loanId) internal returns (Side memory s) {
        (uint128 old,) = v.rollOf(loanId);
        assertEq(v.rollHold(), old, "PREMISE: the armed loan is the hold's only record");
        vm.prank(keeper);
        uint256 rolledId = v.roll(loanId, "");
        assertEq(read.debtOf(loanId), 0, "the roll retired the old debt");
        (uint128 need, bool funded) = v.rollOf(rolledId);
        (uint128 left,) = v.rollOf(loanId);
        assertGt(need, 0, "the hub armed the successor, so the vault records its need");
        assertEq(left, 0, "the roll dropped the old record");
        assertEq(v.rollHold(), need, "and the hold moved from the old record to the new, promised or not");
        s.successorFunded = funded;
        v.crank();
        _settleClock(v);
        s.nav = v.totalAssets();
        s.curatorValue = _lpValue(v, curator);
        s.aliceValue = _lpValue(v, alice);
        s.borrowerEquity = _value(read.loan(rolledId).collateralUnits) - read.debtOf(rolledId);
    }

    /// @notice THE BORROWER'S SIDE: the curator's legs cannot stop the armed roll, and they never block the borrower's own exit.
    /// @notice Nothing of the vault's rests between calls, so a fresh hub draw against its market finds no cash at any hour.
    /// @notice A migration to another lender's funded market lands and repays the vault; the vault's record stays until a crank prunes it.
    /// @notice A stranger's direct policy refinance finds no cash either, while a stranger's vault `roll` after the legs close still lands.
    function test_Veto_AnArmedRollSurvivesTheCuratorsRecall() public {
        (CuratorVault v, uint256 loanId) = _armedInTheWindow(0);
        uint64 tenor = ace.idToMarketParams(mid).minTenor;

        vm.prank(borrower);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinance(loanId, P + 1_000e6, tenor, OpenBounds(0, 0, 0));

        uint256 snap = vm.snapshotState();
        bytes32 usdcMarket = _marketLike(20e6, stranger);
        _lendDirectIn(stranger, usdcMarket, SEED); // its ONE lender: sole tenancy refuses anybody else's cash
        uint256 idle0 = v.idle();
        vm.prank(borrower);
        ace.refinanceTo(MigrateArgs(loanId, usdcMarket, P + 1_000e6, tenor, OpenBounds(0, 0, 0), 0, address(0)));
        assertTrue(ace.isClosed(loanId), "the borrower's exit to another lender is never vetoed");
        (uint128 need,) = v.rollOf(loanId);
        assertGt(need, 0, "the vault's record of the migrated loan stays");
        uint256[] memory ids = new uint256[](1);
        ids[0] = loanId;
        v.crank(ids);
        (need,) = v.rollOf(loanId);
        assertEq(need, 0, "until a crank prunes it");
        assertEq(v.rollHold(), 0, "leaving no hold");
        assertGt(v.idle(), idle0, "and the repayment came home into idle");
        vm.revertToState(snap);

        vm.prank(stranger);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinanceByPolicy(loanId);

        vm.prank(curator);
        v.submitCap(address(collateral), 0);
        vm.prank(stranger);
        uint256 newId = v.roll(loanId, "");
        assertEq(read.loan(newId).borrower, borrower, "the armed roll lands for its borrower after the curator's leg");
        assertEq(read.debtOf(loanId), 0, "and retires the old debt");
    }

    /// @notice A PROMISED LOAN NOBODY ROLLED SETTLES UNDER THE HUB'S FOLD at expiry, open to anyone, and the vault does better than rolling it.
    /// @dev The fold settles the claim and the pot sells at the hub's ask; the record's buffer under the collateral is the vault's gain over the roll.
    function test_AHubForceCloseAtExpirySettlesAPromisedLoan() public {
        (CuratorVault v, uint256 loanId) = _armedInTheWindow(0);
        uint256 root = vm.snapshotState();
        Side memory a = _roll(v, loanId);
        vm.revertToState(root);

        _warpAtLeastTo(uint256(read.loan(loanId).expiry));
        vm.prank(stranger);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the fold settled the promised loan nobody rolled");
        uint256 pot = read.invPotOf(mid, loanId);
        assertGt(pot, 0, "PREMISE: the settlement left a pot");
        _buyPot(stranger, loanId, 1_000_000e6);
        v.crank();
        _settleClock(v);
        uint256 nav = v.totalAssets();
        emit log_named_decimal_uint("rolled  vault NAV (USDC)", a.nav, 6);
        emit log_named_decimal_uint("settled vault NAV (USDC)", nav, 6);
        assertGt(nav, a.nav, "the settle branch pays the vault the buffer the roll would have left with the borrower");
    }
}
