// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens, TornRead} from "../../src/ace/lens/AceLens.sol";
import {ArmNeedsRecord, BufferOutOfRange, RecordMismatch, RollUnbacked, RoutingNeedsBuffer, TenorOutOfRange} from "../../src/ace/hub/Borrower.sol";
import {MarketInit} from "../../src/ace/hub/MarketInit.sol";
import {MarketParams, MigrateArgs, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockHookERC20} from "../mocks/MockHookERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceRecordlessCannotArm
/// @notice A RECORDLESS MARKET CANNOT ARM: both writers of a loan's auto policy refuse `ArmNeedsRecord` there.
/// @notice `arm` refuses before any other policy rail; a borrower's own refinance of an ARMED loan into one refuses before the cash test.
/// @notice A keeper's route into one never gets that far: `_compatLeg` answers `RecordMismatch` first.
/// @dev Every refusal row carries a record-backed control, so the refusal is attributable to the missing record and nothing else.
contract AceRecordlessCannotArmTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal home; // record-backed: the class that may arm
    bytes32 internal bare; // recordless, otherwise the same pair, lender and terms

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0BB);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN28 = 28 days;
    uint256 internal constant P = 50_000e6;
    uint256 internal constant NP = P + 1_000e6; // a refinance principal that retires the old debt and its fee
    uint256 internal constant UNITS = 100_000e18;

    event AutoPolicySet(uint256 indexed id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(AceFixtures.px(1.1e18, address(usdc), address(coll)));
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(address(rec), alice));
        (ace, pm, read, home) = (d.ace, d.positionManager, d.read, d.id);
        bare = ace.createMarket(_params(address(0), alice));
        lens = new AceLens(address(ace));
    }

    function _params(address record, address lender) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = record;
        p.lender = lender;
        p.baseBps = 40;
        p.minTenor = TEN7;
        p.maxTenor = TEN28;
        p.settleBountyBps = 50;
        p.minCoverageWad = 1.4e18;
    }

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _openIn(bytes32 mid, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(mid, UNITS, principal, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _armAs(uint256 loanId, uint64 tenor, uint16 buf, uint16 fee, bytes4 want) internal {
        vm.prank(borrower);
        vm.expectRevert(want);
        ace.setAutoRefinance(loanId, tenor, buf, fee);
    }

    function _tenorOf(uint256 loanId) internal view returns (uint64 tenor) {
        (tenor,,) = read.autoPolicyOf(loanId);
    }

    /* ================================================================= */
    /*  arm: the first writer                                             */
    /* ================================================================= */

    /// @notice REVERT: arming in a recordless market refuses `ArmNeedsRecord`, AHEAD of a bad buffer, an unconsented route or an off-grid tenor.
    /// @dev The control runs the same bad inputs in the record-backed market, where each answers its own rail.
    function testRevert_ArmRefusesARecordlessMarketAheadOfEveryOtherRail() public {
        _deposit(bare, alice, 2 * P);
        _deposit(home, alice, 2 * P);
        uint256 inBare = _openIn(bare, P);
        uint256 inHome = _openIn(home, P);

        _armAs(inBare, TEN7, 0, 0, ArmNeedsRecord.selector);
        _armAs(inBare, TEN7, 10_000, 0, ArmNeedsRecord.selector);
        _armAs(inBare, TEN7, 0, 100, ArmNeedsRecord.selector);
        _armAs(inBare, TEN28 + 1, 0, 0, ArmNeedsRecord.selector);

        _armAs(inHome, TEN7, 10_000, 0, BufferOutOfRange.selector);
        _armAs(inHome, TEN7, 0, 100, RoutingNeedsBuffer.selector);
        _armAs(inHome, TEN28 + 1, 0, 0, TenorOutOfRange.selector);
        vm.prank(borrower);
        ace.setAutoRefinance(inHome, TEN7, 0, 0);
        assertGt(read.reservedOf(inHome), 0, "CONTROL: the record-backed twin arms and reserves");
        assertEq(_tenorOf(inBare), 0, "the recordless loan carries no policy");
        assertEq(read.rollReserve(bare), 0, "and its market reserves nothing");
    }

    /// @notice A DISARM LANDS in a recordless market: tenor zero writes nothing to reserve, so there is nothing to refuse.
    function test_ADisarmLandsInARecordlessMarket() public {
        _deposit(bare, alice, 2 * P);
        uint256 loanId = _openIn(bare, P);
        vm.expectEmit(true, false, false, true, address(ace));
        emit AutoPolicySet(loanId, 0, 0, 0);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, 0, 0, 0);
        assertEq(_tenorOf(loanId), 0, "still disarmed");
        assertEq(read.rollReserve(bare), 0, "and nothing is reserved");
    }

    /// @notice A record-backed market whose lender rested exactly the draw still refuses for want of CASH, never for the record.
    /// @dev The pawn shape with a record: the counterpart to the precedence rows, from the side where the record check passes.
    function testRevert_ARecordBackedMarketRestingExactlyTheDrawRefusesRollUnbacked() public {
        bytes32 snug = ace.createMarket(_params(address(rec), bob));
        _deposit(snug, bob, P);
        uint256 loanId = _openIn(snug, P);
        assertEq(ace.restingOf(snug), 0, "PREMISE: the draw took every resting atom");
        _armAs(loanId, TEN7, 0, 0, RollUnbacked.selector);
    }

    /* ================================================================= */
    /*  _carry: the second writer                                         */
    /* ================================================================= */

    /// @notice REVERT: a borrower's own refinance of an ARMED loan into a recordless market refuses `ArmNeedsRecord`.
    /// @notice Disarming in the same multicall is the way through, and the successor lands unarmed.
    function testRevert_AnArmedLoansStrictRefinanceIntoARecordlessMarketRefuses() public {
        _deposit(home, alice, 2 * P);
        _deposit(bare, alice, 2 * P);
        uint256 loanId = _openIn(home, P);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
        MigrateArgs memory m = MigrateArgs(loanId, bare, NP, TEN7, OpenBounds(0, 0, 0), 0, address(0));

        vm.prank(borrower);
        vm.expectRevert(ArmNeedsRecord.selector);
        ace.refinanceTo(m);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.setAutoRefinance, (loanId, 0, 0, 0));
        calls[1] = abi.encodeCall(Ace.refinanceTo, (m));
        vm.prank(borrower);
        ace.multicall(calls);
        uint256 newId = read.loanCount();
        assertEq(read.loan(newId).market, bare, "the refinance landed in the recordless market");
        assertEq(read.debtOf(newId), NP, "at the asked principal");
        assertEq(_tenorOf(newId), 0, "unarmed, as the borrower chose");
        assertEq(read.rollReserve(bare), 0, "with nothing reserved in the destination");
        assertEq(read.rollReserve(home), 0, "and the source's reservation freed");
    }

    /// @notice CONTROL for the row above: the same armed loan's strict refinance into a RECORD-BACKED twin, funded alike, lands armed.
    /// @dev The twin differs from `bare` by its record and its lender, and no compatibility rule reads the lender.
    function test_ControlAnArmedLoansStrictRefinanceIntoARecordBackedTwinStaysArmed() public {
        _deposit(home, alice, 2 * P);
        bytes32 twin = ace.createMarket(_params(address(rec), bob));
        _deposit(twin, bob, 2 * P);
        uint256 loanId = _openIn(home, P);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);

        vm.prank(borrower);
        ace.refinanceTo(MigrateArgs(loanId, twin, NP, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
        uint256 newId = read.loanCount();
        assertEq(read.loan(newId).market, twin, "the refinance landed in the twin");
        assertEq(_tenorOf(newId), TEN7, "and the policy rode across");
        assertGt(read.reservedOf(newId), 0, "re-reserved in the destination");
        assertEq(read.rollReserve(twin), read.reservedOf(newId), "as the twin's whole reserve");
        assertEq(read.rollReserve(home), 0, "and the source's reservation freed");
    }

    /// @notice PRECEDENCE: a recordless destination whose cash cannot hold the roll still answers `ArmNeedsRecord`, not `RollUnbacked`.
    /// @dev The permanent refusal comes first: `RollUnbacked` is retryable, and a market that can never take the policy must not say so.
    /// @dev The control is a record-backed destination funded the same way, which answers `RollUnbacked`.
    function testRevert_ARecordlessDestinationOutranksItsOwnCashShortfall() public {
        _deposit(home, alice, 2 * P);
        _deposit(bare, alice, NP); // the draw takes every atom, leaving none to reserve the successor's roll
        bytes32 twin = ace.createMarket(_params(address(rec), bob));
        _deposit(twin, bob, NP);
        uint256 loanId = _openIn(home, P);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);

        vm.prank(borrower);
        vm.expectRevert(ArmNeedsRecord.selector);
        ace.refinanceTo(MigrateArgs(loanId, bare, NP, TEN7, OpenBounds(0, 0, 0), 0, address(0)));

        vm.prank(borrower);
        vm.expectRevert(RollUnbacked.selector);
        ace.refinanceTo(MigrateArgs(loanId, twin, NP, TEN7, OpenBounds(0, 0, 0), 0, address(0)));
    }

    /// @notice A KEEPER'S ROUTE into a recordless market answers `RecordMismatch`, on the view and on the verb.
    /// @dev An armed loan is record-backed, so a recordless destination is always another record; the carry's own refusal is never reached.
    function test_AKeeperRouteIntoARecordlessMarketAnswersRecordMismatch() public {
        _deposit(home, alice, 2 * P);
        _deposit(bare, alice, 2 * P);
        uint256 loanId = _openIn(home, P);
        vm.prank(borrower);
        ace.setAutoRefinance(loanId, TEN7, 2000, 100);
        uint64 w = MarketInit.autoRefinanceWindow(TEN7);
        _warpTo(uint256(read.loan(loanId).expiry) - w / 4);

        (bool ok, bytes4 why,) = ace.tryContinueTo(loanId, bare);
        assertFalse(ok, "the route is refused");
        assertEq(why, RecordMismatch.selector, "by the record leg");
        vm.prank(keeper);
        vm.expectRevert(RecordMismatch.selector);
        ace.refinanceByPolicyTo(loanId, bare);
        (bool okHome,,) = ace.tryContinue(loanId);
        assertTrue(okHome, "CONTROL: the home roll is admissible at the same block");
    }

    /* ================================================================= */
    /*  the lens agrees                                                   */
    /* ================================================================= */

    /// @notice `armable` answers `(false, 0)` in a recordless market, on the grid and with cash to spare.
    /// @dev The zero is EXPLICIT: a need computed before the record check must not leak out as a quote.
    function test_ArmableAnswersFalseAndZeroInARecordlessMarket() public {
        _deposit(bare, alice, 2 * P);
        _deposit(home, alice, 2 * P);
        uint256 inBare = _openIn(bare, P);
        uint256 inHome = _openIn(home, P);
        (bool ok, uint256 q) = lens.armable(inBare, TEN7);
        assertFalse(ok, "a recordless loan is not armable");
        assertEq(q, 0, "and quotes no reservation");
        (bool okHome, uint256 qHome) = lens.armable(inHome, TEN7);
        assertTrue(okHome, "CONTROL: the record-backed twin is armable");
        assertGt(qHome, 0, "and quotes its need");
        vm.prank(borrower);
        ace.setAutoRefinance(inHome, TEN7, 0, 0);
        assertEq(read.reservedOf(inHome), qHome, "CONTROL: and the hub reserves exactly the need the lens quoted");
    }
}

/// @title AceRecordlessArmableGuard
/// @notice `armable` still refuses `TornRead` mid-body in a RECORDLESS market: the record check runs after the guarded read.
/// @dev The probe is a quote token's receive hook on the lender's own withdraw, which runs while the hub's guard is held.
contract AceRecordlessArmableGuardTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockHookERC20 internal quote;
    MockERC20 internal coll;
    bytes32 internal id;
    uint256 internal loanId;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    uint256 internal constant P = 50_000e6;
    uint256 internal constant UNITS = 100_000e18;

    bytes4 internal seen; // what `armable` answered mid-body: its revert selector, or zero when it answered
    bool internal probed;

    function setUp() public {
        _warpTo(1_000_000);
        quote = new MockHookERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        p.lender = alice;
        p.baseBps = 40;
        p.minTenor = 7 days;
        p.maxTenor = 7 days;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        quote.mint(alice, 2 * P);
        vm.startPrank(alice);
        quote.approve(address(ace), 2 * P);
        ace.deposit(id, 2 * P);
        vm.stopPrank();
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, 7 days, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The receive hook: `armable` asked while the hub's withdraw body still holds its guard.
    function onTokenReceived(address, uint256) external {
        probed = true;
        try lens.armable(loanId, 7 days) returns (bool, uint256) {}
        catch (bytes memory e) {
            seen = bytes4(e);
        }
    }

    /// @notice Mid-body `armable` refuses `TornRead` though the market is recordless; once the body returns it answers `(false, 0)`.
    function test_TheRecordlessArmableReadStillRefusesAMidBodyRead() public {
        quote.setHookTarget(address(this));
        vm.prank(alice);
        ace.withdraw(id, 1_000e6, address(this), 0);
        assertTrue(probed, "fixture: the hook ran inside the withdraw");
        assertEq(seen, TornRead.selector, "armable answered mid-body in a recordless market");
        (bool ok, uint256 q) = lens.armable(loanId, 7 days);
        assertTrue(!ok && q == 0, "and after the body it answers, refusing");
    }
}
