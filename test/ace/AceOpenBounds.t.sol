// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {BadNonce, BadSig, NotAuthorized, SigExpired} from "../../src/ace/hub/Ace.sol";
import {BufferBelowMin, OpenExpired, PayoutBelowMin, TriggerAboveFloor, ZeroCollateral} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PersistenceRecord} from "../utils/PersistenceRecord.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {
    IGrantDoor,
    INonceReader,
    NonceObserving1271Wallet,
    Permissive1271Wallet,
    Reentering1271Wallet,
    Reverting1271Wallet,
    ShortMagic1271Wallet,
    ShortReturn1271Wallet,
    Signing1271Wallet,
    WrongAnswer1271Wallet
} from "../mocks/Mock1271Wallet.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceOpenBounds
/// @notice The borrower's open-time protections: `minPayout`, `minBufferWad`, `deadline`.
/// @notice Plus the third-party draw -- opening in another's name -- and the CREDIT DELEGATION grant.
/// @dev Bounds exist because fee, payout, roll-reserve pull and the funding floor are all read from LIVE state at mine time.
/// @dev So state moving between a borrower's quote and their mined tx silently changes their outcome.
/// @dev The legacy `OpenBounds`, `OpenBoundsHardening` and `ZeroCollateralOpen` suites are the spec for the first two.
/// @dev THE CREDIT-DELEGATION HALF HAS NO SPEC: no legacy test names `setCreditOperator`, `openFor` or `openWithBounds`.
/// @dev So those are NEW coverage, written against replay, expiry, a foreign signer, and ERC-6909 receipt-operator aliasing.
/// @dev DEFERRED, not dropped: eight legacy tests assert `quoteOpen` / `previewDrawFloor`, both VIEWS on the per-market pair.
/// @dev `Ace.previewOpen` and `AceLens.quoteOpen` replace them over `LadderWalks.preview`, so the eight are owed a port.
contract AceOpenBoundsTest is WarpClock {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal id;
    // the ordered pair the record prices; every record read is parameterized by it
    address internal recQ;
    address internal recC;

    address internal alice = address(0xA11CE); // lender
    address internal bob = address(0xB0B); // borrower A
    address internal carol; // borrower B, the racing borrower; keyed, so she can sign
    uint256 internal carolPk;
    address internal operator = address(0x0BEE);
    address internal mallory = address(0xBAD); // holds nothing, ever

    uint256 internal T2; // par for this pair; assigned in setUp, since par is not a compile-time value
    uint256 internal T3; // 480 ticks above par, ~1.0492x it
    uint256 internal T4; // 960 ticks above par, ~1.1007x it

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant SCALE = 1 << 96; // the hub's fixed price frame, which no decimal pair moves

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(vault), offset);
    }

    function setUp() public {
        (carol, carolPk) = makeAddrAndKey("carol");
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(vault));
        (recQ, recC) = (address(usdc), address(vault));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.price = T4; // WAS the ladder's top rung, which every quote here was named against
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);

        usdc.mint(alice, 15_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 15_000e6);
        ace.deposit(id, 15_000e6); // WAS three rungs of 5_000; one market, one balance
        vm.stopPrank();
    }

    // ---- helpers ----

    function _fundBorrower(address who) internal {
        vault.mint(who, COLL);
        vm.prank(who);
        vault.approve(address(positionManager), COLL);
    }

    function _openPlain(address who, uint256 principal) internal returns (uint256) {
        vm.prank(who);
        return ace.open(id, COLL, principal, 0, who, OpenBounds(0, 0, 0));
    }

    /// @dev Signs a Permit2 SignatureTransfer for the zero-collateral leg; twin of `AcePermit2`'s helper.
    function _permitBlob(uint256 pk, address token, uint256 amt, uint256 nonce) internal view returns (bytes memory) {
        MockPermit2 p2 = MockPermit2(PERMIT2);
        uint256 deadline = _now() + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(p2.PERMIT_TRANSFER_FROM_TYPEHASH(), keccak256(abi.encode(p2.TOKEN_PERMISSIONS_TYPEHASH(), token, amt)), address(ace), nonce, deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", p2.DOMAIN_SEPARATOR(), structHash)));
        return abi.encode(IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amt), nonce, deadline), abi.encodePacked(r, s, v));
    }

    function _bounds(uint256 minPayout, uint256 minBufferWad, uint64 deadline) internal pure returns (OpenBounds memory) {
        return OpenBounds({minPayout: minPayout, minBufferWad: minBufferWad, deadline: deadline});
    }

    function _fee(uint256 principal) internal pure returns (uint256) {
        uint64 t = ProtocolPolicy.MIN_TENOR;
        return LoanMath.originationFee(principal, t, PocDeployConfig.BASE_BPS, t);
    }

    /// @dev The health buffer a draw landing at `tick` would leave, by `_fundAndCheck`'s arithmetic.
    function _bufferAt(uint256 floor, uint256 principal) internal pure returns (uint256) {
        uint256 trig = LoanMath.triggerPrice(principal, COLL, PocDeployConfig.MIN_COVERAGE_WAD, SCALE);
        return floor <= trig ? 0 : ((floor - trig) * 1e18) / floor;
    }

    // ============ deadline ============

    function test_Open_Deadline_RevertsWhenStale() public {
        _fundBorrower(bob);
        _warpTo(1_000);
        vm.prank(bob);
        vm.expectRevert(OpenExpired.selector);
        ace.open(id, COLL, PRINCIPAL, 0, bob, _bounds(0, 0, uint64(_now() - 1)));
    }

    function test_Open_Deadline_PassesWhenFresh() public {
        _fundBorrower(bob);
        _warpTo(1_000);
        vm.prank(bob);
        assertGt(ace.open(id, COLL, PRINCIPAL, 0, bob, _bounds(0, 0, uint64(_now()))), 0, "at the boundary");
    }

    // ============ minPayout ============

    /// @notice THERE IS NO FEE RACE: the fee reads nothing but principal and term, so a front-run cannot move it.
    /// @dev The property to pin is the ABSENCE of the race.
    function test_Open_NoFeeRace_QuoteSurvivesAFrontRun() public {
        uint256 payoutQuote = PRINCIPAL - _fee(PRINCIPAL);

        _fundBorrower(bob);
        uint256 balBob = usdc.balanceOf(bob);
        _openPlain(bob, PRINCIPAL); // the front-run that used to raise carol's fee
        assertEq(usdc.balanceOf(bob) - balBob, payoutQuote, "bob got exactly the quote");

        _fundBorrower(carol);
        uint256 balCarol = usdc.balanceOf(carol);
        vm.prank(carol);
        assertGt(ace.open(id, COLL, PRINCIPAL, 0, carol, _bounds(payoutQuote, 0, 0)), 0, "the bound still admits");
        assertEq(usdc.balanceOf(carol) - balCarol, payoutQuote, "the bound she was quoted is the bound she gets");
    }

    function test_Open_MinPayout_ExactBoundary() public {
        uint256 exactPayout = PRINCIPAL - _fee(PRINCIPAL);

        _fundBorrower(bob);
        vm.prank(bob);
        assertGt(ace.open(id, COLL, PRINCIPAL, 0, bob, _bounds(exactPayout, 0, 0)), 0, "the exact payout admits");

        _fundBorrower(carol);
        vm.prank(carol);
        vm.expectRevert(PayoutBelowMin.selector);
        ace.open(id, COLL, PRINCIPAL, 0, carol, _bounds(exactPayout + 1, 0, 0)); // one unit tighter: rejects
    }

    // ============ minPayout: the over-fee half of the guard ============

    /// @dev The all-in fee at a staged rate, priced at the market's own shortest term.
    function _feeAt(uint256 principal, uint256 baseBps) internal pure returns (uint256) {
        uint64 t = ProtocolPolicy.MIN_TENOR;
        return LoanMath.originationFee(principal, t, baseBps, t);
    }

    /// @dev Writes `bps` into the market's `baseBps`, past the genesis rails that forbid it at creation.
    /// @dev The slot is FOUND, never hardcoded: only the true one moves what the hub's own getter reports.
    /// @dev So a MarketParams layout shift fails HERE, in the fixture, rather than vacuously downstream.
    /// @dev It writes only into a word whose whole value is today's `baseBps`, so no packed field is disturbed.
    function _forceBaseBps(uint256 bps) internal {
        uint256 was0 = ace.idToMarketParams(id).baseBps;
        for (uint256 i; i < 23; i++) {
            bytes32 slot = bytes32(read.marketSlot(id, i));
            bytes32 was = vm.load(address(ace), slot);
            if (uint256(was) != was0) continue;
            vm.store(address(ace), slot, bytes32(bps));
            if (ace.idToMarketParams(id).baseBps == bps) return;
            vm.store(address(ace), slot, was);
        }
        revert("baseBps slot not found: the MarketParams layout moved");
    }

    /// @notice THE OVER-FEE HALF of the payout guard, at the DEFAULT bound of `minPayout == 0`.
    /// @notice The guard must refuse by NAME there, never panic 0x11 on the payout subtraction.
    /// @dev The input is unreachable at genesis, so `baseBps` is staged past the rails that make it so.
    /// @dev The staging IS the finding: the helper's safety rests on a precondition its signature never states.
    /// @dev Fails if the over-fee leg ever stops binding at a zero bound, because a panic is not `PayoutBelowMin`.
    function test_Open_MinPayout_ZeroBoundStillBindsTheOverFeeCase() public {
        _forceBaseBps(20_000); // 2.2x the draw per minTenor: the fee overshoots the whole principal
        assertGt(_feeAt(PRINCIPAL, 20_000), PRINCIPAL, "the fixture must put the fee OVER the principal");

        _fundBorrower(bob);
        vm.prank(bob);
        vm.expectRevert(PayoutBelowMin.selector);
        ace.open(id, COLL, PRINCIPAL, 0, bob, _bounds(0, 0, 0));
    }

    /// @notice THE CONTROL for the zero-bound row: armed, the very same guard refuses the very same input by the same name.
    /// @notice Together the two rows show `minPayout` no longer decides whether the over-fee leg binds.
    /// @dev The armed half was never the defect, so this row passed before the fix and after it.
    function test_control_MinPayout_ArmedBoundAlreadyBindsTheOverFeeCase() public {
        _forceBaseBps(20_000);
        assertGt(_feeAt(PRINCIPAL, 20_000), PRINCIPAL, "same staged input as the zero-bound case");

        _fundBorrower(bob);
        vm.prank(bob);
        vm.expectRevert(PayoutBelowMin.selector);
        ace.open(id, COLL, PRINCIPAL, 0, bob, _bounds(1, 0, 0)); // one wei of floor arms the whole condition
    }

    // ============ minBufferWad ============

    /// @notice The buffer guard BINDS: a caller demanding more headroom than the market's price affords is refused,
    /// @notice and the same open with the demand off succeeds at exactly the floor it was refused for.
    /// @dev THE RACE IT WAS WRITTEN FOR IS STRUCTURALLY GONE, and that is the finding rather than a coverage loss.
    /// @dev It read: a front-run drains the top tick, the victim's draw walks down to a worse one, and the loan's
    /// @dev funding floor -- and so its buffer -- lands under what was quoted. A market names ONE price. Draining
    /// @dev its cash cannot move that price, so a front-run turns the victim's open into `InsufficientCash`, which
    /// @dev is a refusal rather than a silently worse fill. The guard survives for the demand it can still fail.
    function test_Open_BufferGuardReverts_UnguardedSucceeds() public {
        uint256 affordable = _bufferAt(T4, PRINCIPAL);
        assertGt(affordable, 0, "the market's price really does sit above the trigger");

        _fundBorrower(carol);
        vm.prank(carol);
        vm.expectRevert(BufferBelowMin.selector);
        ace.open(id, COLL, PRINCIPAL, 0, carol, _bounds(0, affordable + 1, 0));

        address dave = address(0xDA5E);
        _fundBorrower(dave);
        uint256 idPlain = _openPlain(dave, PRINCIPAL);
        assertEq(read.fundingFloor(id, idPlain), T4, "and with the demand off the same open funds at the market's price");
    }

    // ============ the default-off path ============

    /// @notice All-zero bounds must be byte-identical to a plain `open`.
    /// @dev Compared under a snapshot, not a second market: identical params hash to the same id, so no control market can coexist.
    function test_Open_BoundsAllZero_ByteIdentical() public {
        _fundBorrower(bob);
        uint256 snap = vm.snapshotState();

        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 idBounds = ace.open(id, COLL, PRINCIPAL, 0, bob, _bounds(0, 0, 0));
        uint256 payoutBounds = usdc.balanceOf(bob) - balBefore;
        uint256 feeBounds = read.loan(idBounds).lastFee;
        uint256 floorBounds = read.fundingFloor(id, idBounds);

        vm.revertToState(snap);
        uint256 balPlain = usdc.balanceOf(bob);
        uint256 idPlain = _openPlain(bob, PRINCIPAL);

        assertEq(idBounds, idPlain, "same loan id");
        assertEq(feeBounds, read.loan(idPlain).lastFee, "same fee");
        assertEq(payoutBounds, usdc.balanceOf(bob) - balPlain, "same net payout");
        assertEq(floorBounds, read.fundingFloor(id, idPlain), "same funding floor");
    }

    // ============ zero collateral, through every door ============

    /// @notice A non-zero debt against zero collateral must be impossible.
    /// @dev The position has no title to transfer, so the lenders' only recovery path is empty from birth.
    function test_INVARIANT_ZeroCollateralAgainstNonZeroDebtIsImpossible() public {
        vm.prank(mallory);
        vm.expectRevert(ZeroCollateral.selector);
        ace.open(id, 0, PRINCIPAL, 0, mallory, OpenBounds(0, 0, 0));
    }

    /// @notice The same hole, re-asked at every door the overload cut left standing: there are two.
    /// @notice The guard lives in `Borrower.open`, so one check closes both entry points at once.
    /// @dev The Permit2 leg is load-bearing: it pulls collateral BEFORE the guard, so plain `open` cannot cover it.
    function test_INVARIANT_ZeroCollateralIsImpossibleThroughEveryOpenEntryPoint() public {
        vm.prank(mallory);
        vm.expectRevert(ZeroCollateral.selector);
        ace.open(id, 0, PRINCIPAL, 0, mallory, _bounds(0, 0, 0));

        vm.etch(PERMIT2, address(new MockPermit2()).code);
        vm.prank(carol);
        vault.approve(PERMIT2, type(uint256).max);
        bytes memory blob = _permitBlob(carolPk, address(vault), 0, 0);
        vm.prank(carol);
        vm.expectRevert(ZeroCollateral.selector);
        ace.openWithPermit2(id, 0, PRINCIPAL, 0, carol, _bounds(0, 0, 0), blob);
    }

    /// @notice The guard is discontinuous at exactly zero and BOTH sides stay closed, for DIFFERENT reasons.
    /// @dev One wei trips the trigger gate, since `k*debt*scale/1` dwarfs any floor.
    /// @dev Zero trips the explicit check instead, because the trigger gate reads 0 and clears.
    /// @dev Collapsing the two errors would mean one of those guards had started doing the other's job.
    function test_control_BothZeroAndOneWeiAreRefused_ForDifferentReasons() public {
        vm.prank(mallory);
        vm.expectRevert(ZeroCollateral.selector);
        ace.open(id, 0, PRINCIPAL, 0, mallory, OpenBounds(0, 0, 0));

        vault.mint(mallory, 1);
        vm.startPrank(mallory);
        vault.approve(address(positionManager), 1);
        vm.expectRevert(TriggerAboveFloor.selector);
        ace.open(id, 1, PRINCIPAL, 0, mallory, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice WITNESS against the REAL record, not the mock: a zero trigger can never be reported below.
    /// @dev So the settlement path could never have finalized a zero-collateral loan.
    /// @dev `persistedBelow` opens with `if (_last >= x) return false`, and `_last >= 0` holds for every uint.
    function test_witness_RealRecordCanNeverReportBelowAZeroTrigger() public {
        PersistenceRecord real = new PersistenceRecord(
            PersistenceRecord.Config({
                writer: address(this),
                truncCapBps: 5000,
                initialPrice: 1e18,
                obsInterval: 1,
                volRefFloor: 1e18,
                obsCap: 64,
                unitScale: 1e30,
                volRefBps: 5000,
                depthWindow: 30,
                quote: address(usdc),
                collateral: address(vault),
                persistenceWindow: 30,
                pendingWindow: 30
            })
        );
        assertFalse(real.persistedBelowDistress(recQ, recC, 0), "a fresh record is not below zero");

        for (uint256 i; i < 40; i++) {
            _warpBy(60);
            real.observe(1, 1e18); // crash to the floor, sustained past the whole window
        }

        assertGt(real.lastObserved(), 0, "the record sits at its floor, but above zero");
        assertTrue(real.persistedBelow(recQ, recC, 1e18, 30 minutes), "it DOES report below a live, non-zero trigger");
        assertFalse(real.persistedBelow(recQ, recC, 0, 30 minutes), "but can NEVER report below a zero trigger");
    }

    // ============ credit delegation: NEW coverage, no legacy spec ============

    /// @notice The direct grant, and its revocation.
    function test_CreditOperator_GrantAndRevoke() public {
        assertFalse(read.creditOperator(carol, operator), "no grant by default");
        vm.prank(carol);
        ace.setCreditOperator(operator, true);
        assertTrue(read.creditOperator(carol, operator), "the grant landed");

        vm.prank(carol);
        ace.setCreditOperator(operator, false);
        assertFalse(read.creditOperator(carol, operator), "and it is revocable");
    }

    /// @notice Without the grant the operator is refused; with it the operator funds and is paid.
    /// @notice The BORROWER takes the debt either way, and `_open` is the one gate both doors pass.
    function test_OpenFor_RequiresTheGrant_ThenPaysThePayer() public {
        vault.mint(operator, COLL);
        vm.prank(operator);
        vault.approve(address(positionManager), COLL);

        vm.prank(operator);
        vm.expectRevert(NotAuthorized.selector);
        ace.open(id, COLL, PRINCIPAL, 0, carol, OpenBounds(0, 0, 0));

        vm.prank(carol);
        ace.setCreditOperator(operator, true);

        uint256 balOp = usdc.balanceOf(operator);
        vm.prank(operator);
        uint256 loanId = ace.open(id, COLL, PRINCIPAL, 0, carol, OpenBounds(0, 0, 0));

        assertEq(read.loan(loanId).borrower, carol, "title and debt are the borrower's");
        assertEq(usdc.balanceOf(operator) - balOp, PRINCIPAL - _fee(PRINCIPAL), "the payer received the payout");
        assertEq(positionManager.collateralOf(loanId), COLL, "the payer's collateral is escrowed under the loan");
    }

    /// @notice The bounded third-party draw: the operator's payout bound is honoured too.
    function test_OpenForWithBounds_OperatorPayerPayee() public {
        vault.mint(operator, COLL);
        vm.prank(operator);
        vault.approve(address(positionManager), COLL);
        vm.prank(carol);
        ace.setCreditOperator(operator, true);

        uint256 payoutQuote = PRINCIPAL - _fee(PRINCIPAL);
        uint256 balOp = usdc.balanceOf(operator);
        vm.prank(operator);
        uint256 loanId = ace.open(id, COLL, PRINCIPAL, 0, carol, _bounds(payoutQuote, 0, 0));

        assertEq(read.loan(loanId).borrower, carol, "title is the borrower's");
        assertEq(usdc.balanceOf(operator) - balOp, payoutQuote, "the payee received the bounded payout");
    }

    function test_OpenForWithBounds_Unauthorized() public {
        _fundBorrower(operator);
        vm.prank(operator);
        vm.expectRevert(NotAuthorized.selector);
        ace.open(id, COLL, PRINCIPAL, 0, carol, _bounds(0, 0, 0));
    }

    // DELETED with the receipt token: the ERC-6909 operator grant it guarded against aliasing no longer exists.

    /// @dev The EIP-712 digest the hub verifies.
    /// @dev The typehash string is deliberately unchanged from the legacy grant, so integrator signing code carries over untouched.
    function _grantDigest(address borrower, address op, bool allowed, uint256 nonce, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SetOperator(address borrower,address operator,bool allowed,uint256 nonce,uint256 deadline)"), borrower, op, allowed, nonce, deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", ace.DOMAIN_SEPARATOR(), structHash));
    }

    /// @dev The door takes a `bytes` signature so a contract wallet can answer it, so an ECDSA one is packed r-s-v.
    function _signGrant(uint256 pk, address borrower, bool allowed, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _grantDigest(borrower, operator, allowed, nonce, deadline));
        return _packSig(v, r, s);
    }

    function _packSig(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        return abi.encodePacked(r, s, v);
    }

    /// @notice A borrower's signature grants credit delegation without the borrower sending a tx, and consumes exactly one nonce.
    function test_CreditOperatorWithSig_GrantsFromASignature() public {
        assertEq(read.creditOperatorNonce(carol), 0, "the nonce starts at zero");
        bytes memory sig = _signGrant(carolPk, carol, true, 0, _now() + 1 days);

        vm.prank(operator); // anyone may relay it
        ace.setCreditOperatorWithSig(carol, operator, true, 0, _now() + 1 days, sig);

        assertTrue(read.creditOperator(carol, operator), "the signed grant landed");
        assertEq(read.creditOperatorNonce(carol), 1, "and consumed exactly one nonce");
    }

    /// @notice REPLAY: the same signature cannot be used twice, because the nonce has moved on.
    function test_CreditOperatorWithSig_RejectsAReplayedSignature() public {
        uint256 deadline = _now() + 1 days;
        bytes memory sig = _signGrant(carolPk, carol, true, 0, deadline);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);

        vm.expectRevert(BadNonce.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);
    }

    /// @notice A revocation signed at the CURRENT nonce still works.
    /// @dev The nonce bounds replay; it does not strand the borrower's ability to take the grant back.
    function test_CreditOperatorWithSig_RevokesAtTheNextNonce() public {
        uint256 deadline = _now() + 1 days;
        bytes memory sig = _signGrant(carolPk, carol, true, 0, deadline);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);

        sig = _signGrant(carolPk, carol, false, 1, deadline);
        ace.setCreditOperatorWithSig(carol, operator, false, 1, deadline, sig);
        assertFalse(read.creditOperator(carol, operator), "the signed revocation landed");
    }

    function test_CreditOperatorWithSig_RejectsAnExpiredDeadline() public {
        _warpTo(1_000);
        uint256 stale = _now() - 1;
        bytes memory sig = _signGrant(carolPk, carol, true, 0, stale);

        vm.expectRevert(SigExpired.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, stale, sig);
    }

    /// @notice A signature from anyone other than the borrower is refused, however well-formed.
    function test_CreditOperatorWithSig_RejectsAForeignSigner() public {
        (, uint256 malloryPk) = makeAddrAndKey("mallory");
        uint256 deadline = _now() + 1 days;
        bytes memory sig = _signGrant(malloryPk, carol, true, 0, deadline);

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);
    }

    /// @notice The grant is bound to the MARKET-INDEPENDENT hub and to this chain.
    /// @dev The domain separator is what stops a signature being replayed onto another deployment.
    function test_CreditOperatorWithSig_RejectsAForeignDomain() public {
        uint256 deadline = _now() + 1 days;
        bytes32 foreignDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ACE")),
                keccak256(bytes("1")),
                block.chainid + 1, // a different chain
                address(ace)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SetOperator(address borrower,address operator,bool allowed,uint256 nonce,uint256 deadline)"),
                carol,
                operator,
                true,
                uint256(0),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolPk, keccak256(abi.encodePacked("\x19\x01", foreignDomain, structHash)));
        bytes memory sig = _packSig(v, r, s);

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);
    }

    // ============ revocation must not be outlived ============

    /// @notice The DIRECT door spends the caller's signature nonce, so a direct write invalidates the signature standing at it.
    /// @dev Grant and revoke both spend one: the borrower's invalidation path must not depend on which way they wrote.
    function test_CreditOperator_DirectWriteSpendsTheNonce() public {
        assertEq(read.creditOperatorNonce(carol), 0, "the nonce starts at zero");

        vm.prank(carol);
        ace.setCreditOperator(operator, true);
        assertEq(read.creditOperatorNonce(carol), 1, "the direct grant spent one");

        vm.prank(carol);
        ace.setCreditOperator(operator, false);
        assertEq(read.creditOperatorNonce(carol), 2, "and so did the direct revocation");
    }

    /// @notice THE REPRO: a borrower who revokes DIRECTLY has invalidated the signature they left outstanding.
    /// @dev Unfixed, the stale grant relays and the operator opens in the borrower's name -- under a per-borrower gate quota, that is the borrower's own quota.
    function test_CreditOperator_DirectRevokeKillsTheOutstandingSignature() public {
        uint256 deadline = _now() + 1 days;
        bytes memory sig = _signGrant(carolPk, carol, true, 0, deadline);

        vm.prank(carol);
        ace.setCreditOperator(operator, true);
        vm.prank(carol);
        ace.setCreditOperator(operator, false);
        assertFalse(read.creditOperator(carol, operator), "the direct revocation landed");

        vm.prank(operator);
        vm.expectRevert(BadNonce.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);
        assertFalse(read.creditOperator(carol, operator), "and the stale signature did not restore it");

        vault.mint(operator, COLL);
        vm.prank(operator);
        vault.approve(address(positionManager), COLL);
        vm.prank(operator);
        vm.expectRevert(NotAuthorized.selector);
        ace.open(id, COLL, PRINCIPAL, 0, carol, OpenBounds(0, 0, 0));
    }

    /// @notice The nonce row is the writer's own, so nobody else's grant can strand a borrower's pending signature.
    function test_CreditOperator_AStrangersWriteCannotMoveMyNonce() public {
        vm.prank(operator);
        ace.setCreditOperator(carol, true);

        assertEq(read.creditOperatorNonce(carol), 0, "carol's nonce is untouched by someone else's write");
        assertEq(read.creditOperatorNonce(operator), 1, "the writer spent their own");
    }

    /// @notice The separator is re-derived once the chain id leaves the one the hub was constructed on.
    function test_DomainSeparator_FollowsTheChainId() public {
        bytes32 atDeploy = ace.DOMAIN_SEPARATOR();
        assertEq(atDeploy, _domainSeparatorFor(block.chainid), "the CACHED branch is right in absolute terms");

        uint256 forked = block.chainid + 1;
        vm.chainId(forked);

        assertTrue(ace.DOMAIN_SEPARATOR() != atDeploy, "the separator moved with the chain");
        assertEq(ace.DOMAIN_SEPARATOR(), _domainSeparatorFor(forked), "and it is the new chain's separator");
    }

    /// @notice THE REPRO: a grant signed for the pre-fork chain does not verify once the chain id has moved.
    function test_CreditOperatorWithSig_RejectsAPreForkSignature() public {
        uint256 deadline = _now() + 1 days;
        bytes memory sig = _signGrant(carolPk, carol, true, 0, deadline);

        vm.chainId(block.chainid + 1);

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);
        assertFalse(read.creditOperator(carol, operator), "no grant crossed the fork");
    }

    /// @notice The other direction, so a fix that rebuilds the separator from the wrong inputs cannot pass.
    /// @dev The digest is built HERE over the forked id rather than read back from the getter, which would pass either way.
    function test_CreditOperatorWithSig_AcceptsASignatureMadeOnTheNewChain() public {
        uint256 forked = block.chainid + 1;
        vm.chainId(forked);
        uint256 deadline = _now() + 1 days;

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SetOperator(address borrower,address operator,bool allowed,uint256 nonce,uint256 deadline)"),
                carol,
                operator,
                true,
                uint256(0),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolPk, keccak256(abi.encodePacked("\x19\x01", _domainSeparatorFor(forked), structHash)));
        bytes memory sig = _packSig(v, r, s);

        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);
        assertTrue(read.creditOperator(carol, operator), "a grant signed on the new chain lands there");
    }

    // ============ ERC-1271: the relayed door serves smart accounts ============

    /// @notice A contract wallet that answers the magic value for the digest takes the relayed door.
    function test_CreditOperatorWithSig_AcceptsAContractWalletSignature() public {
        Signing1271Wallet wallet = new Signing1271Wallet();
        uint256 deadline = _now() + 1 days;
        wallet.sign(_grantDigest(address(wallet), operator, true, 0, deadline));

        vm.prank(operator);
        ace.setCreditOperatorWithSig(address(wallet), operator, true, 0, deadline, hex"beef");

        assertTrue(read.creditOperator(address(wallet), operator), "the wallet's grant landed");
        assertEq(read.creditOperatorNonce(address(wallet)), 1, "and consumed exactly one nonce");
    }

    /// @notice A wallet that has not signed THIS digest is refused, so the door is not a rubber stamp for contracts.
    function test_CreditOperatorWithSig_RejectsAnUnsignedContractWallet() public {
        Signing1271Wallet wallet = new Signing1271Wallet();

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(address(wallet), operator, true, 0, _now() + 1 days, hex"beef");
    }

    /// @notice A wallet answering a well-formed but WRONG selector is refused; only the magic value admits.
    function test_CreditOperatorWithSig_RejectsAWrongAnswerFromAWallet() public {
        WrongAnswer1271Wallet wallet = new WrongAnswer1271Wallet();

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(address(wallet), operator, true, 0, _now() + 1 days, hex"beef");
    }

    /// @notice A wallet returning a short answer with the WRONG content is refused.
    /// @dev Refused on content, not on frame: the length check is what `ShortMagic1271Wallet` pins, and only it does.
    function test_CreditOperatorWithSig_RejectsAShortReturnFromAWallet() public {
        ShortReturn1271Wallet wallet = new ShortReturn1271Wallet();

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(address(wallet), operator, true, 0, _now() + 1 days, hex"beef");
    }

    /// @notice A wallet that REVERTS is refused by name: its error is a non-answer, never something the hub bubbles.
    /// @dev So a borrower's own code cannot pick the revert reason the door fails with, and callers branch on one selector.
    function test_CreditOperatorWithSig_ARevertingWalletIsRefusedByName() public {
        Reverting1271Wallet wallet = new Reverting1271Wallet();
        uint256 deadline = _now() + 1 days;

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(address(wallet), operator, true, 0, deadline, hex"beef");
        assertEq(read.creditOperatorNonce(address(wallet)), 0, "a reverted call spends nothing");

        vm.prank(address(wallet));
        ace.setCreditOperator(operator, true);
        assertEq(read.creditOperatorNonce(address(wallet)), 1, "and the direct door still moves it");
    }

    /// @notice CEI: the nonce is spent BEFORE the borrower's code is asked, and the wallet's own read proves the order.
    /// @dev A wallet answering only when it ALREADY sees nonce 1 cannot be admitted by a door that asks first and spends after.
    function test_CreditOperatorWithSig_SpendsTheNonceBeforeAskingTheWallet() public {
        NonceObserving1271Wallet spends = new NonceObserving1271Wallet(INonceReader(address(read)), 1);

        ace.setCreditOperatorWithSig(address(spends), operator, true, 0, _now() + 1 days, hex"beef");
        assertTrue(read.creditOperator(address(spends), operator), "the wallet saw the nonce already spent");
    }

    /// @notice The same order from the other side, as its own kill signal rather than a leg the test above can hide.
    /// @dev A wallet answering only while the nonce is STILL 0 must never be admitted; it is refused because the spend came first.
    function test_CreditOperatorWithSig_AWalletSeeingTheOldNonceIsRefused() public {
        NonceObserving1271Wallet asksFirst = new NonceObserving1271Wallet(INonceReader(address(read)), 0);

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(address(asksFirst), operator, true, 0, _now() + 1 days, hex"beef");
    }

    /// @notice The 1271 branch is selected by CODE PRESENCE, which under EIP-7702 flips on and off at one address.
    /// @notice Same address, same digest: ECDSA verifies while it has no code, and the wallet answers once it does.
    /// @dev This is 7702 item 3 becoming live, which the standing rejection had disposed of as "no surface".
    function test_CreditOperatorWithSig_CodePresenceSelectsTheBranch() public {
        (address eoa, uint256 eoaPk) = makeAddrAndKey("delegating-eoa");
        uint256 deadline = _now() + 1 days;

        bytes memory sig = _signGrant(eoaPk, eoa, true, 0, deadline);

        vm.etch(eoa, address(new Signing1271Wallet()).code);
        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(eoa, operator, true, 0, deadline, sig);

        vm.etch(eoa, hex"");
        ace.setCreditOperatorWithSig(eoa, operator, true, 0, deadline, sig);
        assertTrue(read.creditOperator(eoa, operator), "the same signature verifies once the address has no code");
    }

    /// @notice 7702 ITEM 3, made concrete: a delegate that answers unconditionally admits a signature nobody made.
    /// @dev Self-inflicted rather than third-party -- whoever sets an account's 7702 delegate can already act as it.
    function test_CreditOperatorWithSig_APermissiveDelegateAdmitsAnyoneForItself() public {
        (address eoa,) = makeAddrAndKey("permissive-eoa");
        vm.etch(eoa, address(new Permissive1271Wallet()).code);

        vm.prank(operator);
        ace.setCreditOperatorWithSig(eoa, operator, true, 0, _now() + 1 days, hex"");
        assertTrue(read.creditOperator(eoa, operator), "the delegate answered for a signature nobody made");
    }

    // ============ what the mutation screen left alive ============

    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141; // the curve order, for the mirrored s

    event CreditOperatorSet(address indexed borrower, address indexed operator, bool allowed); // the hub's, redeclared to expect it

    /// @dev Signs for an arbitrary operator, where `_signGrant` fixes it to the suite's one.
    function _signGrantFor(uint256 pk, address borrower, address op, bool allowed, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _grantDigest(borrower, op, allowed, nonce, deadline));
        return _packSig(v, r, s);
    }

    /// @notice THE DOCUMENTED INVALIDATION PATH: a write granting NOTHING still kills the signature standing at the nonce.
    /// @dev Revoke-first is the whole point -- a repro that grants before revoking is killed by the GRANT's bump, not the revoke's.
    function test_CreditOperator_ANoOpWriteKillsAPendingSignature() public {
        uint256 deadline = _now() + 1 days;
        bytes memory sig = _signGrant(carolPk, carol, true, 0, deadline);
        assertFalse(read.creditOperator(carol, operator), "nothing was ever granted");

        vm.prank(carol);
        ace.setCreditOperator(operator, false); // writes false over false, and that is the borrower's kill switch
        assertEq(read.creditOperatorNonce(carol), 1, "the no-op spent the nonce anyway");

        vm.prank(operator);
        vm.expectRevert(BadNonce.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);
        assertFalse(read.creditOperator(carol, operator), "and the pending signature is dead");
    }

    /// @notice DELIBERATE RESIDUE: one write spends ONE nonce, so a borrower holding a queue kills N and ARMS N+1.
    /// @dev Pinned rather than reported -- the remedy is a second write, and the door will never walk a nonce past a queue.
    function test_CreditOperator_ADirectWriteArmsTheQueuedSuccessor() public {
        uint256 deadline = _now() + 1 days;
        bytes memory atZero = _signGrant(carolPk, carol, true, 0, deadline);
        bytes memory atOne = _signGrant(carolPk, carol, true, 1, deadline);

        vm.prank(carol);
        ace.setCreditOperator(operator, false);

        vm.expectRevert(BadNonce.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, atZero);

        ace.setCreditOperatorWithSig(carol, operator, true, 1, deadline, atOne);
        assertTrue(read.creditOperator(carol, operator), "the queued successor is armed, not killed");

        vm.prank(carol);
        ace.setCreditOperator(operator, false);
        assertFalse(read.creditOperator(carol, operator), "and a second write is the borrower's remedy");
    }

    /// @notice The two grant doors compose in ONE multicall, so guarding the signed one did not close the batch.
    /// @dev Each leg takes and releases the guard, and the direct leg's bump is what the signed leg must be signed at.
    function test_CreditOperator_MulticallComposesBothDoors() public {
        uint256 deadline = _now() + 1 days;
        bytes memory sig = _signGrantFor(carolPk, carol, mallory, true, 1, deadline);

        bytes[] memory legs = new bytes[](2);
        legs[0] = abi.encodeCall(Ace.setCreditOperator, (operator, true));
        legs[1] = abi.encodeCall(Ace.setCreditOperatorWithSig, (carol, mallory, true, 1, deadline, sig));

        vm.prank(carol);
        ace.multicall(legs);

        assertTrue(read.creditOperator(carol, operator), "the direct leg landed");
        assertTrue(read.creditOperator(carol, mallory), "and the signed leg landed behind it");
        assertEq(read.creditOperatorNonce(carol), 2, "two doors, two nonces");
    }

    /// @notice The deadline is INCLUSIVE: a signature is still live at exactly the second it names.
    function test_CreditOperatorWithSig_AdmitsADeadlineExactlyAtNow() public {
        _warpTo(1_000_000);
        uint256 deadline = _now();
        bytes memory sig = _signGrant(carolPk, carol, true, 0, deadline);

        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);
        assertTrue(read.creditOperator(carol, operator), "a signature is live at its own deadline");
    }

    /// @notice And dead at every second past it, not merely at the one a boundary test would name.
    function testFuzz_CreditOperatorWithSig_IsDeadPastItsDeadline(uint256 ahead) public {
        _warpTo(1_000_000);
        uint256 deadline = _now();
        bytes memory sig = _signGrant(carolPk, carol, true, 0, deadline);

        _warpTo(deadline + bound(ahead, 1, 3650 days));
        vm.expectRevert(SigExpired.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, sig);
    }

    /// @notice Only the CURRENT nonce admits, and a wrong one is refused before the signature is ever looked at.
    /// @dev Signed AT the wrong nonce on purpose: the refusal must be the nonce's, never a signature mismatch standing in for it.
    function testFuzz_CreditOperatorWithSig_OnlyTheCurrentNonceAdmits(uint256 nonce) public {
        nonce = bound(nonce, 1, type(uint128).max);
        uint256 deadline = _now() + 1 days;
        bytes memory sig = _signGrant(carolPk, carol, true, nonce, deadline);

        vm.expectRevert(BadNonce.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, nonce, deadline, sig);
        assertEq(read.creditOperatorNonce(carol), 0, "a refused relay leaves the nonce where it was");
    }

    /// @notice The mirrored `s` of a real signature is refused, so one grant cannot be relayed under two signatures.
    /// @dev New with the SignatureChecker door: bare `ecrecover` admitted both halves of the curve.
    function test_CreditOperatorWithSig_RejectsAMalleableSignature() public {
        uint256 deadline = _now() + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolPk, _grantDigest(carol, operator, true, 0, deadline));
        bytes32 mirrored = bytes32(SECP256K1_N - uint256(s));

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, _packSig(v == 27 ? 28 : 27, r, mirrored));

        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, _packSig(v, r, s));
        assertTrue(read.creditOperator(carol, operator), "and the unmirrored original is what lands");
    }

    /// @notice A signature that is not 65 bytes is refused rather than recovered from whatever it happens to hold.
    /// @dev The door takes `bytes` now, so length is the relayer's to get wrong; EIP-2098's 64-byte form is NOT accepted.
    function test_CreditOperatorWithSig_RejectsAMalformedSignatureLength() public {
        uint256 deadline = _now() + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolPk, _grantDigest(carol, operator, true, 0, deadline));

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, abi.encodePacked(r, s));
        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, hex"");
        assertEq(read.creditOperatorNonce(carol), 0, "and neither refusal spent the nonce");

        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, _packSig(v, r, s));
        assertEq(read.creditOperatorNonce(carol), 1, "the well-formed one spends exactly one");
    }

    /// @notice A wallet answering the magic value in FOUR bytes is refused: right content, wrong frame.
    /// @dev This is what pins the 32-byte length check -- a two-byte answer is refused by its content alone.
    function test_CreditOperatorWithSig_RejectsAShortMagicFromAWallet() public {
        ShortMagic1271Wallet wallet = new ShortMagic1271Wallet();

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(address(wallet), operator, true, 0, _now() + 1 days, hex"beef");
    }

    /// @notice A borrower's wallet cannot write hub state while being asked: the ask is a STATICCALL, so its write reverts.
    /// @dev The refusal is BadSig rather than the wallet's own error, and nothing the failed ask attempted is left behind.
    function test_CreditOperatorWithSig_AWalletCannotWriteWhileBeingAsked() public {
        Reentering1271Wallet wallet = new Reentering1271Wallet(IGrantDoor(address(ace)));

        vm.expectRevert(BadSig.selector);
        ace.setCreditOperatorWithSig(address(wallet), operator, true, 0, _now() + 1 days, hex"beef");
        assertFalse(read.creditOperator(address(wallet), operator), "no grant, from either direction");
        assertEq(read.creditOperatorNonce(address(ace)), 0, "and the hub's own row was never written");
    }

    /// @notice Both doors announce the same event, and the BORROWER is its subject -- never the relayer, never the operator.
    /// @dev An indexer that reads the grant off the event must see the same pair the storage write used.
    function test_CreditOperator_BothDoorsEmitAgainstTheBorrower() public {
        vm.expectEmit(true, true, false, true, address(ace));
        emit CreditOperatorSet(carol, operator, true);
        vm.prank(carol);
        ace.setCreditOperator(operator, true);

        uint256 deadline = _now() + 1 days;
        bytes memory sig = _signGrant(carolPk, carol, false, 1, deadline);
        vm.expectEmit(true, true, false, true, address(ace));
        emit CreditOperatorSet(carol, operator, false);
        vm.prank(mallory); // relayed by a stranger, and still the borrower's event
        ace.setCreditOperatorWithSig(carol, operator, false, 1, deadline, sig);
    }

    /// @notice CONTROL for the foreign-domain refusal: the SAME struct hash under this hub's real domain lands.
    /// @dev Without it, a typo in that test's inline typehash would refuse the signature and the test would still pass.
    function test_control_TheForeignDomainRefusalIsTheDomainNotTheStruct() public {
        uint256 deadline = _now() + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SetOperator(address borrower,address operator,bool allowed,uint256 nonce,uint256 deadline)"),
                carol,
                operator,
                true,
                uint256(0),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolPk, keccak256(abi.encodePacked("\x19\x01", ace.DOMAIN_SEPARATOR(), structHash)));

        ace.setCreditOperatorWithSig(carol, operator, true, 0, deadline, _packSig(v, r, s));
        assertTrue(read.creditOperator(carol, operator), "the same struct under this hub's own domain admits");
    }

    /// @dev The hub's domain separator for an arbitrary chain id, built the way the constructor builds it.
    function _domainSeparatorFor(uint256 chainId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ACE")),
                keccak256(bytes("1")),
                chainId,
                address(ace)
            )
        );
    }

    // ============ the envelope's fee ceiling ============

    /// @dev A market with a real tenor GRID, so the ALL-IN fee ceiling is reachable at a legal baseBps.
    /// @dev `baseBps * maxTenor * 11000 < 10000 * 10000 * minTenor`: a single-rung market never reaches it.
    function _gridParams(uint256 baseBps) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.minTenor = 1 hours;
        p.maxTenor = 22 hours;
        p.baseBps = baseBps;
    }

    /// @notice The fee can never exceed its SHARE ceiling at the LONGEST term the market issues.
    /// @dev 22x the shortest term puts the ALL-IN ceiling at 1e8/(4*22*11000) = 103.3 bps.
    /// @dev It was 413 bps against the old whole-principal bound; the share ceiling moved it.
    /// @dev Still under the envelope's own 500 bps cap, so this rail is binding here and is reachable.
    function test_FeeCeiling_RejectsOneOverAndAdmitsAtTheCeiling() public {
        ace.createMarket(_gridParams(103)); // at the ceiling: admitted

        /// @dev built BEFORE the cheatcode: `_gridParams` reads the reference seam off the hub
        /// @dev an external call in the ARGUMENT list would eat the expectRevert, not createMarket
        MarketParams memory oneOver = _gridParams(104);
        vm.expectRevert(bytes("fee bps too high"));
        ace.createMarket(oneOver);
    }

    // ============ the over-fee clause: why it is unreachable, and why the edit is a superset ============

    /// @dev Seeds a grid market's top tick with cash consenting to its longest term, so every rung draws.
    function _seedGrid(bytes32 gid, uint64 horizon, uint256 amount) internal {
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(ace), amount);
        ace.deposit(gid, amount / 2);
        ace.deposit(gid, amount - amount / 2);
        vm.stopPrank();
    }

    /// @notice WITNESS: at every rung a market issues, the all-in fee is STRICTLY under the smallest
    /// @notice principal that market issues, so `fee > principal` is unreachable and the payout is non-zero.
    /// @dev The RAILS establish that -- genesis `min debt under fee` plus the `feeFundable` share ceiling.
    /// @dev `_payoutCheck` only DEFENDS it, which is why this witness lives beside the guard's own tests.
    function test_witness_OriginationFeeIsStrictlyUnderPrincipalAtEveryAdmissibleOpen() public {
        MarketParams memory p = _gridParams(103); // the all-in ceiling this grid admits
        bytes32 gid = ace.createMarket(p);

        /// @dev SAMPLED across the band rather than stepped along a grid: the tenor grid is gone with the tick
        /// @dev grid, so a market admits every term in `[minTenor, maxTenor]` and there are no rungs to walk.
        /// @dev The fee is monotone in the tenor, so the ends bound the interior and the midpoint is a witness.
        uint64[3] memory terms = [p.minTenor, (p.minTenor + p.maxTenor) / 2, p.maxTenor];
        for (uint256 i; i < terms.length; i++) {
            uint256 termFee = LoanMath.originationFee(p.minDebt, terms[i], p.baseBps, p.minTenor);
            assertLt(termFee, p.minDebt, "the fee is under the smallest principal, at every admissible term");
        }

        _seedGrid(gid, p.maxTenor, 5_000e6);
        uint256 fee = LoanMath.originationFee(p.minDebt, p.maxTenor, p.baseBps, p.minTenor);

        _fundBorrower(bob);
        uint256 bal = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 loanId = ace.open(gid, COLL, p.minDebt, p.maxTenor, bob, _bounds(0, 0, 0));

        assertEq(read.loan(loanId).lastFee, fee, "the hub charged the fee this witness computed");
        assertEq(usdc.balanceOf(bob) - bal, p.minDebt - fee, "and paid out principal less that fee");
        assertGt(usdc.balanceOf(bob) - bal, 0, "the hardest admissible open still pays something out");
    }

    /// @notice THE CONTROL for the guard's edit: it must refuse a STRICT SUPERSET of what it refuses today.
    /// @notice Every input that opens now still opens, at the same payout, under both the zero and armed bounds.
    /// @dev The zero-bound half is the branch the edit changes; the armed half is identical either way.
    /// @dev What makes the superset strict is that `fee < principal` holds at every admissible draw.
    function test_control_NoAdmissibleOpenChangesOutcome() public {
        MarketParams memory p = _gridParams(103);
        bytes32 gid = ace.createMarket(p);
        _seedGrid(gid, p.maxTenor, 12_000e6);

        uint256[] memory principals = new uint256[](3);
        (principals[0], principals[1], principals[2]) = (p.minDebt, p.minDebt + 1, 1_000e6);
        uint64[] memory tenors = new uint64[](2);
        (tenors[0], tenors[1]) = (p.minTenor, p.maxTenor);

        for (uint256 i; i < principals.length; i++) {
            for (uint256 j; j < tenors.length; j++) {
                uint256 fee = LoanMath.originationFee(principals[i], tenors[j], p.baseBps, p.minTenor);
                assertLt(fee, principals[i], "the added clause is INERT: the fee never reaches the principal");
                for (uint256 k; k < 2; k++) {
                    uint256 floor = k == 0 ? 0 : principals[i] - fee; // the changed branch, then the untouched one
                    address who = address(uint160(0xC0DE00 + i * 8 + j * 2 + k));
                    _fundBorrower(who);
                    uint256 bal = usdc.balanceOf(who);
                    vm.prank(who);
                    uint256 loanId = ace.open(gid, COLL, principals[i], tenors[j], who, _bounds(floor, 0, 0));
                    assertGt(loanId, 0, "an input that opens today must still open");
                    assertEq(usdc.balanceOf(who) - bal, principals[i] - fee, "and pay exactly principal - fee");
                }
            }
        }
    }

    /// @notice The inertness at scale: over every admissible draw the market issues, the fee stays under it.
    /// @dev Pure math on the market's own params, so it reaches principals no test ladder could fund.
    function testFuzz_control_OverFeeClauseIsInertAtEveryAdmissibleDraw(uint256 principal, uint64 tenor) public view {
        MarketParams memory p = ace.idToMarketParams(id);
        principal = bound(principal, p.minDebt, type(uint128).max);
        tenor = uint64(bound(uint256(tenor), p.minTenor, p.maxTenor));
        assertLt(LoanMath.originationFee(principal, tenor, p.baseBps, p.minTenor), principal, "fee strictly under principal");
    }
}
