// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {CashCapped} from "../../src/ace/hub/Lender.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceMarketCashCap
/// @notice THE BOUND `MarketState.cash <= type(uint128).max`, and the genesis rail that bounds `maxTenor` with it.
/// @notice Narrowings in the hub rest on the first, so nothing may accumulate resting cash past that width.
/// @notice Nothing enforced it: `creditCash` added the FULL uint256, so N deposits accumulated past the width freely.
/// @notice The refusal lands on the DEPOSITOR at the door; a cast at the draw would brick every draw on a full market.
/// @dev IT WAS `AceTickCashCap`, and the cap MOVED SCOPE with the storage it guards: `Bucket.cash` per tick became
/// @dev `MarketState.cash` per market. Every row below is the same property re-asked one level up.
/// @dev ONE ROW INVERTED, and it is the one worth reading twice: the cap used to be PER TICK, so the error's own
/// @dev remedy was "rest at a neighbouring tick" and a market-scoped cap would have been the BUG. There are no
/// @dev neighbours now, so the remedy is a different MARKET and the row asserts the market scope it used to refuse.
/// @dev SOLE TENANCY also collapses the two depositors these rows used: one lender rests here, so a pair of legal
/// @dev deposits summing past the width is that one lender twice. The property is unchanged; the cast is smaller.
/// @dev The pair runs the widest down gap genesis admits, which is what makes `unitScale` one and the cap legible.
contract AceMarketCashCapTest is Test {
    Ace internal ace;
    AceReader internal read;
    MockERC20 internal quote; // 18 decimals: the widest `MAX_DECIMALS` admits
    MockERC20 internal collateral; // 0, so the gap is the widest admitted and `unitScale` lands on one
    bytes32 internal mid;

    address internal alice = AceFixtures.LENDER; // the market's ONE lender: sole tenancy admits nobody else

    uint256 internal constant HALF = uint256(1) << 127; // two of these are the smallest pair that accumulates past the width
    uint256 internal constant WALL = uint256(type(uint128).max);
    uint256 internal constant ORDINARY = 10e36; // ten tokens of a 36-decimal quote: the control amount
    uint256 internal constant FLOOR = 10e6; // the fixture's `minDebt`, which is the deposit floor at both doors

    function setUp() public {
        vm.warp(1_000_000);
        quote = new MockERC20("Eighteen Decimal Quote", "Q18", 18);
        collateral = new MockERC20("Zero Decimal Collateral", "C0", 0);
        ace = AceFixtures.newAce();
        mid = ace.createMarket(_params());
        read = new AceReader(address(ace));
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(quote), address(collateral));
        p.record = address(0);
        p.baseBps = 1;
        p.settleBountyBps = 0;
        p.minDebt = FLOOR;
    }

    /// @dev `maxTenor` named, everything else the baseline, so the genesis rows differ in exactly one field.
    function _tenorParams(uint64 maxTenor) internal view returns (MarketParams memory p) {
        p = _params();
        p.minTenor = maxTenor;
        p.maxTenor = maxTenor;
    }

    function _fund(address who, uint256 amt) internal {
        quote.mint(who, amt);
        vm.prank(who);
        quote.approve(address(ace), amt);
    }

    function _deposit(uint256 amt) internal {
        _fund(alice, amt);
        vm.prank(alice);
        ace.deposit(mid, amt);
    }

    // ---- 1. the market cash cap, at the deposit ----

    /// @notice THE CONTROL. Without it every refusal below could pass for the wrong reason.
    function test_Control_AnOrdinaryDepositIsAdmissible() public {
        _deposit(ORDINARY);
        assertEq(ace.restingOf(mid), ORDINARY, "the baseline deposit really does land");
    }

    /// @notice THE REGRESSION ROW. Two legal deposits, each inside a uint256, sum past the market's width.
    /// @notice Without the bound the second lands silently, leaving `cash` past 2^128 with every stamp still narrowing.
    function test_Deposit_RefusedWhenMarketCashWouldExceedUint128() public {
        _deposit(HALF);
        assertEq(ace.restingOf(mid), HALF, "guard: the first half landed whole, so the second is what is under test");

        _fund(alice, HALF);
        vm.prank(alice);
        vm.expectRevert(CashCapped.selector);
        ace.deposit(mid, HALF);

        assertEq(ace.restingOf(mid), HALF, "the refused deposit left the market exactly where it was");
    }

    /// @notice The boundary itself is ADMITTED: the cap is `> type(uint128).max`, never `>=`.
    /// @dev An off-by-one here refuses a legal lender, which is the one cost the guard must not carry.
    function test_Deposit_AdmittedAtExactlyUint128Max() public {
        _deposit(HALF);
        _deposit(HALF - 1);
        assertEq(ace.restingOf(mid), WALL, "the widest representable market must be reachable");
    }

    /// @notice ONE DOOR, not two: a single over-wide deposit is refused by name, not by an OZ downcast.
    /// @dev A SafeCast selector is indistinguishable from a full market's, so a lender could not tell them apart.
    function test_Deposit_SingleOversizeRevertsCashCapped() public {
        uint256 assets = WALL + 1;
        _fund(alice, assets);
        vm.prank(alice);
        vm.expectRevert(CashCapped.selector);
        ace.deposit(mid, assets);
    }

    /// @notice The cap bites on the smallest step past the wall, which is the smallest legal deposit.
    /// @dev The named rows above jump the wall by 2^127; this walks up to it, so a guard loose by any margin fails.
    function test_Deposit_TheCapBitesOnTheSmallestAdmissibleStepOver() public {
        _deposit(WALL - FLOOR);
        _deposit(FLOOR);
        assertEq(ace.restingOf(mid), WALL, "landing exactly ON the width is admitted");

        /// @dev WAS ONE WEI. The deposit floor is `minDebt` ITSELF now -- it was `ceil(minDebt / maxClaimTicks)`
        /// @dev and derived far below it -- so a one-wei leg is refused `BelowMinLot` before the cap is reached
        /// @dev and the row would pass for the wrong reason. The SMALLEST ADMISSIBLE deposit is the floor, and
        /// @dev on a market sitting exactly on the wall every admissible deposit is one past it.
        _fund(alice, FLOOR);
        vm.prank(alice);
        vm.expectRevert(CashCapped.selector);
        ace.deposit(mid, FLOOR);
        assertEq(ace.restingOf(mid), WALL, "the smallest admissible deposit past it is refused, and the market is left untouched");
    }

    /// @notice THE INVERTED ROW: the cap is PER MARKET, so a full market's remedy is a DIFFERENT market.
    /// @notice Its ancestor asserted the opposite -- per TICK -- because the error's remedy was a neighbouring tick.
    /// @dev The same lender may run a second market in the same quote, and its cash is capped independently.
    /// @dev What is NOT independent is their pooled `resting`, which spans both; the cap is on the market's own cash.
    function test_Deposit_TheCapIsPerMarketNotPerLender() public {
        _deposit(HALF);
        _fund(alice, HALF);
        vm.prank(alice);
        vm.expectRevert(CashCapped.selector);
        ace.deposit(mid, HALF);

        MarketParams memory p = _params();
        p.minDebt = FLOOR + 1; // one field apart, so this is a DIFFERENT id and therefore a different market
        bytes32 other = ace.createMarket(p);

        _fund(alice, HALF);
        vm.prank(alice);
        ace.deposit(other, HALF);

        assertEq(ace.restingOf(other), HALF, "the remedy works: a second market takes the same deposit whole");
        assertEq(ace.restingOf(mid), HALF, "while the refused market is exactly where it was");
    }

    /// @notice The cap reads LIVE cash: an exit lowers it, and the room freed takes the deposit the full market refused.
    /// @dev A guard kept against a high-water mark, or a monotone counter, would refuse that refill forever.
    function test_Deposit_AdmittedAgainAfterAWithdrawFreesRoom() public {
        _deposit(HALF);
        _deposit(HALF - 1);
        assertEq(ace.restingOf(mid), WALL, "guard: the market starts at the widest it can hold");

        _fund(alice, FLOOR);
        vm.prank(alice);
        vm.expectRevert(CashCapped.selector);
        ace.deposit(mid, FLOOR);

        vm.prank(alice);
        ace.withdraw(mid, FLOOR, alice, 0);
        assertEq(ace.restingOf(mid), WALL - FLOOR, "the exit lowered the market by exactly what it paid out");

        _deposit(FLOOR);
        assertEq(ace.restingOf(mid), WALL, "and the freed room is admissible again");
    }

    /// @notice THE PROPERTY, fuzzed: a deposit lands if and only if the market's RESULTING cash fits the width.
    /// @dev The named rows pin points on the wall; this pins the rule between them, in both directions at once.
    function testFuzz_Deposit_AdmittedIffTheSumFitsUint128(uint256 firstSeed, uint256 secondSeed) public {
        uint256 first = bound(firstSeed, FLOOR, WALL);
        uint256 second = bound(secondSeed, FLOOR, WALL);
        _deposit(first);

        bool fits = first + second <= WALL;
        _fund(alice, second);
        vm.prank(alice);
        if (!fits) vm.expectRevert(CashCapped.selector);
        ace.deposit(mid, second);

        assertEq(ace.restingOf(mid), fits ? first + second : first, "the market moves exactly when the sum fits, never otherwise");
        assertLe(ace.restingOf(mid), WALL, "and never outruns the width every draw-side stamp narrows it to");
    }

    /// @notice THE SEQUENCE PROPERTY: eight deposits, each admitted iff it fits, the width re-asserted after every leg.
    /// @notice The invariant campaign cannot do this job -- its deposit bounds sit far below 2^128.
    /// @dev Legs are bounded at 2^126, so eight of them CAN straddle the wall; `admitted` fails the run if none landed.
    function testFuzz_Deposit_TheMarketNeverOutrunsUint128AcrossASequence(uint256[8] memory seeds) public {
        uint256 admitted;
        for (uint256 i; i < seeds.length; i++) {
            uint256 a = bound(seeds[i], FLOOR, uint256(1) << 126);
            bool fits = ace.restingOf(mid) + a <= WALL;
            _fund(alice, a);
            vm.prank(alice);
            if (!fits) vm.expectRevert(CashCapped.selector);
            ace.deposit(mid, a);
            if (fits) admitted++;
            assertLe(ace.restingOf(mid), WALL, "the market outran the width mid-sequence");
        }
        assertGt(admitted, 0, "guard: every leg was refused, so the sequence proved nothing");
    }

    // ---- 2. the genesis rail on `maxTenor` ----

    /// @notice THE REGRESSION ROW: refuse the market at genesis, not the lender at the door.
    /// @notice Nothing else bounds `maxTenor` -- `minTenor == maxTenor` satisfies every span rail at any width.
    /// @dev IT OUTLIVED ITS ORIGINAL REASON, which was `Bucket.horizon`'s uint40, and is kept as a sanity bound.
    /// @dev One `require` on a permissionless creation path, unfixable after broadcast, is worth keeping either way.
    function test_Genesis_RefusesMaxTenorAboveUint40() public {
        MarketParams memory p = _tenorParams(uint64(type(uint40).max) + 1);
        vm.expectRevert(bytes("max tenor too long"));
        ace.createMarket(p);
    }

    /// @notice The boundary itself is ADMITTED, so the rail cannot be an off-by-one that refuses a legal term.
    function test_Genesis_AdmitsMaxTenorAtUint40Max() public {
        bytes32 id = ace.createMarket(_tenorParams(uint64(type(uint40).max)));
        assertEq(ace.idToMarketParams(id).maxTenor, uint64(type(uint40).max), "the widest representable term must be creatable");
    }
}
