// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceReserveShrink
/// @notice Run 251533 Y-10: an armed loan's share SHRINKS to its roll's need when its debt falls, by repay or by a deleverage melt.
/// @notice Floored at the dust band's worst need, `minDebt - 1`, so a later dust repay is covered whatever order the repays came in.
/// @notice A shrink only: the share never grows, so a repay into the dust band can still outgrow it (the KNOWN residual).
/// @dev At the SHIPPED `minDebt`, 5,000 USDC; expected needs are re-derived from the fee algebra, never read off the hub.
/// @dev A 30-day share exceeds the floor only above ~260,000 of debt, so the rows that watch a shrink fire use a 300,000 loan.
contract AceReserveShrinkTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal borrower2 = address(0xB0B2);
    address internal stranger = address(0x57A2);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint256 internal constant MIN_DEBT = 5_000e6;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant BIG = 6 * P; // a loan whose 30-day roll needs more than `minDebt - 1`, so a shrink can fire
    uint256 internal constant UNITS = 100_000e18;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        _deposit(id, 4 * P);
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
        p.minCoverageWad = 1.4e18;
        p.minDebt = MIN_DEBT;
    }

    function _deposit(bytes32 m, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    function _openArmed(bytes32 m, address who, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        usdc.mint(who, principal);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(m, UNITS, principal, TEN7, who, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN30, 0, 0);
        vm.stopPrank();
    }

    /// @dev An armed `BIG` loan: its 30-day roll needs ~5,766, over the dust band's worst need.
    function _openBig(bytes32 m, address who) internal returns (uint256 loanId) {
        coll.mint(who, 6 * UNITS);
        vm.startPrank(who);
        coll.approve(address(pm), 6 * UNITS);
        loanId = ace.open(m, 6 * UNITS, BIG, TEN7, who, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN30, 0, 0);
        vm.stopPrank();
    }

    /// @dev The floor a shrink keeps: the dust band's worst need, the need at one atom of debt, `minDebt - 1`.
    function _floor(bytes32 m) internal view returns (uint256) {
        return _need(m, 1, TEN30);
    }

    function _repay(address who, uint256 loanId, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
        vm.stopPrank();
    }

    /// @dev What an expiry roll of `debt` at `tenor` draws fresh: `max(principalForOwed(debt), minDebt) - debt`.
    function _need(bytes32 m, uint256 debt, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(m);
        uint256 succ = LoanMath.principalForOwed(debt, tenor, p.baseBps, p.minTenor);
        if (succ < p.minDebt) succ = p.minDebt;
        return succ > debt ? succ - debt : 0;
    }

    /// @notice A borrower's partial repay shrinks the share to the roll's need at the new debt, and the reserve with it.
    /// @dev On a `BIG` loan, so the need at 280,000 still sits over the dust band's worst need and the shrink lands on it exactly.
    function test_APartialRepayShrinksTheShareToItsRollsNewNeed() public {
        _deposit(id, 3 * P);
        uint256 loanId = _openBig(id, borrower);
        uint256 armed = read.reservedOf(loanId);
        assertEq(armed, _need(id, BIG, TEN30), "PREMISE: arming reserved the need of the armed debt");
        _repay(borrower, loanId, 20_000e6);
        uint256 want = _need(id, BIG - 20_000e6, TEN30);
        assertLt(want, armed, "PREMISE: a smaller debt needs less");
        assertGt(want, _floor(id), "PREMISE: and still more than the dust band's worst need");
        assertEq(read.reservedOf(loanId), want, "the share is the roll's need at the new debt");
        assertEq(read.rollReserve(id), want, "and the market's reserve fell by exactly the difference");
    }

    /// @notice A stranger's partial repay, which must leave at least `minDebt`, shrinks the share too, down to the floor.
    function test_AStrangersPartialRepayShrinksTheShareToo() public {
        _deposit(id, 3 * P);
        uint256 loanId = _openBig(id, borrower);
        _repay(stranger, loanId, BIG - MIN_DEBT);
        assertLt(_need(id, MIN_DEBT, TEN30), _floor(id), "PREMISE: at minDebt the roll's need is under the floor");
        assertEq(read.reservedOf(loanId), _floor(id), "the share follows the debt the stranger left, floored at minDebt - 1");
        assertEq(read.rollReserve(id), _floor(id), "and the market holds exactly that");
    }

    /// @notice A repay to one atom shrinks the share to the floor's remainder, `minDebt - 1`: what repay-then-arm reserves.
    /// @dev ACCEPTED: a loan withdrawn to its line keeps that share, so it costs a griefer about one `minDebt` loan's fee.
    function test_ARepayIntoTheDustBandShrinksToTheFloorsRemainder() public {
        _deposit(id, 3 * P); // cash for the draw and the roll's reservation beside it
        uint256 loanId = _openBig(id, borrower);
        assertEq(_floor(id), MIN_DEBT - 1, "PREMISE: the fee algebra's floor is the dust band's worst need, minDebt - 1");
        assertGt(read.reservedOf(loanId), _floor(id), "PREMISE: the arm reserved more than the floor's remainder");
        _repay(borrower, loanId, BIG - 1);
        assertEq(read.reservedOf(loanId), _floor(id), "a one-atom loan holds what its floored successor draws fresh");
        assertEq(read.rollReserve(id), _floor(id), "and nothing more is held back from other draws");
    }

    /// @notice Any borrower repay of a `BIG` armed loan leaves the share at `min(armed, max(need(debt), floor))`, to the atom.
    /// @notice The freed difference becomes drawable cash at once: a repay credits no cash, so only the reserve moved.
    /// @dev The repay spans the dust band, the floor's neighbourhood and the shallow end, where the need still exceeds the floor.
    function testFuzz_ABorrowerRepayLeavesTheShareAtTheFlooredNeed(uint256 amtSeed) public {
        _deposit(id, 3 * P);
        uint256 loanId = _openBig(id, borrower);
        uint256 armed = read.reservedOf(loanId);
        uint256 amt = bound(amtSeed, 1, BIG - 1);
        uint256 drawable = ace.drawableOf(id);
        _repay(borrower, loanId, amt);
        uint256 want = _need(id, BIG - amt, TEN30);
        if (want < _floor(id)) want = _floor(id);
        if (want > armed) want = armed;
        assertEq(read.reservedOf(loanId), want, "the share is the floored need at the new debt, never over the armed share");
        assertEq(read.rollReserve(id), want, "and the market's reserve is that one share");
        assertEq(ace.drawableOf(id), drawable + (armed - want), "the freed share is drawable cash, to the atom");
    }

    /// @notice A share already at or under the floor never moves on a repay, wherever the repay lands the debt.
    /// @dev A 5,000 to 50,000 loan's 30-day share is under `minDebt - 1`, so neither the need nor the floor can cut it.
    function testFuzz_AShareUnderTheFloorNeverMovesOnARepay(uint256 principalSeed, uint256 amtSeed) public {
        uint256 principal = bound(principalSeed, MIN_DEBT, P);
        uint256 loanId = _openArmed(id, borrower, principal);
        uint256 armed = read.reservedOf(loanId);
        assertLe(armed, _floor(id), "PREMISE: the share starts at or under the floor");
        uint256 amt = bound(amtSeed, 1, principal - 1);
        _repay(borrower, loanId, amt);
        assertEq(read.reservedOf(loanId), armed, "a repay never grows the share, and the floor keeps it from shrinking");
        assertEq(read.rollReserve(id), armed, "and the reserve did not move");
    }

    /// @notice KNOWN: the share never GROWS, so a dust-band repay of a loan armed at the floor leaves its roll under-reserved.
    /// @dev Growing it would need a cash test, and a refused repay is worse than an under-covered roll; the borrower re-arms instead.
    function test_Known_AShareNeverGrows_ADustRepayCanOutgrowIt() public {
        uint256 loanId = _openArmed(id, borrower, MIN_DEBT);
        uint256 armed = read.reservedOf(loanId);
        _repay(borrower, loanId, MIN_DEBT / 2);
        uint256 need = _need(id, MIN_DEBT / 2, TEN30);
        assertGt(need, armed, "PREMISE: under the floor the successor floors at minDebt, so the need rose");
        assertEq(read.reservedOf(loanId), armed, "the share stayed where arming put it: a shrink, never a growth");
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN30, 0, 0);
        assertEq(read.reservedOf(loanId), need, "and a re-arm reserves the risen need");
    }

    /// @notice Code-review finding 1, ruled (b): coverage of a dust-band roll does not depend on the ORDER of the repays.
    /// @dev A stranger pays the armed loan down to `minDebt`, then the borrower repays into the dust band: the fold still rolls, fully lent.
    function test_APayDownToTheFloorThenADustRepayStillCoversTheRoll() public {
        uint256 loanId = _openArmed(id, borrower, P);
        _repay(stranger, loanId, P - MIN_DEBT);
        _repay(borrower, loanId, 500e6);
        _assertTheFoldRolls(loanId);
    }

    /// @notice The control: one borrower repay straight into the dust band leaves the roll covered too.
    function test_ASingleDustRepayCoversTheRoll() public {
        uint256 loanId = _openArmed(id, borrower, P);
        _repay(borrower, loanId, P - 4_500e6);
        _assertTheFoldRolls(loanId);
    }

    /// @dev At 4,500 the successor floors at `minDebt`, so the roll draws 500 fresh; the lender then lends out all but the reserve.
    function _assertTheFoldRolls(uint256 loanId) internal {
        uint256 need = _need(id, read.debtOf(loanId), TEN30);
        assertEq(need, 500e6, "PREMISE: under the floor the successor floors at minDebt");
        assertLe(need, read.reservedOf(loanId), "the share covers the dust-band roll");
        vm.startPrank(alice);
        ace.withdraw(id, ace.drawableOf(id), alice, 0);
        vm.stopPrank();
        assertEq(ace.drawableOf(id), 0, "PREMISE: fully lent, only the reserve rests");
        _warpTo(read.loan(loanId).expiry);
        uint256 n = read.loanCount();
        vm.prank(stranger);
        ace.forceClose(loanId);
        assertEq(read.loan(n + 1).borrower, borrower, "the fold rolled rather than settled");
    }

    /// @notice THE SUM survives the shrink: across a floored shrink and a share already under the floor, the reserve is the sum.
    function test_TheReserveStaysTheSumOfSharesAcrossShrinks() public {
        _deposit(id, 4 * P);
        uint256 a = _openBig(id, borrower);
        uint256 b = _openArmed(id, borrower2, P);
        uint256 bArmed = read.reservedOf(b);
        assertLt(bArmed, _floor(id), "PREMISE: the 50,000 loan's share starts under the floor");
        _repay(borrower, a, BIG - 10_000e6);
        _repay(borrower2, b, 10_000e6);
        assertEq(read.rollReserve(id), read.reservedOf(a) + read.reservedOf(b), "the reserve is the sum of the live shares");
        assertEq(read.reservedOf(a), _floor(id), "the big loan's share shrank to the floor");
        assertEq(read.reservedOf(b), bArmed, "the small loan's share stayed where arming put it: the floor is over it");
    }

    /// @notice A deleverage melt lowers the debt, and the armed share shrinks with it, to the larger of the new need and the floor.
    function test_ADeleverageMeltShrinksTheShare() public {
        MarketParams memory p = _params();
        p.deleverageFloorEpsBps = 100;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 5000;
        p.deleverageStopBps = 1000;
        bytes32 banded = ace.createMarket(p);
        _deposit(banded, 7 * P);
        uint256 loanId = _openBig(banded, borrower);
        uint256 armed = read.reservedOf(loanId);
        uint256 trig = read.triggerPrice(loanId);
        rec.setBelowBand((trig * 10_000) / 7000 + 1); // in band, above the trigger: no distress
        rec.setMinPrice((trig * 13) / 10); // above the stop level
        MockDeleverageKeeper k = new MockDeleverageKeeper(ace, address(usdc), address(coll), 1 << 96);
        (uint256 u,) = k.crankDeleverage(loanId);
        assertGt(u, 0, "PREMISE: the crank sold");
        uint256 debt = read.debtOf(loanId);
        assertLt(debt, BIG, "PREMISE: and melted debt");
        uint256 want = _need(banded, debt, TEN30);
        if (want < _floor(banded)) want = _floor(banded);
        assertLt(read.reservedOf(loanId), armed, "the share shrank");
        assertEq(read.reservedOf(loanId), want, "to the larger of the roll's need at the melted debt and the floor");
        assertEq(read.rollReserve(banded), read.reservedOf(loanId), "and the market's reserve with it");
    }
}
