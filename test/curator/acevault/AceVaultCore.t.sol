// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {RollWindowOpen} from "../../../src/ace/hub/Settlement.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../../src/curator/AceVaultFlows.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AceVaultHarness} from "./AceVaultHarness.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The base's own refusals, whatever terms a product hands it, and the product settle doors' split by promise.
/// @dev Driven through a test product whose terms a row sets, so the core is what answers rather than a shipped product's own checks.
contract AceVaultCoreTest is AceVaultRig {
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

    function _hmp() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = address(h);
        p.settleBountyBps = 0;
    }

    function _ht(bool arm) internal pure returns (Terms memory) {
        return Terms({units: UNITS, principal: PRINCIPAL, tenor: MIN_TENOR, arm: arm, minBufferWad: 0});
    }

    function _hborrow(MarketParams memory p, bool arm) internal returns (uint256 loanId) {
        h.setTerms(p, _ht(arm));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(h), UNITS);
        loanId = h.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR, arm), "", "");
        vm.stopPrank();
    }

    function _expectBorrowRevert(MarketParams memory p, bytes4 sel) internal {
        h.setTerms(p, _ht(false));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(h), UNITS);
        BorrowRequest memory r = _req(UNITS, PRINCIPAL, MIN_TENOR, false);
        vm.expectRevert(sel);
        h.borrow(r, "", "");
        vm.stopPrank();
    }

    /// @notice A market paying any settle bounty is refused: at a zero bounty nothing strands, so every vault market takes zero.
    function test_ANonzeroBountyMarketIsRefused() public {
        MarketParams memory p = _hmp();
        p.settleBountyBps = 50;
        _expectBorrowRevert(p, AceVaultFlows.PaysSettleBounty.selector);
    }

    /// @notice A market naming another lender is not this vault's.
    function test_AnotherLendersMarketIsRefused() public {
        MarketParams memory p = _hmp();
        p.lender = stranger;
        _expectBorrowRevert(p, AceVaultFlows.NotOurLender.selector);
    }

    /// @notice A market quoting anything but the vault's asset is refused before any collateral is pulled.
    function test_AForeignQuoteIsRefusedBeforeAnyPull() public {
        MarketParams memory p = _hmp();
        p.quote = address(new MockERC20("Other Cash", "OTH", 6));
        uint256 held = coll.balanceOf(borrower);
        _expectBorrowRevert(p, AceVaultFlows.OutsideEnvelope.selector);
        assertEq(coll.balanceOf(borrower), held + UNITS, "the refusal pulled nothing");
        assertEq(coll.balanceOf(address(h)), 0, "and the vault holds none");
    }

    /// @notice The vault's own share is never collateral.
    function test_TheVaultsOwnShareIsRefused() public {
        MarketParams memory p = _hmp();
        p.collateral = address(h);
        _expectBorrowRevert(p, AceVaultFlows.SharesAreNotCollateral.selector);
    }

    /// @notice A placement past the cap room is refused by name.
    function test_APlacementPastTheRoomIsRefused() public {
        h.setRoom(PRINCIPAL - 1);
        _expectBorrowRevert(_hmp(), AceVaultFlows.OverCap.selector);
    }

    /// @notice A loan with no promise settles at once: the product door force-closes it at expiry.
    function test_AnUnpromisedLoanSettlesAtExpiry() public {
        uint256 loanId = _hborrow(_hmp(), false);
        _warpAtLeastTo(_expiry(loanId));
        h.settle(loanId);
        assertTrue(ace.isClosed(loanId), "settled at the expiry second");
    }

    /// @notice A loan with no promise and a persisted distress settles before expiry, by finalize.
    function test_AnUnpromisedDistressedLoanFinalizes() public {
        uint256 loanId = _hborrow(_hmp(), false);
        record.setBelow(true);
        h.settle(loanId);
        assertTrue(ace.isClosed(loanId), "finalized on distress");
    }

    /// @notice A promised loan settles through the door only by `settleExpired`: never at the expiry second, so the roll keeps its window.
    function test_APromisedLoanWaitsForTheBackstop() public {
        uint256 loanId = _hborrow(_hmp(), true);
        assertTrue(_fundedH(loanId), "premise: the door promised the roll");
        _warpAtLeastTo(_expiry(loanId));
        vm.expectRevert(RollWindowOpen.selector);
        h.settle(loanId);
        _warpAtLeastTo(_expiry(loanId) + 2 hours);
        h.settle(loanId);
        assertTrue(ace.isClosed(loanId), "the backstop settled it once the window ran");
    }

    /// @notice A promised loan in distress is not finalized through the door either.
    function test_APromisedLoanIsNotFinalizedThroughTheDoor() public {
        uint256 loanId = _hborrow(_hmp(), true);
        record.setBelow(true);
        vm.expectRevert(RollWindowOpen.selector);
        h.settle(loanId);
        assertFalse(ace.isClosed(loanId), "the door left the promised loan alone");
    }

    /// @notice A promised loan left unrolled past expiry: the vault's own door refuses it, while a stranger's hub fold settles it.
    function test_AStrangersFoldSettlesAPromisedLoanTheDoorRefuses() public {
        uint256 loanId = _hborrow(_hmp(), true);
        _warpAtLeastTo(_expiry(loanId));
        vm.expectRevert(RollWindowOpen.selector);
        h.settle(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the hub's fold, open to anyone, settled the promised loan");
    }

    /// @notice A product door never leaves idle under the roll hold and the requests' hold: it frees exactly the settled loan's share.
    /// @dev An unpromised successor settles beside a promised loan, so the record path runs while another hold stands.
    /// @dev A request for every share binds all of exitable, so the requests' hold is exitable itself before and after, and nothing lends.
    function test_AProductDoorLeavesTheHoldsStanding() public {
        uint256 armed = _hborrow(_hmp(), true);
        uint256 succ = _unpromisedSuccessor();
        (uint256 needA, uint256 needS) = (_needH(armed), _needH(succ));
        assertTrue(needS != 0 && !_fundedH(succ) && _fundedH(armed), "premise: an unpromised successor recorded beside a promised loan");
        uint256 shares = h.balanceOf(alice);
        vm.prank(alice);
        h.requestExit(shares);
        (uint256 exitable, uint256 held) = h.holds();
        assertEq(held, exitable, "premise: the request binds all of exitable");
        (uint256 idle0, uint256 hold0) = (h.idle(), h.rollHoldNow());

        _warpAtLeastTo(_expiry(succ));
        h.settle(succ);
        assertTrue(ace.isClosed(succ), "premise: the door settled the successor at its expiry");
        assertEq(_needH(succ), 0, "the settled record left");
        assertTrue(_needH(armed) == needA && _fundedH(armed), "and the promised one stands");
        assertEq(h.rollHold(), needA, "the hold is the promised record alone");
        assertEq(h.rollHoldNow(), hold0 - 3 * needS, "the door freed exactly the settled loan's share, the dust floor kept");
        assertGe(h.idle(), idle0, "and spent no idle");
        (exitable, held) = h.holds();
        assertEq(exitable, h.idle() - h.rollHoldNow(), "exitable is idle past the roll hold");
        assertEq(held, exitable, "the request still binds all of it, the freed share included");
        assertEq(h.lendable(), 0, "so nothing is lendable");
    }

    /// @dev A promised loan rolled while the curator's roll leg is shut: its successor is recorded without a promise.
    function _unpromisedSuccessor() internal returns (uint256 succ) {
        uint256 rolled = _hborrow(_hmp(), true);
        h.setLegs(true, false);
        _toWindow(rolled);
        succ = h.roll(rolled, "");
        h.setLegs(true, true);
    }

    /// @notice A loan somebody else already ended is tolerated, and the door goes on.
    function test_AnAlreadyEndedLoanIsTolerated() public {
        uint256 loanId = _hborrow(_hmp(), false);
        _warpAtLeastTo(_expiry(loanId));
        ace.forceClose(loanId);
        h.settle(loanId);
        assertTrue(ace.isClosed(loanId), "still closed, no revert");
    }

    /// @notice `wouldLend` answers false twice for a market that is not this vault's.
    function test_WouldLendRefusesAForeignMarket() public {
        uint256 loanId = _borrow(MIN_TENOR, true);
        (bool price, bool rearm) = h.wouldLend(_mid(loanId));
        assertFalse(price, "not this vault's market");
        assertFalse(rearm, "not this vault's market");
    }

    /// @notice `wouldLend` reports the two legs the verbs gate on: the price, and the re-arm under the curator's legs and the drain.
    function test_WouldLendReportsBothLegs() public {
        uint256 loanId = _hborrow(_hmp(), true);
        bytes32 m = _mid(loanId);
        (bool price, bool rearm) = h.wouldLend(m);
        assertTrue(price && rearm, "both legs open");
        h.setLegs(true, false);
        (price, rearm) = h.wouldLend(m);
        assertTrue(price && !rearm, "a closed curator leg stops only the re-arm");
        h.setLegs(true, true);
        vm.prank(curator);
        h.setDrain(true);
        (price, rearm) = h.wouldLend(m);
        assertTrue(price && !rearm, "the drain stops only the re-arm");
        h.setLegs(false, true);
        (price, rearm) = h.wouldLend(m);
        assertTrue(!price && !rearm, "a closed price leg stops both");
        _toWindow(loanId);
        vm.expectRevert(AceVault.NotLending.selector);
        h.roll(loanId, "");
    }

    function _fundedH(uint256 loanId) internal view returns (bool funded) {
        (, funded) = h.rollOf(loanId);
    }

    function _needH(uint256 loanId) internal view returns (uint256 need) {
        (need,) = h.rollOf(loanId);
    }
}
