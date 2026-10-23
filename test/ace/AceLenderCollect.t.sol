// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceLenderCollect
/// @notice THE LENDER'S ONE PAYOUT DOOR: credit accumulates in the pool and the lender's own `collect` pays it out.
/// @notice ACCUMULATION IS THE ONLY BEHAVIOUR. The rearm policy and `compound` that re-rested it are deleted.
/// @notice `collect` CONSULTS NOTHING -- no record, no gate, no policy -- so nothing off-chain can strand a payout.
/// @dev The contrast rows are the DEPOSIT door, which IS a lending decision and so does read the record.
/// @dev Its two answers are pinned here because they used to be pinned only as the foil to a compound refusal.
/// @dev A record that answers ZERO fails OPEN and the deposit lands; a record that cannot answer fails CLOSED.
contract AceLenderCollectTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE); // the fixture's named lender, so every market here is hers
    address internal stranger = address(0x57A);
    address internal sink = address(0x5111);
    address internal borrower = address(0xB0BA);

    uint256 internal T4; // the price this suite's market bids at; assigned in setUp, since par is not a compile-time value
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 1_000e6;
    uint256 internal constant MIN_LOT = 1e6; // the resting floor IS `minDebt`, low enough that a real fee clears it

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
        T4 = _price(960);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(vault)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault))); // above priceAt(T4) ~= 1.1007x par
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.price = T4; // the market's own bid, which the deposit door's cap rows read
        p.minDebt = MIN_LOT;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (d.ace, d.positionManager, d.read, d.id);
    }

    /* ------------------------------- helpers ------------------------------- */

    function _deposit(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(uint256 principal) internal returns (uint256 id) {
        vault.mint(borrower, COLL);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), 100e6);
        id = ace.open(mid, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev A bucket for `collect` to work on, built by a PARTIAL repay rather than a closing one.
    /// @dev IT WAS A FULL REPAY, and it had to change: a full repay is a TERMINAL CLOSE, and the hub now
    /// @dev pushes the whole pool to the lender there, so the bucket is empty by the time a row reads it.
    /// @dev A PARTIAL repay credits and does NOT push -- that is the exclusion ruling -- so it is the only
    /// @dev fixture that still leaves a bucket standing, and every `collect` row below needs one.
    /// @dev THIS ALSO REPAIRS TWO ROWS THAT HAD GONE VACUOUS: `NamesNoDestination` and the sick-record row
    /// @dev were still GREEN against an empty bucket, asserting nothing, because zero satisfied them.
    /// @dev `collect` IS THE RECOVERY DOOR NOW rather than the normal one, and these rows are what prove
    /// @dev it still works -- which is exactly why they must not be left asserting over a zero.
    function _oneCreditedLoan() internal returns (uint256 id) {
        _deposit(alice, PRINCIPAL * 3);
        id = _open(PRINCIPAL);
        uint256 half = read.loan(id).debt / 2;
        usdc.mint(borrower, half);
        vm.startPrank(borrower);
        usdc.approve(address(ace), half);
        ace.repay(id, half);
        vm.stopPrank();
        assertEq(read.loan(id).closedAt, 0, "fixture: the loan is still live, which is what stops the push");
    }

    /// @dev Alice's credit bucket, which is what a collect pays. POOLED over her markets in this quote.
    function _owed() internal view returns (uint256) {
        (,, uint256 owed) = read.lenderPools(alice, address(usdc));
        return owed;
    }

    /* ------------------------------ collect --------------------------------- */

    /// @notice `collect` pays the whole bucket in cash and empties it, which is the entirety of the verb.
    /// @dev WAS `test_Collect_PaysEvenWhileArmed`, whose subject was the explicit ask outranking a standing
    /// @dev rearm default. There is no default left to outrank, so what survives is the payment itself.
    function test_Collect_PaysTheWholeBucket() public {
        _oneCreditedLoan();
        uint256 owed = _owed();
        assertGt(owed, 0, "fixture: the lender is owed something to begin with");

        vm.prank(alice);
        uint256 paid = ace.collect(address(usdc), alice);

        assertEq(paid, owed, "the collect took the whole bucket");
        assertEq(usdc.balanceOf(alice), owed, "in cash, to the lender");
        assertEq(_owed(), 0, "and the bucket is empty");
    }

    /// @notice THE POOL PAID IS THE CALLER'S: a stranger naming a sink as `to` spends their own, empty, pool.
    /// @dev RENAMED from `test_Collect_NamesNoDestination_SoAStrangerDivertsNothing`: `collect` takes a `to` now,
    /// @dev and what makes that safe is the LEDGER KEY being `msg.sender`, so the destination moves only the caller's money.
    /// @dev WHAT THE FIXTURE HAS TO GUARANTEE, or this row means nothing: alice's bucket is NON-ZERO when
    /// @dev the stranger calls. Against an empty pool every assertion here is satisfied by zero -- the sink
    /// @dev is paid nothing because nobody is owed anything -- and the row passes while testing no rail at
    /// @dev all. It sat in exactly that state after the push landed and stayed GREEN, which is why
    /// @dev `_oneCreditedLoan` asserts its own premise rather than trusting the repay to leave a bucket.
    function test_Collect_SpendsOnlyTheCallersPool_SoAStrangerDivertsNothing() public {
        _oneCreditedLoan();
        uint256 owed = _owed();
        assertGt(owed, 0, "fixture: the lender has a bucket a stranger might reach for");

        vm.prank(stranger);
        assertEq(ace.collect(address(usdc), sink), 0, "the stranger's own pool is empty, so nothing is paid");
        assertEq(usdc.balanceOf(sink), 0, "so no quote reaches the address the caller chose");
        assertEq(_owed(), owed, "and the lender's bucket is untouched by the attempt");
    }

    /// @notice LENDER-ONLY: a stranger cannot bring the lender's money home; only the lender's own call moves it.
    /// @dev CONVERTED from `test_Collect_IsPermissionless_AndPaysTheLender`, whose permissionless door is removed.
    /// @dev A lender need not appear anyway: a terminal close pushes the pool, and this door recovers a refused push.
    function test_Collect_IsLenderOnly_AStrangerCannotReachTheLendersPool() public {
        _oneCreditedLoan();
        uint256 owed = _owed();
        assertGt(owed, 0, "fixture: the lender has a bucket a stranger might reach for");

        vm.prank(stranger);
        assertEq(ace.collect(address(usdc), stranger), 0, "the stranger's call spends only their own, empty, pool");
        assertEq(_owed(), owed, "so the lender's bucket is untouched");
        assertEq(usdc.balanceOf(alice), 0, "and nothing reached the lender on the stranger's call");
        assertEq(usdc.balanceOf(stranger), 0, "nor the stranger");

        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), owed, "the lender's own call moves the whole bucket");
        assertEq(usdc.balanceOf(alice), owed, "to the lender");
    }

    /// @notice An empty bucket collects zero rather than reverting, so a sweep is safe to run blind.
    /// @dev LOAD-BEARING: this is the row that pins `collect`'s `owed == 0` EARLY RETURN, which lands before
    /// @dev its storage write and before any transfer. A caller that cannot afford a revert needs no try/catch.
    function test_Collect_EmptyBucketPaysZero() public {
        _oneCreditedLoan();
        assertGt(_owed(), 0, "fixture: the first collect really has something to take");

        vm.prank(alice);
        ace.collect(address(usdc), alice);

        assertEq(_owed(), 0, "the bucket is empty, so the second call takes the zero path");
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), 0, "a second collect finds nothing");
        assertEq(usdc.balanceOf(alice), aliceBefore, "and moved no token on the way to saying so");
    }

    /// @notice A SICK record cannot stop the lender collecting: the payout door reads no record at all.
    /// @dev THE ASYMMETRY IS THE POINT and it is a doctrine line. Collecting is the lender taking money that
    /// @dev is already theirs, so it consults nothing. DEPOSITING is a lending decision, so it fails CLOSED
    /// @dev on the same record -- and that contrast is what the deleted `compound` row used to carry.
    /// @dev WHAT THE FIXTURE HAS TO GUARANTEE, or the collect half means nothing: the bucket is NON-ZERO
    /// @dev under the sick record. A collect of zero returns zero without reading anything, so an empty pool
    /// @dev satisfies "a sick record cannot stop the lender collecting" while proving no such thing. This row
    /// @dev was silently in that state after the push landed and stayed GREEN; `_oneCreditedLoan` is what
    /// @dev stops it recurring, and it asserts the loan is still live rather than assuming it.
    function test_Collect_PaysUnderASickRecord_WhereTheDepositDoorRefuses() public {
        _oneCreditedLoan();
        uint256 owed = _owed();
        record.setSick(true);

        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), owed, "a sick record cannot stop the lender collecting");

        usdc.mint(alice, PRINCIPAL);
        vm.startPrank(alice);
        usdc.approve(address(ace), PRINCIPAL);
        vm.expectRevert(RecordUnreadable.selector);
        ace.deposit(mid, PRINCIPAL);
        vm.stopPrank();
    }

    /* --------------------------- the deposit door ---------------------------- */

    /// @notice The deposit door admits under a hostile cap rather than reverting on the headroom arithmetic.
    /// @dev IT RESTED AT THE TOP USABLE TICK, the extreme a lender could reach by choosing a coordinate.
    /// @dev A market names its price at genesis, so the extreme is the CAP's now and the deposit is ordinary.
    function test_Deposit_UnderAHostileCapStillAdmits() public {
        record.setMinPrice(type(uint256).max);
        _deposit(alice, PRINCIPAL);
        assertGt(ace.restingOf(mid), 0, "the deposit door admits at the extreme rather than reverting");
    }

    /// @notice A record that ANSWERS ZERO fails OPEN: the deposit lands, because no price was refused.
    /// @dev The other half of the record's three answers, and it is not the sick case above: `NoPrice` is an
    /// @dev answer and `Record` is the absence of one. Only `Live` reaches the price leg at all.
    /// @dev Re-pinned standalone: this used to ride as the foil to a `compound` refusal that is now deleted.
    function test_Deposit_UnderANoPriceRecordStillAdmits() public {
        record.setMinPrice(0); // Live with no floor is the NoPrice answer
        uint256 restingBefore = ace.restingOf(mid);

        _deposit(alice, PRINCIPAL);

        assertEq(ace.restingOf(mid), restingBefore + PRINCIPAL, "a deposit under NoPrice is still admitted, whole");
    }
}
