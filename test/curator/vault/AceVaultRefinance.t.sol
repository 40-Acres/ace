// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {GateRefused, InsufficientCash, LoanMatured} from "../../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../../src/ace/hub/Types.sol";
import {PositionManager} from "../../../src/ace/positions/PositionManager.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultCaps, CapListing, ProductConfig} from "../../../src/curator/libraries/AceVaultCaps.sol";
import {AceVaultFlows, BorrowRequest, Terms, VaultConfig} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {AceVaultTail} from "../../../src/curator/libraries/AceVaultTail.sol";
import {IAceLenderOps} from "../../../src/interfaces/IAceLenderOps.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {Extension} from "../../../src/interfaces/IRollPolicy.sol";
import {IVaultTerms, Lend, RefinanceRequest} from "../../../src/interfaces/IVaultTerms.sol";

/// @notice The vault's refinance door and the refusals it names, by selector: the surface this suite holds the deployed vault to.
interface IRefinanceDoor {
    error NotTheBorrower();
    error WithdrawToVault();

    event Refinanced(uint256 indexed loanId, uint256 indexed newId, address indexed holder, uint256 principal, uint256 out);

    function refinanceFor(
        uint256 loanId,
        address collateral,
        uint256 principal,
        uint64 tenor,
        uint256 minPayout,
        uint256 minBufferWad,
        uint64 deadline,
        uint256 withdrawUnits,
        address withdrawTo,
        bytes calldata data
    ) external returns (uint256 newId, uint256 out);
}

/// @notice A product that answers a settable market for each door, records every write call, and can donate or re-enter inside them.
contract RefiTerms is IVaultTerms {
    struct Call {
        Lend kind;
        uint256 loanId;
        address holder;
        address borrowerNow; // the hub's holder of record for the call's loan, read inside the call
        bool before;
        bytes data;
    }

    address public immutable VAULT;
    address public immutable ACE;
    MarketParams internal _bmp;
    Terms internal _bt;
    MarketParams internal _rmp;
    Terms internal _rt;
    bool public echo = true; // the refinance answer echoes the request's principal and term
    uint256 public productRoom = type(uint256).max;
    uint256 public donation; // cash this contract sends the vault inside `beforeLend`
    bool public reenter; // whether each write call tries the vault's `crank`
    Call[] internal _calls;
    bytes[] internal _reentries;

    constructor(address vault, address ace) {
        (VAULT, ACE) = (vault, ace);
    }

    function setBorrow(MarketParams calldata mp, Terms calldata t) external {
        (_bmp, _bt) = (mp, t);
    }

    function setRefinance(MarketParams calldata mp, Terms calldata t, bool echo_) external {
        (_rmp, _rt, echo) = (mp, t, echo_);
    }

    function setRoom(uint256 r) external {
        productRoom = r;
    }

    function setDonation(uint256 d) external {
        donation = d;
    }

    function setReenter(bool on) external {
        reenter = on;
    }

    function calls() external view returns (Call[] memory) {
        return _calls;
    }

    function reentries() external view returns (bytes[] memory) {
        return _reentries;
    }

    function borrowTerms(address, BorrowRequest calldata, bytes calldata) external view returns (MarketParams memory, Terms memory) {
        return (_bmp, _bt);
    }

    function refinanceTerms(address, uint256, RefinanceRequest calldata r, bytes calldata) external view returns (MarketParams memory, Terms memory) {
        if (!echo) return (_rmp, _rt);
        return (_rmp, Terms(_rt.units, r.principal, r.tenor, 0));
    }

    function admitsExtension(Extension calldata, bytes calldata) external pure returns (bool) {
        return true;
    }

    function room(MarketParams calldata) external view returns (uint256) {
        return productRoom;
    }

    function entryCap(address, uint256) external pure returns (uint256) {
        return type(uint256).max;
    }

    function beforeLend(Lend kind, MarketParams calldata, uint256 loanId, bytes calldata data) external {
        _calls.push(Call(kind, loanId, address(0), Ace(ACE).borrowerOf(loanId), true, data));
        if (donation != 0) IERC20(Ace(ACE).idToMarketParams(Ace(ACE).loanMarket(loanId)).quote).transfer(VAULT, donation);
        _tryReenter();
    }

    function afterLend(Lend kind, MarketParams calldata, uint256 loanId, address holder, bytes calldata data) external {
        _calls.push(Call(kind, loanId, holder, Ace(ACE).borrowerOf(loanId), false, data));
        _tryReenter();
    }

    function _tryReenter() private {
        if (!reenter) return;
        (bool ok, bytes memory r) = VAULT.call(abi.encodeWithSignature("crank()"));
        _reentries.push(ok ? bytes("ok") : r);
    }
}

/// @notice Two refinances in one transaction, with an optional exit request between them, so both read the vault's transient words.
contract TwoRefinances {
    function both(IRefinanceDoor v, address coll, uint256 a, uint256 b, uint256 principal, address shares, uint256 request) external {
        address title = Ace(IAceVaultDoorView(address(v)).ACE()).POSITION_TITLE();
        IERC721(title).setApprovalForAll(address(v), true);
        _one(v, coll, a, principal);
        if (request != 0) IRequestExit(shares).requestExit(request);
        _one(v, coll, b, principal);
    }

    /// @dev One week-long refinance of `id`, nothing shed, off `both`'s stack.
    function _one(IRefinanceDoor v, address coll, uint256 id, uint256 principal) private {
        v.refinanceFor(id, coll, principal, 7 days, 0, 0, 0, 0, address(0), "");
    }
}

interface IAceVaultDoorView {
    function ACE() external view returns (address);
}

/// @notice Etched at the vault's address for one read: transient storage stays the address's, whatever code sits there.
contract TransientPeek {
    function peek(bytes32 slot) external view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }
}

interface IRequestExit {
    function requestExit(uint256 shares) external;
}

/// @title AceVaultRefinance
/// @notice The base lending verb `refinanceFor`: the holder hands the vault its title for one call, the vault refinances as holder of record,
/// @notice and both titles and the net payout come home; the exit gate in the policy's form, the room on the net new cash, and the rest bounded.
contract AceVaultRefinanceTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    IAceVaultLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    AceVault internal vault;
    IRefinanceDoor internal rv;
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
        _deploy(UNCAPPED, LP_CASH);
    }

    function _deploy(uint192 total, uint256 lp) internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        terms = new RefiTerms(predicted, address(ace));
        ProductConfig memory pc =
            ProductConfig({terms: address(terms), door: address(0), inKind: false, drainable: true, capTimelock: 3 days, minTenor: 1 days, maxTenor: 30 days});
        CapListing[] memory caps = new CapListing[](2);
        (caps[0], caps[1]) = (CapListing(address(coll), UNCAPPED), CapListing(predicted, total));
        VaultConfig memory cfg = VaultConfig({
            ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: 0, vestWindow: 1 days, seed: VaultSeed.SEED
        });
        VaultSeed.fund(cfg, predicted);
        vault = new AceVault(cfg, pc, caps, "Refi", "rVLT");
        assertEq(address(vault), predicted, "rig: the vault landed off its predicted address");
        rv = IRefinanceDoor(address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        (p.record, p.lender, p.settleBountyBps, p.minTenor, p.maxTenor) = (address(record), predicted, 0, 7 days, 30 days);
        mpA = p;
        p.minPrincipal = 20e6;
        mpB = p;
        terms.setBorrow(mpA, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        terms.setRefinance(mpA, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        if (lp != 0) _lp(alice, lp);
    }

    function _lp(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev A loan to the borrower for `tenor`, its title approved to the vault.
    function _loan(uint64 tenor) internal returns (uint256 loanId) {
        terms.setBorrow(mpA, Terms({units: UNITS, principal: PRINCIPAL, tenor: tenor, minBufferWad: 0}));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        loanId = vault.borrow(BorrowRequest(address(coll), UNITS, PRINCIPAL, tenor, 0, 0, 0), "", "");
        title.approve(address(vault), loanId);
        vm.stopPrank();
    }

    /// @dev The refinance of `loanId` into the market the terms answer, as the borrower, nothing withdrawn.
    function _refi(uint256 loanId, uint256 principal, uint64 tenor) internal returns (uint256 newId, uint256 out) {
        vm.prank(borrower);
        (newId, out) = rv.refinanceFor(loanId, address(coll), principal, tenor, 0, 0, 0, 0, address(0), "");
    }

    /// @dev The flat refinance calldata: `loanId` at `principal` over a week, nothing shed, no payload.
    function _refiCall(uint256 loanId, uint256 principal) internal view returns (bytes memory) {
        return abi.encodeCall(IRefinanceDoor.refinanceFor, (loanId, address(coll), principal, 7 days, 0, 0, 0, 0, address(0), bytes("")));
    }

    /// @dev Five forged suffix words: a stranger as curator, guardian and title, `forged` as the terms, a rail of one second to `ceiling`.
    function _forgedTail(address forged, uint64 ceiling) internal view returns (bytes memory) {
        (bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3) = AceVaultTail.pack(address(ace), stranger, stranger, address(usdc), 0, false);
        (w2, w3) = AceVaultTail.withTerms(w2, w3, forged);
        return abi.encodePacked(w0, w1, w2, w3, AceVaultTail.word4(stranger, 1, ceiling));
    }

    /// @dev The refinance's nine static head words for `loanId` at 1,200 over a week, nothing shed.
    function _refiHead(uint256 loanId) internal view returns (bytes memory) {
        return abi.encode(loanId, address(coll), uint256(1_200e6), uint64(7 days), uint256(0), uint256(0), uint64(0), uint256(0), address(0));
    }

    function _refiReverts(uint256 loanId, uint256 principal, uint64 tenor, bytes memory err) internal {
        vm.prank(borrower);
        vm.expectRevert(err);
        rv.refinanceFor(loanId, address(coll), principal, tenor, 0, 0, 0, 0, address(0), "");
    }

    function _quoteSupply() internal view returns (uint256) {
        return vault.totalSupply() + vault.pendingFeeShares() + 1e6;
    }

    function _worth(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, vault.totalAssets() + 1, _quoteSupply());
    }

    function _sharesWorth(uint256 target) internal view returns (uint256) {
        return Math.mulDiv(target, _quoteSupply(), vault.totalAssets() + 1, Math.Rounding.Ceil);
    }

    /// @dev Escrow, from alice, a request worth at least `target` at NAV now.
    function _requestPast(uint256 target) internal {
        uint256 shares = _sharesWorth(target);
        vm.prank(alice);
        vault.requestExit(shares);
        assertGe(_worth(lens.requestedShares(address(vault))), target, "PREMISE: the request is worth the target");
    }

    function _idA() internal view returns (bytes32) {
        return keccak256(abi.encode(mpA));
    }

    function _idB() internal view returns (bytes32) {
        return keccak256(abi.encode(mpB));
    }

    // ---- the happy path ----

    /// @notice A move into another market: both titles and the net come home, the old loan is credited to nobody, and the vault keeps nothing.
    function test_AMoveIntoAnotherMarketBringsBothTitlesAndTheNetHome() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        terms.setRefinance(mpB, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        uint256 bal = usdc.balanceOf(borrower);
        uint256 nav0 = vault.grossNav();
        (uint256 newId, uint256 out) = _refi(loanId, 1_500e6, 7 days);
        assertEq(ace.loanMarket(newId), _idB(), "the successor sits in the market the product answered");
        assertEq(ace.borrowerOf(newId), borrower, "the holder holds the successor");
        assertEq(title.ownerOf(newId), borrower, "the successor's title came home");
        assertEq(title.ownerOf(loanId), borrower, "and the retired loan's title too");
        assertEq(title.balanceOf(address(vault)), 0, "the vault holds no title");
        assertEq(title.getApproved(loanId), address(0), "no approval outlives the call");
        assertEq(usdc.balanceOf(borrower) - bal, out, "the net came home whole");
        assertGt(out, 0, "PREMISE: a larger principal pays a net out");
        (uint256 u, uint256 q) = ace.owedOf(loanId, address(vault));
        assertEq(u + q, 0, "the retired loan credits the vault nothing");
        assertEq(ace.restingOf(_idA()) + ace.restingOf(_idB()), 0, "nothing rests in either market");
        assertEq(ace.lenderOwed(address(vault), address(usdc)), 0, "and nothing is left owed");
        assertGe(vault.grossNav(), nav0, "the vault lost nothing");
        assertFalse(ace.isLiveLoan(loanId), "the old loan closed");
    }

    /// @notice A same-market refinance reuses the claim on the vault's own policy, and the product sees Refinance before and after.
    function test_ASameMarketRefinanceReusesTheClaim_TheProductSeesBothWriteCalls() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        vm.prank(borrower);
        (uint256 newId,) = rv.refinanceFor(loanId, address(coll), 1_200e6, 7 days, 0, 0, 0, 0, address(0), hex"c0ffee");
        assertEq(ace.loanMarket(newId), _idA(), "the same market");
        assertEq(read.debtOf(newId), 1_200e6, "the new principal");
        RefiTerms.Call[] memory c = terms.calls();
        assertEq(c.length, 4, "a borrow's two write calls, then the refinance's two");
        assertTrue(c[2].kind == Lend.Refinance && c[2].before && c[2].loanId == loanId, "beforeLend sees Refinance and the retiring loan");
        assertEq(c[2].borrowerNow, address(vault), "with the vault holding its title");
        assertTrue(c[3].kind == Lend.Refinance && !c[3].before && c[3].loanId == newId, "afterLend sees Refinance and the successor");
        assertEq(c[3].holder, borrower, "and the holder");
        assertEq(c[3].borrowerNow, borrower, "who already holds the successor's title");
        assertEq(keccak256(c[2].data), keccak256(hex"c0ffee"), "the product's payload reaches its write calls");
    }

    /// @notice The net counts only what `refinanceTo` paid: cash reaching the vault elsewhere in the call stays in the vault.
    function test_TheNetExcludesCashThatReachedTheVaultOutsideTheHubsRefinance() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        terms.setRefinance(mpB, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        uint256 snap = vm.snapshotState();
        (, uint256 want) = _refi(loanId, 1_500e6, 7 days);
        vm.revertToState(snap);
        usdc.mint(address(terms), 77e6);
        terms.setDonation(77e6);
        uint256 bal = usdc.balanceOf(borrower);
        uint256 nav0 = vault.grossNav();
        (, uint256 out) = _refi(loanId, 1_500e6, 7 days);
        assertEq(out, want, "the net is what the same refinance pays with no donation: the hub's alone");
        assertEq(usdc.balanceOf(borrower) - bal, out, "the holder received exactly the net");
        assertGe(vault.grossNav(), nav0 + 77e6, "the donation stayed in the vault");
    }

    /// @notice The rest takes at most the principal, though idle holds far more.
    function test_TheRestTakesAtMostThePrincipal() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        terms.setRefinance(mpB, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        assertGt(vault.idle(), 1_500e6, "PREMISE: idle is over the principal");
        vm.expectCall(address(ace), abi.encodeCall(IAceLenderOps.deposit, (_idB(), 1_500e6)), 1);
        _refi(loanId, 1_500e6, 7 days);
    }

    // ---- the refusals, in order ----

    /// @notice I9: a stranger the holder approved for every title is still refused `NotTheBorrower`: the door acts only for the caller's own loan.
    function test_AStrangerApprovedForEveryTitleIsRefusedNotTheBorrower() public {
        uint256 loanId = _loan(7 days);
        vm.prank(borrower);
        title.setApprovalForAll(stranger, true);
        vm.expectCall(address(title), abi.encodeWithSelector(IERC721.transferFrom.selector), 0); // the refusal comes before the title pull
        vm.prank(stranger);
        vm.expectRevert(IRefinanceDoor.NotTheBorrower.selector);
        rv.refinanceFor(loanId, address(coll), 1_200e6, 7 days, 0, 0, 0, 0, address(0), "");
    }

    /// @notice A loan of another lender's market is not the vault's to refinance: `NotOurLoan`.
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
        uint256 lid = ace.open(other, UNITS, PRINCIPAL, 7 days, borrower, OpenBounds(0, 0, 0));
        title.approve(address(vault), lid);
        vm.stopPrank();
        _refiReverts(lid, 1_200e6, 7 days, abi.encodeWithSelector(IAceVaultDoor.NotOurLoan.selector));
    }

    /// @notice A matured loan refuses `LoanMatured`, ahead of the exit gate, even while requests outweigh idle.
    function test_AMaturedLoanRefusesBeforeTheGate() public {
        uint256 loanId = _loan(7 days);
        _requestPast(vault.idle() + 1);
        _warpTo(read.loan(loanId).expiry);
        _refiReverts(loanId, 1_200e6, 7 days, abi.encodeWithSelector(LoanMatured.selector));
    }

    /// @notice Collateral shed by the refinance never lands on the vault: `WithdrawToVault`.
    function test_AWithdrawToTheVaultRefuses() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        vm.prank(borrower);
        vm.expectRevert(IRefinanceDoor.WithdrawToVault.selector);
        rv.refinanceFor(loanId, address(coll), 1_200e6, 7 days, 0, 0, 0, 1e18, address(vault), "");
    }

    /// @notice The base binds the product's answer to the ask: another collateral, more principal, another term, a term off the rail, another mode.
    function test_TheBindingAndTheRailRefuse() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        MarketParams memory p = mpA;
        p.collateral = address(0xC011);
        terms.setRefinance(p, Terms(UNITS, 1_200e6, 7 days, 0), false);
        _refiReverts(loanId, 1_200e6, 7 days, abi.encodeWithSelector(AceVaultCaps.CollateralNotAsked.selector));
        terms.setRefinance(mpA, Terms(UNITS, 1_200e6 + 1, 7 days, 0), false);
        _refiReverts(loanId, 1_200e6, 7 days, abi.encodeWithSelector(AceVaultCaps.OverAsk.selector));
        terms.setRefinance(mpA, Terms(UNITS, 1_200e6, 8 days, 0), false);
        _refiReverts(loanId, 1_200e6, 7 days, abi.encodeWithSelector(AceVaultCaps.TenorNotAsked.selector));
        p = mpA;
        p.maxTenor = 31 days;
        terms.setRefinance(p, Terms(UNITS, 1_200e6, 7 days, 0), false);
        _refiReverts(loanId, 1_200e6, 7 days, abi.encodeWithSelector(AceVaultCaps.TenorOutOfRail.selector));
        p = mpA;
        p.inventoryAsk = false;
        terms.setRefinance(p, Terms(UNITS, 1_200e6, 7 days, 0), false);
        _refiReverts(loanId, 1_200e6, 7 days, abi.encodeWithSelector(AceVaultCaps.WrongInventoryMode.selector));
        terms.setRefinance(mpA, Terms(UNITS, 1_200e6, 7 days, 0), false);
        (uint256 newId,) = _refi(loanId, 1_200e6, 7 days);
        assertEq(read.debtOf(newId), 1_200e6, "CONTROL: the bound answer lands");
    }

    /// @notice A market naming a third party as its borrower refuses at the hub's gate: the vault is the holder of record for the call.
    function test_AMarketNamingAThirdPartyBorrowerRefuses() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        MarketParams memory p = mpB;
        p.borrower = stranger;
        terms.setRefinance(p, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        _refiReverts(loanId, 1_200e6, 7 days, abi.encodeWithSelector(GateRefused.selector));
    }

    /// @notice The net new cash may not pass lendable, the total's room, the row's room or the product's room.
    function test_TheNetNewCashIsHeldUnderLendableTheTotalTheRowAndTheProduct() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        vault.crank();
        _requestPast(vault.idle() - 100e6);
        assertLt(vault.lendable(), 200e6, "PREMISE: the requests leave under 200 lendable");
        _refiReverts(loanId, PRINCIPAL + 200e6, 7 days, abi.encodeWithSelector(AceVaultFlows.OverLendable.selector));
        (uint256 requested,) = lens.requestOf(address(vault), alice);
        vm.prank(alice);
        vault.cancelExit(requested);
        vm.prank(curator);
        vault.submitCap(address(coll), uint192(PRINCIPAL + 100e6));
        _refiReverts(loanId, PRINCIPAL + 100e6 + 1, 7 days, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        terms.setRoom(50e6);
        _refiReverts(loanId, PRINCIPAL + 51e6, 7 days, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        vm.prank(curator);
        vault.submitCap(address(vault), uint192(PRINCIPAL + 40e6));
        _refiReverts(loanId, PRINCIPAL + 45e6, 7 days, abi.encodeWithSelector(AceVaultCaps.OverTotal.selector));
        (uint256 newId,) = _refi(loanId, PRINCIPAL + 40e6, 7 days);
        assertEq(read.debtOf(newId), PRINCIPAL + 40e6, "CONTROL: inside every room it lands");
    }

    /// @notice A row cut under what is lent refuses any refinance that raises it, and passes one that leaves it where it is.
    function test_UnderACutRowARaiseRefuses_ARefinanceThatRaisesNothingLands() public {
        uint256 loanId = _loan(30 days);
        vm.prank(curator);
        vault.submitCap(address(coll), 1);
        _refiReverts(loanId, PRINCIPAL + 1, 7 days, abi.encodeWithSelector(AceVaultFlows.OverCap.selector));
        (uint256 newId,) = _refi(loanId, PRINCIPAL, 7 days);
        assertEq(read.debtOf(newId), PRINCIPAL, "a re-term that lends nothing new lands under the cut row");
    }

    /// @notice A draining vault refuses `Draining` before anything else.
    function test_ADrainRefuses() public {
        uint256 loanId = _loan(7 days);
        vm.prank(curator);
        vault.setDrain(true);
        _refiReverts(loanId, 1_200e6, 7 days, abi.encodeWithSelector(AceVault.Draining.selector));
    }

    // ---- the exit gate, in the policy's form ----

    /// @notice D1: a lengthening refinance refuses while the exit requests outweigh idle.
    function test_ALengtheningRefinanceRefusesWhileRequestsOutweighIdle() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        _requestPast(vault.idle() + ace.lenderOwed(address(vault), address(usdc)) + 1);
        _refiReverts(loanId, PRINCIPAL, 7 days, abi.encodeWithSelector(IAceVaultDoor.RequestsOutweighIdle.selector));
    }

    /// @notice D1: a refinance ending no later than the old loan lands though requests outweigh idle, as the policy's own reuse lets it.
    function test_ARefinanceEndingNoLaterLandsThoughRequestsOutweighIdle() public {
        uint256 loanId = _loan(30 days);
        _requestPast(vault.idle() + ace.lenderOwed(address(vault), address(usdc)) + 1);
        assertLe(_now() + 7 days, read.loan(loanId).expiry, "PREMISE: the successor ends by the old expiry");
        (uint256 newId,) = _refi(loanId, PRINCIPAL, 7 days);
        assertEq(ace.loanMarket(newId), _idA(), "the same market");
        assertEq(read.loan(newId).tenor, 7 days, "re-termed shorter");
    }

    /// @notice D1's edge: a successor ending exactly at the old expiry lands though requests outweigh idle; one second later refuses.
    /// @dev Over the same week only half the lender's fee refunds, so the old loan is paid down 60% first: the re-term at its debt draws no fresh cash.
    function test_TheGatesEdge_EndingExactlyAtTheOldExpiryLands_OneSecondLaterRefuses() public {
        uint256 loanId = _loan(30 days);
        _warpBy(23 days);
        _payDown(loanId, (PRINCIPAL * 6) / 10);
        _requestPast(vault.idle() + ace.lenderOwed(address(vault), address(usdc)) + 1);
        uint64 left = uint64(read.loan(loanId).expiry - _now());
        assertEq(left, 7 days, "PREMISE: a week is left");
        uint256 debt = read.debtOf(loanId);
        _refiReverts(loanId, debt, left + 1, abi.encodeWithSelector(IAceVaultDoor.RequestsOutweighIdle.selector));
        uint64 expiry = read.loan(loanId).expiry;
        (uint256 newId,) = _refi(loanId, debt, left);
        assertEq(read.loan(newId).expiry, expiry, "the successor ends at the old expiry exactly");
    }

    /// @dev A stranger pays `amount` of `loanId` down at the hub.
    function _payDown(uint256 loanId, uint256 amount) internal {
        usdc.mint(stranger, amount);
        vm.startPrank(stranger);
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
        vm.stopPrank();
    }

    /// @notice The held-request bridge: a covered request's idle funds a move's whole principal for one call, and the request is still covered after.
    function test_AMoveDrawsItsWholePrincipalThroughHeldIdle_TheRequestStaysCovered() public {
        _deploy(UNCAPPED, 0);
        _lp(alice, 2_500e6);
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        vault.crank();
        _requestPast(1_000e6);
        uint256 lendable = vault.lendable();
        assertLt(lendable, 1_300e6, "PREMISE: lendable alone cannot fund the whole new principal");
        assertGe(lendable, 300e6, "PREMISE: but covers the net new cash");
        terms.setRefinance(mpB, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        (uint256 newId,) = _refi(loanId, 1_300e6, 7 days);
        assertEq(ace.loanMarket(newId), _idB(), "PREMISE: another market, drawn whole");
        assertGe(vault.idle(), _worth(lens.requestedShares(address(vault))), "the request is still covered");
        assertEq(ace.restingOf(_idB()), 0, "nothing rests");
    }

    // ---- the collect and the rest ----

    /// @notice D2: the leading sweep collects the hub credit before the rest, so a paydown's credit funds a move's fresh draw.
    function test_TheDoorCollectsTheHubCreditBeforeItRests() public {
        _deploy(UNCAPPED, 0);
        _lp(alice, 3_000e6);
        uint256 loanId = _loan(7 days);
        uint256 other = _loan(7 days);
        uint256 paydown = 500e6;
        usdc.mint(stranger, paydown);
        vm.startPrank(stranger);
        usdc.approve(address(ace), paydown);
        ace.repay(other, paydown);
        vm.stopPrank();
        _warpBy(1 days);
        uint256 newP = 1_300e6;
        assertLt(vault.idle(), newP, "PREMISE: idle alone cannot cover the whole draw");
        assertGe(vault.idle() + ace.lenderOwed(address(vault), address(usdc)), newP, "PREMISE: idle and the uncollected credit cover the draw");
        terms.setRefinance(mpB, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        (uint256 newId,) = _refi(loanId, newP, 7 days);
        assertEq(read.debtOf(newId), newP, "landed on the collected credit");
    }

    /// @notice D3: idle under the destination's smallest lot rests nothing, and a re-term drawing no fresh cash still lands on the reused claim.
    function test_ThinIdleRestsNothing_AReTermDrawingNoFreshCashLands() public {
        _deploy(UNCAPPED, 0);
        _lp(alice, PRINCIPAL + 1e6);
        uint256 loanId = _loan(30 days);
        vault.crank();
        assertLt(vault.idle(), mpA.minPrincipal, "PREMISE: idle is under a lot");
        vm.expectCall(address(ace), abi.encodeWithSelector(IAceLenderOps.deposit.selector), 0);
        (uint256 newId,) = _refi(loanId, PRINCIPAL, 7 days);
        assertEq(ace.loanMarket(newId), _idA(), "the same market");
        assertEq(read.loan(newId).tenor, 7 days, "re-termed");
    }

    /// @notice C11: a re-term that nets exactly nothing sends the holder no zero transfer, as the hub sends the vault none.
    function test_ANetOfNothingSendsNoTransfer() public {
        uint256 loanId = _loan(30 days);
        uint256 p = _principalNettingNothing(loanId);
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.transfer, (borrower, 0)), 0);
        (, uint256 out) = _refi(loanId, p, 7 days);
        assertEq(out, 0, "PREMISE: the re-term netted exactly nothing");
    }

    /// @dev The week-long re-term principal whose net is zero: the net at the old principal, measured and undone, moves by `p - fee(p)`.
    function _principalNettingNothing(uint256 loanId) internal returns (uint256 p) {
        uint256 snap = vm.snapshotState();
        (, uint256 out0) = _refi(loanId, PRINCIPAL, 7 days);
        vm.revertToState(snap);
        uint256 fee0 = LoanMath.originationFee(PRINCIPAL, 7 days, mpA.lenderAprBps);
        uint256 guess = Math.mulDiv(PRINCIPAL - fee0 - out0, PRINCIPAL, PRINCIPAL - fee0);
        for (p = guess - 100; p < guess + 100; ++p) {
            if (out0 + p + fee0 == PRINCIPAL + LoanMath.originationFee(p, 7 days, mpA.lenderAprBps)) return p;
        }
        revert("no principal nets exactly nothing");
    }

    /// @notice C1: with the record under the market's price the hub takes no resting cash, so the rest is skipped and a re-term on the reused claim lands.
    function test_AReTermWithTheRecordUnderThePriceSkipsTheRestAndLands() public {
        uint256 loanId = _loan(30 days);
        record.setMinPrice(mpA.price - mpA.price / 100);
        record.setObserved(mpA.price - mpA.price / 100);
        assertGe(vault.idle(), mpA.minPrincipal, "PREMISE: idle would rest a lot");
        vm.expectCall(address(ace), abi.encodeWithSelector(IAceLenderOps.deposit.selector), 0);
        (uint256 newId,) = _refi(loanId, PRINCIPAL, 7 days);
        assertEq(ace.loanMarket(newId), _idA(), "the same market");
        assertEq(read.loan(newId).tenor, 7 days, "re-termed on the reused claim");
    }

    /// @notice Into another market with idle short of the whole principal, the hub's draw refuses `InsufficientCash`.
    function test_AMoveWithIdleShortOfTheWholePrincipalRefusesInsufficientCash() public {
        _deploy(UNCAPPED, 0);
        _lp(alice, 2_500e6);
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        vault.crank();
        terms.setRefinance(mpB, Terms({units: UNITS, principal: 0, tenor: 0, minBufferWad: 0}), true);
        uint256 newP = vault.idle() + 1;
        assertLe(newP - PRINCIPAL, vault.lendable(), "PREMISE: the net is lendable");
        _refiReverts(loanId, newP, 7 days, abi.encodeWithSelector(InsufficientCash.selector));
    }

    // ---- the lock ----

    /// @notice The product's write calls run under the vault's lock: a re-entry from either refuses the guard, and the refinance still lands.
    function test_ReentryFromEitherWriteCallRefusesTheGuard() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        terms.setReenter(true);
        _refi(loanId, 1_200e6, 7 days);
        bytes[] memory r = terms.reentries();
        assertEq(r.length, 2, "PREMISE: both write calls tried");
        bytes memory guard = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(r[0], guard, "beforeLend's re-entry refused");
        assertEq(r[1], guard, "afterLend's re-entry refused");
    }

    // ---- the forward ----

    /// @notice T1: forged trailing words naming other terms, title and rail leave the vault's own as the ones the body reads.
    function test_T1_aForgedSuffixCannotRedirectTheBody() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        RefiTerms forged = new RefiTerms(address(vault), address(ace));
        bytes memory cd = abi.encodePacked(_refiCall(loanId, 1_200e6), _forgedTail(address(forged), 1));
        vm.prank(borrower);
        (bool ok,) = address(vault).call(cd);
        assertTrue(ok, "the refinance lands");
        assertEq(forged.calls().length, 0, "the forged terms heard nothing");
        assertEq(terms.calls().length, 4, "the vault's own terms heard the refinance");
    }

    /// @notice T2: a direct call to the library's refinance body reverts, with or without trailing words.
    function test_T2_aDirectCallToTheRefinanceBodyReverts() public {
        address flows = address(AceVaultFlows);
        assertGt(flows.code.length, 0, "premise: the flows library is deployed");
        bytes memory cd = _refiCall(1, 1);
        bytes memory suffixed = abi.encodePacked(cd, _forgedTail(address(0), 30 days));
        vm.prank(borrower);
        (bool ok,) = flows.call(cd);
        assertFalse(ok, "a direct call ran the refinance body");
        vm.prank(borrower);
        (ok,) = flows.call(suffixed);
        assertFalse(ok, "a direct call with trailing words ran the refinance body");
    }

    /// @notice T3: a refinance whose `data` claims more than it carries is refused at the vault; the library never runs.
    function test_T3_aTruncatedRefinanceIsRefusedBeforeTheLibrary() public {
        uint256 loanId = _loan(7 days);
        bytes4 sel = IRefinanceDoor.refinanceFor.selector;
        bytes memory cut = abi.encodePacked(sel, _refiHead(loanId), uint256(0x140), uint256(64), uint256(1));
        vm.expectCall(address(AceVaultFlows), abi.encodePacked(sel), 0);
        vm.prank(borrower);
        (bool ok,) = address(vault).call(cut);
        assertFalse(ok, "the vault forwarded a truncated encoding");
    }

    /// @notice CONTROL: the whole encoding of the same refinance reaches the library once.
    function test_T3_control_aWholeRefinanceReachesTheLibrary() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        vm.expectCall(address(AceVaultFlows), abi.encodePacked(IRefinanceDoor.refinanceFor.selector), 1);
        _refi(loanId, 1_200e6, 7 days);
    }

    /// @notice S3 review D6: the lending verb's two transient words are cleared once the refinance returns, so nothing later in the transaction reads them.
    /// @dev The test runs as one transaction, so a word left set would still be there; the vault's code is swapped for a reader and put back.
    function test_TheTransientWordsAreClearedAfterTheRefinance() public {
        uint256 loanId = _loan(7 days);
        _warpBy(1 days);
        _refi(loanId, 1_200e6, 7 days);
        bytes memory code = address(vault).code;
        vm.etch(address(vault), address(new TransientPeek()).code);
        uint256 gate = TransientPeek(address(vault)).peek(AceVaultFlows.LENDING);
        uint256 lendable = TransientPeek(address(vault)).peek(bytes32(uint256(AceVaultFlows.LENDING) + 1));
        vm.etch(address(vault), code);
        assertEq(gate, 0, "the gate word is cleared");
        assertEq(lendable, 0, "and the lendable word");
        assertGt(vault.lendable(), 0, "PREMISE: the words would have been set: lendable and the gate were open");
    }

    /// @notice The transient words are the vault's per call: a second refinance in the same transaction refuses once a request lands between.
    function test_TwoRefinancesInOneTransactionReadTheirOwnWords() public {
        uint256 a = _loan(7 days);
        uint256 b = _loan(7 days);
        _warpBy(1 days);
        TwoRefinances helper = new TwoRefinances();
        vm.startPrank(borrower);
        title.transferFrom(borrower, address(helper), a);
        title.transferFrom(borrower, address(helper), b);
        vm.stopPrank();
        uint256 shares = _sharesWorth(vault.idle() + 1_000e6);
        vm.prank(alice);
        vault.transfer(address(helper), shares);
        vm.expectRevert(IAceVaultDoor.RequestsOutweighIdle.selector);
        helper.both(rv, address(coll), a, b, 1_100e6, address(vault), shares);
        helper.both(rv, address(coll), a, b, 1_100e6, address(vault), 0);
        assertFalse(ace.isLiveLoan(a) || ace.isLiveLoan(b), "CONTROL: with no request between them both land");
        assertEq(title.balanceOf(address(helper)), 4, "and every title came home to the helper");
    }
}
