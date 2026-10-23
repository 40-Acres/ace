// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceExecutorAttribution
/// @notice C41 plan tests A24-A24f: section 6.11's `address indexed executor` on every paid crank.
/// @notice Written failing-first before the re-signing; the field shipped and this suite is green.
/// @dev The assertion is a SIGNATURE match: a log still hashing the old argument list is not found.
/// @dev DELEGATECALL: `msg.sender` inside a linked library is the EXTERNAL caller, not the hub.
/// @dev Get that backwards and every settlement logs the hub: silently useless, and nothing fails.
/// @dev The events pinned here are declared in `Deleverage` and `Settlement`, never in `Ace` itself.
/// @dev A drifted declaration still COMPILES, so the signature constants below are what catch the drift.
contract AceExecutorAttributionTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TENOR = 7 days;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant P = 20_000e6;
    uint256 internal constant CASH = 300_000e6;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal T; // par for this pair; assigned in setUp, since par is not a compile-time value

    /// @dev Section 6.11's post-change signatures, appended LAST, one per re-signed event.
    string internal constant SIG_FORCE_CLOSED = "ForceClosed(uint256,uint256,uint256,address)";
    string internal constant SIG_FINALIZED = "Finalized(uint256,uint256,uint256,address)";
    string internal constant SIG_DELEVERAGED = "Deleveraged(uint256,uint256,uint256,uint256,address)";

    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);

        _deposit(id, CASH);
    }

    // ---- fixture ----

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(bytes32 mid, uint256 principal, uint256 units) internal returns (uint256 loanId) {
        vault.mint(borrower, units);
        vm.startPrank(borrower);
        vault.approve(address(pm), units);
        loanId = ace.open(mid, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The executor topic of a re-signed event: topic0 is the signature, topic1 the loan id.
    /// @dev Returns the sentinel when no matching log exists, which is exactly today's answer.
    function _executorOf(Vm.Log[] memory logs, string memory sig, uint256 loanId, uint256 topicIndex) internal pure returns (address) {
        bytes32 want = keccak256(bytes(sig));
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length <= topicIndex) continue;
            if (logs[i].topics[0] == want && logs[i].topics[1] == bytes32(loanId)) {
                return address(uint160(uint256(logs[i].topics[topicIndex])));
            }
        }
        return address(0);
    }

    function _executorOf(Vm.Log[] memory logs, string memory sig, uint256 loanId) internal pure returns (address) {
        return _executorOf(logs, sig, loanId, 2);
    }

    // ============ A24. the library path, and it is the bounty's own address ============

    /// @notice A24: a keeper-called `forceClose` logs the KEEPER, and it is the address the sliver went to.
    /// @notice The equality is the assertion; the field's mere presence proves nothing about attribution.
    /// @dev `forceClose` is permissionless, bounty-paying and single-caller, so this is the cleanest case.
    function test_A24_ForceClosed_LogsTheKeeper_AndItIsWhoTheBountyPaid() public {
        uint256 loanId = _open(id, P, COLL);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 collBefore = vault.balanceOf(keeper);

        vm.recordLogs();
        vm.prank(keeper);
        ace.forceClose(loanId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // the bounty is CREDITED to the cranking caller, so the pull is what moves it into their wallet
        vm.prank(keeper);
        ace.claimOwed(loanId, keeper);
        uint256 sliver = vault.balanceOf(keeper) - collBefore;
        assertGt(sliver, 0, "fixture: the settle bounty really did pay this caller");
        address executor = _executorOf(logs, SIG_FORCE_CLOSED, loanId);
        assertEq(executor, keeper, "delegatecall PRESERVES msg.sender, so the library logs the external caller");
        assertTrue(executor != address(ace), "and never the hub's own address, which is the silent failure");
    }

    // ============ A24e. twin parity across the settlement pair ============

    /// @notice A24e: the two dual-declared SETTLEMENT events decode against the `Ace`-side signature.
    /// @notice A drifted twin still compiles and still emits; only a decode test catches it.
    /// @dev Same class as the layout rail: green does not mean covered unless the check is the right one.
    function test_A24e_TwinParity_SettlementEventsDecodeAgainstTheHubsSignature() public {
        uint256 forced = _open(id, P, COLL);
        uint256 settled = _open(id, P, COLL);
        _warpTo(uint256(read.loan(forced).expiry) + 1);

        vm.recordLogs();
        vm.prank(keeper);
        ace.forceClose(forced);
        Vm.Log[] memory forcedLogs = vm.getRecordedLogs();

        record.setBelowBand(read.triggerPrice(settled));
        assertTrue(read.settleable(settled), "fixture: the second loan is settleable right now");
        vm.recordLogs();
        vm.prank(keeper);
        ace.finalize(settled);
        Vm.Log[] memory settledLogs = vm.getRecordedLogs();

        assertTrue(read.loan(forced).closedAt != 0, "fixture: the force close landed");
        assertTrue(read.loan(settled).closedAt != 0, "fixture: and so did the finalize");
        assertEq(_executorOf(forcedLogs, SIG_FORCE_CLOSED, forced), keeper, "ForceClosed's twin matches");
        assertEq(_executorOf(settledLogs, SIG_FINALIZED, settled), keeper, "and so does Finalized's");
    }

    // ============ A24f. the seventh event, and a pre-existing ABI gap ============

    /// @notice A24f: `Deleveraged` is a keeper crank in the same family, so it takes the field too.
    /// @notice It is declared ONLY in `Deleverage`, so today its log is emitted at the hub and undecodable.
    /// @dev The missing `Ace`-side declaration is a source fact a test cannot see; this pins the SIGNATURE.
    function test_A24f_Deleveraged_CarriesTheExecutorToo() public {
        (uint256 loanId, MockDeleverageKeeper delevKeeper) = _bandedLoan();

        vm.recordLogs();
        (uint256 sold,) = delevKeeper.crankDeleverage(loanId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(sold, 0, "fixture: the decline channel really fired");
        assertEq(_executorOf(logs, SIG_DELEVERAGED, loanId), address(delevKeeper), "the decline crank names its caller, like every other paid crank");
    }

    // ---- secondary fixtures ----

    /// @dev A market with the decline channel open, and a record parked inside its band.
    function _bandedLoan() private returns (uint256 loanId, MockDeleverageKeeper delevKeeper) {
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(vault));
        rec.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));
        MarketParams memory p = _params();
        p.record = address(rec); // its own record: what makes this market a distinct id
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        bytes32 mid = ace.createMarket(p);
        _deposit(mid, 40_000e6);
        loanId = _open(mid, 4_500e6, 10_000e18);

        uint256 trig = read.triggerPrice(loanId);
        rec.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - 2000 * 1e14));
        rec.setMinPrice(AceFixtures.px(0.7e18, address(usdc), address(vault)));
        delevKeeper = new MockDeleverageKeeper(ace, address(usdc), address(vault), UNIT_SCALE);
    }
}
