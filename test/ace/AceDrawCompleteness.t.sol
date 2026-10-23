// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceDrawCompleteness
/// @notice `drawCount` is the change detector a lender contract caches against, and it counts DRAWS.
/// @dev WAS GAP-1: the count a vault priced against had to equal the classes it could actually book, and
/// @dev the binding invariant was `entitledClasses` == the loans `materialize` accepted for a lot. Both
/// @dev sides of that are gone -- there are no lots to be entitled and no mint to accept -- so what is
/// @dev left is the watermark itself, which still tells a reader whether any draw has happened since.
/// @dev the design record.
contract AceDrawCompletenessTest is Test {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal whale = address(0xBEEF);
    address internal borrower = address(0xB0BA);

    uint256 internal T4; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal constant COLL = 10_000e18;

    uint256[] internal opened;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T4 = _price(960);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(vault)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    function _deposit(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(uint256 principal) internal returns (uint256 id) {
        vault.mint(borrower, COLL);
        usdc.mint(borrower, 100e6);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        usdc.approve(address(ace), 100e6);
        id = ace.open(mid, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        opened.push(id);
    }

    function _withdraw(address who, uint256 amt) internal returns (uint256 paid) {
        vm.prank(who);
        paid = ace.withdraw(mid, amt, who, 0);
    }

    /// @notice THE binding invariant for the WATERMARK: it moves exactly once per draw.
    /// @dev A lender contract skips its completeness walk while this number is unchanged, so a draw
    /// @dev created without moving it would be an unbooked draw a vault reports as complete -- the one
    /// @dev direction the gate must never fail. It counts DRAWS: a market has one price, so a draw is one.
    function test_DrawCountMovesOncePerDraw() public {
        _deposit(alice, 10_000e6);
        assertEq(read.marketState(mid).drawCount, 0, "no draw, no watermark");

        _open(2_000e6);
        assertEq(read.marketState(mid).drawCount, 1, "one draw at the market price");
        _open(3_000e6);
        assertEq(read.marketState(mid).drawCount, 2, "and the next draw is the next");

        uint256 before = read.marketState(mid).drawCount;
        _withdraw(alice, 100e6);
        assertEq(read.marketState(mid).drawCount, before, "a lender exit is no draw and moves nothing");
    }

    /// @dev WAS `..._CountsEveryTickAMultiTickDrawTouches`: a draw spanning two ticks bumped the count twice,
    /// @dev because the counter ticked once per funded bucket. A draw funds at ONE price now, so the count
    /// @dev is one per DRAW -- and the two deposits below, which used to be two rungs, are one balance.
    function test_DrawCountCountsEveryDrawExactlyOnce() public {
        _deposit(alice, 3_000e6);
        vm.startPrank(alice);
        usdc.mint(alice, 3_000e6);
        usdc.approve(address(ace), 3_000e6);
        ace.deposit(mid, 3_000e6);
        vm.stopPrank();

        _open(5_000e6);
        assertEq(read.marketState(mid).drawCount, 1, "one loan, one price, one draw");
        _open(500e6);
        assertEq(read.marketState(mid).drawCount, 2, "and the watermark still moves on the next one");
    }
}

