// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../src/ace/hub/Ace.sol";
import {ExitToCustodian, ExitToHub, ZeroWithdrawTo} from "../../src/ace/hub/libraries/Recipients.sol";
import {NoClaimLeg} from "../../src/ace/hub/Settlement.sol";
import {Loan, MarketParams, MarketState, MigrateArgs, OpenBounds, Order} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @notice Drives every exit that names a recipient, drawing it from zero, the hub, the custodian, a third party and the actor.
/// @notice The latch trips when a refused recipient LANDS; the suite's balance identities catch whatever a landing stranded.
/// @dev Every other campaign names only actors, so none of them ever reaches a refused recipient: this one exists for that gap.
contract AceRecipientRailsHandler is WarpClock {
    Ace public immutable ace;
    PositionManager public immutable pm;
    AceReader public immutable read;
    MockERC20 public immutable usdc;
    MockERC20 public immutable coll;
    MockPersistenceRecord public immutable record;
    bytes32 public immutable mid;

    address public constant LENDER = address(0xA11CE);
    address public constant BORROWER = address(0xB0B);
    address public constant BUYER = address(0xB1E4);
    address public constant MAKER = address(0x4A6E);
    address public constant PAYEE = address(0xCA401);
    uint256 public constant ORDER_P = 1_000e6;
    uint256 public constant MINFILL = 250e6;

    uint256[] public loanIds;
    uint256[] public orderIds;

    bool public refusedLanded; // a call naming a refused recipient returned successfully
    string public refusedLandedVerb;
    uint256 public namedRefusals; // refused recipients answered by their own named error
    uint256 public validLandings; // exits that paid a recipient the rule admits
    mapping(string => uint256) public named;

    constructor(Ace ace_, PositionManager pm_, AceReader read_, MockERC20 usdc_, MockERC20 coll_, MockPersistenceRecord record_, bytes32 mid_) {
        ace = ace_;
        pm = pm_;
        read = read_;
        usdc = usdc_;
        coll = coll_;
        record = record_;
        mid = mid_;
        coll_.mint(MAKER, 1e30);
        vm.prank(MAKER);
        coll_.approve(address(pm_), type(uint256).max);
    }

    /* ---- recipient draw and bookkeeping ---- */

    /// @dev Zero, the hub, the custodian, a third party, or the acting party itself.
    function _to(uint256 seed, address self) internal view returns (address) {
        uint256 k = seed % 5;
        if (k == 0) return address(0);
        if (k == 1) return address(ace);
        if (k == 2) return address(pm);
        if (k == 3) return PAYEE;
        return self;
    }

    function _refusal(address to) internal view returns (bytes4) {
        if (to == address(0)) return ZeroWithdrawTo.selector;
        if (to == address(ace)) return ExitToHub.selector;
        if (to == address(pm)) return ExitToCustodian.selector;
        return bytes4(0);
    }

    function _landed(string memory verb, bool refused) internal {
        if (refused) {
            refusedLanded = true;
            refusedLandedVerb = verb;
        } else {
            validLandings++;
        }
    }

    function _reverted(string memory verb, bytes4 want, bytes4 alt, bytes memory err) internal {
        if (err.length < 4 || want == bytes4(0)) return;
        bytes4 got = bytes4(err);
        if (got == want || (alt != bytes4(0) && got == alt)) {
            namedRefusals++;
            named[verb]++;
        }
    }

    function _loan(uint256 seed) internal view returns (uint256) {
        return loanIds.length == 0 ? type(uint256).max : loanIds[seed % loanIds.length];
    }

    function loanCount() external view returns (uint256) {
        return loanIds.length;
    }

    /* ---- state builders: no recipient ---- */

    function open(uint256 collSeed, uint256 drawSeed) public {
        uint256 units = bound(collSeed, 10_000e18, 100_000e18);
        uint256 draw = bound(drawSeed, 10e6, (units / 1e18) * 400_000); // at most 40% of the par value, the rails fixture's ratio
        coll.mint(BORROWER, units);
        vm.startPrank(BORROWER);
        coll.approve(address(pm), units);
        try ace.open(mid, units, draw, 0, BORROWER, OpenBounds(0, 0, 0)) returns (uint256 id) {
            loanIds.push(id);
        } catch {}
        vm.stopPrank();
    }

    function repay(uint256 loanSeed, uint256 amtSeed) external {
        uint256 id = _loan(loanSeed);
        if (id == type(uint256).max) return;
        Loan memory l = read.loan(id);
        if (l.closedAt != 0) return;
        uint256 amt = amtSeed % 2 == 0 ? type(uint256).max : bound(amtSeed, 1e6, l.debt);
        usdc.mint(l.borrower, l.debt);
        vm.startPrank(l.borrower);
        usdc.approve(address(ace), type(uint256).max);
        try ace.repay(id, amt) {} catch {}
        vm.stopPrank();
    }

    /// @dev Distress for one call: finalize title moves, and the record reads healthy again after.
    function settle(uint256 loanSeed) external {
        uint256 id = _loan(loanSeed);
        if (id == type(uint256).max || read.loan(id).closedAt != 0) return;
        record.setBelow(true);
        try ace.finalize(id) {} catch {}
        record.setBelow(false);
    }

    function postOrder() public {
        uint256 low = AceFixtures.px(0.5e18, address(usdc), address(coll));
        uint256 high = AceFixtures.px(0.6e18, address(usdc), address(coll));
        uint64 tenor = ace.idToMarketParams(mid).minTenor;
        vm.prank(MAKER);
        try ace.postOrder(mid, ORDER_P, low, high, MINFILL, tenor, 0) returns (uint256 id) {
            orderIds.push(id);
        } catch {}
    }

    /// @dev Half at the order's own ratio, or the whole principal against all but zero or one unit.
    function fillOrder(uint256 orderSeed, uint256 shapeSeed) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[orderSeed % orderIds.length];
        Order memory o = ace.orderOf(id);
        if (o.closed || o.principal == 0) return;
        uint256 principalOut = o.principal;
        uint256 unitsOut = o.collateralUnits - (shapeSeed % 2);
        if (shapeSeed % 3 == 0 && o.principal / 2 >= MINFILL) {
            principalOut = o.principal / 2;
            unitsOut = (o.collateralUnits * principalOut) / o.principal;
        }
        try ace.fillOrder(id, principalOut, unitsOut) returns (uint256 loanId) {
            loanIds.push(loanId);
        } catch {}
    }

    function warp(uint256 seed) external {
        _warpBy(bound(seed, 1 hours, 3 days));
    }

    /* ---- the exits, each with a drawn recipient ---- */

    function withdraw(uint256 amtSeed, uint256 toSeed) external {
        address to = _to(toSeed, LENDER);
        vm.prank(LENDER);
        try ace.withdraw(mid, bound(amtSeed, 1e6, 100_000e6), to, 0) {
            _landed("withdraw", _refusal(to) != bytes4(0));
        } catch (bytes memory err) {
            _reverted("withdraw", _refusal(to), bytes4(0), err);
        }
    }

    function collect(uint256 toSeed) external {
        address to = _to(toSeed, LENDER);
        vm.prank(LENDER);
        try ace.collect(address(usdc), to) {
            _landed("collect", _refusal(to) != bytes4(0));
        } catch (bytes memory err) {
            _reverted("collect", _refusal(to), bytes4(0), err);
        }
    }

    function withdrawCollateral(uint256 loanSeed, uint256 unitSeed, uint256 toSeed) external {
        uint256 id = _loan(loanSeed);
        if (id == type(uint256).max) return;
        Loan memory l = read.loan(id);
        address to = _to(toSeed, l.borrower);
        vm.prank(l.borrower);
        try ace.withdrawCollateral(id, bound(unitSeed, 1, l.collateralUnits / 10 + 1), to) {
            _landed("withdrawCollateral", _refusal(to) != bytes4(0));
        } catch (bytes memory err) {
            _reverted("withdrawCollateral", _refusal(to), bytes4(0), err);
        }
    }

    /// @dev The claimant is the borrower or, for a settlement's keeper sliver, this handler; zero here is `NoClaimLeg`.
    function claimOwed(uint256 loanSeed, uint256 whoSeed, uint256 toSeed) external {
        uint256 id = _loan(loanSeed);
        if (id == type(uint256).max) return;
        address who = whoSeed % 2 == 0 ? read.loan(id).borrower : address(this);
        address to = _to(toSeed, who);
        bytes4 want = to == address(0) ? NoClaimLeg.selector : _refusal(to);
        vm.prank(who);
        try ace.claimOwed(id, to) {
            _landed("claimOwed", want != bytes4(0));
        } catch (bytes memory err) {
            _reverted("claimOwed", want, bytes4(0), err);
        }
    }

    /// @dev Zero skips a leg here; two zeros are `NoClaimLeg`, and a named hub or custodian on either leg refuses.
    function claimSplit(uint256 loanSeed, uint256 uSeed, uint256 qSeed) external {
        uint256 id = _loan(loanSeed);
        if (id == type(uint256).max) return;
        address who = read.loan(id).borrower;
        address tu = _to(uSeed, who);
        address tq = _to(qSeed, who);
        bytes4 wu = tu == address(0) ? bytes4(0) : _refusal(tu);
        bytes4 wq = tq == address(0) ? bytes4(0) : _refusal(tq);
        if (tu == address(0) && tq == address(0)) wu = NoClaimLeg.selector;
        vm.prank(who);
        try ace.claimOwed(id, tu, tq) {
            _landed("claimSplit", wu != bytes4(0) || wq != bytes4(0));
        } catch (bytes memory err) {
            _reverted("claimSplit", wu != bytes4(0) ? wu : wq, wq, err);
        }
    }

    function redeemInKind(uint256 loanSeed, uint256 toSeed) external {
        uint256 id = _loan(loanSeed);
        if (id == type(uint256).max) return;
        address to = _to(toSeed, LENDER);
        vm.prank(LENDER);
        try ace.redeemInKind(id, to) {
            _landed("redeemInKind", _refusal(to) != bytes4(0));
        } catch (bytes memory err) {
            _reverted("redeemInKind", _refusal(to), bytes4(0), err);
        }
    }

    function buyInventory(uint256 loanSeed, uint256 spendSeed, uint256 toSeed) external {
        uint256 id = _loan(loanSeed);
        if (id == type(uint256).max) return;
        address to = _to(toSeed, BUYER);
        uint256 spend = bound(spendSeed, 0, 5_000e6);
        usdc.mint(BUYER, spend);
        vm.startPrank(BUYER);
        usdc.approve(address(ace), type(uint256).max);
        try ace.buyInventory(id, spend, 0, to) {
            _landed("buyInventory", _refusal(to) != bytes4(0));
        } catch (bytes memory err) {
            _reverted("buyInventory", _refusal(to), bytes4(0), err);
        }
        vm.stopPrank();
    }

    function closeOrder(uint256 orderSeed, uint256 toSeed) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[orderSeed % orderIds.length];
        address to = _to(toSeed, MAKER);
        vm.prank(MAKER);
        try ace.closeOrder(id, to) {
            _landed("closeOrder", _refusal(to) != bytes4(0));
        } catch (bytes memory err) {
            _reverted("closeOrder", _refusal(to), bytes4(0), err);
        }
    }

    /// @dev One seed in three sheds nothing; one in seven names no recipient either, which is the plain roll.
    function refinanceTo(uint256 loanSeed, uint256 unitSeed, uint256 toSeed) external {
        uint256 id = _loan(loanSeed);
        if (id == type(uint256).max) return;
        Loan memory l = read.loan(id);
        address to = unitSeed % 7 == 0 ? address(0) : _to(toSeed, l.borrower);
        uint256 units = unitSeed % 3 == 0 || unitSeed % 7 == 0 ? 0 : bound(unitSeed, 1, l.collateralUnits / 20 + 1);
        bytes4 want = units == 0 && to == address(0) ? bytes4(0) : _refusal(to);
        MigrateArgs memory m = MigrateArgs(id, mid, l.debt + l.debt / 10 + 10e6, ace.idToMarketParams(mid).minTenor, OpenBounds(0, 0, 0), units, to);
        vm.prank(l.borrower);
        try ace.refinanceTo(m) returns (uint256 n) {
            loanIds.push(n);
            _landed("refinanceTo", want != bytes4(0));
        } catch (bytes memory err) {
            _reverted("refinanceTo", want, bytes4(0), err);
        }
    }
}

/// @notice No exit ever pays a refused recipient, and nothing a landing could strand shows up in the hub, the custodian or at zero.
contract AceRecipientRailsInvariantTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal mid;
    AceRecipientRailsHandler internal handler;
    address internal constant LENDER = address(0xA11CE);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("Quote", "Q", 6);
        coll = new MockERC20("Collateral", "C", 18);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        record = new MockPersistenceRecord(address(usdc), address(coll));
        p.record = address(record);
        mid = ace.createMarket(p);
        usdc.mint(LENDER, 10_000_000e6);
        vm.startPrank(LENDER);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(mid, 10_000_000e6);
        vm.stopPrank();
        handler = new AceRecipientRailsHandler(ace, pm, read, usdc, coll, record, mid);
        handler.open(100_000e18, type(uint256).max); // every run starts with a live loan and a resting order
        handler.postOrder();
        require(handler.loanCount() == 1, "BASELINE: the seeded open did not land");
        bytes4[] memory sel = new bytes4[](15);
        sel[0] = AceRecipientRailsHandler.open.selector;
        sel[1] = AceRecipientRailsHandler.repay.selector;
        sel[2] = AceRecipientRailsHandler.settle.selector;
        sel[3] = AceRecipientRailsHandler.postOrder.selector;
        sel[4] = AceRecipientRailsHandler.fillOrder.selector;
        sel[5] = AceRecipientRailsHandler.warp.selector;
        sel[6] = AceRecipientRailsHandler.withdraw.selector;
        sel[7] = AceRecipientRailsHandler.collect.selector;
        sel[8] = AceRecipientRailsHandler.withdrawCollateral.selector;
        sel[9] = AceRecipientRailsHandler.claimOwed.selector;
        sel[10] = AceRecipientRailsHandler.claimSplit.selector;
        sel[11] = AceRecipientRailsHandler.redeemInKind.selector;
        sel[12] = AceRecipientRailsHandler.buyInventory.selector;
        sel[13] = AceRecipientRailsHandler.closeOrder.selector;
        sel[14] = AceRecipientRailsHandler.refinanceTo.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @dev The quote the books assign the hub: resting cash, revenue, borrower credits, fee escrows and the lender's pool.
    function _booked() internal view returns (uint256 booked) {
        MarketState memory s = read.marketState(mid);
        booked = s.cash + s.protocolRevenue + s.quoteOwedTotal;
        uint256[] memory ids = ace.marketLoans(mid, 0, ace.marketLoansLength(mid));
        for (uint256 i; i < ids.length; ++i) {
            booked += read.feeEscrowOf(ids[i]);
        }
        (,, uint256 owed) = read.lenderPools(LENDER, address(usdc));
        booked += owed;
    }

    /// @notice The strands a refused recipient would leave, then the rail itself, on one walk.
    /// @dev The balance identities run FIRST, so a red run names the strand a landing left rather than only the latch.
    function invariant_noExitPaysARefusedRecipient() public view {
        assertEq(coll.balanceOf(address(ace)), 0, "the hub holds collateral");
        assertEq(coll.balanceOf(address(pm)), pm.custodiedOf(address(coll)), "the custodian holds collateral no ledger assigns");
        assertEq(usdc.balanceOf(address(pm)), 0, "the custodian holds quote");
        assertEq(coll.balanceOf(address(0)), 0, "collateral was sent to zero");
        assertEq(usdc.balanceOf(address(0)), 0, "quote was sent to zero");
        assertEq(usdc.balanceOf(address(ace)), _booked(), "the hub holds quote its books do not assign");
        assertFalse(handler.refusedLanded(), string.concat("a refused recipient landed on ", handler.refusedLandedVerb()));
    }

    /// @notice Anti-vacuity, per run: the walk reached at least one rail and was refused there by name.
    function afterInvariant() public view {
        assertGt(handler.namedRefusals(), 0, "COVERAGE: no exit was ever handed a refused recipient");
    }

    /// @notice The handler's wiring, deterministically: each exit, handed a refused recipient, is refused by that name.
    /// @dev Without this the campaign could pass by never reaching a rail at all.
    function test_EveryHandlerExitReachesItsRail() public {
        uint256 id = handler.loanIds(0);
        handler.withdraw(SPEND_SEED, 1);
        handler.collect(2);
        handler.withdrawCollateral(0, 1, 0);
        handler.claimOwed(0, 0, 1);
        handler.claimSplit(0, 0, 2);
        handler.redeemInKind(0, 2);
        handler.buyInventory(0, 0, 1);
        handler.closeOrder(0, 0);
        handler.refinanceTo(0, 1, 2);
        string[9] memory verbs =
            ["withdraw", "collect", "withdrawCollateral", "claimOwed", "claimSplit", "redeemInKind", "buyInventory", "closeOrder", "refinanceTo"];
        for (uint256 i; i < verbs.length; ++i) {
            assertEq(handler.named(verbs[i]), 1, string.concat("refused by name once: ", verbs[i]));
        }
        assertFalse(handler.refusedLanded(), "and none landed");
        assertTrue(read.loan(id).closedAt == 0, "the seeded loan is still live");
    }

    uint256 internal constant SPEND_SEED = 5_000e6;
}
