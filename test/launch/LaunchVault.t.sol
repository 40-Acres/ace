// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {Permits} from "../../src/ace/hub/libraries/Permits.sol";
import {GateRefused, InsufficientCash, NotBorrower} from "../../src/ace/hub/Borrower.sol";
import {Bid} from "../../src/interfaces/ILaunchAuction.sol";
import {IAllowanceTransfer, LaunchVault} from "../../src/curator/LaunchVault.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPermit2Allowance} from "../mocks/MockPermit2Allowance.sol";
import {LaunchVaultFixture} from "./LaunchVaultFixture.sol";

/// @title LaunchVaultBase
/// @notice The shared scenario: a whole term with a repaid loan and a forfeited one, and the readers the suites assert with.
abstract contract LaunchVaultBase is LaunchVaultFixture {
    using PoolIdLibrary for PoolKey;

    address internal dave = address(0xDA7E); // a second depositor
    address internal keeper = address(0x4EE9); // 40acres' keeper, or anyone

    /// @dev One opt-in deposit, alice's refund of `amount` swept from her account by the keeper.
    function _refund(address who, uint256 amount) internal returns (uint256) {
        usdc.mint(m.lock.account(who, 0), amount);
        vm.prank(keeper);
        return vault.depositRefund(who);
    }

    /// @dev A whole term, every vault verb on it but `depositRefund`: `_termUntilExit`, then carol exits and the curator is paid.
    function _wholeTerm() internal {
        _termUntilExit();
        vm.prank(carol);
        vault.exit(CASH, carol);
        vault.claimFee();
    }

    /// @dev alice and bob buy, carol deposits, both reserve and draw; the curator stops, alice repays and bob forfeits, and the pot is redeemed.
    function _termUntilExit() internal returns (uint256 aliceLoan, uint256 bobLoan) {
        _buy(alice, SPEND);
        _buy(bob, SPEND);
        _deposit(vault, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m));
        (bytes32 a,) = _reserve(vault, alice, type(uint256).max);
        (bytes32 b, uint256 rb) = _reserve(vault, bob, type(uint256).max);
        aliceLoan = _borrow(m, alice, a, ace.restingOf(a), 30 days);
        bobLoan = _borrow(m, bob, b, rb, 30 days);
        vm.prank(curator);
        vault.stop();
        vault.recall(address(_acct(alice)));
        _repay(aliceLoan);
        _warpTo(read.loan(bobLoan).expiry);
        ace.forceClose(bobLoan);
        vault.redeem(bobLoan);
    }

    /// @dev The params the vault builds for `acct` at `price`, by name, as a stranger would to front-run its market.
    function _paramsFor(address acct, uint256 price) internal view returns (MarketParams memory p) {
        (p.quote, p.collateral, p.borrower, p.price, p.lender) = (address(usdc), m.token, acct, price, address(vault));
        (p.minCoverageWad, p.baseBps, p.minTenor, p.maxTenor, p.minDebt) = (1.25e18, BASE, 7 days, 30 days, 10e6);
    }

    /// @dev The vault's current terms, field by field, for an equality against what it was created with.
    function _terms(LaunchVault v) internal view returns (bytes memory) {
        return abi.encode(v.terms());
    }
}

/// @title LaunchVaultCreationTest
/// @notice The implementation is the factory: get-or-create clones on terms genesis takes, and nothing but `vaultFor` runs on it.
contract LaunchVaultCreationTest is LaunchVaultBase {
    using PoolIdLibrary for PoolKey;

    /// @notice `vaultFor` is get-or-create: anyone's second call returns the same clone, at the address `predictVault` names, with its terms.
    function test_VaultForIsGetOrCreate() public {
        assertEq(address(vault), impl.predictVault(m.token, curator, D, BASE), "the clone is not where predictVault said");
        assertEq(vault.predictVault(m.token, curator, D, BASE), address(vault), "a clone predicts another address");
        vm.prank(stranger);
        assertEq(impl.vaultFor(m.token, curator, D, BASE), address(vault), "a second call made another vault");
        LaunchVault.Terms memory t = vault.terms();
        assertEq(abi.encode(t.token, t.curator, t.dTicks, t.baseBps), abi.encode(m.token, curator, D, BASE), "the terms");
        assertEq(abi.encode(t.lock, t.auction, t.budget), abi.encode(m.lock, m.auction, m.budget), "the launch");
        assertEq(abi.encode(t.pool, t.launchBy, t.tokenIs0), abi.encode(m.key.toId(), m.launchBy, m.token < address(usdc)), "the pool and the clock");
        assertTrue(impl.vaultFor(m.token, stranger, D, BASE) != address(vault), "another curator shares the vault");
        assertTrue(impl.vaultFor(m.token, curator, D + 1, BASE) != address(vault), "another discount shares the vault");
        assertTrue(impl.vaultFor(m.token, curator, D, BASE + 1) != address(vault), "another rate shares the vault");
    }

    /// @notice The rate's edges are genesis's: 0 and 531 are refused, 1 and 530 accepted, at 30 days over 7.
    /// @notice The discount's edges are 10% and 50%: 1053 and 6933 ticks are refused, 1054 and 6932 accepted.
    function test_TheTermsAreGenesissAtTheirEdges() public {
        uint16[2] memory badRate = [uint16(0), 531];
        uint24[2] memory badD = [uint24(1053), 6933];
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(LaunchVault.BadTerms.selector);
            impl.vaultFor(m.token, curator, D, badRate[i]);
            vm.expectRevert(LaunchVault.BadTerms.selector);
            impl.predictVault(m.token, curator, D, badRate[i]);
            vm.expectRevert(LaunchVault.BadTerms.selector);
            impl.vaultFor(m.token, curator, badD[i], BASE);
        }
        assertGt(impl.vaultFor(m.token, curator, D, 1).code.length, 0, "a rate of 1 was refused");
        assertGt(impl.vaultFor(m.token, curator, D, 530).code.length, 0, "a rate of 530 was refused");
        assertGt(impl.vaultFor(m.token, curator, 1054, BASE).code.length, 0, "a 10% discount was refused");
        assertGt(impl.vaultFor(m.token, curator, 6932, BASE).code.length, 0, "a 50% discount was refused");
    }

    /// @notice A vault at the top rate, 530, creates its market at genesis and rests: the rate rail is genesis's own.
    function test_AVaultAt530CanReserve() public {
        LaunchVault v = LaunchVault(impl.vaultFor(m.token, curator, D, 530));
        uint256 bidId = _bid(m, alice, SPEND);
        strat.send(m.token, m.lock.predict(alice, 0), _filled(SPEND));
        v.credit(bidId, 0, 0);
        _deposit(v, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m));
        (bytes32 id, uint256 got) = _reserve(v, alice, type(uint256).max);
        assertEq(ace.idToMarketParams(id).baseBps, 530, "the market's rate");
        assertEq(ace.restingOf(id), got, "nothing rested");
        assertGt(got, v.MIN_DEBT(), "fixture: a real reservation");
    }

    /// @notice A zero curator and a token the factory never launched are refused by name, on both the create and the predict.
    function test_AZeroCuratorAndAForeignTokenAreRefused() public {
        vm.expectRevert(LaunchVault.ZeroCurator.selector);
        impl.vaultFor(m.token, address(0), D, BASE);
        MockERC20 foreign = new MockERC20("Foreign", "FRN", 18);
        vm.expectRevert(LaunchVault.NotALaunch.selector);
        impl.vaultFor(address(foreign), curator, D, BASE);
        vm.expectRevert(LaunchVault.NotALaunch.selector);
        impl.predictVault(address(foreign), curator, D, BASE);
    }

    /// @notice A clone cannot make clones: `vaultFor` on it is NotImplementation.
    function test_AClonesVaultForIsNotImplementation() public {
        vm.expectRevert(LaunchVault.NotImplementation.selector);
        vault.vaultFor(m.token, curator, D, BASE);
    }

    /// @notice Every verb and every launch read on the implementation is NotAClone: it carries no launch.
    function test_EveryVerbOnTheImplementationIsNotAClone() public {
        bytes[14] memory calls = [
            abi.encodeCall(LaunchVault.deposit, (1)),
            abi.encodeCall(LaunchVault.depositRefund, (alice)),
            abi.encodeCall(LaunchVault.credit, (1, 0, 0)),
            abi.encodeCall(LaunchVault.reserve, (1)),
            abi.encodeCall(LaunchVault.recall, (alice)),
            abi.encodeCall(LaunchVault.stop, ()),
            abi.encodeCall(LaunchVault.redeem, (1)),
            abi.encodeCall(LaunchVault.exit, (1, alice)),
            abi.encodeCall(LaunchVault.claimFee, ()),
            abi.encodeCall(LaunchVault.depositing, ()),
            abi.encodeCall(LaunchVault.quote, ()),
            abi.encodeCall(LaunchVault.blockStartQuote, ()),
            abi.encodeCall(LaunchVault.isHome, ()),
            abi.encodeCall(LaunchVault.terms, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(impl).call(calls[i]);
            assertFalse(ok, "a verb ran on the implementation");
            assertEq(ret, abi.encodeWithSelector(LaunchVault.NotAClone.selector), "a verb on the implementation reverted otherwise");
        }
    }

    /// @notice The ABI pin: the runtime's dispatcher answers exactly these 42 selectors, so there is no setter, sweep or sale.
    /// @notice The ten mutators are the factory, two entries, credit, reserve, recall, stop, redeem, exit and claimFee.
    /// @dev Read off the deployed bytecode: every PUSH4 the dispatcher compares calldata against with EQ.
    function test_TheDispatcherAnswersExactlyTheSurface() public view {
        string[42] memory sigs = [
            "vaultFor(address,address,uint24,uint16)",
            "deposit(uint256)",
            "depositRefund(address)",
            "credit(uint256,uint64,uint64)",
            "reserve(uint256)",
            "recall(address)",
            "stop()",
            "redeem(uint256)",
            "exit(uint256,address)",
            "claimFee()",
            "predictVault(address,address,uint24,uint16)",
            "depositing()",
            "quote()",
            "blockStartQuote()",
            "isHome()",
            "terms()",
            "accountCount()",
            "totalShares()",
            "sharesOf(address)",
            "feeOwed()",
            "stopped()",
            "creditOf(address)",
            "credited(uint256)",
            "reservationOf(address)",
            "accounts(uint256)",
            "DEPOSIT_WINDOW()",
            "LEND_TERM()",
            "RESERVE_TTL()",
            "MIN_TENOR()",
            "MAX_TENOR()",
            "COVERAGE_WAD()",
            "MIN_DEBT()",
            "FEE_BPS()",
            "MIN_D_TICKS()",
            "MAX_D_TICKS()",
            "GRID()",
            "BUYER()",
            "SELF()",
            "FACTORY()",
            "HUB()",
            "QUOTE()",
            "HOOK()"
        ];
        bytes4[] memory got = _dispatched(address(impl).code);
        for (uint256 i; i < sigs.length; ++i) {
            assertTrue(_has(got, bytes4(keccak256(bytes(sigs[i])))), string.concat("the dispatcher lacks ", sigs[i]));
        }
        for (uint256 i; i < got.length; ++i) {
            bool known;
            for (uint256 j; j < sigs.length && !known; ++j) {
                known = got[i] == bytes4(keccak256(bytes(sigs[j])));
            }
            assertTrue(known, "the dispatcher answers a selector outside the pinned surface");
        }
    }

    /// @dev Every PUSH4 immediate met by EQ, directly or across one DUP: the selectors a Solidity dispatcher compares calldata against.
    function _dispatched(bytes memory code) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](code.length / 6 + 1);
        uint256 n;
        for (uint256 i; i + 6 < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x63) {
                uint8 nx = uint8(code[i + 5]);
                if (nx == 0x14 || (nx >= 0x80 && nx <= 0x8f && uint8(code[i + 6]) == 0x14)) {
                    out[n++] =
                        bytes4(uint32(uint8(code[i + 1])) << 24 | uint32(uint8(code[i + 2])) << 16 | uint32(uint8(code[i + 3])) << 8 | uint8(code[i + 4]));
                }
            }
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _has(bytes4[] memory set, bytes4 s) internal pure returns (bool) {
        for (uint256 i; i < set.length; ++i) {
            if (set[i] == s) return true;
        }
        return false;
    }
}

/// @title LaunchVaultEntryTest
/// @notice Entry: 1:1 shares inside the window by `deposit` or by a keeper's `depositRefund`, and its one Permit2 pull.
contract LaunchVaultEntryTest is LaunchVaultBase {
    // ---- the window ----

    /// @notice Each of `depositing()`'s clauses at its edge: graduation, the end checkpoint, and openAt, a second before and at it.
    function test_DepositingEachClauseAtItsEdge() public {
        uint64 e = m.auction.endBlock();
        assertTrue(vault.depositing(), "a final, graduated auction does not admit deposits");
        m.auction.setState(e, false, 0);
        assertFalse(vault.depositing(), "an ungraduated auction admits deposits");
        m.auction.setState(e - 1, true, 0);
        assertFalse(vault.depositing(), "an auction whose end is not checkpointed admits deposits");
        m.auction.setState(e, true, 0);
        _warpTo(_openAt(m) - 1);
        assertTrue(vault.depositing(), "a second before openAt is closed");
        _warpTo(_openAt(m));
        assertFalse(vault.depositing(), "openAt itself admits deposits");
    }

    /// @notice A live settle keeps the window open until openAt; a failed one closes it at once.
    function test_DepositingStaysOpenLiveAndClosesOnFailure() public {
        _goLive(m);
        assertTrue(vault.depositing(), "a live settle closed the window");
        (Made memory x, LaunchVault v) = _fresh();
        assertTrue(v.depositing(), "fixture: the second launch admits deposits before settle");
        _goFailed(x);
        assertFalse(v.depositing(), "a failed settle left the window open");
        usdc.mint(carol, 1e6);
        vm.prank(carol);
        vm.expectRevert(LaunchVault.NotDepositing.selector);
        v.deposit(1e6);
    }

    /// @notice A launch that settles failed never lends: holders exit 1:1, with no fee and no tokens.
    function test_AFailedLaunchExitsOneToOne() public {
        (Made memory x, LaunchVault v) = _fresh();
        _deposit(v, carol, 500e6);
        _goFailed(x);
        _warpTo(_openAt(x));
        vm.prank(alice);
        vm.expectRevert(LaunchVault.NotLending.selector);
        v.reserve(1);
        vm.prank(carol);
        (uint256 assets, uint256 units) = v.exit(500e6, carol);
        assertEq(abi.encode(assets, units, v.feeOwed()), abi.encode(500e6, 0, 0), "a failed launch did not exit 1:1");
        assertEq(usdc.balanceOf(carol), 500e6, "carol was not paid");
    }

    /// @dev A second launch with its auction final and the default vault on it.
    function _fresh() internal returns (Made memory x, LaunchVault v) {
        x = _launch();
        _final(x);
        v = LaunchVault(impl.vaultFor(x.token, curator, D, BASE));
    }

    // ---- deposit ----

    /// @notice `deposit` mints 1:1 to the caller and pulls exactly the assets; zero is refused.
    function test_DepositMintsOneToOneToTheCaller() public {
        _deposit(vault, carol, 777e6);
        assertEq(abi.encode(vault.sharesOf(carol), vault.totalShares()), abi.encode(777e6, 777e6), "the shares");
        assertEq(usdc.balanceOf(address(vault)), 777e6, "the cash");
        vm.prank(carol);
        vm.expectRevert(LaunchVault.ZeroAssets.selector);
        vault.deposit(0);
    }

    /// @notice `deposit` is refused before the end checkpoint and from openAt on.
    function test_DepositIsRefusedOutsideTheWindow() public {
        usdc.mint(carol, 2e6);
        vm.prank(carol);
        usdc.approve(address(vault), 2e6);
        m.auction.setState(m.auction.endBlock() - 1, true, 0);
        vm.prank(carol);
        vm.expectRevert(LaunchVault.NotDepositing.selector);
        vault.deposit(1e6);
        m.auction.setState(m.auction.endBlock(), true, 0);
        _warpTo(_openAt(m));
        vm.prank(carol);
        vm.expectRevert(LaunchVault.NotDepositing.selector);
        vault.deposit(1e6);
    }

    // ---- depositRefund: the five Permit2 conditions ----

    /// @notice Condition 1: one Permit2 call site. Across a whole term, no verb but `depositRefund` touches Permit2 at all.
    /// @notice `depositRefund` reads the allowance and pulls once, and nothing else of Permit2's.
    function test_Permit2_OneCallSite() public {
        _optIn(vault, alice, type(uint160).max, type(uint48).max);
        vm.startStateDiffRecording();
        _refund(alice, 300e6);
        Vm.AccountAccess[] memory a = vm.stopAndReturnStateDiff();
        uint256 calls;
        for (uint256 i; i < a.length; ++i) {
            VmSafe.AccountAccessKind k = a[i].kind;
            if (a[i].account != Permits.PERMIT2 || a[i].accessor != address(vault)) continue;
            if (k != VmSafe.AccountAccessKind.Call && k != VmSafe.AccountAccessKind.StaticCall) continue;
            ++calls;
            bytes4 sel = bytes4(a[i].data);
            assertTrue(sel == IAllowanceTransfer.allowance.selector || sel == IAllowanceTransfer.transferFrom.selector, "another Permit2 call");
        }
        assertEq(calls, 2, "depositRefund did not read once and pull once");
        assertEq(permit2.pulls(), 1, "depositRefund did not pull once");

        vm.startStateDiffRecording();
        _wholeTerm();
        a = vm.stopAndReturnStateDiff();
        for (uint256 i; i < a.length; ++i) {
            assertTrue(a[i].account != Permits.PERMIT2, "a verb other than depositRefund reached Permit2");
        }
        assertEq(permit2.pulls(), 1, "a whole term pulled through Permit2");
    }

    /// @notice Condition 2: the pull is from the beneficiary whose derived buyer account the same call swept, whoever calls.
    /// @notice The account ends empty, the wallet where it started, and the vault holds the refund against the beneficiary's shares.
    function test_Permit2_FromIsTheBeneficiaryWhoseAccountWasSwept() public {
        _optIn(vault, alice, type(uint160).max, type(uint48).max);
        usdc.mint(alice, 50e6);
        address acct = m.lock.account(alice, 0);
        usdc.mint(acct, 300e6);
        vm.expectCall(Permits.PERMIT2, abi.encodeCall(MockPermit2Allowance.transferFrom, (alice, address(vault), 300e6, address(usdc))));
        vm.prank(keeper);
        assertEq(vault.depositRefund(alice), 300e6, "the deposit is not the sweep");
        assertEq(usdc.balanceOf(acct), 0, "the account was not swept");
        assertEq(usdc.balanceOf(alice), 50e6, "the wallet moved");
        assertEq(usdc.balanceOf(address(vault)), 300e6, "the vault does not hold the refund");
        vm.prank(keeper);
        vm.expectRevert(LaunchVault.NotAnAccount.selector);
        vault.depositRefund(stranger); // no buyer account was ever made for the stranger
    }

    /// @notice Condition 3: the amount is at most that sweep: an allowance and a wallet far over it pull only what was swept.
    function test_Permit2_TheAmountIsAtMostTheSweep() public {
        _optIn(vault, alice, type(uint160).max, type(uint48).max);
        usdc.mint(alice, 1_000_000e6);
        assertEq(_refund(alice, 300e6), 300e6, "the pull is not the sweep");
        assertEq(usdc.balanceOf(alice), 1_000_000e6, "the wallet paid past the sweep");
        assertEq(vault.sharesOf(alice), 300e6, "the shares are not the sweep");
    }

    /// @notice Condition 4: shares mint only to the beneficiary; the keeper, the caller, gets none, and there is no receiver parameter.
    function test_Permit2_SharesMintOnlyToTheBeneficiary() public {
        _optIn(vault, alice, type(uint160).max, type(uint48).max);
        _refund(alice, 300e6);
        assertEq(abi.encode(vault.sharesOf(alice), vault.sharesOf(keeper), vault.totalShares()), abi.encode(300e6, 0, 300e6), "the shares");
        (bool ok,) = address(vault).call(abi.encodeWithSignature("depositRefund(address,address)", alice, keeper));
        assertFalse(ok, "a depositRefund with a receiver exists");
    }

    /// @notice Condition 5: the clone cannot be changed. Its terms read the same after a whole term, every verb run, as at creation.
    /// @dev The dispatcher pin in the creation suite shows no setter exists; this shows none of the verbs moves a term.
    function test_Permit2_TheCloneCannotChange() public {
        bytes memory before = _terms(vault);
        _wholeTerm();
        assertEq(_terms(vault), before, "a verb moved the clone's terms");
    }

    // ---- depositRefund: the rest ----

    /// @notice A stranger's donation to the account, then a call, only turns the donor's money into the beneficiary's shares.
    function test_ADonationThenACallOnlyConvertsTheDonorsMoney() public {
        _optIn(vault, alice, type(uint160).max, type(uint48).max);
        usdc.mint(alice, 50e6);
        address acct = m.lock.account(alice, 0);
        usdc.mint(stranger, 40e6);
        vm.startPrank(stranger);
        usdc.transfer(acct, 40e6);
        vault.depositRefund(alice);
        vm.stopPrank();
        assertEq(abi.encode(vault.sharesOf(alice), vault.sharesOf(stranger)), abi.encode(40e6, 0), "the shares");
        assertEq(abi.encode(usdc.balanceOf(alice), usdc.balanceOf(stranger)), abi.encode(50e6, 0), "the wallets");
    }

    /// @notice The pull is min(swept, allowance): an allowance under the sweep pulls the allowance, and the rest stays in the wallet.
    function test_ThePullIsTheLesserOfSweepAndAllowance() public {
        _optIn(vault, alice, 200e6, type(uint48).max);
        assertEq(_refund(alice, 300e6), 200e6, "the pull is not the allowance");
        assertEq(usdc.balanceOf(alice), 100e6, "the sweep's rest did not stay in the wallet");
        (uint160 left,,) = permit2.allowance(alice, address(usdc), address(vault));
        assertEq(left, 0, "the allowance was not spent");
    }

    /// @notice A dust donation spends one atom of the allowance and leaves the rest usable for the real refund.
    function test_ADustDonationLeavesTheAllowanceUsable() public {
        _optIn(vault, alice, 300e6, type(uint48).max);
        assertEq(_refund(alice, 1), 1, "the dust was not deposited");
        assertEq(_refund(alice, 300e6), 300e6 - 1, "the real refund did not take the allowance's rest");
        assertEq(abi.encode(vault.sharesOf(alice), usdc.balanceOf(alice)), abi.encode(300e6, 1), "the shares and the wallet");
    }

    /// @notice An expired allowance reverts the whole call, the sweep with it: the refund stays in the account.
    /// @notice An allowance expiring this very second is still live, as Permit2 reads it.
    function test_AnExpiredAllowanceRevertsAndTheRefundStays() public {
        _warpBy(1 hours); // so a second ago is not zero, which Permit2 would store as now
        _optIn(vault, alice, type(uint160).max, uint48(_now() - 1));
        address acct = m.lock.account(alice, 0);
        usdc.mint(acct, 300e6);
        vm.prank(keeper);
        vm.expectRevert(LaunchVault.NothingToDeposit.selector);
        vault.depositRefund(alice);
        assertEq(usdc.balanceOf(acct), 300e6, "the refund left the account");
        _optIn(vault, alice, type(uint160).max, uint48(_now()));
        vm.prank(keeper);
        assertEq(vault.depositRefund(alice), 300e6, "an allowance live this second was read as expired");
    }

    /// @notice No allowance at all, and an empty account, each deposit nothing and revert.
    function test_NoAllowanceOrNothingSweptReverts() public {
        address acct = m.lock.account(alice, 0);
        usdc.mint(acct, 300e6);
        vm.expectRevert(LaunchVault.NothingToDeposit.selector);
        vault.depositRefund(alice);
        _optIn(vault, alice, type(uint160).max, type(uint48).max);
        vault.depositRefund(alice);
        vm.expectRevert(LaunchVault.NothingToDeposit.selector);
        vault.depositRefund(alice);
    }

    /// @notice A team account's USDC is never swept: only the beneficiary's BUYER account is derived, whatever else it holds.
    function test_ATeamAccountIsNeverSwept() public {
        _optIn(vault, team, type(uint160).max, type(uint48).max);
        address teamAcct = m.lock.account(team, TEAM_LINEAR);
        usdc.mint(teamAcct, 300e6);
        vm.expectRevert(LaunchVault.NotAnAccount.selector);
        vault.depositRefund(team);
        m.lock.account(team, 0);
        vm.expectRevert(LaunchVault.NothingToDeposit.selector);
        vault.depositRefund(team);
        assertEq(usdc.balanceOf(teamAcct), 300e6, "the team account was swept");
    }

    /// @notice depositRefund is shut outside the window like deposit.
    function test_DepositRefundIsRefusedOutsideTheWindow() public {
        _optIn(vault, alice, type(uint160).max, type(uint48).max);
        usdc.mint(m.lock.account(alice, 0), 300e6);
        _warpTo(_openAt(m));
        vm.expectRevert(LaunchVault.NotDepositing.selector);
        vault.depositRefund(alice);
    }

    // ---- the stop ----

    /// @notice A stop shuts entry inside the window: `depositing()` reads false, and `deposit` and `depositRefund` both revert NotDepositing.
    /// @notice The opted-in refund stays in the buyer's account and the depositor's cash in its wallet.
    function test_AStopShutsEntry() public {
        _optIn(vault, alice, type(uint160).max, type(uint48).max);
        address acct = m.lock.account(alice, 0);
        usdc.mint(acct, 300e6);
        usdc.mint(carol, 100e6);
        vm.prank(carol);
        usdc.approve(address(vault), 100e6);
        assertTrue(vault.depositing(), "fixture: entry is open");
        vm.prank(curator);
        vault.stop();
        assertFalse(vault.depositing(), "a stop left entry open");
        vm.prank(carol);
        vm.expectRevert(LaunchVault.NotDepositing.selector);
        vault.deposit(100e6);
        vm.prank(keeper);
        vm.expectRevert(LaunchVault.NotDepositing.selector);
        vault.depositRefund(alice);
        assertEq(abi.encode(usdc.balanceOf(acct), usdc.balanceOf(carol), vault.totalShares()), abi.encode(300e6, 100e6, 0), "entry moved cash");
    }

    /// @notice A stop before any lending leaves the vault home: each holder exits 1:1, with no fee and no tokens, before openAt and after.
    function test_AStopBeforeLendingExitsOneToOne() public {
        _buy(alice, SPEND);
        _deposit(vault, carol, 500e6);
        _optIn(vault, alice, type(uint160).max, type(uint48).max);
        _refund(alice, 300e6);
        vm.prank(curator);
        vault.stop();
        vm.prank(carol);
        (uint256 assets, uint256 units) = vault.exit(500e6, carol);
        assertEq(abi.encode(assets, units, vault.feeOwed()), abi.encode(500e6, 0, 0), "a stopped vault did not exit 1:1 before openAt");
        _goLive(m);
        _warpTo(_openAt(m));
        vm.prank(alice);
        vm.expectRevert(LaunchVault.NotLending.selector);
        vault.reserve(type(uint256).max);
        vm.prank(alice);
        (assets, units) = vault.exit(300e6, alice);
        assertEq(abi.encode(assets, units, vault.feeOwed()), abi.encode(300e6, 0, 0), "a stopped vault did not exit 1:1 after openAt");
        assertEq(abi.encode(usdc.balanceOf(address(vault)), vault.totalShares()), abi.encode(0, 0), "the vault kept cash or shares");
    }
}

/// @title LaunchVaultCreditTest
/// @notice Credit: what a bid spent at the final clearing price, less an atom, once per bid, and the room it alone buys.
contract LaunchVaultCreditTest is LaunchVaultBase {
    /// @notice A bid credits its owner floor(spent / clearing) - 1 units, once; a second credit is refused.
    function test_CreditCountsOnce() public {
        uint256 id = _bid(m, alice, SPEND);
        assertEq(vault.credit(id, 0, 0), _creditFor(SPEND), "the credit is not the formula");
        assertEq(vault.creditOf(m.lock.predict(alice, 0)), _creditFor(SPEND), "the account was not credited");
        assertTrue(vault.credited(id), "the bid is not marked");
        vm.expectRevert(LaunchVault.AlreadyCredited.selector);
        vault.credit(id, 0, 0);
    }

    /// @notice The credit ignores the bid's exit and claim: exited then claimed, claimed by a stranger first, and never claimed, alike.
    function test_CreditIsOrderFree() public {
        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            ids[i] = _bid(m, alice, SPEND);
        }
        Bid memory b = m.auction.bids(ids[0]);
        (b.exitedBlock, b.tokensFilled) = (m.auction.endBlock(), 0);
        m.auction.setBid(ids[0], b); // exited, then claimed
        b = m.auction.bids(ids[1]);
        b.tokensFilled = 0;
        m.auction.setBid(ids[1], b); // claimed by a stranger, never exited
        b = m.auction.bids(ids[2]);
        (b.exitedBlock, b.tokensFilled) = (m.auction.endBlock(), _filled(SPEND));
        m.auction.setBid(ids[2], b); // exited, never claimed
        for (uint256 i; i < 3; ++i) {
            vm.prank(stranger);
            assertEq(vault.credit(ids[i], 0, 0), _creditFor(SPEND), "the bid's state moved its credit");
        }
        assertEq(vault.creditOf(m.lock.predict(alice, 0)), 3 * _creditFor(SPEND), "the credits do not add up");
    }

    /// @notice The budget's own refusals propagate: a hint its exit arithmetic refuses, and an auction not yet final. Nothing is marked.
    function test_BadHintAndNotFinalPropagate() public {
        uint256 id = _bid(m, alice, SPEND);
        Bid memory b = m.auction.bids(id);
        b.maxPrice = CLEAR; // at the clearing price: the hints are judged
        m.auction.setBid(id, b);
        vm.expectRevert(LaunchOpsBudget.BadHint.selector);
        vault.credit(id, START, 0);
        uint256 other = _bid(m, bob, SPEND);
        m.auction.setState(m.auction.endBlock() - 1, true, 0);
        vm.expectRevert(LaunchOpsBudget.NotFinal.selector);
        vault.credit(other, 0, 0);
        assertFalse(vault.credited(id) || vault.credited(other), "a refused credit was marked");
    }

    /// @notice A token donation to the account never raises its room: the reservation is the credit's, not the balance's.
    function test_ADonationNeverRaisesRoom() public {
        LockAccount acct = _ready();
        strat.send(m.token, address(acct), 10 * _filled(SPEND));
        (, uint256 got) = _reserve(vault, alice, type(uint256).max);
        assertEq(got, _maxPrincipal(_creditFor(SPEND), vault.quote()), "the donation raised the room");
    }

    /// @notice A 1-USDC bid gets exactly its formula's credit, and its room, under one minimum ticket, rests nothing.
    /// @notice Beside a 20-USDC bid the two credits add, and the room is theirs together.
    function test_AOneUsdcBidGetsItsFormulaRoom() public {
        LockAccount acct = _buy(alice, 1e6);
        assertEq(vault.creditOf(address(acct)), _creditFor(1e6), "a 1-USDC bid's credit");
        _deposit(vault, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m));
        vm.prank(alice);
        vm.expectRevert(LaunchVault.BelowMinDebt.selector);
        vault.reserve(type(uint256).max);
        uint256 id = _bid(m, alice, 20e6);
        strat.send(m.token, address(acct), _filled(20e6));
        vault.credit(id, 0, 0);
        (, uint256 got) = _reserve(vault, alice, type(uint256).max);
        assertEq(got, _maxPrincipal(_creditFor(1e6) + _creditFor(20e6), vault.quote()), "the two bids' room");
    }

    /// @notice A release shrinks room for good: the released units count as spent, and sending them back buys nothing.
    function test_AReleaseShrinksRoomPermanently() public {
        LockAccount acct = _ready();
        _warpTo(m.launchBy + 30 days); // the buyer schedule has vested
        uint256 r = _filled(SPEND) / 4;
        vm.prank(alice);
        acct.release(r);
        vm.prank(alice);
        IERC20(m.token).transfer(address(acct), r);
        (, uint256 got) = _reserve(vault, alice, type(uint256).max);
        assertEq(got, _maxPrincipal(_creditFor(SPEND) - r, vault.quote()), "the release did not shrink the room");
    }

    /// @notice A forfeit shrinks room for good: the forfeited units count as spent once reclaimed, and before that as pledged.
    function test_AForfeitShrinksRoomPermanently() public {
        LockAccount acct = _ready();
        (bytes32 id,) = _reserve(vault, alice, 100e6);
        uint256 loanId = _borrow(m, alice, id, 100e6, 30 days);
        uint256 pledged = acct.pledged();
        _warpTo(read.loan(loanId).expiry);
        ace.forceClose(loanId);
        acct.reclaim(loanId);
        assertEq(acct.spent(), pledged, "fixture: the forfeit counts as spent");
        strat.send(m.token, address(acct), pledged); // replacing the tokens buys nothing back
        _warpTo(_lendEnd(m) - 1);
        (, uint256 got) = _reserve(vault, alice, type(uint256).max);
        assertEq(got, _maxPrincipal(_creditFor(SPEND) - pledged, vault.quote()), "the forfeit did not shrink the room");
    }

    /// @notice A pledge comes off the credit, not only off the balance: with donated tokens to spare, a draw still spends its units of room.
    function test_APledgeComesOffTheCredit() public {
        LockAccount acct = _ready();
        strat.send(m.token, address(acct), 10 * _filled(SPEND));
        (bytes32 id, uint256 got) = _reserve(vault, alice, type(uint256).max);
        _borrow(m, alice, id, got / 2, 30 days);
        _warpBy(1 hours);
        vault.recall(address(acct));
        (, uint256 again) = _reserve(vault, alice, type(uint256).max);
        assertEq(again, _maxPrincipal(_creditFor(SPEND) - acct.pledged(), vault.quote()), "the pledge did not come off the credit");
    }

    /// @notice Capacity still binds: a credit over what the account holds rests only what the holding secures.
    function test_CapacityStillBinds() public {
        uint256 id = _bid(m, alice, SPEND);
        LockAccount acct = LockAccount(m.lock.predict(alice, 0));
        uint256 held = _filled(SPEND) / 3;
        strat.send(m.token, address(acct), held);
        vault.credit(id, 0, 0);
        _deposit(vault, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m));
        (, uint256 got) = _reserve(vault, alice, type(uint256).max);
        assertEq(got, _maxPrincipal(held, vault.quote()), "the room is not the capacity's");
    }

    /// @notice Capacity is read at now + MAX_TENOR, the latest a loan taken now can expire: on a 120-day buyer vest, what vests by then.
    /// @notice Never what vests by the end of time, which no draw this term can pledge.
    function test_CapacityIsReadAtTheLongestTenor() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.buyerDuration = 120 days;
        Made memory x = _launch(p);
        _final(x);
        LaunchVault v = LaunchVault(impl.vaultFor(x.token, curator, D, BASE));
        LockAccount acct = _buy(x, v, alice, SPEND);
        _deposit(v, carol, CASH);
        _goLive(x);
        _warpTo(_openAt(x));
        uint256 vested = acct.capacity(uint64(_now()) + 30 days);
        assertLt(vested, v.creditOf(address(acct)), "fixture: the vest binds under the credit 30 days out");
        assertGt(acct.capacity(type(uint64).max), v.creditOf(address(acct)), "fixture: the credit binds at the vest's end");
        vm.prank(alice);
        (, uint256 got) = v.reserve(type(uint256).max);
        assertEq(got, _maxPrincipal(vested, v.quote()), "the room is not what vests by now + MAX_TENOR");
    }
}

/// @title LaunchVaultQuoteCases
/// @notice The quote, in token ticks: min(window floor, spot, clearing) - d, snapped down onto the 50-tick grid, zero unless live.
/// @dev Run for both currency orders: the window is pinned in raw pool ticks, and `_poolTick` turns a token tick into one.
abstract contract LaunchVaultQuoteCases is LaunchVaultBase {
    function _tokenIs0() internal pure virtual returns (bool);

    function setUp() public override {
        super.setUp();
        (m, vault) = _launchOn(_tokenIs0());
        _goLive(m);
    }

    /// @notice The window's floor is the token tick: `lo` as currency0, `-hi - 1` as currency1, never `-hi`.
    /// @notice A floor one tick under a grid line snaps down a whole step, where `-hi` would sit on the line itself.
    function test_TheWindowFloorRoundsDown() public {
        int24 t = TickBitmap.compress(_clearTick() - 1000, 50) * 50 + 31; // t - D sits one tick under a grid line
        _flat(m, t);
        assertEq(vault.quote(), _priceAt(t - int24(D) - 49), "the quote is not the window floor, less d, snapped down");
        assertEq(vault.blockStartQuote(), vault.quote(), "a flat window quotes apart with spot");
    }

    /// @notice A window whose sides differ quotes off its low token price, never its high: `lo` as currency0, `-hi - 1` as currency1.
    /// @dev Both sides sit under clearing and quote apart, and spot sits at the high, so only the side the vault reads can bind.
    function test_AWideWindowQuotesItsLowSide() public {
        int24 a = _clearTick() - 3_000; // the window's low token tick
        int24 b = _clearTick() - 1_000; // its high
        (int24 pa, int24 pb) = (_poolTick(m, a), _poolTick(m, b));
        (int24 lo, int24 hi) = pa < pb ? (pa, pb) : (pb, pa);
        assertEq(abi.encode(lo, hi), _tokenIs0() ? abi.encode(a, b) : abi.encode(-b - 1, -a - 1), "fixture: the raw pool window");
        _window(m, lo, hi, pb);
        assertTrue(_quoteAt(a) < _quoteAt(b), "fixture: the two sides quote apart");
        assertEq(vault.blockStartQuote(), _quoteAt(a), "the block-start quote is not the window's low token price");
        assertEq(vault.quote(), _quoteAt(a), "the borrower's quote is not the window's low token price");
    }

    /// @notice A pump in the window, its high over clearing, lifts nothing: the quote stays the window's low token price, never clearing's.
    function test_APumpedWindowHighLiftsNothing() public {
        int24 a = _clearTick() - 2_000;
        int24 b = _clearTick() + 5_000; // a pump held for one block start
        (int24 pa, int24 pb) = (_poolTick(m, a), _poolTick(m, b));
        (int24 lo, int24 hi) = pa < pb ? (pa, pb) : (pb, pa);
        _window(m, lo, hi, pa);
        assertTrue(_quoteAt(a) < _quoteAt(_clearTick()), "fixture: the low quotes under the clearing ceiling");
        assertEq(vault.blockStartQuote(), _quoteAt(a), "the pump lifted the block-start quote");
        assertEq(vault.quote(), _quoteAt(a), "the pump lifted the borrower's quote");
    }

    /// @notice Spot's floor rounds the same way: spot alone binding, one tick under a grid line, snaps down a whole step.
    function test_TheSpotFloorRoundsDown() public {
        int24 t = TickBitmap.compress(_clearTick() - 1000, 50) * 50 + 31;
        int24 w = _poolTick(m, _clearTick() + 1000);
        _window(m, w, w, _poolTick(m, t));
        assertEq(vault.quote(), _priceAt(t - int24(D) - 49), "the borrower's quote is not spot's floor, less d, snapped down");
        assertEq(vault.blockStartQuote(), _quoteAt(_clearTick()), "spot reached the block-start quote");
    }

    /// @notice A window at the bottom of the tick range quotes zero, and `reserve` refuses NoQuote: `-MAX_TICK - 1 - d` is under MIN_TICK.
    function test_TheBottomOfTheRangeQuotesZero() public {
        if (_tokenIs0()) _window(m, TickMath.MIN_TICK, TickMath.MIN_TICK, TickMath.MIN_TICK);
        else _window(m, TickMath.MAX_TICK, TickMath.MAX_TICK, TickMath.MAX_TICK);
        assertEq(abi.encode(vault.quote(), vault.blockStartQuote()), abi.encode(0, 0), "the range's bottom quotes above zero");
        _buy(m, vault, alice, SPEND);
        _deposit(vault, carol, CASH);
        _warpTo(_openAt(m));
        vm.prank(alice);
        vm.expectRevert(LaunchVault.NoQuote.selector);
        vault.reserve(type(uint256).max);
    }

    /// @notice No window, however extreme, reverts the quote or lifts it past clearing less d.
    function testFuzz_NoTickOverflows(int24 lo, int24 hi, int24 spot) public {
        _window(m, lo, hi, spot);
        uint256 cap = CLEAR * 8 / 10;
        assertLe(vault.quote(), cap, "the quote passed clearing less d");
        assertLe(vault.blockStartQuote(), cap, "the block-start quote passed clearing less d");
    }

    /// @notice Unless settle found the launch live, the quote is zero: before settle, and after a failure.
    function test_TheQuoteIsZeroUnlessLive() public {
        (Made memory x, LaunchVault v) = _launchOn(_tokenIs0());
        _flat(x, _clearTick());
        assertEq(v.quote() + v.blockStartQuote(), 0, "an unsettled launch quoted");
        _goFailed(x);
        assertEq(v.quote() + v.blockStartQuote(), 0, "a failed launch quoted");
    }

    /// @notice A window over clearing quotes the clearing tick less d: the clearing tick is PriceGrid's floor, at or under CLEAR.
    function test_TheClearingCeilingTakesPriceGridsFloor() public {
        int24 c = _clearTick();
        assertLe(_priceAt(c), CLEAR, "the clearing tick prices over CLEAR");
        assertGt(_priceAt(c + 1), CLEAR, "the clearing tick is not the floor");
        _flat(m, c + 5_000);
        assertEq(vault.quote(), _quoteAt(c), "the ceiling is not the clearing tick less d, snapped");
        assertEq(vault.blockStartQuote(), _quoteAt(c), "the block-start ceiling");
    }

    /// @notice For any window, the quote is the snapped price of min(floor, clearing) - d: never over its unsnapped price,
    /// @notice and never over min(window floor, clearing) x (1 - d).
    function testFuzz_TheQuoteIsBoundedAndSnappedDown(int24 t) public {
        t = int24(bound(t, TickMath.MIN_TICK + int24(D) + 100, TickMath.MAX_TICK - 100));
        _flat(m, t);
        int24 f = t < _clearTick() ? t : _clearTick();
        uint256 q = vault.quote();
        assertEq(q, _quoteAt(f), "the quote is not min(floor, clearing) - d, snapped");
        assertLe(q, _priceAt(f - int24(D)), "the snap raised the price");
        uint256 floor = Math.min(_priceAt(t), CLEAR);
        assertLe(q * 10, (floor + 1) * 8, "the quote passed min(window, clearing) x (1 - d)"); // the atom: both prices are floored
    }

    /// @notice Spot only ever lowers `quote()`: the block-start quote ignores it, and a spot under the window lowers the borrower's own.
    function testFuzz_SpotOnlyLowers(int24 s) public {
        int24 w = _clearTick() - 1_000;
        s = int24(bound(s, TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 1));
        _flat(m, w);
        uint256 flat = vault.blockStartQuote();
        int24 p = _poolTick(m, w);
        _window(m, p, p, _poolTick(m, s));
        assertEq(vault.blockStartQuote(), flat, "spot moved the block-start quote");
        assertLe(vault.quote(), flat, "spot raised the borrower's quote");
        if (s < w - 100) assertLt(vault.quote(), flat, "a spot under the window did not lower the borrower's quote");
    }
}

/// @title LaunchVaultQuoteToken0Test
/// @notice The quote with the launch token as the pool's currency0.
contract LaunchVaultQuoteToken0Test is LaunchVaultQuoteCases {
    function _tokenIs0() internal pure override returns (bool) {
        return true;
    }
}

/// @title LaunchVaultQuoteToken1Test
/// @notice The quote with the launch token as the pool's currency1, read through `-tick - 1`.
contract LaunchVaultQuoteToken1Test is LaunchVaultQuoteCases {
    function _tokenIs0() internal pure override returns (bool) {
        return false;
    }
}

/// @title LaunchVaultReserveTest
/// @notice Reservations, borrowing through the account, and the recall: who may move cash, at what price, and when.
contract LaunchVaultReserveTest is LaunchVaultBase {
    // ---- reserve ----

    /// @notice Only a beneficiary reserves, for its own buyer account, and the market it makes is pinned field by field.
    function test_ReserveIsTheBeneficiarysAndPinsEveryField() public {
        LockAccount acct = _ready();
        uint256 q = vault.quote();
        (bytes32 id, uint256 got) = _reserve(vault, alice, type(uint256).max);
        MarketParams memory want = _paramsFor(address(acct), q);
        assertEq(abi.encode(ace.idToMarketParams(id)), abi.encode(want), "the market's params");
        assertEq(id, keccak256(abi.encode(want)), "the id is not the params' hash");
        assertEq(got, _maxPrincipal(_creditFor(SPEND), q), "the reservation is not the room");
        assertEq(ace.restingOf(id), got, "the cash did not rest");
        (bytes32 rm, uint64 at) = vault.reservationOf(address(acct));
        assertEq(abi.encode(rm, at), abi.encode(id, uint64(_now())), "the reservation");
        assertEq(abi.encode(vault.accountCount(), vault.accounts(0)), abi.encode(1, address(acct)), "the account list");
        vm.prank(stranger);
        vm.expectRevert(LaunchVault.NotAnAccount.selector);
        vault.reserve(1e6);
        m.lock.account(bob, 0);
        vm.prank(bob);
        vm.expectRevert(LaunchVault.BelowMinDebt.selector);
        vault.reserve(type(uint256).max); // an account, but no credit
    }

    /// @notice One unit held at a launch-scale price rests nothing: its worth sits far under the minimum debt.
    function test_RoomOfOneUnitRestsNothing() public {
        uint256 id = _bid(m, alice, SPEND);
        strat.send(m.token, m.lock.predict(alice, 0), 1);
        vault.credit(id, 0, 0);
        _deposit(vault, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m));
        vm.prank(alice);
        vm.expectRevert(LaunchVault.BelowMinDebt.selector);
        vault.reserve(type(uint256).max);
    }

    /// @notice Room that shrinks under what already rests saturates to zero: the top-up is BelowMinDebt, never an underflow.
    function test_RoomUnderRestingSaturates() public {
        LockAccount acct = _ready();
        _reserve(vault, alice, type(uint256).max);
        _warpTo(m.launchBy + 30 days);
        vm.prank(alice);
        acct.release(_filled(SPEND) / 2);
        vm.prank(alice);
        vm.expectRevert(LaunchVault.BelowMinDebt.selector);
        vault.reserve(type(uint256).max);
    }

    /// @notice An ask under one minimum ticket is refused; one ticket exactly rests.
    function test_AnAskUnderOneTicketIsRefused() public {
        _ready();
        vm.prank(alice);
        vm.expectRevert(LaunchVault.BelowMinDebt.selector);
        vault.reserve(10e6 - 1);
        (, uint256 got) = _reserve(vault, alice, 10e6);
        assertEq(got, 10e6, "one ticket did not rest");
    }

    /// @notice Re-reserving at a new price after a stranger emptied the old market skips its recall, which the hub would refuse.
    function test_AnEmptyOldMarketIsSkipped() public {
        LockAccount acct = _ready();
        (bytes32 a,) = _reserve(vault, alice, 50e6);
        _warpBy(1 hours);
        vm.prank(stranger);
        vault.recall(address(acct));
        assertEq(ace.restingOf(a), 0, "fixture: the stranger emptied the market");
        _flat(m, _clearTick() - 1_000);
        (bytes32 b, uint256 got) = _reserve(vault, alice, 50e6);
        assertTrue(b != a, "fixture: the price moved");
        assertEq(ace.restingOf(b), got, "the new market did not rest");
    }

    /// @notice Booked fee is never rested: a reservation takes at most the cash past feeOwed.
    function test_ReserveIsCappedAtTheCashPastTheFee() public {
        _buy(alice, 10_000e6);
        _deposit(vault, carol, 100e6);
        _deposit(vault, dave, 100e6);
        usdc.mint(address(vault), 1_000e6); // a donation; home, so carol's exit books a fee on it
        vm.prank(carol);
        vault.exit(100e6, carol); // 600 out on a 100 basis: 50 of fee
        assertEq(abi.encode(vault.feeOwed(), usdc.balanceOf(address(vault))), abi.encode(50e6, 650e6), "fixture: the fee");
        _goLive(m);
        _warpTo(_openAt(m));
        (, uint256 got) = _reserve(vault, alice, type(uint256).max);
        assertEq(got, 600e6, "the reservation reached the booked fee");
    }

    /// @notice What the hub owes the vault mid-term, a partial repayment and the draw's lender fee, is reservable with no separate collect.
    function test_OwedCreditIsReservableWithoutACollect() public {
        _buy(alice, SPEND);
        _buy(bob, SPEND);
        _deposit(vault, carol, 500e6);
        _goLive(m);
        _warpTo(_openAt(m));
        (bytes32 a, uint256 ra) = _reserve(vault, alice, type(uint256).max);
        assertEq(ra, 500e6, "fixture: alice reserves every free atom");
        uint256 loanId = _borrow(m, alice, a, ra, 30 days);
        uint256 part = ace.debtOf(loanId) / 2;
        usdc.mint(address(0xFA7E4), part);
        vm.startPrank(address(0xFA7E4));
        usdc.approve(address(ace), part);
        ace.repay(loanId, part);
        vm.stopPrank();
        uint256 owed = ace.lenderOwed(address(vault), address(usdc));
        assertGt(owed, part, "fixture: the repayment and the lender fee are owed, not pushed");
        assertEq(usdc.balanceOf(address(vault)), 0, "fixture: the vault holds no cash of its own");
        (, uint256 got) = _reserve(vault, bob, type(uint256).max);
        assertEq(got, owed, "the owed credit was not reservable");
        assertEq(ace.lenderOwed(address(vault), address(usdc)), 0, "reserve left credit uncollected");
    }

    /// @notice Reservations open at openAt and close at lendEnd: refused a second before the one and at the other.
    function test_ReserveRunsFromOpenAtToLendEnd() public {
        _buy(alice, SPEND);
        _deposit(vault, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m) - 1);
        vm.prank(alice);
        vm.expectRevert(LaunchVault.NotLending.selector);
        vault.reserve(50e6);
        _warpTo(_openAt(m));
        _reserve(vault, alice, 20e6);
        _warpTo(_lendEnd(m) - 1);
        _reserve(vault, alice, 20e6);
        _warpTo(_lendEnd(m));
        vm.prank(alice);
        vm.expectRevert(LaunchVault.NotLending.selector);
        vault.reserve(20e6);
    }

    /// @notice A stop is the curator's alone and one-way: after it nothing reserves.
    function test_AStopShutsReservations() public {
        _ready();
        vm.prank(stranger);
        vm.expectRevert(LaunchVault.NotCurator.selector);
        vault.stop();
        vm.prank(curator);
        vault.stop();
        assertTrue(vault.stopped(), "the stop did not latch");
        vm.prank(alice);
        vm.expectRevert(LaunchVault.NotLending.selector);
        vault.reserve(50e6);
    }

    /// @notice A launch not live never reserves: unsettled at openAt, or settled failed.
    function test_ReserveNeedsALiveLaunch() public {
        _buy(alice, SPEND);
        _deposit(vault, carol, CASH);
        _warpTo(_openAt(m));
        vm.prank(alice);
        vm.expectRevert(LaunchVault.NotLending.selector);
        vault.reserve(50e6);
        _goFailed(m);
        vm.prank(alice);
        vm.expectRevert(LaunchVault.NotLending.selector);
        vault.reserve(50e6);
    }

    /// @notice A stranger who creates the account's market first changes nothing: the reservation rests in it.
    function test_AFrontRunMarketDoesNotBlockReserve() public {
        LockAccount acct = _ready();
        vm.prank(stranger);
        bytes32 pre = ace.createMarket(_paramsFor(address(acct), vault.quote()));
        (bytes32 id,) = _reserve(vault, alice, 50e6);
        assertEq(id, pre, "the reservation went elsewhere");
        assertEq(ace.restingOf(id), 50e6, "nothing rested");
    }

    /// @notice A new price is a new market: the old one is recalled first, so one market per account holds cash.
    function test_ANewPriceRecallsTheOldMarketFirst() public {
        LockAccount acct = _ready();
        (bytes32 a,) = _reserve(vault, alice, 50e6);
        uint256 cash = usdc.balanceOf(address(vault));
        _flat(m, _clearTick() - 1_000);
        (bytes32 b, uint256 got) = _reserve(vault, alice, 70e6);
        assertTrue(a != b, "fixture: the price moved");
        assertEq(abi.encode(ace.restingOf(a), ace.restingOf(b), got), abi.encode(0, 70e6, 70e6), "the two markets");
        (bytes32 rm,) = vault.reservationOf(address(acct));
        assertEq(rm, b, "the reservation is not the new market");
        assertEq(usdc.balanceOf(address(vault)), cash + 50e6 - 70e6, "the old cash did not come home");
        assertEq(vault.accountCount(), 1, "a re-reservation listed the account twice");
    }

    /// @notice A top-up at the same price restarts the hour: the old stamp no longer lets a stranger recall.
    function test_ATopUpRestartsTheHour() public {
        LockAccount acct = _ready();
        (bytes32 a,) = _reserve(vault, alice, 50e6);
        uint256 t0 = _now();
        _warpBy(50 minutes);
        (bytes32 b,) = _reserve(vault, alice, 20e6);
        assertEq(b, a, "fixture: the same price");
        assertEq(ace.restingOf(a), 70e6, "the top-up did not add");
        _warpTo(t0 + 1 hours);
        vm.prank(stranger);
        vm.expectRevert(LaunchVault.NotRecallable.selector);
        vault.recall(address(acct));
        _warpTo(t0 + 50 minutes + 1 hours);
        vm.prank(stranger);
        assertEq(vault.recall(address(acct)), 70e6, "the restarted hour did not run out");
    }

    // ---- borrowing ----

    /// @notice The account borrows its reservation and the beneficiary is paid; another account, a liquid EOA and a team account cannot.
    function test_OnlyTheAccountBorrows() public {
        LockAccount acct = _ready();
        LockAccount bobAcct = _buy(bob, SPEND);
        (bytes32 id, uint256 got) = _reserve(vault, alice, type(uint256).max);
        uint256 units = _unitsFor(got, ace.idToMarketParams(id).price);
        vm.prank(bob);
        vm.expectRevert(GateRefused.selector);
        bobAcct.borrow(id, units, got, 30 days, OpenBounds(0, 0, 0));
        vm.prank(stranger);
        vm.expectRevert(GateRefused.selector);
        ace.open(id, units, got, 30 days, stranger, OpenBounds(0, 0, 0));
        LockAccount teamAcct = LockAccount(m.lock.account(alice, TEAM_LINEAR));
        strat.send(m.token, address(teamAcct), 100 * units);
        vm.prank(alice);
        vm.expectRevert(GateRefused.selector);
        teamAcct.borrow(id, units, got, 30 days, OpenBounds(0, 0, 0));
        uint256 before = usdc.balanceOf(alice);
        uint256 loanId = _borrow(m, alice, id, got, 30 days);
        assertEq(ace.borrowerOf(loanId), address(acct), "the loan is not the account's");
        assertGt(usdc.balanceOf(alice), before, "the beneficiary was not paid");
        assertEq(ace.restingOf(id), 0, "the reservation was not drawn whole");
    }

    // ---- recall ----

    /// @notice A stranger recalls a reservation from its hour on, never a second sooner.
    function test_RecallOnExpiry() public {
        LockAccount acct = _ready();
        (bytes32 id,) = _reserve(vault, alice, 50e6);
        uint256 t0 = _now();
        _warpTo(t0 + 1 hours - 1);
        vm.prank(stranger);
        vm.expectRevert(LaunchVault.NotRecallable.selector);
        vault.recall(address(acct));
        _warpTo(t0 + 1 hours);
        vm.prank(stranger);
        assertEq(vault.recall(address(acct)), 50e6, "the recall did not bring the reservation home");
        assertEq(ace.restingOf(id), 0, "cash still rests");
    }

    /// @notice A stranger recalls a fresh reservation once its price is over the block-start quote, and not on spot alone.
    function test_RecallWhenStaleOnTheBlockStartQuoteOnly() public {
        int24 w = _clearTick() - 1_000;
        _flat(m, w);
        LockAccount acct = _ready();
        _reserve(vault, alice, 50e6);
        int24 p = _poolTick(m, w);
        _window(m, p, p, _poolTick(m, w - 5_000)); // spot dumps, the window holds
        assertLt(vault.quote(), vault.blockStartQuote(), "fixture: spot lowered the borrower's quote");
        vm.prank(stranger);
        vm.expectRevert(LaunchVault.NotRecallable.selector);
        vault.recall(address(acct));
        _flat(m, w - 100); // the window itself falls
        vm.prank(stranger);
        assertEq(vault.recall(address(acct)), 50e6, "a stale reservation was not recallable");
    }

    /// @notice A dump inside one transaction cannot recall: the window holds the block's start, whatever spot does.
    function test_ADumpInOneTransactionCannotRecall() public {
        LockAccount acct = _ready();
        _nextBlock();
        (bytes32 id,) = _reserve(vault, alice, 50e6);
        uint256 price = ace.idToMarketParams(id).price;
        _swap(m, true, 50_000e18);
        assertLt(vault.quote(), price, "fixture: the dump moved spot");
        assertEq(vault.blockStartQuote(), price, "the dump reached the block-start quote");
        vm.prank(stranger);
        vm.expectRevert(LaunchVault.NotRecallable.selector);
        vault.recall(address(acct));
        _swap(m, false, 5_000e6); // the buy-back
        assertEq(ace.restingOf(id), 50e6, "the reservation moved");
    }

    /// @notice A dump held into the next block's start enters the window, and then a stranger recalls.
    function test_ADumpThatSurvivesTheBlockCanRecall() public {
        LockAccount acct = _ready();
        _nextBlock();
        (bytes32 id,) = _reserve(vault, alice, 50e6);
        _swap(m, true, 50_000e18);
        _nextBlock();
        assertLt(vault.blockStartQuote(), ace.idToMarketParams(id).price, "a held dump did not reach the block-start quote");
        vm.prank(stranger);
        assertEq(vault.recall(address(acct)), 50e6, "the held dump did not make the reservation recallable");
    }

    /// @notice Past the term, a fresh reservation is anyone's to recall, from lendEnd exactly.
    function test_RecallFromLendEnd() public {
        LockAccount acct = _ready();
        _warpTo(_lendEnd(m) - 1);
        _reserve(vault, alice, 50e6);
        vm.prank(stranger);
        vm.expectRevert(LaunchVault.NotRecallable.selector);
        vault.recall(address(acct));
        _warpTo(_lendEnd(m));
        vm.prank(stranger);
        assertEq(vault.recall(address(acct)), 50e6, "a reservation past lendEnd was not recallable");
    }

    /// @notice After a stop, a fresh reservation is anyone's to recall.
    function test_RecallAfterAStop() public {
        LockAccount acct = _ready();
        _reserve(vault, alice, 50e6);
        vm.prank(curator);
        vault.stop();
        vm.prank(stranger);
        assertEq(vault.recall(address(acct)), 50e6, "a stop did not make the reservation recallable");
    }

    /// @notice An account that never reserved has nothing to recall.
    function test_RecallWithNoReservation() public {
        LockAccount acct = _ready();
        vm.expectRevert(LaunchVault.NoReservation.selector);
        vault.recall(address(acct));
    }

    /// @notice A parked reservation: reserved, left an hour, recalled by a keeper, then a crash. Nothing is drawable at the old price.
    function test_AParkedReservationIsGoneBeforeACrash() public {
        LockAccount acct = _ready();
        (bytes32 id, uint256 got) = _reserve(vault, alice, type(uint256).max);
        uint256 price = ace.idToMarketParams(id).price;
        _warpBy(1 hours);
        vm.prank(keeper);
        vault.recall(address(acct));
        _swap(m, true, 50_000e18);
        _nextBlock();
        uint256 units = _unitsFor(got, price);
        vm.prank(alice);
        vm.expectRevert(InsufficientCash.selector);
        acct.borrow(id, units, got, 30 days, OpenBounds(0, 0, 0));
        (bytes32 again,) = _reserve(vault, alice, 50e6);
        assertLt(ace.idToMarketParams(again).price, price, "a new reservation was not struck at the crashed quote");
    }

    // ---- the term ----

    /// @notice With a keeper recall at lendEnd, every vault loan expires by lendEnd + 30 days.
    /// @notice A draw a second before lendEnd ends by then, its beneficiary cannot re-term it, and after the recall nothing more is drawn.
    function test_TheTermBoundsEveryLoan() public {
        LockAccount acct = _ready();
        _warpTo(_lendEnd(m) - 1);
        (bytes32 id, uint256 got) = _reserve(vault, alice, type(uint256).max);
        uint256 loanId = _borrow(m, alice, id, got / 2, 30 days);
        assertLe(read.loan(loanId).expiry, _lendEnd(m) + 30 days, "a loan outlived the term");
        vm.prank(alice);
        vm.expectRevert(NotBorrower.selector);
        ace.refinance(loanId, got / 2, 30 days, OpenBounds(0, 0, 0));
        _warpTo(_lendEnd(m));
        vm.prank(keeper);
        vault.recall(address(acct));
        uint256 units = _unitsFor(got / 4, ace.idToMarketParams(id).price);
        vm.prank(alice);
        vm.expectRevert(InsufficientCash.selector);
        acct.borrow(id, units, got / 4, 30 days, OpenBounds(0, 0, 0));
    }
}

/// @title LaunchVaultExitTest
/// @notice Home and exit: pro rata in kind, the curator's fee on USDC gain alone, forfeits redeemed in kind, and donations.
contract LaunchVaultExitTest is LaunchVaultBase {
    /// @dev alice buys, `holders` deposit `amounts`, alice draws her whole room for 30 days and repays a second before expiry.
    function _gainTerm(address[] memory holders, uint256[] memory amounts) internal returns (uint256 loanId) {
        _buy(alice, SPEND);
        for (uint256 i; i < holders.length; ++i) {
            _deposit(vault, holders[i], amounts[i]);
        }
        _goLive(m);
        _warpTo(_openAt(m));
        (bytes32 id, uint256 got) = _reserve(vault, alice, type(uint256).max);
        loanId = _borrow(m, alice, id, got, 30 days);
        _warpTo(read.loan(loanId).expiry - 1);
        _repay(loanId);
    }

    function _one(address who, uint256 amount) internal pure returns (address[] memory h, uint256[] memory a) {
        (h, a) = (new address[](1), new uint256[](1));
        (h[0], a[0]) = (who, amount);
    }

    function _two(address w0, uint256 a0, address w1, uint256 a1) internal pure returns (address[] memory h, uint256[] memory a) {
        (h, a) = (new address[](2), new uint256[](2));
        (h[0], a[0], h[1], a[1]) = (w0, a0, w1, a1);
    }

    /// @dev bob buys, carol deposits CASH, bob draws his whole room for 30 days and forfeits; the pot is redeemed.
    function _lossTerm() internal returns (uint256 loanId) {
        _buy(bob, SPEND);
        _deposit(vault, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m));
        (bytes32 id, uint256 got) = _reserve(vault, bob, type(uint256).max);
        loanId = _borrow(m, bob, id, got, 30 days);
        _warpTo(read.loan(loanId).expiry);
        ace.forceClose(loanId);
        vault.redeem(loanId);
    }

    // ---- home ----

    /// @notice Nothing exits while a loan is out; once it is repaid the vault is home and the exit pays `to`, never the caller.
    /// @notice The fee is floor(gain / 10), booked, and the rest of the USDC is the exiter's.
    function test_ExitPaysToOnceHomeAndBooksTheFee() public {
        (address[] memory h, uint256[] memory a) = _one(carol, CASH);
        _buy(alice, SPEND);
        _deposit(vault, h[0], a[0]);
        _goLive(m);
        _warpTo(_openAt(m));
        (bytes32 id, uint256 got) = _reserve(vault, alice, type(uint256).max);
        uint256 loanId = _borrow(m, alice, id, got, 30 days);
        assertFalse(vault.isHome(), "a vault with a loan out reads home");
        vm.prank(carol);
        vm.expectRevert(LaunchVault.NotHome.selector);
        vault.exit(CASH, carol);
        _warpTo(read.loan(loanId).expiry - 1);
        _repay(loanId);
        assertTrue(vault.isHome(), "a repaid vault is not home");
        uint256 gain = usdc.balanceOf(address(vault)) - CASH;
        assertGt(gain, 0, "fixture: the loan earned the vault something");
        vm.prank(carol);
        (uint256 assets, uint256 units) = vault.exit(CASH, dave);
        assertEq(vault.feeOwed(), gain / 10, "the fee is not a tenth of the gain, floored");
        assertEq(abi.encode(assets, units), abi.encode(CASH + gain - gain / 10, 0), "the exit");
        assertEq(abi.encode(usdc.balanceOf(dave), usdc.balanceOf(carol)), abi.encode(assets, 0), "the exit did not pay `to`");
        assertEq(vault.sharesOf(carol), 0, "the shares were not burned from the caller");
    }

    /// @notice Resting cash keeps the vault from home until it is recalled.
    function test_RestingCashIsNotHome() public {
        _ready();
        _reserve(vault, alice, 50e6);
        assertFalse(vault.isHome(), "resting cash reads home");
        _warpBy(1 hours);
        vault.recall(address(_acct(alice)));
        assertTrue(vault.isHome(), "a recalled vault is not home");
    }

    /// @notice `isHome` and `exit` agree while the vault has uncollected credit: the view nets it, and the exit collects it first.
    function test_IsHomeAgreesWithExitOverUncollectedCredit() public {
        _buy(alice, SPEND);
        _deposit(vault, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m));
        (bytes32 id, uint256 got) = _reserve(vault, alice, type(uint256).max);
        uint256 loanId = _borrow(m, alice, id, got, 30 days);
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, address(vault)), "refused");
        _repay(loanId); // the close's push to the vault fails, so its credit stays owed
        vm.clearMockedCalls();
        uint256 owed = ace.lenderOwed(address(vault), address(usdc));
        assertGt(owed, 0, "fixture: the credit is uncollected");
        assertTrue(vault.isHome(), "the view counts uncollected credit as away");
        uint256 cash = usdc.balanceOf(address(vault));
        vm.prank(carol);
        (uint256 assets,) = vault.exit(CASH, carol);
        assertEq(assets + vault.feeOwed(), cash + owed, "the exit did not collect the credit first");
    }

    // ---- the fee ----

    /// @notice A loss pays no fee, and the forfeited tokens are paid out whole: tokens are fee-free.
    function test_NoFeeOnALossAndTokensAreFeeFree() public {
        _lossTerm();
        uint256 cash = usdc.balanceOf(address(vault));
        uint256 pot = IERC20(m.token).balanceOf(address(vault));
        assertLt(cash, CASH, "fixture: the forfeit lost USDC");
        assertGt(pot, 0, "fixture: the pot came home");
        vm.prank(carol);
        (uint256 assets, uint256 units) = vault.exit(CASH, carol);
        assertEq(abi.encode(assets, units, vault.feeOwed()), abi.encode(cash, pot, 0), "a loss paid a fee, or the tokens were charged");
    }

    /// @notice Booked fee is out of every later exit: two equal holders exit alike, and the vault ends holding exactly the fee.
    function test_TheBookedFeeIsOutOfLaterExits() public {
        (address[] memory h, uint256[] memory a) = _two(carol, CASH / 2, dave, CASH / 2);
        _gainTerm(h, a);
        vm.prank(carol);
        (uint256 first,) = vault.exit(CASH / 2, carol);
        uint256 fee1 = vault.feeOwed();
        vm.prank(dave);
        (uint256 second,) = vault.exit(CASH / 2, dave);
        assertApproxEqAbs(first, second, 1, "the second exiter was paid the first one's fee");
        assertApproxEqAbs(vault.feeOwed(), 2 * fee1, 1, "the second exit's fee is not the first's");
        assertEq(usdc.balanceOf(address(vault)), vault.feeOwed(), "the vault holds other than the fee");
    }

    /// @notice `claimFee` pays the curator, whoever calls; a curator the quote refuses strands only the fee, never an exit.
    function test_ClaimFeePaysTheCuratorAndARefusalStrandsOnlyIt() public {
        (address[] memory h, uint256[] memory a) = _two(carol, CASH / 2, dave, CASH / 2);
        _gainTerm(h, a);
        vm.prank(carol);
        vault.exit(CASH / 2, carol);
        uint256 fee = vault.feeOwed();
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, curator), "blacklisted");
        vm.prank(stranger);
        vm.expectRevert(bytes("blacklisted"));
        vault.claimFee();
        vm.prank(dave);
        vault.exit(CASH / 2, dave);
        vm.clearMockedCalls();
        uint256 owed = vault.feeOwed();
        assertGt(owed, fee, "fixture: the second exit booked a fee");
        vm.prank(stranger);
        assertEq(vault.claimFee(), owed, "the claim is not the booked fee");
        assertEq(abi.encode(usdc.balanceOf(curator), usdc.balanceOf(stranger), vault.feeOwed()), abi.encode(owed, 0, 0), "the fee's payee");
        assertEq(usdc.balanceOf(address(vault)), 0, "the vault kept USDC past the fee");
    }

    /// @notice The curator's own shares pay the fee like anyone's: its exit books a tenth of its gain.
    function test_TheCuratorsOwnSharesAreCharged() public {
        (address[] memory h, uint256[] memory a) = _one(curator, CASH);
        _gainTerm(h, a);
        uint256 gain = usdc.balanceOf(address(vault)) - CASH;
        vm.prank(curator);
        (uint256 assets,) = vault.exit(CASH, curator);
        assertEq(abi.encode(assets, vault.feeOwed()), abi.encode(CASH + gain - gain / 10, gain / 10), "the curator was exempt");
    }

    /// @notice Every holder exits and the last takes the remainder: the vault ends holding the fee alone, and no token.
    function test_TheLastExiterTakesTheRemainder() public {
        (address[] memory h, uint256[] memory a) = _two(carol, 33_333_333_333, dave, 66_666_666_667);
        _deposit(vault, stranger, 1_234_567);
        _gainTerm(h, a);
        strat.send(m.token, address(vault), 1_000_000_007); // an odd token balance to split
        vm.prank(carol);
        vault.exit(33_333_333_333, carol);
        vm.prank(stranger);
        vault.exit(1_234_567, stranger);
        vm.prank(dave);
        vault.exit(66_666_666_667, dave);
        assertEq(vault.totalShares(), 0, "shares are left");
        assertEq(usdc.balanceOf(address(vault)), vault.feeOwed(), "the vault holds USDC past the fee");
        assertEq(IERC20(m.token).balanceOf(address(vault)), 0, "the vault kept tokens");
    }

    /// @notice An exit of more than the caller's shares, or of none, is refused.
    function test_OverSharesAndZeroShares() public {
        _deposit(vault, carol, 100e6);
        _deposit(vault, dave, 100e6);
        vm.prank(carol);
        vm.expectRevert(LaunchVault.OverShares.selector);
        vault.exit(100e6 + 1, carol);
        vm.prank(carol);
        vm.expectRevert(LaunchVault.ZeroShares.selector);
        vault.exit(0, carol);
    }

    // ---- forfeits ----

    /// @notice Two defaults in two accounts' markets, ended by forceClose and settleExpired, redeemed by anyone: then home,
    /// @notice and the holders take every forfeited token pro rata, with no fee on the loss.
    function test_TwoForfeitsRoundTripToExits() public {
        _buy(alice, SPEND);
        _buy(bob, SPEND);
        _deposit(vault, carol, 60_000e6);
        _deposit(vault, dave, 40_000e6);
        _goLive(m);
        _warpTo(_openAt(m));
        (bytes32 a, uint256 ra) = _reserve(vault, alice, type(uint256).max);
        uint256 la = _borrow(m, alice, a, ra, 30 days);
        _warpBy(1 days);
        (bytes32 b, uint256 rb) = _reserve(vault, bob, type(uint256).max);
        uint256 lb = _borrow(m, bob, b, rb, 30 days);
        _warpTo(read.loan(la).expiry);
        vm.prank(stranger);
        ace.forceClose(la);
        _warpTo(read.loan(lb).expiry + 2 days);
        vm.prank(stranger);
        ace.settleExpired(lb);
        assertFalse(vault.isHome(), "unredeemed pots read home");
        vm.prank(carol);
        vm.expectRevert(LaunchVault.NotHome.selector);
        vault.exit(1, carol);
        vm.startPrank(stranger);
        uint256 pot = vault.redeem(la) + vault.redeem(lb);
        vm.stopPrank();
        assertTrue(vault.isHome(), "redeemed pots are not home");
        assertEq(IERC20(m.token).balanceOf(address(vault)), pot, "the pots did not come home");
        vm.prank(carol);
        (, uint256 cu) = vault.exit(60_000e6, carol);
        vm.prank(dave);
        (, uint256 du) = vault.exit(40_000e6, dave);
        assertEq(cu, pot * 6 / 10, "carol's tokens are not her share");
        assertEq(cu + du, pot, "the tokens did not all go out");
        assertEq(vault.feeOwed(), 0, "a loss paid a fee");
    }

    // ---- donations ----

    /// @notice A USDC donation is gain: it raises the payout and the curator's fee on it.
    function test_AUsdcDonationRaisesTheGainAndTheFee() public {
        _deposit(vault, carol, CASH);
        usdc.mint(address(vault), 1_000e6);
        vm.prank(carol);
        (uint256 assets,) = vault.exit(CASH, carol);
        assertEq(abi.encode(assets, vault.feeOwed()), abi.encode(CASH + 900e6, 100e6), "the donation's fee");
    }

    /// @notice A launch-token donation is paid out pro rata, fee-free; a third token is stranded, paid to nobody.
    function test_ATokenDonationIsProRataAndAThirdTokenStrands() public {
        _deposit(vault, carol, 300e6);
        _deposit(vault, dave, 100e6);
        strat.send(m.token, address(vault), 4_000e18);
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(vault), 1e18);
        vm.prank(carol);
        (, uint256 cu) = vault.exit(300e6, carol);
        vm.prank(dave);
        (, uint256 du) = vault.exit(100e6, dave);
        assertEq(abi.encode(cu, du, vault.feeOwed()), abi.encode(3_000e18, 1_000e18, 0), "the token split");
        assertEq(other.balanceOf(address(vault)), 1e18, "a third token left the vault");
    }

    // ---- the launch token never leaves but by exit ----

    /// @notice Across a whole term, the vault never moves, approves or sells the launch token until an exit, and the exit pays only `to`.
    function test_TheTokenLeavesOnlyThroughExit() public {
        vm.startStateDiffRecording();
        _termUntilExit();
        Vm.AccountAccess[] memory a = vm.stopAndReturnStateDiff();
        for (uint256 i; i < a.length; ++i) {
            bool call = a[i].kind == VmSafe.AccountAccessKind.Call;
            assertFalse(call && a[i].accessor == address(vault) && a[i].account == m.token, "the vault called the launch token before an exit");
        }
        uint256 held = IERC20(m.token).balanceOf(address(vault));
        assertGt(held, 0, "fixture: the pot came home");
        vm.expectCall(m.token, abi.encodeCall(IERC20.transfer, (dave, held)), 1);
        vm.prank(carol);
        vault.exit(CASH, dave);
        assertEq(IERC20(m.token).balanceOf(address(vault)), 0, "the exit left tokens");
    }
}
