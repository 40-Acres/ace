// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../../src/curator/AceVaultFlows.sol";
import {Extension, IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AceVaultHarness} from "./AceVaultHarness.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The base's own refusals, whatever terms a product hands it, the product settle doors, and the vault's own roll policy.
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

    function _ht() internal pure returns (Terms memory) {
        return Terms({units: UNITS, principal: PRINCIPAL, tenor: MIN_TENOR, minBufferWad: 0});
    }

    function _hborrow(MarketParams memory p) internal returns (uint256 loanId) {
        h.setTerms(p, _ht());
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(h), UNITS);
        loanId = h.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR), "", "");
        vm.stopPrank();
    }

    function _expectBorrowRevert(MarketParams memory p, bytes4 sel) internal {
        h.setTerms(p, _ht());
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(h), UNITS);
        BorrowRequest memory r = _req(UNITS, PRINCIPAL, MIN_TENOR);
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

    /// @notice A loan settles at once: the product door force-closes it at expiry.
    function test_ALoanSettlesAtExpiry() public {
        uint256 loanId = _hborrow(_hmp());
        _warpAtLeastTo(_expiry(loanId));
        h.settle(loanId);
        assertTrue(ace.isClosed(loanId), "settled at the expiry second");
    }

    /// @notice A loan in persisted distress settles before expiry, by finalize.
    function test_ADistressedLoanFinalizes() public {
        uint256 loanId = _hborrow(_hmp());
        record.setBelow(true);
        h.settle(loanId);
        assertTrue(ace.isClosed(loanId), "finalized on distress");
    }

    /// @notice A product door never leaves idle under the requests' hold, and leaves every other loan standing.
    /// @dev One loan settles beside another opened an hour later, so the door runs while the other's term still runs.
    /// @dev A request for every share binds all of exitable, so the requests' hold is exitable itself before and after, and nothing lends.
    function test_AProductDoorLeavesTheHoldsStanding() public {
        uint256 succ = _hborrow(_hmp());
        _warpBy(1 hours);
        uint256 other = _hborrow(_hmp());
        uint256 shares = h.balanceOf(alice);
        vm.prank(alice);
        h.requestExit(shares);
        (uint256 exitable, uint256 held) = h.holds();
        assertEq(held, exitable, "premise: the request binds all of exitable");
        uint256 idle0 = h.idle();
        Loan memory o0 = read.loan(other);
        uint256 claim0 = read.claimOf(o0.market, other);

        _warpAtLeastTo(_expiry(succ));
        assertLt(_now(), o0.expiry, "premise: the other loan's term still runs");
        h.settle(succ);
        assertTrue(ace.isClosed(succ), "premise: the door settled one loan at its expiry");
        assertTrue(ace.isLiveLoan(other), "and the other stands");
        Loan memory o1 = read.loan(other);
        assertEq(o1.debt, o0.debt, "its debt untouched");
        assertEq(o1.collateralUnits, o0.collateralUnits, "its lot untouched");
        assertEq(o1.expiry, o0.expiry, "its term untouched");
        assertEq(read.claimOf(o0.market, other), claim0, "and its claim untouched");
        assertGe(h.idle(), idle0, "and spent no idle");
        (exitable, held) = h.holds();
        assertEq(exitable, h.idle(), "exitable is all of idle");
        assertEq(held, exitable, "the request still binds all of it");
        assertEq(h.lendable(), 0, "so nothing is lendable");
    }

    /// @notice A loan somebody else already ended is tolerated, and the door goes on.
    function test_AnAlreadyEndedLoanIsTolerated() public {
        uint256 loanId = _hborrow(_hmp());
        _warpAtLeastTo(_expiry(loanId));
        ace.forceClose(loanId);
        h.settle(loanId);
        assertTrue(ace.isClosed(loanId), "still closed, no revert");
    }

    /// @notice The vault's policy refuses an extension in a market that is not this vault's, every product leg aside.
    function test_TheVaultsPolicyRefusesAForeignMarket() public {
        uint256 loanId = _borrow(MIN_TENOR);
        bytes4 answer = h.admitsExtension(_ext(loanId), "");
        assertEq(answer, bytes4(0), "not this vault's market");
    }

    /// @notice The vault's policy is ONE consent over every leg: the price, the curator's legs and no drain; any one closed refuses.
    /// @notice The hub's extension then refuses `PolicyRefused`, asked here from expiry on.
    function test_TheVaultsPolicyNeedsEveryLeg() public {
        uint256 loanId = _hborrow(_hmp());
        Extension memory e = _ext(loanId);
        assertEq(h.admitsExtension(e, ""), IRollPolicy.admitsExtension.selector, "every leg open: the vault consents");
        h.setLegs(true, false);
        assertEq(h.admitsExtension(e, ""), bytes4(0), "a closed curator leg refuses");
        h.setLegs(false, true);
        assertEq(h.admitsExtension(e, ""), bytes4(0), "a closed price leg refuses");
        h.setLegs(true, true);
        assertEq(h.admitsExtension(e, ""), IRollPolicy.admitsExtension.selector, "CONTROL: every leg reopened");
        vm.prank(curator);
        h.setDrain(true);
        assertEq(h.admitsExtension(e, ""), bytes4(0), "the drain refuses");
        _warpAtLeastTo(_expiry(loanId) - 1); // the term's last second: from expiry the hub refuses LoanMatured before it asks
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /// @dev The extension the borrower's own `extend` by `MIN_TENOR` would hand the lender's policy, its fee left out.
    function _ext(uint256 loanId) internal view returns (Extension memory e) {
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = ace.idToMarketParams(l.market);
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (l.borrower, loanId, l.borrower, l.collateralUnits, l.debt, l.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (l.expiry, l.expiry + MIN_TENOR, mp, mp);
    }
}
