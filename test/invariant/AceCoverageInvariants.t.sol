// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Loan} from "../../src/ace/hub/Types.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AceCoverageHandler} from "./AceCoverageHandler.sol";

/// @title AceCoverageInvariants
/// @notice TWO properties, in the decimal regime where they can actually fail: coverage, and no loss at settlement.
/// @notice Settlement asks each funded tick for `ceil(claim_t x unitScale / price_t)` and the loan must hold the sum.
/// @dev The sibling leg in `AceInvariants` states the same thing over the 6-dec-quote harness, where it cannot bite.
/// @dev That harness's `unitScale` is 1e30 against tick prices near 1e18, so a per-tick ceiling is negligible dust.
/// @dev Here it is 1e8, one collateral wei buys ~1e10 of quote, and the whole coverage margin can be a few wei.
/// @dev `AceLens` is the oracle for both quantities: this file keeps no arithmetic of its own to drift.
/// @dev THIS SUITE PINS ZERO, ON EVERY LOAN: no bound and no per-loan carve-out.
/// @dev The withdrawal gate covers every verb but a SALE, and `LoanAccounting.securedBase` covers the sale.
/// @dev It reserves `collateralNeeded + sliverUnits`, so no crank can take an atom settlement is going to need.
/// @dev Never re-introduce a BOUND here: one bound cannot tell a gate defect from a sale residue, since both are a tick cap wide.
/// @dev `erodedOnTheLine` is a REACH counter -- a campaign that never sold from a loan on its line has proved nothing.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false.
contract AceCoverageInvariantsTest is StdInvariant, Test {
    AceCoverageHandler internal handler;
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    bytes32 internal mid;

    function setUp() public {
        handler = new AceCoverageHandler();
        handler.baselineDisposal(); // pre-snapshot, but it needs the handler's own code deployed to be called back
        ace = handler.ace();
        read = handler.read();
        lens = handler.lens();
        mid = handler.id();

        bytes4[] memory sel = new bytes4[](12);
        sel[0] = AceCoverageHandler.deposit.selector;
        sel[1] = AceCoverageHandler.open.selector;
        sel[2] = AceCoverageHandler.repay.selector;
        /// @dev Without this the debt never reaches the decades the coverage margin is thin in.
        sel[3] = AceCoverageHandler.repayToDust.selector;
        sel[4] = AceCoverageHandler.withdrawCollateral.selector;
        /// @dev Without this NOTHING lands on the withdrawal line, and the invariant only sees loose loans.
        sel[5] = AceCoverageHandler.withdrawCollateralMax.selector;
        sel[6] = AceCoverageHandler.setRate.selector;
        sel[7] = AceCoverageHandler.deleverage.selector;
        sel[8] = AceCoverageHandler.enterBand.selector;
        sel[9] = AceCoverageHandler.heal.selector;
        sel[10] = AceCoverageHandler.forceClose.selector;
        /// @dev The erosion probe: a sale out from under a loan already standing on its line.
        /// @dev Without it that state is a four-action lottery inside one depth window, and goes unvisited.
        sel[11] = AceCoverageHandler.withdrawToLineThenDeleverage.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Both coverage properties below, checked on ONE walk instead of one campaign each.
    /// @dev The leading underscore de-registers a property from forge's `invariant` prefix, name intact for grep.
    /// @dev THE COST: the first failure aborts the other, so a red run names ONE break, not both.
    function invariant_all() public view {
        _invariant_collateralCoversEveryLiveClaim();
        _invariant_noSettlementRealizesALoss();
    }

    /// @notice THE PROPERTY: every OPEN loan holds its own live claims, EXACTLY, with no bound and no carve-out.
    /// @notice The gate covers every verb but a sale, and the sale's own reserve covers the sale.
    /// @dev ONE assertion over every open loan: the state split this carried was DELETED, never merged into a bound.
    /// @dev TEETH ON THE GATE: revert `Ace.withdrawCollateral` to gate on `requiredAt` and this fails on the line withdrawal.
    /// @dev TEETH ON THE SALE: drop `securedBase`'s keep term and this fails on the deleverage.
    function _invariant_collateralCoversEveryLiveClaim() public view {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < ids.length; i++) {
            Loan memory l = read.loan(ids[i]);
            if (l.closedAt != 0) continue;
            assertLe(lens.collateralNeeded(mid, ids[i]), l.collateralUnits, "coverage: a live loan cannot fill its own claims");
        }
    }

    /// @notice THE CONSEQUENCE, read off the hub rather than off a view: NO settlement here realizes any loss.
    /// @notice No loan in this fixture is ever liquidated, so a settled one that is short was thinned, not distressed.
    /// @dev `shortfallOf` is what `_settle` itself wrote, so it survives any drift in the lens above.
    /// @dev It is the leg that would still be right if `collateralNeeded` were the thing that was wrong.
    /// @dev Held to ZERO on every settled loan: the sale reserves what settlement needs, so nothing takes the gate's slack.
    function _invariant_noSettlementRealizesALoss() public view {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < ids.length; i++) {
            if (read.loan(ids[i]).closedAt == 0) continue;
            (uint256 short,) = read.shortfallOf(ids[i]);
            assertEq(short, 0, "coverage: a settled loan realized a loss");
        }
    }

    /// @notice The campaign report: which channels this run actually reached.
    /// @dev A pass over loans that never melted, never sat on the line and never eroded proves nothing.
    /// @dev Reported rather than asserted: foundry reverts handler ghosts between runs.
    /// @dev So a hard assertion here measures one depth-long sequence and is a lottery, not a guard.
    /// @dev The channels themselves are guarded structurally, by the handler's own constructor requires.
    function afterInvariant() public view {
        console2.log("=== AceCoverageHandler verb hits (LAST sequence only) ==="); // the heading `make tallies` finds the block by
        console2.log("deleverage calls      ", handler.callCount("deleverage"));
        console2.log("probe calls           ", handler.callCount("withdrawToLineThenDeleverage"));
        console2.log("cranks attempted      ", handler.cranksAttempted());
        console2.log("cranks landed         ", handler.cranksLanded());
        console2.log("loans opened          ", handler.loansOpened());
        console2.log("dust repays           ", handler.dustRepays());
        console2.log("line withdrawals      ", handler.lineWithdrawals());
        console2.log("deleverages that sold ", handler.deleveragesDone());
        console2.log("erosion on the line   ", handler.erodedOnTheLine());
        console2.log("settlements           ", handler.settlements());
    }
}
