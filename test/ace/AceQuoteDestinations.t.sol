// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {DeleverageCrank} from "../utils/DeleverageCrank.sol";

/// @title AceQuoteDestinations
/// @notice The QUOTE leg has the same fixed-destination shape the collateral leg had.
/// @notice A deleverage residual, a close's escrow refund and a policy-door or fold migration's net-out are credited.
/// @dev Credited, so the verb completes and the claimant names the address that receives; USDC's blocklist is the instance.
/// @dev A BORROWER's own refinance pays its net out in the call, as `open` pays: a refused borrower is refused their own request.
/// @dev That borrower can still refinance at a zero net out, and an armed roll still credits, so nothing is bricked.
contract AceQuoteDestinationsTest is WarpClock, DeleverageCrank {
    Ace internal ace;
    AceReader internal read;
    MockBlockableERC20 internal quote;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal haven = address(0xDEAF); // an address the quote accepts, named at claim time

    event RevenueSweepFailed(bytes32 indexed market, address indexed to, uint256 amount, uint64 at);

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal P_REF; // par in the hub's frame; assigned in setUp
    uint256 internal constant HOLD = 3.5 days;

    uint256 internal T; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal DEEP;

    uint256 internal t0;

    function _deleverageQuote() internal view override returns (address) {
        return address(quote);
    }

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(quote), address(vault), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        quote = new MockBlockableERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T, DEEP) = (_price(0), _price(-6000));
        P_REF = _price(0); // the MARKET BIDS HERE: `px(1e18, ..)` sits a few ppb under it, so a cap set there refuses the draw
        record = new MockPersistenceRecord(address(quote), address(vault));
        record.setMinPrice(P_REF);
    }

    // ---- fixture ----

    function _base() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(quote), address(vault));
        p.record = address(record);
    }

    function _deploy(MarketParams memory p) internal returns (AceFixtures.Deployment memory d) {
        d = AceFixtures.deploy(p);
        (ace, read) = (d.ace, d.read);
        quote.mint(alice, 30_000e6);
        vm.startPrank(alice);
        quote.approve(address(ace), 30_000e6);
        ace.deposit(d.id, 15_000e6);
        ace.deposit(d.id, 15_000e6);
        vm.stopPrank();
    }

    function _open(AceFixtures.Deployment memory d) internal returns (uint256 loanId) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(d.positionManager), COLL);
        loanId = ace.open(d.id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The hub's own solvency identity for this market, with the claimant-owed pot included.
    function _booked(bytes32 mid, uint256 loans) internal view returns (uint256 booked) {
        MarketState memory s = read.marketState(mid);
        (uint256 resting,, uint256 owed) = read.poolOf(mid); // the LENDER legs; one market here, so it spans nothing else
        booked = resting + s.protocolRevenue + owed + s.quoteOwedTotal;
        for (uint256 i = 1; i <= loans; i++) {
            booked += read.feeEscrowOf(i);
        }
    }

    // ============ LoanAccounting.refundFeeEscrow: the clean close's unearned fee ============

    /// @notice A plain full repay must close when the quote refuses the party the refund is owed to.
    /// @dev This site appears in no issue: the same defect, one function deeper.
    function test_CloseClean_FeeEscrowRefundMustNotRevertWhenTheQuoteRefusesTheBorrower() public {
        AceFixtures.Deployment memory d = _deploy(_base());
        uint256 loanId = _open(d);
        quote.setBlocked(borrower, true);

        uint256 debt = read.loan(loanId).debt;
        quote.mint(borrower, debt);
        vm.startPrank(borrower);
        quote.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();

        assertTrue(read.loan(loanId).closedAt != 0, "a refused borrower can still repay their own loan");
        (, uint256 owed) = ace.owedOf(loanId, borrower);
        assertGt(owed, 0, "the unearned escrow is credited rather than pushed");
        assertEq(read.feeEscrowOf(loanId), 0, "and the escrow ledger is cleared exactly once");

        vm.prank(borrower);
        ace.claimOwed(loanId, haven);
        assertEq(quote.balanceOf(haven), owed, "the refund lands where the claimant said");
    }

    // ============ Borrower._net: the migration's net payout ============

    /// @notice A borrower's own cash-out refinance pays in the call, so a quote that refuses the borrower refuses it, as `open` does.
    /// @dev The refusal is the borrower's own request reverting; the old loan stands exactly as it was.
    function test_Refinance_ARefusedBorrowersNetPayoutRevertsAsOpenDoes() public {
        AceFixtures.Deployment memory d = _deploy(_base());
        uint256 loanId = _open(d);
        quote.setBlocked(borrower, true);

        _warpTo(t0 + HOLD);
        uint64 tenor = ace.idToMarketParams(d.id).minTenor; // stated outright; a zero would resolve to the same term
        uint256 debt = read.debtOf(loanId);
        uint256 units = read.loan(loanId).collateralUnits;
        vm.prank(borrower);
        vm.expectRevert(bytes("blocked"));
        ace.refinance(loanId, 6_000e6, tenor, OpenBounds(0, 0, 0));

        assertEq(read.loan(loanId).closedAt, 0, "the old loan is still open");
        assertEq(read.debtOf(loanId), debt, "with its debt untouched");
        assertEq(read.loan(loanId).collateralUnits, units, "and its collateral untouched");
    }

    /// @notice CONTROL: the same refused borrower still refinances when the net out is ZERO; only the cash-out is refused.
    /// @dev Zero comes from choosing the principal, never from repaying first: the blocklist refuses that borrower as a sender too.
    function test_Refinance_ARefusedBorrowerStillRollsAtAZeroNetOut() public {
        AceFixtures.Deployment memory d = _deploy(_base());
        uint256 loanId = _open(d);
        quote.setBlocked(borrower, true);

        _warpTo(t0 + HOLD);
        MarketParams memory p = ace.idToMarketParams(d.id);
        uint256 owedOld = read.debtOf(loanId) - read.earlyExitRefund(loanId);
        uint256 principal = LoanMath.principalForOwed(owedOld, p.minTenor, p.baseBps, p.minTenor);
        uint256 wallet = quote.balanceOf(borrower);
        vm.prank(borrower);
        uint256 newId = ace.refinance(loanId, principal, p.minTenor, OpenBounds(0, 0, 0));

        assertGt(read.debtOf(newId), 0, "the successor is live");
        assertTrue(read.loan(loanId).closedAt != 0, "and the old loan retired into it");
        assertEq(quote.balanceOf(borrower), wallet, "no cash moved to the refused borrower");
        (, uint256 owed) = ace.owedOf(loanId, borrower);
        assertEq(owed, 0, "and nothing was booked for a later claim");
    }

    /// @notice An ARMED roll still credits a refused borrower's net out, so a quote's refusal never stops a continuation.
    /// @dev The real net out comes from the `minDebt` floor: the borrower repaid under it, so the roll draws AT it.
    function test_PolicyRoll_NetPayoutStillCreditedWhenTheQuoteRefusesTheBorrower() public {
        MarketParams memory p = _base();
        p.minDebt = 4_000e6; // under the 4,500 loan, so a partial repay can leave the debt below the floor
        AceFixtures.Deployment memory d = _deploy(p);
        uint256 loanId = _open(d);
        _warpTo(uint256(read.loan(loanId).expiry) - 1);

        quote.mint(borrower, 1_000e6);
        vm.startPrank(borrower);
        quote.approve(address(ace), 1_000e6);
        ace.repay(loanId, 1_000e6); // under the floor by the borrower's own hand
        ace.setAutoRefinance(loanId, p.minTenor, 0, 0);
        vm.stopPrank();
        assertLt(read.debtOf(loanId), p.minDebt, "fixture: the debt sits under the floor, so the roll draws at it");
        quote.setBlocked(borrower, true);

        uint256 wallet = quote.balanceOf(borrower);
        vm.prank(alice);
        uint256 newId = ace.refinanceByPolicy(loanId);

        assertEq(read.debtOf(newId), p.minDebt, "the roll completed, at the floor");
        (, uint256 owed) = ace.owedOf(loanId, borrower);
        assertGt(owed, 0, "and the floored surplus is credited against the retiring loan");
        assertEq(quote.balanceOf(borrower), wallet, "nothing was pushed at the refused borrower");

        vm.prank(borrower);
        ace.claimOwed(loanId, haven);
        assertEq(quote.balanceOf(haven), owed, "paid out to the address the claimant names");
    }

    // ============ the global-pause form, which no chosen destination escapes ============

    /// @notice A globally paused quote cannot stop a clean close either: the refund never moves a token.
    function test_CloseClean_SurvivesAGloballyPausedQuote() public {
        AceFixtures.Deployment memory d = _deploy(_base());
        uint256 loanId = _open(d);

        uint256 debt = read.loan(loanId).debt;
        quote.mint(borrower, debt);
        vm.startPrank(borrower);
        quote.approve(address(ace), debt);
        ace.repay(loanId, debt); // the pull is INBOUND, so a recipient-keyed pause does not bite here
        vm.stopPrank();
        assertTrue(read.loan(loanId).closedAt != 0, "the close completes");

        quote.setPaused(true);
        vm.prank(borrower);
        vm.expectRevert(bytes("paused"));
        ace.claimOwed(loanId, borrower); // only the PULL waits, and only while the pause lasts

        quote.setPaused(false);
        vm.prank(borrower);
        (, uint256 paid) = ace.claimOwed(loanId, borrower);
        assertGt(paid, 0, "and pays in full once it lifts");
    }

    /// @notice A treasury the quote refuses must not brick the settlement that now carries the sweep.
    /// @dev The `catch` in `_sweepRevenue` had ZERO coverage until expiry settlement began sweeping.
    /// @dev A blocked RECIPIENT is the honest shape here: a fixed destination has no alternative.
    /// @dev The EVENT is what makes this non-vacuous: an unchanged counter also holds if no sweep ran.
    function test_Sweep_ABlockedTreasuryDoesNotBrickExpirySettlement() public {
        AceFixtures.Deployment memory d = _deploy(_base());
        uint256 loanId = _open(d);
        uint256 banked = read.protocolRevenue(d.id);
        assertGt(banked, 0, "guard: origination banked a cut for the sweep to fail on");

        quote.setBlocked(AceFixtures.TREASURY, true);
        _warpTo(uint256(read.loan(loanId).expiry) + 1);
        vm.expectEmit(true, true, false, true, address(ace));
        emit RevenueSweepFailed(d.id, AceFixtures.TREASURY, banked, uint64(_now()));
        ace.forceClose(loanId); // must NOT revert, though the sweep inside it does

        assertTrue(read.loan(loanId).closedAt != 0, "the loan settled despite the treasury refusing");
        assertEq(read.protocolRevenue(d.id), banked, "and the swallowed failure RESTORED the counter");
        assertEq(quote.balanceOf(AceFixtures.TREASURY), 0, "nothing reached the blocked destination");
    }
}
