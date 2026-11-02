// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {Ace} from "../../src/ace/hub/Ace.sol";
import {BelowCallerFloor} from "../../src/ace/hub/Lender.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {LoanClosed, NotExpired, NotSettleable} from "../../src/ace/hub/Settlement.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Cfg, Loan, MarketParams, MarketState, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {NotBorrower, QuoteMismatch} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {GasBurnerPolicy, NoPolicy, YesPolicy} from "../utils/RollPolicyMocks.sol";

/// @title AceHandler
/// @notice The stateful-invariant fuzzing surface for FOUR DRIVEN markets on the ACE singleton.
/// @notice It also seeds TWO CANARY markets, one per quote token, that no action here ever touches.
/// @notice And it CREATES markets mid-sequence: strangers, addressed by no action and outside both counts.
/// @dev Successor to the pre-singleton invariant handlers.
/// @dev The hub ships no venue and disposal is keeper-routed, so this handler is its own deleverage solver.
/// @dev NO PRIVILEGED DOORS: one draw door, so every aggregate fold is reached through the REAL verbs.
/// @dev Adding a privileged door here would weaken every aggregate equality the suite asserts.
/// @dev Junior is out of core v1: `depositSeed`/`withdrawSeed`/`juniorDepth` are CANCELLED, not ported.
/// @dev One lender class, so a shortfall is the funding tick's own write-down, with no cohort to fold.
/// @dev Every action is bounded and try/catch-guarded (fail_on_revert = false).
/// @dev ANY claim that cannot be recomputed from live state is latched into a ghost mid-call.
contract AceHandler is WarpClock, DeleverageCrank {
    /// @dev Latched per crank rather than fixed, so a dai market's disposal mints dai. `DeleverageCrank`
    /// @dev is inherited by 20+ suites, so the market-awareness belongs here, not in the shared base.
    /// @dev Defaults to usdc for the pre-registry window: the ctor's first baselines run before a crank latches.
    address private _crankQuote;

    function _deleverageQuote() internal view override returns (address) {
        return _crankQuote == address(0) ? address(usdc) : _crankQuote;
    }

    uint256 internal constant COLL = 40_000e18; // per-loan collateral; deep enough that the trigger gate admits
    uint256 internal constant MAX_LOANS = 24; // tracked-loan cap; raised from 16 so four markets each keep a workable book

    /// @dev The geometric tick band the fuzzer plays in (spacing 60; ~0.90 .. ~1.15).
    uint256[6] internal PRICES; // the prices this campaign stands markets up at, par plus the old offsets
    uint256 internal parT; // the 6/18 par tick every market here shares, since all four pairs carry that gap

    Ace public ace;
    AceLens public lens; // the shipped read surface every lens-vs-hub differential is asked of
    PositionManager public positionManager;
    AceReader public read;
    MockERC20 public usdc;
    MockStakeVault public vault;
    MockPersistenceRecord public record;
    uint256 internal constant BAND_BPS = 3000; // the market's deleverage band, mirrored for the crank's arming
    uint256 public skimSuccesses; // cranks that COMPLETED: the verb-hit tally counts calls, not completions
    bytes32 public id;
    uint256 public unitScale;

    bytes32 public canaryId; // the usdc canary, `canaries[0]`: seeded once, asserted unchanged, addressed by nothing
    uint256 public canarySeededCash; // pinned by invariant_canaryMarketUntouched, not by this comment
    MockPersistenceRecord public canaryRecord; // its OWN record: the differing param that forks its id, and crashBelow/heal/setRate cannot reach it
    address public canaryLender = address(0xCA9A47); // ADDING AN ACTOR? keep it distinct from this one

    /// @dev THE DRIVEN MARKETS. `mids[0]` IS `id`: the incumbent keeps its name so every existing read compiles.
    /// @dev M0 usdc/vault A, M1 usdc/vault B (migration-compatible with M0), M2 usdc/vault2, M3 dai/vault.
    /// @dev M0/M1 is the only migratable pair; M0->M2 and M0->M3 are the refusal legs, driven on purpose.
    bytes32[4] public mids;
    MockPersistenceRecord[4] public records; // records[0] IS `record`; each market's own, so crashBelow is scoped
    uint256[4] public unitScales;
    /// @dev THE CROSS-MARKET LATCH. Isolation is LOGICAL here, so the property is measured, never assumed.
    /// @dev Latched mid-action: `fail_on_revert = false` discards a bare revert, and a crossing inside one with it.
    /// @dev THE ENTITLED SET IS THE ASSERTION: a move in any market a verb did not name is a crossing.
    /// @dev One verb may entitle more than one: `migrate`, over its source and its destination.
    /// @dev FAILS CLOSED: the mask clears every action, so an unannotated verb is loud, never silently exempt.
    bytes32[6] private _bookSnap; // the booked tuple of every market, hashed, as of this action's start
    uint256 private _entitledMask; // bit i set == this action may move market i
    bool public crossMarketMoved;
    uint256 public crossMarketId; // the index, over `allMarketAt`'s space, that moved unentitled
    string public crossMarketTag; // the VERB that crossed; with the index it is enough to reproduce
    string private _tag; // this action's tag, held so a crossing can name the verb that caused it
    uint256 public crossMarketChecks; // snapshots taken with a live second market; logged in afterInvariant, asserted by nothing

    uint256 public migrationsAttempted; // migrate calls that reached the hub; the denominator for the two below
    uint256 public migrationsDone; // completed cross-market migrations: the M0<->M1 compatible pair
    uint256 public migrationsRefused; // refused ones: the collateral and quote gates, which must be REACHED
    uint256 public baselineMigrations; // the ctor's own two legs, which move the buckets without an attempt
    bytes4 public migrateRefusalSelector; // the FIRST refusal's selector, so a refusal cannot be anonymous
    uint256[4] public picksInMarket; // what the seed CHOSE, per market: the drive-distribution witness
    uint256[4] public landedInMarket; // what actually landed, so a 40/20/20/20 intent cannot read healthy while starving

    /// @dev THE PASSIVE MARKETS, one per quote token, so the per-token solvency identity is symmetric.
    /// @dev `canaries[0]` IS `canaryId`. They are NOT driven; nothing here ever addresses them.
    bytes32[2] public canaries;
    uint256[2] public canarySeededCashOf; // `canarySeededCashOf[0]` IS `canarySeededCash`

    bytes32[] private _strangers; // markets the fuzzer creates MID-SEQUENCE; outside allMarketAt's space on purpose
    uint256 public genesisAttempted; // createMarket actions that reached the hub
    uint256 public genesisCreated; // ones that returned an id
    bool public genesisCollided; // a fresh genesis returned an id some market already held
    bool public genesisIdNotItsParams; // an id stopped re-hashing to the params it resolves to

    MockERC20 public dai; // SIX decimals, deliberately: see the handler header. The name is the misnomer.
    MockStakeVault public vault2; // the second collateral, so one quote spans two collaterals
    address public canaryLender2 = address(0xCA9A48); // the dai canary's lender; distinct from every fuzzed actor

    /// @notice How many markets the fuzzer drives.
    function marketCount() external pure returns (uint256) {
        return 4;
    }

    /// @notice The i-th DRIVEN market.
    function midAt(uint256 i) external view returns (bytes32) {
        return mids[i];
    }

    /// @notice Every market the hub holds for this handler: the four driven, then the two canaries.
    /// @dev ONE index space, so the revenue latch and the isolation snapshot never each roll their own.
    function allMarketCount() external pure returns (uint256) {
        return 6;
    }

    /// @notice The i-th market over that one index space.
    function allMarketAt(uint256 i) external view returns (bytes32) {
        return i < 4 ? mids[i] : canaries[i - 4];
    }

    /// @notice How many markets this handler created mid-sequence.
    function strangerCount() external view returns (uint256) {
        return _strangers.length;
    }

    /// @notice The i-th mid-sequence market.
    function strangerAt(uint256 i) external view returns (bytes32) {
        return _strangers[i];
    }

    /// @notice The quote token of the i-th market, over `allMarketAt`'s index space.
    /// @dev The per-token solvency identity partitions on exactly this, so it must span the canaries too.
    function quoteOf(uint256 i) external view returns (address) {
        return (i == 3 || i == 5) ? address(dai) : address(usdc);
    }

    /// @notice The collateral of the i-th market over `allMarketAt`'s index space: only M2 secures `vault2`, the canaries `vault`.
    function collOf(uint256 i) external view returns (address) {
        return _collAt(i); // the driven map, which already answers `vault` for the canaries' indices
    }

    address[3] public lenders = [address(0xA11CE), address(0xA11CF), address(0xA11D0)];
    address[2] public borrowers = [address(0xB0B), address(0xB0C)];
    address public keeper = address(0xCAFE);
    address public trader = address(0x74AD34);

    uint256[] internal _loanIds;
    mapping(uint256 => uint64) public tenorAtIssue; // each tracked loan's tenor when it was issued, which no later verb may move
    mapping(uint256 => bool) internal _knownLoan;
    mapping(uint256 => bool) public everClosed;
    bool public monotonicityViolated;
    uint256 public monoLoanId;

    bool public theftFlag;
    uint256 public theftMarket; // WAS `theftTick`: a round trip happens in a market, and a market names one price
    uint256 public theftValueIn;
    uint256 public theftValueOut;

    address public payee = address(0x9A7EE); // the third party a redirected exit names: no market's lender, never pranked
    bool public redirectMisdelivered; // a redirected exit returned a figure its payee's balance did not receive
    uint256 public redirectWithdrawsPaid; // `withdraw` to the payee that moved quote: the leg's non-vacuity witness
    uint256 public redirectWithdrawsLanded; // `withdraw` to the payee that RETURNED; each asked a nonzero fill, so each must have paid
    uint256 public redirectCollectsPaid; // `collect` to the payee that moved quote: the leg's non-vacuity witness
    uint256 public redirectCollectsOwed; // `collect` to the payee on a pool that held credit; each must have paid
    uint256 public redirectFloorsRefused; // `withdraw` floored one wei above its fill that refused with `BelowCallerFloor`
    bool public redirectFloorIgnored; // a `withdraw` floored above its fill returned, or refused with anything but the floor

    bool public floorViolated;
    uint256 public floorLoanId;
    uint256 public floorBefore;
    uint256 public floorAfter;
    string public floorAction;

    /// @dev The trigger-direction ghosts: a crank moves BOTH sides of the ratio, so it must be measured.
    /// @dev Latched cross-multiplied, `pay * collBefore >= debtBefore * unitsSold`, so no division can drift.
    /// @dev A no-op crank and a full self-repay both land on equality, which is a non-raise and admitted.
    bool public deleverageRaisedTrigger;
    uint256 public deleverageTriggerLoanId;
    uint256 public deleveragePay;
    uint256 public deleverageUnitsSold;
    uint256 public deleverageDebtBefore;
    uint256 public deleverageCollBefore;
    uint256 public skimsMeasured; // non-vacuity: cranks that actually sold units and were checked
    uint256 public debtMelted; // quote a disposal really took off loan debt, cumulative: the melt leg's witness

    /// @dev THE DUST GHOSTS: a crank that sells either closes the loan clean or leaves its debt at or over its debt floor.
    uint256 public crankCloses; // cranks that closed a loan
    bool public crankLeftDust; // a selling crank left a live loan under its debt floor, or a closing one left debt
    uint256 public crankDustLoanId;
    uint256 public crankDustDebt;
    uint256 public nearLineOpened; // draws that LANDED within atoms of their coverage line
    uint256 public smallOpened; // dust-bound loans `openSmall` landed
    uint256 public smallCranked; // selling cranks on a dust-bound loan
    uint256 public smallCloses; // of those, the ones that closed it
    mapping(uint256 => bool) internal _isSmall;
    uint256 public floorRepaysTried; // borrower repays sized to leave exactly the debt floor
    uint256 public repaysToTheFloor; // of those, the ones that landed with the debt exactly on the debt floor
    uint256 private _drawUnits; // a near-line draw's own units for one `_open`; zero means the standard `COLL`

    address public maker = address(0x3A4E2); // posts honest resting orders
    uint256[] internal _orderIds;

    /// @dev THE ROLL POLICIES the driven markets' two lenders choose between; both start on the yes, installed in the constructor.
    YesPolicy public yesPolicy;
    NoPolicy public noPolicy;
    GasBurnerPolicy public gasPolicy; // burns its whole gas budget, so every ask fails out of gas inside the hub's cap
    uint256[4] public policySets; // `setRollPolicy` actions that landed, by kind: 0 yes, 1 no, 2 gas burner, 3 none

    /// @dev THE HOLDER'S EXTENSION: its `tryExtend` asked for the holder, then the cash `extend` the holder sends.
    uint256 public extendCalls; // `extend` actions that found a loan within reach to try
    uint256 public extendFallbacks; // `extend` actions with none in reach, which asked the seed's own pick so the refusal straddle still runs
    uint256 public extendTries; // straddles run
    uint256 public extendsLanded; // of those, the ones that extended
    uint8 public extendInPlaceCode; // first law broken: 1 minted, 2 expiry, 3 debt, 4 resting moved, 5 cash fee short, 6 draw count off
    uint256 public extendInPlaceLoanId;

    /// @dev THE CALLER SPLIT of the view-versus-verb straddle: 0 the holder, 1 the market lender.
    uint256[2] public modeBothAdmit;
    uint256[2] public modeBothRefuse;

    /// @dev THE E-3 PATH: the market lender, holding the holder's credit grant, extends in cash it pays itself; ungranted it refuses.
    uint256 public operatorTries; // `lenderExtend` straddles run
    uint256 public operatorLanded; // of those, the ones that extended: granted
    uint256 public operatorRefusedByName; // the ungranted asks, refused `NotBorrower` at both doors as they must be
    uint8 public operatorCode; // first break: 1 landed ungranted, 2 refused it by another name, 3 the fee not the lender's
    uint256 public operatorLoanId;

    /// @dev The refinance ghosts, SUCCEEDING the rotation's: same floor law, different writer.
    /// @dev A refinance retires exactly one loan's floor and writes exactly one new one.
    /// @dev Every OTHER live loan's floor must be untouched, and that is what these latch.
    bool public refinanceMovedFloor;
    uint256 public refinanceFloorLoanId;
    uint256 public refinanceFloorBefore;
    uint256 public refinanceFloorAfter;

    /// @dev THE DIFFERENTIAL GHOSTS: a quote surface against the mutator it quotes for.
    /// @dev Latched mid-call: the quote dies with the call, so no later `invariant_` can compare it.
    // previewOpen vs open: 1 the quote refused a draw open funded, 2 it quoted one open refused, 3 a number differed, 4 the refusals differed
    uint8 public previewCode;
    uint256 public previewLoanId; // the draw the first disagreement landed on; 0 when open never got an id
    uint256 public previewPrincipal; // the principal it was asked for
    bytes4 public previewSelector; // what previewOpen refused with, zero when it admitted
    bytes4 public openSelector; // what open refused with, zero when it funded
    uint256 public previewExpected; // the number the quote reported, on code 3
    uint256 public previewActual; // the number the hub then wrote, on code 3
    string public previewField; // which Quote field disagreed, on code 3
    uint256 public previewChecks; // straddles run at all: the non-vacuity counter
    uint256 public previewBothAdmit; // straddles where quote and draw both went through, so the numbers were compared
    uint256 public previewBothRefuse; // straddles where both refused, so the selector leg was exercised

    // tryExtend vs extend: 1 view refused an extension the verb made, 2 view admitted one it refused
    uint8 public extendCode; // 3 the fee differed, 4 both refused with different selectors
    uint256 public extendCodeLoanId; // the extension the first disagreement landed on
    bytes4 public extendViewSelector; // what the view reported, zero when it admitted
    bytes4 public extendVerbSelector; // what the verb refused with, zero when it extended
    uint256 public extendViewFee; // the fee the view reported, on code 3
    uint256 public extendVerbFee; // the fee the verb then charged, on code 3
    uint256 public extendBothAdmit; // straddles where view and verb both went through
    uint256 public extendBothRefuse; // straddles where both refused, so the selector leg was exercised

    bool public strangerMovedMoney; // a deposit, withdraw or redeemInKind by someone other than the market's lender LANDED
    string public strangerMovedBy; // the door it landed through, first violation only
    uint256 public strangerDoorsRefused; // stranger attempts at those three doors that refused, as sole tenancy requires
    bool public claimableDisagreed; // AceLens.claimable promised an amount claimUnits did not pay
    bool public lenderDoorLeftDust; // a deposit or withdraw RETURNED leaving resting cash in (0, minPrincipal); a draw may, they may not
    address public claimableLender; // WAS `claimableMarket`: the preview is keyed on the pool, not a market
    address public claimableQuote; // and the pool's other half, so a mismatch names the token it happened in
    uint256 public claimablePromised;
    uint256 public claimablePaid;
    uint256 public claimableChecks; // straddles run
    uint256 public claimablePaidChecks; // straddles where the claim actually paid: the leg that is not 0 == 0

    // settleable vs finalize: 1 finalize settled a loan the lens called unsettleable, 2 finalize answered NotSettleable on one it called settleable
    uint8 public settleableCode;
    uint256 public settleableLoanId;
    uint256 public settleableChecks; // straddles run
    uint256 public settleableAdmits; // finalizes that completed with the lens agreeing
    uint256 public settleableRefusals; // NotSettleable refusals the lens agreed with

    // forceClose vs its own promise: 1 refused on a precondition the caller had already established, 2 refused past both, 3 left the loan live
    uint8 public forceCloseCode;
    uint256 public forceCloseLoanId;
    bytes4 public forceCloseSelector; // the refusal the latch caught, so a red names the leg rather than the tally
    uint256 public forceCloseOwed; // attempts on a LIVE loan at or past expiry: the calls the promise binds
    uint256 public forceCloseHonoured; // of those, the ones that settled

    /// @dev Coverage evidence: proof this run moved real inventory, real units and real settlements.
    uint256 public buyInventoryUnits;
    uint256 public seededInventoryUnits; // what the ctor's own buy drained; the campaign must beat it, not merely match zero
    bool public salePaidSomeone; // a buy moved its seller's quote balance, or credited the pool by other than the fill
    uint256 public salePaidLoanId; // the loan whose buy tripped it, first violation only
    uint256 public saleFillsChecked; // buys that FILLED and were measured against their seller, the ghost's non-vacuity count
    uint256 public inventoryClaimedUnits; // units OUT of custody in kind: the LR-9 outflow branch's driver
    /// @dev THE ASK-OFF LATCH. One driven market is built with the hub's ask OFF, so its settled pots may leave one way only.
    /// @dev KEYED ON THE DRIVEN INDEX, fixed at construction, never on the hub's stored flag: a hub that lost the flag must not blind it.
    uint256 internal constant ASK_OFF_MARKET = 2;
    mapping(uint256 => uint256) private _askOffPotMark; // each ask-off loan's pot as of the last action's end
    bool public askOffPotFellOutOfKind; // an ask-off pot fell across an action that was not an in-kind exit
    uint256 public askOffPotLoanId; // the loan whose pot fell, first violation only
    string public askOffPotTag; // the verb it fell under
    uint256 public askOffPotsSeen; // ask-off pots the run has held, counted once each as they appear: the latch's non-vacuity witness
    uint256 public askOffInKindExits; // ask-off pots that fell across an in-kind exit
    uint256 public askOffUnitsLeft; // every unit that has left an ask-off pot, which the lender's own wallet must account for
    uint256 public titlesTransferred; // ERC-721 title moves that landed, so the retitle leg is not vacuous
    uint256 public quoteClaimed; // quote pulled through collect: the credit bucket really pays
    bool public collectReachedAnotherPool; // WAS `collectPaidTheCaller`: a stranger's collect moved the market lender's pool
    uint256 public settlements; // finalize + forceClose: the TOTAL, and it cannot tell them apart
    uint256 public settlementsFinalized; // finalize completed: the distress settlement
    uint256 public forceCloseSettles; // forceClose that SETTLED: the expiry settle, the channel the total can hide
    uint256 public distressArmed; // crashBelow after which the record answers settleable, not merely armed
    uint256 public loansOpened;
    uint256 public opensRefusedAtCap;
    uint256 public refinancesDone; // refinances that really retired one loan and opened another
    uint256 public refinancesRefused; // refinances the ladder or the gates would not admit
    bool public everInventory;

    mapping(bytes32 => uint256) public calls;
    mapping(address => mapping(address => uint256)) public realizedQuoteOf; // lender -> quote token -> what it really pulled
    uint256[4] private _owedMarkOf; // `unitOwed` as of the last fold, per DRIVEN market
    uint256[4] private _balMarkOf; // the pool lender's quote balance as of the last fold, the realized side's baseline
    uint256 public quoteDeliveredEver; // every wei `_foldOwed` attributed to a lender, across BOTH doors
    mapping(address => uint256) public quoteReleasedEverOf; // every wei that left `unitOwed`, per QUOTE TOKEN

    /// @dev DELETED WITH THE REARM POLICY: `quoteRestedEverOf`, `rearmsArmed`, `rearmsFired`, `rearmMovedToken`
    /// @dev and the preview-differential pair. A fall in `unitOwed` HAS ONE DESTINATION AGAIN -- a payee's wallet --
    /// @dev so the attribution identity tightened from `realized + rested == released` to `realized == released`.

    constructor() {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        parT = AceFixtures.priceAt(address(usdc), address(vault), 0);
        /// @dev SIX PRICES, NOT SIX TICKS. What was a ladder INSIDE one market is now the menu this
        /// @dev campaign stands markets up AT: a market names one price, so a spread of prices is a
        /// @dev spread of markets. The offsets are the ones the campaign always walked, unchanged.
        PRICES = [
            AceFixtures.priceAt(address(usdc), address(vault), -1080),
            AceFixtures.priceAt(address(usdc), address(vault), -540),
            parT,
            AceFixtures.priceAt(address(usdc), address(vault), 480),
            AceFixtures.priceAt(address(usdc), address(vault), 960),
            AceFixtures.priceAt(address(usdc), address(vault), 1380)
        ];

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS; // the disposal channel the handler cranks
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1; // tiny, so a near-trigger band price is still admitted
        /// @dev The incumbent joins `lenders[0]`'s pool alongside M1 and M3, so that pool spans THREE
        /// @dev markets across two quotes -- which is what the cross-market properties need to be non-trivial.
        p.lender = lenders[0];
        // `extend` lengthens a loan in place; `refinanceTo` is the only verb that replaces one
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace)); // before the baselines, so every straddle below already has it
        unitScale = read.marketState(id).unitScale;
        (mids[0], records[0], unitScales[0]) = (id, record, unitScale);
        _buildDrivenMarkets();
        _installPolicies();

        record.setAbove(true); // healthy by default; crashBelow arms distress, heal dissolves it
        /// @dev A FINITE windowed min, above every tick in TICKS so the draw cap still admits them all.
        /// @dev ASKED FOR, not inherited: the disposal floor reads this same value, and `max` overflows it.
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));

        /// @dev Light bootstrap so call 0 already has depth to draw against and cash to withdraw.
        /// @dev THE SAME DEPOSITOR THREE TIMES. It used to be three lenders once each, and `_seed`'s
        /// @dev try/catch meant sole tenancy silently dropped two of them -- the incumbent was seeded a
        /// @dev THIRD of what every depth-dependent baseline below assumes, with nothing going red.
        address tenant = ace.idToMarketParams(id).lender;
        _seed(tenant, 5_000e6);
        _seed(tenant, 5_000e6);
        _seed(tenant, 5_000e6);
        require(read.marketState(id).cash == 15_000e6, "TOPOLOGY: the incumbent seed did not land whole");

        _buildCanary();

        /// @dev BASELINE EXERCISE: foundry REVERTS ghost state between runs, so the adequacy guards measure one sequence, not the campaign.
        /// @dev Opening a loan and minting inventory here, pre-snapshot, makes them hold structurally instead of riding the selector lottery.
        _open(borrowers[0], 2_000e6);
        _baselineOpenEveryMarket();
        _baselineRefinance();
        _baselineMigrate();
        _baselineInventory(borrowers[1], 1_000e6);
        _buyInventory(500e6); // pre-snapshot too: the adequacy guards read ghost state, not the campaign
        require(loansOpened > 0, "BASELINE: the ctor open failed -- the suite cannot exercise anything");
        require(everInventory, "BASELINE: the ctor sell fill minted no inventory");
        require(refinancesDone > 0, "BASELINE: the ctor refinance never completed -- the verb is unreachable");
        require(buyInventoryUnits > 0, "BASELINE: the ctor buy drained no inventory -- the ask leg is unreachable");
        /// @dev Stamped LAST, so the campaign's own draining is what the anti-vacuity guard measures.
        /// @dev A guard against zero would be satisfied by the seed above and could witness nothing.
        seededInventoryUnits = buyInventoryUnits;
        /// @dev The baselines move both migration buckets without touching `migrationsAttempted`, so the
        /// @dev afterInvariant identity needs their count rather than a hardcoded two beside the denominator.
        baselineMigrations = migrationsDone + migrationsRefused;
    }

    /// @notice The disposal channel's baseline exercise, still pre-snapshot, called from the invariant test's setUp.
    /// @notice It CANNOT live in the constructor: solver routing calls `onAceDeleverage` back here, where this address has no code yet.
    /// @dev Every fuzz action is try/catch-guarded, so without a structural success the channel could be inert with the tally reading healthy.
    /// @dev It is also the trigger-direction check's witness: an `afterInvariant` per-verb tally would be a lottery on the last sequence.
    /// @dev It opens its OWN loan: the inventory baseline warps past MAX_TENOR, so every ctor loan has matured, and a matured loan refuses the crank.
    /// @dev And ITS OWN headroom, as the refinance and migration baselines take theirs: the draw never eats the reserve coverage rows read.
    function baselineSkim() external {
        _seed(lenders[0], 2_000e6);
        _open(borrowers[0], 2_000e6);
        uint256 loanId = _loanIds[_loanIds.length - 1];
        Loan memory l = read.loan(loanId);
        require(l.closedAt == 0 && _now() < l.expiry, "BASELINE: the disposal baseline has no live, unexpired loan to crank");
        _crankDisposal(loanId);
        require(skimSuccesses > 0, "BASELINE: the crank never completed -- the disposal channel is inert");
        require(skimsMeasured > 0, "BASELINE: the ctor crank sold no units, so the direction check is unwitnessed");
        require(debtMelted > 0, "BASELINE: the ctor crank melted no debt -- the melt leg is unwitnessed");
    }

    /// @notice THE CLOSE'S WITNESS, pre-snapshot: a loan at 1.2x its debt floor, whose restore would leave dust, closes clean.
    /// @dev Opened at 12e6 (2.4 floors, over `minPrincipal`), then repaid to 1.2 floors: the crank arms off the live trigger, so the margin carries.
    /// @dev The close is counted and the dust ghost stays clear.
    function baselineCrankCloses() external {
        uint256 n = _loanIds.length;
        _openSizedAt(0, 12e6, 8500, borrowers[0]);
        require(_loanIds.length == n + 1, "BASELINE: the dust-bound loan did not open, so the close has no subject");
        uint256 loanId = _loanIds[n];
        uint256 pay = read.loan(loanId).debt - LoanMath.debtFloor(ace.idToMarketParams(mids[0]).minPrincipal) * 12 / 10;
        _fundQuote(borrowers[0], 0, pay);
        vm.prank(borrowers[0]);
        ace.repay(loanId, pay);
        _crankDisposal(loanId);
        require(read.loan(loanId).closedAt != 0, "BASELINE: the dust-bound crank did not close the loan");
        require(read.loan(loanId).debt == 0, "BASELINE: the closing crank left debt behind");
        require(crankCloses > 0, "BASELINE: the close ghost never counted the close");
        require(!crankLeftDust, "BASELINE: the closing crank tripped the dust ghost");
    }

    /// @notice THE EXTENSION'S WITNESS, pre-snapshot: a loan in a market resting NOTHING, extended in place twice by its holder in cash.
    /// @notice Each lands with zero cash resting, its fee pulled from the holder and its debt unmoved.
    /// @dev Structural, as the other baselines are: a regression in either refuses setUp, not a seed.
    function baselineExtend() external {
        _seed(lenders[0], 2_000e6);
        _open(borrowers[0], 2_000e6);
        uint256 loanId = _loanIds[_loanIds.length - 1];
        uint256 rested = read.restingOf(id);
        vm.prank(lenders[0]);
        ace.withdraw(id, type(uint256).max, lenders[0], 0);
        require(read.restingOf(id) == 0, "BASELINE: the incumbent still rests cash");
        require(_extendOne(loanId, 0), "BASELINE: the holder's cash extension did not land with nothing resting");
        require(_extendOne(loanId, 0), "BASELINE: the holder's second cash extension did not land with nothing resting");
        require(extendInPlaceCode == 0 && extendCode == 0, "BASELINE: an extension broke an in-place law");
        _seed(lenders[0], rested); // the campaign gets its headroom back; the loan stays live for the walk to pay
    }

    /// @notice One M1 -> M0 migration and one refused one, pre-snapshot, like every other baseline.
    /// @dev BOTH LEGS ARE REQUIRED: every fuzz action is try/catch-guarded, so a channel can refuse all campaign long.
    /// @dev Without a completion the isolation invariant's cross-market entitlement is true for want of a subject.
    /// @dev It opens its OWN loan: a migration CLOSES what it retires, so it never consumes a ctor loan another baseline counted on.
    /// @dev M1 -> M0, not the reverse: the pair is symmetric, and this leaves the incumbent's top tick funded.
    function _baselineMigrate() internal {
        /// @dev ITS OWN headroom, as the refinance baseline takes its own: the successor draws M0's top tick down.
        /// @dev Without it this eats the reserve the coverage tests read, which then see a draw minting nothing.
        _seed(lenders[0], 8_000e6);
        _open(borrowers[0], 2_000e6, 1);
        uint256 loanId = _loanIds[_loanIds.length - 1];
        Loan memory l = read.loan(loanId);
        /// @dev STRICTLY ABOVE the retiring debt: the successor funds the old debt AND its own
        /// @dev origination, so a draw equal to the debt refuses `DrawBelowDebt` and the leg looks inert.
        uint256 draw = l.debt + 1_000e6;
        _fundQuote(l.borrower, 0, draw + _fee(draw, l.tenor) + 5_000e6);
        vm.prank(l.borrower);
        try ace.refinanceTo(MigrateArgs(loanId, mids[0], draw, l.tenor, OpenBounds(0, 0, 0), 0, address(0))) returns (uint256 n) {
            migrationsDone++;
            loansOpened++;
            _track(n);
            landedInMarket[0]++;
        } catch (bytes memory err) {
            migrateRefusalSelector = _revertSelector(err);
        }
        require(migrationsDone > 0, "BASELINE: the M1->M0 migration never completed -- the cross-market verb is inert");
        _baselineMigrateRefusal();
    }

    /// @dev The quote gate, reached deliberately: M1 and M3 share a collateral and differ in quote.
    /// @dev Pinned by SELECTOR, not by "it reverted": a migration refused for the wrong reason would
    /// @dev otherwise count as the gate working, and this is the leg #177 lived behind.
    function _baselineMigrateRefusal() internal {
        _open(borrowers[0], 2_000e6, 1);
        uint256 loanId = _loanIds[_loanIds.length - 1];
        Loan memory l = read.loan(loanId);
        require(l.closedAt == 0 && l.debt > 0, "BASELINE: the refusal leg has no live loan to refuse");
        vm.prank(l.borrower);
        try ace.refinanceTo(MigrateArgs(loanId, mids[3], l.debt, l.tenor, OpenBounds(0, 0, 0), 0, address(0))) {
            revert("BASELINE: a cross-QUOTE migration succeeded, so the quote gate is not holding");
        } catch (bytes memory err) {
            migrationsRefused++;
            require(
                _revertSelector(err) == QuoteMismatch.selector, "BASELINE: the cross-quote migration refused for some OTHER reason, so the gate is unwitnessed"
            );
        }
    }

    /// @notice One drawn loan per driven market, pre-snapshot, so every market starts with a live book.
    /// @dev THE DILUTION MITIGATION, and the reason the per-market adequacy guard can be an assertion at all.
    /// @dev Actions are fixed, so each market gets ~1/M of a depth-32 sequence and a draw in each is a LOTTERY.
    /// @dev Reaching the state by construction makes the guard structural, and puts every loan-keyed verb live.
    function _baselineOpenEveryMarket() internal {
        for (uint256 i = 1; i < 4; i++) {
            _open(borrowers[i % borrowers.length], 1_000e6, i);
        }
        require(
            landedInMarket[1] > 0 && landedInMarket[2] > 0 && landedInMarket[3] > 0,
            "BASELINE: a driven market took no draw, so its ladder or its token is misconfigured"
        );
    }

    /// @notice Build M1..M3, the three driven markets beside the incumbent, and seed each a ladder.
    /// @dev FOUR IS THE MINIMUM: two quotes, two collaterals, one collateral spanning two quotes, one migratable pair.
    /// @dev M1 forks M0 only by record, so it shares quote AND collateral -- the one migratable pair.
    /// @dev M2 and M3 are the refusal legs, collateral mismatch and `QuoteMismatch`, and are driven on purpose.
    function _buildDrivenMarkets() internal {
        dai = new MockERC20("Dai Stablecoin", "DAI", 6);
        vault2 = new MockStakeVault(43);
        address[4] memory quotes = [address(usdc), address(usdc), address(usdc), address(dai)];
        address[4] memory colls = [address(vault), address(vault), address(vault2), address(vault)];
        for (uint256 i = 1; i < 4; i++) {
            records[i] = new MockPersistenceRecord(quotes[i], colls[i]);
            MarketParams memory p = AceFixtures.marketParams(quotes[i], colls[i]);
            p.record = address(records[i]);
            p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
            p.deleverageBandBps = BAND_BPS;
            p.deleverageTargetBps = 4000;
            p.deleverageStopBps = 1;
            /// @dev ONE LENDER PER MARKET AND ONE LENDER OVER SEVERAL MARKETS, both at once, and that is
            /// @dev the whole topology change. Sole tenancy forces the first; the POOLED properties need
            /// @dev the second, because a pool spans a lender's markets in one quote and a fixture giving
            /// @dev each market its own lender would leave every cross-market law summing a single term.
            /// @dev `lenders[0]` therefore holds M1 (usdc) AND M3 (dai) -- the pair that makes the
            /// @dev token-partition law reachable -- while M2 goes to a second lender so the isolation
            /// @dev property still has more than one actor to tell apart.
            p.lender = i == 2 ? lenders[1] : lenders[0];
            /// @dev M2 SELLS NO POT: the one driven market built with the hub's ask off, so an ask-off pot is a state the campaign reaches.
            /// @dev Its lender runs no other market and its collateral backs no other, so every unit leaving its pots has one honest payee.
            p.inventoryAsk = i != ASK_OFF_MARKET;
            /// @dev A market's price is part of its id, so distinct prices also keep these four distinct.
            p.price = PRICES[i];
            mids[i] = ace.createMarket(p);
            require(mids[i] != mids[0], "TOPOLOGY: a driven market collided with the incumbent");
            records[i].setAbove(true);
            records[i].setMinPrice(AceFixtures.px(2e18, quotes[i], colls[i]));
            unitScales[i] = read.marketState(mids[i]).unitScale;
            _seedMarket(i);
        }
        require(mids[1] != mids[2] && mids[2] != mids[3] && mids[1] != mids[3], "TOPOLOGY: two driven markets collided");
    }

    /// @dev Every driven market is seeded to the same DEPTH, so a deep state is reached by construction
    /// @dev rather than by lottery -- the fuzzer only has ~1/M of the sequence per market.
    /// @dev ONE DEPOSITOR, THREE TIMES, where it used to be three depositors once each: only the market's
    /// @dev named lender may rest, and the rest of the campaign is what proves a stranger cannot.
    /// @dev The TOTAL is unchanged at 15_000e6, so every depth-dependent assertion downstream still holds.
    function _seedMarket(uint256 i) internal {
        MockERC20 q = MockERC20(_quoteAt(i));
        address who = ace.idToMarketParams(mids[i]).lender;
        q.mint(who, 15_000e6);
        vm.startPrank(who);
        q.approve(address(ace), 15_000e6);
        for (uint256 k; k < 3; k++) {
            ace.deposit(mids[i], 5_000e6);
        }
        vm.stopPrank();
    }

    /// @dev Deploy the three policies and name the yes for both driven lenders, before any baseline, so the campaign starts consenting.
    /// @dev The canaries' lenders name none: their markets are never addressed, so no extension there asks anything.
    function _installPolicies() internal {
        (yesPolicy, noPolicy, gasPolicy) = (new YesPolicy(), new NoPolicy(), new GasBurnerPolicy());
        for (uint256 i; i < 2; i++) {
            vm.prank(lenders[i]);
            ace.setRollPolicy(address(yesPolicy));
            require(read.rollPolicyOf(lenders[i]) == address(yesPolicy), "TOPOLOGY: a driven lender's yes policy did not land");
        }
    }

    /// @dev The quote of a DRIVEN market, by index. `quoteOf` spans the canaries too; this one does not.
    function _quoteAt(uint256 i) internal view returns (address) {
        return i == 3 ? address(dai) : address(usdc);
    }

    /// @dev The collateral of a DRIVEN market. Only M2 forks it, which is what makes M0->M2 a refusal leg.
    function _collAt(uint256 i) internal view returns (address) {
        return i == 2 ? address(vault2) : address(vault);
    }

    /// @dev An actor's balance in a market's own quote; a call rather than a held handle, for the stack.
    function _quoteBal(address who, uint256 i) internal view returns (uint256) {
        return MockERC20(_quoteAt(i)).balanceOf(who);
    }

    /// @notice Build the untouched USDC canary and seed it, pre-snapshot like every other baseline.
    /// @dev The market id is `keccak256(abi.encode(p))`, so its own record is what forks it.
    /// @dev The requires are the witness: a colliding id or a shared lender would make the canary vacuous.
    function _buildCanary() internal {
        canaryRecord = new MockPersistenceRecord(address(usdc), address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(canaryRecord);
        /// @dev THE CANARY'S OWN LENDER, and the requires below are what make that load-bearing: it must
        /// @dev be no fuzzed actor, so no driven action can reach its pool any more than its market.
        /// @dev Under sole tenancy this is also what lets the seed land at all.
        p.lender = canaryLender;
        canaryId = ace.createMarket(p);
        require(canaryId != id, "CANARY: the second market collided with the driven one");
        for (uint256 i; i < lenders.length; i++) {
            require(canaryLender != lenders[i], "CANARY: its lender is also a fuzzed actor");
        }
        for (uint256 i; i < borrowers.length; i++) {
            require(canaryLender != borrowers[i], "CANARY: its lender is also a fuzzed actor");
        }
        require(canaryLender != keeper && canaryLender != trader, "CANARY: its lender is also a fuzzed actor");
        canaryRecord.setAbove(true);
        canaryRecord.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        usdc.mint(canaryLender, 9_000e6);
        vm.startPrank(canaryLender);
        usdc.approve(address(ace), 9_000e6);
        for (uint256 i; i < 3; i++) {
            ace.deposit(canaryId, 3_000e6);
        }
        vm.stopPrank();
        canarySeededCash = read.marketState(canaryId).cash;
        require(canarySeededCash == 9_000e6, "CANARY: the seed did not land, so the witness is empty");
        (canaries[0], canarySeededCashOf[0]) = (canaryId, canarySeededCash);
        _buildDaiCanary();
    }

    /// @notice The DAI-side canary, so the second quote token gets the same zero-state witness as the first.
    /// @dev Without it the per-token solvency identity is an equality on one token and a bare sum on the other.
    /// @dev Its lender is its own: sharing one with the usdc canary would let a single actor's mistake
    /// @dev show up as movement in both, and neither witness could then say which market moved.
    function _buildDaiCanary() internal {
        MockPersistenceRecord r = new MockPersistenceRecord(address(dai), address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(dai), address(vault));
        p.record = address(r);
        p.lender = canaryLender2; // its own, and distinct from the usdc canary's: two isolated witnesses
        canaries[1] = ace.createMarket(p);
        require(canaries[1] != canaries[0], "CANARY: the dai canary collided with the usdc one");
        for (uint256 i; i < 4; i++) {
            require(canaries[1] != mids[i], "CANARY: the dai canary collided with a driven market");
        }
        require(canaryLender2 != canaryLender, "CANARY: both canaries share a lender, so neither witness is isolated");
        r.setAbove(true);
        r.setMinPrice(AceFixtures.px(2e18, address(dai), address(vault)));
        dai.mint(canaryLender2, 9_000e6);
        vm.startPrank(canaryLender2);
        dai.approve(address(ace), 9_000e6);
        for (uint256 i; i < 3; i++) {
            ace.deposit(canaries[1], 3_000e6);
        }
        vm.stopPrank();
        canarySeededCashOf[1] = read.marketState(canaries[1]).cash;
        require(canarySeededCashOf[1] == 9_000e6, "CANARY: the dai seed did not land, so the witness is empty");
    }

    /// @dev The refinance baseline, pre-snapshot like the open and the settlement.
    /// @dev SUCCEEDS `_baselineRotation`, which armed a roll the codebase no longer has.
    /// @dev It opens its OWN loan rather than reusing the ctor's, so no earlier action has moved it.
    /// @dev The fresh draw must CLEAR the old debt: the verb refuses a short one rather than pulling it.
    function _baselineRefinance() internal {
        _seed(lenders[0], 8_000e6); // headroom, so the fresh draw is never cap-refused
        _open(borrowers[0], 2_000e6);
        _doRefinance(_loanIds[_loanIds.length - 1], 2_100e6);
    }

    // ---- construction + shared helpers ----

    function _seed(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        try ace.deposit(id, amt) {} catch {}
        vm.stopPrank();
    }

    function _fundUsdc(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(ace), amt);
    }

    /// @dev Fund in a DRIVEN market's own quote, so a dai market is never handed usdc it cannot take.
    function _fundQuote(address who, uint256 i, uint256 amt) internal {
        MockERC20 q = MockERC20(_quoteAt(i));
        q.mint(who, amt);
        vm.prank(who);
        q.approve(address(ace), amt);
    }

    /// @dev BIASED 40/20/20/20, not uniform: an even split leaves every market too shallow to reach settlement.
    /// @dev M0 keeps a deep single-market thread, and the other three still draw often enough to interact.
    /// @dev `picksInMarket` is the witness: without it the intent can starve a market silently.
    function _pickMarket(uint256 seed) internal returns (uint256 i) {
        uint256 r = seed % 10;
        i = r < 4 ? 0 : 1 + (r - 4) / 2;
        picksInMarket[i]++;
    }

    function _pickPrice(uint256 seed) internal view returns (uint256) {
        return PRICES[seed % PRICES.length];
    }

    function _bump(string memory tag) internal {
        calls[keccak256(bytes(tag))]++;
        _tag = tag;
        _foldOwed();
        _snapBook();
    }

    // DELETED with the roll reservation: `_deficits`, `_firstDeficit` and `_checkReserve`, the latch on a non-lender action leaving a market under it.

    /// @dev The booked tuple of one market, hashed: quantities no OTHER market's action may move.
    /// @dev MARKET-LOCAL ONLY, and the narrowing is deliberate rather than a casualty. `totalLent` and
    /// @dev `unitOwed` left `MarketState` for `pools[lender][quote]`, which SPANS a lender's markets --
    /// @dev so a draw in one of their markets legitimately moves the aggregate another market reads.
    /// @dev Hashing them here would make isolation FALSE for a correct hub, which is the failure a
    /// @dev port produces by keeping the tuple intact. The pool is exempt BY NAME, not by omission,
    /// @dev and `_invariant_poolsNeverCrossQuotes` is what holds the exemption to the quote it belongs to.
    function _bookOf(uint256 i) internal view returns (bytes32) {
        MarketState memory s = read.marketState(this.allMarketAt(i));
        return
            keccak256(
                abi.encode(s.cash, s.protocolRevenue, s.quoteOwedTotal, s.cumulativeBackedBurns, s.netSyntheticOutflow, s.realizedLossAtBook, s.drawCount)
            );
    }

    /// @dev Opens an action: every market's book is snapshotted and the entitled set is EMPTIED.
    function _snapBook() internal {
        for (uint256 i; i < 6; i++) {
            _bookSnap[i] = _bookOf(i);
        }
        _entitledMask = 0;
        crossMarketChecks++;
    }

    /// @dev Declares that this action may move market `i`. Called by the verb, before it acts.
    function _entitle(uint256 i) internal {
        _entitledMask |= (1 << i);
    }

    /// @dev The loan a loan-keyed verb acts on, entitling its market in the same breath.
    /// @dev ONE door for all fifteen of them, so a new loan-keyed verb cannot forget to entitle and
    /// @dev then report a crossing it did not commit -- the entitlement rides on the pick itself.
    function _pickLoan(uint256 seed) internal returns (uint256 loanId) {
        loanId = _loanIds[seed % _loanIds.length];
        _entitle(_marketIndexOf(loanId));
    }

    /// @dev Track a freshly issued loan, with the tenor it was issued at.
    function _track(uint256 loanId) internal {
        _loanIds.push(loanId);
        tenorAtIssue[loanId] = read.loan(loanId).tenor;
    }

    /// @dev `_pickLoan`, but the first LIVE tracked loan from the seed's slot on, wrapping once; the seed's own pick when none is.
    function _pickLiveLoan(uint256 seed) internal returns (uint256) {
        uint256 n = _loanIds.length;
        for (uint256 k; k < n; k++) {
            uint256 loanId = _loanIds[(seed % n + k) % n];
            if (read.loan(loanId).closedAt != 0) continue;
            _entitle(_marketIndexOf(loanId));
            return loanId;
        }
        return _pickLoan(seed);
    }

    /// @dev Closes an action: any market outside the entitled set whose book moved is a crossing.
    /// @dev First violation only, like every other ghost here: a later one must not overwrite it.
    function _checkIsolation() internal {
        if (crossMarketMoved) return;
        for (uint256 i; i < 6; i++) {
            if (_entitledMask & (1 << i) != 0) continue;
            if (_bookOf(i) == _bookSnap[i]) continue;
            crossMarketMoved = true;
            crossMarketId = i;
            crossMarketTag = _tag;
            return;
        }
    }

    /// @dev A fall in `unitOwed` has ONE destination -- a claim PAYOUT -- so a release here IS a payout.
    /// @dev IT WAS TWO while a lender's re-rest could take a fall without paying a wallet; that verb is deleted.
    /// @dev The identity the fold feeds is therefore `realized == released`, with no second term to sum against.
    /// @dev Run from both `_bump` and `_tail`, so a verb that skips the tail leaves no unfolded gap.
    /// @dev FOLDED PER POOL, WHICH IS THE GRANULARITY IT IS BANKED AT, and the two have to agree.
    /// @dev `poolOwed(mid)` reads the (lender, quote) pool a market WRITES INTO, never the market -- so
    /// @dev two markets of one lender in one quote report the SAME number and a per-market fold banks
    /// @dev each fall once per market. Measured here the moment `lenders[0]` took both M0 and M1: the
    /// @dev attribution equality read 6143424385 against 12286848770, an exact 2x.
    /// @dev This is the defect shape #559 records, and it returns the instant a fold is keyed on a market.
    /// @dev IT BANKS BOTH SIDES OF THE IDENTITY NOW, and that is what the terminal push forced. The realized
    /// @dev term used to be written only inside the `collect` ACTION, so a fall in `owed` that the HUB pushed
    /// @dev out at a terminal close was invisible to it -- the money reached a named payee and the ghost did
    /// @dev not watch that door. The identity itself never changed; only the number of doors did.
    /// @dev THE TEETH ARE KEPT, which is the whole reason not to just mirror the fall into both terms: the
    /// @dev realized side is the lender's own BALANCE DELTA, so a hub that reported a release and moved no
    /// @dev token banks nothing and the equality breaks. Capped at the fall, because a lender's wallet also
    /// @dev rises on `withdraw`, which is resting cash leaving and not a release from `owed`.
    function _foldOwed() internal {
        for (uint256 i; i < 4; i++) {
            if (_poolSlot(i) != i) continue; // a second market of the same pool is the same balance, not a second one
            uint256 owed = read.poolOwed(mids[i]);
            address lender = ace.idToMarketParams(mids[i]).lender;
            address tok = _quoteAt(i);
            uint256 bal = MockERC20(tok).balanceOf(lender);
            if (owed < _owedMarkOf[i]) {
                uint256 fell = _owedMarkOf[i] - owed;
                quoteReleasedEverOf[tok] += fell;
                uint256 rose = bal > _balMarkOf[i] ? bal - _balMarkOf[i] : 0;
                uint256 banked = rose < fell ? rose : fell;
                realizedQuoteOf[lender][tok] += banked;
                quoteDeliveredEver += banked; // the running total the per-address decomposition is checked against
            }
            (_owedMarkOf[i], _balMarkOf[i]) = (owed, bal);
        }
    }

    /// @dev The dust-wall check, asked ONLY after a lender door RETURNED. A draw is allowed to leave the
    /// @dev band and does so in one ordinary call, so reading this off the state would latch on a legal
    /// @dev draw; asked here it holds exactly the two doors that are floored to their own contract.
    /// @dev ON CASH ALONE: there is no roll reserve to exempt, so a door may leave nothing or a whole floor.
    function _checkDustWall(uint256 mi) internal {
        uint256 cash = read.marketState(mids[mi]).cash;
        if (cash == 0 || cash >= ace.idToMarketParams(mids[mi]).minPrincipal) return;
        lenderDoorLeftDust = true;
    }

    /// @dev The pool a driven market writes into, as a comparable key: its lender and its quote.
    function _poolKeyAt(uint256 i) internal view returns (bytes32) {
        MarketParams memory p = ace.idToMarketParams(mids[i]);
        return keccak256(abi.encode(p.lender, p.quote));
    }

    /// @dev The FIRST market index writing into the same (lender, quote) pool as `mi`: the one slot the owed fold marks.
    /// @dev `_foldOwed` and `_foldRedirect` both key on it, so the dedupe rule is written once and cannot drift.
    function _poolSlot(uint256 mi) internal view returns (uint256) {
        for (uint256 j; j < mi; j++) {
            if (_poolKeyAt(j) == _poolKeyAt(mi)) return j;
        }
        return mi;
    }

    /// @notice Per-action call count, for the run report.
    function callCount(string memory tag) external view returns (uint256) {
        return calls[keccak256(bytes(tag))];
    }

    /// @notice Every loan id the fuzzer has opened and tracks.
    function loanIds() external view returns (uint256[] memory) {
        return _loanIds;
    }

    function priceAt(uint256 i) external view returns (uint256) {
        return PRICES[i];
    }

    function priceCount() external pure returns (uint256) {
        return 6;
    }

    /// @notice The collateral every draw here posts, so a probe quote asks the same question the draw does.
    function collateralUnits() external pure returns (uint256) {
        return COLL;
    }

    /// @notice The tick's parked, reserved-to-nobody units, for the entitlement conservation check.
    /// @dev RETIRED with the reservation ledger: nothing is parked unreserved under pooled inventory.
    function unreservedUnitsAt(int24) external pure returns (uint256) {
        return 0;
    }

    function _fee(uint256 principal, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(id);
        return LoanMath.originationFee(principal, tenor, p.baseBps, p.minTenor);
    }

    // ---- ghost snapshots ----

    /// @dev THE FLAGGED-DEFICIT GHOSTS (inv-15) ARE DELETED WITH THE EXIT FLAGS, 2026-08-18.
    /// @dev Nothing reserves against a draw any more; an exiting lender withdraws or sells units.

    /// @dev Snapshot every tracked loan's funding floor around a PURE action; flag any move.
    /// @dev EACH PROBE FOLLOWS ITS OWN LOAN'S MARKET, exactly as `_snapFloors` does for the refinance.
    /// @dev Read against market 0 a loan drawn elsewhere reports zero at both ends: unmoved because unread.
    function _preFloors() internal view returns (uint256[] memory snap) {
        snap = new uint256[](_loanIds.length);
        for (uint256 i; i < _loanIds.length; i++) {
            snap[i] = read.fundingFloor(ace.loanMarket(_loanIds[i]), _loanIds[i]);
        }
    }

    function _postFloors(uint256[] memory snap, string memory tag) internal {
        for (uint256 i; i < snap.length; i++) {
            uint256 aft = read.fundingFloor(ace.loanMarket(_loanIds[i]), _loanIds[i]);
            if (aft != snap[i] && !floorViolated) {
                floorViolated = true;
                floorLoanId = _loanIds[i];
                floorBefore = snap[i];
                floorAfter = aft;
                floorAction = tag;
            }
        }
    }

    /// @dev End-of-action tail: closed is TERMINAL (no status enum), plus the coverage ghosts proving the run did not assert over an empty book.
    function _tail() internal {
        for (uint256 i; i < _loanIds.length; i++) {
            uint256 loanId = _loanIds[i];
            bool cur = read.loan(loanId).closedAt != 0;
            if (everClosed[loanId] && !cur && !monotonicityViolated) {
                monotonicityViolated = true;
                monoLoanId = loanId;
            }
            if (cur) everClosed[loanId] = true;
        }
        if (!everInventory && _sumInventory() > 0) everInventory = true;
        _foldOwed();
        _checkIsolation();
        _checkAskOffPots();
    }

    /// @dev A pot in the ask-off market may fall only across an in-kind exit; anything else that drains one latches, naming the verb.
    /// @dev The tag says WHICH DOOR and the suite's delivery equality says WHO: every unit that left sits in the lender's own wallet.
    function _checkAskOffPots() internal {
        bytes32 askOff = mids[ASK_OFF_MARKET];
        bool inKind = keccak256(bytes(_tag)) == keccak256("redeemInKind");
        for (uint256 j; j < _loanIds.length; j++) {
            uint256 loanId = _loanIds[j];
            if (ace.loanMarket(loanId) != askOff) continue;
            uint256 pot = read.invPotOf(askOff, loanId);
            uint256 had = _askOffPotMark[loanId];
            if (pot == had) continue;
            _askOffPotMark[loanId] = pot;
            if (pot > had) {
                if (had == 0) askOffPotsSeen++;
                continue;
            }
            askOffUnitsLeft += had - pot;
            if (inKind) {
                askOffInKindExits++;
            } else if (!askOffPotFellOutOfKind) {
                (askOffPotFellOutOfKind, askOffPotLoanId) = (true, loanId);
                askOffPotTag = _tag;
            }
        }
    }

    /// @notice The ask-off market's index over the driven set, and its lender: what the delivery equality is asked of.
    function askOffMarket() external view returns (bytes32 market, address lender, address collateralToken) {
        market = mids[ASK_OFF_MARKET];
        return (market, ace.idToMarketParams(market).lender, _collAt(ASK_OFF_MARKET));
    }

    /// @notice Every class pot across the tracked loans and the fuzz band: the LR-9 custody sum.
    /// @dev The pot is keyed (market, loan), so it follows each loan's OWN market -- read against market 0
    /// @dev a loan drawn elsewhere reports zero, and the custody sum silently under-counts.
    /// @dev ONE READ PER LOAN, and the inner walk is DELETED rather than re-pointed: the pot lost its tick
    /// @dev argument, so walking six of them added the same number six times. A per-rung loop kept around a
    /// @dev market-wide read is not a port, it is a multiplier -- and it over-counted by exactly 6x here.
    function _sumInventory() internal view returns (uint256 s) {
        for (uint256 j; j < _loanIds.length; j++) {
            s += read.invPotOf(ace.loanMarket(_loanIds[j]), _loanIds[j]);
        }
    }

    /// @notice Public twin for the invariant suite's LR-9 reconciliation.
    function sumInventory() external view returns (uint256) {
        return _sumInventory();
    }

    // ---- lender actions: PURE under the floor law, so no loan's funding floor may move ----

    /// @dev THE ACTOR IS MIXED ON PURPOSE: mostly the market's own lender, sometimes a stranger.
    /// @dev Sole tenancy refuses the stranger with `GateRefused`, and the `try` keeps that a driven
    /// @dev path rather than a dead one -- a handler that only ever deposits as the tenant never
    /// @dev exercises the door that holds foreign cash out of a market.
    function deposit(uint256 marketSeed, uint256 actorSeed, uint256 amtSeed) external {
        _bump("deposit");
        uint256 mi = _pickMarket(marketSeed);
        uint256 amt = bound(amtSeed, 1e6, 20_000e6);
        /// @dev ONE IN FOUR, the lender aims half a floor into an EMPTY market: the band the door must refuse, else the dust wall latches.
        bool aimed = amtSeed % 4 == 1 && read.marketState(mids[mi]).cash == 0;
        if (aimed) amt = ace.idToMarketParams(mids[mi]).minPrincipal / 2;
        _entitle(mi);
        address who = !aimed && actorSeed % 4 == 0 ? lenders[actorSeed % lenders.length] : ace.idToMarketParams(mids[mi]).lender;
        _fundQuote(who, mi, amt);
        uint256[] memory m = _preFloors();
        bool stranger = who != ace.idToMarketParams(mids[mi]).lender;
        vm.prank(who);
        try ace.deposit(mids[mi], amt) {
            landedInMarket[mi]++;
            _checkDustWall(mi);
            if (stranger) _latchStrangerMoved("deposit");
        } catch {
            if (stranger) strangerDoorsRefused++;
        }
        _postFloors(m, "deposit");
        _tail();
    }

    /// @dev Sole tenancy, asserted where the handler already drives it: a stranger's door call must refuse.
    /// @dev The money a stranger deposits credits the MARKET LENDER's pool, so no ledger reddens when the gate is gone.
    function _latchStrangerMoved(string memory door) internal {
        if (strangerMovedMoney) return;
        strangerMovedMoney = true;
        strangerMovedBy = door;
    }

    /// @dev NO LOT INDEX AND NO EARLY RETURN. Lots are gone: a market holds ONE balance, so there is
    /// @dev nothing to enumerate and nothing to pick. The old `lotCount == 0` bail also skipped the
    /// @dev empty-market case entirely, which is exactly where `NothingResting` has to be reached.
    function withdraw(uint256 marketSeed, uint256 actorSeed, uint256 amtSeed) external {
        _bump("withdraw");
        uint256 mi = _pickMarket(marketSeed);
        _entitle(mi);
        address who = actorSeed % 4 == 0 ? lenders[actorSeed % lenders.length] : ace.idToMarketParams(mids[mi]).lender;
        /// @dev ONE DRAW IN FOUR AIMS AT THE DUST BAND ON PURPOSE, and it is the only way that state is
        /// @dev reached. A bound of `[1, max]` almost always exceeds the balance, so the withdraw drains
        /// @dev the market whole and the sub-`minPrincipal` remainder never exists -- MEASURED: with the dust
        /// @dev wall mutated out of `Lender.withdraw`, the campaign stayed GREEN. The property was sound
        /// @dev and simply unreached, which is issue #190's class and not a weak assertion.
        /// @dev It is EXPECTED TO REVERT on a healthy hub. That is the point: the invariant then catches
        /// @dev the market sitting in the band only if the guard that refuses this call ever stops refusing.
        /// @dev ONE IN SIXTEEN, not one in four. At a quarter it measurably starved the deep lane: the
        /// @dev expiry-settle guard at depth 256 went from passing on 6 seeds of 10 to none, because a
        /// @dev dust-aimed withdraw is REFUSED and a refused verb advances no state toward an expiry.
        /// @dev The band still has to be reached -- the mutation above proves the property is otherwise
        /// @dev unreached -- so the draw stays; what changed is that it no longer crowds the sequence.
        /// @dev The band is resting cash alone: the aim leaves half a floor, with no reserve to exempt.
        uint256 amt = bound(amtSeed, 1, type(uint256).max);
        if (amtSeed % 16 == 1) {
            uint256 resting = read.marketState(mids[mi]).cash;
            uint256 floor = ace.idToMarketParams(mids[mi]).minPrincipal;
            if (resting > floor) amt = resting - (floor / 2); // squarely in the dust band
        }
        uint256[] memory m = _preFloors();
        bool stranger = who != ace.idToMarketParams(mids[mi]).lender;
        vm.prank(who);
        try ace.withdraw(mids[mi], amt, who, 0) {
            landedInMarket[mi]++;
            _checkDustWall(mi);
            if (stranger) _latchStrangerMoved("withdraw");
        } catch {
            if (stranger) strangerDoorsRefused++;
        }
        _postFloors(m, "withdraw");
        _tail();
    }

    /// @notice The pull payout: the caller's whole pool in this market's quote, paid to the caller.
    /// @dev WAS `claimUnits(actor, tick, loan)`, which picked a CLASS. There are no classes: one bucket per
    /// @dev market, one claimant, so the market id is the whole of the target and the actor is either it or not.
    /// @dev THE STRANGER DRAW IS DELIBERATE: three quarters of the draws collect as the market's lender, one
    /// @dev quarter as a fuzzed lender, who may run a pool of their own in this quote or none at all.
    /// @dev THE DOOR IS LENDER-ONLY BY ITS LEDGER KEY: a caller spends their own pool and nobody else's. So
    /// @dev what is worth latching is a stranger's collect moving the MARKET LENDER'S pool, which no `to` excuses.
    /// @dev A STRANGER WITH NOTHING OWED NAMES THE MARKET LENDER AS `to`: the one payee a `to`-keyed pool would drain.
    /// @dev One with credit pays itself: its pool paid to another wallet leaves `_foldOwed` a fall with no matching rise.
    /// @dev IT TAKES NO MARKET. The pool spans a lender's markets in this quote, so one call drains all of
    /// @dev them and `mi` only chooses the token, and whose pool a stranger must leave alone.
    function collect(uint256 marketSeed, uint256 actorSeed) external {
        _bump("collect");
        uint256 mi = _pickMarket(marketSeed);
        _entitle(mi);
        address lender = ace.idToMarketParams(mids[mi]).lender;
        address who = actorSeed % 4 == 0 ? lenders[actorSeed % lenders.length] : lender;
        address tok = _quoteAt(mi);
        uint256 promised = lens.claimable(who, tok);
        uint256 lenderOwed = ace.lenderOwed(lender, tok); // the market lender's pool, which a stranger's call must leave alone
        address to = who == lender || ace.lenderOwed(who, tok) != 0 ? who : lender;
        uint256[] memory m = _preFloors();
        vm.prank(who);
        try ace.collect(tok, to) returns (uint256 paid) {
            quoteClaimed += paid;
            /// @dev THE REALIZED TERM IS NOT BANKED HERE ANY MORE. `_foldOwed` is its single writer, because a
            /// @dev fall in `owed` has more than one door -- this one and the hub's PUSH at a terminal close -- and banking it
            /// @dev at one door alone is exactly what left the identity blind to the other. Banking it at both
            /// @dev would double-count every collect. The ghost below is still this action's own.
            if (who != lender && ace.lenderOwed(lender, tok) != lenderOwed) collectReachedAnotherPool = true;
            _checkClaimable(who, tok, promised, paid);
        } catch {}
        _postFloors(m, "collect");
        _tail();
    }

    /// @dev DELETED WITH THE REARM POLICY: the `setRearm` and `compound` ACTIONS, plus their `_armFor`,
    /// @dev `_snapRearm`, `_bankRest` and `_latchPreviewBreak` helpers. The campaign's action set is two
    /// @dev verbs smaller, and `collect` is the only door a fall in the credit leg can go out of.

    /// @notice The in-kind exit: the lender takes a settled loan's whole pot, an LR-9 outflow driver.
    /// @dev NO AMOUNT IS DRAWN any more -- the pot is taken whole or not at all, so there is nothing to size.
    /// @dev The stranger draw stays: `redeemInKind` is lender-gated, and the refusal leg needs a caller who is not.
    function redeemInKind(uint256 actorSeed, uint256 loanSeed) external {
        _bump("redeemInKind");
        if (_loanIds.length == 0) return;
        uint256 loanId = _pickLoan(loanSeed);
        bytes32 mkt = ace.loanMarket(loanId);
        address who = actorSeed % 4 == 0 ? lenders[actorSeed % lenders.length] : ace.idToMarketParams(mkt).lender;
        _entitle(_marketIndexOf(loanId));
        uint256[] memory m = _preFloors();
        bool stranger = who != ace.idToMarketParams(mkt).lender;
        vm.prank(who);
        try ace.redeemInKind(loanId, who) returns (uint256 out) {
            inventoryClaimedUnits += out;
            if (stranger) _latchStrangerMoved("redeemInKind");
        } catch {
            if (stranger) strangerDoorsRefused++;
        }
        _postFloors(m, "redeemInKind"); // an in-kind exit is not a claim: no floor may move
        _tail();
    }

    /// @notice THE STRONG LOCAL NO-THEFT PROBE: deposit `a`, then withdraw exactly `a` back.
    /// @dev WITHDRAWS `a`, NEVER `max`, and that change is forced rather than cosmetic. With lots, `max`
    /// @dev took the LOT this action had just opened, so the round trip was exact by construction. A market
    /// @dev holds ONE balance now, so `max` takes the seeded depth too and `out > a` is true of every
    /// @dev healthy call -- the probe would report theft on a correct hub, which is the shape a naive port
    /// @dev produces. Asking for `a` back restores the property the action was always making: what went in
    /// @dev comes out, and no more.
    /// @dev It ROUND-TRIPS, so the book usually returns to its snapshot and the isolation check would
    /// @dev pass whether or not it entitled anything. It entitles anyway: a partial exit leaves a delta,
    /// @dev and a verb that is exempt only by arithmetic accident is not a verb anyone should rely on.
    function depositThenExit(uint256 marketSeed, uint256 actorSeed, uint256 amtSeed) external {
        _bump("depositThenExit");
        uint256 mi = _pickMarket(marketSeed);
        _entitle(mi);
        address who = ace.idToMarketParams(mids[mi]).lender; // the round trip must LAND, so it is always the tenant
        uint256 a = bound(amtSeed, 1e6, 5_000e6);
        _fundQuote(who, mi, a);
        vm.startPrank(who);
        /// @dev NO LOT COMES BACK: `deposit` returns nothing now, because there is no lot to identify.
        try ace.deposit(mids[mi], a) {
            landedInMarket[mi]++;
        } catch {
            vm.stopPrank();
            _tail();
            return;
        }
        try ace.withdraw(mids[mi], a, who, 0) returns (uint256 cash) {
            if (cash > a && !theftFlag) {
                theftFlag = true;
                theftMarket = mi;
                theftValueIn = a;
                theftValueOut = cash;
            }
        } catch {}
        vm.stopPrank();
        _tail();
    }

    /// @notice The lender's exits to an address they NAME: a `withdraw` round trip, or a `collect` of their pool.
    /// @dev The payee is a third party, so solvency, the theft probe and attribution all see value leave to a non-caller.
    /// @dev Every check reads the PAYEE'S balance delta, never the returned figure, so a misdirected transfer is caught.
    /// @dev ONE WITHDRAW IN FOUR is floored a wei ABOVE its fill, so the campaign drives `BelowCallerFloor` too.
    function exitTo(uint256 marketSeed, uint256 amtSeed, uint256 legSeed) external {
        _bump("exitTo");
        uint256 mi = _pickMarket(marketSeed);
        _entitle(mi);
        address who = ace.idToMarketParams(mids[mi]).lender; // both doors pay the caller's own position, so the tenant is what lands
        uint256 had = _quoteBal(payee, mi);
        uint256[] memory m = _preFloors();
        if (legSeed % 2 == 0) _withdrawToPayee(mi, who, bound(amtSeed, 1e6, 5_000e6), (legSeed / 2) % 4 == 0, had);
        else _collectToPayee(mi, who, had);
        _postFloors(m, "exitTo");
        _tail();
    }

    /// @dev `depositThenExit` with a `to`: rest `a`, ask exactly `a` back at the payee, floored at `a` or at `a + 1`.
    /// @dev Over the fill, the ONLY admissible answer is `BelowCallerFloor`: the floor is checked before the dust wall.
    function _withdrawToPayee(uint256 mi, address who, uint256 a, bool overFloor, uint256 had) internal {
        _fundQuote(who, mi, a);
        vm.startPrank(who);
        try ace.deposit(mids[mi], a) {
            landedInMarket[mi]++;
        } catch {
            vm.stopPrank();
            return;
        }
        try ace.withdraw(mids[mi], a, payee, overFloor ? a + 1 : a) returns (uint256 cash) {
            if (overFloor) redirectFloorIgnored = true; // a fill of `a` met a floor of `a + 1`
            redirectWithdrawsLanded++;
            uint256 got = _quoteBal(payee, mi) - had;
            if (got != cash) redirectMisdelivered = true;
            if (got > a && !theftFlag) {
                theftFlag = true;
                theftMarket = mi;
                theftValueIn = a;
                theftValueOut = got;
            }
            if (got != 0) redirectWithdrawsPaid++;
        } catch (bytes memory err) {
            if (overFloor && _revertSelector(err) == BelowCallerFloor.selector) redirectFloorsRefused++;
            else if (overFloor) redirectFloorIgnored = true;
        }
        vm.stopPrank();
    }

    /// @dev The tenant's whole pool in this quote, to the payee; the fall is banked to the payee's delta.
    function _collectToPayee(uint256 mi, address who, uint256 had) internal {
        address tok = _quoteAt(mi);
        uint256 owed = ace.lenderOwed(who, tok);
        vm.prank(who);
        try ace.collect(tok, payee) returns (uint256 paid) {
            uint256 got = _quoteBal(payee, mi) - had;
            if (got != paid) redirectMisdelivered = true;
            if (owed != 0) redirectCollectsOwed++;
            if (got != 0) redirectCollectsPaid++;
            _foldRedirect(mi, who, tok, got);
        } catch {}
    }

    /// @dev `_foldOwed` banks a fall in `owed` to the LENDER's balance delta, which a redirect never raises.
    /// @dev So a redirected fall is banked here, to the payee's measured delta, and re-marked so the fold skips it.
    /// @dev Marked at `_poolSlot(mi)`, the one slot `_foldOwed` reads for that (lender, quote) pair.
    function _foldRedirect(uint256 mi, address lender, address tok, uint256 got) internal {
        uint256 k = _poolSlot(mi);
        uint256 owed = read.poolOwed(mids[mi]);
        if (owed < _owedMarkOf[k]) {
            uint256 fell = _owedMarkOf[k] - owed;
            uint256 banked = got < fell ? got : fell;
            quoteReleasedEverOf[tok] += fell;
            realizedQuoteOf[lender][tok] += banked;
            quoteDeliveredEver += banked;
        }
        _owedMarkOf[k] = owed;
    }

    // ---- the differential straddles: a quote surface against the mutator it quotes for ----

    /// @notice The quote `open` is about to be asked for, taken at the same block and the same state.
    /// @dev Never reverts: the refusal IS the answer here, exactly as `AceLens.tryQuoteOpen` reports it.
    /// @dev Unpranked would be equally valid -- previewOpen reads no caller -- but matching `open` keeps it apples to apples.
    function _quoteOpenNow(address who, uint256 principal, uint256 mi) internal view returns (bool ok, bytes4 sel, Borrower.Quote memory q) {
        try ace.previewOpen(mids[mi], _units(), principal, 0, who, OpenBounds(0, 0, 0)) returns (Borrower.Quote memory r) {
            return (true, bytes4(0), r);
        } catch (bytes memory err) {
            return (false, _revertSelector(err), q);
        }
    }

    /// @dev The revert's own selector; a bare or short revert reads zero.
    /// @dev Byte-wise, not `mload`: an assembly-assigned bytesN carries dirty low bits Solidity will not clean.
    function _revertSelector(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length < 4) return bytes4(0);
        s = bytes4(ret[0]) | (bytes4(ret[1]) >> 8) | (bytes4(ret[2]) >> 16) | (bytes4(ret[3]) >> 24);
    }

    /// @notice The quote against a draw that WENT THROUGH: it must have admitted, and its numbers must be the hub's.
    /// @dev A quote that refused what the draw funded is #175's shape, whatever the next instance turns out to be.
    function _quoteVsFundedOpen(bool ok, bytes4 sel, Borrower.Quote memory q, uint256 loanId, uint256 paid) internal {
        previewChecks++;
        if (!ok) {
            _latchQuoteRefusal(1, loanId, read.loan(loanId).debt, sel, bytes4(0));
            return;
        }
        previewBothAdmit++;
        _quoteNumbers(q, loanId, paid);
    }

    /// @notice Every number a quote reports, against what the hub then wrote for that same draw.
    /// @dev `lastFee`, the stored floor and the live trigger are the hub's own copies, not a re-derivation.
    /// @dev `bufferWad` alone has no second source, so it is checked against the floor and trigger the hub wrote.
    /// @dev The floor follows the LOAN's market: read against market 0, every quote elsewhere latches a false code 3.
    function _quoteNumbers(Borrower.Quote memory q, uint256 loanId, uint256 paid) internal {
        Loan memory l = read.loan(loanId);
        uint256 floor = read.fundingFloor(ace.loanMarket(loanId), loanId);
        uint256 trig = read.triggerPrice(loanId);
        if (q.fee != l.lastFee) {
            _latchQuoteNumber(loanId, l.debt, q.fee, l.lastFee, "fee");
            return;
        }
        if (q.payout != paid) {
            _latchQuoteNumber(loanId, l.debt, q.payout, paid, "payout");
            return;
        }
        if (q.postDrawFloor != floor) {
            _latchQuoteNumber(loanId, l.debt, q.postDrawFloor, floor, "postDrawFloor");
            return;
        }
        if (q.triggerAtOpen != trig) {
            _latchQuoteNumber(loanId, l.debt, q.triggerAtOpen, trig, "triggerAtOpen");
            return;
        }
        uint256 buf = floor == 0 ? 0 : ((floor - trig) * 1e18) / floor;
        if (q.bufferWad != buf) _latchQuoteNumber(loanId, l.debt, q.bufferWad, buf, "bufferWad");
    }

    /// @notice The quote against a draw the hub REFUSED: it must have refused too, and with the same selector.
    /// @dev A quote that admitted what the draw refused is #184's shape.
    /// @dev `previewOpen`'s header disclaims token-side failure; this fixture removes both its legs.
    /// @dev The payer holds and approves the collateral, and the ladder pays out of cash the hub holds.
    function _quoteVsRefusedOpen(bool ok, bytes4 pSel, bytes4 oSel, uint256 principal) internal {
        previewChecks++;
        if (ok) {
            _latchQuoteRefusal(2, 0, principal, bytes4(0), oSel);
            return;
        }
        previewBothRefuse++;
        if (pSel != oSel) _latchQuoteRefusal(4, 0, principal, pSel, oSel);
    }

    /// @dev First violation only, like every other ghost in this file: a later one must not overwrite it.
    function _latchQuoteRefusal(uint8 code, uint256 loanId, uint256 principal, bytes4 pSel, bytes4 oSel) internal {
        if (previewCode != 0) return;
        previewCode = code;
        previewLoanId = loanId;
        previewPrincipal = principal;
        previewSelector = pSel;
        openSelector = oSel;
    }

    function _latchQuoteNumber(uint256 loanId, uint256 principal, uint256 expected, uint256 actual, string memory field) internal {
        if (previewCode != 0) return;
        previewCode = 3;
        previewLoanId = loanId;
        previewPrincipal = principal;
        previewExpected = expected;
        previewActual = actual;
        previewField = field;
    }

    /// @notice What the lens promised a collect would pay, against what it paid.
    /// @dev `AceLens.claimable` previews the (lender, quote) POOL, which spans that lender's markets,
    /// @dev so this is an equality against one call that drains all of them -- not a per-market figure.
    /// @dev A REFUSED collect never reaches here -- the try/catch swallows it -- so a zero is not a break.
    function _checkClaimable(address lender, address quote, uint256 promised, uint256 paid) internal {
        claimableChecks++;
        if (paid > 0) claimablePaidChecks++;
        if (promised == paid || claimableDisagreed) return;
        claimableDisagreed = true;
        claimableLender = lender;
        claimableQuote = quote;
        claimablePromised = promised;
        claimablePaid = paid;
    }

    /// @notice The lens's finalize precondition against the hub's own gate, in both directions.
    /// @dev ONLY the leg the lens mirrors: a non-`NotSettleable` refusal is silence here, not a violation.
    /// @dev `LoanClosed` and `NoRecord` sit outside the lens's answer, so neither can falsify this.
    function _checkSettleable(uint256 loanId, bool promised, bytes4 sel) internal {
        settleableChecks++;
        if (sel == bytes4(0)) {
            if (promised) settleableAdmits++;
            else if (settleableCode == 0) (settleableCode, settleableLoanId) = (1, loanId);
            return;
        }
        if (sel != NotSettleable.selector) return;
        if (!promised) settleableRefusals++;
        else if (settleableCode == 0) (settleableCode, settleableLoanId) = (2, loanId);
    }

    /// @notice The settlement PROMISE, checked at the call site instead of inferred from a tally later.
    /// @notice `forceClose` declares exactly two refusals, and the caller established both false.
    /// @dev So a live loan at or past expiry MUST settle; a refusal is a regression, not seed luck.
    /// @dev Latched rather than asserted: `fail_on_revert` is off, so a revert in here would be swallowed whole.
    /// @dev Code 1 is the sharp one -- the hub contradicted a precondition this call had already proven.
    function _checkForceClose(uint256 loanId, bool owed, bytes4 sel) internal {
        if (!owed || forceCloseCode != 0) return;
        forceCloseLoanId = loanId;
        forceCloseSelector = sel;
        forceCloseCode = (sel == LoanClosed.selector || sel == NotExpired.selector) ? 1 : 2;
    }

    // ---- borrower + keeper actions ----

    function open(uint256 marketSeed, uint256 borrowerSeed, uint256 drawSeed) external {
        _bump("open");
        if (_loanIds.length >= MAX_LOANS) {
            opensRefusedAtCap++; // bounded on purpose; afterInvariant reports the cap rather than hiding it
            return;
        }
        _open(borrowers[borrowerSeed % borrowers.length], bound(drawSeed, 50e6, 12_000e6), _pickMarket(marketSeed));
        _tail();
    }

    /// @dev One loan of exactly `debt` with its trigger at `thetaBps` of the market's price; the close witness opens through it.
    /// @dev The collateral is SIZED, never `COLL`: `units = k * debt / (theta * price)` puts the trigger at `theta` of the price.
    function _openSizedAt(uint256 mi, uint256 debt, uint256 thetaBps, address who) internal {
        _entitle(mi);
        MarketParams memory p = ace.idToMarketParams(mids[mi]);
        uint256 units = FullMath.mulDiv(p.minCoverageWad * debt, unitScales[mi] * 10000, thetaBps * p.price * 1e18);
        MockStakeVault v = MockStakeVault(_collAt(mi));
        v.mint(who, units);
        vm.startPrank(who);
        v.approve(address(positionManager), units);
        try ace.open(mids[mi], units, debt, 0, who, OpenBounds(0, 0, 0)) returns (uint256 loanId) {
            landedInMarket[mi]++;
            if (!_knownLoan[loanId]) {
                _knownLoan[loanId] = true;
                _track(loanId);
                loansOpened++;
            }
        } catch {}
        vm.stopPrank();
    }

    /// @notice Fund a draw for `who`, register it if it opens, and straddle it with `previewOpen`.
    /// @dev THE PREVIEW STRADDLE: the quote is taken at the same block and state the draw then runs on.
    /// @dev `tenor` 0 here is deliberate and load-bearing: it is the sentinel BOTH doors must spell.
    /// @dev The payout leg is measured as the payee's own quote delta, so it checks a transfer, not arithmetic.
    /// @dev The incumbent's door, kept so every baseline reads as it did before the registry landed.
    function _open(address who, uint256 principal) internal {
        _open(who, principal, 0);
    }

    /// @dev Collateral, quote and the preview straddle all follow the MARKET, so a dai market is never
    /// @dev funded in usdc and the straddle is asked of the same market the draw then runs against.
    function _open(address who, uint256 principal, uint256 mi) internal {
        _entitle(mi);
        /// @dev Scoped, and the token is re-read rather than held: the market index costs a slot the
        /// @dev single-market version did not pay, and holding a token handle too puts this over the limit.
        {
            MockStakeVault v = MockStakeVault(_collAt(mi));
            MockERC20 t = MockERC20(_quoteAt(mi));
            uint256 reserve = 3 * _fee(principal, ProtocolPolicy.MIN_TENOR) + 1e6;
            v.mint(who, _units());
            t.mint(who, reserve);
            vm.startPrank(who);
            v.approve(address(positionManager), _units());
            t.approve(address(ace), reserve);
        }
        (bool qOk, bytes4 qSel, Borrower.Quote memory q) = _quoteOpenNow(who, principal, mi);
        uint256 payeeBefore = _quoteBal(who, mi);
        try ace.open(mids[mi], _units(), principal, 0, who, OpenBounds(0, 0, 0)) returns (uint256 loanId) {
            _quoteVsFundedOpen(qOk, qSel, q, loanId, _quoteBal(who, mi) - payeeBefore);
            landedInMarket[mi]++;
            if (!_knownLoan[loanId]) {
                _knownLoan[loanId] = true;
                _track(loanId);
                loansOpened++;
            }
        } catch (bytes memory err) {
            _quoteVsRefusedOpen(qOk, qSel, _revertSelector(err), principal);
        }
        vm.stopPrank();
    }

    /// @dev The units a draw posts: `COLL` for every draw but a near-line one, which sets its own for exactly one call.
    /// @dev Held in storage rather than threaded, because `_open` sits at the stack limit already.
    function _units() internal view returns (uint256) {
        return _drawUnits == 0 ? COLL : _drawUnits;
    }

    /// @notice A draw posting units within atoms of its coverage line: one under it, on it, or just past it.
    /// @dev Every other draw here posts far more than the line asks, so the line's refusal at both doors went unexercised.
    /// @dev The landed ones reach expiry as any loan does, so `forceClose` also settles a loan sitting near its own line.
    function openNearLine(uint256 marketSeed, uint256 borrowerSeed, uint256 drawSeed, uint256 slackSeed) external {
        _bump("openNearLine");
        if (_loanIds.length >= MAX_LOANS) {
            opensRefusedAtCap++;
            return;
        }
        uint256 mi = _pickMarket(marketSeed);
        Cfg memory c;
        c.p = ace.idToMarketParams(mids[mi]);
        c.unitScale = unitScales[mi];
        uint256 principal = bound(drawSeed, c.p.minPrincipal, 4_000e6);
        _drawUnits = Borrower.coverageLine(c, principal, c.p.price) + (slackSeed % 4) - 1; // the line less one, on it, one or two past
        uint256 n = _loanIds.length;
        _open(borrowers[borrowerSeed % borrowers.length], principal, mi);
        _drawUnits = 0;
        if (_loanIds.length > n) nearLineOpened++;
        _tail();
    }

    /// @notice A dust-bound loan, 2x to 2.5x the debt floor (`minPrincipal` to 1.25x it) at an 85% trigger: within the close's reach here.
    /// @dev Every other draw is large, so without it every close the campaign counts is the baseline's.
    /// @dev One seed in eight proposes `minPrincipal - 1`, which the hub must refuse: the only sub-floor birth the born-at invariant ever sees.
    function openSmall(uint256 marketSeed, uint256 borrowerSeed, uint256 sizeSeed) external {
        _bump("openSmall");
        if (_loanIds.length >= MAX_LOANS) {
            opensRefusedAtCap++;
            return;
        }
        uint256 mi = _pickMarket(marketSeed);
        uint256 mp = ace.idToMarketParams(mids[mi]).minPrincipal;
        uint256 n = _loanIds.length;
        uint256 size = sizeSeed % 8 == 7 ? mp - 1 : bound(sizeSeed, mp, mp * 5 / 4);
        _openSizedAt(mi, size, 8500, borrowers[borrowerSeed % borrowers.length]);
        if (_loanIds.length > n) {
            smallOpened++;
            _isSmall[_loanIds[n]] = true;
        }
        _tail();
    }

    /// @dev A partial that would leave the loan under its debt floor lands ON it instead, or pays it off where there is no room.
    /// @dev Unsnapped it only reverts into the catch; snapped, it drives the floor state. An in-range seed is still the amount.
    function repay(uint256 loanSeed, uint256 amtSeed) external {
        _bump("repay");
        if (_loanIds.length == 0) return;
        uint256 loanId = _pickLoan(loanSeed);
        Loan memory l = read.loan(loanId);
        if (l.debt == 0) return;
        uint256 md = LoanMath.debtFloor(ace.idToMarketParams(ace.loanMarket(loanId)).minPrincipal);
        uint256 room = l.debt > md ? l.debt - md : 0;
        uint256 amt = bound(amtSeed, 1, l.debt);
        if (amt < l.debt && amt > room) amt = room == 0 ? l.debt : room;
        bool toFloor = amt == room && l.closedAt == 0;
        if (toFloor) floorRepaysTried++;
        _fundQuote(l.borrower, _marketIndexOf(loanId), amt); // a dai loan is repaid in dai, never in usdc
        vm.prank(l.borrower);
        try ace.repay(loanId, amt) {
            if (toFloor && read.loan(loanId).debt == md) repaysToTheFloor++;
        } catch {}
        _tail();
    }

    /// @dev The ONE verb that drives `retitle`: without it the two title ledgers only ever meet at mint.
    /// @dev Distress is NOT excluded -- selling a distressed position is allowed, so the fuzzer may too.
    function transferTitle(uint256 loanSeed, uint256) external {
        _bump("transferTitle");
        if (_loanIds.length == 0) return;
        uint256 loanId = _pickLoan(loanSeed);
        address from = ace.borrowerOf(loanId);
        /// @dev The OTHER borrower, never a seeded pick: over two actors a seed lands on `from` half the time.
        /// @dev A self-move no-ops, halving the only verb that can make the title invariant bite.
        address to = from == borrowers[0] ? borrowers[1] : borrowers[0];
        if (from == address(0) || from == to) return;
        PositionTitleNFT title = PositionTitleNFT(ace.POSITION_TITLE()); // resolved BEFORE the prank, which it would consume
        vm.prank(from);
        try title.transferFrom(from, to, loanId) {
            titlesTransferred++;
        } catch {}
        _tail();
    }

    function withdrawCollateral(uint256 loanSeed, uint256 unitSeed) external {
        _bump("withdrawCollateral");
        if (_loanIds.length == 0) return;
        uint256 loanId = _pickLoan(loanSeed);
        Loan memory l = read.loan(loanId);
        if (l.collateralUnits == 0) return;
        uint256 units = bound(unitSeed, 1, l.collateralUnits);
        vm.prank(l.borrower);
        try ace.withdrawCollateral(loanId, units, l.borrower) {} catch {}
        _tail();
    }

    /// @notice The pull-credit exit: what a close, a settlement or a migration credited its claimant.
    /// @dev Fuzzed over BOTH the holder and a stranger, so a claim that pays the wrong party shows up
    /// @dev in the solvency identity rather than only in a unit test.
    function claimOwed(uint256 loanSeed, uint256 whoSeed) external {
        _bump("claimOwed");
        if (_loanIds.length == 0) return;
        uint256 loanId = _pickLoan(loanSeed);
        address who = whoSeed % 2 == 0 ? read.loan(loanId).borrower : address(uint160(uint256(keccak256(abi.encode("claimStranger", whoSeed)))));
        if (who == address(0)) return;
        vm.prank(who);
        try ace.claimOwed(loanId, who) {} catch {}
        _tail();
    }

    /// @notice The continuation verb: close and reopen atomically at a fuzzed new principal.
    /// @dev The one verb that REPLACES a loan; `extend` lengthens one in place.
    /// @dev Picks among LIVE, UNEXPIRED loans only, as `deleverage` does: from expiry a refinance refuses `LoanMatured`, and the catch would hide it.
    function refinance(uint256 loanSeed, uint256 principalSeed) external {
        _bump("refinance");
        if (_loanIds.length == 0) return;
        (bool found, uint256 idx) = _crankableIndex(loanSeed);
        if (!found) return;
        uint256 loanId = _pickLoan(idx);
        Loan memory l = read.loan(loanId);
        if (l.debt == 0) return;
        // the loan's OWN params, exactly as `migrate` bounds against its destination's
        uint256 newPrincipal = bound(principalSeed, ace.idToMarketParams(ace.loanMarket(loanId)).minPrincipal, l.debt + 2_000e6);

        _doRefinance(loanId, newPrincipal);
        _tail();
    }

    /// @dev One refinance, with the cross-loan floor law latched around it.
    /// @dev Shared by the fuzz action and the constructor baseline so both count the same way.
    function _doRefinance(uint256 loanId, uint256 newPrincipal) internal {
        Loan memory l = read.loan(loanId);
        uint256[] memory floorsBefore = _snapFloors(loanId);
        /// @dev The loan's OWN quote: funded in usdc a dai refinance cannot pay its fee, and the catch hides it.
        _fundQuote(l.borrower, _marketIndexOf(loanId), newPrincipal + _fee(newPrincipal, l.tenor) + 5_000e6);

        MigrateArgs memory home = MigrateArgs(loanId, l.market, newPrincipal, l.tenor, OpenBounds(0, 0, 0), 0, address(0));
        vm.prank(l.borrower);
        try ace.refinanceTo(home) returns (uint256 n) {
            refinancesDone++;
            loansOpened++;
            _track(n);
        } catch {
            refinancesRefused++;
        }
        _checkFloorsUnmoved(floorsBefore, loanId);
    }

    /// @dev Every OTHER live loan's funding floor, snapshotted before a refinance touches the ladder.
    /// @dev EACH PROBE FOLLOWS ITS OWN LOAN'S MARKET: a floor unmoved because it was never read holds nothing.
    function _snapFloors(uint256 skipId) internal view returns (uint256[] memory snap) {
        snap = new uint256[](_loanIds.length);
        for (uint256 i; i < _loanIds.length; i++) {
            if (_loanIds[i] == skipId) continue;
            snap[i] = read.fundingFloor(ace.loanMarket(_loanIds[i]), _loanIds[i]);
        }
    }

    /// @dev Latch the first violation: a refinance may retire ITS loan's floor and no other.
    function _checkFloorsUnmoved(uint256[] memory snap, uint256 skipId) internal {
        for (uint256 i; i < snap.length; i++) {
            if (_loanIds[i] == skipId || refinanceMovedFloor) continue;
            uint256 now_ = read.fundingFloor(ace.loanMarket(_loanIds[i]), _loanIds[i]);
            if (now_ != snap[i]) {
                refinanceMovedFloor = true;
                refinanceFloorLoanId = _loanIds[i];
                refinanceFloorBefore = snap[i];
                refinanceFloorAfter = now_;
            }
        }
    }

    /// @notice `refinanceTo`: retires a loan in one market and opens its successor in another.
    /// @notice The only verb that MOVES A POSITION between markets.
    /// @dev The destination is picked over ALL four on purpose: M0->M1 is the only compatible pair.
    /// @dev M0->M2 refuses on collateral and M0->M3 on quote, and a gate nothing reaches is a gate nothing proved.
    /// @dev Picks among LIVE, UNEXPIRED loans only: from expiry it refuses `LoanMatured`, a refusal that would thin the gate's tallies.
    function migrate(uint256 loanSeed, uint256 dstSeed, uint256 principalSeed) external {
        _bump("migrate");
        if (_loanIds.length == 0 || _loanIds.length >= MAX_LOANS) return;
        (bool found, uint256 idx) = _crankableIndex(loanSeed);
        if (!found) return;
        uint256 loanId = _pickLoan(idx);
        Loan memory l = read.loan(loanId);
        if (l.debt == 0) return;
        uint256 dst = dstSeed % 4;
        uint256 newPrincipal = bound(principalSeed, ace.idToMarketParams(mids[dst]).minPrincipal, l.debt + 2_000e6);
        uint256[] memory floorsBefore = _snapFloors(loanId);

        uint256 mi = _marketIndexOf(loanId);
        /// @dev TWO, NAMED. The assertion, not an exemption: source retired, destination opened, nothing else moved.
        _entitle(mi);
        _entitle(dst);
        _fundQuote(l.borrower, mi, newPrincipal + _fee(newPrincipal, l.tenor) + 5_000e6);
        _fundQuote(l.borrower, dst, newPrincipal + _fee(newPrincipal, l.tenor) + 5_000e6);
        migrationsAttempted++;
        vm.prank(l.borrower);
        try ace.refinanceTo(MigrateArgs(loanId, mids[dst], newPrincipal, l.tenor, OpenBounds(0, 0, 0), 0, address(0))) returns (uint256 n) {
            migrationsDone++;
            loansOpened++;
            _track(n);
            landedInMarket[dst]++;
        } catch (bytes memory err) {
            migrationsRefused++;
            if (migrateRefusalSelector == bytes4(0)) migrateRefusalSelector = _revertSelector(err);
        }
        _checkFloorsUnmoved(floorsBefore, loanId);
        _tail();
    }

    /// @notice The disposal crank; also the path that carries the revenue sweep.
    /// @dev Measures the trigger DIRECTION around every successful crank, which is the property #208 bought.
    /// @dev RENAMED from `skim`, which it never called: the body has driven `ace.deleverage` throughout.
    /// @dev Picks among LIVE, UNEXPIRED loans only: a matured loan refuses `LoanMatured`, and the catch would hide it.
    function deleverage(uint256 loanSeed) external {
        _bump("deleverage");
        if (_loanIds.length == 0) return;
        (bool found, uint256 idx) = _crankableIndex(loanSeed);
        if (found) _crankDisposal(_pickLoan(idx));
        _tail();
    }

    /// @dev The first live, unexpired tracked loan at or after the seed's own pick, wrapping once round: what a crank or a refinance can act on.
    /// @dev A seed that already names such a loan still gets that loan, so a written sequence keeps its target.
    function _crankableIndex(uint256 seed) internal view returns (bool found, uint256 idx) {
        uint256 n = _loanIds.length;
        for (uint256 k; k < n; k++) {
            idx = (seed % n + k) % n;
            Loan memory l = read.loan(_loanIds[idx]);
            if (l.closedAt == 0 && _now() < l.expiry) return (true, idx);
        }
    }

    /// @dev Arms the band on THIS loan, cranks, then restores the healthy print every other verb assumes.
    /// @dev NOT pranked: solver routing calls the caller back, and `keeper` is a codeless EOA.
    /// @dev EVERY MOCK HERE FOLLOWS THE LOAN'S MARKET: arming market 0's prices one the crank is not cranking.
    /// @dev `_crankQuote` is latched first -- the callback mints the proceeds, and the wrong token is a silent no-op.
    function _crankDisposal(uint256 loanId) internal {
        uint256 trig = read.triggerPrice(loanId);
        if (trig == 0) return;
        uint256 mi = _marketIndexOf(loanId);
        _crankQuote = _quoteAt(mi);
        MockPersistenceRecord r = records[mi];
        uint256 debtBefore = read.loan(loanId).debt;
        uint256 collBefore = read.loan(loanId).collateralUnits;
        uint256 ps = trig + trig / 20; // 5% over the trigger: inside the band, well above the stop
        r.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        r.setMinPrice(ps);
        try ace.deleverage(loanId, 0, "") returns (uint256 u, uint256) {
            skimSuccesses++;
            _checkSkimDirection(loanId, debtBefore, collBefore, u);
            _checkDust(loanId, mi, u);
        } catch {}
        _healRecord(r);
    }

    /// @dev Count a close, and latch the first selling crank that left a live loan under its debt floor or a closed one holding debt.
    function _checkDust(uint256 loanId, uint256 mi, uint256 u) internal {
        Loan memory l = read.loan(loanId);
        if (l.closedAt != 0) crankCloses++;
        if (u != 0 && _isSmall[loanId]) {
            smallCranked++;
            if (l.closedAt != 0) smallCloses++;
        }
        if (u == 0 || crankLeftDust) return;
        bool dust = l.closedAt != 0 ? l.debt != 0 : l.debt < LoanMath.debtFloor(ace.idToMarketParams(mids[mi]).minPrincipal);
        if (!dust) return;
        crankLeftDust = true;
        crankDustLoanId = loanId;
        crankDustDebt = l.debt;
    }

    /// @dev The healthy print the rest of the campaign draws against.
    function _healRecord(MockPersistenceRecord r) internal {
        r.setBelowBand(0);
        r.setBelow(false);
        r.setMinPrice(AceFixtures.px(2e18, address(dai), address(vault)));
    }

    /// @dev Which driven market a tracked loan belongs to. Every tracked loan is opened into one, so a
    /// @dev miss is a handler bug and says so rather than defaulting to market 0 and mispricing silently.
    function _marketIndexOf(uint256 loanId) internal view returns (uint256) {
        return _indexOfMarket(ace.loanMarket(loanId));
    }

    /// @dev A market id back to its driven index; the rearm policy names an id, not an index.
    function _indexOfMarket(bytes32 m) internal view returns (uint256) {
        for (uint256 i; i < 4; i++) {
            if (mids[i] == m) return i;
        }
        revert("HANDLER: a tracked market is in no driven slot");
    }

    /// @dev The trigger is `k * debt * S / (coll * 1e18)`, so it does not rise iff `pay/unitsSold >= debt/coll`.
    /// @dev Cross-multiplied here rather than recomputed, so the check cannot drift from the formula.
    /// @dev A crank that sold nothing is skipped: it moves neither side and would only pad the counter.
    /// @dev On a CLOSED loan `closeClean` zeroed the position, so the units sold are the crank's own `u`; `_checkDust` holds its pay to the whole debt.
    function _checkSkimDirection(uint256 loanId, uint256 debtBefore, uint256 collBefore, uint256 u) internal {
        uint256 unitsSold = read.loan(loanId).closedAt != 0 ? u : collBefore - read.loan(loanId).collateralUnits;
        if (unitsSold == 0) return;
        uint256 pay = debtBefore - read.loan(loanId).debt;
        skimsMeasured++;
        debtMelted += pay; // the melt leg's only structural witness now the reward crank is gone
        if (pay * collBefore >= debtBefore * unitsSold || deleverageRaisedTrigger) return;
        deleverageRaisedTrigger = true;
        deleverageTriggerLoanId = loanId;
        deleveragePay = pay;
        deleverageUnitsSold = unitsSold;
        deleverageDebtBefore = debtBefore;
        deleverageCollBefore = collBefore;
    }

    /// @dev The reward-claim drivers went with the channel they drove; nothing here consumes a vault's foreign token.
    /// @dev So no stand-in pusher replaces them: it would move a balance no assertion in this campaign reads.

    /// @notice Reward accrual (rate up) or a validator slash (rate down) on the mock; no hub verb reads a rate now.
    /// @dev BOTH vaults: `vault` backs M0/M1/M3 and `vault2` backs M2, whose coverage arithmetic is otherwise pinned.
    function setRate(uint256 rateSeed) external {
        _bump("setRate");
        uint256 r = bound(rateSeed, 0.5e18, 3e18);
        vault.setRate(r); // mock-only: reaches no hub storage, so no floor probe
        vault2.setRate(r);
        _tail();
    }

    /// @notice A driven market's lender names its roll policy: the yes, the no, one that burns its whole gas budget, or none.
    /// @dev Biased five in eight to the yes, so the holder's extension keeps landing between the refusals.
    /// @dev Entitles NOTHING: a policy lives in the lender's record, so a market book that moves here is a crossing.
    function setRollPolicy(uint256 lenderSeed, uint256 kindSeed) external {
        _bump("setRollPolicy");
        address lender = lenders[lenderSeed % 2];
        uint256 r = kindSeed % 8;
        uint256 kind = r < 5 ? 0 : r - 4;
        address[4] memory policies = [address(yesPolicy), address(noPolicy), address(gasPolicy), address(0)];
        vm.prank(lender);
        try ace.setRollPolicy(policies[kind]) {
            policySets[kind]++;
        } catch {}
        _tail();
    }

    /// @notice THE HOLDER'S EXTENSION, in cash: `tryExtend` asked for the holder, straddled against the `extend` it then sends.
    /// @notice It tries loans within reach from the seed's pick on until one extends, so the cash fee and the re-spread are reached.
    /// @notice With none in reach it asks the seed's own pick, closed or matured, so the refusal straddle still runs.
    /// @dev Same block, same state: the view is read IMMEDIATELY before the call it predicts, and both name the same caller.
    /// @dev Matured loans are skipped: each refuses `LoanMatured`, and trying it healed its market's record and padded the refusal tally.
    function extend(uint256 loanSeed, uint256 whenSeed) external {
        _bump("extend");
        uint256 n = _loanIds.length;
        bool found;
        for (uint256 k; k < n; k++) {
            uint256 loanId = _loanIds[(loanSeed % n + k) % n];
            if (!_reachable(loanId)) continue;
            found = true;
            _entitle(_marketIndexOf(loanId));
            if (_extendOne(loanId, whenSeed)) break;
        }
        if (found) {
            extendCalls++;
        } else if (n != 0) {
            extendFallbacks++;
            _extendOne(_pickLoan(loanSeed), whenSeed);
        }
        _tail();
    }

    /// @dev Whether an extension can still land: live, and short of its expiry.
    /// @dev `_extendOne` first warps to a seeded second past the open one, where an extension adds no time, and short of expiry.
    /// @dev Judged at the later of the clock and the chain, which is the time `_warpAtLeastTo` re-anchors to and the hub reads.
    function _reachable(uint256 loanId) internal view returns (bool) {
        Loan memory l = read.loan(loanId);
        return l.closedAt == 0 && _later() < l.expiry;
    }

    /// @dev The later of the campaign clock and the chain's.
    function _later() internal view returns (uint256) {
        uint256 chain = vm.getBlockTimestamp(); // a cheatcode read, which the optimizer cannot hoist past a warp
        return chain > _now() ? chain : _now();
    }

    /// @dev Warp to a seeded second inside `loanId`'s term: past its open second and the present, short of its expiry.
    function _warpIntoTerm(uint256 loanId, uint256 whenSeed) internal {
        Loan memory l = read.loan(loanId);
        uint256 t = _later();
        uint256 lo = t > l.openTime ? t : uint256(l.openTime) + 1;
        _warpAtLeastTo(bound(whenSeed, lo, uint256(l.expiry) - 1));
    }

    /// @notice Whether an extension can still land on `loanId`: the reach `extend` and `lenderExtend` pick by.
    function reachable(uint256 loanId) external view returns (bool) {
        return _reachable(loanId);
    }

    /// @dev The first tracked loan within reach from the seed's slot on, wrapping once, its market entitled; not found when none is.
    function _reachableLoan(uint256 seed) internal returns (bool found, uint256 loanId) {
        uint256 n = _loanIds.length;
        for (uint256 k; k < n; k++) {
            loanId = _loanIds[(seed % n + k) % n];
            if (!_reachable(loanId)) continue;
            _entitle(_marketIndexOf(loanId));
            return (true, loanId);
        }
    }

    /// @notice THE E-3 PATH: the market lender, holding the holder's credit grant, extends a loan within reach in cash it pays itself.
    /// @notice One ask in four runs ungranted: it must refuse `NotBorrower`, at the view and at the verb.
    /// @dev The holder sets or revokes the grant first, so the grant is the seed's, never a leftover of an earlier call.
    function lenderExtend(uint256 loanSeed, uint256 grantSeed) external {
        _bump("lenderExtend");
        (bool found, uint256 loanId) = _reachableLoan(loanSeed);
        if (found) _lenderExtendOne(loanId, grantSeed % 4 != 0, grantSeed >> 8);
        _tail();
    }

    /// @dev One operator extension, straddled as the holder's is; the fee is funded to the lender, and only the lender's wallet may pay it.
    /// @return landed Whether the verb extended the loan.
    function _lenderExtendOne(uint256 loanId, bool granted, uint256 whenSeed) internal returns (bool landed) {
        uint256 mi = _marketIndexOf(loanId);
        address holder = ace.borrowerOf(loanId);
        address lender = ace.idToMarketParams(mids[mi]).lender;
        if (holder == lender) return false; // the lender's own loan is the holder's path, not this one
        _warpIntoTerm(loanId, whenSeed);
        _healRecord(records[mi]);
        vm.prank(holder);
        ace.setCreditOperator(lender, granted);
        operatorTries++;
        ExtendPre memory s = _extendView(loanId, mi, lender);
        _fundQuote(lender, mi, s.vFee);
        s.hubQuote = MockERC20(_quoteAt(mi)).balanceOf(address(ace));
        (uint256 lenderHad, uint256 holderHad) = (_quoteBal(lender, mi), _quoteBal(holder, mi));
        vm.prank(lender);
        try ace.extend(loanId, 0, "") returns (uint256 fee) {
            landed = true;
            operatorLanded++;
            _viewVsExtended(s.vOk, s.vSel, s.vFee, loanId, fee, 1);
            _checkExtendInPlace(loanId, mi, s, fee);
            if (!granted) _latchOperator(1, loanId);
            else if (_quoteBal(lender, mi) + fee != lenderHad || _quoteBal(holder, mi) != holderHad) _latchOperator(3, loanId);
        } catch (bytes memory err) {
            bytes4 got = _revertSelector(err);
            _viewVsRefusedExtension(s.vOk, s.vSel, loanId, got, 1);
            if (granted) return false;
            if (got == NotBorrower.selector) operatorRefusedByName++;
            else _latchOperator(2, loanId);
        }
    }

    /// @dev First violation only, like every other latch here.
    function _latchOperator(uint8 code, uint256 loanId) internal {
        if (operatorCode == 0) (operatorCode, operatorLoanId) = (code, loanId);
    }

    /// @dev What an extension must leave as it was, or move by exactly its own terms.
    struct ExtendPre {
        uint256 loans;
        uint64 expiry;
        uint256 debt;
        uint256 resting;
        uint256 hubQuote;
        uint64 tenor; // the loan's own, which an extension runs again from now
        bool vOk; // the view's answer, asked for the holder before the verb
        bytes4 vSel;
        uint256 vFee;
        uint256 draws; // the market's draw counter: an extension bumps it once
    }

    /// @dev One holder's extension, at a seeded second inside the loan's term with its record healed.
    /// @dev The holder is funded the view's fee exactly, so the pull is what the in-place check measures.
    /// @dev A pick out of reach is neither warped to nor healed: its refusal reads no record, and a closed loan may keep a future expiry.
    /// @return landed Whether the verb extended the loan.
    function _extendOne(uint256 loanId, uint256 whenSeed) internal returns (bool landed) {
        uint256 mi = _marketIndexOf(loanId);
        if (_reachable(loanId)) {
            _warpIntoTerm(loanId, whenSeed);
            _healRecord(records[mi]);
        }
        address holder = ace.borrowerOf(loanId);
        extendTries++;
        ExtendPre memory s = _extendView(loanId, mi, holder);
        _fundQuote(holder, mi, s.vFee);
        s.hubQuote = MockERC20(_quoteAt(mi)).balanceOf(address(ace));
        vm.prank(holder);
        try ace.extend(loanId, 0, "") returns (uint256 fee) {
            landed = true;
            extendsLanded++;
            _viewVsExtended(s.vOk, s.vSel, s.vFee, loanId, fee, 0);
            _checkExtendInPlace(loanId, mi, s, fee);
        } catch (bytes memory err) {
            _viewVsRefusedExtension(s.vOk, s.vSel, loanId, _revertSelector(err), 0);
        }
    }

    /// @dev The pre-state, and `caller`'s view of the extension now, which runs the loan's own tenor again from now.
    function _extendView(uint256 loanId, uint256 mi, address caller) internal view returns (ExtendPre memory s) {
        Loan memory l = read.loan(loanId);
        s.tenor = l.tenor;
        (s.vOk, s.vSel, s.vFee) = ace.tryExtend(loanId, 0, "", caller);
        (s.loans, s.expiry, s.debt, s.resting) = (read.loanCount(), l.expiry, l.debt, read.restingOf(mids[mi]));
        s.draws = read.marketState(mids[mi]).drawCount;
    }

    /// @dev A landed extension kept the loan in place: no loan minted, the term re-anchored at now on its own tenor, the debt unmoved.
    /// @dev No cash rested or drawn, the fee reached the hub whole, and it bumped the market's draw counter once, the lender contract's change detector.
    function _checkExtendInPlace(uint256 loanId, uint256 mi, ExtendPre memory s, uint256 fee) internal {
        if (extendInPlaceCode != 0) return;
        Loan memory l = read.loan(loanId);
        uint8 code;
        if (read.loanCount() != s.loans) code = 1;
        else if (l.openTime != _later() || l.tenor != s.tenor || l.expiry != _later() + s.tenor) code = 2;
        else if (l.debt != s.debt) code = 3;
        else if (read.restingOf(mids[mi]) != s.resting) code = 4;
        else if (MockERC20(_quoteAt(mi)).balanceOf(address(ace)) != s.hubQuote + fee) code = 5;
        else if (read.marketState(mids[mi]).drawCount != s.draws + 1) code = 6;
        if (code != 0) (extendInPlaceCode, extendInPlaceLoanId) = (code, loanId);
    }

    /// @dev The extension went through: the view must have admitted it, at the fee the verb charged.
    function _viewVsExtended(bool vOk, bytes4 vSel, uint256 vFee, uint256 loanId, uint256 fee, uint8 mode) internal {
        if (!vOk) {
            if (extendCode == 0) (extendCode, extendCodeLoanId, extendViewSelector) = (1, loanId, vSel);
            return;
        }
        extendBothAdmit++;
        modeBothAdmit[mode]++;
        if (vFee != fee && extendCode == 0) {
            (extendCode, extendCodeLoanId) = (3, loanId);
            (extendViewFee, extendVerbFee) = (vFee, fee);
        }
    }

    /// @dev The extension was refused: the view must have refused too, with the SAME selector.
    function _viewVsRefusedExtension(bool vOk, bytes4 vSel, uint256 loanId, bytes4 got, uint8 mode) internal {
        if (vOk) {
            if (extendCode == 0) (extendCode, extendCodeLoanId, extendVerbSelector) = (2, loanId, got);
            return;
        }
        extendBothRefuse++;
        modeBothRefuse[mode]++;
        if (vSel != got && extendCode == 0) {
            (extendCode, extendCodeLoanId) = (4, loanId);
            (extendViewSelector, extendVerbSelector) = (vSel, got);
        }
    }

    /// @dev Collateral that puts `principal`'s trigger at `1/div` of the market's price: a draw every gate admits.
    function _unitsFor(uint256 mi, uint256 principal, uint256 div) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(mids[mi]);
        return FullMath.mulDiv(p.minCoverageWad * principal, unitScales[mi] * div, p.price * 1e18) + 1;
    }

    /// @notice An honest maker's all-or-nothing resting order, sized across the market's cash, so posted escrow is part of the books.
    function postOrder(uint256 marketSeed, uint256 sizeSeed) external {
        _bump("postOrder");
        uint256 mi = _pickMarket(marketSeed);
        _entitle(mi);
        MarketParams memory p = ace.idToMarketParams(mids[mi]);
        uint256 cash = read.restingOf(mids[mi]);
        uint256 principal = bound(sizeSeed, p.minPrincipal, cash > p.minPrincipal ? cash : p.minPrincipal);
        uint256 units = 3 * _unitsFor(mi, principal, 2);
        MockStakeVault(_collAt(mi)).mint(maker, units);
        vm.startPrank(maker);
        MockStakeVault(_collAt(mi)).approve(address(positionManager), units);
        try ace.postOrder(mids[mi], principal, p.price / 2, p.price / 2, principal, p.minTenor, 0) returns (uint256 oid) {
            _orderIds.push(oid);
        } catch {}
        vm.stopPrank();
        _tail();
    }

    // ---- fill + settlement actions ----

    /// @notice Permissionless buying OUT of ladder inventory: the path that re-cashes a tick.
    /// @dev REPLACES the `sellFill` driver, deleted 2026-08-13 with the ladder's bid side.
    /// @dev Inventory now arrives only by settlement, which the loan drivers already reach.
    /// @dev So LR-9 reconciles real state rather than 0 == 0.
    function buyInventory(uint256 quoteSeed) external {
        _bump("buyInventory");
        _armAskHold();
        uint256[] memory m = _preFloors();
        _buyInventory(bound(quoteSeed, 1e6, 50_000e6));
        _postFloors(m, "buyInventory"); // a trade is never a claim -> no floor may move
        _tail();
    }

    /// @dev Self-arm the ask the way `forceClose` warps to expiry: settled inventory RESTS before it opens.
    /// @dev Every fill is try/catch-guarded, so an unarmed leg would revert into the catch and go unexercised.
    /// @dev That failure is silent by construction -- the verb tally still rises while the ask drains nothing.
    /// @dev The window is bounded by an hour, so the campaign clock gains far less than the `warp` action does.
    function _armAskHold() internal {
        uint256 opens;
        for (uint256 j; j < _loanIds.length; j++) {
            uint256 t = read.inventoryAskOpensAt(_loanIds[j]);
            if (t > opens) opens = t;
        }
        _warpAtLeastTo(opens);
    }

    /// @dev It walks EVERY tracked loan and entitles each market as it goes; a blanket entitlement is an exemption.
    /// @dev The buyer funds in the LOAN'S OWN quote: usdc against a dai ask buys nothing and reads as empty inventory.
    /// @dev Each landed buy is checked against its SELLER, the market's lender: a sale pays nobody and credits exactly the fill.
    function _buyInventory(uint256 quoteIn) internal {
        for (uint256 j; j < _loanIds.length; j++) {
            uint256 mi = _marketIndexOf(_loanIds[j]);
            _entitle(mi);
            MockERC20 t = MockERC20(_quoteAt(mi));
            t.mint(address(this), quoteIn); // a buyer funds its own leg
            t.approve(address(ace), quoteIn);
            address seller = ace.idToMarketParams(ace.loanMarket(_loanIds[j])).lender;
            (uint256 balHad, uint256 owedHad) = (t.balanceOf(seller), ace.lenderOwed(seller, address(t)));
            try ace.buyInventory(_loanIds[j], quoteIn, 0, trader) returns (uint256 out, uint256 filled) {
                buyInventoryUnits += out;
                _checkSalePaysNobody(_loanIds[j], t, seller, balHad, owedHad, filled);
                quoteIn -= filled;
                if (quoteIn == 0) break;
            } catch {}
        }
        if (!everInventory && _sumInventory() > 0) everInventory = true;
    }

    /// @dev The sale latch: the seller's wallet is flat across the buy and its pool rose by exactly the fill.
    /// @dev First violation only, like every other latch here; a filled buy counts toward the ghost's non-vacuity.
    function _checkSalePaysNobody(uint256 loanId, MockERC20 t, address seller, uint256 balHad, uint256 owedHad, uint256 filled) internal {
        if (filled > 0) saleFillsChecked++;
        if (salePaidSomeone) return;
        if (t.balanceOf(seller) == balHad && ace.lenderOwed(seller, address(t)) == owedHad + filled) return;
        (salePaidSomeone, salePaidLoanId) = (true, loanId);
    }

    /// @dev THE ARMED ROTATION IS DELETED with the subsystem it drove.
    /// @dev It was `rotateUnderConcurrentExits` plus `_pickLanding`, `_armAndRoll` and `_flaggedClaimOf`.
    /// @dev All four existed to reach `recashAndBackfill`, which no caller can reach any more.
    /// @dev `refinance` above is its successor as the armed, non-lottery continuation action.

    /// @dev Seeds inventory pre-snapshot the ONLY way it now arrives: a loan that matures unpaid.
    /// @dev `sellFill` used to mint it directly; with the bid side gone, settlement is the door.
    /// @dev `forceClose` at expiry always settles, so the loan it opens is the inventory it seeds.
    function _baselineInventory(address who, uint256 principal) internal {
        _open(who, principal);
        uint256 loanId = _loanIds[_loanIds.length - 1];
        uint256 nBefore = read.loanCount();
        _warpBy(ProtocolPolicy.MAX_TENOR + 1);
        try ace.forceClose(loanId) {} catch {} // no forceCloseSettles++: that tally must prove the FUZZER settled one
        require(read.loan(loanId).closedAt != 0 && read.loanCount() == nBefore, "BASELINE: the ctor forceClose at expiry did not settle");
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId)); // the ctor buy is a stranger's ask, and it rests first
        if (!everInventory && _sumInventory() > 0) everInventory = true;
    }

    function _selectorOf(bytes memory ret) internal pure returns (bytes4 sel) {
        if (ret.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(ret, 0x20))
        }
    }

    /// @notice Arm distress: park the record's band just under a live loan's trigger.
    /// @dev The band is arithmetic, so distress dissolves the moment a repay lowers the trigger under it: the derived-pending property.
    function crashBelow(uint256 loanSeed) external {
        _bump("crashBelow");
        if (_loanIds.length == 0) return;
        uint256 loanId = _pickLoan(loanSeed);
        uint256 trig = read.triggerPrice(loanId);
        if (trig == 0) return;
        /// @dev The LOAN'S OWN record: arming market 0's prices a market the distress never reaches, so nothing arms.
        MockPersistenceRecord r = records[_marketIndexOf(loanId)];
        r.setBelowBand(trig); // mock-only: reaches no hub storage, so no floor probe
        r.setAbove(false);
        if (read.settleable(loanId)) distressArmed++; // the record now answers what finalize will ask it
        _tail();
    }

    /// @notice The recovery print: no verb, no fee -- settleable simply goes false again.
    /// @dev EVERY driven market: `crashBelow` arms whichever one its loan sits in, so a market-0 heal strands three.
    function heal() external {
        _bump("heal");
        for (uint256 i; i < 4; i++) {
            records[i].setBelowBand(0); // mock-only: reaches no hub storage, so no floor probe
            records[i].setBelow(false);
            records[i].setAbove(true);
        }
        _tail();
    }

    function finalize(uint256 loanSeed) external {
        _bump("finalize");
        if (_loanIds.length == 0) return;
        uint256 loanId = _pickLoan(loanSeed);
        bool promised = lens.settleable(loanId); // the lens calls this the ONLY finalize precondition
        vm.prank(keeper);
        try ace.finalize(loanId) {
            settlements++;
            settlementsFinalized++;
            _checkSettleable(loanId, promised, bytes4(0));
        } catch (bytes memory err) {
            _checkSettleable(loanId, promised, _revertSelector(err));
        }
        _tail();
    }

    /// @dev The refusal is CAUGHT, not swallowed: a settlement regression must not read as a seed that missed expiry.
    /// @dev `owed` is measured AFTER the warp, so it is the state the hub itself will judge and not the pre-warp one.
    /// @dev It picks a LIVE loan: a closed pick is not owed, so it checked nothing, and once the tracked list filled with closed
    /// @dev loans that was most picks. Measured at depth 256, it is what left whole runs without a single expiry settle.
    function forceClose(uint256 loanSeed) external {
        _bump("forceClose");
        if (_loanIds.length == 0) return;
        uint256 loanId = _pickLiveLoan(loanSeed);
        uint64 exp = read.loan(loanId).expiry;
        if (exp != 0 && _now() < exp) _warpTo(uint256(exp) + 1);
        bool owed = exp != 0 && _now() >= exp && read.loan(loanId).closedAt == 0;
        if (owed) forceCloseOwed++;
        if (_forceCloseOne(loanId) && owed) forceCloseHonoured++;
        _tail();
    }

    /// @dev One keeper `forceClose`, which always settles: a return that leaves the loan live latches code 3.
    /// @dev The settle mints nothing, so the loan's own `closedAt` is the discriminator, never the loan count.
    /// @return landed Whether the call returned and closed the loan.
    function _forceCloseOne(uint256 loanId) internal returns (bool landed) {
        Loan memory l = read.loan(loanId);
        vm.prank(keeper);
        try ace.forceClose(loanId) {
            if (read.loan(loanId).closedAt != 0) {
                landed = true;
                settlements++;
                forceCloseSettles++;
            } else if (forceCloseCode == 0) {
                (forceCloseCode, forceCloseLoanId, forceCloseSelector) = (3, loanId, bytes4(0));
            }
        } catch (bytes memory err) {
            _checkForceClose(loanId, l.closedAt == 0 && _now() >= l.expiry, _revertSelector(err));
        }
    }

    function warp(uint256 dtSeed) external {
        _bump("warp");
        uint256[] memory m = _preFloors();
        _warpBy(bound(dtSeed, 1 minutes, 45 days));
        _postFloors(m, "warp");
        _tail();
    }

    // ---- protocol-revenue actions ----

    function sweepRevenue(uint256 marketSeed) external {
        _bump("sweepRevenue");
        uint256 mi = _pickMarket(marketSeed);
        _entitle(mi);
        uint256[] memory m = _preFloors();
        vm.prank(keeper);
        try ace.sweepRevenue(mids[mi]) {
            landedInMarket[mi]++;
        } catch {}
        _postFloors(m, "sweepRevenue");
        _tail();
    }

    // ---- genesis, mid-sequence ----

    /// @notice Creates a market MID-SEQUENCE, while the driven four are live and mid-flight.
    /// @notice Every other market here is built in the constructor, so no sequence has ever held a genesis.
    /// @dev Entitles NOTHING: genesis writes one fresh id, so any incumbent book that moves is a crossing.
    /// @dev Params are always ADMISSIBLE, so `genesisCreated == genesisAttempted` is a PROPERTY, not a witness.
    /// @dev A rail refusal is `MarketInit`'s unit question, not a sequence one: do not build one here.
    /// @dev The dials vary inside rails the driven markets already prove, so a stranger is never a copy.
    /// @dev Its own record forks the id, exactly as the canary's does.
    function createMarket(uint256 seed) external {
        _bump("createMarket");
        address q = seed % 2 == 0 ? address(usdc) : address(dai);
        address c = (seed >> 8) % 2 == 0 ? address(vault) : address(vault2);
        MarketParams memory p = AceFixtures.marketParams(q, c);
        p.record = address(new MockPersistenceRecord(q, c));
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.minPrincipal = bound(seed >> 16, p.minPrincipal, p.minPrincipal * 50);
        p.settleBountyBps = bound(seed >> 48, 0, p.settleBountyBps);
        p.inventoryAsk = (seed >> 80) % 2 == 0; // either setting is a genesis the fuzzer may land mid-sequence; the baseline names no fill fee
        genesisAttempted++;
        try ace.createMarket(p) returns (bytes32 sid) {
            genesisCreated++;
            _noteStranger(sid, p);
        } catch {}
        _tail();
    }

    /// @dev The id IS `keccak256(abi.encode(p))` and `init` stores `p` verbatim, so both round-trips are exact.
    /// @dev A colliding id would put two markets in one storage slot, which is the catastrophic form.
    /// @dev A broken params round-trip is the quiet one: `idToMarketParams` is what an integrator verifies against.
    function _noteStranger(bytes32 sid, MarketParams memory p) internal {
        for (uint256 i; i < 6; i++) {
            if (this.allMarketAt(i) == sid) genesisCollided = true;
        }
        for (uint256 i; i < _strangers.length; i++) {
            if (_strangers[i] == sid) genesisCollided = true;
        }
        if (keccak256(abi.encode(p)) != sid) genesisIdNotItsParams = true;
        if (keccak256(abi.encode(ace.idToMarketParams(sid))) != sid) genesisIdNotItsParams = true;
        _strangers.push(sid);
    }
}
