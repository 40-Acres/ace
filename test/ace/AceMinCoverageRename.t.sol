// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceMinCoverageRename
/// @notice `MarketParams.k` is now `minCoverageWad`: a pure rename, so the ARITHMETIC must be untouched.
/// @notice The pins here are hand-derived absolutes, never a re-expression of the code under test.
/// @dev `triggerPrice = ceil(k * debt * unitScale / (units * 1e18))`, with unitScale = 1e18 * 10^(cd - qd).
/// @dev At k = 1.4, debt = 70_000e6, units = 100_000e18 and 18/6 decimals that is exactly 0.98e18.
/// @dev The live leg also crosses the `gate` field's +1 slot shift, since the reader walks raw slots.
contract AceMinCoverageRenameTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id0;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal constant FORMULA_SCALE = 1e30; // a ROUND scale for the algebra rows, so halving stays exact
    uint256 internal constant TRIG = 0.98e18; // the hand-derived answer for (1.4, P, COLL), at FORMULA_SCALE
    uint256 internal T; // par for this pair; assigned in setUp, since par is not a compile-time value

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
        T = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id0) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    // ---- the arithmetic, hand-derived ----

    /// @notice The renamed argument still multiplies the debt: one absolute value, computed by hand.
    function test_TriggerPrice_KnownValue() public pure {
        assertEq(LoanMath.triggerPrice(P, COLL, 1.4e18, FORMULA_SCALE), TRIG, "1.4 coverage on 70k against 100k units");
    }

    /// @notice The coverage multiple is LINEAR in the trigger, which is the whole meaning of the field.
    function test_TriggerPrice_ScalesLinearlyInCoverage() public pure {
        assertEq(LoanMath.triggerPrice(P, COLL, 2.8e18, FORMULA_SCALE), 2 * TRIG, "double coverage, double trigger");
        assertEq(LoanMath.triggerPrice(P, COLL, 0.7e18, FORMULA_SCALE), TRIG / 2, "and half for half");
        assertEq(LoanMath.triggerPrice(2 * P, COLL, 1.4e18, FORMULA_SCALE), 2 * TRIG, "linear in the debt too");
        assertEq(LoanMath.triggerPrice(P, 2 * COLL, 1.4e18, FORMULA_SCALE), TRIG / 2, "and inverse in the collateral");
    }

    /// @notice Rounding is UP, against the borrower, at every coverage multiple.
    function test_TriggerPrice_RoundsUpAgainstTheBorrower() public pure {
        assertEq(LoanMath.triggerPrice(1, 3, 1e18, 1e18), 333333333333333334, "1e18/3 ceils to ...334, not ...333");
        assertEq(LoanMath.triggerPrice(0, COLL, 1.4e18, FORMULA_SCALE), 0, "but a zero debt triggers at zero");
        assertEq(LoanMath.triggerPrice(P, 0, 1.4e18, FORMULA_SCALE), 0, "and an unsecured loan has no trigger");
    }

    // ---- the same number, through the live market ----

    /// @notice A real loan's trigger is the hand-derived value, read back through the raw-slot reader.
    /// @dev The reader takes `unitScale` from slot base+26, so a wrong `gate` offset would show up here.
    function test_TriggerPrice_LiveLoanMatchesTheKnownValue() public {
        assertEq(read.marketState(id0).unitScale, UNIT_SCALE, "every market carries the atom frame's scale");
        // the same hand-derived $0.98, converted into the hub's frame by this pair's own factor; both ceil
        uint256 liveTrig = FullMath.mulDivRoundingUp(TRIG, UNIT_SCALE, FORMULA_SCALE);
        _deposit(alice, id0, T, 400_000e6);
        uint256 loanId = _open(borrower, id0, P, TEN7);

        assertEq(read.loan(loanId).debt, P, "the loan is the one the pin was computed for");
        assertEq(read.triggerPrice(loanId), liveTrig, "the live trigger is the hand-derived value");
        assertEq(lens.triggerPrice(loanId), liveTrig, "and the lens agrees, so no reader mirrors the hub's bug");
    }

    /// @notice The field ROUND-TRIPS through genesis: what a creator set is what the hub prices on.
    function test_MinCoverageWad_RoundTripsThroughGenesis() public {
        MarketParams memory p = _params();
        p.minCoverageWad = 2.5e18;
        bytes32 mid = ace.createMarket(p);
        assertEq(ace.idToMarketParams(mid).minCoverageWad, 2.5e18, "the renamed field survives genesis verbatim");
        assertEq(ace.idToMarketParams(id0).minCoverageWad, PocDeployConfig.MIN_COVERAGE_WAD, "and the default one too");
    }

    /// @notice The band's own ends: the floor admits, one wei under it does not, and the message names it.
    function test_MinCoverageWad_BandFloorIsExactAndNamed() public {
        MarketParams memory p = _params();
        p.minCoverageWad = Constants.MIN_COVERAGE_WAD;
        ace.createMarket(p); // the floor itself admits, so the refusal below is not vacuous

        MarketParams memory q = _params();
        q.minCoverageWad = Constants.MIN_COVERAGE_WAD - 1;
        vm.expectRevert(bytes("min coverage out of band"));
        ace.createMarket(q);

        MarketParams memory r = _params();
        r.minCoverageWad = Constants.MAX_COVERAGE_WAD + 1;
        vm.expectRevert(bytes("min coverage out of band"));
        ace.createMarket(r);
    }

    // ---- the new `gate` field is part of market IDENTITY ----

    /// @notice `borrower` sits between `record` and `price`, and every neighbour round-trips with it.
    /// @dev The field AFTER it was `tickSpacing`, which the price replaced in the same slot position.
    function test_MarketParams_GateRoundTripsWithItsNeighbours() public {
        MarketParams memory p = _params();
        p.borrower = address(0x6A7E);
        p.fillFeeBps = 25; // a non-default two past the insertion, so its round-trip is not vacuous
        bytes32 mid = ace.createMarket(p);
        MarketParams memory got = ace.idToMarketParams(mid);

        assertEq(got.record, p.record, "the field BEFORE the insertion is intact");
        assertEq(got.borrower, p.borrower, "the inserted field carries what was set");
        assertEq(got.price, p.price, "and the field AFTER it is intact");
        assertEq(got.fillFeeBps, 25, "as is the one past that");
        assertEq(got.minCoverageWad, p.minCoverageWad, "and the renamed field further down");
    }

    /// @notice The gate is hashed into the id, so two otherwise identical markets are DIFFERENT markets.
    /// @dev A second record, configured exactly like the first, is what keeps the ungated leg off setUp's id.
    function test_MarketId_DependsOnTheGate() public {
        MarketParams memory p = _params();
        p.record = address(new MockPersistenceRecord(address(usdc), address(vault)));
        bytes32 open_ = ace.createMarket(p);
        p.borrower = address(0xBEEF);
        bytes32 gated = ace.createMarket(p);
        assertTrue(open_ != gated, "the gate is part of market identity");
        assertEq(ace.idToMarketParams(open_).borrower, address(0), "and each id resolves to its own gate");
        assertEq(ace.idToMarketParams(gated).borrower, address(0xBEEF), "including the gated one");
    }

    // ---- helpers ----

    function _deposit(address who, bytes32 mid, uint256 price, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(address who, bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(who, COLL);
        usdc.mint(who, 1_000_000e6);
        vm.startPrank(who);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, principal, tenor, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }
}
