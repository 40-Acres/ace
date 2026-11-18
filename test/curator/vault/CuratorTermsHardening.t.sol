// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Constants} from "../../../src/ace/hub/Constants.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorTerms, CuratorTermsConfig, Listing, Row} from "../../../src/entities/curated/CuratorTerms.sol";
import {Extension} from "../../../src/interfaces/IRollPolicy.sol";
import {Lend} from "../../../src/interfaces/IVaultTerms.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";

/// @title CuratorTermsHardeningTest
/// @notice R1/R2/N4 hardening: the binding refuses an asset mismatch too, `_checkRow` refuses each bad leg at its edge, the deploy rails hold,
/// @notice the row timelock's edges and keys, the room's unsold-pot hold at the record minimum, and each leg of the extension consent.
contract CuratorTermsHardeningTest is AceVaultBaseRig {
    uint256 internal constant MIN_P = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint64 internal constant ROW_LOCK = 3 days;
    uint16 internal constant BUFFER_BPS = 1000;
    uint16 internal constant RATE_BPS = 40;

    CuratorTerms internal ct;

    function setUp() public override {
        super.setUp();
        (vault, ct) = _deployCurated(_cfgFor(address(0)), _listings(_row(address(record))), _caps(UNCAPPED, 0, UNCAPPED));
        _lp(alice, LP_CASH);
    }

    function _row(address rec) internal pure returns (Row memory) {
        return Row({record: rec, bufferBps: BUFFER_BPS, lenderAprBps: RATE_BPS, minTenor: TENOR, maxTenor: RAIL_MAX});
    }

    function _listings(Row memory r) internal view returns (Listing[] memory l) {
        l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: r});
    }

    function _cfgFor(address v) internal view returns (CuratorTermsConfig memory) {
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

    /// @dev CuratorTerms on config `c` aimed at the address the vault's create takes, then the vault naming them.
    function _deployCurated(CuratorTermsConfig memory c, Listing[] memory l, uint192[3] memory caps) internal returns (AceVault v, CuratorTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        c.vault = predicted;
        t = new CuratorTerms(c, l);
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        VaultSeed.fund(_cfg(), predicted);
        v = new AceVault(_cfg(), pc, _listing(predicted, caps), "Curated", "cVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
    }

    function _submit(address c, Row memory r) internal {
        vm.prank(curator);
        ct.submitCollateral(c, r);
    }

    function _expectBadRow(address c, Row memory r) internal {
        vm.prank(curator);
        vm.expectRevert(CuratorTerms.BadRow.selector);
        ct.submitCollateral(c, r);
    }

    // ---- R1: the binding refuses an asset mismatch too ----

    /// @notice TERMS ON ANOTHER ASSET refuse their vault's write call by `VaultMismatch`, and a borrow through them refuses on the market's quote.
    function test_TermsOnAnotherAssetRefuseTheVaultsWriteCall() public {
        MockERC20 other = new MockERC20("Other Cash", "OTH", 6);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(other), address(coll));
        CuratorTermsConfig memory c = _cfgFor(address(0));
        c.asset = address(other);
        (AceVault v, CuratorTerms t) = _deployCurated(c, _listings(_row(address(rec))), _caps(UNCAPPED, 0, UNCAPPED));
        assertEq(t.ASSET(), address(other), "premise: the terms copied another asset than the vault's");
        MarketParams memory mp;
        vm.prank(address(v));
        vm.expectRevert(CuratorTerms.VaultMismatch.selector);
        t.beforeLend(Lend.Borrow, mp, 0, "");
        vault = v;
        _lp(alice, LP_CASH);
        _expectBorrowRevert(address(coll), AceVaultFlows.OutsideEnvelope.selector);
    }

    /// @notice The write calls are the vault's alone; the vault's own `beforeLend` on honest terms passes.
    function test_TheWriteCallsAreTheVaultsAlone() public {
        MarketParams memory mp;
        vm.startPrank(stranger);
        vm.expectRevert(CuratorTerms.NotVault.selector);
        ct.beforeLend(Lend.Borrow, mp, 0, "");
        vm.expectRevert(CuratorTerms.NotVault.selector);
        ct.afterLend(Lend.Borrow, mp, 1, stranger, "");
        vm.stopPrank();
        vm.startPrank(address(vault));
        ct.beforeLend(Lend.Borrow, mp, 0, "");
        ct.afterLend(Lend.Borrow, mp, 1, borrower, "");
        vm.stopPrank();
    }

    // ---- _checkRow, leg by leg ----

    /// @notice A row naming no record, no collateral, the vault's asset or the vault's own share is refused.
    function test_checkRow_RefusesTheIdentityLegs() public {
        MockStakeVault c = new MockStakeVault(42);
        MockPersistenceRecord rec = _record(address(c));
        _expectBadRow(address(c), _row(address(0)));
        _expectBadRow(address(0), _row(address(rec)));
        _expectBadRow(address(usdc), _row(address(_record(address(usdc)))));
        _expectBadRow(address(vault), _row(address(_record(address(vault)))));
        _submit(address(c), _row(address(rec)));
        (, uint64 validAt) = ct.pendingRowOf(address(c));
        assertGt(validAt, 0, "CONTROL: a sound row is queued");
    }

    /// @notice A record that does not affirm the vault's asset against the collateral is refused.
    function test_checkRow_RefusesARecordForAnotherPair() public {
        MockStakeVault c = new MockStakeVault(42);
        _expectBadRow(address(c), _row(address(record)));
    }

    /// @notice The buffer is refused at the whole price and admitted a basis point under it; the rate is refused under the hub's floor.
    function test_checkRow_TheBufferAndRateEdges() public {
        MockStakeVault c = new MockStakeVault(42);
        MockPersistenceRecord rec = _record(address(c));
        Row memory r = _row(address(rec));
        r.bufferBps = 10_000;
        _expectBadRow(address(c), r);
        r.bufferBps = 9_999;
        _submit(address(c), r);
        r = _row(address(rec));
        r.lenderAprBps = uint16(Constants.MIN_LENDER_APR_BPS - 1);
        _expectBadRow(address(c), r);
        r.lenderAprBps = uint16(Constants.MIN_LENDER_APR_BPS);
        _submit(address(c), r);
    }

    /// @notice The tenors are refused crossed and admitted equal; a rate whose fee over the longest term passes the hub's share is refused.
    /// @dev At a thirty-day longest term the hub's 25% share admits 27651 bps a year all-in with its 10% take, and refuses 27652.
    function test_checkRow_TheTenorAndFeeEdges() public {
        MockStakeVault c = new MockStakeVault(42);
        MockPersistenceRecord rec = _record(address(c));
        Row memory r = _row(address(rec));
        (r.minTenor, r.maxTenor) = (TENOR, TENOR - 1);
        _expectBadRow(address(c), r);
        (r.minTenor, r.maxTenor) = (TENOR, TENOR);
        _submit(address(c), r);
        r = _row(address(rec));
        (r.minTenor, r.maxTenor) = (RAIL_MIN, RAIL_MAX);
        r.lenderAprBps = 27_652;
        _expectBadRow(address(c), r);
        r.lenderAprBps = 27_651;
        _submit(address(c), r);
    }

    // ---- the deploy rails ----

    /// @notice The minimum principal and the coverage are refused just past each genesis edge and admitted at it.
    function test_TheDeployRefusesTermsGenesisWouldRefuse() public {
        Listing[] memory none = new Listing[](0);
        CuratorTermsConfig memory c = _cfgFor(address(0xBEEF));
        c.minPrincipal = 1;
        vm.expectRevert(CuratorTerms.BadTerms.selector);
        new CuratorTerms(c, none);
        c.minPrincipal = 2;
        new CuratorTerms(c, none);
        c.minPrincipal = uint256(type(uint128).max) + 1;
        vm.expectRevert(CuratorTerms.BadTerms.selector);
        new CuratorTerms(c, none);
        c.minPrincipal = type(uint128).max;
        new CuratorTerms(c, none);
        c = _cfgFor(address(0xBEEF));
        c.coverageWad = Constants.MIN_COVERAGE_WAD - 1;
        vm.expectRevert(CuratorTerms.BadTerms.selector);
        new CuratorTerms(c, none);
        c.coverageWad = Constants.MAX_COVERAGE_WAD + 1;
        vm.expectRevert(CuratorTerms.BadTerms.selector);
        new CuratorTerms(c, none);
        c.coverageWad = Constants.MIN_COVERAGE_WAD;
        new CuratorTerms(c, none);
        c.coverageWad = Constants.MAX_COVERAGE_WAD;
        CuratorTerms ok = new CuratorTerms(c, none);
        assertEq(ok.COVERAGE_WAD(), Constants.MAX_COVERAGE_WAD, "CONTROL: the coverage at its ceiling deploys");
    }

    /// @notice A rail whose two ends meet is not crossed: terms on a single-term rail deploy, and a row on that one term lists.
    function test_TheTermsAdmitARailWhoseEndsMeet() public {
        CuratorTermsConfig memory c = _cfgFor(address(0xBEEF));
        (c.minTenor, c.maxTenor) = (TENOR, TENOR);
        Row memory r = _row(address(record));
        (r.minTenor, r.maxTenor) = (TENOR, TENOR);
        Listing[] memory l = _listings(r);
        CuratorTerms t = new CuratorTerms(c, l);
        assertEq(t.MIN_TENOR(), t.MAX_TENOR(), "the single-term rail did not stand");
        assertEq(t.rowOf(address(coll)).maxTenor, TENOR, "a row on the single term did not list");
    }

    /// @notice The row timelock is refused a second outside one to fourteen days, and admitted at both ends.
    function test_TheDeployRefusesARowTimelockOutOfBounds() public {
        Listing[] memory none = new Listing[](0);
        CuratorTermsConfig memory c = _cfgFor(address(0xBEEF));
        c.timelock = 1 days - 1;
        vm.expectRevert(CuratorTerms.TimelockOutOfBounds.selector);
        new CuratorTerms(c, none);
        c.timelock = 14 days + 1;
        vm.expectRevert(CuratorTerms.TimelockOutOfBounds.selector);
        new CuratorTerms(c, none);
        c.timelock = 1 days;
        new CuratorTerms(c, none);
        c.timelock = 14 days;
        assertEq(new CuratorTerms(c, none).TIMELOCK(), 14 days, "CONTROL: the timelock at its ceiling deploys");
    }

    // ---- the row timelock ----

    /// @notice A row is refused a second before its `validAt` and goes live at it, by anyone; a second accept has nothing due.
    function test_ARowLandsAtItsValidAtAndNotBefore() public {
        MockStakeVault c = new MockStakeVault(42);
        _submit(address(c), _row(address(_record(address(c)))));
        (, uint64 validAt) = ct.pendingRowOf(address(c));
        assertEq(validAt, _now() + ROW_LOCK, "premise: the row waits the timelock");
        _warpTo(validAt - 1);
        vm.expectRevert(CuratorTerms.NothingDue.selector);
        ct.accept(address(c));
        _warpTo(validAt);
        vm.prank(stranger);
        ct.accept(address(c));
        assertTrue(ct.rowOf(address(c)).record != address(0), "the row did not go live at its validAt");
        vm.expectRevert(CuratorTerms.NothingDue.selector);
        ct.accept(address(c));
    }

    /// @notice The guardian and the curator may each drop a pending row; a stranger may not, and a dropped row never lands.
    function test_TheGuardianOrTheCuratorDropsAPendingRow() public {
        MockStakeVault c = new MockStakeVault(42);
        Row memory r = _row(address(_record(address(c))));
        _submit(address(c), r);
        vm.prank(stranger);
        vm.expectRevert(CuratorTerms.NotCurator.selector);
        ct.revokePending(address(c));
        vm.prank(guardian);
        ct.revokePending(address(c));
        (, uint64 validAt) = ct.pendingRowOf(address(c));
        assertEq(validAt, 0, "the guardian's revoke left the row pending");
        _submit(address(c), r);
        vm.prank(curator);
        ct.revokePending(address(c));
        _warpBy(ROW_LOCK);
        vm.expectRevert(CuratorTerms.NothingDue.selector);
        ct.accept(address(c));
        assertEq(ct.rowOf(address(c)).record, address(0), "a dropped row went live");
    }

    // ---- the answers ----

    /// @notice An unlisted collateral is refused; a record answering no price refuses; a zero ask takes the row's shortest term, an asked one stands.
    function test_TheBorrowAnswer() public {
        BorrowRequest memory r = _req(address(new MockStakeVault(42)), UNITS, PRINCIPAL, 0);
        vm.expectRevert(CuratorTerms.NotListed.selector);
        ct.borrowTerms(borrower, r, "");
        r = _req(address(coll), UNITS, PRINCIPAL, 0);
        (MarketParams memory mp, Terms memory t) = ct.borrowTerms(borrower, r, "");
        assertEq(t.tenor, TENOR, "a zero ask did not take the row's shortest term");
        assertEq(mp.lender, address(vault), "the market names another lender");
        assertEq(mp.quote, address(usdc), "the market quotes another asset");
        assertEq(mp.minPrincipal, MIN_P, "the market's floor ticket is not the terms'");
        assertEq(mp.minCoverageWad, COVERAGE, "the market's coverage is not the terms'");
        assertEq(mp.settleBountyBps, 0, "the market pays a settle bounty");
        assertTrue(mp.inventoryAsk, "the market does not sell at the hub's ask");
        assertEq(t.principal, PRINCIPAL, "the draw is not the asked principal");
        r.tenor = 2 * TENOR;
        (, t) = ct.borrowTerms(borrower, r, "");
        assertEq(t.tenor, 2 * TENOR, "an asked term was not answered back");
        record.setMinPrice(0);
        vm.expectRevert(CuratorTerms.PriceZero.selector);
        ct.borrowTerms(borrower, r, "");
    }

    /// @notice No entry cap of the terms' own; the refinance answers are `CuratorTermsDrawMore`'s rows.
    function test_NoEntryCapOfTheTermsOwn() public view {
        assertEq(ct.entryCap(alice, 123), type(uint256).max, "the terms capped entry");
    }

    /// @notice THE UNSOLD POT IS HELD AT THE RECORD MINIMUM: the room is the row less the pot at that price, a draw at it lands and one unit more refuses.
    /// @dev The rig's record reads two whole quote per whole collateral, so the pot is worth `2e6` atoms a `1e18` unit; the Q96 price leaves a wei.
    function test_TheUnsoldPotHoldsTheRowAtTheRecordMinimum() public {
        uint192 rowCap = uint192(5 * PRINCIPAL);
        (vault, ct) = _deployCurated(_cfgFor(address(0)), _listings(_row(address(record))), _caps(rowCap, 0, UNCAPPED));
        _lp(alice, LP_CASH);
        uint256 loanId = _borrow();
        MarketParams memory mp0 = ace.idToMarketParams(ace.loanMarket(loanId));
        assertEq(ct.room(mp0), type(uint256).max, "premise: with nothing unsold the terms hold no room");
        _finalize(loanId);
        (uint256 lent, uint256 unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(lent, 0, "premise: the settled loan holds no lent");
        assertGt(unsold, 0, "premise: the pot is unsold");
        uint256 parked = (unsold * 2e6) / 1e18;
        assertApproxEqAbs(ct.room(mp0), rowCap - parked, 1, "the terms' room is not the row less the pot at the record minimum");
        uint256 m = record.minPrice(address(usdc), address(coll));
        record.setMinPrice(m / 2);
        assertApproxEqAbs(ct.room(mp0), rowCap - parked / 2, 1, "the pot did not follow the record's minimum");
        record.setMinPrice(m);
        uint256 held = ct.room(mp0);
        assertLt(held, vlens.roomOf(address(vault), address(coll)), "premise: the terms' hold binds under the vault's own row");
        _expectBorrowAt(held + 1, AceVaultFlows.OverCap.selector);
        uint256 at = _borrowAs(borrower, address(coll), (UNITS * held) / PRINCIPAL + 1, held);
        assertTrue(ace.isLiveLoan(at), "a draw exactly at the held room was refused");
    }

    /// @notice A LIVE LOAN AND AN UNSOLD POT HOLD THE ROW TOGETHER: the terms' room is the row less both, tighter than the vault's own row.
    /// @dev A room that forgot the live loan would read the row less the pot alone; that mutant survived every earlier row.
    function test_ALiveLoanAndAnUnsoldPotHoldTheRowTogether() public {
        uint192 rowCap = uint192(5 * PRINCIPAL);
        (vault, ct) = _deployCurated(_cfgFor(address(0)), _listings(_row(address(record))), _caps(rowCap, 0, UNCAPPED));
        _lp(alice, LP_CASH);
        uint256 live = _borrow();
        uint256 settled = _borrow();
        MarketParams memory mp0 = ace.idToMarketParams(ace.loanMarket(live));
        _finalize(settled);
        assertTrue(ace.isLiveLoan(live), "premise: one loan is still out");
        (uint256 lent, uint256 unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(lent, PRINCIPAL, "premise: the live loan holds its principal");
        uint256 parked = (unsold * 2e6) / 1e18;
        assertGt(parked, 0, "premise: the settled loan left a pot");
        uint256 held = ct.room(mp0);
        assertApproxEqAbs(held, rowCap - PRINCIPAL - parked, 1, "the terms' room is not the row less the live loan and the pot");
        assertLt(held, vlens.roomOf(address(vault), address(coll)), "premise: the terms' hold binds under the vault's own row");
        _expectBorrowAt(held + 1, AceVaultFlows.OverCap.selector);
        uint256 at = _borrowAs(borrower, address(coll), (UNITS * held) / PRINCIPAL + 1, held);
        assertTrue(ace.isLiveLoan(at), "a draw exactly at the held room was refused");
    }

    function _expectBorrowAt(uint256 p, bytes4 sel) internal {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        BorrowRequest memory r = _req(address(coll), UNITS, p, 0);
        vm.expectRevert(sel);
        vault.borrow(r, "", "");
        vm.stopPrank();
    }

    /// @notice EACH LEG OF THE CONSENT: a changed record, rate or either tenor refuses; a changed buffer does not; the price leg admits at equality.
    function test_EachLegOfTheConsent() public {
        uint256 loanId = _borrow();
        Extension memory e = _ext(loanId);
        assertTrue(ct.admitsExtension(e, ""), "premise: the row as it stands consents");
        Extension memory x = _ext(loanId);
        x.dst.record = address(0xDEAD);
        assertFalse(ct.admitsExtension(x, ""), "a changed record consented");
        x = _ext(loanId);
        x.dst.lenderAprBps = RATE_BPS + 1;
        assertFalse(ct.admitsExtension(x, ""), "a changed rate consented");
        x = _ext(loanId);
        x.dst.minTenor = TENOR + 1;
        assertFalse(ct.admitsExtension(x, ""), "a changed shortest term consented");
        x = _ext(loanId);
        x.dst.maxTenor = RAIL_MAX - 1;
        assertFalse(ct.admitsExtension(x, ""), "a changed longest term consented");
        Row memory moved = _row(address(record));
        moved.bufferBps = BUFFER_BPS + 500;
        _submit(address(coll), moved);
        _warpBy(ROW_LOCK);
        ct.accept(address(coll));
        assertTrue(ct.admitsExtension(_ext(loanId), ""), "a changed buffer stopped an old market's extension");
        record.setMinPrice(e.dst.price);
        assertTrue(ct.admitsExtension(_ext(loanId), ""), "a record minimum exactly at the market's price refused");
        record.setMinPrice(e.dst.price - 1);
        assertFalse(ct.admitsExtension(_ext(loanId), ""), "a record minimum under the market's price consented");
    }
}
