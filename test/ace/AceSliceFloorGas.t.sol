// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceSliceFloorGas
/// @notice MEASUREMENT, not refutation: what is the smallest loan slice a keeper will settle?
/// @notice A router that partitions one borrow across curators makes N loans, so N independent settlements.
/// @notice The settle sliver is proportional to DEBT while the gas that earns it is FIXED, so small slices strand.
/// @dev Every assertion is a price tag; a red row here means an ECONOMIC change, never a correctness one.
/// @dev Rows emit gas, and the dollar tables are computed here so the economics are reproducible from one run.
/// @dev THE SLICE FLOOR IS A LOWER BOUND: slices in DIFFERENT markets pay cold market storage this never touches.
contract AceSliceFloorGasTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the market's only lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 64_000e6; // the blended borrow: $64,000, divisible by every N below
    uint256 internal constant COLL = 200_000e18; // collateral behind the blended borrow
    uint256 internal constant TOP = 2_000_000e6; // one deep rung, so a slice is a single-tick draw
    uint256 internal constant UNIT_SCALE = 1 << 96;

    /// @dev ETH price the dollar tables are struck at; every figure scales linearly in it.
    uint256 internal constant ETH_USD = 4000;
    /// @dev The SHIPPED admission floor (Defaults.MIN_DEBT), not the fixture's 10e6, since it is the rival floor.
    uint256 internal constant SHIPPED_MIN_DEBT = 5000e6;

    uint256 internal T;

    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        T = _price(0);
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        usdc.mint(borrower, 10_000_000e6);
    }

    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50; // PocDeployConfig.SETTLE_BOUNTY_BPS
        p.minCoverageWad = 1.4e18;
    }

    function _deposit(uint256 price, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _open(uint256 principal, uint256 collateral) internal returns (uint256 loanId) {
        vault.mint(borrower, collateral);
        vm.startPrank(borrower);
        vault.approve(address(pm), collateral);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(id, collateral, principal, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Micro-dollars a gas figure costs at `price` gwei. ETH at $4,000 makes this `gas * price * 4`.
    function _costUsd6(uint256 gas, uint256 price) internal pure returns (uint256) {
        return (gas * price * ETH_USD) / 1000;
    }

    /// @dev The smallest debt whose proportional sliver pays for a settlement costing `gas`.
    /// @dev NOMINAL: the sliver is in-kind at the loan's funding floor, and a settling loan trades UNDER it.
    function _breakEvenDebt6(uint256 gas, uint256 price, uint256 bps) internal pure returns (uint256) {
        return (_costUsd6(gas, price) * 10000) / bps;
    }

    /* ================================================================= */
    /*  1 -- THE SLICE FLOOR: what one settlement costs, and what it pays */
    /* ================================================================= */

    /// @notice The per-settlement gas a slice must earn back, measured on a single-tick loan.
    /// @dev Single-tick is the CHEAPEST settlement there is, so the floor this yields is a lower bound.
    function test_SliceFloor_SingleTickFinalizeGas() public {
        _deposit(T, TOP);
        uint256 loanId = _open(P, COLL);
        _warpBy(1 days);
        record.setBelow(true);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        ace.finalize(loanId);
        uint256 used = g0 - gasleft();

        emit log_named_uint("finalize gas, one funded tick", used);
        _emitFloorTable("finalize", used);
        assertGt(used, 0, "guard: the settlement ran");
        assertTrue(read.loan(loanId).closedAt != 0, "guard: the loan really settled");
    }

    /// @notice The expiry door's gas, the other crank a slice needs someone to pay for.
    function test_SliceFloor_SettleExpiredGas() public {
        _deposit(T, TOP);
        uint256 loanId = _open(P, COLL);
        _warpTo(uint256(read.loan(loanId).expiry));
        vm.prank(alice);
        ace.withdraw(id, type(uint256).max, alice, 0); // empty the market, so the crank's push to alice is not a first write
        assertEq(read.marketState(id).cash, 0, "guard: the withdraw really emptied the market");
        _warpBy(Constants.AUTO_REFINANCE_WINDOW + 1); // past the paid door's roll window

        vm.prank(keeper);
        uint256 g0 = gasleft();
        ace.settleExpired(loanId);
        uint256 used = g0 - gasleft();

        emit log_named_uint("settleExpired gas, one funded tick", used);
        _emitFloorTable("settleExpired", used);
        assertGt(used, 0, "guard: the expiry crank ran");
        assertTrue(read.loan(loanId).closedAt != 0, "guard: the loan really settled");
    }

    /// @notice The floor the two rival bounds produce: gas-break-even against the SHIPPED minDebt.
    /// @notice MEASURED ANSWER: the ADMISSION floor binds through 25 gwei; near 29 gwei gas takes over and sets the slice.
    /// @dev The row also emits the gas price at which the two swap, which is the number a router would watch.
    /// @dev The crossover fell from above 30 gwei when settlement began writing the lender's per-collateral split.
    /// @dev Was `test_SliceFloor_AdmissionFloorBindsAcrossTheGasRange`, renamed when 30 gwei stopped being inside that range.
    function test_SliceFloor_AdmissionFloorBindsThrough25Gwei() public {
        _deposit(T, TOP);
        uint256 loanId = _open(P, COLL);
        _warpBy(1 days);
        record.setBelow(true);
        vm.prank(keeper);
        uint256 g0 = gasleft();
        ace.finalize(loanId);
        uint256 gas = g0 - gasleft();

        uint256 atOne = _breakEvenDebt6(gas, 1, 50);
        uint256 atFive = _breakEvenDebt6(gas, 5, 50);
        uint256 atTwentyFive = _breakEvenDebt6(gas, 25, 50);
        uint256 atThirty = _breakEvenDebt6(gas, 30, 50);
        emit log_named_decimal_uint("break-even slice,  1 gwei, 50bps (USDC)", atOne, 6);
        emit log_named_decimal_uint("break-even slice,  5 gwei, 50bps (USDC)", atFive, 6);
        emit log_named_decimal_uint("break-even slice, 25 gwei, 50bps (USDC)", atTwentyFive, 6);
        emit log_named_decimal_uint("break-even slice, 30 gwei, 50bps (USDC)", atThirty, 6);
        emit log_named_decimal_uint("shipped MIN_DEBT                 (USDC)", SHIPPED_MIN_DEBT, 6);

        // the gas price at which the gas bound overtakes the admission floor, in gwei
        uint256 flip = (SHIPPED_MIN_DEBT * 50 * 1000) / (10000 * gas * ETH_USD);
        emit log_named_uint("gwei at which GAS overtakes MIN_DEBT", flip);

        assertLt(atTwentyFive, SHIPPED_MIN_DEBT, "the ADMISSION floor binds through 25 gwei: gas does not set the slice there");
        assertGt(flip, 25, "and the crossover sits above 25 gwei");
    }

    /// @notice The bounty cap does not rescue the small slice: 200bps is 4x, and the 30-gwei gap is wider.
    function test_SliceFloor_MaxBountyStillLeavesAGasBoundFloor() public {
        _deposit(T, TOP);
        uint256 loanId = _open(P, COLL);
        _warpBy(1 days);
        record.setBelow(true);
        vm.prank(keeper);
        uint256 g0 = gasleft();
        ace.finalize(loanId);
        uint256 gas = g0 - gasleft();

        uint256 maxBps = Constants.MAX_SETTLE_BOUNTY_BPS;
        emit log_named_decimal_uint("break-even slice, 30 gwei, MAX bps (USDC)", _breakEvenDebt6(gas, 30, maxBps), 6);
        emit log_named_decimal_uint("break-even slice,  5 gwei, MAX bps (USDC)", _breakEvenDebt6(gas, 5, maxBps), 6);
        assertLt(_breakEvenDebt6(gas, 30, maxBps), SHIPPED_MIN_DEBT, "the cap does buy headroom at 30 gwei");
    }

    /* ================================================================= */
    /*  3 -- THE OVERHEAD RATIO: N slices against one blended loan        */
    /* ================================================================= */

    /// @notice N partitioned loans against one blended loan of the same size, opens AND settlements.
    /// @dev All N draw from ONE deep rung in ONE market, which is the cheapest partition that exists.
    /// @dev A real router's slices sit in N different markets and pay cold storage this row never touches.
    function test_Overhead_NSlicesAgainstOneBlendedLoan() public {
        uint256 one = _measureRound(1);
        emit log_named_uint("N = 1 (the blended loan), total gas", one);
        for (uint256 n = 2; n <= 16; n *= 2) {
            uint256 tot = _measureRound(n);
            emit log_named_uint("slices", n);
            emit log_named_uint("  total gas", tot);
            emit log_named_uint("  overhead bps vs blended", (tot * 10000) / one);
            assertGt(tot, one, "partitioning is never cheaper than one blended loan");
        }
    }

    /// @dev One round: open `n` equal slices, settle every one, return the total gas for both legs.
    /// @dev Snapshots so each round starts from the same market, never from the last round's leftovers.
    function _measureRound(uint256 n) internal returns (uint256 total) {
        uint256 root = vm.snapshotState();
        _deposit(T, TOP);
        uint256[] memory loans = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 g0 = gasleft();
            loans[i] = _openMeasured(P / n, COLL / n);
            total += g0 - gasleft();
        }
        _warpBy(1 days);
        record.setBelow(true);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(keeper);
            uint256 g0 = gasleft();
            ace.finalize(loans[i]);
            total += g0 - gasleft();
        }
        vm.revertToState(root);
    }

    /// @notice The SAME partition with each leg in its OWN market, which is where a router's legs actually sit.
    /// @notice This is the row the one-market measurement understates: every leg pays cold market storage.
    /// @dev Market creation and the deposits are OUTSIDE the measured span -- a curator's market already exists.
    /// @dev Markets are distinguished by their own record, since the id is `keccak256(abi.encode(p))`.
    function test_Overhead_NSlicesAcrossDistinctMarkets() public {
        uint256 warmOne = _measureRound(1); // the blended loan, one market: the same baseline as the row above
        emit log_named_uint("N = 1 (blended, one market), total gas", warmOne);
        for (uint256 n = 2; n <= 16; n *= 2) {
            uint256 cold = _measureColdRound(n);
            uint256 warm = _measureRound(n);
            emit log_named_uint("slices", n);
            emit log_named_uint("  same-market total gas", warm);
            emit log_named_uint("  cross-market total gas", cold);
            uint256 premium = (cold * 10000) / warm;
            emit log_named_uint("  cross-market premium bps", premium);
            assertLt(premium, 11000, "own-market legs cost a few percent over shared-market ones, never a multiple");
        }
    }

    /// @dev One cross-market round: `n` markets, one slice each, opens and settlements measured.
    function _measureColdRound(uint256 n) internal returns (uint256 total) {
        uint256 root = vm.snapshotState();
        bytes32[] memory mids = new bytes32[](n);
        MockPersistenceRecord[] memory recs = new MockPersistenceRecord[](n);
        for (uint256 i = 0; i < n; i++) {
            (mids[i], recs[i]) = _newMarket();
            _depositTo(mids[i], TOP / n);
        }
        uint256[] memory loans = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vault.mint(borrower, COLL / n);
            vm.startPrank(borrower);
            vault.approve(address(pm), COLL / n);
            usdc.approve(address(ace), type(uint256).max);
            vm.stopPrank();
            vm.prank(borrower);
            uint256 g0 = gasleft();
            loans[i] = ace.open(mids[i], COLL / n, P / n, TEN7, borrower, OpenBounds(0, 0, 0));
            total += g0 - gasleft();
        }
        _warpBy(1 days);
        for (uint256 i = 0; i < n; i++) {
            recs[i].setBelow(true);
        }
        for (uint256 i = 0; i < n; i++) {
            vm.prank(keeper);
            uint256 g0 = gasleft();
            ace.finalize(loans[i]);
            total += g0 - gasleft();
        }
        vm.revertToState(root);
    }

    /// @notice DOES A SOLE-TENANT MARKET STILL NEED A LADDER? Priced as one loan over K rungs against K loans.
    /// @notice Both reach the same depth at the same prices; the only difference is whether one lender's
    /// @notice price curve lives INSIDE a market or is spread across K single-rung markets a router picks.
    /// @dev The per-RUNG marginal is a class write and a claim-tick push; the per-LOAN marginal is a whole
    /// @dev position, its custody and its own settlement. This row is the gap between those two numbers.
    function test_LadderValue_OneLoanAcrossKRungsAgainstKLoans() public {
        for (uint256 k = 2; k <= 8; k *= 2) {
            uint256 spanned = _measureSpannedRound(k);
            uint256 split = _measureRound(k);
            emit log_named_uint("rungs", k);
            emit log_named_uint("  one loan spanning K rungs, gas", spanned);
            emit log_named_uint("  K loans of the same total, gas", split);
            emit log_named_uint("  split premium bps", (split * 10000) / spanned);
            assertLt(spanned, split, "the ladder funds K price points for less than K loans do");
        }
    }

    /// @dev One round: K rungs each holding a slice, ONE loan drawing all of them, then its settlement.
    /// @dev Rungs descend from par so the walk funds top-down and the floor lands on the lowest.
    function _measureSpannedRound(uint256 k) internal returns (uint256 total) {
        uint256 root = vm.snapshotState();
        uint256 slice = P / 8;
        for (uint256 i = 0; i < k; i++) {
            _deposit(_price(-int24(int256(i)) * 60), slice);
        }
        uint256 coll = (COLL * k) / 8;
        vault.mint(borrower, coll);
        vm.startPrank(borrower);
        vault.approve(address(pm), coll);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
        vm.prank(borrower);
        uint256 g0 = gasleft();
        uint256 loanId = ace.open(id, coll, slice * k, TEN7, borrower, OpenBounds(0, 0, 0));
        total += g0 - gasleft();

        _warpBy(1 days);
        record.setBelow(true);
        vm.prank(keeper);
        g0 = gasleft();
        ace.finalize(loanId);
        total += g0 - gasleft();
        vm.revertToState(root);
    }

    /// @dev A fresh market with its own record, so its id differs from every other market's.
    function _newMarket() internal returns (bytes32 mid, MockPersistenceRecord rec) {
        rec = new MockPersistenceRecord(address(usdc), address(vault));
        MarketParams memory p = _params();
        p.record = address(rec);
        mid = ace.createMarket(p);
    }

    /// @dev `_deposit` against an arbitrary market id.
    function _depositTo(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev `_open` with the mint and the approvals hoisted out, so the measured span is the hub call alone.
    function _openMeasured(uint256 principal, uint256 collateral) internal returns (uint256 loanId) {
        vault.mint(borrower, collateral);
        vm.startPrank(borrower);
        vault.approve(address(pm), collateral);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
        vm.prank(borrower);
        loanId = ace.open(id, collateral, principal, TEN7, borrower, OpenBounds(0, 0, 0));
    }

    /* ================================================================= */
    /*  reporting                                                        */
    /* ================================================================= */

    /// @dev The break-even slice at each gas regime, for one measured settlement cost.
    function _emitFloorTable(string memory label, uint256 gas) internal {
        emit log_string(label);
        emit log_named_decimal_uint("  break-even slice,  1 gwei (USDC)", _breakEvenDebt6(gas, 1, 50), 6);
        emit log_named_decimal_uint("  break-even slice,  5 gwei (USDC)", _breakEvenDebt6(gas, 5, 50), 6);
        emit log_named_decimal_uint("  break-even slice, 30 gwei (USDC)", _breakEvenDebt6(gas, 30, 50), 6);
    }
}
