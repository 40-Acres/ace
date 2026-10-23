// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP7PooledIdentityTest
/// @notice Audit run 2026-09-13-670568 phase 7, goal 2: try to make the books lie on the POOLED, sole-tenant model.
/// @notice Two lenders share one quote; one lender runs two markets, so her pool spans both; a stranger routes a loan between lenders.
/// @notice The invariant handler drives no routed roll, so this sequence is the first to hold the identity across one.
/// @dev After every step: hub quote == pools(resting + owed) + markets(revenue + quoteOwed) + loans(feeEscrow), and pool legs match markets.
contract AceP7PooledIdentityTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal h1; // alice's first market
    bytes32 internal h2; // alice's second market, same quote: her pool spans both
    bytes32 internal d; // mallory's market, the routing destination

    address internal alice = address(0xA11CE);
    address internal mallory = address(0xBAD);
    address internal b1 = address(0xB1);
    address internal b2 = address(0xB2);
    address internal stranger = address(0x5712);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(new MockPersistenceRecord(address(usdc), address(coll))); // one record for all three: arming needs one, routing an equal one
        AceFixtures.Deployment memory dep = AceFixtures.deploy(p);
        (ace, pm, read, h1) = (dep.ace, dep.positionManager, dep.read, dep.id);
        p.minCoverageWad = 1.5e18;
        h2 = ace.createMarket(p);
        p.minCoverageWad = ace.idToMarketParams(h1).minCoverageWad;
        p.lender = mallory;
        d = ace.createMarket(p);
        _rest(h1, alice, 1000e6);
        _rest(h2, alice, 500e6);
        _rest(d, mallory, 300e6);
    }

    function _rest(bytes32 m, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    function _open(bytes32 m, address who, uint256 units, uint256 principal) internal returns (uint256 id) {
        coll.mint(who, units);
        vm.startPrank(who);
        coll.approve(address(pm), units);
        id = ace.open(m, units, principal, 0, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _repay(address who, uint256 id, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.repay(id, amt);
        vm.stopPrank();
    }

    /// @dev The quote identity, the pool-to-market partition, `lent` against live claims, and custody against the pot.
    function _assertBooks(string memory step) internal view {
        (uint256 rA, uint256 lA, uint256 oA) = read.lenderPools(alice, address(usdc));
        (uint256 rM, uint256 lM, uint256 oM) = read.lenderPools(mallory, address(usdc));
        uint256 pots = rA + oA + rM + oM;
        bytes32[3] memory ms = [h1, h2, d];
        for (uint256 i; i < 3; i++) {
            pots += read.protocolRevenue(ms[i]) + read.quoteOwedTotal(ms[i]);
        }
        uint256 n = read.loanCount();
        uint256 claimsA;
        uint256 claimsM;
        uint256 ledger;
        for (uint256 id = 1; id <= n; id++) {
            pots += read.feeEscrowOf(id);
            claimsA += read.claimOf(h1, id) + read.claimOf(h2, id);
            claimsM += read.claimOf(d, id);
            ledger += pm.collateralOf(id) + pm.retiredOf(id);
        }
        assertEq(usdc.balanceOf(address(ace)), pots, string.concat(step, ": hub quote == every pot"));
        assertEq(read.restingOf(h1) + read.restingOf(h2), rA, string.concat(step, ": alice's resting == her two markets' cash"));
        assertEq(read.restingOf(d), rM, string.concat(step, ": mallory's resting == her market's cash"));
        assertEq(lA, claimsA, string.concat(step, ": alice's lent == her live claims"));
        assertEq(lM, claimsM, string.concat(step, ": mallory's lent == her live claims"));
        assertEq(pm.custodiedOf(address(coll)), ledger, string.concat(step, ": custody aggregate == per-id ledgers"));
        assertEq(coll.balanceOf(address(pm)), ledger, string.concat(step, ": the pot holds exactly the ledger"));
    }

    function test_TheBooksHoldAcrossPoolingRoutingSettlementAndEveryExit() public {
        _assertBooks("genesis");
        uint256 a = _open(h1, b1, 1000e18, 100e6);
        uint64 tenor = read.loan(a).tenor; // read before the prank: an argument's own call would consume it
        vm.prank(b1);
        ace.setAutoRefinance(a, tenor, 2000, 100);
        uint256 b = _open(h2, b2, 500e18, 50e6);
        _assertBooks("two opens across alice's two markets");
        _repay(b2, b, 20e6);
        _assertBooks("partial repay");

        uint64 w = MarketInit.autoRefinanceWindow(ace.idToMarketParams(h1).minTenor);
        _warpTo(uint256(read.loan(a).expiry) - w / 4);
        vm.prank(mallory);
        uint256 a2 = ace.refinanceByPolicyTo(a, d);
        assertEq(ace.loanMarket(a2), d, "fixture: the successor sits in the other lender's market");
        _assertBooks("routed roll between two lenders");

        uint256 owedA = ace.lenderOwed(alice, address(usdc));
        assertGt(owedA, 0, "fixture: alice has pooled credit a stranger might reach for");
        vm.prank(stranger);
        assertEq(ace.collect(address(usdc), stranger), 0, "a stranger's collect spends only their own, empty, pool");
        assertEq(ace.lenderOwed(alice, address(usdc)), owedA, "and alice's pool is untouched by it");
        _assertBooks("a stranger's collect reaches nobody else's pool");
        vm.prank(alice);
        ace.collect(address(usdc), alice);
        _assertBooks("alice collects her own pool home");

        _repay(b2, b, read.debtOf(b));
        vm.prank(b2);
        ace.claimOwed(b, b2);
        _assertBooks("full repay and claim");

        vm.prank(mallory);
        ace.withdraw(d, type(uint256).max, mallory, 0);
        _warpTo(read.loan(a2).expiry);
        vm.prank(stranger);
        ace.forceClose(a2);
        assertGt(read.invPotOf(d, a2), 0, "fixture: the starved successor settled into a pot");
        _assertBooks("starved successor settles, with the piggyback sweep");

        _warpTo(read.inventoryAskOpensAt(a2));
        usdc.mint(stranger, 70e6);
        vm.startPrank(stranger);
        usdc.approve(address(ace), 70e6);
        (uint256 bought, uint256 paid) = ace.buyInventory(a2, 70e6, 0, stranger);
        vm.stopPrank();
        assertGt(bought, 0, "fixture: the ask actually filled");
        assertGt(paid, 0, "fixture: and took quote for it");
        _assertBooks("inventory ask");

        vm.prank(b1);
        ace.claimOwed(a2, b1);
        vm.prank(b1);
        ace.claimOwed(a, b1);
        vm.startPrank(stranger);
        ace.claimOwed(a2, stranger);
        vm.stopPrank();
        vm.startPrank(mallory);
        ace.redeemInKind(a2, mallory);
        vm.stopPrank();
        vm.prank(mallory);
        ace.collect(address(usdc), mallory);
        vm.prank(alice);
        ace.collect(address(usdc), alice);
        _assertBooks("claims, in-kind exit and both collects");

        vm.startPrank(alice);
        ace.withdraw(h1, type(uint256).max, alice, 0);
        ace.withdraw(h2, type(uint256).max, alice, 0);
        vm.stopPrank();
        ace.sweepRevenue(h1);
        ace.sweepRevenue(h2);
        ace.sweepRevenue(d);
        _assertBooks("both lenders fully out, revenue swept");
    }
}
