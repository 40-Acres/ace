// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, VaultConfig} from "../../src/curator/CuratorVault.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {NotTheLender} from "../../src/ace/hub/Lender.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";

/// @notice A quote token that reads `lenderAssets` from inside every move, so a TORN read can be staged.
/// @dev The hub pulls quote with `transferFrom` inside its own guarded body; that pull is the window.
/// @dev The probe SWALLOWS the revert and records it, because bubbling would only fail the deposit.
/// @dev It reads the HUB, not the lens: the share-pricing guard lives on the contract owning the lock.
/// @dev A SINGULAR id, never an empty batch -- an empty list makes no call and so proves nothing here.
contract TornReadQuote {
    string public constant name = "Torn";
    string public constant symbol = "TORN";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    Ace public ace; // zero disarms the probe entirely
    AceLens public lens; // optional second leg: proves the guard is SCOPED to the hub's pricing read
    bytes32 public marketId;
    address public lender; // the pricing read is keyed by (lender, quote) now, so the probe carries both
    bool public probed; // the hook ran at all, which is what makes a clean result meaningful
    bool public reverted;
    bytes4 public seen;
    bool public lensAnswered; // an UNGUARDED lens view, read in the same window

    function arm(address a, bytes32 id, address who) external {
        ace = Ace(a);
        marketId = id;
        lender = who;
    }

    function armLens(address l) external {
        lens = AceLens(l);
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _move(f, to, a);
        return true;
    }

    /// @notice The same read with no hub body in flight: the control every torn-read claim needs.
    function probeOutside() external {
        _probe();
    }

    function _move(address f, address t, uint256 a) private {
        balanceOf[f] -= a;
        balanceOf[t] += a;
        if (address(ace) != address(0)) _probe();
    }

    /// @dev The UNGUARDED leg WAS `lens.unclaimableStrand(market, loanIds)`, which sized the NAV error a
    /// @dev per-market walk could carry. There are no per-market aggregates to strand, so the view is gone;
    /// @dev what stands in its place is any unguarded lens read of the same market, and `restingOf` is one.
    function _probe() private {
        probed = true;
        try ace.lenderAssets(lender, address(this)) returns (uint256) {
            reverted = false;
            seen = bytes4(0);
        } catch (bytes memory err) {
            reverted = true;
            seen = err.length >= 4 ? bytes4(err) : bytes4(0);
        }
        if (address(lens) == address(0)) return;
        try lens.restingOf(marketId) returns (uint256) {
            lensAnswered = true;
        } catch {
            lensAnswered = false;
        }
    }
}

/// @title CuratorVaultStrangerFirst
/// @notice THE PERMISSIONLESS-VERB RULE: every hub verb whose NatSpec says permissionless is driven here by
/// @notice a STRANGER FIRST, because that is the ordering under which two real bugs already shipped.
/// @notice Also the hub's one guarded READ, `lenderAssets`, which is guarded BECAUSE it prices shares.
/// @dev the design record (the rule) and the rev-3 sole-lender NAV identity.
contract CuratorVaultStrangerFirstTest is CuratorVaultBase {
    uint256 internal constant SEED = 20_000e6;
    uint256 internal constant DRAW = 6_000e6;
    address internal stranger = address(0x57A11);

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function _price(int24 t) internal pure returns (int24[] memory x) {
        x = new int24[](1);
        x[0] = t;
    }

    /// @dev One lot, one drawn class, real quote sitting at it, and NOBODY has cranked.
    function _accrued(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        loanId = _open(DRAW);
        _warpBy(30 days);
        _repay(loanId, DRAW / 2);
    }

    /// @dev The counter and the cash must agree after every path, or the exit is paying from a fiction.
    /// @dev The vault holds its cash, so idle IS its asset balance, and NAV is that plus the hub's pools.
    function _assertCounterHonest(CuratorVault v, string memory where) internal view {
        assertEq(usdc.balanceOf(address(v)), v.idle(), where);
        assertEq(v.grossNav(), _hubTruthNav(v), where);
    }

    // ---- collect: NOT permissionless, and the arbitrary `to` is the lender's own ----

    /// @dev THE SHAPE CHANGE that retired the two rows this replaces. `claimUnits` was permissionless and
    /// @dev took an arbitrary `to`, so both a PUSH (naming the vault as payee) and a DRAIN (naming oneself)
    /// @dev had to be shown inert -- and they were inert only because the stranger held no units to settle.
    /// @dev `collect` IS LENDER-ONLY NOW: its ledger key is `msg.sender`, so a stranger's call spends the
    /// @dev stranger's own pool whatever `to` it names. CONVERTED from `test_Stranger_MayCollectForTheVaultAndMovesNothingDoingIt`,
    /// @dev whose permissionless collect-for-the-vault is removed; the vault's own `crank` is how its pool comes home.
    /// @dev The crank leg below pins that the vault's own collect moves its pool into its own balance, and NAV with it nowhere.
    function test_Stranger_CannotCollectTheVaultsPool_AndMovesNothingTrying() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _accrued(v);
        _repay(loanId, DRAW / 4);

        uint256 owed = lens.claimable(address(v), v.asset());
        assertGt(owed, 0, "LIVENESS: there is a live accrual for a stranger to try to move");
        uint256 grossBefore = v.grossNav();
        uint256 idleBefore = v.idle();

        vm.prank(stranger);
        assertEq(ace.collect(v.asset(), stranger), 0, "the drain shape: the stranger's collect spends only their own, empty, pool");

        vm.prank(stranger);
        assertEq(ace.collect(v.asset(), address(v)), 0, "and the push shape: naming the vault as `to` still spends the stranger's pool");

        assertEq(usdc.balanceOf(stranger), 0, "the stranger was paid nothing at all");
        assertEq(v.idle(), idleBefore, "not a wei reached the vault");
        assertEq(v.grossNav(), grossBefore, "and the aggregate did not move either");
        assertEq(lens.claimable(address(v), v.asset()), owed, "and the vault's whole claim is still there for its own crank");
        _assertCounterHonest(v, "after a stranger tried to collect the vault's pool both ways");

        v.crank(); // the vault's own collect: permissionless at the VAULT, and it pays the vault's pool to the vault
        assertEq(lens.claimable(address(v), v.asset()), 0, "the crank brought the whole claim home for its owner");
        assertEq(v.idle(), idleBefore + owed, "into the vault's own balance, to the wei");
        assertEq(v.grossNav(), grossBefore, "and moving it valued nothing");
        _assertCounterHonest(v, "after the vault's own crank collected");
    }

    /// @dev THE LITERAL LEGACY CALLDATA, as a keeper sent it before the reshape: `collect(address lender, address quote)`.
    /// @dev The selector survived the argument swap, so it decodes as `(quote = vault, to = asset)` and spends the caller's
    /// @dev own, empty, pool. ACCEPTED BY RULING rather than refused: it pays nothing, logs nothing, and moves no NAV.
    function test_Stranger_ALegacyOrderCollectNamingTheVaultPaysNothingAndLogsNothing() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _accrued(v);
        _repay(loanId, DRAW / 4);
        uint256 owed = lens.claimable(address(v), v.asset());
        assertGt(owed, 0, "LIVENESS: the vault has a pool the old call used to bring home");
        bytes memory legacy = abi.encodeWithSignature("collect(address,address)", address(v), v.asset());
        uint256 grossBefore = v.grossNav();
        uint256 idleBefore = v.idle();

        vm.recordLogs();
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(ace).call(legacy);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok, "the old calldata does NOT revert: the selector survived the argument swap");
        assertEq(abi.decode(ret, (uint256)), 0, "it pays nothing");
        assertEq(logs.length, 0, "and logs nothing at all");
        assertEq(lens.claimable(address(v), v.asset()), owed, "the vault's pool is untouched, still its own crank's to bring home");
        assertEq(v.idle(), idleBefore, "no cash reached the vault");
        assertEq(v.grossNav(), grossBefore, "so the aggregate did not move");
    }

    // ---- finalize and buyInventory: keeper-driven, and both take a party the vault never chose ----

    /// @dev A keeper settles and a stranger buys the pot, with the vault never cranking in between.
    /// @dev The loss must land atomically and the recovery must reach the aggregate the vault reads.
    function test_Stranger_SettlementAndFillLandWithoutTheVaultTouchingAnything() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);

        uint256 grossBefore = v.grossNav();
        _finalize(loanId); // the keeper, who is nobody the vault named
        uint256 afterLoss = v.grossNav();
        assertLt(afterLoss, grossBefore, "the loss landed the instant a stranger settled it");
        _assertCounterHonest(v, "after a stranger-driven settlement");

        assertGt(_buyPot(stranger, loanId, 40_000e6), 0, "a stranger really did buy the pot");
        assertGt(v.grossNav(), afterLoss, "and the recovery reached the aggregate with nobody cranking");
        _assertCounterHonest(v, "after a stranger-driven fill");
    }

    /// @dev A stranger's buy CREDITS the vault's pool at the hub, and a stranger's crank brings it home, NAV-NEUTRALLY.
    /// @dev The buyer's cash waits at the hub as the vault's credit, so the aggregate moves by the fill alone, at the sale.
    /// @dev The crank after it MOVES that cash into the vault's balance and values nothing.
    function test_Stranger_ASaleCreditsTheVaultsPool_AndItsCrankBringsItHome() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        assertEq(lens.claimable(address(v), v.asset()), 0, "PREMISE: nothing is pooled for the vault before the sale");

        uint256 grossBefore = v.grossNav();
        uint256 idleBefore = v.idle();

        uint256 filled = _buyPot(stranger, loanId, 40_000e6);

        assertGt(filled, 0, "LIVENESS: a stranger really did buy the pot");
        assertEq(lens.claimable(address(v), v.asset()), filled, "the proceeds wait in the vault's pool, credited whole");
        assertEq(v.idle(), idleBefore, "and none of the buyer's cash has reached the vault yet");
        assertEq(v.grossNav() - grossBefore, filled, "so the aggregate rose by the fill alone, at the sale");
        _assertCounterHonest(v, "after a sale credited the vault");

        vm.prank(stranger);
        v.crank();
        assertEq(lens.claimable(address(v), v.asset()), 0, "a stranger's crank brought the credit home");
        assertEq(v.idle(), idleBefore + filled, "into the vault's own balance, to the wei");
        assertEq(v.grossNav() - grossBefore, filled, "so the crank itself is NAV-neutral");
        _assertCounterHonest(v, "after a stranger's crank brought the sale home");
    }

    /// @dev `buyInventory`'s `unitsTo` is arbitrary, so a stranger can push COLLATERAL onto the vault.
    /// @dev The vault has no collateral accounting at all, so the arrival must be worth exactly nothing.
    /// @dev It is also UNRECOVERABLE: there is no rescue verb, which is the accepted cost of that silence.
    function test_Stranger_CollateralPushedOntoTheVaultIsWorthNothingToIt() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);
        /// @dev Past the ask hold BEFORE the baselines are taken, so no vesting runs between them and the fill
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));

        uint256 grossBefore = v.grossNav();
        uint256 navBefore = v.totalAssets();
        usdc.mint(stranger, 40_000e6);
        vm.startPrank(stranger);
        _approveCash(mid, 40_000e6); // the hub pulls the buyer's cash
        (uint256 unitsOut,) = ace.buyInventory(loanId, 40_000e6, 0, address(v)); // the vault as payee
        vm.stopPrank();

        assertGt(unitsOut, 0, "LIVENESS: real collateral really was directed at the vault");
        assertEq(collateral.balanceOf(address(v)), unitsOut, "and it landed and is stuck there");
        assertGt(v.grossNav(), grossBefore, "the SALE lifted the aggregate, as any fill does");
        assertGt(v.grossNav() - grossBefore, 0, "which is the quote leg, never the collateral leg");
        assertEq(v.totalAssets(), navBefore, "and the deferral holds the rise back exactly as usual");
        _assertCounterHonest(v, "after collateral was pushed onto the vault");
    }

    // ---- the one guarded lens view ----

    /// @dev A market on a quote token that reads the lens from inside the hub's own guarded body.
    function _tornMarket(address quote) internal returns (bytes32) {
        MockPersistenceRecord rec = new MockPersistenceRecord(quote, address(collateral));
        rec.setObserved(1e18);
        rec.setMinPrice(T2);
        MarketParams memory p = AceFixtures.marketParams(quote, address(collateral));
        p.record = address(rec);
        p.lender = stranger; // sole tenancy: the party whose deposit fires the probe has to BE the market's lender
        return ace.createMarket(p);
    }

    /// @dev THE GUARD THAT PRICES SHARES. `Ace.lenderAssets` refuses a torn read, because the three
    /// @dev aggregates it sums move mid-body on the draw, repay, deleverage and settle paths.
    /// @dev A vault quoting off a half-updated sum mints or burns at a price that never existed.
    /// @dev MUTATION TARGET: delete the `nonReentrantView` modifier on `Ace.lenderAssets`.
    function testRevert_LenderAssets_RefusesAReadTakenInsideAGuardedHubBody() public {
        TornReadQuote tok = new TornReadQuote();
        bytes32 id = _tornMarket(address(tok));
        tok.arm(address(ace), id, stranger); // the depositor IS the market lender, which sole tenancy requires

        tok.probeOutside();
        assertTrue(tok.probed(), "LIVENESS: the probe ran");
        assertFalse(tok.reverted(), "CONTROL: the same read answers fine with no hub body in flight");

        tok.mint(stranger, 5_000e6);
        vm.startPrank(stranger);
        tok.approve(address(ace), 5_000e6);
        ace.deposit(id, 5_000e6); // the pull fires the probe inside the hub's guarded body
        vm.stopPrank();

        assertTrue(tok.reverted(), "the torn read was NOT refused, so a vault could price shares off it");
        assertEq(tok.seen(), GUARD_TRIP, "refused as the guard, not by accident");
    }

    /// @dev The guard is SCOPED, and the scope is the claim worth pinning: it gates the HUB's pricing
    /// @dev read and NOTHING on the lens, which is why a monitor can still read the gap from a callback.
    /// @dev Both legs are taken in the SAME window, so this is a live comparison rather than two stories.
    function test_LenderAssets_TheGuardGatesThePricingReadAndNotTheLens() public {
        TornReadQuote tok = new TornReadQuote();
        bytes32 id = _tornMarket(address(tok));
        tok.arm(address(ace), id, stranger); // the depositor IS the market lender, which sole tenancy requires
        tok.armLens(address(lens));

        tok.mint(stranger, 5_000e6);
        vm.startPrank(stranger);
        tok.approve(address(ace), 5_000e6);
        ace.deposit(id, 5_000e6); // both probes fire inside the hub's guarded body
        vm.stopPrank();

        assertTrue(tok.probed(), "LIVENESS: the probe ran");
        assertTrue(tok.reverted(), "the hub's pricing read is gated");
        assertTrue(tok.lensAnswered(), "and an unguarded lens view still answers in the SAME window");

        /// @dev WAS `lens.lenderAssets(ids)`, a BATCH over market ids that summed a per-market aggregate.
        /// @dev The figure is keyed by (lender, quote) across a lender's markets, so there is no batch to take
        /// @dev and the lens's own unguarded twin is `lenderPools`, which returns the three legs rather than a sum.
        (uint256 resting,,) = lens.lenderPools(stranger, address(tok));
        assertGt(resting, 0, "outside any body the unguarded twin answers normally");
        assertEq(lens.marketState(id).cash, 5_000e6, "the unguarded views answer as they always did");
    }

    /// @dev The consequence for the VAULT, which is the reason the guard is on this read at all.
    /// @dev Its NAV rests on `lenderAssets`, so a torn read is a torn share price on every verb.
    function test_LenderAssets_TheVaultsWholeNavRestsOnTheGuardedRead() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        bytes memory torn = abi.encodeWithSelector(GUARD_TRIP);
        vm.mockCallRevert(address(ace), abi.encodeWithSelector(Ace.lenderAssets.selector), torn);

        vm.expectRevert(GUARD_TRIP);
        v.grossNav();
        vm.expectRevert(GUARD_TRIP);
        v.totalAssets();
        vm.clearMockedCalls();
        assertEq(v.grossNav(), _hubTruthNav(v), "and it answers again the moment the guard clears");
    }

    // ---- the sync seam, which a stranger can move under somebody else's standing quote ----

    /// @dev A ladder standing from an earlier arrival, then an unsynced settlement big enough to burn it.
    /// @dev Duplicated from the vault's own suites deliberately, so this file still reads on its own.
    /// @dev The settled loan is SHALLOW_DOOMED, about four percent of the book, which still burns past the ladder.
    function _unsyncedFallUnderALadder(CuratorVault v) internal {
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, lens.loan(loanId).debt);
        _crankAll(v); // banks the repayment AND stamps the arrival on the ladder in one sync
        uint256 ladder = v.unvested();
        assertGt(ladder, 0, "fixture: a ladder the loss has not yet retired is standing");
        assertGt(SHALLOW_DOOMED, ladder, "fixture: the fall still burns past the ladder");
        uint256 doomed = _open(SHALLOW_DOOMED);
        _crankByLoan(v, doomed);
        _finalize(doomed);
        _waivePots(v); // the pot stays unsold and the fall unsynced, and the depositor may still enter
    }

    uint256 internal constant SHALLOW_DOOMED = 800e6; // about four percent of the seed

    /// @dev `collectFee` is PERMISSIONLESS, so a stranger picks the moment the seam closes.
    /// @dev Fired between a depositor's quote and their fill, it must not cost them a single share.
    /// @dev BROKEN: the sync retires the ladder the loss wiped out, which RAISES NAV and mints fewer.
    function test_Stranger_SyncingBetweenAQuoteAndItsFillDoesNotMoveThePrice() public {
        CuratorVault v = _newVault(2000);
        _unsyncedFallUnderALadder(v);
        uint256 promised = v.previewDeposit(1_000e6);

        vm.prank(stranger);
        v.collectFee();

        assertGe(_lpDeposit(v, bob, 1_000e6), promised, "a stranger's sync must not cost the depositor shares");
    }

    /// @dev The same seam through `crank`, whose NatSpec says PERMISSIONLESS and which also syncs first.
    /// @dev `crank` is the same `_sync` then `_collectFeeAt` shape, so this row covers the class.
    function test_Stranger_CrankingBetweenAQuoteAndItsFillDoesNotMoveThePrice() public {
        CuratorVault v = _newVault(2000);
        _unsyncedFallUnderALadder(v);
        uint256 promised = v.previewDeposit(1_000e6);

        vm.startPrank(stranger);
        _crankAll(v);
        vm.stopPrank();

        assertGe(_lpDeposit(v, bob, 1_000e6), promised, "a stranger's crank must not cost the depositor shares");
    }
}
