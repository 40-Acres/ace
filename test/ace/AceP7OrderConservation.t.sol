// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Cfg, Loan, MarketParams, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP7OrderConservation
/// @notice Phase-7 (attacker) fuzz over the credit-order door, which no invariant handler drives.
/// @notice A filler chooses `principalOut` and `unitsOut` freely; the maker's escrow must be conserved across the
/// @notice order and every loan it spawned, no spawned loan may sit above the maker's worst trigger, and the
/// @notice maker's total debt must equal the principal the fills drew.
/// @dev Fills that the rails refuse are skipped, so the fuzz measures what an ADMITTED fill can do to the maker.
contract AceP7OrderConservationTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal lender = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);

    uint64 internal constant TEN = 7 days;
    uint256 internal constant P = 100_000e6;
    uint256 internal LIQ_LOW;
    uint256 internal LIQ_HIGH;

    // the running tallies one fuzz run accumulates, kept in storage so the loop body holds no locals
    uint256 internal debtSum;
    uint256 internal unitsInLoans;
    uint256 internal fills;
    uint256 internal lowDrifts;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        LIQ_LOW = AceFixtures.px(1.4e18, address(usdc), address(coll));
        LIQ_HIGH = AceFixtures.px(1.6e18, address(usdc), address(coll));
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setObserved(AceFixtures.px(2e18, address(usdc), address(coll)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        // deep honest liquidity at 1.935, so every fill funds and the floor is not the variable here
        usdc.mint(lender, 10 * P);
        vm.startPrank(lender);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(mid, 10 * P);
        vm.stopPrank();

        coll.mint(maker, 1e30);
        vm.prank(maker);
        coll.approve(address(pm), type(uint256).max);
    }

    function _cfg() internal view returns (Cfg memory c) {
        c.p = ace.idToMarketParams(mid);
        c.unitScale = read.marketState(mid).unitScale;
    }

    /// @notice Up to six fills of fuzzed size and collateral against one order; the conservation laws hold after each.
    function testFuzz_OrderFills_ConserveEscrowAndStayInsideTheBand(uint256[6] memory pSeeds, uint256[6] memory uSeeds, uint256 minFillSeed) public {
        uint256 minFill = bound(minFillSeed, ace.idToMarketParams(mid).minDebt, P / 2);
        vm.prank(maker);
        uint256 orderId = ace.postOrder(mid, P, LIQ_LOW, LIQ_HIGH, minFill, TEN, 0);
        uint256 escrow0 = pm.collateralOf(orderId);
        uint256 loansBefore = read.loanCount();

        for (uint256 i; i < 6; i++) {
            if (!_tryFill(orderId, pSeeds[i], uSeeds[i])) break;
        }

        Order memory fin = ace.orderOf(orderId);
        assertEq(fin.collateralUnits + unitsInLoans, escrow0, "ESCROW: order remainder plus every spawned loan equals the post");
        assertEq(pm.collateralOf(orderId), fin.collateralUnits, "custody's order row mirrors the hub's remainder");
        assertEq(fin.principal + debtSum, P, "PRINCIPAL: remainder plus every spawned debt equals the post");
        assertEq(read.loanCount() - loansBefore, fills, "one loan per admitted fill, no phantom ids");
        if (lowDrifts > 0) emit log_named_uint("fills landing under liqLow (documented drift)", lowDrifts);

        // the maker closes and takes back exactly the remainder
        vm.prank(maker);
        uint256 back = ace.closeOrder(orderId, maker);
        assertEq(back, fin.collateralUnits, "close returns the remainder, whole");
        assertEq(pm.collateralOf(orderId), 0, "a closed order holds no custody");
    }

    /// @dev One fuzzed fill. Returns false when the order can take no further fill; a rail refusal is skipped, not fatal.
    function _tryFill(uint256 orderId, uint256 pSeed, uint256 uSeed) internal returns (bool) {
        Order memory o = ace.orderOf(orderId);
        if (o.principal < o.minFillPrincipal) return false;
        uint256 pOut = bound(pSeed, o.minFillPrincipal, o.principal);
        // the pro-rata take is the most the band admits; the fuzz ranges under it down to the band's high end
        uint256 maxU = (o.collateralUnits * pOut) / o.principal;
        uint256 minU = Borrower.requiredAt(_cfg(), pOut, LIQ_HIGH);
        if (minU > maxU) minU = maxU;
        uint256 uOut = bound(uSeed, minU, maxU);
        vm.prank(filler);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.fillOrder, (orderId, pOut, uOut)));
        if (!ok) return true; // a rail refused it; the fuzz measures what is ADMITTED
        _checkLoan(abi.decode(ret, (uint256)), pOut, uOut);
        return true;
    }

    /// @dev The per-loan laws on one admitted fill, and the running tallies.
    function _checkLoan(uint256 loanId, uint256 pOut, uint256 uOut) internal {
        fills++;
        Loan memory l = read.loan(loanId);
        debtSum += l.debt;
        unitsInLoans += l.collateralUnits;
        assertEq(l.borrower, maker, "every fill is titled to the maker");
        assertEq(l.debt, pOut, "the loan's debt is exactly the fill's principal");
        assertEq(l.collateralUnits, uOut, "the loan holds exactly the fill's units");
        uint256 trig = read.triggerPrice(loanId);
        assertLe(trig, LIQ_HIGH, "no admitted fill lands the maker above their worst trigger");
        if (trig < LIQ_LOW) lowDrifts++; // the LOW end is NOT held (Types.sol:214): a thin early fill enriches the remainder; measured ~12% under
        assertEq(pm.collateralOf(loanId), uOut, "custody credits the loan exactly what the order gave up");
    }
}
