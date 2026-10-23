// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {AutoPolicyDisarmed, Borrower} from "../../../src/ace/hub/Borrower.sol";
import {RollWindowOpen} from "../../../src/ace/hub/Settlement.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVaultFlows, Terms} from "../../../src/curator/AceVaultFlows.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceVaultHarness} from "./AceVaultHarness.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The core's edges a shipped product cannot reach: markets of different minDebt, a zero tenor, a room exactly the draw.
/// @dev THE DUST FLOOR: the hold's minDebt term is the largest booked since the book was last empty, and every path that empties it resets it.
/// @dev Driven through the test product, whose terms a row sets, so two markets of one collateral can carry different minDebts.
contract AceVaultHarnessEdgesTest is AceVaultRig {
    bytes32 internal constant ROOT = 0xb7a4de03362d20465bcc8b45bb9625cb4abe76f109b674085f908e1bc61c7000; // erc7201:ace.curatorvault
    uint256 internal constant LO = 10e6; // the low market's minDebt
    uint256 internal constant HI = 50e6; // the high market's minDebt
    AceVaultHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new AceVaultHarness(_cfg());
        usdc.mint(alice, LP_CASH);
        vm.startPrank(alice);
        usdc.approve(address(h), LP_CASH);
        h.deposit(LP_CASH, alice);
        vm.stopPrank();
    }

    /// @dev A vault market on the rig's collateral at `minDebt`, priced by the rig's record, paying no bounty.
    function _hmp(uint256 minDebt) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = address(h);
        p.settleBountyBps = 0;
        p.minDebt = minDebt;
    }

    function _hborrow(MarketParams memory p, uint64 tenor, bool arm) internal returns (uint256 loanId) {
        h.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: tenor, arm: arm, minBufferWad: 0}));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(h), UNITS);
        loanId = h.borrow(_req(UNITS, PRINCIPAL, tenor, arm), "", "");
        vm.stopPrank();
    }

    function _floor() internal view returns (uint256) {
        return uint256(vm.load(address(h), bytes32(uint256(ROOT) + 7)));
    }

    function _needH(uint256 loanId) internal view returns (uint256 need) {
        (need,) = h.rollOf(loanId);
    }

    function _prune(uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        h.crank(ids);
    }

    /// @dev After a path emptied the book: a new low-market record holds three needs plus the LOW minDebt, never a stale high one.
    function _assertFloorReset() internal {
        assertEq(h.rollHold(), 0, "premise: the book is empty");
        assertEq(_floor(), 0, "the dust floor reset with the empty book");
        uint256 lo = _hborrow(_hmp(LO), MIN_TENOR, true);
        assertEq(h.rollHoldNow(), 3 * _needH(lo) + LO, "a fresh record holds its own market's minDebt, not the old ceiling");
    }

    // ---- the dust floor ----

    /// @notice The floor is the largest minDebt booked, and it stays while any record stands, though the market that set it is gone.
    function test_TheFloorIsTheLargestMinDebtAndStaysWhileARecordStands() public {
        uint256 lo = _hborrow(_hmp(LO), MIN_TENOR, true);
        assertEq(_floor(), LO, "one record: its own minDebt");
        uint256 hi = _hborrow(_hmp(HI), MIN_TENOR, true);
        assertEq(_floor(), HI, "a larger minDebt lifts the floor");
        assertEq(h.rollHoldNow(), 3 * (_needH(lo) + _needH(hi)) + HI, "the hold is three needs plus the largest minDebt");
        _repayAs(borrower, hi, ace.debtOf(hi));
        _prune(hi);
        assertEq(h.rollHold(), _needH(lo), "premise: the high record left");
        assertEq(_floor(), HI, "the floor does not fall while a record stands: the ruled over-hold");
        assertEq(h.rollHoldNow(), 3 * _needH(lo) + HI, "so the low record is held at the high minDebt");
        uint256 lo2 = _hborrow(_hmp(LO), MIN_TENOR, true);
        assertEq(_floor(), HI, "a smaller minDebt never lowers it");
        lo2;
    }

    /// @notice A crank that empties the book resets the floor.
    function test_ACrankThatEmptiesTheBookResetsTheFloor() public {
        uint256 hi = _hborrow(_hmp(HI), MIN_TENOR, true);
        _repayAs(borrower, hi, ace.debtOf(hi));
        _prune(hi);
        _assertFloorReset();
    }

    /// @notice A product door whose settle empties the book resets the floor in the same call.
    function test_AProductDoorThatEmptiesTheBookResetsTheFloor() public {
        uint256 hi = _hborrow(_hmp(HI), MIN_TENOR, true);
        _warpAtLeastTo(_expiry(hi) + 2 hours);
        h.settle(hi);
        _assertFloorReset();
    }

    /// @notice A roll whose successor the carry left disarmed, on a book it empties, resets the floor.
    function test_ARollThatLeavesNoRecordResetsTheFloor() public {
        uint256 hi = _hborrow(_hmp(HI), MIN_TENOR, true);
        _toWindow(hi);
        deal(address(usdc), address(h), read.reservedOf(hi));
        uint256 newId = h.roll(hi, "");
        (, bytes4 why,) = ace.tryContinue(newId);
        assertEq(why, AutoPolicyDisarmed.selector, "premise: the carry left the successor disarmed");
        assertEq(_needH(newId), 0, "premise: nothing was recorded for it");
        assertEq(h.rollHold(), 0, "premise: the book is empty");
        assertEq(_floor(), 0, "the dust floor reset with it");
        assertEq(h.rollHoldNow(), 0, "and nothing is held");
    }

    /// @notice A product door handed a promised loan already repaid tolerates the close and still drops its record.
    function test_AProductDoorDropsTheRecordOfALoanAlreadyRepaid() public {
        uint256 id = _hborrow(_hmp(LO), MIN_TENOR, true);
        _repayAs(borrower, id, ace.debtOf(id));
        assertGt(_needH(id), 0, "premise: the record outlived the repay");
        h.settle(id);
        assertEq(_needH(id), 0, "the door dropped the record");
        assertEq(h.rollHold(), 0, "and its share of the hold");
        assertEq(_floor(), 0, "and the floor with the empty book");
    }

    /// @notice A promised loan in distress is refused by the door with the backstop's own name, before expiry as after it.
    function test_APromisedDistressedLoanIsRefusedRollWindowOpen() public {
        uint256 id = _hborrow(_hmp(LO), MIN_TENOR, true);
        record.setBelow(true);
        vm.expectRevert(RollWindowOpen.selector);
        h.settle(id);
        assertTrue(ace.isLiveLoan(id), "the door left the promised loan alone");
        assertGt(_needH(id), 0, "and its record");
    }

    // ---- the door's own edges ----

    /// @notice A cap room exactly the principal admits the draw.
    function test_ARoomExactlyThePrincipalAdmits() public {
        h.setRoom(PRINCIPAL);
        uint256 id = _hborrow(_hmp(LO), MIN_TENOR, false);
        assertTrue(ace.isLiveLoan(id), "a draw of exactly the room opens");
    }

    /// @notice A product handing the door no tenor opens at the market's shortest and arms at it: a zero arm tenor would disarm.
    function test_AZeroTenorOpensAndArmsAtTheMarketsShortest() public {
        MarketParams memory p = _hmp(LO);
        uint256 id = _hborrow(p, 0, true);
        assertEq(read.loan(id).tenor, p.minTenor, "the loan runs the market's shortest term");
        (uint64 armed,,) = read.autoPolicyOf(id);
        assertEq(armed, p.minTenor, "and its roll is armed at it");
        assertGt(read.reservedOf(id), 0, "so the hub reserved the roll");
        (uint128 need, bool funded) = h.rollOf(id);
        assertTrue(need != 0 && funded, "and the vault recorded the promise");
        _assertRecordCoversH(id);
    }

    /// @notice The door logs one `Borrowed` from the vault: the loan, its market, the caller, the draw, the measured payout and the promise.
    function test_TheBorrowedEventNamesTheLoanAndTheCaller() public {
        MarketParams memory p = _hmp(LO);
        uint256 cash0 = usdc.balanceOf(borrower);
        vm.recordLogs();
        uint256 id = _hborrow(p, MIN_TENOR, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(h) || logs[i].topics[0] != AceVaultFlows.Borrowed.selector) continue;
            seen++;
            assertEq(uint256(logs[i].topics[1]), id, "the loan");
            assertEq(logs[i].topics[2], ace.loanMarket(id), "its market");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), borrower, "the caller, not the vault");
            (uint256 units, uint256 principal, uint256 payout, bool armed) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
            assertEq(units, UNITS, "the pledge");
            assertEq(principal, PRINCIPAL, "the draw");
            assertEq(payout, usdc.balanceOf(borrower) - cash0, "the payout the caller received");
            assertTrue(armed, "and the promise");
        }
        assertEq(seen, 1, "exactly one Borrowed, from the vault");
    }

    function _assertRecordCoversH(uint256 id) internal view {
        assertGe(_needH(id), read.reservedOf(id), "law: the recorded need covers the hub's reservation");
        MarketParams memory mp = ace.idToMarketParams(ace.loanMarket(id));
        assertEq(_needH(id), Borrower.rollNeed(mp.baseBps, mp.minTenor, mp.minDebt, PRINCIPAL, mp.maxTenor), "at the market's longest term");
    }
}
