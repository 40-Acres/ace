// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {Permits} from "../../src/ace/hub/libraries/Permits.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {BelowMinLot, GateRefused} from "../../src/ace/hub/Lender.sol";
import {FeeOnTransferUnsupported} from "../../src/ace/hub/libraries/Transfers.sol";
import {NotPermitOwner, Permit2Missing, Permit2TokenMismatch} from "../../src/ace/hub/libraries/Permits.sol";
import {LoanClosed} from "../../src/ace/hub/Borrower.sol";
import {NoMarket} from "../../src/ace/hub/Ace.sol";
import {GUARD_TRIP} from "../utils/GuardTrip.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockUSDTApprove} from "../mocks/MockUSDTApprove.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @dev Exposes `Permits.pull` with a caller-chosen owner, which no hub entry point can produce.
contract PermitsHarness {
    function pull(address token, address owner, uint256 amount, bytes calldata blob) external {
        Permits.pull(token, owner, amount, blob);
    }
}

/// @notice A quote ERC20 that re-enters the hub from inside `transferFrom`, mid Permit2 pull.
/// @dev The hook mocks in test/mocks cannot express this: they fire on the hub or on an EOA signer.
contract ReentrantQuoteERC20 {
    string public name = "Reentrant USD";
    string public symbol = "RUSD";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    Ace public ace;
    bytes32 public marketId;
    bool public armed;

    function wire(Ace a, bytes32 mid) external {
        ace = a;
        marketId = mid;
    }

    function arm() external {
        armed = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev Permit2 executes this inside `Permits.pull`, so the reentry lands mid hub call.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (armed) {
            armed = false;
            ace.deposit(marketId, uint256(1));
        }
        return true;
    }
}

/// @notice A rate-reporting collateral that skims a transfer fee, for the first-guard refusal test.
contract FotVault is MockFeeOnTransferERC20 {
    constructor() MockFeeOnTransferERC20("Fee vMON", "fvMON", 18, 100) {}

    function rate() external pure returns (uint256) {
        return 1e18;
    }
}

/// @notice A rate-reporting collateral with USDT approve semantics, for the forceApprove hand-on leg.
contract UsdtVault is MockUSDTApprove {
    constructor() MockUSDTApprove("Tether vMON", "tvMON", 18) {}

    function rate() external pure returns (uint256) {
        return 1e18;
    }
}

/// @title AcePermit2
/// @notice The three Permit2 SignatureTransfer entries: deposit, repay and open funded by signature.
/// @dev The mock verifies deadline, nonces and spender binding for real; the fork twin proves canonical Permit2.
contract AcePermit2Test is WarpClock {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal id;

    uint256 internal constant LENDER_PK = 0xA11CE;
    uint256 internal constant PAYER_PK = 0xB0B;
    address internal lender;
    address internal payer;
    // WAS a distinct address: one lender per market, and the permit rows deposit as the SIGNER
    address internal attacker = address(0xBAD);

    uint256 internal T2; // ticks above par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3;
    uint256 internal T4;
    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;

    /// @dev The fixture ships min == max tenor, so this is the market's only nonzero rung.
    uint64 internal constant HORIZON = ProtocolPolicy.MIN_TENOR;
    uint64 internal constant OFF_GRID = 14 days;

    event Recash(uint256 indexed loanId, uint256 amount, address indexed from);
    event Repaid(uint256 indexed id, uint256 amount, uint256 remainingDebt);

    /// @dev Every pair this suite builds is a 6-decimal quote over an 18-decimal collateral, so they share a par.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        lender = vm.addr(LENDER_PK);
        payer = vm.addr(PAYER_PK);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.lender = lender; // sole tenancy: this suite deposits as the permit SIGNER, so the market names them
        p.record = address(new MockPersistenceRecord(address(usdc), address(vault)));
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        vm.etch(PERMIT2, address(new MockPermit2()).code);
    }

    // ---- helpers ----

    function _sign(uint256 pk, address token, uint256 amt, uint256 nonce, uint256 deadline, address spender) internal view returns (bytes memory) {
        MockPermit2 p2 = MockPermit2(PERMIT2);
        bytes32 structHash = keccak256(
            abi.encode(p2.PERMIT_TRANSFER_FROM_TYPEHASH(), keccak256(abi.encode(p2.TOKEN_PERMISSIONS_TYPEHASH(), token, amt)), spender, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", p2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _blob(uint256 pk, address token, uint256 permitAmt, uint256 nonce) internal view returns (bytes memory) {
        uint256 deadline = _now() + 1 hours;
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, permitAmt), nonce, deadline);
        return abi.encode(p, _sign(pk, token, permitAmt, nonce, deadline, address(ace)));
    }

    function _fundLadder() internal {
        usdc.mint(lender, 15_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id, 5_000e6);
        ace.deposit(id, 5_000e6);
        ace.deposit(id, 5_000e6);
        vm.stopPrank();
    }

    /// @dev The borrower is `payer`, so the repay-side permits are signed with a known key.
    function _open() internal returns (uint256 loanId) {
        _fundLadder();
        vault.mint(payer, COLL);
        vm.startPrank(payer);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, payer, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev A funded account holding ONLY a Permit2 approval: any plain-allowance pull would revert.
    function _fundViaPermit2Only(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(PERMIT2, type(uint256).max);
    }

    // ============ deposit ============

    function test_DepositWithPermit2_NoAllowanceToAceNeeded() public {
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory blob = _blob(LENDER_PK, address(usdc), 1000e6, 0); // hoisted: a call in the args eats the prank
        vm.prank(lender);
        ace.depositWithPermit2(id, 1000e6, blob);

        assertEq(usdc.allowance(lender, address(ace)), 0, "the approval moved to Permit2, never to ACE");
        assertEq(ace.restingOf(id), 1000e6, "tick credited");

        assertEq(usdc.balanceOf(address(ace)), 1000e6, "hub holds exactly the deposit");
    }

    function test_DepositWithPermit2_RequestedAmountPinnedToAssets() public {
        _fundViaPermit2Only(lender, 2000e6);
        bytes memory blob = _blob(LENDER_PK, address(usdc), 2000e6, 0);
        vm.prank(lender);
        ace.depositWithPermit2(id, 800e6, blob);

        assertEq(usdc.balanceOf(lender), 1200e6, "an over-signed permit moves only the deposit");
        assertEq(ace.restingOf(id), 800e6);
    }

    // ============ repay ============

    function test_RepayWithPermit2_FullRepayClosesLoan() public {
        uint256 loanId = _open();
        _fundViaPermit2Only(payer, PRINCIPAL);
        bytes memory blob = _blob(PAYER_PK, address(usdc), PRINCIPAL, 0);

        vm.prank(payer);
        ace.repayWithPermit2(loanId, PRINCIPAL, blob);

        Loan memory l = read.loan(loanId);
        assertTrue(l.closedAt != 0, "full repayment closes the loan");
        assertEq(positionManager.collateralOf(loanId), 0, "custody left the live ledger");
        vm.prank(payer); // the close CREDITS the collateral to the holder; the pull delivers it
        ace.claimOwed(loanId, payer);
        assertEq(vault.balanceOf(payer), COLL, "collateral back with the borrower");
        assertEq(usdc.allowance(payer, address(ace)), 0, "no ERC20 allowance to ACE was ever needed");
    }

    /// @dev Equivalence with the plain overpay twin: the clamp fires before the pull on both paths.
    function test_RepayWithPermit2_OverpayPullsOnlyClampedDebt() public {
        uint256 loanId = _open();
        uint256 over = PRINCIPAL + 500e6;

        uint256 snap = vm.snapshotState();
        usdc.mint(payer, over);
        vm.startPrank(payer);
        usdc.approve(address(ace), over);
        ace.repay(loanId, over);
        vm.stopPrank();
        uint256 plainFinal = usdc.balanceOf(payer);
        vm.revertToState(snap);

        _fundViaPermit2Only(payer, over);
        bytes memory blob = _blob(PAYER_PK, address(usdc), over, 0);
        vm.prank(payer);
        ace.repayWithPermit2(loanId, over, blob);

        assertEq(read.loan(loanId).debt, 0);
        assertEq(usdc.balanceOf(payer), plainFinal, "the permit path pulls exactly what the plain path pulls");
    }

    function test_RepayWithPermit2_ThirdPartyMayRepay() public {
        uint256 loanId = _open();
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory blob = _blob(LENDER_PK, address(usdc), 1000e6, 7);

        vm.prank(lender);
        ace.repayWithPermit2(loanId, 1000e6, blob);

        assertEq(read.loan(loanId).debt, PRINCIPAL - 1000e6, "repay stays permissionless on the Permit2 path");
    }

    function test_RepayWithPermit2_EmptyBlobFallsBackToAllowance() public {
        uint256 loanId = _open();
        usdc.mint(payer, 1000e6);
        vm.startPrank(payer);
        usdc.approve(address(ace), 1000e6);
        ace.repayWithPermit2(loanId, 1000e6, "");
        vm.stopPrank();

        assertEq(read.loan(loanId).debt, PRINCIPAL - 1000e6, "an empty blob is byte-for-byte the plain path");
    }

    // ============ the signature is bound to signer and spender ============

    /// @dev WAS `InvalidSigner`, the permit's own spender binding. Sole tenancy refuses the relayer FIRST --
    /// @dev the market names one lender and the attacker is not it -- so the signature is never reached.
    /// @dev THAT IS STRICTLY STRONGER: the relay is refused before any Permit2 state is touched at all, and
    /// @dev the spender binding itself is still pinned on `repayWithPermit2`, which carries no tenancy gate.
    function test_RelayedSignature_Reverts() public {
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory blob = _blob(LENDER_PK, address(usdc), 1000e6, 0);

        vm.prank(attacker);
        vm.expectRevert(GateRefused.selector);
        ace.depositWithPermit2(id, 1000e6, blob);
    }

    function test_CrossEntryReplayByThirdParty_Reverts() public {
        uint256 loanId = _open();
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory depositBlob = _blob(LENDER_PK, address(usdc), 1000e6, 0);

        vm.prank(attacker);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        ace.repayWithPermit2(loanId, 1000e6, depositBlob);
    }

    function test_PermitsPull_OwnerMismatch_Reverts() public {
        PermitsHarness h = new PermitsHarness();
        bytes memory blob = _blob(LENDER_PK, address(usdc), 1000e6, 0);

        vm.prank(attacker);
        vm.expectRevert(NotPermitOwner.selector);
        h.pull(address(usdc), lender, 1000e6, blob);
    }

    // ============ Permit2's own guards still bite through ACE ============

    function test_NonceReuse_Reverts() public {
        _fundViaPermit2Only(lender, 2000e6);
        bytes memory blob = _blob(LENDER_PK, address(usdc), 1000e6, 0);

        vm.prank(lender);
        ace.depositWithPermit2(id, 1000e6, blob);

        vm.prank(lender);
        vm.expectRevert(MockPermit2.InvalidNonce.selector);
        ace.depositWithPermit2(id, 1000e6, blob);
    }

    function test_ExpiredDeadline_Reverts() public {
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory blob = _blob(LENDER_PK, address(usdc), 1000e6, 0);

        _warpBy(2 hours);
        vm.prank(lender);
        vm.expectRevert(MockPermit2.SignatureExpired.selector);
        ace.depositWithPermit2(id, 1000e6, blob);
    }

    // ============ ACE-owned guards ============

    function test_TokenMismatch_Reverts() public {
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory blob = _blob(LENDER_PK, address(vault), 1000e6, 0); // names the wrong token

        vm.prank(lender);
        vm.expectRevert(Permit2TokenMismatch.selector);
        ace.depositWithPermit2(id, 1000e6, blob);
    }

    function test_Permit2CodeMissing_Reverts() public {
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory blob = _blob(LENDER_PK, address(usdc), 1000e6, 0);

        vm.etch(PERMIT2, "");
        vm.prank(lender);
        vm.expectRevert(Permit2Missing.selector);
        ace.depositWithPermit2(id, 1000e6, blob);
    }

    function test_FeeOnTransferQuote_RevertsOnPermitPathToo() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20("Fee USD", "FUSD", 6, 100);
        MarketParams memory p = AceFixtures.marketParams(address(fot), address(vault));
        p.lender = lender;
        p.record = address(new MockPersistenceRecord(address(fot), address(vault)));
        bytes32 fid = ace.createMarket(p);

        fot.mint(lender, 1000e6);
        vm.prank(lender);
        fot.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(LENDER_PK, address(fot), 1000e6, 0);

        vm.prank(lender);
        vm.expectRevert(FeeOnTransferUnsupported.selector);
        ace.depositWithPermit2(fid, 1000e6, blob);
    }

    // ============ the horizon grid reaches through the permit stub ============

    /// @notice A signed deposit lands exactly what the blob names, through the same door the plain path uses.
    /// @dev THE THREE HORIZON ROWS ARE GONE. They checked that `depositWithPermit2` THREADED the caller's
    /// @dev horizon rather than defaulting it: one that a nonzero horizon formed the bucket, one on a two-rung
    /// @dev grid where a dropped horizon would otherwise be invisible, one that a live tick refused a mismatched
    /// @dev second deposit. `horizon` is DELETED -- a market's `maxTenor` is the whole of its maturity consent,
    /// @dev asked once at genesis -- so the permit2 door has no extra argument left to drop on the floor.
    /// @dev What survives is the only thing this door adds over the plain one: the signature, the amount, the
    /// @dev nonce. Those are asserted above and below; the threading rows had nothing left to thread.
    function test_DepositWithPermit2_LandsTheSignedAmount() public {
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory blob = _blob(LENDER_PK, address(usdc), 1000e6, 0);
        vm.prank(lender);
        ace.depositWithPermit2(id, 1000e6, blob);

        assertEq(ace.restingOf(id), 1000e6, "the signed cash rests whole, in the market the caller named");
    }

    /// @notice A REFUSAL FIRES BEFORE THE PULL, and before the nonce burns: the ordering is the property.
    /// @dev IT ASKED THIS OF `HorizonNotOnGrid`, which is gone. The ordering it pinned is not: a door that
    /// @dev pulled first and validated second would spend the signature on a deposit it then refused, leaving
    /// @dev the signer unable to retry with the same nonce. `BelowMinLot` is the surviving refusal of that shape.
    function testRevert_DepositWithPermit2_RefusesBeforeThePullAndBeforeTheNonceBurns() public {
        _fundViaPermit2Only(lender, 1000e6);
        uint256 under = ace.idToMarketParams(id).minDebt - 1;
        bytes memory blob = _blob(LENDER_PK, address(usdc), under, 0);

        vm.prank(lender);
        vm.expectRevert(BelowMinLot.selector);
        ace.depositWithPermit2(id, under, blob);

        assertEq(usdc.balanceOf(lender), 1000e6, "the floor gate fires before the pull");
        assertEq(uint256(MockPermit2(PERMIT2).nonceBitmap(lender, 0)), 0, "and before the nonce burns");
    }

    // ============ a blob that will not decode ============

    function testRevert_DepositWithPermit2_GarbageBlob() public {
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory garbage = abi.encode(uint256(1));

        vm.prank(lender);
        vm.expectRevert(bytes(""));
        ace.depositWithPermit2(id, 1000e6, garbage);

        assertEq(usdc.balanceOf(lender), 1000e6, "an undecodable blob moves nothing");
        assertEq(ace.restingOf(id), 0, "and books nothing");
    }

    function testRevert_DepositWithPermit2_TruncatedBlob() public {
        _fundViaPermit2Only(lender, 1000e6);
        bytes memory full = _blob(LENDER_PK, address(usdc), 1000e6, 0);
        bytes memory cut = new bytes(full.length - 32);
        for (uint256 i; i < cut.length; i++) {
            cut[i] = full[i];
        }

        vm.prank(lender);
        vm.expectRevert(bytes(""));
        ace.depositWithPermit2(id, 1000e6, cut);

        assertEq(usdc.balanceOf(lender), 1000e6, "a truncated blob never reaches Permit2");
    }

    /// @dev A 64-byte signature is the classic malleability-stripped shape; Permit2 requires 65.
    function testRevert_DepositWithPermit2_SixtyFourByteSignature() public {
        _fundViaPermit2Only(lender, 1000e6);
        uint256 deadline = _now() + 1 hours;
        bytes memory full = _sign(LENDER_PK, address(usdc), 1000e6, 0, deadline, address(ace));
        bytes memory short = new bytes(64);
        for (uint256 i; i < 64; i++) {
            short[i] = full[i];
        }
        IPermit2.PermitTransferFrom memory p = IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(address(usdc), 1000e6), 0, deadline);
        bytes memory blob = abi.encode(p, short);

        vm.prank(lender);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        ace.depositWithPermit2(id, 1000e6, blob);
    }

    // ============ the relocated Borrower.repay gates, reached from the permit entry ============

    function testRevert_RepayWithPermit2_ClosedLoan() public {
        uint256 loanId = _open();
        _fundViaPermit2Only(payer, PRINCIPAL);
        bytes memory first = _blob(PAYER_PK, address(usdc), PRINCIPAL, 0);
        vm.prank(payer);
        ace.repayWithPermit2(loanId, PRINCIPAL, first);

        bytes memory second = _blob(PAYER_PK, address(usdc), 100e6, 1);
        vm.prank(payer);
        vm.expectRevert(LoanClosed.selector);
        ace.repayWithPermit2(loanId, 100e6, second);
    }

    /// @dev An unknown id resolves to market 0, so the cache refuses before any permit is spent.
    function testRevert_RepayWithPermit2_UnknownLoanId() public {
        _open();
        _fundViaPermit2Only(payer, 100e6);
        bytes memory blob = _blob(PAYER_PK, address(usdc), 100e6, 0);

        vm.prank(payer);
        vm.expectRevert(NoMarket.selector);
        ace.repayWithPermit2(type(uint256).max, 100e6, blob);
    }

    /// @dev `minDebt` gates ADMISSION only, so a paydown under it stands behind both doors; pin it from the permit one.
    function test_RepayWithPermit2_MayLandUnderMinDebt() public {
        uint256 loanId = _open();
        uint256 amt = PRINCIPAL - 5e6; // 5e6 left, under the fixture's 10e6 minDebt
        _fundViaPermit2Only(payer, amt);
        bytes memory blob = _blob(PAYER_PK, address(usdc), amt, 0);

        vm.prank(payer);
        ace.repayWithPermit2(loanId, amt, blob);

        assertEq(read.loan(loanId).debt, 5e6, "the paydown stands, under the floor and open");
        assertFalse(read.loan(loanId).closedAt != 0, "and a dust loan is still a live loan");
    }

    // ============ events survive the relocation under delegatecall ============

    function test_Repay_EmitsRecashAndRepaidFromTheHub() public {
        uint256 loanId = _open();
        usdc.mint(payer, 1000e6);

        vm.startPrank(payer);
        usdc.approve(address(ace), 1000e6);
        vm.expectEmit(true, true, false, true, address(ace));
        emit Recash(loanId, 1000e6, payer);
        vm.expectEmit(true, false, false, true, address(ace));
        emit Repaid(loanId, 1000e6, PRINCIPAL - 1000e6);
        ace.repay(loanId, 1000e6);
        vm.stopPrank();
    }

    function test_RepayWithPermit2_EmitsTheSameEventsFromTheHub() public {
        uint256 loanId = _open();
        _fundViaPermit2Only(payer, 1000e6);
        bytes memory blob = _blob(PAYER_PK, address(usdc), 1000e6, 0);

        vm.expectEmit(true, true, false, true, address(ace));
        emit Recash(loanId, 1000e6, payer);
        vm.expectEmit(true, false, false, true, address(ace));
        emit Repaid(loanId, 1000e6, PRINCIPAL - 1000e6);
        vm.prank(payer);
        ace.repayWithPermit2(loanId, 1000e6, blob);
    }

    // ============ reentrancy from inside the pull ============

    /// @dev The pull is an external call into a creator-chosen ERC20; the mutex is what makes it safe.
    function test_DepositWithPermit2_ReentrantQuoteRefusedByTheMutex() public {
        (ReentrantQuoteERC20 q, bytes32 pid) = _probeMarket();
        q.mint(lender, 1000e6);
        vm.prank(lender);
        q.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(LENDER_PK, address(q), 1000e6, 0);
        q.arm();

        vm.prank(lender);
        vm.expectRevert(GUARD_TRIP);
        ace.depositWithPermit2(pid, 1000e6, blob);
    }

    /// @dev Repay decrements the debt BEFORE the pull, so a reentrant read would see the credit early.
    function test_RepayWithPermit2_ReentrantQuoteRefusedByTheMutex() public {
        (ReentrantQuoteERC20 q, bytes32 pid) = _probeMarket();
        uint256 loanId = _openIn(q, pid);

        vm.prank(payer);
        q.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(PAYER_PK, address(q), 1000e6, 0);
        q.arm();

        vm.prank(payer);
        vm.expectRevert(GUARD_TRIP);
        ace.repayWithPermit2(loanId, 1000e6, blob);
    }

    // ============ zero amounts ============

    /// @dev The one dust quantum floors BOTH paths identically: zero assets is BelowMinLot either way.
    function test_DepositWithPermit2_ZeroAssets_MatchesPlainPath() public {
        _fundViaPermit2Only(lender, 1000e6);

        vm.prank(lender);
        vm.expectRevert(BelowMinLot.selector);
        ace.deposit(id, 0);

        bytes memory blob = _blob(LENDER_PK, address(usdc), 1000e6, 0);
        vm.prank(lender);
        vm.expectRevert(BelowMinLot.selector);
        ace.depositWithPermit2(id, 0, blob);

        assertEq(usdc.balanceOf(lender), 1000e6, "nothing moved on either refusal");
        assertEq(MockPermit2(PERMIT2).nonceBitmap(lender, 0), 0, "a refused deposit spends no nonce");
    }

    function test_RepayWithPermit2_ZeroAmount_MatchesPlainPath() public {
        uint256 loanId = _open();
        _fundViaPermit2Only(payer, 1000e6);
        uint256 held = usdc.balanceOf(payer);

        uint256 snap = vm.snapshotState();
        vm.prank(payer);
        ace.repay(loanId, 0);
        uint256 plainDebt = read.loan(loanId).debt;
        uint256 plainHeld = usdc.balanceOf(payer);
        vm.revertToState(snap);

        bytes memory blob = _blob(PAYER_PK, address(usdc), 1000e6, 0);
        vm.prank(payer);
        ace.repayWithPermit2(loanId, 0, blob);

        assertEq(plainDebt, PRINCIPAL, "the plain zero repay is a no-op");
        assertEq(read.loan(loanId).debt, plainDebt, "and so is the signed one");
        assertEq(plainHeld, held, "the plain path moved no quote");
        assertEq(usdc.balanceOf(payer), held, "and neither did the signed one");
    }

    // ============ open ============

    function test_OpenWithPermit2_NoAllowanceToPositionManagerNeeded() public {
        _fundLadder();
        vault.mint(payer, COLL);
        vm.prank(payer);
        vault.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(PAYER_PK, address(vault), COLL, 0);

        vm.prank(payer);
        uint256 loanId = ace.openWithPermit2(id, COLL, PRINCIPAL, 0, payer, OpenBounds(0, 0, 0), blob);

        assertEq(positionManager.collateralOf(loanId), COLL, "custody written exactly once");
        assertEq(vault.balanceOf(address(positionManager)), COLL, "the custodian's pot holds it");
        assertEq(vault.balanceOf(address(ace)), 0, "the hub's custody was transient");
        assertEq(vault.allowance(address(ace), address(positionManager)), 0, "hand-on approval fully consumed");
        assertEq(vault.allowance(payer, address(positionManager)), 0, "no borrower approval to the positionManager");
        assertEq(read.loan(loanId).borrower, payer, "title to the signer");
        assertGt(usdc.balanceOf(payer), 0, "principal drawn");
    }

    /// @dev Equivalence: tenor 0 through the permit stub is the plain open's minTenor form.
    function test_OpenWithPermit2_TenorZeroMatchesPlainMinTenorOpen() public {
        uint256 snap = vm.snapshotState();
        uint256 plainId = _open();
        uint64 plainExpiry = read.loan(plainId).expiry;
        uint256 plainDebt = read.loan(plainId).debt;
        vm.revertToState(snap);

        _fundLadder();
        vault.mint(payer, COLL);
        vm.prank(payer);
        vault.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(PAYER_PK, address(vault), COLL, 0);
        vm.prank(payer);
        uint256 loanId = ace.openWithPermit2(id, COLL, PRINCIPAL, 0, payer, OpenBounds(0, 0, 0), blob);

        assertEq(read.loan(loanId).expiry, plainExpiry, "tenor 0 is the minTenor form");
        assertEq(read.loan(loanId).debt, plainDebt);
    }

    /// @dev Equivalence against the plain open at the same rung: the tenor threads, not defaults.
    function test_OpenWithPermit2_TenorThreadsToTheChosenRung() public {
        bytes32 gid = _gridMarket();
        usdc.mint(lender, 10_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ace), 10_000e6);
        ace.deposit(gid, 10_000e6);
        vm.stopPrank();

        uint256 snap = vm.snapshotState();
        vault.mint(payer, COLL);
        vm.startPrank(payer);
        vault.approve(address(positionManager), COLL);
        uint256 plainId = ace.open(gid, COLL, PRINCIPAL, 30 days, payer, OpenBounds(0, 0, 0));
        vm.stopPrank();
        uint64 plainExpiry = read.loan(plainId).expiry;
        vm.revertToState(snap);

        vault.mint(payer, COLL);
        vm.prank(payer);
        vault.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(PAYER_PK, address(vault), COLL, 0);
        vm.prank(payer);
        uint256 loanId = ace.openWithPermit2(gid, COLL, PRINCIPAL, 30 days, payer, OpenBounds(0, 0, 0), blob);

        assertEq(read.loan(loanId).expiry, plainExpiry, "the chosen rung, not the minTenor default");
    }

    function test_OpenWithPermit2_EmptyBlobFallsBackToHubAllowance() public {
        _fundLadder();
        vault.mint(payer, COLL);
        vm.startPrank(payer);
        vault.approve(address(ace), COLL); // to the HUB: the fallback's approval target, not the positionManager
        uint256 loanId = ace.openWithPermit2(id, COLL, PRINCIPAL, 0, payer, OpenBounds(0, 0, 0), "");
        vm.stopPrank();

        assertEq(positionManager.collateralOf(loanId), COLL, "a plain hub allowance funds the hand-on path");
        assertEq(vault.allowance(address(ace), address(positionManager)), 0, "hand-on approval fully consumed");
    }

    function testRevert_OpenWithPermit2_QuoteSignedPermit() public {
        _fundLadder();
        vault.mint(payer, COLL);
        vm.prank(payer);
        vault.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(PAYER_PK, address(usdc), COLL, 0); // names the quote; the pull wants collateral

        vm.prank(payer);
        vm.expectRevert(Permit2TokenMismatch.selector);
        ace.openWithPermit2(id, COLL, PRINCIPAL, 0, payer, OpenBounds(0, 0, 0), blob);
    }

    function testRevert_OpenWithPermit2_RelayedSignature() public {
        _fundLadder();
        vault.mint(payer, COLL);
        vm.prank(payer);
        vault.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(PAYER_PK, address(vault), COLL, 0);

        vm.prank(attacker);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        ace.openWithPermit2(id, COLL, PRINCIPAL, 0, attacker, OpenBounds(0, 0, 0), blob);
    }

    function testRevert_OpenWithPermit2_FeeOnTransferCollateral() public {
        FotVault fot = new FotVault();
        bytes32 fid = _collMarket(address(fot));
        fot.mint(payer, COLL);
        vm.prank(payer);
        fot.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _blob(PAYER_PK, address(fot), COLL, 0);

        vm.prank(payer);
        vm.expectRevert(FeeOnTransferUnsupported.selector);
        ace.openWithPermit2(fid, COLL, PRINCIPAL, 0, payer, OpenBounds(0, 0, 0), blob);
    }

    /// @dev Two loans back to back: the forceApprove leg survives USDT approve-race semantics twice.
    function test_OpenWithPermit2_UsdtApproveCollateral_TwiceOver() public {
        UsdtVault tv = new UsdtVault();
        bytes32 tid = _collMarket(address(tv));
        usdc.mint(lender, 15_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(tid, 5_000e6);
        ace.deposit(tid, 5_000e6);
        ace.deposit(tid, 5_000e6);
        vm.stopPrank();

        tv.mint(payer, 2 * COLL);
        vm.prank(payer);
        tv.approve(PERMIT2, type(uint256).max);

        bytes memory b1 = _blob(PAYER_PK, address(tv), COLL, 0);
        vm.prank(payer);
        uint256 l1 = ace.openWithPermit2(tid, COLL, PRINCIPAL, 0, payer, OpenBounds(0, 0, 0), b1);

        bytes memory b2 = _blob(PAYER_PK, address(tv), COLL, 1);
        vm.prank(payer);
        uint256 l2 = ace.openWithPermit2(tid, COLL, PRINCIPAL, 0, payer, OpenBounds(0, 0, 0), b2);

        assertEq(positionManager.collateralOf(l1), COLL);
        assertEq(positionManager.collateralOf(l2), COLL, "the second hand-on approval sets cleanly from zero");
    }

    // ---- extra-market helpers ----

    /// @dev A market over an alternate rate-reporting collateral, same quote and defaults.
    function _collMarket(address coll) internal returns (bytes32 mid) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), coll);
        p.lender = lender;
        p.record = address(new MockPersistenceRecord(address(usdc), coll));
        mid = ace.createMarket(p);
    }

    /// @dev A two-rung tenor grid, {7d, 30d}, so a threaded horizon differs from the minTenor default.
    function _gridMarket() internal returns (bytes32 gid) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.lender = lender; // sole tenancy: this suite deposits as the permit SIGNER, so the market names them
        p.minTenor = 7 days;
        p.maxTenor = 30 days;
        p.record = address(new MockPersistenceRecord(address(usdc), address(vault)));
        gid = ace.createMarket(p);
    }

    /// @dev A market whose quote re-enters the hub mid transfer, wired to deposit at T2 on reentry.
    function _probeMarket() internal returns (ReentrantQuoteERC20 q, bytes32 pid) {
        q = new ReentrantQuoteERC20();
        MarketParams memory p = AceFixtures.marketParams(address(q), address(vault));
        p.lender = lender;
        p.record = address(new MockPersistenceRecord(address(q), address(vault)));
        pid = ace.createMarket(p);
        q.wire(ace, pid);
    }

    /// @dev The probe market's own ladder and loan; `payer` borrows, so the repay permit has a key.
    function _openIn(ReentrantQuoteERC20 q, bytes32 pid) internal returns (uint256 loanId) {
        q.mint(lender, 15_000e6);
        vm.startPrank(lender);
        q.approve(address(ace), 15_000e6);
        ace.deposit(pid, 5_000e6);
        ace.deposit(pid, 5_000e6);
        ace.deposit(pid, 5_000e6);
        vm.stopPrank();

        vault.mint(payer, COLL);
        vm.startPrank(payer);
        vault.approve(address(positionManager), COLL);
        loanId = ace.open(pid, COLL, PRINCIPAL, 0, payer, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }
}
