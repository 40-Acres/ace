// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {CuratorTerms, CuratorTermsConfig, Listing, Row} from "../../../src/entities/curated/CuratorTerms.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {Extension, IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {Lend, RefinanceRequest} from "../../../src/interfaces/IVaultTerms.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {CuratedVaults} from "../../utils/CuratedVaults.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @notice A product built on CuratorTerms: it halves the pledge the base asks for, gates every vault lend, and can refuse every extension.
contract HalvingTerms is CuratorTerms {
    error Gated();

    bool public gated; // every lend the vault makes refuses while set
    bool public refuseExtensions; // every extension refuses while set

    constructor(CuratorTermsConfig memory c, Listing[] memory l) CuratorTerms(c, l) {}

    /// @notice Set both switches.
    function set(bool gated_, bool refuse_) external {
        (gated, refuseExtensions) = (gated_, refuse_);
    }

    /// @notice The base's market and draw, with half the pledge.
    function borrowTerms(address caller, BorrowRequest calldata r, bytes calldata data) public view override returns (MarketParams memory mp, Terms memory t) {
        (mp, t) = super.borrowTerms(caller, r, data);
        t.units /= 2;
    }

    /// @notice The gate, past the sealed vault checks: refuses `Gated` on any lend the vault makes while set.
    function _productBeforeLend(Lend, MarketParams calldata, uint256, bytes calldata) internal view override {
        if (gated) revert Gated();
    }

    /// @notice The base's answer, unless extensions are refused.
    function admitsExtension(Extension calldata e, bytes calldata data) public view override returns (bool) {
        return !refuseExtensions && super.admitsExtension(e, data);
    }
}

/// @notice A product that names what the vault hands its write calls, caps its own room and its refinance draw, and reads the base's market helpers.
contract CuratorProbeTerms is CuratorTerms {
    error Before(Lend kind, bytes32 market, uint256 loanId); // a probed beforeLend, naming what the vault handed it
    error After(Lend kind, bytes32 market, uint256 loanId, address holder); // a probed afterLend, naming what the vault handed it

    uint256 public beforeKinds; // bit k set: a beforeLend of kind k refuses `Before`
    uint256 public afterKinds; // bit k set: an afterLend of kind k refuses `After`
    uint256 public roomCap = type(uint256).max; // the product's own room ceiling over the base's
    uint256 public principalCap = type(uint256).max; // the most a refinance answer draws

    constructor(CuratorTermsConfig memory c, Listing[] memory l) CuratorTerms(c, l) {}

    /// @notice Set every probe.
    function set(uint256 before_, uint256 after_, uint256 room_, uint256 principal_) external {
        (beforeKinds, afterKinds, roomCap, principalCap) = (before_, after_, room_, principal_);
    }

    /// @notice The base's refinance answer, its draw clamped to `principalCap`.
    function refinanceTerms(address holder, uint256 loanId, RefinanceRequest calldata r, bytes calldata data)
        public
        view
        override
        returns (MarketParams memory mp, Terms memory t)
    {
        (mp, t) = super.refinanceTerms(holder, loanId, r, data);
        t.principal = Math.min(t.principal, principalCap);
    }

    /// @notice The base's room, under `roomCap`.
    function room(MarketParams calldata mp) public view override returns (uint256) {
        return Math.min(super.room(mp), roomCap);
    }

    /// @notice Past the sealed vault checks, a refusal naming the door's kind, market and loan while that kind is probed.
    function _productBeforeLend(Lend kind, MarketParams calldata mp, uint256 loanId, bytes calldata) internal view override {
        if ((beforeKinds >> uint8(kind)) & 1 != 0) revert Before(kind, keccak256(abi.encode(mp)), loanId);
    }

    /// @notice Past the sealed vault check, a refusal naming the door's kind, market, loan and holder while that kind is probed.
    function _productAfterLend(Lend kind, MarketParams calldata mp, uint256 loanId, address holder, bytes calldata) internal view override {
        if ((afterKinds >> uint8(kind)) & 1 != 0) revert After(kind, keccak256(abi.encode(mp)), loanId, holder);
    }

    /// @notice Today's market for `collateral`, built from the base's internal helpers as a product would build it.
    function todaysMarket(address collateral) external view returns (MarketParams memory) {
        Row memory w = _rows[collateral];
        return _market(w, collateral, _buffered(w, collateral));
    }

    /// @notice Whether `collateral`'s live row still names `mp`, by the base's own test.
    function stillNames(address collateral, MarketParams calldata mp) external view returns (bool) {
        return _names(_rows[collateral], mp);
    }
}

/// @title CuratorTermsSubclassTest
/// @notice A product can extend CuratorTerms' vault answers, and the vault asks the extension on every lending verb.
/// @notice The reshaped pledge is the one the vault pulls and the hub holds; the gate binds a borrow, a top-up and a refinance the base would admit.
/// @notice An extension refusal binds the holder's own extend at the hub, which reaches the product only through `admitsExtension`.
contract CuratorTermsSubclassTest is AceVaultBaseRig {
    uint256 internal constant MIN_P = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint16 internal constant BUFFER_BPS = 1000;
    uint16 internal constant RATE_BPS = 40;
    uint256 internal constant AMOUNT = 200e6; // a top-up's draw

    HalvingTerms internal ht;

    function setUp() public override {
        super.setUp();
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({
            collateral: address(coll), row: Row({record: address(record), bufferBps: BUFFER_BPS, lenderAprBps: RATE_BPS, minTenor: TENOR, maxTenor: RAIL_MAX})
        });
        CuratedVaults.Terms memory t = CuratedVaults.Terms(MIN_P, COVERAGE, CAP_LOCK, CuratedVaults.UNCAPPED);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        ht = new HalvingTerms(CuratedVaults.termsConfig(predicted, _cfg(), t), l);
        VaultSeed.fund(_cfg(), predicted);
        vault = new AceVault(_cfg(), CuratedVaults.product(address(ht), CAP_LOCK), CuratedVaults.caps(predicted, l, t.rowCap), "Halving", "hVLT");
        assertEq(address(vault), predicted, "rig: the vault landed off its predicted address");
        _lp(alice, LP_CASH);
        IERC721 titles = IERC721(ace.POSITION_TITLE());
        vm.prank(borrower);
        titles.setApprovalForAll(address(vault), true);
    }

    /// @dev A loan to the borrower through the vault at the row's longest term, so a top-up and a refinance have time left.
    function _loan() internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        loanId = vault.borrow(_req(address(coll), UNITS, PRINCIPAL, RAIL_MAX), "", "");
        vm.stopPrank();
    }

    /// @notice The vault pulls, and the hub holds, the subclass's halved pledge; the borrower keeps the other half.
    function test_TheVaultPledgesTheSubclassReshapedUnits() public {
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        assertEq(read.loan(loanId).collateralUnits, UNITS / 2, "the hub holds the subclass's halved pledge");
        assertEq(coll.balanceOf(borrower), UNITS - UNITS / 2, "the borrower keeps the half the subclass left out");
    }

    /// @notice The subclass reshapes the base's draw and nothing else: the market and the principal are the base's own.
    function test_TheSubclassKeepsTheBaseMarket() public view {
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, 0);
        (MarketParams memory mp, Terms memory t) = ht.borrowTerms(borrower, r, "");
        assertEq(mp.record, address(record), "the base's record");
        assertEq(mp.lender, address(vault), "the base's lender");
        assertEq(mp.lenderAprBps, RATE_BPS, "the base's rate");
        assertEq(t.principal, PRINCIPAL, "the base's principal");
        assertEq(t.tenor, TENOR, "the base's default tenor");
        assertEq(t.units, UNITS / 2, "only the pledge is reshaped");
    }

    /// @notice All three sealed checks in `beforeLend` refuse ahead of a shut product gate, each by its own name; past them, the gate's own error.
    function test_EverySealedCheckRunsAheadOfTheProductGate() public {
        (MarketParams memory mp,) = ht.borrowTerms(borrower, _req(address(coll), UNITS, PRINCIPAL, 0), "");
        ht.set(true, false);
        vm.prank(stranger);
        vm.expectRevert(CuratorTerms.NotVault.selector);
        ht.beforeLend(Lend.Borrow, mp, 0, "");
        vm.mockCall(address(vault), abi.encodeWithSignature("ACE()"), abi.encode(address(0xDEAD)));
        vm.prank(address(vault));
        vm.expectRevert(CuratorTerms.VaultMismatch.selector);
        ht.beforeLend(Lend.Borrow, mp, 0, "");
        vm.clearMockedCalls();
        vm.mockCall(address(vault), abi.encodeWithSignature("DOOR()"), abi.encode(address(ht)));
        vm.mockCall(address(vault), abi.encodeWithSignature("GUARDIAN()"), abi.encode(address(0)));
        vm.prank(address(vault));
        vm.expectRevert(CuratorTerms.GuardianUnset.selector);
        ht.beforeLend(Lend.Borrow, mp, 0, "");
        vm.clearMockedCalls();
        vm.prank(address(vault));
        vm.expectRevert(HalvingTerms.Gated.selector);
        ht.beforeLend(Lend.Borrow, mp, 0, "");
    }

    /// @notice The gate refuses a borrow with the subclass's own error, and the same borrow opens once the gate lifts.
    function test_TheGateRefusesABorrowTheBaseTakes() public {
        ht.set(true, false);
        _expectBorrowRevert(address(coll), HalvingTerms.Gated.selector);
        ht.set(false, false);
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        assertEq(read.loan(loanId).collateralUnits, UNITS / 2, "the ungated borrow opened, on the halved pledge");
    }

    /// @notice The gate refuses a top-up in place, which asks the refinance answer and never the borrow answer; ungated, the same top-up lands.
    function test_TheGateRefusesATopUp() public {
        uint256 loanId = _loan();
        uint256 debt = ace.debtOf(loanId);
        ht.set(true, false);
        vm.prank(borrower);
        vm.expectRevert(HalvingTerms.Gated.selector);
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        ht.set(false, false);
        vm.prank(borrower);
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        assertGt(ace.debtOf(loanId), debt, "the ungated top-up drew more");
    }

    /// @notice The gate refuses a refinance that draws more, and the same refinance lands once the gate lifts.
    function test_TheGateRefusesARefinance() public {
        uint256 loanId = _loan();
        ht.set(true, false);
        vm.prank(borrower);
        vm.expectRevert(HalvingTerms.Gated.selector);
        vault.refinanceFor(loanId, address(coll), PRINCIPAL + 50e6, 0, 0, 0, 0, 0, address(0), "");
        ht.set(false, false);
        vm.prank(borrower);
        (uint256 next,) = vault.refinanceFor(loanId, address(coll), PRINCIPAL + 50e6, 0, 0, 0, 0, 0, address(0), "");
        assertGt(ace.debtOf(next), ace.debtOf(loanId), "the ungated refinance drew more");
    }

    /// @notice The holder's own extend at the hub lands while the subclass admits it, and refuses once the subclass refuses extensions.
    function test_TheRefusalBindsTheHoldersExtendAtTheHub() public {
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        _warpBy(1 days);
        _fundFee(borrower);
        assertEq(vault.admitsExtension(_ext(loanId), ""), IRollPolicy.admitsExtension.selector, "premise: the base admits the extension");
        ht.set(false, true);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
        ht.set(false, false);
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        Loan memory l = read.loan(loanId);
        assertEq(l.expiry, _now() + l.tenor, "the admitted extension landed");
    }

    /// @notice The vault's own extend meets both switches: the gate through `_productBeforeLend` as Extend, the refusal through the hub's ask of the vault.
    function test_TheGateAndTheRefusalEachBindTheVaultsOwnExtend() public {
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        _warpBy(1 days);
        _fundVault(borrower);
        ht.set(true, false);
        vm.prank(borrower);
        vm.expectRevert(HalvingTerms.Gated.selector);
        vault.extendFor(loanId, type(uint256).max, 0, "", "");
        ht.set(false, true);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        vault.extendFor(loanId, type(uint256).max, 0, "", "");
        ht.set(false, false);
        vm.prank(borrower);
        uint256 fee = vault.extendFor(loanId, type(uint256).max, 0, "", "");
        Loan memory l = read.loan(loanId);
        assertEq(l.expiry, _now() + l.tenor, "the vault's extend landed once both switches were off");
        assertGt(fee, 0, "premise: the extend added time and paid for it");
    }

    /// @notice A stranger's extend at the hub never meets the vault's door, so the refusal reaches it through `admitsExtension` alone.
    function test_TheRefusalBindsAStrangersExtendAtTheHub() public {
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        _warpTo(read.loan(loanId).expiry - 1 days);
        _fundFee(stranger);
        ht.set(false, true);
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", borrower);
        assertFalse(ok, "the holder is refused while extensions are refused");
        assertEq(why, PolicyRefused.selector, "the holder's refusal is the policy's");
        vm.prank(stranger);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
        ht.set(false, false);
        uint256 strangerCash = usdc.balanceOf(stranger);
        uint256 borrowerCash = usdc.balanceOf(borrower);
        vm.prank(stranger);
        uint256 fee = ace.extend(loanId, 0, "");
        Loan memory l = read.loan(loanId);
        assertEq(l.expiry, _now() + l.tenor, "the admitted stranger's extend landed");
        assertGt(fee, 0, "premise: the stranger's extend added time");
        assertEq(strangerCash - usdc.balanceOf(stranger), fee, "the stranger paid the fee");
        assertEq(usdc.balanceOf(borrower), borrowerCash, "the holder paid nothing for a stranger's extend");
    }

    /// @notice The refusal alone leaves a top-up and a refinance open, as neither needs `admitsExtension` to land: their gate is `_productBeforeLend`.
    function test_TheRefusalAloneLeavesATopUpAndARefinanceOpen() public {
        uint256 loanId = _loan();
        ht.set(false, true);
        uint256 debt = ace.debtOf(loanId);
        vm.prank(borrower);
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        assertEq(ace.debtOf(loanId), debt + AMOUNT, "the top-up landed under the refusal");
        vm.prank(borrower);
        (uint256 next,) = vault.refinanceFor(loanId, address(coll), debt + AMOUNT + 50e6, 0, 0, 0, 0, 0, address(0), "");
        assertEq(ace.debtOf(next), debt + AMOUNT + 50e6, "the refinance landed under the refusal");
    }

    /// @notice Neither switch reaches a repay, which never asks the product: a gated, refusing product still lets the holder close and reclaim the pledge.
    function test_NeitherSwitchBlocksARepay() public {
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        ht.set(true, true);
        uint256 debt = ace.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertEq(ace.debtOf(loanId), 0, "the gated product's loan repaid whole");
        assertTrue(read.loan(loanId).closedAt != 0, "the repay closed the loan");
        assertEq(read.unitsOwedOf(loanId, borrower), UNITS / 2, "the whole halved pledge is owed back to the holder");
    }

    /// @notice A plain CuratorTerms on the same vault and row answers as the subclass does, but for the pledge the subclass halves and the refusal it adds.
    function test_APlainCuratorTermsAnswersAsTheBase() public {
        CuratorTerms plain = new CuratorTerms(CuratedVaults.termsConfig(address(vault), _cfg(), _curated()), _table());
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, 0);
        (MarketParams memory pm, Terms memory pt) = plain.borrowTerms(borrower, r, "");
        (MarketParams memory hm, Terms memory st) = ht.borrowTerms(borrower, r, "");
        assertEq(keccak256(abi.encode(pm)), keccak256(abi.encode(hm)), "the plain terms and the subclass name one market");
        assertEq(pt.units, UNITS, "the plain terms pledge all that was asked");
        assertEq(st.units, UNITS / 2, "the subclass pledges half");
        assertEq(keccak256(abi.encode(pt.principal, pt.tenor, pt.minBufferWad)), keccak256(abi.encode(st.principal, st.tenor, st.minBufferWad)), "one draw");
        uint256 loanId = _loan();
        RefinanceRequest memory rr = RefinanceRequest(address(coll), PRINCIPAL + 50e6, 0, 0, 0, 0, 0, address(0));
        (pm, pt) = plain.refinanceTerms(borrower, loanId, rr, "");
        (hm, st) = ht.refinanceTerms(borrower, loanId, rr, "");
        assertEq(keccak256(abi.encode(pm, pt)), keccak256(abi.encode(hm, st)), "the refinance answer is the base's, untouched");
        assertEq(keccak256(abi.encode(hm)), ace.loanMarket(loanId), "premise: the refinance answer is the loan's own market");
        assertEq(plain.room(hm), ht.room(hm), "one room");
        assertEq(plain.entryCap(alice, 0), ht.entryCap(alice, 0), "one entry cap");
        Extension memory e = _ext(loanId);
        assertTrue(plain.admitsExtension(e, "") && ht.admitsExtension(e, ""), "both admit the extension while the subclass admits");
        ht.set(false, true);
        assertTrue(plain.admitsExtension(e, ""), "the plain terms still admit it");
        assertFalse(ht.admitsExtension(e, ""), "the subclass refuses it");
    }

    /// @dev The curated figures this suite deploys with.
    function _curated() internal pure returns (CuratedVaults.Terms memory) {
        return CuratedVaults.Terms(MIN_P, COVERAGE, CAP_LOCK, CuratedVaults.UNCAPPED);
    }

    /// @dev The one row this suite lists.
    function _table() internal view returns (Listing[] memory l) {
        l = new Listing[](1);
        l[0] = Listing({
            collateral: address(coll), row: Row({record: address(record), bufferBps: BUFFER_BPS, lenderAprBps: RATE_BPS, minTenor: TENOR, maxTenor: RAIL_MAX})
        });
    }

    /// @dev Fund `who` for any fee the vault pulls, approving the vault.
    function _fundVault(address who) internal {
        usdc.mint(who, 1_000_000e6);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }
}

/// @title CuratorTermsProbeTest
/// @notice The vault reaches every CuratorTerms answer a product overrides: the room, the refinance draw and both write calls, on every lending verb.
/// @notice Each write call is handed its door's kind, the market it lends in, the loan and the holder; the base's helpers build the base's own market.
contract CuratorTermsProbeTest is AceVaultBaseRig {
    uint256 internal constant MIN_P = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint16 internal constant BUFFER_BPS = 1000;
    uint16 internal constant RATE_BPS = 40;
    uint256 internal constant AMOUNT = 200e6; // a top-up's draw
    uint256 internal constant ALL = type(uint256).max; // no probe ceiling
    uint256 internal constant BORROW = uint256(1) << uint8(Lend.Borrow);
    uint256 internal constant EXTEND = uint256(1) << uint8(Lend.Extend);
    uint256 internal constant REFINANCE = uint256(1) << uint8(Lend.Refinance);

    CuratorProbeTerms internal pt;
    CuratorTerms internal plain; // a plain CuratorTerms on the same vault and row: the base's answers

    function setUp() public override {
        super.setUp();
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({
            collateral: address(coll), row: Row({record: address(record), bufferBps: BUFFER_BPS, lenderAprBps: RATE_BPS, minTenor: TENOR, maxTenor: RAIL_MAX})
        });
        CuratedVaults.Terms memory t = CuratedVaults.Terms(MIN_P, COVERAGE, CAP_LOCK, CuratedVaults.UNCAPPED);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        pt = new CuratorProbeTerms(CuratedVaults.termsConfig(predicted, _cfg(), t), l);
        VaultSeed.fund(_cfg(), predicted);
        vault = new AceVault(_cfg(), CuratedVaults.product(address(pt), CAP_LOCK), CuratedVaults.caps(predicted, l, t.rowCap), "Probe", "pVLT");
        assertEq(address(vault), predicted, "rig: the vault landed off its predicted address");
        plain = new CuratorTerms(CuratedVaults.termsConfig(address(vault), _cfg(), t), l);
        _lp(alice, LP_CASH);
        IERC721 titles = IERC721(ace.POSITION_TITLE());
        vm.prank(borrower);
        titles.setApprovalForAll(address(vault), true);
        usdc.mint(borrower, 1_000_000e6);
        vm.prank(borrower);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev A loan to the borrower through the vault at the row's longest term, so a top-up and a refinance have time left.
    function _loan() internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        loanId = vault.borrow(_req(address(coll), UNITS, PRINCIPAL, RAIL_MAX), "", "");
        vm.stopPrank();
    }

    /// @dev Expect the rig's borrow to revert with exactly `err`, the borrower minted and approved.
    function _borrowExpecting(bytes memory err) internal {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, 0);
        vm.expectRevert(err);
        vault.borrow(r, "", "");
        vm.stopPrank();
    }

    /// @dev The market id the product answers a rig borrow with.
    function _borrowMarket() internal view returns (bytes32) {
        (MarketParams memory mp,) = pt.borrowTerms(borrower, _req(address(coll), UNITS, PRINCIPAL, 0), "");
        return keccak256(abi.encode(mp));
    }

    /// @notice A stranger's call to either sealed hook refuses `NotVault` while the product's probes are armed; the vault's call reaches the probe.
    function test_TheSealedCallerCheckRunsAheadOfBothProbes() public {
        (MarketParams memory mp,) = pt.borrowTerms(borrower, _req(address(coll), UNITS, PRINCIPAL, 0), "");
        pt.set(ALL, ALL, ALL, ALL);
        vm.prank(stranger);
        vm.expectRevert(CuratorTerms.NotVault.selector);
        pt.beforeLend(Lend.Borrow, mp, 0, "");
        vm.prank(stranger);
        vm.expectRevert(CuratorTerms.NotVault.selector);
        pt.afterLend(Lend.Borrow, mp, 0, borrower, "");
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(CuratorProbeTerms.After.selector, Lend.Borrow, keccak256(abi.encode(mp)), uint256(0), borrower));
        pt.afterLend(Lend.Borrow, mp, 0, borrower, "");
    }

    /// @notice Each lending verb hands `_productBeforeLend` its own kind, the market it lends in, and the loan: zero for a borrow, the loan for the rest.
    function test_BeforeLendNamesEachDoor() public {
        pt.set(BORROW, 0, ALL, ALL);
        _borrowExpecting(abi.encodeWithSelector(CuratorProbeTerms.Before.selector, Lend.Borrow, _borrowMarket(), uint256(0)));
        pt.set(0, 0, ALL, ALL);
        uint256 loanId = _loan();
        bytes32 own = ace.loanMarket(loanId);
        _warpBy(1 days);
        pt.set(EXTEND, 0, ALL, ALL);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CuratorProbeTerms.Before.selector, Lend.Extend, own, loanId));
        vault.extendFor(loanId, type(uint256).max, 0, "", "");
        pt.set(REFINANCE, 0, ALL, ALL);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CuratorProbeTerms.Before.selector, Lend.Refinance, own, loanId));
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CuratorProbeTerms.Before.selector, Lend.Refinance, own, loanId));
        vault.refinanceFor(loanId, address(coll), PRINCIPAL + 50e6, 0, 0, 0, 0, 0, address(0), "");
    }

    /// @notice A gate on one kind binds that kind's doors alone: one on Borrow leaves the extend, the top-up and the refinance open, so gate all three.
    function test_AGateOnBorrowAloneLeavesTheOtherDoorsOpen() public {
        uint256 loanId = _loan();
        _warpBy(1 days);
        pt.set(BORROW, 0, ALL, ALL);
        _borrowExpecting(abi.encodeWithSelector(CuratorProbeTerms.Before.selector, Lend.Borrow, _borrowMarket(), uint256(0)));
        uint256 debt = ace.debtOf(loanId);
        vm.startPrank(borrower);
        vault.extendFor(loanId, type(uint256).max, 0, "", "");
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        (uint256 next,) = vault.refinanceFor(loanId, address(coll), debt + AMOUNT + 50e6, 0, 0, 0, 0, 0, address(0), "");
        vm.stopPrank();
        assertEq(ace.debtOf(next), debt + AMOUNT + 50e6, "the extend, the top-up and the refinance all landed past a Borrow-only gate");
        pt.set(EXTEND | REFINANCE, 0, ALL, ALL);
        uint256 opened = _loan();
        assertEq(read.loan(opened).borrower, borrower, "a borrow lands past a gate on the other two kinds");
    }

    /// @notice Each lending verb hands `_productAfterLend` its kind, its market, the loan it opened or kept, and the holder, once the lend has landed.
    function test_AfterLendNamesEachDoorsLoanAndHolder() public {
        uint256 loanId = _loan();
        bytes32 own = ace.loanMarket(loanId);
        pt.set(0, BORROW, ALL, ALL);
        _borrowExpecting(abi.encodeWithSelector(CuratorProbeTerms.After.selector, Lend.Borrow, _borrowMarket(), loanId + 1, borrower));
        _warpBy(1 days);
        pt.set(0, EXTEND, ALL, ALL);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CuratorProbeTerms.After.selector, Lend.Extend, own, loanId, borrower));
        vault.extendFor(loanId, type(uint256).max, 0, "", "");
        pt.set(0, REFINANCE, ALL, ALL);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CuratorProbeTerms.After.selector, Lend.Refinance, own, loanId, borrower));
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CuratorProbeTerms.After.selector, Lend.Refinance, own, loanId + 1, borrower));
        vault.refinanceFor(loanId, address(coll), PRINCIPAL + 50e6, 0, 0, 0, 0, 0, address(0), "");
        pt.set(0, 0, ALL, ALL);
        vm.prank(borrower);
        (uint256 next,) = vault.refinanceFor(loanId, address(coll), PRINCIPAL + 50e6, 0, 0, 0, 0, 0, address(0), "");
        assertEq(next, loanId + 1, "premise: the refinance's successor is the id its afterLend was handed");
    }

    /// @notice The product's room binds a borrow at its edge: a principal one over it refuses `OverCap`, and a principal exactly at it lands.
    function test_TheProductsRoomBindsABorrowAtItsEdge() public {
        pt.set(0, 0, PRINCIPAL - 1, ALL);
        _borrowExpecting(abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        pt.set(0, 0, PRINCIPAL, ALL);
        uint256 loanId = _loan();
        assertEq(ace.debtOf(loanId), PRINCIPAL, "a borrow exactly at the product's room landed");
    }

    /// @notice The product's room binds a top-up and a refinance on the fresh cash alone: one over refuses, exactly at lands, and none needs no room.
    function test_TheProductsRoomBindsOnlyFreshCash() public {
        uint256 loanId = _loan();
        pt.set(0, 0, AMOUNT - 1, ALL);
        vm.prank(borrower);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        pt.set(0, 0, AMOUNT, ALL);
        uint256 debt = ace.debtOf(loanId);
        vm.prank(borrower);
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        assertEq(ace.debtOf(loanId), debt + AMOUNT, "a top-up exactly at the product's room landed");
        debt = ace.debtOf(loanId);
        pt.set(0, 0, AMOUNT - 1, ALL);
        vm.prank(borrower);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        vault.refinanceFor(loanId, address(coll), debt + AMOUNT, 0, 0, 0, 0, 0, address(0), "");
        pt.set(0, 0, 0, ALL);
        vm.prank(borrower);
        (uint256 next,) = vault.refinanceFor(loanId, address(coll), debt, 0, 0, 0, 0, 0, address(0), "");
        assertEq(ace.debtOf(next), debt, "a refinance drawing no fresh cash landed on a zero room");
    }

    /// @notice An overridden refinance answer binds both doors that ask it: a refinance draws the clamped principal, and a top-up it clamps refuses.
    function test_TheRefinanceAnswerBindsTheRefinanceAndTheTopUp() public {
        uint256 loanId = _loan();
        uint256 debt = ace.debtOf(loanId);
        pt.set(0, 0, ALL, debt);
        vm.prank(borrower);
        vm.expectRevert(IAceVaultDoor.TopUpRefused.selector);
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        pt.set(0, 0, ALL, debt + AMOUNT);
        vm.prank(borrower);
        vault.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        assertEq(ace.debtOf(loanId), debt + AMOUNT, "the top-up landed once the clamp admitted all of it");
        debt = ace.debtOf(loanId);
        pt.set(0, 0, ALL, debt);
        vm.prank(borrower);
        (uint256 next,) = vault.refinanceFor(loanId, address(coll), debt + 50e6, 0, 0, 0, 0, 0, address(0), "");
        assertEq(ace.debtOf(next), debt, "the refinance drew the clamped principal, not the ask");
    }

    /// @notice A product building a market from `_buffered` and `_market` gets the base's market, at the rig price and after the record moves.
    function test_TheBaseHelpersBuildTheBaseMarket() public {
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, 0);
        MarketParams memory built = pt.todaysMarket(address(coll));
        (MarketParams memory base,) = plain.borrowTerms(borrower, r, "");
        assertEq(keccak256(abi.encode(built)), keccak256(abi.encode(base)), "the helpers build the base's market");
        assertEq(built.lender, address(vault), "the helpers name the vault as lender");
        assertTrue(pt.stillNames(address(coll), built), "the base's row test names the market it built");
        uint256 was = built.price;
        record.setMinPrice(AceFixtures.px(3e18, address(usdc), address(coll)));
        built = pt.todaysMarket(address(coll));
        (base,) = plain.borrowTerms(borrower, r, "");
        assertEq(keccak256(abi.encode(built)), keccak256(abi.encode(base)), "the helpers follow the record as the base does");
        assertGt(built.price, was, "premise: the record's move moved the market");
        vm.expectRevert(CuratorTerms.NotListed.selector);
        pt.todaysMarket(address(0xDEAD));
        record.setMinPrice(0);
        vm.expectRevert(CuratorTerms.PriceZero.selector);
        pt.todaysMarket(address(coll));
    }
}
