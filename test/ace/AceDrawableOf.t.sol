// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceDrawableOf
/// @notice `Ace.drawableOf` is PER MARKET: resting cash less the roll reserve, floored at zero, and zero for an unknown id.
/// @notice It must equal the lens's `drawableOf` in every reserve state, and it must BE the draw's own cash boundary.
/// @dev The boundary rows run with a Live record whose cap sits over the market's price, so `InsufficientCash` can only mean cash.
contract AceDrawableOfTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's one lender
    address internal borrower = address(0xB0B);
    address internal drawer = address(0xD4A3); // a second borrower, whose fresh draw the boundary rows quote

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 1_000_000e18; // worth a million at par: collateral never binds a draw here

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll))); // Live, and over the price: the cap never binds
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _openArmed(uint256 principal, bool armIt) internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, principal, TEN7, borrower, OpenBounds(0, 0, 0));
        if (armIt) ace.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
    }

    /// @dev The lender takes the market down to exactly `keep`; under or at the reserve always lands.
    function _withdrawTo(uint256 keep) internal {
        uint256 out = ace.restingOf(id) - keep; // hoisted: a call in the argument list eats the prank
        vm.prank(alice);
        ace.withdraw(id, out, alice, 0);
    }

    function _assertBoth(bytes32 mid, uint256 want, string memory why) internal view {
        assertEq(ace.drawableOf(mid), want, why);
        assertEq(lens.drawableOf(mid), want, string.concat(why, ": the lens reads the same"));
    }

    /// @notice PARITY with the lens across every reserve state: none, armed, exactly the reserve, a lender's deficit, and no market.
    function test_Parity_TheHubAndTheLensAgreeInEveryReserveState() public {
        _assertBoth(id, 0, "an empty market has nothing to draw");
        _deposit(2 * P);
        _assertBoth(id, 2 * P, "with no reserve, everything resting is drawable");

        _openArmed(P, true);
        uint256 rr = read.rollReserve(id);
        assertGt(rr, 0, "PREMISE: the armed loan reserved");
        _assertBoth(id, ace.restingOf(id) - rr, "armed: resting less the roll reserve");

        _withdrawTo(rr);
        _assertBoth(id, 0, "exactly the reserve resting leaves nothing drawable");
        _withdrawTo(rr / 2);
        _assertBoth(id, 0, "a lender's deficit floors at zero rather than reverting");
        assertGt(ace.restingOf(id), 0, "while cash still rests");

        _assertBoth(keccak256("no market was ever created at this id"), 0, "an unknown id reads zero");
    }

    /// @notice PER MARKET, never pooled: a reserve in one of a lender's markets nets that market alone, on the hub and the lens alike.
    /// @dev The second market is the first's params with one inert field moved, so the same lender rests in both.
    function test_PerMarket_AReserveNetsOnlyItsOwnMarket() public {
        MarketParams memory p2 = ace.idToMarketParams(id);
        p2.settleBountyBps += 1; // a distinct id; nothing the cash test reads
        bytes32 id2 = ace.createMarket(p2);
        _deposit(2 * P);
        usdc.mint(alice, P);
        vm.startPrank(alice);
        usdc.approve(address(ace), P);
        ace.deposit(id2, P);
        vm.stopPrank();

        _openArmed(P, true);
        uint256 rr = read.rollReserve(id);
        assertGt(rr, 0, "PREMISE: the armed loan reserved in the first market");
        assertEq(read.rollReserve(id2), 0, "PREMISE: and nothing in the second");
        _assertBoth(id, ace.restingOf(id) - rr, "the first market nets its own reserve");
        _assertBoth(id2, P, "the second market's drawable is its whole resting cash");
    }

    /// @notice FUZZ (the draw's own boundary): a fresh draw clears the cash test IFF it is at most `drawableOf`.
    /// @notice And one atom past `drawableOf` refuses `InsufficientCash`, so the view is the rule and not an estimate of it.
    /// @dev Bounded to `fresh >= minDebt` and a Live record capped over the price, so no other rail answers first.
    function testFuzz_TheViewIsTheDrawsOwnCashBoundary(uint256 depositSeed, uint256 principalSeed, bool armIt, uint256 keepSeed, uint256 freshSeed) public {
        uint256 minDebt = ace.idToMarketParams(id).minDebt;
        uint256 dep = bound(depositSeed, 4 * minDebt, 400_000e6);
        _deposit(dep);
        _openArmed(bound(principalSeed, minDebt, dep / 2), armIt);
        uint256 out = ace.restingOf(id) - bound(keepSeed, 0, ace.restingOf(id)); // hoisted: a call in the argument list eats the prank
        vm.prank(alice);
        try ace.withdraw(id, out, alice, 0) {} catch {} // a dust remainder is refused, and the state stays

        uint256 drawable = ace.drawableOf(id);
        assertEq(drawable, lens.drawableOf(id), "the hub and the lens agree");
        uint256 fresh = bound(freshSeed, minDebt, ace.restingOf(id) + minDebt);
        bool admitted = _previews(fresh);
        assertEq(admitted, fresh <= drawable, "the draw clears the cash test exactly when it fits under drawableOf");
        if (drawable + 1 >= minDebt) {
            assertFalse(_previews(drawable + 1), "and one atom past it is refused");
        }
    }

    /// @dev Whether a fresh draw of `fresh` previews clean; any refusal must be the cash rail's.
    function _previews(uint256 fresh) internal view returns (bool) {
        try ace.previewOpen(id, UNITS, fresh, 0, drawer, OpenBounds(0, 0, 0)) {
            return true;
        } catch (bytes memory err) {
            assertEq(bytes4(err), InsufficientCash.selector, "the only refusal is the cash rail");
            return false;
        }
    }
}
