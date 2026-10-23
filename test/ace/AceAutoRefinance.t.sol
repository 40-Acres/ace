// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds, Storage} from "../../src/ace/hub/Types.sol";
import {
    AutoPolicyDisarmed,
    AutoTenorUnfundable,
    BufferBelowMin,
    BufferOutOfRange,
    DrawBelowDebt,
    LoanClosed,
    NotBorrower,
    OutsideRefinanceWindow,
    PayoutBelowMin,
    RoutingNeedsBuffer,
    TenorOutOfRange,
    TriggerAboveFloor
} from "../../src/ace/hub/Borrower.sol";
import {IAceDeleverageCallback} from "../../src/interfaces/IAceDeleverageCallback.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IAceRefinance, MigrateArgs} from "../utils/RebateHarness.sol";

/// @notice C41 section 6's auto-refinance surface, declared test-side so this file compiles today.
/// @dev Cast onto `address(ace)`; `Ace` has no fallback, so an absent selector reverts with EMPTY data.
/// @dev THE SIGNATURE IS THE CONTRACT: a shipped mismatch shows up as every test here reverting.
interface IAceAutoRefinance {
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
    function refinanceByPolicy(uint256 id) external returns (uint256 newId);
    /// @notice The ALL-OR-NOTHING batch: any refusal takes the whole transaction with it.
    function refinanceByPolicies(uint256[] calldata ids) external returns (uint256[] memory newIds);
}

/// @notice THE TIP-SELECTOR NEGATIVE IS GONE, and its absence is deliberate rather than an omission.
/// @notice `(uint256,uint64,uint16,uint16)` once proved a deleted tip setter absent; `maxFeeBps` now occupies it.
/// @notice A selector-shaped guard can no longer tell a fee CEILING from a tip, so A16 asks by BEHAVIOUR instead.
/// @dev The property defended is unchanged: a whole run pays `msg.sender` nothing, whatever the fourth argument says.

/// @notice The policy view section 6.1 makes load-bearing: a stored policy is only useful if READABLE.
interface IAceLensAuto {
    function autoPolicyOf(uint256 id) external view returns (uint64 tenor, uint16 minBufferBps);
}

/// @notice A borrower contract that reaches each of C41's THREE new entries from inside a deleverage callback.
/// @dev The three are the only unguarded-by-default surface the round added; each carries its own modifier.
/// @dev Dropping `nonReentrant` from any of them compiles, ships, and changes no other test.
contract ReentrantAutoCaller is IAceDeleverageCallback {
    Ace internal immutable ACE;
    uint256 internal target;
    uint8 internal door;

    constructor(Ace ace) {
        ACE = ace;
    }

    /// @notice Open in this contract's own name, so it holds the title every door here needs.
    function openLoan(bytes32 mid, address coll, address quote, uint256 units, uint256 principal, uint64 tenor) external returns (uint256) {
        IERC20(coll).approve(ACE.POSITION_MANAGER(), units);
        IERC20(quote).approve(address(ACE), type(uint256).max);
        return ACE.open(mid, units, principal, tenor, address(this), OpenBounds(0, 0, 0));
    }

    /// @notice `which` picks the door: 0 arms, 1 executes the singular, 2 executes the batch.
    function arm(uint256 id, uint8 which) external {
        target = id;
        door = which;
    }

    function setPolicy(uint256 id, uint64 tenor) external {
        IAceAutoRefinance(address(ACE)).setAutoRefinance(id, tenor, 0, 0);
    }

    function crank(uint256 id) external {
        ACE.deleverage(id, 0, "");
    }

    function onAceDeleverage(uint256, uint256, bytes calldata) external {
        if (door == 0) {
            IAceAutoRefinance(address(ACE)).setAutoRefinance(target, 7 days, 0, 0);
        } else if (door == 1) {
            IAceAutoRefinance(address(ACE)).refinanceByPolicy(target);
        } else {
            uint256[] memory batch = new uint256[](1);
            batch[0] = target;
            IAceAutoRefinance(address(ACE)).refinanceByPolicies(batch);
        }
    }
}

/// @title AceAutoRefinance
/// @notice C41 plan tests A1-A23: the stored per-loan auto-continuation policy and its timing gate.
/// @notice Written failing-first; `setAutoRefinance` and `refinanceByPolicy` shipped and this is green.
/// @dev Happy-path tests low-level-call and, on EMPTY returndata, revert naming the gap.
/// @dev Refusal tests raw-call and compare the RETURNED SELECTOR against the one section 9 names.
/// @dev A raw call rather than `vm.expectRevert` keeps the bit-identical state assertions running today.
contract AceAutoRefinanceTest is WarpClock {
    Ace internal ace;
    IAceRefinance internal fin;
    IAceLensAuto internal lensAuto;
    AceReader internal read;
    PositionManager internal pm;
    PositionTitleNFT internal title;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal mallory = address(0xBAD);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;

    /// @notice Section 6.8's keeper-latency window: `min(2 hours, minTenor / 5)`, per market by derivation.
    /// @dev This is the CAP leg. It binds on every market here except the minute-scale one in A23b.
    uint64 internal constant WINDOW = 2 hours;
    /// @dev The testnet rollover shape: a tenor short enough that the fifth binds instead of the cap.
    uint64 internal constant SHORT = 10 minutes;

    /// @dev A dust floor over the melted debt but UNDER what the surviving collateral can carry.
    uint256 internal constant REACHABLE_FLOOR = 45_000e6;
    /// @dev A dust floor over the melted debt and ALSO over what the surviving collateral can carry.
    uint256 internal constant UNREACHABLE_FLOOR = 65_000e6;
    /// @dev The same lever on the price channel, whose crank sells a different slice of the position.
    uint256 internal constant BAND_BPS = 3000;

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant FLOAT = 1_000_000e6;
    uint256 internal constant BASE_BPS = 40;
    /// @dev A second market's origination rate, so a mis-cached batch member derives a VISIBLY wrong size.
    uint256 internal constant ALT_BPS = 80;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame

    uint256 internal T; // ticks from this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal DEEP; // a second price this suite names; the draws here never fund at it
    uint256 internal constant TOP = 400_000e6;
    uint256 internal constant DEEP_CASH = 200_000e6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);
    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T, DEEP) = (_price(0), _price(-6000));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        fin = IAceRefinance(address(ace));
        title = PositionTitleNFT(ace.POSITION_TITLE());
        lensAuto = IAceLensAuto(address(new AceLens(address(ace))));

        _deposit(id, TOP);
        _deposit(id, DEEP_CASH);
        usdc.mint(borrower, FLOAT);
    }

    // ---- fixture ----

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    /// @dev The base market: a two-rung grid at 7d and 30d, so an armed tenor has somewhere to sit.
    function _params() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.baseBps = BASE_BPS;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    /// @dev A twin of `record` on the same pair, seeded identically: what makes an otherwise identical market hash distinct.
    /// @dev The draw cap is copied over, so a price the caller set before this call reaches the new market too.
    function _twinRecord() private returns (address) {
        MockPersistenceRecord twin = new MockPersistenceRecord(address(usdc), address(vault));
        twin.setMinPrice(record.minPrice(address(usdc), address(vault)));
        return address(twin);
    }

    function _deposit(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _open(uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        return _openOn(id, principal, tenor);
    }

    function _openOn(bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        return _openOnWith(mid, COLL, principal, tenor);
    }

    /// @dev The same open at a chosen collateral, for the rows whose SUCCESSOR needs margin the baseline lacks.
    function _openOnWith(bytes32 mid, uint256 coll, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(borrower, coll);
        vm.startPrank(borrower);
        vault.approve(address(pm), coll);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, coll, principal, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice Section 6.4's derived principal, written from the decision record and not from `src`.
    /// @dev `P >= (debtOld - refundOld) * D / (D - N)`, `N = baseBps*tenor*11000`, `D = 1e8*minTenor`.
    /// @dev The widened factor is the ALL-IN one: `baseBps` prices the lender, the protocol adds its share.
    /// @dev Ceiled, because a floor here would leave the continuation one wei short of retiring the debt.
    function _derivedPrincipal(uint256 debtOld, uint256 refundOld, uint64 tenor) internal pure returns (uint256) {
        uint256 d = 10000 * 10000 * uint256(TEN7);
        uint256 den = d - BASE_BPS * uint256(tenor) * 11000;
        return ((debtOld - refundOld) * d + den - 1) / den;
    }

    /// @dev What section 6.4's formula asks for on THIS loan, at THIS instant.
    function _expected(uint256 loanId, uint64 tenor) internal view returns (uint256) {
        return _derivedPrincipal(read.debtOf(loanId), read.earlyExitRefund(loanId), tenor);
    }

    /// @dev The market's ALL-IN origination fee, spelled from the record rather than called out of `src`.
    function _fee(uint256 principal, uint64 tenor) internal pure returns (uint256) {
        uint256 den = 10000 * 10000 * uint256(TEN7);
        return (principal * BASE_BPS * uint256(tenor) * 11000 + den - 1) / den;
    }

    // ---- the raw doors ----

    function _rawArm(address caller, uint256 loanId, uint64 tenor, uint16 buf) internal returns (bool ok, bytes memory ret) {
        return _rawArmFee(caller, loanId, tenor, buf, 0); // zero is home-only: every pre-routing row's own behaviour
    }

    /// @dev The fourth argument is a fee CEILING; a nonzero one also consents to a keeper-named destination.
    function _rawArmFee(address caller, uint256 loanId, uint64 tenor, uint16 buf, uint16 feeCap) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(ace).call(abi.encodeWithSelector(IAceAutoRefinance.setAutoRefinance.selector, loanId, tenor, buf, feeCap));
    }

    function _arm(address caller, uint256 loanId, uint64 tenor, uint16 buf) internal {
        (bool ok, bytes memory ret) = _rawArm(caller, loanId, tenor, buf);
        if (!ok) _bubble(ret, "Ace.setAutoRefinance(uint256,uint64,uint16,uint16) is MISSING -- build it");
    }

    function _rawExec(address caller, uint256 loanId) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(ace).call(abi.encodeWithSelector(IAceAutoRefinance.refinanceByPolicy.selector, loanId));
    }

    function _exec(address caller, uint256 loanId) internal returns (uint256 newId) {
        (bool ok, bytes memory ret) = _rawExec(caller, loanId);
        if (!ok) _bubble(ret, "Ace.refinanceByPolicy(uint256) is MISSING -- build it");
        newId = abi.decode(ret, (uint256));
    }

    function _rawExecBatch(address caller, uint256[] memory ids) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(ace).call(abi.encodeWithSelector(IAceAutoRefinance.refinanceByPolicies.selector, ids));
    }

    function _execBatch(address caller, uint256[] memory ids) internal returns (uint256[] memory newIds) {
        (bool ok, bytes memory ret) = _rawExecBatch(caller, ids);
        if (!ok) _bubble(ret, "Ace.refinanceByPolicies(uint256[]) is MISSING -- build it");
        newIds = abi.decode(ret, (uint256[]));
    }

    /// @dev A short draw rides the repay-then-migrate COMPOSITION: the verb refuses to pull a shortfall.
    /// @dev These rows are about the tenor CLAMP and the baseline carry, which the netting shape leaves alone.
    function _migrate(address caller, MigrateArgs memory m) internal returns (uint256 newId) {
        uint256 gap = _migrateGap(m);
        if (gap != 0) {
            bytes[] memory calls = new bytes[](2);
            calls[0] = abi.encodeCall(Ace.repay, (m.id, gap));
            calls[1] = abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m);
            vm.prank(caller);
            return abi.decode(ace.multicall(calls)[1], (uint256));
        }
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(ace).call(abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m));
        if (!ok) _bubble(ret, "Ace.refinanceTo(MigrateArgs) is MISSING -- build it");
        newId = abi.decode(ret, (uint256));
    }

    /// @dev A same-market continuation through the composition, for rows whose subject is not the netting.
    function _refiComposed(address caller, uint256 oldId, uint256 principal, uint64 tenor) internal returns (uint256) {
        MigrateArgs memory m = MigrateArgs(oldId, read.loan(oldId).market, principal, tenor, OFF, 0, address(0));
        uint256 gap = _migrateGap(m);
        if (gap == 0) {
            vm.prank(caller);
            return fin.refinance(oldId, principal, tenor, OFF);
        }
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (oldId, gap));
        calls[1] = abi.encodeCall(Ace.refinance, (oldId, principal, tenor, OFF));
        vm.prank(caller);
        return abi.decode(ace.multicall(calls)[1], (uint256));
    }

    /// @dev The destination's fee against the source's refund: what the fresh draw fails to cover.
    function _migrateGap(MigrateArgs memory m) internal view returns (uint256) {
        MarketParams memory p = ace.idToMarketParams(m.dst);
        uint256 feeNew = LoanMath.originationFee(m.newPrincipal, m.newTenor, p.baseBps, p.minTenor);
        uint256 credit = m.newPrincipal - feeNew + read.earlyExitRefund(m.id);
        uint256 debtOld = read.loan(m.id).debt;
        return credit >= debtOld ? 0 : debtOld - credit;
    }

    function _bubble(bytes memory ret, string memory why) private pure {
        require(ret.length != 0, why);
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    /// @dev Asserts the call failed with EXACTLY `sel`, then returns so the state asserts still run.
    function _refuses(bool ok, bytes memory ret, bytes4 sel, string memory why) internal pure {
        assertFalse(ok, why);
        assertEq(bytes32(bytes4(ret)), bytes32(sel), why);
    }

    /// @dev The lens view through the raw door, so its absence reads as a specification and not a revert.
    function _policy(uint256 loanId) internal returns (uint64 tenor, uint16 buf) {
        (bool ok, bytes memory ret) = address(lensAuto).call(abi.encodeWithSelector(IAceLensAuto.autoPolicyOf.selector, loanId));
        if (!ok || ret.length == 0) revert("AceLens.autoPolicyOf(uint256) is MISSING -- build it");
        (tenor, buf) = abi.decode(ret, (uint64, uint16));
    }

    /// @dev Everything a failed batch must leave untouched, per member.
    struct Snap {
        uint256 debt;
        uint256 units;
        uint256 escrow;
        uint256 floor;
        uint256 claims;
        uint64 expiry;
        uint64 closedAt;
    }

    function _snap(uint256 loanId) internal view returns (Snap memory) {
        return _snapOn(id, loanId);
    }

    /// @dev The same snapshot for a loan on a market other than the base fixture's.
    function _snapOn(bytes32 mid, uint256 loanId) internal view returns (Snap memory s) {
        s.debt = read.debtOf(loanId);
        s.units = read.loan(loanId).collateralUnits;
        s.escrow = read.feeEscrowOf(loanId);
        s.floor = read.fundingFloor(mid, loanId);
        s.claims = read.claimCount(mid, loanId);
        s.expiry = read.loan(loanId).expiry;
        s.closedAt = read.loan(loanId).closedAt;
    }

    function _assertSnapEq(Snap memory x, Snap memory y, string memory why) internal pure {
        assertEq(x.debt, y.debt, string.concat(why, ": debt"));
        assertEq(x.units, y.units, string.concat(why, ": collateral units"));
        assertEq(x.escrow, y.escrow, string.concat(why, ": fee escrow"));
        assertEq(x.floor, y.floor, string.concat(why, ": funding floor"));
        assertEq(x.claims, y.claims, string.concat(why, ": claim ticks"));
        assertEq(x.expiry, y.expiry, string.concat(why, ": expiry"));
        assertEq(x.closedAt, y.closedAt, string.concat(why, ": close stamp"));
    }

    /// @dev The fee a continuation credits lands in the LENDER'S POOL, not in tick cash.
    /// @dev WAS the new class's own index. There is no per-class index: one credit bucket per (lender,
    /// @dev quote), so the loan and tick are tracked and ignored, and the caller reads a DELTA to isolate.
    function _classFeeOf(uint256 loanId) internal view returns (uint256) {
        return read.poolOwed(id);
    }

    // ============ A1 / A2. the two msg.sender substitutions, SEPARATELY ============

    /// @notice A1, substitution 1: a third party executes and the NEW loan is the BORROWER's.
    /// @dev Left as `msg.sender` the continuation would be MINTED TO THE EXECUTOR, debt and title alike.
    /// @dev A single happy-path test passes with that bug live, which is why this is its own case.
    function test_A1_AutoRefinance_TitlesTheBorrower_NeverTheExecutor() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);

        uint256 newId = _exec(mallory, oldId);

        assertEq(read.loan(newId).borrower, borrower, "the continuation is the BORROWER's debt");
        assertEq(title.ownerOf(newId), borrower, "and the title mints to the borrower, not to whoever cranked");
        assertEq(read.loan(oldId).borrower, borrower, "the retired loan's holder is unchanged too");
    }

    /// @notice A1b: `L.borrower` is the CURRENT title holder, so in an open market a sold position continues for its buyer.
    /// @dev Pins the substitution against a third address, one that never called anything.
    function test_A1b_AutoRefinance_FollowsTheTitle_NotTheOpener() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        vm.prank(borrower);
        title.transferFrom(borrower, carol, oldId);
        assertEq(read.loan(oldId).borrower, carol, "fixture: the position was sold");
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);

        uint256 newId = _exec(mallory, oldId);

        assertEq(read.loan(newId).borrower, carol, "the continuation follows the title, never the opener");
        assertEq(title.ownerOf(newId), carol, "in both ledgers");
    }

    /// @notice A2, substitution 2: the executor receives NOTHING at all from a whole run.
    /// @dev Exact, now that section 6.7 moved the tip to periphery: `msg.sender` is correct in ZERO places.
    function test_A2_AutoRefinance_TheExecutorReceivesNothing() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        usdc.mint(mallory, 1e6);
        uint256 execQuote = usdc.balanceOf(mallory);
        uint256 execColl = vault.balanceOf(mallory);
        uint256 borrowerQuote = usdc.balanceOf(borrower);

        uint256 newId = _exec(mallory, oldId);

        assertEq(usdc.balanceOf(mallory), execQuote, "the executor's quote balance is bit-identical: no tip at all");
        assertEq(vault.balanceOf(mallory), execColl, "and no collateral reaches it either");
        assertEq(title.balanceOf(mallory), 0, "nor any title");
        assertGe(usdc.balanceOf(borrower), borrowerQuote, "whatever surplus there is lands on the borrower");
        assertEq(pm.collateralOf(newId), COLL, "and the whole position followed the borrower's new loan");
    }

    /// @notice A2b, substitution 2 where the surplus is REAL: the manual path pays the borrower out.
    /// @notice GREEN today and stays green -- it is the regression guard on the shared body's payee.
    /// @dev The auto path's own surplus is provably dust (the derivation ceils), so the amount is pinned here.
    function test_A2b_ManualRefinance_PaysTheWholeSurplusToTheBorrower() public {
        uint256 oldId = _open(P, TEN7);
        _warpTo(t0 + 3 days);
        assertEq(read.earlyExitRefund(oldId), 80e6, "fixture: four sevenths of the 140 escrow is still unearned");
        uint256 before = usdc.balanceOf(borrower);

        vm.prank(borrower);
        fin.refinance(oldId, 71_000e6, TEN7, OFF);

        /// @dev The borrower's own refinance PAYS the net out in the call; a policy door or the fold would credit it
        assertEq(usdc.balanceOf(borrower) - before, 767_600_000, "P_new less its fee, plus the refund, less the old debt, from the refinance itself");
        (uint256 owedUnits, uint256 owedQuote) = ace.owedOf(oldId, borrower);
        assertEq(owedUnits + owedQuote, 0, "and nothing is left booked for a later claim");
        assertEq(usdc.balanceOf(address(0xBAD)), 0, "and nothing was routed anywhere else");
    }

    // ============ A3-A7. the verb, the policy, and the setter's gates ============

    /// @notice A3: an armed loan is continued by a stranger inside the window, on the borrower's terms.
    function test_A3_AutoRefinance_HappyPath_ContinuesOnThePolicysOwnTerms() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 want = _expected(oldId, TEN7);

        uint256 newId = _exec(mallory, oldId);

        assertGt(newId, oldId, "a continuation allocates a NEW loan id, never reuses one");
        assertTrue(read.loan(oldId).closedAt != 0, "the old loan is retired");
        assertEq(read.debtOf(oldId), 0, "and its debt is retired in FULL, so its lenders take cash at par");
        assertFalse(read.loan(newId).closedAt != 0, "the continuation is live");
        assertEq(read.debtOf(newId), want, "at the DERIVED principal");
        assertEq(read.loan(newId).tenor, TEN7, "on the armed tenor");
        assertEq(read.loan(newId).expiry, _now() + TEN7, "with a fresh term from now");
        assertEq(read.loan(newId).market, id, "SAME-MARKET ONLY: the auto path never reaches 4.1's arbitrage surface");
        assertGt(read.fundingFloor(id, newId), 0, "and a funding floor of its own");
    }

    /// @notice A4: an unarmed loan has no policy, so the permissionless verb has nothing to execute.
    function test_A4_AutoRefinance_RefusesAnUnarmedLoan() public {
        uint256 oldId = _open(P, TEN7);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 debt0 = read.debtOf(oldId);

        (bool ok, bytes memory ret) = _rawExec(mallory, oldId);
        _refuses(ok, ret, AutoPolicyDisarmed.selector, "no policy is not an invitation");

        assertFalse(read.loan(oldId).closedAt != 0, "and the loan is exactly where it was");
        assertEq(read.debtOf(oldId), debt0, "with its debt intact");
    }

    /// @notice A4b: `tenor == 0` IS disarmed -- there is no separate `armed` flag to disagree with it.
    function test_A4b_AutoRefinance_ADisarmedPolicyIsGone() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _arm(borrower, oldId, 0, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);

        (bool ok, bytes memory ret) = _rawExec(mallory, oldId);
        _refuses(ok, ret, AutoPolicyDisarmed.selector, "zero disarms, and one field cannot disagree with itself");
        assertFalse(read.loan(oldId).closedAt != 0, "the loan is untouched");
    }

    /// @notice A5: arming is borrower-only, and explicitly NOT the credit-operator path.
    /// @dev An operator may `open` in the borrower's name; arming a continuation is a different decision.
    function test_A5_SetAutoRefinance_IsBorrowerOnly_AndNotTheCreditOperator() public {
        uint256 oldId = _open(P, TEN7);

        (bool ok, bytes memory ret) = _rawArm(mallory, oldId, TEN7, 0);
        _refuses(ok, ret, NotBorrower.selector, "a stranger may not arm someone else's position");

        vm.prank(borrower);
        ace.setCreditOperator(mallory, true);
        (ok, ret) = _rawArm(mallory, oldId, TEN7, 0);
        _refuses(ok, ret, NotBorrower.selector, "and nor may a credit operator");
    }

    /// @notice A6: a settled position cannot be armed; a closed loan takes no borrower policy at all.
    function test_A6_SetAutoRefinance_RefusesAClosedLoan() public {
        uint256 oldId = _open(P, TEN7);
        vm.prank(borrower);
        ace.repay(oldId, P);
        assertTrue(read.loan(oldId).closedAt != 0, "fixture: the loan repaid clean");

        (bool ok, bytes memory ret) = _rawArm(borrower, oldId, TEN7, 0);
        _refuses(ok, ret, LoanClosed.selector, "a closed loan has no term to continue");
    }

    /// @notice A7: the tenor is validated at ARMING time, where the borrower is present to see it fail.
    /// @dev Validating only at execution would leave an armed policy that can never fire, silently.
    function test_A7_SetAutoRefinance_ValidatesTheTenorAtArmingTime() public {
        uint256 oldId = _open(P, TEN7);

        (bool ok, bytes memory ret) = _rawArm(borrower, oldId, 60 days, 0);
        _refuses(ok, ret, TenorOutOfRange.selector, "a tenor over the market's ceiling is refused at arming");

        (ok, ret) = _rawArm(borrower, oldId, 1 days, 0);
        _refuses(ok, ret, TenorOutOfRange.selector, "and so is one under its floor");
    }

    /// @notice A7b: the buffer is validated at ARMING time too, and refused only where no live loan can ever meet it.
    /// @dev 10000 bps asks for a zero trigger, and every live loan's trigger rounds UP to at least one.
    /// @dev Stored, it reads ARMED while every continuation refuses, and the fold SETTLES a loan the borrower expects to roll.
    /// @dev A valid policy differing in EVERY field is armed first, so a refused call that wrote anything would show.
    function test_A7b_SetAutoRefinance_RefusesAnUnsatisfiableBufferAtArmingTime() public {
        uint256 oldId = _open(P, TEN7);
        (bool ok, bytes memory ret) = _rawArmFee(borrower, oldId, TEN30, 500, 25);
        assertTrue(ok, "fixture: the prior policy arms");

        (ok, ret) = _rawArm(borrower, oldId, TEN7, 10_000);
        _refuses(ok, ret, BufferOutOfRange.selector, "a buffer of the whole floor is unsatisfiable and refused at arming");
        (ok, ret) = _rawArm(borrower, oldId, TEN7, type(uint16).max);
        _refuses(ok, ret, BufferOutOfRange.selector, "and so is every value above it");
        (uint64 t, uint16 buf, uint16 fee) = read.autoPolicyOf(oldId);
        assertEq(t, TEN30, "a refused re-arm overwrote the prior tenor");
        assertEq(buf, 500, "a refused re-arm overwrote the prior buffer");
        assertEq(fee, 25, "a refused re-arm overwrote the prior ceiling");

        _arm(borrower, oldId, TEN7, 9_999);
        (t, buf, fee) = read.autoPolicyOf(oldId);
        assertEq(t, TEN7, "one bps under the whole floor is satisfiable in principle and must arm");
        assertEq(buf, 9_999, "the accepted buffer was not stored as given");
        assertEq(fee, 0, "and the accepted ceiling was not stored as given");
    }

    /// @notice A7c: the buffer check sits INSIDE the disarm guard, beside the tenor and routing checks.
    /// @dev A zero tenor disarms outright, so neither a stale buffer nor a stale ceiling beside it refuses anything.
    /// @dev A disarm stores both stale fields AS GIVEN; they are inert because every hub reader keys on the zero tenor first.
    function test_A7c_SetAutoRefinance_DisarmIgnoresAStaleBuffer() public {
        uint256 oldId = _open(P, TEN7);
        (bool ok,) = _rawArmFee(borrower, oldId, TEN7, 500, 25);
        assertTrue(ok, "fixture: a routed policy arms");
        (ok,) = _rawArmFee(borrower, oldId, 0, 10_000, 77);
        assertTrue(ok, "a disarm carrying an out-of-range buffer and a nonzero ceiling was refused");

        (uint64 t, uint16 buf, uint16 fee) = read.autoPolicyOf(oldId);
        assertEq(t, 0, "a disarm carrying an out-of-range buffer did not disarm");
        assertEq(buf, 10_000, "the disarm stores the buffer it was given");
        assertEq(fee, 77, "and the ceiling it was given");
        (bool live, bytes4 reason,) = ace.tryContinue(oldId);
        assertFalse(live, "a disarmed loan cannot continue");
        assertEq(reason, AutoPolicyDisarmed.selector, "and no leg past the zero tenor ever reads the stale fields");
    }

    /// @notice A7d: the rail refuses only the provably impossible; a buffer just under the whole floor arms AND rolls.
    /// @dev The gap is `(floor - trigger) / floor`, so small debt against large collateral meets it with no special case.
    /// @dev A minimum-debt loan on ten times the baseline collateral puts the trigger near 1.4e-5 of the floor: ~9999.86 bps.
    function test_A7d_AHighButSatisfiableBuffer_ArmsAndTheFoldRollsIt() public {
        uint256 oldId = _openOnWith(id, 10 * COLL, 10e6, TEN7);
        _arm(borrower, oldId, TEN7, 9_999);
        assertGe(_gapBps(oldId), 9_999, "fixture: the loan's own gap already meets the armed buffer");
        _warpTo(uint256(read.loan(oldId).expiry) + 1);
        uint256 n = read.loanCount();

        vm.prank(carol);
        ace.forceClose(oldId);

        assertEq(read.loanCount(), n + 1, "the fold ROLLED: a buffer under the whole floor is not an impossible one");
        assertEq(read.debtOf(oldId), 0, "the old debt retired in full, which a settlement does not do");
        uint256 newId = n + 1;
        assertFalse(read.loan(newId).closedAt != 0, "the successor is live");
        assertGe(_gapBps(newId), 9_999, "and its own gap clears the buffer the borrower armed");
        (uint64 t, uint16 buf,) = read.autoPolicyOf(newId);
        assertEq(t, TEN7, "the policy carried forward");
        assertEq(buf, 9_999, "with the high buffer intact");
    }

    /// @notice A7e: which refusal an out-of-range buffer draws when another arming rail could also object.
    /// @dev `RoutingNeedsBuffer` fires on a ZERO buffer and this rail on 10000 or more, so the two conditions never overlap.
    /// @dev A routed consent beside an out-of-range buffer therefore answers `BufferOutOfRange`, never the routing refusal.
    /// @dev The buffer rail runs BEFORE the tenor legs, so an out-of-range tenor beside it is not the reported reason.
    function test_A7e_BufferOutOfRange_PrecedenceAgainstTheOtherArmingRails() public {
        uint256 oldId = _open(P, TEN7);

        (bool ok, bytes memory ret) = _rawArmFee(borrower, oldId, TEN7, 10_000, 50);
        _refuses(ok, ret, BufferOutOfRange.selector, "a routed consent with an impossible buffer is refused for the buffer");
        (ok, ret) = _rawArmFee(borrower, oldId, TEN7, 0, 50);
        _refuses(ok, ret, RoutingNeedsBuffer.selector, "control: the routing rail still owns the zero buffer");
        (ok, ret) = _rawArm(borrower, oldId, 60 days, 10_000);
        _refuses(ok, ret, BufferOutOfRange.selector, "the buffer rail answers before the tenor legs");
        (ok, ret) = _rawArm(borrower, oldId, 60 days, 500);
        _refuses(ok, ret, TenorOutOfRange.selector, "control: that tenor alone IS out of range, so the precedence is real");
    }

    /// @dev The loan's floor-to-trigger gap in whole bps, floored: `>= b` here is exactly admission's `>= b * 1e14` in wad.
    function _gapBps(uint256 loanId) internal view returns (uint256) {
        uint256 floorPrice = read.fundingFloor(id, loanId);
        uint256 trig = read.triggerPrice(loanId);
        if (floorPrice == 0 || trig > floorPrice) return 0;
        return ((floorPrice - trig) * 10000) / floorPrice;
    }

    /// @notice A7f: the rail's premise -- even the smallest trigger a live loan can hold leaves the whole floor unmet.
    /// @dev An exact trigger under one atom rounds UP to one, so the gap tops out a hair under 10000 bps and 9999 still clears.
    /// @dev The 10000 policy is written PAST the rail at `LoanBook` index 6: the one state the rail exists to forbid.
    /// @dev A round-down trigger would read zero here, meet the whole floor, and make the rail refuse a meetable buffer.
    function test_A7f_TheWholeFloorIsUnmeetable_EvenAtATriggerOfOneAtom() public {
        uint256 loanId = _openOnWith(id, 1e37, 10e6, TEN7);
        assertLe(read.triggerPrice(loanId), 1, "fixture: the exact trigger sits under one atom");
        _arm(borrower, loanId, TEN7, 9_999);
        _warpTo(uint256(read.loan(loanId).expiry) - WINDOW);
        (bool live, bytes4 reason,) = ace.tryContinue(loanId);
        assertTrue(live, "control: the highest buffer the rail admits is met by this loan");

        bytes32 slot = keccak256(abi.encode(loanId, uint256(Storage.BOOK) + 6));
        vm.store(address(ace), slot, bytes32(uint256(TEN7) | (uint256(10_000) << 64)));
        (uint64 t, uint16 buf,) = read.autoPolicyOf(loanId);
        assertEq(t, TEN7, "fixture: the forbidden policy reads ARMED");
        assertEq(buf, 10_000, "fixture: at the whole floor");

        (live, reason,) = ace.tryContinue(loanId);
        assertFalse(live, "a trigger of one atom still misses the whole floor");
        assertEq(reason, BufferBelowMin.selector, "and it misses on the buffer, so the rail refuses exactly the unmeetable range");

        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();
        vm.prank(carol);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), n, "so the fold SETTLES a policy that reads armed: the harm the rail prevents");
        assertTrue(read.loan(loanId).closedAt != 0, "the loan ended at expiry rather than rolling");
    }

    /// @notice A7g: the carry is the ONE other writer of a policy, and it never arms a disarm's stale out-of-range fields.
    /// @dev It copies an ARMED buffer verbatim, so the rail holds by induction; a disarm's stale fields must stop at the zero tenor.
    /// @dev Keyed on anything but the tenor, the clamp lifts zero to minTenor and arms a 10000 buffer the rail never saw.
    function test_A7g_Carry_NeverArmsADisarmsStaleOutOfRangeBuffer() public {
        uint256 oldId = _open(P, TEN7);
        (bool ok,) = _rawArmFee(borrower, oldId, TEN7, 500, 25);
        assertTrue(ok, "fixture: a routed policy arms");
        (ok,) = _rawArmFee(borrower, oldId, 0, 10_000, 77);
        assertTrue(ok, "fixture: the disarm stores its stale out-of-range fields");
        _warpTo(t0 + 3 days);

        vm.recordLogs();
        uint256 newId = _refiComposed(borrower, oldId, 71_000e6, TEN7);

        assertFalse(_sawAutoPolicySet(vm.getRecordedLogs(), newId), "the carry announced a policy for a disarmed loan");
        (uint64 t, uint16 buf, uint16 fee) = read.autoPolicyOf(newId);
        assertEq(t, 0, "the carry ARMED the successor of a disarmed loan");
        assertEq(buf, 0, "and the stale out-of-range buffer rode across");
        assertEq(fee, 0, "and the stale ceiling rode across");
        _warpTo(uint256(read.loan(newId).expiry) - WINDOW);
        (bool live, bytes4 reason,) = ace.tryContinue(newId);
        assertFalse(live, "the successor cannot continue");
        assertEq(reason, AutoPolicyDisarmed.selector, "because it is disarmed, not because a stale buffer is unmeetable");
    }

    /// @notice A7h: who may arm, and whether the loan is live, answer BEFORE the buffer rail.
    /// @dev A stranger or a closed loan is refused for that, whatever buffer rides with the call.
    function test_A7h_BufferOutOfRange_AnswersAfterTheAuthAndLivenessGuards() public {
        uint256 oldId = _open(P, TEN7);
        (bool ok, bytes memory ret) = _rawArm(mallory, oldId, TEN7, 10_000);
        _refuses(ok, ret, NotBorrower.selector, "a stranger arming an out-of-range buffer is refused as a stranger");

        vm.prank(borrower);
        ace.repay(oldId, P);
        assertTrue(read.loan(oldId).closedAt != 0, "fixture: the loan repaid clean");
        (ok, ret) = _rawArm(borrower, oldId, TEN7, 10_000);
        _refuses(ok, ret, LoanClosed.selector, "and a closed loan is refused as closed");
    }

    /// @dev The hub's arming notice, redeclared so a row can `expectEmit` it field for field.
    event AutoPolicySet(uint256 indexed id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps);

    /// @notice A7i: across the whole uint16 domain, arming refuses EXACTLY the buffers at or above the whole floor.
    /// @dev The oracle is the two arming rails as specified: 10000 and up is out of range, and a routed zero needs a buffer.
    /// @dev An admitted arm stores AND logs every field as given; a refused one leaves the prior policy whole.
    /// @dev A disarm carrying the same fields is always admitted, so the rail never reaches a zero tenor.
    function testFuzz_A7i_ArmingRefusesExactlyTheUnmeetableBuffers(uint16 buf, uint16 fee) public {
        uint256 oldId = _open(P, TEN7);
        (bool ok, bytes memory ret) = _rawArmFee(borrower, oldId, TEN30, 500, 25);
        assertTrue(ok, "fixture: the prior policy arms");

        bytes4 want = buf >= 10_000 ? BufferOutOfRange.selector : (fee != 0 && buf == 0 ? RoutingNeedsBuffer.selector : bytes4(0));
        if (want == bytes4(0)) {
            vm.expectEmit(true, false, false, true, address(ace));
            emit AutoPolicySet(oldId, TEN7, buf, fee);
        }
        (ok, ret) = _rawArmFee(borrower, oldId, TEN7, buf, fee);
        (uint64 t, uint16 b, uint16 f) = read.autoPolicyOf(oldId);
        if (want == bytes4(0)) {
            if (!ok) _bubble(ret, "a meetable buffer was refused at arming"); // surfaces a refusal or a log mismatch by name
            assertEq(t, TEN7, "the admitted tenor was not stored as given");
            assertEq(b, buf, "the admitted buffer was not stored as given");
            assertEq(f, fee, "the admitted ceiling was not stored as given");
        } else {
            _refuses(ok, ret, want, "the refusal is not the one the two rails predict");
            assertEq(t, TEN30, "a refused arm overwrote the prior tenor");
            assertEq(b, 500, "a refused arm overwrote the prior buffer");
            assertEq(f, 25, "a refused arm overwrote the prior ceiling");
        }

        (ok,) = _rawArmFee(borrower, oldId, 0, buf, fee);
        assertTrue(ok, "a disarm was refused for a field it never acts on");
        (t,,) = read.autoPolicyOf(oldId);
        assertEq(t, 0, "and it disarmed");
    }

    // ============ A8-A12. the derived principal ============

    /// @notice A8: the principal is DERIVED from the live debt, exactly, with no room for discretion.
    function test_A8_AutoRefinance_DerivesThePrincipal_WithNoExecutorDiscretion() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 debtOld = read.debtOf(oldId);
        uint256 refundOld = read.earlyExitRefund(oldId);
        uint256 want = _derivedPrincipal(debtOld, refundOld, TEN7);

        uint256 newId = _exec(mallory, oldId);

        assertEq(read.debtOf(newId), want, "the principal is section 6.4's formula, to the wei");
        uint256 credit = want - _fee(want, TEN7) + refundOld;
        assertGe(credit, debtOld, "SELF-FUNDING: the draw covers the whole old debt on its own");
        assertLe(credit - debtOld, 2, "and no more than the ceils demand, so nobody sizes a payout for themselves");
    }

    /// @notice A8b: self-funding must hold TO THE WEI at every debt, which one naive ceil does not give.
    /// @dev `P = ceil(A*D/(D-N))` then `fee = ceil(P*N/D)` can land one wei SHORT: two ceils fight.
    /// @dev A short derivation would try to pull the difference from a borrower who granted nothing.
    function testFuzz_A8b_AutoRefinance_IsSelfFundingToTheWei(uint256 debtSeed) public {
        uint256 principal = bound(debtSeed, 10_000e6, 70_000e6);
        uint256 oldId = _open(principal, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 debtOld = read.debtOf(oldId);
        uint256 refundOld = read.earlyExitRefund(oldId);
        uint256 before = usdc.balanceOf(borrower);

        uint256 pNew = read.debtOf(_exec(mallory, oldId));

        assertGe(pNew - _fee(pNew, TEN7) + refundOld, debtOld, "no continuation may be one wei short of the old debt");
        assertGe(usdc.balanceOf(borrower), before, "and the borrower is never charged for the difference");
    }

    /// @notice A9: a borrower who paid down is continued at the REDUCED debt, not at their original size.
    /// @dev ACE has no accrual, so a principal stored at arming time only ever over-covers as debt falls.
    /// @dev Stored, it would silently RE-LEVER a deleveraging borrower at every automatic continuation.
    function test_A9_AutoRefinance_DoesNotReLeverADeleveragingBorrower() public {
        uint256 oldId = _open(P, TEN30);
        _arm(borrower, oldId, TEN7, 0);
        vm.prank(borrower);
        ace.repay(oldId, 40_000e6);
        assertEq(read.debtOf(oldId), 30_000e6, "fixture: the borrower paid down to 30k of the 70k");
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 want = _expected(oldId, TEN7);

        uint256 pNew = read.debtOf(_exec(mallory, oldId));

        assertEq(pNew, want, "the continuation is sized off the debt that is actually there");
        assertLt(pNew, 31_000e6, "so a borrower who deleveraged stays deleveraged");
        assertLt(pNew, P, "a stored principal would have put all 70k back on them, automatically");
    }

    /// @notice A10: genesis refuses a market whose LONGEST rung breaks the fee-share ceiling.
    /// @notice The rail is the ALL-IN share bound: `4 * baseBps * maxTenor * 11000 <= 1e8 * minTenor`.
    /// @dev Moved here from the auto-refinance setter, which used to catch it one boundary later.
    /// @dev Was `test_A10_SetAutoRefinance_RefusesATenorWhoseFeeEatsTheWholeDraw`, on a market at `D == N`.
    /// @dev `AutoTenorUnfundable` survives in both readers as unreachable defence; see their NatSpec.
    function test_A10_Genesis_RefusesAMarketWhoseLongestRungFeeEatsTheWholeDraw() public {
        MarketParams memory p = _params();
        p.baseBps = 500;
        p.minTenor = 1 days;
        p.maxTenor = 5 days; // 4 * 500 * 5d * 11000 == 9.504e12, over the 8.64e12 bound: the FIRST refused rung
        vm.expectRevert("fee bps too high");
        ace.createMarket(p);

        // one rung inside the bound is admitted, so the rail is a boundary and not a ban
        p.maxTenor = 4 days; // 4 * 500 * 4d * 11000 == 7.6032e12, under it
        assertTrue(ace.createMarket(p) != bytes32(0), "one rung inside the share still builds a market");
    }

    /// @notice A11: a loan its borrower repaid under `minDebt` continues AT `minDebt`, and is not refused.
    /// @notice `minDebt` is the smallest loan the market issues, so it is the only legal continuation.
    /// @dev Only a partial repay (anyone's) reaches here: open refuses under the floor, and a keeper's crank stops at it.
    /// @dev Refusing would force-close a borrower for a state `repay` let them reach.
    function test_A11_AutoRefinance_ContinuesAtMinDebtWhenARepayLeftItBelow() public {
        (bytes32 mid, uint256 loanId) = _dustFloorLoan(REACHABLE_FLOOR);
        _warpTo(uint256(read.loan(loanId).expiry) - WINDOW);
        _repayTo(loanId, 30_000e6);
        uint256 debt = read.debtOf(loanId);
        assertGt(debt, 0, "fixture: the repay left debt without closing the loan");
        assertLt(debt, REACHABLE_FLOOR, "fixture: and left it UNDER that market's own dust floor");
        _arm(borrower, loanId, TEN7, 0);
        uint256 before = usdc.balanceOf(borrower);

        uint256 newId = _exec(mallory, loanId);

        assertEq(read.debtOf(newId), REACHABLE_FLOOR, "the continuation is drawn AT the floor, exactly");
        assertEq(read.loan(newId).market, mid, "in its own market");
        assertTrue(read.loan(loanId).closedAt != 0, "the melted loan retired rather than waiting to be force-closed");
        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);
        assertGt(usdc.balanceOf(borrower), before, "and the difference reaches the BORROWER");
    }

    /// @notice A11c: ABOVE the floor the DERIVATION still governs -- the floor never raises a principal.
    /// @dev The no-re-lever regression guard for the floor: it must bind strictly under `minDebt`.
    function test_A11c_AutoRefinance_TheFloorNeverRaisesAPrincipalAboveIt() public {
        uint256 oldId = _open(P, TEN30);
        _arm(borrower, oldId, TEN7, 0);
        vm.prank(borrower);
        ace.repay(oldId, 40_000e6);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 want = _expected(oldId, TEN7);
        assertGt(want, ace.idToMarketParams(id).minDebt, "fixture: the derivation sits well clear of the floor");

        uint256 pNew = read.debtOf(_exec(mallory, oldId));

        assertEq(pNew, want, "the derivation governs unraised, exactly as before the floor existed");
        assertLt(pNew, P, "so a borrower who deleveraged still stays deleveraged");
    }

    /// @notice A11d: the floored surplus reaches the BORROWER, never the executor, and to the wei.
    /// @dev The floor makes that surplus REAL rather than dust, so this is where substitution 2 can bite.
    function test_A11d_AutoRefinance_TheFlooredSurplusReachesTheBorrower_NotTheExecutor() public {
        (, uint256 loanId) = _dustFloorLoan(REACHABLE_FLOOR);
        _warpTo(uint256(read.loan(loanId).expiry) - WINDOW);
        _repayTo(loanId, 30_000e6); // under the floor by the borrower's own hand
        _arm(borrower, loanId, TEN7, 0);
        uint256 debt = read.debtOf(loanId);
        uint256 refundOld = read.earlyExitRefund(loanId);
        usdc.mint(mallory, 1e6);
        uint256 execBefore = usdc.balanceOf(mallory);
        uint256 borrowerBefore = usdc.balanceOf(borrower);

        _exec(mallory, loanId);

        assertEq(usdc.balanceOf(mallory), execBefore, "the executor's balance is bit-identical: no tip, no surplus");
        /// @dev And the credit names the BORROWER, so the executor cannot pull it either
        (, uint256 owedExec) = ace.owedOf(loanId, mallory);
        assertEq(owedExec, 0, "nothing is credited to the executor");
        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);
        assertEq(
            usdc.balanceOf(borrower) - borrowerBefore,
            REACHABLE_FLOOR - _fee(REACHABLE_FLOOR, TEN7) + refundOld - debt,
            "and the borrower takes the floor less its fee, plus the refund, less the melted debt"
        );
    }

    /// @notice A11e: the floor does NOT override admissibility -- a position that cannot carry `minDebt`
    /// @notice is refused, and the refusal moves nothing.
    /// @dev The borrower's own repay and withdrawal reach the pairing: debt under the floor, and a lot too small to carry the floor.
    function test_A11e_AutoRefinance_TheFloorDoesNotOverrideAdmissibility() public {
        (bytes32 mid, uint256 loanId) = _dustFloorLoan(UNREACHABLE_FLOOR);
        _warpTo(uint256(read.loan(loanId).expiry) - WINDOW);
        _repayTo(loanId, 30_000e6);
        vm.prank(borrower);
        ace.withdrawCollateral(loanId, 40_000e18, borrower); // 60k units carry 30k of debt and not a 65k floor
        uint256 debt = read.debtOf(loanId);
        assertLt(debt, UNREACHABLE_FLOOR, "fixture: the repay left it under a floor its collateral cannot carry");
        _arm(borrower, loanId, TEN7, 0);
        Snap memory before = _snapOn(mid, loanId);

        (bool ok, bytes memory ret) = _rawExec(mallory, loanId);
        _refuses(ok, ret, TriggerAboveFloor.selector, "solvency outranks the dust floor");

        _assertSnapEq(before, _snapOn(mid, loanId), "and a refused continuation leaves the loan whole");
    }

    /// @notice A12: `minBufferBps` earns its slot -- it is the only lever an ABSENT borrower has.
    /// @dev The admissibility gate alone admits a draw at ZERO buffer, re-arming distress on execution.
    function test_A12_AutoRefinance_MinBufferBpsIsTheAbsentBorrowersOnlyTerm() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 5000);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 debt0 = read.debtOf(oldId);

        (bool ok, bytes memory ret) = _rawExec(mallory, oldId);
        _refuses(ok, ret, BufferBelowMin.selector, "continue me, but NOT on any terms");
        assertFalse(read.loan(oldId).closedAt != 0, "so the loan is left exactly as it was");
        assertEq(read.debtOf(oldId), debt0, "with its debt intact");

        _arm(borrower, oldId, TEN7, 100);
        uint256 newId = _exec(mallory, oldId);
        assertFalse(read.loan(newId).closedAt != 0, "and the same draw clears a buffer the borrower will accept");
    }

    // ============ A13-A15. carry-forward ============

    /// @notice A13: the policy CARRIES FORWARD, so the second term fires as well as the first.
    /// @dev Without it the feature continues a loan once and then stops, silently, into a force-close.
    function test_A13_AutoRefinance_ThePolicyCarriesForward_SoTheSecondTermFiresToo() public {
        uint256 first = _open(P, TEN7);
        _arm(borrower, first, TEN7, 0);
        _warpTo(uint256(read.loan(first).expiry) - WINDOW);
        uint256 second = _exec(mallory, first);

        _warpTo(uint256(read.loan(second).expiry) - WINDOW);
        uint256 third = _exec(mallory, second);

        assertGt(third, second, "the SECOND execution fired: the policy crossed the continuation");
        assertTrue(read.loan(second).closedAt != 0, "the middle loan retired in its turn");
        assertEq(read.loan(third).borrower, borrower, "still the borrower's position");
        (uint64 tenor,) = _policy(third);
        assertEq(tenor, TEN7, "and the third loan is armed too, so the chain does not stop here");
    }

    /// @notice A14: a MANUAL refinance must not silently disarm the borrower.
    /// @dev The carry lives in the SHARED body precisely so this path cannot forget it.
    function test_A14_ManualRefinance_DoesNotSilentlyDisarmTheBorrower() public {
        uint256 oldId = _open(P, TEN30);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(t0 + 15 days);

        // a 10% take shrinks the inbound refund, so P alone no longer clears the old debt after fee
        vm.prank(borrower);
        uint256 newId = fin.refinance(oldId, P + 100e6, TEN7, OFF);

        (uint64 tenor, uint16 buf) = _policy(newId);
        assertEq(tenor, TEN7, "a manual continuation carries the policy across");
        assertEq(buf, 0, "field for field");
        _warpTo(uint256(read.loan(newId).expiry) - WINDOW);
        assertGt(_exec(mallory, newId), newId, "and the auto path still fires on the manual continuation");
    }

    /// @notice A15: a cross-market migration carries the policy CLAMPED, and says so in a log.
    /// @dev In range the clamp is a no-op, so this is the control C1/C2 lean on; the emit stays visible.
    function test_A15_Migration_CarriesThePolicyClamped_AndSaysSo() public {
        bytes32 dst = _twinMarket();
        uint256 oldId = _open(P, TEN30);
        _arm(borrower, oldId, TEN7, 250);
        _warpTo(t0 + 15 days);

        vm.recordLogs();
        uint256 newId = _migrate(borrower, MigrateArgs(oldId, dst, P, TEN7, OFF, 0, address(0)));

        (uint64 tenor, uint16 buf) = _policy(newId);
        assertEq(tenor, TEN7, "the policy follows the loan across markets");
        assertEq(buf, 250, "with the borrower's own terms intact");
        assertTrue(_sawAutoPolicySet(vm.getRecordedLogs(), newId), "and the blind carry is EMITTED, not silent");
    }

    // ============ C1-C6. the carry clamp (D0 ruling 2026-08-17) ============

    /// @notice C1: a carried tenor over the destination's ceiling is CLAMPED to it, storage and log alike.
    /// @dev Storage must equal what will execute; the emit must report the EFFECTIVE value, not the wish.
    function test_C1_Carry_ClampsDownToTheDestinationsMaxTenor() public {
        bytes32 dst = _gridMarket(TEN7, 14 days, 7 days);
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN30, 0);

        vm.recordLogs();
        uint256 newId = _migrate(borrower, MigrateArgs(oldId, dst, P, TEN7, OFF, 0, address(0)));

        (uint64 tenor,) = _policy(newId);
        assertEq(tenor, 14 days, "a 30d policy lands on a 14d-ceiling market clamped to 14d");
        assertEq(_autoPolicyTenor(vm.getRecordedLogs(), newId), 14 days, "and the LOG carries 14d too, not 30d");
    }

    /// @notice C2: the clamp works UP as well -- a tenor under the destination's floor rises to it.
    /// @dev The up direction is separately deletable, so it is separately pinned.
    function test_C2_Carry_ClampsUpToTheDestinationsMinTenor() public {
        bytes32 dst = _gridMarket(14 days, 28 days, 14 days);
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);

        uint256 newId = _migrate(borrower, MigrateArgs(oldId, dst, P, 14 days, OFF, 0, address(0)));

        (uint64 tenor,) = _policy(newId);
        assertEq(tenor, 14 days, "a 7d policy on a 14d-floor market is clamped UP to 14d");
    }

    /// @notice C3: control -- an in-range tenor is left alone, so the clamp is a boundary and not a rewrite.
    /// @dev Without this a clamp that always wrote minTenor would pass C2.
    function test_C3_Carry_LeavesAnInRangeTenorAlone() public {
        bytes32 dst = _twinMarket();
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);

        uint256 newId = _migrate(borrower, MigrateArgs(oldId, dst, P, TEN7, OFF, 0, address(0)));

        (uint64 tenor,) = _policy(newId);
        assertEq(tenor, TEN7, "same grid, same tenor: the clamp is a no-op in range");
    }

    /// @notice C4: the clamped policy EXECUTES -- neither TenorOutOfRange nor AutoTenorUnfundable fires.
    /// @dev The positive form of "both rails become unreachable".
    function test_C4_ClampedPolicy_IsExecutable_NeitherRailFires() public {
        bytes32 dst = _gridMarket(TEN7, 14 days, 7 days);
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN30, 0);
        uint256 newId = _migrate(borrower, MigrateArgs(oldId, dst, P, TEN7, OFF, 0, address(0)));
        _warpTo(uint256(read.loan(newId).expiry) - WINDOW);

        uint256 contId = _exec(mallory, newId);

        assertEq(read.loan(contId).tenor, 14 days, "the continuation runs on the CLAMPED tenor");
        assertFalse(read.loan(contId).closedAt != 0, "and is live");
    }

    /// @notice C5: the clamp is TOTAL -- no genesis-admissible destination grid can strand a carried policy.
    /// @dev The test that would catch a clamp applied against the SOURCE grid instead of the destination's.
    function testFuzz_C5_TheClampIsTotal_NoDestinationGridRefusesThePolicy(uint64 armSeed, uint64 minSeed, uint64 spanSeed, bool twoRungs) public {
        uint64 armTenor = uint64(bound(uint256(armSeed), TEN7, TEN30));
        uint64 minT = uint64(bound(uint256(minSeed), 1 days, 30 days));
        uint64 maxT = minT;
        uint64 spacing = 0;
        if (twoRungs) {
            spacing = uint64(bound(uint256(spanSeed), 1 hours, 30 days));
            maxT = minT + spacing;
        }
        bytes32 dst = _gridMarket(minT, maxT, spacing);
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, armTenor, 0);
        uint256 newId = _migrate(borrower, MigrateArgs(oldId, dst, P, minT, OFF, 0, address(0)));
        _warpTo(uint256(read.loan(newId).expiry) - MarketInit.autoRefinanceWindow(minT));

        (bool ok, bytes memory ret) = _rawExec(mallory, newId);

        if (!ok) {
            assertTrue(bytes4(ret) != TenorOutOfRange.selector, "a clamped policy is never off the grid");
            assertTrue(bytes4(ret) != AutoTenorUnfundable.selector, "and never fee-unfundable");
        }
    }

    /// @notice C6: a chain A -> B -> C keeps the CLAMPED value; the original intent does not resurrect.
    /// @dev Pins the ACCEPTED COST verbatim so a later reader does not "fix" it into a stored wish.
    function test_C6_ChainedCarry_KeepsTheClampedValue_AndSaysSoIsAccepted() public {
        bytes32 mktB = _gridMarket(TEN7, 14 days, 7 days);
        bytes32 mktC = _gridMarket(TEN7, TEN30, SPACING);
        uint256 a = _open(P, TEN7);
        _arm(borrower, a, TEN30, 0);

        uint256 b = _migrate(borrower, MigrateArgs(a, mktB, P, TEN7, OFF, 0, address(0)));
        uint256 c = _migrate(borrower, MigrateArgs(b, mktC, P, TEN7, OFF, 0, address(0)));

        (uint64 tenor,) = _policy(c);
        assertEq(tenor, 14 days, "the clamp is one-way: C could hold 30d, but the stored policy is 14d");
    }

    // ============ A16. the tip that is NOT here ============

    /// @notice A16: there is NO tip in the hub, and a whole run moves ZERO to `msg.sender`.
    /// @dev A deliberate negative test: it stops a tip being reintroduced inside the hub by a later edit.
    function test_A16_AutoRefinance_FourthArgIsAFeeCeiling_AndPaysTheExecutorNothing() public {
        uint256 oldId = _open(P, TEN7);
        /// @dev The ADVERSARIAL case: a nonzero fourth argument is exactly what a tip would have used.
        /// @dev The buffer must be nonzero with it -- venue consent without a risk distance is refused at arming.
        (bool armed,) = _rawArmFee(borrower, oldId, TEN7, 1, 100);
        assertTrue(armed, "a fee ceiling is a legal standing term");
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 execQuote = usdc.balanceOf(mallory);
        uint256 rev0 = read.protocolRevenue(id);

        _exec(mallory, oldId);

        assertEq(usdc.balanceOf(mallory), execQuote, "a whole run moves ZERO to msg.sender");
        assertGt(read.protocolRevenue(id), rev0, "the fee the churn does create goes to the market, never the caller");
    }

    // ============ A18. the timing gate, pinned from BOTH sides ============

    /// @notice A18: one second before the window opens the verb is shut, and nothing has moved.
    /// @dev The borrower keeps their own relief the whole time: `refinance` has no window at all.
    function test_A18_AutoRefinance_RefusedOneSecondBeforeTheWindowOpens() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW - 1);
        uint256 debt0 = read.debtOf(oldId);

        (bool ok, bytes memory ret) = _rawExec(mallory, oldId);
        _refuses(ok, ret, OutsideRefinanceWindow.selector, "one second outside the window is outside the window");
        assertFalse(read.loan(oldId).closedAt != 0, "the loan is untouched");
        assertEq(read.debtOf(oldId), debt0, "with its debt intact");

        uint256 manual = _refiComposed(borrower, oldId, P, TEN7);
        assertFalse(read.loan(manual).closedAt != 0, "while the borrower's OWN verb is never gated on the window");
    }

    /// @notice A18b: at exactly `expiry - AUTO_REFINANCE_WINDOW` the gate is open. The edge is INSIDE.
    function test_A18b_AutoRefinance_AdmittedExactlyAtTheWindowsEdge() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);

        uint256 newId = _exec(mallory, oldId);

        assertTrue(read.loan(oldId).closedAt != 0, "the gate is `>=`, so the edge itself admits");
        assertFalse(read.loan(newId).closedAt != 0, "and the continuation is live");
        assertEq(read.loan(newId).expiry, _now() + TEN7, "a whole fresh term, from here");
    }

    /// @notice A18c: churn is bounded to ONCE PER TENOR. This is the test the rejected formula fails.
    /// @dev `expiry - minTenor` reopens at `new_expiry - 7d == now`, so an attacker refinances every block.
    function test_A18c_AutoRefinance_ChurnIsBoundedToOncePerTenor() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 newId = _exec(mallory, oldId);

        (bool ok, bytes memory ret) = _rawExec(mallory, newId);
        _refuses(ok, ret, OutsideRefinanceWindow.selector, "the window reopens a whole tenor away, not in the next block");
        assertFalse(read.loan(newId).closedAt != 0, "so nobody churns an absent borrower block after block");

        _warpTo(uint256(read.loan(newId).expiry) - WINDOW - 1);
        (ok, ret) = _rawExec(mallory, newId);
        _refuses(ok, ret, OutsideRefinanceWindow.selector, "still shut one second before the next window");
    }

    /// @notice A18d: the churn incentive is STRUCTURAL -- a lender at a funded tick can fire it themselves.
    /// @dev Every origination credits part of its fee to the funding ticks, immediately, at zero tip.
    /// @dev So the gate does not depend on a tip parameter anyone might set to zero.
    function test_A18d_AutoRefinance_TheChurnIncentiveIsStructural() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 aliceQuote = usdc.balanceOf(alice);

        uint256 newId = _exec(alice, oldId);

        assertGt(newId, oldId, "a LENDER at a funded tick may call the verb: it is permissionless");
        assertGt(_classFeeOf(newId), 0, "and a fresh origination fee accrues to the new class at once");
        assertEq(usdc.balanceOf(alice), aliceQuote, "the lender funded none of it, so the incentive needs no tip");
    }

    // ============ A19-A22. the drain vector, staleness, the lens, the slot ============

    /// @notice A19: no standing approval is EVER needed, so the wallet-drain vector cannot be opened.
    /// @dev The verb has no pull leg at all now, so the vector is shut by construction rather than by a zero dial.
    /// @dev It once could have been funded from a standing ERC20 approval, at a moment of the CRANKER's choosing.
    function test_A19_AutoRefinance_NeedsNoStandingApproval() public {
        uint256 oldId = _open(P, TEN7);
        vm.prank(borrower);
        usdc.approve(address(ace), 0);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        assertEq(usdc.allowance(borrower, address(ace)), 0, "fixture: the borrower has granted the hub NOTHING");
        uint256 before = usdc.balanceOf(borrower);

        uint256 newId = _exec(mallory, oldId);

        assertEq(usdc.allowance(borrower, address(ace)), 0, "and still nothing afterwards");
        assertGe(usdc.balanceOf(borrower), before, "no wallet was conscripted: the verb has no pull leg to drain one");
        assertFalse(read.loan(newId).closedAt != 0, "yet the continuation went through: SELF-FUNDING ONLY");
    }

    /// @notice A20: a policy on a closed loan is inert, whether the loan was continued or repaid.
    function test_A20_AutoRefinance_AStalePolicyOnAClosedLoanIsInert() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 newId = _exec(mallory, oldId);

        (bool ok, bytes memory ret) = _rawExec(mallory, oldId);
        _refuses(ok, ret, LoanClosed.selector, "the old entry survives behind `closed` and is unreachable");

        vm.startPrank(borrower);
        usdc.approve(address(ace), type(uint256).max);
        ace.repay(newId, read.debtOf(newId));
        vm.stopPrank();

        (ok, ret) = _rawExec(mallory, newId);
        _refuses(ok, ret, LoanClosed.selector, "and a repaid position cannot be continued by a stale policy");
    }

    /// @notice A21: the lens exposes the policy, which is the WHOLE of the hub's incentive contribution.
    /// @dev A signature would be invisible to a keeper scanning expiries; a stored policy is readable.
    function test_A21_TheLensExposesThePolicy() public {
        uint256 oldId = _open(P, TEN7);
        (uint64 t1, uint16 b1) = _policy(oldId);
        assertEq(t1, 0, "an unarmed loan reads DISARMED rather than absent");
        assertEq(b1, 0, "with no terms attached");

        _arm(borrower, oldId, TEN7, 250);

        (uint64 t2, uint16 b2) = _policy(oldId);
        assertEq(t2, TEN7, "an armed policy is discoverable by anyone scanning expiries");
        assertEq(b2, 250, "terms and all");
    }

    /// @notice A22: the policy is an APPEND at `LoanBook` index 6, so no existing offset moved.
    /// @dev The 36-red-tests incident was an INSERTION; this pins that this one is not.
    /// @dev The index fell 8 -> 6 when the skim deletion dropped `rate0Of` and `hwmOf` ahead of it.
    function test_A22_TheAppendedPolicySitsAtLoanBookIndexSix() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 250);

        uint256 packed = uint256(ace.extsload(keccak256(abi.encode(oldId, uint256(Storage.BOOK) + 6))));

        assertEq(uint64(packed), TEN7, "the tenor reads at BOOK + 6");
        assertEq(uint16(packed >> 64), uint16(250), "and both fields pack into that one slot");
        assertGt(read.feeEscrowOf(oldId), 0, "while index 5 still answers feeEscrowOf: the append moved nothing");
    }

    // ============ A23. the DERIVED window, both legs of `min(2 hours, minTenor / 5)` ============

    /// @notice A23: on a long-tenor market the 2-hour CAP binds, not the fifth. Pinned from both sides.
    /// @dev A fifth of 7 days is 1.4 days, so a fifth-only window would open a day early.
    function test_A23_AutoWindow_TheCapBinds_OnALongTenorMarket() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        uint256 expiry = read.loan(oldId).expiry;

        _warpTo(expiry - TEN7 / 5);
        (bool ok, bytes memory ret) = _rawExec(mallory, oldId);
        _refuses(ok, ret, OutsideRefinanceWindow.selector, "a fifth of seven days is far outside the capped window");

        _warpTo(expiry - WINDOW - 1);
        (ok, ret) = _rawExec(mallory, oldId);
        _refuses(ok, ret, OutsideRefinanceWindow.selector, "and one second before the cap is still outside");

        _warpTo(expiry - WINDOW);
        assertGt(_exec(mallory, oldId), oldId, "while the cap's own edge admits");
    }

    /// @notice A23b: on a minute-scale market the FIFTH binds, which is what makes such a market work.
    /// @dev A market at a ten-minute tenor is the testnet rollover shape, and a fixed 2-hour window put
    /// @dev the gate before the loan existed -- so no such market could be created at all.
    function test_A23b_AutoWindow_TheFifthBinds_OnAMinuteScaleMarket() public {
        (bytes32 mid, uint256 oldId) = _minuteScaleLoan();
        assertEq(ace.idToMarketParams(mid).minTenor, SHORT, "fixture: a ten-minute market IS creatable");
        _arm(borrower, oldId, SHORT, 0);
        uint256 expiry = read.loan(oldId).expiry;

        _warpTo(expiry - SHORT / 5 - 1);
        (bool ok, bytes memory ret) = _rawExec(mallory, oldId);
        _refuses(ok, ret, OutsideRefinanceWindow.selector, "one second before a fifth of the term is outside");

        _warpTo(expiry - SHORT / 5);
        uint256 newId = _exec(mallory, oldId);

        assertTrue(read.loan(oldId).closedAt != 0, "two minutes out, the gate is open");
        assertEq(read.loan(newId).expiry, _now() + SHORT, "with a whole fresh ten-minute term");
        assertEq(read.loan(newId).borrower, borrower, "still the borrower's position");
    }

    // ============ A24c. executor attribution on the auto path ============

    /// @notice A24c: `Refinanced` logs the EXTERNAL caller, which is what a periphery sponsor pays against.
    /// @dev `delegatecall` preserves `msg.sender`, so the relocated body still sees the real caller.
    /// @dev Backwards, every continuation would log the hub's own address and nothing would fail.
    function test_A24c_Refinanced_LogsTheExternalCaller_NotTheHub() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);

        vm.recordLogs();
        uint256 newId = _exec(mallory, oldId);
        assertEq(_refinancedExecutor(vm.getRecordedLogs(), oldId), mallory, "a third-party run logs the third party");

        _arm(borrower, newId, TEN7, 0);
        _warpTo(uint256(read.loan(newId).expiry) - WINDOW);
        vm.recordLogs();
        _exec(borrower, newId);
        assertEq(_refinancedExecutor(vm.getRecordedLogs(), newId), borrower, "and the borrower's own run logs them");
    }

    // ============ A26. the batch, and the all-or-nothing rule that defines it ============

    /// @notice A26: a keeper continues many armed loans in ONE transaction, answered in the CALLER's order.
    /// @dev The three principals differ, so `newIds[k]` is tied back to `ids[k]` by the DERIVED debt
    /// @dev rather than by the id counter, which would rise in order whatever the input order was.
    function test_A26_RefinanceByPolicies_ContinuesTheWholeBatch_InInputOrder() public {
        uint256[] memory armed = _threeArmed();
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (armed[2], armed[0], armed[1]); // deliberately NOT id order
        uint256[] memory want = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            want[i] = _expected(ids[i], TEN7);
        }

        uint256[] memory newIds = _execBatch(mallory, ids);

        assertEq(newIds.length, 3, "one fresh loan per input");
        for (uint256 i; i < 3; i++) {
            assertTrue(read.loan(ids[i]).closedAt != 0, "every armed member retired");
            assertEq(read.debtOf(newIds[i]), want[i], "and newIds[k] is the continuation of ids[k]");
            assertEq(read.loan(newIds[i]).borrower, borrower, "titled to the borrower, never to the keeper");
        }
        assertTrue(want[0] != want[1] && want[1] != want[2], "fixture: the three are distinguishable at all");
    }

    /// @notice A26b: ALL-OR-NOTHING. One DISARMED member in the middle takes the whole batch with it.
    /// @dev The revert is the cheap half; the property is that the other two did not move one wei.
    function test_A26b_RefinanceByPolicies_ADisarmedMemberRevertsTheWholeBatch() public {
        uint256[] memory ids = _threeArmed();
        _arm(borrower, ids[1], 0, 0); // the middle one disarms
        uint256 countBefore = read.loanCount();
        Snap[] memory before = new Snap[](3);
        for (uint256 i; i < 3; i++) {
            before[i] = _snap(ids[i]);
        }

        (bool ok, bytes memory ret) = _rawExecBatch(mallory, ids);
        _refuses(ok, ret, AutoPolicyDisarmed.selector, "a disarmed member is not skipped, it is fatal");

        for (uint256 i; i < 3; i++) {
            _assertSnapEq(before[i], _snap(ids[i]), "every member of a failed batch is bit-identical");
        }
        assertEq(read.loanCount(), countBefore, "and no loan id was consumed");
    }

    /// @notice A26c: one member OUTSIDE its window is fatal too, on the same rule.
    /// @dev The odd member runs a 30-day term, so the batch's own warp is a fortnight from its window.
    function test_A26c_RefinanceByPolicies_AnOutOfWindowMemberRevertsTheWholeBatch() public {
        uint256 far = _open(P, TEN30);
        _arm(borrower, far, TEN7, 0);
        uint256[] memory armed = _threeArmed();
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (armed[0], far, armed[2]);
        uint256 countBefore = read.loanCount();
        Snap[] memory before = new Snap[](3);
        for (uint256 i; i < 3; i++) {
            before[i] = _snap(ids[i]);
        }

        (bool ok, bytes memory ret) = _rawExecBatch(mallory, ids);
        _refuses(ok, ret, OutsideRefinanceWindow.selector, "one member outside its window is fatal to the batch");

        for (uint256 i; i < 3; i++) {
            _assertSnapEq(before[i], _snap(ids[i]), "every member of a failed batch is bit-identical");
        }
        assertEq(read.loanCount(), countBefore, "and no loan id was consumed");
    }

    /// @notice A26d: a DUPLICATE id is refused LOUDLY -- the second pass finds the loan already closed.
    /// @dev A caller building an id list from logs can easily double one, and a silent second pass would
    /// @dev charge that borrower a second origination fee for a term they already bought.
    function test_A26d_RefinanceByPolicies_ADuplicateIdIsRefusedLoudly() public {
        uint256[] memory armed = _threeArmed();
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (armed[0], armed[1], armed[0]);
        uint256 countBefore = read.loanCount();
        Snap memory before = _snap(armed[0]);

        (bool ok, bytes memory ret) = _rawExecBatch(mallory, ids);
        _refuses(ok, ret, LoanClosed.selector, "the second pass over an id finds a closed loan");

        _assertSnapEq(before, _snap(armed[0]), "and the doubled loan is exactly where it was");
        assertEq(read.loanCount(), countBefore, "with no loan id consumed");
    }

    /// @notice A26e: for ONE id the batch and the singular are outcome-identical.
    /// @dev Both legs run from the SAME state via a snapshot: a second draw walks a ladder the first
    /// @dev already thinned, so running them back to back would not be a control at all.
    function test_A26e_RefinanceByPolicies_MatchesTheSingularForOneId() public {
        uint256 oldId = _open(P, TEN7);
        _arm(borrower, oldId, TEN7, 0);
        _warpTo(uint256(read.loan(oldId).expiry) - WINDOW);
        uint256 root = vm.snapshotState();

        uint256 single = _exec(mallory, oldId);
        Snap memory viaSingle = _snap(single);
        uint256 singleFloor = read.fundingFloor(id, single);

        vm.revertToState(root);
        uint256[] memory ids = new uint256[](1);
        ids[0] = oldId;
        uint256[] memory newIds = _execBatch(mallory, ids);

        assertEq(newIds.length, 1, "one in, one out");
        assertEq(newIds[0], single, "the same fresh id");
        assertEq(read.fundingFloor(id, newIds[0]), singleFloor, "the same funding floor");
        _assertSnapEq(viaSingle, _snap(newIds[0]), "and the same loan, field for field");
    }

    /// @notice A26f: every `Refinanced` in a batch names the BATCH's caller, which is what a sponsor pays.
    /// @dev One transaction, three library calls; `delegatecall` preserves the external caller through all.
    function test_A26f_RefinanceByPolicies_EveryLogNamesTheBatchCaller() public {
        uint256[] memory ids = _threeArmed();

        vm.recordLogs();
        _execBatch(mallory, ids);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < 3; i++) {
            assertEq(_refinancedExecutor(logs, ids[i]), mallory, "each continuation names the batch caller");
        }
    }

    /// @notice A26g: an EMPTY batch is an inert no-op rather than a revert.
    /// @dev Chosen because the loop already does nothing: a guard would spend bytes turning a harmless
    /// @dev keeper edge case into a failed transaction the keeper then has to special-case around.
    function test_A26g_RefinanceByPolicies_AnEmptyBatchIsAnInertNoOp() public {
        uint256 countBefore = read.loanCount();

        uint256[] memory newIds = _execBatch(mallory, new uint256[](0));

        assertEq(newIds.length, 0, "nothing in, nothing out");
        assertEq(read.loanCount(), countBefore, "and no loan id was consumed");
    }

    // ============ H1-H5. the hardening pass: five guards no green test was defending ============

    /// @notice H1: an UNARMED continuation says nothing. `_carry`'s early return is what makes it silent.
    /// @notice Deleting that return is not log-only: the clamp lifts the zero tenor to minTenor and ARMS the successor (H1, A7g fail).
    /// @dev Written as a policy an all-zero carry cannot fake: a keeper indexing `AutoPolicySet` would
    /// @dev otherwise see a disarm notice for a loan nobody ever armed, on every manual continuation.
    /// @dev The armed leg is the recorder's own control, so a dead matcher cannot pass the negative half.
    function test_H1_ManualRefinance_OfAnUnarmedLoan_EmitsNoPolicyNotice() public {
        uint256 oldId = _open(P, TEN7);
        _warpTo(t0 + 3 days);

        vm.recordLogs();
        uint256 quiet = _refiComposed(borrower, oldId, 71_000e6, TEN7);
        assertFalse(_sawAutoPolicySet(vm.getRecordedLogs(), quiet), "an unarmed loan carries nothing, and says so");

        (uint64 tenor, uint16 buf) = _policy(quiet);
        assertEq(tenor, 0, "the continuation of an unarmed loan reads DISARMED");
        assertEq(buf, 0, "with no terms attached either");

        _arm(borrower, quiet, TEN7, 250);
        vm.recordLogs();
        uint256 loud = _refiComposed(borrower, quiet, 71_000e6, TEN7);
        assertTrue(_sawAutoPolicySet(vm.getRecordedLogs(), loud), "control: the recorder DOES see a real carry");
    }

    /// @notice H2: `minPayout` bounds the NET out of a refinance, and it is the borrower's only such term.
    /// @notice Pinned from both sides, because the gate lives in `_net` and `open` is handed a ZEROED copy.
    /// @dev Deleting the check leaves all 92 refinance tests green: nothing else reads the field on this path.
    /// @dev A borrower quoting a continuation off-chain has no other way to refuse a drifted ladder.
    function test_H2_Refinance_RefusesANetPayoutUnderTheBorrowersFloor() public {
        uint256 oldId = _open(P, TEN7);
        _warpTo(t0 + 3 days);
        uint256 refundOld = read.earlyExitRefund(oldId);
        uint256 pNew = 71_000e6;
        uint256 out = pNew - _fee(pNew, TEN7) + refundOld - read.debtOf(oldId);
        assertGt(out, 0, "fixture: this continuation really does pay the borrower something");

        vm.prank(borrower);
        vm.expectRevert(PayoutBelowMin.selector);
        fin.refinance(oldId, pNew, TEN7, OpenBounds(out + 1, 0, 0));

        assertFalse(read.loan(oldId).closedAt != 0, "a refused continuation leaves the old loan whole");

        vm.prank(borrower);
        uint256 newId = fin.refinance(oldId, pNew, TEN7, OpenBounds(out, 0, 0));
        assertFalse(read.loan(newId).closedAt != 0, "while the exact net the borrower asked for is admitted");
    }

    /// @notice H3: an underfunded draw is refused BY NAME, and the composition that covers it succeeds.
    /// @notice The original coverage was a bare `vm.expectRevert()`, which any revert at all satisfies.
    /// @dev So the guard's presence was pinned but its identity was not: a wrong error read as a pass.
    function test_H3_Refinance_RefusesADrawBelowTheOldDebt_ByName() public {
        uint256 oldId = _open(P, TEN7);
        _warpTo(t0 + 3 days);
        uint256 pNew = 60_000e6;
        uint256 owed = read.debtOf(oldId) - (pNew - _fee(pNew, TEN7) + read.earlyExitRefund(oldId));
        assertGt(owed, 0, "fixture: the fresh draw really does fall short of the old debt");
        uint256 before = usdc.balanceOf(borrower);

        vm.prank(borrower);
        vm.expectRevert(DrawBelowDebt.selector);
        fin.refinance(oldId, pNew, TEN7, OFF);

        assertEq(usdc.balanceOf(borrower), before, "and a refused refinance takes nothing from the wallet");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (oldId, owed));
        calls[1] = abi.encodeCall(Ace.refinance, (oldId, pNew, TEN7, OFF));
        vm.prank(borrower);
        ace.multicall(calls);
        assertEq(before - usdc.balanceOf(borrower), owed, "repaying the gap first pays exactly the shortfall");
    }

    /// @notice H3b: the gap this suite computes is the EXACT wei the verb stops refusing at, not merely enough.
    /// @notice H3 repays `owed` and then asserts the borrower paid `owed`, which is true of any over-payment.
    /// @dev `_migrateGap` and H3's arithmetic are a SECOND copy of `Borrower._net`, shared by every composed row.
    /// @dev Too small already fails loudly: the inner refinance reverts inside the multicall.
    /// @dev Too large is the silent direction, and only a boundary pin closes it.
    function test_H3b_TheComputedGapIsTheExactRefusalBoundary() public {
        uint256 oldId = _open(P, TEN7);
        _warpTo(t0 + 3 days);
        uint256 pNew = 60_000e6;
        uint256 owed = read.debtOf(oldId) - (pNew - _fee(pNew, TEN7) + read.earlyExitRefund(oldId));
        assertGt(owed, 1, "fixture: the shortfall is more than a single wei");

        vm.startPrank(borrower);
        ace.repay(oldId, owed - 1);
        vm.expectRevert(DrawBelowDebt.selector);
        fin.refinance(oldId, pNew, TEN7, OFF);
        ace.repay(oldId, 1);
        uint256 newId = fin.refinance(oldId, pNew, TEN7, OFF);
        vm.stopPrank();

        assertTrue(read.loan(oldId).closedAt != 0, "the last wei of the gap is what opens the successor");
        assertEq(read.debtOf(newId), pNew, "at the requested principal");
    }

    /// @notice H4: all THREE new entries answer to the hub's one transient slot, from inside a callback.
    /// @dev Each modifier is independently deletable, so each door is probed on its own.
    /// @dev A mid-crank arm would let a route change the borrower's standing terms while their collateral
    /// @dev is out on loan; a mid-crank execution would migrate a position whose sale is half-applied.
    function test_H4_TheThreeNewEntries_AreAllRefusedFromInsideACallback() public {
        for (uint8 door; door < 3; door++) {
            uint256 root = vm.snapshotState();
            (ReentrantAutoCaller attacker, uint256 loanId) = _armReentrant(door);

            vm.expectRevert(GUARD_TRIP);
            attacker.crank(loanId);

            assertFalse(read.loan(loanId).closedAt != 0, "and the loan is exactly where it was");
            vm.revertToState(root);
        }
    }

    /// @notice H5: the derived window is STRICTLY under the shortest term, at every `minTenor` that exists.
    /// @notice That is the property the gate's addition form leans on, and no market can be created without it.
    /// @dev Section 6.8's rail was dropped as dead code on exactly this argument, so the argument needs a test.
    /// @dev It also kills either leg of the `min` being dropped: a bare cap fails at one second, a bare
    /// @dev fifth fails nowhere but is no longer bounded by the two-hour latency budget, asserted below.
    function testFuzz_H5_AutoWindow_IsStrictlyUnderEveryAdmissibleMinTenor(uint64 minTenorSeed) public pure {
        uint64 minTenor = uint64(bound(uint256(minTenorSeed), 1, type(uint64).max));

        uint64 w = MarketInit.autoRefinanceWindow(minTenor);

        assertLt(w, minTenor, "the window can never span a whole term, so expiry - window never underflows");
        assertLe(w, 2 hours, "and it is a keeper-latency budget, never more");
    }

    /// @notice H6: the batch prices EVERY member against its OWN market, which is what a batch is for.
    /// @notice Every batch test before this one ran on a single market, so the per-member cache was free.
    /// @dev Caching all members against `ids[0]`'s market compiles and passes all seven A26 cases: the
    /// @dev fee schedule, dust floor and ladder of the first member would then govern the whole list.
    /// @dev Two markets differing ONLY in `baseBps`, so the wrong cache shows up as a wrong principal.
    function test_H6_RefinanceByPolicies_PricesEachMemberAgainstItsOwnMarket() public {
        bytes32 alt = _altFeeMarket();
        uint256 here = _open(P, TEN7);
        uint256 there = _openOn(alt, P, TEN7);
        _arm(borrower, here, TEN7, 0);
        _arm(borrower, there, TEN7, 0);
        _warpTo(uint256(read.loan(here).expiry) - WINDOW);
        uint256 wantHere = _derivedAt(read.debtOf(here), read.earlyExitRefund(here), TEN7, BASE_BPS);
        uint256 wantThere = _derivedAt(read.debtOf(there), read.earlyExitRefund(there), TEN7, ALT_BPS);
        assertTrue(wantHere != wantThere, "fixture: the two schedules really do derive different principals");

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (here, there);
        uint256[] memory newIds = _execBatch(mallory, ids);

        assertEq(read.loan(newIds[0]).market, id, "member 0 continues in its own market");
        assertEq(read.loan(newIds[1]).market, alt, "and member 1 in ITS own, never in member 0's");
        assertEq(read.debtOf(newIds[0]), wantHere, "each member is derived against its own fee schedule");
        assertEq(read.debtOf(newIds[1]), wantThere, "which is the whole of what caching per member buys");
    }

    // ---- secondary fixtures ----

    /// @dev Section 6.4's derivation at a chosen `baseBps`, so a second market's answer is spelled out too.
    function _derivedAt(uint256 debtOld, uint256 refundOld, uint64 tenor, uint256 baseBps) private pure returns (uint256) {
        uint256 d = 10000 * 10000 * uint256(TEN7);
        uint256 den = d - baseBps * uint256(tenor) * 11000;
        return ((debtOld - refundOld) * d + den - 1) / den;
    }

    /// @dev A funded twin differing from the base market in its ORIGINATION FEE and nothing else.
    function _altFeeMarket() private returns (bytes32 mid) {
        MarketParams memory p = _params();
        p.baseBps = ALT_BPS;
        mid = ace.createMarket(p);
        _deposit(mid, TOP);
    }

    /// @dev A title-holding contract armed to reach `door` from inside its own deleverage callback.
    /// @dev The loan sits inside its auto window and the record has entered the band, so the crank reaches the callback.
    /// @dev A BANDED market, because the crank that hands control to a caller is the decline channel.
    function _armReentrant(uint8 door) private returns (ReentrantAutoCaller attacker, uint256 loanId) {
        MarketParams memory p = _params();
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = BAND_BPS;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        bytes32 mid = ace.createMarket(p);
        _deposit(mid, TOP);

        attacker = new ReentrantAutoCaller(ace);
        vault.mint(address(attacker), COLL);
        usdc.mint(address(attacker), FLOAT);
        loanId = attacker.openLoan(mid, address(vault), address(usdc), COLL, P, TEN7);
        attacker.setPolicy(loanId, TEN7);
        attacker.arm(loanId, door);
        _warpTo(uint256(read.loan(loanId).expiry) - WINDOW);
        _enterBand(loanId);
    }

    /// @dev Three loans on the base market at DISTINCT principals, all armed, all inside the window.
    function _threeArmed() private returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = _open(20_000e6, TEN7);
        ids[1] = _open(45_000e6, TEN7);
        ids[2] = _open(P, TEN7);
        for (uint256 i; i < 3; i++) {
            _arm(borrower, ids[i], TEN7, 0);
        }
        _warpTo(uint256(read.loan(ids[0]).expiry) - WINDOW);
    }

    /// @dev A market whose dust floor sits ABOVE what a repaid-down debt would otherwise derive back to.
    /// @dev `floor` is the lever: a reachable one the collateral can still carry, or one it cannot.
    /// @dev The debt goes under the floor by the BORROWER's own partial repay: a keeper's crank never melts a loan under `minDebt`.
    function _dustFloorLoan(uint256 floor) private returns (bytes32 mid, uint256 loanId) {
        MarketParams memory p = _params();
        p.minDebt = floor;
        mid = ace.createMarket(p);
        _deposit(mid, TOP);
        loanId = _openOn(mid, P, TEN7);
    }

    /// @dev The borrower repays down to `left`, which `repay` allows under `minDebt`: it bounds what a market issues, not what a repay leaves.
    function _repayTo(uint256 loanId, uint256 left) private {
        uint256 amount = read.debtOf(loanId) - left; // read BEFORE the prank: an external call in the argument would spend it
        vm.prank(borrower);
        ace.repay(loanId, amount);
    }

    /// @dev Put the record in the band at 35% over the trigger, which is also the disposal floor.
    /// @dev HIGH inside the band on purpose: the sale prices per unit, so a high fill melts the debt the
    /// @dev dust-floor rows need while leaving the successor enough collateral to carry the floored draw.
    function _enterBand(uint256 loanId) private {
        uint256 trig = read.triggerPrice(loanId);
        uint256 ps = (trig * 135) / 100;
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - BAND_BPS * 1e14));
        record.setMinPrice(ps);
    }

    /// @dev A second market on the SAME pair, which is the only compatibility rule a migration has.
    function _twinMarket() private returns (bytes32 mid) {
        MarketParams memory p = _params();
        p.record = _twinRecord();
        mid = ace.createMarket(p);
        _deposit(mid, TOP);
    }

    /// @dev A funded market on the same pair with an arbitrary tenor grid, for the carry-clamp cases.
    function _gridMarket(uint64 minT, uint64 maxT, uint64 spacing) private returns (bytes32 mid) {
        MarketParams memory p = _params();
        p.record = _twinRecord(); // a grid may coincide with the base market's, so identity rides on the record
        p.minTenor = minT;
        p.maxTenor = maxT;
        mid = ace.createMarket(p);
        _deposit(mid, TOP);
    }

    /// @dev The DATA half of `AutoPolicySet`: `_sawAutoPolicySet` matches topics only and misses a wrong tenor.
    function _autoPolicyTenor(Vm.Log[] memory logs, uint256 loanId) private pure returns (uint64) {
        bytes32 sig = keccak256("AutoPolicySet(uint256,uint64,uint16,uint16)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] == sig && logs[i].topics[1] == bytes32(loanId)) {
                (uint64 tenor,,) = abi.decode(logs[i].data, (uint64, uint16, uint16));
                return tenor;
            }
        }
        return 0;
    }

    /// @dev A single-rung market at a tenor near the auto window; every other genesis rail stays clear.
    function _shortTenorParams(uint64 tenor) private view returns (MarketParams memory p) {
        p = _params();
        p.minTenor = tenor;
        p.maxTenor = tenor;
    }

    // ---- the pro-rata refund: the SIZING read and the BOOK WRITE must agree ----

    /// @notice `Borrower.derivedPrincipal` RECOMPUTES the pro-rata refund that `LoanAccounting.earnFeeEscrowProRata`
    /// @notice WRITES. Nothing in either names the other, and either formula moving breaks the auto path.
    /// @dev A disagreement of ONE WEI reverts `DrawBelowDebt`, so the crank COMPLETING at all is the
    /// @dev coupling assertion, and the caller's untouched balance is the visible half of it.
    /// @dev THE ORACLE IS `feeEscrowOf` RECOMPUTED HERE, deliberately. `read.earlyExitRefund` is a THIRD
    /// @dev copy of the same formula in a DIFFERENT shape -- it carries no `refund > escrow` clamp -- so
    /// @dev routing this through it would pass a drift that moved the reader and the hub together.
    function test_AutoRefinance_TheDerivedPrincipalNetsTheSameRefundTheRetirementBooks() public {
        /// @dev DOUBLE collateral: the successor draws the debt PLUS its own fee, and at the baseline
        /// @dev collateral that widened draw's trigger sits a hair over the par rung, so the roll is refused
        /// @dev before the two formulas can be compared. The row is about the formulas, not about admission.
        uint256 loanId = _openOnWith(id, 2 * COLL, P, TEN30);
        _arm(borrower, loanId, TEN30, 0);
        _warpTo(t0 + uint256(TEN30) - 1 hours); // inside the window, whose cap leg is 2 hours

        uint256 debtBefore = read.debtOf(loanId);
        uint256 escrowBefore = read.feeEscrowOf(loanId);
        uint256 remaining = uint256(read.loan(loanId).expiry) - _now();
        uint256 refundBefore = (escrowBefore * remaining) / uint256(TEN30);
        assertGt(refundBefore, 0, "fixture: there IS an unearned refund for the two formulas to disagree about");
        uint256 keeperBefore = usdc.balanceOf(carol);
        uint256 borrowerBefore = usdc.balanceOf(borrower);

        uint256 newId = _exec(carol, loanId);

        assertEq(usdc.balanceOf(carol), keeperBefore, "the crank funded nothing: a one-wei shortfall would have reverted");
        uint256 expectedP = _derivedPrincipal(debtBefore, refundBefore, TEN30);
        assertEq(read.debtOf(newId), expectedP, "the draw is sized off the refund the retirement actually booked");
        uint256 expectedOut = expectedP - _fee(expectedP, TEN30) + refundBefore - debtBefore;
        assertEq(usdc.balanceOf(borrower) - borrowerBefore, expectedOut, "and the netting paid out that exact refund, once");
    }

    /// @dev A funded single-rung market at a ten-minute tenor, plus one loan on it.
    function _minuteScaleLoan() private returns (bytes32 mid, uint256 loanId) {
        mid = ace.createMarket(_shortTenorParams(SHORT));
        _deposit(mid, TOP);
        loanId = _openOn(mid, P, SHORT);
    }

    /// @dev The carry-forward notice section 6.10 requires; the name is the plan's step 9.
    function _sawAutoPolicySet(Vm.Log[] memory logs, uint256 loanId) private pure returns (bool) {
        bytes32 sig = keccak256("AutoPolicySet(uint256,uint64,uint16,uint16)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] == sig && logs[i].topics[1] == bytes32(loanId)) return true;
        }
        return false;
    }

    /// @dev `Refinanced` with section 6.11's appended `address indexed executor`: topic 3 of 3.
    function _refinancedExecutor(Vm.Log[] memory logs, uint256 oldId) private pure returns (address) {
        bytes32 sig = keccak256("Refinanced(uint256,uint256,uint256,uint64,uint256,address)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length < 4) continue;
            if (logs[i].topics[0] == sig && logs[i].topics[1] == bytes32(oldId)) {
                return address(uint160(uint256(logs[i].topics[3])));
            }
        }
        return address(0);
    }
}
