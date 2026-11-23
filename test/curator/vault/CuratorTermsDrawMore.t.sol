// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {CuratorTerms, CuratorTermsConfig, Listing, Row} from "../../../src/vault/curated/CuratorTerms.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {RefinanceRequest} from "../../../src/interfaces/IVaultTerms.sol";
import {IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";

/// @title CuratorTermsDrawMoreTest
/// @notice CuratorTerms prices a refinance in the loan's own market while its row names it and today's buffered minimum covers its price.
/// @notice Otherwise it prices today's market, as a borrow does; a vault top-up lands only on the first answer, a vault refinance on either.
contract CuratorTermsDrawMoreTest is AceVaultBaseRig {
    uint256 internal constant MIN_P = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint64 internal constant ROW_LOCK = 3 days;
    uint16 internal constant BUFFER_BPS = 1000;
    uint16 internal constant RATE_BPS = 40;
    uint256 internal constant AMOUNT = 200e6;

    CuratorTerms internal ct;
    IAceVaultDoor internal dv;
    IERC721 internal titles;

    function setUp() public override {
        super.setUp();
        (vault, ct) = _deployCurated();
        _lp(alice, LP_CASH);
        dv = IAceVaultDoor(address(vault));
        titles = IERC721(ace.POSITION_TITLE());
        vm.prank(borrower);
        titles.setApprovalForAll(address(vault), true);
    }

    function _row(uint16 bufferBps, uint16 rateBps) internal view returns (Row memory) {
        return Row({record: address(record), bufferBps: bufferBps, lenderAprBps: rateBps, minTenor: TENOR, maxTenor: RAIL_MAX});
    }

    /// @dev CuratorTerms first, against the address the vault's create takes, then the vault naming them.
    function _deployCurated() internal returns (AceVault v, CuratorTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: _row(BUFFER_BPS, RATE_BPS)});
        CuratorTermsConfig memory c = CuratorTermsConfig({
            vault: predicted,
            ace: address(ace),
            asset: address(usdc),
            minPrincipal: MIN_P,
            coverageWad: COVERAGE,
            timelock: ROW_LOCK,
            minTenor: RAIL_MIN,
            maxTenor: RAIL_MAX
        });
        t = new CuratorTerms(c, l);
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        VaultSeed.fund(_cfg(), predicted);
        v = new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Curated", "cVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
    }

    /// @dev A loan to the borrower through the vault at the row's longest term, so a top-up has time left.
    function _loan() internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        loanId = vault.borrow(_req(address(coll), UNITS, PRINCIPAL, RAIL_MAX), "", "");
        vm.stopPrank();
    }

    /// @dev Put `w` live for the rig collateral after the timelock.
    function _setRow(Row memory w) internal {
        vm.prank(curator);
        ct.submitCollateral(address(coll), w);
        _warpBy(ROW_LOCK);
        ct.accept(address(coll));
    }

    function _top(uint256 loanId) internal {
        vm.prank(borrower);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
    }

    function _topRefused(uint256 loanId) internal {
        vm.prank(borrower);
        vm.expectRevert(IAceVaultDoor.TopUpRefused.selector);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
    }

    function _marketOf(uint256 loanId) internal view returns (MarketParams memory) {
        return ace.idToMarketParams(ace.loanMarket(loanId));
    }

    function _todays() internal view returns (MarketParams memory mp) {
        (mp,) = ct.borrowTerms(borrower, _req(address(coll), UNITS, PRINCIPAL, 0), "");
    }

    function _refiAsk(uint256 principal) internal view returns (RefinanceRequest memory) {
        return RefinanceRequest(address(coll), principal, 0, 0, 0, 0, 0, address(0));
    }

    function _same(MarketParams memory a, MarketParams memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    // ---- the answer ----

    /// @notice The answer is the loan's own market while it qualifies, at the asked principal and the row's shortest term; today's once it does not.
    function test_TheAnswerIsTheOwnMarketWhileItQualifies_TodaysAfter() public {
        uint256 loanId = _loan();
        MarketParams memory src = _marketOf(loanId);
        (MarketParams memory mp, Terms memory t) = ct.refinanceTerms(borrower, loanId, _refiAsk(PRINCIPAL + AMOUNT), "");
        assertTrue(_same(mp, src), "the answer is not the loan's own market while it qualifies");
        assertEq(t.principal, PRINCIPAL + AMOUNT, "the answer did not take the asked principal");
        assertEq(t.tenor, TENOR, "a zero term did not take the row's shortest");
        _setRow(_row(2000, RATE_BPS));
        (mp,) = ct.refinanceTerms(borrower, loanId, _refiAsk(PRINCIPAL + AMOUNT), "");
        assertFalse(_same(mp, src), "the answer stayed the loan's market past a buffer raise");
        assertTrue(_same(mp, _todays()), "the answer is not today's market as a borrow prices it");
    }

    // ---- the top-up ----

    /// @notice A Curator loan tops up in its own market while it qualifies: the debt carries the amount, the market and the term hold.
    function test_ACuratorLoanTopsUpInItsOwnMarket() public {
        uint256 loanId = _loan();
        _warpBy(1 days);
        bytes32 market = ace.loanMarket(loanId);
        uint64 expiry = read.loan(loanId).expiry;
        _top(loanId);
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "the debt does not carry the top-up");
        assertEq(ace.loanMarket(loanId), market, "the top-up moved the loan's market");
        assertEq(read.loan(loanId).expiry, expiry, "the top-up moved the expiry");
    }

    /// @notice A row whose rate moved names the old market no more: a top-up refuses `TopUpRefused`.
    function test_ARowWhoseRateMovedStopsATopUp() public {
        uint256 loanId = _loan();
        _setRow(_row(BUFFER_BPS, RATE_BPS + 1));
        _topRefused(loanId);
    }

    /// @notice A buffer raise puts the old market over today's buffered minimum and stops a top-up; a later cut under it lets one land.
    function test_ABufferRaiseStopsATopUp_ABufferCutKeepsIt() public {
        uint256 loanId = _loan();
        _setRow(_row(2000, RATE_BPS));
        _topRefused(loanId);
        _setRow(_row(500, RATE_BPS));
        _top(loanId);
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "CONTROL: under a cut buffer the old market tops up");
    }

    /// @notice A record fall that leaves the minimum at the price but its buffered line under it stops a top-up while extensions still consent.
    function test_ARecordFallUnderTheBufferedLineStopsATopUpNotAnExtension() public {
        uint256 loanId = _loan();
        _warpBy(1 days);
        record.setMinPrice(_marketOf(loanId).price);
        _topRefused(loanId);
        assertEq(vault.admitsExtension(_ext(loanId), ""), IRollPolicy.admitsExtension.selector, "the record at the price stopped the extension too");
    }

    // ---- the refinance it turns on ----

    /// @notice A Curator loan refinances through the vault: into its own market while it qualifies, shedding collateral, and into today's after.
    function test_ACuratorLoanRefinancesOwnMarketThenTodays() public {
        uint256 loanId = _loan();
        _warpBy(1 days);
        bytes32 own = ace.loanMarket(loanId);
        vm.prank(borrower);
        (uint256 next,) = vault.refinanceFor(loanId, address(coll), PRINCIPAL + 50e6, 0, 0, 0, 0, 500e18, borrower, "");
        assertEq(ace.loanMarket(next), own, "a qualifying refinance left the loan's own market");
        assertEq(coll.balanceOf(borrower), 500e18, "the shed collateral did not reach the holder");
        _setRow(_row(2000, RATE_BPS));
        vm.prank(borrower);
        (uint256 moved,) = vault.refinanceFor(next, address(coll), PRINCIPAL + 100e6, 0, 0, 0, 0, 0, address(0), "");
        assertEq(ace.loanMarket(moved), keccak256(abi.encode(_todays())), "the refinance did not move to today's market");
        assertEq(titles.ownerOf(moved), borrower, "the successor's title is not the holder's");
    }

    // ---- each leg of the own-market answer ----

    /// @dev Whether the refinance answer to a top-up's ask on `loanId` is the loan's own market.
    function _keepsOwn(uint256 loanId) internal view returns (bool) {
        (MarketParams memory mp,) = ct.refinanceTerms(borrower, loanId, _refiAsk(read.debtOf(loanId) + AMOUNT), "");
        return _same(mp, _marketOf(loanId));
    }

    /// @notice Each row leg the answer names moves it alone: a new record, shortest term or longest term each answers today's market, and a top-up refuses.
    /// @notice CONTROL: a cut buffer, under which the price still clears, keeps the loan's own market.
    function test_EachRowLegMovesTheAnswerAlone() public {
        uint256 loanId = _loan();
        assertTrue(_keepsOwn(loanId), "PREMISE: the row as it stands keeps the loan's market");
        uint256 snap = vm.snapshotState();
        MockPersistenceRecord twin = new MockPersistenceRecord(address(usdc), address(coll));
        twin.setMinPrice(record.minPrice(address(usdc), address(coll)));
        Row memory w = _row(BUFFER_BPS, RATE_BPS);
        w.record = address(twin);
        _setRow(w);
        assertFalse(_keepsOwn(loanId), "a new record kept the loan's market");
        _topRefused(loanId);
        vm.revertToState(snap);
        w = _row(BUFFER_BPS, RATE_BPS);
        w.minTenor = TENOR + 1 days;
        _setRow(w);
        assertFalse(_keepsOwn(loanId), "a new shortest term kept the loan's market");
        _topRefused(loanId);
        vm.revertToState(snap);
        w = _row(BUFFER_BPS, RATE_BPS);
        w.maxTenor = RAIL_MAX - 1 days;
        _setRow(w);
        assertFalse(_keepsOwn(loanId), "a new longest term kept the loan's market");
        _topRefused(loanId);
        vm.revertToState(snap);
        _setRow(_row(BUFFER_BPS - 100, RATE_BPS));
        assertTrue(_keepsOwn(loanId), "CONTROL: a cut buffer moved the loan's market");
    }

    /// @notice The price leg binds at the wei: a buffered minimum one wei under the market's price moves the answer, and exactly at it keeps it.
    /// @notice At the edge a top-up lands in the loan's own market.
    function test_TheBufferedMinimumAtThePriceKeepsTheMarket_OneWeiUnderMovesIt() public {
        uint256 loanId = _loan();
        uint256 price = _marketOf(loanId).price;
        uint256 m = Math.mulDiv(price, 10_000, 10_000 - BUFFER_BPS, Math.Rounding.Ceil);
        assertEq(Math.mulDiv(m, 10_000 - BUFFER_BPS, 10_000), price, "PREMISE: this minimum buffers to exactly the price");
        assertEq(Math.mulDiv(m - 1, 10_000 - BUFFER_BPS, 10_000), price - 1, "PREMISE: one wei less buffers to one wei under it");
        record.setMinPrice(m - 1);
        assertFalse(_keepsOwn(loanId), "a buffered minimum one wei under the price kept the market");
        _topRefused(loanId);
        record.setMinPrice(m);
        assertTrue(_keepsOwn(loanId), "a buffered minimum exactly at the price moved the market");
        _top(loanId);
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "a top-up at the price leg's edge did not land");
    }

    /// @notice The answer prices the collateral asked: a loan on another collateral is never its answer, though one record and the same row terms serve both.
    function test_TheAnswerPricesTheCollateralAsked() public {
        uint256 loanId = _loan();
        MockStakeVault other = new MockStakeVault(43);
        record.setFrame(address(usdc), address(other));
        vm.prank(curator);
        ct.submitCollateral(address(other), _row(BUFFER_BPS, RATE_BPS));
        record.setFrame(address(usdc), address(coll));
        _warpBy(ROW_LOCK);
        ct.accept(address(other));
        assertEq(ct.rowOf(address(other)).record, _marketOf(loanId).record, "PREMISE: the other row names the loan's record");
        RefinanceRequest memory q = _refiAsk(PRINCIPAL + AMOUNT);
        q.collateral = address(other);
        (MarketParams memory mp,) = ct.refinanceTerms(borrower, loanId, q, "");
        assertEq(mp.collateral, address(other), "the answer priced another collateral than the one asked");
        assertFalse(_same(mp, _marketOf(loanId)), "the answer is the loan's market on another collateral");
    }

    /// @notice The answer refuses as a borrow's does: an unlisted collateral `NotListed`, through the vault's refinance too.
    /// @notice A record whose buffered minimum falls off the grid, or a dark one, refuses `PriceZero`, and stops a top-up before the hub is asked.
    function test_TheAnswerRefusesUnlistedAndOffTheGrid() public {
        uint256 loanId = _loan();
        RefinanceRequest memory q = _refiAsk(PRINCIPAL + AMOUNT);
        q.collateral = address(new MockStakeVault(44));
        vm.expectRevert(CuratorTerms.NotListed.selector);
        ct.refinanceTerms(borrower, loanId, q, "");
        vm.prank(borrower);
        vm.expectRevert(CuratorTerms.NotListed.selector);
        vault.refinanceFor(loanId, q.collateral, PRINCIPAL, 0, 0, 0, 0, 0, address(0), "");
        record.setMinPrice(1);
        vm.expectRevert(CuratorTerms.PriceZero.selector);
        ct.refinanceTerms(borrower, loanId, _refiAsk(PRINCIPAL + AMOUNT), "");
        record.setMinPrice(0);
        vm.prank(borrower);
        vm.expectRevert(CuratorTerms.PriceZero.selector);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
    }

    /// @notice An asked term comes back in the answer's draw, so the vault's binding to the ask holds on a refinance that names one.
    function test_AnAskedTermIsAnsweredBack() public {
        uint256 loanId = _loan();
        RefinanceRequest memory q = _refiAsk(PRINCIPAL + AMOUNT);
        q.tenor = 2 * TENOR;
        (, Terms memory t) = ct.refinanceTerms(borrower, loanId, q, "");
        assertEq(t.tenor, 2 * TENOR, "an asked term was not answered back");
        assertEq(t.principal, PRINCIPAL + AMOUNT, "the answer did not take the asked principal");
    }
}
