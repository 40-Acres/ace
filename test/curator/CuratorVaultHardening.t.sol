// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {GateRefused} from "../../src/ace/hub/Lender.sol";

/// @title CuratorVaultHardening
/// @notice The rails the first pass left unpinned: the donation seam, both workout halves, and the exit guards.
contract CuratorVaultHardeningTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant DUST = 10e6; // the market's own `minDebt`; a paydown may legally land under it
    address internal attacker = address(0xBAD);
    address internal carol = address(0xCAC0);

    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    // ---- shared rigs ----

    /// @dev One vault, one door loan, booked and ready; the lot is always zero.
    function _funded(CuratorVault v) internal returns (uint256 loanId, uint256 lot) {
        _lpDeposit(v, alice, SEED);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, lot);
    }

    // ---- [LR-A]: the donation seam is CLOSED AT THE GATE, not defended against in the book ----


    /// @dev THE REPLACEMENT FOR THE WHOLE DONATION FAMILY, and it is a deletion rather than a defence.
    /// @dev A donated unit needed a co-funder of the vault's OWN market. Sole tenancy admits exactly one
    /// @dev lender, named in the market's own id preimage, so no third party can ever hold a claim to give.
    /// @dev The old tests defended the cost book against a gift; sole tenancy removes the gift instead.
    /// @dev IT IS NOW READ OFF THE CLAIM LEDGER, since the receipt tokens a donation needed are deleted too.
    function test_LrA_NoStrangerCanEverHoldAClaimOnThisVaultsMarket() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);

        usdc.mint(attacker, 4_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(ace), 4_000e6);
        /// @dev BY NAME, and the name is the DOOR'S: `restRefusal` maps a foreign owner onto the gate arm,
        /// @dev so `GateRefused` is what a depositor sees. `NotTheLender` is the backstop inside `bookCash`.
        vm.expectRevert(GateRefused.selector);
        ace.deposit(mid, 4_000e6);
        vm.stopPrank();

        assertEq(ace.idToMarketParams(mid).lender, address(v), "the market names the vault and nobody else");
        assertEq(usdc.balanceOf(attacker), 4_000e6, "and the attacker's money never left their wallet");

        _crank(v, loanId, T2, 0);
        assertEq(read.claimOf(mid, loanId), DRAW, "the whole claim is the vault's own");
        assertEq(v.grossNav(), _hubTruthNav(v), "so the aggregate the vault reads is wholly its own");
    }

    // ---- [LR-I]: the title outlives the loss that was struck against it ----

    /// @dev The exit takes no title, so the vault keeps a written-off position until its POT empties.
    /// @dev The loss socialized at settlement; the recovery is later quote that lifts NAV back.
    /// @dev AN LP EXIT IS A CASH EVENT AND NOTHING MORE: the pot is what the exiter cannot reach, and that is what this reads.
    /// @dev Entry is shut while the sale's recovery vests, the price net of it still deep or the pile large, and reopens once it has.
    function test_Loss_SocializesButTheTitleAndItsRecoverySurvive() public {
        CuratorVault v = _newVault(0);
        (uint256 loanId,) = _funded(v);
        _finalize(loanId);
        _crankAll(v);
        assertEq(_carriedClasses(v), 1, "impaired, and the vault still holds the position");
        uint256 navAfterLoss = v.totalAssets();

        uint256 pot = read.invPotOf(mid, loanId);
        _redeemFrac(v, alice, 1, 2);
        assertEq(read.invPotOf(mid, loanId), pot, "the exit took no title, so the stayers keep the recovery");

        _buyPot(keeper, loanId, 1_000_000e6); // empty the pot, which is what leaves the position with nothing to give
        _crankAll(v);
        _crankAll(v);

        assertEq(lens.claimable(address(v), v.asset()), 0, "a spent pot leaves the vault nothing to collect");
        assertGt(v.grossNav(), navAfterLoss, "the sale lifted NAV back, and the aggregates carry it");
        assertEq(v.maxDeposit(bob), 0, "entry stays shut while the recovery vests");
        _warpBy(VEST_W);
        assertEq(v.maxDeposit(bob), type(uint256).max, "entry reopens once the recovery has vested");
        assertTrue(lens.loan(loanId).closedAt != 0, "and the loan behind it really did settle");
    }


    // ---- a zero write-off must not retire a position whose pot is still live ----

    /// @dev Repay almost everything, then settle: the refund covers the sliver, so the loss is ~nothing.
    /// @dev That reaches the zero-loss settlement with real title over a real pot, not a spent class.
    function _sliverThenSettle(CuratorVault v) internal returns (uint256 loanId, uint256 pot, uint256 lost) {
        (loanId,) = _funded(v);
        _repay(loanId, DRAW - DUST);
        _crankAll(v);

        uint256 grossBefore = v.grossNav();
        _finalize(loanId);
        lost = grossBefore > v.grossNav() ? grossBefore - v.grossNav() : 0;
        /// @dev LET THE REPAY'S DEFERRAL MATURE before the settle crank, so the pile below is stamped clean
        /// @dev The one-wei strand the caller pins is the HUB'S double floor, and only a pile whose maturity
        /// @dev sits exactly one window ahead lets `_pendingUnvested` cancel `unvested` to the wei around it
        /// @dev A live pile leaves a blended maturity instead, and the ladder's own ceil adds a second wei
        _warpBy(VEST_W + 1);
        /// @dev And past the ask hold, which the window above already clears; stated so the leg names its own gate
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        _crankAll(v);
        pot = lens.invPotOf(mid, loanId);
    }

    /// @dev The settlement cost the vault almost nothing, but the class still holds a pot it can claim.
    /// @dev What must survive is the TITLE and the route back to the pot, which is the crank.
    function test_WriteOff_AZeroWriteOffDoesNotRetireALivePot() public {
        CuratorVault v = _newVault(0);
        (uint256 loanId, uint256 pot, uint256 lost) = _sliverThenSettle(v);

        assertLe(lost, DUST, "the cash beat all but the sliver, so almost nothing socialized");
        assertGt(pot, 0, "yet the class really did take title to collateral");
        assertGt(read.invPotOf(mid, loanId), 0, "and the vault's claim on that collateral is still standing");
    }

    /// @dev The consequence, in money: proceeds that arrive after the pass must still reach the counters.
    /// @dev The vault's balance is what every exit pays from, so banking them there is what makes them deliverable.
    /// @dev THE D1 FLOORING STRAND IS GONE, and it is pinned at ZERO rather than dropped: the sale credited
    /// @dev `unitOwed` in full while `qIndex` floored twice on the way out, so the class recognized ONE WEI
    /// @dev more than its holder could claim. There is no per-(loan, tick) index to floor through -- the
    /// @dev credit lands in the lender's pool directly -- so the second floor has nothing to round. A 1 here
    /// @dev would mean the strand came back through some other divisor, and should say so.
    function test_WriteOff_APotSoldAfterAZeroWriteOffStillReachesNav() public {
        CuratorVault v = _newVault(0);
        (uint256 loanId,,) = _sliverThenSettle(v);
        assertGt(_buyPot(keeper, loanId, 20_000e6), 0, "a keeper buys the pot at the hub's own ask");

        uint256 proceeds = lens.claimable(address(v), v.asset());
        assertGt(proceeds, 0, "the proceeds are owed to the vault's pool");
        uint256 idleBefore = v.idle();
        uint256 grossBefore = v.grossNav(); // the sale already landed here: the hub credited the vault's pool
        uint256 navBefore = v.totalAssets() + v.unvested(); // gross of the ladder: the subject is the AMOUNT
        assertGt(grossBefore, navBefore, "and it is in the aggregate before anyone has synced");
        _crankAll(v);

        assertEq(v.idle() - idleBefore, proceeds, "a later crank brings them home as cash, to the wei");
        assertEq(v.grossNav(), grossBefore, "banking them valued nothing: the crank moves cash, not marks");
        assertEq(grossBefore - navBefore - proceeds, 0, "the flooring strand is gone: there is no second floor left to round");
        assertEq(v.totalAssets() + v.unvested(), grossBefore, "and they carry to every share alike, in full");
    }

    /// @dev The sibling fixture with the vest pile LEFT LIVE: it rests past the ask hold and no further.
    /// @dev An hour of hold inside a one-day window is reachable in production, so this state is too.
    /// @dev SEPARATE HELPER on purpose: two green tests depend on `_sliverThenSettle` maturing the pile.
    function _sliverThenSettleLivePile(CuratorVault v) internal returns (uint256 loanId) {
        (loanId,) = _funded(v);
        _repay(loanId, DRAW - DUST);
        _crankAll(v);
        _finalize(loanId);
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        _crankAll(v);
    }

    /// @notice THE SIBLING, one line apart: the same sale against a LIVE vest pile instead of a matured one.
    /// @notice The hold is an hour and the window is a day, so a partly-vested seller is the ordinary case.
    /// @dev THE STRAND IS DERIVED HERE, NOT OBSERVED, and it separates into two independently named wei.
    /// @dev HUB WEI: the sale credits `unitOwed` in full while `qIndex` floors twice, so the class recognizes
    /// @dev exactly one wei more than its holder can claim. That is the sibling's subject and it is EXACT.
    /// @dev VEST WEI: `_pendingUnvested` re-grosses the rise, and `_grossed` then `_readVest` both CEIL.
    /// @dev `_grossed`'s own contract is that the round trip returns the pile "or one wei above it": 0 or 1.
    /// @dev It returns exactly the pile only when the maturity sits one full window out, which is a MATURED pile.
    /// @dev A live pile blends to `mat - now < VEST_WINDOW`, so the two ceils no longer cancel and the wei can land.
    /// @dev The NAV mark is the gross the crank above synced at, and nothing moves gross before the sale.
    /// @dev So `grossAfter - grossPre` IS the `g - m` rise the deferral arithmetic reads, with nothing in between.
    /// @dev The vest wei lands on 1 under this fixture, making the whole strand 2 against the matured sibling's 1.
    /// @dev It is asserted as the DERIVED CEILING and not as that 1: which of 0 or 1 a given round trip lands on
    /// @dev falls out of the specific numbers, so an equality here would be a measured constant wearing a proof.
    function test_WriteOff_APotSoldIntoALiveVestPileStrandsTheHubWeiAndAtMostOneMore() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _sliverThenSettleLivePile(v);
        assertGt(v.unvested(), 0, "PREMISE: the pile is still LIVE, or this is just the matured sibling again");

        uint256 grossPre = v.grossNav(); // == the NAV mark: the crank synced here and nothing has moved gross since
        assertGt(_buyPot(keeper, loanId, 20_000e6), 0, "a keeper buys the pot at the hub's own ask");

        uint256 proceeds = lens.claimable(address(v), v.asset());
        assertGt(proceeds, 0, "the proceeds are owed to the vault's pool");
        uint256 idleBefore = v.idle();
        uint256 grossAfter = v.grossNav();
        uint256 navBefore = v.totalAssets() + v.unvested(); // gross of the ladder: the subject is the AMOUNT
        assertGt(grossAfter, navBefore, "and it is in the aggregate before anyone has synced");

        uint256 hubWei = (grossAfter - grossPre) - proceeds;
        uint256 vestWei = (grossAfter - navBefore - proceeds) - hubWei;
        /// @dev WAS 1: the hub's own double floor, `unitOwed` credited whole against a `qIndex` that floored
        /// @dev twice on the way out. The per-(loan, tick) index is deleted and the credit lands in the
        /// @dev lender's pool directly, so the second floor is gone and the hub strands nothing.
        assertEq(hubWei, 0, "HUB: the class recognizes exactly what its holder can claim");
        assertLe(vestWei, 1, "VEST: one ceil round trip through `_grossed` may add a wei, and can never add two");
        _crankAll(v);

        assertEq(v.idle() - idleBefore, proceeds, "a later crank brings them home as cash, to the wei");
        assertEq(v.grossNav(), grossAfter, "banking them valued nothing: the crank moves cash, not marks");
    }

    // ---- no price read on the entry path either ----

    /// @dev Arm every price source the vault could reach, then run the legs T12 leaves outside its window: the crank, the fee and entry.
    /// @dev The door reads the row's record by design, so the loan opens BEFORE the record is armed; the hub reads it too.
    function test_Vault_ReadsNoPriceOnTheEntryAndRegistrationPath() public {
        vm.mockCallRevert(address(lens), abi.encodeWithSelector(AceLens.inventoryMark.selector), bytes("MARK_READ"));
        CuratorVault v = _newVault(2000);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);

        vm.mockCallRevert(address(record), bytes(""), bytes("RECORD_READ"));
        _crank(v, loanId, T2, 0);
        /// @dev The loan is LIVE, so what the crank ran against is its CLAIM.
        assertGt(read.claimOf(mid, loanId), 0, "the crank ran with every price source armed");
        v.collectFee();
        _crank(v, loanId, T2, 0);
        assertGt(v.totalAssets(), 0, "and so did the fee and the second crank");
        assertGt(_lpDeposit(v, bob, 1_000e6), 0, "and an entry");
        vm.clearMockedCalls();
    }

    // ---- the exit's liquidity guard and the withdraw verb ----

    /// @dev The cash exit is bounded by exitable cash, and asking past it is OZ's named error, not a panic.
    /// @dev One share is left behind, so the refusal is the cash bound's and never the last-out rule's.
    function testRevert_Redeem_PastTheFreePotIsRefused() public {
        CuratorVault v = _newVault(0);
        _funded(v);
        assertLt(v.idle(), v.totalAssets(), "the draw is out at cost, so idle cannot clear the whole holding");

        uint256 shares = v.balanceOf(alice) - 1;
        uint256 max = v.maxRedeem(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, shares, max));
        v.redeem(shares, alice, alice);
    }

    /// @dev Same bound on the assets-denominated verb, one wei past what maxWithdraw quotes.
    /// @dev The open's own gain vests first, so the last-out rule leaves the sole holder's view at exitable cash.
    function testRevert_Withdraw_OneWeiPastTheFreePotIsRefused() public {
        CuratorVault v = _newVault(0);
        _funded(v);
        _warpBy(VEST_W);
        v.crank();
        uint256 cap = v.maxWithdraw(alice);
        (uint256 exitable, uint256 held) = v.holds();
        assertEq(cap, exitable - held, "the quote is exitable cash less the requests' hold, which binds a sole holder of a lent vault");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, cap + 1, cap));
        v.withdraw(cap + 1, alice, alice);
    }

    /// @dev The withdraw verb pays the assets asked to the wei, and moves no title doing it.
    function test_Withdraw_PaysTheAssetsAskedExactly() public {
        CuratorVault v = _newVault(0);
        (uint256 loanId,) = _funded(v);
        _lpDeposit(v, bob, 2_000e6);
        _finalize(loanId);
        _crankAll(v);
        assertEq(_carriedClasses(v), 1, "impaired, so there is title that must NOT move");

        uint256 unitsBefore = read.invPotOf(mid, loanId);
        uint256 want = 500e6;
        uint256 quoted = v.previewWithdraw(want);
        uint256 cashBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        uint256 burned = v.withdraw(want, bob, bob); // the instant exit, at the impaired price

        assertEq(burned, quoted, "the shares burned are what previewWithdraw quotes");
        assertEq(usdc.balanceOf(bob) - cashBefore, want, "and the assets asked for arrived exactly");
        assertEq(read.invPotOf(mid, loanId), unitsBefore, "and none taken from the stayers");
    }

    /// @dev A delegated exit spends the ERC-20 allowance; the receiver may differ from the owner throughout.
    function test_Exit_DelegatedRedeemSpendsTheAllowance() public {
        CuratorVault v = _newVault(0);
        (uint256 loanId,) = _funded(v);
        _lpDeposit(v, bob, 2_000e6);
        _finalize(loanId);
        _crankAll(v);

        uint256 shares = v.balanceOf(bob) / 2;
        vm.prank(bob);
        v.approve(carol, shares);

        uint256 unitsBefore = _unitsHeld(v);
        vm.prank(carol);
        uint256 got = v.redeem(shares, carol, bob); // the instant exit, at the impaired price

        assertGt(got, 0, "the delegate was paid");
        assertEq(usdc.balanceOf(carol), got, "to the receiver she named, not to the owner");
        assertEq(_unitsHeld(v), unitsBefore, "and no title followed the cash: the pot is unmoved");
        assertEq(v.allowance(bob, carol), 0, "the allowance was spent exactly");
    }

    /// @dev Without an allowance the delegate is refused; the exit is not a public drain on anyone's shares.
    function testRevert_Exit_DelegatedRedeemWithoutAllowance() public {
        CuratorVault v = _newVault(0);
        _funded(v);
        _lpDeposit(v, bob, 2_000e6);

        uint256 shares = v.balanceOf(bob) / 2;
        vm.prank(carol);
        vm.expectRevert();
        v.redeem(shares, carol, bob);
    }

    // ---- the targeted crank ----

    /// @dev The crank is NAV-NEUTRAL: it moves what the hub owes the vault into the vault's own balance.
    /// @dev Was `..._ValuesTheNamedPositionLikeALap`; there is no valuation left for a lap to do.
    /// @dev The borrower repays the hub; the credit waits in the vault's pool until the crank brings it home as cash.
    function test_Crank_MovesQuoteIntoIdleAndIsNavNeutral() public {
        CuratorVault v = _newVault(0);
        (uint256 loanId, uint256 lot) = _funded(v);
        _repay(loanId, 2_000e6);

        uint256 idleBefore = v.idle();
        uint256 grossBefore = v.grossNav();
        uint256 owed = lens.claimable(address(v), v.asset());
        assertGt(owed, 0, "PREMISE: the repayment is owed to the vault at the hub");
        _crank(v, loanId, T2, lot);

        assertEq(v.idle() - idleBefore, owed, "the crank moved what the vault was owed into its balance, to the wei");
        assertEq(lens.claimable(address(v), v.asset()), 0, "leaving nothing owed");
        assertEq(v.grossNav(), grossBefore, "and gross did not move: what left the hub's pool arrived as cash");
        assertEq(v.grossNav(), _hubTruthNav(v), "with the second read path agreeing to the wei");
    }


    // ---- conservation over a whole impairment ----

    /// @dev One deep vault, so the interleavings below all draw from the same shape without exhausting its cash mid-fuzz.
    function _feeRig(uint16 bps) internal returns (CuratorVault v) {
        v = _newVault(bps);
        _lpDeposit(v, alice, 32_020e6);
    }

    function _impair(CuratorVault v) internal returns (uint256 loanId) {
        loanId = _open(10e6);
        _crankAllTicks(v, loanId, 0);
        _finalize(loanId);
        _crankAll(v);
    }

    /// @dev The wait is load-bearing: the ladder defers recognition, and this driver is about the AMOUNT.
    function _growth(CuratorVault v) internal {
        uint256 loanId = _open(6_000e6);
        _crankAllTicks(v, loanId, 0);
        _repay(loanId, 6_000e6 * 2);
        _crankAndRecognize(v);
        v.collectFee();
    }

    /// @dev The impaired loan's remaining inventory pot in its own market; zero means there is nothing left to sell.
    function _potOf(uint256 loanId) internal view returns (uint256 pot) {
        pot = lens.invPotOf(ace.loanMarket(loanId), loanId);
    }

    /// @dev THE CONSERVATION LAW, restated on the aggregates: only a SETTLEMENT lowers gross NAV, and
    /// @dev every other interleaving of growth, recovery and cranking can only raise it or leave it.
    /// @dev Replaces `testFuzz_BadDebt_ConservationAcrossInterleavings`, which summed the deleted events.
    function testFuzz_Loss_OnlyASettlementEverLowersGrossNav(uint96 buyAmt, uint8 order) public {
        CuratorVault v = _feeRig(5000);
        uint256 loanId = _impair(v);

        uint256 prev = v.grossNav();
        uint256 moved;
        for (uint256 step; step < 4; step++) {
            uint256 pick = (uint256(order) >> (step * 2)) & 3;
            // step 0 is FORCED: drawn by chance a seed can pick four idle ops and judge nothing at all
            if (pick == 0 || step == 0) _growth(v);
            else if (_potOf(loanId) != 0) _buyPot(keeper, loanId, 1 + (uint256(buyAmt) % 1_000e6));
            _crankAll(v);
            uint256 now_ = v.grossNav();
            if (now_ != prev) moved++;
            assertGe(now_, prev, "no settlement in this step, so nothing may shrink the aggregates");
            prev = now_;
        }
        assertGt(moved, 0, "LIVENESS: nothing moved the aggregates, so this run judged nothing");
    }

    /// @dev A recovery pass raises NAV and a collection carries the high-water up with it; no burn runs here, so it never sinks.
    /// @dev Replaces `test_Fee_ADebtMovedPassRestampsWhenRecoveryDiffersFromTheLoss`.
    function test_Fee_ARecoveryCarriesTheMarkUpButNeverDown() public {
        CuratorVault v = _feeRig(2000);
        uint256 loanId = _impair(v);
        uint256 highWaterBefore = v.feeHighWater();
        assertGt(highWaterBefore, 0, "the pre-loss mark stands and the write-off did not sink it");

        uint256 filled = _buyPot(keeper, loanId, 1_000e6);
        assertGt(filled, 0, "the keeper bought part of the pot");
        _crankAndRecognize(v);
        v.collectFee();

        assertGe(v.feeHighWater(), highWaterBefore, "the mark never moves down, whatever the recovery does");
        uint256 nav = v.totalAssets();
        assertEq(v.feeHighWater(), nav > highWaterBefore ? nav : highWaterBefore, "it is the high-water of the two");
    }


    // ---- the derived registration verb's blast radius ----

    /// @dev LENDING-REVIEW MITIGATION. The derived walk is O(ticks x lots-at-tick), lots at one tick unbounded.
    /// @dev So NO gated path may depend on it: this contract is immutable and an OOG there ends it.
    /// @dev Asserted behaviourally: a verb that walked would BOOK, and not one of these books anything.
    /// @dev MORE load-bearing after the teardown, not less: the hub's mint is the only double-book guard.
    function test_NoGatedPathEverMovesTheClaimTheOpenWrote() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW / 2); // most stays idle, so the exit has cash to pay from

        uint256 out = v.balanceOf(alice) / 8; // read BEFORE the prank, or the read consumes it
        /// @dev THE REQUEST COMES FIRST: the claim view reads a standing request, so there has to be one.
        vm.prank(alice);
        v.requestExit(out);

        assertEq(v.maxDeposit(alice), type(uint256).max, "the max-views answer without booking their way there");
        v.maxWithdraw(alice); // the instant views answer too; the last free holder over the open's unvested gain reads zero
        v.maxRedeem(alice);
        v.collectFee();
        /// @dev THE EXERCISE ASKS FOR WHAT EXITABLE CASH COVERS, which is never more than the request asked.
        uint256 fill = v.maxClaim(alice);
        assertGt(fill, 0, "there is a claimable part, or the gated path below is never exercised at all");
        assertLe(fill, out, "and never past the request: the claim spends the escrow and nothing of the free holding");
        vm.prank(alice);
        v.claimExit(fill, alice, 0);

        /// @dev WAS "no gated verb MINTS the vault a unit, only the crank does", from when a crank minted
        /// @dev receipt tokens and the question was which verb could. Receipts are deleted: the hub writes
        /// @dev the CLAIM at the draw and nothing on the vault's side ever moves it. So what survives is the
        /// @dev same safety read the other way -- the claim the open wrote is the claim that still stands.
        uint256 claim = read.claimOf(mid, loanId);
        assertEq(claim, DRAW / 2, "the open wrote the claim, and no gated verb above touched it");
        _crankByLoan(v, loanId);
        assertEq(read.claimOf(mid, loanId), claim, "nor does the crank: it moves CREDIT, never title");
    }
}
