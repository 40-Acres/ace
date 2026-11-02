// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanClosed, NotExpired} from "../../src/ace/hub/Settlement.sol";
import {ZeroPrincipal} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockRevertingRecord} from "../mocks/MockRevertingRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceExpiryRollover
/// @notice `forceClose` at expiry: it settles, pays the keeper its sliver, refuses by name before expiry and on a closed loan.
/// @notice It settles whatever the record answers, and `finalize` stays policy-blind.
/// @dev The lender names a yes-policy in setUp, so no row here settles on a missing policy: `forceClose` asks none.
contract AceExpiryRolloverTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);
    address internal mallory = address(0xBAD);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant BASE_BPS = 40;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame

    uint256 internal T; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal DEEP; // the depth the draws in this file never walk down to
    uint256 internal NEAR; // one rung under the top
    uint256 internal constant TOP = 400_000e6;
    uint256 internal constant DEEP_CASH = 200_000e6;

    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T, DEEP, NEAR) = (_price(0), _price(-6000), _price(-60));
        record = new MockPersistenceRecord(address(usdc), address(vault));

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params());
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        AceFixtures.installYesPolicy(ace, alice);

        _deposit(id, TOP);
        _deposit(id, DEEP_CASH);
        usdc.mint(borrower, 1_000_000e6);
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
        p.baseBps = BASE_BPS;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    /// @dev A twin of `record` on the same pair, seeded identically: what makes a market on the base terms hash distinct.
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
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, principal, tenor, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The debt-based in-kind sliver, mirroring `Settlement._settle`, clamped to the position.
    function _sliver(bytes32 mid, uint256 loanId) internal view returns (uint256) {
        uint256 floorPrice = read.fundingFloor(mid, loanId);
        if (floorPrice == 0) return 0;
        uint256 bty = (read.debtOf(loanId) * ace.idToMarketParams(mid).settleBountyBps * UNIT_SCALE) / (10000 * floorPrice);
        uint256 units = read.loan(loanId).collateralUnits;
        return bty < units ? bty : units;
    }

    /// @dev The sliver is CREDITED to the cranking caller, so the crank's second half is the caller pulling it.
    /// @dev Bundled here, since every assertion below measures the wallet.
    function _forceClose(address caller, uint256 loanId) internal {
        vm.prank(caller);
        ace.forceClose(loanId);
        vm.prank(caller);
        ace.claimOwed(loanId, caller);
    }

    function _rawForceClose(address caller, uint256 loanId) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(ace).call(abi.encodeWithSelector(Ace.forceClose.selector, loanId));
    }

    // R1-R3d, R8-R9b, R12, R13h, R14, R17b, R19 and R20 went with the armed fold they pinned: forceClose now only settles

    // ============ R4-R6. the settle and the guards ============

    /// @notice R4: `forceClose` at expiry settles: the position empties into the claim's pot, the keeper takes the sliver.
    function test_R4_ForceClose_AtExpiry_Settles() public {
        uint256 loanId = _open(P, TEN7);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();
        uint256 want = _sliver(id, loanId);
        uint256 rev0 = read.protocolRevenue(id);
        uint256 paid0 = usdc.balanceOf(AceFixtures.TREASURY);
        uint256 burns0 = read.marketState(id).cumulativeBackedBurns;

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "closed");
        assertEq(read.debtOf(loanId), P, "settlement does not zero the debt field");
        assertEq(pm.collateralOf(loanId), 0, "the position emptied");
        assertEq(vault.balanceOf(keeper), want, "the sliver paid as ever");
        assertGt(read.invPotOf(id, loanId), 0, "claims became the classes' pots at their own ticks");
        assertEq(read.loanCount(), n, "no new loan");
        uint256 swept = usdc.balanceOf(AceFixtures.TREASURY) - paid0;
        assertEq(read.protocolRevenue(id) + swept, rev0, "no protocol take at the loss endpoint: the sweep moved banked revenue, it did not create any");
        assertGt(read.marketState(id).cumulativeBackedBurns, burns0, "and the backed synthetic burned as ever");
    }

    /// @notice R5: before expiry the verb refuses BY NAME.
    /// @dev The guard must precede every other read or mc1_expiry_force_close.json step 4 goes red.
    function test_R5_ForceClose_RefusedBeforeExpiry_ByName() public {
        uint256 loanId = _open(P, TEN7);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);

        (bool ok, bytes memory ret) = _rawForceClose(keeper, loanId);

        assertFalse(ok, "refused");
        assertEq(bytes32(bytes4(ret)), bytes32(NotExpired.selector), "NotExpired, exactly, zero-arg");
        assertFalse(read.loan(loanId).closedAt != 0, "and the loan is untouched");
    }

    /// @notice R6: a closed loan refuses BY NAME.
    function test_R6_ForceClose_RefusedOnAClosedLoan_ByName() public {
        uint256 loanId = _open(P, TEN7);
        vm.prank(borrower);
        ace.repay(loanId, P);
        assertTrue(read.loan(loanId).closedAt != 0, "fixture: repaid clean");
        _warpTo(uint256(read.loan(loanId).expiry) + 1);

        (bool ok, bytes memory ret) = _rawForceClose(keeper, loanId);

        assertFalse(ok, "refused");
        assertEq(bytes32(bytes4(ret)), bytes32(LoanClosed.selector), "LoanClosed, exactly");
    }

    // ============ R7. finalize stays policy-blind ============

    /// @notice R7: persistent distress settles a loan through `finalize`, its lender's policy unread.
    /// @dev Pins "do not touch finalize" as an executable fact: distress is what the right is FOR.
    function test_R7_Finalize_StaysPolicyBlind_ADistressedLoanSettles() public {
        uint256 loanId = _open(P, TEN7);
        record.setBelow(true);
        _warpTo(t0 + 5 hours);
        uint256 n = read.loanCount();

        vm.prank(keeper);
        ace.finalize(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "settled");
        assertGt(read.invPotOf(id, loanId), 0, "a pot was created");
        assertEq(read.loanCount(), n, "NO new loan: the policy was never consulted");
    }

    // ============ R13. forceClose settles whatever the record answers ============

    /// @notice R13: a REVERTING record leaves an expired loan settleable: `forceClose` calls no record.
    function test_R13_ForceClose_StillSettles_WhenTheRecordReverts() public {
        MockRevertingRecord sick = new MockRevertingRecord(address(usdc), address(vault));
        MarketParams memory p = _params();
        p.record = address(sick); // the sick record is also what makes this market a distinct id
        bytes32 mid = ace.createMarket(p);
        _deposit(mid, TOP);
        uint256 loanId = _openOn(mid, P, TEN7);
        sick.setRevoked(true);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the loan settled");
        assertGt(read.debtOf(loanId), 0, "the stored debt word is kept");
        assertEq(read.loanCount(), n, "and no loan id was consumed");
    }

    /// @notice R13d: a record answering EMPTY leaves an expired loan settleable: `forceClose` settles whatever the record answers.
    function test_R13d_ForceClose_StillSettles_WhenTheRecordAnswersEmpty() public {
        (uint256 loanId, MockRevertingRecord rec) = _decayingRecordLoan();
        rec.setAnswerMode(1);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the loan settled");
        assertGt(read.debtOf(loanId), 0, "the stored debt word is kept");
        assertEq(read.loanCount(), n, "and no loan id was consumed");
    }

    /// @notice R13e: a 31-byte answer from the record is the same: `forceClose` settles whatever the record answers.
    function test_R13e_ForceClose_StillSettles_WhenTheRecordAnswersShort() public {
        (uint256 loanId, MockRevertingRecord rec) = _decayingRecordLoan();
        rec.setAnswerMode(2);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        uint256 n = read.loanCount();

        _forceClose(keeper, loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the loan settled");
        assertGt(read.debtOf(loanId), 0, "the stored debt word is kept");
        assertEq(read.loanCount(), n, "and no loan id was consumed");
    }

    // ============ R21. the loan that funded no tick -- RETIRED WITH ITS STATE ============

    /// @notice The unfunded loan is unconstructible: both a zero principal and a zero market quantum are refused.
    /// @dev Their arithmetic is pinned in `AceZeroFloorGuards.t.sol`, since the hub can no longer stage the state.
    function test_R21_TheUnfundedLoanIsUnconstructible_AtBothDoors() public {
        MarketParams memory p = _params();
        p.minPrincipal = 0;
        vm.expectRevert(bytes("debt floor zero"));
        ace.createMarket(p);

        MarketParams memory q = _params();
        q.record = _twinRecord();
        bytes32 mid = ace.createMarket(q);
        _deposit(mid, TOP);
        vault.mint(borrower, COLL); // staged OUTSIDE the expectRevert, so the mint is not what it catches
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        vm.expectRevert(ZeroPrincipal.selector);
        ace.open(mid, COLL, 0, TEN7, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    // ---- secondary fixtures ----

    /// @dev A loan whose RECORD can be made to answer badly after the fact.
    function _decayingRecordLoan() private returns (uint256 loanId, MockRevertingRecord rec) {
        rec = new MockRevertingRecord(address(usdc), address(vault));
        MarketParams memory p = _params();
        p.record = address(rec); // also what makes this market a distinct id
        bytes32 mid = ace.createMarket(p);
        _deposit(mid, TOP);
        loanId = _openOn(mid, P, TEN7);
    }
}
