// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NoInventoryAsk} from "../../../src/ace/hub/Ace.sol";
import {NotSettleable} from "../../../src/ace/hub/Settlement.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {ProductConfig} from "../../../src/curator/libraries/AceVaultCaps.sol";
import {PriceGrid} from "../../../src/curator/libraries/PriceGrid.sol";
import {CuratorTerms, CuratorTermsConfig, Listing, Row} from "../../../src/entities/curated/CuratorTerms.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {IDoorSaleCallback} from "../../../src/interfaces/IDoorSaleCallback.sol";
import {IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @dev A buyer that pays a fixed figure for whatever the door hands it.
contract PayingBuyer is IDoorSaleCallback {
    MockERC20 internal immutable CASH;
    uint256 internal immutable PAYS;

    constructor(MockERC20 cash, uint256 pays) {
        (CASH, PAYS) = (cash, pays);
    }

    function onDoorSale(address, uint256, uint256, bytes calldata) external returns (uint256) {
        CASH.mint(address(this), PAYS);
        CASH.approve(msg.sender, PAYS);
        return PAYS;
    }
}

/// @title CuratorTermsInKindTest
/// @notice CuratorTerms beside an in-kind AceVault: record-priced rows and no signer, every default paid home in kind to the shares that carried it.
/// @notice The record reads two quote per collateral and the row lends a tenth under it; setUp leaves alice the only tracked holder.
contract CuratorTermsInKindTest is AceVaultBaseRig {
    uint256 internal constant MIN_P = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint64 internal constant ROW_LOCK = 3 days;
    uint16 internal constant BUFFER_BPS = 1000;
    uint16 internal constant RATE_BPS = 40;
    uint192 internal constant ROW_CAP = 100_000e6;
    uint256 internal constant AMOUNT = 200e6;
    uint256 internal constant Q96 = 1 << 96;

    CuratorTerms internal ct;
    IAceVaultDoor internal dv;
    IERC721 internal titles;

    function setUp() public override {
        super.setUp();
        (vault, ct) = _deployInKind(RAIL_MAX);
        _lp(alice, LP_CASH);
        dv = IAceVaultDoor(address(vault));
        titles = IERC721(ace.POSITION_TITLE());
        vm.prank(borrower);
        titles.setApprovalForAll(address(vault), true);
    }

    // ---- the rig ----

    /// @dev CuratorTerms with rail `termsMax` at the address the vault's create takes, then an in-kind vault on the rig's 30-day rail naming them.
    function _deployInKind(uint64 termsMax) internal returns (AceVault v, CuratorTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        Listing[] memory l = new Listing[](1);
        Row memory w = Row({record: address(record), bufferBps: BUFFER_BPS, lenderAprBps: RATE_BPS, minTenor: TENOR, maxTenor: RAIL_MAX});
        l[0] = Listing({collateral: address(coll), row: w});
        CuratorTermsConfig memory c = CuratorTermsConfig({
            vault: predicted,
            ace: address(ace),
            asset: address(usdc),
            minPrincipal: MIN_P,
            coverageWad: COVERAGE,
            timelock: ROW_LOCK,
            minTenor: RAIL_MIN,
            maxTenor: termsMax
        });
        t = new CuratorTerms(c, l);
        ProductConfig memory pc = _pc();
        (pc.terms, pc.inKind) = (address(t), true);
        VaultSeed.fund(_cfg(), predicted);
        v = new AceVault(_cfg(), pc, _listing(predicted, _caps(ROW_CAP, 0, UNCAPPED)), "Curated in kind", "ckVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    function _tokens() internal view returns (address[] memory a) {
        a = new address[](1);
        a[0] = address(coll);
    }

    function _marketOf(uint256 loanId) internal view returns (MarketParams memory) {
        return ace.idToMarketParams(ace.loanMarket(loanId));
    }

    /// @dev A loan at the row's longest term, so a top-up and a refinance have time left.
    function _longLoan() internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        loanId = vault.borrow(_req(address(coll), UNITS, PRINCIPAL, RAIL_MAX), "", "");
        vm.stopPrank();
    }

    /// @dev A loan of the rig's ask, the clock past its expiry.
    function _expired() internal returns (uint256 loanId) {
        loanId = _borrow();
        _warpTo(read.loan(loanId).expiry + 1);
    }

    function _collect(uint256 loanId) internal returns (uint256) {
        vm.prank(stranger);
        return vault.collectForfeited(_ids(loanId))[0];
    }

    /// @dev Expect a one-unit deposit by bob to refuse `sel`.
    function _expectEntryShut(bytes4 sel) internal {
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(sel);
        vault.deposit(1e6, bob);
        vm.stopPrank();
    }

    // ---- the mode ----

    /// @notice An in-kind vault's curated market lends at the gridded buffered record minimum with the hub's ask off.
    function test_InKindMarketsLendAskOffAtTheBufferedMinimum() public {
        assertTrue(vault.IN_KIND(), "premise: the vault pays defaults in kind");
        assertEq(vault.DOOR(), address(0), "premise: an in-kind vault has no door");
        uint256 loanId = _borrow();
        MarketParams memory mp = _marketOf(loanId);
        assertFalse(mp.inventoryAsk, "an in-kind vault's market sells at the hub's ask");
        assertEq(mp.record, address(record), "the market does not price off the row's record");
        assertEq(mp.lender, address(vault), "the market names another lender");
        uint256 buffered = Math.mulDiv(record.minPrice(address(usdc), address(coll)), 10_000 - BUFFER_BPS, 10_000);
        assertEq(mp.price, PriceGrid.down(buffered), "the market is not at the gridded buffered minimum");
        assertEq(mp.minPrincipal, MIN_P, "the market does not carry the terms' floor ticket");
        assertEq(mp.minCoverageWad, COVERAGE, "the market does not carry the terms' coverage");
        assertEq(mp.lenderAprBps, RATE_BPS, "the market does not carry the row's rate");
        assertEq(titles.ownerOf(loanId), borrower, "the borrower does not hold the title");
        assertEq(read.debtOf(loanId), PRINCIPAL, "the loan did not draw the asked principal");
    }

    /// @notice No one buys a settled pot at the hub: the market's ask is off.
    function test_NoOneBuysASettledPotAtTheHub() public {
        uint256 loanId = _expired();
        ace.forceClose(loanId);
        uint256 pot = read.invPotOf(ace.loanMarket(loanId), loanId);
        assertGt(pot, 0, "premise: the settle left a pot at the hub");
        vm.expectRevert(NoInventoryAsk.selector);
        ace.buyInventory(loanId, 1e6, 0, stranger);
        assertEq(read.invPotOf(ace.loanMarket(loanId), loanId), pot, "the refused buy moved the pot");
    }

    // ---- the settle and the collect ----

    /// @notice A distressed loan settles inside its term only when someone calls; the pot comes home in kind and the borrower keeps the rest.
    function test_AnInTermDistressSettleComesHomeInKindAndLeavesTheBorrowerTheRest() public {
        uint256 loanId = _borrow();
        _warpBy(1 days);
        assertLt(_now(), read.loan(loanId).expiry, "premise: inside the term");
        record.setBelow(true);
        assertEq(read.loan(loanId).closedAt, 0, "a distressed loan closed with nobody calling");
        uint256 price = _marketOf(loanId).price;
        uint256 need = Math.mulDiv(read.claimOf(ace.loanMarket(loanId), loanId), Q96, price, Math.Rounding.Ceil);
        uint256 line = Math.mulDiv(COVERAGE * read.debtOf(loanId), Q96, price * 1e18, Math.Rounding.Ceil) + 1;
        uint256 take = Math.min(line, Math.mulDiv(UNITS, 1e18, COVERAGE, Math.Rounding.Ceil));
        assertGt(take, need, "premise: the in-term take exceeds the need, so it tells the two takes apart");
        uint256 units = _collect(loanId);
        record.setBelow(false);
        assertEq(uint256(read.loan(loanId).closedAt), _now(), "the collect did not settle the distressed loan now");
        uint256 left = read.unitsOwedOf(loanId, borrower);
        assertEq(units, take, "the in-term take is not the coverage line capped at the lot over k");
        assertGt(left, 0, "an in-term settle took the borrower's whole pledge");
        assertEq(units + left, UNITS, "the pot and the borrower's credit do not sum to the pledge");
        assertEq(read.invPotOf(ace.loanMarket(loanId), loanId), 0, "part of the pot stayed at the hub");
        assertEq(coll.balanceOf(address(vault)), units, "the pot did not land at the vault");
        vm.roll(block.number + 1);
        assertEq(vlens.claimable(address(vault), alice, address(coll)), units, "the sole holder is not credited the whole pot");
        vm.prank(alice);
        vault.claim(_tokens(), alice);
        assertEq(coll.balanceOf(alice), units, "the claim did not pay the pot");
    }

    /// @notice From expiry the vault takes exactly the claim's need, rounded up, and the borrower is credited the rest.
    function test_AnExpiredLoanComesHomeAtTheNeed() public {
        uint256 loanId = _expired();
        bytes32 id = ace.loanMarket(loanId);
        uint256 need = Math.mulDiv(read.claimOf(id, loanId), Q96, _marketOf(loanId).price, Math.Rounding.Ceil);
        uint256 units = _collect(loanId);
        assertEq(units, need, "the expiry take is not the claim's need");
        assertLt(units, UNITS, "premise: the pledge covers more than the need");
        assertEq(read.unitsOwedOf(loanId, borrower), UNITS - units, "the borrower is not credited what the need left");
    }

    /// @notice A batch naming a distress-settleable loan and a live healthy one reverts whole, at the vault and through the terms; the first settles alone.
    function test_AMixedBatchWithALiveHealthyLoanRevertsWhole() public {
        uint256 sick = _borrow();
        uint256 well = _borrowAs(borrower, address(coll), UNITS, MIN_P * 10);
        uint256 trigWell = read.triggerPrice(well);
        assertGt(read.triggerPrice(sick), trigWell, "premise: the heavier loan triggers higher");
        record.setBandPrice(trigWell);
        assertTrue(read.settleable(sick), "premise: the heavier loan is settleable on distress");
        assertFalse(read.settleable(well), "premise: the lighter loan is healthy");
        assertLt(_now(), read.loan(well).expiry, "premise: the healthy loan is inside its term");
        uint256[] memory both = new uint256[](2);
        (both[0], both[1]) = (sick, well);
        vm.prank(stranger);
        vm.expectRevert(NotSettleable.selector);
        vault.collectForfeited(both);
        vm.prank(stranger);
        vm.expectRevert(NotSettleable.selector);
        ct.collectForfeited(both);
        assertEq(read.loan(sick).closedAt, 0, "the reverted batch left the settleable loan closed");
        assertEq(coll.balanceOf(address(vault)), 0, "the reverted batch brought something home");
        assertGt(_collect(sick), 0, "the settleable loan did not come home alone");
        assertEq(read.loan(well).closedAt, 0, "collecting the settleable loan closed the healthy one");
    }

    /// @notice Two tracked holders split the pot by tracked balance, each credit floored, and each claim pays exactly its credit.
    function test_TwoHoldersSplitThePotByTrackedBalance() public {
        _lp(bob, 3 * LP_CASH);
        (uint256 a, uint256 b) = (vlens.trackedOf(address(vault), alice), vlens.trackedOf(address(vault), bob));
        uint256 supply = vlens.trackedSupply(address(vault));
        assertEq(a + b, supply, "premise: alice and bob are the only tracked holders");
        assertGt(b, 2 * a, "premise: bob holds the larger stake");
        uint256 units = _collect(_expired());
        vm.roll(block.number + 1);
        uint256 ca = vlens.claimable(address(vault), alice, address(coll));
        uint256 cb = vlens.claimable(address(vault), bob, address(coll));
        assertEq(ca, Math.mulDiv(units, a, supply), "alice is not credited her tracked share of the pot");
        assertEq(cb, Math.mulDiv(units, b, supply), "bob is not credited his tracked share of the pot");
        assertLt(ca, units / 3, "the pot landed whole on one holder");
        assertLe(units - ca - cb, 1, "more than the flooring dust went uncredited");
        vm.prank(alice);
        vault.claim(_tokens(), alice);
        vm.prank(bob);
        vault.claim(_tokens(), bob);
        assertEq(coll.balanceOf(alice), ca, "alice's claim did not pay her credit");
        assertEq(coll.balanceOf(bob), cb, "bob's claim did not pay his credit");
        assertEq(coll.balanceOf(address(vault)), units - ca - cb, "the claims paid out other than the credits");
    }

    /// @notice The settle retires the loan's lent principal, less the fee escrow it earns, and the collect values the pot at nothing.
    function test_NavFallsAtTheSettleAndTheCollectAddsNothing() public {
        uint256 loanId = _borrow();
        _warpTo(read.loan(loanId).expiry);
        uint256 escrow = read.feeEscrowOf(loanId);
        uint256 before = vault.grossNav();
        ace.forceClose(loanId);
        uint256 settled = vault.grossNav();
        assertEq(before - settled, PRINCIPAL - escrow, "the settle moved NAV by other than the claim it retired less its earned escrow");
        uint256 units = _collect(loanId);
        assertGt(units, 0, "premise: the pot came home");
        assertEq(vault.grossNav(), settled, "the collect valued the seized pot");
    }

    /// @notice Entry waits while a settled pot sits at the hub and through the collect's block, and opens the block after.
    function test_EntryWaitsWhileThePotIsAtTheHubAndThroughTheCollectBlock() public {
        uint256 loanId = _expired();
        ace.forceClose(loanId);
        _expectEntryShut(AceVault.InventoryUnsold.selector);
        _collect(loanId);
        _expectEntryShut(AceVault.InventoryUnsold.selector);
        vm.roll(block.number + 1);
        assertGt(_lp(bob, 1e6), 0, "entry stayed shut after the pot came home");
    }

    /// @notice The row's room holds a pot unsold at the hub at the record's minimum, and frees it once the pot comes home.
    function test_RoomHoldsAnUnsoldPotUntilItComesHome() public {
        uint256 loanId = _expired();
        ace.forceClose(loanId);
        MarketParams memory mp = _marketOf(loanId);
        uint256 pot = read.invPotOf(ace.loanMarket(loanId), loanId);
        uint256 parked = Math.mulDiv(pot, record.minPrice(address(usdc), address(coll)), Q96);
        assertEq(ct.room(mp), ROW_CAP - parked, "the room does not hold the unsold pot at the record's minimum");
        _collect(loanId);
        assertEq(ct.room(mp), type(uint256).max, "the room still holds a pot that came home");
    }

    // ---- the lending verbs beyond the borrow ----

    /// @notice An extension consents while the record's minimum covers the market's price, and not once it falls under.
    function test_ExtensionsFollowTheRecord() public {
        uint256 loanId = _borrow();
        assertEq(vault.admitsExtension(_ext(loanId), ""), IRollPolicy.admitsExtension.selector, "the record over the price refused the extension");
        uint256 price = _marketOf(loanId).price;
        record.setMinPrice(price);
        assertEq(vault.admitsExtension(_ext(loanId), ""), IRollPolicy.admitsExtension.selector, "a record exactly at the price refused the extension");
        record.setMinPrice(price - 1);
        assertEq(vault.admitsExtension(_ext(loanId), ""), bytes4(0), "a record under the price consented");
    }

    /// @notice A top-up and a refinance land in kind and move no tracked share.
    function test_TopUpAndRefinanceMoveNoTrackedShare() public {
        uint256 loanId = _longLoan();
        _warpBy(1 days);
        uint256 supply = vlens.trackedSupply(address(vault));
        uint256 mine = vlens.trackedOf(address(vault), alice);
        vm.prank(borrower);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "the top-up did not land");
        vm.prank(borrower);
        (uint256 next,) = vault.refinanceFor(loanId, address(coll), PRINCIPAL + AMOUNT + 50e6, 0, 0, 0, 0, 0, address(0), "");
        assertEq(titles.ownerOf(next), borrower, "the successor's title is not the holder's");
        assertEq(ace.loanMarket(next), ace.loanMarket(loanId), "a refinance the row still names left the loan's market");
        assertGt(read.loan(loanId).closedAt, 0, "the refinanced loan is still open");
        assertEq(vlens.trackedSupply(address(vault)), supply, "a lending verb moved the tracked supply");
        assertEq(vlens.trackedOf(address(vault), alice), mine, "a lending verb moved a holder's tracked balance");
    }

    /// @notice A refinance under a fallen record leaves the loan's market for today's, at the new gridded buffered minimum, still with the ask off.
    function test_ARefinanceUnderAFallenRecordMovesToTodaysMarketAskOff() public {
        uint256 loanId = _longLoan();
        uint256 old = _marketOf(loanId).price;
        _warpBy(1 days);
        record.setMinPrice(record.minPrice(address(usdc), address(coll)) * 3 / 4);
        uint256 today = PriceGrid.down(Math.mulDiv(record.minPrice(address(usdc), address(coll)), 10_000 - BUFFER_BPS, 10_000));
        assertLt(today, old, "premise: today's buffered minimum sits under the loan's price");
        vm.prank(borrower);
        (uint256 next,) = vault.refinanceFor(loanId, address(coll), PRINCIPAL + 50e6, 0, 0, 0, 0, 0, address(0), "");
        MarketParams memory mp = _marketOf(next);
        assertTrue(ace.loanMarket(next) != ace.loanMarket(loanId), "the refinance kept the loan's market");
        assertEq(mp.price, today, "the successor is not at today's gridded buffered minimum");
        assertFalse(mp.inventoryAsk, "today's in-kind market sells at the hub's ask");
        assertEq(titles.ownerOf(next), borrower, "the successor's title is not the holder's");
    }

    // ---- the rail ----

    /// @notice CuratorTerms built on a rail longer than the in-kind vault's thirty days lend nothing beside it: `VaultMismatch`.
    function test_ATermsRailOverThirtyDaysLendsNothing() public {
        (vault, ct) = _deployInKind(365 days);
        _lp(alice, LP_CASH);
        assertEq(vault.MAX_TENOR(), RAIL_MAX, "premise: the in-kind vault's rail ends at thirty days");
        _expectBorrowRevert(address(coll), CuratorTerms.VaultMismatch.selector);
    }

    // ---- the door verbs, which an in-kind vault does not have ----

    /// @notice The terms' collect forwards to the vault's own, which brings the pot home in kind; nothing stays at the terms.
    function test_TheTermsCollectBringsThePotHomeInKind() public {
        uint256 loanId = _expired();
        uint256 need = Math.mulDiv(read.claimOf(ace.loanMarket(loanId), loanId), Q96, _marketOf(loanId).price, Math.Rounding.Ceil);
        vm.prank(stranger);
        uint256 units = ct.collectForfeited(_ids(loanId))[0];
        assertEq(units, need, "the forwarded collect did not bring home the claim's need");
        assertEq(ct.saleRecord(address(coll)), address(record), "the terms did not pin the pot's market record");
        assertEq(coll.balanceOf(address(vault)), units, "the pot did not land at the vault");
        assertEq(coll.balanceOf(address(ct)), 0, "the pot stopped at the terms");
        vm.roll(block.number + 1);
        assertEq(vlens.claimable(address(vault), alice, address(coll)), units, "the pot was not credited to the holder");
    }

    /// @notice With no door to return to, the terms' sale and cash return refuse `NotDoor`, so anything donated to the terms stays there.
    function test_TheTermsSaleAndCashReturnRefuseInKind() public {
        usdc.mint(address(ct), 5e6);
        vm.expectRevert(IAceVaultDoor.NotDoor.selector);
        ct.forwardCash();
        coll.mint(address(ct), 1e18);
        PayingBuyer buyer = new PayingBuyer(usdc, 1e6);
        vm.prank(curator);
        vm.expectRevert(IAceVaultDoor.NotDoor.selector);
        ct.sell(address(coll), 1e18, address(buyer), 0, "");
        assertEq(usdc.balanceOf(address(ct)), 5e6, "the donated cash left the terms");
        assertEq(coll.balanceOf(address(ct)), 1e18, "the donated goods left the terms");
    }
}
