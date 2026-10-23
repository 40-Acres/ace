// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMultiPairRecord} from "../mocks/MockMultiPairRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceMultiPairRecord
/// @notice The capability the pair-parameterized interface exists for: TWO markets on DIFFERENT pairs share ONE record deployment.
/// @notice Distress, settlement or feed death on pair A leaves pair B's market byte-identically untouched.
/// @notice The isolation is the security property -- a record's blast radius is exactly the markets that chose it.
/// @notice They now share ONE positionManager too, so the custody seam is inside the blast radius being tested.
contract AceMultiPairRecordTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    MockMultiPairRecord internal record;
    MockERC20 internal usdc;
    MockStakeVault internal vaultA;
    MockStakeVault internal vaultB;
    PositionManager internal positionManager;
    bytes32 internal idA;
    bytes32 internal idB;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal T2; // par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3; // the rung above T2
    uint256 internal T4; // the rung above T3
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;

    /// @dev Both markets quote the same token against equally-decimalled vaults, so one par serves both.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vaultA), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vaultA = new MockStakeVault(1);
        vaultB = new MockStakeVault(2);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        ace = AceFixtures.newAce();
        positionManager = PositionManager(ace.POSITION_MANAGER());
        read = new AceReader(address(ace));

        record = new MockMultiPairRecord();
        record.registerPair(address(usdc), address(vaultA));
        record.registerPair(address(usdc), address(vaultB));

        idA = _createMarket(address(vaultA));
        idB = _createMarket(address(vaultB));

        _deposit(idA, 5_000e6);
        _deposit(idA, 5_000e6);
        _deposit(idA, 5_000e6);
        _deposit(idB, 5_000e6);
        _deposit(idB, 5_000e6);
        _deposit(idB, 5_000e6);
    }

    function _createMarket(address collateral) internal returns (bytes32 id) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), collateral);
        p.record = address(record);
        id = ace.createMarket(p);
    }

    function _deposit(bytes32 id, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(bytes32 id, MockStakeVault vault) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev A snapshot of everything pair-B observable: the loan, the funded bucket, the aggregates.
    function _snapshotB(uint256 loanB) internal view returns (bytes memory) {
        return abi.encode(read.loan(loanB), read.restingOf(idB), read.restingOf(idB), read.restingOf(idB), read.marketState(idB));
    }

    // ============ the load-bearing case: shared record, isolated markets ============

    function test_SharedRecord_DistressOnPairA_LeavesPairBByteIdentical() public {
        uint256 loanA = _open(idA, vaultA);
        uint256 loanB = _open(idB, vaultB);
        bytes memory before = _snapshotB(loanB);

        record.setBelow(address(usdc), address(vaultA), true); // ONLY pair A prints distress
        _warpBy(5 hours); // persistence + pending covered

        assertTrue(read.inDistress(loanA), "pair A loan is distressed");
        assertFalse(read.inDistress(loanB), "pair B loan untouched by pair A's prints");
        assertTrue(read.settleable(loanA), "pair A settleable");

        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanB);

        ace.finalize(loanA);
        assertTrue(read.loan(loanA).closedAt != 0, "pair A title moved");
        assertEq(_snapshotB(loanB), before, "pair B market is byte-identical through pair A's settlement");
    }

    // ============ genesis refuses an unregistered pair ============

    function test_Genesis_RefusesUnregisteredPair() public {
        MockStakeVault vaultC = new MockStakeVault(3);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vaultC));
        p.record = address(record); // does not serve (usdc, vaultC)

        vm.expectRevert("record orientation");
        ace.createMarket(p);

        record.registerPair(address(usdc), address(vaultC));
        assertTrue(ace.createMarket(p) != bytes32(0), "registered on the record: admitted");
    }

    // ============ a wrong-pair read is loud, and no created market can reach it ============

    function test_WrongPairRead_RevertsRatherThanAnsweringZero() public {
        MockStakeVault vaultC = new MockStakeVault(3);
        vm.expectRevert(MockMultiPairRecord.UnregisteredPair.selector);
        record.lastObserved(address(usdc), address(vaultC));
        vm.expectRevert(MockMultiPairRecord.UnregisteredPair.selector);
        record.minPrice(address(usdc), address(vaultC));
    }

    // ============ per-pair feed death: A fails closed, B keeps working, A still matures ============

    function test_FeedDeathOnPairA_FailsClosed_PairBLive_MaturityStillSettles() public {
        uint256 loanA = _open(idA, vaultA);
        record.setDead(address(usdc), address(vaultA));

        assertFalse(read.inDistress(loanA), "dead feed proves nothing: no distress");
        assertFalse(read.settleable(loanA), "dead feed cannot admit finalize");
        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanA);

        uint256 loanB = _open(idB, vaultB); // pair B unaffected: opens fine
        assertEq(read.loan(loanB).debt, PRINCIPAL, "pair B keeps working through pair A's outage");

        Loan memory l = read.loan(loanA);
        _warpTo(uint256(l.expiry) + 1);
        ace.forceClose(loanA); // maturity reads no price: tenor bounds the outage
        assertTrue(read.loan(loanA).closedAt != 0, "expiry settles regardless of the record");
    }
}
