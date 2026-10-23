// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Loan, MarketState} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceReader} from "../utils/AceReader.sol";
import {BookedQuote} from "../utils/BookedQuote.sol";
import {AceGenesisDriveHandler} from "./AceGenesisDriveHandler.sol";

/// @title AceGenesisDrive
/// @notice The safety identities re-asserted over markets the FUZZER created, on params nobody wrote.
/// @notice `AceInvariants` drives four markets built in `setUp`, so its params are ours and always were.
/// @dev THE GAP THIS CLOSES: a creator-chosen `MarketParams` reaching a draw, a settlement and a claim.
/// @dev Market creation is permissionless and every field is the creator's, so the fixture set is a sample of one.
/// @dev It is a SECOND SUITE and not a fifth market slot: the sibling's registry is fixed-size throughout,
/// @dev and a rarely-picked extra market would make its every-market-landed-an-action guard flaky, not false.
/// @dev ONE `invariant_all` per suite, per the consolidation ruling: forge runs a whole campaign per prefix.
/// @dev The cost is that the first failing property aborts the rest, so re-read the whole list after a fix.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false, pinned seed.
contract AceGenesisDriveTest is StdInvariant, Test {
    AceGenesisDriveHandler internal handler;
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens; // the LR-9 headroom leg must read the SRC lens, never the test reader

    uint256 internal constant SEEDS = 24; // param sets the deterministic search may try, one hub each
    uint256 internal _configsTried; // sets that were ADMITTED, so the search's real breadth is a number, not a loop bound

    function setUp() public {
        handler = new AceGenesisDriveHandler();
        ace = handler.ace();
        read = handler.read();
        lens = handler.lens();

        /// @dev WEIGHTED BY REPETITION: forge picks uniformly from this array, so a repeated selector is a weight.
        /// @dev Depth is 32 and the ladder verbs are what carry a sequence into settlement, so they get the weight.
        /// @dev Every verb bootstraps a market when none exists, so `createMarket` needs no privileged position.
        bytes4[] memory sel = new bytes4[](22);
        sel[0] = AceGenesisDriveHandler.createMarket.selector;
        sel[1] = AceGenesisDriveHandler.createMarket.selector;
        sel[2] = AceGenesisDriveHandler.deposit.selector;
        sel[3] = AceGenesisDriveHandler.deposit.selector;
        sel[4] = AceGenesisDriveHandler.deposit.selector;
        sel[5] = AceGenesisDriveHandler.open.selector;
        sel[6] = AceGenesisDriveHandler.open.selector;
        sel[7] = AceGenesisDriveHandler.open.selector;
        sel[8] = AceGenesisDriveHandler.open.selector;
        sel[9] = AceGenesisDriveHandler.repay.selector;
        sel[10] = AceGenesisDriveHandler.repay.selector;
        sel[11] = AceGenesisDriveHandler.withdraw.selector;
        sel[12] = AceGenesisDriveHandler.withdrawCollateral.selector;
        sel[13] = AceGenesisDriveHandler.claimOwed.selector;
        sel[14] = AceGenesisDriveHandler.crashBelow.selector;
        sel[15] = AceGenesisDriveHandler.heal.selector;
        sel[16] = AceGenesisDriveHandler.finalize.selector;
        sel[17] = AceGenesisDriveHandler.forceClose.selector;
        sel[18] = AceGenesisDriveHandler.warp.selector;
        sel[19] = AceGenesisDriveHandler.sweepRevenue.selector;
        /// @dev `materialize` and `claimUnits` are GONE, not renamed: minting a unit and pulling one
        /// @dev class's accrual were both receipt-ledger verbs. `collect` is the single credit door now.
        sel[20] = AceGenesisDriveHandler.collect.selector;
        sel[21] = AceGenesisDriveHandler.redeemInKind.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Every property on ONE walk, per the one-campaign-per-suite ruling.
    function invariant_all() public view {
        _invariant_perTokenSolvency();
        _invariant_everyCreatedMarketIsCoherent();
        _invariant_cashMatchesTheLens();
        _invariant_loanClaimsEqualDebt();
        _invariant_lr9Reconciliation();
        _invariant_unusedQuoteTokenHoldsNothing();
        _invariant_canaryMarketUntouched();
    }

    // ---- 1. Solvency, per quote token, over every market the fuzzer created ----

    /// @notice The hub's balance in each quote is exactly the pots the markets using it book, and no other float.
    /// @notice THE HEADLINE PROPERTY: it is the one a wrong param set breaks without breaking liveness.
    /// @dev The token pools are SHARED, so several fuzz-created markets book into one balance and a
    /// @dev denomination mix between two of them lands here rather than cancelling inside one market.
    /// @dev Deliberately an EQUALITY: an unsolicited donation must fail here, never be absorbed.
    function _invariant_perTokenSolvency() internal view {
        for (uint256 t; t < 3; t++) {
            address tok = address(handler.quoteTokens(t));
            assertEq(
                MockERC20(tok).balanceOf(address(ace)), _bookedQuote(tok), "solvency: hub balance != cash + protocolRevenue + unitOwed + quoteOwed + feeEscrows"
            );
        }
    }

    /// @notice A quote token no created market names holds nothing in the hub.
    /// @dev The zero-state witness for the identity above, and the leg a mis-keyed market write would break.
    function _invariant_unusedQuoteTokenHoldsNothing() internal view {
        for (uint256 t; t < 3; t++) {
            address tok = address(handler.quoteTokens(t));
            if (_marketsUsing(tok) != 0) continue;
            assertEq(MockERC20(tok).balanceOf(address(ace)), 0, "the hub holds a quote no market of its own names");
        }
    }

    /// @notice The ACTIVE isolation witness: a funded market NO action here ever names keeps its seed exactly.
    /// @notice Isolation on this hub is LOGICAL, per market id, and this is the suite whose market set is dynamic.
    /// @dev A creator-chosen registry is the topology most likely to surface a mis-keyed write, and nothing
    /// @dev else here asserts that an action stayed inside the market it named.
    /// @dev SEEDED, so it witnesses both directions: an empty canary can only catch a leak INTO it.
    function _invariant_canaryMarketUntouched() internal view {
        bytes32 m = handler.canaryId();
        MarketState memory s = read.marketState(m);
        assertEq(s.cash, handler.canarySeededCash(), "CANARY: cash moved in a market no action ever named");
        /// @dev `totalLent` and `unitOwed` left `MarketState` for the (lender, quote) pool, which spans
        /// @dev a lender's markets -- so neither is a per-market witness any more. The canary's loan
        /// @dev count below is the sharper statement of the same thing: nothing lent here at all.
        assertEq(s.protocolRevenue + s.quoteOwedTotal, 0, "CANARY: a pot filled in an unaddressed market");
        assertEq(s.cumulativeBackedBurns + s.netSyntheticOutflow, 0, "CANARY: the synthetic ledger moved in an unaddressed market");
        assertEq(ace.marketLoansLength(m), 0, "CANARY: a loan opened in a market no action ever named");
    }

    // ---- 2. The created market is a real market: coherent scale, and an id that commits to its params ----

    /// @notice Genesis derived a unit scale, and the id still re-hashes to the config it resolves to.
    /// @dev `Ace.createMarket` sets `id = keccak256(abi.encode(p))` and `MarketInit` stores `p` verbatim.
    /// @dev That binding is what `idToMarketParams` lets an integrator verify, so a break here is silent elsewhere.
    function _invariant_everyCreatedMarketIsCoherent() internal view {
        assertFalse(handler.genesisIdNotItsParams(), "GENESIS: an id stopped committing to the params it resolves to");
        for (uint256 i; i < handler.marketCount(); i++) {
            bytes32 m = handler.marketAt(i);
            assertGt(read.marketState(m).unitScale, 0, "GENESIS: a created market carries no unit scale");
            assertEq(keccak256(abi.encode(ace.idToMarketParams(m))), m, "GENESIS: a live market's params no longer hash to its id");
        }
    }

    // ---- 3. The aggregate mirrors, the claim ledger and LR-9, restated over the dynamic set ----

    /// @notice Each market's cash equals what the lens reports resting there, and its claims are its own.
    /// @dev THE CACHE-VS-WALK HALF IS GONE: `MarketState.cash` IS the balance, so the two reads are one.
    /// @dev What survives is the CROSS-READ -- the raw slot against the shipped view -- plus the claim
    /// @dev book, which no longer has a per-market `totalLent` to check against and is asserted against
    /// @dev the pool by `AceInvariants._invariant_lentIsTheClaimBook` at the granularity it lives at.
    function _invariant_cashMatchesTheLens() internal view {
        for (uint256 i; i < handler.marketCount(); i++) {
            bytes32 m = handler.marketAt(i);
            assertEq(read.marketState(m).cash, _walkCash(i), "the cash slot and the resting view disagree");
        }
    }

    /// @notice An open loan's claim IS its debt exactly; a closed loan carries none.
    /// @dev Claims are keyed (market, loan), so each loan is asked of its own market and never of the first.
    /// @dev NO SUM: a loan holds ONE claim word, so "sums to" became "equals" and the walk went with it.
    function _invariant_loanClaimsEqualDebt() internal view {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < ids.length; i++) {
            Loan memory l = read.loan(ids[i]);
            uint256 claim = read.claimOf(ace.loanMarket(ids[i]), ids[i]);
            if (l.closedAt != 0) assertEq(claim, 0, "a closed loan still carries a live claim");
            else assertEq(claim, l.debt, "an open loan's claim is not its debt");
        }
    }

    /// @notice Backed burns not yet delivered equal total inventory, and the lens advertises exactly that.
    /// @dev The synthetic cap's own identity, and the one a settlement on odd decimals is most likely to bend.
    /// @dev THE SECOND LEG READS `AceLens`, never `AceReader`: the reader recomputes the first leg's own expression.
    /// @dev Asserted against that reader the leg could not fail for any `src` edit at all.
    function _invariant_lr9Reconciliation() internal view {
        for (uint256 i; i < handler.marketCount(); i++) {
            bytes32 m = handler.marketAt(i);
            MarketState memory s = read.marketState(m);
            uint256 inv = _sumInventory(i);
            assertEq(s.cumulativeBackedBurns - s.netSyntheticOutflow, inv, "LR-9: backed burns net of outflow != sum(inventoryOf)");
            assertEq(lens.headroom(m), inv, "LR-9: AceLens.headroom() != sum(inventoryOf)");
        }
    }

    // ---- coverage: what the walk actually reached, and the guards that keep it honest ----

    /// @dev The seed is PINNED, so these are deterministic facts about one walk, not a lottery.
    /// @dev The suite's whole claim is that fuzz-chosen params reach a DRAW, so that is the guard with teeth.
    function afterInvariant() public view {
        string[16] memory tags = [
            "createMarket",
            "deposit",
            "withdraw",
            "open",
            "repay",
            "withdrawCollateral",
            "claimOwed",
            "materialize",
            "claimUnits",
            "redeemInKind",
            "crashBelow",
            "heal",
            "finalize",
            "forceClose",
            "warp",
            "sweepRevenue"
        ];
        console2.log("=== AceGenesisDriveHandler verb hits (LAST sequence only) ===");
        uint256 total;
        for (uint256 i; i < tags.length; i++) {
            uint256 h = handler.callCount(tags[i]);
            total += h;
            console2.log(tags[i], h);
        }
        console2.log("genesis attempted     ", handler.genesisAttempted());
        console2.log("  of which created    ", handler.genesisCreated());
        console2.log("  of which refused    ", handler.genesisRefused());
        console2.log("  skipped at the cap  ", handler.genesisCappedOut());
        console2.log("markets that drew     ", handler.marketsThatDrew());
        console2.log("loans opened          ", handler.loansOpened());
        console2.log("  of which refused    ", handler.opensRefused());
        console2.log("  skipped at loan cap ", handler.opensSkippedAtCap());
        console2.logBytes4(handler.openRefusalSelector());
        console2.log("deposits landed/refused", handler.depositsLanded(), handler.depositsRefused());
        console2.log("repays landed         ", handler.repaysLanded());
        console2.log("credits pulled        ", handler.creditsPulled());
        console2.log("quote collected       ", handler.quoteClaimed());
        console2.log("units redeemed in kind", handler.unitsRedeemed());
        console2.log("settlements           ", handler.settlements());
        for (uint256 i; i < handler.marketCount(); i++) {
            (uint256 qdec, uint256 cdec) = handler.scalesAt(i);
            console2.log("  market/qdec/cdec", i, qdec, cdec);
        }
        assertGt(total, 0, "VACUOUS: the final sequence produced no action at all");
        /// @dev AN ACCOUNTING IDENTITY, not a coverage guard: every attempt lands in exactly one bucket.
        /// @dev It cannot lottery, and it fails on a miscounted verb, which is the only thing it claims.
        /// @dev `cappedOut` is deliberately OUTSIDE it: a capped call returns before reaching the hub, so it
        /// @dev is not an attempt. Folding it in was this assertion's first red, on its first run.
        assertEq(
            handler.genesisCreated() + handler.genesisRefused(),
            handler.genesisAttempted(),
            "a genesis attempt fell out of the tally: created + refused != attempted"
        );
        /// @dev NO COVERAGE GUARD LIVES HERE, and `genesisCreated > 0` is the one that tried to.
        /// @dev It read as structural -- every verb bootstraps a market -- but bootstrapping starts an
        /// @dev ATTEMPT, and 2 of 5 attempts were refused in the measured walk, so the guard was a lottery.
        /// @dev These counters also describe the LAST sequence alone, which no property should rest on.
        /// @dev Reachability is proved by the deterministic coverage tests below; exploration is the campaign's job.
        /// @dev The refusal count is logged for one more reason: a walk whose every config happened to be
        /// @dev admissible is a fact about the walk, and whether the RAILS refuse is `MarketInit`'s question.
    }

    // ---- deterministic coverage: the central claim, proved without the campaign's seed lottery ----

    /// @notice A market created from fuzzed params takes lender cash and then funds a draw against it.
    /// @notice THE SUITE'S CENTRAL CLAIM, and it is proved here rather than in `afterInvariant`.
    /// @dev These drive the handler's own verbs directly, so no campaign walk decides whether they run.
    /// @dev A refusal names its selector: a path that stops must say which rail stopped it, never just fail.
    function test_Coverage_AFuzzCreatedMarketFundsADraw() public {
        _driveUntilADrawLands();
        console2.log("created / refused     ", handler.genesisCreated(), handler.genesisRefused());
        console2.log("ladder landed / refused", handler.depositsLanded(), handler.depositsRefused());
        console2.logBytes4(handler.depositRefusalSelector());
        console2.log("opened / refused      ", handler.loansOpened(), handler.opensRefused());
        console2.logBytes4(handler.openRefusalSelector());
        console2.log("param sets admitted   ", _configsTried);
        assertGt(handler.genesisCreated(), 0, "no seed in the sweep produced an admissible market");
        assertGt(handler.depositsLanded(), 0, "an admitted market's ladder took no cash");
        assertGt(handler.loansOpened(), 0, "a fuzz-created market funded no draw");
        assertGt(handler.marketsThatDrew(), 0, "the draw witness never armed on the market that drew");
        /// @dev THE BREADTH GUARD. Structural while the search deploys a hub per seed, and that is the point:
        /// @dev it goes red the moment anyone puts the search back on one shared handler, where the registry
        /// @dev cap silently turned iterations past `maxMarkets()` into draw-seed variation on the same configs.
        assertEq(handler.genesisCappedOut(), 0, "the search hit the registry cap, so its later seeds varied no params");
        assertLe(_configsTried, SEEDS, "the search reported more param sets than it had seeds");
    }

    /// @dev A SEARCH, never a magic seed. The claim is that SOME admissible config funds a draw, and a
    /// @dev hardcoded seed turns any change to the param bounds into a false red about reachability.
    /// @dev It does NOT prove the sweep straddles the genesis rails: on the pinned dials every seed it tries is admitted.
    /// @dev Its refusals are all at the DRAW, on the trigger-vs-floor gate; genesis refusals are the campaign's to find.
    /// @dev HASHED, not the counter: the handler reads its dials off high bit-shifts of the seed, and a
    /// @dev small counter leaves every one of them zero -- which pins `minDebt` to one atom and refuses
    /// @dev every market on the fee-ceiling rail. A counter here tests one corner and calls it the space.
    /// @dev ONE HANDLER PER SEED, and that is the whole fix: the registry caps at `maxMarkets()`, so a shared
    /// @dev handler turned every iteration past the cap into draw-seed variation over the SAME six configs.
    /// @dev The loop bound and the config count are now the same number, and the caller asserts it rather than
    /// @dev narrating it: a search that samples six is a much weaker claim than a loop to 24 reads as.
    /// @dev Four draw seeds per config, because the binding refusal is the trigger-vs-floor gate at the DRAW.
    function _driveUntilADrawLands() internal {
        for (uint256 s; s < SEEDS && handler.loansOpened() == 0; s++) {
            uint256 seed = uint256(keccak256(abi.encode(s)));
            _rebind(new AceGenesisDriveHandler());
            handler.createMarket(seed);
            if (handler.genesisCreated() == 0) continue;
            _configsTried++;
            for (uint256 d; d < 4 && handler.loansOpened() == 0; d++) {
                handler.open(seed, d, uint256(keccak256(abi.encode(seed, d))));
            }
        }
    }

    /// @dev Points the suite's handles at the search's current hub, so every assertion after it reads that one.
    function _rebind(AceGenesisDriveHandler h) internal {
        handler = h;
        ace = h.ace();
        read = h.read();
        lens = h.lens();
    }

    /// @notice The whole lifecycle on fuzzed params: create, fund, draw, repay, and settle at expiry.
    /// @dev The #208 lesson, applied: reaching a terminal state proves almost nothing on its own, so the
    /// @dev solvency identity is re-asserted at the END rather than trusted because every verb returned.
    function test_Coverage_AFuzzCreatedMarketSettles() public {
        _driveUntilADrawLands();
        assertGt(handler.loansOpened(), 0, "no admissible market funded a draw to settle");
        handler.repay(0, 1);
        assertGt(handler.repaysLanded(), 0, "a loan on fuzzed params could not be repaid");
        handler.forceClose(0);
        assertGt(handler.settlements(), 0, "a loan on fuzzed params never settled at expiry");
        uint256[] memory ids = handler.loanIds();
        assertTrue(read.loan(ids[0]).closedAt != 0, "forceClose returned without closing the loan");
        _invariant_perTokenSolvency();
        _invariant_loanClaimsEqualDebt();
        _invariant_lr9Reconciliation();
    }

    /// @notice The DISTRESS settlement path lands on fuzzed params, and LR-9 then reconciles NONZERO state.
    /// @notice `forceClose` is the expiry backstop and reads no price; `finalize` is the leg that reads the record.
    /// @dev WITHOUT THIS THE LR-9 INVARIANT IS `0 == 0`: the campaign's last sequence settles nothing at all.
    /// @dev `netSyntheticOutflow` has two writers, `redeemInKind` and the ask, and this suite drives neither.
    /// @dev So the identity's subtrahend is pinned at zero here and only its backed-burn half can ever move.
    /// @dev The credit pull is the other half: settlement is the only verb that CREDITS a borrower residual.
    function test_Coverage_DistressFinalizeLandsAndLR9IsNonTrivial() public {
        _driveUntilADrawLands();
        assertGt(handler.loansOpened(), 0, "no admissible market funded a draw to settle");

        handler.crashBelow(0);
        handler.finalize(0);
        assertGt(handler.settlements(), 0, "a persisted-distress finalize never landed on fuzzed params");
        uint256[] memory ids = handler.loanIds();
        assertTrue(read.loan(ids[0]).closedAt != 0, "finalize returned without closing the loan");

        assertGt(_totalBackedBurns(), 0, "settlement credited no backed burn, so LR-9 reconciles 0 == 0");
        assertGt(_totalInventory(), 0, "settlement minted no ladder inventory for the identity to bind on");

        /// @dev The residual equity is CREDITED, never pushed, so nothing proves it collectable until it is pulled.
        handler.claimOwed(0);
        assertGt(handler.creditsPulled(), 0, "the settled borrower could not pull the residual it was credited");

        _invariant_perTokenSolvency();
        _invariant_loanClaimsEqualDebt();
        _invariant_lr9Reconciliation();
    }

    /// @notice The lender exit legs on fuzzed params: mint units, pull the quote payout, burn units in kind.
    /// @notice THE TWO DEAD LEGS THIS CLOSES: `unitOwed` never fell, and `netSyntheticOutflow` never left zero.
    /// @dev So LR-9's subtraction ran all campaign with a subtrahend pinned at zero, testing only half itself.
    /// @dev And the payout index only ever grew, on a suite whose whole point is 2-decimal quote against 18.
    /// @dev Driven deterministically: at 16 selectors and depth 32, whether the campaign draws all three is a lottery.
    function test_Coverage_LenderExitsMoveTheUnitLedgerAndTheOutflow() public {
        _driveUntilADrawLands();
        assertGt(handler.loansOpened(), 0, "no admissible market funded a draw to exit from");
        /// @dev PART of the debt: a full repay closes the loan, and the distress settlement below needs it live.
        uint256[] memory ids = handler.loanIds();
        uint256 half = read.loan(ids[0]).debt / 2;
        assertGt(half, 0, "the drawn loan is too small to repay in part, so the payout index cannot be funded");
        handler.repay(0, half); // credits the funding ticks, so a claim has quote to pull
        assertGt(handler.repaysLanded(), 0, "the repay that funds the payout index did not land");

        /// @dev NO MATERIALIZE STEP. A repay credits the lender's pool directly; there is no unit to mint
        /// @dev first and no (lender, tick) pair to sweep, so the ledger the old sweep drove is one write.
        uint256 owedBefore = _totalUnitOwed();
        _sweepClaims();
        assertGt(handler.quoteClaimed(), 0, "collect paid nothing, so the credit leg has no debit witness");
        assertLt(_totalUnitOwed(), owedBefore, "quote was collected and the pool's credit leg did not fall");

        handler.crashBelow(0);
        handler.finalize(0);
        assertGt(handler.settlements(), 0, "the distress settlement that mints inventory never landed");
        assertGt(_totalInventory(), 0, "the settlement minted no inventory for the in-kind exit to burn");
        assertTrue(read.loan(ids[0]).closedAt != 0, "finalize returned without closing the loan");

        uint256 outflowBefore = _totalOutflow();
        _sweepRedeems();
        assertGt(handler.unitsRedeemed(), 0, "the in-kind exit burned nothing, so LR-9's subtrahend stays at zero");
        assertGt(_totalOutflow(), outflowBefore, "units left in kind and netSyntheticOutflow did not move");

        _invariant_perTokenSolvency();
        _invariant_loanClaimsEqualDebt();
        _invariant_lr9Reconciliation();
        _invariant_canaryMarketUntouched();
    }

    /// @dev Every lender, so no leg turns on guessing which one is the market's tenant.
    /// @dev ODD SEEDS take the handler's fuzzed-lender branch, `lenders[seed % 3]`: 1, 3 and 5 are lenders 1, 0 and 2.
    /// @dev WAS seeds 0, 1 and 2, which the tenant-or-fuzzed mapping sent to the tenant twice, so `lenders[2]` never collected.
    /// @dev NO TICK DIMENSION: `collect` takes (quote, to) and drains the caller's own pool across their markets.
    function _sweepClaims() internal {
        for (uint256 a; a < 3; a++) {
            handler.collect(0, 2 * a + 1);
        }
    }

    /// @dev NO AMOUNT AND NO TICK: `redeemInKind` takes the loan's whole pot or reverts, and one lender
    /// @dev owns it, so the old per-(lender, tick) balance lookup has nothing left to look up.
    function _sweepRedeems() internal {
        for (uint256 a; a < 3; a++) {
            handler.redeemInKind(0, a);
        }
    }

    function _marketIndexOf(uint256 loanId) internal view returns (uint256) {
        bytes32 m = ace.loanMarket(loanId);
        for (uint256 i; i < handler.marketCount(); i++) {
            if (handler.marketAt(i) == m) return i;
        }
        revert("the drawn loan sits in no created market");
    }

    // ---- view helpers over live hub state ----

    /// @dev Inventory across every created market, for the non-triviality witness LR-9 needs.
    function _totalInventory() internal view returns (uint256 s) {
        for (uint256 i; i < handler.marketCount(); i++) {
            s += _sumInventory(i);
        }
    }

    function _totalBackedBurns() internal view returns (uint256 s) {
        for (uint256 i; i < handler.marketCount(); i++) {
            s += read.marketState(handler.marketAt(i)).cumulativeBackedBurns;
        }
    }

    /// @dev LR-9's SUBTRAHEND, which only an in-kind exit moves: zero here means half the identity is dead.
    function _totalOutflow() internal view returns (uint256 s) {
        for (uint256 i; i < handler.marketCount(); i++) {
            s += read.marketState(handler.marketAt(i)).netSyntheticOutflow;
        }
    }

    /// @dev The credit leg across the created set: `collect` is the only verb here that lowers it.
    /// @dev READ OFF THE POOL, not off `MarketState`: the leg moved to (lender, quote), so a per-market
    /// @dev sum would count a lender running several markets once per market instead of once.
    function _totalUnitOwed(address token) internal view returns (uint256 s) {
        address[] memory who = _lendersOf(token);
        for (uint256 a; a < who.length; a++) {
            s += read.unitOwed(who[a], token);
        }
    }

    /// @dev The DISTINCT lenders of the created markets quoting in `token`: the set the credit leg is summed over.
    function _lendersOf(address token) internal view returns (address[] memory seen) {
        seen = new address[](handler.marketCount());
        uint256 c;
        for (uint256 i; i < handler.marketCount(); i++) {
            bytes32 m = handler.marketAt(i);
            /// @dev FILTERED ON THE TOKEN, and it is the whole correctness of the term: a pool is keyed
            /// @dev (lender, quote), so summing a lender's pools across quotes adds dai credit into the
            /// @dev usdc identity. Measured as `0 != 6196500` on a token whose markets hold nothing.
            if (ace.idToMarketParams(m).quote != token) continue;
            address who = ace.idToMarketParams(m).lender;
            bool dup;
            for (uint256 j; j < c; j++) {
                if (seen[j] == who) dup = true;
            }
            if (dup) continue;
            seen[c++] = who;
        }
        assembly ("memory-safe") {
            mstore(seen, c) // shrink to the distinct lenders found, which fill the array's head
        }
    }

    /// @dev The FIRST driven market's quote, which is what the bare call sites meant. This suite builds its
    /// @dev markets from a fuzzed genesis rather than from named tokens, so the token is read off market 0.
    function _totalUnitOwed() internal view returns (uint256) {
        return _totalUnitOwed(handler.quoteOf(0));
    }

    /// @dev The per-token identity: a market books only in its own quote, so the sum partitions on it.
    /// @dev The fee escrow is per LOAN and outside `totalCash`, exactly as in the sibling suite.
    /// @dev The CANARY is counted: it is funded, so leaving it out would read its seed as hub float and go red.
    /// @dev The sum itself is `BookedQuote.total`, shared with the other solvency campaigns; this caller picks its markets.
    function _bookedQuote(address token) internal view returns (uint256) {
        uint256 n = handler.marketCount();
        bytes32[] memory markets = new bytes32[](n + 1);
        uint256 held;
        for (uint256 i; i < n; i++) {
            if (handler.quoteOf(i) == token) markets[held++] = handler.marketAt(i);
        }
        if (handler.canaryQuote() == token) markets[held++] = handler.canaryId();
        assembly ("memory-safe") {
            mstore(markets, held) // shrink to the markets in `token`, which fill the array's head
        }
        /// @dev ONCE PER LENDER, outside the market loop: the credit leg spans that lender's markets.
        return BookedQuote.total(ace, read, markets, _lendersOf(token), token);
    }

    /// @dev The canary counts here too: its quote is named by a market, so the zero-balance witness must skip it.
    function _marketsUsing(address token) internal view returns (uint256 n) {
        for (uint256 i; i < handler.marketCount(); i++) {
            if (handler.quoteOf(i) == token) n++;
        }
        if (handler.canaryQuote() == token) n++;
    }

    /// @dev ONE READ, NOT A WALK. The rung loop is deleted rather than re-pointed: resting cash is a
    /// @dev market-wide balance now, so walking six rungs added the same number six times.
    function _walkCash(uint256 mi) internal view returns (uint256) {
        return read.restingOf(handler.marketAt(mi));
    }

    function _sumClaims(bytes32 m) internal view returns (uint256 s) {
        uint256[] memory ids = ace.marketLoans(m, 0, ace.marketLoansLength(m));
        for (uint256 k; k < ids.length; k++) {
            s += read.claimOf(m, ids[k]); // `_claimsOf` is gone with the per-loan tick list it walked
        }
    }

    /// @dev Same deletion as `_walkCash`: one pot per loan, so the inner rung loop was a 6x multiplier.
    function _sumInventory(uint256 mi) internal view returns (uint256 s) {
        bytes32 m = handler.marketAt(mi);
        uint256[] memory ids = ace.marketLoans(m, 0, ace.marketLoansLength(m));
        for (uint256 k; k < ids.length; k++) {
            s += read.invPotOf(m, ids[k]);
        }
    }
}
