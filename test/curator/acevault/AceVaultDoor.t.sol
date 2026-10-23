// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Borrower} from "../../../src/ace/hub/Borrower.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows, BorrowRequest} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault} from "../../../src/curator/CuratorVault.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The core borrow door: the vault opens to itself in its own market, arms while it holds the title, withdraws every unit, and hands over.
contract AceVaultDoorTest is AceVaultRig {
    /// @notice The borrower leaves with the payout and the title; the vault keeps no collateral, no title and no allowance.
    function test_BorrowPaysAndHandsTheTitleOver() public {
        uint256 loanId = _borrow(MIN_TENOR, false);
        assertEq(IERC721(ace.POSITION_TITLE()).ownerOf(loanId), borrower, "the title is the borrower's");
        uint256 fee = PRINCIPAL - usdc.balanceOf(borrower);
        assertGt(fee, 0, "premise: the open charged a fee");
        assertEq(usdc.balanceOf(borrower), PRINCIPAL - fee, "the payout reached the borrower");
        assertEq(coll.balanceOf(address(vault)), 0, "no collateral left on the vault");
        _assertNoAllowances();
        _assertNothingRests(_mid(loanId));
    }

    /// @notice The market the door built is the vault's: it names the vault as lender, the asset as quote, nobody as borrower.
    function test_TheMarketIsTheVaultsOwnShape() public {
        MarketParams memory mp = _mp(_borrow(MIN_TENOR, false));
        assertEq(mp.lender, address(vault), "the vault is the one lender");
        assertEq(mp.quote, address(usdc), "quoted in the asset, no line");
        assertEq(mp.borrower, address(0), "a market naming nobody, so a title carries its roll");
        assertEq(mp.settleBountyBps, 0, "no settle bounty on a vault market");
        assertEq(mp.deleverageBandBps, 0, "the deleverage band is off");
        assertEq(mp.fillFeeBps, 0, "no fill fee");
        assertTrue(mp.inventoryAsk, "the hub sells this vault's settled pots");
        assertEq(mp.minDebt, MIN_DEBT, "minDebt is the vault's immutable");
        assertEq(mp.minCoverageWad, COVERAGE, "coverage is the vault's immutable");
        assertEq(mp.baseBps, RATE_BPS, "the rate is the row's");
        assertEq(mp.minTenor, MIN_TENOR, "the floor term is the row's");
        assertEq(mp.maxTenor, MAX_TENOR, "the ceiling term is the row's");
    }

    /// @notice An unarmed borrow records no reservation.
    function test_AnUnarmedBorrowRecordsNothing() public {
        uint256 loanId = _borrow(MIN_TENOR, false);
        assertEq(_need(loanId), 0, "no record");
        assertEq(vault.rollHold(), 0, "no hold");
        assertEq(vault.rollHoldNow(), 0, "an empty book holds nothing");
    }

    /// @notice An armed borrow records a funded need covering the hub's reservation, and the hold is three times it plus minDebt.
    function test_AnArmedBorrowRecordsAFundedNeed() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        MarketParams memory mp = _mp(loanId);
        uint256 need = Borrower.rollNeed(mp.baseBps, mp.minTenor, mp.minDebt, PRINCIPAL, mp.maxTenor);
        assertEq(_need(loanId), need, "the record is the roll need at the market's longest term");
        assertTrue(_funded(loanId), "the door promises the first roll");
        assertGt(read.reservedOf(loanId), 0, "premise: the hub reserved the roll on paper");
        _assertRecordCovers(loanId);
        assertEq(vault.rollHold(), need, "the hold is the record's sum");
        assertEq(vault.rollHoldNow(), _holdNowOf(need), "three times the record plus minDebt");
        _assertNothingRests(_mid(loanId));
        _assertNoAllowances();
    }

    /// @notice While the drain stands the door refuses by name.
    function test_TheDrainShutsTheDoor() public {
        vm.prank(curator);
        vault.setDrain(true);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        vm.expectRevert(AceVault.Draining.selector);
        vault.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR, false), "", "");
        vm.stopPrank();
    }

    /// @notice A placement past what the holds leave lendable is refused.
    function test_APlacementPastLendableIsRefused() public {
        uint256 lend = vault.lendable();
        uint256 units = 10 * UNITS * (lend / PRINCIPAL + 1);
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(vault), units);
        vm.expectRevert(AceVaultFlows.OverLendable.selector);
        vault.borrow(_req(units, lend + 1, MIN_TENOR, false), "", "");
        vm.stopPrank();
    }

    /// @notice Arming grows the hold, and the growth counts in the placement: a draw that fits unarmed can be refused armed.
    function test_ArmGrowthCountsInThePlacement() public {
        uint256 shares = vault.convertToShares(LP_CASH - 1_050e6);
        vm.prank(alice);
        vault.requestExit(shares);
        uint256 lend = vault.lendable();
        assertLt(lend, 1_100e6, "premise: the request holds all but a thin slice");
        uint256 p = lend - 30e6;
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        vm.expectRevert(AceVaultFlows.OverLendable.selector);
        vault.borrow(_req(UNITS, p, MAX_TENOR, true), "", "");
        vm.stopPrank();
        uint256 loanId = _borrowAs(borrower, UNITS, p, MAX_TENOR, false);
        assertGt(loanId, 0, "the same draw unarmed fits");
    }

    /// @notice A bystander creating the door's exact market first blocks nothing: the next borrow lands in it.
    function test_ABystandersMarketIsTheDoorsMarket() public {
        vm.prank(borrower);
        (bytes32 id, MarketParams memory mp,) = vault.previewTerms(_req(UNITS, PRINCIPAL, MIN_TENOR, false), "");
        vm.prank(stranger);
        assertEq(ace.createMarket(mp), id, "premise: the bystander made the door's market");
        uint256 loanId = _borrow(MIN_TENOR, false);
        assertEq(_mid(loanId), id, "the borrow landed in it");
    }

    /// @notice `previewTerms` names the market a borrow lands in, before the borrow.
    function test_PreviewTermsNamesTheMarket() public {
        vm.prank(borrower);
        (bytes32 id,,) = vault.previewTerms(_req(UNITS, PRINCIPAL, MIN_TENOR, false), "");
        assertEq(_mid(_borrow(MIN_TENOR, false)), id, "the preview's id is the borrow's market");
    }

    /// @notice A collateral the vault has not listed is refused by name, before anything moves.
    function test_AnUnlistedCollateralIsRefused() public {
        MockStakeVault other = new MockStakeVault(7);
        other.mint(borrower, UNITS);
        BorrowRequest memory r = _req(UNITS, PRINCIPAL, MIN_TENOR, false);
        r.collateral = address(other);
        vm.startPrank(borrower);
        other.approve(address(vault), UNITS);
        vm.expectRevert(CuratorVault.NotListed.selector);
        vault.borrow(r, "", "");
        vm.stopPrank();
        assertEq(other.balanceOf(borrower), UNITS, "nothing was pulled");
    }
}
