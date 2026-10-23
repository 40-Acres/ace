// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {Loan, MarketParams, MarketState, MigrateArgs, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP10OrderCustodyIdentity
/// @notice The three custody EQUALITIES (see `AceP10CustodyIdentity`) on the paths the invariant handler never drives:
/// @notice the credit-order escrow and its carry, the unpaid backstop, the held ask, in-kind redemption, and `claimOwed` by legs.
/// @dev Phase 7's identity test on these verbs checks the quote side and one custody INEQUALITY; this is the equality.
contract AceP10OrderCustodyIdentityTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal mid;
    bytes32 internal mid2; // the migration sibling: same pair, a different fee, created by the second walk alone

    address internal lender = address(0xA11CE);
    address internal maker = address(0x4A6E);
    address internal filler = address(0xF111);
    address internal buyer = address(0xB111);
    address internal keeper = address(0x4EE9);

    uint64 internal constant TEN = 7 days;
    uint256 internal constant P = 20_000e6;
    uint256 internal price; // the price the fixture markets bid at

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setObserved(AceFixtures.px(2e18, address(usdc), address(coll)));
        rec.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        price = AceFixtures.priceAt(address(usdc), address(coll), 6600);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        /// @dev THE MARKET BIDS AT `price`, which is where the rig used to rest and the order band still sits
        /// @dev above par to reach. Left at par the fill's collateral, derived from the band's LOW end, opens
        /// @dev under the funding floor and the whole walk stops on `TriggerAboveFloor`.
        p.price = price;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(lender, 5 * P);
        vm.startPrank(lender);
        usdc.approve(address(ace), 5 * P);
        ace.deposit(mid, 5 * P);
        vm.stopPrank();
        coll.mint(maker, 1e30);
        vm.startPrank(maker);
        coll.approve(address(pm), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(ace), type(uint256).max);
    }

    /// @dev Every address a close or a settlement can credit units to in this walk.
    function _owedUnits(uint256 id) internal view returns (uint256 s) {
        s = read.unitsOwedOf(id, maker) + read.unitsOwedOf(id, keeper) + read.unitsOwedOf(id, lender) + read.unitsOwedOf(id, buyer);
    }

    /// @dev WAS a sum over the loan's funded ticks; a loan holds one pot, so the sum is that one read.
    function _pots(uint256 id) internal view returns (uint256) {
        bytes32 m = read.loan(id).market; // the loan's OWN market: the second walk spans two
        return read.invPotOf(m, id);
    }

    /// @dev The three equalities over every id the hub has issued, loans AND orders.
    function _custody(string memory at) internal view {
        uint256 live;
        uint256 retired;
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            Loan memory l = read.loan(id);
            uint256 c = pm.collateralOf(id);
            uint256 r = pm.retiredOf(id);
            if (l.market == bytes32(0)) {
                Order memory o = ace.orderOf(id);
                assertEq(c, o.collateralUnits, string.concat(at, ": A(order): collateralOf != order escrow"));
                assertEq(r, 0, string.concat(at, ": an order retired units"));
            } else if (l.closedAt == 0) {
                assertEq(c, l.collateralUnits, string.concat(at, ": A(live): collateralOf != collateralUnits"));
            } else {
                assertEq(c, 0, string.concat(at, ": A(closed): live custody remains"));
                assertEq(r, _pots(id) + _owedUnits(id), string.concat(at, ": B: retiredOf != pots + credits"));
            }
            live += c;
            retired += r;
        }
        assertEq(pm.custodiedOf(address(coll)), live + retired, string.concat(at, ": C: custodiedOf != sum of ledgers"));
        assertGe(coll.balanceOf(address(pm)), pm.custodiedOf(address(coll)), string.concat(at, ": C: pot under ledger"));
    }

    /// @notice Post, two fills, close; repay one; settle the other unpaid; buy the held pot; redeem in kind; claim by legs.
    function test_CustodyEqualities_HoldOnTheOrderAndBackstopPaths() public {
        _custody("genesis");
        uint256 liqLow = AceFixtures.px(1.4e18, address(usdc), address(coll));
        uint256 liqHigh = AceFixtures.px(1.5e18, address(usdc), address(coll));
        vm.prank(maker);
        uint256 orderId = ace.postOrder(mid, P, liqLow, liqHigh, P / 4, TEN, 0);
        _custody("post");
        Order memory o = ace.orderOf(orderId);
        vm.prank(filler);
        uint256 l1 = ace.fillOrder(orderId, P / 2, (o.collateralUnits * (P / 2)) / o.principal);
        _custody("fill 1");
        o = ace.orderOf(orderId);
        vm.prank(filler);
        uint256 l2 = ace.fillOrder(orderId, P / 4, (o.collateralUnits * (P / 4)) / o.principal);
        _custody("fill 2");
        vm.prank(maker);
        ace.closeOrder(orderId, maker);
        _custody("close order");

        vm.prank(maker);
        ace.repay(l1, type(uint256).max);
        _custody("repay l1");
        _warpTo(read.loan(l2).expiry + MarketInit.autoRefinanceWindow(TEN));
        vm.prank(keeper);
        ace.settleExpired(l2);
        _custody("settleExpired l2");

        _warpTo(read.inventoryAskOpensAt(l2));
        vm.prank(buyer);
        (uint256 unitsOut,) = ace.buyInventory(l2, 5_000e6, 0, buyer);
        assertGt(unitsOut, 0, "the ask sold part of the pot");
        _custody("buyInventory l2");

        /// @dev WAS a HALF redemption against a receipt balance: the lender burned half of a per-tick unit
        /// @dev class. The receipt ledger is gone and so is the class, so a redemption takes the whole pot.
        vm.prank(lender);
        uint256 out = ace.redeemInKind(l2, lender);
        assertGt(out, 0, "the redemption delivered collateral");
        _custody("redeemInKind");

        vm.startPrank(maker);
        ace.claimOwed(l1, address(0), maker);
        _custody("claimOwed l1 quote leg");
        ace.claimOwed(l1, maker, address(0));
        _custody("claimOwed l1 units leg");
        ace.claimOwed(l2, maker);
        vm.stopPrank();
        _custody("claimOwed l2");
        assertEq(read.unitsOwedOf(l2, maker), 0, "nothing left owed on l2");
    }

    /// @notice FUZZED FILLS: any admissible first fill, then the LAST fill that empties the order, keep all three equalities.
    /// @dev The invariant campaign posts no orders, so this is the fill path's fuzzed custody check.
    /// @dev An unpaired carry on either fill breaks C: `the design record` rests on it.
    function testFuzz_CustodyEqualities_HoldAcrossAnyFillThenTheLast(uint256 firstBps) public {
        firstBps = bound(firstBps, 2500, 7500); // at least the P/4 minimum, and leaving at least P/4 for the last fill
        uint256 liqLow = AceFixtures.px(1.4e18, address(usdc), address(coll));
        uint256 liqHigh = AceFixtures.px(1.5e18, address(usdc), address(coll));
        vm.prank(maker);
        uint256 orderId = ace.postOrder(mid, P, liqLow, liqHigh, P / 4, TEN, 0);
        Order memory o = ace.orderOf(orderId);
        uint256 p1 = (P * firstBps) / 10_000;
        vm.prank(filler);
        ace.fillOrder(orderId, p1, (o.collateralUnits * p1) / o.principal);
        _custody("fuzz: first fill");
        o = ace.orderOf(orderId);
        vm.prank(filler);
        ace.fillOrder(orderId, o.principal, o.collateralUnits); // the LAST fill: the whole remainder
        _custody("fuzz: last fill");
        assertEq(ace.orderOf(orderId).collateralUnits, 0, "the last fill emptied the escrow");
    }

    /// @dev The quote identity beside the custody one, so the two sides are read at every step of the walk below.
    /// @dev THE LENDER LEGS ARE READ ONCE: both markets name one lender in one quote, so they share ONE
    /// @dev pool at the hub and adding it per market would claim the same money twice on a solvent hub.
    function _quote(string memory at) internal view {
        (uint256 resting,, uint256 owed) = read.poolOf(mid); // mid2 shares this pool: same lender, same quote
        MarketState memory s = read.marketState(mid);
        uint256 pots = resting + owed + s.protocolRevenue + s.quoteOwedTotal;
        s = read.marketState(mid2);
        pots += s.protocolRevenue + s.quoteOwedTotal;
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            pots += read.feeEscrowOf(id);
        }
        assertEq(usdc.balanceOf(address(ace)), pots, string.concat(at, ": QUOTE IDENTITY broken"));
    }

    /// @notice A migration that sheds collateral, then an ARMED expiry roll: the two paths the fuzz handler never drives.
    /// @dev The roll retires a sliver to the keeper and carries the rest into the successor; both identities hold throughout.
    function test_CustodyEqualities_HoldOnTheWithdrawLegAndTheArmedRoll() public {
        MarketParams memory p2 = AceFixtures.marketParams(address(usdc), address(coll));
        p2.record = address(rec);
        p2.price = price; // the sibling bids where the rig does, or the migration lands under its own floor
        p2.baseBps = 60; // forks the id: same pair, same quote, a sibling the migration may land in
        mid2 = ace.createMarket(p2);
        usdc.mint(lender, 5 * P);
        vm.startPrank(lender);
        usdc.approve(address(ace), 5 * P);
        ace.deposit(mid2, 5 * P);
        vm.stopPrank();

        uint256 units = 40_000e18;
        vm.prank(maker);
        uint256 l1 = ace.open(mid, units, P, 0, maker, OpenBounds(0, 0, 0));
        _custody("open");
        _quote("open");

        // the successor draws more than the debt, sheds a quarter of the collateral to the maker, in the sibling market
        usdc.mint(maker, P);
        vm.prank(maker);
        uint256 l2 = ace.refinanceTo(MigrateArgs(l1, mid2, P + 2_000e6, TEN, OpenBounds(0, 0, 0), units / 4, maker));
        _custody("refinanceTo with withdrawUnits");
        assertEq(read.loan(l2).collateralUnits, units - units / 4, "the successor shed a quarter");
        assertEq(coll.balanceOf(maker), 1e30 - units + units / 4, "and the maker holds it");

        // arm the successor, let it expire, and let a keeper roll it: sliver to the keeper, the rest carried into l3
        vm.prank(maker);
        ace.setAutoRefinance(l2, TEN, 0, 0);
        _warpTo(read.loan(l2).expiry);
        uint256 before = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(l2);
        assertEq(read.loanCount(), before + 1, "the armed loan ROLLED rather than settled");
        uint256 l3 = before + 1;
        assertGt(read.unitsOwedOf(l2, keeper), 0, "the roll credited the keeper a sliver off the retiring loan");
        assertEq(read.loan(l3).collateralUnits + read.unitsOwedOf(l2, keeper), units - units / 4, "sliver plus carry is the whole lot");
        _custody("armed roll");

        vm.prank(keeper);
        ace.claimOwed(l2, keeper);
        _custody("keeper claims the sliver");
        vm.prank(maker);
        ace.claimOwed(l1, maker); // pays zero quote now: the maker's own refinance paid its net out in the call
        vm.prank(maker);
        ace.claimOwed(l2, maker);
        _custody("maker claims the roll's net");
        _quote("end");
    }
}
