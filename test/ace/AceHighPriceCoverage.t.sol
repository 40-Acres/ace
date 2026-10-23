// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {Cfg, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @notice `Borrower.requiredAt` behind an EXTERNAL door, so an arithmetic panic is catchable rather than fatal.
/// @dev The shipped function is `internal`, so this call inlines it: the arithmetic under test is the real one.
/// @dev Without the door a sweep dies on its first bad price and reports a bare panic instead of the price.
contract RequiredAtProbe {
    /// @notice `Borrower.requiredAt` on a Cfg carrying only the two fields it reads.
    /// @param minCoverageWad The market's coverage multiple.
    /// @param debt The debt to secure.
    /// @param price The price to secure it at.
    /// @return The units the shipped gate demands.
    function requiredAt(uint256 minCoverageWad, uint256 debt, uint256 price) external pure returns (uint256) {
        Cfg memory c;
        c.p.minCoverageWad = minCoverageWad;
        c.unitScale = 1 << 96; // the FIXED frame every market carries, as `MarketInit` writes it
        return Borrower.requiredAt(c, debt, price);
    }
}

/// @title AceHighPriceCoverage
/// @notice The coverage gate at the TOP of the price range, where a Q96 atom price outgrows a plain `* 1e18`.
/// @notice `requiredAt` divides by `price * 1e18`, a product `FullMath` never saw, so above the boundary it panicked 0x11.
/// @notice A CREATOR MAY NAME ANY PRICE UP TO `Constants.MAX_PRICE`, so that panic sits inside the legal band.
/// @dev IT WAS `AceHighTickCoverage`, and the tick deletion made the reachability argument SHORTER, not weaker.
/// @dev The old one had to show a lender could rest above the boundary and that no lower tick dragged the floor
/// @dev down; a market now names one price at genesis, so the boundary is reachable by writing the number down.
/// @dev The boundary is `type(uint256).max / 1e18`, about 1.1579e59, against a ceiling of `1 << 224`, about 2.7e67.
/// @dev The fix is Uniswap's try-precise-then-fall-back shape, and the agreement tests here are its regression net.
contract AceHighPriceCoverageTest is WarpClock {
    uint256 internal constant MAXP = type(uint256).max / 1e18; // the largest price whose `* 1e18` still fits
    uint256 internal constant UNIT_SCALE = 1 << 96; // the hub's fixed price frame, one constant for every market

    uint256 internal constant DEPOSIT = 5_000e6;
    uint256 internal constant PRINCIPAL = 2_500e6;
    uint256 internal constant COLL = 1_000e18;

    address internal alice = address(0xA11CE); // the lender
    address internal borrower = address(0xB0B);

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    RequiredAtProbe internal probe;

    function setUp() public {
        _warpTo(1_000_000);
        probe = new RequiredAtProbe();
    }

    /* ============ 1. the two spellings are ONE function, which is what the fix rests on ============ */

    /// @notice The fallback branch the fix takes above the boundary: ceil twice instead of once.
    /// @dev `ceil(ceil(x / a) / b) == ceil(x / (a * b))` for positive integers, so there is no seam to land on.
    /// @dev It is total wherever `price > (minCoverageWad * debt) / 2 ** 160`, which the whole high branch clears.
    /// @param k The market's coverage multiple.
    /// @param debt The debt to secure.
    /// @param price The price to secure it at.
    /// @return The same units the precise spelling returns.
    function _fallback(uint256 k, uint256 debt, uint256 price) internal pure returns (uint256) {
        if (debt == 0) return 0;
        if (price == 0) return type(uint256).max;
        return FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(k * debt, UNIT_SCALE, price), 1, 1e18);
    }

    /// @notice The shipped gate and the fallback agree AT the boundary and one wei under it.
    /// @notice Debts are sized so the answer is millions of units, not the degenerate one both spellings floor to.
    /// @dev PINS THE IDENTITY the fix rests on: if these ever diverge, branching on the price changes behaviour.
    function test_TheTwoSpellingsAgreeAtTheExactOverflowBoundary() public view {
        uint256[3] memory ks = [Constants.MIN_COVERAGE_WAD, 1.4e18, Constants.MAX_COVERAGE_WAD];
        uint256[3] memory debts = [uint256(1e30), 1.04e36, 7e36];

        for (uint256 i; i < ks.length; i++) {
            for (uint256 j; j < debts.length; j++) {
                assertEq(probe.requiredAt(ks[i], debts[j], MAXP), _fallback(ks[i], debts[j], MAXP), "the two spellings diverged AT the boundary");
                assertEq(probe.requiredAt(ks[i], debts[j], MAXP - 1), _fallback(ks[i], debts[j], MAXP - 1), "the two spellings diverged one wei under it");
            }
        }
        assertGt(_fallback(1.4e18, 1.04e36, MAXP), 1, "fixture: the boundary debts must produce a discriminating answer");
    }

    /// @notice One wei ABOVE the boundary only the fallback computes, and it does so without a jump.
    /// @dev The upper neighbour: the precise spelling cannot be asked here at all, which IS the defect.
    /// @dev Non-increasing across the step is the whole continuity claim -- a seam would show as a rise.
    function test_TheFallbackIsTotalAndContinuousOneWeiAboveTheBoundary() public pure {
        uint256 k = 1.4e18;
        uint256 debt = 1.04e36;

        uint256 at = _fallback(k, debt, MAXP);
        uint256 above = _fallback(k, debt, MAXP + 1);
        assertGt(at, 0, "fixture: the boundary answer must be non-zero or continuity says nothing");
        assertLe(above, at, "the fallback rose as the price rose: the branch introduced a seam");
        assertGe(above + 1, at, "and it fell by more than one unit across a one-wei price step");
    }

    /// @notice The two spellings agree at every price and debt where BOTH can be computed at all.
    /// @notice Price sweeps by DECADE, so the fuzzer visits small prices rather than only enormous ones.
    /// @dev `1e3` is the low bound because the fallback's inner ceil must fit a uint256 at these debts.
    /// @dev This is the regression net: the two spellings must stay ONE function wherever both can be asked at all.
    function testFuzz_TheTwoSpellingsAgreeWhereverBothCompute(uint256 kSeed, uint256 debtSeed, uint256 expSeed, uint256 priceSeed) public view {
        uint256 k = bound(kSeed, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        uint256 debt = bound(debtSeed, 1, 1e30);
        uint256 e = bound(expSeed, 3, 59);
        uint256 lo = 10 ** e;
        uint256 price = bound(priceSeed, lo, e == 59 ? MAXP : 10 ** (e + 1) - 1);

        assertEq(probe.requiredAt(k, debt, price), _fallback(k, debt, price), "the fallback branch is not the same function as the precise one");
    }

    /// @notice The two degenerate answers survive the rewrite: no debt needs nothing, no price fails closed.
    /// @dev Both are ordering-sensitive, and a branch added above them is exactly where that order gets lost.
    function testFuzz_TheZeroAnswersAreUnchangedByEitherSpelling(uint256 kSeed, uint256 priceSeed) public view {
        uint256 k = bound(kSeed, Constants.MIN_COVERAGE_WAD, Constants.MAX_COVERAGE_WAD);
        uint256 price = bound(priceSeed, 0, MAXP);

        assertEq(probe.requiredAt(k, 0, price), 0, "a zero debt needs no units at any price");
        assertEq(_fallback(k, 0, price), 0, "and the fallback must agree, price zero included");
        assertEq(probe.requiredAt(k, 1, 0), type(uint256).max, "a real debt at an unknown price fails closed");
        assertEq(_fallback(k, 1, 0), type(uint256).max, "and the fallback must fail closed identically");
    }

    /* ============ 2. the boundary is INSIDE the band a creator may legally name ============ */

    /// @notice The severity claim, and under one price it is arithmetic rather than a search over a grid.
    /// @dev Genesis admits any price in `[1, MAX_PRICE]`, so a boundary under the ceiling is nameable by writing it.
    function test_TheOverflowBoundaryPriceIsInsideTheAdmissibleBand() public {
        emit log_named_uint("first price whose `price * 1e18` overflows", MAXP + 1);
        emit log_named_uint("the genesis ceiling on a market's price   ", Constants.MAX_PRICE);

        assertLt(MAXP + 1, Constants.MAX_PRICE, "a creator can name a price above the boundary");
    }

    /// @notice THE PROPERTY: more collateral is never required as the price it is valued at rises.
    /// @notice Swept by DECADE across the whole admissible band, from one atom to the genesis ceiling.
    /// @dev This went RED on the unbranched gate: the probe died partway up, at the price it reports.
    /// @dev The probe is external so the sweep names the price it died on instead of taking a bare panic 0x11.
    function test_RequiredAtNeverRisesAsPriceRisesAcrossTheWholeAdmissibleBand() public {
        uint256 debt = 1e24;
        uint256 prev = type(uint256).max;
        uint256 died;
        bool broke;

        for (uint256 p = 1; p <= Constants.MAX_PRICE; p = p > Constants.MAX_PRICE / 2 ? Constants.MAX_PRICE + 1 : p * 2) {
            (bool ok, uint256 got) = _tryRequiredAt(1.4e18, debt, p);
            if (!ok) {
                (died, broke) = (p, true);
                break;
            }
            assertLe(got, prev, "requiredAt rose as the price rose");
            prev = got;
        }

        if (broke) emit log_named_uint("requiredAt reverted at price", died);
        assertFalse(broke, "requiredAt is not total over the admissible band: `price * 1e18` overflowed inside it");
    }

    /* ============ 3. the same break, reached through the hub by a legal market ============ */

    /// @notice A market CREATED above the boundary takes a draw without panicking.
    /// @notice Either outcome is acceptable -- a funded loan, or a refusal that names itself -- never a bare panic.
    /// @dev This went RED on the unbranched gate: `_fund` reached `coverageLine` at that price and overflowed.
    /// @dev NO WALK TO ARRANGE ANY MORE. The old repro had to rest at one tick and prove nothing dragged the
    /// @dev funding floor below the boundary; the floor IS the market's price now, so naming it is the whole setup.
    function test_ADrawInAMarketPricedAboveTheBoundaryNeverPanics() public {
        (Ace a, MockERC20 q, bytes32 m, AceReader r) = _recordlessMarketAt(MAXP + 1);
        MockERC20 c = MockERC20(a.idToMarketParams(m).collateral);

        q.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        q.approve(address(a), DEPOSIT);
        a.deposit(m, DEPOSIT);
        vm.stopPrank();

        c.mint(borrower, COLL);
        vm.startPrank(borrower);
        c.approve(address(a.POSITION_MANAGER()), COLL);
        try a.open(m, COLL, PRINCIPAL, 0, borrower, OFF) returns (uint256 loanId) {
            assertEq(r.fundingFloor(m, loanId), MAXP + 1, "the loan funded at the market's own price");
        } catch (bytes memory err) {
            emit log_named_bytes("open reverted with", err);
            assertFalse(_isPanic(err), "a legal market priced past the boundary bricked the draw with a bare arithmetic panic");
        }
        vm.stopPrank();
    }

    /// @notice The same draw in a market priced UNDER the boundary still opens, which bounds the severity to liveness.
    /// @dev Without this the repro above could be read as "high prices are broken", when only the top slice is.
    /// @dev It also proves the fixture funds at all, so a red above is the arithmetic and not a mis-sized market.
    function test_TheSameDrawUnderTheBoundaryPriceOpensNormally() public {
        (Ace a, MockERC20 q, bytes32 m, AceReader r) = _recordlessMarketAt(MAXP);
        MockERC20 c = MockERC20(a.idToMarketParams(m).collateral);

        q.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        q.approve(address(a), DEPOSIT);
        a.deposit(m, DEPOSIT);
        vm.stopPrank();

        c.mint(borrower, COLL);
        vm.startPrank(borrower);
        c.approve(address(a.POSITION_MANAGER()), COLL);
        uint256 loanId = a.open(m, COLL, PRINCIPAL, 0, borrower, OFF);
        vm.stopPrank();

        assertEq(r.loan(loanId).debt, PRINCIPAL, "a price just under the boundary funds the whole draw");
        assertEq(r.fundingFloor(m, loanId), MAXP, "and the funding floor is that price");
    }

    /* ================================= fixtures ================================= */

    /// @dev `requiredAt` through the external door, reporting a revert instead of taking the test down with it.
    /// @param k The coverage multiple.
    /// @param debt The debt to secure.
    /// @param price The price to secure it at.
    /// @return ok False when the shipped arithmetic reverted.
    /// @return got The units it demanded, zero when it did not answer.
    function _tryRequiredAt(uint256 k, uint256 debt, uint256 price) internal view returns (bool ok, uint256 got) {
        try probe.requiredAt(k, debt, price) returns (uint256 res) {
            return (true, res);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Whether revert data is a bare `Panic(uint256)` rather than a refusal the hub names.
    /// @param err The revert data.
    /// @return True for a panic.
    function _isPanic(bytes memory err) internal pure returns (bool) {
        return err.length >= 4 && err[0] == 0x4e && err[1] == 0x48 && err[2] == 0x7b && err[3] == 0x71; // `Panic(uint256)`
    }

    /// @dev A record-less market at a named price, so `restRefusal` admits it whatever the draw cap would say.
    function _recordlessMarketAt(uint256 price) internal returns (Ace a, MockERC20 q, bytes32 m, AceReader r) {
        q = new MockERC20("Quote", "Q", 6);
        MockERC20 c = new MockERC20("Coll", "C", 18);
        MarketParams memory p = AceFixtures.marketParams(address(q), address(c));
        p.price = price;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (a, m, r) = (d.ace, d.id, d.read);
    }
}
