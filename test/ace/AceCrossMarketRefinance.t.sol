// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MarketPairMismatch, NotBorrower, QuoteMismatch} from "../../src/ace/hub/Borrower.sol";
import {BelowMinDebt, TenorOutOfRange, TriggerAboveFloor} from "../../src/ace/hub/Borrower.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {NoMarket} from "../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IAceRefinance, MigrateArgs} from "../utils/RebateHarness.sol";

/// @notice A borrower contract that tries to continue its own loan from inside its deleverage callback.
/// @dev Both verbs are probed: `refinance` pins today's guard, `refinanceTo` pins the new entry's.
/// @dev The point is the SHARED transient slot, which relocating the body into `Borrower` must not move.
contract ReentrantMigrator is IAceDeleverageCallback {
    Ace internal immutable ACE;
    MigrateArgs internal args;
    bool internal useDestination;

    constructor(Ace ace) {
        ACE = ace;
    }

    /// @notice Open a loan in this contract's own name, so it holds title and may continue it.
    function openLoan(bytes32 mid, address coll, address quote, uint256 units, uint256 principal, uint64 tenor) external returns (uint256) {
        IERC20(coll).approve(ACE.POSITION_MANAGER(), units);
        IERC20(quote).approve(address(ACE), type(uint256).max);
        return ACE.open(mid, units, principal, tenor, address(this), OpenBounds(0, 0, 0));
    }

    function arm(MigrateArgs memory m, bool destination) external {
        args = m;
        useDestination = destination;
    }

    function crank(uint256 id) external {
        ACE.deleverage(id, 0, "");
    }

    function onAceDeleverage(uint256, uint256, bytes calldata) external {
        MigrateArgs memory m = args;
        if (useDestination) {
            IAceRefinance(address(ACE)).refinanceTo(m);
        } else {
            IAceRefinance(address(ACE)).refinance(m.id, m.newPrincipal, m.newTenor, m.bnd);
        }
    }
}

/// @title AceCrossMarketRefinance
/// @notice C41 plan tests 1-19: `refinanceTo` across TWO markets that share a quote AND a collateral.
/// @notice Written failing-first before `refinanceTo` existed; the verb shipped and this suite is green.
/// @dev Every error case asserts the SPECIFIC selector the plan's 7c table names, never a bare revert.
/// @dev A named selector reads as a specification, not an absence, which is why it outlived the stub.
/// @dev The atomicity cases use a raw call so the bit-identical assertions still run on the failure path.
/// @dev The verb is reached through `IAceRefinance`, declared in `test/utils/RebateHarness.sol`.
/// @dev THE SIGNATURE IS THE CONTRACT: `MigrateArgs` field order expands into the selector.
contract AceCrossMarketRefinanceTest is WarpClock {
    Ace internal ace;
    IAceRefinance internal fin;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal recA;
    MockPersistenceRecord internal recB;
    bytes32 internal idA;
    bytes32 internal idB;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal mallory = address(0xBAD);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant FLOAT = 2_000_000e6;
    /// @dev The ELAPSED half of a 30-day loan's 600 fee escrow at t+15d, which the retirement earns.
    /// @dev It credits A's own funding ticks before the melt, so A's cash takes it ON TOP of the debt.
    uint256 internal constant EARNED30_AT15 = 300e6;
    uint256 internal constant REFUND30_AT15 = 300e6; // the UNEARNED half of that escrow, which the retirement pays back
    uint256 internal constant FEE30_B = 2_640e6; // B's ALL-IN origination on a 30-day draw of P, at its own 80 bps
    uint256 internal constant TOP_UP_B = FEE30_B - REFUND30_AT15; // what the netting leaves the caller to fund

    /// @dev A's origination is 40 bps per 7d; B's is 80. The whole point of test 5.
    uint256 internal constant BASE_BPS_A = 40;
    uint256 internal constant BASE_BPS_B = 80;
    uint256 internal constant K_A = 1.4e18;
    uint256 internal constant K_B = 1.2e18;
    uint256 internal constant HWM_B = 1.5e18; // B's record's windowed minimum, as a human WAD

    uint256 internal TA_TOP; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal TA_DEEP; // the depth A's draws walk down to
    uint256 internal TB_TOP; // deliberately NOT A's top tick, so the two floors differ
    uint256 internal TB_DEEP; // the depth B's draws walk down to
    uint256 internal constant TOP_CASH = 400_000e6;
    uint256 internal constant DEEP_CASH = 200_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);
    uint256 internal t0;

    /// @dev Everything a failed migration must leave untouched, on BOTH markets and the old loan.
    struct Snap {
        uint256 cashA;
        uint256 lentA;
        uint256 revA;
        uint256 cashB;
        uint256 lentB;
        uint256 revB;
        uint256 loansA;
        uint256 loansB;
        uint256 loanCount;
        uint256 debt;
        uint256 units;
        uint256 floorA;
        uint256 claims;
        uint256 pmUnits;
        uint256 principal;
        uint256 hubQuote;
        uint256 hubColl;
        uint256 borrowerQuote;
        uint64 closedAt;
    }

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (TA_TOP, TA_DEEP, TB_TOP, TB_DEEP) = (_price(0), _price(-6000), _price(600), _price(-3000));
        recA = new MockPersistenceRecord(address(usdc), address(vault));
        recB = new MockPersistenceRecord(address(usdc), address(vault));
        /// @dev The two markets DIVERGE on the window, which now lives on each market's own record.
        /// @dev It is also the migration answer: a cross-market move reads the DESTINATION record over its own window.
        recA.setWindows(30 minutes, 4 hours);
        recB.setWindows(20 minutes, 2 hours);
        recB.setMinPrice(AceFixtures.px(HWM_B, address(usdc), address(vault)));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_paramsA());
        (ace, pm, read, idA) = (d.ace, d.positionManager, d.read, d.id);
        idB = ace.createMarket(_paramsB());
        fin = IAceRefinance(address(ace));

        _deposit(idA, TOP_CASH);
        _deposit(idA, DEEP_CASH);
        _deposit(idB, TOP_CASH);
        _deposit(idB, DEEP_CASH);
        usdc.mint(borrower, FLOAT);
    }

    // ---- fixture ----

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    /// @dev Market A: the source. k = 1.4, 40 bps, deleverage OFF.
    function _paramsA() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(recA);
        p.baseBps = BASE_BPS_A;
        p.minCoverageWad = K_A;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    /// @dev Market B: the destination. EVERY regime field the plan's 7b table lets diverge, diverging.
    /// @dev Same quote and same collateral, which is the ONLY compatibility rule (7b).
    function _paramsB() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(recB); // the differentiator: its own record is what makes B a distinct id
        p.baseBps = BASE_BPS_B;
        p.minCoverageWad = K_B;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000; // the decline channel is OFF in A and ON here
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1000;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    /// @dev THE HORIZON OVERLOAD IS GONE with the field it named. It existed because a deposit carried its own
    /// @dev maturity CONSENT, so a test could rest cash a 30-day destination would then refuse. A market's
    /// @dev `maxTenor` is that consent now, fixed at genesis, so there is one deposit and nothing to overload on.
    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, principal, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _args(uint256 oldId, bytes32 dst, uint256 principal, uint64 tenor) internal view returns (MigrateArgs memory) {
        return MigrateArgs(oldId, dst, principal, tenor, OFF, 0, address(0));
    }

    /// @dev The old debt less what the destination's draw nets: the shortfall the migration must not carry.
    /// @dev The fee is the DESTINATION's, which is the whole reason a cross-market roll can fall short.
    function _gap(MigrateArgs memory m) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(m.dst);
        uint256 feeNew = LoanMath.originationFee(m.newPrincipal, m.newTenor, p.baseBps, p.minTenor);
        uint256 credit = m.newPrincipal - feeNew + read.earlyExitRefund(m.id);
        uint256 debtOld = read.loan(m.id).debt;
        return credit >= debtOld ? 0 : debtOld - credit;
    }

    /// @dev The raw door, so a failure keeps its data and the caller can still assert state.
    function _rawMigrate(address caller, MigrateArgs memory m) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(ace).call(abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m));
    }

    /// @dev The success door. An EMPTY revert today means the selector is simply not there yet.
    /// @dev A short draw goes through the repay-then-migrate COMPOSITION, since the verb no longer pulls.
    /// @dev So those rows exercise the composition, moving the same net, and their numbers are unchanged.
    function _migrate(address caller, MigrateArgs memory m) internal returns (uint256 newId) {
        uint256 gap = _gap(m);
        if (gap != 0) {
            bytes[] memory calls = new bytes[](2);
            calls[0] = abi.encodeCall(Ace.repay, (m.id, gap));
            calls[1] = abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m);
            vm.prank(caller);
            bytes[] memory res = ace.multicall(calls);
            return abi.decode(res[1], (uint256));
        }
        (bool ok, bytes memory ret) = _rawMigrate(caller, m);
        if (!ok) _bubble(ret);
        newId = abi.decode(ret, (uint256));
    }

    function _bubble(bytes memory ret) private pure {
        require(ret.length != 0, "Ace.refinanceTo(MigrateArgs) is MISSING -- build it");
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    /// @dev Asserts the migration failed with EXACTLY `sel`, then returns so state asserts still run.
    function _refuses(address caller, MigrateArgs memory m, bytes4 sel, string memory why) internal {
        (bool ok, bytes memory ret) = _rawMigrate(caller, m);
        assertFalse(ok, why);
        assertEq(bytes32(bytes4(ret)), bytes32(sel), why);
    }

    /// @dev THE LENDER LEGS ARE POOLED, so when A and B share a lender and quote they are ONE number and
    /// @dev the A/B split below reads the same figure twice. That is the honest reading: a migration between
    /// @dev two of one lender's markets moves nothing at the pool, which is a property this file now pins.
    function _snap(uint256 oldId) internal view returns (Snap memory s) {
        MarketState memory a = read.marketState(idA);
        MarketState memory b = read.marketState(idB);
        (uint256 restA, uint256 lentA,) = read.poolOf(idA);
        (uint256 restB, uint256 lentB,) = read.poolOf(idB);
        (s.cashA, s.lentA, s.revA) = (restA, lentA, a.protocolRevenue);
        (s.cashB, s.lentB, s.revB) = (restB, lentB, b.protocolRevenue);
        s.loansA = ace.marketLoansLength(idA);
        s.loansB = ace.marketLoansLength(idB);
        s.loanCount = read.loanCount();
        s.debt = read.debtOf(oldId);
        s.units = read.loan(oldId).collateralUnits;
        s.closedAt = read.loan(oldId).closedAt;
        s.floorA = read.fundingFloor(idA, oldId);
        s.claims = read.claimCount(idA, oldId);
        s.pmUnits = pm.collateralOf(oldId);
        s.principal = read.principalOf(oldId);
        s.hubQuote = usdc.balanceOf(address(ace));
        s.hubColl = vault.balanceOf(address(ace));
        s.borrowerQuote = usdc.balanceOf(borrower);
    }

    function _assertSnapEq(Snap memory x, Snap memory y, string memory why) internal pure {
        assertEq(x.cashA, y.cashA, string.concat(why, ": A totalCash"));
        assertEq(x.lentA, y.lentA, string.concat(why, ": A totalLent"));
        assertEq(x.revA, y.revA, string.concat(why, ": A protocolRevenue"));
        assertEq(x.cashB, y.cashB, string.concat(why, ": B totalCash"));
        assertEq(x.lentB, y.lentB, string.concat(why, ": B totalLent"));
        assertEq(x.revB, y.revB, string.concat(why, ": B protocolRevenue"));
        assertEq(x.loansA, y.loansA, string.concat(why, ": A openedLoans"));
        assertEq(x.loansB, y.loansB, string.concat(why, ": B openedLoans"));
        assertEq(x.loanCount, y.loanCount, string.concat(why, ": loan id counter"));
        assertEq(x.debt, y.debt, string.concat(why, ": old debt"));
        assertEq(x.units, y.units, string.concat(why, ": old collateral units"));
        assertEq(x.closedAt, y.closedAt, string.concat(why, ": old close stamp"));
        assertEq(x.floorA, y.floorA, string.concat(why, ": old funding floor"));
        assertEq(x.claims, y.claims, string.concat(why, ": old claim ticks"));
        assertEq(x.pmUnits, y.pmUnits, string.concat(why, ": custody"));
        assertEq(x.principal, y.principal, string.concat(why, ": principalOf"));
        assertEq(x.hubQuote, y.hubQuote, string.concat(why, ": hub quote balance"));
        assertEq(x.hubColl, y.hubColl, string.concat(why, ": hub collateral balance"));
        assertEq(x.borrowerQuote, y.borrowerQuote, string.concat(why, ": borrower quote balance"));
    }

    // ============ 1-4. the migration itself ============

    /// @notice Plan test 1: the new loan lives in B, the old one is retired, and the ids are distinct.
    /// @dev The ONE variable that made refinance same-market was `mid`, read once at Ace.sol:632.
    function test_CrossMarket_HappyPath_TheNewLoanLivesInB() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);

        uint256 newId = _migrate(borrower, _args(oldId, idB, P, TEN30));

        assertGt(newId, oldId, "a migration allocates a NEW loan id, never reuses one");
        assertEq(read.loan(oldId).market, idA, "the retired loan keeps its own market");
        assertEq(read.loan(newId).market, idB, "and the fresh one is a market B loan");
        assertTrue(read.loan(oldId).closedAt != 0, "the old loan is retired");
        assertEq(read.debtOf(oldId), 0, "and its debt is retired in FULL");
        assertFalse(read.loan(newId).closedAt != 0, "the new loan is live");
        assertEq(read.debtOf(newId), P, "at the requested principal");
        assertEq(read.loan(newId).borrower, borrower, "titled to the same borrower");
        assertEq(read.loan(newId).expiry, _now() + TEN30, "with a fresh term from now");
    }

    /// @notice Plan test 2: the credit moves from the old id to the new one, with no orphan.
    /// @dev A cross-market refinance shares the pot with market A's other loans, so the pot must not move.
    /// @dev The hub also custodies market B's lender INVENTORY, so its balance must come back unchanged.
    function test_CrossMarket_Custody_MovesWholeAndStrandsNothingAtTheHub() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 potBefore = vault.balanceOf(address(pm));
        uint256 custodiedBefore = pm.custodiedOf(address(vault));
        uint256 hubCollBefore = vault.balanceOf(address(ace));

        uint256 newId = _migrate(borrower, _args(oldId, idB, P, TEN30));

        assertEq(pm.collateralOf(newId), COLL, "the ledger credits the new id");
        assertEq(pm.collateralOf(oldId), 0, "and the old id is emptied");
        assertEq(vault.balanceOf(address(pm)), potBefore, "a cross-market refinance moves ZERO tokens either");
        assertEq(pm.custodiedOf(address(vault)), custodiedBefore, "and the pot-level aggregate is invariant");
        assertEq(vault.balanceOf(address(ace)), hubCollBefore, "the hub's collateral holding is unchanged");
        assertEq(read.loan(newId).collateralUnits, COLL, "the loan record agrees");
    }

    /// @notice Plan test 3: A's lenders take par through their CLASSES, and A's claims are gone.
    /// @dev `openedLoans` is append-only, so the retired id stays enumerated -- membership is ever-opened.
    function test_CrossMarket_ABooks_LentDownCashUp_ClaimsGone_StillEnumerated() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        (uint256 restBefore, uint256 lentBefore, uint256 owedBefore) = read.poolOf(idA);
        uint256 lenA = ace.marketLoansLength(idA);

        _migrate(borrower, _args(oldId, idB, P, TEN30));

        /// @dev A AND B SHARE A POOL: same lender, same quote, so `lent` falls at A and rises at B inside
        /// @dev ONE number and nets to zero. That is the honest statement of what a migration does to the
        /// @dev lender -- the loan moved, their capital did not -- and it is stronger than the old per-market
        /// @dev pair, which could hold while the two legs disagreed by any amount that happened to cancel.
        (uint256 restAfter, uint256 lentAfter, uint256 owedAfter) = read.poolOf(idA);
        assertEq(lentAfter, lentBefore, "the lender's drawn principal is UNMOVED: the loan changed markets, not hands");
        assertEq(restBefore - restAfter, P, "the new draw came out of resting cash, as any draw does");
        /// @dev AND B'S OWN ORIGINATION CUT, which the same pool takes the moment the successor opens.
        /// @dev It was invisible while `owed` was a per-market figure; A and B share one (lender, quote)
        /// @dev position, so the migration's credit and the new draw's credit land in the same number.
        assertEq(
            owedAfter - owedBefore,
            P + EARNED30_AT15 + _lenderCutAtOpen(P, TEN30, BASE_BPS_B, TEN7),
            "and par returned to the pool, plus the escrow the served term earned and B's own cut"
        );
        assertEq(_liveClaims(idA, oldId), 0, "A holds no claim for the retired loan");
        assertEq(read.fundingFloor(idA, oldId), 0, "and its funding floor retires with it");
        assertEq(ace.marketLoansLength(idA), lenA, "A's ever-opened list is append-only and unchanged");
        assertEq(ace.marketLoans(idA, 0, 10)[0], oldId, "the retired id is still enumerated by A");
    }

    /// @notice Plan test 4: B enumerates the new loan and writes a floor from ITS OWN walk.
    /// @dev B's top tick is 600 and A's is 0, so a floor carried across would be visible as A's price.
    function test_CrossMarket_BBooks_EnumeratesTheNewLoan_WithBsOwnFloor() public {
        uint256 oldId = _open(idA, P, TEN30);
        uint256 floorInA = read.fundingFloor(idA, oldId);
        _warpTo(t0 + 15 days);
        uint256 lenB = ace.marketLoansLength(idB);

        uint256 newId = _migrate(borrower, _args(oldId, idB, P, TEN30));

        assertEq(ace.marketLoansLength(idB), lenB + 1, "B's ever-opened list grew by the migrated loan");
        assertEq(ace.marketLoans(idB, lenB, 10)[0], newId, "and names it");
        uint256 floorInB = read.fundingFloor(idB, newId);
        assertGt(floorInB, 0, "B wrote a funding floor of its own");
        /// @dev WAS `floorInB != floorInA`, which held because A and B ran different LADDERS and a walk
        /// @dev could land anywhere. The price is a market PARAM now and this rig's two markets happen to
        /// @dev bid alike, so inequality proves nothing. What the row is about is WHOSE answer it is, and
        /// @dev that is exact: B's floor IS B's own `price`, and A's was A's.
        assertEq(floorInB, ace.idToMarketParams(idB).price, "and it is B's own price, never A's carried across");
        assertEq(floorInA, ace.idToMarketParams(idA).price, "as A's was A's");
        assertEq(read.fundingFloor(idA, newId), 0, "A holds no floor for a loan that is not its own");
        assertEq(read.claimCount(idB, newId), 1, "B funded it at B's own price");
    }

    // ============ 5-8. whose config prices the new loan ============

    /// @notice Plan test 5: B's `baseBps` prices the origination -- B's lenders fund it, B's pot takes it.
    /// @dev The one-Cfg shape is what guarantees this; threading A's would price the loan at 40 bps.
    function test_CrossMarket_BsFeePricesTheNewLoan() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 revA = read.protocolRevenue(idA);
        uint256 revB = read.protocolRevenue(idB);

        _migrate(borrower, _args(oldId, idB, P, TEN30));

        uint256 den = 10000 * 10000 * uint256(TEN7);
        uint256 feeA = (P * BASE_BPS_A * TEN30 * 11000 + den - 1) / den;
        uint256 feeB = (P * BASE_BPS_B * TEN30 * 11000 + den - 1) / den;
        assertEq(feeB, feeA * 2, "fixture: B's origination is exactly twice A's");
        assertEq(read.protocolRevenue(idB) - revB, (feeB * 1000) / 11000, "B's pot took the hub's cut of B's all-in");
        assertEq(read.protocolRevenue(idA), revA, "and A's pot took nothing for a loan it does not carry");
    }

    /// @notice Plan test 6: the new loan answers to B's regime, which is the repricing being bought.
    /// @dev Asserted through the loan's own `market`, since a loan stores no copy of its market's rules.
    function test_CrossMarket_BsRegimeGovernsTheNewLoan() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);

        uint256 newId = _migrate(borrower, _args(oldId, idB, P, TEN30));

        MarketParams memory pb = ace.idToMarketParams(read.loan(newId).market);
        MarketParams memory pa = ace.idToMarketParams(read.loan(oldId).market);
        assertEq(pb.minCoverageWad, K_B, "the new loan's trigger multiplier is B's");
        assertEq(pa.minCoverageWad, K_A, "and A's is untouched, so the two genuinely differ");
        assertEq(pb.deleverageBandBps, 3000, "B's decline channel governs it");
        assertEq(pa.deleverageBandBps, 0, "where A had none at all");
        assertEq(MockPersistenceRecord(pb.record).PERSISTENCE_WINDOW(), 20 minutes, "and B's distress window times it");
        assertEq(MockPersistenceRecord(pa.record).PERSISTENCE_WINDOW(), 30 minutes, "not A's");
    }

    /// @notice Plan test 7: the successor's per-loan state is seeded FRESH, from the draw it just made.
    /// @dev Nothing per-loan is carried across a migration any more, so `principalOf` is the whole of it.
    function test_CrossMarket_FreshBaselines_SeededFromBsSources() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);

        uint256 newId = _migrate(borrower, _args(oldId, idB, P, TEN30));

        assertEq(read.principalOf(newId), P, "principalOf is the fresh draw");
        assertGt(read.fundingFloor(idB, newId), 0, "and the successor reseeded its floor off B's own ladder");
        assertEq(read.loan(newId).openTime, _now(), "and the term clock restarts here");
    }

    // ============ 9-14. the refusals ============

    /// @notice Plan test 9: a destination securing DIFFERENT collateral is refused before state moves.
    /// @dev Without this the second hop would pull the DESTINATION's collateral out of lender inventory.
    /// @dev The measured hop would also catch it, but by accident and under a misleading error.
    function test_CrossMarket_RefusesADifferentCollateral_AndDrainsNoInventory() public {
        MockStakeVault other = new MockStakeVault(43);
        MockPersistenceRecord recC = new MockPersistenceRecord(address(usdc), address(other));
        MarketParams memory pc = AceFixtures.marketParams(address(usdc), address(other));
        pc.record = address(recC);
        bytes32 idC = ace.createMarket(pc);
        other.mint(address(ace), 500e18); // the hub's holding stands in for C's lender inventory

        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        Snap memory before = _snap(oldId);

        _refuses(borrower, _args(oldId, idC, P, TEN7), MarketPairMismatch.selector, "a mismatched pair is refused");

        assertEq(other.balanceOf(address(ace)), 500e18, "and the destination's inventory is untouched");
        _assertSnapEq(before, _snap(oldId), "a refused pair moves nothing");
    }

    /// @notice Plan test 10: an unknown destination is `NoMarket`, free, from the cache build.
    function test_CrossMarket_RefusesAnUnknownDestination() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);

        _refuses(borrower, _args(oldId, keccak256("no such market"), P, TEN30), NoMarket.selector, "unknown id");
        _refuses(borrower, _args(oldId, bytes32(0), P, TEN30), NoMarket.selector, "the zero id is not a market");
    }

    /// @notice Plan test 11: a principal legal in A but under B's dust floor is refused by B's floor.
    /// @dev The gates that matter are on the RESULTING state in the destination, never on the origin.
    function test_CrossMarket_RefusesBelowTheDestinationsMinDebt() public {
        MarketParams memory pd = _paramsB();
        pd.minDebt = 100_000e6; // P is a legal loan in A and dust here; also what makes D a distinct id
        bytes32 idD = ace.createMarket(pd);
        _deposit(idD, TOP_CASH);

        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);

        _refuses(borrower, _args(oldId, idD, P, TEN30), BelowMinDebt.selector, "B's own dust floor binds");
    }

    /// @notice Plan test 12: a tenor legal in A but off B's grid is refused by B's range check.
    function test_CrossMarket_RefusesATenorOutsideTheDestinationsRange() public {
        MarketParams memory pd = _paramsB();
        pd.maxTenor = TEN7; // a single-rung destination; also what makes D a distinct id
        bytes32 idD = ace.createMarket(pd);
        _deposit(idD, TOP_CASH);

        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);

        _refuses(borrower, _args(oldId, idD, P, TEN30), TenorOutOfRange.selector, "B's own tenor range binds");
    }

    /// @notice Plan test 13: a destination with no drawable cash takes the WHOLE migration down.
    /// @dev A partial migration is not available even in principle -- the debt is retired in A and the
    /// @dev collateral is in transit, so there is no half-state to settle into.
    function test_CrossMarket_DestinationWithoutDrawableCash_LeavesEverythingBitIdentical() public {
        MarketParams memory pd = _paramsB();
        MockPersistenceRecord recD = new MockPersistenceRecord(address(usdc), address(vault)); // recB's twin: D differs by identity alone
        recD.setMinPrice(AceFixtures.px(HWM_B, address(usdc), address(vault)));
        pd.record = address(recD);
        bytes32 idD = ace.createMarket(pd); // created and never funded

        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        Snap memory before = _snap(oldId);

        _refuses(borrower, _args(oldId, idD, P, TEN30), InsufficientCash.selector, "an empty ladder cannot fund");

        _assertSnapEq(before, _snap(oldId), "a refused migration is a total no-op");
    }

    /// @notice Plan test 14: a destination that can only fund below the new trigger is refused.
    /// @dev Migration is not a rescue verb either: the new loan clears `trigger <= funding floor` or dies.
    function test_CrossMarket_RefusesWhenTheDestinationCannotFundAdmissibly() public {
        MarketParams memory pd = _paramsB();
        pd.minCoverageWad = 2.9e18; // a strict destination: the same debt trips its gate at any floor here
        bytes32 idD = ace.createMarket(pd);
        _deposit(idD, TOP_CASH); // funded only DEEP, so the walk's floor sits well under the trigger

        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        Snap memory before = _snap(oldId);

        _refuses(borrower, _args(oldId, idD, P, TEN30), TriggerAboveFloor.selector, "B's own gate binds");

        _assertSnapEq(before, _snap(oldId), "and a failed gate leaves the old loan whole");
    }

    // ============ 15-17. what migration is NOT ============

    /// @notice Plan test 15: a live-breach loan may migrate, and A's lenders are paid CASH AT PAR for it.
    /// @notice The control is the same loan finalized instead: claims convert to collateral at tick price.
    /// @dev THIS IS WHY MIGRATION IS NOT AN ESCAPE. Par is strictly the best outcome A's lenders can have,
    /// @dev and `LoanAccounting.meltLoan` reverts `MeltExceedsClaims` if the loan's own claims cannot cover it, so
    /// @dev full retirement is enforced by code rather than assumed.
    /// @dev Bad debt is only ever booked by `finalize`/`forceClose`; the migration path emits neither.
    function test_CrossMarket_DistressEscape_ALendersTakeParAndABooksNoBadDebt() public {
        uint256 control = _open(idA, P, TEN30);
        uint256 oldId = _open(idA, P, TEN30);
        recA.setBelowBand(read.triggerPrice(oldId));
        assertTrue(read.settleable(oldId), "fixture: both loans are settleable right now");
        _warpTo(t0 + 15 days);

        (uint256 restControlBefore,,) = read.poolOf(idA);
        vm.prank(keeper);
        ace.finalize(control);
        (uint256 restControlAfter,,) = read.poolOf(idA);
        assertEq(restControlAfter, restControlBefore, "the control repays the lender NO cash at par");
        assertGt(read.invPotOf(idA, control), 0, "it hands them collateral at the tick price instead");

        (, uint256 lentBefore, uint256 owedBefore) = read.poolOf(idA);
        vm.recordLogs();

        uint256 newId = _migrate(borrower, _args(oldId, idB, 35_000e6, TEN30));

        (, uint256 lentAfter, uint256 owedAfter) = read.poolOf(idA);
        assertApproxEqAbs(
            owedAfter - owedBefore,
            P + EARNED30_AT15 + _lenderCutAtOpen(35_000e6, TEN30, BASE_BPS_B, TEN7),
            4,
            "the migrating loan repays the lender at par, in full, plus the served term's earn and B's own cut"
        );
        /// @dev The new draw is 35_000e6, so `lent` falls by the retired P and rises by that: a NET fall of
        /// @dev the difference. A and B share the pool, so this is the only place the shrink is visible.
        assertEq(lentBefore - lentAfter, P - 35_000e6, "and the lender's drawn principal shrinks by exactly the paydown");
        assertEq(read.invPotOf(idA, oldId), 0, "no collateral was converted, so nothing was written down");
        assertEq(_countSettlementLogs(vm.getRecordedLogs()), 0, "no settlement fired, so A booked ZERO bad debt");
        assertFalse(read.settleable(newId), "and the trip dissolved: a lower debt is a lower trigger");
    }

    /// @dev The lender's IMMEDIATE cut of a new draw's origination, which lands in the pool at the open.
    /// @dev A AND B SHARE A POOL -- same lender, same quote -- so a migration's `owed` delta carries this
    /// @dev alongside par and the escrow the served term earned. It was invisible while `owed` was per-market.
    function _lenderCutAtOpen(uint256 principal, uint64 tenor, uint256 baseBps, uint64 minTenor) private pure returns (uint256) {
        return LoanMath.tickCut(LoanMath.originationFee(principal, tenor, baseBps, minTenor));
    }

    /// @dev What the LENDER is owed in quote. WAS a per-class walk of the loan's funded ticks; there is one
    /// @dev credit bucket per (lender, quote), so the loan is tracked and ignored and callers read a DELTA.
    function _classOwedAll(bytes32 mid, uint256 loanId) private view returns (uint256) {
        return read.poolOwed(mid);
    }

    /// @dev A loan's LIVE claim. It was a SUM over the funded-tick list, which survived retirement while the
    /// @dev claims on it did not; there is one claim now, and it IS the funded flag, so the sum is a read.
    function _liveClaims(bytes32 mid, uint256 loanId) private view returns (uint256) {
        return read.claimOf(mid, loanId);
    }

    /// @dev `Finalized` and `ForceClosed` are the ONLY two events that ever carry a `badDebt` figure.
    function _countSettlementLogs(Vm.Log[] memory logs) private pure returns (uint256 n) {
        bytes32 fin_ = keccak256("Finalized(uint256,uint256,uint256,address)");
        bytes32 forced = keccak256("ForceClosed(uint256,uint256,uint256,address)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == fin_ || logs[i].topics[0] == forced) n++;
        }
    }

    /// @notice Plan test 16: credit-operator migration is OUT of scope, so an operator is refused.
    /// @dev An operator may `open` in the borrower's name; migrating a position is a different decision.
    /// @dev It is also what BOUNDS the adverse-selection residual: bulk migration is where it compounds.
    function test_CrossMarket_ACreditOperatorCannotMigrate() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        vm.prank(borrower);
        ace.setCreditOperator(mallory, true);

        _refuses(mallory, _args(oldId, idB, P, TEN30), NotBorrower.selector, "an operator may not migrate");
        _refuses(address(this), _args(oldId, idB, P, TEN30), NotBorrower.selector, "and nor may anyone else");
    }

    /// @notice Plan test 17: `refinanceTo` with `dst == src` IS `refinance`, outcome for outcome.
    /// @dev Both legs run from the SAME state via a snapshot: a second draw walks a ladder the first
    /// @dev already thinned, so running them back to back would not be a control at all.
    function test_CrossMarket_MigratingToTheSourceMarket_EqualsARefinance() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 root = vm.snapshotState();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (oldId, _gap(_args(oldId, idA, P, TEN30))));
        calls[1] = abi.encodeCall(Ace.refinance, (oldId, P, TEN30, OFF));
        vm.prank(borrower);
        uint256 refiId = abi.decode(ace.multicall(calls)[1], (uint256));
        Snap memory viaRefinance = _snap(oldId);
        uint256 refiFloor = read.fundingFloor(idA, refiId);
        uint256 refiDebt = read.debtOf(refiId);
        uint256 refiEscrow = read.feeEscrowOf(refiId);

        vm.revertToState(root);
        uint256 migId = _migrate(borrower, _args(oldId, idA, P, TEN30));

        assertEq(migId, refiId, "the same fresh id");
        assertEq(read.debtOf(migId), refiDebt, "the same debt");
        assertEq(read.fundingFloor(idA, migId), refiFloor, "the same funding floor");
        assertEq(read.feeEscrowOf(migId), refiEscrow, "the same withheld fee");
        _assertSnapEq(viaRefinance, _snap(oldId), "and the same market and old-loan state");
    }

    // ============ 18. the shared guard ============

    /// @notice Plan test 18: today's `refinance` is unreachable from inside an ACE callback.
    /// @notice This leg is GREEN and stays green: it is the regression guard on the relocation.
    /// @dev Relocating the body into `Borrower` turns a private call into a DELEGATECALL library jump.
    /// @dev The guard slot is the hub's either way, so the refusal must not move with the code.
    function test_CrossMarket_RefinanceFromInsideACallback_RefusedByTheSharedSlot() public {
        (ReentrantMigrator attacker, uint256 loanId) = _armAttacker();
        attacker.arm(_args(loanId, idB, P, TEN7), false);

        vm.expectRevert(GUARD_TRIP);
        attacker.crank(loanId);

        assertFalse(read.loan(loanId).closedAt != 0, "and the loan is exactly where it was");
    }

    /// @notice Plan test 18, the new entry: `refinanceTo` must answer to the SAME one transient slot.
    /// @dev A callback that could migrate would see A's melt half-applied, which is the whole hazard.
    function test_CrossMarket_RefinanceToFromInsideACallback_RefusedByTheSharedSlot() public {
        (ReentrantMigrator attacker, uint256 loanId) = _armAttacker();
        attacker.arm(_args(loanId, idA, P, TEN7), true);

        vm.expectRevert(GUARD_TRIP);
        attacker.crank(loanId);

        assertFalse(read.loan(loanId).closedAt != 0, "and the loan is exactly where it was");
    }

    /// @dev A contract holding its own title on B, in band, so its crank actually reaches a callback.
    /// @dev B is the market with the decline channel on; A has none, so it can never hand off control.
    function _armAttacker() private returns (ReentrantMigrator attacker, uint256 loanId) {
        attacker = new ReentrantMigrator(ace);
        vault.mint(address(attacker), COLL);
        usdc.mint(address(attacker), FLOAT);
        loanId = attacker.openLoan(idB, address(vault), address(usdc), COLL, P, TEN7);
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = (trig * 125) / 100; // inside B's 30% band and clear of its 10% stop
        recB.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - 3000 * 1e14));
        recB.setMinPrice(ps);
    }

    // ============ the netting: one migration, one token ============

    /// @notice ONE migration touches exactly ONE token, and the shortfall comes from `msg.sender` alone.
    /// @notice A second ERC20 no market here quotes in is planted at the hub and the borrower as the control.
    /// @dev This is what the quote rail buys, stated as a balance: every term of the netting is one token.
    /// @dev The shortfall now rides the repay leg of the composition, which pulls from the same caller.
    function test_CrossMarket_TheShortfallIsPaidByTheCallerInTheDestinationsQuote_AndNoOtherTokenMoves() public {
        MockERC20 stray = new MockERC20("Not A Quote", "NAQ", 6);
        stray.mint(address(ace), 500_000e6);
        stray.mint(borrower, 500_000e6);

        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        uint256 hubBefore = usdc.balanceOf(address(ace));
        uint256 borrowerBefore = usdc.balanceOf(borrower);

        _migrate(borrower, _args(oldId, idB, P, TEN30));

        assertEq(borrowerBefore - usdc.balanceOf(borrower), TOP_UP_B, "the caller funded B's fee less A's refund, exactly");
        assertEq(usdc.balanceOf(address(ace)) - hubBefore, TOP_UP_B, "and the hub took exactly that, once");
        assertEq(stray.balanceOf(address(ace)), 500_000e6, "no other token left the hub");
        assertEq(stray.balanceOf(borrower), 500_000e6, "and none left the borrower");
    }

    /// @notice A shortfall the caller cannot fund takes the WHOLE composition down, both legs together.
    /// @notice The repay leg is now where the pull lives, and it runs FIRST, so the migration never starts.
    /// @dev The caller holds the money throughout, so only the token's own refusal can be what fired.
    /// @dev The all-or-nothing property survives the cut: multicall legs share one transaction.
    function test_CrossMarket_AShortfallTheCallerCannotFund_LeavesEverythingBitIdentical() public {
        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        vm.prank(borrower);
        usdc.approve(address(ace), 0);
        assertGe(usdc.balanceOf(borrower), TOP_UP_B, "fixture: the caller HOLDS the money; only the approval is missing");
        Snap memory before = _snap(oldId);

        MigrateArgs memory m = _args(oldId, idB, P, TEN30);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (m.id, _gap(m)));
        calls[1] = abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m);
        vm.prank(borrower);
        (bool ok,) = address(ace).call(abi.encodeCall(Ace.multicall, (calls)));

        assertFalse(ok, "an unfundable shortfall takes the composition down");
        _assertSnapEq(before, _snap(oldId), "a failed pull is a total no-op");
    }

    /// @notice A destination quoting a DIFFERENT token is refused before any state moves, by its own name.
    /// @dev The collateral rail and the quote rail are separate errors, so a mutation to one kills a test.
    function test_CrossMarket_RefusesADifferentQuote_AndMovesNothing() public {
        MarketParams memory pq = _paramsB();
        pq.quote = address(new MockERC20("Other USD", "OUSD", 6));
        pq.record = address(new MockPersistenceRecord(pq.quote, address(vault)));
        bytes32 idQ = ace.createMarket(pq);

        uint256 oldId = _open(idA, P, TEN30);
        _warpTo(t0 + 15 days);
        Snap memory before = _snap(oldId);

        _refuses(borrower, _args(oldId, idQ, P, TEN30), QuoteMismatch.selector, "a mismatched quote is refused");

        _assertSnapEq(before, _snap(oldId), "a refused quote moves nothing");
    }

    // ============ 19. the gas curve ============

    /// @notice Plan test 19: the cross-market gas curve at 1 / 8 / 25 / 32 claim ticks.
    /// @notice A migration walks TWO ladders, which is the worst case the claim-cap ceiling awaits.
    /// @dev A MEASUREMENT, logged; the only assertion is the operational one.
    function test_CrossMarket_GasCurve_AcrossClaimTickCounts() public {
        _gasAt(1);
        _gasAt(8);
        _gasAt(25);
        _gasAt(32); // the genesis rail: the widest spread any market may legally reach
    }

    /// @dev One measurement point on its own PAIR of markets, so no ladder is ever shared.
    function _gasAt(uint256 n) private {
        MarketParams memory pa = _paramsA();
        MarketParams memory pb = _paramsB();
        pa.minDebt = 10e6 + n; // inert; it only makes each measurement point a distinct market id
        pb.minDebt = 10e6 + n;
        bytes32 srcId = ace.createMarket(pa);
        bytes32 dstId = ace.createMarket(pb);

        uint256 draw = n * 1_000e6;
        usdc.mint(alice, draw * 4);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        for (uint256 i; i < n; i++) {
            ace.deposit(srcId, 1_000e6);
        }
        ace.deposit(dstId, draw * 2);
        vm.stopPrank();

        uint256 units = 400_000e18;
        vault.mint(borrower, units);
        usdc.mint(borrower, draw * 2);
        vm.startPrank(borrower);
        vault.approve(address(pm), units);
        usdc.approve(address(ace), type(uint256).max);
        uint256 loanId = ace.open(srcId, units, draw, TEN7, borrower, OpenBounds(0, 0, 0));
        assertEq(read.claimCount(srcId, loanId), 1, "fixture: the draw holds exactly one claim");

        MigrateArgs memory m = MigrateArgs(loanId, dstId, draw, TEN7, OFF, 0, address(0));
        bytes[] memory legs = new bytes[](2);
        legs[0] = abi.encodeCall(Ace.repay, (loanId, _gap(m)));
        legs[1] = abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m);
        bytes memory cd = abi.encodeCall(Ace.multicall, (legs));
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(ace).call(cd);
        uint256 used = g - gasleft();
        vm.stopPrank();
        if (!ok) _bubble(ret);

        console2.log(n, used);
        assertLt(used, 30_000_000, "a cross-market migration must fit inside a mainnet block");
    }
}
