// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceTenorSentinel
/// @notice #738 I-2: a zero tenor means the market's `minTenor` on EVERY door that takes a term, through one helper.
/// @notice `open`, `previewOpen`, `refinance`, `refinanceTo` and `postOrder` resolve it; `setAutoRefinance` keeps zero as disarm.
/// @dev `Refinanced` and `OrderPosted` log the RESOLVED term, so an indexer never sees a zero that no loan carries.
contract AceTenorSentinelTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id; // 7d to 28d
    bytes32 internal dst; // the same pair at 14d to 28d: its own `minTenor` resolves a routed zero

    address internal alice = AceFixtures.LENDER;
    address internal borrower = address(0xB0B);
    address internal filler = address(0xF111);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN14 = 14 days;
    uint64 internal constant TEN28 = 28 days;
    uint256 internal constant P = 10_000e6;
    uint256 internal constant UNITS = 20_000e18;

    bytes32 internal constant REFINANCED = keccak256("Refinanced(uint256,uint256,uint256,uint64,uint256,address)");
    bytes32 internal constant ORDER_POSTED = keccak256("OrderPosted(uint256,bytes32,address,uint256,uint256,uint256,uint64,uint64)");

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.minTenor = TEN7;
        p.maxTenor = TEN28;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        p.minTenor = TEN14;
        dst = ace.createMarket(p);
        _deposit(id);
        _deposit(dst);
        coll.mint(borrower, 10 * UNITS);
        usdc.mint(borrower, P);
        vm.startPrank(borrower);
        coll.approve(address(pm), type(uint256).max);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(bytes32 m) internal {
        usdc.mint(alice, 4 * P);
        vm.startPrank(alice);
        usdc.approve(address(ace), 4 * P);
        ace.deposit(m, 4 * P);
        vm.stopPrank();
    }

    function _open(uint64 tenor) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = ace.open(id, UNITS, P, tenor, borrower, OpenBounds(0, 0, 0));
    }

    /// @dev The tenor field of the one `topic0` log the hub emitted; reverts the row when it is absent.
    function _loggedTenor(bytes32 topic0, uint256 slot) internal returns (uint64 t) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length == 0 || logs[i].topics[0] != topic0) continue;
            bytes memory data = logs[i].data;
            assembly ("memory-safe") {
                t := mload(add(add(data, 0x20), mul(slot, 0x20)))
            }
            return t;
        }
        revert("the event was not emitted");
    }

    /// @notice `refinance` with a zero tenor lands a `minTenor` loan, and `Refinanced` logs that term.
    function test_ARefinanceWithAZeroTenorLandsAMinTenorLoan() public {
        uint256 loanId = _open(TEN28);
        vm.recordLogs();
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, P, 0, OpenBounds(0, 0, 0));
        assertEq(read.loan(newId).tenor, TEN7, "the successor carries the market's minTenor");
        assertEq(_loggedTenor(REFINANCED, 1), TEN7, "and Refinanced logs it, not the zero");
    }

    /// @notice `refinanceTo` resolves a zero tenor against the DESTINATION's `minTenor`.
    function test_ARefinanceToWithAZeroTenorTakesTheDestinationsMinTenor() public {
        uint256 loanId = _open(TEN28);
        vm.recordLogs();
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, dst, P, 0, OpenBounds(0, 0, 0), 0, address(0)));
        assertEq(read.loan(newId).tenor, TEN14, "the successor carries the destination's minTenor");
        assertEq(_loggedTenor(REFINANCED, 1), TEN14, "and Refinanced logs the destination's term, not the source's or a zero");
    }

    /// @notice CONTROL: a NONZERO tenor passes through every term door unchanged; only zero is the sentinel.
    /// @dev Each re-term draws 2,000 fresh, so its payout retires the old debt whatever the two fees are.
    function test_ANonzeroTenorPassesThroughEveryDoorUnchanged() public {
        uint256 loanId = _open(TEN28);
        assertEq(read.loan(loanId).tenor, TEN28, "open keeps a stated term");
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, P + 2_000e6, TEN14, OpenBounds(0, 0, 0));
        assertEq(read.loan(newId).tenor, TEN14, "refinance keeps a stated term");
        uint256 other = _open(TEN7);
        vm.prank(borrower);
        uint256 movedId = ace.refinanceTo(MigrateArgs(other, dst, P + 2_000e6, TEN28, OpenBounds(0, 0, 0), 0, address(0)));
        assertEq(read.loan(movedId).tenor, TEN28, "refinanceTo keeps a stated term");
        uint256 liq = ace.idToMarketParams(id).price / 2;
        vm.prank(borrower);
        uint256 orderId = ace.postOrder(id, P, liq, liq, P, TEN14, 0);
        assertEq(ace.orderOf(orderId).tenor, TEN14, "postOrder keeps a stated term");
    }

    /// @notice `postOrder` with a zero tenor rests a `minTenor` order; `OrderPosted` and every fill carry that term.
    function test_AnOrderWithAZeroTenorRestsAndFillsAtMinTenor() public {
        uint256 liq = ace.idToMarketParams(id).price / 2;
        vm.recordLogs();
        vm.prank(borrower);
        uint256 orderId = ace.postOrder(id, P, liq, liq, P, 0, 0);
        assertEq(ace.orderOf(orderId).tenor, TEN7, "the order stores the resolved term");
        assertEq(_loggedTenor(ORDER_POSTED, 3), TEN7, "and OrderPosted logs it");
        uint256 escrow = ace.orderOf(orderId).collateralUnits;
        vm.prank(filler);
        uint256 loanId = ace.fillOrder(orderId, P, escrow);
        assertEq(read.loan(loanId).tenor, TEN7, "the fill opens a minTenor loan");
    }

    /// @notice CONTROL: `setAutoRefinance` keeps zero as DISARM; the sentinel never reaches it.
    function test_SetAutoRefinanceKeepsZeroAsDisarm() public {
        uint256 loanId = _open(TEN7);
        vm.startPrank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        vm.stopPrank();
        (uint64 tenor,,) = read.autoPolicyOf(loanId);
        assertEq(tenor, 0, "a zero tenor disarmed rather than arming at minTenor");
    }
}
