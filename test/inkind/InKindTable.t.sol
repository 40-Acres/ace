// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "../mocks/MockERC20.sol";
import {Signing1271Wallet} from "../mocks/Mock1271Wallet.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../src/curator/libraries/AceVaultFlows.sol";
import {IInKindTerms, IInKindVault, InKindConfig, Listing, Quote, Row} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindTable
/// @notice The write-once rails and the curation table: new rows and every widening or rate change wait the timelock; two cuts land at once.
/// @notice The terms' two cuts are a lower `maxPrincipal` and a shorter `maxTenor`; the vault's cap is cut or raised through its own cap verbs.
/// @notice Anyone accepts after the timelock; the tracker's slot cap binds on caps going live, and a never-credited token releases its slot.
contract InKindTableTest is InKindRig {
    MockERC20 internal tokC;

    function setUp() public override {
        super.setUp();
        tokC = new MockERC20("Token C", "TKC", 18);
    }

    function _sameRow(Row memory a, Row memory b, string memory what) internal pure {
        assertEq(a.lenderAprBps, b.lenderAprBps, string.concat(what, ": rate"));
        assertEq(a.minTenor, b.minTenor, string.concat(what, ": minTenor"));
        assertEq(a.maxTenor, b.maxTenor, string.concat(what, ": maxTenor"));
        assertEq(a.maxPrincipal, b.maxPrincipal, string.concat(what, ": maxPrincipal"));
    }

    /// @dev The rig's row with a largest loan of `maxPrincipal`.
    function _rowMax(uint256 maxPrincipal) internal pure returns (Row memory row) {
        row = _row();
        row.maxPrincipal = uint128(maxPrincipal);
    }

    /// @dev Submit `row` for `coll` as `who`.
    function _submit(address who, address coll, Row memory row) internal {
        vm.prank(who);
        terms.submitRow(coll, row);
    }

    // ---- the write-once rails ----

    function testRevert_constructor_timelockUnderADay() public {
        InKindConfig memory ik = _ik();
        ik.timelock = 1 days - 1;
        _deployExpecting(IInKindVault.TimelockOutOfBounds.selector, ik, _listings());
    }

    function testRevert_constructor_timelockOverFourteenDays() public {
        InKindConfig memory ik = _ik();
        ik.timelock = 14 days + 1;
        _deployExpecting(IInKindVault.TimelockOutOfBounds.selector, ik, _listings());
    }

    /// @notice Both timelock ends are admitted.
    function test_constructor_timelockEndsAreInclusive() public {
        InKindConfig memory ik = _ik();
        ik.timelock = 1 days;
        assertEq(_deploy(_cfg(0), ik, _listings()).CAP_TIMELOCK(), 1 days, "one day admitted");
        ik.timelock = 14 days;
        assertEq(_deploy(_cfg(0), ik, _listings()).CAP_TIMELOCK(), 14 days, "fourteen days admitted");
    }

    /// @notice The rail's floor is at least a day, every vault's `MIN_TENOR_RAIL`, though the hub would take 10 s.
    function testRevert_constructor_minTenorUnderADay() public {
        InKindConfig memory ik = _ik();
        ik.minTenor = 1 days - 1;
        Listing[] memory l = _listings();
        (l[0].row.minTenor, l[1].row.minTenor) = (ik.minTenor, ik.minTenor);
        _deployExpecting(IInKindTerms.TenorRailOutOfBounds.selector, ik, l);
    }

    /// @notice A one-day minimum term is admitted, and it is `MIN_TENOR()` on both the vault and its terms.
    function test_constructor_aOneDayMinTenorDeploys() public {
        InKindConfig memory ik = _ik();
        ik.minTenor = 1 days;
        Listing[] memory l = _listings();
        (l[0].row.minTenor, l[1].row.minTenor) = (1 days, 1 days);
        vault = _deploy(_cfg(0), ik, l);
        assertEq(vault.MIN_TENOR(), 1 days, "the vault's minimum term is the one named");
        assertEq(terms.MIN_TENOR(), 1 days, "and the terms' rail floor with it");
    }

    function testRevert_constructor_maxTenorOverThirtyDays() public {
        InKindConfig memory ik = _ik();
        ik.maxTenor = 30 days + 1;
        _deployExpecting(IInKindTerms.TenorRailOutOfBounds.selector, ik, _listings());
    }

    function testRevert_constructor_minTenorOverMaxTenor() public {
        InKindConfig memory ik = _ik();
        (ik.minTenor, ik.maxTenor) = (15 days, 14 days);
        _deployExpecting(IInKindTerms.TenorRailOutOfBounds.selector, ik, new Listing[](0));
    }

    function testRevert_constructor_zeroAppraiser() public {
        InKindConfig memory ik = _ik();
        ik.appraiser = address(0);
        _deployExpecting(IInKindTerms.ZeroAppraiser.selector, ik, _listings());
    }

    /// @notice An EIP-7702-delegated EOA is refused as the appraiser at deploy too.
    function testRevert_constructor_aDelegatedAppraiser() public {
        address eoa = vm.addr(0x7702);
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(new Signing1271Wallet())));
        InKindConfig memory ik = _ik();
        ik.appraiser = eoa;
        _deployExpecting(IInKindTerms.DelegatedAppraiser.selector, ik, _listings());
    }

    function testRevert_constructor_aMinPrincipalGenesisRefuses() public {
        InKindConfig memory ik = _ik();
        ik.minPrincipal = 1;
        _deployExpecting(IInKindTerms.BadTerms.selector, ik, _listings());
    }

    function testRevert_constructor_aCoverageGenesisRefuses() public {
        InKindConfig memory ik = _ik();
        ik.coverageWad = 1e18;
        _deployExpecting(IInKindTerms.BadTerms.selector, ik, _listings());
    }

    function testRevert_constructor_aRowUnderTheVaultsMinTenor() public {
        Listing[] memory l = _listings();
        l[0].row.minTenor = MIN_TENOR - 1;
        _deployExpecting(IInKindTerms.BadRow.selector, _ik(), l);
    }

    function testRevert_constructor_aRowOverTheVaultsMaxTenor() public {
        Listing[] memory l = _listings();
        l[0].row.maxTenor = MAX_TENOR + 1;
        _deployExpecting(IInKindTerms.BadRow.selector, _ik(), l);
    }

    function testRevert_constructor_aRowListingTheAsset() public {
        Listing[] memory l = _listings();
        l[0].collateral = address(usdc);
        _deployExpecting(IInKindTerms.BadRow.selector, _ik(), l);
    }

    function testRevert_constructor_aZeroRate() public {
        Listing[] memory l = _listings();
        l[0].row.lenderAprBps = 0;
        _deployExpecting(IInKindTerms.BadRow.selector, _ik(), l);
    }

    // ---- new rows ----

    /// @notice A new token waits twice: its terms row and its vault cap each pend the timelock, refuse an early accept, then anyone accepts both and it lends.
    function test_aNewRowWaitsTheTimelockThenAnyoneAccepts() public {
        Row memory row = _row();
        vm.expectEmit(true, false, false, true, address(terms));
        emit IInKindTerms.SubmitRow(address(tokC), row, uint64(_now() + TIMELOCK));
        _submit(curator, address(tokC), row);
        (Row memory p, uint64 validAt) = terms.pendingRowOf(address(tokC));
        _sameRow(p, row, "pending");
        assertEq(validAt, _now() + TIMELOCK, "the row is valid after the timelock");
        assertEq(terms.rowOf(address(tokC)).maxTenor, 0, "the row is not live yet");
        _setCap(curator, address(tokC), CAP);
        (uint192 pc,, uint64 capValidAt) = lens.pendingCapOf(address(vault), address(tokC));
        assertEq(pc, CAP, "the cap pends too: the wildcard is zero, so a new cap is a raise");
        assertEq(capValidAt, _now() + TIMELOCK, "after the vault's cap timelock");
        assertEq(_capOf(address(tokC)), 0, "and is not live yet");
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.accept(address(tokC));
        vm.expectRevert(IInKindVault.NothingDue.selector);
        vault.acceptCap(address(tokC));
        _warpBy(TIMELOCK);
        vm.expectEmit(true, true, false, true, address(terms));
        emit IInKindTerms.SetRow(stranger, address(tokC), row);
        vm.prank(stranger);
        terms.accept(address(tokC));
        _sameRow(terms.rowOf(address(tokC)), row, "live");
        _lp(alice, LP_CASH);
        Quote memory q = _quote(address(tokC), PRICE);
        bytes memory data = _data(q);
        _fund(address(tokC), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        vault.borrow(_req(address(tokC), UNITS, PRINCIPAL, MIN_TENOR), data, "");
        vm.prank(stranger);
        vault.acceptCap(address(tokC));
        assertEq(_capOf(address(tokC)), CAP, "the cap is live");
        assertGt(_open(address(tokC)), 0, "the accepted row lends once its cap is live too");
    }

    /// @notice Until a new row is accepted the token is unlisted.
    function testRevert_aPendingRowDoesNotLend() public {
        _submit(curator, address(tokC), _row());
        _lp(alice, LP_CASH);
        Quote memory q = _quote(address(tokC), PRICE);
        bytes memory data = _data(q);
        _fund(address(tokC), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.NotListed.selector);
        vault.borrow(_req(address(tokC), UNITS, PRINCIPAL, MIN_TENOR), data, "");
    }

    function testRevert_aStrangerCannotSubmitARow() public {
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NotCurator.selector);
        terms.submitRow(address(tokC), _row());
    }

    function testRevert_theGuardianCannotSubmitANewRow() public {
        vm.prank(guardian);
        vm.expectRevert(IInKindTerms.NotCurator.selector);
        terms.submitRow(address(tokC), _row());
    }

    // ---- the classification ----

    /// @notice A lower cap lands at once on the vault, by the guardian too.
    function test_aCapCutLandsAtOnceByTheGuardian() public {
        _setCap(guardian, address(tokA), CAP / 2);
        assertEq(_capOf(address(tokA)), CAP / 2, "the cut is live");
        (,, uint64 validAt) = lens.pendingCapOf(address(vault), address(tokA));
        assertEq(validAt, 0, "and nothing pends");
    }

    /// @notice A zero cap is a cut, and lands at once.
    function test_aCapCutToZeroLandsAtOnce() public {
        _setCap(guardian, address(tokA), 0);
        assertEq(_capOf(address(tokA)), 0, "the token lends no more");
    }

    /// @notice A shorter maxTenor lands at once.
    function test_aMaxTenorCutLandsAtOnce() public {
        Row memory row = _row();
        row.maxTenor = MIN_TENOR;
        _submit(curator, address(tokA), row);
        _sameRow(terms.rowOf(address(tokA)), row, "cut");
    }

    /// @notice A lower maxPrincipal lands at once, by the curator and by the guardian, and binds the next borrow at once.
    function test_aMaxPrincipalCutLandsAtOnce() public {
        Row memory row = _rowMax(PRINCIPAL * 2);
        vm.expectEmit(true, true, false, true, address(terms));
        emit IInKindTerms.SetRow(curator, address(tokA), row);
        _submit(curator, address(tokA), row);
        _sameRow(terms.rowOf(address(tokA)), row, "the curator's cut");
        row.maxPrincipal = uint128(PRINCIPAL - 1);
        _submit(guardian, address(tokA), row);
        _sameRow(terms.rowOf(address(tokA)), row, "the guardian's cut");
        (, uint64 validAt) = terms.pendingRowOf(address(tokA));
        assertEq(validAt, 0, "nothing left pending");
        _lp(alice, LP_CASH);
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _data(q);
        _fund(address(tokA), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.OverMaxPrincipal.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, "");
    }

    /// @dev `row` for tokA must wait: the live row is unchanged, the change is pending, and it lands after the timelock.
    function _assertWaits(Row memory row) internal {
        Row memory live = terms.rowOf(address(tokA));
        _submit(curator, address(tokA), row);
        _sameRow(terms.rowOf(address(tokA)), live, "unchanged until the timelock");
        (Row memory p, uint64 validAt) = terms.pendingRowOf(address(tokA));
        _sameRow(p, row, "pending");
        assertEq(validAt, _now() + TIMELOCK, "valid after the timelock");
        _warpBy(TIMELOCK);
        terms.accept(address(tokA));
        _sameRow(terms.rowOf(address(tokA)), row, "live after the accept");
    }

    /// @notice A cap raise waits the vault's cap timelock: the live cap holds, the raise pends, and anyone lands it after.
    function test_aCapRaiseWaits() public {
        _setCap(curator, address(tokA), CAP * 2);
        assertEq(_capOf(address(tokA)), CAP, "unchanged until the timelock");
        (uint192 p,, uint64 validAt) = lens.pendingCapOf(address(vault), address(tokA));
        assertEq(p, CAP * 2, "pending");
        assertEq(validAt, _now() + TIMELOCK, "valid after the vault's cap timelock");
        _warpBy(TIMELOCK);
        vault.acceptCap(address(tokA));
        assertEq(_capOf(address(tokA)), CAP * 2, "live after the accept");
    }

    function test_aMaxTenorRaiseWaits() public {
        Row memory row = _row();
        row.maxTenor = MAX_TENOR;
        _assertWaits(row);
    }

    /// @notice A higher maxPrincipal is a widening, so it waits whole.
    function test_aMaxPrincipalRaiseWaits() public {
        _assertWaits(_rowMax(uint256(CAP) + 1));
    }

    /// @notice A rate CUT waits too: it lowers depositor yield, and any rate change stops old markets extending.
    function test_aRateCutWaits() public {
        Row memory row = _row();
        row.lenderAprBps = RATE_BPS - 10;
        _assertWaits(row);
    }

    function test_aRateRaiseWaits() public {
        Row memory row = _row();
        row.lenderAprBps = RATE_BPS + 10;
        _assertWaits(row);
    }

    /// @notice A minTenor change is none of the cuts, so it waits.
    function test_aMinTenorChangeWaits() public {
        Row memory row = _row();
        row.minTenor = MIN_TENOR + 1 days;
        _assertWaits(row);
    }

    function testRevert_theGuardianCannotRaise() public {
        vm.prank(guardian);
        vm.expectRevert(IInKindVault.NotCurator.selector);
        vault.submitCap(address(tokA), CAP * 2);
    }

    function testRevert_aStrangerCannotCut() public {
        vm.prank(stranger);
        vm.expectRevert(IInKindVault.NotCurator.selector);
        vault.submitCap(address(tokA), CAP / 2);
    }

    /// @notice A cut drops what is pending on its own side, so no earlier submission can lift it back after the timelock.
    /// @dev The vault's cap and the terms' row are separate keys: each cut drops only its own side's pending change.
    function test_aCutDropsWhatIsPending() public {
        _setCap(curator, address(tokA), CAP * 2);
        _setCap(guardian, address(tokA), CAP);
        (,, uint64 capValidAt) = lens.pendingCapOf(address(vault), address(tokA));
        assertEq(capValidAt, 0, "the cap cut dropped the pending cap raise");
        _submit(curator, address(tokA), _rowMax(uint256(CAP) * 2));
        _submit(guardian, address(tokA), _rowMax(PRINCIPAL));
        (, uint64 rowValidAt) = terms.pendingRowOf(address(tokA));
        assertEq(rowValidAt, 0, "the maxPrincipal cut dropped the pending row raise");
        _warpBy(TIMELOCK);
        vm.expectRevert(IInKindVault.NothingDue.selector);
        vault.acceptCap(address(tokA));
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.accept(address(tokA));
        assertEq(_capOf(address(tokA)), CAP, "the cap raise never lands");
        assertEq(terms.rowOf(address(tokA)).maxPrincipal, PRINCIPAL, "and neither does the row raise");
    }

    /// @notice The guardian may revoke what is pending: a maxPrincipal raise.
    function test_revokePendingByTheGuardian() public {
        _submit(curator, address(tokA), _rowMax(uint256(CAP) * 2));
        vm.expectEmit(true, true, false, false, address(terms));
        emit IInKindTerms.RevokePending(guardian, address(tokA));
        vm.prank(guardian);
        terms.revokePending(address(tokA));
        (, uint64 validAt) = terms.pendingRowOf(address(tokA));
        assertEq(validAt, 0, "nothing pending");
    }

    function testRevert_revokePendingByAStranger() public {
        _submit(curator, address(tokA), _rowMax(uint256(CAP) * 2));
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NotCurator.selector);
        terms.revokePending(address(tokA));
    }

    // ---- row rails at submit ----

    function testRevert_submitRow_maxTenorOverTheVaultsMax() public {
        Row memory row = _row();
        row.maxTenor = MAX_TENOR + 1;
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.BadRow.selector);
        terms.submitRow(address(tokC), row);
    }

    function testRevert_submitRow_minTenorUnderTheVaultsMin() public {
        Row memory row = _row();
        row.minTenor = MIN_TENOR - 1;
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.BadRow.selector);
        terms.submitRow(address(tokC), row);
    }

    function testRevert_submitRow_minTenorOverMaxTenor() public {
        Row memory row = _row();
        (row.minTenor, row.maxTenor) = (ROW_MAX_TENOR + 1 days, ROW_MAX_TENOR);
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.BadRow.selector);
        terms.submitRow(address(tokC), row);
    }

    /// @notice A maxPrincipal under the vault's floor ticket is refused, since no loan could open; exactly the floor is admitted.
    function testRevert_submitRow_aMaxPrincipalUnderTheFloorTicket() public {
        Row memory row = _rowMax(MIN_PRINCIPAL - 1);
        vm.prank(curator);
        vm.expectRevert(IInKindTerms.BadRow.selector);
        terms.submitRow(address(tokC), row);
        row.maxPrincipal = uint128(MIN_PRINCIPAL);
        _submit(curator, address(tokC), row);
        (Row memory p, uint64 validAt) = terms.pendingRowOf(address(tokC));
        assertEq(validAt, _now() + TIMELOCK, "exactly the floor ticket is admitted, and waits");
        assertEq(p.maxPrincipal, MIN_PRINCIPAL, "at the floor");
    }

    /// @notice The dead-pot override applies in kind, where an uncollected pot gates entry: the guardian lands it and a curator key refuses.
    function test_exemptDeadPots_isTheGuardiansInKind() public {
        (, uint256 settled) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(curator);
        vm.expectRevert(AceVault.NotGuardian.selector);
        vault.exemptDeadPots(settled);
        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit AceVault.DeadPotsExempted(0, settled);
        vault.exemptDeadPots(settled);
    }

    // ---- surface ruling 3: an edit lands at once only if EVERY changed field is a cut; otherwise the WHOLE edit waits ----

    /// @notice A maxPrincipal cut bundled with a maxTenor widening waits whole: not even the maxPrincipal cut lands until the timelock.
    function test_aCutBundledWithAWideningWaitsWhole() public {
        Row memory row = _rowMax(PRINCIPAL);
        row.maxTenor = MAX_TENOR;
        _assertWaits(row);
    }

    /// @notice A maxPrincipal cut bundled with a rate cut waits whole.
    function test_aCutBundledWithARateChangeWaitsWhole() public {
        Row memory row = _rowMax(PRINCIPAL);
        row.lenderAprBps = RATE_BPS - 1;
        _assertWaits(row);
    }

    /// @notice A maxTenor cut bundled with a minTenor change waits whole.
    function test_aCutBundledWithAMinTenorChangeWaitsWhole() public {
        Row memory row = _row();
        (row.minTenor, row.maxTenor) = (MIN_TENOR + 1 days, ROW_MAX_TENOR - 1 days);
        _assertWaits(row);
    }

    /// @notice The terms' two cuts together, every changed field a cut, land at once.
    function test_threeCutsTogetherLandAtOnce() public {
        Row memory row = _rowMax(PRINCIPAL);
        row.maxTenor = MIN_TENOR;
        _submit(guardian, address(tokA), row);
        _sameRow(terms.rowOf(address(tokA)), row, "both cuts live at once");
        (, uint64 validAt) = terms.pendingRowOf(address(tokA));
        assertEq(validAt, 0, "nothing left pending");
    }

    /// @notice A bundled edit that waits is the curator's alone: the guardian, which may cut, cannot submit one.
    function testRevert_theGuardianCannotSubmitABundledEdit() public {
        Row memory row = _rowMax(PRINCIPAL);
        row.maxTenor = MAX_TENOR;
        vm.prank(guardian);
        vm.expectRevert(IInKindTerms.NotCurator.selector);
        terms.submitRow(address(tokA), row);
    }
}
