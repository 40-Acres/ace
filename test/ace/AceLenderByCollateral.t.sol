// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {MarketPairMismatch} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";

/// @title AceLenderByCollateral
/// @notice The hub's per-(lender, quote, collateral) split: principal lent at par, and collateral held in unsold pots.
/// @notice A vault caps its exposure per collateral off this in one read, with nobody poking it, at any collateral count.
/// @dev Every expectation is built INDEPENDENTLY: each loan's raw claim and pot, read through `AceReader`, grouped by its market's params.
/// @dev A live loan in a SECOND collateral stands through most rows, so a split that read zero, or the pair's total, cannot pass.
contract AceLenderByCollateralTest is WarpClock, DeleverageCrank {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockERC20 internal dai;
    MockERC20 internal collX;
    MockERC20 internal collY;
    MockERC20 internal collZ; // 0 decimals, priced off a non-integral record, so a one-atom buy delivers nothing

    address internal lender = address(0x1E4D);
    address internal lender2 = address(0x1E4D2);
    address internal borrower = address(0xB0BA);
    address internal buyer = address(0xB04E5);
    address internal keeper = address(0xCAFE);

    uint256 internal constant SEED = 20_000e6;
    uint256 internal constant PX = 4_500e6;
    uint256 internal constant PY = 3_000e6; // distinct from PX, so no row passes on a coincidence of amounts
    uint256 internal constant PZ = 2_000e6;
    uint256 internal constant BAND_BPS = 3000;
    OpenBounds internal OFF;

    bool internal probeMidBody;
    bool internal refusedMidBody;
    bytes internal midBodyRevert;

    struct Mkt {
        bytes32 id;
        MockERC20 quote;
        MockERC20 coll;
        MockPersistenceRecord record;
        address lender;
        uint256 units; // collateral a loan posts: ten thousand whole tokens, well over the coverage line at par
    }

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function setUp() public {
        _warpTo(1_000_000);
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 6);
        collX = new MockERC20("X", "X", 18);
        collY = new MockERC20("Y", "Y", 18);
        collZ = new MockERC20("Z", "Z", 0);
    }

    // ============ fixtures ============

    /// @dev A market of `coll` against `quote`, lent by `who`, its record capping draws at twice par.
    function _market(MockERC20 quote, MockERC20 coll, address who, bool ask) internal returns (Mkt memory m) {
        return _marketAt(quote, coll, who, ask, 2e18);
    }

    function _marketAt(MockERC20 quote, MockERC20 coll, address who, bool ask, uint256 capWad) internal returns (Mkt memory m) {
        m.quote = quote;
        m.coll = coll;
        m.lender = who;
        m.units = 10_000 * 10 ** coll.decimals();
        m.record = new MockPersistenceRecord(address(quote), address(coll));
        m.record.setObserved(AceFixtures.px(1e18, address(quote), address(coll)));
        m.record.setMinPrice(AceFixtures.px(capWad, address(quote), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.record = address(m.record);
        p.lender = who;
        p.inventoryAsk = ask;
        m.id = ace.createMarket(p);
        _lend(m, SEED);
    }

    /// @dev A band-armed market of `coll`, so a deleverage crank can melt a live loan's claim.
    function _deleverageMarket(MockERC20 coll) internal returns (Mkt memory m) {
        m.quote = usdc;
        m.coll = coll;
        m.lender = lender;
        m.units = 10_000 * 10 ** coll.decimals();
        m.record = new MockPersistenceRecord(address(usdc), address(coll));
        m.record.setObserved(AceFixtures.px(1e18, address(usdc), address(coll)));
        m.record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(m.record);
        p.lender = lender;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        m.id = ace.createMarket(p);
        _lend(m, SEED);
    }

    function _lend(Mkt memory m, uint256 amount) internal {
        m.quote.mint(m.lender, amount);
        vm.startPrank(m.lender);
        m.quote.approve(address(ace), amount);
        ace.deposit(m.id, amount);
        vm.stopPrank();
    }

    function _borrow(Mkt memory m, uint256 principal) internal returns (uint256 loanId) {
        m.coll.mint(borrower, m.units);
        vm.startPrank(borrower);
        m.coll.approve(address(positionManager), m.units);
        loanId = ace.open(m.id, m.units, principal, 0, borrower, OFF);
        vm.stopPrank();
    }

    function _repay(Mkt memory m, uint256 loanId, uint256 amount) internal {
        m.quote.mint(borrower, amount);
        vm.startPrank(borrower);
        m.quote.approve(address(ace), amount);
        ace.repay(loanId, amount);
        vm.stopPrank();
    }

    /// @dev Settle by distress through `finalize`, then warp to the moment the pot's ask opens.
    function _finalize(Mkt memory m, uint256 loanId) internal {
        m.record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        m.record.setBelow(false);
        uint256 opens = read.inventoryAskOpensAt(loanId);
        if (opens != type(uint256).max) _warpAtLeastTo(opens);
    }

    function _buy(Mkt memory m, uint256 loanId, uint256 budget) internal returns (uint256 unitsOut) {
        m.quote.mint(buyer, budget);
        vm.startPrank(buyer);
        m.quote.approve(address(ace), budget);
        (unitsOut,) = ace.buyInventory(loanId, budget, 0, buyer);
        vm.stopPrank();
    }

    // ============ the independent expectation ============

    /// @dev Every loan the hub issued whose market names this triple: its raw claim and its raw pot, summed here.
    /// @dev Keyed off the market's own write-once params, never off the split under test.
    function _expected(address l, address q, address c) internal view returns (uint256 lent, uint256 units) {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            bytes32 mkt = read.loan(id).market;
            if (mkt == bytes32(0)) continue; // an order id, which holds no claim
            MarketParams memory p = ace.idToMarketParams(mkt);
            if (p.lender != l || p.quote != q || p.collateral != c) continue;
            lent += read.claimOf(mkt, id);
            units += read.invPotOf(mkt, id);
        }
    }

    function _split(Mkt memory m) internal view returns (uint256 lent, uint256 units) {
        return ace.lenderByCollateral(m.lender, address(m.quote), address(m.coll));
    }

    /// @dev The split equals the independent sums, for this market's triple.
    function _assertSplit(Mkt memory m, string memory at) internal view {
        (uint256 lent, uint256 units) = _split(m);
        (uint256 wantLent, uint256 wantUnits) = _expected(m.lender, address(m.quote), address(m.coll));
        assertEq(lent, wantLent, string.concat(at, ": lent is not the sum of this collateral's claims"));
        assertEq(units, wantUnits, string.concat(at, ": unsoldUnits is not the sum of this collateral's pots"));
    }

    /// @dev The splits over these collaterals sum to the pair's pooled `lent`, and their units to every pot the pair holds.
    function _assertPairSums(address l, MockERC20 q, MockERC20[3] memory colls, string memory at) internal view {
        uint256 lentSum;
        uint256 unitSum;
        for (uint256 i; i < 3; i++) {
            (uint256 a, uint256 u) = ace.lenderByCollateral(l, address(q), address(colls[i]));
            lentSum += a;
            unitSum += u;
        }
        (, uint256 pooled,) = read.lenderPools(l, address(q));
        assertEq(lentSum, pooled, string.concat(at, ": the splits do not sum to the pair's lent"));
        uint256 pots;
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            bytes32 mkt = read.loan(id).market;
            if (mkt == bytes32(0)) continue;
            MarketParams memory p = ace.idToMarketParams(mkt);
            if (p.lender == l && p.quote == address(q)) pots += read.invPotOf(mkt, id);
        }
        assertEq(unitSum, pots, string.concat(at, ": the units do not sum to the pair's pots"));
    }

    // ============ R1-R3: the draw and the repay ============

    /// @notice A draw moves ONLY its own collateral's total, by exactly the principal; the other collateral's stands.
    function test_Draw_MovesOnlyItsCollateralByThePrincipal() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        (uint256 x0,) = _split(mx);
        assertEq(x0, 0, "PREMISE: nothing lent against X yet");

        uint256 id = _borrow(mx, PX);
        (uint256 x1, uint256 ux) = _split(mx);
        (uint256 y1,) = _split(my);
        assertEq(x1, PX, "X's total rose by the principal");
        assertEq(x1, read.claimOf(mx.id, id), "and equals the loan's claim");
        assertEq(y1, PY, "Y's standing loan is untouched");
        assertEq(ux, 0, "a draw holds no pot");
        _assertSplit(mx, "draw X");
        _assertSplit(my, "draw X, Y");
        _assertPairSums(lender, usdc, [collX, collY, collZ], "draw");
    }

    /// @notice A partial repay lowers the total by the amount paid, and leaves it equal to the loan's remaining claim.
    function test_Repay_APartialRepayFallsByTheAmount() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        _repay(mx, id, 1_000e6);
        (uint256 x,) = _split(mx);
        assertEq(x, PX - 1_000e6, "fell by the amount paid");
        assertEq(x, read.claimOf(mx.id, id), "and equals what the claim still owes");
        _assertSplit(mx, "partial repay");
        _assertSplit(my, "partial repay, Y");
    }

    /// @notice A full repay takes the collateral's total to zero while another collateral's loan stands.
    function test_Repay_AFullRepayZeroesItsCollateralAndLeavesTheOther() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        _repay(mx, id, read.debtOf(id));
        assertTrue(read.loan(id).closedAt != 0, "PREMISE: the loan closed clean");
        (uint256 x, uint256 ux) = _split(mx);
        (uint256 y,) = _split(my);
        assertEq(x, 0, "X's total is zero");
        assertEq(ux, 0, "and a clean close leaves no pot");
        assertEq(y, PY, "Y's stands");
        _assertPairSums(lender, usdc, [collX, collY, collZ], "full repay");
    }

    // ============ R4: the deleverage melt ============

    /// @dev Put the record in the band at `pct`% of the trigger, which is also the disposal floor.
    function _enterBand(Mkt memory m, uint256 loanId, uint256 pct) internal {
        uint256 trig = read.triggerPrice(loanId);
        m.record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        m.record.setMinPrice((trig * pct) / 100);
    }

    /// @notice A deleverage crank melts the claim, and the total falls by exactly the debt it melted.
    function test_Deleverage_FallsByTheMelt() public {
        Mkt memory dx = _deleverageMarket(collX);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(dx, PX);
        uint256 claim0 = read.claimOf(dx.id, id);
        _enterBand(dx, id, 110);
        (uint256 sold,) = ace.deleverage(id, 0, "");
        assertGt(sold, 0, "PREMISE: the crank sold");
        uint256 claim1 = read.claimOf(dx.id, id);
        assertLt(claim1, claim0, "PREMISE: and melted the claim");
        (uint256 x,) = _split(dx);
        assertEq(x, claim1, "the total fell by the melt, to the claim that is left");
        _assertSplit(dx, "deleverage");
        _assertSplit(my, "deleverage, Y");
    }

    /// @notice THE GUARD: the split refuses to answer while the hub's own body is open, as the pooled views do.
    /// @dev Driven through `deleverage`, the one verb that hands control to a caller mid-body.
    function testRevert_LenderByCollateral_RefusesInsideAGuardedHubBody() public {
        Mkt memory dx = _deleverageMarket(collX);
        uint256 id = _borrow(dx, PX);
        (uint256 outside,) = _split(dx);
        assertGt(outside, 0, "PREMISE: the same call answers OUTSIDE the body");
        probeMidBody = true;
        _enterBand(dx, id, 110);
        (uint256 sold,) = ace.deleverage(id, 0, "");
        assertGt(sold, 0, "PREMISE: the crank fired, so the probe ran");
        assertTrue(refusedMidBody, "lenderByCollateral answered mid-body: the guard is gone");
        assertEq(bytes4(midBodyRevert), GUARD_TRIP, "refused, but not as the guard");
    }

    function _deleverageCallback(uint256 unitsSold, uint256 quoteOwed, bytes calldata data) internal override {
        if (probeMidBody) {
            (bool ok, bytes memory ret) = address(ace).staticcall(abi.encodeCall(Ace.lenderByCollateral, (lender, address(usdc), address(collX))));
            refusedMidBody = !ok;
            midBodyRevert = ret;
        }
        super._deleverageCallback(unitsSold, quoteOwed, data);
    }

    // ============ R5-R7: settlement, through each door ============

    /// @notice `finalize` retires the whole claim from the total and puts the whole pot into the unsold units.
    function test_Settle_FinalizeMovesTheClaimOutAndThePotIn() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        _finalize(mx, id);
        _assertSettled(mx, my, id);
    }

    /// @notice `forceClose` on an unarmed loan at expiry settles it, with the same split.
    function test_Settle_ForceCloseMovesTheClaimOutAndThePotIn() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        _warpTo(read.loan(id).expiry + 1);
        vm.prank(keeper);
        ace.forceClose(id);
        _assertSettled(mx, my, id);
    }

    /// @notice The unpaid backstop `settleExpired` settles with the same split.
    function test_Settle_SettleExpiredMovesTheClaimOutAndThePotIn() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        _warpTo(read.loan(id).expiry + 1 days);
        vm.prank(keeper);
        ace.settleExpired(id);
        _assertSettled(mx, my, id);
    }

    function _assertSettled(Mkt memory mx, Mkt memory my, uint256 id) internal view {
        assertTrue(read.loan(id).closedAt != 0, "PREMISE: the door settled the loan");
        uint256 pot = read.invPotOf(mx.id, id);
        assertGt(pot, 0, "PREMISE: and left a pot");
        (uint256 x, uint256 ux) = _split(mx);
        (uint256 y, uint256 uy) = _split(my);
        assertEq(x, 0, "the whole claim left the total");
        assertEq(ux, pot, "and the whole pot is unsold units");
        assertEq(y, PY, "Y's loan stands");
        assertEq(uy, 0, "and Y holds no pot");
        _assertPairSums(lender, usdc, [collX, collY, collZ], "settled");
    }

    // ============ R8-R11: migrations ============

    /// @notice A HOME refinance recycles the retiring claim, and the total lands on the successor's principal, not short by the recycle.
    /// @dev The one row that kills a melt written as `amount - recycle`: a routed migration recycles nothing.
    function test_Migrate_AHomeRefinanceLandsOnTheSuccessorsPrincipal() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        uint256 newP = PX + 1_000e6;
        vm.prank(borrower);
        uint256 next = ace.refinance(id, newP, 0, OFF);
        assertTrue(read.loan(id).closedAt != 0, "PREMISE: the old loan retired");
        (uint256 x,) = _split(mx);
        assertEq(read.claimOf(mx.id, next), newP, "PREMISE: the successor's claim is its principal");
        assertEq(x, newP, "the total is the successor's principal");
        _assertSplit(mx, "home refinance");
        _assertSplit(my, "home refinance, Y");
    }

    /// @notice An ARMED loan rolls at expiry through the fold, and the total follows it onto the successor.
    function test_Migrate_TheExpiryFoldRollsTheTotalOntoTheSuccessor() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        uint64 tenor = read.loan(id).tenor; // read before the prank, which the next external call spends
        vm.prank(borrower);
        ace.setAutoRefinance(id, tenor, 0, 0);
        _warpAtLeastTo(read.loan(id).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(id);
        assertEq(read.loanCount(), n + 1, "PREMISE: the fold rolled into a successor");
        (uint256 x, uint256 ux) = _split(mx);
        assertEq(x, read.claimOf(mx.id, n + 1), "the total is the successor's claim");
        assertGt(x, 0, "PREMISE: which is live");
        assertEq(ux, 0, "and a roll leaves no pot");
        _assertSplit(mx, "fold");
        _assertSplit(my, "fold, Y");
    }

    /// @notice `refinanceTo` into the same lender's other X market keeps the total in X, at the new principal.
    function test_Migrate_RefinanceToAnotherMarketOfTheSameCollateral() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory mx2 = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        uint256 newP = PX + 500e6;
        vm.prank(borrower);
        uint256 next = ace.refinanceTo(MigrateArgs(id, mx2.id, newP, 0, OFF, 0, address(0)));
        (uint256 x,) = _split(mx);
        assertEq(read.claimOf(mx2.id, next), newP, "PREMISE: the successor sits in the second X market");
        assertEq(x, newP, "one triple spans both X markets, so it reads the new principal");
        _assertSplit(mx, "refinanceTo X'");
        _assertSplit(my, "refinanceTo X', Y");
    }

    /// @notice A ROUTED refinance between lenders moves the total out of the old lender's X and into the new one's.
    function test_Migrate_ARoutedRefinanceMovesTheTotalBetweenLenders() public {
        Mkt memory theirs = _market(usdc, collX, lender2, true);
        Mkt memory mine = _market(usdc, collX, lender, true);
        uint256 id = _borrow(theirs, PX);
        uint256 newP = PX + 700e6;
        vm.prank(borrower);
        uint256 next = ace.refinanceTo(MigrateArgs(id, mine.id, newP, 0, OFF, 0, address(0)));
        (uint256 l2,) = _split(theirs);
        (uint256 l1,) = _split(mine);
        assertEq(l2, 0, "the old lender's X total fell by the whole retiring claim");
        assertEq(l1, newP, "and the new lender's rose by the successor's principal");
        assertEq(read.claimOf(mine.id, next), newP, "PREMISE: the successor sits in the new lender's market");
        _assertSplit(theirs, "routed, old lender");
        _assertSplit(mine, "routed, new lender");
    }

    /// @notice A migration into a DIFFERENT collateral is refused before anything moves, so no total crosses collateral.
    function test_Migrate_IntoAnotherCollateralRevertsAndMovesNothing() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        vm.prank(borrower);
        vm.expectRevert(MarketPairMismatch.selector);
        ace.refinanceTo(MigrateArgs(id, my.id, PX, 0, OFF, 0, address(0)));
        (uint256 x,) = _split(mx);
        (uint256 y,) = _split(my);
        assertEq(x, PX, "X unchanged");
        assertEq(y, PY, "Y unchanged");
    }

    // ============ R12: credit orders ============

    /// @notice Posting an order lends nothing; each partial fill moves the total by exactly the principal it draws.
    function test_Orders_PostMovesNothingAndEachFillMovesItsPrincipal() public {
        Mkt memory m;
        m.quote = usdc;
        m.coll = collX;
        m.lender = lender;
        m.record = new MockPersistenceRecord(address(usdc), address(collX));
        m.record.setObserved(AceFixtures.px(2e18, address(usdc), address(collX)));
        m.record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(collX)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(collX));
        p.record = address(m.record);
        p.lender = lender;
        p.price = AceFixtures.priceAt(address(usdc), address(collX), 6600); // the band sits above par, so the market must too
        m.id = ace.createMarket(p);
        _lend(m, SEED);

        collX.mint(borrower, 1e30);
        vm.startPrank(borrower);
        collX.approve(address(positionManager), type(uint256).max);
        uint256 liqLow = AceFixtures.px(1.4e18, address(usdc), address(collX));
        uint256 liqHigh = AceFixtures.px(1.5e18, address(usdc), address(collX));
        uint256 orderId = ace.postOrder(m.id, PX, liqLow, liqHigh, PX / 4, ProtocolPolicy.MIN_TENOR, 0);
        vm.stopPrank();
        (uint256 x0,) = _split(m);
        assertEq(x0, 0, "an order is not a loan: posting lends nothing");

        Order memory o = ace.orderOf(orderId);
        vm.prank(keeper);
        ace.fillOrder(orderId, PX / 2, (o.collateralUnits * (PX / 2)) / o.principal);
        (uint256 x1,) = _split(m);
        assertEq(x1, PX / 2, "the first fill drew half");
        o = ace.orderOf(orderId);
        vm.prank(keeper);
        ace.fillOrder(orderId, PX / 4, (o.collateralUnits * (PX / 4)) / o.principal);
        (uint256 x2,) = _split(m);
        assertEq(x2, PX / 2 + PX / 4, "and the second a quarter more");
        _assertSplit(m, "orders");
    }

    // ============ R13: the unsold units ============

    /// @notice A whole buy empties the pot and takes the units to zero; a partial buy takes off exactly what it delivered.
    function test_Units_APartialBuyTakesWhatItDeliveredAndAWholeBuyTheRest() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        _finalize(mx, id);
        uint256 pot = read.invPotOf(mx.id, id);

        uint256 got = _buy(mx, id, 1_000e6);
        assertGt(got, 0, "PREMISE: the partial buy delivered");
        assertLt(got, pot, "PREMISE: but not the whole pot");
        (, uint256 u1) = _split(mx);
        assertEq(u1, pot - got, "the units fell by what was delivered");
        _assertSplit(mx, "partial buy");

        _buy(mx, id, 1_000_000e6);
        assertEq(read.invPotOf(mx.id, id), 0, "PREMISE: the second buy emptied the pot");
        (, uint256 u2) = _split(mx);
        assertEq(u2, 0, "and the units with it");
        _assertSplit(my, "whole buy, Y");
    }

    /// @notice On a market without the ask the lender's in-kind redeem takes the whole pot, and the units with it.
    function test_Units_ARedeemInKindTakesThemAll() public {
        Mkt memory mx = _market(usdc, collX, lender, false);
        uint256 id = _borrow(mx, PX);
        _finalize(mx, id);
        (, uint256 u0) = _split(mx);
        assertEq(u0, read.invPotOf(mx.id, id), "PREMISE: the pot is unsold units");
        assertGt(u0, 0, "PREMISE: and there are some");
        vm.prank(lender);
        ace.redeemInKind(id, lender);
        (, uint256 u1) = _split(mx);
        assertEq(u1, 0, "the redeem took them all");
        _assertSplit(mx, "redeem");
    }

    /// @notice A buy that delivers nothing leaves the units where they were.
    function test_Units_AZeroDeliverBuyLeavesThemUnchanged() public {
        Mkt memory mz = _marketAt(usdc, collZ, lender, true, 1.234567891e18);
        uint256 id = _borrow(mz, PZ);
        _finalize(mz, id);
        (, uint256 u0) = _split(mz);
        assertGt(u0, 0, "PREMISE: a pot");
        assertEq(_buy(mz, id, 1), 0, "PREMISE: one quote atom buys no whole unit");
        (, uint256 u1) = _split(mz);
        assertEq(u1, u0, "the units stand");
    }

    /// @notice A buy on an emptied pot, or on a loan that closed clean, never takes another pot's units.
    function test_Units_ABuyOnAnEmptyPotNeverTakesAnotherPotsUnits() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        uint256 a = _borrow(mx, PX);
        uint256 b = _borrow(mx, PX);
        uint256 clean = _borrow(mx, PX);
        _finalize(mx, a);
        _finalize(mx, b);
        _repay(mx, clean, read.debtOf(clean));
        _warpAtLeastTo(read.inventoryAskOpensAt(clean));
        _buy(mx, a, 1_000_000e6);
        assertEq(read.invPotOf(mx.id, a), 0, "PREMISE: A emptied");
        uint256 potB = read.invPotOf(mx.id, b);
        assertGt(potB, 0, "PREMISE: B stands");

        assertEq(_buy(mx, a, 1_000e6) + _buy(mx, clean, 1_000e6), 0, "PREMISE: both buys met an empty pot");
        (, uint256 u) = _split(mx);
        assertEq(u, potB, "B's units stand");
        _assertSplit(mx, "empty buys");
    }

    // ============ R14-R17: the walk, the quote, the unknown triple, the identity ============

    /// @notice One lender, one quote, three collaterals, one scripted walk: after every step each split is its book and they sum to the pair.
    function test_Walk_ThreeCollateralsSumToThePairAfterEveryStep() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        Mkt memory mz = _market(usdc, collZ, lender, true);
        MockERC20[3] memory colls = [collX, collY, collZ];
        uint256 x = _borrow(mx, PX);
        uint256 y = _borrow(my, PY);
        uint256 z = _borrow(mz, PZ);
        _walkCheck(mx, my, mz, colls, "three draws");
        _repay(mx, x, 1_234e6);
        _walkCheck(mx, my, mz, colls, "partial repay X");
        _finalize(my, y);
        _walkCheck(mx, my, mz, colls, "settle Y");
        _buy(my, y, 500e6);
        _walkCheck(mx, my, mz, colls, "partial buy Y");
        vm.prank(borrower);
        ace.refinance(z, PZ + 300e6, 0, OFF);
        _walkCheck(mx, my, mz, colls, "refinance Z");
        _repay(mx, x, read.debtOf(x));
        _walkCheck(mx, my, mz, colls, "full repay X");
        _buy(my, y, 1_000_000e6);
        _walkCheck(mx, my, mz, colls, "whole buy Y");
    }

    function _walkCheck(Mkt memory mx, Mkt memory my, Mkt memory mz, MockERC20[3] memory colls, string memory at) internal view {
        _assertSplit(mx, at);
        _assertSplit(my, at);
        _assertSplit(mz, at);
        _assertPairSums(lender, usdc, colls, at);
    }

    /// @notice The split is keyed by the quote: a DAI market on X never moves the USDC total on X.
    function test_Keys_QuotesNeverCross() public {
        Mkt memory usdX = _market(usdc, collX, lender, true);
        Mkt memory daiX = _market(dai, collX, lender, true);
        _borrow(usdX, PX);
        _borrow(daiX, PY);
        (uint256 u,) = _split(usdX);
        (uint256 d,) = _split(daiX);
        assertEq(u, PX, "USDC on X reads only the USDC loan");
        assertEq(d, PY, "DAI on X reads only the DAI loan");
        _assertSplit(usdX, "usdc");
        _assertSplit(daiX, "dai");
    }

    /// @notice A triple that never lent reads zero rather than reverting.
    function test_Keys_AnUnknownTripleReadsZero() public view {
        (uint256 lent, uint256 units) = ace.lenderByCollateral(address(0xdead), address(usdc), address(collX));
        assertEq(lent + units, 0, "an unknown lender reads zero");
        (lent, units) = ace.lenderByCollateral(lender, address(usdc), address(0xdead));
        assertEq(lent + units, 0, "and so does a collateral it never lent against");
    }

    /// @notice `lenderAssets` is resting cash, plus every collateral's split of `lent`, plus uncollected credit.
    function test_Identity_LenderAssetsIsRestingPlusTheSplitsPlusOwed() public {
        Mkt memory mx = _market(usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender, true);
        uint256 x = _borrow(mx, PX);
        _borrow(my, PY);
        _repay(mx, x, 1_000e6);
        (uint256 resting,, uint256 owed) = read.lenderPools(lender, address(usdc));
        (uint256 lx,) = _split(mx);
        (uint256 ly,) = _split(my);
        assertGt(owed, 0, "PREMISE: the repay left credit uncollected");
        assertEq(ace.lenderAssets(lender, address(usdc)), resting + lx + ly + owed, "the three legs, with lent split by collateral");
    }
}
