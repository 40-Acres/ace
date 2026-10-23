// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, InventoryHeld} from "../../src/ace/hub/Ace.sol";
import {HomeRollExclusive, OutsideRefinanceWindow} from "../../src/ace/hub/Borrower.sol";
import {RollWindowOpen} from "../../src/ace/hub/Settlement.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceMinTenorFloorWindows
/// @notice The genesis tenor floor's PROMISE, asked of the verbs rather than of the window helpers' return values.
/// @notice Two flat markets at exactly `MIN_TENOR_FLOOR`, differing only in rate and lender, so a stranger has somewhere to route.
/// @dev `AceGenesisRails` pins the rail, `AceWindowHelperLiterals` the helpers' values; this suite pins what each window DOES there.
/// @dev Instants are named against the loan's own expiry or `closedAt`, never against a literal tenor.
/// @dev Issue #522; the settle-and-buy guarantee is #370's.
contract AceMinTenorFloorWindowsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    bytes32 internal home; // the loan's own market, alice's, baseBps 40
    bytes32 internal rival; // a cheaper stranger at the same floor, downside identical

    address internal alice = address(0xA11CE);
    address internal rivalLender = address(0xF1A5C0);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);
    address internal buyer = address(0xB0FF);

    uint64 internal constant FLOOR = Constants.MIN_TENOR_FLOOR; // the shortest term genesis admits, and every term here
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 400_000e18;
    uint256 internal constant TOP = 1_000_000e6;
    uint256 internal constant BUDGET = 1_000e6; // a partial fill: the rows ask whether the ask is OPEN, not what it clears
    uint16 internal constant BUF = 500; // routing consent needs a risk distance
    uint16 internal constant FEE_CAP = 200; // nonzero, so a keeper may name the destination

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(40, alice));
        (ace, pm, read, home) = (d.ace, d.positionManager, d.read, d.id);
        rival = ace.createMarket(_params(30, rivalLender));
        assertEq(ace.idToMarketParams(home).minTenor, FLOOR, "fixture: the home market sits at the floor");
        assertEq(ace.idToMarketParams(rival).maxTenor, FLOOR, "fixture: and the rival is flat at it too");

        _deposit(home, alice, TOP);
        _deposit(rival, rivalLender, TOP);
        usdc.mint(borrower, 5_000_000e6);
    }

    // ---- fixture ----

    /// @dev Shared record and downside dials, so the two markets differ only where a routed roll is allowed to differ.
    function _params(uint256 baseBps, address lender_) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = baseBps;
        p.lender = lender_;
        (p.minTenor, p.maxTenor) = (FLOOR, FLOOR);
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
    }

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev One loan on the home market, for exactly one floor-length term.
    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(home, COLL, P, FLOOR, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(read.loan(loanId).expiry, _now() + FLOOR, "fixture: the loan runs one floor-length term");
    }

    /// @dev Arm at the floor tenor with routing consent, so both the home roll and a stranger's route are live questions.
    function _arm(uint256 loanId) internal {
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, FLOOR, BUF, FEE_CAP);
    }

    // ---- the roll window, before expiry ----

    /// @notice THE ROLL WINDOW OPENS BEFORE EXPIRY, AND ITS FIRST SECOND IS THE INCUMBENT'S ALONE.
    /// @notice At that instant the home roll is admissible and a stranger's route is refused by name, through the real door.
    /// @dev One second earlier the home roll is itself outside the window, so the edge is the window's and not the fixture's.
    /// @dev A zero window would put that first instant AT expiry, which the premise refuses before any door is asked.
    function test_Floor_TheRollWindowOpensBeforeExpiryAndLeadsWithTheIncumbent() public {
        uint256 loanId = _open();
        _arm(loanId);
        uint256 expiry = read.loan(loanId).expiry;
        uint256 opens = expiry - MarketInit.autoRefinanceWindow(FLOOR);
        assertLt(opens, expiry, "at the floor the roll window must open strictly before expiry");

        _warpTo(opens - 1);
        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, home);
        assertFalse(ok, "one second before the window the home roll is refused");
        assertEq(reason, OutsideRefinanceWindow.selector, "by the window's own name");

        _warpTo(opens);
        (ok,,) = ace.tryContinueTo(loanId, home);
        assertTrue(ok, "at the window's first second the incumbent's own roll is admissible");
        vm.prank(rivalLender);
        vm.expectRevert(HomeRollExclusive.selector);
        ace.refinanceByPolicyTo(loanId, rival);
    }

    /// @notice THE LAST SECOND BEFORE EXPIRY IS OPEN TO A STRANGER'S ROUTE, and that is what a NONZERO `homeRollHold` buys.
    /// @notice The hold is the window's TRAILING share: a stranger is refused until `expiry - homeRollHold`, then admitted.
    /// @dev So a zero hold does not cost the incumbent its prefix; it runs the prefix to expiry and leaves the stranger no second.
    /// @dev Named at `expiry - 1` rather than off `homeRollHold`, so the row states the promise and not the formula.
    function test_Floor_AStrangerMayRouteInTheLastSecondBeforeExpiry() public {
        uint256 loanId = _open();
        _arm(loanId);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);

        vm.prank(rivalLender);
        uint256 newId = ace.refinanceByPolicyTo(loanId, rival);
        assertEq(read.loan(newId).market, rival, "the successor sits in the stranger's market");
        assertEq(read.debtOf(loanId), 0, "and the retiring loan was rolled, not settled");
        assertEq(read.loan(newId).expiry, _now() + FLOOR, "with a whole fresh floor-length term");
    }

    // ---- the roll window, after expiry ----

    /// @notice THE UNPAID BACKSTOP WAITS OUT A NONZERO WINDOW PAST EXPIRY, so the armed roll owns the expiry second.
    /// @notice A zero window would let `settleExpired` end a floor-tenor loan in the very second its roll falls due.
    /// @dev The window is the LOAN's own, `autoRefinanceWindow(L.tenor)`; the loan here runs the floor tenor.
    function test_Floor_TheBackstopCannotSettleInTheExpirySecond() public {
        uint256 loanId = _open();
        _arm(loanId);
        uint256 expiry = read.loan(loanId).expiry;
        uint256 w = MarketInit.autoRefinanceWindow(FLOOR);

        _warpTo(expiry);
        vm.prank(keeper);
        vm.expectRevert(RollWindowOpen.selector);
        ace.settleExpired(loanId);

        _warpTo(expiry + w - 1);
        vm.prank(keeper);
        vm.expectRevert(RollWindowOpen.selector);
        ace.settleExpired(loanId);

        _warpTo(expiry + w);
        vm.prank(keeper);
        ace.settleExpired(loanId);
        assertTrue(ace.isClosed(loanId), "once the window has run, the backstop settles");
    }

    // ---- the inventory hold ----

    /// @notice #370 AT THE FLOOR: a stranger's `forceClose` + `buyInventory` multicall is refused by name.
    /// @notice The pot does not exist until the settle leg runs, so no bidder could win that race at any diligence.
    /// @dev What refuses it is `inventoryHold(minTenor)` being nonzero, which the genesis floor is what guarantees.
    function test_Floor_TheSettlingTransactionCannotAlsoBuyThePot() public {
        uint256 loanId = _open();
        _warpTo(uint256(read.loan(loanId).expiry));
        usdc.mint(buyer, BUDGET);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.forceClose, (loanId));
        calls[1] = abi.encodeCall(Ace.buyInventory, (loanId, BUDGET, 0, buyer));
        vm.startPrank(buyer);
        usdc.approve(address(ace), BUDGET);
        vm.expectRevert(InventoryHeld.selector);
        ace.multicall(calls);
        vm.stopPrank();
    }

    /// @notice THE ASK OPENS INSIDE ONE TERM: refused one second before `closedAt + inventoryHold`, admitted on it.
    /// @dev At the floor the halving leg binds, so the hold is shorter than the market's own term and the ask is not a lockout.
    function test_Floor_TheInventoryHoldLapsesInsideOneTerm() public {
        uint256 loanId = _open();
        _warpTo(uint256(read.loan(loanId).expiry));
        vm.prank(keeper);
        ace.forceClose(loanId);
        uint256 closedAt = _now();
        assertEq(read.loan(loanId).closedAt, closedAt, "fixture: the loan settled in this second");
        uint256 hold = MarketInit.inventoryHold(FLOOR);
        assertGe(hold, 1, "PREMISE: at the floor the hold is at least a second");
        assertLt(hold, FLOOR, "and shorter than one term, so the ask opens inside it");

        usdc.mint(buyer, BUDGET);
        vm.startPrank(buyer);
        usdc.approve(address(ace), BUDGET);
        _warpTo(closedAt + hold - 1);
        vm.expectRevert(InventoryHeld.selector);
        ace.buyInventory(loanId, BUDGET, 0, buyer);

        _warpTo(closedAt + hold);
        (uint256 unitsOut,) = ace.buyInventory(loanId, BUDGET, 0, buyer);
        vm.stopPrank();
        assertGt(unitsOut, 0, "the hold lapsed and the ask opened");
    }
}
