// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Loan, MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AceHandler} from "./AceHandler.sol";

/// @title AceDifferentialTest
/// @notice THE DIFFERENTIAL suite: every pair of surfaces that is supposed to agree, asked to agree.
/// @notice A differential does not need to know what the bug is. It says "these two must match".
/// @dev SIBLING of `AceInvariants.t.sol`, which owns safety. Both drive `AceHandler`, separately.
/// @dev PREVIEW vs ACTUAL cannot be an `invariant_`: the quote dies with the call that answers it.
/// @dev It is latched into a handler ghost DURING the call, and asserted off the ghost here.
/// @dev LENS vs HUB is a true invariant: both sides are pure views, recomputed from live state.
/// @dev A bound the FIXTURE guarantees is not a bound the CODE guarantees.
contract AceDifferentialTest is StdInvariant, Test {
    AceHandler internal handler;
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    bytes32 internal mid;
    uint256 internal coll;
    address internal midLender; // the incumbent's named tenant, which every pooled read is keyed by
    address internal midQuote; // and its quote, the other half of that key

    /// @dev Every party a fuzzed action can credit; the owed-ledger differential closes over exactly these.
    address[5] internal claimants;

    /// @dev Draws the quote doors are probed with: one dust, two fundable, one the market cannot fill.
    /// @dev The last is what keeps the refusal branch of the door comparison off 0 == 0.
    uint256[4] internal probes = [uint256(50e6), 2_000e6, 11_000e6, 5_000_000e6];

    function setUp() public {
        handler = new AceHandler();
        handler.baselineSkim();
        ace = handler.ace();
        read = handler.read();
        lens = handler.lens();
        mid = handler.id();
        coll = handler.collateralUnits();
        MarketParams memory p = ace.idToMarketParams(mid);
        (midLender, midQuote) = (p.lender, p.quote);
        claimants = [handler.lenders(0), handler.borrowers(0), handler.borrowers(1), handler.keeper(), address(handler)];

        /// @dev The verbs `AceInvariants` drives, minus `transferTitle`, `migrate`, `setRate`, `createMarket`, `exitTo` and `postOrder`.
        /// @dev `extend` and `setRollPolicy` run in BOTH suites, so neither owns them exclusively.
        /// @dev Here they drive the `tryExtend`-vs-`extend` straddle, the policy kinds feeding its refusals; next door, the in-place laws.
        /// @dev `collect` REPLACES the three receipt verbs this suite used to drive, and is the only credit door.
        /// @dev `materialize`, `claimUnits` and `transferUnits` went with the ERC-6909 ledger and have no successor.
        /// @dev `setRearm` and `compound` drove beside it until the rearm policy was deleted; they have none either.
        /// @dev `setAutoExtend` and `foldAtExpiry` went with manual renewal: no loan arms, and expiry only settles.
        bytes4[] memory sel = new bytes4[](22);
        sel[0] = AceHandler.deposit.selector;
        sel[1] = AceHandler.withdraw.selector;
        sel[2] = AceHandler.collect.selector;
        sel[3] = AceHandler.redeemInKind.selector;
        sel[4] = AceHandler.depositThenExit.selector;
        sel[5] = AceHandler.open.selector;
        sel[6] = AceHandler.repay.selector;
        sel[7] = AceHandler.withdrawCollateral.selector;
        sel[8] = AceHandler.refinance.selector;
        sel[9] = AceHandler.deleverage.selector;
        sel[10] = AceHandler.buyInventory.selector;
        sel[11] = AceHandler.crashBelow.selector;
        sel[12] = AceHandler.heal.selector;
        sel[13] = AceHandler.forceClose.selector;
        sel[14] = AceHandler.warp.selector;
        sel[15] = AceHandler.sweepRevenue.selector;
        sel[16] = AceHandler.finalize.selector;
        sel[17] = AceHandler.claimOwed.selector;
        sel[18] = AceHandler.extend.selector;
        /// @dev Draws on and around the coverage line: the one place `previewOpen`, `open` and the extension predicate can split.
        sel[19] = AceHandler.openNearLine.selector;
        sel[20] = AceHandler.setRollPolicy.selector;
        /// @dev The market lender's cash extension: the operator's view against its verb.
        sel[21] = AceHandler.lenderExtend.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @notice Every differential below, checked on ONE walk instead of one campaign each.
    /// @dev The leading underscore de-registers a property from forge's `invariant` prefix, name intact for grep.
    /// @dev THE COST: the first failure aborts the rest, so a red run names ONE break, not all of them.
    function invariant_all() public {
        _invariant_previewOpenAgreesWithOpen();
        _invariant_tryExtendAgreesWithTheVerb();
        _invariant_claimableIsWhatTheCollectPays();
        _invariant_settleableAgreesWithFinalize();
        _invariant_lensLoanViewsMirrorTheHub();
        _invariant_lensOwedLedgerMirrorsTheHub();
        _invariant_lensPoolsMirrorLenderAssets();
        _invariant_lensMarketViewsMirrorTheReader();
        _invariant_lensQuoteDoorsMirrorTheHub();
    }

    // ---- 1. PREVIEW vs ACTUAL: the quote surface against the mutator it quotes for ----

    /// @notice `previewOpen` and `open`, asked the same question at the same block, must answer the same.
    /// @notice Admissible quote implies a funded draw carrying the quote's own numbers.
    /// @notice Inadmissible implies a refusal, and the SAME refusal: a differing selector is code 4.
    /// @dev THE PROPERTY BOTH #175 AND #184 DIE ON, and it needed to know neither of them to catch them.
    /// @dev #175 was the tenor-0 sentinel spelled at one door and not the other: code 1.
    /// @dev #184 was the Rate baseline leg spelled at one door and not the other: code 2.
    /// @dev Latched in the handler because the quote cannot survive the call that answers it.
    function _invariant_previewOpenAgreesWithOpen() public {
        if (handler.previewCode() != 0) {
            emit log_named_uint("code         ", handler.previewCode());
            emit log_named_uint("loan         ", handler.previewLoanId());
            emit log_named_uint("principal    ", handler.previewPrincipal());
            emit log_named_bytes32("preview error", bytes32(handler.previewSelector()));
            emit log_named_bytes32("open error   ", bytes32(handler.openSelector()));
            emit log_named_string("field        ", handler.previewField());
            emit log_named_uint("quoted       ", handler.previewExpected());
            emit log_named_uint("hub wrote    ", handler.previewActual());
        }
        assertEq(handler.previewCode(), 0, "QUOTE: previewOpen and open disagreed about the same draw");
    }

    /// @notice `Ace.tryExtend`, asked for the caller it names, must answer for the `extend` that caller then sends: the same yes, fee and no.
    /// @notice The callers are the holder, and the market lender holding the holder's grant, both in cash.
    /// @dev Both run one predicate, so this pins what the view can still get wrong apart from it: the caller it names and the fee it reports.
    /// @dev A policy may answer a preview and a verb apart; none this campaign names does, so any split here is the hub's.
    function _invariant_tryExtendAgreesWithTheVerb() public {
        if (handler.extendCode() != 0) {
            emit log_named_uint("code         ", handler.extendCode());
            emit log_named_uint("loan         ", handler.extendCodeLoanId());
            emit log_named_bytes32("view error   ", bytes32(handler.extendViewSelector()));
            emit log_named_bytes32("verb error   ", bytes32(handler.extendVerbSelector()));
            emit log_named_uint("view fee     ", handler.extendViewFee());
            emit log_named_uint("verb fee     ", handler.extendVerbFee());
        }
        assertEq(handler.extendCode(), 0, "FILTER: tryExtend and extend disagreed about the same extension");
    }

    /// @dev DELETED with manual renewal: `_invariant_theFoldPreviewAgreesWithTheFold`; the fold extends nothing, so it has no preview.

    /// @notice `AceLens.claimable` previews the PULL, so what it promises is what `collect` settles.
    /// @dev An equality, not a bound: the lens re-decodes the lender's pool and must not drift from the verb.
    /// @dev THE CLASS INDEX IS GONE. A claim was once per (loan, tick), with a banked term and an accrual term.
    /// @dev A lender's credit is one pooled word now, so the promise and the payout are the same number or a bug.
    function _invariant_claimableIsWhatTheCollectPays() public {
        if (handler.claimableDisagreed()) {
            emit log_named_address("lender  ", handler.claimableLender());
            emit log_named_address("quote   ", handler.claimableQuote());
            emit log_named_uint("promised", handler.claimablePromised());
            emit log_named_uint("paid    ", handler.claimablePaid());
        }
        assertFalse(handler.claimableDisagreed(), "CLAIM: lens.claimable promised what collect did not pay");
    }

    /// @notice `AceLens.settleable` is the finalize precondition, so the lens and the hub's gate agree.
    /// @dev Both directions, on the ONE gate the lens mirrors; `LoanClosed` and `NoRecord` sit outside its answer.
    /// @dev LIMIT: the fixture mirrors the settle twin to the distress twin, so this pins COMPOSITION and never WHICH twin.
    /// @dev The twin is pinned by `test_Coverage_SettleableAndFinalizeAgreeWhenTheTwinsSplit`, which splits them.
    function _invariant_settleableAgreesWithFinalize() public {
        if (handler.settleableCode() != 0) {
            emit log_named_uint("code", handler.settleableCode());
            emit log_named_uint("loan", handler.settleableLoanId());
        }
        assertEq(handler.settleableCode(), 0, "SETTLE: lens.settleable and finalize disagreed about the same loan");
    }

    // ---- 2. LENS vs HUB: one fact, two readings, recomputed from live state ----

    /// @notice Every loan fact the lens decodes off a slot equals the hub's own view of that fact.
    /// @notice The lens is where the read-only-reentrancy chain terminates, so a drift here is a live integrator hazard.
    /// @dev Walks `loanCount`, not the handler's tracked list: a refinance mints ids the handler never records.
    /// @dev THE CLAIM LEG REPLACES THE CLAIM-TICK LEG. The lens used to rebuild a packed int24 array the hub
    /// @dev served one entry at a time; a market names one price, so what survives is one word and its two decodes.
    function _invariant_lensLoanViewsMirrorTheHub() public view {
        uint256 n = read.loanCount();
        for (uint256 i = 1; i <= n; i++) {
            Loan memory l = lens.loan(i);
            assertEq(l.borrower, ace.borrowerOf(i), "lens loan.borrower != Ace.borrowerOf");
            assertEq(l.closedAt != 0, ace.isClosed(i), "lens loan.closedAt != Ace.isClosed");
            assertEq(read.loan(i).closedAt != 0, ace.isClosed(i), "reader loan.closedAt != Ace.isClosed");
            assertEq(l.market, ace.loanMarket(i), "lens loan.market != Ace.loanMarket");
            assertEq(lens.loanMarket(i), ace.loanMarket(i), "lens.loanMarket != Ace.loanMarket");
            _claimLeg(l.market, i);
        }
    }

    /// @dev The loan's one claim, and the funding floor derived from it, through both decoders.
    function _claimLeg(bytes32 market, uint256 loanId) private view {
        assertEq(lens.claimOf(market, loanId), read.claimOf(market, loanId), "lens claimOf != reader claimOf");
        assertEq(lens.fundingFloor(market, loanId), read.fundingFloor(market, loanId), "lens fundingFloor != reader fundingFloor");
    }

    /// @notice The owed ledger the lens decodes equals the hub's own `owedOf`, for every party a verb can credit.
    /// @dev A separate walk from the loan views for legibility only: `invariant_all` pays both costs every step.
    function _invariant_lensOwedLedgerMirrorsTheHub() public view {
        uint256 n = read.loanCount();
        for (uint256 i = 1; i <= n; i++) {
            for (uint256 a; a < claimants.length; a++) {
                (uint256 u1, uint256 q1) = lens.owedOf(i, claimants[a]);
                (uint256 u2, uint256 q2) = ace.owedOf(i, claimants[a]);
                assertEq(u1, u2, "lens owedOf units != Ace.owedOf units");
                assertEq(q1, q2, "lens owedOf quote != Ace.owedOf quote");
            }
        }
    }

    /// @notice The lens's decode of a lender's pool adds up to the hub's own guarded share-pricing read.
    /// @dev `lenderAssets` is resting + lent + owed, so this pins three of the lens's slot offsets at once.
    /// @dev KEYED BY (lender, quote), NEVER BY MARKET, and the DEDUPE is the whole of the correction: the pool
    /// @dev spans a lender's markets, so a per-market loop over markets sharing one tenant asks the same
    /// @dev question repeatedly, and a per-market SUM of it would over-count the hub by the sharing factor.
    /// @dev The walk still spans every market the hub holds, because that is how the distinct pairs are found.
    function _invariant_lensPoolsMirrorLenderAssets() public view {
        uint256 n = handler.allMarketCount();
        address[] memory seenL = new address[](n);
        address[] memory seenQ = new address[](n);
        uint256 k;
        for (uint256 i; i < n; i++) {
            MarketParams memory p = ace.idToMarketParams(handler.allMarketAt(i));
            if (_seen(seenL, seenQ, k, p.lender, p.quote)) continue;
            (seenL[k], seenQ[k]) = (p.lender, p.quote);
            k++;
            _poolLeg(p.lender, p.quote);
        }
        assertGt(k, 0, "no market resolved a (lender, quote) pair, so the pool legs are vacuous");
    }

    /// @dev One pair, three ways: the lens's decode, the reader's own offsets, and the hub's guarded total.
    function _poolLeg(address lender, address quote) private view {
        (uint256 resting, uint256 lent, uint256 owed) = lens.lenderPools(lender, quote);
        assertEq(resting + lent + owed, ace.lenderAssets(lender, quote), "lens lenderPools total != Ace.lenderAssets");
        (uint256 r2, uint256 l2, uint256 o2) = read.lenderPools(lender, quote);
        assertEq(resting, r2, "lens pool resting != reader pool resting");
        assertEq(lent, l2, "lens pool lent != reader pool lent");
        assertEq(owed, o2, "lens pool owed != reader pool owed");
    }

    /// @dev Has this (lender, quote) pair already been asserted on this walk?
    function _seen(address[] memory ls, address[] memory qs, uint256 k, address l, address q) private pure returns (bool) {
        for (uint256 i; i < k; i++) {
            if (ls[i] == l && qs[i] == q) return true;
        }
        return false;
    }

    /// @notice The market-scalar reads the shipped lens serves against the test reader's own decode of them.
    /// @notice And the per-loan pot, which is where a mis-keyed market offset would surface first.
    /// @dev NOT a duplicate of the safety suite's checks: those read through `AceReader` alone.
    /// @dev The reader keeps its OWN offsets; this pins the shipped lens's copy, the one integrators run.
    /// @dev ONE READ PER MARKET: the six-rung bitmap walk this replaces is DELETED rather than re-pointed,
    /// @dev because every read in it lost its tick argument and a loop would compare one pair six times.
    function _invariant_lensMarketViewsMirrorTheReader() public view {
        uint256[] memory ids = handler.loanIds();
        for (uint256 i; i < handler.allMarketCount(); i++) {
            bytes32 m = handler.allMarketAt(i);
            assertEq(lens.restingOf(m), read.restingOf(m), "lens restingOf != reader restingOf");
            assertEq(lens.isActive(m), read.isActive(m), "lens isActive != reader isActive");
            assertEq(lens.headroom(m), read.headroom(m), "lens headroom != reader headroom");
            MarketState memory s = lens.marketState(m);
            assertEq(s.cash, read.marketState(m).cash, "lens marketState.cash != reader marketState.cash");
            assertEq(s.quoteOwedTotal, read.quoteOwedTotal(m), "lens marketState.quoteOwedTotal != reader quoteOwedTotal");
            for (uint256 j; j < ids.length; j++) {
                assertEq(lens.invPotOf(m, ids[j]), read.invPotOf(m, ids[j]), "lens invPotOf != reader invPotOf");
            }
        }
    }

    /// @notice The lens's three quote doors and the hub's own preview answer identically, right now.
    /// @notice `tryQuoteOpen`'s admissibility answer and its reported selector both ride on this.
    /// @dev The doors FORWARD, so what this really pins is that they keep forwarding, arguments intact.
    /// @dev Probed against live market state, so the same probe is admitted early in a run and refused later.
    function _invariant_lensQuoteDoorsMirrorTheHub() public view {
        for (uint256 i; i < probes.length; i++) {
            _quoteDoorLeg(probes[i]);
        }
    }

    /// @dev One probe through all three doors; the hub's `previewOpen` is the answer they are measured against.
    function _quoteDoorLeg(uint256 principal) private view {
        address who = handler.borrowers(0);
        (bool ok, bytes4 reason, Borrower.Quote memory q) = lens.tryQuoteOpen(mid, coll, principal, 0, who, OpenBounds(0, 0, 0));
        try ace.previewOpen(mid, coll, principal, 0, who, OpenBounds(0, 0, 0)) returns (Borrower.Quote memory h) {
            assertTrue(ok, "tryQuoteOpen refused a draw the hub quoted");
            assertEq(q.fee, h.fee, "tryQuoteOpen fee != hub fee");
            assertEq(q.payout, h.payout, "tryQuoteOpen payout != hub payout");
            assertEq(q.postDrawFloor, h.postDrawFloor, "tryQuoteOpen floor != hub floor");
            assertEq(q.triggerAtOpen, h.triggerAtOpen, "tryQuoteOpen trigger != hub trigger");
            assertEq(q.bufferWad, h.bufferWad, "tryQuoteOpen buffer != hub buffer");
            _quoteOpenLeg(principal, who, h);
        } catch (bytes memory err) {
            assertFalse(ok, "tryQuoteOpen quoted a draw the hub refused");
            assertTrue(reason == _sel(err), "tryQuoteOpen reported a different refusal than the hub raised");
        }
    }

    /// @dev The bare six-return door, measured against the same hub quote as the struct doors.
    /// @dev Its own frame because six unpacked returns beside two Quote structs overrun the legacy stack.
    function _quoteOpenLeg(uint256 principal, address who, Borrower.Quote memory h) private view {
        (uint256 f, uint256 p, uint256 fl, uint256 t, uint256 b, uint256 pf) = lens.quoteOpen(mid, coll, principal, 0, who);
        assertEq(f, h.fee, "quoteOpen fee != hub fee");
        assertEq(p, h.payout, "quoteOpen payout != hub payout");
        assertEq(fl, h.postDrawFloor, "quoteOpen floor != hub floor");
        assertEq(t, h.triggerAtOpen, "quoteOpen trigger != hub trigger");
        assertEq(b, h.bufferWad, "quoteOpen buffer != hub buffer");
        assertEq(pf, h.protocolFee, "quoteOpen protocol fee != hub protocol fee");
    }

    /// @dev The revert's own selector; byte-wise, so no assembly leaves dirty bits under the comparison.
    function _sel(bytes memory ret) private pure returns (bytes4 s) {
        if (ret.length < 4) return bytes4(0);
        s = bytes4(ret[0]) | (bytes4(ret[1]) >> 8) | (bytes4(ret[2]) >> 16) | (bytes4(ret[3]) >> 24);
    }

    // ---- 3. Deterministic witnesses: each differential really can go red ----

    /// @notice #175, mechanically: the `tenor == 0` sentinel has to be spelled at BOTH open doors.
    /// @dev Delete `Ace.previewOpen`'s copy and this reddens as code 1, with `open` funding what the quote refused.
    function test_Coverage_TenorZeroSentinel_TheQuoteAndTheDrawAgree() public {
        handler.open(0, 0, 4_000e6);
        assertEq(handler.previewCode(), 0, "previewOpen and open disagreed about a tenor-0 draw");
        assertGt(handler.previewChecks(), 0, "the preview straddle never ran at all");
        assertGt(handler.previewBothAdmit(), 0, "no draw was both quoted and funded, so the number legs are vacuous");
    }

    /// @notice The holder's view and the holder's verb, on the same extension in the same block: BOTH branches are reached.
    /// @notice The admitted branch compares the fee; the refused branch, with both driven lenders naming the no, compares the selector.
    /// @dev WHAT THIS CANNOT CATCH, stated because the obvious assumption is wrong: a leg deleted from the
    /// @dev SHARED body does not show up as a disagreement. Both doors read one predicate, so they go
    /// @dev permissive together and AGREE while being wrong.
    /// @dev The leg-specific guards are the hub's own extension suites, which assert each leg's SELECTOR and not agreement.
    function test_Coverage_ExtendStraddleReachesBothBranches() public {
        uint256 nBefore = handler.loanIds().length;
        handler.open(0, 0, 4_000e6);
        assertEq(handler.loanIds().length, nBefore + 1, "PREMISE: the open landed, so the last id is the loan it opened");
        uint256 admitted = handler.extendBothAdmit();
        handler.extend(nBefore, 0);
        assertGt(handler.extendBothAdmit(), admitted, "no extension was both admitted and made, so the fee leg is vacuous");

        /// @dev Both driven lenders name the no, so every live loan's extension refuses `PolicyRefused` at both doors.
        handler.setRollPolicy(0, 5);
        handler.setRollPolicy(1, 5);
        uint256 refusedBefore = handler.extendBothRefuse();
        handler.extend(nBefore, 0);
        assertGt(handler.extendBothRefuse(), refusedBefore, "the refusal branch never ran");

        assertEq(handler.extendCode(), 0, "tryExtend and extend disagreed");
    }

    /// @dev DELETED with manual renewal: `test_Coverage_FoldPreviewStraddleReachesBothBranches`; the fold it straddled extends nothing now.

    /// @notice O33 PER POLICY KIND: each policy the campaign installs answers a preview and its verb alike, for both callers.
    /// @notice The callers are the holder in cash and the market lender in cash on the grant.
    /// @notice The yes runs first and is the control: the same loan and asks land, so each refusal after it is the policy's answer.
    /// @dev The no answers zero, the gas burner fails out of gas inside the cap, and none asks nothing; all read no context, so none can split.
    function test_Coverage_EveryInstalledPolicyAnswersAPreviewAndItsVerbAlike() public {
        uint256[4] memory kindSeed = [uint256(0), 5, 6, 7]; // yes, no, gas burner, none
        for (uint256 k; k < 4; k++) {
            handler.setRollPolicy(0, kindSeed[k]);
            handler.setRollPolicy(1, kindSeed[k]);
            uint256 n = handler.loanIds().length;
            handler.open(0, 0, 1_000e6);
            assertEq(handler.loanIds().length, n + 1, "PREMISE: the open landed");
            uint256[2] memory admit = [handler.modeBothAdmit(0), handler.modeBothAdmit(1)];
            uint256[2] memory refuse = [handler.modeBothRefuse(0), handler.modeBothRefuse(1)];
            handler.extend(n, 0);
            handler.lenderExtend(n, 1);
            for (uint256 m; m < 2; m++) {
                if (k == 0) assertEq(handler.modeBothAdmit(m), admit[m] + 1, "the yes: the view and the verb both admitted, for this caller");
                else assertGt(handler.modeBothRefuse(m), refuse[m], "a refusing kind: the view and the verb both refused, for this caller");
            }
            assertEq(handler.extendCode(), 0, "tryExtend and extend disagreed under this policy");
        }
    }

    /// @dev A repay the handler's seed-0 pick is GUARANTEED to leave partial: half of that loan's live debt.
    /// @dev A literal used to do this job only because the baseline crank had already melted loan 0 below it.
    function _halfOfLoanZerosDebt() internal view returns (uint256 amt) {
        amt = read.loan(handler.loanIds()[0]).debt / 2;
        require(amt > 0, "PREMISE: loan 0 carries no debt to repay partially");
    }

    /// @notice The pull preview really runs against collects that really pay, not against a book of zeros.
    /// @dev A repay runs FIRST: a collect pays a lender's accumulated credit, and a run that melted no debt
    /// @dev has none, so the straddle would be an equality between two zeros and would witness nothing.
    /// @dev THE REPAY IS PARTIAL. A `type(uint256).max` repay closes the loan, and a terminal close PUSHES
    /// @dev the pool to its lender, so `collect` would find nothing and the straddle would be the equality
    /// @dev between two zeros this row exists to avoid. A partial credits without pushing.
    function test_Coverage_ClaimablePreviewIsExercisedAndAgrees() public {
        handler.repay(0, _halfOfLoanZerosDebt());
        handler.collect(0, 1);
        handler.collect(4, 1);
        assertGt(handler.claimableChecks(), 0, "the collect straddle never ran");
        assertGt(handler.claimablePaidChecks(), 0, "no collect in this run paid anything, so the equality is 0 == 0");
        assertFalse(handler.claimableDisagreed(), "lens.claimable promised what collect did not pay");
    }

    /// @notice The preview tracks a FRESH accrual, not merely whatever had already accumulated.
    /// @dev IT REPLACES `..._CoversTheAccrualArm`, whose subject was the class index's two terms: a banked
    /// @dev pending plus the accrual since the mint. Sole tenancy pools a lender's credit into ONE word, so
    /// @dev those two arms no longer exist and nothing is left to split a payout between.
    /// @dev What survives, and is what that test really guarded, is that the preview MOVES when the hub
    /// @dev credits the pool and still equals what the payout then pays.
    /// @dev The pre-melt read is latched, so the GROWTH is asserted and not just the level.
    function test_Coverage_ClaimablePreviewTracksAFreshAccrual() public {
        uint256 before_ = lens.claimable(midLender, midQuote);
        /// @dev PARTIAL, for the reason the row above states: a closing repay pushes the accrual out before
        /// @dev this row can preview it, and the growth it asserts would be zero against zero.
        handler.repay(0, _halfOfLoanZerosDebt()); // melts part of a debt, which credits the lender's pool
        assertGt(lens.claimable(midLender, midQuote), before_, "the melt credited nothing: there is no accrual to preview");
        uint256 paidBefore = handler.claimablePaidChecks();
        handler.collect(0, 1);
        assertGt(handler.claimablePaidChecks(), paidBefore, "the post-accrual collect paid nothing, so the arm is untested");
        assertFalse(handler.claimableDisagreed(), "lens.claimable mis-priced a payout it had just previewed");
    }

    /// @notice The finalize precondition really runs against a settlement that really completes.
    function test_Coverage_SettleablePreconditionIsExercisedAndAgrees() public {
        handler.crashBelow(0);
        handler.finalize(0);
        assertEq(handler.settleableCode(), 0, "lens.settleable and finalize disagreed");
        assertGt(handler.settleableChecks(), 0, "the finalize straddle never ran");
        assertGt(handler.settleableAdmits(), 0, "no finalize completed, so only the refusal leg was exercised");
    }

    /// @notice ON THE COVERAGE LINE the quote and the draw agree: one atom under it both refuse, on it both admit.
    /// @dev Every other draw here posts far more than the line asks, so neither door's line was ever compared.
    function test_Coverage_TheQuoteAndTheDrawAgreeOnTheCoverageLine() public {
        uint256 refused = handler.previewBothRefuse();
        uint256 admitted = handler.previewBothAdmit();
        handler.openNearLine(0, 0, 4_000e6, 0); // slack seed 0: one atom under the line
        assertGt(handler.previewBothRefuse(), refused, "a draw one atom under the line was not refused at both doors");
        handler.openNearLine(0, 0, 4_000e6, 1); // slack seed 1: exactly on the line
        assertGt(handler.previewBothAdmit(), admitted, "a draw on the line was not admitted at both doors");
        assertEq(handler.previewCode(), 0, "previewOpen and open disagreed about a draw at the coverage line");
    }

    /// @notice THE TWINS SPLIT: distress has persisted and the settle window has not, so the lens and finalize both refuse.
    /// @dev The fixture's record answers the settle twin by MIRRORING the distress twin, so the campaign itself cannot see a
    /// @dev side that asks the wrong twin: both answer alike. This row splits them, the one shape where the two differ.
    function test_Coverage_SettleableAndFinalizeAgreeWhenTheTwinsSplit() public {
        handler.crashBelow(0);
        uint256 id = handler.loanIds()[0];
        handler.records(0).setSettleBelow(false); // loan 0 is the incumbent's, so its record is records(0)
        assertTrue(read.inDistress(id), "PREMISE: distress has persisted on the loan");
        uint256 refusedBefore = handler.settleableRefusals();
        handler.finalize(0);
        assertEq(handler.settleableCode(), 0, "lens.settleable and finalize asked different twins of the record");
        assertGt(handler.settleableRefusals(), refusedBefore, "both sides refused the split, and the refusal was compared");
        assertFalse(ace.isClosed(id), "finalize settled a loan whose settle window has not passed");
    }

    /// @notice The quote-door comparison reaches BOTH branches: a hub that answers, and a hub that refuses.
    /// @dev Without this the door legs could be green on four probes the hub happened to refuse identically.
    function test_Coverage_QuoteDoorsReachBothBranches() public view {
        uint256 admitted;
        uint256 refused;
        for (uint256 i; i < probes.length; i++) {
            (bool ok,,) = lens.tryQuoteOpen(mid, coll, probes[i], 0, handler.borrowers(0), OpenBounds(0, 0, 0));
            if (ok) admitted++;
            else refused++;
        }
        assertGt(admitted, 0, "no probe was admissible, so the number comparison never ran");
        assertGt(refused, 0, "no probe was refused, so the selector comparison never ran");
    }

    /// @notice The lens walks are not asserting over an empty book.
    function test_Coverage_TheLensWalksHaveSomethingToWalk() public view {
        assertGt(read.loanCount(), 0, "no loan exists, so every per-loan lens leg is vacuous");
        assertGt(ace.lenderAssets(midLender, midQuote), 0, "the incumbent's tenant books nothing, so the pool leg is 0 == 0");
        assertGt(lens.claimOf(mid, 1), 0, "the baseline loan holds no claim, so the claim leg is empty");
    }

    // ---- 4. The run report ----

    /// @dev Ghost state is reverted between runs, so this reports the LAST sequence, exactly as next door.
    /// @dev The two hard guards are the ones the handler's constructor baseline makes structural.
    function afterInvariant() public view {
        console2.log("=== differential straddles (LAST sequence only) ===");
        console2.log("preview straddles     ", handler.previewChecks());
        console2.log("  both admitted       ", handler.previewBothAdmit());
        console2.log("  both refused        ", handler.previewBothRefuse());
        console2.log("collect straddles     ", handler.claimableChecks());
        console2.log("  of which paid       ", handler.claimablePaidChecks());
        console2.log("extend straddles      ", handler.extendTries());
        console2.log("  both admitted       ", handler.extendBothAdmit());
        console2.log("  both refused        ", handler.extendBothRefuse());
        console2.log("  admit holder/lender ", handler.modeBothAdmit(0), handler.modeBothAdmit(1));
        console2.log("  refuse holder/lender", handler.modeBothRefuse(0), handler.modeBothRefuse(1));
        console2.log("finalize straddles    ", handler.settleableChecks());
        console2.log("  settleable admits   ", handler.settleableAdmits());
        console2.log("  agreed refusals     ", handler.settleableRefusals());
        console2.log("loans opened          ", handler.loansOpened());
        assertGt(handler.previewChecks(), 0, "VACUOUS: no draw was ever straddled by a quote");
        assertGt(handler.previewBothAdmit(), 0, "VACUOUS: no draw was ever both quoted and funded");
    }
}
