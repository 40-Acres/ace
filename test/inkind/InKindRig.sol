// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {InKindVaults} from "../utils/InKindVaults.sol";
import {VaultSeed} from "../utils/VaultSeed.sol";
import {VaultLens} from "../utils/VaultLens.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {BorrowRequest, VaultConfig} from "../../src/curator/libraries/AceVaultFlows.sol";
import {IAceVaultLens, IInKindTerms, IInKindVault, InKindConfig, Listing, Quote, RollQuote, Row} from "./InKindSurface.sol";
import {SafeLikeHandler, SafeLikeProxy, SafeLikeSingleton} from "./InKindMocks.sol";

/// @notice The shared rig for the in-kind suites: one hub, USDC as the asset, two listed tokens, one appraiser key, an in-kind AceVault and its InKindTerms.
/// @dev Every loan is recordless and opens through the vault's door on a signed quote; the rig never creates a vault market itself.
/// @dev THE ONE DEPLOY POINT is `_deploy`: every suite builds its pair there, and `terms` follows the vault it last built.
/// @dev The tracker's views and the vault's stored figures are read through one `AceVaultLens`; the total is uncapped unless a suite sizes `total` first.
abstract contract InKindRig is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockERC20 internal tokA;
    MockERC20 internal tokB;
    IInKindVault internal vault;
    IInKindTerms internal terms;
    IAceVaultLens internal lens;

    uint256 internal constant APPRAISER_KEY = 0xA99A15E4;
    uint256 internal constant ROGUE_KEY = 0xBAD5161;
    address internal appraiser;
    address internal curator = address(0xC0A11);
    address internal guardian = address(0x6A2E);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);
    address internal dave = address(0xDA7E);
    address internal borrower = address(0xB0BA);
    address internal keeper = address(0xCAFE);
    address internal stranger = address(0x5EE);

    uint256 internal constant MIN_PRINCIPAL = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint64 internal constant TIMELOCK = 3 days;
    uint64 internal constant MIN_TENOR = 7 days; // the vault's minimum term
    uint64 internal constant MAX_TENOR = 30 days;
    uint16 internal constant RATE_BPS = 40;
    uint64 internal constant ROW_MAX_TENOR = 14 days;
    uint192 internal constant CAP = 500_000e6;
    uint64 internal constant VEST_W = 1 days;
    uint256 internal constant LP_CASH = 1_000_000e6;
    uint256 internal constant PRINCIPAL = 1_000e6;
    uint256 internal constant UNITS = 4_000e18; // at 0.5 USDC a unit and k = 1.4 the line is about 2,800 units, so a default leaves the borrower some
    uint256 internal constant T0 = 1_000_800; // the rig's start, an hour boundary
    bytes32 internal constant INKIND_ROOT = 0xd7a5145a3d83b645b4f9f0f6fce92a69c8eed8dbba6d917e62a7d17852ce5100; // erc7201:ace.inkind
    string internal constant NAME = "ACE In-Kind Vault";
    string internal constant SYMBOL = "aceIK";

    uint256 internal PRICE; // half a USDC a unit, in the hub's frame: the price the rig's appraiser signs
    uint256 internal _nonce; // the last quote nonce handed out
    uint256 internal _blk; // the test's block clock, kept in storage for the reason WarpClock keeps time there
    uint192 internal total = InKindVaults.UNCAPPED; // the vault-wide total the next `_deploy` lists

    function setUp() public virtual {
        _warpTo(T0);
        _blk = block.number;
        appraiser = vm.addr(APPRAISER_KEY);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        tokA = new MockERC20("Token A", "TKA", 18);
        tokB = new MockERC20("Token B", "TKB", 18);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        PRICE = AceFixtures.px(0.5e18, address(usdc), address(tokA));
        lens = VaultLens.deploy();
        vault = _deploy(_cfg(0), _ik(), _listings());
        vm.label(address(vault), "AceVault");
        vm.label(address(tokA), "tokA");
        vm.label(address(tokB), "tokB");
    }

    // ---- deploy ----

    /// @dev THE ONE DEPLOY POINT: every suite's pair is built here and nowhere else; `terms` is left naming the new vault's.
    function _deploy(VaultConfig memory cfg, InKindConfig memory ik, Listing[] memory l) internal returns (IInKindVault v) {
        v = IInKindVault(address(InKindVaults.deploy(cfg, ik, l, total, NAME, SYMBOL)));
        terms = IInKindTerms(v.TERMS());
        vm.label(address(terms), "InKindTerms");
    }

    /// @dev `_deploy` as an external call of this suite's own, so an expectation armed before it catches either constructor's refusal.
    function deployExternal(VaultConfig memory cfg, InKindConfig memory ik, Listing[] memory l) external returns (IInKindVault) {
        return _deploy(cfg, ik, l);
    }

    /// @dev Expect the pair's deploy to refuse with `err`, from whichever constructor names it.
    function _deployExpecting(bytes4 err, InKindConfig memory ik, Listing[] memory l) internal {
        VaultConfig memory c = _cfg(0);
        vm.expectRevert(err);
        this.deployExternal(c, ik, l);
    }

    /// @dev The terms a vault names.
    function _termsOf(IInKindVault v) internal view returns (IInKindTerms) {
        return IInKindTerms(v.TERMS());
    }

    function _cfg(uint16 perfFeeBps) internal view returns (VaultConfig memory) {
        return VaultConfig({
            ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: perfFeeBps, vestWindow: VEST_W, seed: VaultSeed.SEED
        });
    }

    function _ik() internal view returns (InKindConfig memory) {
        return
            InKindConfig({
                appraiser: appraiser, minPrincipal: MIN_PRINCIPAL, coverageWad: COVERAGE, timelock: TIMELOCK, minTenor: MIN_TENOR, maxTenor: MAX_TENOR
            });
    }

    /// @dev The rig's row: its rate and tenors, and a largest loan of the rig's whole cap.
    function _row() internal pure returns (Row memory) {
        return Row({lenderAprBps: RATE_BPS, minTenor: MIN_TENOR, maxTenor: ROW_MAX_TENOR, maxPrincipal: uint128(CAP)});
    }

    /// @dev `coll` listed on the rig's row at `cap`.
    function _listing(address coll, uint192 cap) internal pure returns (Listing memory) {
        return Listing({collateral: coll, row: _row(), cap: cap});
    }

    function _listings() internal view returns (Listing[] memory l) {
        l = new Listing[](2);
        l[0] = _listing(address(tokA), CAP);
        l[1] = _listing(address(tokB), CAP);
    }

    // ---- caps ----

    /// @dev `who` sets `coll`'s cap on the vault.
    function _setCap(address who, address coll, uint192 cap) internal {
        vm.prank(who);
        vault.submitCap(coll, cap);
    }

    /// @dev `coll`'s stored cap on the vault.
    function _capOf(address coll) internal view returns (uint192 cap) {
        (cap,) = lens.capOf(address(vault), coll);
    }

    // ---- the appraiser seat ----

    /// @dev The curator appoints `a`, and the timelock runs out; nothing is seated until `_acceptAppraiser`.
    function _submitAppraiser(address a) internal {
        vm.prank(curator);
        terms.submitAppraiser(a);
        _warpBy(TIMELOCK);
    }

    /// @dev Anyone seats the pending appraiser.
    function _acceptAppraiser() internal {
        vm.prank(keeper);
        terms.acceptAppraiser();
    }

    /// @dev Appoint `a` through the timelock and seat it.
    function _appoint(address a) internal {
        _submitAppraiser(a);
        _acceptAppraiser();
    }

    /// @dev An `m`-of-`n` Safe-shaped appraiser and the owners' keys, ascending by address.
    function _safe(uint256 m, uint256 n) internal returns (address proxy, uint256[] memory keys) {
        SafeLikeSingleton single = new SafeLikeSingleton();
        SafeLikeHandler handler = new SafeLikeHandler();
        proxy = address(new SafeLikeProxy(address(single)));
        keys = new uint256[](n);
        for (uint256 i; i < n; i++) {
            keys[i] = 0x5AFE00 + i;
        }
        for (uint256 i = 1; i < n; i++) {
            for (uint256 j = i; j > 0 && vm.addr(keys[j - 1]) > vm.addr(keys[j]); j--) {
                (keys[j - 1], keys[j]) = (keys[j], keys[j - 1]);
            }
        }
        address[] memory owners = new address[](n);
        for (uint256 i; i < n; i++) {
            owners[i] = vm.addr(keys[i]);
        }
        SafeLikeSingleton(proxy).setup(address(handler), owners, m);
    }

    /// @dev The first `m` owners' signatures over the Safe's own message hash of the terms' `digest`, ascending as a Safe requires.
    function _safeSigs(address proxy, uint256[] memory keys, uint256 m, bytes32 digest) internal view returns (bytes memory sigs) {
        bytes32 h = SafeLikeSingleton(proxy).getMessageHash(abi.encode(digest));
        for (uint256 i; i < m; i++) {
            sigs = abi.encodePacked(sigs, _sig(keys[i], h));
        }
    }

    // ---- holders ----

    /// @dev `who` deposits `amt` for itself, minted and approving exactly that.
    function _lp(address who, uint256 amt) internal returns (uint256 shares) {
        return _lpFor(who, who, amt);
    }

    /// @dev `payer` deposits `amt` with `receiver` as the receiver.
    function _lpFor(address payer, address receiver, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(payer, amt);
        vm.startPrank(payer);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, receiver);
        vm.stopPrank();
    }

    /// @dev Mint `amt` of the asset to `who` and approve the vault for it, so the next call can be the deposit itself.
    function _armDeposit(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(vault), amt);
    }

    /// @dev Entry is shut for `who`: both max views read zero and a deposit of `amt` refuses `InventoryUnsold`.
    function _expectEntryShut(address who, uint256 amt, string memory why) internal {
        assertEq(vault.maxDeposit(who), 0, string.concat(why, ": maxDeposit reads zero"));
        assertEq(vault.maxMint(who), 0, string.concat(why, ": maxMint reads zero"));
        _armDeposit(who, amt);
        vm.prank(who);
        vm.expectRevert(IInKindVault.InventoryUnsold.selector);
        vault.deposit(amt, who);
    }

    /// @dev `h`'s tracked balance, through the lens: its shares plus any it has escrowed in a request.
    function _tracked(address h) internal view returns (uint256) {
        return lens.trackedOf(address(vault), h);
    }

    /// @dev What `holder` could claim of `token` now, through the lens.
    function _claimable(address holder, address token) internal view returns (uint256) {
        return lens.claimable(address(vault), holder, token);
    }

    /// @dev Every share a batch closing now would count, through the lens: balances and escrow, never shares gifted to the vault.
    function _trackedSupply() internal view returns (uint256) {
        return lens.trackedSupply(address(vault));
    }

    // ---- quotes ----

    /// @dev The rig's standard quote for `coll` at `price`: the rig's borrower, `PRINCIPAL` at most, the row's longest term, a fresh nonce, issued now.
    function _quote(address coll, uint256 price) internal returns (Quote memory) {
        uint64 t = uint64(_now());
        return Quote({collateral: coll, borrower: borrower, price: price, maxPrincipal: PRINCIPAL, maxTenor: ROW_MAX_TENOR, nonce: ++_nonce, issuedAt: t});
    }

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The door's payload: the quote and the appraiser's signature over the terms' own digest of it.
    function _data(Quote memory q) internal view returns (bytes memory) {
        return _dataBy(q, APPRAISER_KEY);
    }

    function _dataBy(Quote memory q, uint256 key) internal view returns (bytes memory) {
        return abi.encode(q, _sig(key, terms.hashQuote(q)));
    }

    /// @dev The extension payload: a roll quote and the appraiser's signature over it.
    function _rollData(RollQuote memory rq, uint256 key) internal view returns (bytes memory) {
        return abi.encode(rq, _sig(key, terms.hashRollQuote(rq)));
    }

    function _req(address coll, uint256 units, uint256 principal, uint64 tenor) internal pure returns (BorrowRequest memory) {
        return BorrowRequest({collateral: coll, units: units, principal: principal, tenor: tenor, minPayout: 0, minBufferWad: 0, deadline: 0});
    }

    /// @dev Mint `units` of `coll` to `who` and approve the vault for exactly that, so a following borrow is the next call.
    function _fund(address coll, address who, uint256 units) internal {
        MockERC20(coll).mint(who, units);
        vm.prank(who);
        MockERC20(coll).approve(address(vault), units);
    }

    /// @dev Borrow on `q` with `data` as its borrower.
    function _borrowWith(Quote memory q, bytes memory data, uint256 units, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        _fund(q.collateral, q.borrower, units);
        vm.prank(q.borrower);
        loanId = vault.borrow(_req(q.collateral, units, principal, tenor), data, "");
    }

    /// @dev The rig's standard loan against `coll`: `PRINCIPAL` on `UNITS` at `PRICE` for one minimum term.
    function _open(address coll) internal returns (uint256) {
        return _openFor(coll, PRINCIPAL, MIN_TENOR);
    }

    function _openFor(address coll, uint256 principal, uint64 tenor) internal returns (uint256) {
        Quote memory q = _quote(coll, PRICE);
        q.maxPrincipal = principal;
        return _borrowWith(q, _data(q), UNITS, principal, tenor);
    }

    // ---- loans and pots ----

    function _expiry(uint256 loanId) internal view returns (uint256) {
        return read.loan(loanId).expiry;
    }

    function _toExpiry(uint256 loanId) internal {
        _warpAtLeastTo(_expiry(loanId));
    }

    function _mp(uint256 loanId) internal view returns (MarketParams memory) {
        return ace.idToMarketParams(ace.loanMarket(loanId));
    }

    /// @dev What a recordless default forfeits: the whole coverage line at the market's price, capped at the pledge. Read BEFORE the settle.
    function _expectedPot(uint256 loanId) internal view returns (uint256) {
        MarketParams memory mp = _mp(loanId);
        Loan memory l = read.loan(loanId);
        uint256 line = FullMath.mulDivRoundingUp(mp.minCoverageWad * l.debt, 1 << 96, mp.price * 1e18) + 1;
        return line < l.collateralUnits ? line : l.collateralUnits;
    }

    /// @dev The keeper collects one loan's pot through the vault.
    function _collect(uint256 loanId) internal returns (uint256) {
        vm.prank(keeper);
        return vault.collectForfeited(_ids(loanId))[0];
    }

    /// @dev Warp to `loanId`'s expiry and collect it, checking the pot came home whole.
    function _defaultAndCollect(uint256 loanId) internal returns (uint256 pot) {
        _toExpiry(loanId);
        pot = _expectedPot(loanId);
        assertEq(_collect(loanId), pot, "the collect brought the whole coverage line home");
    }

    /// @dev Repay `loanId` in full as its borrower, who is minted the cash.
    function _repayAll(uint256 loanId) internal {
        uint256 debt = ace.debtOf(loanId);
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    /// @dev The extension fee `loanId` pays for `tenor` more, minted to its borrower with the hub approved.
    function _armFee(uint256 loanId, uint64 tenor) internal {
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = _mp(loanId);
        uint256 fee = LoanMath.originationFee(l.debt, tenor, mp.lenderAprBps) * 2;
        usdc.mint(borrower, fee);
        vm.prank(borrower);
        usdc.approve(address(ace), fee);
    }

    // ---- small builders ----

    /// @dev Advance one block, never backwards.
    function _nextBlock() internal {
        if (block.number > _blk) _blk = block.number;
        _blk += 1;
        vm.roll(_blk);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        (x[0], x[1]) = (a, b);
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    function _toks(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    function _toks(address a, address b) internal pure returns (address[] memory x) {
        x = new address[](2);
        (x[0], x[1]) = (a, b);
    }

    /// @dev `holder` claims `token` to itself; returns what it was paid.
    function _claim(address holder, address token) internal returns (uint256) {
        vm.prank(holder);
        return vault.claim(_toks(token), holder)[0];
    }
}
