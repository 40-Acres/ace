// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {WarpClock} from "../../utils/WarpClock.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceReader} from "../../utils/AceReader.sol";
import {IAceVaultLens, VaultLens} from "../../utils/VaultLens.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {Ace} from "../../../src/ace/hub/Ace.sol";
import {BufferBelowMin, LoanMatured, NoRecordPrice, NotBorrower, OpenExpired, PayoutBelowMin, TenorOutOfRange} from "../../../src/ace/hub/Borrower.sol";
import {BelowMinLot, LendingAbovePrice} from "../../../src/ace/hub/Lender.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams, OpenBounds} from "../../../src/ace/hub/Types.sol";
import {PositionManager} from "../../../src/ace/positions/PositionManager.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultCaps, CapListing, ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {AceVaultFlows, BorrowRequest, Terms, VaultConfig} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {Lend} from "../../../src/interfaces/IVaultTerms.sol";
import {RefiTerms} from "./AceVaultRefinance.t.sol";

/// @title AceVaultDrawMoreForTest
/// @notice The top-up door: the holder draws more on its vault loan in place, the same loan and term, at the market's price.
/// @notice The product consents through its refinance answer at the new principal, which must be the loan's own market.
/// @notice The new cash is held under lendable and every room as a refinance's is; the vault rests exactly it, and nothing stays.
contract AceVaultDrawMoreForTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    IAceVaultLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    AceVault internal vault;
    IAceVaultDoor internal dv;
    RefiTerms internal terms;
    IERC721 internal title;

    address internal curator = address(0xC0A11);
    address internal guardian = address(0x6A2E);
    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0BA);
    address internal stranger = address(0x5EE);
    address internal competitor = address(0xC0FF);

    uint256 internal constant LP_CASH = 1_000_000e6;
    uint256 internal constant UNITS = 4_000e18;
    uint256 internal constant PRINCIPAL = 1_000e6;
    uint256 internal constant AMOUNT = 300e6;
    uint192 internal constant UNCAPPED = type(uint192).max;

    MarketParams internal mpA; // the market a borrow lands in
    MarketParams internal mpB; // another market of the vault's against the same collateral

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = VaultLens.deploy();
        title = IERC721(ace.POSITION_TITLE());
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        record.setObserved(AceFixtures.px(2e18, address(usdc), address(coll)));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        terms = new RefiTerms(predicted, address(ace));
        ProductConfig memory pc =
            ProductConfig({terms: address(terms), door: address(0), inKind: false, drainable: true, capTimelock: 3 days, minTenor: 1 days, maxTenor: 30 days});
        CapListing[] memory caps = new CapListing[](2);
        (caps[0], caps[1]) = (CapListing(address(coll), UNCAPPED), CapListing(predicted, UNCAPPED));
        VaultConfig memory cfg = VaultConfig({
            ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: 0, vestWindow: 1 days, seed: VaultSeed.SEED
        });
        VaultSeed.fund(cfg, predicted);
        vault = new AceVault(cfg, pc, caps, "Top", "tVLT");
        assertEq(address(vault), predicted, "rig: the vault landed off its predicted address");
        dv = IAceVaultDoor(address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        (p.record, p.lender, p.settleBountyBps, p.minTenor, p.maxTenor) = (address(record), predicted, 0, 7 days, 30 days);
        mpA = p;
        p.minPrincipal = 20e6;
        mpB = p;
        terms.setRefinance(mpA, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        _lp(alice, LP_CASH);
    }

    function _lp(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev A loan to the borrower for `tenor` through the vault, its title approved to the vault when `approve`.
    function _loanApproved(uint64 tenor, bool approve) internal returns (uint256 loanId) {
        terms.setBorrow(mpA, Terms({units: UNITS, principal: PRINCIPAL, tenor: tenor, minBufferWad: 0}));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        loanId = vault.borrow(BorrowRequest(address(coll), UNITS, PRINCIPAL, tenor, 0, 0, 0), "", "");
        if (approve) title.approve(address(vault), loanId);
        vm.stopPrank();
    }

    /// @dev A thirty-day loan, its title approved to the vault, a day old.
    function _loan() internal returns (uint256 loanId) {
        loanId = _loanApproved(30 days, true);
        _warpBy(1 days);
    }

    function _top(uint256 loanId, uint256 amount) internal returns (uint256 fee) {
        vm.prank(borrower);
        fee = dv.drawMoreFor(loanId, amount, 0, 0, 0, "");
    }

    function _topReverts(uint256 loanId, uint256 amount, bytes memory err) internal {
        vm.prank(borrower);
        vm.expectRevert(err);
        dv.drawMoreFor(loanId, amount, 0, 0, 0, "");
    }

    function _quoteSupply() internal view returns (uint256) {
        return vault.totalSupply() + vault.pendingFeeShares() + 1e6;
    }

    function _worth(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, vault.totalAssets() + 1, _quoteSupply());
    }

    /// @dev Escrow, from alice, a request worth at least `target` at NAV now.
    function _requestPast(uint256 target) internal {
        uint256 shares = Math.mulDiv(target, _quoteSupply(), vault.totalAssets() + 1, Math.Rounding.Ceil);
        vm.prank(alice);
        vault.requestExit(shares);
        assertGe(_worth(lens.requestedShares(address(vault))), target, "PREMISE: the request is worth the target");
    }

    function _idA() internal view returns (bytes32) {
        return keccak256(abi.encode(mpA));
    }

    function _lent() internal view returns (uint256 lent) {
        (lent,) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
    }

    // ---- the happy path ----

    /// @notice A top-up draws more in place: debt and lent rise by the amount, the loan, its title and its term hold, and nothing rests.
    /// @notice The fee is the hub's on the amount over the term left, netted from the holder's payout, and the door returns it.
    function test_ATopUpDrawsMoreInPlace_TheHolderIsPaidAndNothingRests() public {
        uint256 loanId = _loan();
        Loan memory pre = read.loan(loanId);
        uint256 lentPre = _lent();
        uint256 heldPre = usdc.balanceOf(borrower);
        uint256 quoted = LoanMath.originationFee(AMOUNT, pre.expiry - uint64(_now()), mpA.lenderAprBps);
        assertGt(quoted, 0, "PREMISE: the top-up carries a fee");
        vm.expectEmit(true, true, false, true, address(vault));
        emit IAceVaultDoor.ToppedUp(loanId, borrower, AMOUNT, quoted);
        uint256 fee = _top(loanId, AMOUNT);
        Loan memory post = read.loan(loanId);
        assertEq(fee, quoted, "the door returned other than the hub's fee on the term left");
        assertEq(post.debt, pre.debt + AMOUNT, "the debt rose by other than the amount");
        assertEq(_lent() - lentPre, AMOUNT, "lent rose by other than the amount");
        assertEq(post.expiry, pre.expiry, "the top-up moved the expiry");
        assertEq(post.tenor, pre.tenor, "the top-up moved the tenor");
        assertEq(title.ownerOf(loanId), borrower, "the title left the holder");
        assertEq(usdc.balanceOf(borrower) - heldPre, AMOUNT - fee, "the holder was paid other than the amount less the fee");
        assertEq(ace.restingOf(_idA()), 0, "vault cash rests in the market after the top-up");
    }

    /// @notice Two top-ups stack on one loan: the debt carries both, the term never moves, and the later one pays for less time.
    function test_TwoTopUpsStackOnOneLoan() public {
        uint256 loanId = _loan();
        uint64 expiry = read.loan(loanId).expiry;
        uint256 first = _top(loanId, AMOUNT);
        _warpBy(5 days);
        uint256 second = _top(loanId, AMOUNT);
        assertEq(read.debtOf(loanId), PRINCIPAL + 2 * AMOUNT, "the debt does not carry both top-ups");
        assertEq(read.loan(loanId).expiry, expiry, "a top-up moved the expiry");
        assertLt(second, first, "the later top-up paid for as much time as the first");
    }

    // ---- who may call ----

    /// @notice CR-10: a stranger is refused `NotTheBorrower` though the vault holds the holder's blanket approval and so does the stranger.
    function test_AStrangerIsRefusedThoughTheVaultHoldsABlanketApproval() public {
        uint256 loanId = _loan();
        vm.startPrank(borrower);
        title.setApprovalForAll(address(vault), true);
        title.setApprovalForAll(stranger, true);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(IAceVaultDoor.NotTheBorrower.selector);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        _top(loanId, AMOUNT);
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "CONTROL: the holder's own top-up lands");
    }

    /// @notice A holder who never approved the vault for the title is refused at the hub, which takes the vault for a stranger.
    function test_AnUnapprovedHolderIsRefusedAtTheHub() public {
        uint256 loanId = _loanApproved(30 days, false);
        _warpBy(1 days);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(NotBorrower.selector));
    }

    // ---- the product's answer ----

    /// @notice An answer naming another market refuses `TopUpRefused`, and no market is made for it.
    function test_AnAnswerNamingAnotherMarketRefuses() public {
        uint256 loanId = _loan();
        terms.setRefinance(mpB, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(IAceVaultDoor.TopUpRefused.selector));
        assertEq(ace.idToMarketParams(keccak256(abi.encode(mpB))).quote, address(0), "the refused answer's market was created");
    }

    /// @notice An answer admitting less than the whole new principal refuses `TopUpRefused`; the whole of it lands.
    function test_AnAnswerAdmittingLessThanTheWholeNewPrincipalRefuses() public {
        uint256 loanId = _loan();
        terms.setRefinance(mpA, Terms({units: UNITS, principal: PRINCIPAL + AMOUNT - 1, tenor: 0, minBufferWad: 0}), false);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(IAceVaultDoor.TopUpRefused.selector));
        terms.setRefinance(mpA, Terms({units: UNITS, principal: PRINCIPAL + AMOUNT, tenor: 0, minBufferWad: 0}), false);
        _top(loanId, AMOUNT);
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "CONTROL: an answer admitting the whole new principal lands");
    }

    /// @notice The base binds the answer as it binds a refinance's: an answer on another collateral refuses before the hub.
    function test_TheBaseBindsTheAnswerAsARefinances() public {
        uint256 loanId = _loan();
        MarketParams memory p = mpA;
        p.collateral = address(0xC011);
        terms.setRefinance(p, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(AceVaultCaps.CollateralNotAsked.selector));
    }

    // ---- the room on the new cash ----

    /// @notice The new cash, the amount alone, may not pass lendable, the row's room, the product's room or the total's room.
    function test_TheNewCashIsHeldUnderLendableTheRowTheProductAndTheTotal() public {
        uint256 loanId = _loan();
        vault.crank();
        _requestPast(vault.idle() - 100e6);
        assertLt(vault.lendable(), 200e6, "PREMISE: the requests leave under 200 lendable");
        _topReverts(loanId, 200e6, abi.encodeWithSelector(AceVaultFlows.OverLendable.selector));
        (uint256 requested,) = lens.requestOf(address(vault), alice);
        vm.prank(alice);
        vault.cancelExit(requested);
        vm.prank(curator);
        vault.submitCap(address(coll), uint192(PRINCIPAL + 100e6));
        _topReverts(loanId, 100e6 + 1, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        terms.setRoom(50e6);
        _topReverts(loanId, 51e6, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        vm.prank(curator);
        vault.submitCap(address(vault), uint192(PRINCIPAL + 40e6));
        _topReverts(loanId, 45e6, abi.encodeWithSelector(AceVaultCaps.OverTotal.selector));
        _top(loanId, 40e6);
        assertEq(read.debtOf(loanId), PRINCIPAL + 40e6, "CONTROL: inside every room it lands");
    }

    /// @notice While the requests outweigh idle a top-up refuses `OverLendable`: lendable is zero, and the term never lengthens to ask the gate.
    function test_ATopUpRefusesWhileRequestsOutweighIdle() public {
        uint256 loanId = _loan();
        _requestPast(vault.idle() + ace.lenderOwed(address(vault), address(usdc)) + 1);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(AceVaultFlows.OverLendable.selector));
    }

    /// @notice A product answering a tenor past the loan's expiry never makes a top-up ask the exit gate: the term holds, and the room alone binds.
    function test_TheAnswersTenorIsUnused_NoExitGateAsks() public {
        uint256 loanId = _loan();
        uint64 expiry = read.loan(loanId).expiry;
        terms.setRefinance(mpA, Terms({units: UNITS, principal: PRINCIPAL + AMOUNT, tenor: 30 days, minBufferWad: 0}), false);
        assertGt(_now() + 30 days, expiry, "PREMISE: the answered tenor would end past the loan's expiry");
        uint256 snap = vm.snapshotState();
        _requestPast(vault.idle() + ace.lenderOwed(address(vault), address(usdc)) + 1);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(AceVaultFlows.OverLendable.selector));
        vm.revertToState(snap);
        _top(loanId, AMOUNT);
        assertEq(read.loan(loanId).expiry, expiry, "the answered tenor moved the expiry");
    }

    /// @notice A draining vault refuses `Draining` before anything else.
    function test_ADrainRefuses() public {
        uint256 loanId = _loan();
        vm.prank(curator);
        vault.setDrain(true);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(AceVault.Draining.selector));
    }

    // ---- the loan, and the hub's own refusals ----

    /// @notice A loan of another lender's market is not the vault's to top up: `NotOurLoan`.
    function test_ALoanOfAnotherLenderIsNotOurs() public {
        MarketParams memory p = mpA;
        p.lender = competitor;
        bytes32 other = ace.createMarket(p);
        usdc.mint(competitor, 2 * PRINCIPAL);
        vm.startPrank(competitor);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(other, 2 * PRINCIPAL);
        vm.stopPrank();
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        uint256 lid = ace.open(other, UNITS, PRINCIPAL, 30 days, borrower, OpenBounds(0, 0, 0));
        title.approve(address(vault), lid);
        vm.stopPrank();
        _topReverts(lid, AMOUNT, abi.encodeWithSelector(IAceVaultDoor.NotOurLoan.selector));
    }

    /// @notice A matured loan refuses `LoanMatured` at the door.
    function test_AMaturedLoanRefuses() public {
        uint256 loanId = _loan();
        _warpTo(read.loan(loanId).expiry);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(LoanMatured.selector));
    }

    /// @notice A matured loan refuses at the door before the product is asked, so the hub's own `LoanMatured` is never what stops it.
    function test_AMaturedLoanRefusesAtTheDoorBeforeTheProductIsAsked() public {
        uint256 loanId = _loan();
        _warpTo(read.loan(loanId).expiry);
        vm.expectCall(address(terms), abi.encodeWithSelector(RefiTerms.refinanceTerms.selector), 0);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(LoanMatured.selector));
    }

    /// @notice With under the market's shortest term left the hub refuses `TenorOutOfRange`, and the rest reverts with it.
    function test_UnderTheShortestTermLeftTheHubRefuses() public {
        uint256 loanId = _loan();
        _warpTo(read.loan(loanId).expiry - mpA.minTenor + 1);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(TenorOutOfRange.selector));
        assertEq(ace.restingOf(_idA()), 0, "vault cash rests in the market");
    }

    /// @notice The holder's payout bound reaches the hub: a floor one atom over the net refuses `PayoutBelowMin`.
    function test_TheHoldersPayoutBoundReachesTheHub() public {
        uint256 loanId = _loan();
        uint256 fee = LoanMath.originationFee(AMOUNT, read.loan(loanId).expiry - uint64(_now()), mpA.lenderAprBps);
        vm.prank(borrower);
        vm.expectRevert(PayoutBelowMin.selector);
        dv.drawMoreFor(loanId, AMOUNT, AMOUNT - fee + 1, 0, 0, "");
        vm.prank(borrower);
        dv.drawMoreFor(loanId, AMOUNT, AMOUNT - fee, 0, 0, "");
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "CONTROL: a floor at the net lands");
    }

    // ---- the product's write calls ----

    /// @notice The product hears a refinance's two write calls on the loan's own id, the holder's payload with them, the holder named after.
    function test_TheProductHearsBothWriteCallsOnTheLoansOwnId() public {
        uint256 loanId = _loan();
        vm.prank(borrower);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "memo");
        RefiTerms.Call[] memory c = terms.calls();
        assertEq(c.length, 4, "PREMISE: the borrow's two calls, then the top-up's two");
        assertTrue(c[2].kind == Lend.Refinance && c[2].before, "the top-up's first call is not a refinance's beforeLend");
        assertTrue(c[3].kind == Lend.Refinance && !c[3].before, "the top-up's second call is not a refinance's afterLend");
        assertEq(c[2].loanId, loanId, "beforeLend named another loan");
        assertEq(c[3].loanId, loanId, "afterLend named another loan");
        assertEq(c[3].holder, borrower, "afterLend named another holder");
        assertEq(c[2].borrowerNow, borrower, "the title left the holder during the call");
        assertEq(c[2].data, bytes("memo"), "the payload did not reach the product");
    }

    /// @notice The product's write calls run under the vault's lock: a re-entry from either refuses the guard, and the top-up still lands.
    function test_ReentryFromEitherWriteCallRefusesTheGuard() public {
        uint256 loanId = _loan();
        terms.setReenter(true);
        _top(loanId, AMOUNT);
        bytes[] memory r = terms.reentries();
        assertEq(r.length, 2, "PREMISE: both write calls tried");
        bytes memory guard = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(r[0], guard, "beforeLend's re-entry was not refused");
        assertEq(r[1], guard, "afterLend's re-entry was not refused");
    }

    // ---- the forward ----

    /// @notice A direct call to the library's top-up body reverts.
    function test_ADirectCallToTheTopUpBodyReverts() public {
        address flows = address(AceVaultFlows);
        assertGt(flows.code.length, 0, "premise: the flows library is deployed");
        vm.prank(borrower);
        (bool ok,) = flows.call(abi.encodeCall(IAceVaultDoor.drawMoreFor, (1, AMOUNT, 0, 0, 0, bytes(""))));
        assertFalse(ok, "a direct call ran the top-up body");
    }

    // ---- gas ----

    /// @notice A top-up costs well under a fresh borrow of the same cash: no title, no custody pull, no new loan.
    function test_ATopUpCostsWellUnderAFreshBorrow() public {
        uint256 loanId = _loan();
        terms.setBorrow(mpA, Terms({units: UNITS, principal: AMOUNT, tenor: 30 days, minBufferWad: 0}));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        uint256 g = gasleft();
        vault.borrow(BorrowRequest(address(coll), UNITS, AMOUNT, 30 days, 0, 0, 0), "", "");
        uint256 borrowGas = g - gasleft();
        g = gasleft();
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        uint256 topUpGas = g - gasleft();
        vm.stopPrank();
        assertLt(topUpGas * 10, borrowGas * 7, "a top-up costs over 70% of a fresh borrow");
    }

    // ---- the binding's other side ----

    /// @notice An answer admitting one atom over the whole new principal refuses `OverAsk` at the base, before the own-market check.
    function test_AnAnswerOneAtomOverTheNewPrincipalRefusesOverAsk() public {
        uint256 loanId = _loan();
        terms.setRefinance(mpA, Terms({units: UNITS, principal: PRINCIPAL + AMOUNT + 1, tenor: 0, minBufferWad: 0}), false);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(AceVaultCaps.OverAsk.selector));
    }

    /// @notice A loan whose market reads as the vault's in another quote is `NotOurLoan`: the held-loan check the lending verbs share reads the quote.
    function test_AForeignQuoteIsNotOurLoan() public {
        uint256 loanId = _loan();
        bytes32 id = ace.loanMarket(loanId);
        MarketParams memory mp = ace.idToMarketParams(id);
        mp.quote = address(coll);
        vm.mockCall(address(ace), abi.encodeCall(ace.idToMarketParams, (id)), abi.encode(mp));
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(IAceVaultDoor.NotOurLoan.selector));
        vm.clearMockedCalls();
        _top(loanId, AMOUNT);
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "CONTROL: on its real market the loan tops up");
    }

    // ---- each room at the atom ----

    /// @notice Lendable binds at the atom: a top-up of exactly lendable lands, one atom more refuses `OverLendable`.
    function test_LendableBindsAtTheAtom() public {
        uint256 loanId = _loan();
        vault.crank();
        _requestPast(vault.idle() - 100e6);
        uint256 room = vault.lendable();
        assertGe(room, mpA.minPrincipal, "PREMISE: lendable clears the lot floor");
        assertLt(room, AMOUNT, "PREMISE: lendable binds under the rig's amount");
        _topReverts(loanId, room + 1, abi.encodeWithSelector(AceVaultFlows.OverLendable.selector));
        _top(loanId, room);
        assertEq(read.debtOf(loanId), PRINCIPAL + room, "a top-up of exactly lendable did not land");
    }

    /// @notice Lendable binds at the atom where the requests' worth sits just under a whole atom: the door prices that hold at NAV, not NAV plus one.
    /// @dev The row above sizes its request by CEIL, which leaves the worth a hair over an atom, so a hold priced an atom of NAV high reads the same there.
    /// @dev One share less leaves it a hair under, so an atom more of NAV lifts the hold a whole atom and the verb's cash word must equal `lendable()`.
    function test_LendableBindsAtTheAtomWithTheRequestsWorthJustUnderAStep() public {
        uint256 loanId = _loan();
        vault.crank();
        uint256 target = vault.idle() - 100e6;
        uint256 shares = Math.mulDiv(target, _quoteSupply(), vault.totalAssets() + 1, Math.Rounding.Ceil) - 1;
        vm.prank(alice);
        vault.requestExit(shares);
        (uint256 nav, uint256 q) = (vault.totalAssets(), _quoteSupply());
        assertEq(Math.mulDiv(shares, nav + 1, q), target - 1, "PREMISE: the request's worth floors an atom under the target");
        assertEq(Math.mulDiv(shares, nav + 2, q), target, "PREMISE: an atom more of NAV lifts it a whole atom");
        uint256 room = vault.lendable();
        assertEq(room, vault.idle() - (target - 1), "PREMISE: lendable is idle less the request's worth at NAV");
        assertGe(room, mpA.minPrincipal, "PREMISE: lendable clears the lot floor");
        assertLt(room, AMOUNT, "PREMISE: lendable binds under the rig's amount");
        _topReverts(loanId, room + 1, abi.encodeWithSelector(AceVaultFlows.OverLendable.selector));
        _top(loanId, room);
        assertEq(read.debtOf(loanId), PRINCIPAL + room, "a top-up of exactly lendable did not land");
    }

    /// @notice The row's room binds at the atom: exactly the row's cap less what is lent against it lands, one atom more refuses `OverCap`.
    function test_TheRowsRoomBindsAtTheAtom() public {
        uint256 loanId = _loan();
        assertEq(_lent(), PRINCIPAL, "PREMISE: the loan is all that is lent against the row");
        vm.prank(curator);
        vault.submitCap(address(coll), uint192(PRINCIPAL + 60e6));
        _topReverts(loanId, 60e6 + 1, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        _top(loanId, 60e6);
        assertEq(read.debtOf(loanId), PRINCIPAL + 60e6, "a top-up of exactly the row's room did not land");
    }

    /// @notice The product's room binds at the atom: exactly its room lands, one atom more refuses `OverCap`.
    function test_TheProductsRoomBindsAtTheAtom() public {
        uint256 loanId = _loan();
        terms.setRoom(60e6);
        _topReverts(loanId, 60e6 + 1, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        _top(loanId, 60e6);
        assertEq(read.debtOf(loanId), PRINCIPAL + 60e6, "a top-up of exactly the product's room did not land");
    }

    /// @notice The total's room binds at the atom: exactly the cap less what is lent lands, one atom more refuses `OverTotal`.
    function test_TheTotalsRoomBindsAtTheAtom() public {
        uint256 loanId = _loan();
        assertEq(lens.drawdown(address(vault)), 0, "PREMISE: no drawdown counts against the total");
        assertEq(_lent(), PRINCIPAL, "PREMISE: the loan is all the vault has lent");
        vm.prank(curator);
        vault.submitCap(address(vault), uint192(PRINCIPAL + 60e6));
        _topReverts(loanId, 60e6 + 1, abi.encodeWithSelector(AceVaultCaps.OverTotal.selector));
        _top(loanId, 60e6);
        assertEq(read.debtOf(loanId), PRINCIPAL + 60e6, "a top-up of exactly the total's room did not land");
    }

    // ---- the hub's own bounds, reached through the door ----

    /// @notice A zero top-up, or one an atom under the market's lot floor, refuses `BelowMinLot` at the rest; exactly the floor lands.
    function test_AnAmountUnderTheLotFloorRefusesAtTheRest_TheFloorLands() public {
        uint256 loanId = _loan();
        _topReverts(loanId, 0, abi.encodeWithSelector(BelowMinLot.selector));
        _topReverts(loanId, mpA.minPrincipal - 1, abi.encodeWithSelector(BelowMinLot.selector));
        _top(loanId, mpA.minPrincipal);
        assertEq(read.debtOf(loanId), PRINCIPAL + mpA.minPrincipal, "a top-up of exactly the lot floor did not land");
    }

    /// @notice A record an atom under the market's price refuses `LendingAbovePrice` at the rest, and a dark one `NoRecordPrice` at the draw.
    /// @notice CONTROL: a record at exactly the price tops up.
    function test_ARecordUnderThePriceOrDarkRefusesTheTopUp() public {
        uint256 loanId = _loan();
        record.setMinPrice(mpA.price - 1);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(LendingAbovePrice.selector));
        record.setMinPrice(0);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(NoRecordPrice.selector));
        record.setMinPrice(mpA.price);
        _top(loanId, AMOUNT);
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "CONTROL: a record at the price tops up");
    }

    /// @notice The holder's deadline reaches the hub: a second past it refuses `OpenExpired`, and a deadline of now lands.
    function test_TheHoldersDeadlineReachesTheHub() public {
        uint256 loanId = _loan();
        vm.prank(borrower);
        vm.expectRevert(OpenExpired.selector);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, uint64(_now()) - 1, "");
        vm.prank(borrower);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, uint64(_now()), "");
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "CONTROL: a deadline of now lands");
    }

    /// @dev The buffer the hub reads after topping `loanId` up by `amount`: the floor less the trigger on the new debt, over the floor; state restored.
    function _bufferAfter(uint256 loanId, uint256 amount) internal returns (uint256 buffer) {
        uint256 snap = vm.snapshotState();
        _top(loanId, amount);
        buffer = Math.mulDiv(mpA.price - read.triggerPrice(loanId), 1e18, mpA.price);
        vm.revertToState(snap);
        assertGt(buffer, 0, "PREMISE: the top-up leaves a buffer");
    }

    /// @notice The holder's buffer bound reaches the hub on the whole new debt: the exact buffer the top-up leaves lands, one wei more refuses.
    function test_TheHoldersBufferBoundReachesTheHubAtTheWei() public {
        uint256 loanId = _loan();
        uint256 buffer = _bufferAfter(loanId, AMOUNT);
        vm.prank(borrower);
        vm.expectRevert(BufferBelowMin.selector);
        dv.drawMoreFor(loanId, AMOUNT, 0, buffer + 1, 0, "");
        vm.prank(borrower);
        dv.drawMoreFor(loanId, AMOUNT, 0, buffer, 0, "");
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "a bound at the exact buffer did not land");
    }

    /// @notice The product's answered buffer reaches the hub as the larger of the two: one over what the top-up leaves refuses, though the holder asks none.
    function test_TheProductsBufferReachesTheHub() public {
        uint256 loanId = _loan();
        uint256 buffer = _bufferAfter(loanId, AMOUNT);
        terms.setRefinance(mpA, Terms({units: UNITS, principal: PRINCIPAL + AMOUNT, tenor: 0, minBufferWad: buffer + 1}), false);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(BufferBelowMin.selector));
        terms.setRefinance(mpA, Terms({units: UNITS, principal: PRINCIPAL + AMOUNT, tenor: 0, minBufferWad: buffer}), false);
        _top(loanId, AMOUNT);
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "CONTROL: a product buffer at the exact one lands");
    }

    // ---- a new holder ----

    /// @notice A transferred title moves the door: the old holder is refused `NotTheBorrower`, and the new one `NotBorrower` at the hub until it approves.
    /// @notice Once it approves the vault the new holder tops up, and the hub pays it, never the old holder.
    function test_ATransferredTitleMovesTheDoorToTheNewHolder() public {
        address heir = address(0xB0B2);
        uint256 loanId = _loan();
        vm.prank(borrower);
        title.transferFrom(borrower, heir, loanId);
        _topReverts(loanId, AMOUNT, abi.encodeWithSelector(IAceVaultDoor.NotTheBorrower.selector));
        vm.prank(heir);
        vm.expectRevert(NotBorrower.selector);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        vm.prank(heir);
        title.approve(address(vault), loanId);
        uint256 oldHeld = usdc.balanceOf(borrower);
        uint256 quoted = LoanMath.originationFee(AMOUNT, read.loan(loanId).expiry - uint64(_now()), mpA.lenderAprBps);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IAceVaultDoor.ToppedUp(loanId, heir, AMOUNT, quoted);
        vm.prank(heir);
        dv.drawMoreFor(loanId, AMOUNT, 0, 0, 0, "");
        assertEq(usdc.balanceOf(heir), AMOUNT - quoted, "the new holder was paid other than the amount less the fee");
        assertEq(usdc.balanceOf(borrower), oldHeld, "the old holder was paid");
        assertEq(read.debtOf(loanId), PRINCIPAL + AMOUNT, "the new holder's top-up did not land");
    }

    // ---- the vault's books ----

    /// @notice A top-up lowers no NAV: gross NAV rises by no more than the fee and the escrow it earns, and the hub's credit comes home in the call.
    function test_ATopUpLowersNoNav_TheCreditComesHome() public {
        uint256 loanId = _loan();
        vault.crank();
        uint256 navPre = vault.totalAssets();
        uint256 grossPre = vault.grossNav();
        uint256 escrowPre = read.feeEscrowOf(loanId);
        uint256 fee = _top(loanId, AMOUNT);
        assertGe(vault.totalAssets(), navPre, "the top-up lowered NAV");
        assertGt(vault.grossNav(), grossPre, "the top-up earned the vault nothing");
        assertLe(vault.grossNav() - grossPre, fee + escrowPre, "gross NAV rose by more than the fee and the escrow it earns");
        assertEq(ace.lenderOwed(address(vault), address(usdc)), 0, "the hub's credit did not come home in the call");
        assertEq(ace.restingOf(_idA()), 0, "vault cash rests in the market");
    }

    /// @notice A topped-up loan repays whole: both draws come home, nothing stays lent against the row, and the vault ends no poorer than before the top-up.
    function test_ATopUpRepaysWhole_NothingStaysLent() public {
        uint256 loanId = _loan();
        vault.crank();
        uint256 grossPre = vault.grossNav();
        _top(loanId, AMOUNT);
        uint256 debt = read.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
        vault.crank();
        assertEq(_lent(), 0, "the repaid loan stays lent against the row");
        assertEq(ace.lenderOwed(address(vault), address(usdc)), 0, "the repayment did not come home");
        assertGe(vault.idle(), grossPre, "the vault ended poorer than before the top-up");
    }
}
