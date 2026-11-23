// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams} from "../../src/ace/hub/Types.sol";
import {AceVault} from "../../src/vault/AceVault.sol";
import {Lend, RefinanceRequest} from "../../src/interfaces/IVaultTerms.sol";
import {InKindConfig, InKindVaults} from "../utils/InKindVaults.sol";
import {IInKindTerms, IInKindVault, Quote, Row} from "./InKindSurface.sol";
import {InKindRig} from "./InKindRig.sol";

/// @dev The figures InKindTerms reads back from its vault, each settable, so one leg of the binding can disagree at a time.
contract VaultFiguresStub {
    address public asset;
    uint64 public MIN_TENOR;
    uint64 public MAX_TENOR;
    bool public IN_KIND = true;
    uint64 public CAP_TIMELOCK;
    address public CURATOR;
    address public GUARDIAN;

    constructor(address a, uint64 lo, uint64 hi, uint64 lock, address c, address g) {
        (asset, MIN_TENOR, MAX_TENOR, CAP_TIMELOCK, CURATOR, GUARDIAN) = (a, lo, hi, lock, c, g);
    }

    function set(address a, uint64 lo, uint64 hi, bool k, uint64 lock) external {
        (asset, MIN_TENOR, MAX_TENOR, IN_KIND, CAP_TIMELOCK) = (a, lo, hi, k, lock);
    }
}

/// @title InKindTermsBinding
/// @notice InKindTerms is bound to the one in-kind vault it was built for: the binding at every borrow, the vault-only write calls,
/// @notice the answers it leaves to the vault (no room, no entry cap, no refinance), and the timelock it reads from the vault at each use.
contract InKindTermsBindingTest is InKindRig {
    VaultFiguresStub internal stub;
    IInKindTerms internal built; // terms built for the stub

    function setUp() public override {
        super.setUp();
        stub = new VaultFiguresStub(address(usdc), MIN_TENOR, MAX_TENOR, TIMELOCK, curator, guardian);
        built = IInKindTerms(
            InKindVaults.create(
                InKindVaults.TERMS_ARTIFACT,
                abi.encode(InKindVaults.termsConfig(address(stub), address(usdc), _ik()), InKindVaults.termsListings(_listings()), NAME)
            )
        );
    }

    function _mp() internal view returns (MarketParams memory mp) {
        mp.quote = address(usdc);
        mp.collateral = address(tokA);
    }

    /// @dev A borrow's payload as the vault hands it on: a quote and a signature the binding never reads.
    function _payload(uint256 nonce) internal view returns (bytes memory) {
        Quote memory q =
            Quote({collateral: address(tokA), borrower: borrower, price: PRICE, maxPrincipal: PRINCIPAL, maxTenor: ROW_MAX_TENOR, nonce: nonce, issuedAt: 0});
        return abi.encode(q, bytes(""));
    }

    function _before(Lend kind, uint256 nonce) internal {
        vm.prank(address(stub));
        built.beforeLend(kind, _mp(), 0, _payload(nonce));
    }

    function _beforeExpecting(Lend kind, uint256 nonce, bytes4 err) internal {
        MarketParams memory mp = _mp();
        bytes memory data = _payload(nonce);
        vm.prank(address(stub));
        vm.expectRevert(err);
        built.beforeLend(kind, mp, 0, data);
    }

    // ---- the binding ----

    /// @notice CONTROL: on a vault whose figures match, a borrow's `beforeLend` passes and spends the quote's nonce.
    function test_binding_aMatchingVaultSpendsTheNonce() public {
        _before(Lend.Borrow, 7);
        assertTrue(built.spent(7), "the nonce is spent");
        _beforeExpecting(Lend.Borrow, 7, IInKindTerms.QuoteUsed.selector);
    }

    /// @notice Each figure the terms copied at build refuses `VaultMismatch` when the vault disagrees: the asset, either end of the rail, the mode.
    function testRevert_binding_eachLegRefusesVaultMismatch() public {
        stub.set(address(tokB), MIN_TENOR, MAX_TENOR, true, TIMELOCK);
        _beforeExpecting(Lend.Borrow, 1, IInKindTerms.VaultMismatch.selector);
        stub.set(address(usdc), MIN_TENOR + 1, MAX_TENOR, true, TIMELOCK);
        _beforeExpecting(Lend.Borrow, 1, IInKindTerms.VaultMismatch.selector);
        stub.set(address(usdc), MIN_TENOR, MAX_TENOR - 1, true, TIMELOCK);
        _beforeExpecting(Lend.Borrow, 1, IInKindTerms.VaultMismatch.selector);
        stub.set(address(usdc), MIN_TENOR, MAX_TENOR, false, TIMELOCK);
        _beforeExpecting(Lend.Borrow, 1, IInKindTerms.VaultMismatch.selector);
        _beforeExpecting(Lend.Extend, 1, IInKindTerms.VaultMismatch.selector);
        assertFalse(built.spent(1), "no refusal spent the nonce");
    }

    /// @notice An extension's `beforeLend` checks the binding and spends nothing.
    function test_binding_anExtensionSpendsNoNonce() public {
        _before(Lend.Extend, 9);
        assertFalse(built.spent(9), "an extension carries no quote nonce");
    }

    /// @notice On a real pair whose vault runs a shorter rail floor than its terms, the borrow refuses `VaultMismatch` past every base check.
    function testRevert_binding_aRealPairOnAnotherRailOpensNoLoan() public {
        InKindConfig memory ik = _ik();
        (address t, address predicted) = InKindVaults.prepare(_cfg(0), ik, _listings(), NAME);
        ik.minTenor = MIN_TENOR - 1 days;
        vault = IInKindVault(address(new AceVault(_cfg(0), InKindVaults.product(t, ik), InKindVaults.caps(predicted, _listings(), total), NAME, SYMBOL)));
        terms = IInKindTerms(t);
        assertEq(vault.MIN_TENOR(), MIN_TENOR - 1 days, "premise: the vault's rail floor is a day under the terms'");
        _lp(alice, LP_CASH);
        Quote memory q = _quote(address(tokA), PRICE);
        bytes memory data = _data(q);
        _fund(address(tokA), borrower, UNITS);
        vm.prank(borrower);
        vm.expectRevert(IInKindTerms.VaultMismatch.selector);
        vault.borrow(_req(address(tokA), UNITS, PRINCIPAL, MIN_TENOR), data, "");
    }

    // ---- the write calls ----

    /// @notice Only the vault makes either write call: `beforeLend` and `afterLend` refuse `NotVault` to anyone else.
    function testRevert_theWriteCallsAreTheVaultsOnly() public {
        MarketParams memory mp = _mp();
        bytes memory data = _payload(1);
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NotVault.selector);
        built.beforeLend(Lend.Borrow, mp, 0, data);
        vm.prank(stranger);
        vm.expectRevert(IInKindTerms.NotVault.selector);
        built.afterLend(Lend.Borrow, mp, 1, borrower, data);
        vm.prank(address(stub));
        built.afterLend(Lend.Borrow, mp, 1, borrower, data);
    }

    // ---- what the terms leave to the vault ----

    /// @notice The terms bound neither placement nor entry: `room` and `entryCap` answer the maximum, whatever they are asked.
    function test_roomAndEntryCapAnswerTheMaximum() public view {
        assertEq(built.room(_mp()), type(uint256).max, "no room of the terms' own");
        assertEq(built.entryCap(alice, 0), type(uint256).max, "no entry cap at zero NAV");
        assertEq(built.entryCap(stranger, type(uint256).max), type(uint256).max, "nor at any other");
    }

    /// @notice The terms price no refinance: `refinanceTerms` refuses `NoRefinance`.
    function testRevert_refinanceTerms_refusesNoRefinance() public {
        RefinanceRequest memory r;
        vm.expectRevert(IInKindTerms.NoRefinance.selector);
        built.refinanceTerms(borrower, 1, r, "");
    }

    // ---- the timelock ----

    /// @notice The terms' timelock is the vault's `CAP_TIMELOCK`, read at each submit: a row and an appointment wait the figure the vault answers then.
    function test_theTimelockIsReadFromTheVaultAtEachSubmit() public {
        Row memory wider = _row();
        wider.maxPrincipal += 1;
        vm.prank(curator);
        built.submitRow(address(tokA), wider);
        (, uint64 validAt) = built.pendingRowOf(address(tokA));
        assertEq(validAt, _now() + TIMELOCK, "a widening waits the vault's timelock");
        stub.set(address(usdc), MIN_TENOR, MAX_TENOR, true, 5 days);
        vm.prank(curator);
        built.submitAppraiser(stranger);
        (, uint64 seatAt) = built.pendingAppraiser();
        assertEq(seatAt, _now() + 5 days, "an appointment waits the figure the vault answers now");
        vm.prank(curator);
        built.submitRow(address(tokA), wider);
        (, validAt) = built.pendingRowOf(address(tokA));
        assertEq(validAt, _now() + 5 days, "and so does a row submitted after the change");
        _warpBy(5 days - 1);
        vm.expectRevert(IInKindTerms.NothingDue.selector);
        built.accept(address(tokA));
        _warpBy(1);
        built.accept(address(tokA));
        assertEq(built.rowOf(address(tokA)).maxPrincipal, wider.maxPrincipal, "the row lands once the vault's timelock has run");
    }

    /// @notice On a real pair the terms wait the vault's own `CAP_TIMELOCK`, which the pair's deploy set.
    function test_aRealPairWaitsTheVaultsTimelock() public {
        InKindConfig memory ik = _ik();
        ik.timelock = 5 days;
        vault = _deploy(_cfg(0), ik, _listings());
        assertEq(vault.CAP_TIMELOCK(), 5 days, "premise: the vault's timelock");
        vm.prank(curator);
        terms.submitAppraiser(stranger);
        (, uint64 seatAt) = terms.pendingAppraiser();
        assertEq(seatAt, _now() + 5 days, "the appointment waits it");
    }
}
