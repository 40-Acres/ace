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
/// @notice `Borrower.requiredAt` takes ONE ceiling over `k` times the whole debt: admissibility.
/// @notice `LoanAccounting.collateralNeeded` takes ONE ceiling over the loan's one claim, and governs `_settle`.
/// @notice `Borrower.coverageLine` gates `withdrawCollateral`: `requiredAt` plus one atom of margin.
/// @dev Write `omega = price / unitScale`, the QUOTE WEI one COLLATERAL WEI buys at the market's price.
/// @dev Then the gate leaves `k * debt / omega` and settlement asks `ceil(claim / omega)`.
/// @dev The old violation condition was `n_eff > (k - 1) * debt / omega`: the margin, in COLLATERAL WEI, under the funded tick count.
/// @dev It needed BOTH dust debt and a large `omega`; with one claim no violation is left, since `ceil(k X) >= ceil(X)` at every debt.
/// @dev `omega = human_price * 10 ** (quoteDec - collDec)`, so an 8-dec collateral against an 18-dec
/// @dev quote gives `omega ~ 1e10` at a price near 1, and WBTC/USDC at $60k gives `omega ~ 600`.
/// @dev The doctrinal claim under test: "withdrawing to the line does not thin it, because at the line `units = k x need` exactly".
/// @dev That identity is real-arithmetic; `need` is an integer ceiling and is not `debt * S / floor`.
/// @dev DUST DEBT IS REACHABLE ONLY UNDER A PERMISSIVE `minPrincipal`: no repay leaves a live loan under its market's floor.
/// @dev `minPrincipal` is creator-chosen and bounded only by `originationFee(minPrincipal) < minPrincipal`, so a tiny floor is legal.
/// @dev So every row repays to its debt with one public verb, on a market whose floor admits that debt.
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

    uint256 internal constant TICKS = 32; // the retired maxClaimTicks, kept as the seed's lot count
    int24 internal constant SPACING = 60;
    uint256 internal constant K = 1.4e18; // PocDeployConfig.MIN_COVERAGE_WAD, the shipped coverage multiple

    function setUp() public {
        vm.warp(1_000_000);
    }

    /* ============================ the fixture ============================ */

    /// @dev A market whose collateral and quote decimals are the caller's, funded with 32 lots' worth of cash.
    function _deploy(uint8 collDec, uint8 quoteDec, uint256 perTick, uint256 minPrincipal) internal returns (Fx memory f) {
        f.quote = new MockERC20("Quote", "Q", quoteDec);
        f.coll = new MockERC20("Collateral", "C", collDec);
        MockPersistenceRecord record = new MockPersistenceRecord(address(f.quote), address(f.coll));

        MarketParams memory p = AceFixtures.marketParams(address(f.quote), address(f.coll));
        p.record = address(record);
        p.minPrincipal = minPrincipal;

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (f.ace, f.pm, f.read, f.id) = (d.ace, d.positionManager, d.read, d.id);
        f.lens = new AceLens(address(d.ace)); // the shipped views are the oracle; the test keeps no mirror
        f.unitScale = f.read.marketState(f.id).unitScale;

        /// @dev THE TOTAL IS KEPT AND THE PER-RUNG LEG IS GONE: `perTick` sits under the deposit floor, which
        /// @dev is `minPrincipal` itself now rather than the fraction `ceil(minPrincipal / maxClaimTicks)` used to be.
        uint256 total = perTick * TICKS;
        f.quote.mint(alice, total);
        vm.startPrank(alice);
        f.quote.approve(address(f.ace), total);
        f.ace.deposit(f.id, total);
        vm.stopPrank();
    }

    /// @dev DELETED: `_price(par, i)`, the i-th funding tick descending from par so a draw spanned the seeded
    /// @dev band. A market bids at one price, so there is no band to descend and no i to index.

    /// @dev Opens the loan that draws the whole seed: the principal is exactly the seeded cash.
    function _open(Fx memory f, uint256 perTick, uint256 units) internal returns (uint256 loanId) {
        f.coll.mint(borrower, units);
        vm.startPrank(borrower);
        f.coll.approve(address(f.pm), units);
        loanId = f.ace.open(f.id, units, perTick * TICKS, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Walks the debt down to `target` with a plain `repay`; the target must sit at or over the market's `minPrincipal`.
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
    /// @dev IT IS ONE OR ZERO NOW. The coverage line once carried one atom per funded tick; its one atom now is margin.
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

    /// @dev DELETED: `test_WithdrawToTheLine_OnDustDebt_LeavesTheLoanCoveredAtSettlement`, which repaid under a 10e18 floor.
    /// @dev Its sibling `test_RepayRoute_OnAPermissiveMinDebt_StaysCoveredWithNoDustWindow` runs the same quantities at a legal debt.

    /// @notice The same sequence read off the CONTRACT, with no mirrored arithmetic anywhere.
    /// @notice A loan withdrawn only to the line, then force-closed at tenor, must record no bad debt.
    /// @dev The lens is only a MIRROR of the hub's own sum, so this asserts on `shortfallOf`, which `_settle` writes.
    /// @dev It is the ground truth for the sibling below: if the mirror were wrong, this would still be right.
    function test_ForceClose_AfterWithdrawingToTheLine_RecordsNoShortfall() public {
        Fx memory f = _deploy(8, 18, 1e18, 1e5); // a floor that admits the 64e9 debt
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

    /// @notice THE PROPERTY: a loan withdrawn to the gate's own line still covers every claim it created.
    /// @notice On an 8-dec collateral against an 18-dec quote, at a debt whose `minPrincipal` admits it, so it is legal, not dust.
    /// @dev `minPrincipal` is creator-chosen and bounded only by `originationFee(minPrincipal) < minPrincipal`, so 1e5
    /// @dev wei of an 18-dec quote is a legal floor. Unusual, but a permissionless creator may pick it.
    /// @dev No `src` site reads `minPrincipal` on the gate or settlement paths; the repay reads it only to admit the debt.
    function test_RepayRoute_OnAPermissiveMinDebt_StaysCoveredWithNoDustWindow() public {
        Fx memory f = _deploy(8, 18, 1e18, 1e5);
        uint256 loanId = _open(f, 1e18, 8e9);

        _repayTo(f, loanId, 64e9);
        assertGt(f.read.loan(loanId).debt, f.ace.idToMarketParams(f.id).minPrincipal, "fixture: this debt is legal, not dust");
        assertEq(_liveTicks(f, loanId), 1, "fixture: the partial repay left the loan ONE live claim, which is all it ever holds");

        uint256 line = _withdrawToTheLine(f, loanId);
        assertLe(_need(f, loanId), line, "a repaid loan on the withdrawal gate's line must still cover settlement");
    }

    /* ============================ the control ============================ */

    /// @notice THE CONTROL, and it must PASS: the same sequence on an 18-dec collateral / 6-dec quote pair.
    /// @dev There one collateral wei buys ~1e-12 of quote, so the need's one ceiling is negligible beside the `k` margin.
    /// @dev Its job is to show the failure above is the DECIMAL/PRICE regime and not the fixture's plumbing.
    function test_Control_WideUnitScale_StaysCoveredOnTheSameSequence() public {
        Fx memory f = _deploy(18, 6, 1e6, 1e4); // a floor that admits the 32_000 debt
        uint256 loanId = _open(f, 1e6, 8e19);
        assertEq(f.read.claimCount(f.id, loanId), 1, "fixture: the draw funded, and a draw funds exactly one claim");

        _repayTo(f, loanId, 32_000); // the same dust posture, scaled to a 6-dec quote
        assertEq(_liveTicks(f, loanId), 1, "fixture: the loan keeps its ONE live claim");

        uint256 line = _withdrawToTheLine(f, loanId);
        assertLe(_need(f, loanId), line, "the wide-unitScale pair keeps its margin at the line");
    }
}
