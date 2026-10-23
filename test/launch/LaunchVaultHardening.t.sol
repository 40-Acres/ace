// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";
import {Bid, Checkpoint} from "../../src/interfaces/ILaunchAuction.sol";
import {LaunchVault} from "../../src/curator/LaunchVault.sol";
import {SetValue} from "../../src/curator/sets/SetValue.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {LaunchVaultBase} from "./LaunchVault.t.sol";

/// @title LaunchVaultHardeningBase
/// @notice Helpers the hardening rows share: a bid on any stretch of the auction, an independent grid floor, and a third holder.
abstract contract LaunchVaultHardeningBase is LaunchVaultBase {
    address internal erin = address(0xE41); // a third depositor

    /// @dev A bid owned by `who`'s buyer account, entering at `start` with `startMps` of the schedule run, capped at `maxPrice`.
    function _bidAt(address who, uint64 start, uint24 startMps, uint256 maxPrice, uint256 amount) internal returns (uint256 id) {
        id = ++lastBid;
        Bid memory b;
        (b.startBlock, b.startCumulativeMps, b.maxPrice, b.owner, b.amountQ96) = (start, startMps, maxPrice, m.lock.account(who, 0), amount << 96);
        m.auction.setBid(id, b);
    }

    /// @dev A checkpoint with its links and its raise at the clearing price, as the auction's exit arithmetic reads them.
    function _cpLinked(uint256 clearing, uint24 cumMps, uint64 prev, uint64 next, uint256 raisedX7) internal pure returns (Checkpoint memory c) {
        (c.clearingPrice, c.cumulativeMps, c.prev, c.next, c.currencyRaisedAtClearingPriceQ96X7) = (clearing, cumMps, prev, next, raisedX7);
    }

    /// @dev The largest multiple of 50 at or under `x`, by integer arithmetic alone: the grid floor toward minus infinity.
    function _floor50(int256 x) internal pure returns (int24) {
        int256 r = x % 50;
        return int24(r < 0 ? x - r - 50 : x - r);
    }
}

/// @title LaunchVaultCreditHardeningTest
/// @notice Credit on bids the unit rig never filled whole: a partial fill at the clearing price, an outbid bid, and one that spent nothing.
/// @dev The auction is re-laid as a ladder: START and MID clear at half CLEAR, the end at CLEAR, so the budget judges every hint.
contract LaunchVaultCreditHardeningTest is LaunchVaultHardeningBase {
    uint64 internal constant MID = 20; // the ladder's middle checkpoint, half the schedule run
    uint256 internal constant PARTIAL = 1_000e6; // the one bid at CLEAR: its stretch below CLEAR, then a quarter more at it

    function setUp() public override {
        super.setUp();
        uint64 e = m.auction.endBlock();
        m.auction.setCheckpoint(START, _cpLinked(CLEAR / 2, 0, 0, MID, 0));
        m.auction.setCheckpoint(MID, _cpLinked(CLEAR / 2, 5e6, START, e, 0));
        m.auction.setCheckpoint(e, _cpLinked(CLEAR, MPS, MID, type(uint64).max, ((PARTIAL / 4) << 96) * MPS));
        m.auction.setTick(CLEAR, PARTIAL << 96);
    }

    /// @notice A bid at the final clearing price, partly filled there, credits what it SPENT, three quarters, never its whole amount.
    /// @notice The hints are the budget's: a wrong one reverts BadHint and marks nothing.
    function test_APartialFillCreditsWhatItSpent() public {
        uint256 id = _bidAt(alice, START, 0, CLEAR, PARTIAL);
        assertEq(m.budget.spentOf(id, MID, 0), (PARTIAL * 3 / 4) << 96, "fixture: the bid spent its half below CLEAR and a quarter at it");
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        vault.credit(id, 0, 0);
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        vault.credit(id, START, 0); // START's successor still clears under the bid's price
        assertFalse(vault.credited(id), "a refused credit was marked");
        assertEq(vault.credit(id, MID, 0), _creditFor(PARTIAL * 3 / 4), "the credit is not the spend at the final clearing price, less an atom");
        assertEq(vault.creditOf(m.lock.predict(alice, 0)), _creditFor(PARTIAL * 3 / 4), "the account was not credited the spend");
    }

    /// @notice An outbid bid credits only its fully filled stretch, by both hints in their own places: swapped, they are refused.
    function test_AnOutbidBidCreditsItsFullyFilledStretch() public {
        uint64 e = m.auction.endBlock();
        uint256 id = _bidAt(alice, START, 0, CLEAR * 3 / 4, 400e6);
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        vault.credit(id, e, MID);
        assertEq(vault.credit(id, MID, e), _creditFor(200e6), "an outbid bid's credit is not its fully filled half");
    }

    /// @notice An outbid bid that spent nothing credits nothing, yet is marked, so it can never be credited again.
    function test_AnOutbidBidThatSpentNothingIsMarkedAtZero() public {
        uint64 e = m.auction.endBlock();
        uint256 id = _bidAt(alice, MID, 5e6, CLEAR * 3 / 4, 300e6);
        assertEq(m.budget.spentOf(id, MID, e), 0, "fixture: the bid entered at MID and was outbid at once");
        assertEq(vault.credit(id, MID, e), 0, "a bid that spent nothing was credited");
        assertEq(vault.creditOf(m.lock.predict(alice, 0)), 0, "the account gained credit for nothing");
        assertTrue(vault.credited(id), "a zero credit was not marked");
        vm.expectRevert(LaunchVault.AlreadyCredited.selector);
        vault.credit(id, MID, e);
    }

    /// @notice An account's bids of every kind add: a full fill, a partial one, an outbid half and an outbid nothing; their sum is its room.
    /// @notice A full fill's hints are ignored, whatever they are.
    function test_EveryKindOfBidAddsIntoOneRoom() public {
        uint64 e = m.auction.endBlock();
        uint256 full = _bid(m, alice, SPEND);
        uint256 part = _bidAt(alice, START, 0, CLEAR, PARTIAL);
        uint256 half = _bidAt(alice, START, 0, CLEAR * 3 / 4, 400e6);
        uint256 none = _bidAt(alice, MID, 5e6, CLEAR * 3 / 4, 300e6);
        LockAccount acct = _acct(alice);
        strat.send(m.token, address(acct), _filled(SPEND + PARTIAL + 400e6));
        vault.credit(full, 999, 999);
        vault.credit(part, MID, 0);
        vault.credit(half, MID, e);
        vault.credit(none, MID, e);
        uint256 sum = _creditFor(SPEND) + _creditFor(PARTIAL * 3 / 4) + _creditFor(200e6);
        assertEq(vault.creditOf(address(acct)), sum, "the bids' credits do not add");
        _deposit(vault, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m));
        (, uint256 got) = _reserve(vault, alice, type(uint256).max);
        assertEq(got, _maxPrincipal(sum, vault.quote()), "the room is not the bids' credits together");
    }
}

/// @title LaunchVaultReserveHardeningTest
/// @notice reserve's min, leg by leg; the account list; the old market's recall; the borrower's own quote; and the hub's allowance.
contract LaunchVaultReserveHardeningTest is LaunchVaultHardeningBase {
    /// @notice Each leg of the min binds in turn: the ask, then the room less what rests, then the free cash past the booked fee.
    /// @notice No reserve leaves the hub an allowance: the approval is exactly each deposit.
    function test_EachLegOfTheMinBindsInTurn() public {
        _buy(alice, SPEND);
        _buy(bob, SPEND);
        _deposit(vault, carol, 1_000e6);
        _deposit(vault, dave, 100e6);
        usdc.mint(address(vault), 100e6); // a donation, so dave's exit books a fee
        vm.prank(dave);
        vault.exit(100e6, dave);
        uint256 fee = vault.feeOwed();
        assertGt(fee, 0, "fixture: a fee is booked");
        _goLive(m);
        _warpTo(_openAt(m));
        uint256 room = _maxPrincipal(_creditFor(SPEND), vault.quote());
        (bytes32 a, uint256 got) = _reserve(vault, alice, 100e6);
        assertEq(got, 100e6, "the ask did not bind");
        assertEq(usdc.allowance(address(vault), address(ace)), 0, "a reserve left the hub an allowance");
        (, got) = _reserve(vault, alice, type(uint256).max);
        assertEq(got, room - 100e6, "the room less what rests did not bind");
        assertEq(ace.restingOf(a), room, "alice's market rests other than her room");
        uint256 free = usdc.balanceOf(address(vault)) - fee;
        assertLt(free, room, "fixture: the free cash is under bob's room");
        (bytes32 b, uint256 gotB) = _reserve(vault, bob, type(uint256).max);
        assertEq(gotB, free, "the free cash past the fee did not bind");
        assertEq(abi.encode(usdc.balanceOf(address(vault)), ace.restingOf(b)), abi.encode(fee, free), "the fee was rested, or free cash was left");
        assertEq(usdc.allowance(address(vault), address(ace)), 0, "a reserve left the hub an allowance");
    }

    /// @notice The account list grows once per account: a top-up, a re-price, a recall and a reserve after it never list an account again.
    function test_TheAccountListGrowsOncePerAccount() public {
        LockAccount a = _ready();
        LockAccount b = _buy(bob, SPEND);
        _reserve(vault, alice, 50e6);
        _reserve(vault, alice, 20e6); // a top-up
        _flat(m, _clearTick() - 1_000);
        _reserve(vault, alice, 30e6); // a re-price
        _warpBy(1 hours);
        vault.recall(address(a));
        _reserve(vault, alice, 10e6); // after a recall
        assertEq(vault.accountCount(), 1, "one account was listed twice");
        _reserve(vault, bob, 10e6);
        assertEq(abi.encode(vault.accountCount(), vault.accounts(0), vault.accounts(1)), abi.encode(2, address(a), address(b)), "the account list");
    }

    /// @notice A re-price recalls exactly the old market's resting cash: a loan drawn from it stays out, its principal still lent.
    function test_ARepriceRecallsOnlyTheOldMarketsRestingCash() public {
        _ready();
        (bytes32 old,) = _reserve(vault, alice, 100e6);
        uint256 loanId = _borrow(m, alice, old, 40e6, 30 days);
        (uint256 lent,) = ace.lenderByCollateral(address(vault), address(usdc), m.token);
        assertEq(lent, 40e6, "fixture: the draw is lent");
        uint256 cash = usdc.balanceOf(address(vault));
        uint256 owed = ace.lenderOwed(address(vault), address(usdc)); // the draw's lender fee, which reserve collects
        _flat(m, _clearTick() - 1_000);
        (bytes32 neu, uint256 got) = _reserve(vault, alice, 20e6);
        assertTrue(neu != old, "fixture: a new market");
        assertEq(abi.encode(ace.restingOf(old), ace.restingOf(neu), got), abi.encode(0, 20e6, 20e6), "the two markets");
        assertEq(usdc.balanceOf(address(vault)), cash + owed + 60e6 - 20e6, "the recall took home other than the old market's resting cash");
        (uint256 lentAfter,) = ace.lenderByCollateral(address(vault), address(usdc), m.token);
        assertEq(lentAfter, 40e6, "the old market's loan moved");
        assertFalse(ace.isClosed(loanId), "the old market's loan closed");
    }

    /// @notice A reservation after a dump in its own block is struck at the borrower's spot-lowered quote, never the block-start one.
    /// @notice A third party still cannot recall it: its price is under the block-start quote.
    function test_AReserveAfterAnInBlockDumpStrikesAtSpot() public {
        LockAccount acct = _ready();
        _nextBlock();
        uint256 start = vault.blockStartQuote();
        _swap(m, true, 50_000e18); // this block's first swap: the window keeps the block's start
        uint256 q = vault.quote();
        assertLt(q, start, "fixture: the dump lowered the borrower's quote");
        assertEq(vault.blockStartQuote(), start, "fixture: the window held the block's start");
        (bytes32 id,) = _reserve(vault, alice, 50e6);
        assertEq(ace.idToMarketParams(id).price, q, "the reservation was not struck at the borrower's own quote");
        vm.prank(stranger);
        vm.expectRevert(LaunchVault.NotRecallable.selector);
        vault.recall(address(acct));
    }
}

/// @title LaunchVaultRecallHardeningTest
/// @notice The recall's conditions at their exact edges: the hour from a top-up's second, and one tick under the reservation's grid line.
contract LaunchVaultRecallHardeningTest is LaunchVaultHardeningBase {
    /// @notice A top-up restarts the hour from its own second: a stranger is refused at top-up + 1h - 1 and recalls at top-up + 1h.
    function test_TheHourRunsFromTheTopUpToTheSecond() public {
        LockAccount acct = _ready();
        _reserve(vault, alice, 50e6);
        _warpBy(37 minutes);
        uint256 t1 = _now();
        _reserve(vault, alice, 20e6);
        _warpTo(t1 + 1 hours - 1);
        vm.prank(stranger);
        vm.expectRevert(LaunchVault.NotRecallable.selector);
        vault.recall(address(acct));
        _warpTo(t1 + 1 hours);
        vm.prank(stranger);
        assertEq(vault.recall(address(acct)), 70e6, "the hour from the top-up did not run out to the second");
    }

    /// @notice The block-start quote recalls at the grid line's edge: a window up to 49 ticks higher, or 50, keeps the reservation;
    /// @notice one tick under the line it was struck on makes it anyone's.
    function test_ARecallTurnsOnOneTickUnderTheReservationsGridLine() public {
        int24 w = TickBitmap.compress(_clearTick() - 1_000 - int24(D), 50) * 50 + int24(D); // w - d sits on a grid line
        _flat(m, w);
        LockAccount acct = _ready();
        (bytes32 id,) = _reserve(vault, alice, 50e6);
        assertEq(ace.idToMarketParams(id).price, _priceAt(w - int24(D)), "fixture: struck exactly on the line");
        int24[3] memory keep = [w + 49, w + 50, w];
        for (uint256 i; i < 3; ++i) {
            _flat(m, keep[i]);
            vm.prank(stranger);
            vm.expectRevert(LaunchVault.NotRecallable.selector);
            vault.recall(address(acct));
        }
        _flat(m, w - 1);
        assertLt(vault.blockStartQuote(), ace.idToMarketParams(id).price, "fixture: one tick under the line drops a whole step");
        vm.prank(stranger);
        assertEq(vault.recall(address(acct)), 50e6, "one tick under the line did not free the reservation");
    }

    /// @notice A second recall of an emptied reservation returns nothing and never reverts; the reservation and the list stand.
    function test_ASecondRecallReturnsNothing() public {
        LockAccount acct = _ready();
        (bytes32 id,) = _reserve(vault, alice, 50e6);
        _warpBy(1 hours);
        vm.startPrank(stranger);
        assertEq(vault.recall(address(acct)), 50e6, "the first recall");
        assertEq(vault.recall(address(acct)), 0, "a second recall moved cash");
        vm.stopPrank();
        (bytes32 rm,) = vault.reservationOf(address(acct));
        assertEq(abi.encode(rm, vault.accountCount()), abi.encode(id, 1), "the recall moved the reservation or the list");
    }
}

/// @title LaunchVaultQuoteHardeningCases
/// @notice The quote's clamp at MIN_TICK, its grid floor by integer arithmetic, and its clearing ceiling for any clearing price.
/// @dev Run for both currency orders, as the existing quote cases are.
abstract contract LaunchVaultQuoteHardeningCases is LaunchVaultHardeningBase {
    function _tokenIs0() internal pure virtual returns (bool);

    function setUp() public override {
        super.setUp();
        (m, vault) = _launchOn(_tokenIs0());
        _goLive(m);
    }

    /// @notice A window floor whose t - d snaps under MIN_TICK quotes zero, never a revert: at MIN_TICK - 1, MIN_TICK, and MIN_TICK + 21.
    /// @notice The lowest grid line in range, -887250, quotes zero too, since its price rounds to nothing; reserve refuses NoQuote, not InvalidTick.
    function test_AFloorSnappingUnderMinTickQuotesZero() public {
        int24[4] memory xs = [TickMath.MIN_TICK - 1, TickMath.MIN_TICK, TickMath.MIN_TICK + 21, int24(-887_250)];
        for (uint256 i; i < xs.length; ++i) {
            _flat(m, xs[i] + int24(D));
            assertEq(abi.encode(vault.quote(), vault.blockStartQuote()), abi.encode(0, 0), "a floor under the grid's range quoted");
        }
        _flat(m, TickMath.MIN_TICK + int24(D));
        _buy(m, vault, alice, SPEND);
        _deposit(vault, carol, CASH);
        _warpTo(_openAt(m));
        vm.prank(alice);
        vm.expectRevert(LaunchVault.NoQuote.selector);
        vault.reserve(type(uint256).max);
    }

    /// @notice For any window under clearing, the quote is the price at the grid floor of t - d toward minus infinity, by integer arithmetic.
    function testFuzz_TheSnapIsTheGridFloorTowardMinusInfinity(int24 t) public {
        t = int24(bound(t, int256(-887_250) + int256(uint256(D)), int256(_clearTick()) - 1));
        _flat(m, t);
        assertEq(vault.quote(), _priceAt(_floor50(int256(t) - int256(uint256(D)))), "the quote is not the grid floor of t - d");
    }

    /// @notice For any clearing price and window, the quote never passes the lower of the two less d, and sits within a grid step and two ticks of it.
    /// @dev The bounds are the spec's, in prices: 1.0001^-d below the lower price, and at most 1.0001^-(d + 51) under it.
    function testFuzz_TheQuoteTracksTheLowerOfClearingAndWindow(uint256 clearing, int24 t) public {
        clearing = bound(clearing, CLEAR / 100, CLEAR * 100);
        m.auction.setCheckpoint(m.auction.endBlock(), _cp(clearing, MPS));
        t = int24(bound(t, -500_000, 100_000));
        _flat(m, t);
        uint256 lower = Math.min(_priceAt(t), clearing);
        uint256 q = vault.quote();
        uint256 hiB = Math.mulDiv(lower, _priceAt(-int24(D)), Q) + Math.mulDiv(lower, 1, 1e12) + 1;
        uint256 loB = Math.mulDiv(lower, _priceAt(-int24(D) - 51), Q);
        loB = loB > Math.mulDiv(loB, 1, 1e12) + 1 ? loB - Math.mulDiv(loB, 1, 1e12) - 1 : 0;
        assertLe(q, hiB, "the quote passed the lower of clearing and the window, less d");
        assertGe(q, loB, "the quote fell more than a grid step and two ticks under the lower price, less d");
        assertEq(vault.blockStartQuote(), q, "a flat window quotes apart with spot");
    }
}

/// @title LaunchVaultQuoteHardeningToken0Test
/// @notice The hardening quote rows with the launch token as currency0.
contract LaunchVaultQuoteHardeningToken0Test is LaunchVaultQuoteHardeningCases {
    function _tokenIs0() internal pure override returns (bool) {
        return true;
    }
}

/// @title LaunchVaultQuoteHardeningToken1Test
/// @notice The hardening quote rows with the launch token as currency1.
contract LaunchVaultQuoteHardeningToken1Test is LaunchVaultQuoteHardeningCases {
    function _tokenIs0() internal pure override returns (bool) {
        return false;
    }
}

/// @title LaunchVaultHighPriceCases
/// @notice A launch whose token atom clears at 1,000 USDC atoms: positive token ticks, and a unit of room worth hundreds of atoms.
/// @notice There the room must be the hub's coverage line inverted exactly, and the grid floor must hold on both sides of tick zero.
/// @dev At the default CLEAR a unit is worth about 6e-14 atoms, so the line's one-unit atom can never show in a reservation.
abstract contract LaunchVaultHighPriceCases is LaunchVaultHardeningBase {
    uint256 internal constant HIGH = 1_000 << 96; // the final clearing price here, Q96 USDC atoms per token atom

    function _tokenIs0() internal pure virtual returns (bool);

    function setUp() public override {
        super.setUp();
        (m, vault) = _launchOn(_tokenIs0());
        m.auction.setCheckpoint(m.auction.endBlock(), _cp(HIGH, MPS));
        _goLive(m);
    }

    /// @dev `who` spends `amount` above HIGH, holds what it filled, and the vault credits it: amount / 1000 - 1 units.
    function _buyHigh(address who, uint256 amount) internal returns (LockAccount acct, uint256 units) {
        uint256 id = _bidAt(who, START, 0, HIGH + 1, amount);
        acct = _acct(who);
        strat.send(m.token, address(acct), amount / 1_000);
        units = vault.credit(id, 0, 0);
    }

    function _hTick() internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(SetValue.sqrtPriceX96(HIGH, false));
    }

    /// @notice The room is the hub's line inverted exactly: the account can draw it pledging its credit, and one atom more would need a unit it lacks.
    function test_TheRoomIsTheHubsLineInvertedExactly() public {
        (LockAccount acct, uint256 units) = _buyHigh(alice, SPEND);
        assertEq(units, SPEND / 1_000 - 1, "fixture: the credit at HIGH");
        _flat(m, _hTick() - 500);
        _deposit(vault, carol, CASH);
        _warpTo(_openAt(m));
        uint256 q = vault.quote();
        assertGt(q, 1_000 * Q / 2, "fixture: a unit is worth hundreds of atoms");
        (bytes32 id, uint256 got) = _reserve(vault, alice, type(uint256).max);
        assertLe(_unitsFor(got, q), units, "the room needs more units than the credit");
        assertGt(_unitsFor(got + 1, q), units, "the room stops short of what the credit secures");
        vm.prank(alice);
        acct.borrow(id, units, got, 30 days, OpenBounds(0, 0, 0));
        assertEq(ace.restingOf(id), 0, "the account could not draw its whole room");
    }

    /// @notice Around tick zero the grid floor is toward minus infinity: t - d at -1, -49 and -50 quotes tick -50; at -51, -100; at 0 and 49, 0.
    function test_TheGridFloorAroundTickZero() public {
        int24[6] memory xs = [int24(-1), -49, -50, -51, 0, 49];
        int24[6] memory want = [int24(-50), -50, -50, -100, 0, 0];
        for (uint256 i; i < xs.length; ++i) {
            _flat(m, xs[i] + int24(D));
            assertEq(vault.quote(), _priceAt(want[i]), "the snap near tick zero is not the floor toward minus infinity");
        }
    }

    /// @notice A window over a positive clearing tick quotes the clearing tick less d on the grid: clearing binds from above.
    function test_APositiveClearingTickCapsTheQuote() public {
        int24 h = _hTick();
        assertGt(h, 0, "fixture: the clearing tick is positive");
        assertLe(_priceAt(h), HIGH, "fixture: the clearing tick prices at or under HIGH");
        _flat(m, h + 3_000);
        assertEq(vault.quote(), _priceAt(_floor50(int256(h) - int256(uint256(D)))), "the clearing ceiling at a positive tick");
        _flat(m, h - 3_000);
        assertEq(vault.quote(), _priceAt(_floor50(int256(h) - 3_000 - int256(uint256(D)))), "a window under a positive clearing tick");
    }
}

/// @title LaunchVaultHighPriceToken0Test
/// @notice The high-price rows with the launch token as currency0.
contract LaunchVaultHighPriceToken0Test is LaunchVaultHighPriceCases {
    function _tokenIs0() internal pure override returns (bool) {
        return true;
    }
}

/// @title LaunchVaultHighPriceToken1Test
/// @notice The high-price rows with the launch token as currency1.
contract LaunchVaultHighPriceToken1Test is LaunchVaultHighPriceCases {
    function _tokenIs0() internal pure override returns (bool) {
        return false;
    }
}

/// @title LaunchVaultExitHardeningTest
/// @notice Exits in any order, chunked, with fee claims between: nothing made or lost, each holder paid pro rata, the fee a floored tenth.
contract LaunchVaultExitHardeningTest is LaunchVaultHardeningBase {
    struct Step {
        uint8 holder;
        uint256 shares;
    }

    /// @notice The fee floors per exit: a gain of 9 atoms books nothing, 10 books 1, 19 books 1, 20 books 2.
    function test_TheFeeFloorsUnderTenAtomsOfGain() public {
        uint256[4] memory gains = [uint256(9), 10, 19, 20];
        uint256[4] memory fees = [uint256(0), 1, 1, 2];
        for (uint256 i; i < 4; ++i) {
            LaunchVault v = LaunchVault(impl.vaultFor(m.token, address(uint160(0xF00 + i)), D, BASE));
            _deposit(v, carol, 1_000);
            usdc.mint(address(v), gains[i]);
            vm.prank(carol);
            (uint256 assets,) = v.exit(1_000, carol);
            assertEq(abi.encode(assets, v.feeOwed()), abi.encode(1_000 + gains[i] - fees[i], fees[i]), "the fee is not the gain's tenth, floored");
        }
    }

    /// @notice The floor is per exit: two holders each 9 atoms up book no fee, though the vault's whole gain is 18.
    /// @dev So a holder can dodge under one atom of fee per exit; gas makes that worthless, and it is recorded, not fixed.
    function test_TheFloorIsPerExitNotPerVault() public {
        _deposit(vault, carol, 100);
        _deposit(vault, dave, 100);
        usdc.mint(address(vault), 18);
        vm.prank(carol);
        (uint256 a,) = vault.exit(100, carol);
        vm.prank(dave);
        (uint256 b,) = vault.exit(100, dave);
        assertEq(abi.encode(a, b, vault.feeOwed()), abi.encode(109, 109, 0), "a sub-ten gain per exit booked a fee");
    }

    /// @notice A fee claimed between two equal exits changes neither: the second exiter is paid as the first, and the curator gets both fees.
    function test_AClaimBetweenExitsMovesNoHoldersPay() public {
        _deposit(vault, carol, 500e6);
        _deposit(vault, dave, 500e6);
        usdc.mint(address(vault), 100e6);
        vm.prank(carol);
        (uint256 a,) = vault.exit(500e6, carol);
        uint256 claimed = vault.claimFee();
        assertEq(abi.encode(claimed, vault.feeOwed()), abi.encode(5e6, 0), "the first fee was not paid whole");
        vm.prank(dave);
        (uint256 b,) = vault.exit(500e6, dave);
        claimed += vault.claimFee();
        assertEq(abi.encode(a, b), abi.encode(545e6, 545e6), "a claim between exits moved a holder's pay");
        assertEq(abi.encode(usdc.balanceOf(curator), claimed, usdc.balanceOf(address(vault))), abi.encode(10e6, 10e6, 0), "the fees' payee");
    }

    /// @notice A gain from donations alone: three holders exit in any order, in up to three chunks each, the curator claiming at random between.
    function testFuzz_ExitsInAnyOrderConserveAndPayProRata(uint64[3] memory dep, uint64 gift, uint96 tokens, uint256 seed) public {
        address[3] memory hs = [carol, dave, erin];
        uint256[3] memory sh;
        for (uint256 i; i < 3; ++i) {
            sh[i] = bound(dep[i], 1, 1_000_000e6);
            _deposit(vault, hs[i], sh[i]);
        }
        usdc.mint(address(vault), bound(gift, 0, 1_000_000e6));
        strat.send(m.token, address(vault), bound(tokens, 0, 100_000e18));
        _exitAll(hs, sh, seed);
    }

    /// @notice A gain or loss from a real term: two loans, each repaid or forfeited, then the same any-order exits with claims between.
    function testFuzz_ExitsAfterARealTermConserveAndPayProRata(uint64[3] memory dep, uint8 outcomes, uint256 seed) public {
        address[3] memory hs = [carol, dave, erin];
        uint256[3] memory sh;
        _buy(alice, SPEND);
        _buy(bob, 2 * SPEND);
        for (uint256 i; i < 3; ++i) {
            sh[i] = bound(dep[i], 1e6, 2_000e6);
            _deposit(vault, hs[i], sh[i]);
        }
        _goLive(m);
        _warpTo(_openAt(m));
        address[2] memory buyers = [alice, bob];
        uint256[2] memory loans;
        for (uint256 i; i < 2; ++i) {
            vm.prank(buyers[i]);
            try vault.reserve(type(uint256).max) returns (bytes32 id, uint256 got) {
                loans[i] = _borrow(m, buyers[i], id, got, 30 days);
            } catch {}
        }
        for (uint256 i; i < 2; ++i) {
            if (loans[i] == 0) continue;
            _warpAtLeastTo(read.loan(loans[i]).expiry - 1);
            if ((outcomes >> i) & 1 == 0) {
                _repay(loans[i]);
            } else {
                _warpAtLeastTo(read.loan(loans[i]).expiry);
                ace.forceClose(loans[i]);
                vault.redeem(loans[i]);
            }
        }
        assertTrue(vault.isHome(), "fixture: home after every loan closed");
        _exitAll(hs, sh, seed);
    }

    /// @dev What the exits paid each holder, what the curator claimed, and how many exits ran.
    struct Tally {
        uint256[3] paid;
        uint256[3] units;
        uint256 claimed;
        uint256 n;
    }

    /// @dev Every holder exits all its shares, in 1 to 3 chunks each, shuffled by `seed`, with a fee claim before any step `seed` picks.
    /// @dev Checks against the spec, never the vault's own arithmetic: USDC and tokens all go out, the curator takes at most a tenth of the gain,
    /// @dev and each holder is paid s(9B + S)/(10S) of a gain, or sB/S of a loss, within the rounding the exits can carry.
    function _exitAll(address[3] memory hs, uint256[3] memory sh, uint256 seed) internal {
        assertEq(vault.feeOwed(), 0, "fixture: no fee booked before the exits");
        uint256 s0 = sh[0] + sh[1] + sh[2];
        assertEq(vault.totalShares(), s0, "fixture: the holders are the whole supply");
        uint256 b0 = usdc.balanceOf(address(vault)) + ace.lenderOwed(address(vault), address(usdc));
        uint256 t0 = IERC20(m.token).balanceOf(address(vault));
        Tally memory r = _runExits(hs, sh, seed);
        assertEq(vault.totalShares(), 0, "shares are left");
        assertEq(r.paid[0] + r.paid[1] + r.paid[2] + r.claimed, b0, "USDC was made or lost across the exits");
        assertEq(r.units[0] + r.units[1] + r.units[2], t0, "tokens were made or lost across the exits");
        assertEq(abi.encode(usdc.balanceOf(address(vault)), IERC20(m.token).balanceOf(address(vault))), abi.encode(0, 0), "the vault kept an asset");
        assertEq(usdc.balanceOf(curator), r.claimed, "the curator was not paid what was claimed");
        uint256 g = b0 > s0 ? b0 - s0 : 0;
        assertLe(r.claimed * 10, g, "the curator took over a tenth of the gain");
        assertGe(r.claimed * 10 + 9 * r.n, g, "the curator took under a tenth of the gain, past one floor per exit");
        for (uint256 i; i < 3; ++i) {
            uint256 ideal = b0 >= s0 ? Math.mulDiv(sh[i], 9 * b0 + s0, 10 * s0) : Math.mulDiv(sh[i], b0, s0);
            assertApproxEqAbs(r.paid[i], ideal, 3 * r.n + 4, "a holder's USDC depends on the exit order");
            assertApproxEqAbs(r.units[i], Math.mulDiv(t0, sh[i], s0), 3 * r.n + 4, "a holder's tokens depend on the exit order");
        }
    }

    /// @dev The shuffled exits themselves, a claim before each step `seed` picks and one after the last.
    function _runExits(address[3] memory hs, uint256[3] memory sh, uint256 seed) internal returns (Tally memory r) {
        Step[] memory steps;
        (steps, r.n) = _steps(sh, seed);
        for (uint256 k; k < r.n; ++k) {
            if (uint256(keccak256(abi.encode(seed, "claim", k))) % 2 == 0) r.claimed += vault.claimFee();
            _exitStep(r, hs, steps[k]);
        }
        r.claimed += vault.claimFee();
    }

    /// @dev One exit, its fee checked against the spec on what it paid: a tenth of its USDC over its 1:1 basis, floored, or none.
    function _exitStep(Tally memory r, address[3] memory hs, Step memory s) internal {
        uint256 fee0 = vault.feeOwed();
        vm.prank(hs[s.holder]);
        (uint256 a, uint256 u) = vault.exit(s.shares, hs[s.holder]);
        uint256 fee = vault.feeOwed() - fee0;
        uint256 gain = a + fee > s.shares ? a + fee - s.shares : 0;
        assertEq(fee, gain / 10, "an exit's fee is not a tenth of its USDC over its 1:1 basis, floored");
        r.paid[s.holder] += a;
        r.units[s.holder] += u;
    }

    /// @dev Each holder's shares cut into 1 to 3 chunks, then all the chunks shuffled.
    function _steps(uint256[3] memory sh, uint256 seed) internal pure returns (Step[] memory steps, uint256 n) {
        steps = new Step[](9);
        for (uint256 i; i < 3; ++i) {
            uint256 k = 1 + uint256(keccak256(abi.encode(seed, i))) % 3;
            uint256 left = sh[i];
            for (uint256 j; j < k && left != 0; ++j) {
                uint256 part = j == k - 1 ? left : 1 + uint256(keccak256(abi.encode(seed, i, j))) % left;
                steps[n++] = Step(uint8(i), part);
                left -= part;
            }
        }
        for (uint256 i = n; i > 1; --i) {
            uint256 r = uint256(keccak256(abi.encode(seed, "shuffle", i))) % i;
            (steps[i - 1], steps[r]) = (steps[r], steps[i - 1]);
        }
    }
}
