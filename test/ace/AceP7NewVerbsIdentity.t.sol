// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, InventoryHeld} from "../../src/ace/hub/Ace.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, MarketState, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP7NewVerbsIdentity
/// @notice Phase-7 (attacker) probe: the solvency identity across TWO markets sharing one quote, driven only through
/// @notice the verbs that landed after the last attacker pass and that no invariant handler reaches:
/// @notice `postOrder` / `fillOrder` / `closeOrder`, `settleExpired`, the held inventory ask, and `claimOwed` by legs.
/// @dev The identity: `quote.balanceOf(ace) == Σ_markets (totalCash + protocolRevenue + unitOwed + quoteOwedTotal) + Σ_loans feeEscrow`.
/// @dev Checked after EVERY step, and the collateral pot identity beside it.
contract AceP7NewVerbsIdentityTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal collA;
    MockERC20 internal collB;
    MockPersistenceRecord internal recA;
    bytes32 internal midA;
    bytes32 internal midB; // record-less, same quote, other collateral: the sibling that must not be touched

    /// @dev ONE LENDER FOR BOTH MARKETS. It WAS two, one per market; the identity this file pins is that the
    /// @dev hub keeps ONE pool per (lender, quote) across their markets, which needs the lender to be the same.
    address internal lenderA = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);
    address internal buyer = address(0xB111);
    address internal keeper = address(0x4EE9);

    uint64 internal constant TEN = 7 days;
    uint256 internal constant P = 20_000e6;
    uint256[] internal loans;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        collA = new MockERC20("Collateral A", "CA", 18);
        collB = new MockERC20("Collateral B", "CB", 8);
        recA = new MockPersistenceRecord(address(usdc), address(collA));
        recA.setObserved(AceFixtures.px(2e18, address(usdc), address(collA)));
        recA.setMinPrice(AceFixtures.px(2e18, address(usdc), address(collA)));

        /// @dev BOTH MARKETS BID AT +6600, which is where `_lend` used to rest and the ORDER BAND still sits
        /// @dev above par to reach. The offset was a rung a deposit chose; it is a creation param now, so a
        /// @dev market left at par funds an order whose band is above it and the fill opens liquidatable.
        MarketParams memory pa = AceFixtures.marketParams(address(usdc), address(collA));
        pa.record = address(recA);
        pa.price = AceFixtures.priceAt(address(usdc), address(collA), 6600);
        AceFixtures.Deployment memory d = AceFixtures.deploy(pa);
        (ace, pm, read, midA) = (d.ace, d.positionManager, d.read, d.id);
        MarketParams memory pb = AceFixtures.marketParams(address(usdc), address(collB));
        pb.price = AceFixtures.priceAt(address(usdc), address(collB), 6600);
        midB = ace.createMarket(pb);

        _lend(lenderA, midA, address(collA), 6600, 5 * P);
        _lend(lenderA, midB, address(collB), 6600, 5 * P);
        collA.mint(maker, 1e30);
        collB.mint(maker, 1e30);
        vm.startPrank(maker);
        collA.approve(address(pm), type(uint256).max);
        collB.approve(address(pm), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(ace), type(uint256).max);
    }

    function _lend(address who, bytes32 mid, address coll, int24 offset, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev The quote identity over both markets and every loan opened so far, plus the collateral pots.
    /// @dev THE LENDER LEGS ARE READ ONCE, NOT PER MARKET, and that is load-bearing rather than a tidy-up:
    /// @dev both markets name one lender in one quote, so the hub keeps ONE pool for them and adding it
    /// @dev per market would claim the same money twice, breaking the identity on a solvent hub.
    function _identity(string memory at) internal view {
        (uint256 resting,, uint256 owed) = read.poolOf(midA); // midB shares this pool: same lender, same quote
        uint256 pots = resting + owed;
        bytes32[2] memory mids = [midA, midB];
        for (uint256 i; i < 2; i++) {
            MarketState memory s = read.marketState(mids[i]);
            pots += s.protocolRevenue + s.quoteOwedTotal;
        }
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            pots += read.feeEscrowOf(id);
        }
        assertEq(usdc.balanceOf(address(ace)), pots, string.concat(at, ": QUOTE IDENTITY broken across the two markets"));
        assertGe(collA.balanceOf(address(pm)), pm.custodiedOf(address(collA)), string.concat(at, ": collateral A pot under its ledger"));
        assertGe(collB.balanceOf(address(pm)), pm.custodiedOf(address(collB)), string.concat(at, ": collateral B pot under its ledger"));
    }

    function _snapshotB() internal view returns (MarketState memory) {
        return read.marketState(midB);
    }

    /// @dev `unitOwed` LEFT `MarketState` with the receipt ledger: the credit pools per (lender, quote), which
    /// @dev both markets share, so a sibling-untouched check cannot read it and is not asked to.
    function _assertBUntouched(MarketState memory before, string memory at) internal view {
        MarketState memory now_ = read.marketState(midB);
        assertEq(now_.cash, before.cash, string.concat(at, ": sibling cash moved"));
        assertEq(now_.protocolRevenue, before.protocolRevenue, string.concat(at, ": sibling protocolRevenue moved"));
        assertEq(now_.quoteOwedTotal, before.quoteOwedTotal, string.concat(at, ": sibling quoteOwedTotal moved"));
    }

    /// @notice Post, fill twice, settle unpaid, buy the held inventory, claim both legs, close: the identity holds throughout.
    function test_NewVerbs_HoldTheIdentityAcrossTwoMarketsSharingTheQuote() public {
        MarketState memory b0 = _snapshotB();
        _identity("genesis");
        uint256 lenderAHad = usdc.balanceOf(lenderA); // every close's push and the collect below land here

        // an order on A, two fills by a stranger, a remainder the maker closes
        uint256 liqLow = AceFixtures.px(1.4e18, address(usdc), address(collA));
        uint256 liqHigh = AceFixtures.px(1.5e18, address(usdc), address(collA));
        vm.prank(maker);
        uint256 orderId = ace.postOrder(midA, P, liqLow, liqHigh, P / 4, TEN, 0);
        _identity("post");
        Order memory o = ace.orderOf(orderId);
        vm.prank(filler);
        uint256 l1 = ace.fillOrder(orderId, P / 2, (o.collateralUnits * (P / 2)) / o.principal);
        _identity("fill 1");
        o = ace.orderOf(orderId);
        vm.prank(filler);
        uint256 l2 = ace.fillOrder(orderId, P / 4, (o.collateralUnits * (P / 4)) / o.principal);
        _identity("fill 2");
        vm.prank(maker);
        ace.closeOrder(orderId, maker);
        _identity("close order");
        _assertBUntouched(b0, "orders on A");

        // loan 1 repaid in full by the maker; loan 2 abandoned to the unpaid backstop
        vm.prank(maker);
        ace.repay(l1, type(uint256).max);
        _identity("repay l1");
        _warpTo(read.loan(l2).expiry + MarketInit.autoRefinanceWindow(TEN));
        vm.prank(keeper);
        ace.settleExpired(l2);
        _identity("settleExpired l2");
        assertEq(read.unitsOwedOf(l2, keeper), 0, "the unpaid door credits the keeper nothing");

        // the held ask: refused inside the hold, admitted after it, proceeds land in the class
        vm.prank(buyer);
        vm.expectRevert(InventoryHeld.selector);
        ace.buyInventory(l2, 1_000e6, 0, buyer);
        _warpTo(read.inventoryAskOpensAt(l2));
        vm.prank(buyer);
        (uint256 unitsOut, uint256 filled) = ace.buyInventory(l2, 1_000_000e6, 0, buyer);
        assertGt(unitsOut, 0, "the ask sold the pot");
        assertGt(filled, 0, "the buyer paid");
        _identity("buyInventory l2");

        /// @dev Lender A collects. WAS `claimMany(ids, ticks, to)`, one entry per (loan, funded tick), because a
        /// @dev payout was keyed by the class that earned it. The credit POOLS per (lender, quote) now, so one
        /// @dev `collect` takes every loan's contribution at once and there is no batch verb left to call.
        vm.prank(lenderA);
        uint256 paid = ace.collect(address(usdc), lenderA);
        assertEq(paid, filled, "the closes pushed fee and repayment, so the collect pays exactly the sale's proceeds");
        assertGt(usdc.balanceOf(lenderA) - lenderAHad, filled, "the lender was paid fee, repayment and sale proceeds");
        _identity("collect");
        vm.startPrank(maker);
        ace.claimOwed(l1, address(0), maker); // quote leg only: the unearned escrow refund
        ace.claimOwed(l2, maker, address(0)); // units leg only: the settlement residual
        ace.claimOwed(l1, maker); // the units leg of the repaid loan
        vm.stopPrank();
        _identity("claimOwed legs");
        _assertBUntouched(b0, "the whole sequence");
        assertEq(read.quoteOwedOf(l1, maker), 0, "nothing left owed on l1");
        assertEq(read.unitsOwedOf(l2, maker), 0, "nothing left owed on l2");
    }
}
