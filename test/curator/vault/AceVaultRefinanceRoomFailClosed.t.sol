// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {AceVaultFlows, Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {HostileTerms} from "./HostileTerms.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultRefinanceRoomFailClosedTest
/// @notice The refinance and top-up doors read the product's room as a borrow does: any failure there is zero room, never the product's own refusal.
/// @notice A refinance drawing no fresh cash lands whatever the room does; one drawing fresh cash, and every top-up, refuses `OverCap` on a failed room.
/// @notice CONTROL: a healthy room still caps both at the atom.
contract AceVaultRefinanceRoomFailClosedTest is AceVaultBaseRig {
    uint256 internal constant FRESH = 100e6;
    uint256 internal constant ROOM = 60e6;
    uint256 internal constant BLOCK_GAS = 30_000_000; // a burning room is handed all but the reserve, so a row bounds the call to a block

    IERC721 internal title;
    MarketParams internal mp; // the rig market on a seven-to-thirty-day rail, so a week-long re-term of a month-long loan ends no later

    function setUp() public override {
        super.setUp();
        title = IERC721(ace.POSITION_TITLE());
        mp = _market(address(coll), record);
        mp.maxTenor = RAIL_MAX;
        terms.setTerms(mp, Terms({units: UNITS, principal: PRINCIPAL, tenor: RAIL_MAX, minBufferWad: 0}));
    }

    /// @dev A month-long loan of the rig's principal, its title approved to the vault; the product then answers `principal` over a week.
    function _loan(uint256 principal) internal returns (uint256 loanId) {
        loanId = _borrow();
        vm.prank(borrower);
        title.approve(address(vault), loanId);
        assertEq(read.debtOf(loanId), PRINCIPAL, "premise: the debt is the principal");
        terms.setTerms(mp, Terms({units: UNITS, principal: principal, tenor: TENOR, minBufferWad: 0}));
    }

    function _refi(address v, uint256 loanId, uint256 principal) internal returns (uint256 newId) {
        vm.prank(borrower);
        (newId,) = IAceVaultDoor(v).refinanceFor(loanId, address(coll), principal, TENOR, 0, 0, 0, 0, address(0), "");
    }

    function _refiReverts(address v, uint256 loanId, uint256 principal, bytes memory err) internal {
        vm.prank(borrower);
        vm.expectRevert(err);
        IAceVaultDoor(v).refinanceFor(loanId, address(coll), principal, TENOR, 0, 0, 0, 0, address(0), "");
    }

    function _topReverts(uint256 loanId, uint256 amount, bytes memory err) internal {
        vm.prank(borrower);
        vm.expectRevert(err);
        IAceVaultDoor(address(vault)).drawMoreFor(loanId, amount, 0, 0, 0, "");
    }

    /// @dev The re-term landed: the old loan closed, the successor live at the principal over a week, its title home.
    function _assertReTermed(uint256 loanId, uint256 newId) internal view {
        assertFalse(ace.isLiveLoan(loanId), "the old loan did not close");
        assertTrue(ace.isLiveLoan(newId), "the successor is not live");
        assertEq(read.debtOf(newId), PRINCIPAL, "the successor drew other than the old debt");
        assertEq(read.loan(newId).tenor, TENOR, "the successor is not re-termed");
        assertEq(title.ownerOf(newId), borrower, "the successor's title did not come home");
        assertEq(title.balanceOf(address(vault)), 0, "the vault kept a title");
    }

    /// @dev Re-term `loanId` at its debt with the product's room in mode `m`, and check it landed.
    function _reTermsThrough(MockTerms.Mode m) internal {
        uint256 loanId = _loan(PRINCIPAL);
        terms.setRoom(m, type(uint256).max);
        uint256 newId = _refi(address(vault), loanId, PRINCIPAL);
        _assertReTermed(loanId, newId);
    }

    // ---- a refinance drawing no fresh cash never asks the room's leave ----

    /// @notice A RE-TERM AT THE DEBT lands though the product's room reverts: the room bounds fresh cash only, and a failed room is zero.
    function test_AReTermAtTheDebtLandsThoughTheRoomReverts() public {
        _reTermsThrough(MockTerms.Mode.Revert);
    }

    /// @notice A RE-TERM AT THE DEBT lands though the room answers a short word: a malformed answer is zero, never a decode refusal.
    function test_AReTermAtTheDebtLandsThoughTheRoomAnswersShort() public {
        _reTermsThrough(MockTerms.Mode.ShortWord);
    }

    /// @notice A RE-TERM AT THE DEBT lands though the room return-bombs: the bomb is not copied into the vault's frame.
    function test_AReTermAtTheDebtLandsThoughTheRoomBombs() public {
        _reTermsThrough(MockTerms.Mode.ReturnBomb);
    }

    /// @notice A RE-TERM AT THE DEBT never asks the room: a product burning all its gas there cannot starve the hub leg.
    function test_AReTermAtTheDebtNeverAsksTheRoom() public {
        uint256 loanId = _loan(PRINCIPAL);
        terms.setRoom(MockTerms.Mode.BurnGas, type(uint256).max);
        vm.expectCall(address(terms), abi.encodeWithSelector(MockTerms.room.selector), 0);
        uint256 newId = _refi(address(vault), loanId, PRINCIPAL);
        _assertReTermed(loanId, newId);
    }

    // ---- fresh cash on a failed room refuses by the vault's name ----

    /// @notice A REFINANCE DRAWING FRESH CASH refuses `OverCap` when the room reverts, not with the product's own error.
    function test_AFreshDrawRefusesOverCapWhenTheRoomReverts() public {
        uint256 loanId = _loan(PRINCIPAL + FRESH);
        terms.setRoom(MockTerms.Mode.Revert, type(uint256).max);
        _refiReverts(address(vault), loanId, PRINCIPAL + FRESH, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
    }

    /// @notice A REFINANCE DRAWING FRESH CASH refuses `OverCap` when the room answers short, not with a decode refusal.
    function test_AFreshDrawRefusesOverCapWhenTheRoomAnswersShort() public {
        uint256 loanId = _loan(PRINCIPAL + FRESH);
        terms.setRoom(MockTerms.Mode.ShortWord, type(uint256).max);
        _refiReverts(address(vault), loanId, PRINCIPAL + FRESH, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
    }

    /// @notice A REFINANCE DRAWING FRESH CASH refuses `OverCap` when the room answers two words of the maximum: parity with borrow's exactly-one-word read.
    function test_AFreshDrawRefusesOverCapWhenTheRoomAnswersLong() public {
        uint256 loanId = _loan(PRINCIPAL + FRESH);
        terms.setRoom(MockTerms.Mode.LongWord, type(uint256).max);
        _refiReverts(address(vault), loanId, PRINCIPAL + FRESH, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
    }

    /// @notice A REFINANCE DRAWING FRESH CASH refuses `OverCap` when the room return-bombs: the bomb is never admitted as room.
    function test_AFreshDrawRefusesOverCapWhenTheRoomBombs() public {
        uint256 loanId = _loan(PRINCIPAL + FRESH);
        terms.setRoom(MockTerms.Mode.ReturnBomb, type(uint256).max);
        _refiReverts(address(vault), loanId, PRINCIPAL + FRESH, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
    }

    /// @notice A REFINANCE DRAWING FRESH CASH refuses `OverCap` on a block-sized budget when the room burns its gas: the reserve is left to refuse with.
    function test_AFreshDrawRefusesOverCapWhenTheRoomBurnsItsGas() public {
        uint256 loanId = _loan(PRINCIPAL + FRESH);
        terms.setRoom(MockTerms.Mode.BurnGas, type(uint256).max);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        IAceVaultDoor(address(vault)).refinanceFor{gas: BLOCK_GAS}(loanId, address(coll), PRINCIPAL + FRESH, TENOR, 0, 0, 0, 0, address(0), "");
    }

    /// @notice A ROOM THAT REVERTS WITH THE MAXIMUM AS ITS PAYLOAD is zero room to a fresh refinance draw, not unlimited room and not that payload.
    function test_AFreshDrawRefusesOverCapWhenTheRoomRevertsWithAMaxWord() public {
        (AceVault hv, HostileTerms ht) = _hostile();
        MarketParams memory p = mp;
        p.lender = address(hv);
        ht.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: RAIL_MAX, minBufferWad: 0}));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(hv), UNITS);
        uint256 loanId = hv.borrow(_req(address(coll), UNITS, PRINCIPAL, 0), "", "");
        title.approve(address(hv), loanId);
        vm.stopPrank();
        ht.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL + FRESH, tenor: TENOR, minBufferWad: 0}));
        ht.setView(HostileTerms.View.RevertWord, type(uint256).max);
        _refiReverts(address(hv), loanId, PRINCIPAL + FRESH, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
    }

    /// @dev A funded vault on `HostileTerms` answering the maximum on every view, the rig's caps and rail.
    function _hostile() internal returns (AceVault v, HostileTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new HostileTerms(predicted, HostileTerms.Bind.Honest);
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        VaultSeed.fund(_cfg(), predicted);
        v = new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Hostile", "hVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
        t.setView(HostileTerms.View.Answer, type(uint256).max);
        usdc.mint(alice, LP_CASH);
        vm.startPrank(alice);
        usdc.approve(address(v), LP_CASH);
        v.deposit(LP_CASH, alice);
        vm.stopPrank();
    }

    // ---- a top-up is always fresh cash ----

    /// @notice A TOP-UP refuses `OverCap` when the room reverts, not with the product's own error.
    function test_ATopUpRefusesOverCapWhenTheRoomReverts() public {
        uint256 loanId = _loan(PRINCIPAL + FRESH);
        terms.setRoom(MockTerms.Mode.Revert, type(uint256).max);
        _topReverts(loanId, FRESH, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
    }

    /// @notice A TOP-UP refuses `OverCap` when the room answers short, not with a decode refusal.
    function test_ATopUpRefusesOverCapWhenTheRoomAnswersShort() public {
        uint256 loanId = _loan(PRINCIPAL + FRESH);
        terms.setRoom(MockTerms.Mode.ShortWord, type(uint256).max);
        _topReverts(loanId, FRESH, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
    }

    /// @notice A TOP-UP refuses `OverCap` on a block-sized budget when the room burns its gas, as a fresh refinance draw does.
    function test_ATopUpRefusesOverCapWhenTheRoomBurnsItsGas() public {
        uint256 loanId = _loan(PRINCIPAL + FRESH);
        terms.setRoom(MockTerms.Mode.BurnGas, type(uint256).max);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        IAceVaultDoor(address(vault)).drawMoreFor{gas: BLOCK_GAS}(loanId, FRESH, 0, 0, 0, "");
    }

    // ---- CONTROL: a healthy room binds both doors at the atom ----

    /// @notice CONTROL: a refinance drawing exactly the product's room lands, one atom more refuses `OverCap`.
    function test_AHealthyRoomCapsARefinanceAtTheAtom() public {
        uint256 loanId = _loan(PRINCIPAL + ROOM + 1);
        terms.setRoom(MockTerms.Mode.Answer, ROOM);
        _refiReverts(address(vault), loanId, PRINCIPAL + ROOM + 1, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        terms.setTerms(mp, Terms({units: UNITS, principal: PRINCIPAL + ROOM, tenor: TENOR, minBufferWad: 0}));
        uint256 newId = _refi(address(vault), loanId, PRINCIPAL + ROOM);
        assertEq(read.debtOf(newId), PRINCIPAL + ROOM, "a refinance of exactly the product's room did not land");
    }

    /// @notice CONTROL: a top-up of exactly the product's room lands, one atom more refuses `OverCap`.
    function test_AHealthyRoomCapsATopUpAtTheAtom() public {
        uint256 loanId = _loan(PRINCIPAL + ROOM + 1);
        terms.setRoom(MockTerms.Mode.Answer, ROOM);
        _topReverts(loanId, ROOM + 1, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        terms.setTerms(mp, Terms({units: UNITS, principal: PRINCIPAL + ROOM, tenor: 0, minBufferWad: 0}));
        vm.prank(borrower);
        IAceVaultDoor(address(vault)).drawMoreFor(loanId, ROOM, 0, 0, 0, "");
        assertEq(read.debtOf(loanId), PRINCIPAL + ROOM, "a top-up of exactly the product's room did not land");
    }

    /// @notice CONTROL: a re-term at the debt lands under a zero room, so a zero is the closed answer a fixed failure must read as.
    function test_AReTermAtTheDebtLandsUnderAZeroRoom() public {
        uint256 loanId = _loan(PRINCIPAL);
        terms.setRoom(MockTerms.Mode.Answer, 0);
        uint256 newId = _refi(address(vault), loanId, PRINCIPAL);
        _assertReTermed(loanId, newId);
    }
}
