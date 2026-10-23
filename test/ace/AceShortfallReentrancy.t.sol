// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MarketParams, OpenBounds, Storage} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {RetireProbeManager} from "../mocks/RetireProbeManager.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceShortfallReentrancy
/// @notice A custodian reading the hub back from inside settlement's one external call sees a shortfall of zero.
/// @notice The loan already reads closed at that instant, so the stamp and the record disagree mid-flight.
/// @dev The hub's guard stops a re-entrant WRITE, never a view, which is the surface here.
/// @dev The write cannot move earlier -- `quoteAtBook` does not exist until the claims convert -- so this pins the order.
/// @dev It is also the proof of the lens NatSpec: `shortfallOf` is FINAL only once the close has emitted.
contract AceShortfallReentrancyTest is Test {
    Ace internal ace;
    AceLens internal lens;
    RetireProbeManager internal manager;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal T0; // par for this pair, where a whole-quote claim divides exactly; assigned in setUp
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant LADDER = 20_000e6;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant DRAW = 4_500e6;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    /// @dev PositionManager stand-in FIRST at the hub's predicted address, exactly as the real fixture orders it.
    /// @dev Everything the prediction must not disturb is deployed before the nonce is read.
    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        T0 = _price(0);

        address predictedHub = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        manager = new RetireProbeManager(predictedHub);
        ace = new Ace(AceFixtures.TREASURY, address(manager), AceFixtures.PUSH_GAS);

        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(type(uint256).max); // inert: the record is here for the settlement rule, not for a price
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        mid = ace.createMarket(p);
        lens = new AceLens(address(ace));

        usdc.mint(alice, LADDER);
        vm.startPrank(alice);
        usdc.approve(address(ace), LADDER);
        ace.deposit(mid, LADDER);
        vm.stopPrank();
    }

    // ---- helpers ----

    function _open() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(manager), COLL);
        loanId = ace.open(mid, COLL, DRAW, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Units this loan's live claim needs at its pre-committed price, ceiled as settlement ceils.
    /// @dev WAS a sum over the funded ticks, each at its own price; there is one claim at one price now.
    function _needNow(uint256 loanId) internal view returns (uint256) {
        uint256 amt = lens.claimOf(mid, loanId);
        if (amt == 0) return 0;
        uint256 price = lens.fundingFloor(mid, loanId);
        return (amt * UNIT_SCALE + price - 1) / price;
    }

    /// @dev The debt-based in-kind sliver, mirroring `LoanAccounting.sliverUnits`.
    function _sliver(uint256 loanId) internal view returns (uint256) {
        uint256 floorPrice = lens.fundingFloor(mid, loanId);
        if (floorPrice == 0) return 0;
        return (lens.loan(loanId).debt * ace.idToMarketParams(mid).settleBountyBps * UNIT_SCALE) / (10000 * floorPrice);
    }

    /// @dev Stages collateral scarcity directly, the way `AceSettlement` does and for the same reason:
    /// @dev no in-protocol route reaches a short settlement on an admitted loan, so the code is defensive.
    /// @dev Writing `collateralUnits` touches no other field and leaves the custodian's real balance alone.
    function _shortenTo(uint256 loanId, uint256 units) internal {
        uint256 loanSlot = uint256(keccak256(abi.encode(loanId, uint256(Storage.BOOK) + 1)));
        vm.store(address(ace), bytes32(loanSlot + 2), bytes32(units)); // word 2 == collateralUnits
    }

    // ============ the mid-flight reading ============

    /// @notice CLAIM UNDER TEST: from inside the custody hop the shortfall reads ZERO on a loan that will be short.
    /// @notice The same read after the call returns the real figure, so this is a pin on ORDER, not on the value.
    /// @dev A reorder that wrote the record before `retireCustody` would make the mid-flight read non-zero.
    /// @dev Both halves are asserted in one test so an always-zero reader cannot satisfy the zero half alone.
    function test_ShortSettlement_ShortfallIsInvisibleFromInsideTheCustodyHop() public {
        uint256 loanId = _open();
        uint256 need = _needNow(loanId);
        uint256 claim = lens.claimOf(mid, loanId);
        _shortenTo(loanId, (need * 60) / 100);
        uint256 left = lens.loan(loanId).collateralUnits - _sliver(loanId);
        assertLt(left, need, "fixture: the position is actually short against its live claims");

        manager.arm(address(lens), mid, loanId);
        vm.warp(uint256(lens.loan(loanId).expiry) + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertEq(manager.snaps(), 1, "the custody hop fired exactly once, so the probe really did read");
        assertTrue(manager.closedSeen(), "mid-flight the loan is ALREADY closed");
        assertEq(manager.unitsSeen(), 0, "and its live collateral is ALREADY zero");
        assertEq(manager.claimSeen(), claim, "while the claims it will short are still LIVE: the window is torn");
        assertEq(manager.shortUnitsSeen(), 0, "yet the shortfall reads zero, because it is not written yet");
        assertEq(manager.shortQuoteSeen(), 0, "both halves of it");

        (uint256 units, uint256 quoteAtBook) = lens.shortfallOf(loanId);
        assertEq(units, need - left, "and after the close the same read carries the real gap");
        assertEq(quoteAtBook, claim - (left * T0) / UNIT_SCALE, "valued at the funding tick");
        assertGt(quoteAtBook, 0, "which is non-zero, so the zeros above are an ORDER fact and not a dead reader");
    }

    /// @notice CONTROL: a covered close fires the same hop and reads zero at both instants.
    /// @notice So the row above cannot be satisfied by a settlement that simply never reaches the write site.
    function test_CoveredSettlement_ReadsZeroAtBothInstants() public {
        uint256 loanId = _open();
        uint256 need = _needNow(loanId);
        assertGe(lens.loan(loanId).collateralUnits, need, "fixture: covered, nothing is short");

        manager.arm(address(lens), mid, loanId);
        vm.warp(uint256(lens.loan(loanId).expiry) + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);

        assertEq(manager.snaps(), 1, "the same hop fired");
        assertTrue(manager.closedSeen(), "on a loan already closed");
        assertEq(manager.shortUnitsSeen(), 0, "and it was short of nothing mid-flight");
        (uint256 units, uint256 quoteAtBook) = lens.shortfallOf(loanId);
        assertEq(units, 0, "nor after");
        assertEq(quoteAtBook, 0, "in either half");
        uint256 pot = lens.invPotOf(mid, loanId);
        assertEq(pot, need, "the pot proves the write site was reached and declined");
    }
}
