// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";

/// @title AceLenderAssetsTest
/// @notice The hub's own share-pricing read, which exists so ACE'S OWN AUDITED CONTRACTS never staticcall
/// @notice the lens, which is not audited.
/// @dev The guard row is the one that matters: `CuratorVault` prices shares off `lenderAssets`, so a
/// @dev torn read mints wrong. It asserts the selector, not merely that something reverted.
contract AceLenderAssetsTest is Test, DeleverageCrank {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant P = 2e18;
    uint256 internal constant BAND_BPS = 3000;

    bool internal probeMidBody;
    bool internal refusedMidBody;
    bytes internal midBodyRevert;

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        record.setMinPrice(P);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS; // the mid-body probe needs a crank to run inside, and this is the one
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id, 15_000e6);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Probes the hub from inside its own body, the one moment an integrator's code can run there.
    function _deleverageCallback(uint256 unitsSold, uint256 quoteOwed, bytes calldata data) internal override {
        if (probeMidBody) {
            (bool ok, bytes memory ret) = address(ace).staticcall(abi.encodeCall(Ace.lenderAssets, (alice, address(usdc))));
            refusedMidBody = !ok;
            midBodyRevert = ret;
        }
        super._deleverageCallback(unitsSold, quoteOwed, data);
    }

    // ============ the share-pricing read ============

    /// @notice The hub's number IS the pool's three legs, so nothing re-derives them off a slot map.
    /// @dev KEYED BY (lender, quote), not by market: the same figure covers every market this lender runs
    /// @dev in this quote, which is what lets a vault price shares in two reads at any market count: its balance and this.
    function test_LenderAssets_IsTheSumOfTheThreeAggregates() public {
        _open();
        (uint256 resting, uint256 lent, uint256 owed) = read.lenderPools(alice, address(usdc));

        assertEq(ace.lenderAssets(alice, address(usdc)), resting + lent + owed, "hub total");
        assertGt(ace.lenderAssets(alice, address(usdc)), 0, "PREMISE: the fixture must hold a real position");
    }

    /// @notice A pair that never lent reads ZERO, exactly as every raw hub getter does.
    /// @dev A revert here would cost bytes and defend nothing: the vault proves existence before it asks.
    function test_LenderAssets_UnknownPairReadsZero() public view {
        assertEq(ace.lenderAssets(address(0xdead), address(usdc)), 0, "a lender who never lent totals zero");
        assertEq(ace.lenderAssets(alice, address(0xdead)), 0, "and so does a quote she never lent in");
    }

    /// @notice THE SHARE-PRICING GUARD: the hub refuses this read while its own body is open.
    /// @notice `CuratorVault` prices shares off exactly this, so a torn answer mints wrong.
    /// @dev Driven through `deleverage`, the one verb that hands control to a caller mid-body.
    function testRevert_LenderAssets_RefusesInsideAGuardedHubBody() public {
        uint256 loanId = _open();
        assertGt(ace.lenderAssets(alice, address(usdc)), 0, "PREMISE: the same call must answer OUTSIDE the body");
        probeMidBody = true;
        _enterBand(loanId, 110);

        (uint256 sold,) = ace.deleverage(loanId, 0, "");

        assertGt(sold, 0, "PREMISE: the crank must fire, or the probe never ran");
        assertTrue(refusedMidBody, "lenderAssets answered mid-body: the share-pricing guard is gone");
        assertEq(bytes4(midBodyRevert), GUARD_TRIP, "refused, but not as the guard");
    }

    /// @dev Put the record in the band at `pct`% of the trigger, which is also the disposal floor.
    function _enterBand(uint256 loanId, uint256 pct) internal {
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = (trig * pct) / 100;
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(ps);
    }

    /// @dev DELETED: the claim-tick pair, three rows. `Ace.claimTickCount` and `Ace.claimTickAt` existed to let
    /// @dev an audited caller enumerate a loan's funded ticks WITHOUT the lens, and the rows pinned the scalar
    /// @dev pair against the lens array, the unknown-loan zero, and the index panic that kept a real tick 0 from
    /// @dev reading as absent. A loan funds one price: there is no list to enumerate, no pair on the hub, and the
    /// @dev "tick 0 is a real tick" hazard the panic defended against cannot arise. What survives is the lens's
    /// @dev own claim read, pinned against an independent slot walk in `AceLensParity.test_Parity_ClaimRegion`.
}
