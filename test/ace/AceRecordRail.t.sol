// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DeleverageDisabled, LoanClosed} from "../../src/ace/hub/Deleverage.sol";
import {NoRecord, NotExpired, NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {LendingAbovePrice} from "../../src/ace/hub/Lender.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRecordRail
/// @notice The record rail and the ONE class it deliberately leaves open.
/// @notice A live deleverage channel reads the record on every crank, so genesis demands one under a band.
/// @notice Band 0 + record 0 stays LEGAL: bullet collateral has no price series to read.
/// @dev In that class the draw cap is INFINITE by ruling, not by accident -- `persistedPrice` reads max.
/// @dev The brakes are the lender's resting bid, TENOR, and `Borrower._gate`'s `trig > floor` refusal.
/// @dev Every record-reading verb must therefore answer BY NAME rather than call into address(0).
/// @dev `NotSettleable` means not YET and keepers retry on it; `NoRecord` means never, and they stop.
contract AceRecordRailTest is Test {
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3;
    uint256 internal T4;
    uint256 internal T_HIGH; // far above any plausible reference price: only an infinite cap admits cash here

    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id; // the record-less market: band 0, record 0

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        (T2, T3, T4, T_HIGH) = (_price(0), _price(480), _price(960), _price(20_040));
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        id = ace.createMarket(_recordless());

        _deposit(id, 5_000e6);
        _deposit(id, 5_000e6);
        _deposit(id, 5_000e6);
    }

    // ---- helpers ----

    /// @dev THE CLASS: no decline band, no record, and no reference seam either.
    /// @dev Built by hand rather than through `AceFixtures.deploy`, which auto-fills a reference.
    function _recordless() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        /// @dev IT BIDS WHERE NO REFERENCE PRICE COULD JUSTIFY, which is the whole point of the class: the
        /// @dev infinite draw cap is only observable at a price a live record would refuse. `T_HIGH` was the
        /// @dev rung a lender rested at; the price is a creation param now, so the MARKET has to name it.
        p.price = T_HIGH;
    }

    /// @dev A banded market shaped so the RECORD rail is the next thing genesis can complain about.
    function _banded() internal view returns (MarketParams memory p) {
        p = _recordless();
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1000;
    }

    function _reject(MarketParams memory p, string memory reason) internal {
        Ace fresh = AceFixtures.newAce(); // a fresh hub, so a duplicate id can never stand in for a refusal
        vm.expectRevert(bytes(reason));
        fresh.createMarket(p);
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    // ============ the rail: a live deleverage channel must name a record ============

    /// @dev The decline channel reads the record on every crank, and its rail sits inside the band block.
    /// @dev So a band with no record is refused, while a band-off market carries no record obligation at all.
    function test_Genesis_RefusesADeleverageBandWithNoRecord() public {
        MarketParams memory p = _banded();
        _reject(p, "record required");
    }

    // ============ rail ORDERING: each refusal names the seam the creator actually left unset ============

    /// @dev The record rail runs FIRST inside the band block, before eps and before the reference.
    /// @dev One missing seam per refusal is the property: a creator fixes them one at a time.
    function test_Order_TheRecordRailAnswersBeforeTheEpsRail() public {
        MarketParams memory p = _banded();
        p.deleverageFloorEpsBps = 0;
        p.fillFeeBps = 0;
        _reject(p, "record required");
    }

    /// @dev eps IS the keeper's pay, and it is refused once the record is supplied.
    function test_Order_TheEpsRailAnswersAfterTheRecordRail() public {
        MarketParams memory p = _banded();
        p.record = address(new MockPersistenceRecord(address(usdc), address(coll)));
        p.deleverageFloorEpsBps = 0;
        p.fillFeeBps = 0; // inert here: no rail couples the fill fee to eps
        _reject(p, "deleverage eps zero");
    }

    /// @dev With record and eps both supplied the band block has nothing left to refuse: the market is born.
    /// @dev This is the whole of what the retired reference rail used to sit in front of.
    function test_Order_RecordAndEpsAreTheWholeSeamList() public {
        MarketParams memory p = _banded();
        p.record = address(new MockPersistenceRecord(address(usdc), address(coll)));
        assertTrue(ace.createMarket(p) != bytes32(0), "record plus eps is a complete armed channel");
    }

    // ============ the class genesis keeps open ============

    /// @dev The ruling in one assertion: no band, no record, and the market is born.
    function test_Genesis_AdmitsTheRecordlessClass() public view {
        MarketParams memory p = ace.idToMarketParams(id);
        assertTrue(id != bytes32(0), "the market was created");
        assertEq(p.deleverageBandBps, 0, "no decline channel");
        assertEq(p.record, address(0), "and no record at all");
    }

    // ============ the verbs that read the record answer by name ============

    /// @dev THE DISTINCTION THAT MATTERS: not `NotSettleable`, which a keeper would poll against forever.
    /// @dev Not a bare revert either -- `expectRevert` on the selector fails on empty returndata.
    function test_Recordless_FinalizeAnswersNoRecord() public {
        uint256 loanId = _open();
        vm.expectRevert(NoRecord.selector);
        vm.prank(keeper);
        ace.finalize(loanId);
    }

    /// @dev The guard sits AFTER `L.closedAt`, and that order is right: a closed loan is done, not unknowable.
    /// @dev Reversing it would answer `NoRecord` for a loan that already settled at tenor.
    function test_Recordless_FinalizeOnAClosedLoanStillAnswersLoanClosed() public {
        uint256 loanId = _open();
        vm.warp(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);

        vm.expectRevert(LoanClosed.selector);
        vm.prank(keeper);
        ace.finalize(loanId);
    }

    /// @dev The old `claimInventory` record-state tests are DELETED WITH THE VERB that replaced it, `redeemInKind`.
    /// @dev `redeemInKind` reads no price at all -- pro rata of a loan-scoped pot -- so there is no record to gate on.

    /// @dev The crank verb is gated on its own BAND before any record read, so it never goes bare.
    /// @dev This is the claim the relocated rail rests on; it is verified here rather than assumed.
    function test_Recordless_TheCrankVerbRefusesOnItsOwnBandGate() public {
        uint256 loanId = _open();

        vm.expectRevert(DeleverageDisabled.selector);
        vm.prank(keeper);
        ace.deleverage(loanId, 0, "");
    }

    // ============ THE RULING MADE REAL: the class is usable, not merely admissible ============

    /// @dev Lenders in, a loan out, and title back at tenor -- the whole life of a bullet-mode market.
    /// @dev `forceClose` reads NO price and is gated only on expiry, which is what makes the class work.
    function test_Recordless_AdmitsLendersOpensALoanAndForceClosesAtTenor() public {
        assertEq(read.marketState(id).cash, 15_000e6, "three buckets of lender cash rest in the market");

        uint256 loanId = _open();
        assertEq(read.loan(loanId).debt, PRINCIPAL, "a real debt is booked");
        assertEq(read.loan(loanId).collateralUnits, COLL, "against real escrowed collateral");
        assertEq(coll.balanceOf(borrower), 0, "custody took every unit");
        assertGt(read.fundingFloor(id, loanId), 0, "and a funding floor was set at the draw");

        uint64 expiry = read.loan(loanId).expiry; // minTenor out: the ONLY brake this class has
        vm.warp(expiry - 1);
        vm.expectRevert(NotExpired.selector);
        vm.prank(keeper);
        ace.forceClose(loanId); // one second short, so the bound is the tenor and not the warp

        vm.warp(expiry); // the gate is `>=`, so the expiry second itself is already closeable
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "tenor closed it with no price read anywhere");
    }

    /// @dev THE INFINITE DRAW CAP, made observable: a tick no reference price could justify still funds.
    /// @dev Priced ~7.4e18 against a 1e18 reference, so only the max sentinel ever admits cash here.
    function test_Recordless_TheDrawCapIsInfiniteSoAnyRestingTickFunds() public {
        _deposit(id, 6_000e6);
        uint256 loanId = _open();
        assertEq(read.fundingFloor(id, loanId), T_HIGH, "the top tick funded the whole draw");
    }

    /// @dev THE CONTRAST that makes the test above load-bearing rather than a fixture accident.
    /// @dev The same deposit into a market differing ONLY in `record` is refused by the price leg.
    function test_Contrast_ALiveRecordClosesTheVeryTickTheRecordlessClassAdmits() public {
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1e18, address(usdc), address(coll)));
        MarketParams memory p = _recordless();
        p.record = address(rec);
        bytes32 capped = ace.createMarket(p);

        usdc.mint(alice, 6_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 6_000e6);
        vm.expectRevert(LendingAbovePrice.selector);
        ace.deposit(capped, 6_000e6);
        vm.stopPrank();
    }

    /// @notice In a record-less market `forceClose` is the ONLY automatic revenue collection there is.
    /// @notice So expiry settlement carrying the sweep is what stops this class collecting nothing, ever.
    /// @dev `deleverage` reverts DeleverageDisabled here and `finalize` reverts NoRecord, both pinned above.
    /// @dev Nobody calls `sweepRevenue`: the point is that collection needs no babysitter in this class.
    function test_Recordless_ExpirySettlementSweeps() public {
        uint256 loanId = _open();
        uint256 banked = read.protocolRevenue(id);
        assertGt(banked, 0, "guard: origination banked a cut in a market with no decline channel");
        assertEq(usdc.balanceOf(AceFixtures.TREASURY), 0, "the treasury starts unpaid");

        vm.warp(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the loan settled at tenor");
        assertEq(usdc.balanceOf(AceFixtures.TREASURY), banked, "and the settlement delivered the banked revenue");
        assertEq(read.protocolRevenue(id), 0, "clearing the counter, with nobody cranking sweepRevenue");
    }
}
