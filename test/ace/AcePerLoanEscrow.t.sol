// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice Mint hook on the quote token; the executor mints its fill rather than being pre-funded.
interface IQuoteMintable {
    function mint(address to, uint256 amount) external;
}

/// @title PartialFillKeeper
/// @notice Deterministic route that keeps only fillBps of the units and hands the tail back, the shape `_recreditRefund` exists to handle.
/// @dev Local to this file rather than `MockDeleverageKeeper` because the tests set a SHARE, not a unit count.
/// @dev They never see the sized units, so bps is the only knob expressible here.
contract PartialFillKeeper is IAceDeleverageCallback {
    Ace public immutable ACE;
    /// @notice The collateral this keeper routes.
    IERC20 public immutable COLLATERAL;
    /// @notice The quote token minted as the proceeds.
    address public immutable STABLE;

    /// @notice Share of the released units actually routed; the remainder goes back to the hub.
    uint256 public fillBps = 10000;

    constructor(Ace ace, IERC20 collateral, address stable) {
        ACE = ace;
        COLLATERAL = collateral;
        STABLE = stable;
    }

    /// @notice Sets the filled share in bps; below 10000 refuses a tail and triggers the re-credit.
    function setFillBps(uint256 bps) external {
        fillBps = bps;
    }

    function crank(uint256 loanId) external returns (uint256, uint256) {
        return ACE.deleverage(loanId, 0, "");
    }

    /// @dev Approves the FULL-SIZE floor; the hub pulls the pro-rata share of what actually filled.
    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata) external {
        uint256 refund = unitsSold - (unitsSold * fillBps) / 10000;
        if (refund > 0) COLLATERAL.transfer(msg.sender, refund);
        IQuoteMintable(STABLE).mint(address(this), quoteOwed);
        IERC20(STABLE).approve(address(ACE), quoteOwed);
    }
}

/// @notice Custody is ONE pot per collateral on the custodian, split between loans by the ledger alone.
/// @dev The invariants this file pins, restated for the pooled shape:
/// @dev I-A: the sum of `collateralOf + retiredOf` over every loan on a token is at most the pot.
/// @dev I-A tightens to EQUALITY against `custodiedOf`, which is the runtime rail enforcing it.
/// @dev I-B': the HUB routes and never custodies, so its balance is not a protocol quantity.
/// @dev I-B' is a routing claim, never an equality: anyone may donate to the hub and nothing sweeps it.
/// @dev I-C: the ledgers move only through the custodian's verbs, so a donation credits nobody.
contract AcePerLoanEscrowTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc; // quote, 6dec
    MockStakeVault internal stakeColl; // collateral, 18dec
    PartialFillKeeper internal executor;
    MockPersistenceRecord internal record;
    bytes32 internal id_;

    address internal alice = address(0xA11CE); // lender
    address internal borrowerA = address(0xB0BA);
    address internal borrowerB = address(0xB0BB);
    address internal keeper = address(0xCAFE);
    address internal stranger = address(0x57A6);
    address internal donor = address(0xD0405);

    uint256 constant COLL_A = 10_000e18;
    uint256 constant COLL_B = 4_000e18;
    uint256 constant PRINCIPAL_A = 4_500e6;
    uint256 constant PRINCIPAL_B = 1_500e6;
    uint256 constant FEE_FLOAT = 100e6;
    uint256 constant DONATION = 777e18;
    uint256 constant BAND_BPS = 3000; // the market's decline band, mirrored for the crank's arming

    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3;
    uint256 internal T4;
    uint256 internal CAP; // the healthy draw cap in the hub's frame, above every seeded tick; assigned in setUp

    /// @notice Every field of loan B that loan A's operations must leave bit-identical.
    /// @dev Pooled, the LEDGER is the whole of a loan's custody, so it is the whole of the snapshot.
    struct LoanSnapshot {
        uint256 collateralOf;
        uint256 retiredOf;
        address holder; // hub title (ace.borrowerOf); the positionManager's local ownerOf mirror is deleted
    }

    /// @notice Loans this suite has opened, so the I-A sum can be taken over all of them.
    uint256[] internal opened;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(stakeColl), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stakeColl = new MockStakeVault(42);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        CAP = AceFixtures.px(2e18, address(usdc), address(stakeColl));
        record = new MockPersistenceRecord(address(usdc), address(stakeColl));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(stakeColl)));
        // finite and above every seeded tick so the draw still funds top-down; the mock defaults to type(uint256).max, which the floor cannot use
        record.setMinPrice(CAP);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(stakeColl));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS; // the one crank that hands units to a routing keeper
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id_) = (d.ace, d.positionManager, d.read, d.id);
        /// @dev built after the hub: the keeper CALLS the hub, so it cannot exist before the hub does
        executor = new PartialFillKeeper(ace, IERC20(address(stakeColl)), address(usdc));

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id_, 5_000e6);
        ace.deposit(id_, 5_000e6);
        ace.deposit(id_, 5_000e6);
        vm.stopPrank();

        vm.label(address(ace), "Ace");
        vm.label(address(positionManager), "PositionManager");
        vm.label(address(executor), "Executor");
    }

    // ---- helpers ----

    function _open(address who, uint256 units, uint256 principal) internal returns (uint256 id) {
        stakeColl.mint(who, units);
        usdc.mint(who, FEE_FLOAT);
        vm.startPrank(who);
        stakeColl.approve(address(positionManager), units);
        usdc.approve(address(ace), FEE_FLOAT);
        id = ace.open(id_, units, principal, 0, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
        opened.push(id);
    }

    function _openA() internal returns (uint256 id) {
        return _open(borrowerA, COLL_A, PRINCIPAL_A);
    }

    function _openB() internal returns (uint256 id) {
        return _open(borrowerB, COLL_B, PRINCIPAL_B);
    }

    /// @dev Put the record in this loan's band at 5% over its trigger, which is also the disposal floor.
    function _enterBand(uint256 loanId) internal {
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = trig + trig / 20;
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(ps);
    }

    /// @dev Undo the arming. Band mode OVERRIDES the `below` flag in the mock, and the low windowed min
    /// @dev caps every later draw, so a test doing anything after a crank has to hand the record back.
    function _healRecord() internal {
        record.setBelowBand(0);
        record.setMinPrice(CAP);
    }

    /// @dev The clean close CREDITS the collateral rather than pushing it; the pull is the exit's second half.
    function _repayInFull(address who, uint256 id) internal {
        uint256 debt = read.loan(id).debt;
        usdc.mint(who, debt);
        vm.startPrank(who);
        usdc.approve(address(ace), debt);
        ace.repay(id, debt);
        ace.claimOwed(id, who);
        vm.stopPrank();
    }

    function _snapshot(uint256 id) internal view returns (LoanSnapshot memory s) {
        s.collateralOf = positionManager.collateralOf(id);
        s.retiredOf = positionManager.retiredOf(id);
        s.holder = ace.borrowerOf(id);
    }

    function _assertBitIdentical(LoanSnapshot memory before, uint256 id, string memory tag) internal view {
        LoanSnapshot memory current = _snapshot(id);
        assertEq(current.collateralOf, before.collateralOf, string.concat(tag, ": live ledger moved"));
        assertEq(current.retiredOf, before.retiredOf, string.concat(tag, ": retired ledger moved"));
        assertEq(current.holder, before.holder, string.concat(tag, ": title moved"));
    }

    /// @dev I-B': the HUB routes and never custodies, so nothing it holds is ever at rest.
    /// @dev Asserted as zero rather than as a delta because no test here donates to the hub.
    function _assertHubHoldsNothing(string memory tag) internal view {
        assertEq(stakeColl.balanceOf(address(ace)), 0, string.concat(tag, ": I-B' -- the hub is holding collateral"));
    }

    /// @dev I-A over every loan this suite opened, in both of its forms.
    /// @dev The `<=` leg is the invariant proper, which a donation into the pot only widens.
    /// @dev The equality leg is the runtime rail: `custodiedOf` counts exactly what the ledgers claim.
    function _assertPooledCustodySolvent(string memory tag) internal view {
        uint256 claimed;
        for (uint256 i; i < opened.length; i++) {
            claimed += positionManager.collateralOf(opened[i]) + positionManager.retiredOf(opened[i]);
        }
        uint256 pot = stakeColl.balanceOf(address(positionManager));
        assertLe(claimed, pot, string.concat(tag, ": I-A -- the ledgers claim more than the pot holds"));
        assertEq(claimed, positionManager.custodiedOf(address(stakeColl)), string.concat(tag, ": custodiedOf desynced"));
        assertLe(positionManager.custodiedOf(address(stakeColl)), pot, string.concat(tag, ": the rail is under water"));
    }

    /// @dev A loan's own two ledgers, which nothing but that loan's own verbs may move.
    function _loanCustody(uint256 id) internal view returns (uint256) {
        return positionManager.collateralOf(id) + positionManager.retiredOf(id);
    }

    // ---- per-loan isolation: A's operations leave B bit-identical on the shared pot ----

    /// @notice Two loans share one pot and are told apart by the ledger, which credits each exactly.
    /// @dev What the two-address form used to say structurally, the ledger now has to say on its own.
    function test_isolation_TwoLoansAreSeparatedByTheLedgerAlone() public {
        uint256 idA = _openA();
        uint256 idB = _openB();

        assertEq(stakeColl.balanceOf(address(positionManager)), COLL_A + COLL_B, "one pot carries both");
        assertEq(positionManager.collateralOf(idA), COLL_A, "A's ledger carries exactly A's units");
        assertEq(positionManager.collateralOf(idB), COLL_B, "B's ledger carries exactly B's units");
        _assertHubHoldsNothing("two open loans");
        _assertPooledCustodySolvent("two open loans");
    }

    /// @notice Loan A's full life -- deleverage, partial fill, repay-to-close -- leaves B's ledger alone.
    /// @dev Pooled, this is the isolation claim: A's exits debit A's key and no other loan's.
    /// @dev The old form could lean on two addresses; there is one address now, so the ledger carries it.
    function test_isolation_LoanALifecycleLeavesLoanBBitIdentical() public {
        uint256 idA = _openA();
        uint256 idB = _openB();
        LoanSnapshot memory b0 = _snapshot(idB);

        _enterBand(idA);
        vm.prank(keeper);
        executor.crank(idA);
        _assertBitIdentical(b0, idB, "after A's full-fill crank");

        _enterBand(idA);
        executor.setFillBps(5000);
        vm.prank(keeper);
        executor.crank(idA);
        _assertBitIdentical(b0, idB, "after A's partial-fill crank");

        _repayInFull(borrowerA, idA);
        _assertBitIdentical(b0, idB, "after A closes clean");
        assertGe(stakeColl.balanceOf(address(positionManager)), COLL_B, "and B's units are still in the pot");
        _assertPooledCustodySolvent("B after A's whole life");
    }

    /// @notice Settling loan A does not reach loan B's credit either, though both sit in one pot.
    /// @notice The settlement path releases three ways, and every leg must debit A's key.
    function test_isolation_SettlingLoanALeavesLoanBBitIdentical() public {
        uint256 idA = _openA();
        uint256 idB = _openB();
        LoanSnapshot memory b0 = _snapshot(idB);

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(idA);

        _assertBitIdentical(b0, idB, "after A is finalized");
        assertEq(positionManager.collateralOf(idA), 0, "A's LIVE ledger is fully drained by settlement");
        assertEq(_loanCustody(idA), COLL_A, "and its units moved to A's RETIRED ledger, not out of the pot");
        _assertPooledCustodySolvent("after A is finalized");
        _assertHubHoldsNothing("after A is finalized");
    }

    // ---- I-B': the hub routes and never custodies ----

    /// @notice I-B' after open: the hub holds no collateral, one open or two.
    /// @dev The pot leg says where the units DID go, so a regression cannot pass by losing them.
    function test_openRoutesToTheCustodian_AndTheHubHoldsNothing() public {
        _openA();
        _assertHubHoldsNothing("after open");
        _openB();
        _assertHubHoldsNothing("after a second open");
        assertEq(stakeColl.balanceOf(address(positionManager)), COLL_A + COLL_B, "both opens landed in the pot");
        _assertPooledCustodySolvent("after two opens");
    }

    /// @notice I-B' after a full-fill deleverage: the hub is a pass-through and holds nothing when it returns.
    /// @dev The crank routes hub -> Loans -> executor, so the hub is genuinely a waypoint here.
    function test_crankRoutesThroughTheHub_AndLeavesNothingOnIt() public {
        uint256 id = _openA();
        _enterBand(id);
        vm.prank(keeper);
        executor.crank(id);
        _assertHubHoldsNothing("after a crank");
        _assertPooledCustodySolvent("after a crank");
    }

    /// @notice I-B' after a partial-fill refund: the unsold tail re-enters custody, it does not rest on the hub.
    /// @dev The refund is the one place a naive implementation leaves the tail sitting on the hub.
    function test_partialFillRefundReturnsToTheCustodian_NotTheHub() public {
        uint256 id = _openA();
        _enterBand(id);
        executor.setFillBps(6000);
        vm.prank(keeper);
        executor.crank(id);
        _assertHubHoldsNothing("after partial-fill refund");
        _assertPooledCustodySolvent("after partial-fill refund");
    }

    /// @notice I-B' after finalize, with a live loan alongside so an emptied pot cannot fake it.
    /// @dev Settlement moves units between two LEDGER keys, so the pot must not move at all.
    function test_finalizeMovesLedgerOnly_AndTheHubHoldsNothing() public {
        uint256 idA = _openA();
        uint256 idB = _openB();
        uint256 potBefore = stakeColl.balanceOf(address(positionManager));
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(idA);
        _assertHubHoldsNothing("after finalize with a live loan alongside");
        assertEq(stakeColl.balanceOf(address(positionManager)), potBefore, "a settlement moves no token at all");
        assertEq(positionManager.collateralOf(idA), 0, "only the settled loan's units left the LIVE ledger");
        assertEq(positionManager.collateralOf(idB), COLL_B, "the live loan's ledger is untouched");
        _assertPooledCustodySolvent("after finalize");
    }

    /// @notice I-B' after a clean close, again with a live loan alongside.
    /// @dev The close plus its claim really does take units OUT, so the pot must fall by exactly A's.
    function test_closeCleanTakesOnlyItsOwnUnitsOutOfThePot() public {
        uint256 idA = _openA();
        uint256 idB = _openB();
        uint256 potBefore = stakeColl.balanceOf(address(positionManager));
        _repayInFull(borrowerA, idA);
        _assertHubHoldsNothing("after closeClean with a live loan alongside");
        assertEq(potBefore - stakeColl.balanceOf(address(positionManager)), COLL_A, "exactly A's units left the pot");
        assertEq(positionManager.collateralOf(idA), 0, "only the closed loan's units left the ledger");
        assertEq(positionManager.collateralOf(idB), COLL_B, "the live loan's ledger is untouched");
        _assertPooledCustodySolvent("after closeClean");
    }

    // ---- I-C: the ledger is the only crediting path, so a donation credits nobody ----

    /// @notice A donation into the pot before any loan opens credits no loan and no aggregate.
    /// @dev The custodian's address is public, so pre-loading it is the one thing an attacker can do.
    /// @dev Crediting it would let a donor inflate a loan's ledger before that loan exists.
    function test_donation_ToTheEmptyPot_CreditsNothing() public {
        uint256 nextId = read.loanCount() + 1;

        stakeColl.mint(donor, DONATION);
        vm.prank(donor);
        stakeColl.transfer(address(positionManager), DONATION);

        assertEq(stakeColl.balanceOf(address(positionManager)), DONATION, "the donation sits in the pot");
        assertEq(positionManager.collateralOf(nextId), 0, "a donation credits no loan ledger");
        assertEq(positionManager.custodiedOf(address(stakeColl)), 0, "nor the pot-level aggregate");
        assertEq(positionManager.uncreditedSurplus(address(stakeColl)), DONATION, "it is surplus, and only surplus");
        assertEq(ace.borrowerOf(nextId), address(0), "and claims no title holder");
    }

    /// @notice Opening on top of a pre-loaded pot credits the MEASURED pull only, and never the donation.
    /// @notice The donation survives the whole loan and stays stranded after the close.
    function test_donation_SurvivesTheLoanAndStaysStranded() public {
        stakeColl.mint(donor, DONATION);
        vm.prank(donor);
        stakeColl.transfer(address(positionManager), DONATION);

        uint256 id = _openA();
        assertEq(positionManager.collateralOf(id), COLL_A, "ledger credits the pull only, never the donation");
        assertEq(positionManager.custodiedOf(address(stakeColl)), COLL_A, "and the aggregate agrees with it");
        assertEq(stakeColl.balanceOf(address(positionManager)), COLL_A + DONATION, "while the pot carries both");
        _assertPooledCustodySolvent("open over a donated pot");

        _repayInFull(borrowerA, id);
        assertEq(stakeColl.balanceOf(borrowerA), COLL_A, "the borrower gets back exactly what they escrowed");
        assertEq(stakeColl.balanceOf(address(positionManager)), DONATION, "the donation is stranded, not paid out");
        assertEq(positionManager.uncreditedSurplus(address(stakeColl)), DONATION, "and is surplus for ever after");
        _assertHubHoldsNothing("after a close over a donated pot");
    }

    // ---- every exit debits the correct loan's ledger ONLY ----

    /// @notice closeClean pays out of the pot against the closing loan's ledger and nobody else's.
    function test_closeClean_DebitsTheCorrectLedgerOnly() public {
        uint256 idA = _openA();
        uint256 idB = _openB();
        uint256 potBefore = stakeColl.balanceOf(address(positionManager));
        LoanSnapshot memory b0 = _snapshot(idB);

        _repayInFull(borrowerA, idA);

        assertEq(potBefore - stakeColl.balanceOf(address(positionManager)), COLL_A, "exactly A's units left the pot");
        assertEq(stakeColl.balanceOf(borrowerA), COLL_A, "and the borrower received exactly A's units");
        assertEq(_loanCustody(idA), 0, "A's ledgers are cleared");
        _assertBitIdentical(b0, idB, "closeClean on A");
        _assertHubHoldsNothing("closeClean");
        _assertPooledCustodySolvent("closeClean");
    }

    /// @notice The _recreditRefund round trip -- release, partial fill, pull the unsold tail back.
    /// @dev The tail re-enters through `pull`, whose MEASURED delta must credit A's key and no other.
    /// @dev A mis-keyed refund pull would fund the wrong loan's ledger out of a pot it shares.
    function test_recreditRefund_RoundTripsIntoTheCorrectLedgerOnly() public {
        uint256 idA = _openA();
        uint256 idB = _openB();
        uint256 potBefore = stakeColl.balanceOf(address(positionManager));
        LoanSnapshot memory b0 = _snapshot(idB);

        _enterBand(idA);
        executor.setFillBps(6000); // 40% of the sized units come straight back

        vm.prank(keeper);
        (uint256 unitsSold,) = executor.crank(idA);

        assertGt(unitsSold, 0, "a partial fill still sells something");
        assertEq(potBefore - stakeColl.balanceOf(address(positionManager)), unitsSold, "only the FILLED units left");
        assertEq(positionManager.collateralOf(idA), COLL_A - unitsSold, "ledger tracks the net debit");
        _assertBitIdentical(b0, idB, "refund round trip on A");
        _assertHubHoldsNothing("refund round trip");
        _assertPooledCustodySolvent("after the refund round trip");
    }

    /// @notice The three-way _settle split -- keeper sliver, lender leg, borrower residual -- in one pot.
    /// @dev Every leg must debit the settling loan's RETIRED ledger and no other loan's credit.
    function test_settle_ThreeWaySplit_DebitsTheCorrectLedgerOnly() public {
        uint256 idA = _openA();
        uint256 idB = _openB();
        LoanSnapshot memory b0 = _snapshot(idB);

        uint256 keeperPre = stakeColl.balanceOf(keeper);
        uint256 borrowerPre = stakeColl.balanceOf(borrowerA);

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(idA);

        /// @dev The three legs are LEDGER writes now, so the split is read off the ledgers first
        (uint256 owedKeeper,) = ace.owedOf(idA, keeper);
        (uint256 owedBorrower,) = ace.owedOf(idA, borrowerA);
        uint256 toMarket = positionManager.retiredOf(idA) - owedKeeper - owedBorrower;

        vm.prank(keeper);
        ace.claimOwed(idA, keeper);
        vm.prank(borrowerA);
        ace.claimOwed(idA, borrowerA);

        uint256 toKeeper = stakeColl.balanceOf(keeper) - keeperPre;
        uint256 toBorrower = stakeColl.balanceOf(borrowerA) - borrowerPre;

        assertEq(toKeeper, owedKeeper, "the sliver pays the crank in full on the pull");
        assertEq(toBorrower, owedBorrower, "and the residual pays the title holder in full");
        assertGt(toKeeper, 0, "the in-kind sliver must be paid");
        assertGt(toBorrower, 0, "the residual leg must be paid too");
        assertGt(toMarket, 0, "the lender leg must be filled");
        assertEq(toKeeper + toMarket + toBorrower, COLL_A, "all three legs sum to A's units, no more, no less");
        assertEq(positionManager.retiredOf(idA), toMarket, "A's retired ledger holds exactly the undelivered leg");
        assertEq(positionManager.collateralOf(idA), 0, "A's live ledger cleared");
        _assertBitIdentical(b0, idB, "three-way settle on A");
        _assertHubHoldsNothing("three-way settle");
        _assertPooledCustodySolvent("three-way settle");
    }

    /// @notice The same three-way split through the must-execute backstop.
    /// @dev Asserted by BALANCE DELTAS, since the display mirror and its burn events are deleted.
    function test_forceClose_ThreeWaySplit_SumsToUnits() public {
        uint256 id = _openA();
        uint256 keeperPre = stakeColl.balanceOf(keeper);
        uint256 borrowerPre = stakeColl.balanceOf(borrowerA);

        _warpBy(30 days + 1);
        vm.prank(keeper);
        ace.forceClose(id);

        uint256 retired = positionManager.retiredOf(id);
        vm.prank(keeper);
        ace.claimOwed(id, keeper);
        vm.prank(borrowerA);
        ace.claimOwed(id, borrowerA);

        uint256 pulled = (stakeColl.balanceOf(keeper) - keeperPre) + (stakeColl.balanceOf(borrowerA) - borrowerPre);
        assertEq(retired, COLL_A, "sliver, market portion and residual sum to the loan's units");
        assertEq(pulled + positionManager.retiredOf(id), COLL_A, "and the two pulls plus the market's leg still sum to it");
        assertEq(stakeColl.balanceOf(address(positionManager)), positionManager.retiredOf(id), "the pot holds exactly the market's leg");
        assertEq(positionManager.collateralOf(id), 0, "the live ledger is cleared");
        _assertPooledCustodySolvent("forceClose three-way split");
    }

    /// @notice Interleaved multi-loan traffic holds the pooled custody identity at every step.
    /// @dev I-A is now a SUM over every open loan, which is the form pooling makes the honest one.
    /// @dev A per-loan equality would be unfalsifiable here: one address holds every loan's units.
    function test_Invariant_PooledCustody_InterleavedSequence() public {
        uint256 idA = _open(borrowerA, COLL_A, PRINCIPAL_A);
        uint256 idB = _open(borrowerB, COLL_B, PRINCIPAL_B);
        _assertPooledCustodySolvent("after opens");

        _enterBand(idA);
        vm.prank(keeper);
        (uint256 sold,) = executor.crank(idA);
        _healRecord();
        assertGt(sold, 0, "the crank sold units");
        _assertPooledCustodySolvent("after A's crank");
        assertEq(positionManager.collateralOf(idB), COLL_B, "B's ledger is untouched by A's crank");
        assertEq(ace.borrowerOf(idA), borrowerA, "title untouched by the crank");

        usdc.mint(borrowerB, 1_000e6);
        vm.startPrank(borrowerB);
        usdc.approve(address(ace), 1_000e6);
        ace.repay(idB, 1_000e6);
        vm.stopPrank();
        _assertPooledCustodySolvent("after B's partial repay");

        uint256 idC = _open(borrowerA, COLL_A / 4, 1_000e6);
        _assertPooledCustodySolvent("after C opens mid-stream");

        _repayInFull(borrowerA, idA);
        assertEq(_loanCustody(idA), 0, "A cleared, both ledgers");
        _assertPooledCustodySolvent("after A's full repay");

        _warpBy(90 days + 1);
        vm.prank(keeper);
        ace.forceClose(idB);
        vm.prank(keeper);
        ace.forceClose(idC);
        /// @dev A settled loan is credited exactly what nobody has claimed yet; the sum still binds
        assertEq(positionManager.collateralOf(idB), 0, "B's live ledger cleared by settlement");
        assertEq(positionManager.collateralOf(idC), 0, "C's live ledger cleared by settlement");
        _assertPooledCustodySolvent("after everything closed");
        _assertHubHoldsNothing("after everything closed");
    }

    // ---- the custody verbs answer to the hub and to nobody else ----

    /// @notice A stranger cannot move the ledger. The custodian's only gate is `onlyLoanManager`.
    /// @dev Under clones a wrong caller was refused by a self-verifying CREATE2 check on the vault.
    /// @dev Pooled there is no derivation left to verify, so this ONE modifier carries all of it.
    function testRevert_onlyLoanManager_RejectsAStranger() public {
        uint256 id = _openA();

        vm.prank(stranger);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.release(id, stranger, COLL_A);
    }

    /// @notice The borrower is refused too: title on the hub is not authority over the pot.
    /// @notice While the loan is live the only exit is a LOAN_MANAGER-driven release.
    function testRevert_onlyLoanManager_RejectsTheBorrower() public {
        uint256 id = _openA();

        vm.prank(borrowerA);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.release(id, borrowerA, COLL_A);

        assertEq(positionManager.collateralOf(id), COLL_A, "the ledger did not move");
    }

    /// @notice Every ledger-moving verb carries the gate, not just `release`.
    /// @dev One unguarded verb would hand the whole shared pot to the first caller who found it.
    function testRevert_onlyLoanManager_GuardsEveryVerb() public {
        uint256 idA = _openA();
        uint256 idB = _openB();

        vm.startPrank(stranger);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.pull(idA, stranger, 1);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.retireCustody(idA, 1);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.releaseRetired(idA, stranger, 1);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.carryOut(idA, 1);
        vm.expectRevert(PositionManager.NotLoanManager.selector);
        positionManager.carryIn(idA, idB, 1);
        vm.stopPrank();

        _assertPooledCustodySolvent("after five refused verbs");
    }
}
