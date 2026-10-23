// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {GateRefused} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IAceRefinance} from "../utils/RebateHarness.sol";

/// @title AcePooledCustodyMigration
/// @notice The two hub-level claims the pooled carry has to make: open parity, and no observable window.
/// @dev PARITY: `open` and a refinance-carried open run ONE body, so the records must agree field for field.
/// @dev Duplicating that body would have let a future gate or ledger write apply to opens and not to rolls.
/// @dev THE WINDOW: the carry is split so the debit stays where the old staged approval sat.
/// @dev An atomic carry could not precede the destination's admission, since the successor has no id until then.
/// @dev So an atomic verb would have exposed a CLOSED loan still holding LIVE custody to an attacker's gate.
/// @dev THAT ATTACKER NO LONGER EXISTS: admission is an address comparison, so the window contains no
/// @dev external call and nothing can observe it. The split is kept because the ordering is still the honest one.
contract AcePooledCustodyMigrationTest is WarpClock {
    Ace internal ace;
    IAceRefinance internal fin;
    AceReader internal read;
    PositionManager internal pm;
    PositionTitleNFT internal titles;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal recA;
    MockPersistenceRecord internal recB;
    bytes32 internal idA;
    bytes32 internal idB;
    bytes32 internal idClosed; // names a foreign borrower, so every open here is refused at its door

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant FLOAT = 2_000_000e6;

    /// @dev ONE funded tick per market, so the funding floor cannot drift between the two worlds.
    /// @dev Named RELATIVE to par and assigned in setUp, since par is not a compile-time value.
    uint256 internal TOP;
    uint256 internal constant TOP_CASH = 600_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        TOP = _price(0);
        recA = new MockPersistenceRecord(address(usdc), address(coll));
        recB = new MockPersistenceRecord(address(usdc), address(coll));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(address(recA), address(0)));
        (ace, pm, read, idA) = (d.ace, d.positionManager, d.read, d.id);
        fin = IAceRefinance(address(ace));
        titles = PositionTitleNFT(ace.POSITION_TITLE());

        idB = ace.createMarket(_params(address(recB), address(0))); // open, so the parity rolls land
        /// @dev A THIRD market naming a borrower nobody here is: the refusal control's destination, and only that.
        idClosed = ace.createMarket(_params(address(recB), address(0xDEAD1)));

        _deposit(idA, TOP_CASH);
        _deposit(idB, TOP_CASH);
        usdc.mint(borrower, FLOAT);

        vm.label(address(pm), "PositionManager");
    }

    // ---- fixture ----

    /// @dev The two markets differ ONLY by record and named borrower, which is what makes them distinct ids.
    function _params(address record, address borrower_) internal returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = record;
        p.borrower = borrower_;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, principal, tenor, borrower, OFF);
        vm.stopPrank();
    }

    /// @dev The shortfall a same-principal roll always leaves, since the new fee exceeds the old refund.
    function _gap(bytes32 dst, uint256 oldId, uint256 principal, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(dst);
        uint256 credit = principal - LoanMath.originationFee(principal, tenor, p.baseBps, p.minTenor) + read.earlyExitRefund(oldId);
        uint256 debtOld = read.loan(oldId).debt;
        return credit >= debtOld ? 0 : debtOld - credit;
    }

    /// @dev Repay the shortfall and roll in ONE transaction, which is how a short roll reaches the verb.
    function _migrate(uint256 oldId, bytes32 dst, uint256 principal, uint64 tenor) internal returns (uint256) {
        MigrateArgs memory m = MigrateArgs(oldId, dst, principal, tenor, OFF, 0, address(0));
        uint256 gap = _gap(dst, oldId, principal, tenor);
        bytes[] memory calls = new bytes[](gap == 0 ? 1 : 2);
        if (gap != 0) calls[0] = abi.encodeCall(Ace.repay, (oldId, gap));
        calls[gap == 0 ? 0 : 1] = abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m);
        vm.prank(borrower);
        bytes[] memory out = ace.multicall(calls);
        return abi.decode(out[out.length - 1], (uint256));
    }

    /// @dev Every field of a loan record an open and a carried open must agree on, id excepted.
    struct Record {
        bytes32 market;
        address borrower;
        uint256 collateralUnits;
        uint256 debt;
        uint64 tenor;
        uint64 expiry;
        uint256 feeEscrow;
        uint256 principal;
        uint256 floorPrice;
        uint256 appendedAtTail; // the id sitting at the market's last openedLoans index
        address title; // the minted ERC-721's owner
        uint256 custody; // the successor's credit on the shared pot
    }

    function _record(bytes32 mid, uint256 id) internal view returns (Record memory r) {
        r.market = read.loan(id).market;
        r.borrower = read.loan(id).borrower;
        r.collateralUnits = read.loan(id).collateralUnits;
        r.debt = read.loan(id).debt;
        r.tenor = read.loan(id).tenor;
        r.expiry = read.loan(id).expiry;
        r.feeEscrow = read.feeEscrowOf(id);
        r.principal = read.principalOf(id);
        r.floorPrice = read.fundingFloor(mid, id);
        uint256 len = ace.marketLoansLength(mid);
        r.appendedAtTail = ace.marketLoans(mid, len - 1, 1)[0];
        r.title = titles.ownerOf(id);
        r.custody = pm.collateralOf(id);
    }

    // ---- one open body, so the two doors cannot drift ----

    /// @notice An ordinary open and a refinance-carried open produce byte-identical loan records.
    /// @dev Both worlds run from the SAME snapshot at the SAME timestamp against the same one-tick ladder.
    /// @dev The ladder has one funded tick precisely so the funding floor cannot drift between them.
    /// @dev The `openedLoans` leg is asserted as an APPEND, since the carried world has a predecessor ahead of it.
    function test_openAndCarriedOpen_ProduceByteIdenticalLoanRecords() public {
        uint256 root = vm.snapshotState();

        uint256 plainId = _open(idA, P, TEN30);
        Record memory plain = _record(idA, plainId);
        assertEq(plain.appendedAtTail, plainId, "the plain open appended itself to the market's loan list");

        vm.revertToState(root);

        uint256 oldId = _open(idA, P, TEN30);
        uint256 carriedId = _migrate(oldId, idA, P, TEN30);
        Record memory carried = _record(idA, carriedId);

        assertTrue(carriedId != plainId, "the two worlds really did allocate different ids");
        assertEq(carried.market, plain.market, "market differs");
        assertEq(carried.borrower, plain.borrower, "borrower differs");
        assertEq(carried.collateralUnits, plain.collateralUnits, "collateralUnits differ");
        assertEq(carried.debt, plain.debt, "debt differs");
        assertEq(carried.tenor, plain.tenor, "tenor differs");
        assertEq(carried.expiry, plain.expiry, "expiry differs");
        assertEq(carried.feeEscrow, plain.feeEscrow, "feeEscrowOf differs");
        assertEq(carried.principal, plain.principal, "principalOf differs");
        assertEq(carried.floorPrice, plain.floorPrice, "the funding floor differs");
        assertEq(carried.appendedAtTail, carriedId, "the carried open appended itself too");
        assertEq(carried.title, plain.title, "the minted title differs");
        assertEq(carried.custody, plain.custody, "the successor's custody credit differs");
    }

    /// @notice The carried open moves ZERO tokens, which is the whole economic claim of the carry.
    /// @dev A plain open pulls the units; a carried one inherits a credit that is already in the pot.
    function test_carriedOpen_MovesNoTokens_WhileAPlainOpenPulls() public {
        uint256 oldId = _open(idA, P, TEN30);
        uint256 potBefore = coll.balanceOf(address(pm));
        uint256 borrowerBefore = coll.balanceOf(borrower);

        uint256 newId = _migrate(oldId, idA, P, TEN30);

        assertEq(coll.balanceOf(address(pm)), potBefore, "the pot did not move");
        assertEq(coll.balanceOf(borrower), borrowerBefore, "and the borrower funded nothing");
        assertEq(pm.collateralOf(newId), COLL, "while the successor carries the whole credit");
        assertEq(pm.collateralOf(oldId), 0, "and the predecessor gave it up");
    }

    // ---- the carry is SPLIT, so the window never opens ----

    /// @notice The destination's admission really is consulted on the migration path.
    /// @dev SURVIVES THE GATE'S DELETION in its useful half: the destination names a borrower this one is not.
    /// @dev WHAT WENT WITH THE GATE, and it is the point worth recording: the two probe rows above watched the
    /// @dev mid-migration window through the gate's staticcall, which was the ONE external call inside it.
    /// @dev There is now no external call in that window at all, so the closed-with-live-custody pair those
    /// @dev rows refused is UNOBSERVABLE rather than merely absent. The hazard is gone, and so is the probe.
    function testRevert_migrate_IntoADestinationNamingAnotherBorrower() public {
        uint256 oldId = _open(idA, P, TEN30);

        MigrateArgs memory m = MigrateArgs(oldId, idClosed, P, TEN30, OFF, 0, address(0));
        uint256 gap = _gap(idClosed, oldId, P, TEN30);
        vm.startPrank(borrower);
        if (gap != 0) ace.repay(oldId, gap);
        vm.expectRevert(GateRefused.selector);
        fin.refinanceTo(m);
        vm.stopPrank();

        assertFalse(read.loan(oldId).closedAt != 0, "a refused migration leaves the predecessor open");
        assertEq(pm.collateralOf(oldId), COLL, "and its custody credit whole");
    }

    /// @notice The predecessor's credit is never double-counted: the aggregate is bit-identical across a roll.
    /// @dev Neither carry verb moves the aggregate, so the rail never sees one; the ledgers sum to it only because the hub pairs them.
    function test_migrate_LeavesTheCustodyAggregateBitIdentical() public {
        uint256 oldId = _open(idA, P, TEN30);
        uint256 aggregateBefore = pm.custodiedOf(address(coll));

        uint256 newId = _migrate(oldId, idB, P, TEN30);

        assertEq(pm.custodiedOf(address(coll)), aggregateBefore, "the aggregate moved across a cross-market roll");
        assertEq(pm.collateralOf(newId) + pm.collateralOf(oldId), aggregateBefore, "and the ledgers still sum to it");
        assertEq(pm.custodiedOf(address(coll)), coll.balanceOf(address(pm)), "with the pot funding it exactly");
    }
}
