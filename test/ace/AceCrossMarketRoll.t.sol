// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceCrossMarketRoll
/// @notice An armed continuation may name a DESTINATION market, after the incumbent's time-gated first refusal.
/// @notice The keeper supplying `dst` is the destination's lender, paid by an origination fee already charged.
/// @dev WRITTEN FAILING-FIRST: `refinanceByPolicyTo`, `tryContinueTo` and `AutoPolicy.maxFeeBps` do not exist yet.
/// @dev The borrower pre-commits on three axes -- TERM, RISK DISTANCE, COST -- and a keeper chooses only inside them.
/// @dev Reasoning: the design record.
contract AceCrossMarketRollTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    bytes32 internal home; // the loan's own market, baseBps 40
    bytes32 internal rival; // a cheaper competitor, baseBps 30, downside identical

    address internal alice = address(0xA11CE); // the home lender
    address internal rivalLender = address(0xF1A5C0); // the competing curator
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 400_000e18;
    uint256 internal constant TOP = 1_000_000e6;
    uint16 internal constant BUF = 500; // 5% risk-distance pre-commit
    uint16 internal constant FEE_CAP = 200; // 2% realized-rate ceiling; nonzero ALSO opts into routing

    uint256 internal T;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = AceFixtures.priceAt(address(usdc), address(vault), 0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(40, address(0), alice)); // the HOME market is alice own
        (ace, pm, read, home) = (d.ace, d.positionManager, d.read, d.id);
        rival = ace.createMarket(_params(30, address(0)));

        _deposit(home, alice, TOP);
        _deposit(rival, rivalLender, TOP);
        usdc.mint(borrower, 5_000_000e6);
    }

    // ---- fixture ----

    /// @dev Every market here shares the record and the six pinned downside dials; only PRICE differs.
    /// @dev EVERY MARKET NAMES ITS ONE LENDER, and the default is the RIVAL keeper: the home market is
    /// @dev alice's and every other market this suite stands up is the destination the keeper supplies.
    function _params(uint256 baseBps, address borrower_) internal view returns (MarketParams memory p) {
        return _params(baseBps, borrower_, rivalLender);
    }

    function _params(uint256 baseBps, address borrower_, address lender_) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = baseBps;
        p.borrower = borrower_;
        p.lender = lender_;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
    }

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(bytes32 mid) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Arm with the three-axis pre-commit. A nonzero fee cap IS the cross-market opt-in.
    function _arm(uint256 loanId, uint16 feeCap) internal {
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, BUF, feeCap);
    }

    /// @dev The window is derived from the SOURCE market's minTenor, per autoRefinanceWindow's own NatSpec.
    function _window() internal pure returns (uint64) {
        return MarketInit.autoRefinanceWindow(TEN7);
    }

    /// @dev Land inside the home-exclusive prefix: the roll is open, but only to the loan's own market.
    function _warpIntoHomeExclusive(uint256 loanId) internal {
        _warpTo(uint256(read.loan(loanId).expiry) - uint256(_window()));
    }

    /// @dev Land after the prefix: any compatible destination is legal, settlement still impossible.
    function _warpIntoOpenWindow(uint256 loanId) internal {
        _warpTo(uint256(read.loan(loanId).expiry) - uint256(_window()) / 2);
    }

    /* ================================================================= */
    /*  the happy path                                                   */
    /* ================================================================= */

    /// @notice A cheaper rival wins the roll once the incumbent's first-refusal window has passed.
    /// @dev The successor lives in the rival market: that is the whole feature in one assertion.
    function test_Roll_IntoCheaperRival_AfterTheHomeWindow() public {
        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoOpenWindow(loanId);

        vm.prank(rivalLender);
        uint256 newId = ace.refinanceByPolicyTo(loanId, rival);

        assertEq(read.loan(newId).market, rival, "the successor sits in the destination market");
        assertEq(read.debtOf(loanId), 0, "the old loan was retired, not settled");
        assertGt(read.debtOf(newId), 0, "the successor carries the debt");
    }

    /* ================================================================= */
    /*  the time gate -- the incumbent's first refusal                   */
    /* ================================================================= */

    /// @notice Inside the prefix a foreign destination is REFUSED; the home market keeps first refusal.
    /// @dev This is the whole of the user's "same market first" ruling, expressed as a clock rather than a fallback.
    function test_HomeExclusive_ForeignDestinationRefusedInsideThePrefix() public {
        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoHomeExclusive(loanId);

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, rival);
        assertFalse(ok, "a stranger may not route inside the incumbent's window");
        assertEq(reason, bytes4(keccak256("HomeRollExclusive()")), "refused by name");
    }

    /// @notice The HOME market rolls throughout the prefix -- the gate bounds the destination, never the roll.
    function test_HomeExclusive_TheHomeMarketStillRollsInsideThePrefix() public {
        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoHomeExclusive(loanId);

        vm.prank(alice);
        uint256 newId = ace.refinanceByPolicyTo(loanId, home);
        assertEq(read.loan(newId).market, home, "the incumbent's own roll is never gated");
    }

    /// @notice Settlement is impossible for the WHOLE window, so the incumbent's hour buys time, not an outcome.
    /// @dev Pins the property that makes the halved routing window safe rather than merely smaller.
    function test_HomeExclusive_SettlementIsImpossibleForTheWholeWindow() public {
        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoHomeExclusive(loanId);

        vm.prank(keeper);
        vm.expectRevert(); // NotExpired -- Settlement.sol guards both doors pre-expiry
        ace.forceClose(loanId);
    }

    /// @notice A PERMANENT incompatibility reports itself as such even inside the prefix, never as timing.
    /// @dev `HomeRollExclusive` means "come back later", so a keeper may retry on it. A destination that can
    /// @dev never take this loan must not answer that way, or the retry never terminates. Hence the clock runs LAST.
    function test_LegOrder_PermanentRefusalBeatsTheClock() public {
        MockPersistenceRecord other = new MockPersistenceRecord(address(usdc), address(vault));
        MarketParams memory p = _params(30, address(0));
        p.record = address(other); // can NEVER take this loan, at any hour
        bytes32 foreign = ace.createMarket(p);
        _deposit(foreign, rivalLender, TOP);

        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoHomeExclusive(loanId); // the clock WOULD refuse here, and must not be what answers

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, foreign);
        assertFalse(ok, "guard: still refused");
        assertEq(reason, bytes4(keccak256("RecordMismatch()")), "the permanent reason, not the timing one");
    }

    /// @notice An unknown destination is a REFUSAL, not a revert: the predicate is total and keepers batch on it.
    /// @dev `_cache` would throw `NoMarket`, killing a multicall of simulations over candidate destinations --
    /// @dev which is the exact workflow a routed roll exists to enable.
    function test_Totality_UnknownDestinationRefusesRatherThanReverting() public {
        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoOpenWindow(loanId);

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, keccak256("no such market"));
        assertFalse(ok, "an unknown market cannot take the loan");
        assertEq(reason, bytes4(keccak256("NoMarket()")), "and it says so as a selector a keeper can skip");
    }

    /// @notice Disarming is always available, whatever stale ceiling rides along in the call.
    /// @dev The routing rail sits INSIDE the `tenor != 0` branch: a zero tenor disarms outright, so a
    /// @dev ceiling beside it bounds nothing and must not block the borrower's own exit from the policy.
    function test_Arming_DisarmIsNeverBlockedByAStaleCeiling() public {
        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, FEE_CAP); // tenor zero disarms; the ceiling is vestigial
        (uint64 tenor,,) = read.autoPolicyOf(loanId);
        assertEq(tenor, 0, "disarmed");
    }

    /* ================================================================= */
    /*  the borrower's pre-commit                                        */
    /* ================================================================= */

    /// @notice `maxFeeBps == 0` means HOME ONLY, forever: the field carries the cross-market opt-in.
    /// @dev The overload is honest because a same-market fee cap is a no-op -- `originationFee` reads no state.
    function test_Disarmed_ZeroFeeCapRefusesEveryForeignDestination() public {
        uint256 loanId = _open(home);
        _arm(loanId, 0);
        _warpIntoOpenWindow(loanId);

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, rival);
        assertFalse(ok, "no fee cap means no consent to a keeper-named venue");
        assertEq(reason, bytes4(keccak256("CrossMarketDisarmed()")), "refused by name");
    }

    /// @notice Consenting to a keeper-named venue while naming NO risk distance is refused AT ARMING.
    /// @notice The whole basis for a keeper choosing `dst` is that the borrower pre-committed; a zero buffer is not one.
    /// @dev `_admissibleLeg` SKIPS the buffer check entirely at zero, so the floor and coverage protection
    /// @dev the cross-market case leans on simply is not there -- only `trig <= floor`, which is birth-liquidation
    /// @dev and not a margin. Refused where the borrower is present to see it, as the tenor legs already are.
    function test_Arming_RoutingConsentWithoutARiskDistanceIsRefused() public {
        uint256 loanId = _open(home);
        vm.prank(borrower);
        vm.expectRevert(bytes4(keccak256("RoutingNeedsBuffer()")));
        ace.setAutoRefinance(loanId, TEN7, 0, FEE_CAP);
    }

    /// @notice Both halves of the pair stay legal on their own: zero-and-zero is today's armed loan, unchanged.
    /// @dev The rail is on the COMBINATION, so it must not narrow the same-market policy anyone already uses.
    function test_Arming_ZeroBufferIsStillLegalWhenHomeOnly() public {
        uint256 loanId = _open(home);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0); // home-only: no venue consent, so no buffer is owed
        (,, uint16 cap) = read.autoPolicyOf(loanId);
        assertEq(cap, 0, "armed home-only, exactly as before this change");
    }

    /// @notice A destination dearer than the borrower's ceiling is refused, however admissible it otherwise is.
    /// @dev The cap is on the REALIZED rate, so it bounds the fee curve rather than any one dial.
    function test_FeeCap_DearerDestinationRefused() public {
        bytes32 dear = ace.createMarket(_params(400, address(0))); // 10x the home rate
        _deposit(dear, rivalLender, TOP);

        uint256 loanId = _open(home);
        _arm(loanId, 50); // 0.5% ceiling; the dear market cannot clear it
        _warpIntoOpenWindow(loanId);

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, dear);
        assertFalse(ok, "the borrower's cost pre-commit binds the keeper's choice");
        assertEq(reason, bytes4(keccak256("FeeAboveMax()")), "refused by name");
    }

    /* ================================================================= */
    /*  the downside equality rail                                       */
    /* ================================================================= */

    /// @notice A destination whose debt FLOOR exceeds the source's is refused: it would inflate the notional.
    /// @notice `derivedPrincipal` floors the successor at the DESTINATION's `minDebt`, and a keeper picks the destination.
    /// @dev `maxFeeBps` bounds the RATE and nothing bounded the NOTIONAL: an attacker copying the rail and
    /// @dev naming a huge `minDebt` had the borrower re-open owing multiples, paying origination on all of it
    /// @dev to the attacker's own ticks. Only a HIGHER floor can raise debt, so the rule is directional.
    function test_Rail_HigherDestinationMinDebtRefused() public {
        MarketParams memory p = _params(30, address(0));
        p.minDebt = 500_000e6; // far above this loan's live debt
        bytes32 fat = ace.createMarket(p);
        _deposit(fat, rivalLender, TOP);

        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoOpenWindow(loanId);

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, fat);
        assertFalse(ok, "a keeper may not raise the debt floor the successor is sized against");
        assertEq(reason, bytes4(keccak256("MinDebtRaised()")), "refused by name");
    }

    /// @notice A LOWER destination floor is fine: the floor only ever raises a principal, never lowers one.
    /// @dev The rail is directional on purpose -- equality here would refuse a harmless destination and narrow routing.
    function test_Rail_LowerDestinationMinDebtAdmitted() public {
        MarketParams memory p = _params(30, address(0));
        p.minDebt = 1e6; // a tenth of the fixture floor
        bytes32 thin = ace.createMarket(p);
        _deposit(thin, rivalLender, TOP);

        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoOpenWindow(loanId);

        (bool ok,,) = ace.tryContinueTo(loanId, thin);
        assertTrue(ok, "a smaller ticket cannot inflate anything");
    }

    /// @notice A fee ceiling must NEVER refuse the borrower's own market -- at expiry the fold settles on a refusal.
    /// @notice The realized rate carries the protocol share on top, so `baseBps` 40 bills 44: the obvious number under-sets.
    /// @dev A borrower naming their own market's advertised dial would otherwise refuse every roll and be
    /// @dev settled at expiry rather than rolled. The ceiling exists to bound a venue THEY DID NOT CHOOSE.
    function test_FeeCap_DoesNotBindTheHomeRoll() public {
        uint256 loanId = _open(home);
        _arm(loanId, 1); // 1 bps, far under the ~44 bps this market actually bills
        _warpIntoHomeExclusive(loanId);

        (bool ok,,) = ace.tryContinueTo(loanId, home);
        assertTrue(ok, "the home roll is not bounded by a ceiling written for foreign venues");
    }

    /// @notice A destination on a different price source is refused: a keeper may re-price, never re-anchor.
    function test_Rail_RecordMismatchRefused() public {
        MockPersistenceRecord other = new MockPersistenceRecord(address(usdc), address(vault));
        MarketParams memory p = _params(30, address(0));
        p.record = address(other);
        bytes32 foreign = ace.createMarket(p);
        _deposit(foreign, rivalLender, TOP);

        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoOpenWindow(loanId);

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, foreign);
        assertFalse(ok, "an absent borrower is never moved onto a different price source");
        assertEq(reason, bytes4(keccak256("RecordMismatch()")), "refused by name");
    }

    /// @notice One pinned downside dial differing is enough to refuse: the loss endpoint is invariant across a roll chain.
    function test_Rail_SettleBountyMismatchRefused() public {
        MarketParams memory p = _params(30, address(0));
        p.settleBountyBps = 100; // the borrower's loss endpoint would move
        bytes32 foreign = ace.createMarket(p);
        _deposit(foreign, rivalLender, TOP);

        uint256 loanId = _open(home);
        _arm(loanId, FEE_CAP);
        _warpIntoOpenWindow(loanId);

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, foreign);
        assertFalse(ok, "a keeper may change the PRICE, never the DOWNSIDE");
        assertEq(reason, bytes4(keccak256("TermsMismatch()")), "refused by name");
    }

    /// @notice A loan from an OPEN market may not be routed into one that names a borrower: it never consented.
    /// @dev The lending-review mitigation for lock-in -- an unchosen party must not acquire the roll veto.
    function test_Rail_OpenSourceRefusesNamedDestination() public {
        MarketParams memory p = _params(30, address(0xB0BB1)); // names somebody, whoever they are
        bytes32 named = ace.createMarket(p);
        _deposit(named, rivalLender, TOP);

        uint256 loanId = _open(home); // home names nobody
        _arm(loanId, FEE_CAP);
        _warpIntoOpenWindow(loanId);

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, named);
        assertFalse(ok, "a loan from an open market cannot be routed behind a named borrower it never accepted");
        assertEq(reason, bytes4(keccak256("TermsMismatch()")), "refused by name");
    }

    /* ===================================================================== */
    /*  the latent defect: admission must be read off the DESTINATION       */
    /* ===================================================================== */

    /// @notice The continuation reads the DESTINATION's named borrower, never the source's.
    /// @notice THE MUTATION IT CATCHES: `_gateAdmits` reading `r.cs.p.borrower` instead of `r.cd.p.borrower`.
    /// @dev Invisible while source == destination; cross-market it would judge the roll by the wrong market.
    /// @dev BOTH LEGS RUN OFF ONE SOURCE, so the only variable is which market's field the hub consulted.
    /// @dev Leg 1's destination names the same borrower and must ADMIT; leg 2's names another and must REFUSE.
    /// @dev A hub reading the SOURCE would admit both, since the source names this borrower throughout.
    function test_Admission_ReadOffTheDestinationNotTheSource() public {
        bytes32 namedHome = ace.createMarket(_params(40, borrower, alice)); // the borrower's own home, alice's to lend
        bytes32 sameBorrower = ace.createMarket(_params(30, borrower));
        bytes32 otherBorrower = ace.createMarket(_params(20, address(0xB0BB1)));
        _deposit(namedHome, alice, TOP);
        _deposit(sameBorrower, rivalLender, TOP);
        _deposit(otherBorrower, rivalLender, TOP);

        uint256 loanId = _open(namedHome);
        _arm(loanId, FEE_CAP);
        _warpIntoOpenWindow(loanId);

        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, sameBorrower);
        assertTrue(ok, "a destination naming this borrower admits the roll");
        assertEq(reason, bytes4(0), "and no leg refused");

        (bool stillOk, bytes4 why,) = ace.tryContinueTo(loanId, otherBorrower);
        assertFalse(stillOk, "a destination naming ANOTHER borrower must refuse, though the source names this one");
        assertEq(why, bytes4(keccak256("GateRefused()")), "refused by the admission leg, not by another");
    }
}
