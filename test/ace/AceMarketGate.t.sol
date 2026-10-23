// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {GateRefused} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceMarketGate
/// @notice The entry seam: a market's `borrower` is checked on the open doors and nowhere else.
/// @notice A zero borrower is permissionless and byte-identical to an ungated market; exits are NEVER checked.
/// @dev WAS A GATE CONTRACT, and the shape change is why half this suite is gone rather than rewritten.
/// @dev `IMarketGate.canBorrow` was a staticcall to a creator-chosen contract; it is now `p.borrower`, an
/// @dev address in the market id preimage. Four hazard classes went with it and are UNREPRESENTABLE, not
/// @dev merely untested: a gate that REVERTS, one that returns the wrong WIDTH, one that BURNS its gas,
/// @dev and one that CHANGES ITS ANSWER between the open and a later roll.
/// @dev THE LAST OF THOSE IS THE ONE WORTH NAMING: a market's admission is now write-once, so "a borrower
/// @dev delisted mid-term" cannot happen. The rows that proved a delisted borrower could still settle are
/// @dev gone with the state they described -- there is no way to reach it.
/// @dev The LENDER half is gone too, for a different reason: sole tenancy names one lender in the params.
contract AceMarketGateTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id0; // the control: no borrower named, so anyone may open

    address internal alice = address(0xA11CE); // the fixture's named lender
    address internal bob = address(0xB0B2);
    address internal borrower = address(0xB0B);
    address internal op = address(0x0123);
    address internal keeper = address(0xCAFE);
    address internal mallory = address(0xBAD);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant TOP = 400_000e6;
    uint256 internal T; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal NEAR; // the rung under par

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T, NEAR) = (_price(0), _price(-60));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(address(0)));
        (ace, pm, read, id0) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        usdc.mint(borrower, 10_000_000e6);
    }

    // ---- fixture ----

    function _params(address borrower_) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.borrower = borrower_; // the id differentiator, and the whole admission rule
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000; // the crank leg of the exit sweep below needs a live channel
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    function _market(address borrower_) internal returns (bytes32) {
        return ace.createMarket(_params(borrower_));
    }

    function _deposit(address who, bytes32 mid, uint256 price, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt); // a 30d horizon, so every tenor on the grid funds
        vm.stopPrank();
    }

    function _open(address who, bytes32 mid, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        vault.mint(who, COLL);
        vm.startPrank(who);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, principal, tenor, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    // ---- the entry door ----

    /// @notice A zero borrower is permissionless and behaves exactly as an ungated market did.
    function test_ZeroBorrower_DepositAndOpenUnchanged() public {
        _deposit(alice, id0, T, TOP);
        assertEq(ace.restingOf(id0), TOP, "the deposit rests");
        uint256 loanId = _open(borrower, id0, P, TEN7);
        assertEq(ace.borrowerOf(loanId), borrower, "loan records the borrower");
        assertEq(read.loan(loanId).debt, P, "debt is the principal");
        assertEq(ace.idToMarketParams(id0).borrower, address(0), "the control market names nobody");
    }

    /// @notice A market naming somebody else refuses this borrower's open, by name.
    function test_NamedBorrower_RefusesAnother() public {
        bytes32 mid = _market(bob);
        _deposit(alice, mid, T, TOP);
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        vm.expectRevert(GateRefused.selector);
        ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice And the market naming THIS borrower admits them, which is what makes the row above load-bearing.
    function test_NamedBorrower_AdmitsTheNamedOne() public {
        bytes32 mid = _market(borrower);
        _deposit(alice, mid, T, TOP);
        uint256 loanId = _open(borrower, mid, P, TEN7);
        assertEq(ace.borrowerOf(loanId), borrower, "the named borrower opened");
    }

    // ---- the delegated and migrating parties ----

    /// @notice The checked party is the BORROWER; an operator is neither shield nor loophole.
    /// @dev Leg (a): an UNNAMED operator opening for the NAMED borrower succeeds.
    /// @dev Leg (b): the same operator opening for an UNNAMED party is refused, so nothing launders through it.
    /// @dev The operator is deliberately not the named party in either leg, which is what isolates the check.
    function test_OpenOnBehalfOf_ChecksBorrowerNotOperator() public {
        bytes32 mid = _market(borrower);
        _deposit(alice, mid, T, TOP);

        vm.prank(borrower);
        ace.setCreditOperator(op, true);
        vault.mint(op, COLL);
        usdc.mint(op, 1_000_000e6);
        vm.startPrank(op);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        uint256 loanId = ace.open(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(ace.borrowerOf(loanId), borrower, "leg (a): the named borrower opened via an operator");

        vm.prank(bob);
        ace.setCreditOperator(op, true);
        vault.mint(op, COLL);
        vm.startPrank(op);
        vault.approve(address(pm), COLL);
        vm.expectRevert(GateRefused.selector);
        ace.open(mid, COLL, P, TEN7, bob, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice A migration checks the DESTINATION only; the source exit asks nothing.
    /// @dev The source names this borrower and the destination does not, so a source read could only ADMIT.
    /// @dev The refusal therefore proves the destination was consulted, and the later success that the source was not.
    function test_RefinanceIntoADestinationNamingAnother() public {
        bytes32 srcId = _market(borrower);
        bytes32 dstId = _market(bob); // names somebody else
        bytes32 openDst = id0; // the rig's OWN open market, which `_market(address(0))` would collide with
        _deposit(alice, srcId, T, TOP);
        _deposit(alice, dstId, T, TOP);
        _deposit(alice, openDst, T, TOP);
        uint256 loanId = _open(borrower, srcId, P, TEN7);

        MigrateArgs memory m = MigrateArgs(loanId, dstId, P, TEN7, OpenBounds(0, 0, 0), 0, address(0));
        vm.prank(borrower);
        vm.expectRevert(GateRefused.selector);
        ace.refinanceTo(m);
        assertFalse(ace.isClosed(loanId), "the refused migration left the source loan whole");
        assertEq(read.loan(loanId).debt, P, "debt untouched");
        assertEq(read.loan(loanId).collateralUnits, COLL, "collateral untouched");

        // a same-principal roll pays a fresh fee against a part refund, so it rides the composition
        MigrateArgs memory ok = MigrateArgs(loanId, openDst, P, TEN7, OpenBounds(0, 0, 0), 0, address(0));
        MarketParams memory dp = ace.idToMarketParams(openDst);
        uint256 credit = P - LoanMath.originationFee(P, TEN7, dp.baseBps, dp.minTenor) + read.earlyExitRefund(loanId);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (loanId, credit >= P ? 0 : P - credit));
        calls[1] = abi.encodeCall(Ace.refinanceTo, (ok));
        vm.prank(borrower);
        uint256 newId = abi.decode(ace.multicall(calls)[1], (uint256));
        assertTrue(ace.isClosed(loanId), "the admitted migration closed the source");
        assertEq(ace.borrowerOf(newId), borrower, "and opened in the destination");
    }

    // ---- the doctrine test ----

    /// @notice EXITS ARE NEVER CHECKED. A market naming one borrower is inert on every verb but the open doors.
    /// @dev The classification below is derived from Ace.sol's external mutating surface, not from memory.
    /// @dev ENTRY (checked): both deposit doors; both open doors; refinanceTo (dst); refinanceByPolicy.
    /// @dev EXIT: withdraw, collect, redeemInKind, buyInventory, repay, finalize.
    /// @dev EXIT, continued: withdrawCollateral, forceClose, deleverage, sweeps, retitle.
    /// @dev NEUTRAL: setAutoRefinance, setCreditOperator, createMarket.
    /// @dev A verb added to Ace later must be classified into one of the lists above.
    /// @dev THE HOSTILE FLIP IS GONE: this used to arm a denying gate mid-test, which the write-once field
    /// @dev cannot express. What is left is the exit surface run by parties the market never named, which is
    /// @dev the half that was always the point -- a stranger's forceClose and buy must not consult admission.
    function test_ExitsNeverChecked() public {
        bytes32 mid = _market(borrower);
        _deposit(alice, mid, T, TOP);
        _deposit(alice, mid, NEAR, 200_000e6);
        uint256 repayLoan = _open(borrower, mid, 60_000e6, TEN30);
        uint256 crankLoan = _open(borrower, mid, 60_000e6, TEN30);
        uint256 finalLoan = _open(borrower, mid, 60_000e6, TEN30);
        uint256 shortLoan = _open(borrower, mid, 60_000e6, TEN7);
        uint256 liveLoan = _open(borrower, mid, 60_000e6, TEN30);
        MockDeleverageKeeper sk = new MockDeleverageKeeper(ace, address(usdc), address(vault), 1e30);

        vm.prank(alice);
        ace.withdraw(mid, 1000e6, alice, 0);

        vm.startPrank(borrower);
        ace.repay(repayLoan, 10_000e6);
        ace.repay(repayLoan, type(uint256).max);
        vm.stopPrank();
        assertTrue(ace.isClosed(repayLoan), "full repay closed clean");

        vm.prank(borrower);
        ace.withdrawCollateral(liveLoan, 100e18, borrower);

        uint256 trig = read.triggerPrice(crankLoan);
        record.setBelowBand(FullMath.mulDivRoundingUp(trig, 1e18, 1e18 - 3000 * 1e14));
        record.setMinPrice(trig + trig / 20);
        sk.crankDeleverage(crankLoan); // a keeper the market never named
        record.setBelowBand(0);
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(vault)));

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(finalLoan);
        assertTrue(ace.isClosed(finalLoan), "a stranger's finalize ran");
        record.setBelow(false);

        _warpBy(TEN7 + 1);
        vm.prank(mallory);
        ace.forceClose(shortLoan);
        assertTrue(ace.isClosed(shortLoan), "a stranger's forceClose ran");

        /// @dev The ask rests after settlement, so the buy below tests ADMISSION rather than the clock
        _warpTo(read.inventoryAskOpensAt(shortLoan));
        usdc.mint(mallory, 50_000e6);
        vm.startPrank(mallory);
        usdc.approve(address(ace), 50_000e6);
        (uint256 unitsOut,) = ace.buyInventory(shortLoan, 10_000e6, 1, mallory);
        vm.stopPrank();
        assertGt(unitsOut, 0, "a stranger's buyInventory ran");

        ace.sweepRevenue(mid);

        // and the ONE door that does check still refuses the party the market never named
        vault.mint(bob, COLL);
        vm.startPrank(bob);
        vault.approve(address(pm), COLL);
        usdc.mint(bob, 1_000_000e6);
        usdc.approve(address(ace), type(uint256).max);
        vm.expectRevert(GateRefused.selector);
        ace.open(mid, COLL, 1_000e6, TEN7, bob, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    // ---- seam discipline ----

    /// @notice The fixture default is a zero borrower, so every other suite is untouched by the seam.
    function test_Genesis_BorrowerDefaultsToZero() public view {
        assertEq(AceFixtures.marketParams(address(usdc), address(vault)).borrower, address(0), "fixture default");
        assertEq(ace.idToMarketParams(id0).borrower, address(0), "the deployed control market");
    }

    /// @notice `previewOpen` refuses exactly as `open` does, and the lens carries the non-reverting form.
    function test_PreviewOpenReflectsTheNamedBorrower() public {
        bytes32 mid = _market(bob);
        vm.prank(borrower);
        vm.expectRevert(GateRefused.selector);
        ace.previewOpen(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));

        (bool ok, bytes4 reason,) = lens.tryQuoteOpen(mid, COLL, P, TEN7, borrower, OpenBounds(0, 0, 0));
        assertFalse(ok, "the lens quote fails closed");
        assertEq(reason, GateRefused.selector, "and names the refusal");
    }

    // ---- the fold constraint ----

    /// @notice An armed loan on a market that names its borrower ROLLS at expiry: the home roll always admits.
    /// @dev STRUCTURAL: an armed loan's holder is the market's named one, because only that holder arms and any title move disarms.
    /// @dev So a HOME roll of an armed loan is never refused on admission; the title can change, the armed state cannot survive it.
    /// @dev The refusable case is a ROUTED roll into a foreign destination, which `AceCrossMarketRoll` owns.
    function test_ArmedLoan_OnAMarketNamingItsBorrower_Rolls() public {
        bytes32 mid = _market(borrower);
        _deposit(alice, mid, T, TOP);
        uint256 loanId = _open(borrower, mid, P, TEN7);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);

        uint256 before = read.loanCount();
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        vm.prank(mallory);
        ace.forceClose(loanId);

        assertTrue(ace.isClosed(loanId), "the expired loan resolved");
        assertEq(read.loanCount(), before + 1, "and the continuation opened the successor");
    }
}
