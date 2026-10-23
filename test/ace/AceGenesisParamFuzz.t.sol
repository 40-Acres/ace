// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {AllInFeeSpec} from "../utils/AllInFeeSpec.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceGenesisParamFuzz
/// @notice `MarketParams` itself under fuzz, over the band `MarketInit` accepts rather than one pinned fixture.
/// @notice Assertion 1: every ACCEPTED config is operable -- deposit, draw, repay and settle all terminate.
/// @notice Assertion 2: every REJECTED config is refused by a NAMED reason, never an arithmetic panic.
/// @notice Assertion 3: the coverage gate and the solvency identity hold across the whole admitted band.
/// @notice Assertion 5: a draw's payout is non-zero at the smallest principal the market admits.
/// @notice Assertion 6 is DISCHARGED: it bounded a ladder walk, and a market names one price.
/// @notice Assertion 7: genesis writes are a pure function of `p`, and no interviewed seam can write at all.
/// @dev WHY. `createMarket` is permissionless on immutable bytecode with no governance, so these rails are
/// @dev the whole distance between a creator and a market outside the validated envelope.
/// @dev Every existing suite starts from one hand-chosen config and explores only the states IT admits,
/// @dev which is why the two known rail gaps were both found by reading rather than by fuzzing.
/// @dev The shape hunted here is COMBINATIONS: a scalar safe alone and unsafe in a product with a neighbour.
contract AceGenesisParamFuzzTest is WarpClock {
    Ace internal ace;
    PositionManager internal positionManager;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal cranker = address(0xCAFE);

    uint256 internal constant PS = 1000; // ACE's origination share, re-spelled: a spec that imports proves nothing
    uint256 internal constant REF = 2 << 96; // the record's windowed min sits here, above tick 0, so the draw cap never gates
    int24 internal constant T0 = 0; // priceAt(0) IS the frame's one-to-one price, and 0 sits on every legal spacing grid
    uint256 internal constant DRIVABLE_MAX_DEBT = 1e30; // the operability arm's ceiling; the brick above it has its own row

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(REF);
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        vm.label(address(ace), "Ace");
    }

    /* ====================== the sampler: one seed, the whole band ====================== */

    /// @dev One independent draw per field, so no two fields are correlated by sharing a slice of the seed.
    function _rand(uint256 seed, uint256 k) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, k)));
    }

    /// @dev Inclusive both ends. Every range below STRADDLES its rail, so both arms of each rail are sampled.
    function _pick(uint256 seed, uint256 k, uint256 lo, uint256 hi) private pure returns (uint256) {
        return lo + (_rand(seed, k) % (hi - lo + 1));
    }

    /// @dev The lender ticket, re-spelled rather than imported: this is the brick predicate's own oracle.
    /// @dev IT WAS `minDebt` DIVIDED ACROSS the funded ticks, because a draw could reach `minDebt` from many
    /// @dev lots. A market has one price, so the smallest lot that can carry the floor IS the floor.
    function _minLot(uint256 minDebt) internal pure returns (uint256) {
        return minDebt;
    }

    /// @dev The whole config from one seed. The SEAMS are pinned; this issue is about the scalars.
    function _draw(uint256 seed) internal view returns (MarketParams memory p) {
        p.quote = address(usdc);
        p.collateral = address(vault);
        p.record = address(record);
        p.lender = lender; // sole tenancy is PINNED like the seams: this issue is about the scalars
        _drawGrid(p, seed);
        _drawLadder(p, seed);
        _drawKeeperBudget(p, seed);
        _drawDeleverage(p, seed);
    }

    /// @dev The market's PRICE and its tenor band, plus the rate whose PRODUCT with the term multiple is railed.
    /// @dev IT WAS THE TICK GRID AND THE TENOR GRID, and neither grid exists: a market names one price and a
    /// @dev tenor band, with no spacing for a creator to get wrong and no rung count for a walk to budget.
    /// @dev The price is drawn as an OFFSET FROM PAR so the operable arm stays reachable at every seed, and one
    /// @dev draw in eight is pushed past `MAX_PRICE` so the ceiling's refusal arm is sampled as well.
    function _drawGrid(MarketParams memory p, uint256 seed) private view {
        int24 off = int24(int256(_pick(seed, 1, 0, 24000)) - 12000); // ~0.3x to ~3.3x par
        p.price = _rand(seed, 4) % 8 == 0 ? Constants.MAX_PRICE + 1 : AceFixtures.priceAt(p.quote, p.collateral, off);
        p.minTenor = uint64(_pick(seed, 2, 0, 30 days));
        p.maxTenor = uint64(_pick(seed, 3, p.minTenor, p.minTenor + 60 days));
        if (_rand(seed, 5) % 8 == 0 && p.minTenor != 0) p.maxTenor = p.minTenor - 1; // inverts the band, one draw in eight
        p.baseBps = _pick(seed, 6, 0, _shareRailedBaseBps(p.minTenor, p.maxTenor) + 2);
    }

    /// @dev The largest rate the SHARE rail admits at this term multiple, clamped to genesis's representational ceiling.
    /// @dev Sampling to it keeps the accept rate high while leaving the whole admissible band reachable.
    /// @dev Re-spelled from the rail's own inequality via `AllInFeeSpec`, never read off `LoanMath`.
    /// @dev THE CLAMP NEVER BINDS on a real shape -- the share cap tops out at 2272 -- and it is here for `maxTenor == 0`.
    function _shareRailedBaseBps(uint64 minTenor, uint64 maxTenor) private pure returns (uint256) {
        if (maxTenor == 0) return Constants.MAX_FEE_SHARE_BPS;
        uint256 cap = (AllInFeeSpec.FEE_SHARE_BPS * 10000 * 10000 * uint256(minTenor)) / (10000 * uint256(maxTenor) * (10000 + PS));
        return cap > Constants.MAX_FEE_SHARE_BPS ? Constants.MAX_FEE_SHARE_BPS : cap;
    }

    /// @dev The ladder floors and the coverage multiple; `minDebt` is sampled by EXPONENT, into the brick region.
    function _drawLadder(MarketParams memory p, uint256 seed) private pure {
        p.minCoverageWad = _pick(seed, 10, 1e18, Constants.MAX_COVERAGE_WAD + 1e18);
        uint256 e = _pick(seed, 12, 0, 48);
        p.minDebt = e == 0 ? 0 : 10 ** e + _pick(seed, 13, 0, 9);
        p.settleBountyBps = _pick(seed, 14, 0, Constants.MAX_SETTLE_BOUNTY_BPS + 2);
    }

    /// @dev The keeper budget; every range straddles its rail.
    /// @dev NO WINDOWS HERE any more: they left `MarketParams`, so genesis has nothing to draw or refuse.
    /// @dev The ask is off one draw in two, the protocol default; an ask-off draw keeps its fee one time in four, for the pairing's refusal arm.
    function _drawKeeperBudget(MarketParams memory p, uint256 seed) private pure {
        p.deleverageFloorEpsBps = _pick(seed, 20, 0, Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS + 2);
        p.fillFeeBps = _pick(seed, 21, 0, Constants.MAX_FILL_FEE_BPS + 1); // its own absolute rail; no ratio to eps binds it
        p.inventoryAsk = _rand(seed, 22) % 2 == 0;
        if (!p.inventoryAsk && _rand(seed, 23) % 4 != 0) p.fillFeeBps = 0;
    }

    /// @dev The decline channel, off one draw in three, so the off-channel lie-guard is sampled too.
    /// @dev Off, eps and target go to zero bar one draw in eight each: the guard's refusal arm is sampled without starving the accept arm.
    function _drawDeleverage(MarketParams memory p, uint256 seed) private pure {
        if (_rand(seed, 30) % 3 == 0) {
            p.deleverageStopBps = _rand(seed, 31) % 4 == 0 ? 1 : 0;
            if (_rand(seed, 36) % 8 != 0) p.deleverageFloorEpsBps = 0; // one draw in eight keeps its drawn eps
            if (_rand(seed, 37) % 8 == 0) p.deleverageTargetBps = 1; // and one in eight declares a target
            return;
        }
        p.deleverageBandBps = _pick(seed, 32, Constants.MIN_DELEVERAGE_BAND_BPS - 500, 10001);
        p.deleverageTargetBps = _pick(seed, 33, p.deleverageBandBps, 10001);
        p.deleverageStopBps = _pick(seed, 34, p.deleverageBandBps / 2, p.deleverageBandBps);
        p.deleverageProtocolBps = _pick(seed, 35, 0, Constants.MAX_DELEVERAGE_PROTOCOL_BPS + 2);
    }

    /* ====================== assertion 2: every refusal is a NAMED one ====================== */

    /// @notice Every config `createMarket` REJECTS is rejected by a reason string, never by an arithmetic panic.
    /// @notice An underflow, a division by zero or a bare revert deeper in the call is a rail defect, not a refusal.
    /// @dev The `minDebt` sampler reaches 1e48 here, so the brick region is INSIDE this sweep rather than beside it.
    /// @dev `Error(string)` is 0x08c379a0 and `Panic(uint256)` is 0x4e487b71; a bare `revert()` returns nothing.
    function testFuzz_Genesis_EveryRefusalIsNamed(uint256 seed) public {
        MarketParams memory p = _draw(seed);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
        if (ok) return;
        assertGe(ret.length, 4, _why("a refusal with no returndata at all", p));
        bytes4 sel = bytes4(ret);
        assertTrue(sel != bytes4(0x4e487b71), _why("an arithmetic panic instead of a named refusal", p));
        assertEq(sel, bytes4(0x08c379a0), _why("a refusal that is not Error(string)", p));
        assertGt(bytes(abi.decode(_tail(ret), (string))).length, 0, _why("an empty reason string", p));
    }

    /// @dev Strips the four-byte selector so the payload decodes on its own.
    function _tail(bytes memory ret) private pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = ret[i + 4];
        }
    }

    /// @dev The scalars that reach a failure, spelled into the message so a red run names its own counterexample.
    function _why(string memory what, MarketParams memory p) private pure returns (string memory) {
        return string.concat(
            what,
            " | price=",
            vm.toString(p.price),
            " k=",
            vm.toString(p.minCoverageWad),
            " base=",
            vm.toString(p.baseBps),
            " tenor=",
            vm.toString(uint256(p.minTenor)),
            "..",
            vm.toString(uint256(p.maxTenor)),
            " minDebt=",
            vm.toString(p.minDebt),
            " eps=",
            vm.toString(p.deleverageFloorEpsBps)
        );
    }

    /// @notice ANTI-VACUITY. A sweep whose every draw is refused asserts nothing, and would still go green.
    /// @notice So the sampler is measured directly: how many configs genesis takes, and how many are drivable.
    /// @dev Deterministic, not fuzzed, so a sampler that quietly stops reaching the accept arm fails by name.
    /// @dev The counts are logged as well as bounded, so a drop is visible before it crosses the bound.
    function test_Sampler_ReachesBothArmsOfTheRails() public {
        uint256 accepted;
        uint256 drivable;
        for (uint256 s = 1; s <= 200; s++) {
            MarketParams memory p = _draw(s);
            (bool ok,) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
            if (!ok) continue;
            accepted++;
            if (_drivable(p)) drivable++;
        }
        emit log_named_uint("configs genesis accepted, of 200", accepted);
        emit log_named_uint("of those, drivable end to end", drivable);
        assertGt(accepted, 20, "the sampler must reach the ACCEPT arm, or assertions 1, 3 and 5 never run");
        assertGt(200 - accepted, 20, "and the REJECT arm, or assertion 2 never runs");
        assertGt(drivable, 10, "and enough of the accepts must be drivable to exercise the loan life");
    }

    /// @notice THE OFF-CHANNEL LIE-GUARD AS AN ORACLE: a band-off draw is admitted only with stop, cut, target and eps all zero.
    /// @notice And the guard's own refusal lands only on a band-off draw that set one of them.
    /// @dev The named-refusal fuzz samples this arm but asks only that a refusal HAS a name, so a loosened guard passed it.
    /// @dev Deterministic like the sampler above, so each arm is counted and a draw that stops reaching one fails by name.
    function test_Sampler_ABandOffDrawIsAdmittedOnlyWithEveryDialZero() public {
        uint256 admitted;
        uint256 guarded;
        bytes32 guard = keccak256(abi.encodeWithSignature("Error(string)", "deleverage off but dials set"));
        for (uint256 s = 1; s <= 200; s++) {
            MarketParams memory p = _draw(s);
            if (p.deleverageBandBps != 0) continue;
            bool dialSet = p.deleverageStopBps != 0 || p.deleverageProtocolBps != 0 || p.deleverageTargetBps != 0 || p.deleverageFloorEpsBps != 0;
            (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
            if (ok) {
                assertFalse(dialSet, _why("a band-off market was admitted with a dial set", p));
                admitted++;
            } else if (keccak256(ret) == guard) {
                assertTrue(dialSet, _why("the lie-guard refused a band-off market with every dial zero", p));
                guarded++;
            }
        }
        emit log_named_uint("band-off draws admitted, of 200", admitted);
        emit log_named_uint("band-off draws the lie-guard refused, of 200", guarded);
        assertGt(admitted, 5, "the sampler must reach the band-off ACCEPT arm"); // 20 at the time of writing
        assertGt(guarded, 5, "and the lie-guard's REFUSAL arm"); // 12 at the time of writing
    }

    /// @notice THE ASK PAIRING AS AN ORACLE: an ask-off draw is admitted only with no fill fee.
    /// @notice And the pairing's own refusal lands only on an ask-off draw that set one, inside the fee's ceiling.
    /// @dev The ceiling is asked first, so an over-ceiling fee on an ask-off draw is the ceiling's refusal and never this one.
    /// @dev Deterministic like the two samplers above, so each arm is counted and a draw that stops reaching one fails by name.
    function test_Sampler_AnAskOffDrawIsAdmittedOnlyWithNoFillFee() public {
        uint256 admitted;
        uint256 guarded;
        bytes32 guard = keccak256(abi.encodeWithSignature("Error(string)", "ask off but fill fee set"));
        for (uint256 s = 1; s <= 200; s++) {
            MarketParams memory p = _draw(s);
            (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
            if (p.inventoryAsk) {
                assertTrue(keccak256(ret) != guard, _why("the pairing refused a market that has the ask", p));
                continue;
            }
            if (ok) {
                assertEq(p.fillFeeBps, 0, _why("an ask-off market was admitted with a fill fee set", p));
                admitted++;
            } else if (keccak256(ret) == guard) {
                assertGt(p.fillFeeBps, 0, _why("the pairing refused an ask-off market with no fill fee", p));
                assertLe(p.fillFeeBps, Constants.MAX_FILL_FEE_BPS, _why("the pairing answered before the fee's own ceiling", p));
                guarded++;
            }
        }
        emit log_named_uint("ask-off draws admitted, of 200", admitted);
        emit log_named_uint("ask-off draws the pairing refused, of 200", guarded);
        assertGt(admitted, 5, "the sampler must reach the ask-off ACCEPT arm");
        assertGt(guarded, 5, "and the pairing's REFUSAL arm");
    }

    /// @notice THE CEILING ANSWERS FIRST, across the whole sampled band: an ask-off draw with an over-ceiling fee is never the pairing's refusal.
    /// @dev AIMED, because the sampler above meets that draw about once in five hundred, so its own ceiling check never met one.
    /// @dev Every draw is forced to the one corner; the refusal may be the ceiling's or an earlier rail's, and the ceiling's is counted.
    function test_Sampler_AnOverCeilingFeeOnAnAskOffDrawIsTheCeilingsRefusal() public {
        uint256 ceilinged;
        bytes32 pairing = keccak256(abi.encodeWithSignature("Error(string)", "ask off but fill fee set"));
        bytes32 ceiling = keccak256(abi.encodeWithSignature("Error(string)", "fill fee too high"));
        for (uint256 s = 1; s <= 200; s++) {
            MarketParams memory p = _draw(s);
            p.inventoryAsk = false;
            p.fillFeeBps = Constants.MAX_FILL_FEE_BPS + 1;
            (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
            assertFalse(ok, _why("a fee over the ceiling was admitted", p));
            assertTrue(keccak256(ret) != pairing, _why("the pairing answered before the fee's own ceiling", p));
            if (keccak256(ret) == ceiling) ceilinged++;
        }
        emit log_named_uint("over-ceiling ask-off draws the ceiling refused, of 200", ceilinged);
        assertGt(ceilinged, 100, "the aimed draw must reach the ceiling, or the ordering is unwitnessed");
    }

    /* ====================== the tenor floor's refusal arm, sampled densely ====================== */

    /// @notice Every `minTenor` under `MIN_TENOR_FLOOR` is refused by THAT name, and the floor admits an otherwise valid market.
    /// @notice The whole-band sampler draws `minTenor` over thirty days, so it lands under the floor about once in 260,000 draws.
    /// @dev Seven draws in eight sit in `[0, MIN_TENOR_FLOOR]`; the eighth reaches thirty days, so the admit arm runs past the floor too.
    /// @dev Under the floor `maxTenor` roams sixty days, where the fee rail would refuse as well, so the name is the floor's by order.
    /// @dev At or over it the market is flat, so the fee rail cancels the term and every other field is the admissible baseline.
    function testFuzz_Genesis_UnderTheTenorFloorTheRefusalIsTheFloors(uint256 seed) public {
        MarketParams memory p = _spanParams();
        uint64 hi = _rand(seed, 40) % 8 == 0 ? uint64(30 days) : Constants.MIN_TENOR_FLOOR;
        uint64 t = uint64(_pick(seed, 41, 0, hi));
        if (t < Constants.MIN_TENOR_FLOOR) {
            (p.minTenor, p.maxTenor) = (t, uint64(_pick(seed, 42, t, uint256(t) + 60 days)));
            vm.expectRevert(bytes("min tenor under floor"));
            ace.createMarket(p);
            return;
        }
        (p.minTenor, p.maxTenor) = (t, t);
        bytes32 id = ace.createMarket(p);
        assertEq(ace.idToMarketParams(id).minTenor, t, _why("at or over the floor the market is admitted with the tenor it was given", p));
    }

    /* ============ assertions 1, 3 and 5: an accepted market is operable and safe ============ */

    /// @notice Every market `createMarket` ACCEPTS funds a draw, repays it whole and settles the next one at tenor.
    /// @notice The coverage gate and the five-pot solvency identity are asserted at every step of that life.
    /// @notice The payout is asserted NON-ZERO at the smallest principal the market admits, which is assertion 5.
    /// @dev The one region skipped is the one this driver cannot fund, not one the rails leave open.
    /// @dev It funds from ONE tick, so a `minDebt` past the tick cash cap needs the 32-lot walk instead.
    /// @dev That walk is driven at its own extreme by `AceGenesisRailGaps`, so the region is covered elsewhere.
    function testFuzz_Genesis_AnAcceptedMarketIsOperable(uint256 seed) public {
        MarketParams memory p = _draw(seed);
        (bool ok, bytes memory id) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
        if (!ok) return;
        if (!_drivable(p)) return;
        _operate(abi.decode(id, (bytes32)), p);
    }

    /// @dev The upper bound is the SINGLE-TICK deposit this driver makes; the lower one is now dead weight.
    /// @dev `min debt under fee` refuses everything under two wei at genesis, so no accept can reach it.
    /// @dev Kept anyway: it costs nothing and it is the assertion that catches that rail silently loosening.
    function _drivable(MarketParams memory p) private pure returns (bool) {
        return p.minDebt >= 2 && p.minDebt <= DRIVABLE_MAX_DEBT;
    }

    /// @dev Deposit, draw at the smallest legal principal, repay it whole, then draw again and settle at tenor.
    function _operate(bytes32 id, MarketParams memory p) private {
        uint256 principal = p.minDebt;
        _seedLadder(id, p, principal);
        uint256 a = _open(id, p, principal);
        _assertSolvency(id);
        _repayWhole(a);
        assertTrue(read.loan(a).closedAt != 0, _why("a repaid loan did not close", p));
        _assertSolvency(id);

        uint256 b = _open(id, p, principal);
        _warpTo(read.loan(b).expiry + 1); // one second past THIS loan's own expiry, not an assumed open time
        vm.prank(cranker);
        ace.forceClose(b);
        assertTrue(read.loan(b).closedAt != 0, _why("an expired loan did not settle", p));
        _assertSolvency(id);
    }

    /// @dev Two loans' worth of cash in the market, never under the derived ticket.
    function _seedLadder(bytes32 id, MarketParams memory p, uint256 principal) private {
        uint256 lot = _minLot(p.minDebt);
        uint256 dep = 2 * principal + 1;
        if (dep < lot) dep = lot;
        usdc.mint(lender, dep);
        vm.startPrank(lender);
        usdc.approve(address(ace), dep);
        ace.deposit(id, dep);
        vm.stopPrank();
    }

    /// @dev One draw at the market's own minimum, collateralized just past the coverage gate at tick 0.
    function _open(bytes32 id, MarketParams memory p, uint256 principal) private returns (uint256 loanId) {
        /// @dev SIZED OFF THE MARKET'S OWN PRICE. It was `k * principal / 1e6 + 1e18`, a constant that only
        /// @dev held while every market bid at par; the price is fuzzed across ~0.3x..3.3x par now, so a
        /// @dev par-shaped guess opens liquidatable at the low end of that range.
        uint256 units = FullMath.mulDivRoundingUp(p.minCoverageWad * principal, read.marketState(id).unitScale, p.price * 1e18) + 1e18;
        vault.mint(borrower, units);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), units);
        loanId = ace.open(id, units, principal, p.minTenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertLe(read.triggerPrice(loanId), read.fundingFloor(id, loanId), _why("a loan opened liquidatable at birth", p));
        uint256 fee = AllInFeeSpec.feeAllIn(principal, p.minTenor, p.baseBps, p.minTenor, PS);
        assertGt(principal, fee, _why("the smallest admitted draw pays out nothing", p));
    }

    /// @dev Full repayment, so the clean-close leg runs and the fee-escrow refund is exercised with it.
    function _repayWhole(uint256 loanId) private {
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    /// @dev The five-pot identity: every quote the hub holds is claimed by exactly one pot, at every step.
    function _assertSolvency(bytes32 id) private view {
        MarketState memory m = read.marketState(id);
        (uint256 resting,, uint256 owed) = read.poolOf(id); // the LENDER legs; one market here, so it spans nothing else
        uint256 pot;
        for (uint256 i = 1; i <= read.loanCount(); i++) {
            pot += read.feeEscrowOf(i);
        }
        assertEq(usdc.balanceOf(address(ace)), resting + m.protocolRevenue + pot + owed + m.quoteOwedTotal, "solvency identity");
    }

    /* ====================== assertion 6: DISCHARGED, there is no grid ====================== */

    /// @dev DELETED: `testFuzz_Genesis_EveryAdmittedSpacingCrossesTheWholeRange` and its `_spanParams` fixture.
    /// @dev It asked whether every `tickSpacing` genesis admitted left a draw able to WALK the whole v4 range
    /// @dev inside its word budget -- the hazard being a coarse grid whose scan ran out before reaching cash
    /// @dev that was really resting. A draw funds at the market's one price: there is no walk, no budget and no
    /// @dev spacing to admit. The range itself is still railed, at `MAX_PRICE`, and `AcePriceRail` pins both ends.

    /// @dev A plainly admissible market with the channel off. WAS `_spanParams(spacing)`, the deleted row's fixture;
    /// @dev assertion 7 uses it as a baseline the probe seams are swapped into, and never varied a grid.
    function _spanParams() private view returns (MarketParams memory p) {
        p.quote = address(usdc);
        p.collateral = address(vault);
        p.record = address(record);
        p.price = AceFixtures.priceAt(address(usdc), address(vault), 0);
        p.lender = lender;
        p.minCoverageWad = 1.4e18;
        p.baseBps = 40;
        p.minTenor = 7 days;
        p.maxTenor = 7 days;
        p.minDebt = 1e6;
        p.settleBountyBps = 50;
    }

    function _deposit(bytes32 id, uint256 amount) private {
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(ace), amount);
        ace.deposit(id, amount);
        vm.stopPrank();
    }

    /* ====================== assertion 7: genesis is pure in `p`, and cannot be reentered ====================== */

    /// forge-config: default.fuzz.runs = 24
    /// @notice Every write genesis makes is a pure function of `p`: the same params on two hubs agree exactly.
    /// @notice That is the property a reentrant `createMarket` would need, and it holds by construction.
    /// @dev `unitScale` is DERIVED from the pair's decimals, so it is asserted rather than assumed to agree.
    /// @dev A second hub is the only way to re-run genesis on the same preimage: a duplicate id reverts by rail.
    function testFuzz_Genesis_TheWritesArePureInTheParams(uint256 seed) public {
        MarketParams memory p = _draw(seed);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
        if (!ok) return;
        bytes32 id = abi.decode(ret, (bytes32));

        (Ace twin,) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        bytes32 twinId = twin.createMarket(p);
        assertEq(twinId, id, "the id is the hash of the params, so two hubs must agree on it");
        AceReader twinRead = new AceReader(address(twin));
        assertEq(twinRead.marketState(twinId).unitScale, read.marketState(id).unitScale, "and on the scale they derive from it");
        assertEq(keccak256(abi.encode(twin.idToMarketParams(twinId))), keccak256(abi.encode(ace.idToMarketParams(id))), "and on every stored field");
    }

    /// @notice The RECORD seam is interviewed under STATICCALL, so it cannot write and therefore cannot reenter.
    /// @notice Control first: the same probe admits while it writes nothing, so the refusal below is not vacuous.
    /// @dev The `ace-lending-review` on #287 asked for reentry to be tested rather than asserted, and this is it.
    /// @dev A seam that could write is a seam that could reenter `createMarket` before `M.p = p` is written.
    /// @dev Proven per seam, because the mutability lives on each interface and one of them could change alone.
    function test_Genesis_AnInterviewedRecordCannotWriteState() public {
        ProbeRecord probe = new ProbeRecord();
        MarketParams memory p = _spanParams();
        p.record = address(probe);
        assertTrue(ace.createMarket(p) != bytes32(0), "control: the probe record admits while it writes nothing");

        probe.setArmed(true);
        p.minDebt = 2e6; // a fresh preimage, so MarketExists cannot be what refuses the armed run
        vm.expectRevert();
        ace.createMarket(p);
    }
}

/// @notice A persistence record whose `supportsPair` WRITES when armed; genesis interviews it under STATICCALL.
/// @dev Non-view on purpose: the interface declares it `view`, so the caller staticcalls whatever the callee is.
contract ProbeRecord {
    bool public armed;
    uint256 public touched;

    uint256 public constant DEPTH_WINDOW = 0;
    uint256 public constant minGuaranteedSpan = 365 days;

    function setArmed(bool v) external {
        armed = v;
    }

    function supportsPair(address, address) external returns (bool) {
        if (armed) touched += 1;
        return true;
    }

    function minPriceOverWindow(address, address, uint256) external pure returns (uint256) {
        return 2e18;
    }

    function persistedBelow(address, address, uint256, uint256) external pure returns (bool) {
        return false;
    }

    /// @dev Three of the four reads `_requireAnswers` makes, `lastObserved` below; a record that cannot answer one is refused.
    function minPrice(address, address) external pure returns (uint256) {
        return 2e18;
    }

    function persistedBelowDistress(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function persistedBelowSettle(address, address, uint256) external pure returns (bool) {
        return false;
    }

    /// @dev The head read genesis now makes on every market that names a record, band armed or not.
    function lastObserved(address, address) external pure returns (uint256) {
        return 2e18;
    }
}
