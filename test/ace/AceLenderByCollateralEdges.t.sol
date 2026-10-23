// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowMinDebt} from "../../src/ace/hub/Borrower.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, MigrateArgs, OpenBounds, Order, Storage} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";

/// @title AceLenderByCollateralEdges
/// @notice The per-(lender, quote, collateral) split on the paths `AceLenderByCollateral` does not drive.
/// @notice A recordless forfeit, a second default, a zero-fresh re-term, a short close, a capped crank, the dust band, a shedding re-term.
/// @dev Expectations come from two INDEPENDENT ledgers: each loan's raw claim and pot, and each live loan's borrower-side debt.
/// @dev A live loan in a second collateral stands through every row, so a split reading zero or the pair's total cannot pass.
/// @dev Neither campaign reaches the recordless forfeit or a short close, so these rows are the only coverage of the split there.
contract AceLenderByCollateralEdgesTest is WarpClock, DeleverageCrank {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockERC20 internal dai;
    MockERC20 internal collX;
    MockERC20 internal collY;

    address internal lender = address(0x1E4D);
    address internal lender2 = address(0x1E4D2);
    address internal borrower = address(0xB0BA);
    address internal buyer = address(0xB04E5);
    address internal keeper = address(0xCAFE);

    uint256 internal constant SEED = 20_000e6;
    uint256 internal constant PX = 4_500e6;
    uint256 internal constant PY = 3_000e6; // distinct from PX, so no row passes on a coincidence of amounts
    uint256 internal constant BAND_BPS = 3000;
    OpenBounds internal OFF;

    struct Mkt {
        bytes32 id;
        MockERC20 quote;
        MockERC20 coll;
        MockPersistenceRecord record; // zero on a recordless market
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
    }

    // ============ fixtures ============

    /// @dev A record-backed market of `coll` against `quote`, lent by `who`, its record capping draws at twice par.
    function _market(MockERC20 quote, MockERC20 coll, address who) internal returns (Mkt memory) {
        return _create(AceFixtures.marketParams(address(quote), address(coll)), quote, coll, who, true);
    }

    /// @dev Creates the market from `p` and rests SEED; `wired` false leaves it recordless, the class whose settlement forfeits coverage.
    function _create(MarketParams memory p, MockERC20 quote, MockERC20 coll, address who, bool wired) internal returns (Mkt memory m) {
        m.quote = quote;
        m.coll = coll;
        m.lender = who;
        m.units = 10_000 * 10 ** coll.decimals();
        if (wired) {
            m.record = new MockPersistenceRecord(address(quote), address(coll));
            m.record.setObserved(AceFixtures.px(1e18, address(quote), address(coll)));
            m.record.setMinPrice(AceFixtures.px(2e18, address(quote), address(coll)));
        }
        p.record = address(m.record);
        p.lender = who;
        m.id = ace.createMarket(p);
        _lend(m, SEED);
    }

    /// @dev A band-armed USDC market of `coll` with its own `minDebt`, so a deleverage crank can be capped by it.
    function _deleverageMarket(MockERC20 coll, uint256 minDebt) internal returns (Mkt memory) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.minDebt = minDebt;
        return _create(p, usdc, coll, lender, true);
    }

    /// @dev A USDC market of `coll` priced above par with its record above the band, so a credit order can rest and fill.
    function _orderMarket(MockERC20 coll) internal returns (Mkt memory m) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.price = AceFixtures.priceAt(address(usdc), address(coll), 6600);
        m.quote = usdc;
        m.coll = coll;
        m.lender = lender;
        m.record = new MockPersistenceRecord(address(usdc), address(coll));
        m.record.setObserved(AceFixtures.px(2e18, address(usdc), address(coll)));
        m.record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        p.record = address(m.record);
        p.lender = lender;
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

    /// @dev The units a live claim needs at its market's price, ceiled as settlement ceils; read BEFORE the claim retires.
    function _needOf(Mkt memory m, uint256 loanId) internal view returns (uint256) {
        uint256 claim = read.claimOf(m.id, loanId);
        return FullMath.mulDivRoundingUp(claim, read.marketState(m.id).unitScale, ace.idToMarketParams(m.id).price);
    }

    /// @dev Put the record in the band at `pct`% of the trigger, which is also the disposal floor.
    function _enterBand(Mkt memory m, uint256 loanId, uint256 pct) internal {
        uint256 trig = read.triggerPrice(loanId);
        m.record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        m.record.setMinPrice((trig * pct) / 100);
    }

    /// @dev Fill `amt` of an order, carrying units pro rata to what is left; the units are read before the prank.
    function _fill(uint256 orderId, uint256 amt) internal {
        Order memory o = ace.orderOf(orderId);
        uint256 units = (o.collateralUnits * amt) / o.principal;
        vm.prank(keeper);
        ace.fillOrder(orderId, amt, units);
    }

    // ============ the independent expectations ============

    /// @dev Every loan whose market names this triple: raw claim, raw pot, and the borrower-side debt of the live ones.
    /// @dev Keyed off the market's own write-once params, never off the split under test.
    function _expected(address l, address q, address c) internal view returns (uint256 lent, uint256 units, uint256 debt) {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            bytes32 mkt = read.loan(id).market;
            if (mkt == bytes32(0)) continue; // an order id, which holds no claim
            MarketParams memory p = ace.idToMarketParams(mkt);
            if (p.lender != l || p.quote != q || p.collateral != c) continue;
            lent += read.claimOf(mkt, id);
            units += read.invPotOf(mkt, id);
            if (read.loan(id).closedAt == 0) debt += read.debtOf(id);
        }
    }

    function _split(Mkt memory m) internal view returns (uint256 lent, uint256 units) {
        return ace.lenderByCollateral(m.lender, address(m.quote), address(m.coll));
    }

    /// @dev The split equals the claim book, the borrower-side debt book and the raw pots, for this market's triple.
    function _assertSplit(Mkt memory m, string memory at) internal view {
        (uint256 lent, uint256 units) = _split(m);
        (uint256 wantLent, uint256 wantUnits, uint256 debt) = _expected(m.lender, address(m.quote), address(m.coll));
        assertEq(lent, wantLent, string.concat(at, ": lent is not the sum of this collateral's claims"));
        assertEq(lent, debt, string.concat(at, ": lent is not the sum of this collateral's live debts"));
        assertEq(units, wantUnits, string.concat(at, ": unsoldUnits is not the sum of this collateral's pots"));
    }

    /// @dev The two collaterals' splits sum to the pair's pooled `lent`, and their units to every pot the pair holds.
    function _assertPairSums(address l, MockERC20 q, MockERC20 c1, MockERC20 c2, string memory at) internal view {
        (uint256 a1, uint256 u1) = ace.lenderByCollateral(l, address(q), address(c1));
        (uint256 a2, uint256 u2) = ace.lenderByCollateral(l, address(q), address(c2));
        (uint256 resting, uint256 pooled, uint256 owed) = read.lenderPools(l, address(q));
        assertEq(a1 + a2, pooled, string.concat(at, ": the splits do not sum to the pair's lent"));
        assertEq(ace.lenderAssets(l, address(q)), resting + a1 + a2 + owed, string.concat(at, ": lenderAssets is not resting + splits + owed"));
        assertEq(u1 + u2, _pairPots(l, address(q)), string.concat(at, ": the units do not sum to the pair's pots"));
    }

    /// @dev Every raw pot the pair holds, over all its markets and collaterals.
    function _pairPots(address l, address q) internal view returns (uint256 pots) {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            bytes32 mkt = read.loan(id).market;
            if (mkt == bytes32(0)) continue;
            MarketParams memory p = ace.idToMarketParams(mkt);
            if (p.lender == l && p.quote == q) pots += read.invPotOf(mkt, id);
        }
    }

    // ============ E1-E2: what settlement puts into the units ============

    /// @notice A RECORDLESS forfeit lands the whole coverage line in the pot, and the units count all of it, spread included.
    /// @dev Kills `unsoldUnits += give`: on a record-backed market the pot IS the give, so only this class tells them apart.
    function test_Settle_ARecordlessForfeitCountsTheSpreadInTheUnits() public {
        Mkt memory rx = _create(AceFixtures.marketParams(address(usdc), address(collX)), usdc, collX, lender, false);
        Mkt memory my = _market(usdc, collY, lender);
        _borrow(my, PY);
        uint256 a = _borrow(rx, PX);
        uint256 b = _borrow(rx, PY);
        uint256 needA = _needOf(rx, a);
        uint256 needB = _needOf(rx, b);

        _warpTo(read.loan(b).expiry);
        vm.prank(keeper);
        ace.forceClose(b); // the paid door: a sliver off the top, then the coverage line
        uint256 potB = read.invPotOf(rx.id, b);
        assertGt(potB, needB, "PREMISE: the forfeit put coverage above the claim's need into the pot");
        (uint256 l1, uint256 u1) = _split(rx);
        assertEq(u1, potB, "the units are the whole pot, the forfeited spread included");
        assertEq(l1, PX, "and only the other loan's claim is left");
        _assertSplit(rx, "forceClose");

        _warpTo(read.loan(a).expiry + MarketInit.autoRefinanceWindow(read.loan(a).tenor));
        vm.prank(keeper);
        ace.settleExpired(a); // the unpaid door: no sliver
        uint256 potA = read.invPotOf(rx.id, a);
        assertGt(potA, needA, "PREMISE: the backstop forfeits coverage too");
        (uint256 l2, uint256 u2) = _split(rx);
        assertEq(u2, potA + potB, "a second forfeit adds its whole pot to the units already held");
        assertEq(l2, 0, "both claims left lent");
        _assertSplit(rx, "settleExpired");
        _assertSplit(my, "settleExpired, Y");

        vm.prank(lender);
        uint256 out = ace.redeemInKind(b, lender);
        assertEq(out, potB, "PREMISE: the redeem took B's whole pot");
        (, uint256 u3) = _split(rx);
        assertEq(u3, potA, "the redeem took B's spread out of the units with the rest of its pot");
        _assertPairSums(lender, usdc, collX, collY, "recordless");
    }

    /// @notice A second default in a triple already holding units ADDS its pot, across two markets of one collateral.
    /// @dev Kills `unsoldUnits = pot`: the first default's write is zero-to-nonzero, so only a second one sees the overwrite.
    function test_Settle_ASecondDefaultAddsToUnitsAlreadyHeld() public {
        Mkt memory mx = _market(usdc, collX, lender);
        Mkt memory mx2 = _market(usdc, collX, lender);
        Mkt memory my = _market(usdc, collY, lender);
        _borrow(my, PY);
        uint256 a = _borrow(mx, PX);
        uint256 b = _borrow(mx2, PY);
        _borrow(mx, 2_000e6); // a live X loan, so lent never reads zero

        _finalize(mx, a);
        uint256 potA = read.invPotOf(mx.id, a);
        (uint256 l1, uint256 u1) = _split(mx);
        assertEq(u1, potA, "the first default's pot");
        assertEq(l1, PY + 2_000e6, "the two live X claims");

        _finalize(mx2, b);
        uint256 potB = read.invPotOf(mx2.id, b);
        assertTrue(potA != potB && potB != 0, "PREMISE: two different nonzero pots");
        (uint256 l2, uint256 u2) = _split(mx2);
        assertEq(u2, potA + potB, "the second default added to the units, in another market of the same collateral");
        assertEq(l2, 2_000e6, "and only the live loan's claim is left");
        _assertSplit(mx, "second default");
        _assertSplit(my, "second default, Y");
        _assertPairSums(lender, usdc, collX, collY, "second default");
    }

    // ============ E3: a short close ============

    /// @notice A SHORT close retires the WHOLE claim from lent, its unpaid part included, and counts only what it delivered.
    /// @dev Kills a melt sized to what was covered: the bad debt would stay in lent with no claim beneath it.
    /// @dev Staged by writing `collateralUnits`, the one field it touches: no public path leaves an admitted loan short.
    function test_Settle_AShortCloseRetiresTheWholeClaimAndCountsWhatItDelivered() public {
        Mkt memory mx = _market(usdc, collX, lender);
        Mkt memory my = _market(usdc, collY, lender);
        _borrow(my, PY);
        uint256 live = _borrow(mx, 2_000e6);
        uint256 id = _borrow(mx, PX);
        uint256 shortUnits = (_needOf(mx, id) * 60) / 100;
        uint256 loanSlot = uint256(keccak256(abi.encode(id, uint256(Storage.BOOK) + 1)));
        vm.store(address(ace), bytes32(loanSlot + 2), bytes32(shortUnits)); // word 2 is collateralUnits
        assertEq(read.loan(id).collateralUnits, shortUnits, "PREMISE: the staged write landed on collateralUnits");

        _finalize(mx, id);
        (, uint256 bad) = read.shortfallOf(id);
        assertGt(bad, 0, "PREMISE: the close came up short");
        uint256 pot = read.invPotOf(mx.id, id);
        assertGt(pot, 0, "PREMISE: and still delivered a pot");
        (uint256 l, uint256 u) = _split(mx);
        assertEq(l, read.claimOf(mx.id, live), "the whole shorted claim left lent; only the live loan's remains");
        assertEq(l, 2_000e6, "which is its principal");
        assertEq(u, pot, "the units are what was delivered, never what the claim asked for");
        _assertSplit(mx, "short close");
        _assertSplit(my, "short close, Y");
    }

    // ============ E4-E6: migrations the first suite does not drive ============

    /// @notice A home re-term into a SMALLER successor, funded by the unearned fee refund, recycles it whole: zero fresh cash.
    /// @notice The split still falls by the retiring debt and rises by the successor's whole principal.
    /// @dev Kills a draw that skips the lent write when nothing fresh leaves cash: every other migration row draws fresh cash.
    function test_Migrate_AHomeRefinanceIntoASmallerSuccessorLandsOnIt() public {
        Mkt memory mx = _market(usdc, collX, lender);
        Mkt memory my = _market(usdc, collY, lender);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        _repay(mx, id, PX - 100e6);
        uint256 debtOld = read.debtOf(id);
        assertEq(debtOld, 100e6, "PREMISE: the repay left 100 owed");
        uint256 newP = 95e6;
        uint256 cash0 = read.marketState(mx.id).cash;
        (,, uint256 owed0) = read.lenderPools(lender, address(usdc));

        vm.prank(borrower);
        uint256 next = ace.refinance(id, newP, 0, OFF);
        assertEq(read.marketState(mx.id).cash, cash0, "PREMISE: a zero-fresh draw, the successor recycled whole");
        assertEq(read.claimOf(mx.id, next), newP, "PREMISE: the successor's claim is its principal");
        (uint256 x,) = _split(mx);
        assertEq(x, newP, "the split lands on the smaller successor, not on the retiring debt");
        (,, uint256 owed1) = read.lenderPools(lender, address(usdc));
        assertGe(owed1 - owed0, debtOld - newP, "the unrecycled principal reached owed");
        _assertSplit(mx, "smaller successor");
        _assertSplit(my, "smaller successor, Y");
        _assertPairSums(lender, usdc, collX, collY, "smaller successor");
    }

    /// @notice A home `refinanceTo` carrying `withdrawUnits` sheds live collateral and leaves the unsold units where they were.
    /// @dev The units count pots, never a live loan's collateral, so a release off the successor must not reach them.
    function test_Migrate_ARefinanceToShedsCollateralAndMovesNoUnits() public {
        Mkt memory mx = _market(usdc, collX, lender);
        Mkt memory my = _market(usdc, collY, lender);
        _borrow(my, PY);
        uint256 settled = _borrow(mx, PY);
        _finalize(mx, settled);
        uint256 potS = read.invPotOf(mx.id, settled);
        assertGt(potS, 0, "PREMISE: the triple holds unsold units");
        uint256 id = _borrow(mx, PX);
        uint256 shed = 1_000e18;
        uint256 newP = PX + 200e6;
        uint256 bal0 = collX.balanceOf(borrower);

        vm.prank(borrower);
        uint256 next = ace.refinanceTo(MigrateArgs(id, mx.id, newP, 0, OFF, shed, borrower));
        assertEq(collX.balanceOf(borrower) - bal0, shed, "PREMISE: the leg released the shed units");
        assertEq(read.loan(next).collateralUnits, mx.units - shed, "PREMISE: off the successor");
        (uint256 x, uint256 u) = _split(mx);
        assertEq(x, newP, "lent is the successor's principal");
        assertEq(u, potS, "and the units stand: a withdrawal is not a pot exit");
        _assertSplit(mx, "shedding re-term");
        _assertSplit(my, "shedding re-term, Y");
    }

    /// @notice Only the borrower may repay into `(0, minDebt)`; the split follows to the dust, and the fold's minDebt floor raises it.
    /// @dev The one roll whose successor is floored ABOVE its fee-derived size, so the split rises past the old debt by more than a fee.
    function test_Repay_TheDustBandThenTheFoldRaisesTheSplitToMinDebt() public {
        Mkt memory mx = _market(usdc, collX, lender);
        Mkt memory my = _market(usdc, collY, lender);
        _borrow(my, PY);
        uint256 id = _borrow(mx, PX);
        uint256 minDebt = ace.idToMarketParams(mx.id).minDebt;
        uint256 dust = minDebt / 2;

        usdc.mint(keeper, PX);
        vm.startPrank(keeper);
        usdc.approve(address(ace), PX);
        vm.expectRevert(BelowMinDebt.selector);
        ace.repay(id, PX - dust);
        vm.stopPrank();
        (uint256 x0,) = _split(mx);
        assertEq(x0, PX, "a refused third-party repay moved nothing");

        _repay(mx, id, PX - dust);
        (uint256 x1,) = _split(mx);
        assertEq(x1, dust, "the borrower's own repay took the split into the dust band");
        _assertSplit(mx, "dust");

        uint64 tenor = read.loan(id).tenor; // read before the prank, which the next external call spends
        vm.prank(borrower);
        ace.setAutoRefinance(id, tenor, 0, 0);
        _warpAtLeastTo(read.loan(id).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(id);
        assertEq(read.loanCount(), n + 1, "PREMISE: the fold rolled into a successor");
        (uint256 x2, uint256 u2) = _split(mx);
        assertEq(x2, minDebt, "the floored successor's principal is the market's minDebt");
        assertEq(x2, read.claimOf(mx.id, n + 1), "and it is the successor's claim");
        assertEq(u2, 0, "a roll leaves no pot");
        _assertSplit(mx, "dust fold");
        _assertSplit(my, "dust fold, Y");
    }

    // ============ E7: a crank capped at minDebt ============

    /// @notice A crank whose restore would melt past `minDebt` is capped there, and the split lands on the debt it leaves.
    function test_Deleverage_ACrankCappedAtMinDebtLandsTheSplitOnTheDebt() public {
        uint256 floorDebt = PX - 10e6; // ten quote of head: far under the restore the band asks for
        Mkt memory dx = _deleverageMarket(collX, floorDebt);
        Mkt memory my = _market(usdc, collY, lender);
        _borrow(my, PY);
        uint256 id = _borrow(dx, PX);
        _enterBand(dx, id, 110);

        (uint256 sold,) = ace.deleverage(id, 0, "");
        assertGt(sold, 0, "PREMISE: the crank sold");
        uint256 debt1 = read.debtOf(id);
        assertLt(debt1, PX, "PREMISE: and melted");
        assertGe(debt1, floorDebt, "PREMISE: no further than minDebt");
        (uint256 x,) = _split(dx);
        assertEq(x, debt1, "the split is the debt the capped melt left");
        assertEq(x, read.claimOf(dx.id, id), "and the loan's claim");
        _assertSplit(dx, "capped crank");
        _assertSplit(my, "capped crank, Y");
    }

    /// @notice A crank that CHARGES the protocol cut melts only the net: the split falls by it, never by the gross proceeds.
    /// @dev The cut is protocol revenue, not the lender's, so a split falling by the gross would read under the loan's debt.
    function test_Deleverage_AChargedCrankLowersTheSplitByTheNetMelt() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(collX));
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.deleverageProtocolBps = 1000;
        Mkt memory dx = _create(p, usdc, collX, lender, true);
        Mkt memory my = _market(usdc, collY, lender);
        _borrow(my, PY);
        uint256 id = _borrow(dx, PX);
        _enterBand(dx, id, 110);
        uint256 rev0 = read.protocolRevenue(dx.id);

        (uint256 sold, uint256 gross) = ace.deleverage(id, 0, "");
        assertGt(sold, 0, "PREMISE: the crank sold");
        uint256 cut = read.protocolRevenue(dx.id) - rev0;
        assertGt(cut, 0, "PREMISE: and charged the cut");
        uint256 debt1 = read.debtOf(id);
        assertEq(PX - debt1, gross - cut, "PREMISE: the debt fell by the net melt");
        (uint256 x,) = _split(dx);
        assertEq(x, debt1, "the split fell by the net melt alone");
        _assertSplit(dx, "charged crank");
        _assertSplit(my, "charged crank, Y");
    }

    // ============ E8: credit orders in two markets of one collateral ============

    /// @notice Fills against orders resting in two markets of ONE collateral sum in one triple, fill by fill.
    /// @dev Kills a split draw written as `=`: every draw after the first in a triple would overwrite the ones before it.
    function test_Orders_FillsInTwoMarketsOfOneCollateralSumInOneTriple() public {
        Mkt memory m1 = _orderMarket(collX);
        Mkt memory m2 = _orderMarket(collX);
        Mkt memory my = _market(usdc, collY, lender);
        _borrow(my, PY);

        collX.mint(borrower, 1e30);
        vm.startPrank(borrower);
        collX.approve(address(positionManager), type(uint256).max);
        uint256 liqLow = AceFixtures.px(1.4e18, address(usdc), address(collX));
        uint256 liqHigh = AceFixtures.px(1.5e18, address(usdc), address(collX));
        uint256 o1 = ace.postOrder(m1.id, PX, liqLow, liqHigh, PX / 4, ProtocolPolicy.MIN_TENOR, 0);
        uint256 o2 = ace.postOrder(m2.id, PY, liqLow, liqHigh, PY / 4, ProtocolPolicy.MIN_TENOR, 0);
        vm.stopPrank();
        (uint256 x0,) = _split(m1);
        assertEq(x0, 0, "posting lends nothing");

        _fill(o1, PX / 2);
        _fill(o2, PY / 2);
        (uint256 x1,) = _split(m2);
        assertEq(x1, PX / 2 + PY / 2, "one fill in each X market, summed in one triple");
        _fill(o1, PX / 4);
        (uint256 x2,) = _split(m1);
        assertEq(x2, PX / 2 + PY / 2 + PX / 4, "and a second fill in the first adds again");
        _assertSplit(m1, "orders");
        _assertSplit(my, "orders, Y");
        _assertPairSums(lender, usdc, collX, collY, "orders");
    }

    // ============ E9: one lender, two quotes, two collaterals ============

    /// @notice A lender spanning both quotes and two collaterals reads each cell alone, units included, beside another lender's X.
    function test_Keys_TwoQuotesTimesTwoCollateralsReadEachCellAlone() public {
        Mkt memory ux = _market(usdc, collX, lender);
        Mkt memory uy = _market(usdc, collY, lender);
        Mkt memory dx = _market(dai, collX, lender);
        Mkt memory dy = _market(dai, collY, lender);
        Mkt memory theirs = _market(usdc, collX, lender2);
        _borrow(ux, 4_500e6);
        _borrow(uy, 3_000e6);
        _borrow(dx, 2_000e6);
        uint256 d = _borrow(dy, 3_700e6);
        _borrow(dy, 1_100e6);
        _borrow(theirs, 2_500e6);
        _finalize(dy, d);
        uint256 pot0 = read.invPotOf(dy.id, d);
        uint256 got = _buy(dy, d, 500e6);
        assertTrue(got != 0 && got < pot0, "PREMISE: a partial buy on the DAI-Y pot");

        _assertCell(ux, 4_500e6, 0, "usdc-X");
        _assertCell(uy, 3_000e6, 0, "usdc-Y");
        _assertCell(dx, 2_000e6, 0, "dai-X");
        _assertCell(dy, 1_100e6, pot0 - got, "dai-Y");
        _assertCell(theirs, 2_500e6, 0, "lender2 usdc-X");
        _assertPairSums(lender, usdc, collX, collY, "usdc");
        _assertPairSums(lender, dai, collX, collY, "dai");
        _assertPairSums(lender2, usdc, collX, collY, "lender2");
    }

    function _assertCell(Mkt memory m, uint256 wantLent, uint256 wantUnits, string memory at) internal view {
        (uint256 lent, uint256 units) = _split(m);
        assertEq(lent, wantLent, string.concat(at, ": lent"));
        assertEq(units, wantUnits, string.concat(at, ": units"));
        _assertSplit(m, at);
    }
}
