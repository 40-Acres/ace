// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanClosed, NotExpired} from "../../src/ace/hub/Settlement.sol";
import {ZeroPrincipal} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockRevertingRecord} from "../mocks/MockRevertingRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice The per-leg door alone: `abi.encodeCall(Ace.claimOwed, ...)` is ambiguous once the name is overloaded.
/// @dev Typed rather than `encodeWithSignature`, so a re-signature breaks the BUILD instead of an assertion.
interface IClaimOwedPerLeg {
    function claimOwed(uint256 loanId, address toUnits, address toQuote) external returns (uint256, uint256);
}

/// @title AceExpiryRollover
/// @notice The policy fold in forceClose (D0 ruling 2026-08-17): pay the sliver, then continue.
/// @notice An armed expired loan continues on its stored terms; it settles only when inadmissible.
/// @notice The outcome is a function of loan state, never of who cranks.
/// @dev Written failing-first when forceClose settled an armed healthy loan; the fold shipped green.
contract AceExpiryRolloverTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);
    address internal mallory = address(0xBAD);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;
    uint64 internal constant WINDOW = 2 hours; // min(2h, 7d/5) == 2h on every market here

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant BASE_BPS = 40;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    /// @dev A dust floor over the melted debt and ALSO over what the surviving collateral can carry.
    uint256 internal constant UNREACHABLE_FLOOR = 65_000e6;

    uint256 internal T; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal DEEP; // the depth the draws in this file never walk down to
    uint256 internal NEAR; // one rung under the top: needs a second claim tick, and stays admissible
    uint256 internal constant TOP = 400_000e6;
    uint256 internal constant DEEP_CASH = 200_000e6;
    /// @dev Enough for one draw of SMALL and too little change to fund its continuation alone.
    uint256 internal constant THIN = 70_000e6;
    uint256 internal constant SMALL = 60_000e6;
    /// @dev Under a continuation of SMALL, so it cannot carry one alone, and over the change THIN leaves, so the pair can.
    uint256 internal constant SPLIT = 55_000e6;

    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T, DEEP, NEAR) = (_price(0), _price(-6000), _price(-60));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        _deposit(id, TOP);
        _deposit(id, DEEP_CASH);
        usdc.mint(borrower, 1_000_000e6);
    }

    // ---- fixture ----

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = BASE_BPS;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    /// @dev A twin of `record` on the same pair, seeded identically: what makes a market on the base terms hash distinct.
    function _twinRecord() private returns (address) {
        MockPersistenceRecord twin = new MockPersistenceRecord(address(usdc), address(vault));
        twin.setMinPrice(record.minPrice(address(usdc), address(vault)));
        return address(twin);
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        return _openOn(id, principal, tenor);
    }

    function _openOn(bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, principal, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _arm(uint256 loanId, uint64 tenor, uint16 buf) internal {
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, tenor, buf, 0);
    }

    /// @dev Section 6.4's derivation, spelled from the record; refund is ZERO at and after expiry.
    /// @dev The ALL-IN factor: `N = baseBps*tenor*11000` against `D = 1e8*minTenor`.
    function _derived(uint256 debtOld, uint64 tenor) internal pure returns (uint256) {
        uint256 d = 10000 * 10000 * uint256(TEN7);
        uint256 den = d - BASE_BPS * uint256(tenor) * 11000;
        return (debtOld * d + den - 1) / den;
    }

    /// @dev The debt-based in-kind sliver, mirroring `Settlement._settle`, clamped to the position.
    function _sliver(bytes32 mid, uint256 loanId) internal view returns (uint256) {
        uint256 floorPrice = read.fundingFloor(mid, loanId);
        if (floorPrice == 0) return 0;
        uint256 bty = (read.debtOf(loanId) * ace.idToMarketParams(mid).settleBountyBps * UNIT_SCALE) / (10000 * floorPrice);
        uint256 units = read.loan(loanId).collateralUnits;
        return bty < units ? bty : units;
    }

    /// @dev The sliver is CREDITED to the cranking caller on both branches, so the crank's second half
    /// @dev is the caller pulling it. Bundled here, since every assertion below measures the wallet.
    function _forceClose(address caller, uint256 loanId) internal {
        vm.prank(caller);
        ace.forceClose(loanId);
        vm.prank(caller);
        ace.claimOwed(loanId, caller);
    }

    function _rawForceClose(address caller, uint256 loanId) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(ace).call(abi.encodeWithSelector(Ace.forceClose.selector, loanId));
    }

    /// @dev An armed healthy loan one second past expiry: the fold's canonical fixture.
    function _armedExpired() internal returns (uint256 loanId) {
        loanId = _open(P, TEN7);
        _arm(loanId, TEN7, 0);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
    }

    function _sawEvent(Vm.Log[] memory logs, bytes32 sig) internal pure returns (bool) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    function _expiryRolledSig() internal pure returns (bytes32) {
        return keccak256("ExpiryRolled(uint256,uint256,uint256,address)");
    }

    // ============ R1-R2. the fold's two branches ============

    /// @notice R1: at expiry an armed healthy loan CONTINUES rather than settling.
    /// @dev Settlement leaves the debt NON-zero; full retirement is how the two branches are told apart.
    function test_R1_ForceClose_OnAnArmedHealthyLoan_Continues_RatherThanSettling() public {
        uint256 oldId = _armedExpired();
        uint256 want = _derived(read.debtOf(oldId), TEN7);
        uint256 n = read.loanCount();

        _forceClose(keeper, oldId);

        assertTrue(read.loan(oldId).closedAt != 0, "the old loan is retired");
        assertEq(read.debtOf(oldId), 0, "its debt retired in FULL: this is a continuation, not a settlement");
        assertEq(read.loanCount(), n + 1, "a fresh loan was allocated");
        uint256 newId = n + 1;
        assertEq(read.loan(newId).borrower, borrower, "titled to the borrower");
        assertEq(read.debtOf(newId), want, "at the derived principal");
        assertEq(read.loan(newId).tenor, TEN7, "on the policy tenor");
        assertEq(read.invPotOf(id, oldId), 0, "and NO class gained an inventory pot");
        assertEq(read.invPotOf(id, oldId), 0, "at either funded level");
    }

    /// @notice The fold's CONTINUE branch carries the revenue push too, not only the settle branch beside it.
    /// @dev The sweep hangs off `forceClose`, which is ONE verb over two branches, so each needs its own row.
    /// @dev The continuation banks a fresh origination cut of its own, and the sweep runs after every write.
    function test_R1c_ForceClose_ContinueBranch_DeliversTheBankedRevenue() public {
        uint256 oldId = _armedExpired();
        uint256 paid0 = usdc.balanceOf(AceFixtures.TREASURY);
        assertGt(read.protocolRevenue(id), 0, "guard: origination banked a cut for the fold to find");

        _forceClose(keeper, oldId);

        assertEq(read.debtOf(oldId), 0, "fixture: this really was the continue branch, not a settlement");
        assertGt(usdc.balanceOf(AceFixtures.TREASURY), paid0, "the fold delivered the banked revenue");
        assertEq(read.protocolRevenue(id), 0, "and cleared the counter it swept, the continuation's own cut included");
    }

    /// @notice R2: BOTH branches pay the keeper the SAME in-kind sliver -- same formula, no new param.
    function test_R2_ForceClose_PaysTheSameSliver_OnBothBranches() public {
        uint256 loanId = _armedExpired();
        uint256 want = _sliver(id, loanId);
        uint256 root = vm.snapshotState();

        _forceClose(keeper, loanId);
        uint256 rolled = vault.balanceOf(keeper);
        assertEq(read.debtOf(loanId), 0, "fixture: this branch really was the rollover");

        vm.revertToState(root);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        _forceClose(keeper, loanId);
        uint256 settled = vault.balanceOf(keeper);
        assertGt(read.debtOf(loanId), 0, "fixture: this branch really was the settle");

        assertGt(want, 0, "the sliver is real");
        assertEq(rolled, want, "the rollover branch pays the settle formula's sliver");
        assertEq(settled, want, "and the settle branch pays the same figure");
    }

    // ============ R3. the fallthroughs to settle ============

    /// @notice R3: a continuation the collateral cannot carry falls through to settle, whole.
    function test_R3_ForceClose_FallsThroughToSettle_WhenTheCollateralCannotCarryTheDraw() public {
        (bytes32 mid, uint256 loanId) = _meltedDustLoan();
        _arm(loanId, TEN7, 0);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();
        uint256 want = _sliver(mid, loanId);

        vm.recordLogs();
        _forceClose(keeper, loanId);

        bytes32 sig = keccak256("ForceClosed(uint256,uint256,uint256,address)");
        assertTrue(_sawEvent(vm.getRecordedLogs(), sig), "settled");
        assertGt(read.invPotOf(mid, loanId), 0, "a pot was created: this was a title transfer");
        assertGt(want, 0, "the sliver is real");
        assertEq(vault.balanceOf(keeper), want, "and the keeper was paid it");
        assertEq(read.loanCount(), n, "no loan id was consumed by a half-attempt");
    }

    /// @notice R3b: a ladder that cannot fund the fresh draw falls through to settle.
    /// @dev The unfundable ladder is now driven by WITHDRAWING the resting cash -- the exit flags
    /// @dev that used to reserve it are deleted (2026-08-18); an exiting lender just leaves.
    function test_R3b_ForceClose_FallsThroughToSettle_WhenTheLadderCannotFundIt() public {
        uint256 loanId = _armedExpired();
        vm.prank(alice); // WAS a withdrawal per funded tick; one market, one resting balance, one exit
        ace.withdraw(id, type(uint256).max, alice, 0);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the loan settled");
        assertGt(read.debtOf(loanId), 0, "on the settle branch: the debt is not retired");
        assertEq(read.loanCount(), n, "and no loan id was consumed");
    }

    /// @notice R3c: the borrower's ONE term is honoured at expiry exactly as inside the window (A12).
    function test_R3c_ForceClose_FallsThroughToSettle_WhenTheBorrowersBufferTermIsUnmet() public {
        uint256 loanId = _open(P, TEN7);
        _arm(loanId, TEN7, 5000);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the loan settled");
        assertGt(read.debtOf(loanId), 0, "continue me, but NOT on any terms: the settle branch ran");
        assertEq(read.loanCount(), n, "and no loan id was consumed");
    }

    // ============ R4-R6. the unarmed path and the guards, unchanged ============

    /// @notice R4: an unarmed `forceClose` is byte-identical to today's settle. GREEN before the fold.
    function test_R4_ForceClose_OnAnUnarmedLoan_IsUnchanged() public {
        uint256 loanId = _open(P, TEN7);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();
        uint256 want = _sliver(id, loanId);
        uint256 rev0 = read.protocolRevenue(id);
        uint256 paid0 = usdc.balanceOf(AceFixtures.TREASURY);
        uint256 burns0 = read.marketState(id).cumulativeBackedBurns;

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "closed");
        assertEq(read.debtOf(loanId), P, "settlement does not zero the debt field");
        assertEq(pm.collateralOf(loanId), 0, "the position emptied");
        assertEq(vault.balanceOf(keeper), want, "the sliver paid as ever");
        assertGt(read.invPotOf(id, loanId), 0, "claims became the classes' pots at their own ticks");
        assertEq(read.loanCount(), n, "no new loan");
        uint256 swept = usdc.balanceOf(AceFixtures.TREASURY) - paid0;
        assertEq(read.protocolRevenue(id) + swept, rev0, "no protocol take at the loss endpoint: the sweep moved banked revenue, it did not create any");
        assertGt(read.marketState(id).cumulativeBackedBurns, burns0, "and the backed synthetic burned as ever");
    }

    /// @notice R5: before expiry the verb refuses BY NAME, policy read or not.
    /// @dev The guard must precede the policy read or mc1_expiry_force_close.json step 4 goes red.
    function test_R5_ForceClose_RefusedBeforeExpiry_ByName_EvenWhenArmed() public {
        uint256 loanId = _open(P, TEN7);
        _arm(loanId, TEN7, 0);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);

        (bool ok, bytes memory ret) = _rawForceClose(keeper, loanId);

        assertFalse(ok, "refused");
        assertEq(bytes32(bytes4(ret)), bytes32(NotExpired.selector), "NotExpired, exactly, zero-arg");
        assertFalse(read.loan(loanId).closedAt != 0, "and the loan is untouched");
    }

    /// @notice R6: a closed loan refuses BY NAME, policy read or not.
    function test_R6_ForceClose_RefusedOnAClosedLoan_ByName_EvenWhenArmed() public {
        uint256 loanId = _open(P, TEN7);
        _arm(loanId, TEN7, 0);
        vm.prank(borrower);
        ace.repay(loanId, P);
        assertTrue(read.loan(loanId).closedAt != 0, "fixture: repaid clean");
        _warpTo(uint256(read.loan(loanId).expiry) + 1);

        (bool ok, bytes memory ret) = _rawForceClose(keeper, loanId);

        assertFalse(ok, "refused");
        assertEq(bytes32(bytes4(ret)), bytes32(LoanClosed.selector), "LoanClosed, exactly");
    }

    // ============ R7. finalize stays policy-blind ============

    /// @notice R7: persistent distress settles an ARMED loan through `finalize`, policy unread.
    /// @dev Pins "do not touch finalize" as an executable fact: distress is what the right is FOR.
    function test_R7_Finalize_StaysPolicyBlind_ADistressedArmedLoanSettles() public {
        uint256 loanId = _open(P, TEN7);
        _arm(loanId, TEN7, 0);
        record.setBelow(true);
        _warpTo(t0 + 5 hours);
        uint256 n = read.loanCount();

        vm.prank(keeper);
        ace.finalize(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "settled");
        assertGt(read.invPotOf(id, loanId), 0, "a pot was created");
        assertEq(read.loanCount(), n, "NO new loan: the policy was never consulted");
    }

    // ============ R8-R9. the race removal ============

    /// @notice R8: the outcome is a function of LOAN STATE -- three callers, identical post-state.
    /// @dev Except the sliver recipient, which is the executor by design.
    /// @dev The borrower-caller leg is economically a health-gated partial withdrawal at expiry: benign.
    function test_R8_ForceClose_IsAFunctionOfLoanState_NotOfWhoCranks() public {
        uint256 oldId = _armedExpired();
        uint256 newId = read.loanCount() + 1;
        uint256 want = _sliver(id, oldId);
        address[3] memory callers = [keeper, borrower, alice];
        uint256 root = vm.snapshotState();

        for (uint256 i; i < 3; i++) {
            uint256 pre = vault.balanceOf(callers[i]);
            _forceClose(callers[i], oldId);

            assertEq(read.debtOf(oldId), 0, "every caller lands the same branch: continuation");
            assertEq(read.loan(newId).borrower, borrower, "titled to the borrower regardless of caller");
            assertEq(pm.collateralOf(newId), COLL - want, "the continuation holds the remainder");
            assertEq(vault.balanceOf(callers[i]) - pre, want, "the caller took the sliver, whoever it was");
            assertLe(read.triggerPrice(newId), read.fundingFloor(id, newId), "and the health gate held on the REDUCED collateral");
            vm.revertToState(root);
        }
    }

    /// @notice R9: THE REPRO -- a keeper used to SETTLE a healthy armed loan and be PAID for it.
    /// @notice Now the same crank continues the loan and the keeper is paid the same sliver.
    /// @dev Fails on today's code for the right reason: forceClose never reads the policy.
    function test_R9_REPRO_ASettleNoLongerBeatsAHealthyArmedLoansContinuation() public {
        uint256 oldId = _armedExpired();
        uint256 n = read.loanCount();

        _forceClose(keeper, oldId);

        assertEq(read.loanCount(), n + 1, "the loan CONTINUED");
        assertEq(read.debtOf(oldId), 0, "debt retired in full, not seized");
        assertGt(vault.balanceOf(keeper), 0, "and the keeper was still paid for cranking");
    }

    /// @notice R9b: the fold's sliver is a UNITS-ONLY credit, so the per-leg door pays it with the quote leg declined.
    /// @notice And declining the UNITS leg leaves the sliver credited, which is the half a forfeiting skip would break.
    /// @dev The continue branch credits `msg.sender` in kind and never in quote, so a keeper's quote entry is empty.
    function test_R9b_ContinueBranchSliver_SurvivesADeclineAndPaysThroughThePerLegDoor() public {
        uint256 oldId = _armedExpired();
        uint256 want = _sliver(id, oldId);
        assertGt(want, 0, "fixture: the sliver is real");

        vm.prank(keeper);
        ace.forceClose(oldId);
        (uint256 u, uint256 q) = ace.owedOf(oldId, keeper);
        assertEq(read.debtOf(oldId), 0, "fixture: this really was the continue branch");
        assertEq(u, want, "the fold credited the crank its sliver in kind");
        assertEq(q, 0, "and no quote at all, so the keeper's second leg is empty");

        vm.prank(keeper);
        IClaimOwedPerLeg(address(ace)).claimOwed(oldId, address(0), keeper);
        assertEq(vault.balanceOf(keeper), 0, "a declined units leg pays the keeper nothing");
        (uint256 uLeft,) = ace.owedOf(oldId, keeper);
        assertEq(uLeft, want, "and the sliver is still credited, not forfeited");

        vm.prank(keeper);
        IClaimOwedPerLeg(address(ace)).claimOwed(oldId, keeper, address(0));
        assertEq(vault.balanceOf(keeper), want, "naming the units leg later pays it in full");
    }

    // ============ R10-R12. the doors and the ledgers around the fold ============

    /// @notice R10: the free pre-expiry window SURVIVES UNCHANGED and stays free.
    function test_R10_PreExpiryRefinanceByPolicy_IsUnchanged_AndStillFree() public {
        uint256 loanId = _open(P, TEN7);
        _arm(loanId, TEN7, 0);
        _warpTo(uint256(read.loan(loanId).expiry) - WINDOW);
        uint256 quote0 = usdc.balanceOf(mallory);

        vm.prank(mallory);
        uint256 newId = ace.refinanceByPolicy(loanId);

        assertFalse(read.loan(newId).closedAt != 0, "the sponsor door fired");
        assertEq(usdc.balanceOf(mallory), quote0, "and moved ZERO quote to the caller");
        assertEq(vault.balanceOf(mallory), 0, "and ZERO collateral: this door is free");
    }

    /// @notice R10b: the post-expiry sponsor door stays OPEN and FREE.
    /// @dev A sponsor may continue an expired armed loan for free; the paid fold is the backstop.
    function test_R10b_PostExpiryRefinanceByPolicy_StaysOpenAndFree_ByRuling() public {
        uint256 loanId = _armedExpired();

        vm.prank(mallory);
        uint256 newId = ace.refinanceByPolicy(loanId);

        assertFalse(read.loan(newId).closedAt != 0, "the sponsor door still fires past expiry");
        assertEq(vault.balanceOf(mallory), 0, "no sliver: free is better for the borrower");
        assertEq(pm.collateralOf(newId), COLL, "and the WHOLE position carries: no sliver was shaved");
    }

    /// @notice R11: the fold logs `ExpiryRolled(oldId, newId, sliverUnits, executor)`, rollover only.
    /// @dev The sliver is invisible in every other event; a sponsor reimbursing keepers needs it.
    function test_R11_ExpiryRolled_LogsTheSliverAndTheExecutor() public {
        uint256 oldId = _armedExpired();
        uint256 want = _sliver(id, oldId);
        uint256 root = vm.snapshotState();

        vm.recordLogs();
        _forceClose(keeper, oldId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != _expiryRolledSig()) continue;
            found = true;
            assertEq(uint256(logs[i].topics[1]), oldId, "oldId");
            assertEq(uint256(logs[i].topics[2]), read.loanCount(), "newId");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), keeper, "executor is msg.sender, delegatecall-safe");
            assertEq(abi.decode(logs[i].data, (uint256)), want, "sliverUnits");
        }
        assertTrue(found, "the rollover emits ExpiryRolled");

        vm.revertToState(root);
        vm.prank(borrower);
        ace.setAutoRefinance(oldId, 0, 0, 0);
        vm.recordLogs();
        _forceClose(keeper, oldId);
        assertFalse(_sawEvent(vm.getRecordedLogs(), _expiryRolledSig()), "and the settle branch does NOT");
    }

    /// @notice R12: the rollover retires the old loan IN FULL and leaves the lender whole at par.
    /// @notice A HOME roll RECYCLES the retiring principal into the successor, so par moves claim to claim, not into `owed`.
    /// @dev Nothing is inventoried, the old claim is gone, the successor's claim covers the old debt, and no lender asset fell.
    function test_R12_TheRolloverBranch_RetiresTheOldLendersInFull() public {
        uint256 oldId = _armedExpired();
        uint256 debtOld = read.debtOf(oldId);
        (uint256 restingBefore, uint256 lentBefore, uint256 owedBefore) = read.lenderPools(alice, address(usdc));
        uint256 n = read.loanCount();

        _forceClose(keeper, oldId);

        (uint256 restingAfter, uint256 lentAfter, uint256 owedAfter) = read.lenderPools(alice, address(usdc));
        assertEq(read.invPotOf(id, oldId), 0, "NOTHING was inventoried: the roll retired the old loan, it did not settle it");
        assertEq(read.claimOf(id, oldId), 0, "and the old loan's claim melted to nothing");
        assertGe(read.claimOf(id, n + 1), debtOld, "the successor's claim carries the old debt at par");
        assertGe(restingAfter + lentAfter + owedAfter, restingBefore + lentBefore + owedBefore, "and no lender asset fell across the roll");
    }

    // ============ R13. the must-execute backstop survives sick oracles ============

    /// @notice R13: a REVERTING record routes an armed expired loan to SETTLEMENT, never to a revert.
    /// @dev Delete the try-wrappers and this is the test that goes red.
    function test_R13_ForceClose_StillSettles_WhenTheRecordReverts() public {
        MockRevertingRecord sick = new MockRevertingRecord(address(usdc), address(vault));
        MarketParams memory p = _params();
        p.record = address(sick); // the sick record is also what makes this market a distinct id
        bytes32 mid = ace.createMarket(p);
        _deposit(mid, TOP);
        uint256 loanId = _openOn(mid, P, TEN7);
        _arm(loanId, TEN7, 0);
        sick.setRevoked(true);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the backstop executed");
        assertGt(read.debtOf(loanId), 0, "on the settle branch");
        assertEq(read.loanCount(), n, "no continuation was attempted");
    }

    // ============ R13d-h. the same backstop, against a record that ANSWERS badly ============

    /// @notice R13d: a record answering EMPTY routes an armed expired loan to SETTLEMENT.
    /// @notice A malformed ANSWER is not a revert: the call succeeds and the decode fails in Borrower's frame.
    /// @dev try/catch cannot absorb that, so `tryPersistedPrice` reads the returndata raw and checks its length.
    /// @dev Written RED against the try/catch form; the twin of the gate seam's own fix in `_gateAdmits`.
    function test_R13d_ForceClose_StillSettles_WhenTheRecordAnswersEmpty() public {
        (uint256 loanId, MockRevertingRecord rec) = _decayingRecordLoan();
        rec.setAnswerMode(1);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the backstop executed");
        assertGt(read.debtOf(loanId), 0, "on the settle branch");
        assertEq(read.loanCount(), n, "no continuation was attempted");
    }

    /// @notice R13e: a 31-byte answer from the record is the same failure with the right shape.
    function test_R13e_ForceClose_StillSettles_WhenTheRecordAnswersShort() public {
        (uint256 loanId, MockRevertingRecord rec) = _decayingRecordLoan();
        rec.setAnswerMode(2);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the backstop executed");
        assertGt(read.debtOf(loanId), 0, "on the settle branch");
        assertEq(read.loanCount(), n, "no continuation was attempted");
    }

    /// @notice R13h: CONTROL -- the SAME record left answering cleanly continues the loan.
    /// @dev Without it, R13d and R13e would be satisfied by a fold that never continues on this fixture.
    function test_R13h_ForceClose_Continues_WhenTheDecayingRecordAnswersCleanly() public {
        (uint256 loanId,) = _decayingRecordLoan();
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertEq(read.loanCount(), n + 1, "a clean answer rolls like any other");
        assertEq(read.debtOf(loanId), 0, "its debt retired in FULL: this was the continuation");
    }

    // ============ R14. the ordering: sliver first, remainder continues ============

    /// @notice R14: the continuation draws on the REMAINDER -- the sliver is shaved before the draw.
    function test_R14_TheContinuationDrawsOnTheREMAINDER_NotTheWholePosition() public {
        uint256 oldId = _armedExpired();
        uint256 want = _sliver(id, oldId);
        assertGt(want, 0, "fixture: the sliver is real");

        _forceClose(keeper, oldId);

        uint256 newId = read.loanCount();
        assertEq(pm.collateralOf(newId), COLL - want, "the new position holds COLL minus the sliver, to the wei");
        assertEq(pm.collateralOf(oldId), 0, "and the old position is empty");
    }

    // ============ R16. the claim-tick cap, folded rather than thrown ============

    // DELETED WITH `maxClaimTicks`: the R16 pair reached settle via `CapacityExceeded`, and one claim at one price has no span to exceed

    // ============ R17. the policy tenor reaches the walk ============

    // DELETED WITH THE PER-DEPOSIT HORIZON: R17 armed a policy no rung consented to; `setAutoRefinance` refuses it at arm time now, so the state is unreachable

    /// @notice R17b: CONTROL -- the identical ladder funds a policy term it DOES consent to.
    function test_R17b_ForceClose_Continues_WhenTheLadderConsentsToThePolicyTerm() public {
        (, uint256 loanId) = _shortConsentLoan(TEN7);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertEq(read.loanCount(), n + 1, "the same ladder funds the term it consented to");
        assertEq(read.loan(n + 1).tenor, TEN7, "on the policy's own tenor");
    }

    // ============ R18. the gate is priced on the collateral that SURVIVES the sliver ============

    /// @notice R18: a term the WHOLE position meets but the post-sliver remainder does not SETTLES.
    /// @notice The same term, at the same instant, still continues through the free sponsor door.
    /// @dev The two doors differ in exactly one thing: this one shaves a sliver first.
    /// @dev A fold that judged the whole position would migrate and then revert inside `open`'s own gate.
    /// @dev The discriminating term is MEASURED off the two doors' own results, never recomputed here.
    function test_R18_TheGateIsPricedOnTheSurvivingCollateral_NotTheWholePosition() public {
        (bytes32 mid, uint256 loanId) = _bountyHeavyLoan();
        uint256 root = vm.snapshotState();

        _forceClose(keeper, loanId);
        uint256 shaved = _bufferBps(mid, read.loanCount());
        vm.revertToState(root);

        vm.prank(mallory);
        uint256 whole = _bufferBps(mid, ace.refinanceByPolicy(loanId));
        vm.revertToState(root);

        assertGt(whole, shaved + 1, "fixture: shaving the sliver measurably thins the buffer");
        uint16 term = uint16((whole + shaved) / 2);
        uint256 n = read.loanCount();

        _arm(loanId, TEN7, term);
        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the paid door settled");
        assertGt(read.debtOf(loanId), 0, "on the settle branch: the REMAINDER cannot meet the term");
        assertEq(read.loanCount(), n, "and no loan id was consumed");

        vm.revertToState(root);
        _arm(loanId, TEN7, term);
        vm.prank(mallory);
        uint256 newId = ace.refinanceByPolicy(loanId);

        assertFalse(read.loan(newId).closedAt != 0, "while the free door, which shaves nothing, meets the SAME term");
        assertEq(pm.collateralOf(newId), COLL, "on the WHOLE position, which is the only difference");
    }

    // ============ R19. the fold conscripts nobody's quote ============

    /// @notice R19: the rollover carries `maxTopUp == 0`, so no standing approval is ever drawn on.
    /// @dev The crank is the one holding an approval here, and `_net` would pull from IT, not the borrower.
    /// @dev Self-funding makes the pull unreachable; this pins the `0` that keeps it unreachable.
    function test_R19_TheFold_ConscriptsNoStandingApproval_FromEitherParty() public {
        uint256 loanId = _armedExpired();
        usdc.mint(keeper, 1_000_000e6);
        vm.prank(keeper);
        usdc.approve(address(ace), type(uint256).max);
        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 borrowerBefore = usdc.balanceOf(borrower);

        _forceClose(keeper, loanId);

        assertEq(read.debtOf(loanId), 0, "fixture: this was the rollover branch");
        assertEq(usdc.balanceOf(keeper), keeperBefore, "the crank's approved quote was never touched");
        assertGe(usdc.balanceOf(borrower), borrowerBefore, "and the borrower's quote never DECREASES");
    }

    // ============ R20. the policy survives the fold ============

    /// @notice R20: the rolled loan carries the policy, so the NEXT expiry rolls as well.
    /// @dev A fold that dropped the policy would settle every position on its second term, silently.
    function test_R20_TheFold_CarriesThePolicy_SoTheSecondExpiryRollsToo() public {
        uint256 oldId = _armedExpired();

        _forceClose(keeper, oldId);
        uint256 midId = read.loanCount();
        (uint64 tenor, uint16 buf,) = read.autoPolicyOf(midId);

        assertEq(tenor, TEN7, "the continuation is armed on the carried tenor");
        assertEq(buf, 0, "and the carried buffer term");

        _warpTo(uint256(read.loan(midId).expiry) + 1);
        _forceClose(keeper, midId);

        assertEq(read.loanCount(), midId + 1, "the second expiry rolled as well");
        assertEq(read.debtOf(midId), 0, "retired in full again, so this was no settlement");
    }

    // ============ R21. the loan that funded no tick -- RETIRED WITH ITS STATE ============

    /// @notice The unfunded loan is unconstructible: both a zero principal and a zero market quantum are refused.
    /// @notice R21 and R21b stood here, proving the fold stayed total on such a loan end to end.
    /// @dev The zero-floor guards in the fold survive as fail-closed defence.
    /// @dev Their arithmetic is pinned in `AceZeroFloorGuards.t.sol`, since the hub can no longer stage the state.
    function test_R21_TheUnfundedLoanIsUnconstructible_AtBothDoors() public {
        MarketParams memory p = _params();
        p.minDebt = 0;
        vm.expectRevert(bytes("min debt zero"));
        ace.createMarket(p);

        MarketParams memory q = _params();
        q.record = _twinRecord();
        bytes32 mid = ace.createMarket(q);
        _deposit(mid, TOP);
        vault.mint(borrower, COLL); // staged OUTSIDE the expectRevert, so the mint is not what it catches
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        vm.expectRevert(ZeroPrincipal.selector);
        ace.open(mid, COLL, 0, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    // ---- secondary fixtures ----

    /// @dev The buffer a live loan actually got, in bps, read off its OWN trigger and funding floor.
    function _bufferBps(bytes32 mid, uint256 loanId) internal view returns (uint256) {
        uint256 floorPrice = read.fundingFloor(mid, loanId);
        uint256 trig = read.triggerPrice(loanId);
        if (floorPrice == 0 || trig > floorPrice) return 0;
        return ((floorPrice - trig) * 10000) / floorPrice;
    }

    /// @dev An armed expired loan whose continuation needs a SECOND tick the cap may or may not admit.
    /// @dev The top tick funds the first draw and keeps too little change to fund the second alone.
    /// @dev `maxTicks` IS IGNORED: it set `maxClaimTicks`, and a draw funds one claim at one price now.
    /// @dev The market takes a TWIN RECORD so its id hashes apart from the rig's own, exactly as
    /// @dev `_shortConsentLoan` does -- without it the params are the base market's and creation collides.
    function _cappedLadderLoan(uint256 maxTicks) private returns (bytes32 mid, uint256 loanId) {
        maxTicks;
        MarketParams memory p = _params();
        p.record = _twinRecord();
        mid = ace.createMarket(p);
        _deposit(mid, THIN);
        /// @dev SPLIT rather than TOP: a tick able to fund the whole continuation alone lets the retry pass over T and roll at cap 1.
        _deposit(mid, SPLIT);
        loanId = _openOn(mid, SMALL, TEN7);
        assertEq(read.claimCount(mid, loanId), 1, "fixture: the first draw fitted in one tick");
        _arm(loanId, TEN7, 0);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
    }

    /// @dev An armed expired loan on a ladder whose resting cash consents to the SHORTEST term only.
    /// @dev Drawn SMALL on purpose: the long continuation must be admissible, so consent is the ONE refusal.
    /// @dev MATURITY CONSENT IS THE MARKET'S `maxTenor` NOW, so the short consent is written here rather than
    /// @dev formed by the tenor a deposit stamped on its rung. A policy term past it cannot be drawn at all.
    function _shortConsentLoan(uint64 policyTenor) private returns (bytes32 mid, uint256 loanId) {
        MarketParams memory p = _params();
        p.record = _twinRecord(); // the terms are the base market's, so identity rides on the record
        p.maxTenor = TEN7; // the whole of what this market will write
        mid = ace.createMarket(p);
        _deposit(mid, TOP);
        loanId = _openOn(mid, SMALL, TEN7);
        _arm(loanId, policyTenor, 0);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
    }

    /// @dev An armed expired loan on a market at MarketInit's bounty ceiling, so the sliver is widest.
    function _bountyHeavyLoan() private returns (bytes32 mid, uint256 loanId) {
        MarketParams memory p = _params();
        p.settleBountyBps = 200; // also what makes this market a distinct id
        mid = ace.createMarket(p);
        _deposit(mid, TOP);
        loanId = _openOn(mid, P, TEN7);
        _arm(loanId, TEN7, 0);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
    }

    /// @dev A loan repaid under a dust floor its collateral cannot carry (A11e's fixture).
    /// @dev The borrower's own repay and withdrawal reach it: a keeper's crank never melts a loan under `minDebt`.
    function _meltedDustLoan() private returns (bytes32 mid, uint256 loanId) {
        MarketParams memory p = _params();
        p.minDebt = UNREACHABLE_FLOOR;
        mid = ace.createMarket(p);
        _deposit(mid, TOP);
        loanId = _openOn(mid, P, TEN7);
        _warpTo(uint256(read.loan(loanId).expiry) - WINDOW);
        uint256 amount = read.debtOf(loanId) - 30_000e6;
        usdc.mint(borrower, amount);
        vm.startPrank(borrower);
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
        ace.withdrawCollateral(loanId, 40_000e18, borrower); // 60k units carry 30k of debt and not a 65k floor
        vm.stopPrank();
        assertGt(read.debtOf(loanId), 0, "fixture: the repay left debt without closing the loan");
        assertLt(read.debtOf(loanId), UNREACHABLE_FLOOR, "fixture: under a floor the collateral cannot carry");
    }

    /// @dev An armed Rate-mode loan whose RECORD can be made to answer badly after the fact.
    /// @dev The rate source stays the healthy collateral, so only the record leg can be what refuses.
    function _decayingRecordLoan() private returns (uint256 loanId, MockRevertingRecord rec) {
        rec = new MockRevertingRecord(address(usdc), address(vault));
        MarketParams memory p = _params();
        p.record = address(rec); // also what makes this market a distinct id
        bytes32 mid = ace.createMarket(p);
        _deposit(mid, TOP);
        loanId = _openOn(mid, P, TEN7);
        _arm(loanId, TEN7, 0);
    }
}
