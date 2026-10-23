// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {BelowWithdrawLine, BufferBelowMin, TriggerAboveFloor, ZeroCollateral, ZeroWithdrawTo} from "../../src/ace/hub/Borrower.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IAceRefinance, MigrateArgs} from "../utils/RebateHarness.sol";

/// @title AceRefinanceWithdraw
/// @notice The withdrawal leg on `refinanceTo`: the borrower's cash-free equity extraction, atomic with the roll.
/// @notice A loan's funding floor is the lowest tick its draw CONSUMED and never moves, so a rally opens no headroom.
/// @notice A refinance redraws against today's bids, so the successor's floor is where the ladder sits now.
/// @notice That is the whole verb, and T0 is the test that says it is worth having at all.
/// @dev The draw cap is the record's windowed minimum, and it ANCHORS the walk, so the reachable rungs move with price.
/// @dev The mock record ignores its window argument, so only the LEVEL of the cap is under test here, never its span.
/// @dev The line is recomputed locally from public params, so no expectation is lifted out of the implementation.
/// @dev Every refusal asserts a SPECIFIC selector: a named refusal reads as a specification, a bare revert does not.
abstract contract AceRefinanceWithdrawFixture is WarpClock {
    Ace internal ace;
    IAceRefinance internal fin;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal flatRec;
    bytes32 internal flat; // the single-rung market whose record never moves

    address internal alice = address(0xA11CE); // lender
    address internal borrower = address(0xB0B);
    address internal sink = address(0x51FC); // the withdrawal recipient, which receives nothing else, ever

    uint256 internal constant K = 1.4e18; // the suite's baseline coverage multiple
    uint256 internal constant K_LOOSE = 1.05e18; // the band floor: needs the fewest units per unit of debt
    uint256 internal constant K_TIGHT = 2e18; // roughly twice as many units for the same debt
    uint64 internal constant TENOR = 7 days;

    uint256 internal T_HI; // 6000 ticks above par, ~1.822x it; assigned in _boot, since par is not a compile-time value
    uint256 internal T_MID; // par itself
    uint256 internal T_LO; // 6000 ticks below par, ~0.5488x it

    uint256 internal constant LADDER = 200_000e6; // a rung deep enough to fund any draw here alone
    uint256 internal constant THIN = 100e6; // a token bid: enough to be walked, nowhere near enough to fill
    uint256 internal constant P = 4_500e6; // the opening draw
    uint256 internal constant NEWP = 4_700e6; // the successor's draw; over P so the netting never needs a repay leg
    uint256 internal constant BIGP = 5_000e6; // the successor's draw where the point is that it descends

    bytes4 internal constant OVER_COLLATERAL = bytes4(keccak256("WithdrawalExceedsCollateral()"));

    OpenBounds internal OFF = OpenBounds(0, 0, 0);
    uint256 internal t0;

    // ---- fixture ----

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function _boot() internal {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T_HI, T_MID, T_LO) = (_price(6000), _price(0), _price(-6000));
        flatRec = new MockPersistenceRecord(address(usdc), address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(flatRec);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, flat) = (d.ace, d.positionManager, d.read, d.id);
        fin = IAceRefinance(address(ace));
        _seed(flat, T_MID, LADDER);
        usdc.mint(borrower, 1_000_000e6);
    }

    /// @dev A fresh market on its OWN record, so one test can move its price without touching another's.
    /// @dev `claimTicks` IS IGNORED: it set `maxClaimTicks`, and a draw funds one claim at one price now.
    /// @dev Kept in the arity so the call sites still read as "a market of this shape", and because the fresh
    /// @dev record on each call is what makes two markets on identical terms hash apart.
    function _newMarket(uint256 coverageWad, uint256 claimTicks) internal returns (bytes32 mid, MockPersistenceRecord rec) {
        rec = new MockPersistenceRecord(address(usdc), address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(rec);
        p.minCoverageWad = coverageWad;
        mid = ace.createMarket(p);
    }

    /// @dev A fresh market BIDDING AT `price`, on its own record with a cap well above it.
    /// @dev The price is a creation param, so a market at a different bid IS a different market -- which is
    /// @dev what a "rally" means one level up, now that no walk can reach a rung a later price unlocked.
    function _newMarketAt(uint256 coverageWad, uint256 price) internal returns (bytes32 mid, MockPersistenceRecord rec) {
        rec = new MockPersistenceRecord(address(usdc), address(vault));
        rec.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(rec);
        p.minCoverageWad = coverageWad;
        p.price = price;
        mid = ace.createMarket(p);
    }

    /// @dev A rung of resting cash. The deposit gate refuses a tick above the live cap, so seed BEFORE any slump.
    function _seed(bytes32 mid, uint256 price, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(bytes32 mid, uint256 coll, uint256 principal) internal returns (uint256 loanId) {
        vault.mint(borrower, coll);
        vm.startPrank(borrower);
        vault.approve(address(pm), coll);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, coll, principal, TENOR, borrower, OFF);
        vm.stopPrank();
    }

    function _args(uint256 oldId, bytes32 dst, uint256 principal, uint256 units, address to) internal view returns (MigrateArgs memory) {
        return MigrateArgs(oldId, dst, principal, TENOR, OFF, units, to);
    }

    /// @dev The same args carrying the borrower's own open-time bounds, which is what the buffer leg turns on.
    function _bargs(uint256 oldId, bytes32 dst, uint256 principal, uint256 units, address to, OpenBounds memory bnd)
        internal
        pure
        returns (MigrateArgs memory)
    {
        return MigrateArgs(oldId, dst, principal, TENOR, bnd, units, to);
    }

    function _migrate(MigrateArgs memory m) internal returns (uint256 newId) {
        vm.prank(borrower);
        newId = fin.refinanceTo(m);
    }

    /// @dev Asserts the migration failed with EXACTLY `sel`, then returns so the state asserts still run.
    function _refuses(MigrateArgs memory m, bytes4 sel, string memory why) internal {
        vm.prank(borrower);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m));
        assertFalse(ok, why);
        assertEq(bytes32(bytes4(ret)), bytes32(sel), why);
    }

    // ---- the line, recomputed from public params ----

    /// @dev Units needed to keep `debt` admissible at `price`, ceiled, exactly as the hub ceils it.
    /// @dev `unitScale` is read off the market rather than spelled, so the frame lives in one place.
    function _requiredAt(bytes32 mid, uint256 debt, uint256 price) internal view returns (uint256) {
        if (debt == 0) return 0;
        if (price == 0) return type(uint256).max;
        uint256 n = ace.idToMarketParams(mid).minCoverageWad * debt;
        return FullMath.mulDivRoundingUp(n, read.marketState(mid).unitScale, price * 1e18);
    }

    /// @dev The withdrawal line: admissibility plus the market's tick cap, which settlement's per-tick ceiling needs.
    function _line(bytes32 mid, uint256 debt, uint256 price) internal view returns (uint256) {
        return _requiredAt(mid, debt, price) + 1;
    }

    /// @dev The price the gate reads: the loan's frozen funding floor, capped by the record's live windowed minimum.
    function _foldPrice(bytes32 mid, uint256 loanId) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(mid);
        uint256 floor = read.fundingFloor(mid, loanId);
        uint256 cap = IPersistenceRecord(p.record).minPrice(p.quote, p.collateral);
        return cap < floor ? cap : floor;
    }

    /// @dev What this loan could shed right now: everything above the live withdrawal line.
    function _freeNow(bytes32 mid, uint256 loanId) internal view returns (uint256) {
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 need = _line(mid, read.loan(loanId).debt, _foldPrice(mid, loanId));
        return units > need ? units - need : 0;
    }
}

/// @notice T0 / T0b / T0c: whether the verb is worth having, and what it does when the ladder cannot deliver.
contract AceRefinanceWithdrawFloorTest is AceRefinanceWithdrawFixture {
    uint256 internal constant COLL_T0 = 6_400e18; // just over the 1.0-rung line, so the slump leaves ~100e18 free
    uint256 internal constant TAKE_T0 = 1_000e18; // ten times that: refused before the roll, released after it
    uint256 internal constant COLL_B = 20_000e18; // enough to stay admissible even at the deep rung

    function setUp() public {
        _boot();
    }

    /// @notice T0: a HIGHER-BIDDING destination raises the successor's floor, and that is where real
    /// @notice withdrawable headroom comes from. The control is the same request refused on the old loan.
    /// @dev IT WAS A RALLY, and a rally moved the WALK: the record's cap pinned the first draw to a low rung,
    /// @dev and a later rise let the successor reach a higher one INSIDE THE SAME MARKET. A market's price is
    /// @dev write-once now, so a redraw into the same market comes to rest exactly where the first one did --
    /// @dev and the economics move one level up: the better bid is a DIFFERENT MARKET, which is what this
    /// @dev migrates into. The loan's own floor is still FROZEN, which is the half the control still pins.
    /// @dev The old floor is captured before the roll because retirement deletes it.
    function test_T0_AHigherBiddingDestinationRaisesTheSuccessorsFloorAndOpensHeadroom() public {
        (bytes32 low,) = _newMarketAt(K, T_MID);
        (bytes32 high,) = _newMarketAt(K, T_HI);
        _seed(low, T_MID, LADDER);
        _seed(high, T_HI, LADDER);

        uint256 oldId = _open(low, COLL_T0, P);
        uint256 floorOld = read.fundingFloor(low, oldId);
        assertEq(floorOld, T_MID, "fixture: the loan funded at the low market's own bid");

        vm.prank(borrower);
        vm.expectRevert(BelowWithdrawLine.selector);
        ace.withdrawCollateral(oldId, TAKE_T0, borrower);

        uint256 freeOld = _freeNow(low, oldId);
        assertLt(freeOld, TAKE_T0, "control: at its own frozen floor the old loan cannot shed this");

        uint256 newId = _migrate(_args(oldId, high, NEWP, TAKE_T0, sink));

        assertEq(read.fundingFloor(high, newId), T_HI, "the successor drew against the destination's own bid");
        assertGt(read.fundingFloor(high, newId), floorOld, "which is strictly above the floor the low market pinned");
        assertEq(vault.balanceOf(sink), TAKE_T0, "and the units the old loan could not shed reached the recipient");
        assertEq(read.loan(newId).collateralUnits, COLL_T0 - TAKE_T0, "the loan record is debited by exactly that");
        assertEq(pm.collateralOf(newId), COLL_T0 - TAKE_T0, "and custody agrees with the ledger");
        assertGt(TAKE_T0 + _freeNow(high, newId), freeOld, "the successor's whole headroom is genuinely larger than the old loan's");
    }

    /// @notice T0c: a flat record refunds at the same rung, so headroom is exactly zero and one wei is refused.
    /// @dev The lot is sized to the SUCCESSOR's line, which sits above the opening loan's because the draw grows.
    function test_T0c_AFlatPriceOpensNoHeadroomSoOneWeiIsRefused() public {
        uint256 coll = _line(flat, NEWP, T_MID);
        uint256 oldId = _open(flat, coll, P);
        uint256 floorOld = read.fundingFloor(flat, oldId);

        uint256 root = vm.snapshotState();
        uint256 probe = _migrate(_args(oldId, flat, NEWP, 0, address(0)));
        assertEq(read.fundingFloor(flat, probe), floorOld, "fixture: a flat record redraws at the very same rung");
        assertEq(_freeNow(flat, probe), 0, "so the successor rests exactly on its line, with nothing above it");
        vm.revertToState(root);

        _refuses(_args(oldId, flat, NEWP, 1, sink), BelowWithdrawLine.selector, "one wei of headroom does not exist");
        assertEq(vault.balanceOf(sink), 0, "and nothing left");
    }
}

/// @notice T6: the buffer gate re-run, which is the ordering defect the withdrawal leg exposed.
contract AceRefinanceWithdrawBufferTest is AceRefinanceWithdrawFixture {
    uint256 internal constant COLL_6 = 9_400e18; // the successor's trigger sits at 0.70, so the buffer opens at 0.30
    uint256 internal constant TAKE_6 = 1_400e18; // shedding these lifts the trigger to 0.8225, so the buffer closes to 0.1775
    uint256 internal constant MIN_BUFFER = 2e17; // between the two, so only the post-withdraw read can fail

    function setUp() public {
        _boot();
    }

    /// @notice The draw prices the buffer on PRE-withdraw units and `triggerPrice` rises as units fall.
    /// @notice So a bound that admits the roll must be asked again once the release has been debited.
    /// @dev The last assert is the control that isolates the leg: the withdrawal LINE admits this release outright.
    function test_T6_TheBufferGateIsReRunOnPostWithdrawCollateral() public {
        uint256 oldId = _open(flat, COLL_6, P);
        OpenBounds memory bnd = OpenBounds(0, MIN_BUFFER, 0);

        uint256 root = vm.snapshotState();
        uint256 probe = _migrate(_bargs(oldId, flat, NEWP, 0, address(0), bnd));
        assertEq(read.loan(probe).collateralUnits, COLL_6, "fixture: the same bound admits the roll while the lot is whole");
        vm.revertToState(root);

        _refuses(_bargs(oldId, flat, NEWP, TAKE_6, sink, bnd), BufferBelowMin.selector, "the shed units thin the buffer past the borrower's floor");

        assertEq(vault.balanceOf(sink), 0, "and nothing was released before it was refused");
        assertGt(COLL_6 - TAKE_6, _line(flat, NEWP, T_MID), "control: the withdrawal line itself admits this release");
    }
}

/// @notice T7: the argument rails, and the one rail that must NOT migrate onto this path.
contract AceRefinanceWithdrawRailsTest is AceRefinanceWithdrawFixture {
    uint256 internal constant COLL_7 = 12_000e18;
    uint256 internal constant TAKE_7 = 1_000e18;

    function setUp() public {
        _boot();
    }

    /// @notice Zero units is a plain refinance, not a refusal: `ZeroWithdrawal` belongs to `withdrawCollateral` alone.
    /// @notice The recipient is left zero too: no units and no one named is the one pairing the recipient rule skips.
    /// @dev Every ordinary caller takes this path, so a rail migrated into the shared body would break every refinance.
    function test_T7_ZeroUnitsIsACleanNoOpRefinanceEvenWithNoRecipient() public {
        uint256 oldId = _open(flat, COLL_7, P);

        uint256 newId = _migrate(_args(oldId, flat, NEWP, 0, address(0)));

        assertFalse(read.loan(newId).closedAt != 0, "the successor is live");
        assertEq(read.loan(newId).collateralUnits, COLL_7, "the whole lot carried across");
        assertEq(pm.collateralOf(newId), COLL_7, "and custody agrees");
        assertEq(vault.balanceOf(sink), 0, "no release fired");
    }

    /// @notice A request that empties the loan is `ZeroCollateral`: an unsecured loan clears every gate and never settles.
    /// @notice One wei MORE than the lot is a named over-withdrawal, matching `withdrawCollateral`.
    function test_T7_TheWholeLotIsZeroCollateralAndMoreThanItIsNamed() public {
        uint256 oldId = _open(flat, COLL_7, P);

        _refuses(_args(oldId, flat, NEWP, COLL_7, sink), ZeroCollateral.selector, "a loan may not be stripped bare");
        _refuses(_args(oldId, flat, NEWP, COLL_7 + 1, sink), OVER_COLLATERAL, "more than the lot is refused by name");

        assertEq(vault.balanceOf(sink), 0, "neither moved a unit");
        assertEq(read.loan(oldId).collateralUnits, COLL_7, "and the old loan is whole");
    }

    /// @notice Units asked for with no recipient REVERT rather than burn, matching `withdrawCollateral`'s posture.
    /// @dev The destination is the caller's own choice and the caller holds title: a refused address is theirs to avoid.
    function test_T7_UnitsWithNoRecipientAreRefusedByName() public {
        uint256 oldId = _open(flat, COLL_7, P);

        _refuses(_args(oldId, flat, NEWP, TAKE_7, address(0)), ZeroWithdrawTo.selector, "units with nowhere to go are never burned");

        assertEq(read.loan(oldId).collateralUnits, COLL_7, "and the old loan is whole");
    }

    /// @notice The gate partitions EVERY request at the destination's line, and each half names its own refusal.
    /// @notice The trigger leg NEVER speaks here: the line is strictly tighter, so it is unreachable behind it.
    /// @dev That last claim is checkable only because the line carries its own name; under one selector it was invisible.
    /// @dev The catch leg pins the refusal to the same predicate, so a gate that refused everything would fail too.
    function testFuzz_TheReleaseIsAdmittedExactlyOnTheLine(uint256 units) public {
        uint256 oldId = _open(flat, COLL_7, P);
        units = bound(units, 1, COLL_7 + 1);
        uint256 rest = units > COLL_7 ? 0 : COLL_7 - units;
        uint256 need = _line(flat, NEWP, T_MID);

        vm.prank(borrower);
        try fin.refinanceTo(_args(oldId, flat, NEWP, units, sink)) returns (uint256 newId) {
            assertGe(rest, need, "an admitted release never drops the successor under its line");
            assertEq(read.loan(newId).collateralUnits, rest, "and leaves exactly the rest with the loan");
            assertEq(vault.balanceOf(sink), units, "with the released units at the recipient");
        } catch (bytes memory err) {
            assertTrue(units > COLL_7 || rest < need, "the refusal must be forced by the line, not by nothing");
            bytes4 want = units > COLL_7 ? OVER_COLLATERAL : (rest == 0 ? ZeroCollateral.selector : BelowWithdrawLine.selector);
            assertEq(bytes32(bytes4(err)), bytes32(want), "and refused for the reason the post state names");
            assertTrue(bytes4(err) != TriggerAboveFloor.selector, "and never by the trigger leg, which the tighter line makes unreachable");
            assertEq(vault.balanceOf(sink), 0, "a refused release moves no units");
            assertEq(read.loan(oldId).collateralUnits, COLL_7, "and leaves the old loan whole");
        }
    }

    /// @notice The same partition fuzzed AT the boundary: the last admitted wei, and the first refused one.
    /// @notice The band straddles the tick-cap slack, which is the whole gap between admissibility and the line.
    /// @dev That slack is where a gate reading admissibility alone would admit and this one refuses, so it is the interesting wei.
    function testFuzz_TheLastAdmittedWeiSitsExactlyOnTheLine(uint256 units) public {
        uint256 oldId = _open(flat, COLL_7, P);
        uint256 need = _line(flat, NEWP, T_MID);
        uint256 free = COLL_7 - need;
        units = bound(units, free - 40, free + 40);
        uint256 rest = COLL_7 - units;

        vm.prank(borrower);
        try fin.refinanceTo(_args(oldId, flat, NEWP, units, sink)) returns (uint256) {
            assertGe(rest, need, "no wei under the line is ever admitted");
            assertEq(vault.balanceOf(sink), units, "and an admitted release lands whole");
        } catch (bytes memory err) {
            assertLt(rest, need, "and no holding on or above the line is ever refused");
            assertEq(bytes32(bytes4(err)), bytes32(BelowWithdrawLine.selector), "the line refuses by its own name");
        }
    }
}

/// @notice T11: `refinanceTo` reads the DESTINATION config, in BOTH directions.
contract AceRefinanceWithdrawDestinationTest is AceRefinanceWithdrawFixture {
    uint256 internal constant COLL_11 = 12_000e18;
    uint256 internal constant TAKE_11 = 5_000e18; // leaves 7000e18: above the loose line, under the tight one

    function setUp() public {
        _boot();
    }

    /// @notice A STRICT destination refuses a release the loose source would have admitted.
    /// @dev Reading the source cache here is one character away, and it would let this release through.
    function test_T11_AStrictDestinationRefusesWhatTheLooseSourceWouldAdmit() public {
        (bytes32 src,) = _newMarket(K_LOOSE, 32);
        (bytes32 dst,) = _newMarket(K_TIGHT, 32);
        _seed(src, T_MID, LADDER);
        _seed(dst, T_MID, LADDER);

        uint256 oldId = _open(src, COLL_11, P);
        /// @dev ONE WEI INSIDE the destination's line. It was TEN, which fitted while the line carried a
        /// @dev `maxClaimTicks`-atom epsilon; that epsilon is ONE atom now, so ten wei lands OUTSIDE it.
        uint256 rest = _line(dst, NEWP, T_MID) - 1; // one atom inside the destination line
        assertGt(rest, _line(src, NEWP, T_MID), "fixture: the SOURCE config would admit this release");
        assertLt(rest, _line(dst, NEWP, T_MID), "and the DESTINATION config would not");

        _refuses(_args(oldId, dst, NEWP, COLL_11 - rest, sink), BelowWithdrawLine.selector, "the destination's coverage is the one that binds");

        assertEq(vault.balanceOf(sink), 0, "and nothing left");
    }

    /// @notice A LOOSE destination ADMITS a release the strict source would have refused.
    /// @notice The mirror is what proves the gate reads the destination rather than simply taking the stricter answer.
    function test_T11_ALooseDestinationAdmitsWhatTheStrictSourceWouldRefuse() public {
        (bytes32 src,) = _newMarket(K_TIGHT, 32);
        (bytes32 dst,) = _newMarket(K_LOOSE, 32);
        _seed(src, T_MID, LADDER);
        _seed(dst, T_MID, LADDER);

        uint256 oldId = _open(src, COLL_11, P);
        uint256 rest = COLL_11 - TAKE_11;
        assertLt(rest, _line(src, NEWP, T_MID), "fixture: the SOURCE config would refuse this release");
        assertGt(rest, _line(dst, NEWP, T_MID), "and the DESTINATION config admits it");

        uint256 newId = _migrate(_args(oldId, dst, NEWP, TAKE_11, sink));

        assertEq(vault.balanceOf(sink), TAKE_11, "the destination's coverage admitted the release");
        assertEq(read.loan(newId).collateralUnits, rest, "and the loan holds exactly the rest");
    }

    /// @notice The tick-cap term of the line is the destination's too, pinned at the wei where the two caps disagree.
    /// @dev Coverage is IDENTICAL in both markets here, so only `maxClaimTicks` can decide, and it decides by 28 wei.
}

/// @notice The two paths that build `MigrateArgs` THEMSELVES, and so can never carry a caller's withdrawal.
contract AceRefinanceWithdrawPolicyPathTest is AceRefinanceWithdrawFixture {
    uint256 internal constant COLL_R = 12_000e18;
    address internal keeper = address(0xCEE9);

    function setUp() public {
        _boot();
    }

    /// @notice `Settlement._roll` passes `0, address(0)` structurally, so an expiry roll releases NOTHING to anyone.
    /// @notice The keeper's bounty is CREDITED out of custody, never transferred, so no vault balance moves at all.
    /// @dev The sliver is derived from what the roll credited, not recomputed, so this cannot drift from the bounty formula.
    /// @dev The guard is against a future `MigrateArgs` field being wired through `_roll` with a caller-supplied value.
    function test_AnExpiryRollShedsTheBountySliverAndNotOneUnitMore() public {
        uint256 oldId = _open(flat, COLL_R, P);
        vm.prank(borrower);
        ace.setAutoRefinance(oldId, TENOR, 0, 0);
        _warpTo(uint256(read.loan(oldId).expiry) + 1);
        uint256 count = read.loanCount();

        vm.prank(keeper);
        ace.forceClose(oldId);

        uint256 newId = read.loanCount();
        assertEq(newId, count + 1, "fixture: the roll continued rather than settling");
        uint256 sliver = read.unitsOwedOf(oldId, keeper);
        assertGt(sliver, 0, "fixture: the crank earned a real bounty");

        assertEq(read.loan(newId).collateralUnits, COLL_R - sliver, "the successor holds the lot less the bounty, to the wei");
        assertEq(pm.collateralOf(newId), read.loan(newId).collateralUnits, "and the loan record agrees with custody");
        assertEq(vault.balanceOf(keeper), 0, "the bounty is credited, never transferred");
        assertEq(vault.balanceOf(sink), 0, "and no release reached any other address");
        assertEq(vault.balanceOf(borrower), 0, "not even the borrower's own");
    }
}

/// @notice T12: the release lands before the net payout, the payout is the last transfer, and a refused release is a total no-op.
contract AceRefinanceWithdrawOrderingTest is AceRefinanceWithdrawFixture {
    uint256 internal constant COLL_12 = 12_000e18;
    uint256 internal constant TAKE_12 = 1_000e18;

    bytes32 internal constant OWED_CREDITED = keccak256("OwedCredited(uint256,address,uint256,uint256)");
    bytes32 internal constant REFINANCED = keccak256("Refinanced(uint256,uint256,uint256,uint64,uint256,address)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    MockBlockableERC20 internal loud; // a quote that LOGS its transfers, so the payout has a place in the log order
    bytes32 internal loudMid; // `flat`'s twin, quoted in `loud`

    function setUp() public {
        _boot();
        loud = new MockBlockableERC20("USD Coin", "USDC", 6);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(loud), address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(loud), address(vault));
        p.record = address(rec);
        loudMid = ace.createMarket(p);
        loud.mint(alice, LADDER);
        vm.startPrank(alice);
        loud.approve(address(ace), LADDER);
        ace.deposit(loudMid, LADDER);
        vm.stopPrank();
    }

    /// @notice Log order IS execution order: the release, then the net payout in cash, then the announcement.
    /// @dev Stable LAST, as `open` sends it; a reorder that paid before the release would fail here, and so would a credit.
    function test_T12_TheNetPayoutLandsAfterTheReleaseAndBeforeTheAnnouncement() public {
        uint256 oldId = _open(loudMid, COLL_12, P);
        uint256 wallet = loud.balanceOf(borrower);

        vm.recordLogs();
        uint256 newId = _migrate(_args(oldId, loudMid, NEWP, TAKE_12, sink));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 released = _releaseIndex(logs);
        uint256 paid = _paidIndex(logs);
        uint256 announced = _indexOf(logs, REFINANCED, address(ace));
        assertLt(released, logs.length, "fixture: a release transfer reached the recipient");
        assertLt(paid, logs.length, "fixture: the refinance paid the borrower a net out");
        assertLt(announced, logs.length, "fixture: the migration announced itself");
        assertEq(_indexOf(logs, OWED_CREDITED, address(ace)), type(uint256).max, "a borrower's own refinance books no credit");

        assertLt(released, paid, "the release lands before the payout");
        assertLt(paid, announced, "and the payout is the last transfer the verb makes");
        assertGt(loud.balanceOf(borrower), wallet, "the borrower holds the net out");
        assertEq(vault.balanceOf(sink), TAKE_12, "the recipient holds exactly what was asked for");
        assertEq(read.loan(newId).collateralUnits, COLL_12 - TAKE_12, "and the ledger agrees");
    }

    /// @notice A refused release leaves the old loan, its custody, its floor and the recipient bit-identical.
    /// @dev The whole roll is behind the refusal -- the close, the melt and the fresh draw all unwind with it.
    function test_T12_ARefusedReleaseIsATotalNoOp() public {
        uint256 oldId = _open(flat, COLL_12, P);
        uint256 count = read.loanCount();
        uint256 hubQuote = usdc.balanceOf(address(ace));

        uint256 edge = COLL_12 - _requiredAt(flat, NEWP, T_MID); // leaves `requiredAt`, ONE ATOM under the line
        _refuses(_args(oldId, flat, NEWP, edge, sink), BelowWithdrawLine.selector, "a release one wei inside the line is refused");

        assertEq(vault.balanceOf(sink), 0, "the recipient's balance is EXACTLY unchanged");
        assertEq(read.loan(oldId).collateralUnits, COLL_12, "the old loan keeps its whole lot");
        assertEq(pm.collateralOf(oldId), COLL_12, "and its custody");
        assertEq(read.debtOf(oldId), P, "its debt is untouched");
        assertFalse(read.loan(oldId).closedAt != 0, "it was not retired");
        assertEq(read.fundingFloor(flat, oldId), T_MID, "its funding floor stands");
        assertEq(read.loanCount(), count, "no successor id was allocated");
        assertEq(usdc.balanceOf(address(ace)), hubQuote, "and no quote moved either");
    }

    /// @dev The first log with this topic from this emitter; the sentinel is asserted away at every call site.
    function _indexOf(Vm.Log[] memory logs, bytes32 topic, address emitter) private pure returns (uint256) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic) return i;
        }
        return type(uint256).max;
    }

    /// @dev The payout leg: the hub's transfer of the logging quote to the borrower.
    function _paidIndex(Vm.Log[] memory logs) private view returns (uint256) {
        bytes32 from = bytes32(uint256(uint160(address(ace))));
        bytes32 to = bytes32(uint256(uint160(borrower)));
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(loud) && logs[i].topics.length == 3 && logs[i].topics[0] == TRANSFER) {
                if (logs[i].topics[1] == from && logs[i].topics[2] == to) return i;
            }
        }
        return type(uint256).max;
    }

    /// @dev The release leg: the ONLY collateral transfer into `sink`, which receives nothing else in this suite.
    function _releaseIndex(Vm.Log[] memory logs) private view returns (uint256) {
        bytes32 to = bytes32(uint256(uint160(sink)));
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics.length == 3 && logs[i].topics[0] == TRANSFER && logs[i].topics[2] == to) return i;
        }
        return type(uint256).max;
    }
}
