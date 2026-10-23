// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {BufferBelowMin, PriceLowered} from "../../src/ace/hub/Borrower.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP8BufferNoDefenceBase
/// @notice Audit run 2026-09-13-670568 phase 8: what `minBufferBps` buys a borrower who consents to routing.
/// @notice The buffer reads `k * debt / (units * price)`, so a destination may lower `k` and `price` together and pass it.
/// @notice Premises pin the tightest buffer the home roll admits; measurements price what a stranger still takes at it.
/// @dev MEASUREMENTS, plus one RED row in the record-backed class. A red here is the finding; do not fix it here.
abstract contract AceP8BufferNoDefenceBase is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    address internal rec;
    bytes32 internal home;

    address internal alice = address(0xA11CE); // the home lender
    address internal mallory = address(0xBAD); // a keeper who stands up her own destination
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal constant DEPOSIT = 20_000e6;
    uint256 internal constant PRINCIPAL = 3_500e6; // k * LTV = 0.49 at the home price: an ordinary, well-margined loan
    uint256 internal constant COLL = 10_000e18; // worth 10,000 USDC at the home price
    uint16 internal constant FEE_CAP = 100; // 1% realized-rate ceiling; nonzero is the routing consent
    uint256 internal constant K_LOW = 1.05e18; // genesis's coverage floor

    function _newRecord() internal virtual returns (address);

    /// @notice Collateral a settlement of `debt` hands the market side at `price` and coverage `k`, by this class's rule.
    function _takenAt(uint256 debt, uint256 price, uint256 k) internal view virtual returns (uint256);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = _newRecord();
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(alice, 0, 0));
        (ace, pm, read, home) = (d.ace, d.positionManager, d.read, d.id);
        _rest(home, alice, DEPOSIT);
    }

    function _params(address lender, uint256 price, uint256 k) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = rec;
        p.lender = lender;
        if (price != 0) p.price = price;
        if (k != 0) p.minCoverageWad = k;
    }

    function _rest(bytes32 m, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    function _homePrice() internal view returns (uint256) {
        return ace.idToMarketParams(home).price;
    }

    function _homeK() internal view returns (uint256) {
        return ace.idToMarketParams(home).minCoverageWad;
    }

    /// @dev Past the incumbent's exclusive half of the roll window, before expiry.
    function _toOpenHalf(uint256 loanId) internal {
        uint64 w = MarketInit.autoRefinanceWindow(ace.idToMarketParams(ace.loanMarket(loanId)).minTenor);
        _warpTo(uint256(read.loan(loanId).expiry) - w / 4);
    }

    /// @dev The tenor is read BEFORE the prank: an external read in the argument list would consume it.
    function _arm(uint256 loanId, uint16 b) internal {
        uint64 tenor = read.loan(loanId).tenor;
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, tenor, b, FEE_CAP);
    }

    /// @dev Opens, arms with a placeholder buffer so the predicate answers, and warps into the open half.
    function _openArmed() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(home, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _arm(loanId, 1);
        _toOpenHalf(loanId);
    }

    function _successorPrincipal(uint256 loanId) internal view returns (uint256 p) {
        bool ok;
        (ok,, p) = ace.tryContinue(loanId);
        assertTrue(ok, "fixture: the home roll must be admissible");
    }

    /// @dev The largest whole-bps buffer the home successor clears: floor of `(price - trig) / price`.
    function _tightBuffer(uint256 principal) internal view returns (uint16) {
        uint256 trig = LoanMath.triggerPrice(principal, COLL, _homeK(), 1 << 96);
        return uint16(FullMath.mulDiv(_homePrice() - trig, 1e18, _homePrice()) / 1e14);
    }

    /// @dev The lowest destination price whose buffer clears `b` at coverage `k`: ceil(trig_k / (1 - b)).
    function _lowestPrice(uint256 principal, uint256 k, uint16 b) internal pure returns (uint256) {
        uint256 trig = LoanMath.triggerPrice(principal, COLL, k, 1 << 96);
        return FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - uint256(b) * 1e14);
    }

    /// @dev Arms at the tightest buffer the home roll admits, routes into a market at coverage `k` and its lowest price, starves it.
    function _routeStarveSettle(uint256 k) internal returns (bool routed, uint256 pot, uint256 homeMeasure, uint256 price, uint256 debt) {
        uint256 loanId = _openArmed();
        uint256 p2 = _successorPrincipal(loanId);
        _arm(loanId, _tightBuffer(p2));
        price = _lowestPrice(p2, k, _tightBuffer(p2));
        bytes32 dst = ace.createMarket(_params(mallory, price, k));
        _rest(dst, mallory, p2);
        vm.prank(mallory);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.refinanceByPolicyTo, (loanId, dst)));
        if (!ok) return (false, 0, 0, price, 0);
        uint256 newId = abi.decode(ret, (uint256));
        debt = read.debtOf(newId);
        _warpTo(read.loan(newId).expiry);
        vm.prank(mallory);
        ace.forceClose(newId);
        (routed, pot, homeMeasure) = (true, read.invPotOf(dst, newId), _takenAt(debt, _homePrice(), _homeK()));
    }

    /// @notice PREMISE: there is exactly one tightest buffer per roll. At it the home roll is admitted; one bps more refuses it.
    function test_Premise_TheTightestBufferTheHomeRollAdmits() public {
        uint256 loanId = _openArmed();
        uint256 p2 = _successorPrincipal(loanId);
        uint16 b = _tightBuffer(p2);
        _arm(loanId, b);
        (bool ok,,) = ace.tryContinue(loanId);
        assertTrue(ok, "at the tightest buffer the home roll is admitted");
        _arm(loanId, b + 1);
        (bool okMore, bytes4 why,) = ace.tryContinue(loanId);
        assertFalse(okMore, "one bps tighter refuses the borrower's own home roll");
        assertEq(why, BufferBelowMin.selector, "and it is the buffer leg that refuses it");
        emit log_named_uint("tightest buffer the home roll admits, bps", b);
    }

    /// @notice CONTROL: at the tightest buffer, the price-only lever at the home coverage takes no more than the home measure.
    function test_Control_AtTheTightBuffer_ThePriceLeverAtHomeCoverageIsClosed() public {
        uint256 loanId = _openArmed();
        uint256 p2 = _successorPrincipal(loanId);
        uint16 b = _tightBuffer(p2);
        _arm(loanId, b);
        uint256 price = _lowestPrice(p2, _homeK(), b);
        bytes32 dst = ace.createMarket(_params(mallory, price, _homeK()));
        _rest(dst, mallory, p2);
        assertLt(price, _homePrice(), "fixture: the destination bids under the price the borrower chose");

        /// @dev INVERTED BY THE FIX. This row proved the BUFFER closed the price lever, to bps resolution.
        /// @dev The price leg now closes it outright, so the bound no longer rides on what the borrower set.
        /// @dev The fixture above is untouched and still differs from home in lender and price alone, which is
        /// @dev what makes the refusal attributable to that leg: the coverage here is the home coverage.
        (bool ok, bytes4 why,) = ace.tryContinueTo(loanId, dst);
        assertFalse(ok, "a destination under the home price is refused whatever buffer the borrower named");
        assertEq(why, PriceLowered.selector, "and the price leg is what refuses it, by name");
    }

    // CLOSED (PriceLowered): TheCoverageDownLeverTakes measured 13334 bps of the home measure record-backed, 1172.184305 USDC of excess at b* = 5078 bps.

    /// @notice MEASURE: the tightest buffer is a ONE-TERM policy. The successor's own home roll refuses it, with cash resting.
    function test_Measure_TheTightBufferEndsTheChainAfterOneTerm() public {
        uint256 loanId = _openArmed();
        _arm(loanId, _tightBuffer(_successorPrincipal(loanId)));
        vm.prank(keeper);
        uint256 newId = ace.refinanceByPolicy(loanId);
        _toOpenHalf(newId);
        (bool ok, bytes4 why,) = ace.tryContinue(newId);
        assertFalse(ok, "the successor's home roll is refused");
        assertEq(why, BufferBelowMin.selector, "by the buffer the borrower set to be safe against routing");
        assertGt(read.restingOf(home), read.debtOf(newId) * 2, "and not for want of cash");
        _warpTo(read.loan(newId).expiry);
        uint256 n = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(newId);
        assertEq(read.loanCount(), n, "the armed policy settled at its second expiry");
        emit log_named_decimal_uint("units taken at the second expiry", read.invPotOf(home, newId), 18);
    }
}

// The recordless instance is deleted: a recordless market cannot arm (`ArmNeedsRecord`), so no keeper can route its loan.

/// @title AceP8BufferNoDefenceRecordBacked
/// @notice The record-backed class takes `debt / price`, which reads no `k`: lowering `k` lowers the admissible price.
contract AceP8BufferNoDefenceRecordBackedTest is AceP8BufferNoDefenceBase {
    function _newRecord() internal override returns (address) {
        return address(new MockPersistenceRecord(address(usdc), address(coll)));
    }

    function _takenAt(uint256 debt, uint256 price, uint256) internal pure override returns (uint256) {
        return FullMath.mulDivRoundingUp(debt, 1 << 96, price);
    }

    // CLOSED (PriceLowered): TheTightBufferBoundsTheCoverageDownLever measured 10000 bps of the home measure recordless, 0.387023 USDC of excess.

    /// @notice RED: at the tightest buffer the home roll admits, a routed borrower never forfeits more than the home measure.
    /// @dev Fix-agnostic: a refused route passes, and a successor that rolls leaves no pot.
    function test_RED_AtTheTightestBuffer_ARoutedBorrowerNeverForfeitsMoreThanTheHomeMeasure() public {
        (bool routed, uint256 pot, uint256 homeMeasure,,) = _routeStarveSettle(K_LOW);
        if (!routed) return;
        assertLe(pot, (homeMeasure * 10005) / 10000 + 2, "the buffer admitted a lower coverage and a lower price together");
    }
}
