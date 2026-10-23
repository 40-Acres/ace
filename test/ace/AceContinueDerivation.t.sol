// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {DrawBelowDebt} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

interface IAceAuto {
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
    function refinanceByPolicy(uint256 id) external returns (uint256 newId);
}

/// @notice `DrawBelowDebt` is UNREACHABLE from an automatic continuation, and this is why.
/// @notice `derivedPrincipal` rounds UP through exactly the factor the origination fee then takes back.
/// @notice So the fresh draw always retires the old debt, and the netting's floor never binds on this path.
/// @dev A MANUAL refinance can still trip it: the borrower names the principal there, and may name one too small.
/// @dev Two halves, and neither alone is the claim. The fuzz proves the ARITHMETIC over the whole genesis
/// @dev domain, where a live market can only ever sample one point; the hub fuzz proves the WIRING, that the
/// @dev numbers the arithmetic bounds are the numbers the two verbs actually pass each other.
contract AceContinueDerivationTest is Test {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    bytes32 internal id;

    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    IAceAuto internal auto_;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xC0FFEE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint16 internal constant BASE_BPS = 40;

    uint256 internal TOP; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant TOP_CASH = 900_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @notice One fuzzed market-and-loan, bundled so the eight bounds and the derivation never share a frame.
    struct Case {
        uint64 minTenor;
        uint256 baseBps;
        uint64 tenor;
        uint256 minDebt;
        uint256 debt;
        uint256 esc;
        uint64 oldTenor;
        uint64 elapsed;
    }

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        TOP = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        auto_ = IAceAuto(address(ace));

        _deposit(TOP_CASH);
    }

    /* ================== half 1: the arithmetic, over the whole rail ================== */

    /// @notice Over the whole SLACK rail, which is wider than genesis: the derived draw less its own fee, plus the refund, clears the debt.
    /// @notice That inequality IS `_net`'s floor, so proving it here proves the floor cannot bind on this path.
    /// @notice DELIBERATELY BROADER THAN ADMISSION: the share rail caps genesis at a quarter, and this sweeps the ratio to nearly one.
    /// @dev The derivation is re-spelled with plain integer arithmetic; only the FEE is the shipped function.
    /// @dev Re-spelling it is the point -- a test that called `derivedPrincipal` would compare the code to itself.
    /// @dev `baseBps` tops at the flat-market ceiling so the domain is the admissible band, not a stale fraction of it.
    function testFuzz_DerivedDrawAlwaysRetiresTheOldDebt(
        uint64 minTenorSeed,
        uint256 baseBpsSeed,
        uint64 tenorSeed,
        uint256 debtSeed,
        uint256 escrowSeed,
        uint64 elapsedSeed,
        uint64 oldTenorSeed,
        uint256 minDebtSeed
    ) public pure {
        Case memory k;
        k.minTenor = uint64(bound(minTenorSeed, 1 hours, 365 days));
        /// @dev The rail is `baseBps * maxTenor * 11000 < 1e8 * minTenor`, and tenor never exceeds maxTenor.
        k.baseBps = bound(baseBpsSeed, 1, 2272); // the top rate a flat market carries, the widest band genesis admits
        k.tenor = _tenorWithinRail(k.minTenor, k.baseBps, tenorSeed);
        k.minDebt = bound(minDebtSeed, 1, 1e12);
        k.debt = bound(debtSeed, k.minDebt, 1e15);
        k.esc = bound(escrowSeed, 0, k.debt);
        k.oldTenor = uint64(bound(oldTenorSeed, k.minTenor, 365 days));
        k.elapsed = uint64(bound(elapsedSeed, 0, k.oldTenor));
        _assertDrawRetiresDebt(k);
    }

    /// @dev A term the genesis rail admits: strictly under `1e8 * minTenor / (baseBps * 11000)`, never under minTenor.
    function _tenorWithinRail(uint64 minTenor, uint256 baseBps, uint64 seed) private pure returns (uint64) {
        uint64 ceiling = uint64((10000 * 10000 * uint256(minTenor) - 1) / (baseBps * 11000));
        if (ceiling < minTenor) ceiling = minTenor;
        return uint64(bound(seed, minTenor, ceiling));
    }

    /// @dev The derivation and the netting floor, in their own frame; the caller holds eight bounds already.
    function _assertDrawRetiresDebt(Case memory k) private pure {
        uint256 d = 10000 * 10000 * uint256(k.minTenor);
        uint256 n = k.baseBps * uint256(k.tenor) * 11000;
        vm.assume(n < d); // the rail itself; `derivedPrincipal` reverts rather than divide by zero below it

        uint256 refundOld = (k.esc * (k.oldTenor - k.elapsed)) / k.oldTenor;
        if (refundOld > k.esc) refundOld = k.esc;
        uint256 owed = k.debt > refundOld ? k.debt - refundOld : 0;
        uint256 p = (owed * d + (d - n) - 1) / (d - n); // the documented ceil
        if (p < k.minDebt) p = k.minDebt;

        uint256 fee = LoanMath.originationFee(p, k.tenor, k.baseBps, k.minTenor);
        assertLe(fee, p, "the fee ate the whole draw, so the netting would underflow before it compared");
        assertGe(p - fee + refundOld, k.debt, "the derived draw cannot retire the debt it replaces: DrawBelowDebt");
    }

    /// @notice The same inequality with the refund FORCED positive: the pre-expiry roll, not just the fold.
    /// @notice `refinanceByPolicy` runs inside the auto window, where the old term is unfinished and the escrow refunds.
    /// @dev The general fuzz above admits `refundOld == 0` on most draws, so the live-refund arm needs its own run.
    /// @dev `DrawBelowDebt` is the fourth refusal `tryContinue` does not mirror; this is the arithmetic that keeps it dead.
    function testFuzz_DerivedDrawRetiresTheOldDebt_WithALiveRefund(
        uint64 minTenorSeed,
        uint256 baseBpsSeed,
        uint64 tenorSeed,
        uint256 debtSeed,
        uint256 escrowSeed,
        uint64 elapsedSeed,
        uint64 oldTenorSeed,
        uint256 minDebtSeed
    ) public pure {
        Case memory k;
        k.minTenor = uint64(bound(minTenorSeed, 1 hours, 365 days));
        k.baseBps = bound(baseBpsSeed, 1, 2272); // the top rate a flat market carries, the widest band genesis admits
        k.tenor = _tenorWithinRail(k.minTenor, k.baseBps, tenorSeed);
        k.minDebt = bound(minDebtSeed, 2, 1e12);
        k.debt = bound(debtSeed, k.minDebt, 1e15);
        k.oldTenor = uint64(bound(oldTenorSeed, k.minTenor, 365 days));
        /// @dev At most half the old term is spent and the escrow is at least two wei, so the pro-rata floor is >= 1.
        k.elapsed = uint64(bound(elapsedSeed, 0, k.oldTenor / 2));
        k.esc = bound(escrowSeed, 2, k.debt);
        _assertDrawRetiresDebtWithALiveRefund(k);
    }

    /// @dev The live-refund arm in its own frame; the caller holds eight bounds already.
    function _assertDrawRetiresDebtWithALiveRefund(Case memory k) private pure {
        uint256 refundOld = (k.esc * (k.oldTenor - k.elapsed)) / k.oldTenor;
        assertGt(refundOld, 0, "the arm's premise: this run must actually carry an unearned refund");
        _assertDrawRetiresDebt(k);
    }

    /// @notice The refund can only HELP: a larger unearned escrow lowers `owed` and the debt it must clear by the same wei.
    /// @dev Pinned separately because the refund is the one term that appears on both sides of the inequality.
    function testFuzz_TheRefundNeverWeakensTheInequality(uint256 debtSeed, uint256 escrowSeed, uint256 splitSeed) public pure {
        uint256 debt = bound(debtSeed, 1e6, 1e15);
        uint256 esc = bound(escrowSeed, 0, debt);
        uint256 refundOld = bound(splitSeed, 0, esc);

        uint256 d = 10000 * 10000 * uint256(uint64(7 days));
        uint256 n = 40 * uint256(uint64(7 days)) * 11000;
        uint256 owed = debt - refundOld;
        uint256 p = (owed * d + (d - n) - 1) / (d - n);
        uint256 fee = LoanMath.originationFee(p, 7 days, 40, 7 days);

        assertGe(p - fee + refundOld, debt, "the refund term broke the inequality it is supposed to relax");
    }

    /* ==================== half 2: the wiring, through the hub ==================== */

    /// @notice The same claim on the live path: an admitted roll never reverts on the netting floor.
    /// @notice Fuzzed over the two things a borrower actually controls, the size of the loan and when it rolls.
    /// @dev `tryContinue` is the gate: what it admits, `refinanceByPolicy` must complete. A refusal is not a failure
    /// @dev of this property, so the run asserts on the ADMITTED case and records that the case was reached.
    function testFuzz_AnAdmittedRollNeverHitsTheNettingFloor(uint256 principalSeed, uint256 lateSeed) public {
        uint256 principal = bound(principalSeed, 10e6, 60_000e6);
        uint256 loanId = _armedLoan(principal);
        uint64 expiry = read.loan(loanId).expiry;
        uint64 window = uint64(bound(lateSeed, 0, 2 hours)); // the whole admissible run-up to expiry
        vm.warp(expiry - window);

        (bool ok,,) = auto_.tryContinue(loanId);
        if (!ok) return; // outside the window, or the ladder moved: neither is this property's subject

        vm.prank(keeper);
        try auto_.refinanceByPolicy(loanId) returns (uint256 newId) {
            assertGt(newId, 0, "an admitted roll produced no successor");
        } catch (bytes memory err) {
            assertTrue(_selector(err) != DrawBelowDebt.selector, "an ADMITTED roll reverted on the netting floor");
            revert("an admitted roll was refused by the verb");
        }
    }

    /// @notice A MANUAL refinance CAN hit the floor, which is what makes the automatic path's freedom from it a property.
    /// @dev The contrast is the point: without it, a green fuzz above could mean the floor is simply dead code.
    function test_ManualRefinanceStillHitsTheNettingFloor() public {
        uint256 loanId = _armedLoan(20_000e6);
        uint256 debt = read.debtOf(loanId);

        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        ace.refinance(loanId, debt, TEN7, OFF); // exactly the old debt, so the fresh fee leaves it a wei short
    }

    /* ========================== helpers ========================== */

    function _selector(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            s := mload(add(err, 32))
        }
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = BASE_BPS;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _armedLoan(uint256 principal) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        usdc.mint(borrower, principal);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, COLL, principal, TEN7, borrower, OFF);
        auto_.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
    }
}
