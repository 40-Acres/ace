// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP8Economic
/// @notice MEASUREMENT, not refutation: every path here is legal and every assertion is a price tag.
/// @notice Written for the economic-actor review, whose subject is harm that needs no defect.
/// @dev Nothing here should ever go red for a correctness reason; a red here means an ECONOMIC change.
/// @dev The numbers are the deliverable, so each test emits them through named assertions.
contract AceP8EconomicTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's only lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 70_000e6; // $70,000 drawn
    uint256 internal constant COLL = 100_000e18; // 100,000 collateral tokens
    uint256 internal constant TOP = 400_000e6;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal T; // par for this pair -- $1.00 per collateral token; assigned in setUp

    /// @dev The market price the settled collateral is valued at: 20% above the funding tick.
    /// @dev Framed like every other price here, so `_valueAt` divides by the same `UNIT_SCALE` the hub uses.
    uint256 internal SPOT; // assigned in setUp, once the pair's decimals are known

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = _price(0);
        SPOT = AceFixtures.px(1.2e18, address(usdc), address(vault));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        _deposit(id, TOP);
        usdc.mint(borrower, 1_000_000e6);
    }

    // ---- fixture ----

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = 40; // the shipped rate, per minTenor
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50; // PocDeployConfig.SETTLE_BOUNTY_BPS
        p.minCoverageWad = 1.4e18; // PocDeployConfig.MIN_COVERAGE_WAD
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(bytes32 mid, uint256 principal) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, principal, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _arm(uint256 loanId, uint64 tenor) internal {
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, tenor, 0, 0);
    }

    /// @dev The settle sliver, mirroring `LoanAccounting.sliverUnits`.
    function _sliver(bytes32 mid, uint256 loanId) internal view returns (uint256) {
        uint256 floorPrice = read.fundingFloor(mid, loanId);
        if (floorPrice == 0) return 0;
        uint256 bty = (read.debtOf(loanId) * ace.idToMarketParams(mid).settleBountyBps * UNIT_SCALE) / (10000 * floorPrice);
        uint256 units = read.loan(loanId).collateralUnits;
        return bty < units ? bty : units;
    }

    /// @dev Quote value of `units` collateral atoms at `price`, in the record's own frame.
    function _valueAt(uint256 units, uint256 price) internal pure returns (uint256) {
        return (units * price) / UNIT_SCALE;
    }

    /// @dev The lender takes everything the loan left them: the pooled credit in quote, then the pot in kind.
    /// @dev WAS a receipt burn against a per-tick unit class. Sole tenancy makes the whole pot this lender's.
    function _harvest(uint256 loanId) internal returns (uint256 units, uint256 quote) {
        vm.startPrank(alice);
        quote = ace.collect(address(usdc), alice);
        if (read.invPotOf(id, loanId) > 0) units = ace.redeemInKind(loanId, alice);
        vm.stopPrank();
    }

    /* ================================================================= */
    /*  E1 -- the sole lender chooses the borrower's outcome at expiry    */
    /* ================================================================= */

    /// @notice The lender withdraws their own cash one block before the crank, and the armed roll
    /// @notice becomes a title transfer at the funding tick. Both verbs are documented as always available.
    /// @dev The suite already pins the MECHANISM green (`AceExpiryRollover::test_R3b`). This prices it.
    function test_P8_E1_SoleLenderWithdrawAtExpiry_ConvertsARollIntoATitleTransferAtBook() public {
        uint256 loanId = _open(id, P);
        _arm(loanId, TEN7);
        uint256 debt = read.debtOf(loanId);
        uint256 par = T; // the market's own price, which IS the floor a draw here lands on
        assertEq(read.fundingFloor(id, loanId), par, "fixture: the loan funded at the market price");
        _warpTo(uint256(read.loan(loanId).expiry));

        uint256 root = vm.snapshotState();

        // --- branch A: the ordinary crank. The policy rolls; the lender keeps a quote claim. ---
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 rolledId = read.loanCount();
        assertEq(read.debtOf(loanId), 0, "branch A really is the continuation");
        uint256 borrowerUnitsA = read.loan(rolledId).collateralUnits;
        uint256 borrowerDebtA = read.debtOf(rolledId);
        uint256 borrowerEquityA = _valueAt(borrowerUnitsA, SPOT) - borrowerDebtA;

        vm.revertToState(root);

        // --- branch B: the lender withdraws first, then cranks. Identical verbs, opposite outcome. ---
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0); // the sole lender takes their whole resting balance out
        vm.prank(alice);
        ace.forceClose(loanId);
        assertGt(read.debtOf(loanId), 0, "branch B really is the settlement: the debt was not retired");

        (uint256 lenderUnits, uint256 lenderQuote) = _harvest(loanId);
        uint256 borrowerResidue = read.unitsOwedOf(loanId, borrower);
        uint256 borrowerEquityB = _valueAt(borrowerResidue, SPOT);

        // The lender bought the collateral at the funding tick and holds it at spot.
        uint256 lenderTake = _valueAt(lenderUnits, SPOT) - debt + lenderQuote;

        assertGt(borrowerEquityA, borrowerEquityB, "the borrower is measurably worse off for the lender's extra call");
        emit log_named_decimal_uint("borrower equity, roll branch      (USDC)", borrowerEquityA, 6);
        emit log_named_decimal_uint("borrower equity, settle branch    (USDC)", borrowerEquityB, 6);
        emit log_named_decimal_uint("borrower loss                     (USDC)", borrowerEquityA - borrowerEquityB, 6);
        emit log_named_decimal_uint("lender gain over par at 1.20 spot (USDC)", lenderTake, 6);
        emit log_named_decimal_uint("forgone roll origination fee      (USDC)", _feeFor(P), 6);

        // The transfer is ~20% of the drawn principal: exactly the appreciation over the funding tick.
        assertGt(borrowerEquityA - borrowerEquityB, (debt * 15) / 100, "the transfer exceeds 15% of the debt");
        assertGt(lenderTake, 20 * _feeFor(P), "and it dwarfs the origination fee the lender gave up to take it");
    }

    /// @dev The all-in origination fee at this market's single tenor.
    function _feeFor(uint256 principal) internal pure returns (uint256) {
        return (principal * 40 * uint256(TEN7) * 11000 + (10000 * 10000 * uint256(TEN7)) - 1) / (10000 * 10000 * uint256(TEN7));
    }

    /* ================================================================= */
    /*  E2 -- the sliver is the keeper's whole pay, and only the LATE     */
    /*        path pays it. The cheap path for the borrower is unpaid.    */
    /* ================================================================= */

    /// @notice Rolling inside the window is free; rolling AT expiry pays the caller a sliver of the
    /// @notice position. So the borrower's cheap path is the one no keeper is paid to run.
    function test_P8_E2_TheFreeRollAndThePaidRoll_DifferOnlyInWhoIsPaid() public {
        uint256 loanId = _open(id, P);
        _arm(loanId, TEN7);
        uint256 root = vm.snapshotState();

        // free door, inside the window
        _warpTo(uint256(read.loan(loanId).expiry) - 2 hours);
        vm.prank(keeper);
        uint256 freeId = ace.refinanceByPolicy(loanId);
        assertEq(read.loan(freeId).collateralUnits, COLL, "the free door shaves nothing");
        assertEq(vault.balanceOf(keeper), 0, "and pays the caller nothing at all");

        vm.revertToState(root);

        // paid door, at expiry
        _warpTo(uint256(read.loan(loanId).expiry));
        uint256 want = _sliver(id, loanId);
        vm.prank(keeper);
        ace.forceClose(loanId);
        vm.prank(keeper);
        ace.claimOwed(loanId, keeper);

        assertGt(want, 0, "the paid door pays a real sliver");
        assertEq(vault.balanceOf(keeper), want, "to whoever cranked it");
        emit log_named_decimal_uint("sliver, one late roll (collateral atoms)", want, 18);
        emit log_named_uint("sliver as bps of the position", (want * 10000) / COLL);
    }

    /// @notice The armed chain is FINITE both ways: the fee compounds the debt into the funding floor
    /// @notice and the loan is settled at book. The sliver on the paid door roughly halves its length.
    /// @dev "Arm it and walk away" therefore terminates in the title transfer E1 prices, on a schedule.
    function test_P8_E2b_TheArmedChainIsFinite_AndThePaidDoorHalvesIt() public {
        uint256 root = vm.snapshotState();

        (uint256 paidTerms, uint256 taken) = _rollUntilSettled(true);
        vm.revertToState(root);
        (uint256 freeTerms,) = _rollUntilSettled(false);

        emit log_named_uint("terms survived, PAID door (forceClose at expiry)", paidTerms);
        emit log_named_uint("terms survived, FREE door (refinanceByPolicy in window)", freeTerms);
        emit log_named_decimal_uint("collateral taken by keepers on the paid door", taken, 18);
        emit log_named_uint("as bps of the opening position", (taken * 10000) / COLL);
        emit log_named_decimal_uint("origination paid per term", _feeFor(P), 6);

        assertGt(freeTerms, paidTerms, "the sliver shortens the chain the borrower armed");
        assertGt(taken, 0, "and the charge is real");
    }

    /// @dev Roll one armed loan until the chain refuses, through one door; returns terms and sliver taken.
    function _rollUntilSettled(bool paid) private returns (uint256 terms, uint256 taken) {
        _deposit(id, 4_000_000e6); // deep enough that the ladder is never the binding constraint
        uint256 loanId = _open(id, P);
        _arm(loanId, TEN7);
        for (uint256 i; i < 12; i++) {
            uint256 n = read.loanCount();
            if (paid) {
                _warpTo(uint256(read.loan(loanId).expiry));
                uint256 s = _sliver(id, loanId);
                vm.prank(keeper);
                ace.forceClose(loanId);
                if (read.loanCount() == n) return (terms, taken); // settled, not rolled
                taken += s;
            } else {
                _warpTo(uint256(read.loan(loanId).expiry) - 2 hours);
                (bool ok, bytes4 why,) = ace.tryContinue(loanId);
                if (!ok) {
                    emit log_named_bytes32("free door refused with", bytes32(why));
                    return (terms, taken);
                }
                vm.prank(keeper);
                ace.refinanceByPolicy(loanId);
            }
            terms++;
            loanId = read.loanCount();
        }
    }

    /* ================================================================= */
    /*  E3 -- baseBps is a rate PER minTenor, floored at MIN_TENOR_FLOOR. */
    /*        The fee-share rail bounds fee/principal, never fee/time.    */
    /* ================================================================= */

    /// @notice Two markets, identical but for `minTenor`, price credit ~168x apart. Both pass genesis.
    /// @dev `MAX_FEE_SHARE_BPS` bounds the fee as a fraction of the DRAW at any admissible term.
    /// @dev It is scale-invariant in time, so it says nothing about the rate a borrower actually pays.
    function test_P8_E3_TheFeeShareRailIsTimeScaleInvariant_SoTheRateIsUnbounded() public {
        MarketParams memory p = _params();
        p.baseBps = 500; // the rate #380 measured this at; the per-term band that once capped it here is gone
        p.minTenor = 1 hours;
        p.maxTenor = 1 hours;
        bytes32 fast = ace.createMarket(p); // genesis admits it
        _deposit(fast, TOP);

        Borrower.Quote memory q = ace.previewOpen(fast, COLL, P, 1 hours, borrower, OpenBounds(0, 0, 0));

        // the fee is 5.5% of the draw -- inside MAX_FEE_SHARE_BPS (25%) with room to spare
        assertApproxEqRel(q.fee, (P * 55) / 1000, 1e12, "5.5% of principal, per HOUR");
        uint256 aprBps = (q.fee * 10000 * 365 days) / (P * 1 hours);
        emit log_named_uint("fee, bps of principal, one term", (q.fee * 10000) / P);
        emit log_named_uint("implied APR, bps", aprBps);
        assertGt(aprBps, 2_000_000, "over 20,000% APR, and every genesis rail passed");

        // the shipped market, same rail, same fee-share headroom, 22.9% APR
        Borrower.Quote memory s = ace.previewOpen(id, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        uint256 shippedAprBps = (s.fee * 10000 * 365 days) / (P * uint256(TEN7));
        emit log_named_uint("shipped market APR, bps", shippedAprBps);
        assertLt(shippedAprBps, 3000, "the shipped market is under 30% APR");
        assertGt(aprBps / shippedAprBps, 100, "the two differ by over 100x on ONE field neither reads as a rate");

        // the floor of the scale: a WINDOW rail derived from the divisors, never sized against the rate
        uint64 floor = Constants.MIN_TENOR_FLOOR;
        MarketParams memory q1 = _params();
        q1.baseBps = 500;
        (q1.minTenor, q1.maxTenor) = (floor - 1, floor - 1);
        vm.expectRevert(bytes("min tenor under floor"));
        ace.createMarket(q1);
        (q1.minTenor, q1.maxTenor) = (floor, floor);
        bytes32 atFloor = ace.createMarket(q1);
        assertEq(ace.idToMarketParams(atFloor).minTenor, floor, "a MIN_TENOR_FLOOR minTenor at 500 bps still passes every genesis rail");
    }

    /* ================================================================= */
    /*  E5 and E6 -- DELETED. Both priced an attack a THIRD PARTY mounted */
    /*  by resting cash in someone else's market, which sole tenancy      */
    /*  makes unexpressible: a market names ONE lender, and its price is  */
    /*  write-once inside its own id.                                     */
    /*                                                                    */
    /*  E5 measured a latecomer resting one rung above an incumbent and   */
    /*  taking the whole draw and the whole fee; there is no rung to rest */
    /*  above and no second lender to take it from.                       */
    /*                                                                    */
    /*  E6 and E6b measured the DUST BLOCK: ten lots of `minLot` at the   */
    /*  top of the grid spent the draw's whole leg budget, so no draw     */
    /*  reached the deep cash and every armed loan settled at book -- for */
    /*  capital the attacker took straight back. Those rows were already  */
    /*  INVERTED once, to record that the guarded retry had closed it.    */
    /*  It is now closed twice over: the attacker cannot deposit into a   */
    /*  market that is not theirs, and a draw funds at one price with no  */
    /*  walk and no budget to exhaust.                                    */
    /*                                                                    */
    /*  WHAT SURVIVES of the concern is the deposit floor, which still    */
    /*  keeps a market's own lender from resting cash no draw can consume */
    /*  -- pinned at genesis by `min debt over cash cap` in               */
    /*  `AceGenesisRailGaps`, and at the door by `BelowMinLot`.           */
    /* ================================================================= */

    /* ================================================================= */
    /*  E4 -- the deleverage hysteresis rail is satisfied by ONE bps.     */
    /* ================================================================= */

    /// @notice `deleverageTargetBps > deleverageBandBps` is the whole hysteresis rail, so a market
    /// @notice whose target sits one bps above its band is admissible and restores essentially nothing.
    function test_P8_E4_OneBpsOfHysteresisIsAdmissible() public {
        MarketParams memory p = _params();
        p.deleverageBandBps = 3000; // MIN_DELEVERAGE_BAND_BPS
        p.deleverageTargetBps = 3001; // one bps of hysteresis
        p.deleverageStopBps = 2500;
        p.deleverageProtocolBps = 2000; // MAX_DELEVERAGE_PROTOCOL_BPS
        p.deleverageFloorEpsBps = 200; // MAX_DELEVERAGE_FLOOR_EPS_BPS
        p.fillFeeBps = 50; // MAX_FILL_FEE_BPS
        p.minCoverageWad = 1.4e18;

        bytes32 churn = ace.createMarket(p);
        MarketParams memory got = ace.idToMarketParams(churn);
        assertEq(got.deleverageTargetBps - got.deleverageBandBps, 1, "genesis admitted a one-bps hysteresis");
        assertEq(got.deleverageProtocolBps, 2000, "with the protocol cut at its ceiling");
        assertEq(got.deleverageFloorEpsBps, 200, "and the keeper margin at its ceiling");

        // every admitted sale loses (1 - (1-eps)(1-cut)) of the reference value before it melts debt
        uint256 keptBps = ((10000 - got.deleverageFloorEpsBps) * (10000 - got.deleverageProtocolBps)) / 10000;
        emit log_named_uint("bps of each sale that reaches the debt", keptBps);
        emit log_named_uint("bps of each sale that does not", 10000 - keptBps);
        assertLt(keptBps, 7900, "under 79% of every deleveraged unit's value melts debt");
    }
}
