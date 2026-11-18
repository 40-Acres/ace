// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVaultCaps} from "../../../src/curator/AceVaultCaps.sol";
import {BorrowRequest, Terms} from "../../../src/curator/AceVaultFlows.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {IAceVaultLens, VaultLens} from "../../utils/VaultLens.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultViewsTest
/// @notice The vault's views over its product: ERC-4626's entry maxima never revert, whatever the product's entry cap does, and the deposit refuses
/// @notice on the same read; `previewTerms` asks for the named borrower and refuses as the door's own checks would; the drawdown views start clean.
/// @dev The preview lives on `AceVaultLens`, which runs the door's own library checks on the vault's figures.
contract AceVaultViewsTest is AceVaultBaseRig {
    uint256 internal constant VIEW_GAS = 5_000_000;
    uint256 internal constant STOP_LINE = 23_000; // the plan's runtime ceiling for the base, in the profile this suite compiles under
    IAceVaultLens internal lens;

    function setUp() public override {
        super.setUp();
        lens = VaultLens.deploy();
    }

    /// @dev A failed entry cap reads zero: both maxima answer it without reverting, and the deposit refuses on it by ERC-4626's own name.
    function _assertEntryCapReadsZero(MockTerms.Mode m) internal {
        terms.setEntryCap(m, 1e30);
        assertEq(vault.maxDeposit{gas: VIEW_GAS}(bob), 0, "maxDeposit answered past a failed entry cap, or reverted");
        assertEq(vault.maxMint{gas: VIEW_GAS}(bob), 0, "maxMint answered past a failed entry cap, or reverted");
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1e6, 0));
        vault.deposit{gas: 2 * VIEW_GAS}(1e6, bob);
        vm.stopPrank();
    }

    function test_AnEntryCapThatRevertsReadsZero() public {
        _assertEntryCapReadsZero(MockTerms.Mode.Revert);
    }

    function test_AnEntryCapThatBurnsItsGasReadsZero() public {
        _assertEntryCapReadsZero(MockTerms.Mode.BurnGas);
    }

    function test_AnEntryCapThatReturnBombsReadsZero() public {
        _assertEntryCapReadsZero(MockTerms.Mode.ReturnBomb);
    }

    function test_AnEntryCapAnsweringAShortOrLongWordReadsZero() public {
        _assertEntryCapReadsZero(MockTerms.Mode.ShortWord);
        _assertEntryCapReadsZero(MockTerms.Mode.LongWord);
    }

    /// @notice CONTROL: a clean entry cap is the bound, in both maxima and at the deposit.
    function test_ACleanEntryCapIsTheBound() public {
        uint256 cap = 5_000e6;
        terms.setEntryCap(MockTerms.Mode.Answer, cap);
        assertEq(vault.maxDeposit(bob), cap, "maxDeposit is not the product's cap");
        assertEq(vault.maxMint(bob), vault.previewDeposit(cap), "maxMint is not the cap in shares at the deposit preview's price");
        usdc.mint(bob, cap + 1);
        vm.startPrank(bob);
        usdc.approve(address(vault), cap + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, cap + 1, cap));
        vault.deposit(cap + 1, bob);
        vault.deposit(cap, bob);
        vm.stopPrank();
    }

    /// @notice The product is told the NAV the deposit prices at, so a deposit cap on NAV needs no read of the vault.
    function test_TheProductIsToldTheNav() public {
        terms.setEntryCap(MockTerms.Mode.Nav, 0);
        assertEq(vault.maxDeposit(bob), vault.totalAssets(), "the entry cap was handed another NAV");
    }

    /// @notice The drain shuts entry without asking the product: an honest uncapped product is never called, and both maxima read zero.
    function test_TheDrainShutsEntryWithoutAskingTheProduct() public {
        terms.setEntryCap(MockTerms.Mode.Answer, type(uint256).max);
        assertEq(vault.maxDeposit(bob), type(uint256).max, "premise: undrained, the honest product opens entry");
        vm.prank(curator);
        vault.setDrain(true);
        vm.expectCall(address(terms), "", 0);
        assertEq(vault.maxDeposit(bob), 0, "a draining vault advertised entry");
        assertEq(vault.maxMint(bob), 0, "and so did maxMint");
    }

    /// @notice `previewTerms` asks the product for the named borrower, not for its own caller.
    function test_PreviewTermsAsksForTheNamedBorrower() public {
        terms.setRefusedBorrower(stranger);
        vm.expectRevert(MockTerms.Refused.selector);
        lens.previewTerms(address(vault), stranger, _req(address(coll), UNITS, PRINCIPAL, 0), "");
        (bytes32 id, MarketParams memory mp,) = lens.previewTerms(address(vault), borrower, _req(address(coll), UNITS, PRINCIPAL, 0), "");
        assertEq(id, keccak256(abi.encode(mp)), "the preview's id is not its market's");
    }

    /// @notice `previewTerms` refuses as the door's checks on the product's answer would: here a market on a collateral the borrower did not ask for.
    function test_PreviewTermsRefusesAsTheDoorsChecksWould() public {
        MockStakeVault other = new MockStakeVault(42);
        terms.setTerms(_market(address(other), _record(address(other))), Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        vm.expectRevert(AceVaultCaps.CollateralNotAsked.selector);
        lens.previewTerms(address(vault), borrower, _req(address(coll), UNITS, PRINCIPAL, 0), "");
    }

    /// @notice `previewTerms` reports the buffer the door will hand the hub: the larger of the ask's and the product's.
    function test_PreviewTermsReportsTheLargerBuffer() public {
        terms.setTerms(_market(address(coll), record), Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0.1e18}));
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, 0);
        r.minBufferWad = 0.3e18;
        (,, Terms memory t) = lens.previewTerms(address(vault), borrower, r, "");
        assertEq(t.minBufferWad, 0.3e18, "the preview did not take the ask's larger buffer");
    }

    /// @notice A fresh vault's high-water is its gross NAV, and its drawdown is zero.
    function test_TheHighWaterStartsAtGrossAndTheDrawdownAtZero() public view {
        assertEq(vlens.navHigh(address(vault)), vault.grossNav(), "the high-water is not gross NAV after the first entry");
        assertEq(vlens.navHigh(address(vault)), LP_CASH + vault.MIN_SEED(), "or not the LP's cash and the seed");
        assertEq(vlens.drawdown(address(vault)), 0, "a fresh vault reads a drawdown");
    }

    /// @notice The base's runtime fits under the plan's STOP line in the profile the suite compiles under.
    function test_TheVaultsRuntimeFitsUnderTheStopLine() public {
        emit log_named_uint("AceVault runtime (B)", address(vault).code.length);
        assertLe(address(vault).code.length, STOP_LINE, "the base passed the STOP line");
    }
}
