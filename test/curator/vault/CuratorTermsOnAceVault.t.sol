// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {AceVaultFlows} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorTerms, CuratorTermsConfig, Listing, Row} from "../../../src/entities/curated/CuratorTerms.sol";
import {PriceGrid} from "../../../src/curator/PriceGrid.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";

/// @title CuratorTermsOnAceVaultTest
/// @notice CuratorTerms as an AceVault product: the oracle-priced row table, its rows held inside the vault's tenor rail, and a loan end to end.
/// @dev THE RAIL ROWS: a row whose tenors sit outside the vault's rail could list and never lend, so the terms refuse it at deploy and at submission.
contract CuratorTermsOnAceVaultTest is AceVaultBaseRig {
    uint256 internal constant MIN_P = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint64 internal constant ROW_LOCK = 3 days;
    uint16 internal constant BUFFER_BPS = 1000;
    uint16 internal constant RATE_BPS = 40;

    CuratorTerms internal ct;

    function setUp() public override {
        super.setUp();
        (vault, ct) = _deployCurated(_listings(_row(address(record), TENOR, RAIL_MAX)), _caps(UNCAPPED, 0, UNCAPPED));
        _lp(alice, LP_CASH);
    }

    function _row(address rec, uint64 minT, uint64 maxT) internal pure returns (Row memory) {
        return Row({record: rec, bufferBps: BUFFER_BPS, lenderAprBps: RATE_BPS, minTenor: minT, maxTenor: maxT});
    }

    function _listings(Row memory r) internal view returns (Listing[] memory l) {
        l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: r});
    }

    function _termsCfg(address v) internal view returns (CuratorTermsConfig memory) {
        return CuratorTermsConfig({
            vault: v,
            ace: address(ace),
            asset: address(usdc),
            minPrincipal: MIN_P,
            coverageWad: COVERAGE,
            timelock: ROW_LOCK,
            minTenor: RAIL_MIN,
            maxTenor: RAIL_MAX
        });
    }

    /// @dev CuratorTerms first, against the address the vault's create takes, then the vault naming them.
    function _deployCurated(Listing[] memory l, uint192[3] memory c) internal returns (AceVault v, CuratorTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new CuratorTerms(_termsCfg(predicted), l);
        VaultSeed.fund(_cfg(), predicted);
        v = new AceVault(_cfg(), _pcFor(address(t)), _listing(predicted, c), "Curated", "cVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
    }

    function _pcFor(address t) internal pure returns (ProductConfig memory pc) {
        pc = _pc();
        pc.terms = t;
    }

    // ---- N4: every row sits inside the vault's tenor rail ----

    /// @notice A row whose shortest term sits under the vault's rail is refused at deploy, so it can never list and fail to lend.
    function test_ARowUnderTheRailIsRefusedAtDeploy() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        Listing[] memory l = _listings(_row(address(record), RAIL_MIN - 1, RAIL_MAX));
        vm.expectRevert(CuratorTerms.BadRow.selector);
        new CuratorTerms(_termsCfg(predicted), l);
    }

    /// @notice A row whose longest term sits over the vault's rail is refused at submission.
    function test_ARowOverTheRailIsRefusedAtSubmission() public {
        MockStakeVault c = new MockStakeVault(42);
        MockPersistenceRecord r = _record(address(c));
        vm.prank(curator);
        vm.expectRevert(CuratorTerms.BadRow.selector);
        ct.submitCollateral(address(c), _row(address(r), TENOR, RAIL_MAX + 1));
    }

    /// @notice CONTROL: a row at both ends of the rail lists, and only the vault's curator submits one.
    function test_ARowAtTheRailsEndsLists() public {
        MockStakeVault c = new MockStakeVault(42);
        MockPersistenceRecord r = _record(address(c));
        vm.prank(stranger);
        vm.expectRevert(CuratorTerms.NotCurator.selector);
        ct.submitCollateral(address(c), _row(address(r), RAIL_MIN, RAIL_MAX));
        vm.prank(curator);
        ct.submitCollateral(address(c), _row(address(r), RAIL_MIN, RAIL_MAX));
        _warpBy(ROW_LOCK);
        ct.accept(address(c));
        assertEq(ct.rowOf(address(c)).maxTenor, RAIL_MAX, "the row at the rail's ends did not list");
    }

    // ---- a loan end to end ----

    /// @notice A borrow lands in the row's market at the record's minimum less the buffer, gridded down, lent by the vault and titled to the borrower.
    function test_ABorrowLandsAtTheGriddedBufferedMinimum() public {
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        MarketParams memory mp = ace.idToMarketParams(ace.loanMarket(loanId));
        uint256 m = record.minPrice(address(usdc), address(coll));
        assertEq(mp.price, PriceGrid.down(Math.mulDiv(m, 10_000 - BUFFER_BPS, 10_000)), "the market is not at the gridded buffered minimum");
        assertEq(mp.lender, address(vault), "the market's lender is not the vault");
        assertTrue(mp.inventoryAsk, "the market does not sell at the hub's ask");
        assertEq(IERC721(ace.POSITION_TITLE()).ownerOf(loanId), borrower, "the title is not the borrower's");
        assertEq(ace.restingOf(ace.loanMarket(loanId)), 0, "vault cash rests in the market");
    }

    /// @notice The holder extends at the hub directly while the row stands, and a row whose rate moves stops it.
    function test_TheHolderExtendsAtTheHubWhileTheRowStands() public {
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        _warpBy(1 days);
        _fundFee(borrower);
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        Loan memory l = read.loan(loanId);
        assertEq(l.expiry, _now() + l.tenor, "the holder's extension did not land");
        Row memory moved = _row(address(record), TENOR, RAIL_MAX);
        moved.lenderAprBps = RATE_BPS + 1;
        vm.prank(curator);
        ct.submitCollateral(address(coll), moved);
        _warpBy(ROW_LOCK);
        ct.accept(address(coll));
        assertEq(vault.admitsExtension(_ext(loanId), ""), bytes4(0), "a row whose rate moved still consented to the old market's extension");
    }

    /// @notice An unsold pot holds its collateral's row at the record's minimum until it sells: the terms' room only tightens the vault's.
    function test_AnUnsoldPotHoldsTheRowUntilItSells() public {
        uint192 rowCap = uint192(2 * PRINCIPAL);
        (vault, ct) = _deployCurated(_listings(_row(address(record), TENOR, RAIL_MAX)), _caps(rowCap, 0, UNCAPPED));
        _lp(alice, LP_CASH);
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        _finalize(loanId);
        (uint256 lent, uint256 unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(lent, 0, "premise: the settled loan holds no lent");
        assertGt(unsold, 0, "premise: the settled pot is unsold");
        assertGe(vlens.roomOf(address(vault), address(coll)), PRINCIPAL, "premise: the vault's own row would admit the draw");
        uint256 parked = Math.mulDiv(unsold, record.minPrice(address(usdc), address(coll)), 1 << 96);
        assertGt(parked, rowCap - PRINCIPAL, "premise: the pot at the minimum outweighs the row's spare room");
        _expectBorrowRevert(address(coll), AceVaultFlows.OverCap.selector);
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        uint256 pay = 2 * parked; // the ask floors at the record's price and rounds against the buyer; the fill stops at the pot
        usdc.mint(stranger, pay);
        vm.startPrank(stranger);
        usdc.approve(address(ace), pay);
        ace.buyInventory(loanId, pay, 0, stranger);
        vm.stopPrank();
        (, unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(unsold, 0, "premise: the sale took the whole pot");
        _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
    }
}
