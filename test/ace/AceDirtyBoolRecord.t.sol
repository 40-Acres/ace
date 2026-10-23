// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {RecordUnreadable} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @notice A record whose two persisted questions answer a RAW word: 0 and 1 are clean bools, anything else is malformed.
/// @dev Genesis decodes those questions typed, so the word stays 0 until the market exists.
contract DirtyBoolRecord {
    uint256 public word;
    uint256 public price;

    constructor(uint256 p) {
        price = p;
    }

    function setWord(uint256 w) external {
        word = w;
    }

    function supportsPair(address, address) external pure returns (bool) {
        return true;
    }

    function minPrice(address, address) external view returns (uint256) {
        return price;
    }

    function lastObserved(address, address) external pure returns (uint256) {
        return 1;
    }

    function persistedBelowDistress(address, address, uint256) external view returns (uint256) {
        return word;
    }

    function persistedBelowSettle(address, address, uint256) external view returns (uint256) {
        return word;
    }
}

/// @title AceDirtyBoolRecord
/// @notice Run 251533 YI-4: a below-answer outside `{0, 1}` is NO answer and refuses `RecordUnreadable`, never a permissive false.
/// @notice Folded to `false` it read as "not distressed" at `deleverage`'s guard and "not settleable" at `finalize`.
contract AceDirtyBoolRecordTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    DirtyBoolRecord internal rec;
    bytes32 internal id;
    uint256 internal loanId;

    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new DirtyBoolRecord(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.deleverageFloorEpsBps = 100;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 5000;
        p.deleverageStopBps = 1000;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, id) = (d.ace, d.positionManager, d.id);
        usdc.mint(AceFixtures.LENDER, 100_000e6);
        vm.startPrank(AceFixtures.LENDER);
        usdc.approve(address(ace), 100_000e6);
        ace.deposit(id, 100_000e6);
        vm.stopPrank();
        coll.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        coll.approve(address(pm), 100_000e18);
        loanId = ace.open(id, 100_000e18, 50_000e6, 7 days, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        rec.setWord(2);
    }

    /// @notice `deleverage` refuses a malformed distress answer by name rather than reading it as "not distressed".
    function test_AMalformedDistressAnswerRefusesTheDeleverageCrank() public {
        vm.prank(keeper);
        vm.expectRevert(RecordUnreadable.selector);
        ace.deleverage(loanId, 0, "");
    }

    /// @notice `finalize` refuses a malformed settle answer by name rather than reading it as "not settleable".
    function test_AMalformedSettleAnswerRefusesFinalize() public {
        vm.prank(keeper);
        vm.expectRevert(RecordUnreadable.selector);
        ace.finalize(loanId);
    }

    /// @notice EVERY word past one is no answer, at both doors: the rail is `word > 1`, so 2 and `type(uint256).max` alike refuse.
    function testFuzz_AnyWordPastOneRefusesBothDoors(uint256 w) public {
        rec.setWord(bound(w, 2, type(uint256).max));
        vm.startPrank(keeper);
        vm.expectRevert(RecordUnreadable.selector);
        ace.deleverage(loanId, 0, "");
        vm.expectRevert(RecordUnreadable.selector);
        ace.finalize(loanId);
        vm.stopPrank();
    }

    /// @notice CONTROL: a clean 1 is an answer, so `finalize` reads it as settleable and moves title.
    function test_ACleanTrueSettles() public {
        rec.setWord(1);
        vm.prank(keeper);
        ace.finalize(loanId);
        assertTrue(ace.isClosed(loanId), "a clean true is a settle answer, not an unreadable one");
    }

    /// @notice CONTROL: a clean 0 still reads "not settleable", the retry-later answer.
    function test_ACleanFalseStillReadsNotSettleable() public {
        rec.setWord(0);
        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("NotSettleable()")));
        ace.finalize(loanId);
    }
}
