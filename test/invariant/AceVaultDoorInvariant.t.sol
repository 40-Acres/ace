// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {IAceVaultLens} from "../utils/VaultLens.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {AceVaultCaps} from "../../src/curator/libraries/AceVaultCaps.sol";
import {Terms} from "../../src/curator/libraries/AceVaultFlows.sol";
import {BorrowRequest} from "../../src/curator/libraries/AceVaultFlows.sol";
import {IAceVaultDoor} from "../../src/interfaces/IAceVaultDoor.sol";
import {AceVaultDoorRig, MockDoor} from "../curator/vault/AceVaultDoorRig.sol";
import {MockTerms} from "../curator/vault/MockTerms.sol";

/// @notice Drives a door-mode vault through loans, repays, expiries, collects, returns under any key, write-offs, entries and cranks.
/// @dev Every verb is bounded and wrapped, so a refusal is a skipped step; the ledger is read around each, and a move no verb may make is a finding.
contract DoorHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant BORROWER = address(0xB0BA);
    address private constant LP = address(0xA11CE);
    address private constant UNKNOWN = address(0x1234); // a key no market names, which no collect can open

    AceVault public immutable VAULT;
    MockTerms public immutable TERMS;
    MockDoor public immutable DOOR;
    Ace public immutable ACE;
    MockERC20 public immutable USDC;
    IAceVaultLens public immutable LENS;
    address public immutable CURATOR;

    address[3] public keys;
    MarketParams[2] internal _markets;
    uint256[] public loans;

    uint256 public ledgerMovedOffVerb; // a ledger move no verb allows: the property
    uint256 public overTotalAtPlacement; // a placement that left lent plus the drawdown past the total: the property
    uint256 public collectedUnits; // coverage ghost
    uint256 public returnedCash; // coverage ghost
    uint256 public writtenOff; // coverage ghost
    uint256 public overTotalRefused; // coverage ghost: placements the total refused, so the total property is reached

    constructor(
        AceVault v,
        MockTerms t,
        MockDoor d,
        Ace a,
        MockERC20 usdc,
        IAceVaultLens lens,
        address curator,
        MarketParams memory m0,
        MarketParams memory m1
    ) {
        (VAULT, TERMS, DOOR, ACE, USDC, LENS, CURATOR) = (v, t, d, a, usdc, lens, curator);
        (_markets[0], _markets[1]) = (m0, m1);
        keys = [m0.collateral, m1.collateral, UNKNOWN];
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) private pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    function _snap() private view returns (uint256[3] memory v, bool[3] memory open) {
        for (uint256 i; i < 3; i++) {
            (v[i], open[i],) = LENS.seizedOf(address(VAULT), keys[i]);
        }
    }

    /// @dev Every key but `k` must not have moved.
    function _othersStill(uint256 k, uint256[3] memory v0, bool[3] memory o0) private {
        (uint256[3] memory v1, bool[3] memory o1) = _snap();
        for (uint256 i; i < 3; i++) {
            if (i == k) continue;
            if (v1[i] != v0[i] || o1[i] != o0[i]) ledgerMovedOffVerb++;
        }
    }

    function _keyOf(address c) private view returns (uint256) {
        for (uint256 i; i < 3; i++) {
            if (keys[i] == c) return i;
        }
        return 3;
    }

    function borrow(uint256 which, uint256 principal) public {
        uint256 free = VAULT.lendable();
        if (free < 10e6) return;
        principal = _bound(principal, 10e6, free < 5_000e6 ? free : 5_000e6);
        MarketParams memory m = _markets[which % 2];
        uint256 units = principal * 4e12;
        TERMS.setTerms(m, Terms({units: units, principal: principal, tenor: 0, minBufferWad: 0}));
        MockStakeVault(m.collateral).mint(BORROWER, units);
        vm.prank(BORROWER);
        MockStakeVault(m.collateral).approve(address(VAULT), units);
        (uint256[3] memory v0, bool[3] memory o0) = _snap();
        vm.prank(BORROWER);
        try VAULT.borrow(BorrowRequest(m.collateral, units, principal, 0, 0, 0, 0), "", "") returns (uint256 id) {
            loans.push(id);
            uint256 lent = ACE.lenderAssets(address(VAULT), address(USDC)) - ACE.lenderOwed(address(VAULT), address(USDC));
            (uint192 cap,) = LENS.capOf(address(VAULT), address(VAULT));
            if (lent + LENS.drawdown(address(VAULT)) > cap) overTotalAtPlacement++;
        } catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == AceVaultCaps.OverTotal.selector) overTotalRefused++;
        }
        _othersStill(3, v0, o0);
    }

    function repay(uint256 i) public {
        if (loans.length == 0) return;
        uint256 id = loans[i % loans.length];
        if (ACE.isClosed(id)) return;
        uint256 debt = ACE.debtOf(id);
        USDC.mint(BORROWER, debt);
        vm.prank(BORROWER);
        USDC.approve(address(ACE), debt);
        (uint256[3] memory v0, bool[3] memory o0) = _snap();
        vm.prank(BORROWER);
        try ACE.repay(id, debt) {} catch {}
        _othersStill(3, v0, o0);
    }

    function warp(uint256 secs) public {
        vm.warp(vm.getBlockTimestamp() + _bound(secs, 1 hours, 4 days));
        vm.roll(block.number + 1);
    }

    function collect(uint256 i) public {
        if (loans.length == 0) return;
        uint256 id = loans[i % loans.length];
        uint256 k = _keyOf(ACE.idToMarketParams(ACE.loanMarket(id)).collateral);
        (uint256[3] memory v0, bool[3] memory o0) = _snap();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        try DOOR.collect(ids) returns (uint256[] memory out) {
            collectedUnits += out[0];
            (uint256 v1, bool o1,) = LENS.seizedOf(address(VAULT), keys[k]);
            if (v1 < v0[k]) ledgerMovedOffVerb++; // a collect only ever raises a value
            if (out[0] == 0 && (v1 != v0[k] || o1 != o0[k])) ledgerMovedOffVerb++; // a zero-unit id books nothing
            if (out[0] != 0 && !o1) ledgerMovedOffVerb++; // a booking opens its key
        } catch {}
        _othersStill(k, v0, o0);
    }

    function giveBack(uint256 key, uint256 cash, bool closes) public {
        uint256 k = key % 3;
        cash = _bound(cash, 0, 5_000e6);
        if (cash == 0 && !closes) return;
        (uint256[3] memory v0, bool[3] memory o0) = _snap();
        USDC.mint(address(DOOR), cash);
        try DOOR.give(keys[k], cash, closes) {
            returnedCash += cash;
            (uint256 v1, bool o1,) = LENS.seizedOf(address(VAULT), keys[k]);
            if (v1 != (v0[k] > cash ? v0[k] - cash : 0)) ledgerMovedOffVerb++; // a return lowers a value by exactly its cash, saturating at zero
            if (closes ? o1 : o1 != o0[k]) ledgerMovedOffVerb++; // only `closes` touches the flag, and only to clear it
        } catch {}
        _othersStill(k, v0, o0);
    }

    function submitWriteOff(uint256 key) public {
        (uint256[3] memory v0, bool[3] memory o0) = _snap();
        vm.prank(CURATOR);
        try IAceVaultDoor(address(VAULT)).submitWriteOff(keys[key % 3]) {} catch {}
        _othersStill(3, v0, o0);
    }

    function acceptWriteOff(uint256 key) public {
        uint256 k = key % 3;
        (uint256[3] memory v0, bool[3] memory o0) = _snap();
        try IAceVaultDoor(address(VAULT)).acceptWriteOff(keys[k]) {
            writtenOff++;
            (uint256 v1, bool o1,) = LENS.seizedOf(address(VAULT), keys[k]);
            if (v1 != 0 || o1) ledgerMovedOffVerb++; // an accepted write-off zeroes and closes its key
            _othersStill(k, v0, o0);
        } catch {
            _othersStill(3, v0, o0);
        }
    }

    function revokeWriteOff(uint256 key) public {
        (uint256[3] memory v0, bool[3] memory o0) = _snap();
        vm.prank(CURATOR);
        try IAceVaultDoor(address(VAULT)).revokeWriteOff(keys[key % 3]) {} catch {}
        _othersStill(3, v0, o0);
    }

    function deposit(uint256 amt) public {
        amt = _bound(amt, 1e6, 50_000e6);
        USDC.mint(LP, amt);
        vm.prank(LP);
        USDC.approve(address(VAULT), amt);
        (uint256[3] memory v0, bool[3] memory o0) = _snap();
        vm.prank(LP);
        try VAULT.deposit(amt, LP) {} catch {}
        _othersStill(3, v0, o0);
    }

    function crank() public {
        (uint256[3] memory v0, bool[3] memory o0) = _snap();
        VAULT.crank();
        _othersStill(3, v0, o0);
    }

    function keyCount() external pure returns (uint256) {
        return 3;
    }

    /// @dev WALKS EVERY RAIL ONCE before the campaign, deterministically: forge resets to the post-setUp state each run.
    /// @dev Two loans default and are collected, cash returns under one key, the other is written off, and the total refuses a placement.
    function seed() external {
        borrow(0, 4_990e6); // the bound maps this to its largest ask, 5,000e6
        borrow(1, 4_990e6);
        require(loans.length == 2, "SEED: both loans opened");
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.roll(vm.getBlockNumber() + 1);
        collect(0);
        collect(1);
        require(collectedUnits > 0, "SEED: a pot reached the door");
        giveBack(0, 1_000e6, false);
        require(returnedCash > 0, "SEED: the door returned cash");
        submitWriteOff(1);
        vm.warp(vm.getBlockTimestamp() + VAULT.CAP_TIMELOCK());
        vm.roll(vm.getBlockNumber() + 1);
        acceptWriteOff(1);
        require(writtenOff > 0, "SEED: a write-off landed");
        for (uint256 i; i < 4 && overTotalRefused == 0; i++) {
            borrow(i, 4_990e6);
        }
        require(overTotalRefused > 0, "SEED: the total refused a placement");
    }
}

/// @title AceVaultDoorInvariant
/// @notice A door-mode vault's ledger against a door that returns any cash under any key: the open count is the open keys, a value
/// @notice rises only by a collect and falls only by cash or an accepted write-off, and every placement leaves lent plus the drawdown under the total.
contract AceVaultDoorInvariantTest is AceVaultDoorRig {
    uint192 internal constant TOTAL = 20_000e6; // four of the handler's largest asks pass it, so the total binds inside one run
    DoorHandler internal handler;

    function setUp() public override {
        super.setUp();
        (vault, terms, door) = _deployDoor(_cfg(), _pc(), _caps(UNCAPPED, UNCAPPED, TOTAL));
        dv = IAceVaultDoor(address(vault));
        _lp(alice, LP_CASH);
        MockStakeVault coll2 = new MockStakeVault(42);
        MockPersistenceRecord record2 = _record(address(coll2));
        handler = new DoorHandler(vault, terms, door, ace, usdc, lens, curator, _doorMarket(address(coll), record), _doorMarket(address(coll2), record2));
        bytes4[] memory verbs = new bytes4[](10);
        verbs[0] = DoorHandler.borrow.selector;
        verbs[1] = DoorHandler.repay.selector;
        verbs[2] = DoorHandler.warp.selector;
        verbs[3] = DoorHandler.collect.selector;
        verbs[4] = DoorHandler.giveBack.selector;
        verbs[5] = DoorHandler.submitWriteOff.selector;
        verbs[6] = DoorHandler.acceptWriteOff.selector;
        verbs[7] = DoorHandler.revokeWriteOff.selector;
        verbs[8] = DoorHandler.deposit.selector;
        verbs[9] = DoorHandler.crank.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: verbs}));
        targetContract(address(handler));
        handler.seed();
    }

    /// @notice The open count is exactly the number of open keys.
    function invariant_openSeizedCountsTheOpenKeys() public view {
        uint256 n;
        for (uint256 i; i < handler.keyCount(); i++) {
            (, bool open,) = lens.seizedOf(address(vault), handler.keys(i));
            if (open) n++;
        }
        assertEq(lens.openSeized(address(vault)), n, "openSeized is the number of open keys");
    }

    /// @notice A value rises only by a collect, falls only by cash or an accepted write-off, and no verb moves another key.
    function invariant_theLedgerMovesOnlyByItsVerbs() public view {
        assertEq(handler.ledgerMovedOffVerb(), 0, "a ledger move no verb allows");
    }

    /// @notice Every placement leaves what is lent plus the drawdown under the total.
    function invariant_lentPlusDrawdownWithinTheTotalAtEveryPlacement() public view {
        assertEq(handler.overTotalAtPlacement(), 0, "a placement past the total");
    }

    /// @notice Every rail the properties read was reached, so none of them holds over an empty ledger or an unreachable total.
    function afterInvariant() public view {
        assertGt(handler.collectedUnits(), 0, "GHOST: no pot reached the door");
        assertGt(handler.returnedCash(), 0, "GHOST: the door returned no cash");
        assertGt(handler.writtenOff(), 0, "GHOST: no write-off landed");
        assertGt(handler.overTotalRefused(), 0, "GHOST: the total never refused a placement");
    }
}
