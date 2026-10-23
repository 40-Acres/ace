// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @title AceAskDriftFuzz
/// @notice Bunni-class confirmation for the settled-pot ask: N tiny `buyInventory` fills against ONE pot, at three decimal frames.
/// @notice Every fill delivers and is charged at least the exact all-in value of what left; the aggregate never undercuts one fill of the same units.
/// @notice The synthetic headroom tracks the pot to the unit, so the lender's in-kind exit can always take whatever is left.
/// @notice The ask's stranded remainder is bounded by ONE rounding unit: under a quote atom when a unit is worth less, at most one unit when it is worth more.
/// @dev MUTANT: `Lender._askLeg`'s total fee `ceilDiv` -> floor; the per-fill exact-value bound kills it.
/// @dev A fill fee of 37 bps is coprime to 10000, so the fee division leaves a remainder on every gross not a multiple of 10000.
abstract contract AceAskDriftFuzzBase is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal quote;
    MockERC20 internal coll;
    bytes32 internal id;
    uint256 internal price;
    uint256 internal loanId;
    uint256 internal pot0;

    address internal lender = AceFixtures.LENDER;
    address internal borrower = address(0xB0B);
    address internal buyer = address(0xB0FF);
    address internal keeper = address(0xCAFE);

    uint256 internal constant S = 1 << 96;
    uint256 internal constant FEE = 37;

    /// @dev The sums a fill sequence leaves behind.
    struct Tally {
        uint256 units;
        uint256 paid;
        uint256 fills; // fills that delivered
        uint256 feeRemainders; // fills whose fee division left a remainder
    }

    function _cd() internal pure virtual returns (uint8);

    function _qd() internal pure virtual returns (uint8);

    function _one() internal pure returns (uint256) {
        return 10 ** _qd();
    }

    /// @dev Multiplies every amount in the fixture; the boundary witness needs a pot of about 1e26 units.
    function _size() internal pure virtual returns (uint256) {
        return 1;
    }

    function setUp() public {
        _warpTo(1_000_000);
    }

    /// @dev The market at `offset` steps over par, with a fill fee, and one loan settled into a pot whose ask is open.
    function _shape(int24 offset) internal {
        quote = new MockERC20("Quote", "Q", _qd());
        coll = new MockERC20("Collateral", "C", _cd());
        MockPersistenceRecord rec = new MockPersistenceRecord(address(quote), address(coll));
        rec.setMinPrice(type(uint256).max); // the sentinel: no ask floor, so the ask is the market's own price
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.price = AceFixtures.priceAt(address(quote), address(coll), offset);
        p.record = address(rec);
        p.baseBps = 1;
        p.settleBountyBps = 0;
        p.minDebt = 10 * _one();
        p.fillFeeBps = FEE;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        price = p.price;
        assertEq(read.marketState(id).unitScale, S, "PREMISE: the atom frame's scale");
        assertEq(ace.idToMarketParams(id).fillFeeBps, FEE, "PREMISE: the fill fee is live");

        uint256 one = _one() * _size();
        quote.mint(lender, 6000 * one);
        vm.startPrank(lender);
        quote.approve(address(ace), type(uint256).max);
        ace.deposit(id, 6000 * one);
        vm.stopPrank();
        uint256 units = FullMath.mulDiv(12_000 * one, S, price) + 1;
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        loanId = ace.open(id, units, 5000 * one, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        _warpBy(7 days + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        _warpTo(read.inventoryAskOpensAt(loanId));
        pot0 = read.invPotOf(id, loanId);
        assertGt(pot0, 1000, "PREMISE: settlement left a pot deep enough for every fill");
        assertEq(_headroom(), pot0, "PREMISE: the synthetic headroom is the pot, unit for unit");
        quote.mint(buyer, type(uint128).max);
        vm.prank(buyer);
        quote.approve(address(ace), type(uint256).max);
    }

    function _headroom() internal view returns (uint256) {
        MarketState memory s = read.marketState(id);
        return s.cumulativeBackedBurns - s.netSyntheticOutflow;
    }

    /// @dev The least budget that delivers a unit: two quote atoms when a unit is worth under one, else two units at the all-in price.
    function _minBudget() internal view returns (uint256) {
        uint256 eff = price + (price * FEE + 9999) / 10000;
        uint256 two = FullMath.mulDivRoundingUp(2, eff, S);
        return two < 2 ? 2 : two + 1;
    }

    /// @dev Exact all-in value of `units` at the ask, times `S * 1e4`, so every comparison stays in integers.
    function _exact(uint256 units) internal view returns (uint256) {
        return units * price * (10000 + FEE);
    }

    /// @dev What ONE fill of `units` would be charged: the gross re-priced up, then the fee up.
    function _oneShot(uint256 units) internal view returns (uint256) {
        uint256 g = FullMath.mulDivRoundingUp(units, price, S);
        return g + (g * FEE + 9999) / 10000;
    }

    /// @dev One fill, checked against every ledger it touches.
    function _fill(Tally memory t, uint256 budget) internal {
        uint256 potB = read.invPotOf(id, loanId);
        uint256 hubB = quote.balanceOf(address(ace));
        uint256 owedB = read.poolOwed(id);
        uint256 collB = coll.balanceOf(buyer);
        vm.prank(buyer);
        (uint256 got, uint256 paid) = ace.buyInventory(loanId, budget, 0, buyer);
        assertGt(got, 0, "a fill at or over the least budget delivers");
        assertLe(paid, budget, "a fill never charges past its budget");
        assertEq(potB - read.invPotOf(id, loanId), got, "the pot fell by exactly what was delivered");
        assertEq(coll.balanceOf(buyer) - collB, got, "and the buyer holds exactly that");
        assertEq(quote.balanceOf(address(ace)) - hubB, paid, "the hub received exactly the charge");
        assertEq(read.poolOwed(id) - owedB, paid, "and credited the lender exactly the charge");
        assertEq(_headroom(), read.invPotOf(id, loanId), "the synthetic headroom still equals the pot");
        assertGe(paid * S * 10000, _exact(got), "a fill is never charged under the exact all-in value of what left");
        assertLt(paid * S * 10000, _exact(got) + 3 * S * 10000, "and over it by under three quote atoms");
        uint256 g = FullMath.mulDivRoundingUp(got, price, S);
        if ((g * FEE) % 10000 != 0) t.feeRemainders++;
        t.units += got;
        t.paid += paid;
        t.fills++;
    }

    /// @dev N fuzzed tiny fills, then the aggregate laws.
    function _drift(uint256 n, uint256 seed) internal returns (Tally memory t) {
        uint256 lo = _minBudget();
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _fill(t, lo + (r % (3 * lo)));
        }
        assertEq(t.fills, n, "every fill delivered: the fill count is exact");
        assertEq(pot0 - read.invPotOf(id, loanId), t.units, "the pot fell by the units the fills reported, summed");
        assertGe(t.paid, _oneShot(t.units), "buyers in aggregate never pay less than one fill of the same units");
        assertGe(t.paid * S * 10000, _exact(t.units), "nor less than the exact all-in value");
        emit log_named_uint("fills", t.fills);
        emit log_named_uint("aggregate charge over one shot, quote atoms", t.paid - _oneShot(t.units));
        emit log_named_uint("fills whose fee left a remainder", t.feeRemainders);
    }

    /// @dev Sweeps the ask until a fill delivers nothing, then bounds what is stranded.
    function _strand() internal returns (uint256 rem) {
        for (uint256 i; i < 6; ++i) {
            uint256 left = read.invPotOf(id, loanId);
            if (left == 0) return 0;
            uint256 budget = _oneShot(left) + 2;
            vm.prank(buyer);
            (uint256 got,) = ace.buyInventory(loanId, budget, 0, buyer);
            if (got == 0) break;
        }
        rem = read.invPotOf(id, loanId);
        emit log_named_uint("stranded units", rem);
        emit log_named_uint("one unit's value, quote atoms (floor)", price / S);
        assertTrue(rem * price < S || rem <= 1, "the ask strands at most one rounding unit: under a quote atom, or one collateral unit");
    }

    /// @dev The lender's in-kind exit takes whatever the ask left, exactly, and the cap never refuses it.
    function _redeemRest() internal {
        uint256 left = read.invPotOf(id, loanId);
        if (left == 0) return;
        uint256 before = coll.balanceOf(lender);
        vm.prank(lender);
        uint256 out = ace.redeemInKind(loanId, lender);
        assertEq(out, left, "the in-kind exit takes the whole remainder");
        assertEq(coll.balanceOf(lender) - before, left, "and delivers it");
        assertEq(read.invPotOf(id, loanId), 0, "leaving the pot empty");
        assertEq(_headroom(), 0, "and the synthetic headroom spent to the unit");
    }

    /// @notice N tiny fills at a fuzzed price, then both exits from the remainder: the lender's in kind, and the ask swept dry.
    function testFuzz_ManyTinyFills_NoDrift(uint256 nSeed, int24 offsetSeed, uint256 seed) public {
        _shape(int24(bound(int256(offsetSeed), -3000, 3000)));
        Tally memory t = _drift(bound(nSeed, 2, 50), seed);
        assertGt(t.feeRemainders, 0, "PREMISE: a fee division left a remainder, so a floored fee would have under-charged it");
        uint256 snap = vm.snapshotState();
        _redeemRest();
        vm.revertToState(snap);
        _strand();
        _redeemRest();
    }

    /// @notice Fifty fills at par's neighbour, pinned, so the measured overcharge is a fixed number a reader can check.
    function test_FiftyFillsOffPar_NoDrift() public {
        _shape(7);
        Tally memory t = _drift(50, 0xA5C);
        assertGt(t.feeRemainders, 0, "PREMISE: a fee division left a remainder");
        _strand();
        _redeemRest();
    }
}

/// @notice The shipped shape: 18-decimal collateral against a 6-decimal quote, a unit worth about 1e-12 of an atom.
contract AceAskDriftFuzzC18Q6Test is AceAskDriftFuzzBase {
    function _cd() internal pure override returns (uint8) {
        return 18;
    }

    function _qd() internal pure override returns (uint8) {
        return 6;
    }
}

/// @notice The inverted extreme: 0-decimal collateral against an 18-decimal quote, a unit worth about 1e18 atoms.
contract AceAskDriftFuzzC0Q18Test is AceAskDriftFuzzBase {
    function _cd() internal pure override returns (uint8) {
        return 0;
    }

    function _qd() internal pure override returns (uint8) {
        return 18;
    }
}

/// @notice The widest gap the other way: 18-decimal collateral against a 0-decimal quote, a unit worth about 1e-18 of an atom.
contract AceAskDriftFuzzC18Q0Test is AceAskDriftFuzzBase {
    function _cd() internal pure override returns (uint8) {
        return 18;
    }

    function _qd() internal pure override returns (uint8) {
        return 0;
    }
}

/// @title AceAskEffPriceBoundary
/// @notice The budget rail's one live boundary: `effPrice` ceils the fee so that `total <= stableIn`, and a FLOORED one breaks it.
/// @notice The break needs a fill near `1e-4 * askPrice / phi` quote atoms, where `phi` is the fee fraction `effPrice` drops, so tiny fills never reach it.
/// @dev The witness search mirrors the FLOORED arithmetic on purpose: it finds a budget, and the assertion is the hub's own rail.
/// @dev MUTANT: `Lender._askLeg` `effPrice`'s `ceilDiv` -> floor; the drift rows cannot see it, this row kills it.
contract AceAskEffPriceBoundaryTest is AceAskDriftFuzzBase {
    function _cd() internal pure override returns (uint8) {
        return 18;
    }

    function _qd() internal pure override returns (uint8) {
        return 6;
    }

    function _size() internal pure override returns (uint256) {
        return 20_000; // a 100M-quote loan: its pot is about 1e26 units, over the witness's take
    }

    /// @dev The first step over par whose ask leaves a fee fraction of at least 0.99 for a floor to drop.
    function _steepOffset() internal pure returns (int24 off) {
        int24 par = PriceFrame.parStep(6, 18);
        for (off = 0; off < 2000; ++off) {
            if ((PriceFrame.priceAtStep(par + off) * FEE) % 10000 >= 9900) return off;
        }
        revert("no steep offset in range");
    }

    /// @dev What a floored-effPrice ask would charge at `budget`, and the units it would take.
    function _flooredCharge(uint256 budget) internal view returns (uint256 total) {
        uint256 effFloor = price + (price * FEE) / 10000;
        uint256 take = FullMath.mulDiv(budget, S, effFloor);
        if (take > pot0) take = pot0;
        uint256 gross0 = FullMath.mulDiv(take, price, S);
        uint256 deliver = FullMath.mulDiv(gross0, S, price);
        uint256 g = FullMath.mulDivRoundingUp(deliver, price, S);
        total = g + (g * FEE + 9999) / 10000;
    }

    /// @notice At the one budget where a floored `effPrice` would charge an atom past it, the real ask stays inside it.
    function test_TheBudgetRailHoldsWhereAFlooredEffPriceWouldOvercharge() public {
        _shape(_steepOffset());
        assertGe((price * FEE) % 10000, 9900, "PREMISE: the ask's fee fraction is at least 0.99");
        uint256 budget;
        for (uint256 k; k < 32; ++k) {
            uint256 g = 5e13 - (5e13 % 10000) + 2973 + k * 10000; // 2973 * 37 = 1 mod 1e4: the fee's fraction is one ten-thousandth
            uint256 t = FullMath.mulDivRoundingUp(g, S, price);
            uint256 b = FullMath.mulDivRoundingUp(t, price + (price * FEE) / 10000, S);
            if (t <= pot0 && _flooredCharge(b) > b) {
                budget = b;
                break;
            }
        }
        assertGt(budget, 0, "PREMISE: a budget exists where a floored effPrice charges past it");
        vm.prank(buyer);
        (uint256 got, uint256 paid) = ace.buyInventory(loanId, budget, 0, buyer);
        emit log_named_uint("witness budget, quote atoms", budget);
        emit log_named_uint("what a floored effPrice would charge", _flooredCharge(budget));
        emit log_named_uint("what the ask charged", paid);
        assertGt(got, 0, "LIVENESS: the witness fill delivered");
        assertLe(paid, budget, "the ask never charges past its budget, even at the boundary a floored effPrice breaks");
        assertGe(paid * S * 10000, _exact(got), "and is still never under the exact all-in value");
    }
}
