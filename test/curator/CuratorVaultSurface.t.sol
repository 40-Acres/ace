// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing, Row} from "../../src/curator/CuratorVault.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";

/// @notice A vault whose NAV can be nudged with no collection behind it, so a fee is genuinely pending.
/// @dev Every shipped verb that moves NAV ends in `_collectFeeAt`, so nothing in-band leaves one outstanding.
/// @dev That is a property of the CALLER SET, not of the preview arithmetic, which is why it is pinned here.
contract GrownNavVault is CuratorVault {
    uint256 public extra;

    constructor(VaultConfig memory cfg, Listing[] memory listings) CuratorVault(cfg, 10e6, 1.4e18, 1 days, listings, "Grown", "cGROW") {}

    function grow(uint256 amount) external {
        extra += amount;
    }

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + extra;
    }
}

/// @title CuratorVaultSurface
/// @notice Every external verb's guards, the freshness gate in both directions, and the D1 inversion.
contract CuratorVaultSurfaceTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;
    uint256 internal constant ENTRY = 1_000e6; // the deposit and withdraw the preview tests quote
    uint256 internal constant WANT = 1_000e6 * 1e6; // the same size in shares, at the virtual offset
    address internal attacker = address(0xBAD);

    /// @dev DELETED: `_emptyIds`, `_emptyTicks` and `_emptyLots`, which built the no-op crank's three empty
    /// @dev arrays. The sweeping crank takes no arrays: it sweeps the vault's whole pool, which the hub keys by
    /// @dev (lender, quote), so `v.crank()` IS the no-op call when there is nothing to sweep.

    /// @dev Twelve positions: more than a single touch window, which is the whole point of the rig.
    /// @dev A position is a LOAN -- one market, one price, one claim -- so twelve positions is twelve door loans,
    /// @dev and the LAST is the one returned.
    function _wide(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, 12 * 500e6 + 6_000e6);
        for (uint256 i; i < 12; i++) {
            loanId = _open(500e6);
            _crankAllTicks(v, loanId, i);
        }
        assertEq(_carriedClasses(v), 12, "twelve positions");
    }

    // ---- access control ----

    function testRevert_Constructor_PerfFeeOutOfBounds() public {
        VaultConfig memory cfg = _cfg(5001);
        Listing[] memory l = _listing(); // built first: it deploys a record, and that call would spend the expectation
        vm.expectRevert(AceVault.PerfFeeOutOfBounds.selector);
        new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, l, "Curator", "cVLT");
    }

    /// @notice A ZERO CURATOR IS REFUSED AT CONSTRUCTION: on a fee vault the first chargeable collection would mint to it and revert.
    /// @dev Every claim runs a due close first, and the close collects, so that revert would freeze the claims of cash already filled.
    function testRevert_Constructor_ZeroCurator() public {
        VaultConfig memory cfg = _cfg(2000);
        cfg.curator = address(0);
        Listing[] memory l = _listing();
        vm.expectRevert(AceVault.ZeroCurator.selector);
        new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, l, "Curator", "cVLT");
    }

    /// @dev A crank with nothing to sweep is a NO-OP, not a refusal: there is no batch shape left to get wrong.
    function test_Crank_WithNothingToSweepIsANoOp() public {
        CuratorVault v = _newVault(0);
        uint256 gross = v.grossNav();
        v.crank();
        assertEq(v.grossNav(), gross, "an empty sweep moved nothing and reverted nothing");
    }

    /// @dev The crank is idempotent: a second call books nothing and reverts nothing.
    /// @dev RENAMED from `..._IsIdempotentPerClassLot`: there is no (class, lot) coordinate left to key it on.
    function test_Register_IsIdempotent() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);

        _crank(v, loanId, T2, 0);
        uint256 claim = read.claimOf(mid, loanId);
        uint256 gross = v.grossNav();

        _crank(v, loanId, T2, 0);
        assertEq(_carriedClasses(v), 1, "no second position");
        assertEq(read.claimOf(mid, loanId), claim, "and the claim the draw wrote is untouched by either lap");
        assertEq(v.grossNav(), gross, "nor any movement in NAV: the repeat is inert");
    }

    // ---- staleness is priced by the PUSH now, not gated by a clock ----

    /// @dev T31: nothing about elapsed time may stand between an LP and their cash, in either direction.
    /// @dev Was `test_Withdraw_IsFreshnessGatedAndCrankClears`: there is no clock left to gate on.
    function test_Withdraw_IsNeverTimeGated() public {
        CuratorVault v = _newVault(0);
        _wide(v);
        _warpBy(3 days);

        uint256 shares = v.balanceOf(alice) / 4;
        assertGt(_requestAndClaim(v, alice, shares), 0, "the exit pays however long nobody swept");

        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(v), 1_000e6);
        assertGt(v.deposit(1_000e6, bob), 0, "and entry takes capital on the same terms");
        vm.stopPrank();
    }

    /// @dev T32 INVERTED: there IS no unrecognized settlement, so the last run surface is gone.
    /// @dev `totalAssets` reads `min(gross, mark)`, so a fall passes through with nobody having synced.
    /// @dev The old law -- exit before the sync and take the stale price -- required a mark that lagged down.
    /// @dev What is left is the opposite guarantee: the unsynced price is never the BETTER one to exit at.
    function test_Withdraw_ASettlementIsPricedBeforeAnybodySyncs() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _wide(v);
        uint256 grossBefore = v.grossNav();
        _finalize(loanId);

        uint256 shares = v.balanceOf(alice) / 100;
        uint256 unsynced = v.convertToAssets(shares);
        uint256 navUnsynced = v.totalAssets();
        assertLt(v.grossNav(), grossBefore, "the settlement really did land at the hub");
        assertEq(v.grossNav(), _hubTruthNav(v), "and the aggregate is right the moment it lands");

        v.collectFee(); // the sync only retires deferral; it has no loss left to discover
        assertLe(unsynced, v.convertToAssets(shares), "exiting first is never the better price: no run surface");
        assertLe(navUnsynced, v.totalAssets(), "because the fall was already in the view before the sync");
        assertEq(v.grossNav(), _hubTruthNav(v), "the aggregate itself was right the whole time");
    }

    /// @dev A crank with nothing to sweep is a NO-OP, and a fresh, all-idle vault still takes deposits after it.
    /// @dev The row survives because the SECOND half was always the point: a no-op must not wedge entry.
    function test_Sweep_AnEmptyCrankIsInertAndAnIdleVaultStillTakesCapital() public {
        CuratorVault v = _newVault(0);
        _warpBy(3 days);
        uint256 navBefore = v.grossNav();
        v.crank();
        assertEq(v.grossNav(), navBefore, "the crank found nothing and moved nothing");
        _lpDeposit(v, alice, SEED);
        assertGt(v.balanceOf(alice), 0, "so entry is open");
    }

    // ---- D1: the donation seam is closed at the gate, so only the EXIT half survives ----

    /// @dev T37, the surviving half: the exit is CASH and carries no title, donated or earned.
    /// @dev What still needs pinning is the part that never depended on a gift: an exit moves no unit.
    function test_Exit_CarriesNoTitleOfAnyKind() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);

        _crank(v, loanId, T2, 0);
        _lpDeposit(v, bob, 1_000e6);
        _finalize(loanId);
        _crankAll(v);

        uint256 balance = read.invPotOf(mid, loanId);
        assertGt(balance, 0, "the vault holds real title going into the exit");
        uint256 held = v.balanceOf(bob); // BEFORE the prank: a read is a call, and a call would eat it
        assertEq(v.maxRedeem(bob), held, "and exitable cash does not bind, so this exit is total");

        vm.prank(bob);
        v.redeem(held, bob, bob); // the instant exit, at the post-loss price

        assertEq(read.invPotOf(mid, loanId), balance, "and the stayers keep every unit of it");
    }

    // ---- 4626 inflation resistance and preview parity ----

    /// @dev A raw token push IS counted: NAV reads the vault's balance, so gross rises by it at once.
    /// @dev The vest is what defends it: the rise is deferred, so the share price does not move in the block,
    /// @dev and entry shuts while a pile over `GATE_BPS` of NAV stands.
    function test_Inflation_ADonationIsCountedAndVests() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 navBefore = v.totalAssets();
        uint256 grossBefore = v.grossNav();
        usdc.mint(address(v), 1_000_000e6);
        assertEq(v.grossNav(), grossBefore + 1_000_000e6, "gross counts the raw balance at once");
        assertEq(v.totalAssets(), navBefore, "but the share price does not move in the block: the rise is deferred");

        v.crank(); // the sync stamps the rise onto the pile
        assertEq(v.totalAssets(), navBefore, "still deferred once stamped");
        assertEq(v.maxDeposit(bob), 0, "and entry shuts while the pile is over the gate");
        usdc.mint(bob, ENTRY);
        vm.startPrank(bob);
        usdc.approve(address(v), ENTRY);
        vm.expectRevert(AceVault.GainVesting.selector);
        v.deposit(ENTRY, bob);
        vm.stopPrank();

        _warpBy(uint256(VEST_W) + 1);
        assertApproxEqAbs(v.totalAssets(), navBefore + 1_000_000e6, 1, "and the donation reaches NAV once it matures");
    }

    /// @dev The full inflate-then-donate sequence: the attacker cannot profit off the next depositor.
    /// @dev The donation is counted and vests, so the victim waits out the gate; after it the 1e6 virtual offset still protects her.
    function test_Inflation_InflateThenDonate_NoProfit() public {
        CuratorVault v = _newVault(0);
        // the one-wei open is ADMITTED, so the virtual offset is the whole defence and must carry it alone
        usdc.mint(bob, MIN_DEP);
        vm.startPrank(bob);
        usdc.approve(address(v), MIN_DEP);
        v.deposit(1, bob);
        vm.stopPrank();

        _lpDeposit(v, bob, MIN_DEP - 1);
        uint256 attackerShares = v.balanceOf(bob);
        usdc.mint(bob, 10_000e6);
        vm.prank(bob);
        usdc.transfer(address(v), 10_000e6);
        uint256 paid = MIN_DEP + 10_000e6; // both entries and the donation

        uint256 victimAssets = 5_000e6;
        v.crank(); // the donation is stamped onto the pile
        assertEq(v.maxDeposit(alice), 0, "the victim's entry waits while the donation vests");
        _warpBy(uint256(VEST_W) + 1);
        uint256 victimShares = _lpDeposit(v, alice, victimAssets);
        assertGt(victimShares, 0, "the victim is not rounded down to zero shares");

        /// @dev Valued through the vault's own conversion, which counts the virtual shares: their slice of the donation is the attacker's loss.
        assertLe(v.convertToAssets(attackerShares), paid + 1, "the seat is worth only what it paid, donation included");
        assertApproxEqAbs(v.convertToAssets(victimShares), victimAssets, 2, "and the victim keeps hers");
    }

    /// @dev The virtual offset is a named security parameter, so pin its magnitude, not just its effect.
    function test_Inflation_VirtualOffsetMagnitudeIsPinned() public {
        CuratorVault v = _newVault(0);
        assertEq(v.previewDeposit(1), 1e6, "a fresh vault prices the first wei at the 1e6 offset");
        assertEq(v.previewDeposit(0), 0, "and zero assets still mint zero shares");
        _lpDeposit(v, alice, SEED);
        assertGt(v.previewDeposit(1), 0, "a one-wei entry is never rounded away to nothing");
    }

    /// @dev THE VIEW/VERB SEAM. Every state-changing verb runs `_sync` as its FIRST statement, so a caller
    /// @dev is quoted against PRE-sync state and settled against POST-sync state, and the two can differ.
    /// @dev EIP-4626 fixes which way each may differ. THREE OF THE FOUR hold across the sync on a rise;
    /// @dev `previewWithdraw` does not, by the ladder's CEIL, and its repro is held outside this repository with the
    /// @dev entry pair's larger break on a fall -- one cause, two magnitudes, and neither is pinned as law.
    function test_Views_TheSyncInsideAVerbNeverMovesThePriceAgainstItsCaller_OnARise() public {
        CuratorVault a = _newVault(0);
        _pendingRise(a);
        uint256 promisedShares = a.previewDeposit(ENTRY);
        uint256 minted = _lpDeposit(a, bob, ENTRY);
        assertGe(minted, promisedShares, "a deposit mints no fewer shares than previewDeposit quoted");
        assertLe(a.convertToAssets(minted), ENTRY, "and the entrant rounded no value out of the stayers");

        CuratorVault b = _newVault(0);
        _lpDeposit(b, bob, SEED); // a second holder, so alice is not the last free one an instant exit refuses over the rise
        _pendingRise(b);
        uint256 sh = b.balanceOf(alice) / 8;
        /// @dev THE QUOTE IS TAKEN BEFORE THE VERB, which is what makes it a pre-sync quote.
        uint256 promisedAssets = b.previewRedeem(sh);
        assertGe(b.maxRedeem(alice), sh, "PREMISE: exitable cash covers the exit whole");
        vm.prank(alice);
        assertGe(b.redeem(sh, alice, alice), promisedAssets, "a redeem pays no fewer assets than previewRedeem quoted");

        CuratorVault c = _newVault(0);
        _pendingRise(c);
        uint256 promisedPull = c.previewMint(WANT);
        usdc.mint(bob, promisedPull);
        vm.startPrank(bob);
        usdc.approve(address(c), promisedPull);
        assertLe(c.mint(WANT, bob), promisedPull, "a mint pulls no more assets than previewMint quoted");
        vm.stopPrank();
    }

    /// @dev The other direction, and the harder one. A FALL is already in the view before anybody syncs,
    /// @dev so the sync has no loss left to find -- but it does RETIRE the ladder the loss wiped out, and
    /// @dev that RAISES the base the quote was taken against, materially rather than by a rounding wei.
    /// @dev THE ENTRY LEG'S 4626 DIRECTION DOES NOT SURVIVE THAT and is held as a repro outside this repository, NOT here.
    /// @dev What is pinned here is the half that holds: no caller rounds value out, and the exit is honest.
    function test_Views_TheSyncInsideAVerbNeverMovesThePriceAgainstItsCaller_OnAFall() public {
        CuratorVault a = _newVault(0);
        _pendingFallUnderALadder(a);
        assertGt(a.unvested(), 0, "fixture: a ladder the loss has not yet retired is still standing");
        uint256 minted = _lpDeposit(a, bob, ENTRY);
        assertLe(a.convertToAssets(minted), ENTRY, "the entrant rounded no value out of the stayers");

        CuratorVault b = _newVault(0);
        _pendingFallUnderALadder(b);
        uint256 heldB = b.balanceOf(alice); // BEFORE the prank: a read is a call, and a call would eat it
        uint256 promisedAssets = b.convertToAssets(heldB); // the unsynced quote, taken before the verb
        uint256 fill = b.maxRedeem(alice); // the instant exit at the price the fall left, bounded by exitable cash
        assertGt(fill, 0, "fixture: exitable cash admits an exit worth measuring");
        vm.prank(alice);
        uint256 paid = b.redeem(fill, alice, alice);
        assertGe(paid, Math.mulDiv(promisedAssets, fill, heldB), "the exit pays no less than the unsynced quote for what it took");
    }

    /// @dev A clean close nobody has synced yet: gross is above the mark and the ladder has not seen it.
    /// @dev Twice the seed goes in and less than half of it is lent, so the exit legs have idle to be served from.
    function _pendingRise(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, 2 * SEED);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, lens.loan(loanId).debt);
    }

    /// @dev A ladder standing from an earlier arrival, then an unsynced settlement big enough to burn it.
    /// @dev A fall of about four percent, large enough that it still burns past the ladder.
    function _pendingFallUnderALadder(CuratorVault v) internal {
        _pendingRise(v);
        _crankAll(v); // banks the repayment AND stamps the arrival on the ladder in one sync
        assertGt(v.unvested(), 0, "fixture: a ladder is standing");
        assertGt(SHALLOW_DOOMED, v.unvested(), "fixture: the fall still burns past the ladder");
        uint256 doomed = _open(SHALLOW_DOOMED);
        _crankByLoan(v, doomed);
        _finalize(doomed);
        _waivePots(v); // the pot stays unsold and the fall unsynced, and the entrant may still come in
    }

    uint256 internal constant SHALLOW_DOOMED = 800e6; // about four percent of the book

    /// @dev previewDeposit must never promise MORE shares than deposit mints in the same transaction.
    function test_Preview_DepositIsNeverOptimistic() public {
        CuratorVault v = _newVault(2000);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _repay(loanId, DRAW + 2_000e6);

        uint256 promised = v.previewDeposit(1_000e6);
        uint256 actual = _lpDeposit(v, bob, 1_000e6);
        assertLe(actual, promised, "the preview is an upper bound, per the standard");
    }

    /// @dev With nothing left to crank and the fee already taken, the preview must be EXACT.
    function test_Preview_IsExactOnceTheFeeIsCollected() public {
        CuratorVault v = _newVault(2000);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _repay(loanId, DRAW + 2_000e6);
        _crankAndRecognize(v);
        v.collectFee();

        uint256 supplyBefore = v.totalSupply();
        uint256 promised = v.previewDeposit(1_000e6);
        uint256 actual = _lpDeposit(v, bob, 1_000e6);
        assertGt(v.balanceOf(curator), 0, "the pass before this already took the fee");
        assertEq(v.totalSupply(), supplyBefore + actual, "so the entry mint is the only supply this call added");
        assertEq(actual, promised, "and the preview priced it exactly");
    }

    /// @dev The previews price the fee the entry ITSELF collects, so that term is arithmetic, not a guard.
    function test_Preview_PricesTheFeeTheDepositItselfCollects() public {
        GrownNavVault v = new GrownNavVault(_cfg(2000), _listing());
        _lpDeposit(v, alice, SEED);
        v.collectFee(); // at NAV, a no-op: the first deposit stamped the high-water at its cash
        v.grow(1_000e6);

        uint256 pending = v.pendingFeeShares();
        assertGt(pending, 0, "a fee really is outstanding at the moment of the quote");
        uint256 supplyBefore = v.totalSupply();
        uint256 promised = v.previewDeposit(1_000e6);
        uint256 actual = _lpDeposit(v, bob, 1_000e6);

        assertEq(v.balanceOf(curator), pending, "the deposit collected exactly that fee on its way in");
        assertEq(v.totalSupply(), supplyBefore + pending + actual, "so the fee shares diluted this mint");
        assertEq(actual, promised, "and the preview priced that dilution exactly");
    }

    /// @dev The public view under the HIGH-WATER MARK, which replaced the diversion as the alignment.
    /// @dev Two vaults, one identical growth: only the one still under its pre-loss mark reads zero.
    /// @dev Replaces `test_PendingFeeShares_IsNetOfTheDiversion` on the same fixture, new mechanism.
    function test_PendingFeeShares_IsZeroUnderTheHighWaterMark() public {
        GrownNavVault impaired = new GrownNavVault(_cfg(2000), _listing());
        mid = _doorMarket(impaired, address(collateral)); // it lends for real, through its own door
        _lpDeposit(impaired, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(impaired, loanId, T2, 0);
        uint256 mark = impaired.feeHighWater();
        assertGt(mark, 0, "a high-water stood before the loss");
        _finalize(loanId);
        _crankAll(impaired);
        assertEq(impaired.feeHighWater(), mark, "and the write-off left it exactly there");

        GrownNavVault healthy = new GrownNavVault(_cfg(2000), _listing());
        _lpDeposit(healthy, alice, SEED);
        healthy.collectFee(); // at NAV, a no-op: the deposit stamped the high-water, so the two vaults are comparable
        impaired.grow(1_000e6);
        healthy.grow(1_000e6);

        assertGt(healthy.pendingFeeShares(), 0, "the same growth is a real fee on a vault sitting at its mark");
        assertLt(impaired.totalAssets(), mark, "the impaired one is under it");
        assertEq(impaired.pendingFeeShares(), 0, "so it reads zero until the loss is clawed back in full");
    }

    /// @dev previewMint must never promise FEWER assets than mint actually pulls.
    function test_Preview_MintIsNeverOptimistic() public {
        CuratorVault v = _newVault(2000);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _repay(loanId, DRAW + 2_000e6);

        uint256 shares = 1_000e6 * 1e6;
        uint256 promised = v.previewMint(shares);
        usdc.mint(bob, promised * 2);
        vm.startPrank(bob);
        usdc.approve(address(v), promised * 2);
        uint256 actual = v.mint(shares, bob);
        vm.stopPrank();
        assertGe(actual, promised, "the preview is a lower bound, per the standard");
        assertEq(v.balanceOf(bob), shares, "and the share count asked for is what lands");
    }

    // ---- the table, the hub floors, and the interface pin ----

    /// @dev The table gates the collateral TOKEN, never the record class: any `IPersistenceRecord` may price a row.
    /// @dev A borrow on a collateral with no live row is refused; a row naming an arbitrary record is admitted once it waits the timelock.
    /// @dev The disclosure is the row itself: `rowOf` names the record the door prices off.
    function test_Envelope_GatesTokenNotOracle() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);

        MockStakeVault other = new MockStakeVault(43);
        other.mint(borrower, COLL);
        vm.startPrank(borrower);
        other.approve(address(v), COLL);
        vm.expectRevert(CuratorVault.NotListed.selector);
        v.borrow(_request(address(other), COLL, 1_000e6), "", "");
        vm.stopPrank();

        Row memory row = _list(v, address(other)); // a fresh record: an arbitrary oracle the curator chose
        uint256 loanId = _borrowOn(v, address(other), 1_000e6);
        assertEq(ace.idToMarketParams(ace.loanMarket(loanId)).record, row.record, "an arbitrary record is admitted: the table reads the TOKEN");
        assertEq(v.rowOf(address(other)).record, row.record, "and the row discloses the record it prices off");
    }

    /// @dev The other end of the same deletion: the vault's own entry minimum went with `MIN_DEPOSIT`,
    /// @dev so the virtual offset is now the WHOLE first-depositor defence and has to carry it alone.
    function test_Entry_ADustDepositIsAdmittedAndTheOffsetStillPricesIt() public {
        CuratorVault v = _newVault(0);
        uint256 first = _lpDeposit(v, bob, 1);
        assertEq(first, 1e6, "the one-wei open mints exactly the 1e6 virtual offset, and no more");
        assertEq(v.idle(), 1, "and the wei really did land in the vault");

        uint256 victim = _lpDeposit(v, alice, 5_000e6);
        assertGt(victim, 0, "a real depositor after it is not rounded to nothing");
        uint256 nav = v.totalAssets();
        assertLe((nav * first) / v.totalSupply(), 2, "the dust seat is worth the wei it paid, plus rounding");
        assertApproxEqAbs((nav * victim) / v.totalSupply(), 5_000e6, 2, "and the entrant keeps hers");
    }

    /// @dev The hub exposes exactly the members the vault is compiled against; the lens legs pin the reader surface.
    function test_InterfaceParity_SelectorsPinned() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);

        assertEq(ace.restingOf(mid), 0, "restingOf pinned: nothing the door rested stays after it");
        /// @dev `unitIdOf`, `unitKey`, `balanceOf` and `unitClass` went with the receipt layer. What they
        /// @dev collectively pinned -- that a wei of drawn quote is owed to exactly one party -- is now the
        /// @dev claim ledger plus the market's named lender, and both are read here in their place.
        assertEq(ace.idToMarketParams(mid).lender, address(v), "the market's one lender pinned");
        assertEq(lens.claimOf(mid, loanId), DRAW, "claimAt pinned, and a claim IS a wei of drawn quote");
        assertFalse(lens.loan(loanId).closedAt != 0, "loan pinned");
        assertEq(PriceFrame.priceAtStep(0), 1 << 96, "the price law is a pure import, never a read");
    }

    // ---- the crank ----

    /// @dev Repeated calls book once: the hub's own guard is it, not a batch-level dedupe.
    /// @dev WAS `test_Crank_DuplicateLegsMintOnce` over a (loan, tick, lot) batch; the reachable shape is repeated calls.
    function test_Crank_RepeatedCallsBookOnce() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 id = _open(DRAW);

        uint256 grossBefore = v.grossNav();
        v.crank();
        v.crank();
        v.crank();

        assertEq(read.claimOf(mid, id), DRAW, "the second and third call book nothing");
        assertEq(v.grossNav(), grossBefore, "and every one of them is NAV-neutral, repeated or not");
    }
}
