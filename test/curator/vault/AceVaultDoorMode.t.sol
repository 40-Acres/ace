// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MockFeeOnTransferERC20} from "../../mocks/MockFeeOnTransferERC20.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {AceVaultFlows, Terms, VaultConfig} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {AceVaultTail} from "../../../src/vault/libraries/AceVaultTail.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {AceVaultDoorRig, MockDoor} from "./AceVaultDoorRig.sol";
import {MockTerms} from "./MockTerms.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";

/// @dev Answers every call with its own calldata, so a vault forwarding into it returns exactly what it sent.
contract DoorCalldataEcho {
    fallback() external payable {
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            return(0, calldatasize())
        }
    }
}

/// @dev The production mode and terms readers over whatever suffix ends the call.
contract ModeReader {
    function read() external pure returns (bool kind, bool doorMode, address t, address guard, address cash) {
        return (AceVaultTail.inKind(), AceVaultTail.door(), AceVaultTail.terms(), AceVaultTail.guardian(), AceVaultTail.asset());
    }
}

/// @dev The one booking spelling, exposed.
contract BookProbe {
    function book(uint256 units, uint256 price) external pure returns (uint256) {
        return AceVaultFlows.bookValue(units, price);
    }
}

/// @title AceVaultDoorMode
/// @notice A door-mode AceVault against a hostile door: the binding, the collect and its ledger, the return under any key, the room a
/// @notice seized collateral holds, the entry gate and the guardian's exemption, the timelocked write-off, and the lock on every new verb.
contract AceVaultDoorModeTest is AceVaultDoorRig {
    uint256 internal constant SEIZED_SLOT_OFFSET = 9;

    // ---- the binding ----

    /// @notice A door with no code, one naming another vault, and one beside in-kind mode each refuse `DoorNotBound`.
    function test_DoorNotBound_threeWays() public {
        ProductConfig memory pc = _pc();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockTerms t = new MockTerms(predicted, address(ace));
        pc.terms = address(t);
        pc.door = address(0xD00D);
        vm.expectRevert(IAceVaultDoor.DoorNotBound.selector);
        new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "x", "x");

        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        t = new MockTerms(predicted, address(ace));
        MockDoor stray = new MockDoor(address(0xBEEF));
        (pc.terms, pc.door) = (address(t), address(stray));
        vm.expectRevert(IAceVaultDoor.DoorNotBound.selector);
        new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "x", "x");

        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        MockDoor bound = new MockDoor(predicted);
        t = new MockTerms(predicted, address(ace));
        (pc.terms, pc.door, pc.inKind) = (address(t), address(bound), true);
        vm.expectRevert(IAceVaultDoor.DoorNotBound.selector);
        new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "x", "x");
    }

    /// @notice The door may be the terms: one contract naming the vault answers both bindings.
    function test_TheDoorMayBeTheTerms() public {
        ProductConfig memory pc = _pc();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockTerms t = new MockTerms(predicted, address(ace));
        (pc.terms, pc.door) = (address(t), address(t));
        VaultSeed.fund(_cfg(), predicted);
        AceVault v = new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "x", "x");
        assertEq(v.DOOR(), address(t), "the door is the terms");
        assertEq(v.TERMS(), address(t), "and the terms the door");
    }

    /// @notice Only the door collects and returns: anyone else refuses `NotDoor`.
    function test_NotDoor() public {
        uint256 loanId = _defaulted();
        uint256[] memory ids = new uint256[](1);
        ids[0] = loanId;
        vm.prank(stranger);
        vm.expectRevert(IAceVaultDoor.NotDoor.selector);
        dv.collectForfeited(ids);
        usdc.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(IAceVaultDoor.NotDoor.selector);
        dv.returnProceeds(address(coll), 1e6, true);
        vm.stopPrank();
    }

    /// @notice A hub-ask vault's collect still refuses `ModeUnbuilt`: it has no door to hand a pot to.
    function test_AHubAskCollectStillRefusesModeUnbuilt() public {
        (AceVault hubAsk,) = _deploy(_cfg(), _pc(), _caps(UNCAPPED, 0, UNCAPPED));
        vm.expectRevert(AceVault.ModeUnbuilt.selector);
        hubAsk.collectForfeited(new uint256[](0));
    }

    /// @notice The forwarded suffix of a door-mode vault carries the door bit, not the in-kind bit, and its terms in words 2 and 3.
    function test_tail_aDoorVaultsSuffixCarriesTheDoorBitAndTheTerms() public {
        vm.etch(address(AceVaultFlows), address(new DoorCalldataEcho()).code);
        bytes memory cd = abi.encodeCall(IAceVaultDoor.submitWriteOff, (address(coll)));
        vm.prank(curator);
        (bool ok, bytes memory sent) = address(vault).call(cd);
        assertTrue(ok, "premise: the forward reached the echo");
        assertEq(sent.length, cd.length + AceVaultTail.SIZE, "the call plus one fixed suffix");
        bytes memory tail = new bytes(AceVaultTail.SIZE);
        for (uint256 i; i < tail.length; i++) {
            tail[i] = sent[cd.length + i];
        }
        (bool okR, bytes memory got) = address(new ModeReader()).staticcall(abi.encodePacked(ModeReader.read.selector, tail));
        assertTrue(okR, "the readers took the suffix");
        (bool kind, bool doorMode, address t, address guard, address cash) = abi.decode(got, (bool, bool, address, address, address));
        assertFalse(kind, "a door vault is not in kind");
        assertTrue(doorMode, "its door bit is set");
        assertEq(t, vault.TERMS(), "the terms rejoin from words 2 and 3");
        assertEq(guard, vault.GUARDIAN(), "the guardian still decodes beside the terms' high bits");
        assertEq(cash, vault.asset(), "and the asset beside their low bits");
    }

    /// @notice T1: a stranger whose trailing words name it curator and guardian is refused every write-off verb.
    function test_T1_aForgedCuratorIsRefusedTheWriteOff() public {
        uint256 loanId = _defaulted();
        _collect(loanId);
        (bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3) = AceVaultTail.pack(address(ace), stranger, stranger, address(usdc), 0, false);
        (w2, w3) = AceVaultTail.withTerms(w2, w3, stranger);
        bytes memory forged = abi.encodePacked(AceVaultTail.withDoor(w0), w1, w2, w3);
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodePacked(abi.encodeCall(IAceVaultDoor.submitWriteOff, (address(coll))), forged));
        assertFalse(ok, "a forged curator's write-off");
        assertEq(bytes4(ret), IAceVaultDoor.NotCurator.selector, "refused by name");
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        vm.prank(stranger);
        (ok, ret) = address(vault).call(abi.encodePacked(abi.encodeCall(IAceVaultDoor.revokeWriteOff, (address(coll))), forged));
        assertFalse(ok, "a forged guardian's revoke");
        assertEq(bytes4(ret), IAceVaultDoor.NotCurator.selector, "refused by name");
        (,, uint64 at) = _seized(address(coll));
        assertEq(at, _now() + CAP_LOCK, "the curator's write-off stands at the vault's own timelock");
    }

    // ---- the collect and its ledger ----

    /// @notice The goods land at the door, booked at `out * price >> 96`, and the key opens: one Seized event names it all.
    function test_Collect_TheGoodsLandAtTheDoorBookedAtThePrice() public {
        uint256 loanId = _defaulted();
        MarketParams memory mp = ace.idToMarketParams(ace.loanMarket(loanId));
        ace.forceClose(loanId);
        uint256 pot = read.invPotOf(ace.loanMarket(loanId), loanId);
        assertGt(pot, 0, "premise: the settle left a pot");
        uint256 value = AceVaultFlows.bookValue(pot, mp.price);
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.Seized(loanId, address(coll), pot, value);
        uint256 out = _collect(loanId);
        assertEq(out, pot, "the batch answers the pot");
        assertEq(coll.balanceOf(address(door)), pot, "the goods are at the door");
        assertEq(coll.balanceOf(address(vault)), 0, "and never at the vault");
        (uint256 v, bool open, uint64 at) = _seized(address(coll));
        assertEq(v, value, "booked at the market's price");
        assertTrue(open, "the key shuts entry");
        assertEq(at, 0, "no write-off pending");
        assertEq(lens.openSeized(address(vault)), 1, "one key open");
    }

    /// @notice The gate opens once per collateral, closes on a closing return, and re-opens at the next collect.
    function test_Collect_TheGateOpensOncePerKeyAndReopensAfterAClose() public {
        uint256 a = _borrow();
        uint256 b = _borrow();
        _warpTo(read.loan(b).expiry + 1);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
        door.collect(ids);
        assertEq(lens.openSeized(address(vault)), 1, "two pots of one collateral open one key");
        _give(address(coll), 1, true);
        assertEq(lens.openSeized(address(vault)), 0, "a closing return shuts the key");
        uint256 c = _defaulted();
        _collect(c);
        assertEq(lens.openSeized(address(vault)), 1, "the next collect re-opens it");
        (, bool open,) = _seized(address(coll));
        assertTrue(open, "the key is open again");
    }

    /// @notice A booking past the record's width saturates and the collect still succeeds.
    function test_Collect_AHugeBookingSaturates() public {
        uint256 loanId = _defaulted();
        bytes32 s = keccak256(abi.encode(address(coll), uint256(AceVaultFlows.ROOT) + SEIZED_SLOT_OFFSET));
        vm.store(address(vault), s, bytes32(uint256(type(uint184).max - 1)));
        _collect(loanId);
        (uint256 v, bool open,) = _seized(address(coll));
        assertEq(v, type(uint184).max, "the value saturates at the record's width");
        assertTrue(open, "and the key still opens");
    }

    /// @notice A saturating booking's `Seized` reports the value the record took, not the booking's: one atom short of full takes one.
    function test_Collect_ASaturatedBookingEmitsTheStoredRise() public {
        uint256 loanId = _defaulted();
        ace.forceClose(loanId);
        uint256 pot = read.invPotOf(ace.loanMarket(loanId), loanId);
        bytes32 s = keccak256(abi.encode(address(coll), uint256(AceVaultFlows.ROOT) + SEIZED_SLOT_OFFSET));
        vm.store(address(vault), s, bytes32(uint256(type(uint184).max - 1)));
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.Seized(loanId, address(coll), pot, 1);
        _collect(loanId);
    }

    /// @notice The booking helper saturates where `units * price` overflows the word, and floors otherwise.
    function test_BookValue_SaturatesAndFloors() public {
        BookProbe p = new BookProbe();
        assertEq(p.book(type(uint256).max, 2), type(uint256).max, "an overflowing product saturates");
        assertEq(p.book(3, uint256(1) << 95), 1, "1.5 floors to 1");
        assertEq(p.book(0, type(uint256).max), 0, "nothing books nothing");
    }

    /// @notice An id already collected, or repaid, yields zero units and books NOTHING: no open, no void, no event, the batch goes on.
    function test_Collect_AZeroUnitIdBooksNothing() public {
        uint256 a = _defaulted();
        _collect(a);
        _give(address(coll), 1, true);
        (uint256 v0,,) = _seized(address(coll));
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        (,, uint64 at0) = _seized(address(coll));
        uint256 repaid = _borrow();
        vm.prank(borrower);
        usdc.approve(address(ace), type(uint256).max);
        usdc.mint(borrower, 2 * PRINCIPAL);
        vm.prank(borrower);
        ace.repay(repaid, type(uint256).max);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a, repaid);
        vm.recordLogs();
        uint256[] memory out = door.collect(ids);
        assertEq(out[0], 0, "an already-collected id yields zero");
        assertEq(out[1], 0, "a repaid id yields zero");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(vault)) continue;
            assertTrue(logs[i].topics[0] != IAceVaultDoor.Seized.selector, "no Seized for a zero id");
            assertTrue(logs[i].topics[0] != IAceVaultDoor.WriteOffRevoked.selector, "no void for a zero id");
        }
        (uint256 v1, bool open, uint64 at1) = _seized(address(coll));
        assertEq(v1, v0, "the value never moved");
        assertFalse(open, "the closed key stayed closed");
        assertEq(at1, at0, "the pending write-off stands");
        assertEq(lens.openSeized(address(vault)), 0, "no key opened");
    }

    /// @notice A collect onto a key voids its pending write-off, and says so with `WriteOffRevoked(door, c)`.
    function test_Collect_ACollectVoidsAPendingWriteOff() public {
        uint256 a = _defaulted();
        _collect(a);
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        uint256 b = _defaulted();
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.WriteOffRevoked(address(door), address(coll));
        _collect(b);
        (,, uint64 at) = _seized(address(coll));
        assertEq(at, 0, "the write-off is void");
        _warpBy(CAP_LOCK);
        vm.expectRevert(IAceVaultDoor.NothingDue.selector);
        dv.acceptWriteOff(address(coll));
    }

    /// @notice A loan whose market reads as the vault's lender in a quote other than its asset is refused `NotOurLoan`.
    /// @notice CONTROL: on its real market the same loan collects.
    function test_Collect_AForeignQuoteIsNotOurs_TheRealMarketCollects() public {
        uint256 loanId = _defaulted();
        bytes32 id = ace.loanMarket(loanId);
        MarketParams memory mp = ace.idToMarketParams(id);
        assertEq(mp.lender, address(vault), "premise: the vault is the loan's lender");
        mp.quote = address(coll);
        vm.mockCall(address(ace), abi.encodeCall(ace.idToMarketParams, (id)), abi.encode(mp));
        uint256[] memory ids = new uint256[](1);
        ids[0] = loanId;
        vm.expectRevert(IAceVaultDoor.NotOurLoan.selector);
        door.collect(ids);
        vm.clearMockedCalls();
        assertTrue(ace.isLiveLoan(loanId), "the refusal settled nothing");
        assertGt(_collect(loanId), 0, "CONTROL: on its real market the same loan collects");
    }

    /// @notice One batch over two collaterals books each pot under its own key at its own market's price, and opens both keys.
    /// @dev The second loan pledges half the units for half the principal, so its pot differs and a crossed index shows in the value.
    function test_Collect_ABatchOverTwoCollateralsBooksEachPotToItsOwnKey() public {
        uint256 a = _borrow();
        MockStakeVault coll2 = new MockStakeVault(7);
        MarketParams memory p2 = _doorMarket(address(coll2), _record(address(coll2)));
        terms.setTerms(p2, Terms({units: UNITS / 2, principal: PRINCIPAL / 2, tenor: 0, minBufferWad: 0}));
        uint256 b = _borrowAs(borrower, address(coll2), UNITS / 2, PRINCIPAL / 2);
        _warpTo(read.loan(b).expiry + 1);
        (bytes32 ma, bytes32 mb) = (ace.loanMarket(a), ace.loanMarket(b));
        ace.forceClose(a);
        ace.forceClose(b);
        (uint256 potA, uint256 potB) = (read.invPotOf(ma, a), read.invPotOf(mb, b));
        assertGt(potA, 0, "PREMISE: the first id leaves a pot");
        assertGt(potB, 0, "PREMISE: and so does the second");
        assertTrue(potA != potB, "PREMISE: the two pots differ, so a crossed index shows");
        uint256 valueA = AceVaultFlows.bookValue(potA, ace.idToMarketParams(ma).price);
        uint256 valueB = AceVaultFlows.bookValue(potB, ace.idToMarketParams(mb).price);
        uint256[] memory both = new uint256[](2);
        (both[0], both[1]) = (a, b);
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.Seized(a, address(coll), potA, valueA);
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.Seized(b, address(coll2), potB, valueB);
        uint256[] memory out = door.collect(both);
        assertEq(out[0], potA, "the batch answers the first pot");
        assertEq(out[1], potB, "and the second");
        assertEq(coll.balanceOf(address(door)), potA, "the first pot's goods are at the door");
        assertEq(coll2.balanceOf(address(door)), potB, "and the second's");
        (uint256 vA, bool openA,) = _seized(address(coll));
        (uint256 vB, bool openB,) = _seized(address(coll2));
        assertEq(vA, valueA, "the first key books its own pot at its own market's price");
        assertEq(vB, valueB, "the second key books its own pot at its own market's price");
        assertTrue(openA && openB, "both keys open");
        assertEq(lens.openSeized(address(vault)), 2, "two keys shut entry");
    }

    // ---- the collect ends the loan ----

    /// @notice A loan settles at once: the door's collect force-closes it at expiry.
    function test_ALoanSettlesAtExpiry() public {
        uint256 loanId = _borrow();
        _warpAtLeastTo(read.loan(loanId).expiry);
        _collect(loanId);
        assertTrue(ace.isClosed(loanId), "settled at the expiry second");
    }

    /// @notice A loan in persisted distress settles before expiry, by finalize.
    function test_ADistressedLoanFinalizes() public {
        uint256 loanId = _borrow();
        record.setBelow(true);
        _collect(loanId);
        assertTrue(ace.isClosed(loanId), "finalized on distress");
    }

    /// @notice The door's collect never leaves idle under the requests' hold, and leaves every other loan standing.
    /// @dev One loan is collected beside another opened an hour later, so the collect runs while the other's term still runs.
    /// @dev A request for every share binds all of exitable, so the requests' hold is exitable itself before and after, and nothing lends.
    function test_AProductDoorLeavesTheHoldsStanding() public {
        uint256 succ = _borrow();
        _warpBy(1 hours);
        uint256 other = _borrow();
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(shares);
        (uint256 exitable, uint256 held) = lens.holds(address(vault));
        assertEq(held, exitable, "premise: the request binds all of exitable");
        uint256 idle0 = vault.idle();
        Loan memory o0 = read.loan(other);
        uint256 claim0 = read.claimOf(o0.market, other);

        _warpAtLeastTo(read.loan(succ).expiry);
        assertLt(_now(), o0.expiry, "premise: the other loan's term still runs");
        _collect(succ);
        assertTrue(ace.isClosed(succ), "premise: the door settled one loan at its expiry");
        assertTrue(ace.isLiveLoan(other), "and the other stands");
        Loan memory o1 = read.loan(other);
        assertEq(o1.debt, o0.debt, "its debt untouched");
        assertEq(o1.collateralUnits, o0.collateralUnits, "its lot untouched");
        assertEq(o1.expiry, o0.expiry, "its term untouched");
        assertEq(read.claimOf(o0.market, other), claim0, "and its claim untouched");
        assertGe(vault.idle(), idle0, "and spent no idle");
        (exitable, held) = lens.holds(address(vault));
        assertEq(exitable, vault.idle(), "exitable is all of idle");
        assertEq(held, exitable, "the request still binds all of it");
        assertEq(vault.lendable(), 0, "so nothing is lendable");
    }

    /// @notice A loan somebody else already ended is tolerated, and the collect goes on.
    function test_AnAlreadyEndedLoanIsTolerated() public {
        uint256 loanId = _borrow();
        _warpAtLeastTo(read.loan(loanId).expiry);
        ace.forceClose(loanId);
        _collect(loanId);
        assertTrue(ace.isClosed(loanId), "still closed, no revert");
    }

    // ---- the return ----

    /// @notice `(c, 0, false)` refuses; `(c, 0, true)` lands even on a key booked at zero, and closes it.
    function test_Return_NothingReturnedRefusesAndAZeroCloseLands() public {
        uint256 a = _defaulted();
        _collect(a);
        vm.prank(address(door));
        vm.expectRevert(IAceVaultDoor.NothingReturned.selector);
        dv.returnProceeds(address(coll), 0, false);
        bytes32 s = keccak256(abi.encode(address(coll), uint256(AceVaultFlows.ROOT) + SEIZED_SLOT_OFFSET));
        vm.store(address(vault), s, bytes32(uint256(1) << 248)); // open, booked at zero
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.ProceedsReturned(address(coll), 0, true);
        vm.prank(address(door));
        dv.returnProceeds(address(coll), 0, true);
        (uint256 v, bool open,) = _seized(address(coll));
        assertEq(v, 0, "nothing booked");
        assertFalse(open, "and closed");
        assertEq(lens.openSeized(address(vault)), 0, "entry's gate is clear");
    }

    /// @notice `ProceedsReturned` reports whether the key closed: a closing return on a key not open closes nothing and says so.
    /// @dev CONTROL: the same closing return on an open key reports the close.
    function test_Return_AClosingReturnReportsWhatClosed() public {
        usdc.mint(address(door), 2e6);
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.ProceedsReturned(address(coll), 1e6, false);
        door.give(address(coll), 1e6, true);
        _collect(_defaulted());
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.ProceedsReturned(address(coll), 1e6, true);
        door.give(address(coll), 1e6, true);
    }

    /// @notice A key's value falls only by the cash returned, saturating, and a short arrival refuses `ProceedsShort`.
    function test_Return_TheValueFallsByCashAndAShortArrivalRefuses() public {
        uint256 a = _defaulted();
        _collect(a);
        (uint256 v0,,) = _seized(address(coll));
        _give(address(coll), 100e6, false);
        (uint256 v1, bool open,) = _seized(address(coll));
        assertEq(v1, v0 - 100e6, "the value falls by exactly the cash");
        assertTrue(open, "a non-closing return leaves the key open");
        _give(address(coll), v1 + 5e6, false);
        (uint256 v2,,) = _seized(address(coll));
        assertEq(v2, 0, "past the value it saturates at zero");

        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20("Fee", "FEE", 6, 100);
        VaultConfig memory cfg = _cfg();
        cfg.asset = address(fot);
        (,, MockDoor fd) = _deployDoor(cfg, _pc(), _caps(UNCAPPED, UNCAPPED, UNCAPPED));
        fot.mint(address(fd), 1e6);
        vm.expectRevert(IAceVaultDoor.ProceedsShort.selector); // the pull lands first and is measured short, so no expectCall(..., 0) can hold here
        fd.give(address(coll), 1e6, false);
    }

    /// @notice A closing return with a residue re-opens entry once its cash has vested, and keeps the residue holding the row's room.
    function test_Return_ACloseWithAResidueReopensEntryAndHoldsTheRow() public {
        uint256 a = _defaulted();
        _collect(a);
        _expectEntryShut();
        (uint256 v0,,) = _seized(address(coll));
        _give(address(coll), 10e6, true);
        (uint256 v1, bool open,) = _seized(address(coll));
        assertFalse(open, "closed");
        assertEq(v1, v0 - 10e6, "the residue stays booked");
        _warpBy(VEST_W); // the closing return stored the trough hold one window out, over its 10 USDC
        _lp(bob, 1e6);
        assertGt(vault.balanceOf(bob), 0, "entry re-opened");
        assertEq(lens.roomOf(address(vault), address(coll)), ROW - _lent(address(coll)) - v1, "the residue holds the row's room");
    }

    /// @notice An unknown key takes cash with no ledger change; cash after a close and after a write-off lands too.
    function test_Return_AnyKeyTakesCash() public {
        address unknown = address(0x1234);
        uint256 idle0 = vault.idle();
        _give(unknown, 7e6, false);
        (uint256 v, bool open, uint64 at) = _seized(unknown);
        assertEq(v + (open ? 1 : 0) + at, 0, "the unknown key's record never moved");
        assertEq(vault.idle(), idle0 + 7e6, "and the cash landed in idle");
        uint256 a = _defaulted();
        _collect(a);
        _give(address(coll), 1e6, true);
        _give(address(coll), 1e6, false);
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        _warpBy(CAP_LOCK);
        dv.acceptWriteOff(address(coll));
        _give(address(coll), 3e6, false);
        (v,,) = _seized(address(coll));
        assertEq(v, 0, "cash after a write-off lands on a zeroed key");
    }

    /// @notice Returned cash vests, and lowers the drawdown one for one.
    function test_Return_CashVestsAndLowersTheDrawdownOneForOne() public {
        uint256 a = _defaulted();
        _collect(a);
        uint256 dd0 = lens.drawdown(address(vault));
        assertGt(dd0, 0, "premise: the default stepped the drawdown down");
        _give(address(coll), 100e6, false);
        assertEq(lens.drawdown(address(vault)), dd0 - 100e6, "the drawdown falls by the cash");
        assertGt(vault.unvested(), 0, "and the cash vests");
    }

    // ---- room ----

    /// @notice The row's room is `eff - lent - seized`; the total's ignores the seized value, since the drawdown carries the loss.
    function test_Room_TheRowSubtractsSeizedAndTheTotalDoesNot() public {
        uint192 total = 400_000e6;
        (vault, terms, door) = _deployDoor(_cfg(), _pc(), _caps(ROW, UNCAPPED, total));
        dv = IAceVaultDoor(address(vault));
        _setDoorTerms(address(coll), record);
        _lp(alice, LP_CASH);
        uint256 a = _defaulted();
        _borrow();
        _collect(a);
        (uint256 v,,) = _seized(address(coll));
        assertGt(v, 0, "premise: a booked value");
        uint256 lent = _lent(address(coll));
        assertGt(lent, 0, "premise: a live loan holds the row too");
        assertEq(lens.roomOf(address(vault), address(coll)), ROW - lent - v, "the row is held by the lent and the booked value");
        uint256 dd = lens.drawdown(address(vault));
        assertEq(_totalRoom(), total - lent - dd, "the total counts the lent and the drawdown, never the booked value");
    }

    /// @notice The wildcard works in door mode: a raise over it queues, lands after the timelock, and nothing is written under the tracker.
    function test_Room_ADoorVaultRaisesItsWildcard() public {
        (vault, terms, door) = _deployDoor(_cfg(), _pc(), _caps(UNCAPPED, 1_000e6, UNCAPPED));
        vm.prank(curator);
        vault.submitCap(address(0), 5_000e6);
        (uint192 cap,, uint64 validAt) = lens.pendingCapOf(address(vault), address(0));
        assertEq(cap, 5_000e6, "the raise queues");
        _warpTo(validAt);
        vault.acceptCap(address(0));
        assertEq(vault.effectiveCap(address(0xABC)), 5_000e6, "and lands on every unlisted collateral");
        vm.prank(curator);
        vault.submitCap(address(0xABC), 4_000e6);
        assertEq(vault.effectiveCap(address(0xABC)), 4_000e6, "a row under the wildcard lands at once");
    }

    // ---- the entry gate ----

    /// @notice The guardian's exemption covers an open key, and the next settlement voids it.
    function test_Gate_TheExemptionCoversOpenKeysUntilTheNextSettle() public {
        uint256 a = _defaulted();
        _collect(a);
        _expectEntryShut();
        (, uint256 s) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(s);
        _lp(bob, 1e6);
        assertGt(vault.balanceOf(bob), 0, "the exemption opened entry over the open key");
        uint256 b = _defaulted();
        _collect(b);
        (uint256 u,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(u, 0, "premise: no hub pot is unsold, so only the open key can shut entry");
        _expectEntryShut();
    }

    // ---- the write-off ----

    /// @notice The write-off lands only after `CAP_TIMELOCK`; it clears the gate, frees the row and leaves the drawdown.
    function test_WriteOff_LandsAfterTheTimelockAndClearsTheKey() public {
        uint256 a = _defaulted();
        _collect(a);
        vm.prank(stranger);
        vm.expectRevert(IAceVaultDoor.NotCurator.selector);
        dv.submitWriteOff(address(coll));
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.WriteOffSubmitted(address(coll), uint64(_now() + CAP_LOCK));
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        _warpBy(CAP_LOCK - 1);
        vm.expectRevert(IAceVaultDoor.NothingDue.selector);
        dv.acceptWriteOff(address(coll));
        _warpBy(1);
        (uint256 v,,) = _seized(address(coll));
        uint256 dd = lens.drawdown(address(vault));
        uint256 roomBefore = lens.roomOf(address(vault), address(coll));
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.WriteOffAccepted(address(coll), v);
        vm.prank(stranger);
        dv.acceptWriteOff(address(coll));
        (uint256 v1, bool open, uint64 at) = _seized(address(coll));
        assertEq(v1, 0, "the residue is forgiven");
        assertFalse(open, "the key is closed");
        assertEq(at, 0, "and nothing is pending");
        assertEq(lens.openSeized(address(vault)), 0, "the gate is clear");
        assertEq(lens.roomOf(address(vault), address(coll)), roomBefore + v, "the row is freed by the residue");
        assertEq(lens.drawdown(address(vault)), dd, "the drawdown never moved");
        _lp(bob, 1e6);
        assertGt(vault.balanceOf(bob), 0, "entry re-opened");
    }

    /// @notice A write-off of an empty key refuses `NothingSeized`.
    function test_WriteOff_AnEmptyKeyRefuses() public {
        vm.prank(curator);
        vm.expectRevert(IAceVaultDoor.NothingSeized.selector);
        dv.submitWriteOff(address(coll));
    }

    /// @notice The curator or the guardian revokes a pending write-off; a stranger refuses `NotCurator`.
    function test_WriteOff_RevokedByTheCuratorOrTheGuardian() public {
        uint256 a = _defaulted();
        _collect(a);
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        vm.prank(stranger);
        vm.expectRevert(IAceVaultDoor.NotCurator.selector);
        dv.revokeWriteOff(address(coll));
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.WriteOffRevoked(guardian, address(coll));
        vm.prank(guardian);
        dv.revokeWriteOff(address(coll));
        (,, uint64 at) = _seized(address(coll));
        assertEq(at, 0, "the guardian revoked it");
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        vm.prank(curator);
        dv.revokeWriteOff(address(coll));
        (,, at) = _seized(address(coll));
        assertEq(at, 0, "and so does the curator");
    }

    /// @notice A revoke with no write-off pending refuses `NothingDue`, as its siblings refuse their empty cases: on an empty key and an open one.
    /// @dev CONTROL: the same curator's revoke of a pending write-off lands, so the refusal is the empty case and nothing else.
    function test_WriteOff_ARevokeWithNothingPendingRefuses() public {
        vm.prank(curator);
        vm.expectRevert(IAceVaultDoor.NothingDue.selector);
        dv.revokeWriteOff(address(coll));
        _collect(_defaulted());
        (, bool open, uint64 at) = _seized(address(coll));
        assertTrue(open && at == 0, "premise: an open key with nothing pending");
        vm.prank(guardian);
        vm.expectRevert(IAceVaultDoor.NothingDue.selector);
        dv.revokeWriteOff(address(coll));
        vm.prank(curator);
        dv.submitWriteOff(address(coll));
        vm.prank(curator);
        dv.revokeWriteOff(address(coll));
        (,, at) = _seized(address(coll));
        assertEq(at, 0, "CONTROL: a pending write-off is revoked");
    }

    // ---- the lock ----

    /// @notice Every new verb refuses re-entry from a product write call, mid-borrow: the vault's lock is held.
    function test_EveryNewVerbRefusesReentry() public {
        bytes[6] memory calls = [
            abi.encodeCall(IAceVaultDoor.collectForfeited, (new uint256[](0))),
            abi.encodeCall(IAceVaultDoor.returnProceeds, (address(coll), 1, true)),
            abi.encodeCall(IAceVaultDoor.submitWriteOff, (address(coll))),
            abi.encodeCall(IAceVaultDoor.acceptWriteOff, (address(coll))),
            abi.encodeCall(IAceVaultDoor.revokeWriteOff, (address(coll))),
            abi.encodeCall(IAceVaultDoor.extendFor, (uint256(1), uint256(0), uint256(0), bytes(""), bytes("")))
        ];
        for (uint256 i; i < calls.length; i++) {
            terms.setReentry(address(vault), calls[i], true, false);
            _borrow();
            assertTrue(terms.reentered(), "premise: the product re-entered");
            assertFalse(terms.reentryOk(), "the re-entry was refused");
            assertEq(bytes4(terms.reentryError()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, "by the vault's lock");
        }
    }

    function _expectEntryShut() internal {
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(AceVault.InventoryUnsold.selector);
        vault.deposit(1e6, bob);
        vm.stopPrank();
    }
}
