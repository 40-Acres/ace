// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP9StrangerDrainVeto
/// @notice Phase 9 (griefer), run 2026-09-13-670568: a party with NO stake settled a funded, armed loan.
/// @notice The lever was an ordinary open repaid in the same transaction: repaid principal lands in `owed`, never in `cash`.
/// @notice FIXED: an armed loan reserves its roll's fresh remainder, a fresh draw sees cash less the reserve, and a home roll recycles.
/// @notice So the stranger's BEST drain now takes every unreserved atom and the armed fold still ROLLS.
/// @dev KNOWN, and pinned: that drain leaves nothing to back the SUCCESSOR's roll, so the successor is born disarmed.
/// @dev `AceP8Veto.t.sol` deleted V1 as unexpressible under sole tenancy; a stranger's draw cannot reach a reservation either.
abstract contract AceP9DrainBase is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the sole lender, honest: she rests the roll's successor plus slack
    address internal borrower = address(0xB0B); // armed, set-and-forget
    address internal keeper = address(0xCAFE); // cranks honestly at expiry
    address internal griefer = address(0x6E1EF); // no units, no loan, not the lender: pays only to do damage

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant UNITS = 100_000e18;
    uint256 internal constant SLACK = 5_000e6; // resting cash beyond the successor: a thin market, not an empty one

    function _record() internal virtual returns (address);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = _record();
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    /// @dev Alice rests the original draw, the successor it will roll into, and slack; the borrower arms a home roll.
    function _scenario() internal returns (uint256 loanId) {
        _deposit(2 * P + SLACK);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, TEN7, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
    }

    /// @dev Mints and approves the griefer's collateral and quote for one open of `amount`.
    function _armGriefer(uint256 amount) internal returns (uint256 units) {
        units = amount * 2e12; // two whole COLL per whole USDC at par: twice the market's coverage
        coll.mint(griefer, units);
        usdc.mint(griefer, amount);
        vm.startPrank(griefer);
        coll.approve(address(pm), units);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The whole lever: open `amount` against the griefer's own collateral, repay it, pull the refund and the units back.
    /// @return cost What the griefer is out of pocket in quote, all-in.
    function _drain(uint256 amount) internal returns (uint256 cost) {
        uint256 units = _armGriefer(amount);
        uint256 before = usdc.balanceOf(griefer);
        uint256 collBefore = coll.balanceOf(griefer);
        uint256 griefLoan = read.loanCount() + 1;
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Ace.open, (id, units, amount, TEN7, griefer, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.repay, (griefLoan, amount));
        calls[2] = abi.encodeWithSignature("claimOwed(uint256,address)", griefLoan, griefer);
        vm.prank(griefer);
        ace.multicall(calls);
        assertEq(coll.balanceOf(griefer), collBefore, "fixture: the griefer's collateral came back whole");
        cost = before - usdc.balanceOf(griefer);
    }

    /// @dev The stranger's BEST drain one hour before expiry: every unreserved atom, which is the most any fresh draw may take.
    /// @dev One atom more is refused; the roll stays admissible; at expiry the fold ROLLS into a successor born disarmed (KNOWN).
    function _attack(uint256 loanId) internal returns (uint256 drain, uint256 cost) {
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);
        (bool ok0,,) = ace.tryContinue(loanId);
        assertTrue(ok0, "PREMISE: before the drain the armed roll is admissible AND funded");
        drain = ace.restingOf(id) - read.rollReserve(id);
        assertGe(drain, ace.idToMarketParams(id).minDebt, "PREMISE: the drain is a legal draw");
        emit log_named_decimal_uint("roll reservation                  (USDC)", read.rollReserve(id), 6);
        emit log_named_decimal_uint("drain principal: all unreserved   (USDC)", drain, 6);

        uint256 over = _armGriefer(drain + 1);
        vm.prank(griefer);
        vm.expectRevert(InsufficientCash.selector);
        ace.open(id, over, drain + 1, TEN7, griefer, OpenBounds(0, 0, 0));

        cost = _drain(drain);

        (bool ok1,,) = ace.tryContinue(loanId);
        assertTrue(ok1, "the roll survives the stranger's best drain");

        _warpTo(read.loan(loanId).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "the fold rolled into a successor");
        assertEq(read.loan(n + 1).borrower, borrower, "and the successor is the borrower's");
        (uint64 tenor,,) = read.autoPolicyOf(n + 1);
        assertEq(tenor, 0, "KNOWN: the successor is born disarmed, since the drain took the cash its own roll would reserve");
    }

    /// @notice CONTROL: the same market and loan, no griefer. The honest keeper's crank at expiry ROLLS.
    function test_Control_NoDrain_TheArmedRollFunds() public {
        uint256 loanId = _scenario();
        _warpTo(read.loan(loanId).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "rolled into a successor");
        assertEq(read.invPotOf(id, loanId), 0, "and nothing was taken from the borrower");
    }

    /// @notice CONTROL: where a stranger's repaid principal lands -- with the lender, never back in her resting cash.
    /// @dev The drain here is the old GROSS form, `cash - P' + 1`. The roll no longer needs that cash: it recycles the retiring debt.
    /// @dev So re-resting is no longer what restores the roll; this row pins only where the repaid principal goes.
    function test_Control_TheLenderReRestingRestoresTheRoll() public {
        uint256 loanId = _scenario();
        _warpTo(uint256(read.loan(loanId).expiry) - 1 hours);
        (,, uint256 p0) = ace.tryContinue(loanId);
        uint256 drain = ace.restingOf(id) - p0 + 1;
        uint256 walletBefore = usdc.balanceOf(alice);
        _drain(drain);
        /// @dev WALLET PLUS OWED, because the grief loan's repay is a CLOSING one and the hub pushes the pool
        /// @dev to the lender at a terminal close. Wherever the drained principal lands, it is NOT her resting cash.
        (uint256 resting,, uint256 owed) = read.lenderPools(alice, address(usdc));
        assertGe(owed + usdc.balanceOf(alice) - walletBefore, drain, "the repaid principal came back to alice, not to the market");
        assertEq(resting, ace.restingOf(id), "and not in her resting cash");
        _deposit(drain);
        _warpTo(read.loan(loanId).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n + 1, "with the cash back, the same crank rolls");
    }

    /// @notice MEASUREMENT: the stranger's best drain costs them the fee and changes this fold's branch not at all.
    function test_Measure_TheStrangersBestDrainOnlyDisarmsTheSuccessor() public {
        uint256 loanId = _scenario();
        (uint256 drain, uint256 cost) = _attack(loanId);
        assertEq(read.invPotOf(id, loanId), 0, "the lender's pot took nothing: the fold rolled");
        emit log_named_decimal_uint("griefer's all-in cost             (USDC)", cost, 6);
        emit log_named_uint("griefer's cost, bps of the drain", (cost * 10000) / drain);
    }

    /// @dev DELETED WITH THE REARM POLICY: `test_Control_ArmedRearmPlusCompound_RestoresTheRollAfterAPersistentDrain`.
    /// @dev It was THE ESCAPE from the persistent form: an armed lender let a keeper `compound` the drained principal
    /// @dev out of `owed` and back into the market, then crank the roll, both in one call. No hub verb does that now:
    /// @dev `collect` and `deposit` are both the lender's own now, so neither composes into a keeper's crank.
    /// @dev NO VEHICLE VERB IS OWED IN ITS PLACE: a vault holds its own cash and rests all of it inside its own door and roll.
    /// @dev A pawn market never holds resting cash. Ruling: curation-portfolios (#601, closed).

    /// @notice MEASUREMENT: the ATOMIC form at expiry, the stranger's best drain and the crank in one call, now ROLLS.
    /// @dev The griefer is still paid the sliver for cranking; what it no longer buys is the settle branch.
    function test_Measure_TheAtomicFormNowRolls() public {
        uint256 loanId = _scenario();
        _warpTo(read.loan(loanId).expiry);
        (bool ok0,,) = ace.tryContinue(loanId);
        assertTrue(ok0, "PREMISE: at expiry the roll is admissible and funded");
        uint256 amount = ace.restingOf(id) - read.rollReserve(id);
        uint256 units = _armGriefer(amount);
        uint256 before = usdc.balanceOf(griefer);
        uint256 griefLoan = read.loanCount() + 1;
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(Ace.open, (id, units, amount, TEN7, griefer, OpenBounds(0, 0, 0)));
        calls[1] = abi.encodeCall(Ace.forceClose, (loanId));
        calls[2] = abi.encodeCall(Ace.repay, (griefLoan, amount));
        calls[3] = abi.encodeWithSignature("claimOwed(uint256,address)", griefLoan, griefer);
        vm.prank(griefer);
        ace.multicall(calls);
        assertTrue(ace.isClosed(loanId), "the armed loan closed inside the griefer's own transaction");
        assertEq(read.invPotOf(id, loanId), 0, "but it ROLLED: the lender's pot took nothing");
        assertEq(read.loan(griefLoan + 1).borrower, borrower, "into the borrower's successor");
        assertEq(read.loan(griefLoan + 1).closedAt, 0, "which is live");
        emit log_named_decimal_uint("atomic form: griefer's all-in cost (USDC)", before - usdc.balanceOf(griefer), 6);
        emit log_named_decimal_uint("atomic form: sliver paid TO the griefer", read.unitsOwedOf(loanId, griefer), 18);
    }
}

// The recordless instance is deleted: a recordless market cannot arm (`ArmNeedsRecord`), so it has no armed roll to drain.

/// @notice The record-backed class: settlement takes `need` at the market price, and the record sits 10% over it.
contract AceP9StrangerDrainRecordBackedTest is AceP9DrainBase {
    MockPersistenceRecord internal rec;

    function _record() internal override returns (address) {
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        return address(rec);
    }

    /// @notice RED, the record-backed twin: a party with no stake cannot convert a funded armed roll into a settlement.
    function test_RED_AStrangerWithNoStakeCannotSettleAFundedArmedLoan() public {
        uint256 loanId = _scenario();
        _attack(loanId);
        assertEq(read.invPotOf(id, loanId), 0, "a stranger with no stake settled a funded armed loan, and the lender took its need");
    }
}
