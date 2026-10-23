// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {NoClaimLeg, Settlement} from "../../src/ace/hub/Settlement.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockBlacklistERC20} from "../mocks/MockBlacklistERC20.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The per-leg door alone: `abi.encodeCall(Ace.claimOwed, ...)` is ambiguous once the name is overloaded.
/// @dev Typed rather than `encodeWithSignature`, so a re-signature breaks the BUILD instead of an assertion.
interface IClaimOwedPerLeg {
    function claimOwed(uint256 loanId, address toUnits, address toQuote) external returns (uint256, uint256);
}

/// @title AceClaimOwedAssetCoupling
/// @notice `claimOwed` is the ONE door to both credit ledgers, and it pays both legs or neither.
/// @notice A clean close credits the borrower BOTH: the whole position in kind, and the unearned fee escrow in quote.
/// @dev So a quote that refuses to move holds a borrower's entire collateral behind a few dollars of refund.
/// @dev The pull-credit rebuild removed every fixed DESTINATION; the asset coupling is what it left.
contract AceClaimOwedAssetCouplingTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockBlockableERC20 internal usdc; // the QUOTE, pausable the way a real stablecoin is
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal carol = address(0xCA401); // a third party, so a destination test is not the claimant's own address
    address internal keeper = address(0xCAFE); // the settle crank's caller, whose sliver is a UNITS-ONLY credit

    uint256 internal constant LADDER = 400_000e6;
    uint256 internal constant DRAW = 40_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal T; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    bytes4 internal constant TRANSFER = 0xa9059cbb; // ERC20 transfer(address,uint256), matched on the selector alone

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockBlockableERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        T = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(coll));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, LADDER);
        vm.startPrank(alice);
        usdc.approve(address(ace), LADDER);
        ace.deposit(id, LADDER);
        vm.stopPrank();
    }

    /// @dev Opens, then repays in full well inside the term, so `closeClean` credits BOTH legs to the borrower.
    function _closedCleanWithBothCredits() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, DRAW, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        usdc.mint(borrower, DRAW); // top up what the origination fee took
        vm.startPrank(borrower);
        usdc.approve(address(ace), DRAW * 2);
        ace.repay(loanId, type(uint256).max);
        vm.stopPrank();

        (uint256 u, uint256 q) = ace.owedOf(loanId, borrower);
        assertEq(u, COLL, "fixture: the whole position is credited in kind");
        assertGt(q, 0, "fixture: and the unearned fee escrow is credited in quote, on the SAME loan");
    }

    /// @notice CONTROL: unpaused, the one door delivers both legs, so the row below is the pause talking.
    function test_Control_Unpaused_TheOneDoorDeliversBothLegs() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (, uint256 q) = ace.owedOf(loanId, borrower);

        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);

        assertEq(coll.balanceOf(borrower), COLL, "the collateral came back");
        assertEq(usdc.balanceOf(borrower) > 0 && q > 0, true, "and so did the refund");
    }

    /// @dev A settled loan: `_settle` credits the borrower a residual in KIND and no quote at all.
    function _settledWithUnitsOnly() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, DRAW, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        vm.warp(uint256(read.loan(loanId).expiry) + 1);
        vm.prank(address(0xCAFE));
        ace.forceClose(loanId);

        (uint256 u, uint256 q) = ace.owedOf(loanId, borrower);
        assertGt(u, 0, "fixture: the settlement residual is credited in kind");
        assertEq(q, 0, "fixture: and settlement credits the borrower no quote at all");
    }

    /// @notice CONTROL: the SETTLED borrower, whose credit is units-only, claims fine under the same pause.
    /// @notice So the pause does not block `releaseRetired`; only the coupled quote leg does.
    function test_Control_PausedQuote_AUnitsOnlyCreditStillClaims() public {
        uint256 loanId = _settledWithUnitsOnly();
        (uint256 u,) = ace.owedOf(loanId, borrower);
        usdc.setPaused(true);

        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);
        assertEq(coll.balanceOf(borrower), u, "the settlement residual came back under the pause");
    }

    /// @notice THE REPRO: a borrower who repaid in full cannot retrieve their COLLATERAL under a paused quote.
    /// @dev Nothing about the collateral is affected by the quote's pause; the coupling is the whole cause.
    function test_PausedQuote_HoldsTheWholeCollateralPosition() public {
        uint256 loanId = _closedCleanWithBothCredits();
        usdc.setPaused(true);

        vm.prank(borrower);
        vm.expectRevert(bytes("paused"));
        ace.claimOwed(loanId, borrower);
        assertEq(coll.balanceOf(borrower), 0, "and the collateral is held behind a few dollars of refund");
    }

    /// @notice THE FIX: naming a destination for the units leg alone releases it while the quote leg waits.
    function test_PausedQuote_TheUnitsLegIsClaimableAlone() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (, uint256 q) = ace.owedOf(loanId, borrower);
        usdc.setPaused(true);

        vm.prank(borrower);
        _claimPerLeg(loanId, borrower, address(0));

        assertEq(coll.balanceOf(borrower), COLL, "the collateral came back under the pause");
        (uint256 uLeft, uint256 qLeft) = ace.owedOf(loanId, borrower);
        assertEq(uLeft, 0, "the units credit is spent");
        assertEq(qLeft, q, "and the SKIPPED quote credit is untouched, not forfeited");
    }

    /// @notice A skipped leg stays claimable: the borrower comes back for the quote once the pause lifts.
    function test_SkippedLeg_IsStillClaimableAfterwards() public {
        uint256 loanId = _closedCleanWithBothCredits();
        usdc.setPaused(true);
        vm.prank(borrower);
        _claimPerLeg(loanId, borrower, address(0));

        usdc.setPaused(false);
        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);

        assertGt(usdc.balanceOf(borrower), 0, "the deferred refund arrives later, in full");
        (uint256 uLeft, uint256 qLeft) = ace.owedOf(loanId, borrower);
        assertEq(uLeft + qLeft, 0, "and both ledgers are now clear");
    }

    /// @notice Both destinations zero claims nothing, which is a caller bug rather than a legal no-op.
    /// @dev Refused BY NAME, so an integrator passing two uninitialized addresses gets a selector, not a silent success.
    function test_BothDestinationsZero_Refuses() public {
        uint256 loanId = _closedCleanWithBothCredits();

        vm.prank(borrower);
        vm.expectRevert(NoClaimLeg.selector);
        IClaimOwedPerLeg(address(ace)).claimOwed(loanId, address(0), address(0));
    }

    /// @notice The 2-arg door still pays both legs to one address, so the overload changed nothing for existing callers.
    function test_TwoArgDoor_StillPaysBothLegs() public {
        uint256 loanId = _closedCleanWithBothCredits();

        vm.prank(borrower);
        (uint256 u, uint256 q) = ace.claimOwed(loanId, borrower);

        assertEq(u, COLL, "the units leg paid");
        assertGt(q, 0, "and so did the quote leg");
        assertEq(coll.balanceOf(borrower), COLL, "to the one destination it was given");
    }

    /* ====== the UNITS skip: the direction the pause repro cannot reach ====== */

    /// @notice The mirror of the quote skip, and the dangerous direction: a skipped UNITS leg keeps its credit.
    /// @dev `releaseRetired` is irreversible and the ledger entry is the only record that the units are owed.
    /// @dev So a skip that zeroed here would be a silent, permanent forfeiture of the whole position.
    function test_SkippedUnitsLeg_KeepsTheCollateralCredit() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (uint256 u0, uint256 q0) = ace.owedOf(loanId, borrower);
        uint256 retired = positionManager.retiredOf(loanId);
        uint256 held = coll.balanceOf(address(positionManager));

        vm.prank(borrower);
        _claimPerLeg(loanId, address(0), borrower);

        assertEq(coll.balanceOf(borrower), 0, "no collateral moved on a skipped units leg");
        assertEq(positionManager.retiredOf(loanId), retired, "the retired pot still owes the whole position");
        assertEq(coll.balanceOf(address(positionManager)), held, "and custody still holds it");
        (uint256 uLeft, uint256 qLeft) = ace.owedOf(loanId, borrower);
        assertEq(uLeft, u0, "the SKIPPED units credit is untouched, not forfeited");
        assertEq(u0, COLL, "non-vacuity: there really was a whole position on that leg");
        assertEq(qLeft, 0, "while the quote leg it named was paid in full");
        assertGt(q0, 0, "non-vacuity: and the quote leg was not empty either");
    }

    /// @notice The deferred units arrive later, in full and to the wei -- measured as a DELTA, not as non-zero.
    function test_SkippedUnitsLeg_IsStillClaimableAfterwards() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (uint256 u0,) = ace.owedOf(loanId, borrower);
        vm.prank(borrower);
        _claimPerLeg(loanId, address(0), borrower);

        uint256 before = coll.balanceOf(carol);
        vm.prank(borrower);
        _claimPerLeg(loanId, carol, address(0));

        assertEq(coll.balanceOf(carol) - before, u0, "the deferred units arrive later, in full");
        (uint256 uLeft, uint256 qLeft) = ace.owedOf(loanId, borrower);
        assertEq(uLeft + qLeft, 0, "and both ledgers are now clear");
    }

    /// @notice The deferred QUOTE arrives later in full, measured as a DELTA against a balance the draw left non-zero.
    /// @dev The sibling row asserts only that the balance is positive, which the drawn principal already makes true.
    function test_SkippedQuoteLeg_PaysTheExactDeferredAmountLater() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (, uint256 q0) = ace.owedOf(loanId, borrower);
        usdc.setPaused(true);
        vm.prank(borrower);
        _claimPerLeg(loanId, borrower, address(0));

        usdc.setPaused(false);
        uint256 before = usdc.balanceOf(carol);
        vm.prank(borrower);
        _claimPerLeg(loanId, address(0), carol);

        assertGt(q0, 0, "non-vacuity: there was a refund to defer");
        assertEq(usdc.balanceOf(carol) - before, q0, "the deferred refund arrives later, to the wei");
    }

    /* ====== the safety property: a skipped leg makes NO external call ====== */

    /// @notice What makes a skip safe under a hostile token: the leg is not attempted, so nothing can revert in it.
    /// @dev Asserted as a call COUNT of zero, so it holds for a cooperative token too, where a failure would be silent.
    function test_SkippedUnitsLeg_MakesNoCustodyCall() public {
        uint256 loanId = _closedCleanWithBothCredits();

        vm.expectCall(address(positionManager), abi.encodeWithSelector(IPositionManager.releaseRetired.selector), 0);
        vm.prank(borrower);
        _claimPerLeg(loanId, address(0), borrower);
    }

    /// @notice The same property on the quote side, stated directly rather than inferred from a pause reverting.
    function test_SkippedQuoteLeg_MakesNoQuoteTransfer() public {
        uint256 loanId = _closedCleanWithBothCredits();

        vm.expectCall(address(usdc), abi.encodeWithSelector(TRANSFER), 0);
        vm.prank(borrower);
        _claimPerLeg(loanId, borrower, address(0));
    }

    /* ====== the market aggregate and the hub's cash across a skip ====== */

    /// @notice A skipped quote leg leaves the market aggregate AND the hub's cash exactly where they were.
    /// @dev The pair is the point: an aggregate that fell without a transfer is quote written off nobody claimed.
    function test_SkippedQuoteLeg_LeavesTheAggregateAndTheHubsCashIntact() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (, uint256 q0) = ace.owedOf(loanId, borrower);
        uint256 owedTotal = read.quoteOwedTotal(id);
        uint256 cash = usdc.balanceOf(address(ace));
        assertGe(owedTotal, q0, "non-vacuity: the aggregate carries this credit");

        vm.prank(borrower);
        _claimPerLeg(loanId, borrower, address(0));

        assertEq(read.quoteOwedTotal(id), owedTotal, "the aggregate did not move on a skip");
        assertEq(usdc.balanceOf(address(ace)), cash, "and neither did the hub's cash");

        vm.prank(borrower);
        _claimPerLeg(loanId, address(0), borrower);

        assertEq(read.quoteOwedTotal(id), owedTotal - q0, "the later pull moves the aggregate by exactly the credit");
        assertEq(usdc.balanceOf(address(ace)), cash - q0, "and the hub's cash by exactly the same figure");
    }

    /* ====== the widened event ====== */

    /// @notice The event names BOTH destinations and BOTH amounts, so an indexer can see where each asset went.
    function test_OwedClaimed_NamesBothDestinationsAndBothAmounts() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (uint256 u0, uint256 q0) = ace.owedOf(loanId, borrower);

        vm.expectEmit(true, true, false, true, address(ace));
        emit Settlement.OwedClaimed(loanId, borrower, carol, alice, u0, q0);
        vm.prank(borrower);
        _claimPerLeg(loanId, carol, alice);
    }

    /// @notice DECLINED and EMPTY are different facts, and the event is where they are told apart.
    /// @dev A zero destination with a live credit is a decline; a named destination with nothing there is an empty pull.
    /// @dev Both report `units == 0`, so only `toUnits` separates them, which is what the event exists to carry.
    function test_OwedClaimed_DistinguishesDeclinedFromEmpty() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (uint256 u0, uint256 q0) = ace.owedOf(loanId, borrower);
        assertGt(u0, 0, "non-vacuity: the declined leg really had a credit behind it");

        vm.expectEmit(true, true, false, true, address(ace));
        emit Settlement.OwedClaimed(loanId, borrower, address(0), carol, 0, q0);
        vm.prank(borrower);
        _claimPerLeg(loanId, address(0), carol); // DECLINED: zero destination, credit still there

        vm.expectEmit(true, true, false, true, address(ace));
        emit Settlement.OwedClaimed(loanId, borrower, carol, carol, u0, 0);
        vm.prank(borrower);
        _claimPerLeg(loanId, carol, carol); // and now the quote leg is EMPTY: named, but nothing to pay
    }

    /* ====== a units-only claimant, which is the keeper's shape ====== */

    /// @notice The settle sliver is credited in UNITS alone, so the keeper's quote leg is empty on either door.
    /// @dev `Settlement._settle` credits `msg.sender` a sliver in kind; the crank never earns quote.
    function test_UnitsOnlyClaimant_ClaimsTheSliverThroughEitherDoor() public {
        uint256 loanId = _settledWithUnitsOnly(); // the fixture's own crank runs from `keeper`, so the sliver is theirs
        (uint256 sliver, uint256 q) = ace.owedOf(loanId, keeper);
        assertGt(sliver, 0, "non-vacuity: the crank earned a sliver");
        assertEq(q, 0, "and it is units-only, as the doctrine says");

        vm.prank(keeper);
        _claimPerLeg(loanId, keeper, address(0));
        assertEq(coll.balanceOf(keeper), sliver, "the per-leg door pays a units-only claimant");
        (uint256 uLeft,) = ace.owedOf(loanId, keeper);
        assertEq(uLeft, 0, "and clears the entry");
    }

    /// @notice A units-only claimant who names the quote leg alone gets a clean no-op, not a revert.
    /// @dev The empty-entry house style survives the overload: an absent credit pays zero and does not refuse.
    function test_UnitsOnlyClaimant_NamingTheEmptyQuoteLegAloneIsANoOp() public {
        uint256 loanId = _settledWithUnitsOnly();
        (uint256 sliver,) = ace.owedOf(loanId, keeper);
        assertGt(sliver, 0, "non-vacuity: the crank earned a sliver");

        vm.prank(keeper);
        _claimPerLeg(loanId, address(0), keeper);

        assertEq(coll.balanceOf(keeper), 0, "the declined units leg moved nothing");
        (uint256 uLeft,) = ace.owedOf(loanId, keeper);
        assertEq(uLeft, sliver, "and the sliver is still owed");
    }

    /* ====== the destination pair, fuzzed ====== */

    /// @notice The conservation law over every destination pair: each leg pays iff it was named, and nothing leaks.
    /// @dev Picks from a fixed set of payable destinations: the hub and the custodian are recipient-rule refusals, not legs that pay.
    /// @dev `pickU == 0` and `pickQ == 0` is the refused pair, and is asserted as a revert rather than skipped.
    function testFuzz_DestinationPair_PaysExactlyTheNamedLegs(uint8 pickU, uint8 pickQ) public {
        address toUnits = _destination(pickU);
        address toQuote = _destination(pickQ);
        uint256 loanId = _closedCleanWithBothCredits();
        (uint256 u0, uint256 q0) = ace.owedOf(loanId, borrower);

        if (toUnits == address(0) && toQuote == address(0)) {
            vm.prank(borrower);
            vm.expectRevert(NoClaimLeg.selector);
            IClaimOwedPerLeg(address(ace)).claimOwed(loanId, toUnits, toQuote);
            return;
        }

        uint256 heldColl = coll.balanceOf(toUnits == address(0) ? carol : toUnits);
        uint256 heldQuote = usdc.balanceOf(toQuote == address(0) ? carol : toQuote);
        uint256 aggregate = read.quoteOwedTotal(id);

        vm.prank(borrower);
        (uint256 u, uint256 q) = IClaimOwedPerLeg(address(ace)).claimOwed(loanId, toUnits, toQuote);

        assertEq(u, toUnits == address(0) ? 0 : u0, "the units leg pays its whole credit iff it was named");
        assertEq(q, toQuote == address(0) ? 0 : q0, "and the quote leg does the same, independently");
        (uint256 uLeft, uint256 qLeft) = ace.owedOf(loanId, borrower);
        assertEq(uLeft + u, u0, "units delivered plus units still credited is what was owed: nothing is lost");
        assertEq(qLeft + q, q0, "and the same conservation holds on the quote ledger");
        assertEq(read.quoteOwedTotal(id), aggregate - q, "the aggregate falls by exactly what moved");
        if (toUnits != address(0)) assertEq(coll.balanceOf(toUnits) - heldColl, u, "the collateral landed where it was sent");
        if (toQuote != address(0)) assertEq(usdc.balanceOf(toQuote) - heldQuote, q, "and so did the quote");
    }

    /// @dev The fuzzer's destination set: zero (decline), the claimant, and two unrelated third parties.
    function _destination(uint8 pick) internal view returns (address) {
        uint8 k = pick % 4;
        if (k == 0) return address(0);
        if (k == 1) return borrower;
        if (k == 2) return carol;
        return alice;
    }

    /// @dev The per-leg door, typed.
    function _claimPerLeg(uint256 loanId, address toUnits, address toQuote) internal {
        IClaimOwedPerLeg(address(ace)).claimOwed(loanId, toUnits, toQuote);
    }
}

/// @title AceClaimOwedDisjointRecipients
/// @notice THE PERMANENT CASE, and the one a pause test cannot reach: two tokens whose allowed
/// @notice recipient sets do not intersect, so NO single destination can ever satisfy both legs.
/// @dev Octane finding 13 scenario 1, rated High: funds blocked with no within-protocol workaround.
/// @dev A pause is symmetric and lifts; disjoint blacklists are neither, so "wait for it" is not an answer.
contract AceClaimOwedDisjointRecipientsTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockBlacklistERC20 internal usdc;
    MockBlacklistERC20 internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal quoteOk = address(0x9001); // accepted by the quote, refused by the collateral
    address internal collOk = address(0x9002); // accepted by the collateral, refused by the quote

    uint256 internal constant LADDER = 400_000e6;
    uint256 internal constant DRAW = 40_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal T; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockBlacklistERC20("USD Coin", "USDC", 6);
        coll = new MockBlacklistERC20("Collateral", "COLL", 18);
        T = AceFixtures.priceAt(address(usdc), address(coll), 0);
        record = new MockPersistenceRecord(address(usdc), address(coll));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, LADDER);
        vm.startPrank(alice);
        usdc.approve(address(ace), LADDER);
        ace.deposit(id, LADDER);
        vm.stopPrank();
    }

    /// @dev The same clean close as the sibling suite: both ledgers credited to one borrower.
    function _closedCleanWithBothCredits() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, DRAW, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        usdc.mint(borrower, DRAW);
        vm.startPrank(borrower);
        usdc.approve(address(ace), DRAW * 2);
        ace.repay(loanId, type(uint256).max);
        vm.stopPrank();

        (uint256 u, uint256 q) = ace.owedOf(loanId, borrower);
        assertEq(u, COLL, "fixture: the whole position is credited in kind");
        assertGt(q, 0, "fixture: and the fee escrow in quote, on the same loan");
    }

    /// @dev Disjoint sets: each destination is refused by exactly the token the other accepts.
    function _makeDisjoint() internal {
        coll.setBlacklisted(quoteOk, true);
        usdc.setBlacklisted(collOk, true);
        usdc.setBlacklisted(borrower, true);
        coll.setBlacklisted(borrower, true);
    }

    /// @notice THE REPRO: with disjoint sets, NO single destination works, and nothing ever lifts.
    function test_DisjointRecipients_NoSingleDestinationCanEverWork() public {
        uint256 loanId = _closedCleanWithBothCredits();
        _makeDisjoint();

        vm.prank(borrower);
        vm.expectRevert(bytes("blacklisted"));
        ace.claimOwed(loanId, quoteOk); // the collateral leg refuses this one

        vm.prank(borrower);
        vm.expectRevert(bytes("blacklisted"));
        ace.claimOwed(loanId, collOk); // and the quote leg refuses the other

        vm.prank(borrower);
        vm.expectRevert(bytes("blacklisted"));
        ace.claimOwed(loanId, borrower); // and the borrower's own address is refused by both
    }

    /// @notice THE FIX: one call, two destinations, each token going somewhere it accepts.
    function test_DisjointRecipients_PerLegDestinationsClearBothInOneCall() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (, uint256 q) = ace.owedOf(loanId, borrower);
        _makeDisjoint();

        vm.prank(borrower);
        IClaimOwedPerLeg(address(ace)).claimOwed(loanId, collOk, quoteOk);

        assertEq(coll.balanceOf(collOk), COLL, "collateral went where the collateral allows");
        assertEq(usdc.balanceOf(quoteOk), q, "and quote went where the quote allows");
        (uint256 uLeft, uint256 qLeft) = ace.owedOf(loanId, borrower);
        assertEq(uLeft + qLeft, 0, "both ledgers clear, with no pause and no waiting");
    }

    /// @notice Localizes the refusal: each destination is refused by ONE named leg and accepted by the other.
    /// @dev The single-destination repro proves only that something reverted, and both legs revert with the same string.
    /// @dev Declining the incompatible leg makes each call SUCCEED, which is what says the refusal sat where claimed.
    function test_DisjointRecipients_EachDestinationIsRefusedByExactlyOneLeg() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (, uint256 q) = ace.owedOf(loanId, borrower);
        _makeDisjoint();

        vm.prank(borrower);
        IClaimOwedPerLeg(address(ace)).claimOwed(loanId, collOk, address(0)); // the units leg alone accepts collOk
        assertEq(coll.balanceOf(collOk), COLL, "collOk was refused by the QUOTE leg, never by the units leg");

        vm.prank(borrower);
        IClaimOwedPerLeg(address(ace)).claimOwed(loanId, address(0), quoteOk); // and the quote leg alone accepts quoteOk
        assertEq(usdc.balanceOf(quoteOk), q, "quoteOk was refused by the UNITS leg, never by the quote leg");
    }

    /// @notice A blacklist arriving between the two pulls cannot strand the leg already taken.
    /// @dev The realistic sequencing: a claimant splits the pull, and the second destination is blacklisted meanwhile.
    function test_DisjointRecipients_ASecondRefusalCannotUndoTheFirstLeg() public {
        uint256 loanId = _closedCleanWithBothCredits();
        (, uint256 q) = ace.owedOf(loanId, borrower);
        _makeDisjoint();

        vm.prank(borrower);
        IClaimOwedPerLeg(address(ace)).claimOwed(loanId, collOk, address(0));
        usdc.setBlacklisted(quoteOk, true); // every remaining destination now refuses the quote

        vm.prank(borrower);
        vm.expectRevert(bytes("blacklisted"));
        IClaimOwedPerLeg(address(ace)).claimOwed(loanId, address(0), quoteOk);

        assertEq(coll.balanceOf(collOk), COLL, "the collateral taken earlier is still out and still theirs");
        (uint256 uLeft, uint256 qLeft) = ace.owedOf(loanId, borrower);
        assertEq(uLeft, 0, "the units ledger stayed clear");
        assertEq(qLeft, q, "and the stranded quote is still credited, waiting for an address that takes it");
    }
}
