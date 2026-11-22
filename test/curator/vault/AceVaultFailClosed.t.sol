// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {ProductConfig} from "../../../src/curator/libraries/AceVaultCaps.sol";
import {AceVaultFlows, Terms} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {GasBurner, HostileTerms} from "./HostileTerms.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultFailClosedTest
/// @notice Every hostile product answer reads as a no or a zero, and never reverts a vault verb that should not revert.
/// @notice A revert carrying a whole word is a no, not that word; an empty success is a zero; a write call that reverts refuses its own borrow whole.
/// @notice NO EXIT PATH CALLS THE PRODUCT: with its code burnt out, every exit, claim, crank, cap verb and share move still lands.
/// @notice EVERY MUTATOR TAKES THE LOCK: a product's write call re-entering any of them is refused by the lock itself.
contract AceVaultFailClosedTest is AceVaultBaseRig {
    bytes4 internal constant YES = IRollPolicy.admitsExtension.selector;
    bytes4 internal constant REENTERED = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;

    AceVault internal hv;
    HostileTerms internal ht;

    function setUp() public override {
        super.setUp();
        (hv, ht) = _hostile(HostileTerms.Bind.Honest);
        ht.setView(HostileTerms.View.Answer, type(uint256).max);
        usdc.mint(alice, LP_CASH);
        vm.startPrank(alice);
        usdc.approve(address(hv), LP_CASH);
        hv.deposit(LP_CASH, alice);
        vm.stopPrank();
        MarketParams memory p = _market(address(coll), record);
        p.lender = address(hv);
        ht.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
    }

    /// @dev A vault on `HostileTerms` built to answer `VAULT()` per `b`, the rig's caps and rail.
    function _hostile(HostileTerms.Bind b) internal returns (AceVault v, HostileTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new HostileTerms(predicted, b);
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        VaultSeed.fund(_cfg(), predicted);
        v = new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Hostile", "hVLT");
    }

    function _hvBorrow() internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(hv), UNITS);
        loanId = hv.borrow(_req(address(coll), UNITS, PRINCIPAL, 0), "", "");
        vm.stopPrank();
    }

    function _expectHvBorrowRevert(bytes memory err) internal {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(hv), UNITS);
        vm.expectRevert(err);
        hv.borrow(_req(address(coll), UNITS, PRINCIPAL, 0), "", "");
        vm.stopPrank();
    }

    function _assertEntryShutForBob(AceVault v) internal {
        assertEq(v.maxDeposit(bob), 0, "maxDeposit answered where entry should read shut");
        assertEq(v.maxMint(bob), 0, "maxMint answered where entry should read shut");
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(v), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1e6, 0));
        v.deposit(1e6, bob);
        vm.stopPrank();
    }

    // ---- a revert carrying a word, and an empty success ----

    /// @notice A ROOM THAT REVERTS WITH THE MAXIMUM AS ITS PAYLOAD is zero room, not the maximum: the call failed, so the word is not read.
    function test_ARoomRevertingWithAMaxWordIsZeroRoom() public {
        ht.setView(HostileTerms.View.RevertWord, type(uint256).max);
        _expectHvBorrowRevert(abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
    }

    /// @notice AN ENTRY CAP THAT REVERTS WITH THE MAXIMUM is a zero cap: both maxima read zero and the deposit refuses at zero.
    function test_AnEntryCapRevertingWithAMaxWordIsZero() public {
        ht.setView(HostileTerms.View.RevertWord, type(uint256).max);
        _assertEntryShutForBob(hv);
    }

    /// @notice A CONSENT THAT REVERTS WITH THE WORD ONE is a no, at the hub and asked directly; a clean one is the control.
    function test_AConsentRevertingWithTheWordOneIsANo() public {
        uint256 loanId = _hvBorrow();
        _warpBy(1 days);
        _fundFee(borrower);
        ht.setView(HostileTerms.View.Answer, 1);
        assertEq(hv.admitsExtension(_ext(loanId), ""), YES, "CONTROL: a clean one is a yes");
        ht.setView(HostileTerms.View.RevertWord, 1);
        assertEq(hv.admitsExtension(_ext(loanId), ""), bytes4(0), "a revert carrying the word one consented");
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /// @notice AN EMPTY SUCCESS is a zero on every read: no room, no entry, no consent.
    function test_AnEmptySuccessIsZeroOnEveryRead() public {
        uint256 loanId = _hvBorrow();
        ht.setView(HostileTerms.View.Empty, 0);
        assertEq(hv.admitsExtension(_ext(loanId), ""), bytes4(0), "an empty consent was a yes");
        _assertEntryShutForBob(hv);
        _expectHvBorrowRevert(abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
    }

    // ---- the write calls refuse their own borrow, whole ----

    /// @notice A `beforeLend` or `afterLend` that reverts refuses the borrow whole: no pledge taken, no cash paid, no loan, nothing resting.
    function test_AWriteCallThatRevertsRefusesTheBorrowWhole() public {
        uint256 idle0 = hv.idle();
        uint256 loans0 = read.loanCount();
        ht.setWrites(true, false);
        _expectHvBorrowRevert(abi.encodeWithSelector(HostileTerms.WriteRefused.selector));
        ht.setWrites(false, true);
        _expectHvBorrowRevert(abi.encodeWithSelector(HostileTerms.WriteRefused.selector));
        assertEq(hv.idle(), idle0, "a refused borrow moved the vault's cash");
        assertEq(coll.balanceOf(address(hv)), 0, "a refused borrow left a pledge on the vault");
        assertEq(read.loanCount(), loans0, "a refused borrow opened a loan");
        ht.setWrites(false, false);
        uint256 loanId = _hvBorrow();
        assertTrue(ace.isLiveLoan(loanId), "CONTROL: with both write calls quiet the borrow lands");
    }

    // ---- the binding at construction ----

    /// @notice A product naming another vault, or none, refuses construction: a wrong word by name, a revert or an empty answer by its own failure.
    function test_AProductThatDoesNotNameTheVaultRefusesConstruction() public {
        vm.expectRevert(AceVault.TermsNotBound.selector);
        this.deployHostile(HostileTerms.Bind.Wrong);
        vm.expectRevert(HostileTerms.WriteRefused.selector);
        this.deployHostile(HostileTerms.Bind.Reverts);
        vm.expectRevert();
        this.deployHostile(HostileTerms.Bind.Empty);
        ProductConfig memory pc = _pc();
        pc.terms = stranger;
        vm.expectRevert(AceVault.TermsNotBound.selector);
        new AceVault(_cfg(), pc, _listing(address(1), _caps(UNCAPPED, 0, UNCAPPED)), "EOA", "eVLT");
        (AceVault ok,) = _hostile(HostileTerms.Bind.Honest);
        assertGt(address(ok).code.length, 0, "CONTROL: a product naming the vault deploys");
    }

    function deployHostile(HostileTerms.Bind b) external returns (AceVault v) {
        (v,) = _hostile(b);
    }

    // ---- no exit path calls the product ----

    /// @notice WITH THE PRODUCT BURNT OUT, every exit, claim, lapse, crank, fee, drain, cap verb, share move and exit view still lands.
    function test_NoExitPathCallsTheProduct() public {
        uint256 loanId = _borrow();
        _lp(bob, 100_000e6);
        uint256 half = vault.balanceOf(bob) / 2;
        vm.prank(bob);
        vault.requestExit(half);
        vm.prank(curator);
        vault.submitCap(address(0), 1);
        vm.etch(address(terms), address(new GasBurner()).code);
        vm.expectCall(address(terms), bytes(""), 0);
        _exitsWithTheProductGone(loanId);
    }

    function _exitsWithTheProductGone(uint256 loanId) internal {
        vault.totalAssets();
        vlens.holds(address(vault));
        vault.lendable();
        vlens.roomOf(address(vault), address(coll));
        vault.previewRedeem(1e18);
        vault.previewWithdraw(1e6);
        vault.maxClaim(bob);
        uint256 out = vault.maxRedeem(alice) / 4;
        vm.startPrank(alice);
        vault.redeem(out, alice, alice);
        vault.withdraw(1e6, alice, alice);
        assertTrue(vault.transfer(stranger, 1e12), "a share move failed with the product gone");
        assertTrue(vault.approve(bob, 1e12), "an approval failed with the product gone");
        vm.stopPrank();
        vm.startPrank(bob);
        assertTrue(vault.transferFrom(alice, bob, 1e12), "a transferFrom failed with the product gone");
        vault.cancelExit(1e12);
        vault.claimExit(vault.maxClaim(bob) / 2, bob, 0);
        vm.stopPrank();
        vault.crank();
        vault.collectFee();
        vm.startPrank(curator);
        vault.revokePendingCap(address(0));
        vault.submitCap(address(coll), 5e6);
        vault.submitDelist(address(coll));
        vm.stopPrank();
        vm.prank(guardian);
        vault.setDrain(true);
        vm.prank(guardian);
        vault.exemptDeadPots(0);
        _warpBy(vault.REQUEST_LEASE());
        vault.lapseExit(bob);
        assertTrue(ace.isLiveLoan(loanId), "an exit path touched the loan");
        assertEq(vault.maxDeposit(bob), 0, "the drain shut entry, and maxDeposit asks no product while draining");
    }

    // ---- every mutator takes the lock ----

    /// @notice EVERY MUTATOR the earlier rows did not reach refuses a re-entry from either write call, by the lock and not by its own check.
    function test_EveryRemainingMutatorRefusesReentryByTheLock() public {
        bytes[11] memory calls = [
            abi.encodeCall(AceVault.mint, (1, address(terms))),
            abi.encodeCall(AceVault.redeem, (1, address(terms), address(terms))),
            abi.encodeCall(AceVault.cancelExit, (0)),
            abi.encodeCall(AceVault.lapseExit, (alice)),
            abi.encodeCall(AceVault.claimExit, (0, address(terms), 0)),
            abi.encodeCall(AceVault.collectFee, ()),
            abi.encodeCall(AceVault.setDrain, (true)),
            abi.encodeCall(AceVault.exemptDeadPots, (0)),
            abi.encodeCall(AceVault.acceptCap, (address(coll))),
            abi.encodeCall(AceVault.revokePendingCap, (address(coll))),
            abi.encodeCall(AceVault.submitDelist, (address(coll)))
        ];
        for (uint256 i; i < calls.length; i++) {
            _assertReentryRefused(calls[i], true);
            _assertReentryRefused(calls[i], false);
        }
    }

    function _assertReentryRefused(bytes memory data, bool before_) internal {
        terms.setReentry(address(vault), data, before_, !before_);
        _borrow();
        assertTrue(terms.reentered(), "premise: the write call re-entered");
        assertFalse(terms.reentryOk(), "a re-entry from a write call went through");
        assertEq(bytes4(terms.reentryError()), REENTERED, "the re-entry was refused, but not by the lock");
    }

    /// @notice THE DRAIN SHUTS ENTRY OVER AN HONEST CAP: with the product answering the maximum, a draining vault advertises and takes nothing.
    /// @dev A cap read that asked the product while draining would let this deposit land; the earlier drain row used a reverting cap, which reads zero anyway.
    function test_TheDrainShutsEntryOverAnHonestCap() public {
        terms.setEntryCap(MockTerms.Mode.Answer, type(uint256).max);
        assertGt(vault.maxDeposit(bob), 0, "premise: entry is open");
        vm.prank(guardian);
        vault.setDrain(true);
        _assertEntryShutForBob(vault);
    }

    /// @notice A product refusing the borrower in `borrowTerms` refuses the borrow by its own reason, and no pledge moves.
    function test_ABorrowTermsRevertRefusesTheBorrowAndPullsNothing() public {
        terms.setRefusedBorrower(borrower);
        _expectBorrowRevert(address(coll), MockTerms.Refused.selector);
        assertEq(coll.balanceOf(borrower), UNITS, "a refused borrow pulled the pledge");
        assertEq(IERC20(address(coll)).balanceOf(address(vault)), 0, "a refused borrow left a pledge on the vault");
    }
}
