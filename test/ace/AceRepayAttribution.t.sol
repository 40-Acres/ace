// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRepayAttribution
/// @notice FORK C as ruled: a partial repay credits the loan's funded ticks PRO RATA by outstanding
/// @notice claim -- no tick is preferentially freed, and repaid principal never re-enters tick cash.
/// @notice THE PROPERTY IS ABOUT TICKS AND SURVIVES SOLE TENANCY: a draw still spans several of them.
/// @dev IT IS NOW READ OFF THE CLAIM LEDGER rather than off what two holders were paid. The old shape
/// @dev inferred the split from `claimUnits` paying alice at one tick and bob at another, which sole
/// @dev tenancy makes unrepresentable -- one lender owns every tick, and their credit lands in one pool.
/// @dev Reading `claimAt` per tick is the better test anyway: it observes the ledger the rule is about
/// @dev instead of its shadow in two payouts, and it no longer needs a fee flush to isolate anything.
/// @dev WHAT WAS DELETED, and it is not a coverage loss: the BETWEEN-HOLDERS half of the pro rata. There
/// @dev is one claimant, so no second party exists for a share to be unfair to.
contract AceRepayAttributionTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0BA);

    uint256 internal T3; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T4;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant TOP = 2_000e6;
    uint256 internal constant REPAY_1 = 900e6;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T3, T4) = (_price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(vault)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (d.ace, d.positionManager, d.read, d.id);

        /// @dev BOTH TICKS ARE ALICE'S: she is the market's one lender, so a second depositor is refused.
        /// @dev The two rungs are what the property needs, and they never needed two owners.
        usdc.mint(alice, TOP + 3_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), TOP + 3_000e6);
        ace.deposit(mid, TOP);
        ace.deposit(mid, 3_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 id) {
        vault.mint(borrower, COLL);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), 100e6);
        id = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _repay(uint256 id, uint256 amt) internal {
        usdc.mint(borrower, amt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), amt);
        ace.repay(id, amt);
        vm.stopPrank();
    }

    /// @notice A partial repay retires the loan's claim by exactly what was paid, and leaves it live.
    /// @dev No fee flush is needed: the claim ledger is read directly, so nothing has to be isolated first.
    /// @dev RENAMED from `..._CreditsTicksProRata`. FORK C's pro-rata ruling was about how a repayment split
    /// @dev across a loan's SEVERAL funded ticks: each was retired by its own share of the claim. A loan holds
    /// @dev ONE claim, so the split has one part and the ruling is discharged -- what survives is the half that
    /// @dev was never about apportionment: the repayment retires the claim by EXACTLY what was paid.
    function test_PartialRepayRetiresTheClaimByExactlyWhatWasPaid() public {
        uint256 id = _open();
        uint256 before = read.claimOf(mid, id);
        assertGt(before, 0, "fixture: the draw funded, so there is a claim for the repayment to retire");

        _repay(id, REPAY_1);

        uint256 paid = before - read.claimOf(mid, id);
        assertEq(paid, REPAY_1, "the claim fell by the repayment, to the atom");
        assertGt(read.claimOf(mid, id), 0, "and a PARTIAL repay leaves it live");
    }

    /// @notice A full repay retires the loan's claim, zeroes its derived floor, and closes it.
    /// @dev The par-plus-fee assertion moved to the pool: with one claimant there is nothing to split, so
    /// @dev what the lender is owed afterwards is the whole principal and then some, in one number.
    /// @dev THE PAR-PLUS-FEE LEG MOVED TO THE LENDER'S WALLET. A full repay is a terminal door and the hub
    /// @dev pushes the pool there, so `poolOwed` reads zero exactly where this row used to read the figure.
    /// @dev The claim is unchanged -- the lender ends up with par and then some -- only its location is.
    function test_FullRepayPaysParAndClosesClean() public {
        uint256 id = _open();
        uint256 before = usdc.balanceOf(alice);
        _repay(id, read.loan(id).debt);
        assertTrue(read.loan(id).closedAt != 0, "full repayment closes the loan");
        assertEq(read.claimOf(mid, id), 0, "the loan's one claim is retired");
        assertEq(read.fundingFloor(mid, id), 0, "and the derived floor goes with it: no claim, no floor");
        assertGe(usdc.balanceOf(alice) - before, PRINCIPAL, "the lender is paid par, plus the fee they earned");
        assertEq(read.poolOwed(mid), 0, "and the close left nothing pooled behind it");
    }

    /// @dev Repaid principal is the lender's credit now; the tick's resting cash must not move.
    function test_RepayNeverRecashesTheTick() public {
        uint256 id = _open();
        uint256 t4CashAfterDraw = read.restingOf(mid);
        _repay(id, REPAY_1);
        assertEq(read.restingOf(mid), t4CashAfterDraw, "repayment does not re-enter bucket cash");
    }
}
