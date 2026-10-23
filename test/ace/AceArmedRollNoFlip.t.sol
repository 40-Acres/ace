// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowMinDebt, BufferBelowMin, InsufficientCash, NoRecordPrice, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceArmedRollNoFlip
/// @notice NO THIRD PARTY CHANGES AN ARMED LOAN'S NEXT EXPIRY FOLD: the property #666 and #514 are built to.
/// @notice An armed loan RESERVES the fresh remainder its expiry roll draws, and every fresh draw sees cash less the reserve.
/// @notice A home roll recycles the retiring principal, so the roll needs only `P' - D` of fresh cash, about one fee.
/// @dev THE CHAIN RESIDUAL IS ACCEPTED AND PINNED KNOWN: the successor re-reserves from unreserved cash or is born disarmed.
/// @dev Every row that turns green also asserts whether the successor is armed, so the residual can never hide inside a pass.
/// @dev Reasoning: the design record.
abstract contract AceArmedRollNoFlipBase is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the sole lender of the victim market
    address internal borrower = address(0xB0B); // armed, set-and-forget
    address internal keeper = address(0xCAFE); // cranks honestly at expiry
    address internal griefer = address(0x6E1EF); // no units, no loan, not the lender
    address internal maker = address(0x3A4E); // posts an honest resting order the griefer fills at the wrong moment

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant UNITS = 100_000e18;
    uint256 internal constant SLACK = 5_000e6; // resting cash beyond the successor: a thin market, not an empty one

    function _record() internal virtual returns (address);

    function setUp() public virtual {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(alice));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    /// @dev The victim market's params; a second market differs only in its lender, so it is compatible for routing.
    function _params(address lender) internal virtual returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = id == bytes32(0) ? _record() : ace.idToMarketParams(id).record;
        p.lender = lender;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
    }

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev Alice rests the draw, the successor and slack; the borrower opens and arms a home-only roll.
    function _scenario() internal returns (uint256 loanId) {
        _deposit(id, alice, 2 * P + SLACK);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
    }

    /// @dev The fresh remainder an expiry roll of `debt` draws: the successor's floored principal less the debt it recycles.
    /// @dev Re-spelled from the fee algebra rather than read off the hub, so a row checks the hub and never echoes it.
    function _fresh(uint256 debt) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(id);
        uint256 pp = LoanMath.principalForOwed(debt, TEN7, p.baseBps, p.minTenor);
        if (pp < p.minDebt) pp = p.minDebt;
        return pp > debt ? pp - debt : 0;
    }

    /// @dev The griefer's collateral and quote for one open of `amount`, approved on both doors.
    function _armGriefer(uint256 amount) internal returns (uint256 units) {
        units = amount * 2e12; // two whole COLL per whole USDC at par: twice the market's coverage
        coll.mint(griefer, units);
        usdc.mint(griefer, amount);
        vm.startPrank(griefer);
        coll.approve(address(pm), units);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Runs the griefer's batch and reports whether it LANDED; a refusal is an outcome here, never a failure.
    function _griefBatch(bytes[] memory calls) internal returns (bool landed) {
        vm.prank(griefer);
        try ace.multicall(calls) returns (bytes[] memory) {
            landed = true;
        } catch {
            landed = false;
        }
    }

    /// @dev The persistent lever: open `amount`, repay it, pull the refund back. Nothing about it needs atomicity.
    function _tryDrain(uint256 amount) internal returns (bool) {
        uint256 units = _armGriefer(amount);
        uint256 griefLoan = read.loanCount() + 1;
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Ace.open, (id, units, amount, TEN7, griefer, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.repay, (griefLoan, amount));
        calls[2] = abi.encodeWithSignature("claimOwed(uint256,address)", griefLoan, griefer);
        return _griefBatch(calls);
    }

    /// @dev The lender takes the victim market down to exactly `keep` of resting cash: her own consent, always open.
    function _withdrawTo(uint256 keep) internal {
        uint256 out = ace.restingOf(id) - keep;
        vm.prank(alice);
        ace.withdraw(id, out, alice, 0);
        assertEq(ace.restingOf(id), keep, "fixture: the market rests exactly what the row asks");
    }

    /// @dev The honest keeper's crank at expiry, only if nobody has ended the loan already.
    function _crankAtExpiry(uint256 loanId) internal {
        _warpAtLeastTo(read.loan(loanId).expiry);
        if (ace.isClosed(loanId)) return;
        vm.prank(keeper);
        ace.forceClose(loanId);
    }

    /// @dev The borrower's live successor to `loanId` in `mid`, or zero when the fold settled instead.
    function _successorOf(uint256 loanId, address who, bytes32 mid) internal view returns (uint256) {
        uint256 n = read.loanCount();
        for (uint256 i = loanId + 1; i <= n; i++) {
            if (read.loan(i).borrower == who && read.loan(i).market == mid && read.loan(i).closedAt == 0) return i;
        }
        return 0;
    }

    function _armed(uint256 loanId) internal view returns (bool) {
        (uint64 tenor,,) = read.autoPolicyOf(loanId);
        return tenor != 0;
    }

    /// @dev The two facts every green row closes on: the fold ROLLED, and whether the successor is armed.
    function _assertRolled(uint256 loanId, bool armedAfter, string memory why) internal view returns (uint256 newId) {
        assertEq(read.invPotOf(id, loanId), 0, string.concat(why, ": the fold rolled; the lender's pot took nothing"));
        newId = _successorOf(loanId, borrower, id);
        assertTrue(newId != 0, string.concat(why, ": the borrower holds a live successor"));
        assertEq(_armed(newId), armedAfter, string.concat(why, ": the successor's armed state"));
    }

    /* ================================================================= */
    /*  the ATOMIC form: drain, crank and unwind inside one call          */
    /* ================================================================= */

    /// @notice RED: the gross drain that used to settle a funded armed loan inside the griefer's own call now leaves it rolling.
    /// @dev `cash - P' + 1` starved the GROSS successor; under recycling the roll needs only `P' - D`, which the drain cannot reach.
    function test_RED_Atomic_TheGrossDrainNoLongerSettlesTheArmedLoan() public {
        uint256 loanId = _scenario();
        _warpTo(read.loan(loanId).expiry);
        (bool ok0,, uint256 p0) = ace.tryContinue(loanId);
        assertTrue(ok0, "PREMISE: at expiry the roll is admissible and funded");
        uint256 amount = ace.restingOf(id) - p0 + 1;
        uint256 units = _armGriefer(amount);
        uint256 griefLoan = read.loanCount() + 1;
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(Ace.open, (id, units, amount, TEN7, griefer, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.forceClose, (loanId));
        calls[2] = abi.encodeCall(Ace.repay, (griefLoan, amount));
        calls[3] = abi.encodeWithSignature("claimOwed(uint256,address)", griefLoan, griefer);
        _griefBatch(calls);
        _crankAtExpiry(loanId);
        _assertRolled(loanId, true, "gross atomic drain");
    }

    /// @notice RED: no stranger draw may reach into a reservation; one atom past the unreserved cash is refused.
    function test_RED_Atomic_AStrangerCannotDrawIntoTheReservation() public {
        uint256 loanId = _scenario();
        _warpTo(read.loan(loanId).expiry);
        uint256 r = _fresh(read.debtOf(loanId));
        uint256 amount = ace.restingOf(id) - r + 1;
        uint256 units = _armGriefer(amount);
        vm.prank(griefer);
        vm.expectRevert(InsufficientCash.selector);
        ace.open(id, units, amount, TEN7, griefer, OpenBounds(0, 0, 0));
        _crankAtExpiry(loanId);
        _assertRolled(loanId, true, "reservation untouched");
    }

    /// @notice RED, THEN PINNED KNOWN: the cheapest drain that forces the SUCCESSOR disarmed still leaves this fold rolling.
    /// @notice The property is the NEXT fold; the successor re-reserves from unreserved cash, and a stranger can take that first.
    /// @dev It costs the stranger the fee on `unreserved - r_new + 1`, or NOTHING when a fitting order stands to fill instead.
    /// @dev The successor carries a whole tenor of notice either way.
    function test_RED_Atomic_TheDisarmForcingDrainRollsTheLoanAndDisarmsTheSuccessor_KNOWN() public {
        uint256 loanId = _scenario();
        _warpTo(read.loan(loanId).expiry);
        (bool ok0,, uint256 p0) = ace.tryContinue(loanId);
        assertTrue(ok0, "PREMISE: at expiry the roll is admissible and funded");
        uint256 r = _fresh(read.debtOf(loanId));
        uint256 rNew = _fresh(p0);
        uint256 amount = ace.restingOf(id) - r - rNew + 1;
        uint256 units = _armGriefer(amount);
        uint256 griefLoan = read.loanCount() + 1;
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(Ace.open, (id, units, amount, TEN7, griefer, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.forceClose, (loanId));
        calls[2] = abi.encodeCall(Ace.repay, (griefLoan, amount));
        calls[3] = abi.encodeWithSignature("claimOwed(uint256,address)", griefLoan, griefer);
        assertTrue(_griefBatch(calls), "the disarm-forcing drain is a legal draw of unreserved cash");
        _crankAtExpiry(loanId);
        _assertRolled(loanId, false, "disarm-forcing drain, KNOWN");
    }

    /* ================================================================= */
    /*  the FILL-ORDER form: a permissionless fill of somebody's order    */
    /* ================================================================= */

    /// @dev An honest maker's all-or-nothing order for `amount`, triggered at half the market's price.
    function _postOrder(uint256 amount) internal returns (uint256 orderId, uint256 units) {
        uint256 liq = ace.idToMarketParams(id).price / 2;
        coll.mint(maker, amount * 4e12);
        vm.startPrank(maker);
        coll.approve(address(pm), amount * 4e12);
        orderId = ace.postOrder(id, amount, liq, liq, amount, TEN7, 0);
        vm.stopPrank();
        units = ace.orderOf(orderId).collateralUnits;
    }

    /// @notice RED: a stranger filling a resting order one hour before expiry no longer settles the armed loan.
    function test_RED_FillOrder_TheGrossFillNoLongerSettlesTheArmedLoan() public {
        uint256 loanId = _scenario();
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);
        (bool ok0,, uint256 p0) = ace.tryContinue(loanId);
        assertTrue(ok0, "PREMISE: the roll is admissible and funded");
        (uint256 orderId, uint256 units) = _postOrder(ace.restingOf(id) - p0 + 1);
        uint256 amount = ace.orderOf(orderId).principal;
        vm.prank(griefer);
        try ace.fillOrder(orderId, amount, units) {} catch {}
        _crankAtExpiry(loanId);
        _assertRolled(loanId, true, "gross fill");
    }

    /// @notice RED: a fill that would reach into the reservation is refused, so the order cannot be the lever either.
    function test_RED_FillOrder_AFillCannotReachTheReservation() public {
        uint256 loanId = _scenario();
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);
        uint256 r = _fresh(read.debtOf(loanId));
        (uint256 orderId, uint256 units) = _postOrder(ace.restingOf(id) - r + 1);
        uint256 amount = ace.orderOf(orderId).principal;
        vm.prank(griefer);
        vm.expectRevert(InsufficientCash.selector);
        ace.fillOrder(orderId, amount, units);
        _crankAtExpiry(loanId);
        _assertRolled(loanId, true, "reserved against a fill");
    }

    /* ================================================================= */
    /*  the ROUTE-IN form: a keeper rolls ANOTHER market's loan into ours */
    /* ================================================================= */

    /// @notice RED: routing another market's armed loan in cannot take the cash this market's armed loan reserved.
    /// @dev The route-in draws its WHOLE principal here, since nothing it retires rests here to recycle.
    function test_RED_RouteIn_ARoutedRollCannotTakeTheReservedCash() public {
        address bob = address(0xB0BB);
        address borrower2 = address(0xB0B2);
        bytes32 src = ace.createMarket(_params(bob));
        _deposit(id, alice, 4 * P);
        _deposit(src, bob, 3 * P);
        uint256 victim = _openArmed(id, borrower, P, UNITS, 0, 0);
        uint256 routed = _openArmed(src, borrower2, 2 * P, 4 * UNITS, 500, 200);

        _warpTo(uint256(read.loan(routed).expiry) - uint256(MarketInit.autoRefinanceWindow(TEN7)) / 2);
        (bool okIn,, uint256 pIn) = ace.tryContinueTo(routed, id);
        assertTrue(okIn, "PREMISE: with the market flush, the route-in is admissible");
        uint256 r = _fresh(read.debtOf(victim));
        uint256 keep = pIn + r - 1; // one atom short of the route-in plus the victim's reservation
        _withdrawTo(keep);

        vm.prank(keeper);
        try ace.refinanceByPolicyTo(routed, id) {} catch {}
        _crankAtExpiry(victim);
        _assertRolled(victim, true, "route-in");
    }

    function _openArmed(bytes32 mid, address who, uint256 principal, uint256 units, uint16 buf, uint16 feeCap) internal returns (uint256 loanId) {
        coll.mint(who, units);
        vm.startPrank(who);
        coll.approve(address(pm), units);
        loanId = ace.open(mid, units, principal, TEN7, who, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, buf, feeCap);
        vm.stopPrank();
    }

    /* ================================================================= */
    /*  the ±1-atom boundary: the fold and the draw read one cash test    */
    /* ================================================================= */

    /// @notice RED: resting cash of exactly the fresh remainder rolls, and the successor is born disarmed (nothing left to reserve).
    /// @dev The lender's own withdraw is consent, so it may take the market to any level; this pins where the roll still funds.
    function test_RED_Boundary_CashExactlyTheFreshRemainderRolls() public {
        uint256 loanId = _scenario();
        _warpTo(read.loan(loanId).expiry);
        uint256 r = _fresh(read.debtOf(loanId));
        _withdrawTo(r);
        (bool ok,, uint256 p) = ace.tryContinue(loanId);
        assertTrue(ok, "the view admits the roll at exactly the fresh remainder");
        assertEq(p - read.debtOf(loanId), r, "and the fresh remainder is the reservation, to the atom");
        _crankAtExpiry(loanId);
        _assertRolled(loanId, false, "boundary");
        assertEq(ace.restingOf(id), 0, "the roll spent the fresh remainder exactly");
    }

    /// @notice CONTROL: one atom less settles through the fold, and the view and the verb agree on why, with no revert.
    function test_Boundary_OneAtomLessSettlesWithoutReverting() public {
        uint256 loanId = _scenario();
        _warpTo(read.loan(loanId).expiry);
        uint256 r = _fresh(read.debtOf(loanId));
        _withdrawTo(r - 1);
        (bool ok, bytes4 why,) = ace.tryContinue(loanId);
        assertFalse(ok, "one atom short, the view refuses");
        assertEq(why, InsufficientCash.selector, "on the cash leg");
        vm.prank(keeper);
        vm.expectRevert(InsufficientCash.selector);
        ace.refinanceByPolicy(loanId);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the fold settled rather than reverting");
        assertEq(_successorOf(loanId, borrower, id), 0, "and wrote no successor");
    }
}

// The recordless instance is deleted: a recordless market cannot arm (`ArmNeedsRecord`), so it has no armed roll to flip.

/// @notice The record-backed class: the record sits 10% over the market's price, so every draw is under the cap.
contract AceArmedRollNoFlipRecordBackedTest is AceArmedRollNoFlipBase {
    function _record() internal override returns (address) {
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        return address(rec);
    }
}

/// @title AceRepayFloorTest
/// @notice A THIRD PARTY MAY PAY A LOAN OFF, NEVER DOWN INTO `(0, minDebt)`; the borrower may, and forfeits the guarantee.
/// @dev Under `minDebt` the successor floors AT `minDebt`, so the fresh need rises as the debt falls: the net leg is non-monotone.
contract AceRepayFloorTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;
    uint256 internal loanId;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal stranger = address(0x57A1);
    uint256 internal constant P = 1_000e6;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        usdc.mint(alice, 10 * P);
        vm.startPrank(alice);
        usdc.approve(address(ace), 10 * P);
        ace.deposit(id, 10 * P);
        vm.stopPrank();
        coll.mint(borrower, 10 * P * 1e12);
        vm.startPrank(borrower);
        coll.approve(address(pm), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, 10 * P * 1e12, P, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        usdc.mint(stranger, 10 * P);
        usdc.mint(borrower, 10 * P);
        vm.prank(stranger);
        usdc.approve(address(ace), type(uint256).max);
    }

    function _minDebt() internal view returns (uint256) {
        return ace.idToMarketParams(id).minDebt;
    }

    /// @notice RED: a stranger's partial repay that would leave a live loan under `minDebt` is refused by name.
    function test_RED_AStrangerMayNotRepayALoanIntoTheDustBand() public {
        uint256 amount = read.debtOf(loanId) - _minDebt() + 1;
        vm.prank(stranger);
        vm.expectRevert(BelowMinDebt.selector);
        ace.repay(loanId, amount);
    }

    /// @notice CONTROL: the borrower's own repay into the band stands; it is theirs to forfeit the guarantee.
    function test_TheBorrowerMayRepayIntoTheDustBand() public {
        uint256 amount = read.debtOf(loanId) - _minDebt() + 1;
        vm.prank(borrower);
        ace.repay(loanId, amount);
        assertEq(read.debtOf(loanId), _minDebt() - 1, "the borrower left their own loan under the floor");
    }

    /// @notice CONTROL: a stranger may still leave exactly `minDebt`, the band's closed lower edge.
    function test_AStrangerMayLeaveExactlyMinDebt() public {
        uint256 amount = read.debtOf(loanId) - _minDebt();
        vm.prank(stranger);
        ace.repay(loanId, amount);
        assertEq(read.debtOf(loanId), _minDebt(), "the floor itself is outside the band");
    }

    /// @notice CONTROL: a stranger may always pay a loan off in full; zero is outside the band.
    function test_AStrangerMayRepayInFull() public {
        vm.prank(stranger);
        ace.repay(loanId, type(uint256).max);
        assertTrue(ace.isClosed(loanId), "a full repay by anyone closes the loan");
    }
}

/// @title AceHomeRollRecordLegTest
/// @notice THE HOME ROLL'S RECORD LEG IS R-g: admissibility at `min(price, record)`, never the lender's stale bid.
/// @notice A dark record still refuses, and so does a record under the successor's trigger or inside its buffer.
/// @dev A ROUTED roll keeps the draw cap: a keeper-chosen venue still may not fund above the record.
contract AceHomeRollRecordLegTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;
    bytes32 internal rival;

    address internal alice = address(0xA11CE);
    address internal rivalLender = address(0xF1A5C0);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18; // trigger at 0.7 of the price: a 30% cushion at the draw
    uint16 internal constant BUF = 1000; // the borrower's 10% risk-distance pre-commit

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(_px(1.1e18));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(alice));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        rival = ace.createMarket(_params(rivalLender));
        _deposit(id, alice, 2 * P);
        _deposit(rival, rivalLender, 2 * P);
    }

    function _px(uint256 human) internal view returns (uint256) {
        return AceFixtures.px(human, address(usdc), address(coll));
    }

    function _params(address lender) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = lender;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
    }

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _openArmed(uint16 feeCap) internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, BUF, feeCap);
        vm.stopPrank();
    }

    /// @dev The fold at expiry; returns the successor, or zero when it settled.
    function _fold(uint256 loanId) internal returns (uint256) {
        _warpTo(read.loan(loanId).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        return read.loanCount() == n + 1 ? n + 1 : 0;
    }

    /// @notice RED: a record between the successor's trigger and the lender's price, outside the buffer, ROLLS.
    /// @dev Collateral still covers `k` times the successor's debt at the record, so settling would convert at a stale bid.
    function test_RED_ARecordUnderThePriceButClearOfTheBufferRolls() public {
        uint256 loanId = _openArmed(0);
        rec.setMinPrice(_px(0.9e18));
        _warpTo(read.loan(loanId).expiry);
        (bool ok, bytes4 why,) = ace.tryContinue(loanId);
        assertTrue(ok, "the view admits the home roll under a record below the price");
        assertEq(why, bytes4(0), "with no refusal");
        uint256 newId = _fold(loanId);
        assertTrue(newId != 0, "the fold rolled rather than settle at the lender's stale bid");
        assertEq(read.invPotOf(id, loanId), 0, "and the lender's pot took nothing");
        (uint64 tenor,,) = read.autoPolicyOf(newId);
        assertEq(tenor, TEN7, "the successor is armed: the market still holds the cash to back its roll");
    }

    /// @notice RED: the same record inside the borrower's buffer refuses by the BUFFER, which is the borrower's own number.
    function test_RED_ARecordInsideTheBufferRefusesBufferBelowMin() public {
        uint256 loanId = _openArmed(0);
        rec.setMinPrice(_px(0.75e18));
        _warpTo(read.loan(loanId).expiry);
        (bool ok, bytes4 why,) = ace.tryContinue(loanId);
        assertFalse(ok, "inside the buffer the home roll is refused");
        assertEq(why, BufferBelowMin.selector, "by the borrower's own risk distance, measured against the record");
        assertEq(_fold(loanId), 0, "and the fold settles");
    }

    /// @notice RED: a record under the successor's own trigger refuses as a trigger above its floor, and the fold settles.
    function test_RED_ARecordUnderTheSuccessorsTriggerSettles() public {
        uint256 loanId = _openArmed(0);
        rec.setMinPrice(_px(0.6e18));
        _warpTo(read.loan(loanId).expiry);
        (bool ok, bytes4 why,) = ace.tryContinue(loanId);
        assertFalse(ok, "a successor born in distress is refused");
        assertEq(why, TriggerAboveFloor.selector, "because its trigger clears the record");
        assertEq(_fold(loanId), 0, "and the fold settles");
    }

    /// @notice CONTROL: a dark record still refuses the roll, and the fold settles.
    function test_ADarkRecordStillSettles() public {
        uint256 loanId = _openArmed(0);
        rec.setMinPrice(0);
        _warpTo(read.loan(loanId).expiry);
        (bool ok, bytes4 why,) = ace.tryContinue(loanId);
        assertFalse(ok, "darkness refuses the roll");
        assertEq(why, NoRecordPrice.selector, "by name");
        assertEq(_fold(loanId), 0, "and the fold settles");
    }

    /// @notice CONTROL: a ROUTED roll keeps the draw cap, so a keeper's venue still may not fund above the record.
    function test_ARoutedRollKeepsTheDrawCap() public {
        uint256 loanId = _openArmed(200);
        rec.setMinPrice(_px(0.9e18));
        _warpTo(uint256(read.loan(loanId).expiry) - uint256(MarketInit.autoRefinanceWindow(TEN7)) / 2);
        (bool ok, bytes4 why,) = ace.tryContinueTo(loanId, rival);
        assertFalse(ok, "a routed roll under a record below the price is refused");
        assertEq(why, InsufficientCash.selector, "by the draw cap, exactly as a fresh draw is");
    }
}

/// @title AceHomeRecycleTest
/// @notice A SAME-MARKET REFINANCE NEEDS ONLY THE FRESH REMAINDER: the retiring principal re-rests inside the call.
contract AceHomeRecycleTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    uint256 internal constant P = 10_000e6;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = 7 days;
        p.maxTenor = 28 days;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        usdc.mint(alice, P);
        vm.startPrank(alice);
        usdc.approve(address(ace), P);
        ace.deposit(id, P);
        vm.stopPrank();
    }

    /// @notice RED: with NO resting cash, a same-market refinance drawing no more than the old debt succeeds.
    /// @dev The long term's escrow refund covers the short term's fee, so `P' == D` clears `DrawBelowDebt` on its own.
    function test_RED_ARefinanceAtOrUnderTheOldDebtNeedsNoRestingCash() public {
        coll.mint(borrower, 2 * P * 1e12);
        vm.startPrank(borrower);
        coll.approve(address(pm), type(uint256).max);
        uint256 loanId = ace.open(id, 2 * P * 1e12, P, 28 days, borrower, OpenBounds(0, 0, 0));
        assertEq(ace.restingOf(id), 0, "PREMISE: the market is fully lent");
        uint256 newId = ace.refinance(loanId, P, 7 days, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(read.debtOf(newId), P, "the successor carries the old debt");
        assertEq(ace.restingOf(id), 0, "and drew nothing fresh: the retiring principal paid for it");
        assertEq(read.claimOf(id, newId), P, "the successor's claim is its whole principal");
    }
}
