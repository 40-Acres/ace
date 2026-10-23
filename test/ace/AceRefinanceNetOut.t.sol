// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRefinanceNetOut
/// @notice `Refinanced.netOut` is the migration's net out on EVERY door, and it names what really moved.
/// @notice On the borrower's own doors it is the cash the borrower received; on a policy door or the fold it is the credit booked.
/// @dev Each row reads the log and a ledger independently, so a log reporting zero, or the gross draw, fails here.
/// @dev Every prank is taken AFTER its call's arguments are built: a view call in an argument list would spend it.
contract AceRefinanceNetOutTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0x4EE9E4);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant FRESH = 6_000e6; // a successor over the debt, so a strict door has cash to pay
    uint256 internal constant FLOOR = 4_000e6; // under the loan, so a partial repay can leave the debt below it
    uint256 internal constant HOLD = 3.5 days;

    bytes32 internal constant REFINANCED = keccak256("Refinanced(uint256,uint256,uint256,uint64,uint256,address)");

    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = _record();
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(address(record), 10e6));
        (ace, read, mid) = (d.ace, d.read, d.id);
        _deposit(mid, 30_000e6);
    }

    // ---- fixture ----

    /// @dev A record bidding at par, so every draw here funds at the market's own price.
    function _record() internal returns (MockPersistenceRecord r) {
        r = new MockPersistenceRecord(address(usdc), address(vault));
        r.setMinPrice(AceFixtures.priceAt(address(usdc), address(vault), 0));
    }

    function _params(address rec, uint256 minDebt) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = rec;
        p.minDebt = minDebt;
    }

    function _deposit(bytes32 m, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(m, amt);
        vm.stopPrank();
    }

    function _open(bytes32 m) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(ace.POSITION_MANAGER(), COLL);
        loanId = ace.open(m, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev A loan in a market floored at FLOOR, repaid under it by its borrower and armed: its roll draws AT the floor.
    /// @dev That floor is what makes a policy door's net out real rather than dust.
    function _flooredArmedLoan() internal returns (uint256 loanId) {
        bytes32 m = ace.createMarket(_params(address(_record()), FLOOR));
        _deposit(m, 30_000e6);
        loanId = _open(m);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);
        uint64 tenor = ace.idToMarketParams(m).minTenor;
        usdc.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(ace), 1_000e6);
        ace.repay(loanId, 1_000e6);
        ace.setAutoRefinance(loanId, tenor, 0, 0);
        vm.stopPrank();
        assertLt(read.debtOf(loanId), FLOOR, "fixture: the debt sits under the floor, so the roll draws at it");
    }

    /// @dev The one `Refinanced` the hub logged for `oldId`: its successor and its `netOut`.
    function _logged(Vm.Log[] memory logs, uint256 oldId) internal view returns (uint256 newId, uint256 netOut) {
        uint256 hits;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics.length != 4) continue;
            if (logs[i].topics[0] != REFINANCED || logs[i].topics[1] != bytes32(oldId)) continue;
            newId = uint256(logs[i].topics[2]);
            (,, netOut) = abi.decode(logs[i].data, (uint256, uint64, uint256));
            hits++;
        }
        assertEq(hits, 1, "fixture: exactly one Refinanced for the retiring loan");
    }

    /// @dev The net out restated from its terms: the new principal less its fee, plus the unearned refund, less the old debt.
    function _netOutOf(bytes32 m, uint256 loanId, uint256 newPrincipal, uint64 tenor) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(m);
        uint256 fee = LoanMath.originationFee(newPrincipal, tenor, p.baseBps, p.minTenor);
        return newPrincipal - fee + read.earlyExitRefund(loanId) - read.debtOf(loanId);
    }

    // ============ the borrower's own doors: netOut is the cash paid ============

    /// @notice `refinance` logs as `netOut` exactly the cash the borrower received, which is the net out its terms give.
    function test_Refinance_LogsAsNetOutTheCashItPaidTheBorrower() public {
        uint256 loanId = _open(mid);
        _warpTo(t0 + HOLD);
        uint64 tenor = ace.idToMarketParams(mid).minTenor;
        uint256 want = _netOutOf(mid, loanId, FRESH, tenor);
        uint256 wallet = usdc.balanceOf(borrower);
        uint256 hub = usdc.balanceOf(address(ace));

        vm.recordLogs();
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, FRESH, tenor, OpenBounds(0, 0, 0));
        (uint256 loggedId, uint256 netOut) = _logged(vm.getRecordedLogs(), loanId);

        assertEq(loggedId, newId, "the log names the successor the call returned");
        assertGt(netOut, 0, "fixture: a successor over the debt has a net out");
        assertEq(netOut, want, "netOut is the principal less its fee, plus the refund, less the old debt");
        assertEq(usdc.balanceOf(borrower) - wallet, netOut, "and it is exactly the cash the borrower received");
        assertEq(hub - usdc.balanceOf(address(ace)), netOut, "out of the hub, in the one transfer the verb makes");
        (, uint256 owed) = ace.owedOf(loanId, borrower);
        assertEq(owed, 0, "with nothing booked behind it");
    }

    /// @notice `refinanceTo` into a twin market logs the same: `netOut` is the cash the borrower received.
    function test_RefinanceTo_LogsAsNetOutTheCashItPaidTheBorrower() public {
        bytes32 dst = ace.createMarket(_params(address(_record()), 10e6)); // the same pair, distinct by its record
        _deposit(dst, 30_000e6);
        uint256 loanId = _open(mid);
        _warpTo(t0 + HOLD);
        uint64 tenor = ace.idToMarketParams(dst).minTenor;
        uint256 want = _netOutOf(dst, loanId, FRESH, tenor);
        MigrateArgs memory m = MigrateArgs(loanId, dst, FRESH, tenor, OpenBounds(0, 0, 0), 0, address(0));
        uint256 wallet = usdc.balanceOf(borrower);
        uint256 hub = usdc.balanceOf(address(ace));

        vm.recordLogs();
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(m);
        (uint256 loggedId, uint256 netOut) = _logged(vm.getRecordedLogs(), loanId);

        assertEq(read.loan(newId).market, dst, "fixture: the successor lives in the destination");
        assertEq(loggedId, newId, "the log names the successor the call returned");
        assertGt(netOut, 0, "fixture: a successor over the debt has a net out");
        assertEq(netOut, want, "netOut is the destination's principal less its fee, plus the refund, less the old debt");
        assertEq(usdc.balanceOf(borrower) - wallet, netOut, "and it is exactly the cash the borrower received");
        assertEq(hub - usdc.balanceOf(address(ace)), netOut, "out of the hub, in the one transfer the verb makes");
        (, uint256 owed) = ace.owedOf(loanId, borrower);
        assertEq(owed, 0, "with nothing booked behind it");
    }

    // ============ the policy doors and the fold, whoever calls them: netOut is the credit booked ============

    /// @notice `refinanceByPolicy` logs as `netOut` exactly the credit it booked for the borrower, and pays no cash.
    function test_PolicyRoll_LogsAsNetOutTheCreditItBooked() public {
        uint256 loanId = _flooredArmedLoan();
        (, uint256 owedBefore) = ace.owedOf(loanId, borrower);
        uint256 wallet = usdc.balanceOf(borrower);

        vm.recordLogs();
        vm.prank(keeper);
        uint256 newId = ace.refinanceByPolicy(loanId);
        (uint256 loggedId, uint256 netOut) = _logged(vm.getRecordedLogs(), loanId);

        assertEq(loggedId, newId, "the log names the successor the call returned");
        assertEq(read.debtOf(newId), FLOOR, "fixture: the roll drew at the floor");
        assertGt(netOut, 0, "fixture: the floored roll has a real net out");
        (, uint256 owedAfter) = ace.owedOf(loanId, borrower);
        assertEq(owedAfter - owedBefore, netOut, "netOut is exactly the credit booked for the borrower");
        assertEq(usdc.balanceOf(borrower), wallet, "and no cash moved: a policy door credits");
        (, uint256 owedKeeper) = ace.owedOf(loanId, keeper);
        assertEq(owedKeeper, 0, "nor is any of it the executor's");
    }

    /// @notice The expiry fold in `forceClose` logs the same: `netOut` is the credit booked, and no cash moves to the borrower.
    function test_ExpiryFold_LogsAsNetOutTheCreditItBooked() public {
        uint256 loanId = _flooredArmedLoan();
        _warpTo(uint256(read.loan(loanId).expiry));
        (, uint256 owedBefore) = ace.owedOf(loanId, borrower);
        uint256 wallet = usdc.balanceOf(borrower);

        vm.recordLogs();
        vm.prank(keeper);
        ace.forceClose(loanId);
        (uint256 newId, uint256 netOut) = _logged(vm.getRecordedLogs(), loanId);

        assertEq(read.loan(newId).borrower, borrower, "fixture: the fold rolled rather than settled");
        assertEq(read.debtOf(newId), FLOOR, "fixture: the roll drew at the floor");
        assertGt(netOut, 0, "fixture: the floored roll has a real net out");
        (, uint256 owedAfter) = ace.owedOf(loanId, borrower);
        assertEq(owedAfter - owedBefore, netOut, "netOut is exactly the credit booked for the borrower");
        assertEq(usdc.balanceOf(borrower), wallet, "and no cash moved to the borrower: the fold credits");
    }
}
