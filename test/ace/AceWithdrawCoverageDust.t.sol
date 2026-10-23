// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowWithdrawLine} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceWithdrawCoverageDust
/// @notice THE QUESTION: does the withdrawal gate still cover settlement once debt is repaid to dust?
/// @notice Two functions answer "collateral this loan needs" and they do not agree at the wei.
/// @notice `Borrower.requiredAt` takes ONE ceiling over the whole debt: admissibility, and the old gate.
/// @notice `LoanAccounting.collateralNeeded` takes N ceilings, one per funded tick, and governs `_settle`.
/// @notice `Borrower.withdrawLine` is what gates `withdrawCollateral` now: `requiredAt` plus the tick cap.
/// @dev Write `omega = priceAt(t) / unitScale`, the QUOTE WEI one COLLATERAL WEI buys at that tick.
/// @dev Then the gate leaves `k * debt / omega_floor` and settlement asks `sum ceil(claim_t / omega_t)`.
/// @dev Each per-tick ceiling rounds up by under one collateral wei, so the sum can exceed the gate.
/// @dev The violation condition is `n_eff > (k - 1) * debt / omega_floor`: the coverage margin,
/// @dev MEASURED IN COLLATERAL WEI, smaller than the count of funded ticks.
/// @dev So it needs BOTH dust debt and a large `omega`, and the shortfall is bounded by `maxClaimTicks` wei.
/// @dev `omega = human_price * 10 ** (quoteDec - collDec)`, so an 8-dec collateral against an 18-dec
/// @dev quote gives `omega ~ 1e10` at a price near 1, and WBTC/USDC at $60k gives `omega ~ 600`.
/// @dev The doctrinal claim under test is `the design record`, `shortfall-unreachable`:
/// @dev "withdrawing to the line does not thin it, because at the line `units = k x need` exactly".
/// @dev That identity is real-arithmetic; `need` is a sum of integer ceilings and is not `debt * S / floor`.
/// @dev DUST DEBT IS REACHABLE WITHOUT ANY CODE CHANGE, BY PLAIN `repay`, and nothing else is needed.
/// @dev `Types.sol` states why: `minDebt` is an ADMISSION quantum that floors what a DRAW issues.
/// @dev It floors what a `deleverage` crank leaves, never what a repay (anyone's) leaves: no `src` site reads it on that path.
/// @dev So a borrower walks a funded loan into the dust window with one public verb and no guard.
contract AceWithdrawCoverageDustTest is Test {
    /// @dev One deployed market, and the borrower repays its debt down to dust.
    struct Fx {
        Ace ace;
        PositionManager pm;
        AceReader read;
        AceLens lens;
        bytes32 id;
        MockERC20 quote;
        MockERC20 coll;
        uint256 unitScale;
    }

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant TICKS = 32; // == maxClaimTicks: the count that maximizes the ceiling slack
    int24 internal constant SPACING = 60;
    uint256 internal constant K = 1.4e18; // PocDeployConfig.MIN_COVERAGE_WAD, the shipped coverage multiple

    function setUp() public {
        vm.warp(1_000_000);
    }

    /* ============================ the fixture ============================ */

    /// @dev A market whose collateral and quote decimals are the caller's, funded across all 32 ticks.
    function _deploy(uint8 collDec, uint8 quoteDec, uint256 perTick, uint256 minDebt) internal returns (Fx memory f) {
        f.quote = new MockERC20("Quote", "Q", quoteDec);
        f.coll = new MockERC20("Collateral", "C", collDec);
        MockPersistenceRecord record = new MockPersistenceRecord(address(f.quote), address(f.coll));

        MarketParams memory p = AceFixtures.marketParams(address(f.quote), address(f.coll));
        p.record = address(record);
        p.minDebt = minDebt;

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (f.ace, f.pm, f.read, f.id) = (d.ace, d.positionManager, d.read, d.id);
        f.lens = new AceLens(address(d.ace)); // the shipped views are the oracle; the test keeps no mirror
        f.unitScale = f.read.marketState(f.id).unitScale;

        /// @dev THE TOTAL IS KEPT AND THE PER-RUNG LEG IS GONE: `perTick` sits under the deposit floor, which
        /// @dev is `minDebt` itself now rather than the fraction `ceil(minDebt / maxClaimTicks)` used to be.
        uint256 total = perTick * TICKS;
        f.quote.mint(alice, total);
        vm.startPrank(alice);
        f.quote.approve(address(f.ace), total);
        f.ace.deposit(f.id, total);
        vm.stopPrank();
    }

    /// @dev DELETED: `_price(par, i)`, the i-th funding tick descending from par so a draw spanned the seeded
    /// @dev band. A market bids at one price, so there is no band to descend and no i to index.

    /// @dev Opens the loan that funds every seeded tick: the principal is exactly the seeded cash.
    function _open(Fx memory f, uint256 perTick, uint256 units) internal returns (uint256 loanId) {
        f.coll.mint(borrower, units);
        vm.startPrank(borrower);
        f.coll.approve(address(f.pm), units);
        loanId = f.ace.open(f.id, units, perTick * TICKS, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Walks the debt down to `target` with a plain `repay`: the only route to dust the hub has.
    /// @dev No `minDebt` guard stands on this path, so the target may sit anywhere inside the window.
    function _repayTo(Fx memory f, uint256 loanId, uint256 target) internal {
        uint256 pay = f.read.loan(loanId).debt - target;
        f.quote.mint(borrower, pay);
        vm.startPrank(borrower);
        f.quote.approve(address(f.ace), pay);
        f.ace.repay(loanId, pay);
        vm.stopPrank();
        assertEq(f.read.loan(loanId).debt, target, "fixture: the repay landed the debt exactly on target");
    }

    /* ======================== the two quantities ======================== */

    /// @dev What settlement needs, read off the SHIPPED lens rather than recomputed here.
    /// @dev The suite deliberately keeps no arithmetic of its own: a mirror that drifts proves nothing.
    function _need(Fx memory f, uint256 loanId) internal view returns (uint256) {
        return f.lens.collateralNeeded(f.id, loanId);
    }

    /// @dev The gate's own line, derived from what the lens says is still withdrawable.
    /// @dev Every caller pins it with a one-wei-past revert probe, so the line is the hub's and not this file's.
    function _gateLine(Fx memory f, uint256 loanId) internal view returns (uint256) {
        return f.read.loan(loanId).collateralUnits - f.lens.withdrawableUnits(f.id, loanId);
    }

    /// @dev Live claims on this loan: `n_eff`, the count `collateralNeeded` pays a ceiling for.
    /// @dev IT IS ONE OR ZERO NOW. The epsilon that rode on it collapsed with it: the coverage line was
    /// @dev `requiredAt` plus one atom PER FUNDED TICK, and a loan funds one, so it is `requiredAt` plus one.
    function _liveTicks(Fx memory f, uint256 loanId) internal view returns (uint256) {
        return f.read.claimCount(f.id, loanId);
    }

    /// @dev Withdraw everything the gate allows, and prove one wei more is refused.
    function _withdrawToTheLine(Fx memory f, uint256 loanId) internal returns (uint256 line) {
        line = _gateLine(f, loanId);
        uint256 held = f.read.loan(loanId).collateralUnits;
        assertGt(held, line, "fixture: the loan holds more than the gate requires");

        /// @dev BY SELECTOR: a bare expectRevert would accept any refusal and leave the line unpinned.
        vm.prank(borrower);
        vm.expectRevert(BelowWithdrawLine.selector);
        f.ace.withdrawCollateral(loanId, held - line + 1, borrower);

        vm.prank(borrower);
        f.ace.withdrawCollateral(loanId, held - line, borrower);
        assertEq(f.read.loan(loanId).collateralUnits, line, "the loan now sits exactly on the gate's line");
    }

    /* ============ the sequence that reproduced the defect ============ */

    /// @notice THE PROPERTY: a loan withdrawn to the gate's own line still covers every claim it created.
    /// @notice Reproduced on an 8-dec collateral against an 18-dec quote, with debt repaid to dust.
    /// @notice This is the route the dust floor used to block, so it is the one the gate has to carry alone.
    /// @dev No `src` edit and no `vm.store`: every step is a public verb any borrower can call today.
    function test_WithdrawToTheLine_OnDustDebt_LeavesTheLoanCoveredAtSettlement() public {
        Fx memory f = _deploy(8, 18, 1e18, 10e18);
        uint256 loanId = _open(f, 1e18, 8e9);
        assertEq(f.read.claimCount(f.id, loanId), 1, "fixture: the draw funded, and a draw funds exactly one claim");

        _repayTo(f, loanId, 64e9); // dust: ~2e9 of claim left on each of the 32 ticks
        assertEq(_liveTicks(f, loanId), 1, "fixture: the partial repay left the loan ONE live claim, which is all it ever holds");
        assertLt(f.read.loan(loanId).debt, f.ace.idToMarketParams(f.id).minDebt, "fixture: debt is inside the dust window");

        uint256 line = _withdrawToTheLine(f, loanId);
        uint256 need = _need(f, loanId);

        emit log_named_uint("n_eff", _liveTicks(f, loanId));
        emit log_named_uint("debt", f.read.loan(loanId).debt);
        emit log_named_uint("unitScale", f.unitScale);
        emit log_named_uint("fundingFloor", f.read.fundingFloor(f.id, loanId));
        emit log_named_uint("withdrawLine (gate line)", line);
        emit log_named_uint("_collateralNeeded", need);

        assertLe(need, line, "a loan on the withdrawal gate's line must still cover settlement");
    }

    /// @notice The same sequence read off the CONTRACT, with no mirrored arithmetic anywhere.
    /// @notice A loan withdrawn only to the line, then force-closed at tenor, must record no bad debt.
    /// @dev The lens is only a MIRROR of the hub's own sum, so this asserts on `shortfallOf`, which `_settle` writes.
    /// @dev It is the ground truth for the sibling above: if the mirror were wrong, this would still be right.
    function test_ForceClose_AfterWithdrawingToTheLine_RecordsNoShortfall() public {
        Fx memory f = _deploy(8, 18, 1e18, 10e18);
        uint256 loanId = _open(f, 1e18, 8e9);

        _repayTo(f, loanId, 64e9);
        _withdrawToTheLine(f, loanId);

        vm.warp(f.read.loan(loanId).expiry + 1);
        f.ace.forceClose(loanId);

        (uint256 short, uint256 quoteAtBook) = f.read.shortfallOf(loanId);
        emit log_named_uint("shortfall units", short);
        emit log_named_uint("shortfall at book (quote)", quoteAtBook);
        assertEq(short, 0, "a loan settled off the withdrawal line must leave its lenders whole");
    }

    /* ============== the same posture with NO dust window at all ============== */

    /// @notice THE SEPARATION: the same debt on a market whose `minDebt` admits it is not dust at all.
    /// @notice So the coverage property is a fact about the ARITHMETIC, not about the dust window.
    /// @dev `minDebt` is creator-chosen and bounded only by `originationFee(minDebt) < minDebt`, so 1e5
    /// @dev wei of an 18-dec quote is a legal floor. Unusual, but a permissionless creator may pick it.
    /// @dev Every quantity the gate and settlement read is identical to the sibling above; only `minDebt` moves.
    /// @dev No `src` site reads `minDebt` on the repay, gate or settlement paths, and this pins that.
    function test_RepayRoute_OnAPermissiveMinDebt_StaysCoveredWithNoDustWindow() public {
        Fx memory f = _deploy(8, 18, 1e18, 1e5);
        uint256 loanId = _open(f, 1e18, 8e9);

        _repayTo(f, loanId, 64e9);
        assertGt(f.read.loan(loanId).debt, f.ace.idToMarketParams(f.id).minDebt, "fixture: this debt is legal, not dust");
        assertEq(_liveTicks(f, loanId), 1, "fixture: the partial repay left the loan ONE live claim, which is all it ever holds");

        uint256 line = _withdrawToTheLine(f, loanId);
        assertLe(_need(f, loanId), line, "a repaid loan on the withdrawal gate's line must still cover settlement");
    }

    /* ============================ the control ============================ */

    /// @notice THE CONTROL, and it must PASS: the same sequence on an 18-dec collateral / 6-dec quote pair.
    /// @dev `unitScale` is 1e30 there against tick prices near 1e18, so `omega ~ 1e-12` and one collateral
    /// @dev wei buys almost no quote. The per-tick ceilings are then negligible beside the `k` margin.
    /// @dev Its job is to show the failure above is the DECIMAL/PRICE regime and not the fixture's plumbing.
    function test_Control_WideUnitScale_StaysCoveredOnTheSameSequence() public {
        Fx memory f = _deploy(18, 6, 1e6, 10e6);
        uint256 loanId = _open(f, 1e6, 8e19);
        assertEq(f.read.claimCount(f.id, loanId), 1, "fixture: the draw funded, and a draw funds exactly one claim");

        _repayTo(f, loanId, 32_000); // the same dust posture, scaled to a 6-dec quote
        assertEq(_liveTicks(f, loanId), 1, "fixture: the loan keeps its ONE live claim");

        uint256 line = _withdrawToTheLine(f, loanId);
        assertLe(_need(f, loanId), line, "the wide-unitScale pair keeps its margin at the line");
    }
}
