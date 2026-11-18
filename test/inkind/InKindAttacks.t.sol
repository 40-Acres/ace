// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {AceVaultCaps} from "../../src/curator/AceVaultCaps.sol";
import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";
import {PriceGrid} from "../../src/curator/PriceGrid.sol";
import {IInKindTerms, IInKindVault, Listing, Quote, Row} from "./InKindSurface.sol";
import {FlashCollector, ShareFlashLender} from "./InKindMocks.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title InKindAttacks
/// @notice The attacks the lending review named and the surface rulings close, each written in the ATTACKER'S ORDER.
/// @notice (1) A flash-borrowed share collects a pot and earns zero. (2) A front-runner cannot burn another borrower's quote nonce.
/// @notice (3) A stolen appraiser key lends each token's room, and no more. Ruling: a widening cannot ride inside a cut.
contract InKindAttacksTest is InKindRig {
    // ---- (1) the flash-borrowed share ----

    /// @notice A venue holding shares is flash-borrowed around the collect: the attacker earns nothing and the venue's slice is unchanged.
    function test_attack_flashBorrowedSharesEarnZero() public {
        uint256 sa = _lp(alice, 600_000e6);
        _lp(carol, 400_000e6);
        _warpBy(MIN_TENOR);
        ShareFlashLender venue = new ShareFlashLender(IERC20(address(vault)));
        vm.prank(alice);
        vault.transfer(address(venue), sa);
        assertEq(_tracked(address(venue)), sa, "premise: the venue holds tracked shares");
        FlashCollector attacker = new FlashCollector(vault, venue);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);

        uint256 snap = vm.snapshotState();
        _collect(loanId);
        _nextBlock();
        uint256 venueHonest = _claimable(address(venue), address(tokA));
        uint256 carolHonest = _claimable(carol, address(tokA));
        assertGt(venueHonest, 0, "premise: the venue earns its slice when nobody attacks");
        vm.revertToState(snap);

        // the attacker, in one transaction: borrow the venue's shares, collect, claim, repay
        attacker.attack(_ids(loanId), _toks(address(tokA)), sa);
        assertEq(attacker.paidInFlash(), 0, "the in-flash claim paid nothing");
        assertEq(vault.balanceOf(address(venue)), sa, "the flash was repaid");
        assertEq(vault.balanceOf(address(attacker)), 0, "and the attacker holds no shares");

        // the attacker, next block: claim again
        _nextBlock();
        assertEq(_claimable(address(attacker), address(tokA)), 0, "the attacker is credited nothing");
        vm.prank(address(attacker));
        vault.claim(_toks(address(tokA)), address(attacker));
        assertEq(tokA.balanceOf(address(attacker)), 0, "and takes nothing");
        assertEq(_claimable(address(venue), address(tokA)), venueHonest, "the venue's slice is what it would have been");
        assertEq(_claimable(carol, address(tokA)), carolHonest, "and so is every other holder's");
    }

    // ---- (2) the front-run nonce ----

    /// @notice A front-runner replaying a borrower's signed quote from the mempool is refused, burns nothing, and the borrower's borrow lands.
    function test_attack_aFrontRunnerCannotBurnAnotherBorrowersNonce() public {
        _lp(alice, LP_CASH);
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _data(q);

        // the attacker sees the borrower's transaction and sends the same payload first
        _fund(address(tokA), stranger, UNITS);
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NotTheBorrower.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, "");
        assertFalse(terms.spent(q.nonce), "the front-run burned no nonce");

        // the borrower's own transaction lands after it
        uint256 loanId = _borrowWith(q, data, UNITS, PRINCIPAL, MIN_TENOR);
        assertGt(loanId, 0, "the borrower's quote still opened");
        assertTrue(terms.spent(q.nonce), "and only then is its nonce spent");
    }

    // ---- surface ruling 3, in the attacker's order ----

    /// @notice Ruling 3: a stolen curator key lands no widening at once. A cap raise waits on the vault and the guardian's `revokePendingCap` kills it.
    /// @notice A row widening bundled with a cut waits whole on the terms, and the guardian revokes that too.
    function test_attack_aStolenCuratorKeyCannotLandAWideningInsideACut() public {
        uint192 cap0 = _capOf(address(tokA));
        Row memory live = terms.rowOf(address(tokA));

        // the attacker, holding the curator key: a cap raise on the vault
        vm.prank(curator);
        vault.submitCap(address(tokA), CAP * 4);
        assertEq(_capOf(address(tokA)), cap0, "the raise did not land at once");

        // and one row edit that looks like a cut and widens the term
        Row memory bundled = _row();
        (bundled.maxTenor, bundled.maxPrincipal) = (MAX_TENOR, uint128(PRINCIPAL));
        vm.prank(curator);
        terms.submitRow(address(tokA), bundled);
        assertEq(terms.rowOf(address(tokA)).maxTenor, live.maxTenor, "the widening did not land at once");
        assertEq(terms.rowOf(address(tokA)).maxPrincipal, live.maxPrincipal, "nor did the cut it was wrapped in");

        // the guardian's answer inside the timelock
        vm.prank(guardian);
        vault.revokePendingCap(address(tokA));
        vm.prank(guardian);
        terms.revokePending(address(tokA));
        _warpBy(TIMELOCK);
        vm.expectRevert(IInKindVault.NothingDue.selector);
        vault.acceptCap(address(tokA));
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.accept(address(tokA));
        assertEq(_capOf(address(tokA)), cap0, "the cap never rose");
        assertEq(terms.rowOf(address(tokA)).maxTenor, live.maxTenor, "and the row never widened");
    }

    /// @notice A curator's whole row built from a read taken before a guardian's cut lands PENDING as the raise it now is, and the cut stands.
    /// @notice The stale row is the terms' alone: the curator's cap cut goes through the vault's `submitCap`, and lands at once.
    /// @dev The guardian's own copy of that stale row is a raise too, so it refuses outright; the guardian lowers only through a cut.
    function test_attack_aWholeRowBuiltBeforeACutLandsPendingAndCannotUndoIt() public {
        // the curator's Safe builds a maxTenor cut from the live row, each row read fresh so no edit aliases another
        Row memory seen = terms.rowOf(address(tokA));
        Row memory stale = terms.rowOf(address(tokA));
        stale.maxTenor = MIN_TENOR;

        // the guardian's maxPrincipal cut lands first
        Row memory cut = terms.rowOf(address(tokA));
        cut.maxPrincipal = uint128(PRINCIPAL);
        vm.prank(guardian);
        terms.submitRow(address(tokA), cut);
        uint256 snap = vm.snapshotState();

        // the curator's transaction lands after it, its cap cut through the vault's own door
        vm.prank(curator);
        terms.submitRow(address(tokA), stale);
        _setCap(curator, address(tokA), CAP / 2);
        Row memory live = terms.rowOf(address(tokA));
        assertEq(live.maxPrincipal, PRINCIPAL, "the cut maxPrincipal stands");
        assertEq(live.maxTenor, seen.maxTenor, "and the maxTenor cut the stale row carried did not land at once");
        (Row memory p, uint64 validAt) = terms.pendingRowOf(address(tokA));
        assertEq(p.maxPrincipal, seen.maxPrincipal, "the stale row waits as a maxPrincipal raise");
        assertEq(validAt, _now() + TIMELOCK, "for the whole timelock");
        assertEq(_capOf(address(tokA)), CAP / 2, "while the cap cut, on the vault, landed at once");

        // the guardian vets it as a raise and drops it by cutting, landing the maxTenor cut through its own door
        cut.maxTenor = MIN_TENOR;
        vm.prank(guardian);
        terms.submitRow(address(tokA), cut);
        (, validAt) = terms.pendingRowOf(address(tokA));
        assertEq(validAt, 0, "the raise is dropped");
        assertEq(terms.rowOf(address(tokA)).maxTenor, MIN_TENOR, "and the maxTenor cut landed");
        _warpBy(TIMELOCK);
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        terms.accept(address(tokA));
        assertEq(terms.rowOf(address(tokA)).maxPrincipal, PRINCIPAL, "the pre-cut maxPrincipal never comes back");

        // the guardian's copy of the same stale row is refused outright: it may only cut
        vm.revertToState(snap);
        vm.prank(guardian);
        vm.expectRevert(IInKindTerms.NotCurator.selector);
        terms.submitRow(address(tokA), stale);
        assertEq(terms.rowOf(address(tokA)).maxPrincipal, PRINCIPAL, "and the cut stands");
    }

    // ---- (3) a stolen appraiser key ----

    /// @dev The coverage line for `principal` at `price`: the units a recordless default forfeits, as the hub rounds it.
    function _line(uint256 principal, uint256 price) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(COVERAGE * principal, 1 << 96, price * 1e18) + 1;
    }

    /// @notice A stolen key signs any price, so the thief pledges dust and walks: the token's whole room lends out, and not one atom more.
    /// @notice The row's maxPrincipal bounds each loan and the cap bounds their sum; the forfeited dust recovers almost nothing at spot.
    function test_attack_aStolenKeysWalkIsBoundedByTheTokensRoom() public {
        uint256 maxp = 10_000e6;
        Listing[] memory l = _listings();
        (l[0].cap, l[0].row.maxPrincipal) = (uint192(5 * maxp), uint128(maxp));
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        uint256 inflated = PRICE * 1000;
        uint256 line = _line(maxp, PriceGrid.down(inflated));

        // the thief, holding the appraiser's key: one loan over the row's maxPrincipal is refused by the row
        Quote memory big = _quote(address(tokA), inflated);
        (big.borrower, big.maxPrincipal) = (stranger, 5 * maxp);
        _fund(address(tokA), stranger, line * 5);
        bytes memory bigData = _data(big);
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.OverMaxPrincipal.selector);
        vault.borrow(_req(address(tokA), line * 5, 5 * maxp, MIN_TENOR), bigData, "");

        // so it splits the room into maxPrincipal loans, each on a dust pledge signed at a thousand times the price
        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            Quote memory q = _quote(address(tokA), inflated);
            (q.borrower, q.maxPrincipal) = (stranger, maxp);
            _fund(address(tokA), stranger, line);
            bytes memory data = _data(q);
            vm.prank(stranger);
            ids[i] = vault.borrow(_req(address(tokA), line, maxp, MIN_TENOR), data, "");
        }
        Quote memory sixth = _quote(address(tokA), inflated);
        sixth.borrower = stranger;
        _fund(address(tokA), stranger, line);
        bytes memory sixthData = _data(sixth);
        vm.prank(stranger);
        vm.expectRevert(AceVaultFlows.OverCap.selector);
        vault.borrow(_req(address(tokA), line, MIN_PRINCIPAL, MIN_TENOR), sixthData, "");
        (uint256 lent,) = ace.lenderByCollateral(address(vault), address(usdc), address(tokA));
        assertEq(lent, 5 * maxp, "the thief's principal is the token's room exactly");

        // and walks: every loan defaults, and the vault takes home exactly the lines
        _toExpiry(ids[4]);
        vm.prank(keeper);
        uint256[] memory out = vault.collectForfeited(ids);
        uint256 home;
        for (uint256 i; i < 5; ++i) {
            assertEq(out[i], line, "each walk forfeits exactly its dust line");
            home += out[i];
        }

        // valued at the honest price, the dust recovers under one percent of the room: the loss is the room, no more
        uint256 recovered = FullMath.mulDiv(home, PRICE, 1 << 96);
        assertLt(recovered, 5 * maxp / 100, "the forfeited lines recover almost nothing");
        assertGt(recovered, 0, "LIVENESS: the lines came home and are worth something");
    }

    /// @notice With two tokens whose rows sum past the vault-wide total, the stolen key's walk stops at the total, the smaller bound.
    function test_attack_aStolenKeysWalkAcrossTwoTokensIsBoundedByTheTotal() public {
        uint256 maxp = 10_000e6;
        Listing[] memory l = _listings();
        (l[0].cap, l[0].row.maxPrincipal) = (uint192(5 * maxp), uint128(maxp));
        (l[1].cap, l[1].row.maxPrincipal) = (uint192(5 * maxp), uint128(maxp));
        total = uint192(6 * maxp);
        vault = _deploy(_cfg(0), _ik(), l);
        _lp(alice, LP_CASH);
        uint256 inflated = PRICE * 1000;
        uint256 line = _line(maxp, PriceGrid.down(inflated));

        // the thief walks both rows a maxPrincipal loan at a time, alternating, until the vault refuses
        for (uint256 i; i < 6; ++i) {
            address c = i % 2 == 0 ? address(tokA) : address(tokB);
            Quote memory q = _quote(c, inflated);
            (q.borrower, q.maxPrincipal) = (stranger, maxp);
            _fund(c, stranger, line);
            bytes memory data = _data(q);
            vm.prank(stranger);
            vault.borrow(_req(c, line, maxp, MIN_TENOR), data, "");
        }
        Quote memory seventh = _quote(address(tokB), inflated);
        seventh.borrower = stranger;
        _fund(address(tokB), stranger, line);
        bytes memory seventhData = _data(seventh);
        vm.prank(stranger);
        vm.expectRevert(AceVaultCaps.OverTotal.selector);
        vault.borrow(_req(address(tokB), line, MIN_PRINCIPAL, MIN_TENOR), seventhData, "");
        (uint256 lentA,) = ace.lenderByCollateral(address(vault), address(usdc), address(tokA));
        (uint256 lentB,) = ace.lenderByCollateral(address(vault), address(usdc), address(tokB));
        assertEq(lentA + lentB, 6 * maxp, "the thief's principal is the total, under the two rows' sum of ten");
        assertLt(lentB, 5 * maxp, "and the second row still had room the total did not");
    }
}
