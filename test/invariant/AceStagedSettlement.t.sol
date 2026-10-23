// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Loan, MarketState} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceReader} from "../utils/AceReader.sol";
import {BookedQuote} from "../utils/BookedQuote.sol";
import {AceStagedSettlementHandler} from "./AceStagedSettlementHandler.sol";

/// @title AceStagedSettlementTest
/// @notice QUARANTINED: the settlement-loss branch and the recordless forfeit, which `AceInvariants` never reaches.
/// @notice The short branch is STAGED by `AceStagedSettlementHandler.stageShortEscrow`; read its header for why that is honest.
/// @dev A SECOND CAMPAIGN ON PURPOSE. The main suite drives real verbs only and must stay that way, so the staging lives here.
/// @dev NOT ASSERTED HERE, deliberately: that every live loan covers its claim. The staging exists to break exactly that.
/// @dev Everything else the hub promises is asserted, so the short branch is checked by the same laws as every other close.
/// @dev No loan here ever goes underwater by itself: the premium is fixed, so this suite is the ONLY coverage of the branch.
contract AceStagedSettlementTest is StdInvariant, Test {
    AceStagedSettlementHandler internal handler;
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;

    function setUp() public {
        handler = new AceStagedSettlementHandler();
        (ace, read, lens, pm) = (handler.ace(), handler.read(), handler.lens(), handler.pm());
        (usdc, vault) = (handler.usdc(), handler.vault());

        bytes4[] memory sel = new bytes4[](20);
        sel[0] = AceStagedSettlementHandler.deposit.selector;
        sel[1] = AceStagedSettlementHandler.withdraw.selector;
        sel[2] = AceStagedSettlementHandler.collect.selector;
        sel[3] = AceStagedSettlementHandler.open.selector;
        sel[4] = AceStagedSettlementHandler.repay.selector;
        sel[5] = AceStagedSettlementHandler.armPolicy.selector;
        sel[6] = AceStagedSettlementHandler.claimOwed.selector;
        sel[7] = AceStagedSettlementHandler.redeemInKind.selector;
        sel[8] = AceStagedSettlementHandler.buyInventory.selector;
        sel[9] = AceStagedSettlementHandler.warp.selector;
        sel[10] = AceStagedSettlementHandler.stageShortEscrow.selector;
        sel[11] = AceStagedSettlementHandler.crash.selector;
        sel[12] = AceStagedSettlementHandler.heal.selector;
        sel[13] = AceStagedSettlementHandler.finalize.selector;
        sel[14] = AceStagedSettlementHandler.forceClose.selector;
        sel[15] = AceStagedSettlementHandler.settleExpired.selector;
        sel[16] = AceStagedSettlementHandler.stageShortEscrow.selector; // twice: the staging is the subject, so it draws double
        sel[17] = AceStagedSettlementHandler.open.selector; // twice: every settle door needs a live loan to land on
        sel[18] = AceStagedSettlementHandler.stageThenSettle.selector;
        sel[19] = AceStagedSettlementHandler.stageThenSettle.selector; // twice: at one draw in 19, a sequence missed it 1 time in 3
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Every property, one walk per step.
    function invariant_all() public view {
        _invariant_settleChecksHold();
        _invariant_stagingLandsAsWritten();
        _invariant_solvency();
        _invariant_lr9();
        _invariant_lentIsTheClaimBook();
        _invariant_cashIsTheRestingPool();
        _invariant_claimIsDebt();
        _invariant_lossTotalIsTheRecords();
        _invariant_custodyIdentity();
        _invariant_zeroCollateralMeansZeroClaim();
        _invariant_quoteOwedIsItsEntries();
    }

    /// @notice A market's booked quote credit is exactly the sum of its loans' per-claimant entries.
    /// @dev Solvency books the AGGREGATE, so an entry that never landed beside it is quote owed to nobody and still balances.
    function _invariant_quoteOwedIsItsEntries() public view {
        address[5] memory who = handler.claimants();
        bytes32[] memory ms = _markets();
        for (uint256 i; i < ms.length; i++) {
            uint256[] memory ids = ace.marketLoans(ms[i], 0, ace.marketLoansLength(ms[i]));
            uint256 entries;
            for (uint256 k; k < ids.length; k++) {
                for (uint256 a; a < who.length; a++) {
                    entries += read.quoteOwedOf(ids[k], who[a]);
                }
            }
            assertEq(read.marketState(ms[i]).quoteOwedTotal, entries, "quote credit: the market total != its loans' claimant entries");
        }
    }

    // ---- the settle-time laws, latched by the handler around every settle ----

    /// @notice A settle conserves the lot, retires the claim, and records exactly what the claim did not get.
    /// @dev Codes are the handler's: 1 units, 2 claim, 3 lent, 4 record, 5 loss total, 6 defaulted borrower paid, 7-8 backstop, 9 arming.
    function _invariant_settleChecksHold() public view {
        if (handler.settleCode() != 0) {
            console2.log("settle code", handler.settleCode());
            console2.log("loan", handler.settleLoanId());
            console2.log("expected", handler.settleExpected());
            console2.log("actual", handler.settleActual());
        }
        assertEq(handler.settleCode(), 0, "SETTLE: a settlement's ledgers disagree with the settle it was");
    }

    /// @notice The staging wrote the hub word and the custodian moved with it, every time.
    function _invariant_stagingLandsAsWritten() public view {
        assertFalse(handler.stagingMisaimed(), "STAGING: a staged loan's units did not read back as written");
    }

    // ---- the laws every close is held to, short ones included ----

    function _markets() internal view returns (bytes32[] memory m) {
        m = new bytes32[](2);
        (m[0], m[1]) = (handler.recId(), handler.norecId());
    }

    function _lenders() internal view returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = (handler.recLender(), handler.norecLender());
    }

    /// @notice A short settle moves no quote, so the hub's balance is still exactly what its books say.
    function _invariant_solvency() public view {
        assertEq(usdc.balanceOf(address(ace)), BookedQuote.total(ace, read, _markets(), _lenders(), address(usdc)), "solvency: balance != booked quote");
    }

    /// @notice Backed burns net of outflow equal what the pots hold, per market: a short pot is credited by what it got.
    function _invariant_lr9() public view {
        bytes32[] memory ms = _markets();
        for (uint256 i; i < ms.length; i++) {
            MarketState memory s = read.marketState(ms[i]);
            uint256[] memory ids = ace.marketLoans(ms[i], 0, ace.marketLoansLength(ms[i]));
            uint256 pots;
            for (uint256 k; k < ids.length; k++) {
                pots += read.invPotOf(ms[i], ids[k]);
            }
            assertEq(s.cumulativeBackedBurns - s.netSyntheticOutflow, pots, "LR-9: backed burns net of outflow != the pots");
            assertEq(lens.headroom(ms[i]), pots, "LR-9: the lens headroom != the pots");
        }
    }

    /// @notice Each lender's `lent` is exactly its market's live claims: a short settle retires the WHOLE claim.
    function _invariant_lentIsTheClaimBook() public view {
        bytes32[] memory ms = _markets();
        for (uint256 i; i < ms.length; i++) {
            uint256[] memory ids = ace.marketLoans(ms[i], 0, ace.marketLoansLength(ms[i]));
            uint256 claims;
            for (uint256 k; k < ids.length; k++) {
                claims += read.claimOf(ms[i], ids[k]);
            }
            (, uint256 lent,) = read.lenderPools(ace.idToMarketParams(ms[i]).lender, address(usdc));
            assertEq(lent, claims, "pool: lent != the market's live claims");
        }
    }

    function _invariant_cashIsTheRestingPool() public view {
        bytes32[] memory ms = _markets();
        for (uint256 i; i < ms.length; i++) {
            (uint256 resting,,) = read.lenderPools(ace.idToMarketParams(ms[i]).lender, address(usdc));
            assertEq(read.marketState(ms[i]).cash, resting, "pool: market cash != the lender's resting pool");
        }
    }

    /// @notice An open loan's claim is its debt; a closed loan carries none, however short its settle came up.
    function _invariant_claimIsDebt() public view {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            Loan memory l = read.loan(id);
            uint256 claim = read.claimOf(l.market, id);
            if (l.closedAt != 0) assertEq(claim, 0, "claim: a closed loan still carries one");
            else assertEq(claim, l.debt, "claim: an open loan's claim is not its debt");
        }
    }

    /// @notice A market's realized loss is the sum of its loans' shortfall records, and nothing else ever writes it.
    function _invariant_lossTotalIsTheRecords() public view {
        bytes32[] memory ms = _markets();
        for (uint256 i; i < ms.length; i++) {
            uint256[] memory ids = ace.marketLoans(ms[i], 0, ace.marketLoansLength(ms[i]));
            uint256 sum;
            for (uint256 k; k < ids.length; k++) {
                (, uint256 q) = read.shortfallOf(ids[k]);
                sum += q;
            }
            assertEq(read.marketState(ms[i]).realizedLossAtBook, sum, "loss: the market total != its loans' shortfall records");
        }
    }

    /// @notice The custodian's ledgers against the hub's, per loan and per pot: what makes the staging checkable.
    /// @dev Live units match the hub word; retired units are the pot plus every claimant's credit; the pot is backed.
    function _invariant_custodyIdentity() public view {
        uint256 n = read.loanCount();
        address[5] memory who = handler.claimants();
        uint256 owed;
        for (uint256 id = 1; id <= n; id++) {
            Loan memory l = read.loan(id);
            assertEq(pm.collateralOf(id), l.closedAt == 0 ? l.collateralUnits : 0, "custody: live units != the hub's word");
            uint256 credited = read.invPotOf(l.market, id);
            for (uint256 a; a < who.length; a++) {
                credited += read.unitsOwedOf(id, who[a]);
            }
            assertEq(pm.retiredOf(id), credited, "custody: retired units != the pot plus every claimant's credit");
            owed += pm.collateralOf(id) + pm.retiredOf(id);
        }
        assertEq(pm.custodiedOf(address(vault)), owed, "custody: the pot's ledger != the sum of every loan's");
        assertGe(vault.balanceOf(address(pm)), owed, "custody: the pot holds less than its ledger owes");
    }

    /// @notice The staging leaves at least one unit, as `withdrawCollateral` does, so no live loan holds nothing.
    function _invariant_zeroCollateralMeansZeroClaim() public view {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            Loan memory l = read.loan(id);
            if (l.closedAt != 0 || l.collateralUnits != 0) continue;
            assertEq(read.claimOf(l.market, id), 0, "a live loan holding no collateral still carries a claim");
        }
    }

    // ---- deterministic coverage: each branch landed in setUp, and is re-driven here with its outcome measured ----

    /// @notice The baseline left a short record on the recorded market and a forfeit on the recordless one.
    function test_Coverage_TheBaselineLandedEveryBranch() public view {
        assertGt(handler.settlesShort(0), 0, "no short finalize");
        assertGt(handler.settlesShort(1), 0, "no short expiry fold");
        assertGt(handler.settlesShort(2), 0, "no short settleExpired");
        assertGt(handler.forfeits(), 0, "no recordless forfeit");
        assertGt(read.marketState(handler.recId()).realizedLossAtBook, 0, "the short settles recorded no loss at book");
        assertGt(handler.stagedOneAtom(), 0, "no staging landed on the quantization edge");
    }

    /// @notice A fuzz-reached short settle measured end to end: stage, settle, and the record is what the laws say.
    function test_Coverage_AStagedShortFinalizeKeepsEveryLaw() public {
        handler.open(1, 0, 3_000e6, 15_000);
        uint256[] memory ids = handler.loanIds();
        uint256 id = ids[ids.length - 1];
        uint256 lossBefore = read.marketState(handler.recId()).realizedLossAtBook;
        handler.stageShortEscrow(ids.length - 1, 3);
        handler.crash(ids.length - 1);
        handler.finalize(ids.length - 1);
        assertTrue(ace.isClosed(id), "PREMISE: the staged loan settled");
        (uint256 su,) = read.shortfallOf(id);
        assertGt(su, 0, "the staged settle came up short");
        assertGt(read.marketState(handler.recId()).realizedLossAtBook, lossBefore, "and the market's loss total moved");
        invariant_all();
    }

    /// @dev The compound action lands a short settle through each door it names, on a loan it has just staged.
    function test_Coverage_StageThenSettleLandsShortThroughEveryDoor() public {
        for (uint256 door; door < 3; door++) {
            handler.open(1, door, 3_000e6, 15_000);
            uint256[] memory ids = handler.loanIds();
            uint256 id = ids[ids.length - 1];
            uint256 before = handler.settlesShort(door);
            handler.stageThenSettle(ids.length - 1, 3, door);
            assertTrue(ace.isClosed(id), "PREMISE: the staged loan settled");
            assertEq(handler.settlesShort(door), before + 1, "the door settled the staged loan short");
            assertEq(handler.settleCode(), 0, "and the settle kept every law");
        }
        invariant_all();
    }

    // ---- the run report ----

    function afterInvariant() public view {
        console2.log("=== AceStagedSettlementHandler verb hits (LAST sequence only) ===");
        string[17] memory tags = [
            "deposit",
            "withdraw",
            "collect",
            "open",
            "repay",
            "armPolicy",
            "claimOwed",
            "redeemInKind",
            "buyInventory",
            "warp",
            "stageShortEscrow",
            "crash",
            "heal",
            "finalize",
            "forceClose",
            "settleExpired",
            "stageThenSettle"
        ];
        for (uint256 i; i < tags.length; i++) {
            console2.log(tags[i], handler.callCount(tags[i]));
        }
        console2.log("staged short          ", handler.stagedShort());
        console2.log("  on the atom edge    ", handler.stagedOneAtom());
        console2.log("short  fin/fold/unpaid", handler.settlesShort(0), handler.settlesShort(1), handler.settlesShort(2));
        uint256 shortAll = handler.settlesShort(0) + handler.settlesShort(1) + handler.settlesShort(2);
        console2.log("  of which the fuzzer's", shortAll - handler.baselineShort());
        console2.log("covered fin/fold/unpaid", handler.settlesCovered(0), handler.settlesCovered(1), handler.settlesCovered(2));
        console2.log("recordless forfeits   ", handler.forfeits());
        console2.log("fold rolls            ", handler.foldRolls());
        console2.log("early backstops refused", handler.earlyRefused());
        /// @dev STRUCTURAL, satisfied in setUp and re-checked here: a red is a broken baseline, never a starved seed.
        assertGt(handler.settlesShort(0) + handler.settlesShort(1) + handler.settlesShort(2), 0, "STRUCTURAL: no short settle survived setUp");
    }
}
