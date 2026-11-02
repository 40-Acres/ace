// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowDebtFloor, BufferBelowMin, NoRecordPrice, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {_extended} from "../utils/Extended.sol";

/// @dev A contract paying a loan for its borrower: the router or relayer the repay floor once keyed out by `msg.sender`.
contract RepayRouter {
    function repayFor(Ace ace, MockERC20 usdc, uint256 loanId, uint256 amount) external {
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
    }
}

/// @title AceRepayFloorTest
/// @notice NO REPAY, BY ANYONE, LEAVES A LIVE LOAN UNDER ITS DEBT FLOOR, half `minPrincipal`: it pays the loan off or leaves at least the floor.
/// @notice The borrower, a stranger and a router paying for the borrower get the same answer at every amount.
/// @dev Reasoning: the design record.
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
    uint256 internal constant MP = 10e6 + 1; // odd, so a floor rounded up (5e6 + 1) differs from the hub's rounded down
    uint256 internal constant FLOOR = 5e6; // MP / 2 rounded down, spelled here rather than read off `LoanMath`

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.lender = alice;
        p.minPrincipal = MP;
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

    /// @dev The expected floor, independent of the derivation under test: a mirror of `LoanMath.debtFloor` would move with a mutant of it.
    function _debtFloor() internal pure returns (uint256) {
        return FLOOR;
    }

    /// @dev Everything a refused repay must leave untouched.
    struct Book {
        uint256 debt;
        uint256 claim;
        uint256 owed;
        uint256 hub;
        uint256 borrowerQuote;
        bool closed;
    }

    function _book() internal view returns (Book memory b) {
        b = Book(read.debtOf(loanId), read.claimOf(id, loanId), read.poolOwed(id), usdc.balanceOf(address(ace)), usdc.balanceOf(borrower), ace.isClosed(loanId));
    }

    function _assertUnmoved(Book memory a, string memory who) internal view {
        Book memory b = _book();
        assertEq(b.debt, a.debt, string.concat(who, ": the refused repay moved the debt"));
        assertEq(b.claim, a.claim, string.concat(who, ": or the claim"));
        assertEq(b.owed, a.owed, string.concat(who, ": or the lender's owed"));
        assertEq(b.hub, a.hub, string.concat(who, ": or the hub's quote"));
        assertEq(b.borrowerQuote, a.borrowerQuote, string.concat(who, ": or the borrower's quote"));
        assertEq(b.closed, a.closed, string.concat(who, ": or the loan's state"));
    }

    /// @dev The repay `who` sends for `amount`; a router pays from its own balance. Returns the revert data, empty when it landed.
    function _repayAs(uint256 whoSeed, uint256 amount) internal returns (bool ok, bytes memory err) {
        uint256 k = whoSeed % 3;
        if (k == 2) {
            RepayRouter router = new RepayRouter();
            usdc.mint(address(router), amount);
            (ok, err) = address(router).call(abi.encodeCall(RepayRouter.repayFor, (ace, usdc, loanId, amount)));
        } else {
            vm.prank(k == 0 ? borrower : stranger);
            (ok, err) = address(ace).call(abi.encodeWithSignature("repay(uint256,uint256)", loanId, amount));
        }
    }

    /// @notice RED: a stranger's partial repay that would leave a live loan under the debt floor is refused by name.
    function test_RED_AStrangerMayNotRepayALoanIntoTheDustBand() public {
        uint256 amount = read.debtOf(loanId) - _debtFloor() + 1;
        vm.prank(stranger);
        vm.expectRevert(BelowDebtFloor.selector);
        ace.repay(loanId, amount);
    }

    /// @notice RED: the borrower's own repay into `(0, floor)` is refused by name too, and moves nothing.
    function test_RED_TheBorrowerMayNotRepayIntoTheDustBand() public {
        uint256 amount = read.debtOf(loanId) - _debtFloor() + 1;
        Book memory before = _book();
        vm.prank(borrower);
        vm.expectRevert(BelowDebtFloor.selector);
        ace.repay(loanId, amount);
        _assertUnmoved(before, "borrower");
    }

    /// @notice CONTROL: the borrower may always pay their loan off; it closes and every unit is credited back.
    function test_TheBorrowerMayRepayInFull() public {
        uint256 units = read.loan(loanId).collateralUnits;
        vm.prank(borrower);
        ace.repay(loanId, type(uint256).max);
        assertTrue(ace.isClosed(loanId), "a full repay closes the loan");
        assertEq(read.debtOf(loanId), 0, "with no debt left");
        assertEq(read.unitsOwedOf(loanId, borrower), units, "and every unit credited to the borrower");
    }

    /// @notice CONTROL: the borrower may leave exactly the debt floor, and the loan stays live.
    function test_TheBorrowerMayLeaveExactlyTheDebtFloor() public {
        uint256 amount = read.debtOf(loanId) - _debtFloor();
        vm.prank(borrower);
        ace.repay(loanId, amount);
        assertEq(read.debtOf(loanId), _debtFloor(), "the borrower left exactly the floor");
        assertFalse(ace.isClosed(loanId), "and the loan is live");
    }

    /// @notice RED: a router paying for the borrower and the borrower itself get the same answer at `floor - 1`, the floor and the full debt.
    function test_RED_ARouterPayingForTheBorrowerIsFlooredAsTheBorrowerIs() public {
        uint256 debt = read.debtOf(loanId);
        uint256[3] memory amounts = [debt - _debtFloor() + 1, debt - _debtFloor(), debt];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            (bool okB, bytes memory errB) = _repayAs(0, amounts[i]);
            uint256 debtB = read.debtOf(loanId);
            vm.revertToState(snap);
            (bool okR, bytes memory errR) = _repayAs(2, amounts[i]);
            uint256 debtR = read.debtOf(loanId);
            vm.revertToState(snap);
            assertEq(okB, okR, "the router and the borrower get the same answer");
            assertEq(keccak256(errB), keccak256(errR), "with the same refusal");
            assertEq(debtB, debtR, "and leave the same debt");
            if (i == 0) assertEq(bytes4(errB), BelowDebtFloor.selector, "leaving floor - 1 is refused for both");
            else assertTrue(okB, "leaving the floor, or nothing, lands for both");
        }
    }

    /// @notice No repay, of any amount and by any sender, leaves a live loan under the debt floor; a refusal is `BelowDebtFloor` and moves nothing.
    function testFuzz_NoRepayByAnyoneLeavesALiveLoanUnderTheDebtFloor(uint256 amountSeed, uint256 whoSeed) public {
        uint256 amount = bound(amountSeed, 1, read.debtOf(loanId));
        Book memory before = _book();
        (bool ok, bytes memory err) = _repayAs(whoSeed, amount);
        if (!ok) {
            assertEq(bytes4(err), BelowDebtFloor.selector, "the only refusal is the floor");
            assertGt(before.debt - amount, 0, "and only a partial repay meets it");
            assertLt(before.debt - amount, _debtFloor(), "one that would leave the loan under the floor");
            return;
        }
        if (ace.isClosed(loanId)) assertEq(read.debtOf(loanId), 0, "a repay that closes the loan leaves no debt");
        else assertGe(read.debtOf(loanId), _debtFloor(), "a live loan is never left under the floor");
    }

    /// @notice M-RF1: a stranger's one-atom repay makes the borrower's repay to exactly the floor revert, but headroom and a full repay land.
    function test_AStrangersAtomRepayRevertsTheBorrowersExactFloorRepay_ButHeadroomAndFullRepayLand() public {
        uint256 exact = read.debtOf(loanId) - _debtFloor(); // what the borrower sized to land on the floor
        vm.prank(stranger);
        ace.repay(loanId, 1);
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(BelowDebtFloor.selector);
        ace.repay(loanId, exact);
        vm.revertToState(snap);
        vm.prank(borrower);
        ace.repay(loanId, exact - 2);
        assertEq(read.debtOf(loanId), _debtFloor() + 1, "a repay with headroom over the floor lands");
        vm.revertToState(snap);
        vm.prank(borrower);
        ace.repay(loanId, type(uint256).max);
        assertTrue(ace.isClosed(loanId), "and a full repay always lands");
    }

    /// @notice CONTROL: a stranger may leave exactly the debt floor.
    function test_AStrangerMayLeaveExactlyTheDebtFloor() public {
        uint256 amount = read.debtOf(loanId) - _debtFloor();
        vm.prank(stranger);
        ace.repay(loanId, amount);
        assertEq(read.debtOf(loanId), _debtFloor(), "the floor itself is outside the band");
    }

    /// @notice CONTROL: a stranger may always pay a loan off in full; zero is outside the band.
    function test_AStrangerMayRepayInFull() public {
        vm.prank(stranger);
        ace.repay(loanId, type(uint256).max);
        assertTrue(ace.isClosed(loanId), "a full repay by anyone closes the loan");
    }
}

/// @title AceExtendRecordLegTest
/// @notice A cash extension's record legs, its lender consenting: the record must answer a price, and admission is at `min(price, record)`.
/// @notice Salvaged from the retired fold's record-leg suite, which judged at the price; a refused extension leaves the loan to `forceClose`.
/// @dev The lender installs an always-yes roll policy, so every refusal here is the record's or admission's, never the lender's.
contract AceExtendRecordLegTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
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
        _deposit(id, alice, 2 * P);
        AceFixtures.installYesPolicy(ace, alice);
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

    /// @dev A loan whose borrower's allowance funds an extension's fee out of the principal the open paid.
    function _openLoan() internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The borrower's extension in the term's last second with its own `minBufferWad`; true when it extended the loan in place, false when refused.
    function _extendInLastSecond(uint256 loanId, uint256 minBufferWad) internal returns (bool) {
        uint64 expiry = read.loan(loanId).expiry;
        _warpTo(uint256(expiry) - 1);
        vm.prank(borrower);
        try ace.extend(loanId, minBufferWad, "") {} catch {}
        return _extended(read, loanId, expiry);
    }

    /// @dev A refused extension leaves the loan to the one settle verb at tenor, from the expiry second.
    function _settles(uint256 loanId) internal returns (bool) {
        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId);
        return ace.isClosed(loanId);
    }

    /// @notice A record between the trigger and the lender's price: the extension, judged at the record, lands in place.
    function test_ARecordUnderThePriceButOverTheTriggerExtends() public {
        uint256 loanId = _openLoan();
        rec.setMinPrice(_px(0.9e18));
        _warpTo(read.loan(loanId).expiry - 1);
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "the preview admits the extension under a record below the price");
        assertEq(why, bytes4(0), "with no refusal");
        assertTrue(_extendInLastSecond(loanId, 0), "the extension landed rather than leave the loan to settle at the lender's stale bid");
        assertEq(read.invPotOf(id, loanId), 0, "and the lender's pot took nothing");
    }

    /// @notice A record inside the borrower's buffer refuses only the buffer the CALLER names: at the record, its own pre-commit binds.
    function test_ARecordInsideTheBufferRefusesOnlyTheCallersOwnBuffer() public {
        uint256 loanId = _openLoan();
        rec.setMinPrice(_px(0.75e18));
        _warpTo(read.loan(loanId).expiry - 1);
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, uint256(BUF) * 1e14, "", borrower);
        assertFalse(ok, "the borrower's extension with its 10% buffer, judged at the record, is refused");
        assertEq(why, BufferBelowMin.selector, "by its risk distance measured against the record");
        (ok, why,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "the same extension naming no buffer admits: the trigger still sits under the record");
        assertEq(why, bytes4(0), "with no refusal");
        assertTrue(_extendInLastSecond(loanId, 0), "and lands");
    }

    /// @notice A record under the loan's own trigger refuses the extension on ONE print: an extension is admitted at `min(price, record)`.
    /// @dev The retired fold judged at the price, so one print admitted it and only PERSISTED distress settled; no persistence is asked now.
    function test_ARecordUnderTheTriggerRefusesTheExtension() public {
        uint256 loanId = _openLoan();
        rec.setMinPrice(_px(0.6e18));
        _warpTo(read.loan(loanId).expiry - 1);
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", borrower);
        assertFalse(ok, "one print under the trigger refuses the extension");
        assertEq(why, TriggerAboveFloor.selector, "named as TriggerAboveFloor");
        assertFalse(_extendInLastSecond(loanId, 0), "the verb refuses as its preview does");
        assertTrue(_settles(loanId), "and forceClose settles the loan");
    }

    /// @notice CONTROL: a dark record still refuses, by name, and the loan settles (liveness is asked of the record).
    function test_ADarkRecordStillSettles() public {
        uint256 loanId = _openLoan();
        rec.setMinPrice(0);
        _warpTo(read.loan(loanId).expiry - 1);
        (bool ok, bytes4 why,) = ace.tryExtend(loanId, 0, "", borrower);
        assertFalse(ok, "darkness refuses the extension");
        assertEq(why, NoRecordPrice.selector, "by name");
        assertFalse(_extendInLastSecond(loanId, 0), "the verb refuses as its preview does");
        assertTrue(_settles(loanId), "and forceClose settles the loan");
    }
}

/// @title AceHomeRecycleTest
/// @notice A SAME-MARKET REFINANCE NEEDS ONLY THE FRESH REMAINDER: the retiring principal re-rests inside the call.
/// @notice Under the extend build it reuses the claim only on the lender's roll policy's yes, so the lender installs one here.
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
        AceFixtures.installYesPolicy(ace, alice);
    }

    /// @notice RED: with NO resting cash, a same-market refinance drawing no more than the old debt succeeds.
    /// @dev The long term's escrow refund covers the short term's fee, so `P' == D` clears `DrawBelowDebt` on its own.
    function test_RED_ARefinanceAtOrUnderTheOldDebtNeedsNoRestingCash() public {
        coll.mint(borrower, 2 * P * 1e12);
        vm.startPrank(borrower);
        coll.approve(address(pm), type(uint256).max);
        uint256 loanId = ace.open(id, 2 * P * 1e12, P, 28 days, borrower, OpenBounds(0, 0, 0));
        assertEq(ace.restingOf(id), 0, "PREMISE: the market is fully lent");
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, id, P, 7 days, OpenBounds(0, 0, 0), 0, address(0)));
        vm.stopPrank();
        assertEq(read.debtOf(newId), P, "the successor carries the old debt");
        assertEq(ace.restingOf(id), 0, "and drew nothing fresh: the retiring principal paid for it");
        assertEq(read.claimOf(id, newId), P, "the successor's claim is its whole principal");
    }
}
