// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {MockBlockableERC20} from "../mocks/MockBlockableERC20.sol";
import {VaultConfig} from "../../src/curator/libraries/AceVaultFlows.sol";
import {Listing, Quote} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindOneDenominator
/// @notice In kind, one default is booked over one supply: its NAV loss and its pot both fall on every tracked share, with no vesting age.
/// @notice The age's job moves to the entry gate: a settle shuts entry until anyone collects, and the collect's own block stays shut.
/// @notice MEASURE rows pin the residuals the fix discloses rather than closes.
contract InKindOneDenominatorTest is InKindRig {
    uint256 internal constant P = 100_000e6; // a tenth of one LP's cash
    uint256 internal constant BIG_UNITS = 400_000e18; // the recordless line is about 280,000 units at 0.5 USDC

    /// @dev A loan of `p` against tokA on a fresh appraiser quote, on `BIG_UNITS`, for one minimum term.
    function _loan(uint256 p) internal returns (uint256) {
        Quote memory q = _quote(address(tokA), PRICE);
        q.maxPrincipal = p;
        return _borrowWith(q, _data(q), BIG_UNITS, p, MIN_TENOR);
    }

    /// @dev What `who`'s shares are worth now.
    function _worth(address who) internal view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(who));
    }

    // ---- the entry gate replaces the vesting age ----

    /// @notice After a stranger's settle entry shuts until anyone collects, and for the collect's block; the next block admits an entrant credited none of it.
    function test_aStrangersSettleShutsEntryUntilAnyoneCollects() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        _nextBlock();
        vm.prank(stranger);
        ace.forceClose(loanId);
        _expectEntryShut(bob, LP_CASH, "a stranger's settle shuts entry");
        _nextBlock();
        _expectEntryShut(bob, LP_CASH, "and it stays shut across blocks until the pot comes home");
        vm.prank(stranger);
        uint256[] memory got = vault.collectForfeited(_ids(loanId));
        assertEq(got[0], pot, "anyone collects, and the whole pot comes home");
        _expectEntryShut(bob, LP_CASH, "the collect's own block stays shut");
        _nextBlock();
        assertGt(vault.maxDeposit(bob), 0, "the next block opens entry");
        assertGt(vault.maxMint(bob), 0, "in both max views");
        uint256 sb = _lp(bob, LP_CASH);
        _nextBlock();
        assertEq(_claimable(bob, address(tokA)), 0, "the entrant is credited nothing of that pot");
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot, 1, "the holder who carried the loss takes it all");
        assertEq(_trackedSupply(), sa + sb, "the entrant is tracked from its own block on");
    }

    /// @notice The vault's own collect, settle and redeem in one call, still shuts entry for the rest of its block.
    function test_theVaultsOwnCollectShutsEntryForItsBlock() public {
        _lp(alice, LP_CASH);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(unsold, 0, "premise: the hub counts no pot unsold once the collect took it home");
        _expectEntryShut(bob, LP_CASH, "a same-block entrant after the vault's own collect");
        _nextBlock();
        _lp(bob, LP_CASH);
        _nextBlock();
        assertEq(_claimable(bob, address(tokA)), 0, "a block later the entrant is admitted and credited none of it");
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot, 1, "the holder at the collect's block end takes it all");
    }

    /// @notice A batch closes on any nonzero tracked supply: a tiny one closes before the next block's entrant is counted, so that entrant takes none.
    function test_aTinyTrackedSupplyClosesTheBatchBeforeTheNextEntrant() public {
        uint256 sa = _lp(alice, LP_CASH);
        _warpBy(MIN_TENOR);
        _nextBlock();
        uint256 loanId = _open(address(tokA));
        uint256 dust = 1_000;
        vm.prank(alice);
        vault.transfer(address(vault), sa - dust);
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        _collect(loanId);
        _nextBlock();
        uint256 sb = _lp(bob, LP_CASH);
        _nextBlock();
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot, 1, "the batch closed on alice's dust, so she takes the whole pot");
        assertEq(_claimable(bob, address(tokA)), 0, "the next block's entrant is not counted in it");
        assertEq(_trackedSupply(), dust + sb, "the gift to the vault left the tracker; the entrant joined after the batch closed");
    }

    // ---- the guardian ----

    /// @notice In kind the guardian can lift a pot that can never come home: its token refuses the vault, so no collect lands and entry would stay shut.
    function test_theGuardianExemptsAPotThatCannotComeHome() public {
        MockBlockableERC20 tokX = new MockBlockableERC20("Token X", "TKX", 18);
        Listing[] memory l = new Listing[](1);
        l[0] = _listing(address(tokX), CAP);
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        Quote memory q = _quote(address(tokX), AceFixtures.px(0.5e18, address(usdc), address(tokX)));
        uint256 loanId = _borrowWith(q, _data(q), UNITS, PRINCIPAL, MIN_TENOR);
        _toExpiry(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        tokX.setBlocked(address(vault), true);
        vm.prank(keeper);
        vm.expectRevert();
        vault.collectForfeited(_ids(loanId));
        _expectEntryShut(bob, LP_CASH, "a pot that cannot come home shuts entry");
        (, uint256 settled) = ace.lenderUnresolved(address(vault), address(usdc));
        vm.prank(guardian);
        vault.exemptDeadPots(settled);
        assertGt(vault.maxDeposit(bob), 0, "the guardian's exemption reopens entry");
        assertGt(_lp(bob, LP_CASH), 0, "and a deposit lands");
    }

    /// @notice An in-kind vault with no guardian refuses at deploy: nothing else could lift a pot that cannot come home.
    function test_anInKindVaultRefusesNoGuardian() public {
        VaultConfig memory c = _cfg(0);
        c.guardian = address(0);
        vm.expectRevert(bytes4(keccak256("ZeroGuardian()")));
        this.deployExternal(c, _ik(), _listings());
    }

    // ---- end-of-block credit ----

    /// @notice Shares borrowed and returned inside the collect's block earn nothing; the holder at the block's end keeps its slice.
    function test_sharesBorrowedInsideTheCollectsBlockEarnNothing() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 sb = _lp(bob, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        _nextBlock();
        vm.prank(bob);
        vault.transfer(stranger, sb);
        vm.prank(stranger);
        vault.collectForfeited(_ids(loanId));
        vm.prank(stranger);
        vault.transfer(bob, sb);
        _nextBlock();
        assertEq(_claimable(stranger, address(tokA)), 0, "the borrower of the shares is credited nothing");
        assertEq(_claim(stranger, address(tokA)), 0, "and a claim pays it nothing");
        assertApproxEqAbs(_claimable(bob, address(tokA)), Math.mulDiv(pot, sb, sa + sb), 1, "the lender of the shares keeps its slice");
        assertApproxEqAbs(_claimable(alice, address(tokA)), Math.mulDiv(pot, sa, sa + sb), 1, "and alice hers");
    }

    // ---- MEASURE: the residuals the fix discloses ----

    /// @notice MEASURE: a holder who exits between a stranger's settle and the collect is paid at the post-loss price and forfeits its pot slice.
    function test_measure_anExitBetweenAStrangersSettleAndTheCollectForfeitsItsSlice() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 sb = _lp(bob, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        vm.prank(bob);
        vault.redeem(sb, bob, bob);
        _nextBlock();
        _collect(loanId);
        _nextBlock();
        emit log_named_uint("pot units", pot);
        emit log_named_uint("bob's slice had he held to the collect", Math.mulDiv(pot, sb, sa + sb));
        emit log_named_uint("bob's credit", _claimable(bob, address(tokA)));
        assertEq(_claimable(bob, address(tokA)), 0, "MEASURE: the exit between the settle and the collect forfeits its slice");
        assertApproxEqAbs(_claimable(alice, address(tokA)), pot, 1, "MEASURE: the stayer takes it");
    }

    /// @notice MEASURE: an exit in the collect's own block forfeits its slice; one a block later keeps it.
    function test_measure_anExitInTheCollectsBlockForfeitsItsSlice() public {
        uint256 sa = _lp(alice, LP_CASH);
        uint256 sb = _lp(bob, LP_CASH);
        uint256 pot = _defaultAndCollect(_open(address(tokA)));
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        vault.redeem(sb, bob, bob);
        _nextBlock();
        uint256 sameBlock = _claimable(bob, address(tokA));
        vm.revertToState(snap);
        _nextBlock();
        vm.prank(bob);
        vault.redeem(sb, bob, bob);
        uint256 nextBlock = _claimable(bob, address(tokA));
        emit log_named_uint("bob's credit, exit in the collect's block", sameBlock);
        emit log_named_uint("bob's credit, exit a block later", nextBlock);
        assertEq(sameBlock, 0, "MEASURE: an exit in the collect's block forfeits the slice");
        assertApproxEqAbs(nextBlock, Math.mulDiv(pot, sb, sa + sb), 1, "MEASURE: collect, wait a block, exit keeps it");
    }

    /// @notice MEASURE: an entrant after expiry and before the settle carries its loss share and is credited its pot share, netting its share of the excess.
    function test_measure_anEntrantAfterExpiryBeforeTheSettleSharesOnlyThePotsExcess() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _loan(P);
        _toExpiry(loanId);
        _nextBlock();
        uint256 sb = _lp(bob, LP_CASH);
        uint256 supply = vault.totalSupply();
        uint256 navBefore = vault.totalAssets();
        uint256 bobBefore = _worth(bob);
        uint256 pot = _collect(loanId);
        _nextBlock();
        uint256 fall = navBefore - vault.totalAssets();
        uint256 loss = bobBefore - _worth(bob);
        uint256 credit = _claimable(bob, address(tokA));
        uint256 potWorth = pot / 2e12; // tokA at the loan's 0.5 USDC: half its 18-decimal units, in 6 decimals
        emit log_named_uint("NAV fall at the collect", fall);
        emit log_named_uint("pot worth at the loan's price", potWorth);
        emit log_named_uint("bob's NAV loss", loss);
        emit log_named_uint("bob's credit worth at the loan's price", credit / 2e12);
        emit log_named_uint("bob's share of the pot's excess over the fall", Math.mulDiv(potWorth - fall, sb, supply));
        uint256 held = supply - vault.SEED_SHARES(); // the seed carries its slice of the loss; untracked, its slice of the pot goes to the holders
        assertApproxEqAbs(loss, Math.mulDiv(fall, sb, supply), 2, "MEASURE: the entrant carries its pro-rata part of the loss");
        assertApproxEqAbs(credit, Math.mulDiv(pot, sb, held), 2, "MEASURE: and is credited its pro-rata part of the pot");
        assertApproxEqAbs(
            credit / 2e12 - loss, Math.mulDiv(potWorth, sb, held) - Math.mulDiv(fall, sb, supply), 2, "MEASURE: so it nets only its share of the excess"
        );
    }

    /// @notice MEASURE: fee shares minted between a settle and its fold are tracked at the batch, so the curator takes their slice of the pot.
    function test_measure_aFeeMintBetweenASettleAndItsFoldTakesItsSlice() public {
        vault = _deploy(_cfg(2_000), _ik(), _listings());
        uint256 sa = _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        usdc.mint(address(vault), 50_000e6);
        vault.crank();
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        uint256 before = vault.balanceOf(curator);
        vault.collectFee();
        assertGt(vault.balanceOf(curator), before, "premise: NAV sat above the high-water after the loss, so fee shares minted after the settle");
        _collect(loanId);
        _nextBlock();
        uint256 s = sa + vault.balanceOf(curator);
        emit log_named_uint("fee shares at the batch", vault.balanceOf(curator));
        emit log_named_uint("the curator's credit", _claimable(curator, address(tokA)));
        assertApproxEqAbs(_claimable(curator, address(tokA)), Math.mulDiv(pot, vault.balanceOf(curator), s), 1, "MEASURE: the fee shares take their slice");
        assertApproxEqAbs(_claimable(alice, address(tokA)), Math.mulDiv(pot, sa, s), 1, "MEASURE: and alice the rest");
    }

    // ---- the payout's sum ----

    /// @notice Each holder is credited exactly its tracked share at the collect's block end, escrow counted, and the credits never sum past the pot.
    function testFuzz_eachCreditIsItsTrackedShareAndTheyNeverSumPastThePot(
        uint256 a0,
        uint256 b0,
        uint256 c0,
        uint8 when,
        uint256 x0,
        uint256 e0,
        uint256 o0,
        uint256 d0
    ) public {
        _lp(alice, bound(a0, 200_000e6, LP_CASH));
        uint256 b = bound(b0, 1e6, LP_CASH);
        if (when % 3 == 0) _lp(bob, b);
        uint256 loanId = _loan(P);
        _warpBy(1 hours);
        _nextBlock();
        if (when % 3 == 1) _lp(bob, b);
        _lp(carol, bound(c0, 1e6, LP_CASH));
        uint256 x = bound(x0, 0, vault.balanceOf(alice));
        vm.prank(alice);
        vault.transfer(carol, x);
        _toExpiry(loanId);
        _nextBlock();
        if (when % 3 == 2) _lp(bob, b);
        uint256 esc = bound(e0, 0, vault.balanceOf(bob));
        vm.prank(bob);
        vault.requestExit(esc);
        uint256 out = bound(o0, 0, vault.maxRedeem(carol));
        if (vault.previewRedeem(out) == 0) out = 0; // a redeem that pays nothing is refused; zero is the no-op
        vm.prank(carol);
        vault.redeem(out, carol, carol);
        uint256 pot = _collect(loanId);
        uint256 gift = bound(d0, 0, vault.balanceOf(bob));
        vm.prank(bob);
        vault.transfer(dave, gift);

        address[4] memory hs = [alice, bob, carol, dave];
        uint256[4] memory t;
        uint256 sum;
        for (uint256 i; i < 4; i++) {
            t[i] = vault.balanceOf(hs[i]) + (hs[i] == bob ? esc : 0);
            sum += t[i];
        }
        _nextBlock();
        uint256 paid;
        for (uint256 i; i < 4; i++) {
            uint256 c = _claim(hs[i], address(tokA));
            assertEq(c, Math.mulDiv(pot, t[i], sum), "each credit is its tracked share at the collect's block end");
            paid += c;
        }
        assertLe(paid, pot, "the credits never sum past the payout's units");
        assertGe(paid + 4, pot, "and leave at most a unit each of rounding");
        assertEq(_trackedSupply(), sum, "the tracked supply is the holders' balances and their escrow");
        assertEq(_tracked(bob), vault.balanceOf(bob) + esc, "bob's escrow stays his");
    }
}
