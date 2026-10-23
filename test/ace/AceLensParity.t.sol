// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";

import {Loan, MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";

/// @title AceLensParity
/// @notice `AceLens` must agree with `AceReader`, view for view, against real market state.
/// @dev The two carry the SAME slot derivations by design, but only the reader is heavily exercised.
/// @dev That asymmetry is the risk: the lens is what outside code reads, and a wrong offset reverts nothing.
/// @dev WHAT THIS CATCHES is a ONE-SIDED edit: a derivation changed in one mirror and not the other.
/// @dev It is NOT an independent net -- a UNIFORM shift moves both mirrors and every assertEq still passes.
/// @dev `make layout` remains the only net for a uniform shift.
contract AceLensParityTest is Test {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;
    uint256 internal loanId;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3; // the rung above T2
    uint256 internal T4; // the rung above T3

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    /// @dev REAL state in every region the lens reads: three funded ticks, a live loan, an exit flag, a pot.
    /// @dev Parity on an EMPTY market would pass with almost any offset table.
    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));

        _deposit(5_000e6);
        _deposit(5_000e6);
        _deposit(5_000e6);

        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, 4_500e6, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    // ============ scalar market state ============

    function test_Parity_MarketState() public view {
        MarketState memory l = lens.marketState(id);
        MarketState memory r = read.marketState(id);
        assertEq(l.cash, r.cash, "cash");
        assertEq(l.drawCount, r.drawCount, "drawCount");
        assertEq(l.cumulativeBackedBurns, r.cumulativeBackedBurns, "cumulativeBackedBurns");
        assertEq(l.netSyntheticOutflow, r.netSyntheticOutflow, "netSyntheticOutflow");
        assertEq(l.protocolRevenue, r.protocolRevenue, "protocolRevenue");
        assertEq(l.lastSweptAt, r.lastSweptAt, "lastSweptAt");
        assertEq(l.unitScale, r.unitScale, "unitScale");
        assertEq(l.quoteOwedTotal, r.quoteOwedTotal, "quoteOwedTotal");
        assertEq(l.realizedLossAtBook, r.realizedLossAtBook, "realizedLossAtBook");
        assertGt(l.drawCount, 0, "the fixture really funded something");
    }

    /// @notice The LAST word of `MarketState` must actually be decoded, not silently read as zero.
    /// @dev A hard-coded word count that stopped one short passes every other test in the suite.
    /// @dev So the pin is a NON-ZERO value read back through the lens, on the newest field.
    function test_LensReportsQuoteOwedTotal() public {
        assertEq(lens.marketState(id).quoteOwedTotal, 0, "nothing owed while the loan is live");

        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt); // the clean close CREDITS the unearned fee escrow
        vm.stopPrank();

        uint256 owed = lens.marketState(id).quoteOwedTotal;
        assertGt(owed, 0, "the lens sees the tenth word: a short count would report zero forever");
        assertEq(owed, read.marketState(id).quoteOwedTotal, "and agrees with the reader");
        (, uint256 fromHub) = ace.owedOf(loanId, borrower);
        assertEq(owed, fromHub, "and with the hub's own per-claimant ledger");
    }

    /// @notice The per-claimant ledger reads back through the lens too, on both mappings.
    function test_Parity_OwedOf() public {
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();

        (uint256 lUnits, uint256 lQuote) = lens.owedOf(loanId, borrower);
        assertEq(lUnits, read.unitsOwedOf(loanId, borrower), "unitsOwed");
        assertEq(lQuote, read.quoteOwedOf(loanId, borrower), "quoteOwed");
        assertGt(lUnits, 0, "the close really credited collateral");
        assertGt(lQuote, 0, "and really credited quote");
    }

    // ============ the market's resting cash ============

    /// @notice The successor to the per-tick BUCKET region: one market, one resting balance, both mirrors.
    /// @dev `Bucket` is DELETED. Its `cash` became `MarketState.cash` and its `horizon` went with the
    /// @dev maturity consent, which a market now carries once as `maxTenor`. The bitmap views went too.
    /// @dev A decoder off by a word reported cash as a timestamp; the `MarketState` region below is where
    /// @dev that risk lives now, and it reads every member rather than only the ones a test happens to use.
    function test_Parity_RestingCash() public view {
        assertEq(lens.restingOf(id), read.restingOf(id), "restingOf");
        assertEq(lens.isActive(id), read.isActive(id), "isActive");
        assertGt(lens.restingOf(id), 0, "the market still rests what the draw left it");
    }

    /// @notice The POOLED lender region: the newest root, and the one nothing else compares across mirrors.
    /// @dev `unitClass` went with the receipt ledger. What replaced it is keyed by (lender, quote) rather
    /// @dev than by (loan, tick), so this reads the lenders root instead of a member offset inside `Market`.
    /// @dev All THREE legs are compared: a decoder that stopped one word short passes on the first two.
    function test_Parity_LenderPoolsRegion() public view {
        (uint256 lr, uint256 ll, uint256 lo) = lens.lenderPools(alice, address(usdc));
        (uint256 rr, uint256 rl, uint256 ro) = read.lenderPools(alice, address(usdc));
        assertEq(lr, rr, "resting");
        assertEq(ll, rl, "lent");
        assertEq(lo, ro, "owed");
        assertGt(lr, 0, "the fixture really rests cash: parity on zero proves nothing");
        assertGt(ll, 0, "and really drew against it");
        assertGt(lo, 0, "and its origination fee already reached the pool");
    }

    /// @dev DELETED: `test_Parity_ActiveTicks`. `activeTicks` walked the market's bitmap and returned the
    /// @dev coordinates carrying cash, and the row pinned the lens's walk against the reader's own. There is
    /// @dev no bitmap and no coordinate: a market is active or it is not, which `test_Parity_RestingCash`
    /// @dev compares across both mirrors as `isActive` alongside the one balance it stands on.

    // ============ loan-keyed regions ============

    function test_Parity_LoanRecord() public view {
        Loan memory l = lens.loan(loanId);
        Loan memory r = read.loan(loanId);
        assertEq(l.market, r.market, "market");
        assertEq(l.borrower, r.borrower, "borrower");
        assertEq(l.collateralUnits, r.collateralUnits, "collateralUnits");
        assertEq(l.debt, r.debt, "debt");
        assertEq(l.openTime, r.openTime, "openTime");
        assertEq(l.expiry, r.expiry, "expiry");
        assertEq(l.tenor, r.tenor, "tenor");
        assertEq(l.closedAt != 0, r.closedAt != 0, "closed");
        assertGt(l.debt, 0, "the fixture loan is live");

        assertEq(lens.loanCount(), read.loanCount(), "loanCount");
        assertEq(lens.principalOf(loanId), read.principalOf(loanId), "principalOf");
        assertEq(lens.feeEscrowOf(loanId), read.feeEscrowOf(loanId), "feeEscrowOf");
        assertGt(lens.feeEscrowOf(loanId), 0, "the fixture loan really carries an escrow to compare");
    }

    /// @dev `autoPolicyOf` is the LAST packed-field decoder either mirror still hardcodes by shift,
    /// @dev and it sits outside the byte-offset block `scripts/layout-check.sh` runs, so nothing else
    /// @dev in the tree would catch a one-sided edit to its `>> 64`.
    function test_Parity_AutoPolicy() public view {
        (uint64 lt, uint16 lb, uint16 lf) = lens.autoPolicyOf(loanId);
        (uint64 rt, uint16 rb, uint16 rf) = read.autoPolicyOf(loanId);
        assertEq(lt, rt, "tenor");
        assertEq(lb, rb, "minBufferBps");
        assertEq(lf, rf, "maxFeeBps");
    }

    /// @dev The parity above runs on a DISARMED policy, where every packed field is zero, so it would
    /// @dev pass against a decoder that had never learned the higher field at all.
    /// @dev This leg writes a non-zero value into EVERY field and re-asks the same question.
    /// @dev `maxFeeBps` is the highest and newest, so a decoder that stopped at `>> 64` reads it as zero here.
    function test_Parity_AutoPolicy_NonDefaultFields() public {
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, ProtocolPolicy.MIN_TENOR, 750, 125);

        (uint64 lt, uint16 lb, uint16 lf) = lens.autoPolicyOf(loanId);
        (uint64 rt, uint16 rb, uint16 rf) = read.autoPolicyOf(loanId);
        assertEq(lt, ProtocolPolicy.MIN_TENOR, "the fixture really carries an armed tenor");
        assertEq(lb, 750, "and a non-default buffer floor");
        assertEq(lf, 125, "and a non-default fee ceiling, so a decoder short of `>> 80` fails here");
        assertEq(lt, rt, "tenor");
        assertEq(lb, rb, "minBufferBps");
        assertEq(lf, rf, "maxFeeBps");
    }

    /// @dev DELETED: `test_Parity_RearmOf` and `test_Parity_RearmOf_IsKeyedPerLenderAndQuote`. They walked the
    /// @dev lender's standing re-rest policy through both mirrors, pinning `market` in particular because it sat
    /// @dev a whole word past the packed buffer. The policy, `rearmOf` and `compound` are all deleted, so both
    /// @dev mirrors have nothing left to disagree about: there is no lender-keyed struct here any more.

    function test_Parity_ClaimRegion() public view {
        assertEq(lens.fundingFloor(id, loanId), read.fundingFloor(id, loanId), "fundingFloor");
        assertGt(lens.fundingFloor(id, loanId), 0, "the loan really has a floor");

        /// @dev WAS a walk comparing two funded-tick LISTS entry by entry. A loan holds one claim, and that
        /// @dev claim IS the funded flag, so the whole region is two scalars -- and both mirrors derive them
        /// @dev by their own slot arithmetic, which is the only reason this row proves anything.
        assertEq(lens.claimOf(id, loanId), read.claimOf(id, loanId), "claimOf");
        assertGt(lens.claimOf(id, loanId), 0, "the loan really holds its claim");
        assertEq(read.claimCount(id, loanId), 1, "and that claim IS the funded flag, so the count is one");
    }

    /// @notice `AceLens.claimable` and `Ace.lenderAssets` are TWO INDEPENDENT DERIVATIONS OF ONE POOL.
    /// @notice Neither reads the other, so nothing but this makes them agree.
    /// @dev The lens walks the three pool words by SLOT OFFSET from `L_POOLS`; the hub reads the typed struct.
    /// @dev So a drifted root shows up as a disagreeing TOTAL, and a swapped word order as a disagreeing leg.
    /// @dev WAS `Ace.rearmRefusal`'s preview as the second derivation; that view went with the rearm policy.
    /// @dev Asked at three states, because agreement on two zeros would prove nothing.
    function test_Parity_ClaimableAgreesWithTheHubsOwnTotal() public {
        _assertClaimableParity("after the mint banked the accrual");
        assertGt(lens.claimable(alice, address(usdc)), 0, "the accrual really banked something to compare");

        /// @dev A PARTIAL repay, deliberately. A CLOSING one is a terminal door and the hub pushes the whole
        /// @dev pool there, so `claimable` would read zero and every leg below would compare two zeros --
        /// @dev green, and asserting nothing. A partial credits without pushing, which keeps a pool to walk.
        uint256 half = read.loan(loanId).debt / 2;
        usdc.mint(borrower, half);
        vm.startPrank(borrower);
        usdc.approve(address(ace), half);
        ace.repay(loanId, half);
        vm.stopPrank();
        uint256 owed = lens.claimable(alice, address(usdc));
        _assertClaimableParity("after the repay moved the pool");
        assertGt(owed, 0, "and the repay really raised it");
        assertEq(read.loan(loanId).closedAt, 0, "premise: the loan is live, which is what left the pool standing");

        /// @dev COLLECT IS THE RECOVERY DOOR: a terminal close pushes, and this pool never reached one.
        vm.prank(alice);
        assertEq(ace.collect(address(usdc), alice), owed, "the collect pays the whole credit leg, in full");
        _assertClaimableParity("after the collect emptied the pool");
        assertEq(lens.claimable(alice, address(usdc)), 0, "and the pool really is empty");
    }

    /// @dev The lens's slot walk against the hub's typed read, at whatever state the caller has reached.
    /// @dev BOTH LEGS EARN THEIR PLACE: the total catches a drifted root, the credit leg a swapped word order.
    function _assertClaimableParity(string memory at) internal view {
        (uint256 resting, uint256 lent, uint256 owed) = lens.lenderPools(alice, address(usdc));
        assertEq(resting + lent + owed, ace.lenderAssets(alice, address(usdc)), string.concat("the lens's triple misses the hub's total ", at));
        (,, uint256 readOwed) = read.lenderPools(alice, address(usdc));
        assertEq(lens.claimable(alice, address(usdc)), readOwed, string.concat("claimable disagrees with the reader's own walk ", at));
    }

    // ============ derived views ============

    function test_Parity_DerivedRiskViews() public view {
        assertEq(lens.utilization(alice, address(usdc)), read.utilization(alice, address(usdc)), "utilization");
        assertGt(lens.utilization(alice, address(usdc)), 0, "the fixture is really drawn");
        assertEq(lens.headroom(id), read.headroom(id), "headroom");
        assertEq(lens.triggerPrice(loanId), read.triggerPrice(loanId), "triggerPrice");
        assertGt(lens.triggerPrice(loanId), 0, "a live loan has a trigger");
        assertEq(lens.settleable(loanId), read.settleable(loanId), "settleable");
        assertEq(lens.inDistress(loanId), read.inDistress(loanId), "inDistress");
        assertEq(lens.isHealthy(loanId), read.isHealthy(loanId), "isHealthy");
    }

    /// @dev The health predicates on a CLOSED loan, where both mirrors carry the closed check: a one-sided drop reads healthy.
    function test_Parity_HealthPredicatesOnAClosedLoan() public {
        record.setAbove(true);
        assertTrue(lens.isHealthy(loanId), "PREMISE: live, and the record holds above the trigger");
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertTrue(read.loan(loanId).closedAt != 0, "PREMISE: the repay closed the loan");

        assertEq(lens.isHealthy(loanId), read.isHealthy(loanId), "isHealthy");
        assertFalse(lens.isHealthy(loanId), "and a closed loan is never healthy");

        record.setBelow(true); // flag mode: the record answers below at any level, so only the closed check keeps distress false
        assertEq(lens.inDistress(loanId), read.inDistress(loanId), "inDistress");
        assertFalse(lens.inDistress(loanId), "and a closed loan is never distressed");
    }

    /// @dev `settleable` on a CLOSED loan, on a record that answers "below" at trigger zero: both mirrors refuse before asking it.
    function test_Parity_SettleableOnAClosedLoan() public {
        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        assertTrue(read.loan(loanId).closedAt != 0, "PREMISE: the repay closed the loan");
        record.setBelow(true); // flag mode: the record answers below at any level, the closed loan's zero trigger included

        assertEq(lens.settleable(loanId), read.settleable(loanId), "settleable");
        assertFalse(lens.settleable(loanId), "and a closed loan is never settleable");
    }

    /// @dev DELETED: `test_Parity_BitmapWords`. The market kept a bitmap of which ticks carried cash, and both
    /// @dev mirrors decoded its words independently, so this row compared five of them. There is no bitmap: the
    /// @dev "does this market carry cash" question is `isActive`, compared in `test_Parity_RestingCash`.

    /// @notice The regression this suite exists for: a ONE-SIDED edit to either mirror's slot map.
    /// @dev Every region is read at once, so a derivation changed in one copy and not the other cannot
    /// @dev hide. A uniform shift is out of scope: it moves both mirrors, so `make layout` owns it.
    function test_Parity_EveryRegionAtOnce_CatchesAOneSidedEdit() public view {
        assertEq(lens.marketState(id).unitScale, read.marketState(id).unitScale, "state region");
        assertEq(lens.restingOf(id), read.restingOf(id), "bucket region");
        assertEq(lens.claimOf(id, loanId), read.claimOf(id, loanId), "claim region");
        assertEq(lens.fundingFloor(id, loanId), read.fundingFloor(id, loanId), "floor region");
        assertEq(lens.invPotOf(id, loanId), read.invPotOf(id, loanId), "inventory region");
        (uint256 lr,,) = lens.lenderPools(alice, address(usdc));
        (uint256 rr,,) = read.lenderPools(alice, address(usdc));
        assertEq(lr, rr, "lenders root");
    }
}
