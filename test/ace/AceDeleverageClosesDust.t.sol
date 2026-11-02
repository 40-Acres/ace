// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, BelowCallerFloor, PushGasShort} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Lender} from "../../src/ace/hub/Lender.sol";
import {LoanAccounting} from "../../src/ace/hub/libraries/LoanAccounting.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {CloseUnfilled, Deleverage, DeleverageStopped, Distressed, LoanClosed, LoanMatured, NotInBand} from "../../src/ace/hub/Deleverage.sol";
import {NoRecordPrice} from "../../src/ace/hub/Borrower.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockHostileGasERC20} from "../mocks/MockHostileGasERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {_extended} from "../utils/Extended.sol";

/// @title AceDeleverageClosesDustTest
/// @notice A crank whose restore would leave the debt under its debt floor sells the WHOLE debt instead and closes the loan clean.
/// @notice The close sells `uClose`, the smallest sale whose ceiled keeper bill covers the debt, fills whole or reverts, and takes no cut.
/// @notice It books in `repay`'s order, credits the borrower every unit left plus the bill's overshoot, and pushes the lender's pool.
/// @dev The decision is a SIZE rule on the full fill's net melt: `debt < floor + net`, so a melt landing exactly on the floor restores.
/// @dev Each market stores `minPrincipal = 2 * floor`; a loan under it opens at it, repays to its size and withdraws to its lot.
/// @dev Every row runs at the PoC deploy's decline dials (band 3000, target 5000, stop 1000, cut 500, k 1.4) unless it says otherwise.
/// @dev The quote is the hostile-gas mock, honest until a row arms it, so the push rows share the fixture.
/// @dev Reasoning: the design record.
contract AceDeleverageClosesDustTest is WarpClock {
    /// @dev One market's dials; `_build` deploys a fresh hub for it and points every handle below at it.
    struct Spec {
        uint8 qDec;
        uint8 cDec;
        uint256 k;
        uint256 eps;
        uint256 cut;
        uint256 band;
        uint256 target;
        uint256 stop;
        uint256 floor; // the debt floor; the market stores twice it as `minPrincipal`
    }

    /// @dev What one crank would do, read before it runs: the restore `_fit` sizes, its net melt, and the close decision.
    struct Pred {
        uint256 units;
        uint256 debt;
        uint256 u; // the restore with the cut
        uint256 free; // the restore with none
        uint256 base; // `securedBase`
        uint256 sold; // what `_fit` sells
        bool charge;
        uint256 net; // the full fill's net melt
        bool closes; // `u > 0` and `debt < floor + net`
        uint256 uClose; // the smallest sale whose ceiled bill covers the debt
    }

    /// @dev What the borrower's own full repay booked, for the twin row.
    struct Twin {
        uint256 lender;
        uint256 revenue;
        uint256 quote;
        uint256 units;
    }

    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal pm;
    MockHostileGasERC20 internal quote;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal keeper;
    bytes32 internal id;
    uint256 internal par; // the market's price, and the record's windowed minimum unless a row moves it

    address internal alice = address(0xA11CE); // the market's one lender
    address internal borrower = address(0xB0B);
    address internal stranger = address(0x5157);

    uint256 internal constant S = 1 << 96;
    uint256 internal constant FLOOR = 10e6;
    uint256 internal constant BAND = 3000;
    uint256 internal constant STOP = 1000;
    uint256 internal constant THETA = 8500; // the live trigger as bps of par: 15% margin, inside the band, clear of the stop
    bytes4 internal constant CLOSE_UNFILLED = CloseUnfilled.selector;
    bytes32 internal constant COLLECTED_SIG = Lender.Collected.selector;
    bytes32 internal constant PUSH_FAILED_SIG = Lender.LenderPushFailed.selector;
    bytes32 internal constant SWEPT_SIG = Ace.RevenueSwept.selector;

    function setUp() public {
        _warpTo(1_000_000);
        _build(_spec());
    }

    /* ============================== the fixture ============================== */

    function _spec() internal pure returns (Spec memory) {
        return Spec(6, 18, 1.4e18, ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS, 500, BAND, 5000, STOP, FLOOR);
    }

    /// @dev A fresh hub, market, record and keeper at `s`, its lender seeded, and every handle pointed at it.
    function _build(Spec memory s) internal {
        quote = new MockHostileGasERC20("Quote", "Q", s.qDec);
        coll = new MockERC20("Collateral", "C", s.cDec);
        record = new MockPersistenceRecord(address(quote), address(coll));
        par = AceFixtures.priceAt(address(quote), address(coll), 0);
        record.setMinPrice(par);
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.record = address(record);
        p.minCoverageWad = s.k;
        p.minPrincipal = 2 * s.floor;
        p.deleverageFloorEpsBps = s.eps;
        p.deleverageProtocolBps = s.cut;
        p.deleverageBandBps = s.band;
        p.deleverageTargetBps = s.target;
        p.deleverageStopBps = s.stop;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        AceFixtures.installYesPolicy(ace, alice);
        keeper = new MockDeleverageKeeper(ace, address(quote), address(coll), S);
        uint256 dep = 100_000 * 10 ** s.qDec;
        quote.mint(alice, dep);
        vm.startPrank(alice);
        quote.approve(address(ace), type(uint256).max);
        ace.deposit(id, dep);
        vm.stopPrank();
    }

    function _p() internal view returns (MarketParams memory) {
        return ace.idToMarketParams(id);
    }

    /// @dev The live debt floor the hub derives: half the stored `minPrincipal`.
    function _floor() internal view returns (uint256) {
        return LoanMath.debtFloor(_p().minPrincipal);
    }

    /// @dev A loan of `debt` whose live trigger sits at `thetaBps` of par; the clock stays where the open ran.
    function _open(uint256 debt, uint256 thetaBps) internal returns (uint256) {
        return _openUnits(FullMath.mulDiv(_p().minCoverageWad * debt, S * 10000, thetaBps * par * 1e18), debt);
    }

    /// @dev A loan carrying exactly `units` and `debt`. Under `minPrincipal` it is born there on twice the lot, repaid to `debt`, then withdrawn to `units`.
    function _openUnits(uint256 units, uint256 debt) internal returns (uint256 loanId) {
        uint256 mp = _p().minPrincipal;
        uint256 born = debt < mp ? mp : debt;
        uint256 lot = debt < mp ? 2 * units : units; // `debt >= mp / 2`, so twice the lot covers `mp` wherever `units` covered `debt`
        coll.mint(borrower, lot);
        vm.startPrank(borrower);
        coll.approve(address(pm), lot);
        loanId = ace.open(id, lot, born, ProtocolPolicy.MIN_TENOR, borrower, OpenBounds(0, 0, 0));
        if (born > debt) {
            quote.approve(address(ace), born - debt);
            ace.repay(loanId, born - debt);
            ace.withdrawCollateral(loanId, lot - units, borrower);
        }
        vm.stopPrank();
        assertEq(read.loan(loanId).debt, debt, "fixture: the loan carries the row's debt");
        assertEq(read.loan(loanId).collateralUnits, units, "fixture: on the row's lot");
    }

    /// @dev The standard subject: 1.2x the debt floor at THETA, a day before expiry, the record proving the band at par.
    function _dustBound() internal returns (uint256 loanId) {
        loanId = _open(FLOOR * 12 / 10, THETA);
        _warpTo(_expiryOf(loanId) - 1 days);
        _enterBand(loanId);
    }

    function _expiryOf(uint256 loanId) internal view returns (uint256) {
        return uint256(read.loan(loanId).expiry);
    }

    function _closed(uint256 loanId) internal view returns (bool) {
        return read.loan(loanId).closedAt != 0;
    }

    function _level(uint256 trig, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - bps * 1e14);
    }

    /// @dev The record proves the band and NOT the trigger: persisted below the band level, not below the trigger; the minimum stays put.
    function _enterBand(uint256 loanId) internal {
        record.setBelowBand(_level(read.triggerPrice(loanId), _p().deleverageBandBps));
    }

    /// @dev The record persists at `ps` and the band rests ON it: in band while `bandLevel > ps`, distressed only if `trig > ps`.
    function _park(uint256 ps) internal {
        record.setBandPrice(ps);
        record.setMinPrice(ps);
    }

    function _repay(uint256 loanId, uint256 amount) internal {
        quote.mint(borrower, amount);
        vm.startPrank(borrower);
        quote.approve(address(ace), amount);
        ace.repay(loanId, amount);
        vm.stopPrank();
    }

    /// @dev Revenue wherever it sits: the crank piggybacks the sweep, so the counter alone can read low.
    function _revenue() internal view returns (uint256) {
        return read.protocolRevenue(id) + quote.balanceOf(AceFixtures.TREASURY);
    }

    /// @dev The lender's quote, pushed or not: a close may move the pool to the wallet.
    function _lenderTotal() internal view returns (uint256) {
        return quote.balanceOf(alice) + read.poolOwed(id);
    }

    /* ============================== the twins ============================== */

    /// @dev `Deleverage._owed`: what the keeper owes for `units` at `ps`, ceiled.
    function _owed(uint256 units, uint256 ps) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(ps, units * (10000 - _p().deleverageFloorEpsBps), 10000 * S);
    }

    /// @dev The close's size: the exact inverse of `_owed`'s ceil, the smallest sale whose bill covers `debt`.
    function _uClose(uint256 debt, uint256 ps) internal view returns (uint256) {
        return FullMath.mulDiv(debt - 1, 10000 * S, ps * (10000 - _p().deleverageFloorEpsBps)) + 1;
    }

    /// @dev `Deleverage._deleverageSizing` at a chosen cut; a `cut` of 0 is the cut-free restore, bit for bit.
    function _sizing(MarketParams memory p, uint256 cut, uint256 units, uint256 trig, uint256 ps) internal pure returns (uint256) {
        uint256 tStar = FullMath.mulDiv(ps, 1e18 - p.deleverageTargetBps * 1e14, 1e18);
        if (trig <= tStar) return 0;
        uint256 y = FullMath.mulDiv(ps, p.minCoverageWad * (10000 - p.deleverageFloorEpsBps), 1e22);
        uint256 u = FullMath.mulDiv(units, trig - tStar, FullMath.mulDiv(y, 10000 - cut, 10000) - tStar);
        return u > units ? units : u;
    }

    /// @dev `LoanAccounting.securedBase` re-spelled: `collateralNeeded` is the lens's; `requiredAt` and the sliver are transcribed.
    function _securedBase(uint256 loanId) internal view returns (uint256) {
        MarketParams memory p = _p();
        uint256 debt = read.loan(loanId).debt;
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 req = FullMath.mulDivRoundingUp(p.minCoverageWad * debt, S, p.price * 1e18);
        uint256 sliver = FullMath.mulDiv(debt * p.settleBountyBps, S, 10000 * p.price);
        uint256 keep = lens.collateralNeeded(id, loanId) + (sliver < units ? sliver : units);
        uint256 sellable = units > keep ? units - keep : 0;
        return req < sellable ? req : sellable;
    }

    /// @dev Every figure one crank at `ps` is held to, read before it runs.
    function _predict(uint256 loanId, uint256 ps) internal view returns (Pred memory r) {
        MarketParams memory p = _p();
        r.units = read.loan(loanId).collateralUnits;
        r.debt = read.loan(loanId).debt;
        uint256 trig = read.triggerPrice(loanId);
        r.u = _sizing(p, p.deleverageProtocolBps, r.units, trig, ps);
        r.free = _sizing(p, 0, r.units, trig, ps);
        r.base = _securedBase(loanId);
        if (r.u < r.units && r.u <= r.base) (r.sold, r.charge) = (r.u, true);
        else r.sold = r.free < r.base ? r.free : r.base;
        uint256 gross = _owed(r.sold, ps);
        r.net = gross - (r.charge ? FullMath.mulDiv(gross, p.deleverageProtocolBps, 10000) : 0);
        r.closes = r.u > 0 && r.debt < LoanMath.debtFloor(p.minPrincipal) + r.net;
        r.uClose = r.debt == 0 ? 0 : _uClose(r.debt, ps);
    }

    /// @dev The unearned share of `e` on `loanId` now, floored, exactly as the hub refunds an escrow.
    function _unearned(uint256 loanId, uint256 e) internal view returns (uint256) {
        Loan memory l = read.loan(loanId);
        if (l.tenor == 0) return 0;
        uint256 remaining = l.expiry > _now() ? l.expiry - _now() : 0;
        uint256 r = FullMath.mulDiv(e, remaining, l.tenor);
        return r < e ? r : e;
    }

    /* ============================== THE CLOSE ============================== */

    /// @notice A restore whose full fill would leave the debt under the debt floor closes the loan clean instead.
    /// @dev At THETA the settlement reserve caps the restore, and even that melt would leave about a third of the floor.
    function test_Close_ARestoreThatWouldLeaveDustClosesTheLoan() public {
        uint256 loanId = _dustBound();
        Pred memory r = _predict(loanId, par);
        assertTrue(r.closes, "PREMISE: the restore's full fill would melt the debt under the floor");
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertTrue(_closed(loanId), "the crank closed the loan");
        assertEq(read.debtOf(loanId), 0, "with no debt left");
        assertEq(read.claimOf(id, loanId), 0, "and no claim");
        assertEq(read.loan(loanId).collateralUnits, 0, "the position is released");
        assertEq(sold, r.uClose, "it sold the close's size");
        assertEq(read.unitsOwedOf(loanId, borrower), r.units - r.uClose, "and credited the borrower every unit left");
    }

    /// @notice The close sells EXACTLY the inverse of the keeper's ceiled bill: the smallest sale whose bill covers the whole debt.
    function test_Close_SellsTheExactInverseOfTheKeeperBill() public {
        uint256 loanId = _dustBound();
        uint256 debt = read.debtOf(loanId);
        uint256 uc = _uClose(debt, par);
        assertGe(_owed(uc, par), debt, "the close's bill covers the whole debt");
        assertLt(_owed(uc - 1, par), debt, "and one unit less would not: it is the smallest such sale");
        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertEq(sold, uc, "the crank sold exactly that size");
        assertEq(out, _owed(uc, par), "and the keeper paid exactly its ceiled bill");
        assertEq(keeper.lastQuoteOwed(), out, "the bill the hub asked for is the one it pulled");
        assertEq(keeper.lastUnitsSold(), uc, "and the units it handed over are the units it sold");
    }

    /// @notice A closing sale takes NO protocol cut, even where the restore it replaces would have charged one.
    /// @dev At theta 0.71 the cut-charging restore fits under the reserve, so the decision is judged on the CUT's net melt.
    function test_Close_TakesNoProtocolCut() public {
        uint256[2] memory cuts = [uint256(500), 2000];
        for (uint256 i; i < cuts.length; ++i) {
            Spec memory s = _spec();
            s.cut = cuts[i];
            _build(s);
            uint256 loanId = _open(FLOOR * 12 / 10, 7100);
            _warpTo(_expiryOf(loanId) - 1 days);
            _enterBand(loanId);
            Pred memory r = _predict(loanId, par);
            assertTrue(r.charge, "PREMISE: the restore fits, so a restore here would take the cut");
            assertTrue(r.closes, "PREMISE: and its net melt would leave dust, so the crank closes instead");
            uint256 rev0 = _revenue();
            (, uint256 out) = keeper.crankDeleverage(loanId);
            assertTrue(_closed(loanId), "the crank closed the loan");
            assertGt(FullMath.mulDiv(out, cuts[i], 10000), 0, "PREMISE: a cut on these proceeds would not round away");
            assertEq(_revenue() - rev0, 0, "revenue did not move: no cut on a closing sale");
        }
    }

    /// @notice The close books EXACTLY as the borrower's own full repay would: the same lender total, revenue and escrow refund.
    /// @notice The only differences are what the sale is: units sold, and the bill's overshoot credited back.
    /// @dev A day before expiry, so the escrow splits into an earned and an unearned share on both twins.
    function test_Close_BooksAsTheBorrowersOwnSaleAndRepayWould() public {
        uint256 loanId = _dustBound();
        uint256 debt = read.debtOf(loanId);
        uint256 rev0 = _revenue();
        uint256 lend0 = _lenderTotal();
        uint256 snap = vm.snapshotState();
        _repay(loanId, debt);
        assertTrue(_closed(loanId), "PREMISE: the twin repay closed the loan");
        Twin memory t = Twin(_lenderTotal() - lend0, _revenue() - rev0, read.quoteOwedOf(loanId, borrower), read.unitsOwedOf(loanId, borrower));
        vm.revertToState(snap);

        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertTrue(_closed(loanId), "the crank closed the loan");
        assertEq(_lenderTotal() - lend0, t.lender, "the lender's book matches the repay's to the wei");
        assertEq(_revenue() - rev0, t.revenue, "and so does revenue");
        assertEq(read.quoteOwedOf(loanId, borrower), t.quote + (out - debt), "the escrow refund matches; the crank adds only the overshoot");
        assertEq(read.unitsOwedOf(loanId, borrower), t.units - sold, "and the borrower keeps every unit the sale did not take");
    }

    /// @notice A closing sale fills WHOLE or the crank reverts: a partial fill would leave a live loan under the reserve.
    function test_Close_ThePartialFillReverts() public {
        uint256 loanId = _dustBound();
        uint256 debt = read.debtOf(loanId);
        keeper.setRefundBps(5000);
        vm.expectRevert(CLOSE_UNFILLED);
        keeper.crankDeleverage(loanId);
        assertEq(read.debtOf(loanId), debt, "nothing moved");
        assertFalse(_closed(loanId), "and the loan is still open");
    }

    /// @notice A WHOLLY refused closing fill reverts too: the restore's exact no-op would hand a keeper the position fee-free for a call.
    function test_Close_AWhollyRefusedFillReverts() public {
        uint256 loanId = _dustBound();
        uint256 units = read.loan(loanId).collateralUnits;
        keeper.setRefundBps(10000);
        vm.expectRevert(CLOSE_UNFILLED);
        keeper.crankDeleverage(loanId);
        assertEq(read.loan(loanId).collateralUnits, units, "nothing moved");
    }

    /* ============================== a loan AT the debt floor, the lowest live state ============================== */

    /// @notice A loan AT the debt floor closes on any admitted crank whose restore sells a unit: any melt would leave it under.
    /// @dev No repay leaves a live loan under the floor, so this is the lowest debt a crank ever meets.
    function test_Close_ALoanAtTheDebtFloorCloses() public {
        uint256 loanId = _open(FLOOR, THETA);
        _warpTo(_expiryOf(loanId) - 1 days);
        _enterBand(loanId);
        uint256 debt = read.debtOf(loanId);
        assertEq(debt, FLOOR, "PREMISE: the loan sits AT the debt floor");
        assertGt(_predict(loanId, par).u, 0, "PREMISE: the restore sells a unit");
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertTrue(_closed(loanId), "the floor loan closed");
        assertEq(sold, _uClose(debt, par), "selling the close's size");
    }

    /// @notice There is no early return at the debt floor: a loan AT it meets the whole gate stack like any other.
    function test_Close_AtTheDebtFloorTheWholeGateStackBinds() public {
        uint256 loanId = _open(FLOOR, THETA);
        assertEq(read.debtOf(loanId), FLOOR, "PREMISE: the loan sits AT the debt floor");
        uint256 trig = read.triggerPrice(loanId);

        record.setBelow(true); // flag mode: persisted below every level
        vm.expectRevert(Distressed.selector);
        keeper.crankDeleverage(loanId);
        record.setBelow(false);

        record.setBandPrice(_level(trig, BAND)); // ON the band level: not persisted below it
        vm.expectRevert(NotInBand.selector);
        keeper.crankDeleverage(loanId);

        record.setBandPrice(trig); // in band, and not below the trigger
        record.setMinPrice(0);
        vm.expectRevert(NoRecordPrice.selector);
        keeper.crankDeleverage(loanId);

        record.setMinPrice(_level(trig, STOP)); // ON the stop level
        vm.expectRevert(DeleverageStopped.selector);
        keeper.crankDeleverage(loanId);

        record.setMinPrice(par);
        uint256 snap = vm.snapshotState();
        _warpTo(_expiryOf(loanId));
        vm.expectRevert(LoanMatured.selector);
        keeper.crankDeleverage(loanId);
        vm.revertToState(snap);

        keeper.crankDeleverage(loanId);
        assertTrue(_closed(loanId), "control: with every gate open the same floor loan closes");
    }

    /// @dev DELETED: `test_Close_AReserveHeldDustLoanStillCloses`. A close on a reserve-held restore (`sold == 0`) needs a live loan
    /// @dev under the debt floor, and none exists: at or over it, the close needs `net(owed(sold)) > debt - floor >= 0`, so `sold > 0`.

    /* ============================== F4 ============================== */

    /// @notice F4: a closing crank is a terminal close: it pushes the lender's whole pool, STRICT, and the sweep runs after it.
    /// @notice A quote refusing the push keeps the credit; a limit short of the push's budget reverts `PushGasShort`.
    function test_Close_PushesTheLendersPool() public {
        uint256 loanId = _dustBound();
        uint256 owed0 = read.poolOwed(id);
        uint256 claim = read.claimOf(id, loanId);
        uint256 e = read.feeEscrowOf(loanId);
        uint256 credit = owed0 + claim + (e - _unearned(loanId, e));
        uint256 bal0 = quote.balanceOf(alice);
        uint256 snap = vm.snapshotState();

        vm.recordLogs();
        keeper.crankDeleverage(loanId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_closed(loanId), "the crank closed the loan");
        assertEq(read.poolOwed(id), 0, "the pool was pushed home");
        assertEq(quote.balanceOf(alice) - bal0, credit, "the lender received the whole pool, the close's own melt included");
        uint256 iPush = _indexOf(logs, COLLECTED_SIG);
        uint256 iSweep = _indexOf(logs, SWEPT_SIG);
        assertLt(iPush, logs.length, "the push fired");
        assertLt(iSweep, logs.length, "PREMISE: a sweep was due and ran");
        assertLt(iPush, iSweep, "and the sweep ran after the push");
        vm.revertToState(snap);

        quote.setReverting(true);
        vm.recordLogs();
        keeper.crankDeleverage(loanId);
        logs = vm.getRecordedLogs();
        assertTrue(_closed(loanId), "a refusing quote cannot fail the close");
        assertLt(_indexOf(logs, PUSH_FAILED_SIG), logs.length, "the swallowed push announced itself");
        assertEq(read.poolOwed(id), credit, "and the credit is restored whole");
        quote.setReverting(false);
        vm.revertToState(snap);

        uint256 least = _leastGasThatCloses(loanId);
        (bool ok, bytes memory ret) = _crankAt(loanId, least - 1_000);
        assertFalse(ok, "under the least budget the crank does not close");
        assertEq(bytes4(ret), PushGasShort.selector, "and it refuses by name: the push's budget is what binds");
    }

    function _indexOf(Vm.Log[] memory logs, bytes32 sig) internal view returns (uint256) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ace) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) return i;
        }
        return logs.length;
    }

    /// @dev One crank at `cap` gas, snapshotted: true when it completed and closed the loan, else the revert data.
    function _crankAt(uint256 loanId, uint256 cap) internal returns (bool ok, bytes memory ret) {
        uint256 snap = vm.snapshotState();
        (ok, ret) = address(keeper).call{gas: cap}(abi.encodeCall(MockDeleverageKeeper.crankDeleverage, (loanId)));
        if (ok) ok = _closed(loanId);
        vm.revertToState(snap);
    }

    /// @dev Bisect the least outer budget at which the closing crank completes.
    function _leastGasThatCloses(uint256 loanId) internal returns (uint256 hi) {
        uint256 lo = 50_000;
        hi = 5_000_000;
        (bool okHi,) = _crankAt(loanId, hi);
        assertTrue(okHi, "PREMISE: the closing crank completes at 5M");
        (bool okLo,) = _crankAt(loanId, lo);
        assertFalse(okLo, "PREMISE: and not at 50k");
        while (hi - lo > 1_000) {
            uint256 m = (lo + hi) / 2;
            (bool ok,) = _crankAt(loanId, m);
            if (ok) hi = m;
            else lo = m;
        }
    }

    /* ============================== BOUNDARIES ============================== */

    /// @dev A q18/c6 market at debt floor `floor` and one loan of `debt` at theta 0.71, the record proving the band at par.
    /// @dev One c6 unit is worth ~1e12 q18 atoms, so a head of a restore's net melt lands the debt on it exactly.
    function _q18Loan(uint256 floor, uint256 debt) internal returns (uint256 loanId) {
        Spec memory s = _spec();
        (s.qDec, s.cDec, s.floor) = (18, 6, floor);
        _build(s);
        loanId = _open(debt, 7100);
        _warpTo(_expiryOf(loanId) - 1 days);
        _enterBand(loanId);
    }

    /// @dev The charged restore on that loan with the debt floor at dust: its units and its NET melt.
    function _q18Restore(uint256 debt) internal returns (uint256 u, uint256 net) {
        uint256 loanId = _q18Loan(1, debt);
        Pred memory r = _predict(loanId, par);
        assertTrue(r.charge, "PREMISE: the restore fits and takes its cut");
        uint256 out;
        (u, out) = keeper.crankDeleverage(loanId);
        net = out - FullMath.mulDiv(out, 500, 10000);
        assertEq(debt - read.debtOf(loanId), net, "PREMISE: it restored, net of the cut");
        assertEq(net, r.net, "PREMISE: the twin prices the same net melt");
    }

    /// @notice A3: a full fill whose net melt lands EXACTLY on the debt floor restores; one atom more of floor and the crank closes.
    function test_Boundary_AMeltLandingExactlyOnTheDebtFloorRestores_OneAtomMoreCloses() public {
        uint256 debt = 20e18;
        (uint256 u, uint256 net) = _q18Restore(debt);

        uint256 loanId = _q18Loan(debt - net, debt);
        assertFalse(_predict(loanId, par).closes, "PREMISE: the decision is strict, so landing on the floor is not a close");
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertEq(sold, u, "a melt landing exactly on the floor restores: the whole sized sale sells");
        assertEq(read.debtOf(loanId), debt - net, "with its cut, and the debt lands ON the floor");
        assertFalse(_closed(loanId), "the loan stays open");

        loanId = _q18Loan(debt - net + 1, debt);
        (sold,) = keeper.crankDeleverage(loanId);
        assertTrue(_closed(loanId), "one atom more of floor and the same crank closes");
        assertEq(sold, _uClose(debt, par), "selling the close's size");
    }

    /// @notice A partial restore fill keeps the restore's cut and melts monotonically less, so it never leaves dust.
    /// @dev The loan whose full fill lands exactly on the debt floor: half the sale fills, and the debt lands above it.
    function test_Boundary_APartialRestoreFillNeverLeavesDust() public {
        uint256 debt = 20e18;
        (uint256 u, uint256 net) = _q18Restore(debt);
        uint256 loanId = _q18Loan(debt - net, debt);
        keeper.setRefundBps(5000);
        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertGt(sold, 0, "PREMISE: part of the sale filled");
        assertLt(sold, u, "PREMISE: and only part");
        assertEq(debt - read.debtOf(loanId), out - FullMath.mulDiv(out, 500, 10000), "the partial is the decision's restore: it keeps the cut");
        assertGt(read.debtOf(loanId), debt - net, "and it melts less than the full fill, so it lands above the floor");
        assertFalse(_closed(loanId), "and the loan stays open");
    }

    /// @notice The close can sell the WHOLE position: `uClose == C` is admitted, and the borrower is credited no units.
    /// @dev Equality needs the position to be worth under ~1.03x the debt at the close's price, so the row uses a 3-unit position.
    function test_Close_TheWholePositionCanSell() public {
        _build(Spec(6, 0, 1.05e18, 100, 500, BAND, 5000, STOP, 1.5e6));
        uint256 loanId = _openUnits(3, 1.9e6);
        uint256 ps = _level(read.triggerPrice(loanId), STOP) + 1; // one wei over the stop
        _park(ps);
        Pred memory r = _predict(loanId, ps);
        assertTrue(r.closes, "PREMISE: the crank closes");
        assertEq(r.uClose, 3, "PREMISE: and its size is the whole position");
        uint256 refund = _unearned(loanId, read.feeEscrowOf(loanId));
        (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
        assertTrue(_closed(loanId), "the loan closed");
        assertEq(sold, 3, "the whole position sold");
        assertEq(read.unitsOwedOf(loanId, borrower), 0, "so the borrower is credited no units");
        assertEq(read.quoteOwedOf(loanId, borrower), refund + (out - r.debt), "only the escrow refund and the bill's overshoot");
    }

    /// @notice On a coarse pair the bill's overshoot of the debt is real, under one unit's price, and credited to the borrower.
    function test_Close_OnACoarsePairTheOvershootIsUnderOneUnit() public {
        uint256 loanId = _q18Loan(10e18, 12e18);
        uint256 debt = read.debtOf(loanId);
        uint256 one = _owed(1, par);
        assertGt(one, 1e6, "PREMISE: one collateral unit is worth many quote atoms here");
        uint256 refund = _unearned(loanId, read.feeEscrowOf(loanId));
        (, uint256 out) = keeper.crankDeleverage(loanId);
        assertTrue(_closed(loanId), "the loan closed");
        assertGe(out, debt, "the bill covers the debt");
        assertLe(out - debt, one, "and overshoots it by under one unit's price plus an atom");
        assertEq(read.quoteOwedOf(loanId, borrower) - refund, out - debt, "the overshoot is credited to the borrower");
    }

    /// @notice The close's events: `Recash` of the whole debt from the hub, the borrower's three credits, then `Deleveraged`.
    /// @dev On the q18/c6 pair, so the overshoot credit is not zero and all three `OwedCredited` rows fire.
    function test_Close_EventsAndCredits() public {
        uint256 loanId = _q18Loan(10e18, 12e18);
        uint256 debt = read.debtOf(loanId);
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 uc = _uClose(debt, par);
        uint256 out = _owed(uc, par);
        uint256 refund = _unearned(loanId, read.feeEscrowOf(loanId));
        assertGt(out, debt, "PREMISE: the bill overshoots, so its credit fires");
        assertGt(refund, 0, "PREMISE: an escrow refund is owed");
        vm.expectEmit(true, true, false, true, address(ace));
        emit Deleverage.Recash(loanId, debt, address(ace));
        vm.expectEmit(true, true, false, true, address(ace));
        emit LoanAccounting.OwedCredited(loanId, borrower, units - uc, 0);
        vm.expectEmit(true, true, false, true, address(ace));
        emit LoanAccounting.OwedCredited(loanId, borrower, 0, refund);
        vm.expectEmit(true, true, false, true, address(ace));
        emit LoanAccounting.OwedCredited(loanId, borrower, 0, out - debt);
        vm.expectEmit(true, true, false, true, address(ace));
        emit Deleverage.Deleveraged(loanId, uc, out, debt, address(keeper));
        keeper.crankDeleverage(loanId);
        assertEq(read.unitsOwedOf(loanId, borrower), units - uc, "the units credit");
        assertEq(read.quoteOwedOf(loanId, borrower), refund + out - debt, "the quote credit");
    }

    /// @notice `minStableOut` binds the close's proceeds like any other crank's.
    function test_Close_ACallerFloorBindsTheCloseProceeds() public {
        uint256 loanId = _dustBound();
        uint256 out = _owed(_uClose(read.debtOf(loanId), par), par);
        vm.expectRevert(BelowCallerFloor.selector);
        keeper.crankWithFloor(loanId, out + 1);
        (, uint256 s) = keeper.crankWithFloor(loanId, out);
        assertEq(s, out, "at exactly the close's proceeds the floor admits it");
        assertTrue(_closed(loanId), "and the loan closed");
    }

    /// @notice The lens answers ELIGIBLE at the debt floor, and the real crank closes the loan.
    function test_Lens_EligibleAtTheDebtFloorAndTheCrankCloses() public {
        uint256 atFloor = _open(FLOOR, THETA);
        _warpTo(_expiryOf(atFloor) - 1 days);
        _enterBand(atFloor);
        assertTrue(lens.deleverageEligible(atFloor), "at the debt floor the lens says yes");
        keeper.crankDeleverage(atFloor);
        assertTrue(_closed(atFloor), "and the real crank closes the loan");
    }

    /* ============================== FUZZ ============================== */

    /// @dev A loan of `debtSeed` at `thetaSeed`, the record anywhere in its corridor.
    function _fuzzLoan(uint256 debtSeed, uint256 thetaSeed, uint256 psSeed) internal returns (uint256 loanId, uint256 ps) {
        uint256 theta = bound(thetaSeed, 5100, 8900);
        loanId = _open(bound(debtSeed, FLOOR, 4 * FLOOR), theta);
        uint256 trig = read.triggerPrice(loanId);
        ps = bound(psSeed, _level(trig, STOP) + 1, _level(trig, BAND) - 1);
        _park(ps);
    }

    /// @notice Whatever the size, margin, price and fill, a legal crank restores, closes, or changes nothing; it never leaves dust.
    /// @dev A predicted close fills whole and closes, or fills short and reverts; anything else lands at or over the debt floor.
    function testFuzz_AnyLegalCrankRestoresOrClosesNeverLeavesDust(uint256 debtSeed, uint256 thetaSeed, uint256 psSeed, uint256 fillSeed) public {
        (uint256 loanId, uint256 ps) = _fuzzLoan(debtSeed, thetaSeed, psSeed);
        Pred memory r = _predict(loanId, ps);
        uint256 trig0 = read.triggerPrice(loanId);
        keeper.setRefundBps(fillSeed % 3 == 0 ? bound(fillSeed, 1, 9999) : 0); // a partial fill a third of the time
        (bool ok, bytes memory ret) = address(keeper).call(abi.encodeCall(MockDeleverageKeeper.crankDeleverage, (loanId)));
        if (!ok) {
            assertEq(bytes4(ret), CLOSE_UNFILLED, "the only refusal here is a short closing fill");
            assertTrue(r.closes && keeper.refundBps() > 0, "and only a predicted close filled short refuses");
            assertEq(read.debtOf(loanId), r.debt, "leaving the loan as it was");
        } else if (_closed(loanId)) {
            assertTrue(r.closes, "a crank closes only where the decision says");
            assertEq(read.debtOf(loanId), 0, "and a close retires the whole debt");
        } else {
            assertFalse(r.closes, "a predicted close that filled whole closed");
            uint256 left = read.debtOf(loanId);
            assertGe(left, _floor(), "a restore never lands under the debt floor");
        }
        assertLe(read.triggerPrice(loanId), trig0, "and the trigger never rises");
    }

    /// @dev On a crank the decision closes: it sells `uClose`, and that is under one debt floor's worth past the restore `_fit` sized.
    function _assertCloseWithinOneFloor(uint256 loanId, uint256 ps) internal returns (bool) {
        Pred memory r = _predict(loanId, ps);
        if (!r.closes) return false;
        (uint256 sold,) = keeper.crankDeleverage(loanId);
        assertTrue(_closed(loanId), "a close the decision predicts closes");
        assertEq(sold, r.uClose, "selling exactly the close's size");
        MarketParams memory p = _p();
        uint256 extra = r.uClose > r.sold + 1 ? r.uClose - r.sold - 1 : 0;
        assertLt(extra * ps * (10000 - p.deleverageFloorEpsBps), (_floor() + 1) * 10000 * S, "M2: the close sells under one debt floor past the restore");
        return true;
    }

    /// @notice M2: past the restore the same crank would have sold, the close sells under one debt floor's worth at the record price.
    function testFuzz_TheCloseSellsUnderOneFloorPastTheRestore(uint256 debtSeed, uint256 thetaSeed, uint256 psSeed) public {
        (uint256 loanId, uint256 ps) = _fuzzLoan(debtSeed, thetaSeed, psSeed);
        _assertCloseWithinOneFloor(loanId, ps);
    }

    /* ============================== THE EXTENSION: rows re-premised from the deleted minDebt-cap suite ============================== */

    /// @dev The borrower's own extension, fee funded at its quote; true when it EXTENDED the same loan in place, false when it refused.
    function _extend(uint256 loanId) internal returns (bool rolled) {
        uint64 x = read.loan(loanId).expiry;
        uint256 n = read.loanCount();
        (,, uint256 fee) = ace.tryExtend(loanId, 0, "", borrower);
        quote.mint(borrower, fee);
        vm.prank(borrower);
        quote.approve(address(ace), fee);
        vm.prank(borrower);
        try ace.extend(loanId, 0, "") {} catch {}
        assertEq(read.loanCount(), n, "an extension mints no loan");
        rolled = _extended(read, loanId, x);
        assertEq(read.loan(loanId).closedAt, 0, "and either answer leaves the loan live");
    }

    /// @dev The record back at par for both questions: its windowed minimum, and nothing persisted below any trigger the price admits.
    function _recordAtPar() internal {
        record.setMinPrice(par);
        record.setBandPrice(par);
    }

    /// @dev What the REAL `extend` does at `expiry - 1` with nothing done in between, run in a snapshot and rolled back: true when it lands.
    function _extendsBeforeExpiry(uint256 loanId) internal returns (bool rolled) {
        uint256 snap = vm.snapshotState();
        _warpTo(_expiryOf(loanId) - 1);
        _recordAtPar();
        rolled = _extend(loanId);
        vm.revertToState(snap);
    }

    /// @notice A stranger's crank in a loan's last live second either closes the loan clean or leaves the borrower's extension admissible.
    /// @notice It closes exactly where the restore's net melt would leave dust; at THETA that is every size the cap suite pinned, and 3x restores.
    /// @dev The extension is asked in the crank's own second, the last one in which any extension lands.
    /// @dev A closed loan refuses `forceClose` with `LoanClosed`: the debt was paid in full and the equity credited, as a stranger's full repay could.
    function test_NoFlip_ALastSecondCrankClosesTheLoanOrLeavesTheExtensionAdmissible() public {
        uint256[5] memory multBps = [uint256(10000), 12000, 13900, 20000, 30000];
        uint256 closes;
        for (uint256 i; i < multBps.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 loanId = _open(FLOOR * multBps[i] / 10000, THETA);
            assertTrue(_extendsBeforeExpiry(loanId), "PREMISE: untouched, the extension lands");
            _warpTo(_expiryOf(loanId) - 1);
            _enterBand(loanId);
            bool predicted = _predict(loanId, par).closes;
            keeper.crankDeleverage(loanId);
            if (_closed(loanId)) {
                assertTrue(predicted, "the crank closed exactly where the restore would have left dust");
                assertEq(read.debtOf(loanId), 0, "and retired the whole debt");
                vm.expectRevert(LoanClosed.selector);
                vm.prank(stranger);
                ace.forceClose(loanId);
                ++closes;
            } else {
                assertFalse(predicted, "a restore that leaves the debt at or over the floor does not close");
                assertGe(read.debtOf(loanId), FLOOR, "it left the debt at or over the floor");
                (bool ok, bytes4 reason,) = ace.tryExtend(loanId, 0, "", borrower);
                assertTrue(ok, string.concat("the extension is still admissible after the crank; reason ", vm.toString(bytes32(reason))));
                assertTrue(_extend(loanId), "and the extension lands: the crank did not refuse it");
            }
            vm.revertToState(snap);
        }
        assertEq(closes, 4, "the four sizes the cap suite pinned close, and the 3x control restores");
    }

    /// @notice Whatever the size, margin, record price, fill and moment, a legal crank closes the loan or leaves an admissible extension landing.
    /// @dev The REAL `extend` runs at `expiry - 1` twice from one state: once untouched (snapshot), once after the crank.
    /// @dev At the extension both runs read the record back at par: the property holds the record path fixed and varies only the crank.
    /// @dev A short fill of a closing sale reverts and leaves the loan as it was, so its extension lands as the untouched one did.
    function testFuzz_ExtensionInvariantUnderAnyLegalPreCrank(uint256 debtSeed, uint256 thetaSeed, uint256 psSeed, uint256 fillSeed, uint256 whenSeed) public {
        uint256 loanId = _open(bound(debtSeed, FLOOR, 3 * FLOOR), bound(thetaSeed, 5100, 8900));
        _warpTo(bound(whenSeed, _now(), _expiryOf(loanId) - 1));
        uint256 trig = read.triggerPrice(loanId);
        record.setBandPrice(trig); // below the band level, not below the trigger: in band, not distressed
        uint256 ps = bound(psSeed, _level(trig, STOP) + 1, _level(trig, BAND) - 1);
        assertTrue(_extendsBeforeExpiry(loanId), "PREMISE: untouched, the extension lands");

        record.setMinPrice(ps);
        keeper.setRefundBps(bound(fillSeed, 0, 9999));
        (bool ok, bytes memory ret) = address(keeper).call(abi.encodeCall(MockDeleverageKeeper.crankDeleverage, (loanId)));
        if (!ok) assertEq(bytes4(ret), CLOSE_UNFILLED, "the only refusal here is a short closing fill");
        if (_closed(loanId)) {
            assertEq(read.debtOf(loanId), 0, "a closing crank retires the whole debt");
            return;
        }
        uint256 debtAfter = read.debtOf(loanId);
        _warpTo(_expiryOf(loanId) - 1);
        _recordAtPar();
        assertTrue(_extend(loanId), "an extension that landed untouched still lands after the crank");
        assertGe(debtAfter, FLOOR, "no crank leaves a live loan under the debt floor");
    }

    /// @notice An unbounded record price never reverts the lens and never wraps the crank: the lens mirrors the gates alone, so it says eligible.
    /// @dev The crank's sizing sells nothing first: at such a price the loan sits far above target, so no close is ever sized.
    function test_Lens_AnUnboundedRecordPriceIsEligibleAndNeverReverts() public {
        uint256 loanId = _open(FLOOR * 2, THETA);
        _warpTo(_expiryOf(loanId) - 1 days);
        _enterBand(loanId);
        assertTrue(lens.deleverageEligible(loanId), "PREMISE: at par the loan is eligible");
        uint256 edge = type(uint256).max / (10000 - _p().deleverageFloorEpsBps);
        uint256[3] memory prices = [edge, edge + 1, type(uint256).max];
        for (uint256 i; i < prices.length; ++i) {
            record.setMinPrice(prices[i]);
            assertTrue(lens.deleverageEligible(loanId), "an unbounded price passes the gates, and the view does not revert");
            (uint256 sold, uint256 out) = keeper.crankDeleverage(loanId);
            assertEq(sold + out, 0, "and the crank's sizing sells nothing: no close's product is ever formed");
        }
        assertEq(read.debtOf(loanId), FLOOR * 2, "nothing moved");
    }

    /// @notice M2's deterministic corners: a close at band entry, and one a wei over the stop.
    function test_TheCloseBound_AtBandEntryAndOneWeiOverTheStop() public {
        uint256 a = _open(FLOOR * 15 / 10, 7100);
        uint256 ps = _level(read.triggerPrice(a), BAND) - 1;
        _park(ps);
        assertTrue(_assertCloseWithinOneFloor(a, ps), "the band-entry crank closes");
        uint256 b = _open(FLOOR * 15 / 10, 7100);
        ps = _level(read.triggerPrice(b), STOP) + 1;
        _park(ps);
        assertTrue(_assertCloseWithinOneFloor(b, ps), "the crank a wei over the stop closes");
    }
}
