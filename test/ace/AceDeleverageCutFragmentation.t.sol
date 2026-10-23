// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";

/// @notice A keeper that fills only enough of each crank to owe `keep`'s proceeds and hands the rest straight back.
/// @dev The hub measures the refund as its own collateral balance delta, so what fills is the keeper's choice alone.
contract FragmentingKeeper is IAceDeleverageCallback {
    Ace public immutable ACE;
    MockERC20 public immutable QUOTE;
    IERC20 public immutable COLLATERAL;
    uint256 public keep; // collateral units kept per crank; everything else released is refunded

    constructor(Ace ace, MockERC20 quote, IERC20 collateral) {
        ACE = ace;
        QUOTE = quote;
        COLLATERAL = collateral;
        quote.approve(address(ace), type(uint256).max); // the hub pulls exactly what filled, never the allowance
    }

    function setKeep(uint256 units) external {
        keep = units;
    }

    function crank(uint256 id) external returns (uint256, uint256) {
        return ACE.deleverage(id, 0, "");
    }

    function onAceDeleverage(uint256 unitsSold, uint256 quoteOwed, bytes calldata) external {
        require(msg.sender == address(ACE), "not the hub");
        uint256 kept = keep < unitsSold ? keep : unitsSold;
        if (unitsSold > kept) COLLATERAL.transfer(msg.sender, unitsSold - kept);
        QUOTE.mint(address(this), quoteOwed); // the full-size floor covers any fill; the pull takes only what filled
    }
}

/// @title AceDeleverageCutFragmentation
/// @notice Octane 2026-10-05 W3: `Deleverage._meltAll` floors the protocol cut PER CRANK, and the keeper chooses each crank's size.
/// @notice With a 0-decimal quote and the PoC 500 bps cut, a crank realizing 19 quote atoms pays `floor(0.95) = 0`.
/// @notice MEASUREMENT ROWS, GREEN BY DESIGN: they pin the CURRENT behaviour and log the bound, they do not demand a fix.
/// @dev The bound is under one quote atom of cut per crank, against a full deleverage transaction of gas per crank.
/// @dev Treasury is zero, so the piggyback sweep is inert and `protocolRevenue` is a clean counter of the cut alone.
/// @dev The cut is ALSO read off the debt (`stableOut - melt`), which is the measure that survives a live sweep.
contract AceDeleverageCutFragmentationTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    bytes32 internal id;
    MockERC20 internal q;
    MockERC20 internal c;
    MockPersistenceRecord internal record;
    FragmentingKeeper internal keeper;
    uint256 internal loanId;
    uint256 internal ps; // the market's price and the record's windowed minimum: one whole quote per whole collateral

    address internal borrower = address(0xB0B);

    uint256 internal constant S = 1 << 96;
    uint256 internal constant K = 1.4e18;
    uint256 internal constant BAND = 3000; // the PoC dials, from `PocMarkets`
    uint256 internal constant TARGET = 5000;
    uint256 internal constant STOP = 1000;
    uint256 internal constant CUT = 500;
    uint256 internal constant THETA = 7100; // trigger at 71% of the price: in band, and the cut-charging restore fits the secured base
    uint256 internal constant DEBT = 10_000; // whole quote, which is atoms: the quote has no decimals
    uint256 internal constant MIN_DEBT = 100; // far under DEBT, so the minDebt room never binds across the run
    uint256 internal constant FRAGMENT = 19; // ceil(1e4 / CUT) - 1: the largest proceeds whose cut floors to zero
    uint256 internal constant CRANKS = 20;

    function setUp() public {
        _warpTo(1_000_000);
        q = new MockERC20("Q0", "Q0", 0);
        c = new MockERC20("C18", "C18", 18);
        ps = AceFixtures.px(1e18, address(q), address(c));
        record = new MockPersistenceRecord(address(q), address(c));
        record.setMinPrice(ps);

        MarketParams memory p = AceFixtures.marketParams(address(q), address(c));
        p.price = ps;
        p.record = address(record);
        p.minDebt = MIN_DEBT;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND;
        p.deleverageTargetBps = TARGET;
        p.deleverageStopBps = STOP;
        p.deleverageProtocolBps = CUT;
        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(p, address(0));
        (ace, read, id) = (d.ace, d.read, d.id);

        q.mint(AceFixtures.LENDER, 1_000_000);
        vm.startPrank(AceFixtures.LENDER);
        q.approve(address(ace), type(uint256).max);
        ace.deposit(id, 1_000_000);
        vm.stopPrank();

        uint256 units = FullMath.mulDiv(K * DEBT, S * 10000, THETA * ps * 1e18);
        c.mint(borrower, units);
        vm.startPrank(borrower);
        c.approve(address(d.positionManager), units);
        loanId = ace.open(id, units, DEBT, ProtocolPolicy.MIN_TENOR, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        _warpBy(1 days);
        record.setBandPrice(read.triggerPrice(loanId)); // persisted below the band level and not below the trigger: in band, not distressed
        keeper = new FragmentingKeeper(ace, q, IERC20(address(c)));
    }

    /// @dev The most units whose `_owed` is `proceeds`: the inverse of the hub's ceiled floor, so the crank realizes exactly that.
    function _unitsFor(uint256 proceeds) internal view returns (uint256) {
        uint256 epsC = 10000 - ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        return FullMath.mulDiv(proceeds, 10000 * S, ps * epsC);
    }

    /// @notice Twenty cranks of 19 quote each: 380 quote of proceeds, all of it melted, and no cut.
    /// @notice CURRENT BEHAVIOUR, pinned: the aggregate's honest cut would be 19 quote, and this pays 0.
    /// @notice The zero is the FLOOR's, not a re-sized crank's: before every fragment, a 20-quote fill from that same state pays one atom.
    /// @dev `charge` is fixed by the sizing before the keeper is called, so the probe and the fragment share it; only the fill differs.
    /// @dev Without the probe, `cut == 0` would also pass if every fragment were a cut-free re-size, which proves nothing about the floor.
    function test_FragmentedDeleverageAvoidsTheProtocolCut() public {
        keeper.setKeep(_unitsFor(FRAGMENT));
        uint256 rev0 = read.protocolRevenue(id);
        uint256 debt0 = read.debtOf(loanId);

        for (uint256 i; i < CRANKS; ++i) {
            _assertThisStateCharges(i);
            (uint256 sold, uint256 out) = keeper.crank(loanId);
            assertGt(sold, 0, "each crank sells a positive lot");
            assertEq(out, FRAGMENT, "each crank realizes exactly 19 quote");
        }

        uint256 melted = debt0 - read.debtOf(loanId);
        uint256 cut = read.protocolRevenue(id) - rev0;
        emit log_named_uint("cranks", CRANKS);
        emit log_named_uint("proceeds realized (quote)", CRANKS * FRAGMENT);
        emit log_named_uint("debt melted (quote)", melted);
        emit log_named_uint("protocol cut taken (quote)", cut);
        emit log_named_uint("cut a single crank of the aggregate pays (quote)", (CRANKS * FRAGMENT * CUT) / 10000);
        emit log_named_uint("cut avoided per crank, in 1e-4 quote atoms (9500 is 0.95 of an atom)", FRAGMENT * CUT);

        assertEq(cut, 0, "MEASURED: twenty 19-quote cranks pay the protocol nothing");
        assertEq(melted, CRANKS * FRAGMENT, "MEASURED: and every quote of the 380 proceeds melted debt");

        keeper.setKeep(_unitsFor(FRAGMENT + 1));
        uint256 rev1 = read.protocolRevenue(id);
        (, uint256 last) = keeper.crank(loanId);
        assertEq(last, FRAGMENT + 1, "after the fragments, a 20-quote crank still realizes 20");
        assertEq(read.protocolRevenue(id) - rev1, 1, "and still pays one atom: the loan never left the charging branch");
    }

    /// @dev WITNESS, in a snapshot: from this exact state a 20-quote fill pays `floor(20 * 5%) = 1`, so this crank is CHARGED.
    function _assertThisStateCharges(uint256 i) internal {
        uint256 snap = vm.snapshotState();
        keeper.setKeep(_unitsFor(FRAGMENT + 1));
        uint256 rev = read.protocolRevenue(id);
        (, uint256 out) = keeper.crank(loanId);
        assertEq(out, FRAGMENT + 1, "WITNESS: the probe realizes 20 quote");
        assertEq(read.protocolRevenue(id) - rev, 1, string.concat("WITNESS: fragment ", vm.toString(i), " sits on the charging branch"));
        vm.revertToState(snap);
    }

    /// @notice What one fragment costs: the crank a fragmenting keeper pays for every atom of cut it avoids.
    /// @dev Measured in-test, so it excludes the 21k intrinsic and includes this mock keeper's own callback work.
    /// @dev The first crank of a test runs on cold slots, the second on warm ones; a real fragment is its own transaction, so cold.
    function test_Gas_OneFragmentCrank() public {
        keeper.setKeep(_unitsFor(FRAGMENT));
        uint256 g = gasleft();
        keeper.crank(loanId);
        uint256 cold = g - gasleft();
        g = gasleft();
        keeper.crank(loanId);
        uint256 warm = g - gasleft();
        emit log_named_uint("gas, first fragment crank (cold slots, no 21k intrinsic)", cold);
        emit log_named_uint("gas, second fragment crank (warm)", warm);
        assertGt(cold, warm, "guard: the first crank paid for cold slots, so the two figures measure different things");
    }

    /// @notice The control twin: ONE crank realizing the same 380 quote pays `floor(380 * 5%) = 19` and melts 361.
    /// @dev Same market, same loan, same sizing; only the keeper's fill differs, which is what makes the gap the floor's.
    function test_Control_OneCrankOfTheSameAggregatePaysTheCut() public {
        keeper.setKeep(_unitsFor(CRANKS * FRAGMENT));
        uint256 rev0 = read.protocolRevenue(id);
        uint256 debt0 = read.debtOf(loanId);

        uint256 g = gasleft();
        (uint256 sold, uint256 out) = keeper.crank(loanId);
        g -= gasleft();
        emit log_named_uint("gas, the control's one crank (cold slots, no 21k intrinsic)", g);

        assertGt(sold, 0, "the crank sold");
        assertEq(out, CRANKS * FRAGMENT, "and realized the same 380 quote the fragments did");
        assertEq(read.protocolRevenue(id) - rev0, 19, "the protocol takes floor(380 * 500 / 1e4) = 19");
        assertEq(debt0 - read.debtOf(loanId), 361, "and the debt melts by the rest");
    }

    /// @notice The edge: at 20 quote of proceeds the cut is one whole atom, so 19 is the largest cut-free crank.
    function test_Edge_TwentyQuoteOfProceedsPaysOneAtom() public {
        keeper.setKeep(_unitsFor(FRAGMENT + 1));
        uint256 rev0 = read.protocolRevenue(id);
        (, uint256 out) = keeper.crank(loanId);
        assertEq(out, FRAGMENT + 1, "the crank realized 20 quote");
        assertEq(read.protocolRevenue(id) - rev0, 1, "and paid floor(20 * 5%) = 1");
    }
}
