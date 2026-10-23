// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceP1OffChannelRouting
/// @notice AUDIT POC, run 2026-09-13-670568 phase 1, finding F1: it deepened #400 L2, and #400's genesis rail closes it.
/// @notice With the band off, target and eps were read by NOTHING but the cross-market equality rail.
/// @notice So two economically identical bullet markets refused to route a loan between them; genesis now refuses both values.
/// @dev The two unread-value rows are fix-agnostic: genesis refuses the value by the lie-guard's exact string, or the market routes.
/// @dev The fuzz row states the fix outright: a band-off destination is admitted only with both dials zero, and then it routes.
/// @dev The home market is the canonical bullet shape, every off-channel dial zero, as `PawnMarkets` writes it.
contract AceP1OffChannelRoutingTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    bytes32 internal home;

    address internal alice = address(0xA11CE); // the home lender
    address internal rivalLender = address(0xF1A5C0); // the destination lender
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 400_000e18;
    uint256 internal constant TOP = 1_000_000e6;
    uint16 internal constant BUF = 500;
    uint16 internal constant FEE_CAP = 200; // nonzero is the cross-market opt-in

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(40, alice));
        (ace, pm, read, home) = (d.ace, d.positionManager, d.read, d.id);
        _deposit(home, alice, TOP);
        usdc.mint(borrower, 5_000_000e6);
    }

    /// @dev The cross-market roll suite's shape with the decline channel OFF and every off-channel dial zeroed.
    function _params(uint256 baseBps, address lender_) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = baseBps;
        p.lender = lender_;
        p.minTenor = TEN7;
        p.maxTenor = TEN7;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
        p.deleverageBandBps = 0;
        p.deleverageTargetBps = 0;
        p.deleverageStopBps = 0;
        p.deleverageProtocolBps = 0;
        p.deleverageFloorEpsBps = 0;
    }

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev Creation through a raw call, so a genesis refusal reads as a result, not a setUp failure.
    /// @dev A refusal must be the band-off lie-guard by its exact string: any other rail refusing would make a row vacuous.
    function _tryCreate(MarketParams memory p) internal returns (bool created, bytes32 id) {
        bytes memory ret;
        (created, ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
        if (created) id = abi.decode(ret, (bytes32));
        else assertEq(ret, abi.encodeWithSignature("Error(string)", "deleverage off but dials set"), "refused by some other rail");
    }

    /// @dev Open at home, arm with routing consent, and stand in the open half of the roll window.
    function _armedLoanInOpenWindow() internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(home, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, BUF, FEE_CAP);
        vm.stopPrank();
        _warpTo(uint256(read.loan(loanId).expiry) - uint256(MarketInit.autoRefinanceWindow(TEN7)) / 2);
    }

    /// @notice THE CONTROL: an identical band-off destination at a cheaper rate takes the roll.
    function test_Control_IdenticalBulletDestinationRoutes() public {
        bytes32 dst = ace.createMarket(_params(30, rivalLender));
        _deposit(dst, rivalLender, TOP);
        uint256 loanId = _armedLoanInOpenWindow();
        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, dst);
        assertTrue(ok, "the harness routes when nothing differs but the rate");
        assertEq(reason, bytes4(0), "no refusal");
    }

    /// @notice A value no verb reads must not decide whether a loan may move: genesis refuses it by name, or the market routes.
    function test_AnUnreadEpsNeverSplitsRouting() public {
        MarketParams memory p = _params(30, rivalLender);
        p.deleverageFloorEpsBps = 100;
        (bool created, bytes32 dst) = _tryCreate(p);
        if (!created) return; // `_tryCreate` has already asserted the refusal is the band-off lie-guard
        _deposit(dst, rivalLender, TOP);
        uint256 loanId = _armedLoanInOpenWindow();
        (bool ok,,) = ace.tryContinueTo(loanId, dst);
        assertTrue(ok, "an admitted band-off market differing only in an unread eps must be a routable destination");
    }

    /// @notice The same property for the restore target.
    function test_AnUnreadTargetNeverSplitsRouting() public {
        MarketParams memory p = _params(30, rivalLender);
        p.deleverageTargetBps = 5000;
        (bool created, bytes32 dst) = _tryCreate(p);
        if (!created) return; // `_tryCreate` has already asserted the refusal is the band-off lie-guard
        _deposit(dst, rivalLender, TOP);
        uint256 loanId = _armedLoanInOpenWindow();
        (bool ok,,) = ace.tryContinueTo(loanId, dst);
        assertTrue(ok, "an admitted band-off market differing only in an unread target must be a routable destination");
    }

    /// @notice FUZZED: a band-off destination genesis ADMITS always routes, whatever the two unread dials were set to.
    /// @notice So genesis may admit one only when both are zero, and that one must take the roll.
    /// @dev Both dials are bounded inside every OTHER rail (target under 10000, eps at its ceiling), so only the lie-guard can refuse.
    /// @dev A quarter of each dial's draws map to zero, so the admitted-and-routed arm is sampled rather than left to edge values.
    function testFuzz_AnAdmittedBandOffDestinationAlwaysRoutes(uint256 target, uint256 eps) public {
        target = target % 4 == 0 ? 0 : bound(target, 1, 9999);
        eps = eps % 4 == 0 ? 0 : bound(eps, 1, Constants.MAX_DELEVERAGE_FLOOR_EPS_BPS);
        MarketParams memory p = _params(30, rivalLender);
        p.deleverageTargetBps = target;
        p.deleverageFloorEpsBps = eps;
        (bool created, bytes32 dst) = _tryCreate(p);
        assertEq(created, target == 0 && eps == 0, "genesis admits a band-off market only with target and eps both zero");
        if (!created) return;
        _deposit(dst, rivalLender, TOP);
        uint256 loanId = _armedLoanInOpenWindow();
        (bool ok, bytes4 reason,) = ace.tryContinueTo(loanId, dst);
        assertTrue(ok, "an admitted band-off destination takes the roll");
        assertEq(reason, bytes4(0), "with no refusal");
    }
}

/// @title AceP1UnfundableGenesis
/// @notice AUDIT POC, run 2026-09-13-670568 phase 1, finding F2: a rail SET whose product was unrailed.
/// @notice `price > 0`, `minDebt <= 2^128` and the coverage band each held, and the market they admitted could never open.
/// @notice FIXED (#738 I-1): genesis refuses a market whose minimum ticket's coverage line is wider than an open admits.
/// @dev The width rail refuses `units > max / 1e18`; the genesis rail asks that same bound of the line, on the open door's arithmetic.
/// @dev The converse row proves the rail EXACT: at the lowest price it admits, the widest admissible lot opens the minimum ticket.
contract AceP1UnfundableGenesisTest is WarpClock {
    Ace internal ace;
    MockERC20 internal usdc;
    MockStakeVault internal vault;

    address internal lender = address(0x1E7D);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant MIN_DEBT = 2e30; // under the cash cap, and over what a price of one atom can ever secure
    uint256 internal constant WIDEST = type(uint256).max / 1e18; // the widest lot `_preChecks` admits

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        ace = AceFixtures.newAce();
    }

    /// @dev Recordless, so no draw cap can be the reason anything refuses.
    function _params(uint256 price) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(0);
        p.lender = lender;
        p.price = price;
        p.minDebt = MIN_DEBT;
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(lender, amt);
        vm.startPrank(lender);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @notice THE CONTROL: the same ticket at par opens, so the refusals below are the price and not the fixture.
    function test_Control_TheSameTicketAtParOpens() public {
        bytes32 id = ace.createMarket(_params(AceFixtures.marketParams(address(usdc), address(vault)).price));
        _deposit(id, MIN_DEBT);
        ace.previewOpen(id, 3e42, MIN_DEBT, TEN7, borrower, OpenBounds(0, 0, 0));
    }

    /// @notice Genesis refuses the market by name: at one raw unit of price the minimum ticket's line is wider than any lot an open takes.
    /// @dev Replaces the four premises that showed it admitted, took cash, and refused its widest lot.
    function test_GenesisRefusesAMarketWhoseMinimumTicketCannotOpen() public {
        MarketParams memory p = _params(1); // hoisted: its decimals() reads would eat the one-shot expectRevert
        vm.expectRevert(bytes("min ticket unopenable"));
        ace.createMarket(p);
    }

    /// @notice THE CONVERSE, proving the rail exact: at the lowest price genesis admits, the widest admissible lot opens.
    /// @notice One raw unit under that price, genesis refuses.
    /// @dev The boundary is found on the test's own spelling of the coverage line, `ceil(k * minDebt * 2^96 / (price * 1e18)) + 1`.
    function test_AtTheBoundaryPriceTheWidestLotOpensTheMinimumTicket() public {
        uint256 k = _params(1).minCoverageWad;
        uint256 lo = 1; // refused: shown by the row above
        uint256 hi = AceFixtures.marketParams(address(usdc), address(vault)).price; // par: admitted
        assertGt(_line(k, hi), 0, "PREMISE: the line is well defined at par");
        assertLe(_line(k, hi), WIDEST, "PREMISE: par admits the ticket");
        while (hi - lo > 1) {
            uint256 m = (lo + hi) / 2;
            if (_line(k, m) <= WIDEST) hi = m;
            else lo = m;
        }
        MarketParams memory under = _params(hi - 1);
        vm.expectRevert(bytes("min ticket unopenable"));
        ace.createMarket(under);
        bytes32 id = ace.createMarket(_params(hi));
        _deposit(id, MIN_DEBT);
        Borrower.Quote memory q = ace.previewOpen(id, WIDEST, MIN_DEBT, TEN7, borrower, OpenBounds(0, 0, 0));
        assertLe(q.triggerAtOpen, hi, "the widest lot triggers at or under the boundary price");
        emit log_named_uint("lowest admitted raw price for this ticket", hi);
    }

    /// @dev The coverage line of the minimum ticket at `price`, below the price branch where `price * 1e18` cannot wrap.
    function _line(uint256 k, uint256 price) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(k * MIN_DEBT, 1 << 96, price * 1e18) + 1;
    }

    /// @notice A market genesis admits must admit at least one lot at its own minimum ticket: at EVERY price, refused or openable.
    /// @dev The price is drawn LOG-uniform over `[1, par]`, so the small prices around the boundary are reached, not one draw in 2^56.
    /// @dev The ticket is drawn log-uniform up to the cash cap, which lifts the boundary to ~3e8 and widens what a loose rail would admit.
    /// @dev A refusal passes only under the rail's own name, so a different refusal cannot turn the row green.
    function testFuzz_AnAdmittedMarketHasAnOpenableLot(uint256 priceSeed, uint256 debtSeed) public {
        uint256 par = AceFixtures.marketParams(address(usdc), address(vault)).price;
        MarketParams memory p = _params(_logUniform(priceSeed, 1, par));
        p.minDebt = _logUniform(debtSeed, MIN_DEBT, type(uint128).max);
        (bool created, bytes memory ret) = address(ace).call(abi.encodeCall(Ace.createMarket, (p)));
        if (!created) {
            assertEq(keccak256(ret), keccak256(abi.encodeWithSignature("Error(string)", "min ticket unopenable")), "refused, but not by the I-1 rail");
            return;
        }
        bytes32 id = abi.decode(ret, (bytes32));
        _deposit(id, p.minDebt);
        (bool ok,) = address(ace).call(abi.encodeCall(Ace.previewOpen, (id, WIDEST, p.minDebt, TEN7, borrower, OpenBounds(0, 0, 0))));
        assertTrue(ok, "genesis admitted a market in which no collateral quantity can open the minimum ticket");
    }

    /// @dev A draw from `[lo, hi]` uniform in its bit length: the low half of the seed picks the octave, the high half the value in it.
    function _logUniform(uint256 seed, uint256 lo, uint256 hi) internal pure returns (uint256) {
        uint256 e = bound(seed & type(uint64).max, Math.log2(lo), Math.log2(hi));
        return bound(seed >> 64, Math.max(lo, 1 << e), Math.min(hi, (1 << (e + 1)) - 1));
    }
}
