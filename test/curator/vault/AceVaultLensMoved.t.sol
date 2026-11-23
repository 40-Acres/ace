// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAceVaultLens, VaultLens} from "../../utils/VaultLens.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultCaps, ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {AceVaultDoorRig} from "./AceVaultDoorRig.sol";
import {MockTerms} from "./MockTerms.sol";

/// @dev The lens rows both rigs share: every moved view against the vault's own storage, and a borrow of exactly `roomOf`.
abstract contract LensMovedChecks is AceVaultBaseRig {
    uint256 internal constant REQUESTED = 3;
    uint256 internal constant REQUESTS = 4;
    uint256 internal constant CAPS = 6;
    uint256 internal constant PENDING_CAPS = 7;
    uint256 internal constant NAV_HIGH = 8;

    function _lensOf() internal view virtual returns (IAceVaultLens);

    function _word(bytes32 s) internal view returns (uint256) {
        return uint256(vm.load(address(vault), s));
    }

    function _at(uint256 k) internal pure returns (bytes32) {
        return bytes32(uint256(AceVaultFlows.ROOT) + k);
    }

    function _key(address key, uint256 k) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, _at(k)));
    }

    /// @dev Every moved view reads what the vault itself stores, and the computed ones the vault's own formula.
    function _checkMovedViews() internal {
        uint256 shares = vault.balanceOf(alice) / 4;
        vm.prank(alice);
        vault.requestExit(shares);
        _checkRequests(shares);
        _checkCaps();
        _checkNav(shares);
    }

    function _checkRequests(uint256 shares) internal view {
        IAceVaultLens l = _lensOf();
        assertEq(l.requestedShares(address(vault)), _word(_at(REQUESTED)), "requestedShares is the stored figure");
        assertEq(l.requestedShares(address(vault)), shares, "and it is the escrow");
        (uint256 s, uint64 at) = l.requestOf(address(vault), alice);
        assertEq(s, shares, "requestOf: the shares");
        assertEq(at, _now() + vault.REQUEST_LEASE(), "requestOf: the lease's end");
        assertEq(s, _word(_key(alice, REQUESTS)), "requestOf reads the stored request");
    }

    function _checkCaps() internal {
        IAceVaultLens l = _lensOf();
        (uint192 cap, bool listed) = l.capOf(address(vault), address(coll));
        uint256 w = _word(_key(address(coll), CAPS));
        assertEq(cap, uint192(w), "capOf: the stored row");
        assertEq(listed, (w >> 192) & 1 != 0, "capOf: the stored listing");
        vm.prank(curator);
        vault.submitCap(address(0), 1e6);
        vm.prank(curator);
        vault.submitCap(address(0), 2e6);
        (uint192 pc, bool pl, uint64 validAt) = l.pendingCapOf(address(vault), address(0));
        assertEq(pc, 2e6, "pendingCapOf: the raise");
        assertTrue(pl, "pendingCapOf: listed");
        assertEq(validAt, _now() + CAP_LOCK, "pendingCapOf: due after the timelock");
    }

    function _checkNav(uint256 shares) internal view {
        IAceVaultLens l = _lensOf();
        uint256 high = _word(_at(NAV_HIGH));
        assertEq(l.navHigh(address(vault)), Math.max(high, vault.grossNav()), "navHigh as a sync would leave it");
        assertEq(l.drawdown(address(vault)), Math.saturatingSub(high, vault.grossNav()), "drawdown below the stored high");
        (uint256 exitable, uint256 heldReq) = l.holds(address(vault));
        assertEq(exitable, vault.idle(), "holds: idle");
        assertEq(heldReq, Math.min(vault.idle(), vault.previewRedeem(shares)), "holds: the requests' worth, capped by idle");
        assertGt(heldReq, 0, "premise: the request holds something");
    }

    /// @dev A borrow of exactly `roomOf` lands, and one atom more refuses by the row.
    function _checkExactRoom() internal {
        IAceVaultLens l = _lensOf();
        uint256 room = l.roomOf(address(vault), address(coll));
        assertLt(room, vault.lendable(), "premise: the row binds, not the cash");
        uint256 snap = vm.snapshotState();
        _setPrincipal(room + 1);
        _expectBorrowRevertAt(room + 1, AceVaultFlows.OverCap.selector);
        vm.revertToState(snap);
        _setPrincipal(room);
        uint256 loanId = _borrowAs(borrower, address(coll), _unitsFor(room), room);
        assertGe(read.loan(loanId).debt, room, "the loan drew the whole room");
    }

    /// @dev Units that cover `principal` at twice its par worth, so coverage never binds a room row.
    function _unitsFor(uint256 principal) internal pure returns (uint256) {
        return principal * 2e12 + 1e18;
    }

    function _setPrincipal(uint256 p) internal virtual;

    function _expectBorrowRevertAt(uint256 principal, bytes4 sel) internal {
        uint256 units = _unitsFor(principal);
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(vault), units);
        BorrowRequest memory r = _req(address(coll), units, principal, 0);
        vm.expectRevert(sel);
        vault.borrow(r, "", "");
        vm.stopPrank();
    }
}

/// @title AceVaultLensMoved
/// @notice The eight views S3 moves off the vault, read from the lens: each equals the vault's own stored or computed figure.
contract AceVaultLensMovedTest is LensMovedChecks {
    IAceVaultLens internal lens;

    function setUp() public override {
        super.setUp();
        lens = VaultLens.deploy();
    }

    function _lensOf() internal view override returns (IAceVaultLens) {
        return lens;
    }

    function _setPrincipal(uint256 p) internal override {
        MarketParams memory m = _market(address(coll), record);
        terms.setTerms(m, Terms({units: _unitsFor(p), principal: p, tenor: 0, minBufferWad: 0}));
    }

    function test_Lens_EachMovedViewIsTheVaultsOwnFigure() public {
        _borrow();
        _checkMovedViews();
    }

    function test_Lens_ABorrowOfExactlyRoomOfLands() public {
        (vault, terms) = _deploy(_cfg(), _pc(), _caps(1_500e6, 0, UNCAPPED));
        _setTerms(address(coll), record);
        _lp(alice, LP_CASH);
        _borrow();
        _checkExactRoom();
    }

    /// @notice C8: the lens's preview admits exactly what a hub-ask `borrow` admits, and refuses a market of the wrong inventory mode as it does.
    function test_Preview_HubAskEqualsTheBorrow() public {
        _previewEqualsBorrow(lens, vault);
        MarketParams memory m = _market(address(coll), record);
        m.inventoryAsk = false;
        terms.setTerms(m, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, 0);
        vm.expectRevert(AceVaultCaps.WrongInventoryMode.selector);
        lens.previewTerms(address(vault), borrower, r, "");
    }

    /// @notice C8: on an in-kind vault the preview takes the in-kind mode, as the borrow does.
    function test_Preview_InKindEqualsTheBorrow() public {
        ProductConfig memory pc = _pc();
        pc.inKind = true;
        (AceVault ik, MockTerms t) = _deploy(_cfg(), pc, _caps(UNCAPPED, 0, UNCAPPED));
        (vault, terms) = (ik, t);
        MarketParams memory m = _market(address(coll), record);
        m.inventoryAsk = false;
        terms.setTerms(m, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        _lp(alice, LP_CASH);
        _previewEqualsBorrow(lens, vault);
    }

    function _previewEqualsBorrow(IAceVaultLens l, AceVault v) internal {
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, 0);
        (bytes32 id, MarketParams memory mp, Terms memory t) = l.previewTerms(address(v), borrower, r, "");
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        Loan memory loan = read.loan(loanId);
        assertEq(loan.market, id, "the borrow lands in the previewed market");
        assertEq(loan.collateralUnits, t.units, "pledging the previewed units");
        assertEq(loan.tenor, t.tenor == 0 ? mp.minTenor : t.tenor, "for the previewed term");
    }
}

/// @title AceVaultLensMovedDoor
/// @notice The same lens rows on a door-mode vault, where the row's room also nets what its goods at the door still hold.
contract AceVaultLensMovedDoorTest is AceVaultDoorRig, LensMovedChecks {
    function setUp() public override(AceVaultDoorRig, AceVaultBaseRig) {
        AceVaultDoorRig.setUp();
    }

    function _lensOf() internal view override returns (IAceVaultLens) {
        return lens;
    }

    function _setPrincipal(uint256 p) internal override {
        MarketParams memory m = _doorMarket(address(coll), record);
        terms.setTerms(m, Terms({units: _unitsFor(p), principal: p, tenor: 0, minBufferWad: 0}));
    }

    function test_Lens_EachMovedViewIsTheVaultsOwnFigure() public {
        _borrow();
        _checkMovedViews();
    }

    /// @notice With a collateral's goods at the door, a borrow of exactly `roomOf` still lands and one atom more still refuses.
    function test_Lens_ABorrowOfExactlyRoomOfLandsWithGoodsAtTheDoor() public {
        uint256 a = _defaulted();
        _collect(a);
        _give(address(coll), 1, true);
        (uint256 v,,) = _seized(address(coll));
        assertGt(v, 0, "premise: the row is held by goods at the door");
        _checkExactRoom();
    }

    /// @notice C8: on a door-mode vault the preview takes the door mode, as the borrow does.
    function test_Preview_DoorEqualsTheBorrow() public {
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, 0);
        (bytes32 id, MarketParams memory mp, Terms memory t) = lens.previewTerms(address(vault), borrower, r, "");
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        Loan memory loan = read.loan(loanId);
        assertEq(loan.market, id, "the borrow lands in the previewed market");
        assertEq(loan.collateralUnits, t.units, "pledging the previewed units");
        assertEq(loan.tenor, t.tenor == 0 ? mp.minTenor : t.tenor, "for the previewed term");
        MarketParams memory m = _market(address(coll), record);
        terms.setTerms(m, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        vm.expectRevert(AceVaultCaps.WrongInventoryMode.selector);
        lens.previewTerms(address(vault), borrower, r, "");
    }
}
