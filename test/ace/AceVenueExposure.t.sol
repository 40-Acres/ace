// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceLens, VenueExposure} from "../../src/ace/lens/AceLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMultiPairRecord} from "../mocks/MockMultiPairRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @notice A record that answers genesis honestly, then reverts on every read the lens probes.
/// @dev Models a source turning hostile AFTER markets exist on it; the views must survive it.
contract HostileAfterGenesisRecord is MockMultiPairRecord {
    bool internal _armed;

    function arm() external {
        _armed = true;
    }

    function lastObserved(address quote, address collateral) external view override returns (uint256) {
        if (_armed) revert("hostile");
        return _state(quote, collateral).observed;
    }

    function minPrice(address quote, address collateral) external view override returns (uint256) {
        if (_armed) revert("hostile");
        return _state(quote, collateral).minPrice;
    }
}

/// @notice A record whose unmatched selectors return a megabyte of zeros instead of reverting.
/// @dev The mitigation-2 subject: probes must survive it and the gas cost must stay bounded.
contract ReturnBombRecord is MockMultiPairRecord {
    // genesis probes UNIT_SCALE() and refuses a fallback-fabricated answer; declare the real one
    uint256 public constant UNIT_SCALE = 1 << 96;

    fallback() external {
        assembly {
            return(0, 0x100000)
        }
    }
}

/// @notice A record that DOES answer the two non-interface probes: the ACE-VENUE-class shape.
contract DepthfulRecord is MockMultiPairRecord {
    uint256 public depth;
    address internal _writer;

    function setDepth(uint256 d) external {
        depth = d;
    }

    function setWriter(address w) external {
        _writer = w;
    }

    function minDepthOverWindow(uint256) external view returns (uint256) {
        return depth;
    }

    function WRITER() external view returns (address) {
        return _writer;
    }
}

/// @title AceVenueExposure
/// @notice The disclosure views the venue-dependency ruling rests on (the design record).
/// @dev Sound-but-incomplete aggregates over a caller-supplied id list, keyed per record AND ordered pair.
/// @dev Never-revert probes for the non-interface reads; a lender's per-collateral exposure is the hub's `lenderByCollateral`.
contract AceVenueExposureTest is Test {
    Ace internal ace;
    AceLens internal lens;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault; // the shared-pair collateral
    MockStakeVault internal vaultOther; // a second pair on the same record
    MockMultiPairRecord internal record; // the queried venue
    MockMultiPairRecord internal otherRecord; // a different venue, same pair

    bytes32 internal mA; // record, pair, k=1.4, window 1800
    bytes32 internal mB; // record, pair, k=1.5, window 3600
    bytes32 internal mC; // record, pair, k=1.6, window 1800
    bytes32 internal mD; // OTHER record, same pair -> rejected in venue query
    bytes32 internal mE; // record, OTHER pair -> rejected in venue query

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal T2; // ticks above par; both pairs here are 6-vs-18, so one par serves them
    uint256 internal T4;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal PX; // the record's price for both pairs, in the hub's frame; assigned in setUp

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(1);
        vaultOther = new MockStakeVault(2);
        (T2, T4) = (_price(0), _price(960));
        PX = AceFixtures.px(2e18, address(usdc), address(vault));
        ace = AceFixtures.newAce();
        positionManager = PositionManager(ace.POSITION_MANAGER());
        lens = new AceLens(address(ace));

        record = new MockMultiPairRecord();
        otherRecord = new MockMultiPairRecord();
        _registerAll(record);
        _registerAll(otherRecord);

        mA = _create(address(record), address(vault), 1.4e18);
        mB = _create(address(record), address(vault), 1.5e18);
        mC = _create(address(record), address(vault), 1.6e18);
        mD = _create(address(otherRecord), address(vault), 1.4e18);
        mE = _create(address(record), address(vaultOther), 1.4e18);

        _deposit(mA, 5_000e6);
        _deposit(mA, 5_000e6);
        _deposit(mB, 3_000e6);
        _deposit(mC, 1_000e6);
        _deposit(mD, 7_000e6);
        _deposit(mE, 9_000e6);
        _open(mA); // one live loan so the verified sum carries lent principal, not just cash
    }

    function _registerAll(MockMultiPairRecord r) internal {
        r.registerPair(address(usdc), address(vault));
        r.registerPair(address(usdc), address(vaultOther));
        r.setObserved(address(usdc), address(vault), PX);
        r.setMinPrice(address(usdc), address(vault), PX);
        r.setObserved(address(usdc), address(vaultOther), PX);
        r.setMinPrice(address(usdc), address(vaultOther), PX);
    }

    /// @dev NO WINDOW ARGUMENT: a market carries none, and every market behind one record shares its window.
    function _create(address rec, address collateral, uint256 k) internal returns (bytes32) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), collateral);
        p.record = rec;
        p.minCoverageWad = k;
        return ace.createMarket(p);
    }

    function _deposit(bytes32 id, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(bytes32 id) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _venueIds() internal view returns (bytes32[] memory ids) {
        ids = new bytes32[](5);
        ids[0] = mA;
        ids[1] = mB;
        ids[2] = mC;
        ids[3] = mD;
        ids[4] = mE;
    }

    // ============ the soundness filter ============

    /// @dev THE CASH SUMS ARE GONE FROM THE VIEW, and their going is a correctness fix rather than a loss.
    /// @dev It reported `totalLent`, `totalCash` and their sum as `lendable`, summed PER MARKET. Those three
    /// @dev aggregates moved onto the LENDER's pool, keyed by (lender, quote) ACROSS their markets -- so adding
    /// @dev them market by market would count one lender's money once per market they run behind that record.
    /// @dev What the view still discloses is the SET: how many ids name this record and pair, how many do not,
    /// @dev and the shared risk dials -- which is what a venue integrator cannot derive from a market id alone.
    function test_VenueExposure_CountsOnlyMarketsNamingTheRecordAndPair() public view {
        VenueExposure memory v = lens.venueExposure(address(record), address(usdc), address(vault), _venueIds());
        assertEq(v.verified, 3, "mA/mB/mC name this record and pair");
        assertGt(v.minK, 0, "and the verified set really reported its dials");
    }

    function test_VenueExposure_ReportsRejectedCount() public view {
        VenueExposure memory v = lens.venueExposure(address(record), address(usdc), address(vault), _venueIds());
        assertEq(v.rejected, 2, "mD (other record) and mE (other pair) are filtered, visibly");
    }

    function test_VenueExposure_EmptySetIsZeroNotRevert() public view {
        VenueExposure memory v = lens.venueExposure(address(record), address(usdc), address(vault), new bytes32[](0));
        assertEq(v.verified, 0, "nothing verified");
        assertEq(v.rejected, 0, "nothing rejected");
        assertEq(v.minK, 0, "nothing verified, so no dial was reported");
        assertEq(v.capPrice, PX, "the record itself still answers");
    }

    function test_VenueExposure_UnknownIdCountsAsRejected() public view {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = mA;
        ids[1] = keccak256("no such market");
        VenueExposure memory v = lens.venueExposure(address(record), address(usdc), address(vault), ids);
        assertEq(v.verified, 1, "the real market counts");
        assertEq(v.rejected, 1, "the phantom id is rejected, not summed as zeros");
    }

    /// @dev Dedup would be O(n^2) on an unbounded caller list; the caller controls the list.
    /// @dev OVERSTATING exposure is the safe direction for a risk disclosure -- never "fix" this silently.
    function test_VenueExposure_DuplicateIdDoubleCounts() public view {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = mA;
        ids[1] = mA;
        VenueExposure memory v = lens.venueExposure(address(record), address(usdc), address(vault), ids);
        assertEq(v.verified, 2, "counted twice: overstatement, the safe direction for a risk disclosure");
    }

    // ============ the probes ============

    function test_VenueExposure_OracleClassRecordAnswersNoDepth() public view {
        // MockMultiPairRecord implements neither minDepthOverWindow nor WRITER -- the ORACLE shape.
        VenueExposure memory v = lens.venueExposure(address(record), address(usdc), address(vault), _venueIds());
        assertFalse(v.depthSupported, "no depth function is a fact, not a failure");
        assertEq(v.minDepth, 0, "depth zero when unanswered");
        assertEq(v.writer, address(0), "writer zero when unanswered");
        assertTrue(v.recordObserving, "the price side still answers");
        assertEq(v.capPrice, PX, "cap read through the probe");
    }

    function test_VenueExposure_DepthfulRecordReportsDepthAndWriter() public {
        DepthfulRecord deep = new DepthfulRecord();
        deep.registerPair(address(usdc), address(vault));
        deep.setObserved(address(usdc), address(vault), PX);
        deep.setMinPrice(address(usdc), address(vault), PX);
        deep.setDepth(123_456e6);
        deep.setWriter(address(0xBEEF));
        bytes32 m = _create(address(deep), address(vault), 1.4e18);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = m;
        VenueExposure memory v = lens.venueExposure(address(deep), address(usdc), address(vault), ids);
        assertEq(v.verified, 1, "market on the depthful record verifies");
        assertTrue(v.depthSupported, "depth probe answered");
        assertEq(v.minDepth, 123_456e6, "depth read through the probe");
        assertEq(v.writer, address(0xBEEF), "writer surfaced for the pool-level roll-up");
    }

    function test_VenueExposure_HostileRecordDoesNotRevert() public {
        HostileAfterGenesisRecord hostile = new HostileAfterGenesisRecord();
        hostile.registerPair(address(usdc), address(vault));
        bytes32 m = _create(address(hostile), address(vault), 1.4e18);
        hostile.arm();
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = m;
        VenueExposure memory v = lens.venueExposure(address(hostile), address(usdc), address(vault), ids);
        assertEq(v.verified, 1, "the ledger half still aggregates");
        assertEq(v.capPrice, 0, "hostile price read degrades to zero");
        assertFalse(v.recordObserving, "a reverting record is not live");
    }

    /// @dev Mitigation 2: a probe target can return a megabyte instead of reverting.
    /// @dev The view must still answer, and the cost must stay a number rather than a guess.
    function test_VenueExposure_ReturnBombRecordDoesNotRevert_GasBounded() public {
        ReturnBombRecord bomb = new ReturnBombRecord();
        bomb.registerPair(address(usdc), address(vault));
        bomb.setObserved(address(usdc), address(vault), PX);
        bomb.setMinPrice(address(usdc), address(vault), PX);
        bytes32 m = _create(address(bomb), address(vault), 1.4e18);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = m;
        uint256 g0 = gasleft();
        VenueExposure memory v = lens.venueExposure(address(bomb), address(usdc), address(vault), ids);
        uint256 used = g0 - gasleft();
        assertEq(v.verified, 1, "the view answered through the bomb");
        assertLt(used, 9_600_000, "a 1MB return bomb stays a bounded cost: four callee expansions, measured 8830474");
    }

    /// @dev Mitigation 1: capPrice 0 with recordObserving TRUE is a genesis/unspanned record failing closed.
    /// @dev Borrowing dark is NOT a zero-exposure signal; recordObserving false means no living record at all.
    function test_VenueExposure_NoPriceRecordReportsObservingButCapZero() public {
        record.setMinPrice(address(usdc), address(vault), 0); // window unspanned: the NoPrice state
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = mA;
        VenueExposure memory v = lens.venueExposure(address(record), address(usdc), address(vault), ids);
        assertEq(v.capPrice, 0, "a record with no price answers zero cap");
        assertTrue(v.recordObserving, "but the record is alive: it cannot price, it is not dead");
    }

    // ============ self-consistency and heterogeneity ============

    /// @dev DELETED: `test_VenueExposure_AggregateMatchesPerMarketState`. It re-summed `totalLent + totalCash`
    /// @dev market by market and compared that to the view's own figure. Both aggregates left `MarketState` for
    /// @dev the lender's pool, and the view stopped reporting them for the reason the header above gives: a
    /// @dev per-market sum counts one lender's money once per market. There is no drift left to check.

    /// @dev THE WINDOW SPREAD IS GONE, and its absence is the point: every market behind one record
    /// @dev shares that record's window by construction, so a min and a max could only report it twice.
    /// @dev The k spread survives, because coverage is still a per-market term.
    function test_VenueExposure_WindowIsTheRecordsAndKSpreadReported() public view {
        VenueExposure memory v = lens.venueExposure(address(record), address(usdc), address(vault), _venueIds());
        assertEq(v.distressWindow, 0, "the mock discloses no window, and the lens reports that honestly");
        assertEq(v.settleWindow, 0, "likewise the seizure window");
        assertEq(v.minK, 1.4e18, "smallest k");
        assertEq(v.maxK, 1.6e18, "largest k: a given lift buys more debt at low k");
    }
}
