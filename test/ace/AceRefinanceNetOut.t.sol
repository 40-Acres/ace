// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Loan, MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {_extended} from "../utils/Extended.sol";

/// @title AceRefinanceNetOut
/// @notice `Refinanced.netOut` is the migration's net out on every `refinanceTo`, and it names what really moved: the cash the borrower received.
/// @notice A cash `extend` logs no `Refinanced`: it lengthens in place and books no net out.
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

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant FRESH = 6_000e6; // a successor over the debt, so a strict door has cash to pay
    uint256 internal constant FLOOR = 4_000e6; // under the loan, so a partial repay can bring the debt down onto it
    uint256 internal constant HOLD = 3.5 days;

    bytes32 internal constant REFINANCED = keccak256("Refinanced(uint256,uint256,uint256,uint64,uint256,address)");
    bytes32 internal constant EXTENDED = keccak256("Extended(uint256,uint64,uint64,uint256,address)");

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

    function _params(address rec, uint256 minPrincipal) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = rec;
        p.minPrincipal = minPrincipal;
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

    /// @dev A loan in a market floored at FLOOR, repaid by its borrower to exactly it: the lowest debt a live loan carries.
    function _flooredLoan() internal returns (uint256 loanId) {
        bytes32 m = ace.createMarket(_params(address(_record()), FLOOR));
        _deposit(m, 30_000e6);
        loanId = _open(m);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);
        uint256 pay = read.debtOf(loanId) - FLOOR;
        usdc.mint(borrower, pay);
        vm.startPrank(borrower);
        usdc.approve(address(ace), pay);
        ace.repay(loanId, pay);
        vm.stopPrank();
        assertEq(read.debtOf(loanId), FLOOR, "fixture: the debt sits on the floor");
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

    /// @notice A home `refinanceTo` logs as `netOut` exactly the cash the borrower received, which is the net out its terms give.
    function test_Refinance_LogsAsNetOutTheCashItPaidTheBorrower() public {
        uint256 loanId = _open(mid);
        _warpTo(t0 + HOLD);
        uint64 tenor = ace.idToMarketParams(mid).minTenor;
        uint256 want = _netOutOf(mid, loanId, FRESH, tenor);
        uint256 wallet = usdc.balanceOf(borrower);
        uint256 hub = usdc.balanceOf(address(ace));

        vm.recordLogs();
        vm.prank(borrower);
        uint256 newId = ace.refinanceTo(MigrateArgs(loanId, mid, FRESH, tenor, OpenBounds(0, 0, 0), 0, address(0)));
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

    // ============ the extension in place ============

    /// @notice A cash extension logs no `Refinanced` at all: it extends in place, logs `Extended`, and books no net out, credited or paid.
    /// @dev The loan sits on its market's floor, and an extension draws nothing, so the debt holds there.
    function test_Extend_LogsExtendedAndBooksNoNetOut() public {
        uint256 loanId = _flooredLoan();
        AceFixtures.installYesPolicy(ace, alice);
        Loan memory l = read.loan(loanId);
        _warpTo(uint256(l.expiry) - 1);
        MarketParams memory p = ace.idToMarketParams(l.market);
        uint256 fee = LoanMath.originationFee(l.debt, l.tenor - 1, p.baseBps, p.minTenor); // the term's last second buys tenor - 1
        usdc.mint(borrower, fee);
        vm.prank(borrower);
        usdc.approve(address(ace), fee);
        (, uint256 owedBefore) = ace.owedOf(loanId, borrower);
        uint256 wallet = usdc.balanceOf(borrower);

        vm.recordLogs();
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, REFINANCED), 0, "the extension logs no Refinanced: there is no successor to net into");
        assertEq(_count(logs, EXTENDED), 1, "it logs one Extended");
        assertTrue(_extended(read, loanId, l.expiry), "for the same loan, extended in place");
        assertEq(read.debtOf(loanId), l.debt, "its debt unchanged: the fee is paid in cash, never drawn");
        assertEq(read.debtOf(loanId), FLOOR, "so it stays on the floor");
        (, uint256 owedAfter) = ace.owedOf(loanId, borrower);
        assertEq(owedAfter, owedBefore, "and nothing is credited to the borrower");
        assertEq(wallet - usdc.balanceOf(borrower), fee, "nor paid: the wallet falls by exactly the fee");
    }

    /// @dev How many logs the hub emitted under `sig`.
    function _count(Vm.Log[] memory logs, bytes32 sig) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(ace) && logs[i].topics[0] == sig) n++;
        }
    }
}
