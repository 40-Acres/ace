// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Loan, MarketParams, MarketState, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceS10ValueFlow
/// @notice Audit run 2026-10-03-251533 phase 10: the value-moving shapes no solvency campaign drives, against every book.
/// @notice Deleverage with a cut AND a partial-fill refund; a home cash-out refinance with a withdrawal leg; a zero-fresh refinance.
/// @notice A recordless settlement's forfeited coverage, sold in part and redeemed in kind; an armed fold with its sliver and a floored credit.
/// @dev Four books after EVERY step: the quote equality, the custody ledgers A/B/C, LR-9 per market, and the pooled pair.
/// @dev Per verb, also: the token that moved IS the variable the books recorded.
/// @dev Two markets on one quote and one collateral, with DIFFERENT lenders, so a custody or pool leak has a neighbour to land in.
contract AceS10ValueFlowTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    MockDeleverageKeeper internal crank;

    bytes32 internal midRec; // record-backed, deleverage band on with a 500 bps cut, terms 7-30 days, lender L1
    bytes32 internal midBare; // recordless, band off, a 20 bps fill fee, one 7-day term, lender L2

    address internal constant L1 = AceFixtures.LENDER;
    address internal constant L2 = address(0xB2B2);
    address internal constant BORROWER = address(0xB0B);
    address internal constant KEEPER = address(0x4EE9);
    address internal constant BUYER = address(0xB111);

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant COLL = 10_000e18; // worth 10,000 USDC at par, the price of both markets

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        crank = new MockDeleverageKeeper(ace, address(usdc), address(coll), Q96);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.maxTenor = 30 days;
        p.deleverageFloorEpsBps = 100;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 5000;
        p.deleverageStopBps = 1000;
        p.deleverageProtocolBps = 500;
        midRec = ace.createMarket(p);

        MarketParams memory q = AceFixtures.marketParams(address(usdc), address(coll));
        q.fillFeeBps = 20;
        q.lender = L2;
        midBare = ace.createMarket(q);

        _deposit(L1, midRec, 20_000e6);
        _deposit(L2, midBare, 20_000e6);
        coll.mint(BORROWER, 1e30);
        usdc.mint(BORROWER, 1e30);
        vm.startPrank(BORROWER);
        coll.approve(address(pm), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
        usdc.mint(BUYER, 1e30);
        vm.prank(BUYER);
        usdc.approve(address(ace), type(uint256).max);
        _books("setUp");
    }

    function _deposit(address who, bytes32 mid, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(bytes32 mid, uint256 units, uint256 principal, uint64 tenor) internal returns (uint256 id) {
        vm.prank(BORROWER);
        id = ace.open(mid, units, principal, tenor, BORROWER, OpenBounds(0, 0, 0));
    }

    /* ====== the four books ====== */

    function _books(string memory at) internal view {
        _quoteIdentity(at);
        _pooledPair(L1, midRec, at);
        _pooledPair(L2, midBare, at);
        _custody(at);
        _lr9(midRec, at);
        _lr9(midBare, at);
        assertEq(coll.balanceOf(address(ace)), 0, string.concat(at, ": the hub kept collateral past the call"));
    }

    function _loansOf(bytes32 mid) internal view returns (uint256[] memory) {
        return ace.marketLoans(mid, 0, ace.marketLoansLength(mid));
    }

    /// @dev `balanceOf(hub) == sum(cash + protocolRevenue + quoteOwedTotal) + sum(feeEscrow) + sum over DISTINCT lenders of owed`.
    function _quoteIdentity(string memory at) internal view {
        uint256 booked;
        bytes32[2] memory mids = [midRec, midBare];
        for (uint256 i; i < 2; i++) {
            MarketState memory s = read.marketState(mids[i]);
            booked += s.cash + s.protocolRevenue + s.quoteOwedTotal;
        }
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            booked += read.feeEscrowOf(id);
        }
        (,, uint256 o1) = read.lenderPools(L1, address(usdc));
        (,, uint256 o2) = read.lenderPools(L2, address(usdc));
        booked += o1 + o2;
        assertEq(usdc.balanceOf(address(ace)), booked, string.concat(at, ": QUOTE identity"));
    }

    /// @dev Each lender runs exactly one market here, so its pooled `resting` IS that market's cash and its `lent` that market's claims.
    function _pooledPair(address lender, bytes32 mid, string memory at) internal view {
        (uint256 resting, uint256 lent,) = read.lenderPools(lender, address(usdc));
        assertEq(resting, read.marketState(mid).cash, string.concat(at, ": pooled resting != the market's cash"));
        uint256[] memory ids = _loansOf(mid);
        uint256 claims;
        for (uint256 i; i < ids.length; i++) {
            claims += read.claimOf(mid, ids[i]);
            Loan memory l = read.loan(ids[i]);
            if (l.closedAt == 0) assertEq(read.claimOf(mid, ids[i]), l.debt, string.concat(at, ": a live claim != its debt"));
        }
        assertEq(lent, claims, string.concat(at, ": pooled lent != the market's claims"));
    }

    /// @dev Every address this file ever lets a close, a fold or a settlement credit units to.
    function _unitsOwed(uint256 id) internal view returns (uint256 s) {
        address[6] memory who = [BORROWER, KEEPER, address(crank), L1, L2, BUYER];
        for (uint256 k; k < 6; k++) {
            s += read.unitsOwedOf(id, who[k]);
        }
    }

    /// @dev (A) live units match the loan, (B) retired units are exactly the pot plus the claimants, (C) the pot is the sum and is funded.
    function _custody(string memory at) internal view {
        uint256 live;
        uint256 retired;
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            (uint256 c, uint256 r) = _custodyOf(id, at);
            live += c;
            retired += r;
        }
        assertEq(pm.custodiedOf(address(coll)), live + retired, string.concat(at, ": C, custodiedOf != live + retired"));
        assertGe(coll.balanceOf(address(pm)), pm.custodiedOf(address(coll)), string.concat(at, ": C, the pot is under its ledger"));
    }

    /// @dev One loan's (A) and (B) legs, returning its live and retired units; split out so the via-IR build fits the stack.
    function _custodyOf(uint256 id, string memory at) internal view returns (uint256 c, uint256 r) {
        Loan memory l = read.loan(id);
        if (l.market == bytes32(0)) return (0, 0); // no orders are posted here
        c = pm.collateralOf(id);
        r = pm.retiredOf(id);
        assertEq(c, l.closedAt == 0 ? l.collateralUnits : 0, string.concat(at, ": A, live custody != the loan's units"));
        if (l.closedAt != 0) assertEq(l.collateralUnits, 0, string.concat(at, ": A, a closed loan still carries units"));
        assertEq(r, read.invPotOf(l.market, id) + _unitsOwed(id), string.concat(at, ": B, retired != pot + claimant credits"));
    }

    /// @dev LR-9 per market: backed burns net of outflow are exactly the settled pots still resting.
    function _lr9(bytes32 mid, string memory at) internal view {
        MarketState memory s = read.marketState(mid);
        uint256[] memory ids = _loansOf(mid);
        uint256 inv;
        for (uint256 i; i < ids.length; i++) {
            inv += read.invPotOf(mid, ids[i]);
        }
        assertEq(s.cumulativeBackedBurns - s.netSyntheticOutflow, inv, string.concat(at, ": LR-9"));
    }

    /* ====== 1. deleverage: a cut AND a partial-fill refund in one crank ====== */

    struct Snap {
        uint256 hub;
        uint256 rev;
        uint256 debt;
        uint256 units;
        uint256 lent;
        uint256 owed;
    }

    function _snap(uint256 id) internal view returns (Snap memory s) {
        s.hub = usdc.balanceOf(address(ace));
        s.rev = read.protocolRevenue(midRec);
        s.debt = read.debtOf(id);
        s.units = read.loan(id).collateralUnits;
        (, s.lent, s.owed) = read.lenderPools(L1, address(usdc));
    }

    /// @notice The keeper pays exactly what the books melt plus the cut; the refunded tail re-enters custody; every book holds.
    function test_DeleverageWithCutAndRefund_MovesWhatItBooks() public {
        uint256 id = _open(midRec, COLL, FullMath.mulDiv(5_000e6, 1e18, 1.4e18), 0);
        _books("open");
        uint256 ps = (read.triggerPrice(id) * 10000) / 7500; // in band, above the stop, not distressed
        record.setMinPrice(ps);
        record.setBandPrice(ps);
        crank.setRefundBps(3000);

        Snap memory b = _snap(id);
        (uint256 filled, uint256 stableOut) = crank.crankDeleverage(id);
        _books("deleverage");
        _checkCrank(id, b, _snap(id), filled, stableOut, ps);

        record.setBandPrice(0);
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        uint256 l1Before = usdc.balanceOf(L1);
        vm.prank(BORROWER);
        ace.repay(id, type(uint256).max);
        _books("closing repay");
        assertGt(usdc.balanceOf(L1) - l1Before, 0, "the close pushed the lender's pool");
        vm.prank(BORROWER);
        ace.claimOwed(id, BORROWER);
        _books("claim");
        assertEq(pm.retiredOf(id), 0, "nothing retired is left once the borrower claims");
    }

    /// @dev The per-verb half of the deleverage row, in its own frame (stack).
    function _checkCrank(uint256 id, Snap memory b, Snap memory a, uint256 filled, uint256 stableOut, uint256 ps) internal view {
        assertGt(filled, 0, "premise: the crank filled");
        assertGt(crank.lastUnitsSold(), filled, "premise: the keeper refunded part of what was released");
        uint256 cut = a.rev - b.rev;
        uint256 melted = b.debt - a.debt;
        assertGt(cut, 0, "premise: the cut-charging restore fit, so the cut path ran");
        assertEq(cut, FullMath.mulDiv(stableOut, 500, 10000), "the cut is the dial's share of what was paid");
        assertEq(crank.lastQuoteOwed() - usdc.balanceOf(address(crank)), stableOut, "MOVED: the keeper paid exactly the reported proceeds");
        assertEq(a.hub - b.hub, stableOut, "MOVED: the hub received exactly the proceeds");
        assertEq(cut + melted, stableOut, "BOOKED: every atom of proceeds is cut or melt");
        assertEq(b.lent - a.lent, melted, "BOOKED: lent falls by the melt");
        assertEq(a.owed - b.owed, melted, "BOOKED: owed rises by the melt");
        assertEq(read.claimOf(midRec, id), a.debt, "BOOKED: the claim fell with the debt");
        assertEq(b.units - a.units, filled, "the loan lost exactly the filled units");
        assertEq(coll.balanceOf(address(crank)), filled, "the keeper kept exactly the filled units");
        assertEq(stableOut, FullMath.mulDivRoundingUp(ps, filled * 9900, 10000 * Q96), "the keeper paid the floor on FILLED units only");
    }

    /* ====== 2. a home cash-out refinance: recycle, strict payout, withdrawal leg ====== */

    /// @notice The borrower is paid `P - feeNew + refundOld - debtOld` once, the cash falls by the fresh part only, and units leave by the leg.
    function test_HomeCashOutRefinanceWithWithdrawal_PaysTheNetOnce() public {
        uint256 id = _open(midRec, COLL, 3_000e6, 30 days);
        _books("open");
        _warpBy(10 days);
        uint256 esc = read.feeEscrowOf(id);
        uint256 refundOld = FullMath.mulDiv(esc, 20 days, 30 days);
        uint256 feeNew = LoanMath.originationFee(4_000e6, 30 days, 40, 7 days);
        uint256 expectedOut = 4_000e6 - feeNew + refundOld - 3_000e6;

        uint256 cashBefore = read.marketState(midRec).cash;
        uint256 hubBefore = usdc.balanceOf(address(ace));
        uint256 bUsdc = usdc.balanceOf(BORROWER);
        uint256 bColl = coll.balanceOf(BORROWER);
        vm.prank(BORROWER);
        uint256 nid = ace.refinanceTo(MigrateArgs(id, midRec, 4_000e6, 30 days, OpenBounds(0, 0, 0), 1_000e18, BORROWER));
        _books("refinanceTo with a withdrawal leg");

        assertEq(usdc.balanceOf(BORROWER) - bUsdc, expectedOut, "MOVED: the borrower got the net out, once");
        assertEq(hubBefore - usdc.balanceOf(address(ace)), expectedOut, "MOVED: the hub paid exactly the net out");
        assertEq(read.quoteOwedOf(id, BORROWER), 0, "and booked no second copy of it as a credit");
        assertEq(cashBefore - read.marketState(midRec).cash, 1_000e6, "BOOKED: cash fell by the fresh part, P less the recycled debt");
        assertEq(coll.balanceOf(BORROWER) - bColl, 1_000e18, "the leg released exactly what it named");
        assertEq(read.loan(nid).collateralUnits, COLL - 1_000e18, "and the successor carries the rest");
    }

    /// @notice A refinance whose principal is UNDER the old debt, bridged by the refund: it draws no fresh cash and still nets.
    function test_ZeroFreshHomeRefinance_DrawsNothingAndNets() public {
        uint256 id = _open(midRec, COLL, 3_000e6, 30 days);
        uint256 refundOld = read.feeEscrowOf(id); // same block: nothing earned yet
        uint256 newP = 2_990e6;
        uint256 feeNew = LoanMath.originationFee(newP, 7 days, 40, 7 days);
        uint256 expectedOut = newP - feeNew + refundOld - 3_000e6;
        (,, uint256 owedBefore) = read.lenderPools(L1, address(usdc));
        uint256 cashBefore = read.marketState(midRec).cash;
        uint256 bUsdc = usdc.balanceOf(BORROWER);

        vm.prank(BORROWER);
        ace.refinance(id, newP, 7 days, OpenBounds(0, 0, 0));
        _books("zero-fresh refinance");

        assertEq(read.marketState(midRec).cash, cashBefore, "BOOKED: a draw recycling its whole principal takes no cash");
        assertEq(usdc.balanceOf(BORROWER) - bUsdc, expectedOut, "MOVED: the borrower got the refund's surplus, once");
        (,, uint256 owedAfter) = read.lenderPools(L1, address(usdc));
        uint256 tick = LoanMath.tickCut(feeNew);
        assertEq(owedAfter - owedBefore, (3_000e6 - newP) + tick, "BOOKED: the unrecycled principal and the new tick reach owed");
    }

    /* ====== 3. a recordless settlement: the forfeit, a partial ask, the in-kind rest ====== */

    /// @notice The lot splits sliver / borrower / pot to the atom; the ask and the redemption move exactly what the pot loses.
    function test_RecordlessForfeit_SoldInPartAndRedeemed() public {
        uint256 id = _open(midBare, COLL, 3_000e6, 0);
        _warpTo(read.loan(id).expiry);
        vm.prank(KEEPER);
        ace.forceClose(id);
        _books("recordless forceClose");

        uint256 sliver = read.unitsOwedOf(id, KEEPER);
        uint256 toBorrower = read.unitsOwedOf(id, BORROWER);
        uint256 pot = read.invPotOf(midBare, id);
        assertEq(sliver + toBorrower + pot, COLL, "the lot splits to the atom");
        assertEq(pot, FullMath.mulDivRoundingUp(1.4e18 * 3_000e6, Q96, ace.idToMarketParams(midBare).price * 1e18) + 1, "the pot is the whole line");

        _warpTo(read.inventoryAskOpensAt(id));
        (,, uint256 owedBefore) = read.lenderPools(L2, address(usdc));
        uint256 buyerBefore = usdc.balanceOf(BUYER);
        vm.prank(BUYER);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(id, 1_000e6, 0, BUYER);
        _books("partial ask");
        assertEq(buyerBefore - usdc.balanceOf(BUYER), filled, "MOVED: the buyer paid what was filled");
        (,, uint256 owedAfter) = read.lenderPools(L2, address(usdc));
        assertEq(owedAfter - owedBefore, filled, "BOOKED: the lender's owed rose by what was filled");
        assertEq(pot - read.invPotOf(midBare, id), unitsOut, "BOOKED: the pot fell by what was delivered");
        assertEq(coll.balanceOf(BUYER), unitsOut, "MOVED: the buyer got what the pot lost");

        uint256 rest = read.invPotOf(midBare, id);
        vm.prank(L2);
        assertEq(ace.redeemInKind(id, L2), rest, "the lender takes the rest whole");
        _books("redeemInKind");
        vm.prank(BORROWER);
        ace.claimOwed(id, BORROWER);
        vm.prank(KEEPER);
        ace.claimOwed(id, KEEPER);
        vm.prank(L2);
        ace.collect(address(usdc), L2);
        _books("claims and collect");
        assertEq(pm.retiredOf(id), 0, "every retired unit has a home");
    }

    /* ====== 4. an armed fold: the sliver, and a floored successor's credit ====== */

    /// @notice A loan repaid under minDebt rolls into a minDebt successor; the net out is CREDITED once and claims to the atom.
    function test_ArmedFoldWithSliverAndFlooredCredit() public {
        uint256 id = _open(midRec, 1_000e18, 50e6, 0);
        vm.prank(BORROWER);
        ace.repay(id, 45e6);
        vm.prank(BORROWER);
        ace.setAutoRefinance(id, 7 days, 0, 0);
        _books("armed under minDebt");

        _warpTo(read.loan(id).expiry);
        uint256 hubBefore = usdc.balanceOf(address(ace));
        uint256 treasuryBefore = usdc.balanceOf(AceFixtures.TREASURY);
        vm.prank(KEEPER);
        ace.forceClose(id);
        _books("fold");
        uint256 nid = read.loanCount();
        assertEq(read.loan(nid).debt, 10e6, "premise: the successor floored at minDebt");

        uint256 fee = LoanMath.originationFee(10e6, 7 days, 40, 7 days);
        uint256 out = 10e6 - fee - 5e6;
        assertEq(read.quoteOwedOf(id, BORROWER), out, "BOOKED: the net out is credited on the retired loan");
        uint256 swept = usdc.balanceOf(AceFixtures.TREASURY) - treasuryBefore;
        assertEq(hubBefore - usdc.balanceOf(address(ace)), swept, "MOVED: only the piggyback sweep left the hub; the roll moved no quote");
        uint256 sliver = read.unitsOwedOf(id, KEEPER);
        assertEq(read.loan(nid).collateralUnits + sliver, 1_000e18, "the successor carries the lot less the sliver");

        uint256 bUsdc = usdc.balanceOf(BORROWER);
        vm.prank(BORROWER);
        ace.claimOwed(id, BORROWER);
        assertEq(usdc.balanceOf(BORROWER) - bUsdc, out, "MOVED: the claim paid the credit exactly");
        vm.prank(KEEPER);
        ace.claimOwed(id, KEEPER);
        assertEq(coll.balanceOf(KEEPER), sliver, "MOVED: the keeper got the sliver exactly");
        _books("claims");
        assertEq(pm.retiredOf(id), 0, "nothing retired is left on the rolled loan");
    }
}
