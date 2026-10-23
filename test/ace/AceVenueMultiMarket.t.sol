// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {BelowMinDebt} from "../../src/ace/hub/Borrower.sol";
import {MarketExists} from "../../src/ace/hub/MarketInit.sol";
import {NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceVenueMultiMarket
/// @notice N same-pair markets with different creator params on ONE record + reference, all at once.
/// @notice N is THREE: two would read as a supersession hand-off rather than the steady state.
/// @dev The twin is `AceMultiPairRecord` (one record, DIFFERENT pairs); here only the market id differs.
/// @dev Isolation is LOGICAL, per market id -- no per-market deployment stands between them.
/// @dev The shared record is many-to-one BY DESIGN, so a dip reaching all three is the requirement, not a leak.
contract AceVenueMultiMarketTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    bytes32 internal idA;
    bytes32 internal idB;
    bytes32 internal idC;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    int24 internal constant SPACING = PocDeployConfig.TICK_SPACING;
    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3;
    uint256 internal T4;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant B_MIN_DEBT = 1_000e6; // B's own dust floor, far over the fixture's 10e6

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(1);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        ace = AceFixtures.newAce();
        positionManager = PositionManager(ace.POSITION_MANAGER());
        read = new AceReader(address(ace));

        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory a = _params();
        MarketParams memory b = _params();
        MarketParams memory c = _params();
        b.minDebt = B_MIN_DEBT; // a different dust floor
        c.minCoverageWad = 1.8e18; // a different trigger coverage multiple
        (idA, idB, idC) = (ace.createMarket(a), ace.createMarket(b), ace.createMarket(c));

        bytes32[3] memory ids = [idA, idB, idC];
        for (uint256 i; i < 3; i++) {
            _deposit(ids[i], 5_000e6);
            _deposit(ids[i], 5_000e6);
            _deposit(ids[i], 5_000e6);
        }
    }

    /// @dev One record, shared verbatim: the three markets differ ONLY in their loan terms.
    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
    }

    function _deposit(bytes32 id, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(bytes32 id, uint256 principal) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Everything about a market an outside observer can see, for a byte-identical comparison.
    function _snapshot(bytes32 id, uint256 loanId) internal view returns (bytes memory) {
        return abi.encode(read.loan(loanId), read.restingOf(id), read.restingOf(id), read.restingOf(id), read.marketState(id));
    }

    // ============ the requirement itself: N concurrent markets on one venue ============

    /// @dev All three name the SAME record and the SAME reference, and genesis admits every one of them.
    function test_OneVenue_AdmitsThreeConcurrentMarkets_WithDistinctIds() public view {
        assertTrue(idA != bytes32(0) && idB != bytes32(0) && idC != bytes32(0), "all three created");
        assertTrue(idA != idB && idB != idC && idA != idC, "three ids, not one market rewritten");

        bytes32[3] memory ids = [idA, idB, idC];
        for (uint256 i; i < 3; i++) {
            MarketParams memory p = ace.idToMarketParams(ids[i]);
            assertEq(p.record, address(record), "same record");
            assertEq(p.collateral, address(vault), "same pair");
            assertEq(p.quote, address(usdc), "same pair");
        }
    }

    /// @dev The id IS the params hash, so N markets are exactly N distinct creator configurations.
    /// @dev That is what stops an attach silently rewriting a live market's terms.
    function test_IdenticalParamsOnTheSameVenue_IsTheSameMarket_AndRefused() public {
        vm.expectRevert(MarketExists.selector);
        ace.createMarket(_params());
    }

    // ============ each one functions, and none of them is "the market" ============

    /// @dev B's higher dust floor gates B ALONE: the same draw is legal on A and C at the same instant.
    function test_PerMarketParamsGateIndependently_OnOneVenue() public {
        uint256 small = B_MIN_DEBT - 1;
        assertGt(_open(idA, small), 0, "A takes a draw under B's floor");
        assertGt(_open(idC, small), 0, "C takes it too");

        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        vm.expectRevert(BelowMinDebt.selector); // B's own minDebt, never a venue-level gate
        ace.open(idB, COLL, small, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        assertGt(_open(idB, B_MIN_DEBT), 0, "B takes its own legal draw");
    }

    /// @dev Three live loans on one venue: a repayment on A leaves B and C byte-identical.
    function test_ThreeLiveMarkets_MoveIndependently() public {
        uint256 loanA = _open(idA, PRINCIPAL);
        uint256 loanB = _open(idB, PRINCIPAL);
        uint256 loanC = _open(idC, PRINCIPAL);

        bytes memory beforeB = _snapshot(idB, loanB);
        bytes memory beforeC = _snapshot(idC, loanC);

        usdc.mint(borrower, PRINCIPAL);
        vm.startPrank(borrower);
        usdc.approve(address(ace), PRINCIPAL);
        ace.repay(loanA, PRINCIPAL / 2);
        vm.stopPrank();

        assertLt(read.loan(loanA).debt, PRINCIPAL, "A's debt fell");
        assertEq(_snapshot(idB, loanB), beforeB, "B untouched by A's repayment");
        assertEq(_snapshot(idC, loanC), beforeC, "C untouched by A's repayment");
    }

    // ============ the shared record is many-to-one, and settlement stays per-market ============

    /// @dev ONE persisted dip reaches all three at once: the aggregate-exposure case, by design.
    /// @dev Settling A is still a per-market act, so B and C stay open and stay each other's business.
    function test_OneDipOnTheSharedRecord_ReachesEveryMarket_SettlementStaysPerMarket() public {
        uint256 loanA = _open(idA, PRINCIPAL);
        uint256 loanB = _open(idB, PRINCIPAL);
        uint256 loanC = _open(idC, PRINCIPAL);

        record.setBelowBand(read.triggerPrice(loanA));
        _warpBy(5 hours); // persistence + pending covered

        assertTrue(read.inDistress(loanA), "A distressed by the shared dip");
        assertTrue(read.inDistress(loanB), "B distressed by the SAME dip");
        assertTrue(read.inDistress(loanC), "C distressed by the SAME dip");

        bytes memory beforeC = _snapshot(idC, loanC);
        ace.finalize(loanA);
        assertTrue(read.loan(loanA).closedAt != 0, "A's title moved");
        assertFalse(read.loan(loanB).closedAt != 0, "B survives A's settlement");
        assertEq(_snapshot(idC, loanC), beforeC, "C is byte-identical through A's settlement");
    }

    /// @dev C's fatter k lifts its trigger, so one venue-wide print is judged against each market's own params.
    function test_TheSameRecordJudgesEachMarketByItsOwnParams() public {
        uint256 loanA = _open(idA, PRINCIPAL);
        uint256 loanC = _open(idC, PRINCIPAL);
        assertGt(read.triggerPrice(loanC), read.triggerPrice(loanA), "C's fatter k lifts its trigger");

        record.setBelowBand(read.triggerPrice(loanA)); // a band under A's trigger is under C's too
        _warpBy(5 hours);
        assertTrue(read.settleable(loanC), "C is reached by a dip below A's trigger");

        record.setBelowBand(read.triggerPrice(loanC) * 2); // a band over every trigger: nobody sits under it
        assertFalse(read.inDistress(loanA), "the dip lifted for A");
        assertFalse(read.inDistress(loanC), "and for C, on the same record");

        vm.expectRevert(NotSettleable.selector);
        ace.finalize(loanA);
    }

    /// @dev Tenor bounds each market on the venue independently: A matures and closes while B lives on.
    function test_MaturityClosesOneMarketsLoan_LeavingTheVenuesOthersOpen() public {
        uint256 loanA = _open(idA, PRINCIPAL);
        uint256 loanB = _open(idB, PRINCIPAL);

        Loan memory l = read.loan(loanA);
        _warpTo(uint256(l.expiry) + 1);
        ace.forceClose(loanA);

        assertTrue(read.loan(loanA).closedAt != 0, "A closed at its own expiry");
        assertFalse(read.loan(loanB).closedAt != 0, "B is not closed by A's expiry");
    }
}
