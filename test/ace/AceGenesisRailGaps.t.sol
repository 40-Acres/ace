// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AllInFeeSpec} from "../utils/AllInFeeSpec.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceGenesisRailGaps
/// @notice The rail gaps the `MarketParams` sweep found, and the rails that closed them.
/// @notice A railed gap pins ONE boundary from BOTH sides: the config refused, by name, and the one admitted.
/// @notice Every rail here is IMMUTABLE at broadcast, so a rail that stops binding must fail loudly.
/// @notice `test_Rail_` pins a gap that is CLOSED: the rail refuses that config by name, and the row is green.
/// @notice `test_Control_` pins the admitted side of the same boundary, so a rail cannot pass by refusing everything.
/// @notice GAP 3 carries NEITHER prefix: its rail was retired, so what survives there is the coverage property alone.
/// @dev THE SHAPE, in every one: a scalar safe alone and unsafe in a PRODUCT with an unchecked neighbour.
/// @dev `MarketInit` did this correctly for the deleverage channel and nowhere else.
/// @dev WHAT EACH RAILED GAP DID before its rail landed is on its refusal row: unreachable now, so that is the only evidence left.
contract AceGenesisRailGapsTest is WarpClock {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal record;
    MockPersistenceRecord internal gapRecord; // the wide-gap market's own record, so a row can pin it distressed

    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal cranker = address(0xCAFE);

    uint256 internal constant U128 = type(uint128).max; // the tick cash cap, at `Ladder.creditCash`
    uint256 internal constant PS = 1000; // ACE's origination share, re-spelled: a spec that imports proves nothing
    uint256 internal T0; // this pair's par rung, assigned in setUp: par is not a compile-time value
    int24 internal constant SPACING = 60;
    int24 internal constant TOP_TICK = 600_000; // high in the v4 range, so a wide-scale gate stays representable

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        T0 = AceFixtures.priceAt(address(usdc), address(coll), 0);
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
    }

    /// @dev A minimal band-off market; each row overrides only the scalar pair it is about.
    function _base() internal view returns (MarketParams memory p) {
        p.quote = address(usdc);
        p.collateral = address(coll);
        p.record = address(record);
        p.minCoverageWad = 1.4e18;
        p.baseBps = 40;
        p.minTenor = 7 days;
        p.maxTenor = 7 days;
        p.minDebt = 1e6;
        p.settleBountyBps = 50;
        /// @dev Sole tenancy: genesis refuses a zero lender, and every row here means to trip a DIFFERENT rail.
        p.lender = lender; // the rig deposits as this address, so the market has to name it
        p.price = PriceFrame.priceAt(address(usdc), address(coll), 0); // and a zero PRICE is refused for the same reason
    }

    /// @dev The lender ticket, re-spelled. WAS `ceil(minDebt / maxClaimTicks)`, since a draw could reach the
    /// @dev floor from many lots; one bucket means the smallest bookable deposit IS `minDebt`.
    function _minLot(uint256 minDebt) internal pure returns (uint256) {
        return minDebt;
    }

    function _reject(MarketParams memory p, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        ace.createMarket(p);
    }

    /* ============ GAP 1: `minDebt` against the market's uint128 cash cap ============ */

    /// @notice A market whose smallest legal deposit beats the cash cap is REFUSED at genesis.
    /// @notice `deposit` refuses anything under `minDebt` and `creditCash` anything over the cap.
    /// @notice The two ends were railed separately and their RELATION was not, so both refused every amount.
    /// @dev BEFORE THE RAIL: this exact config CREATED, passed every rail, and admitted no deposit ever.
    /// @dev A deposit at the floor reverted `CashCapped`; anything the cap allowed reverted `BelowMinDebt`.
    /// @dev THE QUESTION IS UNCHANGED and the arithmetic is simpler: the rail once divided `minDebt` by the
    /// @dev claim cap to get a per-tick ticket, and with one bucket the floor IS `minDebt`, compared directly.
    function test_Rail_AFloorOverTheCashCapIsRefused() public {
        MarketParams memory p = _base();
        p.minDebt = U128 + 1; // one wei past the cap
        assertGt(_minLot(p.minDebt), U128, "fixture: the floor really does sit past the cap");
        _reject(p, "min debt over cash cap");

        p = _base();
        p.minDebt = 32 * (U128 + 1); // far past it, so the rail is not an artefact of the boundary
        _reject(p, "min debt over cash cap");
    }

    /// @notice CONTROL: the floor AT the cap exactly is admitted, and the deposit that size really lands.
    /// @dev So the row above is measuring the relation between the two rails and never the fixture.
    function test_Control_TheFloorAtTheCapExactlyIsAdmittedAndDeposits() public {
        MarketParams memory p = _base();
        p.minDebt = U128;
        assertEq(_minLot(p.minDebt), U128, "fixture: the floor is the cap exactly");
        bytes32 id = ace.createMarket(p);

        usdc.mint(lender, U128);
        vm.startPrank(lender);
        usdc.approve(address(ace), U128);
        ace.deposit(id, U128);
        vm.stopPrank();
        assertEq(ace.restingOf(id), U128, "the floor at the cap really is depositable, and rests whole");
    }

    /// @notice THE REPAIRED PROPERTY, end to end at the extreme: an accepted market can fund one minimum loan.
    /// @notice It needs BOTH rails: a floor the cash cap can hold, and that floor really depositable.
    /// @dev Run at the very edge the rail admits, so a loosening of either bound fails here rather than quietly.
    /// @dev WAS "maximum fragmentation": 32 lots of exactly the cap, because a draw could span 32 ticks. One
    /// @dev bucket at the cap is the same extreme with nothing to fragment, and it settles covered at tenor.
    function test_Rail_TheLargestAdmittedFloorStillFundsOneMinimumLoan() public {
        MarketParams memory p = _base();
        p.minDebt = U128;
        bytes32 id = ace.createMarket(p);

        usdc.mint(lender, p.minDebt);
        vm.startPrank(lender);
        usdc.approve(address(ace), p.minDebt);
        ace.deposit(id, p.minDebt);
        vm.stopPrank();

        /// @dev The coverage line at the market's price, which IS the floor the loan comes to rest on,
        /// @dev plus a whole token of slack so the row is not a boundary test of the line itself.
        uint256 units = FullMath.mulDivRoundingUp(p.minCoverageWad * p.minDebt, read.marketState(id).unitScale, T0 * 1e18) + 1e18;
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        uint256 loanId = ace.open(id, units, p.minDebt, p.minTenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(read.claimCount(id, loanId), 1, "the draw holds one claim: there is no fragmentation left to maximise");

        _warpBy(8 days);
        vm.recordLogs();
        vm.prank(cranker);
        ace.forceClose(loanId);
        assertEq(_badDebt(), 0, "and the loan at the largest admitted floor settles covered");
    }

    /* ============ GAP 2: `minDebt` against the origination fee's own rounding ============ */

    /// @notice A market whose smallest admitted draw would pay the borrower NOTHING is refused at genesis.
    /// @notice The #277 rail bounds the fee's SHARE at a quarter of the draw; a share cannot bound one wei.
    /// @notice `ceil(1 * n / d)` is 1 at every rate the share rail admits, so the whole draw became fee.
    /// @dev BEFORE THE RAIL: `minDebt == 1` was admitted, and `previewOpen(principal = 1)` reported payout 0.
    /// @dev The floor rate and the steepest the share rail admits are both refused, so this is not an artefact of one rate.
    function test_Rail_AMinDebtTheFeeWouldEatIsRefused() public {
        MarketParams memory p = _base();
        p.minDebt = 1;
        p.baseBps = Constants.MIN_BASE_BPS; // the cheapest legal rate, so nothing here is an extreme fee
        _reject(p, "min debt under fee");

        p = _base();
        p.minDebt = 1;
        p.baseBps = _shareRailedBaseBps(p.minTenor, p.maxTenor); // the top of the band is the SHARE rail's now, not a band of its own
        _reject(p, "min debt under fee");
    }

    /// @notice The boundary is exactly one wei wide, at EVERY rate and term the share rail admits.
    /// @notice `minDebt == 1` always refuses and `minDebt == 2` always creates, which is what makes it a rail.
    /// @dev Derived, not measured: `ceil(P r) < P` with `r <= 1/4` fails only at `P == 1`, so `2` is the floor.
    /// @dev The rate is drawn UNDER the share rail, or the earlier `fee bps too high` would be what refuses.
    function testFuzz_Rail_OneWeiIsRefusedAndTwoIsAdmittedAtEveryAdmissibleRate(uint256 a, uint256 b, uint256 c) public {
        MarketParams memory p = _base();
        p.minTenor = uint64(bound(a, 1 hours, 30 days));
        p.maxTenor = p.minTenor * uint64(bound(b, 1, 8));
        p.baseBps = bound(c, Constants.MIN_BASE_BPS, _shareRailedBaseBps(p.minTenor, p.maxTenor));

        p.minDebt = 1;
        _reject(p, "min debt under fee");

        p.minDebt = 2;
        assertTrue(ace.createMarket(p) != bytes32(0), "and two wei is admitted at the same rate, so the floor is exactly two");
    }

    /// @dev The largest rate the SHARE rail admits at this term multiple, clamped to genesis's representational ceiling.
    /// @dev Re-spelled from the rail's own inequality via `AllInFeeSpec`, never read off `LoanMath`.
    /// @dev THE CLAMP NEVER BINDS: the share cap tops out at 2272 on a flat market, under the 2500 genesis names.
    function _shareRailedBaseBps(uint64 minTenor, uint64 maxTenor) private pure returns (uint256) {
        uint256 cap = (AllInFeeSpec.FEE_SHARE_BPS * 10000 * 10000 * uint256(minTenor)) / (10000 * uint256(maxTenor) * (10000 + PS));
        return cap > Constants.MAX_FEE_SHARE_BPS ? Constants.MAX_FEE_SHARE_BPS : cap;
    }

    /// @notice CONTROL: the smallest market the rail admits pays its smallest draw something, which is the point.
    /// @dev REPLACES `test_Control_TwoWeiPaysOut`, which quoted a two-wei draw on a `minDebt == 1` market.
    /// @dev That market is now illegal outright, so its premise died with the behaviour the rail removed.
    /// @dev This asserts the same arithmetic on the smallest market that still exists, which is the live claim.
    function test_Control_TheSmallestAdmittedMarketPaysItsSmallestDrawSomething() public {
        MarketParams memory p = _base();
        p.minDebt = 2;
        p.baseBps = Constants.MIN_BASE_BPS;
        bytes32 id = ace.createMarket(p);
        _deposit(id, 1_000e6);

        Borrower.Quote memory q = ace.previewOpen(id, 1e18, p.minDebt, p.minTenor, borrower, OpenBounds(0, 0, 0));
        assertEq(q.fee, 1, "the ceil still takes a whole wei as fee at the market minimum");
        assertGt(q.payout, 0, "but the draw the market admits now leaves the borrower something");
    }

    /* ============ GAP 3: the decimal gap UP, whose rail the constant price frame retired ============ */

    /// @notice At the WIDEST admitted gap the worst loan every neighbouring rail admits settles, and settles covered.
    /// @notice Maximum fragmentation, every tick at its cash cap, the keeper bounty at its ceiling.
    /// @notice NO refusal row pairs with this one: the up-gap rail is gone, so there is no boundary left to pin.
    /// @dev 18 IS the widest now: `MAX_DECIMALS` bounds each end and nothing bounds the DIFFERENCE.
    /// @dev The retired rail was read off the bounty's `debt * settleBountyBps * unitScale`, which no longer carries the gap.
    function test_TheWidestGapSettlesTheWorstAdmittedLoan() public {
        uint256 loanId = _worstLoan(18);
        _warpBy(8 days);
        vm.recordLogs();
        vm.prank(cranker);
        ace.forceClose(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "the widest gap the absolute bound leaves settles the worst loan");
        assertEq(_badDebt(), 0, "and settles covered, so the row is not passing on a written-down close");
    }

    /// @dev A market whose quote carries ZERO decimals, so `collateralDecimals` alone IS the gap under test.
    /// @dev `minDebt` sits above the fee floor, or the earlier `min debt under fee` rail is what would refuse.
    function _gapParams(uint8 collDecimals) private returns (MarketParams memory p) {
        MockERC20 q = new MockERC20("Quote0", "Q0", 0);
        MockERC20 c = new MockERC20("Coll", "C", collDecimals);
        gapRecord = new MockPersistenceRecord(address(q), address(c));
        gapRecord.setMinPrice(type(uint256).max);

        p = _base();
        p.quote = address(q);
        p.collateral = address(c);
        /// @dev HIGH IN THE RANGE, which the units derivation below already assumed. It used to be a tick a
        /// @dev deposit picked; the price is a creation param now, so the market itself has to name it.
        p.price = PriceFrame.priceAtStep(TOP_TICK);
        p.record = address(gapRecord);
        p.minCoverageWad = Constants.MIN_COVERAGE_WAD;
        p.minDebt = 1000;
        p.settleBountyBps = Constants.MAX_SETTLE_BOUNTY_BPS; // the sliver's second factor, at its own rail
    }

    /// @dev The WORST loan every neighbouring rail admits: the market at its OWN CASH CAP, funded to the wei.
    /// @dev WAS 32 lots of that cap, because a draw could span 32 ticks and each bucket carried the cap alone.
    /// @dev One market holds ONE balance and the cap bounds the whole of it, so the worst admissible depth is
    /// @dev that number ONCE -- the same extreme with nothing left to fragment, and a 32x deposit is refused.
    /// @dev Funded high in the range, so the coverage the gate demands stays a representable number.
    /// @dev The collateral is derived from the gate's own inequality with 20% over, never a hand-picked literal.
    function _worstLoan(uint8 collDecimals) private returns (uint256 loanId) {
        MarketParams memory p = _gapParams(collDecimals);
        bytes32 id = ace.createMarket(p);
        MockERC20 q = MockERC20(p.quote);
        MockERC20 c = MockERC20(p.collateral);
        uint256 debt = U128;

        q.mint(lender, debt);
        vm.startPrank(lender);
        q.approve(address(ace), debt);
        ace.deposit(id, debt);
        vm.stopPrank();

        uint256 units = FullMath.mulDivRoundingUp(p.minCoverageWad * debt, read.marketState(id).unitScale, PriceFrame.priceAtStep(TOP_TICK) * 1e18) * 12 / 10;
        c.mint(borrower, units);
        vm.startPrank(borrower);
        c.approve(address(positionManager), units);
        loanId = ace.open(id, units, debt, p.minTenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(read.claimCount(id, loanId), 1, "fixture: the draw really did fund");
    }

    /* ============ shared ============ */

    /// @dev The bad debt a settlement reported, read off the log rather than derived from the loan.
    function _badDebt() private returns (uint256 bad) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ForceClosed(uint256,uint256,uint256,address)");
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics[0] != sig) continue;
            seen = true;
            (, bad) = abi.decode(logs[i].data, (uint256, uint256));
        }
        assertTrue(seen, "fixture: the hub must have emitted ForceClosed for the read to mean anything");
    }

    function _deposit(bytes32 id, uint256 amount) private {
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(ace), amount);
        ace.deposit(id, amount);
        vm.stopPrank();
    }
}
