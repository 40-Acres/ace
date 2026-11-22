// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WarpClock} from "../../utils/WarpClock.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceReader} from "../../utils/AceReader.sol";
import {AllInFeeSpec} from "../../utils/AllInFeeSpec.sol";
import {IAceVaultLens, VaultLens} from "../../utils/VaultLens.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {Ace} from "../../../src/ace/hub/Ace.sol";
import {LoanMatured, PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams, OpenBounds} from "../../../src/ace/hub/Types.sol";
import {PositionManager} from "../../../src/ace/positions/PositionManager.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {CapListing, ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {AceVaultFlows, BorrowRequest, Terms, VaultConfig} from "../../../src/curator/AceVaultFlows.sol";
import {AceVaultTail} from "../../../src/curator/AceVaultTail.sol";
import {HubLoanTerm} from "../../../src/interfaces/HubLoanTerm.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {Extension} from "../../../src/interfaces/IRollPolicy.sol";
import {IVaultTerms, Lend, RefinanceRequest} from "../../../src/interfaces/IVaultTerms.sol";

/// @notice A product that answers a fixed market and records every write call: its kind, loan, holder and the loan's expiry as it stood.
contract RecordingTerms is IVaultTerms {
    struct Call {
        Lend kind;
        uint256 loanId;
        address holder;
        uint64 expiry;
        bool before;
        bytes data;
    }

    address public immutable VAULT;
    address public immutable ACE;
    MarketParams internal _mp;
    Terms internal _t;
    bool public consent = true;
    Call[] internal _calls;

    constructor(address vault, address ace) {
        (VAULT, ACE) = (vault, ace);
    }

    function setTerms(MarketParams calldata mp, Terms calldata t) external {
        (_mp, _t) = (mp, t);
    }

    function setConsent(bool yes) external {
        consent = yes;
    }

    function calls() external view returns (Call[] memory) {
        return _calls;
    }

    function borrowTerms(address, BorrowRequest calldata, bytes calldata) external view returns (MarketParams memory, Terms memory) {
        return (_mp, _t);
    }

    function refinanceTerms(address, uint256, RefinanceRequest calldata, bytes calldata) external view returns (MarketParams memory, Terms memory) {
        return (_mp, _t);
    }

    function admitsExtension(Extension calldata, bytes calldata) external view returns (bool) {
        return consent;
    }

    function room(MarketParams calldata) external pure returns (uint256) {
        return type(uint256).max;
    }

    function entryCap(address, uint256) external pure returns (uint256) {
        return type(uint256).max;
    }

    function beforeLend(Lend kind, MarketParams calldata, uint256 loanId, bytes calldata data) external {
        _calls.push(Call(kind, loanId, address(0), _expiryOf(loanId), true, data));
    }

    function afterLend(Lend kind, MarketParams calldata, uint256 loanId, address holder, bytes calldata data) external {
        _calls.push(Call(kind, loanId, holder, _expiryOf(loanId), false, data));
    }

    function _expiryOf(uint256 loanId) private view returns (uint64 expiry) {
        if (loanId == 0) return 0;
        (,, expiry) = HubLoanTerm.decode(Ace(ACE).extsload(HubLoanTerm.slot(loanId)));
    }
}

/// @notice Calls `extendFor` twice in one transaction, so the two lending doors share every transient slot the vault might leave set.
contract TwoDoors {
    function both(IAceVaultDoor v, uint256 first, uint256 second, uint256 fee1, uint256 fee2, address shares, uint256 request) external {
        IERC20(IERC20Asset(address(v)).asset()).approve(address(v), fee1 + fee2);
        v.extendFor(first, fee1, 0, "", "");
        IRequest(shares).requestExit(request);
        v.extendFor(second, fee2, 0, "", "");
    }
}

interface IERC20Asset {
    function asset() external view returns (address);
}

interface IRequest {
    function requestExit(uint256 shares) external;
}

/// @title AceVaultExtendFor
/// @notice The base lending door `extendFor`: the holder extends a loan of the vault's in place, the fee priced on the hub's own term word
/// @notice and pulled before the product's write calls, the exit gate read before the pull, and the vault left with no allowance and nothing owed.
contract AceVaultExtendForTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    IAceVaultLens internal lens;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    AceVault internal vault;
    IAceVaultDoor internal dv;
    RecordingTerms internal terms;

    address internal curator = address(0xC0A11);
    address internal guardian = address(0x6A2E);
    address internal alice = address(0xA11CE);
    uint256 internal borrowerKey = 0xB0BA5;
    address internal borrower;
    address internal stranger = address(0x5EE);
    address internal competitor = address(0xC0FF);

    uint64 internal constant TENOR = 7 days;
    uint256 internal constant LP_CASH = 1_000_000e6;
    uint256 internal constant UNITS = 2_000e18;
    uint256 internal constant PRINCIPAL = 1_000e6;
    uint192 internal constant UNCAPPED = type(uint192).max;

    function setUp() public {
        _warpTo(1_000_000);
        borrower = vm.addr(borrowerKey);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = VaultLens.deploy();
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));
        record.setObserved(AceFixtures.px(2e18, address(usdc), address(coll)));
        (vault, terms) = _deploy(UNCAPPED);
        dv = IAceVaultDoor(address(vault));
        _lp(alice, LP_CASH);
    }

    function _deploy(uint192 total) internal returns (AceVault v, RecordingTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new RecordingTerms(predicted, address(ace));
        ProductConfig memory pc =
            ProductConfig({terms: address(t), door: address(0), inKind: false, drainable: true, capTimelock: 3 days, minTenor: 1 days, maxTenor: 30 days});
        CapListing[] memory caps = new CapListing[](2);
        (caps[0], caps[1]) = (CapListing(address(coll), UNCAPPED), CapListing(predicted, total));
        VaultConfig memory cfg = VaultConfig({
            ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: 0, vestWindow: 1 days, seed: VaultSeed.SEED
        });
        VaultSeed.fund(cfg, predicted);
        v = new AceVault(cfg, pc, caps, "Ext", "eVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        (p.record, p.lender, p.settleBountyBps, p.minTenor, p.maxTenor) = (address(record), predicted, 0, TENOR, TENOR);
        t.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
    }

    function _lp(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev A loan to the borrower, a day old so an extension adds time, with the vault approved as its title operator.
    function _loan() internal returns (uint256 loanId) {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        loanId = vault.borrow(BorrowRequest(address(coll), UNITS, PRINCIPAL, 0, 0, 0, 0), "", "");
        IERC721Like(ace.POSITION_TITLE()).setApprovalForAll(address(vault), true);
        vm.stopPrank();
        _warpBy(1 days);
    }

    function _fee(uint256 loanId) internal view returns (uint256) {
        MarketParams memory mp = ace.idToMarketParams(ace.loanMarket(loanId));
        Loan memory l = read.loan(loanId);
        return LoanMath.originationFee(read.debtOf(loanId), uint64(_now()) + l.tenor - l.expiry, mp.lenderAprBps);
    }

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(vault), amt);
    }

    function _extend(address who, uint256 loanId) internal returns (uint256) {
        uint256 fee = _fee(loanId);
        _fund(who, fee);
        vm.prank(who);
        return dv.extendFor(loanId, fee, 0, "", "");
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

    // ---- the happy path ----

    /// @notice The holder extends in place: the fee is the hub's, the product sees Extend before and after, and nothing is left behind.
    function test_AHolderExtendsInPlace() public {
        uint256 loanId = _loan();
        uint64 oldExpiry = read.loan(loanId).expiry;
        uint64 added = uint64(_now() + TENOR - oldExpiry);
        uint256 fee = _fee(loanId);
        _fund(borrower, fee);
        uint256 bal = usdc.balanceOf(borrower);
        vm.expectEmit(address(vault));
        emit IAceVaultDoor.Renewed(loanId, borrower, added, fee);
        vm.prank(borrower);
        uint256 paid = dv.extendFor(loanId, fee, 0, hex"c0ffee", "");
        assertEq(paid, fee, "it answers the hub's fee");
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "the loan runs its tenor again from now");
        assertTrue(ace.isLiveLoan(loanId), "in place, under the same id");
        assertEq(bal - usdc.balanceOf(borrower), fee, "the holder paid the fee");
        assertEq(usdc.allowance(address(vault), address(ace)), 0, "no allowance to the hub outlives the door");
        assertEq(ace.lenderOwed(address(vault), address(usdc)), 0, "the trailing sweep left nothing owed");
        RecordingTerms.Call[] memory c = terms.calls();
        assertEq(c.length, 4, "a borrow's two write calls, then the extension's two");
        assertTrue(c[2].kind == Lend.Extend && c[2].before && c[2].loanId == loanId, "beforeLend sees Extend and the loan");
        assertEq(c[2].expiry, oldExpiry, "before the hub's extend");
        assertTrue(c[3].kind == Lend.Extend && !c[3].before && c[3].loanId == loanId, "afterLend sees Extend and the loan");
        assertEq(c[3].holder, borrower, "and the holder");
        assertEq(c[3].expiry, _now() + TENOR, "after the hub's extend");
        assertEq(keccak256(c[2].data), keccak256(hex"c0ffee"), "the product's payload reaches its write calls");
    }

    /// @notice The door prices the hub's LIVE origination share: once the treasury moves it, a renewal still charges exactly the hub's fee.
    /// @dev A door pricing the ceiling would quote over the hub's charge here and refuse `FeeMismatch`.
    function test_TheDoorPricesTheHubsLiveShare() public {
        uint256[2] memory shares = [uint256(0), 500];
        for (uint256 i; i < shares.length; ++i) {
            uint256 loanId = _loan();
            vm.prank(AceFixtures.TREASURY);
            ace.setProtocolShareBps(shares[i]);
            MarketParams memory mp = ace.idToMarketParams(ace.loanMarket(loanId));
            Loan memory l = read.loan(loanId);
            uint256 fee = AllInFeeSpec.feeAllIn(read.debtOf(loanId), uint64(_now()) + l.tenor - l.expiry, mp.lenderAprBps, shares[i]);
            _fund(borrower, fee);
            vm.prank(borrower);
            assertEq(dv.extendFor(loanId, fee, 0, "", ""), fee, "the door charges the hub's fee at the live share");
        }
    }

    // ---- the refusals, in order ----

    /// @notice A stranger is refused `NotTheBorrower`, and so is a stranger spending a holder's standing title approval.
    function test_AStrangerIsRefusedEvenWhileTheHoldersGrantStands() public {
        uint256 loanId = _loan();
        assertTrue(IERC721Like(ace.POSITION_TITLE()).isApprovedForAll(borrower, address(vault)), "PREMISE: the holder's approval of the vault stands");
        _fund(stranger, _fee(loanId));
        vm.expectCall(address(ace), abi.encodeWithSelector(ace.extend.selector), 0); // the refusal comes before the hub's extend
        vm.prank(stranger);
        vm.expectRevert(IAceVaultDoor.NotTheBorrower.selector);
        dv.extendFor(loanId, type(uint256).max, 0, "", "");
    }

    /// @notice A loan of another lender's market is not the vault's to extend: `NotOurLoan`.
    function test_ALoanOfAnotherLenderIsNotOurs() public {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        (p.record, p.lender) = (address(record), competitor);
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
        vm.stopPrank();
        _warpBy(1 days);
        _fund(borrower, PRINCIPAL);
        vm.prank(borrower);
        vm.expectRevert(IAceVaultDoor.NotOurLoan.selector);
        dv.extendFor(lid, type(uint256).max, 0, "", "");
    }

    /// @notice A matured loan refuses `LoanMatured`, ahead of the exit gate, even while requests outweigh idle.
    function test_AMaturedLoanRefusesBeforeTheGate() public {
        uint256 loanId = _loan();
        _requestPast(vault.idle() + ace.lenderOwed(address(vault), address(usdc)) + 1);
        _warpTo(read.loan(loanId).expiry);
        _fund(borrower, PRINCIPAL);
        vm.prank(borrower);
        vm.expectRevert(LoanMatured.selector);
        dv.extendFor(loanId, type(uint256).max, 0, "", "");
    }

    /// @notice The exit gate refuses before the pull: a holder with no allowance at all reads `RequestsOutweighIdle`.
    function test_TheGateRefusesBeforeThePull() public {
        uint256 loanId = _loan();
        _requestPast(vault.idle() + ace.lenderOwed(address(vault), address(usdc)) + 1);
        assertEq(usdc.allowance(borrower, address(vault)), 0, "PREMISE: no allowance to pull on");
        vm.prank(borrower);
        vm.expectRevert(IAceVaultDoor.RequestsOutweighIdle.selector);
        dv.extendFor(loanId, type(uint256).max, 0, "", "");
    }

    /// @notice A fee over the holder's maximum refuses `FeeOverMax`; at the maximum it lands.
    function test_AFeeOverTheMaxRefuses() public {
        uint256 loanId = _loan();
        uint256 fee = _fee(loanId);
        _fund(borrower, fee);
        vm.prank(borrower);
        vm.expectRevert(IAceVaultDoor.FeeOverMax.selector);
        dv.extendFor(loanId, fee - 1, 0, "", "");
        vm.prank(borrower);
        dv.extendFor(loanId, fee, 0, "", "");
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "CONTROL: at the maximum it lands");
    }

    /// @notice A fee that arrives short refuses `FeePaidShort`.
    function test_AShortFeeRefuses() public {
        uint256 loanId = _loan();
        uint256 fee = _fee(loanId);
        _fund(borrower, fee);
        vm.mockCall(address(usdc), abi.encodeWithSelector(IERC20.transferFrom.selector, borrower, address(vault), fee), abi.encode(true));
        vm.prank(borrower);
        vm.expectRevert(IAceVaultDoor.FeePaidShort.selector);
        dv.extendFor(loanId, fee, 0, "", "");
    }

    /// @notice A hub that charged other than the fee priced refuses `FeeMismatch`.
    function test_AHubChargingOtherThanQuotedRefuses() public {
        uint256 loanId = _loan();
        uint256 fee = _fee(loanId);
        _fund(borrower, fee);
        vm.mockCall(address(ace), abi.encodeWithSelector(Ace.extend.selector), abi.encode(fee + 1));
        vm.prank(borrower);
        vm.expectRevert(IAceVaultDoor.FeeMismatch.selector);
        dv.extendFor(loanId, fee, 0, "", "");
    }

    // ---- the gate ----

    /// @notice The fee in flight never covers the requests: the gate is read before the pull.
    function test_TheFeeInFlightNeverCoversTheRequests() public {
        uint256 loanId = _loan();
        uint256 fee = _fee(loanId);
        uint256 seen = vault.idle() + ace.lenderOwed(address(vault), address(usdc));
        _requestPast(seen + 1);
        assertLe(_worth(lens.requestedShares(address(vault))), seen + fee, "PREMISE: the fee in flight would cover them");
        _fund(borrower, fee);
        vm.prank(borrower);
        vm.expectRevert(IAceVaultDoor.RequestsOutweighIdle.selector);
        dv.extendFor(loanId, fee, 0, "", "");
    }

    /// @notice A paydown counts at once: the door's leading sweep collects the hub credit before the gate is read.
    function test_APaydownCountsThroughTheSweep() public {
        uint256 loanId = _loan();
        uint256 other = _loan();
        uint256 shortfall = 50e6;
        _requestPast(vault.idle() + ace.lenderOwed(address(vault), address(usdc)) + shortfall / 2);
        usdc.mint(borrower, shortfall);
        vm.startPrank(borrower);
        usdc.approve(address(ace), shortfall);
        ace.repay(other, shortfall);
        vm.stopPrank();
        assertGt(_worth(lens.requestedShares(address(vault))), vault.idle(), "PREMISE: idle alone does not cover the requests");
        _extend(borrower, loanId);
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "the sweep collected the paydown before the gate, and the extension landed");
    }

    /// @notice Two lending doors in one transaction each read their own gate: the second refuses once a request lands between them.
    function test_TwoDoorsInOneTransactionReadTheirOwnWords() public {
        uint256 a = _loan();
        uint256 b = _loan();
        TwoDoors helper = new TwoDoors();
        vm.startPrank(borrower);
        IERC721Like(ace.POSITION_TITLE()).transferFrom(borrower, address(helper), a);
        IERC721Like(ace.POSITION_TITLE()).transferFrom(borrower, address(helper), b);
        vm.stopPrank();
        address title = ace.POSITION_TITLE();
        vm.prank(address(helper));
        IERC721Like(title).setApprovalForAll(address(vault), true);
        uint256 feeA = _fee(a);
        uint256 feeB = 2 * _fee(b);
        usdc.mint(address(helper), feeA + feeB);
        uint256 shares = _sharesWorth(vault.idle() + 1_000e6);
        vm.prank(alice);
        vault.transfer(address(helper), shares);
        vm.expectRevert(IAceVaultDoor.RequestsOutweighIdle.selector);
        helper.both(dv, a, b, feeA, feeB, address(vault), shares);
        helper.both(dv, a, b, feeA, feeB, address(vault), 0);
        assertEq(read.loan(b).expiry, _now() + TENOR, "CONTROL: with no request between them both land");
    }

    // ---- the policy and the drain ----

    /// @notice A zero total and a zero row each refuse the vault's own policy at the hub: `PolicyRefused`.
    function test_AZeroTotalOrRowRefusesThePolicy() public {
        uint256 loanId = _loan();
        uint256 fee = _fee(loanId);
        _fund(borrower, 2 * fee);
        vm.prank(curator);
        vault.submitCap(address(vault), 0);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        dv.extendFor(loanId, fee, 0, "", "");
        (AceVault v2, RecordingTerms t2) = _deploy(UNCAPPED);
        (vault, terms, dv) = (v2, t2, IAceVaultDoor(address(v2)));
        _lp(alice, LP_CASH);
        uint256 id2 = _loan();
        vm.prank(curator);
        vault.submitCap(address(coll), 0);
        uint256 fee2 = _fee(id2);
        _fund(borrower, fee2);
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        dv.extendFor(id2, fee2, 0, "", "");
    }

    /// @notice A draining vault refuses `Draining` before anything else.
    function test_ADrainRefuses() public {
        uint256 loanId = _loan();
        vm.prank(curator);
        vault.setDrain(true);
        vm.prank(stranger);
        vm.expectRevert(AceVault.Draining.selector);
        dv.extendFor(loanId, type(uint256).max, 0, "", "");
    }

    // ---- the forward ----

    /// @notice T1: forged trailing words naming another product leave the vault's own TERMS as the one its write calls reach.
    function test_T1_aForgedTermsCannotRedirectTheWriteCalls() public {
        uint256 loanId = _loan();
        RecordingTerms forgedTerms = new RecordingTerms(address(vault), address(ace));
        (bytes32 w0, bytes32 w1, bytes32 w2, bytes32 w3) = AceVaultTail.pack(address(ace), stranger, stranger, address(usdc), 0, false);
        (w2, w3) = AceVaultTail.withTerms(w2, w3, address(forgedTerms));
        uint256 fee = _fee(loanId);
        _fund(borrower, fee);
        bytes memory cd = abi.encodeCall(IAceVaultDoor.extendFor, (loanId, fee, 0, bytes(""), bytes("")));
        vm.prank(borrower);
        (bool ok,) = address(vault).call(abi.encodePacked(cd, w0, w1, w2, w3));
        assertTrue(ok, "the extension lands");
        assertEq(forgedTerms.calls().length, 0, "the forged terms heard nothing");
        assertEq(terms.calls().length, 4, "the vault's own terms heard the extension");
    }

    /// @notice T3: an `extendFor` whose `bytes` claims more than it carries is refused at the vault; the library never runs.
    function test_T3_aTruncatedExtendForIsRefusedBeforeTheLibrary() public {
        uint256 loanId = _loan();
        bytes4 sel = IAceVaultDoor.extendFor.selector;
        bytes memory cut = abi.encodePacked(sel, abi.encode(loanId, type(uint256).max, uint256(0), uint256(0xa0), uint256(0xc0)), uint256(64), uint256(1));
        vm.expectCall(address(AceVaultFlows), abi.encodePacked(sel), 0);
        vm.prank(borrower);
        (bool ok,) = address(vault).call(cut);
        assertFalse(ok, "the vault forwarded a truncated encoding");
    }

    /// @notice CONTROL: the whole encoding of the same extension reaches the library once.
    function test_T3_control_aWholeExtendForReachesTheLibrary() public {
        uint256 loanId = _loan();
        uint256 fee = _fee(loanId);
        _fund(borrower, fee);
        vm.expectCall(address(AceVaultFlows), abi.encodePacked(IAceVaultDoor.extendFor.selector), 1);
        vm.prank(borrower);
        dv.extendFor(loanId, fee, 0, "", "");
    }

    /// @dev Escrow, from alice, a request worth at least `target` at NAV now.
    function _requestPast(uint256 target) internal {
        uint256 shares = _sharesWorth(target);
        vm.prank(alice);
        vault.requestExit(shares);
        assertGe(_worth(lens.requestedShares(address(vault))), target, "PREMISE: the request is worth the target");
    }
}

interface IERC721Like {
    function transferFrom(address from, address to, uint256 id) external;
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}
