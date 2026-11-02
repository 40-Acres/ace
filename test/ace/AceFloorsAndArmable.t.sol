// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {BelowMinLot, WouldLeaveDust} from "../../src/ace/hub/Lender.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceFloorsAndArmable
/// @notice Salvaged from the retired roll-reserve hardening suite: the lender doors' floor on cash alone, a home re-term's recycle,
/// @notice and the lens read that remains.
/// @dev The lender doors are pinned at the SHIPPED `minPrincipal`, where the floor is far over an extension's fee.
/// @dev Expected values come from the decision record's sentences or the fee algebra, never from the hub's own predicate.
contract AceFloorsAndArmableTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id; // the fixture market, `minPrincipal = 10e6`, for rows where the floor plays no part
    bytes32 internal twin; // same pair and terms, another lender: a legal routed destination

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0BB);
    address internal borrower = address(0xB0B);
    address internal borrower2 = address(0xB0B2);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN28 = 28 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;
    uint256 internal constant FLOOR = PocDeployConfig.MIN_PRINCIPAL;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(alice));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        twin = ace.createMarket(_params(bob));
    }

    function _params(address lender) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = lender;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN28;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
    }

    /// @dev The same terms at the shipped `minPrincipal`; call once per row, since a second create names the same market.
    function _shipped() internal returns (bytes32 sid) {
        MarketParams memory p = _params(alice);
        p.minPrincipal = FLOOR;
        sid = ace.createMarket(p);
    }

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _openIn(bytes32 mid, address who, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(who, UNITS);
        vm.startPrank(who);
        coll.approve(address(pm), UNITS);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, UNITS, principal, TEN7, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The lender takes `mid` down to exactly `keep`; zero empties it, which is always allowed.
    function _withdrawTo(bytes32 mid, address lender, uint256 keep) internal {
        uint256 out = keep == 0 ? type(uint256).max : ace.restingOf(mid) - keep; // hoisted: a call in the argument list eats the prank
        vm.prank(lender);
        ace.withdraw(mid, out, lender, 0);
        assertEq(ace.restingOf(mid), keep, "fixture: the market rests exactly what the row asks");
    }

    /// @dev A live loan in a shipped-floor market resting `P` beside it.
    function _loanShipped() internal returns (bytes32 sid, uint256 loanId) {
        sid = _shipped();
        _deposit(sid, alice, 2 * P);
        loanId = _openIn(sid, borrower, P);
        assertLt(FLOOR, ace.restingOf(sid), "PREMISE: more than a whole floor rests beside the live loan");
    }

    /* ================================================================= */
    /*  the deposit door's floor, on what arrives                         */
    /* ================================================================= */

    /// @notice THE DEPOSIT FLOOR, fuzzed: under `minPrincipal` a lot never lands, beside a live loan and in an empty market alike.
    function testFuzz_ASubFloorDepositNeverLands(uint256 keepSeed, uint256 lotSeed, bool empty) public {
        (bytes32 sid,) = _loanShipped();
        uint256 resting = ace.restingOf(sid);
        uint256 keep = empty ? 0 : bound(keepSeed, FLOOR, resting - 1);
        _withdrawTo(sid, alice, keep);
        uint256 lot = bound(lotSeed, 1, FLOOR - 1);
        usdc.mint(alice, lot);
        vm.startPrank(alice);
        usdc.approve(address(ace), lot);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(sid, lot);
        vm.stopPrank();
        assertEq(ace.restingOf(sid), keep, "the lot rested nothing");
    }

    /// @notice A market resting a whole floor beside a live loan refuses a one-atom lot `BelowMinLot`.
    /// @dev The deterministic twin of the fuzz row, at the SHIPPED floor, so it never waits on a seed.
    function test_AHealthyMarketRefusesAOneAtomLotBelowTheFloor() public {
        (bytes32 sid,) = _loanShipped();
        _withdrawTo(sid, alice, FLOOR);
        assertEq(ace.idToMarketParams(sid).minPrincipal, 10000e6, "PREMISE: the shipped minPrincipal, the lender door's floor");
        usdc.mint(alice, 1);
        vm.startPrank(alice);
        usdc.approve(address(ace), 1);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(sid, 1);
        vm.stopPrank();
        assertEq(ace.restingOf(sid), FLOOR, "nothing rested");
    }

    /* ================================================================= */
    /*  the withdraw door's floor, on cash alone                          */
    /* ================================================================= */

    /// @notice THE WITHDRAW RULE, fuzzed: a partial withdraw may leave nothing or at least a whole floor, a live loan notwithstanding.
    /// @dev Aimed so half the range lands in the refused band `(0, minPrincipal)`, and both edges are reachable.
    function testFuzz_AWithdrawLeavesAWholeFloorOrNothing(uint256 leftSeed) public {
        (bytes32 sid,) = _loanShipped();
        uint256 resting = ace.restingOf(sid);
        uint256 left = bound(leftSeed, 1, 2 * FLOOR);
        bool allowed = left >= FLOOR;
        vm.prank(alice);
        if (!allowed) vm.expectRevert(WouldLeaveDust.selector);
        ace.withdraw(sid, resting - left, alice, 0);
        assertEq(ace.restingOf(sid), allowed ? left : resting, "the withdraw left what the rule allows, or nothing moved");
    }

    // the re-arm and keeper-fold rows went with arming and the fold

    /* ================================================================= */
    /*  the home recycle is capped at the successor's principal           */
    /* ================================================================= */

    /// @notice A home refinance to LESS than the old debt draws no cash and hands the lender back exactly the difference.
    /// @notice The claim recycles only on the lender's roll policy's yes, so the lender installs one first.
    /// @dev Kills the recycle returning the whole old claim (the draw underflows) and the melt crediting the whole claim as owed.
    function test_AHomeRefinanceUnderTheOldDebtHandsTheLenderTheDifference() public {
        AceFixtures.installYesPolicy(ace, alice);
        _deposit(id, alice, 2 * P);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        uint256 loanId = ace.open(id, UNITS, P, TEN28, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        uint256 x = 100e6;
        uint256 np = P - x; // the long term's refund covers the short term's fee and the shortfall, so the refinance nets
        uint256 cashBefore = ace.restingOf(id);
        (uint256 restBefore, uint256 lentBefore, uint256 owedBefore) = read.lenderPools(alice, address(usdc));
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, id, np, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        (uint256 restAfter, uint256 lentAfter, uint256 owedAfter) = read.lenderPools(alice, address(usdc));
        MarketParams memory p = ace.idToMarketParams(id);
        uint256 tick = LoanMath.tickCut(LoanMath.originationFee(np, TEN7, p.baseBps, p.minTenor));
        assertEq(ace.restingOf(id), cashBefore, "the successor drew no fresh cash");
        assertEq(restAfter, restBefore, "and the lender's resting pool did not move");
        assertEq(lentBefore - lentAfter, x, "lent carries only the smaller successor");
        assertEq(owedAfter - owedBefore, x + tick, "the lender is owed the principal not re-lent, plus the draw's fee share");
        assertEq(read.claimOf(id, newId), np, "the successor's claim is its whole principal");
    }

    /* ================================================================= */
    /*  the lens reads that remain                                        */
    /* ================================================================= */

    /// @notice `marketState` decodes `drawCount` out of a word whose freed tail stays zero, and a second draw bumps only the count.
    function test_TheLensMarketStateDecodesTheDrawCount() public {
        (bytes32 sid,) = _loanShipped();
        assertEq(lens.marketState(sid).drawCount, 1, "the draw count reads one draw");
        _openIn(sid, borrower2, FLOOR);
        assertEq(lens.marketState(sid).drawCount, 2, "a second draw bumps the count");
        assertEq(uint256(ace.extsload(bytes32(read.cashSlot(sid) + 1))) >> 64, 0, "and the word's freed tail stays zero");
    }

    // the `armable` row went with the lens view
}
