// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BookedQuote} from "../utils/BookedQuote.sol";
import {AceAskDecimalsHandler} from "./AceAskDecimalsHandler.sol";

/// @title AceAskDecimalsInvariants
/// @notice THE ASK'S FIRING REGIMES, WALKED: three markets the standing campaign never prices, with fills, settles and redemptions between buys.
/// @notice a. Solvency, as an EQUALITY: the hub's quote is exactly what its books say, summed by the shared `BookedQuote`.
/// @notice b. No buy charges for a leg that delivered nothing, or past its budget.
/// @notice c. Every buy moves the hub, the lender's pool, the pot and the buyer by exactly the charge and the units it reports.
/// @notice d. Every charge is the ask value of what left, ceiled, plus its fee, ceiled: `g + ceil(g * fee / 1e4)`.
/// @notice e. The three markets' resting cash IS the lender's resting pool: the pin `BookedQuote` relies on to count cash once.
/// @notice f. No buy reverts outside the hub's named refusals: an overcharge past what the buyer holds fails the pull and lands here.
/// @dev b-d and f are measured inside each buy and latched on the handler; this suite asserts the latches stay down.
/// @dev The handler's constructor lands one zero-deliver buy and one filling buy per market before the snapshot, or setUp fails.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false.
contract AceAskDecimalsInvariantsTest is StdInvariant, Test {
    AceAskDecimalsHandler internal handler;

    function setUp() public {
        handler = new AceAskDecimalsHandler();
        bytes4[] memory sel = new bytes4[](12);
        sel[0] = AceAskDecimalsHandler.deposit.selector;
        sel[1] = AceAskDecimalsHandler.open.selector;
        sel[2] = AceAskDecimalsHandler.open.selector;
        sel[3] = AceAskDecimalsHandler.warp.selector;
        sel[4] = AceAskDecimalsHandler.forceClose.selector;
        sel[5] = AceAskDecimalsHandler.forceClose.selector;
        sel[6] = AceAskDecimalsHandler.repay.selector;
        sel[7] = AceAskDecimalsHandler.collect.selector;
        sel[8] = AceAskDecimalsHandler.redeemInKind.selector;
        /// @dev The subject is weighted up: a third of the walk is buys.
        sel[9] = AceAskDecimalsHandler.buy.selector;
        sel[10] = AceAskDecimalsHandler.buy.selector;
        sel[11] = AceAskDecimalsHandler.buy.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Every property, on ONE walk.
    /// @dev Named apart from `invariant_all`, so `--match-test` names this campaign alone.
    function invariant_askDecimalsAll() public view {
        _invariant_aSolvency();
        _invariant_bNoChargeWithoutDeliveryOrPastBudget();
        _invariant_cEveryBuyMovesWhatItReports();
        _invariant_dTheChargeLaw();
        _invariant_eCashIsTheRestingPool();
        _invariant_fNoUnexpectedBuyRefusal();
    }

    /// @notice a. One quote token, three markets, one lender: the pool's credit is counted once, never once per market.
    function _invariant_aSolvency() internal view {
        address[] memory lenders = new address[](1);
        lenders[0] = handler.lender();
        assertEq(
            handler.usdc().balanceOf(address(handler.ace())),
            BookedQuote.total(handler.ace(), handler.read(), handler.markets(), lenders, address(handler.usdc())),
            "a: hub balance != market pots + feeEscrows + pooled credit (or something donated quote)"
        );
    }

    function _invariant_bNoChargeWithoutDeliveryOrPastBudget() internal view {
        _logBreach();
        assertFalse(handler.bookedWithoutDelivery(), "b: a buy charged quote for a leg that delivered no units");
        assertFalse(handler.chargedPastBudget(), "b: a buy charged more than the caller's budget");
    }

    function _invariant_cEveryBuyMovesWhatItReports() internal view {
        assertFalse(handler.hubDeltaMismatch(), "c: the hub's quote moved by other than the charge");
        assertFalse(handler.poolDeltaMismatch(), "c: the lender's pool credit moved by other than the charge");
        assertFalse(handler.potDeltaMismatch(), "c: the pot fell by other than the units delivered");
        assertFalse(handler.deliveryMismatch(), "c: the buyer received other than the units reported");
    }

    function _invariant_dTheChargeLaw() internal view {
        assertFalse(handler.chargeLawBroken(), "d: a charge was not the ceiled ask value of what left plus its ceiled fee");
    }

    /// @notice e. `BookedQuote` counts market `cash` and leaves `pools.resting` out, which is sound only while the two are one sum.
    /// @dev The same law as `AceInvariants._invariant_cashIsTheRestingPool`, here over three markets sharing one lender's pool.
    function _invariant_eCashIsTheRestingPool() internal view {
        bytes32[] memory m = handler.markets();
        uint256 marketSide;
        for (uint256 i; i < m.length; i++) {
            marketSide += handler.read().marketState(m[i]).cash;
        }
        (uint256 poolSide,,) = handler.read().lenderPools(handler.lender(), address(handler.usdc()));
        assertEq(marketSide, poolSide, "e: the markets' resting cash and the lender's resting pool disagree");
    }

    /// @notice f. Under `fail_on_revert = false` a reverted buy is otherwise silent, so an overcharge the buyer cannot fund would read as a refusal.
    function _invariant_fNoUnexpectedBuyRefusal() internal view {
        if (handler.unexpectedBuyRefusal()) console2.logBytes4(handler.unexpectedRefusalSelector());
        assertFalse(handler.unexpectedBuyRefusal(), "f: a buy reverted outside the hub's named refusals");
    }

    function _logBreach() internal view {
        if (!handler.anyBreach()) return;
        console2.log("BREACH loan / budget", handler.breachLoan(), handler.breachBudget());
        console2.log("       units / charge", handler.breachUnits(), handler.breachCharge());
    }

    /// @notice The campaign report. Read the SUCCESS ghosts: a selector hit says nothing about whether its channel landed.
    function afterInvariant() public view {
        console2.log("=== AceAskDecimalsHandler verb hits ===");
        console2.log("buy calls             ", handler.callCount("buy"));
        console2.log("  landed              ", handler.buysLanded());
        console2.log("  refused, expected   ", handler.buysRefused());
        console2.log("  refused, unexpected ", handler.buysRefusedUnexpected());
        console2.log("  zero-deliver window ", handler.zeroDeliverInWindow());
        console2.log("  fills               ", handler.fillsLanded());
        console2.log("  fills, fee remainder", handler.fillsWithFeeRemainder());
        console2.log("  fills M0 / M1 / M2  ", handler.fillsPerMarket(0), handler.fillsPerMarket(1), handler.fillsPerMarket(2));
        console2.log("open calls / landed   ", handler.callCount("open"), handler.opensLanded());
        console2.log("forceClose calls      ", handler.callCount("forceClose"));
        console2.log("  settles landed      ", handler.settlesLanded());
        console2.log("repay calls           ", handler.callCount("repay"));
        console2.log("  landed / refused    ", handler.repaysLanded(), handler.repaysRefused());
        console2.log("redeems landed        ", handler.redeemsLanded());
        console2.log("collects that paid    ", handler.collectsLanded());
    }
}
