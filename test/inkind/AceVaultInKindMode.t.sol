// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CapListing, ProductConfig} from "../../src/curator/libraries/AceVaultCaps.sol";
import {AceVaultFlows} from "../../src/curator/libraries/AceVaultFlows.sol";
import {IAceVaultDoor} from "../../src/interfaces/IAceVaultDoor.sol";
import {AceVaultBaseRig} from "../curator/vault/AceVaultBaseRig.sol";
import {MockTerms} from "../curator/vault/MockTerms.sol";
import {InKindVaults} from "../utils/InKindVaults.sol";
import {VaultSeed} from "../utils/VaultSeed.sol";
import {IInKindTerms, IInKindVault, Listing, Quote} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @title AceVaultInKindMode
/// @notice In-kind mode on the one AceVault: the tracker's slots, entry and the supply bound, the collect's refusals, and whom the context word charges.
/// @dev `SELF` in a raw cap list stands for the vault's own address, which is known only once the terms are deployed.
contract AceVaultInKindModeTest is InKindRig {
    address internal constant SELF = address(0x5E1F);
    uint256 internal constant BOUND = 1 << 160; // the in-kind supply bound

    /// @dev The pair with the terms listing `l` and the vault taking cap list `c` exactly as given, `SELF` replaced by its own address.
    function _raw(Listing[] memory l, CapListing[] memory c) internal returns (IInKindVault v) {
        (address t, address predicted) = InKindVaults.prepare(_cfg(0), _ik(), l, NAME);
        _self(c, predicted);
        v = IInKindVault(address(new AceVault(_cfg(0), InKindVaults.product(t, _ik()), c, NAME, SYMBOL)));
        terms = IInKindTerms(t);
    }

    /// @dev Expect the vault constructor to refuse cap list `c` with `err`, the terms deployed first.
    function _rawExpecting(bytes4 err, Listing[] memory l, CapListing[] memory c) internal {
        (address t, address predicted) = InKindVaults.prepare(_cfg(0), _ik(), l, NAME);
        _self(c, predicted);
        ProductConfig memory pc = InKindVaults.product(t, _ik());
        vm.expectRevert(err);
        new AceVault(_cfg(0), pc, c, NAME, SYMBOL);
    }

    function _self(CapListing[] memory c, address v) internal pure {
        for (uint256 i; i < c.length; i++) {
            if (c[i].key == SELF) c[i].key = v;
        }
    }

    /// @dev A borrow of the rig's ask on `coll` with a valid quote, expected to refuse `err`; returns the quote's nonce.
    function _borrowRefused(address coll, bytes4 err) internal returns (uint256 nonce) {
        Quote memory q = _quote(coll, PRICE);
        bytes memory data = _data(q);
        _fund(coll, borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(err);
        vault.borrow(_req(coll, UNITS, PRINCIPAL, MIN_TENOR), data, "");
        return q.nonce;
    }

    // ---- slots ----

    /// @notice A nonzero wildcard refuses at init and at `submitCap`; a zero one is the figure in-kind mode takes.
    function testRevert_aNonzeroWildcardRefusesAtInitAndAtSubmitCap() public {
        CapListing[] memory c = new CapListing[](2);
        (c[0], c[1]) = (CapListing(address(0), 1), CapListing(SELF, total));
        _rawExpecting(IInKindVault.WildcardInKind.selector, _listings(), c);
        vm.prank(curator);
        vm.expectRevert(IInKindVault.WildcardInKind.selector);
        vault.submitCap(address(0), 1);
        vm.prank(curator);
        vault.submitCap(address(0), 0);
        (uint192 w, bool listed) = lens.capOf(address(vault), address(0));
        assertEq(w, 0, "CONTROL: a zero wildcard lands");
        assertTrue(listed, "as a listed figure");
    }

    /// @notice The asset as a key refuses at init and at `submitCap`; the zero wildcard, the total and a key listed twice are accepted.
    function test_theAssetRefusesAndTheSpecialKeysAndADuplicateAreAccepted() public {
        Listing[] memory l = new Listing[](1);
        l[0] = _listing(address(tokA), CAP);
        CapListing[] memory c = new CapListing[](3);
        (c[0], c[1], c[2]) = (CapListing(address(usdc), CAP), CapListing(address(tokA), CAP), CapListing(SELF, total));
        _rawExpecting(IInKindVault.CashIsNotCollateral.selector, l, c);
        vm.prank(curator);
        vm.expectRevert(IInKindVault.CashIsNotCollateral.selector);
        vault.submitCap(address(usdc), CAP);
        c = new CapListing[](4);
        (c[0], c[1], c[2], c[3]) = (CapListing(address(0), 0), CapListing(address(tokA), CAP), CapListing(address(tokA), CAP), CapListing(SELF, total));
        vault = _raw(l, c);
        (uint192 w, bool wl) = lens.capOf(address(vault), address(0));
        assertTrue(wl && w == 0, "the zero wildcard is accepted, listed");
        assertEq(_capOf(address(tokA)), CAP, "the key listed twice is accepted at its cap");
        assertEq(_capOf(address(vault)), total, "and the total");
    }

    /// @notice A collateral the terms price but the vault never listed cannot borrow: its effective cap is the zero wildcard.
    function test_anUnlistedCollateralCannotBorrow() public {
        CapListing[] memory c = new CapListing[](2);
        (c[0], c[1]) = (CapListing(address(tokA), CAP), CapListing(SELF, total));
        vault = _raw(_listings(), c);
        _lp(alice, LP_CASH);
        assertEq(terms.rowOf(address(tokB)).maxTenor, ROW_MAX_TENOR, "premise: the terms price it");
        assertEq(vault.effectiveCap(address(tokB)), 0, "premise: the vault never listed it");
        _borrowRefused(address(tokB), AceVaultFlows.OverCap.selector);
        assertGt(_open(address(tokA)), 0, "CONTROL: the listed one lends");
    }

    // ---- entry ----

    /// @notice Entry waits on a pot a stranger settled: deposit and mint refuse while it is uncollected, and the collect still brings it home.
    function test_entryWaitsOnAPotAStrangerSettled() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        uint256 pot = _expectedPot(loanId);
        vm.prank(stranger);
        ace.forceClose(loanId);
        (uint256 unsold,) = ace.lenderUnresolved(address(vault), address(usdc));
        assertEq(unsold, 1, "premise: the hub reports the vault's pot uncollected");
        _expectEntryShut(bob, 1_000e6, "a deposit over the uncollected pot");
        _armDeposit(carol, 1_000e6);
        vm.prank(carol);
        vm.expectRevert(IInKindVault.InventoryUnsold.selector);
        vault.mint(1e12, carol);
        assertEq(_collect(loanId), pot, "the vault's own collect still brings the pot home whole");
    }

    /// @notice In kind the guardian may exempt a dead pot, as out of kind; anyone else refuses `NotGuardian`.
    function test_exemptDeadPots_theGuardianExemptsInKindAndNobodyElse() public {
        vm.prank(stranger);
        vm.expectRevert(IInKindVault.NotGuardian.selector);
        vault.exemptDeadPots(0);
        vm.prank(curator);
        vm.expectRevert(IInKindVault.NotGuardian.selector);
        vault.exemptDeadPots(0);
        vm.prank(guardian);
        vault.exemptDeadPots(0);
    }

    /// @notice Entry stops at 2^160 shares: one share past it refuses `OverSupply`, `maxMint` and `maxDeposit` answer the headroom, the bound is reachable.
    function test_theSupplyBoundRefusesAndTheMaxViewsAnswerIt() public {
        uint256 big = (BOUND - vault.SEED_SHARES()) / 1e6; // the genesis seed's shares already count against the bound
        _lp(alice, big);
        uint256 supply = vault.totalSupply();
        assertEq(supply, big * 1e6 + vault.SEED_SHARES(), "premise: the first entry mints at the opening price");
        uint256 room = BOUND - supply;
        assertEq(vault.maxMint(bob), room, "maxMint answers the shares left under the bound");
        assertEq(vault.maxDeposit(bob), room / 1e6, "maxDeposit the cash they price at");
        usdc.mint(bob, room);
        vm.startPrank(bob);
        usdc.approve(address(vault), room);
        vm.expectRevert(IInKindVault.OverSupply.selector);
        vault.mint(room + 1, bob);
        vm.expectRevert(IInKindVault.OverSupply.selector);
        vault.deposit(room / 1e6 + 1, bob);
        vault.mint(room, bob);
        vm.stopPrank();
        assertEq(vault.totalSupply(), BOUND, "the bound is reachable exactly");
        assertEq(vault.maxMint(bob), 0, "and both views read zero at it");
        assertEq(vault.maxDeposit(bob), 0, "maxDeposit too");
        vm.prank(bob);
        vm.expectRevert(IInKindVault.OverSupply.selector);
        vault.mint(1, bob);
    }

    /// @notice Under the bound every share move succeeds with the tracker on, and the tracker follows each one.
    function testFuzz_everyShareMoveSucceedsUnderTheBound(uint256 a, uint256 b, uint256 x, uint256 y, uint256 dt) public {
        uint256 half = (BOUND - vault.SEED_SHARES()) / 1e6 / 2;
        a = bound(a, 1, half);
        b = bound(b, 1, half);
        uint256 sa = _lp(alice, a);
        _warpBy(bound(dt, 0, 2 * MIN_TENOR));
        _lp(bob, b);
        x = bound(x, 0, sa);
        vm.prank(alice);
        vault.transfer(bob, x);
        _warpBy(MIN_TENOR);
        y = bound(y, 0, vault.balanceOf(bob));
        vm.prank(bob);
        vault.transfer(carol, y);
        uint256 r = vault.balanceOf(alice);
        if (vault.previewRedeem(r) != 0) {
            vm.prank(alice);
            vault.redeem(r, alice, alice);
        }
        assertLe(vault.totalSupply(), BOUND, "premise: under the bound");
        assertEq(_tracked(alice) + _tracked(bob) + _tracked(carol), vault.totalSupply() - vault.SEED_SHARES(), "the tracker follows every move");
        assertEq(_tracked(alice) + _tracked(bob) + _tracked(carol), _trackedSupply(), "and its tracked supply is the holders' sum");
    }

    // ---- the collect ----

    /// @notice The collect refuses a loan whose market names another lender.
    function testRevert_theCollectRefusesALoanOfAnotherLender() public {
        _lp(alice, LP_CASH);
        (IInKindVault mine, IInKindTerms mineTerms) = (vault, terms);
        vault = _deploy(_cfg(0), _ik(), _listings());
        _lp(bob, LP_CASH);
        uint256 theirs = _open(address(tokA));
        _toExpiry(theirs);
        (vault, terms) = (mine, mineTerms);
        vm.prank(keeper);
        vm.expectRevert(IInKindVault.NotOurLoan.selector);
        vault.collectForfeited(_ids(theirs));
    }

    /// @notice The collect refuses a loan whose market quotes an asset other than the vault's, and collects it on its real market.
    function testRevert_theCollectRefusesAMarketQuotingAnotherAsset() public {
        _lp(alice, LP_CASH);
        uint256 loanId = _open(address(tokA));
        _toExpiry(loanId);
        bytes32 id = ace.loanMarket(loanId);
        MarketParams memory mp = ace.idToMarketParams(id);
        mp.quote = address(tokB);
        vm.mockCall(address(ace), abi.encodeCall(ace.idToMarketParams, (id)), abi.encode(mp));
        vm.prank(keeper);
        vm.expectRevert(IInKindVault.NotOurLoan.selector);
        vault.collectForfeited(_ids(loanId));
        vm.clearMockedCalls();
        assertGt(_collect(loanId), 0, "CONTROL: on its real market the same loan collects");
    }

    // ---- whom the context word charges ----

    /// @notice A claim's escrow burn is charged to the claimer the base names, and no other requester; a lapse hands the escrow back charging nobody.
    function test_theEscrowBurnIsChargedToTheHolderTheBaseNames() public {
        uint256 a = _lp(alice, 1_000e6);
        uint256 b = _lp(bob, 1_000e6);
        vm.prank(alice);
        vault.requestExit(a / 2);
        vm.prank(bob);
        vault.requestExit(b / 2);
        assertEq(_tracked(address(vault)), 0, "premise: the escrow tracks nothing");
        vm.prank(bob);
        vault.claimExit(b / 4, bob, 0);
        assertEq(_tracked(bob), b - b / 4, "the claimer is charged the burn");
        assertEq(_tracked(alice), a, "the other requester is not");
        (, uint64 expiresAt) = lens.requestOf(address(vault), alice);
        _warpTo(expiresAt);
        vault.lapseExit(alice);
        assertEq(vault.balanceOf(alice), a, "premise: the lapse handed alice her escrow back");
        assertEq(_tracked(alice), a, "and moved no tracked share");
        assertGt(vault.balanceOf(address(vault)), 0, "premise: bob still has shares in escrow");
        assertEq(_tracked(alice) + _tracked(bob), vault.totalSupply() - vault.SEED_SHARES(), "every share, escrowed or not, is tracked once, to its holder");
    }

    /// @notice A mint is tracked to its receiver at once: an entry for another lands on the receiver, never the payer, and the fee on the curator.
    function test_aFeeMintAndAnEntryForAnotherAreTrackedToTheReceiver() public {
        vault = _deploy(_cfg(1000), _ik(), _listings());
        uint256 own = _lp(curator, 1_000e6);
        _lp(alice, 1_000_000e6);
        uint256 gift = _lpFor(bob, carol, 1_000e6);
        assertEq(_tracked(carol), gift, "an entry for another is tracked to the receiver");
        assertEq(_tracked(bob), 0, "and the payer tracks nothing");
        usdc.mint(address(vault), 100_000e6);
        vault.crank();
        _warpBy(VEST_W + 1);
        vault.collectFee();
        uint256 fee = vault.balanceOf(curator) - own;
        assertGt(fee, 0, "premise: a fee minted");
        assertEq(_tracked(curator), own + fee, "the curator's own deposit and its fee are both tracked to it");
    }

    // ---- the quote's nonce ----

    /// @notice A base refusal after a valid quote burns no nonce: the same quote lands once the cause is gone; a cap refusal burns none either.
    function test_aBaseRefusalAfterAValidQuoteBurnsNoNonce() public {
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _data(q);
        _fund(address(tokA), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(AceVaultFlows.OverLendable.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, "");
        assertFalse(terms.spent(q.nonce), "the refused borrow spent no nonce");
        _lp(alice, LP_CASH);
        assertGt(_borrowWith(q, data, UNITS, PRINCIPAL, MIN_TENOR), 0, "the same quote lands once there is cash");
        assertTrue(terms.spent(q.nonce), "and spends its nonce then");
        _setCap(guardian, address(tokB), 0);
        assertFalse(terms.spent(_borrowRefused(address(tokB), AceVaultFlows.OverCap.selector)), "a cap refusal burns none either");
    }
}

/// @title AceVaultInKindModeHubAsk
/// @notice The mode switches on the base rig, its product a stub: the in-kind rail and the door at deploy, and what a hub-ask vault refuses or pays.
contract AceVaultInKindModeHubAskTest is AceVaultBaseRig {
    uint256 internal constant TRANSFER_PIN = 31_954; // the hub-ask transfer's measured cost before in-kind mode, plus 50, plus 66 for three getters

    function _expectDeployRevert(ProductConfig memory pc, bytes4 sel) internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockTerms t = new MockTerms(predicted, address(ace));
        pc.terms = address(t);
        CapListing[] memory c = _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED));
        VaultSeed.fund(_cfg(), predicted);
        vm.expectRevert(sel);
        new AceVault(_cfg(), pc, c, "Base", "bVLT");
    }

    /// @notice In-kind mode deploys on a rail of thirty days and refuses one a second longer, though a year is hub-ask's ceiling.
    function test_inKindDeploysOnAThirtyDayRailAndRefusesPastIt() public {
        ProductConfig memory pc = _pc();
        pc.inKind = true;
        (AceVault v,) = _deploy(_cfg(), pc, _caps(UNCAPPED, 0, UNCAPPED));
        assertTrue(v.IN_KIND(), "in-kind mode deploys");
        assertEq(v.MAX_TENOR(), 30 days, "on a thirty-day rail");
        pc.maxTenor = 30 days + 1;
        _expectDeployRevert(pc, AceVault.TenorRailOutOfBounds.selector);
        pc.maxTenor = 365 days;
        _expectDeployRevert(pc, AceVault.TenorRailOutOfBounds.selector);
    }

    /// @notice An unbound door refuses `DoorNotBound`, alone or beside in-kind mode.
    function testRevert_anUnboundDoorRefusesDoorNotBoundAloneOrInKind() public {
        ProductConfig memory pc = _pc();
        pc.door = stranger;
        _expectDeployRevert(pc, IAceVaultDoor.DoorNotBound.selector);
        pc.inKind = true;
        _expectDeployRevert(pc, IAceVaultDoor.DoorNotBound.selector);
    }

    /// @notice A hub-ask vault's collect refuses `ModeUnbuilt` on an expired loan of its own.
    function testRevert_aHubAskCollectRefusesModeUnbuilt() public {
        uint256 loanId = _borrow();
        _warpAtLeastTo(read.loan(loanId).expiry);
        uint256[] memory ids = new uint256[](1);
        ids[0] = loanId;
        vm.prank(stranger);
        vm.expectRevert(IInKindVault.ModeUnbuilt.selector);
        IInKindVault(address(vault)).collectForfeited(ids);
    }

    /// @notice A REGRESSION PIN: a hub-ask share transfer costs at most its measured cost before in-kind mode plus 50 gas, the tracker's mode read.
    /// @dev The vault, sender and receiver are cooled and the 21,000 transaction base is left out.
    /// @dev The pin still bounds the in-kind tracker's read; the 66 gas via-IR dispatch of `MIN_SEED`, `SEED_SHARES` and `HOLD_BPS` is priced in.
    function test_aHubAskTransferCostsAtMostTheBaselinePlusFifty() public {
        uint256 x = vault.balanceOf(alice) / 10;
        vm.cool(address(vault));
        vm.cool(alice);
        vm.cool(bob);
        vm.prank(alice);
        uint256 g = gasleft();
        vault.transfer(bob, x);
        uint256 used = g - gasleft();
        emit log_named_uint("hub-ask transfer gas", used);
        assertEq(vault.balanceOf(bob), x, "premise: the transfer landed");
        assertLe(used, TRANSFER_PIN, "a hub-ask transfer pays no more than the pin");
    }
}
