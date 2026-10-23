// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Loan, MarketParams, MarketState} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {SelfCallOnly} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {BookedQuote} from "../utils/BookedQuote.sol";
import {AceHandler} from "./AceHandler.sol";

/// @title AceInvariants
/// @notice The SAFETY invariant suite for the singleton: solvency, the aggregate mirrors, LR-9, the claim/floor law, the exit flags.
/// @dev Folds the two legacy safety suites into one: the aggregate walks now run over settlement, deleverage and rotation too.
/// @dev Solvency, the aggregate walks, LR-9, lentPrincipal and the flag aggregates are RECOMPUTED from live state on every check.
/// @dev No-theft, the floor law, settlement monotonicity and inv-15 LATCH into handler ghosts: fail_on_revert = false discards a revert.
/// @dev Junior is out of core v1, so the junior-depth fold and the cohort-coverage invariants are CANCELLED.
/// @dev Singleton-specific replacements: the roll reserve is a term in the solvency identity, and the sparse tick bitmap has its own mirror.
/// @dev FOUR DRIVEN MARKETS plus two passive canaries, one canary per quote token.
/// @dev Plus every market the fuzzer creates MID-SEQUENCE, held outside that index space deliberately.
/// @dev Isolation on this hub is LOGICAL, per market id, so it is measured here rather than assumed.
/// @dev Config (foundry.toml [invariant]): runs = 256, depth = 32, fail_on_revert = false.
/// @dev NOT REACHED HERE, so a green says nothing of them: a settlement that comes up SHORT, and a recordless market's forfeit.
/// @dev Both are `AceStagedSettlement`'s, which stages the short escrow no verb can produce; this campaign stays real-verbs-only.
contract AceInvariantsTest is StdInvariant, Test {
    address internal constant TREASURY = AceFixtures.TREASURY; // the fixture's hub destination; the inert address(0) posture is pinned elsewhere

    AceHandler internal handler;
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens; // the attribution legs need `claimable` and `unclaimableStrand`
    MockERC20 internal usdc;
    bytes32 internal mid;

    function setUp() public {
        handler = new AceHandler();
        handler.baselineSkim(); // pre-snapshot, but it needs the handler's code deployed to be called back
        handler.baselineNoFlip(); // this suite's alone: it asserts the ghost, and the other baselineSkim callers keep their state
        handler.baselineThirdParty(); // every third-party lever pulled once on an armed loan; none may flip its fold
        ace = handler.ace();
        read = handler.read();
        usdc = handler.usdc();
        mid = handler.id();
        lens = new AceLens(address(ace));

        /// @dev SELECTOR ARRAY FIRST (baseline-satisfied-ghosts rule): the unit verbs joined and the
        /// @dev exit-flag verbs left in the SAME edit that changed the handler, with per-verb counts
        /// @dev asserted below so a ghost cannot be satisfied by the constructor baseline alone.
        bytes4[] memory sel = new bytes4[](36);
        sel[0] = AceHandler.deposit.selector;
        sel[1] = AceHandler.withdraw.selector;
        /// @dev `materialize`, `claimUnits` and `transferUnits` are GONE with the receipt ledger, and are
        /// @dev NOT replaced one-for-one: minting a unit, pulling one class's accrual and moving a receipt
        /// @dev were three verbs over a per-holder ledger. `collect` is the single credit door that survives.
        sel[2] = AceHandler.collect.selector;
        sel[3] = AceHandler.redeemInKind.selector;
        sel[4] = AceHandler.depositThenExit.selector;
        sel[5] = AceHandler.open.selector;
        sel[6] = AceHandler.repay.selector;
        sel[7] = AceHandler.withdrawCollateral.selector;
        /// @dev `refinance` REPLACES the four roll actions and the armed rotation, all deleted.
        sel[8] = AceHandler.refinance.selector;
        /// @dev The DELEVERAGE crank, which the handler drove under a `skim` tag long after skim was cut.
        sel[9] = AceHandler.deleverage.selector;
        sel[10] = AceHandler.setRate.selector;
        sel[11] = AceHandler.buyInventory.selector;
        sel[12] = AceHandler.crashBelow.selector;
        sel[13] = AceHandler.heal.selector;
        sel[14] = AceHandler.forceClose.selector;
        sel[15] = AceHandler.warp.selector;
        sel[16] = AceHandler.sweepRevenue.selector;
        sel[17] = AceHandler.finalize.selector;
        /// @dev Without this the fuzzer never pulls a credit, and `quoteOwedTotal` only ever RISES.
        sel[18] = AceHandler.claimOwed.selector;
        /// @dev Without this NOTHING drives `retitle`, and the title invariant only ever sees mint state.
        sel[19] = AceHandler.transferTitle.selector;
        /// @dev THE MIGRATING SIBLING of `refinance` above: without it no verb whose subject is two markets runs.
        sel[20] = AceHandler.migrate.selector;
        /// @dev THE POLICY VERBS. `refinanceByPolicies` is the hub's SECOND cross-market surface: one call, many markets.
        /// @dev The isolation invariant lives in THIS suite, so the entitlement model is exercised only if they run here.
        /// @dev Arming a policy is also what makes `forceClose` take its ROLL branch and mint a successor.
        sel[21] = AceHandler.armPolicy.selector;
        sel[22] = AceHandler.refinanceByPolicy.selector;
        sel[23] = AceHandler.refinanceByPolicies.selector;
        /// @dev GENESIS AS A MOVE: before this selector, market creation could only ever be read AT REST.
        sel[24] = AceHandler.createMarket.selector;
        /// @dev THE REDIRECTED EXITS: `withdraw` and `collect` paying a third party, so value leaves to a non-caller.
        sel[25] = AceHandler.exitTo.selector;
        /// @dev THE SMALL ARMED POPULATION: loans at 1.0-1.5x `minDebt`, the regime the no-flip ghost needs and `open` never draws.
        sel[26] = AceHandler.openSmallArmed.selector;
        /// @dev THE THIRD-PARTY LEVERS on an armed loan's next fold (#666, #514): each is bracketed by the real fold.
        sel[27] = AceHandler.strangerDrain.selector;
        sel[28] = AceHandler.strangerAtomicDrain.selector;
        sel[29] = AceHandler.postOrder.selector;
        sel[30] = AceHandler.strangerFill.selector;
        sel[31] = AceHandler.strangerRepayPartial.selector;
        sel[32] = AceHandler.routeIn.selector;
        sel[33] = AceHandler.recordPush.selector;
        /// @dev THE COVERAGE LINE AT BOTH DOORS: every other draw posts far more than the line asks, so its refusal went undriven.
        sel[34] = AceHandler.openNearLine.selector;
        /// @dev THE UNPAID BACKSTOP: no action called it before, so a regression in its window or its pay was invisible here.
        sel[35] = AceHandler.settleExpired.selector;
        /// @dev DELETED: `setRearm` and `compound`, the lender's standing compounding choice and its crank.
        /// @dev The credit path only ever pays out now, which is the whole of what the verb deletion means here.
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Every property below, checked on ONE walk instead of one campaign each.
    /// @dev The leading underscore de-registers a property from forge's `invariant` prefix, name intact for grep.
    /// @dev A plain rename was rejected: the design record cites about twenty of these by name.
    /// @dev THE COST: the first failure aborts the rest, so a red run names ONE break, not all of them.
    /// @dev COUNT IS LOAD-BEARING: `_invariant_revenueOnlyLeavesViaTheSweep` latches, so it runs exactly once per step.
    function invariant_all() public {
        _invariant_solvency();
        _invariant_canaryMarketUntouched();
        _invariant_noActionCrossesMarkets();
        _invariant_marketCashFitsUint128();
        _invariant_lr9Reconciliation();
        _invariant_loanClaimsEqualDebt();
        _invariant_titleOwnerIsTheBorrower();
        _invariant_titleSupplyEqualsLoanCount();
        _invariant_floorIsTheDerivation();
        _invariant_aSettledLoanHasNoLiveClaim();
        _invariant_claimableIsThePool();
        _invariant_collateralCoversEveryLiveClaim();
        _invariant_everyReleasedWeiHasANamedPayee();
        _invariant_noTheft();
        _invariant_aRedirectedExitReachesItsPayee();
        _invariant_aSaleNeverPays();
        _invariant_floorLaw();
        _invariant_deleverageNeverRaisesTheTrigger();
        _invariant_settlementMonotonicity();
        _invariant_refinanceNeverMovesAnotherLoansFloor();
        _invariant_revenueOnlyLeavesViaTheSweep();
        _invariant_genesisMidSequenceIsInert();
        _invariant_forceCloseHonoursItsPromise();
        _invariant_noThirdPartyFlipsAnArmedFold();
        _invariant_reserveIsTheSumOfLiveShares();
        _invariant_anArmedShareNeverExceedsItsRollsNeed();
        _invariant_aLiveTriggerNeverExceedsThePrice();
        _invariant_noFreshDrawBreachesTheReserve();
        // ---- the pooled model's own laws, which had no per-market analogue before ----
        _invariant_cashIsTheRestingPool();
        _invariant_lentIsTheClaimBook();
        _invariant_lentByCollateralIsTheClaimBook();
        _invariant_poolsNeverCrossQuotes();
        _invariant_noLenderDoorLeavesDust();
        _invariant_zeroCollateralMeansZeroClaim();
        _invariant_onlyTheLenderMovesItsMoney();
        _invariant_aClosedLoanHoldsNoEscrow();
        _invariant_theUnpaidBackstopKeepsItsTerms();
        _invariant_anAskOffPotFallsOnlyInKind();
    }

    /// @notice AN ASK-OFF POT FALLS ONLY IN KIND: in the market built with the hub's ask off, no settled pot ever left by a sale.
    /// @dev TWO LEGS. The latch names the DOOR: a pot fell across some verb other than the in-kind exit.
    /// @dev The equality names the PAYEE: every unit that ever left one of those pots sits in that market's lender's own wallet.
    /// @dev That lender runs no other market and that collateral backs no other, so the balance has no second source.
    function _invariant_anAskOffPotFallsOnlyInKind() public view {
        assertFalse(handler.askOffPotFellOutOfKind(), string.concat("ASK-OFF: a pot fell outside the in-kind exit -- ", handler.askOffPotTag()));
        (, address lender, address coll) = handler.askOffMarket();
        assertEq(MockERC20(coll).balanceOf(lender), handler.askOffUnitsLeft(), "ASK-OFF: units left a pot and did not reach its lender");
    }

    // ---- 1. Solvency: the hub's quote balance is exactly the four booked pots, with NO other float ----

    /// @notice The hub holds resting cash, un-swept revenue and withheld fee escrows -- nothing else.
    /// @dev The escrow INHERITS the retired roll reserve's place: quote custodied outside `totalCash`.
    /// @dev That is the whole point of the escrow, so a share price never prices unearned revenue.
    /// @dev There is NO bribe carve any more: the whole protocol fee accrues, so no term is missing.
    /// @dev A carve stranded on the hub would break this equality, which is what it is for.
    /// @dev Fee dust no placement can absorb lands in `protocolRevenue`, which has an exit.
    /// @dev Deliberately an EQUALITY, not `>=`: an unsolicited donation must fail here, never absorb.
    /// @dev MORPHO BLUE TAKES THE OTHER SIDE and asserts `balance + totalBorrow >= totalSupply`, which
    /// @dev tolerates a donation by construction. The equality is the stronger law and it is kept -- but
    /// @dev it carries a PRECONDITION the inequality does not: no actor may transfer quote to the hub
    /// @dev outside a booked door. The handler mints into actors and only ever approves-and-deposits, so
    /// @dev nothing donates today; a future action that does would redden this for a reason that is not
    /// @dev an accounting defect, and the message says so rather than sending the reader hunting a leak.
    /// @dev ONE EQUALITY PER QUOTE TOKEN. The hub holds a balance per token, so a single sum over all
    /// @dev markets would compare a usdc balance against a total carrying dai, and pass on neither.
    function _invariant_solvency() public view {
        assertEq(
            usdc.balanceOf(address(ace)),
            _bookedQuote(address(usdc)),
            "solvency(usdc): hub balance != market pots + feeEscrows + pooled credit (or something donated quote)"
        );
        assertEq(
            handler.dai().balanceOf(address(ace)),
            _bookedQuote(address(handler.dai())),
            "solvency(dai): hub balance != market pots + feeEscrows + pooled credit (or something donated quote)"
        );
    }

    /// @notice NO ACTION MOVES A MARKET IT DOES NOT NAME. The singleton's isolation, asserted.
    /// @dev THE PROPERTY THIS SUITE'S TOPOLOGY EXISTS FOR: isolation is LOGICAL, so nothing structural holds it.
    /// @dev The ACTIVE half of it, and the harder one -- every market is driven at once, so a crossing has cover.
    /// @dev Latched mid-action: `fail_on_revert = false` drops a bare revert, and a crossing inside one with it.
    function _invariant_noActionCrossesMarkets() public view {
        assertFalse(handler.crossMarketMoved(), string.concat("ISOLATION: an action moved a market it was not entitled to -- verb ", handler.crossMarketTag()));
    }

    /// @notice THE PASSIVE HALF of isolation: no driven market's action moves either untouched canary.
    /// @dev ONE CANARY PER QUOTE TOKEN, so each side of the per-token solvency identity has a zero-state witness.
    /// @dev Each shares its quote with the markets beside it, so a crossing mis-books rather than reverting.
    /// @dev TEETH: this is the assertion the cross-quote refinance defect would have died on.
    /// @dev The `marketLoansLength == 0` leg is what the per-token fee-escrow walk relies on.
    function _invariant_canaryMarketUntouched() public view {
        for (uint256 i; i < 2; i++) {
            bytes32 c = handler.canaries(i);
            MarketState memory s = read.marketState(c);
            assertEq(s.cash, handler.canarySeededCashOf(i), "canary: its cash moved");
            /// @dev `totalLent` and `unitOwed` are NOT checked here any more and their absence is the point:
            /// @dev both moved to the (lender, quote) pool, which a canary shares with nothing because its
            /// @dev lender is its own. `marketLoansLength == 0` below is the sharper witness for the first,
            /// @dev and `_invariant_lentIsTheClaimBook` holds the pool leg at the granularity it lives at.
            assertEq(s.protocolRevenue, 0, "canary: it banked a fee for a draw it never funded");
            assertEq(s.quoteOwedTotal, 0, "canary: quote credited to a claimant it never had");
            assertEq(s.cumulativeBackedBurns, 0, "canary: a backed burn in a market that settled nothing");
            assertEq(s.netSyntheticOutflow, 0, "canary: synthetic left a market that issued none");
            assertEq(ace.marketLoansLength(c), 0, "canary: a loan was opened in a market no verb addresses");
        }
    }

    // DELETED with the walk: `_invariant_aggregatesTrackFullWalk` checked caches against a band recompute. `cash` IS the balance: cache and walk are one read.

    /// @notice Every market's resting cash fits the uint128 the draw narrows it into.
    /// @notice Hub narrowings rest on it, so nothing may accumulate resting cash past that width.
    /// @dev `MarketState.cash` stays a uint256 and the bound is a runtime check at the deposit door, not the field's width.
    /// @dev DOCUMENTATION of that residual, NOT a tripwire: under mutation the campaign stays green with the bound deleted.
    /// @dev The handler's deposit bounds sit ~10^30 below 2^128, and its try/catch would swallow `CashCapped` anyway.
    /// @dev The property's teeth are in `AceMarketCashCap`'s sequence fuzz, which does go red when the bound is deleted.
    function _invariant_marketCashFitsUint128() public view {
        for (uint256 j; j < handler.marketCount(); j++) {
            uint256 cash = read.restingOf(handler.midAt(j));
            assertLe(cash, type(uint128).max, "a market's resting cash outran the uint128 every draw-side stamp narrows it to");
        }
    }

    /// @notice THE BITMAP INVARIANT IS GONE, and it is the one deletion here worth reading twice.
    /// @notice It asserted that the sparse tick bitmap mirrored live bucket state, and that the watermarks
    /// @notice bounded every tick carrying it -- a defect no cash assertion could see, because a dropped bit
    /// @notice starves a tick of draws while every balance still reconciles.
    /// @notice `tickWords`, `loActive`, `hiActive` and `hasActive` are all DELETED. A market holds cash at ONE
    /// @notice price, so there is no index to mirror and no watermark to contain: the two representations the
    /// @notice invariant existed to keep in agreement have collapsed into the single number above.
    /// @dev A mirror invariant with one representation left is not weakened, it is vacuous. Nothing replaces it.

    // ---- 3. LR-9: backed burns not yet delivered == total inventory == headroom() ----

    /// @dev PER MARKET: LR-9 is a per-market identity, and one summed equality lets a surplus cover a deficit.
    /// @dev The headroom leg is bound to the SHIPPED lens and to the inventory walk, never to `net` again.
    /// @dev `AceReader.headroom` respells the same two storage words, so `net == read.headroom(m)` covered no src line.
    function _invariant_lr9Reconciliation() public view {
        for (uint256 i; i < handler.marketCount(); i++) {
            bytes32 m = handler.midAt(i);
            MarketState memory s = read.marketState(m);
            uint256 inv = _sumInventory(m);
            assertEq(s.cumulativeBackedBurns - s.netSyntheticOutflow, inv, "LR-9: backed burns net of outflow != sum(inventoryOf)");
            assertEq(lens.headroom(m), inv, "LR-9: AceLens.headroom() != sum(inventoryOf)");
        }
    }

    // ---- 4. Claim integrity, both sides of the ledger ----

    /// @notice An open loan's claims sum to its debt, exactly; a closed loan carries none.
    /// @notice The funded-tick LIST survives a close for pot discovery, by design.
    /// @dev Every melt debits debt and claims alike, so equality, not a bound: no phantom claims.
    /// @dev CLAIMS ARE KEYED (market, loan): asked of market 0, a loan drawn elsewhere reads a false zero.
    function _invariant_loanClaimsEqualDebt() public view {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < ids.length; i++) {
            Loan memory l = read.loan(ids[i]);
            uint256 claim = read.claimOf(ace.loanMarket(ids[i]), ids[i]); // ONE word: there is nothing to sum
            if (l.closedAt != 0) assertEq(claim, 0, "a closed loan still carries a live claim");
            else assertEq(claim, l.debt, "an open loan's claim is not its debt");
        }
    }

    /// @notice Title's two ledgers agree: the ERC-721 owner IS the hub's `Loan.borrower`, every loan.
    /// @notice It holds past close as well -- no burn path exists and no verb zeroes the borrower.
    /// @dev The collection calls `retitle` from `_update`, so both ledgers move in one tx or neither.
    /// @dev Open and `retitle` are the ONLY two writers of the field, which is what makes it equality.
    /// @dev `ownerOf` REVERTS on an unminted id, so this also pins that every opened loan got a title.
    function _invariant_titleOwnerIsTheBorrower() public view {
        uint256[] memory ids = handler.loanIds();
        PositionTitleNFT title = PositionTitleNFT(ace.POSITION_TITLE());
        for (uint256 i; i < ids.length; i++) {
            assertEq(title.ownerOf(ids[i]), ace.borrowerOf(ids[i]), "ERC-721 owner != Loan.borrower");
        }
    }

    /// @notice One title per loan the HUB opened, hub-wide: `totalSupply()` tracks `loanCount()` exactly.
    /// @notice Strictly wider than the walk above, which can only see loans the handler recorded.
    /// @dev Catches the two desyncs the per-loan walk is blind to: an open that mints no title, and a burn.
    /// @dev `PositionTitleNFT` has no burn path, so an inequality on that leg is a new one.
    /// @dev O(1): `ERC721Enumerable` keeps the supply, so this costs nothing per call.
    /// @dev An ORDER takes its id from the same counter and mints no title, so the hub's own order counts come off the top.
    function _invariant_titleSupplyEqualsLoanCount() public view {
        PositionTitleNFT title = PositionTitleNFT(ace.POSITION_TITLE());
        uint256 orders;
        for (uint256 i; i < handler.allMarketCount(); i++) {
            orders += ace.orderCount(handler.allMarketAt(i));
        }
        assertEq(title.totalSupply() + orders, read.loanCount(), "a loan exists with no title, or a title was burned");
    }

    /// @notice No loan's funded-tick list ever repeats a tick.
    /// @dev A duplicate double-counts lentPrincipal and collateral in settlement; every draw walk must preserve it.
    /// @dev Keyed off each loan's OWN market: asked of market 0, a loan drawn elsewhere returns an empty tick list.
    // DELETED with the ladder: `_invariant_tickUniqueness` pinned that no loan repeats a funded tick. One price, one claim word: no list to repeat.

    /// @notice THE FLOOR IS THE DERIVATION, asserted: a claim means the market's price, no claim means zero.
    /// @dev It REPLACES A BOUND. The floor was stored and could sit anywhere at or below the funded ticks,
    /// @dev so the old property bracketed it between them. It is `claim == 0 ? 0 : p.price` now.
    /// @dev Worth pinning precisely BECAUSE it is derived: a change that reintroduces a stored floor fails
    /// @dev here rather than drifting quietly behind a bound that a single price satisfies trivially.
    function _invariant_floorIsTheDerivation() public view {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < ids.length; i++) {
            bytes32 m = ace.loanMarket(ids[i]); // the loan's own market: the claim and the price are keyed on it
            uint256 floor = read.fundingFloor(m, ids[i]);
            if (read.claimOf(m, ids[i]) == 0) {
                assertEq(floor, 0, "a retired claim still names a funding floor");
            } else {
                assertEq(floor, ace.idToMarketParams(m).price, "a live claim's floor is not its market's price");
            }
        }
    }

    // ---- 5. The unit ledger: minted never exceeds supply, on every class the fuzzer built ----

    // DELETED with the receipt ledger: `_invariant_mintedNeverExceedsClassSupply` bounded ERC-6909 balances by a class supply. No token, no class, no supply.

    /// @notice A class that holds a pot, or that anyone has burned into, carries NO live claim.
    /// @dev THE PRECONDITION THE `EmptyPot` DISCRIMINATOR RESTS ON; it is not visible from one file.
    /// @dev `Settlement._finalizeLoanFor` credits every pot and zeroes every claim in ONE call.
    /// @dev So leg one can never be observed false, which is why the guard may read `M.claim` at all.
    /// @dev A future verb crediting a pot outside settlement breaks that leg before anything else.
    /// @dev Leg two is what lets both `LoanAccounting` credit sites divide by `K.supply - K.burned` safely.
    /// @dev They skip zero-claim ticks, so neither ever runs on a class with `burned > 0`.
    /// @dev A claim can only RISE at the draw, reachable solely from `open` on a fresh id.
    /// @dev Lose it and the empty-pot strand reopens with every other test still green.
    /// @dev IT ABSORBS `_invariant_noPotOutlivesItsUnits`, which pinned the zero-divisor rail on
    /// @dev `K.supply - K.burned`. There are no units to outlive a pot now: the pot is per LOAN, one
    /// @dev claimant owns it whole, and `redeemInKind` takes all of it, so no divisor and no residue exist.
    function _invariant_aSettledLoanHasNoLiveClaim() public view {
        uint256[] memory ids = handler.loanIds();
        for (uint256 k; k < ids.length; k++) {
            bytes32 m = ace.loanMarket(ids[k]); // the pot and the claim are both keyed on the loan's own market
            if (read.claimOf(m, ids[k]) == 0) continue;
            assertEq(read.invPotOf(m, ids[k]), 0, "a loan holding a settled pot still carries a live claim");
        }
    }

    // MERGED into `_invariant_aSettledLoanHasNoLiveClaim`: its zero-divisor rail on `supply - burned` is gone

    // DELETED with the receipt ledger: `_attributed` summed one class's wei over every named holder, and both the class and the per-holder split are gone.

    /* ===================================================================== */
    /*  THE POOLED MODEL'S OWN LAWS                                          */
    /*  None of these had a per-market analogue: the aggregates did not span  */
    /*  markets before, so a PORT of the old campaign misses all of them.     */
    /* ===================================================================== */

    /// @dev Every DISTINCT lender named by a market this campaign knows about, canaries included.
    /// @dev Built from the MARKETS rather than the handler's actor list: a lender the fuzzer never
    /// @dev pranks still owns a pool, and summing only the fuzzed three would compare a full left
    /// @dev side against a partial right one and read as a shortfall that is really a missing term.
    function _distinctLenders() private view returns (address[] memory out) {
        uint256 n = handler.allMarketCount();
        address[] memory buf = new address[](n);
        uint256 c;
        for (uint256 i; i < n; i++) {
            address who = ace.idToMarketParams(handler.allMarketAt(i)).lender;
            bool seen;
            for (uint256 j; j < c; j++) {
                if (buf[j] == who) seen = true;
            }
            if (!seen) buf[c++] = who;
        }
        out = new address[](c);
        for (uint256 i; i < c; i++) {
            out[i] = buf[i];
        }
    }

    /// @notice PER QUOTE, the markets' resting cash and the lenders' resting pools are the SAME MONEY.
    /// @dev `Types.sol` says the two "move together on every deposit, draw and withdraw and must never
    /// @dev be netted", and `Lender.creditCash`/`debitCash` are named as the single site that moves them.
    /// @dev They are NOT the only site: the draw path in `Borrower` writes both inline, because `Lender`
    /// @dev imports `Borrower` and cannot be called back into. So the pairing is a convention held by two
    /// @dev write sites on immutable bytecode, and this equality is the only thing that would catch them
    /// @dev drifting. Morpho Blue asserts the same shape one level down (sum of user shares == total).
    function _invariant_cashIsTheRestingPool() public view {
        address[2] memory toks = [address(usdc), address(handler.dai())];
        address[] memory who = _distinctLenders();
        for (uint256 t; t < toks.length; t++) {
            uint256 marketSide;
            for (uint256 i; i < handler.allMarketCount(); i++) {
                if (handler.quoteOf(i) != toks[t]) continue;
                marketSide += read.marketState(handler.allMarketAt(i)).cash;
            }
            uint256 poolSide;
            for (uint256 a; a < who.length; a++) {
                (uint256 resting,,) = read.lenderPools(who[a], toks[t]);
                poolSide += resting;
            }
            assertEq(marketSide, poolSide, "pooling: the markets' cash and the lenders' resting pools disagree");
        }
    }

    /// @notice PER QUOTE, a lender's `lent` leg is exactly the claims their markets' loans still carry.
    /// @dev AN EQUALITY, deliberately, where a bound was the tempting shape. `lent` is the one pool leg
    /// @dev the solvency identity excludes -- that quote has left the hub -- so nothing else in this file
    /// @dev constrains it at all, and a bound would leave it free to drift upward forever.
    function _invariant_lentIsTheClaimBook() public view {
        address[2] memory toks = [address(usdc), address(handler.dai())];
        address[] memory who = _distinctLenders();
        for (uint256 t; t < toks.length; t++) {
            uint256 claimSide;
            for (uint256 i; i < handler.allMarketCount(); i++) {
                if (handler.quoteOf(i) != toks[t]) continue;
                bytes32 m = handler.allMarketAt(i);
                uint256[] memory ids = ace.marketLoans(m, 0, ace.marketLoansLength(m));
                for (uint256 k; k < ids.length; k++) {
                    claimSide += read.claimOf(m, ids[k]);
                }
            }
            uint256 poolSide;
            for (uint256 a; a < who.length; a++) {
                (, uint256 lent,) = read.lenderPools(who[a], toks[t]);
                poolSide += lent;
            }
            assertEq(poolSide, claimSide, "pooling: the lent pool leg and the claim book disagree");
        }
    }

    /// @notice PER (lender, quote, collateral), the hub's split of `lent` is exactly the claims of that triple's markets.
    /// @dev Over the whole cross product, so a write landing in a triple no market owns still reads as a nonzero hub side.
    /// @dev The claim side is keyed by the handler's own market list and the markets' params, never by the split under test.
    function _invariant_lentByCollateralIsTheClaimBook() public view {
        address[2] memory toks = [address(usdc), address(handler.dai())];
        address[2] memory colls = [address(handler.vault()), address(handler.vault2())];
        address[] memory who = _distinctLenders();
        for (uint256 a; a < who.length; a++) {
            for (uint256 t; t < 2; t++) {
                for (uint256 c; c < 2; c++) {
                    (uint256 lent,) = ace.lenderByCollateral(who[a], toks[t], colls[c]);
                    assertEq(lent, _claimsOf(who[a], toks[t], colls[c]), "pooling: a per-collateral lent and its triple's claim book disagree");
                }
            }
        }
    }

    /// @dev The live claims of every market in `allMarketAt`'s space that names this lender, quote and collateral.
    function _claimsOf(address who, address tok, address coll) private view returns (uint256 claimSide) {
        for (uint256 i; i < handler.allMarketCount(); i++) {
            if (handler.quoteOf(i) != tok || handler.collOf(i) != coll) continue;
            bytes32 m = handler.allMarketAt(i);
            if (ace.idToMarketParams(m).lender != who) continue;
            uint256[] memory ids = ace.marketLoans(m, 0, ace.marketLoansLength(m));
            for (uint256 k; k < ids.length; k++) {
                claimSide += read.claimOf(m, ids[k]);
            }
        }
    }

    /// @notice A POOL IS KEYED BY (lender, quote) AND THE QUOTE HALF IS LOAD-BEARING.
    /// @dev A lender running a usdc market and a dai one holds TWO pools, and no action in one may move
    /// @dev the other. Crossing them is the natural failure of this shape -- Fluid keys the same way --
    /// @dev and it is invisible to every per-market property, because both markets are individually fine.
    /// @dev Asserted as a LEDGER identity rather than a delta: a dai pool whose legs exceed what the dai
    /// @dev markets could possibly hold has taken usdc's money, whatever path it came by.
    function _invariant_poolsNeverCrossQuotes() public view {
        address[2] memory toks = [address(usdc), address(handler.dai())];
        address[] memory who = _distinctLenders();
        for (uint256 t; t < toks.length; t++) {
            uint256 ceiling = MockERC20(toks[t]).balanceOf(address(ace));
            for (uint256 a; a < who.length; a++) {
                (uint256 resting,, uint256 owed) = read.lenderPools(who[a], toks[t]);
                assertLe(resting + owed, ceiling, "pooling: a pool's hub-held legs exceed the hub's balance in that token");
            }
        }
    }

    /// @dev DELETED with the rearm policy: `_invariant_oneRearmPolicyPerPool`. It walked every (lender, quote)
    /// @dev pair and required at most one live policy, naming a market that lender owned in that quote.
    /// @dev `Storage.lenders().rearm` is gone, so there is no per-pool struct left to hold a second one.

    /// @notice THE DUST WALL IS A PROPERTY OF THE TWO LENDER DOORS, never of the resting balance.
    /// @dev IT WAS WRITTEN AS A STATE INVARIANT AND THAT WAS FALSE. The old form asserted no market ever
    /// @dev rests strictly between zero and `minDebt`, on the reasoning that neither door can leave it
    /// @dev there -- naming two doors when there are THREE. The DRAW lowers resting cash too and has no
    /// @dev remainder test, so `minDebt` 10, rest 15, draw 10 leaves 5, in one ordinary call.
    /// @dev It passed only because the fuzzer never composed that draw, which is the shape this campaign
    /// @dev exists to catch and is worth saying out loud: a green invariant that cannot fail reads exactly
    /// @dev like a true one. Ruled ACCEPTED on the draw side rather than railed -- a draw-side floor would
    /// @dev refuse an otherwise-good draw or force it to take the lot, and nothing is trapped in the band.
    /// @dev So what is asserted is what actually holds: neither LENDER door ever leaves a market there.
    /// @dev It is latched per action rather than read off the state, because the draw is allowed to.
    function _invariant_noLenderDoorLeavesDust() public view {
        assertFalse(handler.lenderDoorLeftDust(), "dust wall: a deposit or withdraw left unreserved cash under the market's own minDebt");
    }

    /// @notice NO COLLATERAL, NO CLAIM: a loan holding nothing in escrow carries no live claim against it.
    /// @dev Morpho Blue's `invariantBadDebt` in the pooled shape -- a position with zero collateral must
    /// @dev carry zero debt, or the lender is owed by nobody and the shortfall is already realized.
    /// @dev Closed loans are exempt: settlement retires the claim, and the escrow empties with it.
    function _invariant_zeroCollateralMeansZeroClaim() public view {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < ids.length; i++) {
            Loan memory l = read.loan(ids[i]);
            if (l.closedAt != 0 || l.collateralUnits != 0) continue;
            assertEq(read.claimOf(ace.loanMarket(ids[i]), ids[i]), 0, "a live loan holding no collateral still carries a claim");
        }
    }

    /// @notice SOLE TENANCY: nobody but a market's named lender ever deposits into it, withdraws from it or takes its pots.
    /// @dev The handler already sends strangers to all three doors; this is the assertion those draws were missing.
    /// @dev No ledger sees the breach: a stranger's deposit credits the MARKET LENDER's pool, so every identity still balances.
    function _invariant_onlyTheLenderMovesItsMoney() public view {
        assertFalse(handler.strangerMovedMoney(), string.concat("TENANCY: a stranger's call landed at a lender door -- ", handler.strangerMovedBy()));
    }

    /// @notice A CLOSED LOAN HOLDS NO FEE ESCROW: every close earns it, refunds it or carries it, and none leaves it behind.
    /// @dev Solvency cannot see a strand here: it books every loan's escrow, closed or not, so one owned by nobody still balances.
    /// @dev Walks every id the hub issued; an order's id has no loan record, reads open, and is skipped.
    /// @dev NOT asserted of `debt`: settlement never zeroes a closed loan's debt, and nothing reads it once closed.
    function _invariant_aClosedLoanHoldsNoEscrow() public view {
        uint256 n = read.loanCount();
        for (uint256 id = 1; id <= n; id++) {
            if (read.loan(id).closedAt == 0) continue;
            assertEq(read.feeEscrowOf(id), 0, "ESCROW: a closed loan still holds a fee escrow no close earned, refunded or carried");
        }
    }

    /// @notice `settleExpired` refuses inside a loan's roll window and pays its caller nothing.
    /// @dev Code 1: it landed inside the window, which is the borrower's roll. Code 2: it credited its caller a sliver.
    function _invariant_theUnpaidBackstopKeepsItsTerms() public view {
        if (handler.backstopCode() != 0) console2.log("backstop loan", handler.backstopLoanId());
        assertEq(uint256(handler.backstopCode()), 0, "BACKSTOP: settleExpired landed inside the roll window, or paid its caller");
    }

    /// @dev Every loan the INCUMBENT market (`mid`) has opened, from the hub's own append-only registry.
    /// @dev The attribution legs are scoped to that one market; the other three are covered per market elsewhere.
    /// @dev The hub is the authority here: a handler ghost cannot see the ids the hub mints for itself.
    function _marketLoans() private view returns (uint256[] memory) {
        return ace.marketLoans(mid, 0, ace.marketLoansLength(mid));
    }

    /// @dev Credit-bearing verbs; each can raise `unitOwed` and floor the matching index once per class.
    function _creditEvents() private view returns (uint256 n) {
        n = handler.callCount("open") + handler.callCount("repay") + handler.callCount("refinance");
        n += handler.callCount("deleverage");
        n += handler.callCount("buyInventory") + handler.callCount("finalize") + handler.callCount("forceClose");
        n += handler.callCount("withdrawCollateral") + handler.callCount("claimOwed");
    }

    // ---- 5b. The mirror books only what somebody OWNS ----

    /// @notice THE SHIPPED VIEW EQUALS THE STORAGE IT REPORTS, per (lender, quote) pool.
    /// @dev It replaces the safety/tightness pair, both of which measured a per-HOLDER split of one class.
    /// @dev There is one claimant per market by construction now, so "who owns this wei" is answered by
    /// @dev typing and the only thing left to get wrong is the READ -- which integrators use and no other
    /// @dev property in this file exercises. An EQUALITY: a flooring gap here would be a view defect.
    function _invariant_claimableIsThePool() public view {
        address[2] memory toks = [address(usdc), address(handler.dai())];
        for (uint256 t; t < toks.length; t++) {
            for (uint256 a; a < 3; a++) {
                address who = handler.lenders(a);
                assertEq(lens.claimable(who, toks[t]), read.unitOwed(who, toks[t]), "the claimable view diverged from the pool it reports");
            }
        }
    }

    /// @notice TIGHTNESS: what the mirror books but NOBODY OWNS is bounded by flooring dust alone.
    /// @dev THE LEG THAT CATCHES THE DEFECT CLASS. Over-reserving is invisible to a solvency equality,
    /// @dev so a mirror counting quote with no owner passes every other check in this file.
    /// @dev EVERY BOOKED WEI HAS AN OWNER is the claim -- never that every owner can act on it.
    /// @dev A burn breaks the second and never the first, which is why it may not redden this.
    /// @dev `unclaimableStrand` carries the ACCEPTED materialization gap, which is a view, not a leak.
    /// @dev It is the genuinely ownerless half: no receipt exists, so no holder can be named at all.
    /// @dev BOUND, derived not chosen: a credit floors the index once per class, losing under a wei,
    /// @dev and each holder's payout floors once more, so under `3 + creditEvents` wei per class.
    /// @dev It is orders of magnitude under a real strand, which is PROPORTIONAL to the units involved.
    // DELETED by typing: `_invariant_unitOwedIsFullyAttributed` bounded quote the mirror booked to NOBODY. One claimant owns all of it: no unowned remainder.

    /// @notice COVERAGE: every OPEN loan holds the collateral its own live claims will ask for at settlement.
    /// @notice `collateralNeeded` is a sum of PER-TICK ceilings; the withdrawal gate takes ONE over the whole debt.
    /// @dev A sum of ceilings is not the ceiling of a sum, so the gate has to carry the funded tick count too.
    /// @dev CANNOT FIRE HERE, and that is understood: `unitScale` is 1e30 against tick prices near 1e18.
    /// @dev One collateral wei buys ~1e-12 of quote, so a per-tick ceiling is negligible beside the `k` margin.
    /// @dev `AceCoverageInvariants` runs the same assertion at 8-dec collateral / 18-dec quote, where it bites.
    function _invariant_collateralCoversEveryLiveClaim() public view {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < ids.length; i++) {
            Loan memory l = read.loan(ids[i]);
            if (l.closedAt != 0) continue;
            /// @dev The loan's OWN market: asked of another it reports a need of zero, which any balance satisfies.
            assertLe(lens.collateralNeeded(ace.loanMarket(ids[i]), ids[i]), l.collateralUnits, "coverage: a live loan cannot fill its own claims");
        }
    }

    // DELETED with the pair it guarded: `_invariant_theAttributionLegsAreExercised` was the anti-vacuity check over classes; there are none.

    // ---- 5c. And every wei it PAYS OUT is attributed to a named holder ----

    /// @notice NO LEAKAGE: every wei that left the unit-holder pot is decomposed by payee address.
    /// @dev The legs above bound what the mirror still OWES; nothing bounded what it already PAID.
    /// @dev A fall in `unitOwed` has ONE destination -- a claim PAYOUT -- so a fall lands in a named lender's
    /// @dev balance or nowhere. IT WAS A SUM of two terms while a re-rest could take a fall without paying a
    /// @dev wallet; that verb is deleted, and dropping the second term TIGHTENS this rather than relaxing it.
    /// @dev Each lender's realized term is their own quote DELTA, so it checks a transfer, not a reported figure.
    /// @dev TEETH: a THIRD destination, or a payee outside the fuzzed set, breaks it -- and solvency sees neither.
    /// @dev DECOMPOSED PER TOKEN, not summed across them: adding usdc wei to dai wei would let a shortfall
    /// @dev in one be masked by a surplus in the other, which is the exact failure this is meant to catch.
    function _invariant_everyReleasedWeiHasANamedPayee() public view {
        address[2] memory toks = [address(usdc), address(handler.dai())];
        uint256 realizedAll;
        for (uint256 t; t < toks.length; t++) {
            uint256 realized;
            for (uint256 a; a < 3; a++) {
                realized += handler.realizedQuoteOf(handler.lenders(a), toks[t]);
            }
            assertEq(realized, handler.quoteReleasedEverOf(toks[t]), "attribution: the pot released quote no payee pulled");
            realizedAll += realized;
        }
        /// @dev WHAT THIS LEG CATCHES, AND WHAT IT DOES NOT -- stated because a comment claiming more than its
        /// @dev assertion tests is the vacuous-row shape one level up. Both sides are written by the SAME
        /// @dev `_foldOwed` statement, so it CANNOT catch that statement over-banking; the per-token equality
        /// @dev above is what carries that, since `realized` comes from balance deltas and `released` from
        /// @dev falls in `owed`, and those are computed independently.
        /// @dev WHAT IT DOES CATCH is attribution to an address OUTSIDE the three fuzzed lenders: the sum walks
        /// @dev `lenders(0..2)` while the total counts every pool, so a market whose lender is not one of them
        /// @dev banks into the total and not into the sum. That is a real and reachable divergence once a
        /// @dev handler creates markets more freely than this one does.
        /// @dev IT IS A NET FOR A FUTURE HANDLER rather than a catch for a live bug -- no over-attribution is
        /// @dev constructible today, since `withdraw` raises a wallet while leaving `owed` flat, so `fell` is
        /// @dev zero and nothing banks. Kept for the same reason the per-token leg is: cheap, and the failure
        /// @dev it names is invisible to solvency.
        assertEq(realizedAll, handler.quoteDeliveredEver(), "attribution: a wei was banked to nobody the fuzzer names");
    }

    /// @dev DELETED with the rearm policy: `_invariant_aRearmMovesNoToken`. It pinned that a re-rest
    /// @dev reclassified `unitOwed` and transferred nothing, and that its preview agreed with the verb.
    /// @dev No verb and no preview, so no property: the credit leg falls only when a `collect` pays it.

    // DELETED with the receipts: `_invariant_noPayoutToANeverHolder` refused a payout to an address that never held the class. One claimant, named in the id.

    // DELETED with the token: `_invariant_aMoveShiftsNoAccrual` pinned that a unit TRANSFER redirects no accrual between holders. No transfer, no holders.

    // ---- 6. The latched doctrine claims ----

    /// @notice A deposit followed by an immediate full exit never returns more than was put in.
    function _invariant_noTheft() public {
        if (handler.theftFlag()) {
            emit log_named_uint("theft market", handler.theftMarket());
            emit log_named_uint("value in ", handler.theftValueIn());
            emit log_named_uint("value out", handler.theftValueOut());
        }
        assertFalse(handler.theftFlag(), "THEFT: deposit-then-exit extracted more value than deposited");
    }

    /// @notice A lender exit naming a third party pays that party exactly what it reports, measured at the payee.
    /// @dev THE TWO EQUALITIES ARE WHAT STOP THIS PASSING OVER EXITS THAT PAID NOBODY: every redirected withdraw
    /// @dev that returned asked a nonzero fill, and every redirected collect that found credit owed it, so each
    /// @dev must show up at the payee. A `0 == 0` report passes the misdelivery check and fails these.
    /// @dev THE FLOOR LEG: one withdraw in four is floored a wei above its fill, and only `BelowCallerFloor` may answer it.
    /// @dev THE STRANGER LEG: a non-lender's `collect` naming the market lender as `to` must leave that lender's pool alone.
    function _invariant_aRedirectedExitReachesItsPayee() public view {
        assertFalse(handler.redirectMisdelivered(), "REDIRECT: withdraw or collect reported a payout its named payee did not receive");
        assertEq(handler.redirectWithdrawsPaid(), handler.redirectWithdrawsLanded(), "REDIRECT: a redirected withdraw returned and paid nobody");
        assertEq(handler.redirectCollectsPaid(), handler.redirectCollectsOwed(), "REDIRECT: a redirected collect found credit and paid nobody");
        assertFalse(handler.redirectFloorIgnored(), "REDIRECT: a withdraw floored above its fill was not refused with BelowCallerFloor");
        assertFalse(handler.collectReachedAnotherPool(), "STRANGER: a non-lender's collect moved the market lender's pool");
    }

    /// @notice A SALE PAYS NOBODY: every landed buy leaves its seller's wallet flat and credits the seller's pool by exactly the fill.
    /// @dev The one door a buy's proceeds may leave by is a later terminal close or the lender's own `collect`, never the buy.
    /// @dev `_foldOwed` cannot see this: it banks a pushed wei as an ordinary release to a named lender, so solvency and attribution both hold.
    function _invariant_aSaleNeverPays() public {
        if (handler.salePaidSomeone()) emit log_named_uint("sale loan", handler.salePaidLoanId());
        assertFalse(handler.salePaidSomeone(), "SALE: a buy moved its seller's quote balance, or credited the pool by other than the fill");
    }

    /// @notice Neither trades nor idle cash move a loan's funding floor: only the money at work behind it ever set it, once, at the draw.
    function _invariant_floorLaw() public {
        if (handler.floorViolated()) {
            emit log_named_string("action", handler.floorAction());
            emit log_named_uint("loan", handler.floorLoanId());
            emit log_named_uint("floor before", handler.floorBefore());
            emit log_named_uint("floor after ", handler.floorAfter());
        }
        assertFalse(handler.floorViolated(), "FLOOR: a non-loan action moved a loan's funding floor");
    }

    /// @notice A deleverage crank NEVER raises the loan's trigger, on any crank the market admits.
    /// @notice NO per-crank test of it exists: the guarantee is GENESIS-enforced, never checked per crank.
    /// @dev Asserted over the crank precisely BECAUSE the guarantee is a config property rather than an arithmetic one.
    /// @dev Cross-multiplied in the handler, so it pins the ratio with no division and cannot drift.
    /// @dev RENAMED from `_invariant_skimNeverRaisesTheTrigger`, and NOT deleted with the skim channel:
    /// @dev the handler always drove `ace.deleverage` here, under a tag the rename never reached.
    /// @dev Deleverage is the only sale against a live loan, so this is the surviving no-raise law.
    function _invariant_deleverageNeverRaisesTheTrigger() public {
        if (handler.deleverageRaisedTrigger()) {
            emit log_named_uint("loan", handler.deleverageTriggerLoanId());
            emit log_named_uint("debt retired", handler.deleveragePay());
            emit log_named_uint("units sold  ", handler.deleverageUnitsSold());
            emit log_named_uint("debt before ", handler.deleverageDebtBefore());
            emit log_named_uint("coll before ", handler.deleverageCollBefore());
        }
        assertFalse(handler.deleverageRaisedTrigger(), "DELEVERAGE: a crank sold collateral without retiring its share of debt");
    }

    /// @notice Settlement is terminal: a closed loan never reopens.
    function _invariant_settlementMonotonicity() public {
        if (handler.monotonicityViolated()) emit log_named_uint("loan", handler.monoLoanId());
        assertFalse(handler.monotonicityViolated(), "SETTLE: a settled (closed) loan reopened");
    }

    /// @dev inv-15 (the flagged-deficit law) RETIRED 2026-08-18 with the exit flags themselves:
    /// @dev nothing reserves against a draw; an exiting lender withdraws resting cash or sells units.

    /// @notice A refinance retires ONE loan's floor and writes ONE new one.
    /// @notice No other loan's funding floor may move while it does so.
    /// @dev SUCCEEDS `invariant_rotationNeverMovesTheFloor`, deleted with the rotation it watched.
    /// @dev Still the floor law's hardest case: this verb really moves money at work behind a loan.
    /// @dev Every other action the floor ghosts watch is pure and moves no claim at all.
    /// @dev It re-cashes and re-draws over the SAME ladder every other loan sits on.
    /// @dev That is exactly where a cross-loan floor rewrite would hide from every balance check.
    function _invariant_refinanceNeverMovesAnotherLoansFloor() public {
        if (handler.refinanceMovedFloor()) {
            emit log_named_uint("loan", handler.refinanceFloorLoanId());
            emit log_named_uint("floor before", handler.refinanceFloorBefore());
            emit log_named_uint("floor after ", handler.refinanceFloorAfter());
        }
        assertFalse(handler.refinanceMovedFloor(), "REFINANCE: a refinance moved another loan's funding floor");
    }

    /// @dev `invariant_pooledSlicesNeverExceedInventory` folded into the class-supply invariant above:
    /// @dev the pot pays pro-rata of LIVE units from two live numbers, so nothing can over-promise.

    /// @dev RETIRED 2026-08-13: `invariant_aFillerFundsItsOwnLeg` guarded `sellFill`'s ForeignFunder.
    /// @dev The ask has no funder parameter -- the buyer IS msg.sender, so nothing is left to refuse.
    /// @dev It succeeded `invariant_onlyTheVenueMayFill`, which retired the same way with the venue.

    // ---- 7. Revenue routing: two disjoint pots, one exit each ----

    uint256[6] private _lastRevenueOf; // per market over `allMarketAt`'s index space, CANARIES INCLUDED
    mapping(address => uint256) private _lastTreasuryOf; // per QUOTE TOKEN: one treasury balance each

    /// @notice protocolRevenue may only ever fall into the treasury, never be clawed back out of it.
    /// @notice ONE pot, ONE exit, against the shipped TREASURY (AceFixtures.TREASURY).
    /// @dev Treasury monotonicity is armed every call: no fuzzed action may pay the treasury back out.
    /// @dev Conservation arms when a pot falls, pinning that the treasury took at least that much.
    /// @dev THE TWO GHOSTS SIT AT DIFFERENT SCOPES: `protocolRevenue` is per MARKET, the treasury per TOKEN.
    /// @dev THE ONE LATCHING PROPERTY, so it runs ONCE PER STEP and never inside a per-market loop.
    /// @dev Looped, one market's call advances the treasury latch and the next reddens on correct behaviour.
    /// @dev DROPS ARE SUMMED, never levels differenced, so an accrual cannot net off a sweep elsewhere.
    /// @dev CANARIES ARE IN THE WALK: one that banks and loses revenue in an action shows zero at both ends.
    function _invariant_revenueOnlyLeavesViaTheSweep() public {
        address[2] memory toks = [address(usdc), address(handler.dai())];
        for (uint256 t; t < toks.length; t++) {
            uint256 tre = MockERC20(toks[t]).balanceOf(TREASURY);
            assertGe(tre, _lastTreasuryOf[toks[t]], "REVENUE: the treasury balance fell -- nothing may claw it back");
            uint256 dropped;
            for (uint256 i; i < handler.allMarketCount(); i++) {
                if (handler.quoteOf(i) != toks[t]) continue;
                uint256 rev = read.marketState(handler.allMarketAt(i)).protocolRevenue;
                if (rev < _lastRevenueOf[i]) dropped += _lastRevenueOf[i] - rev;
                _lastRevenueOf[i] = rev;
            }
            if (dropped != 0) {
                assertGe(tre - _lastTreasuryOf[toks[t]], dropped, "REVENUE: protocolRevenue fell further than the treasury was paid");
            }
            _lastTreasuryOf[toks[t]] = tre;
        }
    }

    // ---- 7b. Genesis as a MOVE: markets created mid-sequence -- STRANGERS, addressed by nothing ----

    /// @notice A market nobody addressed holds nothing, and its id still commits to its own params.
    /// @notice The sequence question genesis-at-setUp could never ask: creation while the hub is mid-flight.
    /// @dev The strangers are DELIBERATELY outside `allMarketAt`'s space, and that is what gives them teeth.
    /// @dev `_bookedQuote` sums the six KNOWN markets, so quote leaking into a stranger breaks solvency.
    /// @dev Inside that space the same leak would balance on both sides and the identity would pass.
    /// @dev The incumbent half needs nothing here: `createMarket` entitles no market, so `_checkIsolation` catches it.
    function _invariant_genesisMidSequenceIsInert() public view {
        assertFalse(handler.genesisCollided(), "GENESIS: a mid-sequence creation returned an id another market held");
        assertFalse(handler.genesisIdNotItsParams(), "GENESIS: an id stopped committing to the params it resolves to");
        for (uint256 i; i < handler.strangerCount(); i++) {
            MarketState memory s = read.marketState(handler.strangerAt(i));
            assertGt(s.unitScale, 0, "GENESIS: a created market carries no unit scale");
            /// @dev The pooled legs are gone from `MarketState`, so a stranger market's whole footprint is
            /// @dev what it books itself -- and a stranger has no lender pool of its own to inspect either.
            assertEq(s.cash + s.protocolRevenue + s.quoteOwedTotal, 0, "GENESIS: a market no action ever addressed acquired a balance");
        }
    }

    // ---- 7c. The settlement promise: an expired loan settles or rolls, and a refusal is never silence ----

    /// @notice `forceClose` past expiry on a live loan is PROMISED to settle or roll, so a refusal is a regression.
    /// @notice Checked PER STEP, so the sequence that broke it is the one forge reports and minimizes.
    /// @dev Not a hit count: a zero `expiryFolds` reads identically to a campaign that never reached expiry.
    /// @dev The handler establishes both declared preconditions before it calls, so code 1 is a flat contradiction.
    /// @dev Code 2 is the promise breaking downstream of them, which is where a settlement regression would live.
    function _invariant_forceCloseHonoursItsPromise() public {
        if (handler.forceCloseCode() != 0) {
            emit log_named_uint("forceClose refusal code", handler.forceCloseCode());
            emit log_named_uint("on loan", handler.forceCloseLoanId());
            emit log_named_bytes32("refusal selector", bytes32(handler.forceCloseSelector()));
        }
        assertEq(uint256(handler.forceCloseCode()), 0, "SETTLE: forceClose refused a live loan at or past expiry, which it promises to settle or roll");
    }

    // ---- 7d. The no-flip rule: no third party changes an armed loan's NEXT fold ----

    /// @notice No third party turns an armed loan's expiry fold from ROLL into SETTLE (#674, #666, #514; #403's regime 1).
    /// @notice The levers: a `deleverage` crank, a stranger's drain (persistent and atomic), a fill of someone's order,
    /// @notice a partial repay, a route-in from another market, and a push of a movable record under the lender's price.
    /// @dev The handler runs the real fold at expiry in a snapshot before and after each lever; only the lever differs.
    /// @dev The subject always holds `reserved >= need`, which is the property's premise: a borrower's own repay can forfeit it.
    /// @dev A successor born DISARMED is not a flip -- it is the accepted chain residual, counted apart in `bracketDisarms`.
    /// @dev Witnessed structurally for the crank: `baselineNoFlip` REQUIRES the same branch after a 1.2x `minDebt` crank.
    function _invariant_noThirdPartyFlipsAnArmedFold() public {
        if (handler.foldFlipped()) {
            emit log_named_uint("flipped loan", handler.foldFlipLoanId());
            emit log_named_uint("cause (0 crank 1 drain 2 atomic 3 fill 4 repay 5 route 6 record)", handler.foldFlipCause());
            emit log_named_uint("debt before", handler.foldFlipDebtBefore());
            emit log_named_uint("debt after", handler.foldFlipDebtAfter());
        }
        assertFalse(handler.foldFlipped(), "NO-FLIP: a third party turned an armed fold that rolled into one that settles");
    }

    /// @notice A market's roll reserve is EXACTLY the sum of its loans' reservations, and only live, armed loans hold one.
    /// @notice Over EVERY known market: the driven four, the two canaries, and each market created mid-sequence.
    /// @dev Walks the hub's own append-only loan list, so a loan the handler never tracked is counted too.
    /// @dev The two legs are one ledger: a release that forgot to zero its share breaks the second, a drift the first.
    function _invariant_reserveIsTheSumOfLiveShares() public view {
        for (uint256 i; i < handler.marketCount(); i++) {
            _assertReserveLedger(handler.midAt(i));
        }
        for (uint256 i; i < 2; i++) {
            _assertReserveLedger(handler.canaries(i));
        }
        for (uint256 i; i < handler.strangerCount(); i++) {
            _assertReserveLedger(handler.strangerAt(i));
        }
    }

    /// @dev One market's leg of the identity; a canary or a created market holds no loan, so its reserve must read zero.
    function _assertReserveLedger(bytes32 m) internal view {
        uint256[] memory ids = ace.marketLoans(m, 0, ace.marketLoansLength(m));
        uint256 sum;
        for (uint256 k; k < ids.length; k++) {
            uint256 share = read.reservedOf(ids[k]);
            if (share == 0) continue;
            sum += share;
            assertEq(read.loan(ids[k]).closedAt, 0, "RESERVE: a closed loan still holds a roll reservation");
            (uint64 tenor,,) = read.autoPolicyOf(ids[k]);
            assertGt(tenor, 0, "RESERVE: a disarmed loan still holds a roll reservation");
        }
        assertEq(sum, read.rollReserve(m), "RESERVE: a market's roll reserve is not the sum of its live loans' shares");
    }

    /// @notice A live armed loan's share never exceeds its expiry roll's need at today's debt, floored at the dust band's worst (YI-26).
    /// @notice The sum identity above cannot see a stale share: a share sized at the arm-time debt IS a live armed loan's share.
    /// @dev The need is re-derived from the fee algebra, never read off the hub: the floored successor less the debt it recycles.
    /// @dev The floor is the need at one atom of debt, `minDebt - 1`: a shrink keeps it so a later dust repay stays covered (code-review 1).
    function _invariant_anArmedShareNeverExceedsItsRollsNeed() public view {
        for (uint256 i; i < handler.marketCount(); i++) {
            bytes32 m = handler.midAt(i);
            uint256[] memory ids = ace.marketLoans(m, 0, ace.marketLoansLength(m));
            for (uint256 k; k < ids.length; k++) {
                uint256 share = read.reservedOf(ids[k]);
                if (share == 0) continue;
                (uint64 tenor,,) = read.autoPolicyOf(ids[k]);
                uint256 cap = _rollNeed(m, read.loan(ids[k]).debt, tenor);
                uint256 dust = _rollNeed(m, 1, tenor);
                if (dust > cap) cap = dust;
                assertLe(share, cap, "RESERVE: an armed share outgrew its roll's need at today's debt, floored at the dust band's worst");
            }
        }
    }

    /// @notice A live loan's trigger never exceeds its market's price (#738 C-16): the bound `Deleverage._fit` and settlement rest on.
    /// @dev Admission puts it at or under `min(price, record)`; a withdrawal keeps it under the line's fold; a melt only lowers it.
    function _invariant_aLiveTriggerNeverExceedsThePrice() public view {
        for (uint256 i; i < handler.marketCount(); i++) {
            bytes32 m = handler.midAt(i);
            uint256 price = ace.idToMarketParams(m).price;
            uint256[] memory ids = ace.marketLoans(m, 0, ace.marketLoansLength(m));
            for (uint256 k; k < ids.length; k++) {
                if (read.loan(ids[k]).closedAt != 0) continue;
                assertLe(read.triggerPrice(ids[k]), price, "TRIGGER: a live loan's trigger sits over its market's price");
            }
        }
    }

    /// @dev What an expiry roll of `debt` at `tenor` draws fresh in market `m`: `max(principalForOwed(debt), minDebt) - debt`.
    function _rollNeed(bytes32 m, uint256 debt, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(m);
        uint256 succ = LoanMath.principalForOwed(debt, tenor, p.baseBps, p.minTenor);
        if (succ < p.minDebt) succ = p.minDebt;
        return succ > debt ? succ - debt : 0;
    }

    /// @notice No fresh draw takes reserved cash: only a lender's own door may leave a market under its roll reserve.
    /// @dev Latched per action, since the lender's withdraw may legally leave that state and the draws never may.
    function _invariant_noFreshDrawBreachesTheReserve() public view {
        assertFalse(
            handler.reserveBreached(), string.concat("RESERVE: a non-lender action left cash under the roll reserve -- verb ", handler.reserveBreachedBy())
        );
    }

    // ---- 8. Deterministic coverage proofs: the invariants above are not asserting over dead state ----

    /// @notice The WHOLE protocol fee stays in the hub and lands in `protocolRevenue`.
    /// @dev Replaces `test_Coverage_BribeCarveLeavesTheHub`, which pinned an origination carve pushed OUT to a sink; both died with the carve.
    /// @dev Deleting that invariant beat keeping it: a sink that never receives trivially never falls, so it would have gone VACUOUS, not red.
    function test_Coverage_WholeProtocolFeeStaysInTheHub() public {
        uint256 revenueBefore = read.marketState(mid).protocolRevenue;
        handler.open(0, 0, 4_000e6);
        assertGt(read.marketState(mid).protocolRevenue - revenueBefore, 0, "the origination fee accrued to revenue");
        assertEq(usdc.balanceOf(address(ace)), _bookedQuote(), "and every wei of it is still booked in the hub");
        assertGt(handler.loansOpened(), 0, "the coverage open really opened a loan");
    }

    /// @notice Inventory really moves, so LR-9 reconciles nonzero state rather than the trivial 0 == 0.
    /// @dev THE MINT SIDE IS SETTLEMENT NOW, seeded in the handler's constructor baseline.
    /// @dev `sellFill` used to mint it here; with the bid side deleted, title transfer is the only door.
    function test_Coverage_FillsMoveInventory_ReconNonTrivial() public {
        uint256 inv = _sumInventory();
        assertGt(inv, 0, "settlement minted ladder inventory");
        MarketState memory s = read.marketState(mid);
        assertGt(s.cumulativeBackedBurns, 0, "backed burns credited");
        assertEq(s.cumulativeBackedBurns - s.netSyntheticOutflow, inv, "LR-9 non-trivial on settled inventory");

        // THE ASK is the outflow at an OPEN tick, and that is the whole point of restoring it
        uint256 drainedBefore = handler.buyInventoryUnits(); // the ctor seeded this ghost, so a zero guard passes on a buy that drained nothing
        handler.buyInventory(2_000e6);
        assertGt(handler.buyInventoryUnits(), drainedBefore, "the ask leg drained settled inventory");
        s = read.marketState(mid);
        assertGt(s.netSyntheticOutflow, 0, "netSyntheticOutflow grew");
        assertEq(s.cumulativeBackedBurns - s.netSyntheticOutflow, _sumInventory(), "LR-9 holds after both outflows");
    }

    /// @notice THE SALE LATCH REALLY MEASURES A FILL: a written buy fills, is checked against its seller, and trips nothing.
    /// @dev The ctor's own buy already counts one checked fill, so the row asks for a RISE, never a non-zero.
    function test_Coverage_ASaleIsCheckedAgainstItsSellerAndPaysNobody() public {
        uint256 checked = handler.saleFillsChecked();
        uint256 drained = handler.buyInventoryUnits();
        handler.buyInventory(2_000e6);
        assertGt(handler.buyInventoryUnits(), drained, "PREMISE: the written buy drained settled inventory");
        assertGt(handler.saleFillsChecked(), checked, "the filled buy was measured against its seller");
        _invariant_aSaleNeverPays();
    }

    /// @notice THE CREDIT ROUND TRIP really runs: a repay credits the pool and a collect pays it out.
    /// @dev REPLACES `test_Coverage_UnitVerbsMoveRealState` and `test_Coverage_PayoutAttributionIsDrivenByRealClaims`,
    /// @dev which drove `materialize`, `transferUnits` and `claimUnits` -- three receipt-ledger verbs
    /// @dev that no longer exist. What they were really buying is that the credit path is not a
    /// @dev constructor-only ghost, and that survives: it is just one write and one door now.
    /// @dev The per-address decomposition leg survives too, and is the sharper half -- "the money reached
    /// @dev the LENDER" is the thing worth driving deterministically.
    function test_Coverage_TheCreditPathMovesRealState() public {
        handler.repay(0, _halfOfLoanZerosDebt());
        assertGt(handler.callCount("repay"), 0, "the repay that funds the credit leg did not run");

        uint256 owedBefore = read.unitOwed(handler.lenders(0), address(usdc));
        for (uint256 a; a < 3; a++) {
            handler.collect(0, a);
        }
        assertGt(handler.quoteClaimed(), 0, "collect paid nothing, so the credit door is a dead branch");
        assertLt(read.unitOwed(handler.lenders(0), address(usdc)), owedBefore + 1, "the credit leg did not fall on a collect");

        assertGt(_realizedUsdc(), 0, "no lender realized a wei: the decomposition is over an empty sum");
        /// @dev AN EQUALITY, RESTORED. It was briefly relaxed to `<=` when the push gave the credit leg a
        /// @dev second door, and a one-sided bound cannot catch the per-address map OVER-counting -- which is
        /// @dev the failure this leg exists for. The equality holds here because this row drives a PARTIAL
        /// @dev repay and then collects: nothing in it reaches a terminal close, so every wei the lenders
        /// @dev realized came through the collect door and `quoteClaimed` is the whole of it.
        /// @dev THE TWO SIDES ARE INDEPENDENT, which is what gives it teeth: the left is a sum of returned
        /// @dev `paid` values, the right a sum of measured BALANCE DELTAS. A hub that reported a payout it did
        /// @dev not make breaks this, and so does a handler that banks a delta to the wrong address.
        assertEq(handler.quoteClaimed(), _realizedUsdc(), "the per-address decomposition lost a wei");
        assertFalse(handler.collectReachedAnotherPool(), "a caller's collect moved the market lender's pool");
        assertEq(usdc.balanceOf(address(ace)), _bookedQuote(), "and the hub reconciles after the collects");
    }

    /// @dev A repay the handler's seed-0 pick is GUARANTEED to leave partial: half of that loan's live debt.
    /// @dev A literal above the debt only did this by `bound`'s wraparound, which is not a thing to lean on.
    function _halfOfLoanZerosDebt() internal view returns (uint256 amt) {
        amt = read.loan(handler.loanIds()[0]).debt / 2;
        require(amt > 0, "PREMISE: loan 0 carries no debt to repay partially");
    }

    /// @dev Quote the fuzzed lenders have really pulled in USDC, which is the whole of what left `unitOwed`.
    function _realizedUsdc() internal view returns (uint256 s) {
        for (uint256 a; a < 3; a++) {
            s += handler.realizedQuoteOf(handler.lenders(a), address(usdc));
        }
    }

    /// @notice THE REDIRECTED EXITS REALLY PAY: both legs of `exitTo` move quote to the payee, and the floor refuses.
    /// @dev THIS ROW IS REDIRECT'S COVERAGE GUARD, written rather than counted in `afterInvariant`, and on purpose.
    /// @dev forge reverts ghosts between runs, and `exitTo` is one selector of 27 split three ways, so a per-run
    /// @dev `> 0` on each leg is the selector lottery the run report refuses for every other verb.
    /// @dev The per-step equalities in REDIRECT make every exit that DOES run pay or refuse correctly; this row
    /// @dev makes each leg run, with the state it needs written rather than drawn.
    function test_Coverage_TheRedirectedExitsPayTheirPayee() public {
        handler.repay(0, 5_000e6); // a partial repay credits the tenant's pool, so the collect leg has credit to move
        address payee = handler.payee();
        uint256 had = usdc.balanceOf(payee);

        handler.exitTo(0, 1_000e6, 2); // an even legSeed is the withdraw leg; 2 floors it AT its fill
        assertGt(handler.redirectWithdrawsPaid(), 0, "the redirected withdraw paid nobody");
        handler.exitTo(0, 1_000e6, 0); // 0 floors it a wei ABOVE its fill
        assertGt(handler.redirectFloorsRefused(), 0, "the over-floored withdraw was not refused by BelowCallerFloor");
        assertGt(ace.lenderOwed(handler.lenders(0), address(usdc)), 0, "premise: the tenant's pool holds credit to redirect");
        handler.exitTo(0, 0, 1); // an odd legSeed is the collect leg
        assertGt(handler.redirectCollectsPaid(), 0, "the redirected collect paid nobody");

        assertGt(usdc.balanceOf(payee), had, "and the payee's own balance is what moved");
        _invariant_aRedirectedExitReachesItsPayee();
        _invariant_everyReleasedWeiHasANamedPayee();
        assertEq(usdc.balanceOf(address(ace)), _bookedQuote(), "and the hub reconciles after the redirects");
    }

    /// @notice SOLE TENANCY at all three lender doors, driven by a stranger with something there to take.
    /// @dev Actor seed 4 is `lenders[1]`, who runs M2 and NOT the incumbent, so every call below is a stranger's.
    function test_Coverage_StrangersAreRefusedAtEveryLenderDoor() public {
        uint256 refused = handler.strangerDoorsRefused();
        handler.deposit(0, 4, 1_000e6);
        handler.withdraw(0, 4, 1_000e6);
        handler.redeemInKind(4, _aPotInTheIncumbent());
        assertEq(handler.strangerDoorsRefused(), refused + 3, "a stranger's call at a lender door did not refuse");
        _invariant_onlyTheLenderMovesItsMoney();
    }

    /// @dev The tracked index of a settled loan in `mid` whose pot still holds units, so a redeem has something to move.
    function _aPotInTheIncumbent() internal view returns (uint256) {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < ids.length; i++) {
            if (ace.loanMarket(ids[i]) == mid && read.invPotOf(mid, ids[i]) != 0) return i;
        }
        revert("PREMISE: the baseline left no settled pot in the incumbent market");
    }

    /// @notice THE ASK-OFF LATCH REALLY SEES A POT: one settles in the ask-off market, a buy leaves it whole, its lender takes it in kind.
    /// @dev Written rather than counted in `afterInvariant`: one market's settled pot is a lottery in any single run.
    /// @dev Every figure is a RISE over what the baselines left, so a pot a baseline had already made cannot satisfy the row.
    function test_Coverage_AnAskOffPotIsRefusedTheAskAndFallsOnlyInKind() public {
        (bytes32 askOff, address lender, address coll) = handler.askOffMarket();
        assertFalse(ace.idToMarketParams(askOff).inventoryAsk, "PREMISE: the hub stored that market with the ask off");
        uint256 idx = _aLiveLoanIn(askOff);
        uint256 loanId = handler.loanIds()[idx];
        uint256[3] memory had = [handler.askOffPotsSeen(), handler.askOffInKindExits(), MockERC20(coll).balanceOf(lender)];

        handler.forceClose(idx);
        uint256 pot = read.invPotOf(askOff, loanId);
        assertGt(pot, 0, "PREMISE: the fold left a pot in the ask-off market");
        assertEq(handler.askOffPotsSeen(), had[0] + 1, "the latch saw the pot appear");

        handler.buyInventory(50_000e6);
        assertEq(read.invPotOf(askOff, loanId), pot, "the campaign's own buy left the ask-off pot whole");
        _invariant_anAskOffPotFallsOnlyInKind();

        handler.redeemInKind(1, idx); // an actor seed off the stranger draw, so the market's own lender is the caller
        assertEq(read.invPotOf(askOff, loanId), 0, "PREMISE: the lender took the pot in kind");
        assertEq(handler.askOffInKindExits(), had[1] + 1, "the latch counted the in-kind exit");
        assertEq(MockERC20(coll).balanceOf(lender), had[2] + pot, "and every unit of it is in the lender's wallet");
        _invariant_anAskOffPotFallsOnlyInKind();
    }

    /// @dev The tracked index of a live loan in `m`, so a written row can settle it.
    function _aLiveLoanIn(bytes32 m) internal view returns (uint256) {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < ids.length; i++) {
            if (ace.loanMarket(ids[i]) == m && !ace.isClosed(ids[i])) return i;
        }
        revert("PREMISE: the baseline left no live loan in that market");
    }

    /// @notice A loan repaid in full leaves no fee escrow behind: the earned part is credited, the rest refunded.
    function test_Coverage_AFullRepayLeavesNoEscrow() public {
        uint256 n = handler.loanIds().length;
        handler.open(0, 0, 4_000e6);
        assertEq(handler.loanIds().length, n + 1, "PREMISE: the open landed");
        uint256 id = handler.loanIds()[n];
        assertGt(read.feeEscrowOf(id), 0, "PREMISE: the open withheld an escrow");
        handler.repay(n, type(uint256).max); // `bound` maps the max seed onto the whole debt
        assertTrue(ace.isClosed(id), "PREMISE: the full repay closed the loan");
        _invariant_aClosedLoanHoldsNoEscrow();
    }

    /// @notice The unpaid backstop refuses inside a loan's roll window, then settles it once the window has passed.
    function test_Coverage_TheUnpaidBackstopRefusesEarlyAndLandsLate() public {
        uint256 n = handler.loanIds().length;
        handler.open(0, 0, 4_000e6);
        assertEq(handler.loanIds().length, n + 1, "PREMISE: the open landed");
        uint256 refused = handler.backstopEarlyRefused();
        uint256 landed = handler.unpaidSettles();
        handler.settleExpiredAtExpiry(n); // at expiry, inside the roll window
        assertEq(handler.backstopEarlyRefused(), refused + 1, "settleExpired inside the roll window did not refuse");
        handler.warp(type(uint256).max); // `bound` maps the max seed onto 45 days: past the term and its window
        handler.settleExpired(n); // where the clock stands, which is now past the window
        assertEq(handler.unpaidSettles(), landed + 1, "settleExpired past the roll window did not settle");
        assertFalse(ace.isClosed(handler.loanIds()[n]), "and the action rolled its settle back, so no fold is starved");
        _invariant_theUnpaidBackstopKeepsItsTerms();
    }

    /// @notice An armed loan opened ON its coverage line settles at its fold: its successor's fee puts it under that line.
    /// @dev The fold must refuse the roll by the line, and a predicate that forgot the line rolls into a draw that reverts.
    function test_Coverage_ANearLineArmedLoanSettlesAtItsFold() public {
        uint256 n = handler.loanIds().length;
        handler.openNearLine(0, 0, 4_000e6, 5); // slack seed 5: units exactly on the line, then armed
        assertEq(handler.loanIds().length, n + 1, "PREMISE: the on-the-line draw landed");
        uint256 id = handler.loanIds()[n];
        (uint64 armed,,) = read.autoPolicyOf(id);
        assertGt(armed, 0, "PREMISE: the near-line loan is armed");
        uint256 folds = handler.expiryFolds();
        handler.forceClose(n);
        assertEq(uint256(handler.forceCloseCode()), 0, "forceClose refused an armed near-line loan at expiry");
        assertEq(handler.expiryFolds(), folds + 1, "the near-line loan's fold settled rather than rolled");
    }

    /// @notice The fuzzed `forceClose` folds an expired, unarmed loan: the path `make reach` measures as a rate, pinned once here.
    function test_Coverage_TheFuzzedForceCloseFoldsAnExpiredLoan() public {
        uint256 n = handler.loanIds().length;
        handler.open(0, 0, 4_000e6);
        assertEq(handler.loanIds().length, n + 1, "PREMISE: the open landed");
        uint256 id = handler.loanIds()[n];
        (uint64 armed,,) = read.autoPolicyOf(id);
        assertEq(armed, 0, "PREMISE: the loan is not armed, so its fold settles rather than rolls");
        uint256 folds = handler.expiryFolds();
        handler.forceClose(n);
        assertEq(uint256(handler.forceCloseCode()), 0, "forceClose refused an expired, unarmed loan");
        assertEq(handler.expiryFolds(), folds + 1, "the handler's forceClose did not fold the expired loan");
        assertTrue(ace.isClosed(id), "the folded loan is closed");
    }

    /// @notice A `forceClose` drawn onto a CLOSED tracked loan acts on the next live one, so the draw is never wasted.
    /// @dev A closed pick is not owed, so it judged nothing; at depth those picks were what left whole runs without a fold.
    function test_Coverage_ForceCloseSkipsAClosedPickForALiveLoan() public {
        uint256 n = handler.loanIds().length;
        handler.open(0, 0, 4_000e6);
        handler.open(0, 1, 4_000e6);
        assertEq(handler.loanIds().length, n + 2, "PREMISE: both opens landed");
        handler.repay(n, type(uint256).max); // `bound` maps the max seed onto the whole debt
        assertTrue(ace.isClosed(handler.loanIds()[n]), "PREMISE: the first loan is closed");
        uint256 live = handler.loanIds()[n + 1];
        uint256 folds = handler.expiryFolds();
        handler.forceClose(n); // the seed's own slot holds the closed loan
        assertEq(handler.expiryFolds(), folds + 1, "a forceClose drawn onto a closed loan folded nothing");
        assertTrue(ace.isClosed(live), "the live loan after the closed slot is the one that folded");
    }

    /// @notice An armed loan whose successor would sit EXACTLY on its trigger's requirement still settles: the line refuses it.
    /// @dev The roll predicate asks the trigger before the line, and the line is one atom tighter, so this is the only state
    /// @dev where the predicate's line leg decides. A predicate without it admits a roll the draw then refuses, and the fold reverts.
    function test_Coverage_AnArmedLoanOnItsSuccessorsEdgeSettlesAtItsFold() public {
        uint256 n = handler.loanIds().length;
        handler.openNearLine(0, 0, 4_000e6, 7); // slack seed 7: units on the successor's edge, then armed
        assertEq(handler.loanIds().length, n + 1, "PREMISE: the successor-edge draw landed");
        (uint64 armed,,) = read.autoPolicyOf(handler.loanIds()[n]);
        assertGt(armed, 0, "PREMISE: the successor-edge loan is armed");
        uint256 folds = handler.expiryFolds();
        handler.forceClose(n);
        assertEq(uint256(handler.forceCloseCode()), 0, "forceClose refused an armed loan on its successor's edge");
        assertEq(handler.expiryFolds(), folds + 1, "the edge loan's fold settled rather than rolled");
    }

    /// @dev DELETED with the rearm policy: `test_Coverage_ARearmIsDrivenAndMovesNoToken`. It armed each lender,
    /// @dev cranked `compound` from a stranger, and pinned that the hub's balance stayed flat across it.
    /// @dev The attribution identity it fed a second term to is one term now, which the row above already drives.

    // DELETED with the token: `test_Coverage_AMoveWithAccrualOnBothEndsIsMeasured` drove unit transfers, and there is no move

    /// @notice Origination banks a protocol cut, and a FUZZED crank -- never a direct sweepRevenue -- delivers it to the treasury.
    function test_Coverage_RevenueReachesTreasuryViaCrank() public {
        uint256 nBefore = handler.loanIds().length;
        handler.open(0, 0, 4_000e6);
        assertEq(handler.loanIds().length, nBefore + 1, "PREMISE: the open landed, so the last id is the loan it opened");
        uint256 fresh = nBefore; // the loan just opened: every ctor loan has matured, and a matured loan refuses the crank
        assertGt(read.protocolRevenue(mid), 0, "origination banked a protocol cut");
        // a DELTA, not a zero: the ctor baseline settles a loan, and the warp it needs clears SWEEP_PERIOD and pays the treasury
        uint256 paidBefore = usdc.balanceOf(TREASURY);

        handler.setRate(1.2e18); // real reward growth over the baseline, so the crank really fires
        handler.warp(Constants.SWEEP_PERIOD + 1); // clears SWEEP_PERIOD and stays inside every tenor, so the crank is admitted and may push
        handler.deleverage(fresh);

        assertGt(usdc.balanceOf(TREASURY), paidBefore, "a fuzzed crank delivered revenue to the treasury");
        assertEq(read.protocolRevenue(mid), 0, "and cleared the counter it swept");
        assertEq(handler.callCount("deleverage"), 1, "the delivery really came through the deleverage action");
    }

    /// @notice A refinance really closes and reopens: the old loan retires and a fresh one funds.
    /// @notice The hub's quote balance still reconciles across the whole atomic swap.
    /// @dev REPLACES `test_Coverage_RotationRecashesUnderConcurrentExits`, deleted with the rotation.
    /// @dev That drove `recashAndBackfill`, the only writer debiting lent and crediting cash at a tick.
    /// @dev `refinance` is now the only verb retiring and re-drawing a loan in one call.
    /// @dev The balance leg is the sharp one: the escrow settles, refunds and re-withholds in one tx.
    function test_Coverage_RefinanceRetiresAndRedraws() public {
        uint256[] memory ids = handler.loanIds();
        assertGt(ids.length, 0, "the ctor left no loan to refinance");
        uint256 countBefore = read.loanCount();

        handler.refinance(0, type(uint256).max);

        assertGt(handler.callCount("refinance"), 0, "the refinance action ran");
        if (read.loanCount() > countBefore) {
            uint256 newId = read.loanCount();
            assertFalse(read.loan(newId).closedAt != 0, "the fresh loan is live");
            assertGt(read.feeEscrowOf(newId), 0, "and carries a fresh full-term escrow");
            assertEq(read.claimOf(mid, newId), read.loan(newId).debt, "the refinance broke claim == debt");
        }
        assertEq(usdc.balanceOf(address(ace)), _bookedQuote(), "a refinance leaves the hub reconciled");
    }

    /// @dev RETIRED 2026-08-13 with `sellFill`: `test_Coverage_ForeignVenueFillIsRefused` drove the
    /// @dev ForeignFunder gate, and the ask sources its quote from msg.sender with no funder argument.
    /// @dev RETIRED with the rotation: `test_Coverage_RotateFundingIsSelfCallOnly` guarded the
    /// @dev `rotateFunding` self-call seam, which no longer exists to be called from outside.

    // ---- 9. The run report, and the coverage-collapse guard ----

    /// @dev The third-party levers, per cause: judged, landed, rolled-before, FLIPS (must be 0), and stranger-caused DISARMS (KNOWN).
    function _logBrackets() internal view {
        string[7] memory causes = ["  crank ", "  drain ", "  atomic", "  fill  ", "  repay ", "  route ", "  record"];
        console2.log("third-party levers: judged / landed / rolled, then flips / disarms");
        for (uint256 c = 1; c < 7; c++) {
            console2.log(causes[c], handler.bracketJudged(c), handler.bracketLanded(c), handler.bracketRolled(c));
            console2.log(causes[c], "flips / disarms", handler.bracketFlips(c), handler.bracketDisarms(c));
        }
    }

    /// @dev forge reverts handler state between runs, so each report below covers ONE run's sequence.
    /// @dev And it is checked after EVERY run, not once at the end: a guard here must hold in all of them.
    /// @dev Enough to assert that sequence moved the book, which trips when a swath of paths goes no-op.
    /// @dev The hard guards below are the ones the constructor's BASELINE EXERCISE makes structural.
    /// @dev Per-verb asserts stay out AT EVERY DEPTH: with 36 selectors, one verb's presence in a run is a lottery.
    /// @dev Depth shortens the odds and never ends them, and this hook must hold in EVERY run, so the odds compound.
    /// @dev The expiry fold, which the ctor deliberately never lands, is judged as a rate instead: `make reach`.
    /// @dev TWO TALLIES ARE PRINTED AND DELIBERATELY NOT ASSERTED, at any depth.
    /// @dev `settlementsFinalized` is a lottery everywhere -- 13 of 30 seeds at depth 256, and WORSE at 128 than 64.
    /// @dev `distressArmed` counts arming CALLS past the trigger gate, not distinct episodes: `crashBelow` does not
    /// @dev check whether the loan is already armed, so repeated calls on one loan each increment it.
    /// @dev Neither absence is an oversight, and a green here does NOT cover either channel.
    /// @dev Real per-path coverage is the TEETH property: drop a delta fold and the aggregate walk fails.
    /// @dev EVERY DRIVEN SELECTOR IS IN `tags`, and the two array widths are what make that checkable.
    /// @dev A short tag list turns `total` into a partial count, so a sequence of the missing verbs reads as inert.
    function afterInvariant() public view {
        /// @dev RE-SYNCED with the selector list, and the drift it had is the failure this header warns
        /// @dev about, observed: it still counted `materialize`, `claimUnits` and `transferUnits` -- three
        /// @dev verbs deleted with the receipt ledger -- and named neither `collect` nor `compound`, the two
        /// @dev that replaced them. `total` was therefore blind to the credit path entirely, and the cold
        /// @dev first run reported "no action at all" while the sequence had in fact driven one.
        string[36] memory tags = [
            "transferTitle",
            "deposit",
            "withdraw",
            "collect",
            "redeemInKind",
            "depositThenExit",
            "open",
            "repay",
            "withdrawCollateral",
            "claimOwed",
            "refinance",
            "deleverage",
            "setRate",
            "buyInventory",
            "crashBelow",
            "heal",
            "finalize",
            "forceClose",
            "warp",
            "sweepRevenue",
            "migrate",
            "armPolicy",
            "refinanceByPolicy",
            "refinanceByPolicies",
            "createMarket",
            "exitTo",
            "openSmallArmed",
            "strangerDrain",
            "strangerAtomicDrain",
            "postOrder",
            "strangerFill",
            "strangerRepayPartial",
            "routeIn",
            "recordPush",
            "openNearLine",
            "settleExpired"
        ];
        console2.log("=== AceHandler verb hits (LAST sequence only) ===");
        uint256 total;
        for (uint256 i; i < tags.length; i++) {
            uint256 h = handler.callCount(tags[i]);
            total += h;
            console2.log(tags[i], h);
        }
        console2.log("loans opened          ", handler.loansOpened());
        console2.log("opens refused at cap  ", handler.opensRefusedAtCap());
        console2.log("settlements           ", handler.settlements());
        console2.log("  of which expiry fold", handler.expiryFolds());
        console2.log("  of which finalize   ", handler.settlementsFinalized());
        console2.log("expiry rolls (no fold)", handler.expiryRolls());
        console2.log("forceClose owed       ", handler.forceCloseOwed(), handler.forceCloseHonoured());
        console2.log("distress armed        ", handler.distressArmed());
        console2.log("buyInventory units    ", handler.buyInventoryUnits());
        console2.log("sale fills checked    ", handler.saleFillsChecked());
        console2.log("in-kind units claimed ", handler.inventoryClaimedUnits());
        console2.log("ask-off pots / exits  ", handler.askOffPotsSeen(), handler.askOffInKindExits());
        console2.log("titles transferred    ", handler.titlesTransferred());
        console2.log("quote collected       ", handler.quoteClaimed());
        console2.log("redirects paid (w / c)", handler.redirectWithdrawsPaid(), handler.redirectCollectsPaid());
        console2.log("redirect floors refused", handler.redirectFloorsRefused());
        console2.log("ever held inventory   ", handler.everInventory());
        console2.log("debt melted by skims  ", handler.debtMelted());
        console2.log("refinances completed  ", handler.refinancesDone());
        console2.log("refinances refused    ", handler.refinancesRefused());
        console2.log("skims measured        ", handler.skimsMeasured());
        console2.log("cranks completed      ", handler.skimSuccesses());
        console2.log("small armed opened    ", handler.smallArmedOpened());
        console2.log("near-line opened      ", handler.nearLineOpened());
        console2.log("unpaid settles        ", handler.unpaidSettles(), handler.backstopEarlyRefused());
        console2.log("stranger doors refused", handler.strangerDoorsRefused());
        console2.log("armed folds judged    ", handler.foldChecks(), handler.foldChecksRolled());
        _logBrackets();
        console2.log("genesis mid-sequence  ", handler.genesisAttempted());
        console2.log("  of which created    ", handler.genesisCreated());
        console2.log("migrations attempted  ", handler.migrationsAttempted());
        console2.log("  of which completed  ", handler.migrationsDone());
        console2.log("  of which refused    ", handler.migrationsRefused());
        console2.log("=== market drive distribution (picks / landed) ===");
        for (uint256 i; i < handler.marketCount(); i++) {
            console2.log("  market", i, handler.picksInMarket(i), handler.landedInMarket(i));
        }
        assertGt(total, 0, "VACUOUS: the final sequence produced no action at all");
        /// @dev EVERY GUARD MARKED `STRUCTURAL` BELOW IS SATISFIED BEFORE THE FUZZER RUNS, by the ctor
        /// @dev baseline exercise, and each already sits behind a ctor `require`. They cannot report on a
        /// @dev campaign and they are not claiming to: they re-check that setUp's own state survived.
        /// @dev A red on one is a broken BASELINE, never a starved seed, and the message says which.
        /// @dev The teeth in this block are the three that are NOT structural: the migration identity, the
        /// @dev `liveTransferPicks` implication, and the owed-pot check.
        assertGt(handler.loansOpened(), 0, "STRUCTURAL: the ctor baseline open stopped landing, so setUp is what broke");
        for (uint256 i; i < handler.marketCount(); i++) {
            assertGt(handler.landedInMarket(i), 0, "STRUCTURAL: a driven market lost its ctor baseline draw, so setUp is what broke");
        }
        /// @dev THE ACCOUNTING IDENTITY, and the one migration guard that cannot be a lottery: every attempt
        /// @dev lands in exactly one bucket. It catches an outcome recorded in NEITHER, which the two
        /// @dev `> 0` witnesses below cannot see because the ctor already made both non-zero.
        /// @dev `baselineMigrations` is the ctor's own pair, stamped at the end of setUp, so it is not a magic 2.
        console2.log("cross-market checks   ", handler.crossMarketChecks());
        assertEq(
            handler.migrationsDone() + handler.migrationsRefused(),
            handler.migrationsAttempted() + handler.baselineMigrations(),
            "MIGRATE: an attempt landed in neither bucket, so the two witnesses below count a partial denominator"
        );
        assertGt(handler.migrationsDone(), 0, "STRUCTURAL: the ctor M1->M0 baseline migration stopped landing");
        assertGt(handler.migrationsRefused(), 0, "STRUCTURAL: the ctor cross-quote refusal baseline stopped landing");
        /// @dev CONDITIONAL: this tally is the LAST sequence only, and one selector in 36 may never land in 32 draws.
        /// @dev The per-step invariant leg runs over every sequence regardless; only the IMPLICATION is asserted here.
        /// @dev The equality is a real PROPERTY, not a witness: a refusal means genesis started reading live state.
        if (handler.genesisAttempted() > 0) {
            assertGt(handler.strangerCount(), 0, "VACUOUS: genesis ran and registered nothing to check");
            assertEq(
                handler.genesisCreated(),
                handler.genesisAttempted(),
                "GENESIS: a well-formed market was refused mid-sequence -- admissibility now depends on hub state"
            );
        }
        assertTrue(handler.everInventory(), "STRUCTURAL: the ctor baseline settlement stopped minting inventory");
        assertGt(handler.debtMelted(), 0, "STRUCTURAL: the baselineSkim crank stopped melting debt");
        assertGt(handler.refinancesDone(), 0, "STRUCTURAL: the ctor baseline refinance stopped landing");
        /// @dev THE ASK'S DRAIN GUARD IS GONE, at every depth: a drawn buy may legitimately drain nothing.
        /// @dev Its unconditional pin is `test_Coverage_FillsMoveInventory_ReconNonTrivial`; the history is in
        /// @dev the design record.
        /// @dev AN IMPLICATION (if drawn, then it measured), re-pointed from the deleted `transferUnits` at the verb that replaced the
        /// @dev whole receipt ledger: a healthy hit count is exactly what hid the old action moving zero
        /// @dev units for its entire life, so the guard is the IMPLICATION and never the count.
        if (handler.callCount("collect") > 0) {
            assertGt(handler.claimableChecks(), 0, "VACUOUS: collect ran and its preview differential never measured a leg");
        }
        /// @dev NO PER-RUN `> 0` ON THE REDIRECTED EXITS, and that is a ruling on odds rather than an omission: one
        /// @dev selector of 36 split three ways is the lottery this block refuses. REDIRECT's per-step equalities
        /// @dev and `test_Coverage_TheRedirectedExitsPayTheirPayee` carry it; the tally above is the campaign's evidence.
        /// @dev a market CAN end fully drained; the owed pot proves money moved through the book
        /// @dev THE DELIVERED TOTAL IS THE FOURTH TERM, and it had to be added: `owed` is usually ZERO now,
        /// @dev because a terminal close PUSHES the pool to its lender instead of leaving it to be collected.
        /// @dev A run that opened, lent and closed everything would read empty on the first three and trip a
        /// @dev guard whose whole job is to catch a run that did NOTHING. What the guard means is unchanged:
        /// @dev money moved through the book, wherever it came to rest.
        uint256 owed = read.poolOwed(mid);
        assertGt(_walkCash() + _sumClaims(mid) + owed + handler.quoteDeliveredEver(), 0, "VACUOUS: the invariants ran over an empty book");
        /// @dev NO EXPIRY-FOLD ASSERT, AT ANY DEPTH. This hook runs after EVERY run, so `expiryFolds > 0` had to hold
        /// @dev in all of them at once, and a 500-run sweep almost never passed it. Reach is judged as a RATE by
        /// @dev `scripts/invariant-reach-check.sh` (`make reach`, and the pre-deploy sweep). See the design record
        /// @dev, which also keeps what the deleted assert's notes still teach.
    }

    // ---- view helpers over live hub state ----

    /// @dev THE PER-TOKEN IDENTITY: the hub holds a separate balance per token, and a market books only in its own.
    /// @dev So the sum partitions on the quote, over the six KNOWN markets holding it -- driven AND canary.
    /// @dev A mid-sequence stranger is DELIBERATELY out: excluding it is what makes a leak into one break this.
    /// @dev THE FEE-ESCROW LEG IS THE DEFECT-PRONE HALF: walked hub-wide it MIXES DENOMINATIONS across quotes.
    /// @dev `Ace.marketLoans` is the authority and is complete -- a refinance reaches the one open body too.
    /// @dev THE CREDIT LEG IS ADDED ONCE PER LENDER, NOT ONCE PER MARKET, and that is the whole re-key.
    /// @dev `unitOwed` was a per-market pot; the credit it held now accumulates in `pools[lender][quote]`,
    /// @dev which SPANS that lender's markets. Adding it inside the market loop would count a lender
    /// @dev running three usdc markets three times over -- the exact shape of the defect #559 records
    /// @dev `AceHandler._foldOwed` making, where a per-market fold was banked at pool granularity.
    /// @dev `pools.lent` is deliberately absent: that quote has left the hub, so it is not a pot.
    /// @dev The sum itself is `BookedQuote.total`, shared with the other solvency campaigns; this caller picks its markets.
    function _bookedQuote(address token) internal view returns (uint256) {
        uint256 n = handler.allMarketCount();
        bytes32[] memory markets = new bytes32[](n);
        uint256 held;
        for (uint256 i; i < n; i++) {
            if (handler.quoteOf(i) == token) markets[held++] = handler.allMarketAt(i);
        }
        assembly ("memory-safe") {
            mstore(markets, held) // ONE pass: shrink to the matches, whose slots are the array's head
        }
        return BookedQuote.total(ace, read, markets, _distinctLenders(), token);
    }

    /// @dev The FEE ESCROW inherits the retired roll reserve's place: quote custodied outside `totalCash`.
    /// @dev Omit it and solvency breaks by fee dust, exactly as the `keeperPool()` omission once did.
    /// @dev The USDC leg, kept as a bare name because most call sites only ever meant this token.
    function _bookedQuote() internal view returns (uint256) {
        return _bookedQuote(address(usdc));
    }

    function _walkCash() internal view returns (uint256 cash) {
        return _walkCash(mid);
    }

    /// @dev NOT A WALK ANY MORE, and the rung loop is DELETED rather than re-pointed. `restingOf` lost its
    /// @dev tick argument, so looping six rungs added the same balance six times -- a 6x over-count that
    /// @dev every solvency comparison would have inherited. The name is kept so the diff reads as one change.
    function _walkCash(bytes32 m) internal view returns (uint256) {
        return read.restingOf(m);
    }

    /// @dev Every live claim across ONE market's loans, from the HUB's registry so a minted id still counts.
    /// @dev Never hub-wide `loanCount`: walking every loan against one market id sums zeroes for the rest.
    /// @dev The cost is unchanged -- each loan is visited once, under its own market, instead of M times.
    function _sumClaims(bytes32 m) internal view returns (uint256 s) {
        uint256[] memory ids = ace.marketLoans(m, 0, ace.marketLoansLength(m));
        for (uint256 k; k < ids.length; k++) {
            s += read.claimOf(m, ids[k]); // one claim word per loan: the per-tick inner walk is deleted
        }
    }

    function _sumInventory() internal view returns (uint256 s) {
        return _sumInventory(mid);
    }

    function _sumInventory(bytes32 m) internal view returns (uint256 s) {
        uint256[] memory ids = ace.marketLoans(m, 0, ace.marketLoansLength(m));
        for (uint256 k; k < ids.length; k++) {
            s += read.invPotOf(m, ids[k]); // one pot per loan, same deletion as the claim walk above
        }
    }

    // DELETED with the receipts: `_heldByLenders` summed unit balances per class, and `_inBand` asked whether a tick was one this campaign seeded.
}
