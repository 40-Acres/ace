// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows, BorrowRequest} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault} from "../../../src/curator/CuratorVault.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The core borrow door: the vault opens to itself in its own market, withdraws every unit, and hands over.
contract AceVaultDoorTest is AceVaultRig {
    /// @notice The borrower leaves with the payout and the title; the vault keeps no collateral, no title and no allowance.
    function test_BorrowPaysAndHandsTheTitleOver() public {
        uint256 loanId = _borrow(MIN_TENOR);
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
        MarketParams memory mp = _mp(_borrow(MIN_TENOR));
        assertEq(mp.lender, address(vault), "the vault is the one lender");
        assertEq(mp.quote, address(usdc), "quoted in the asset, no line");
        assertEq(mp.borrower, address(0), "a market naming nobody, so a title carries its extension");
        assertEq(mp.settleBountyBps, 0, "no settle bounty on a vault market");
        assertEq(mp.deleverageBandBps, 0, "the deleverage band is off");
        assertEq(mp.fillFeeBps, 0, "no fill fee");
        assertTrue(mp.inventoryAsk, "the hub sells this vault's settled pots");
        assertEq(mp.minPrincipal, MIN_PRINCIPAL, "minPrincipal is the vault's immutable");
        assertEq(mp.minCoverageWad, COVERAGE, "coverage is the vault's immutable");
        assertEq(mp.baseBps, RATE_BPS, "the rate is the row's");
        assertEq(mp.minTenor, MIN_TENOR, "the floor term is the row's");
        assertEq(mp.maxTenor, MAX_TENOR, "the ceiling term is the row's");
    }

    /// @notice A borrow holds no idle back beyond its principal: an extension draws none, so nothing is kept for one.
    function test_ABorrowHoldsNoIdleBack() public {
        uint256 idle0 = vault.idle();
        uint256 loanId = _borrow(MIN_TENOR);
        assertEq(vault.idle(), idle0 - PRINCIPAL, "idle fell by the principal alone");
        assertEq(vault.lendable(), vault.idle(), "and lendable is all of idle");
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
        vault.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR), "", "");
        vm.stopPrank();
    }

    /// @notice A placement past what the requests' hold leaves lendable is refused.
    function test_APlacementPastLendableIsRefused() public {
        uint256 lend = vault.lendable();
        uint256 units = 10 * UNITS * (lend / PRINCIPAL + 1);
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(vault), units);
        vm.expectRevert(AceVaultFlows.OverLendable.selector);
        vault.borrow(_req(units, lend + 1, MIN_TENOR), "", "");
        vm.stopPrank();
    }

    /// @notice A bystander creating the door's exact market first blocks nothing: the next borrow lands in it.
    function test_ABystandersMarketIsTheDoorsMarket() public {
        vm.prank(borrower);
        (bytes32 id, MarketParams memory mp,) = vault.previewTerms(_req(UNITS, PRINCIPAL, MIN_TENOR), "");
        vm.prank(stranger);
        assertEq(ace.createMarket(mp), id, "premise: the bystander made the door's market");
        uint256 loanId = _borrow(MIN_TENOR);
        assertEq(_mid(loanId), id, "the borrow landed in it");
    }

    /// @notice `previewTerms` names the market a borrow lands in, before the borrow.
    function test_PreviewTermsNamesTheMarket() public {
        vm.prank(borrower);
        (bytes32 id,,) = vault.previewTerms(_req(UNITS, PRINCIPAL, MIN_TENOR), "");
        assertEq(_mid(_borrow(MIN_TENOR)), id, "the preview's id is the borrow's market");
    }

    /// @notice A collateral the vault has not listed is refused by name, before anything moves.
    function test_AnUnlistedCollateralIsRefused() public {
        MockStakeVault other = new MockStakeVault(7);
        other.mint(borrower, UNITS);
        BorrowRequest memory r = _req(UNITS, PRINCIPAL, MIN_TENOR);
        r.collateral = address(other);
        vm.startPrank(borrower);
        other.approve(address(vault), UNITS);
        vm.expectRevert(CuratorVault.NotListed.selector);
        vault.borrow(r, "", "");
        vm.stopPrank();
        assertEq(other.balanceOf(borrower), UNITS, "nothing was pulled");
    }
}
