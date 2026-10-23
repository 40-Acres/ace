// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/ILaunchAuction.sol";
import {LaunchVault} from "../../src/curator/LaunchVault.sol";
import {SetValue} from "../../src/curator/sets/SetValue.sol";
import {LaunchLock, Leg} from "../../src/entities/launch/LaunchLock.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {ICcaBidding, ILBPStrategyLaunch, IPositionsView} from "./CcaInterfaces.sol";
import {RunwaySalt} from "./RunwayMocks.sol";

/// @notice Canonical Permit2's allowance door, as a bidder's signed opt-in and the vault's pull use it.
interface IPermit2Single {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature) external;
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address owner, address token, address spender) external view returns (uint160, uint48, uint48);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @title LaunchVaultFork
/// @notice The vault against the DEPLOYED launcher on a mainnet fork: the real auction, canonical Permit2, real USDC, the real pool.
/// @notice A keeper's post-auction bundle under front-runs, the credit against what each bid filled, the price's units against the pool,
/// @notice a failed migration's 1:1 exits, the gas of the two hot verbs, pump-and-hold on the full-range pool, and a same-block sandwich.
/// @dev Skipped cleanly when ALCHEMY_API_KEY is absent, as every fork suite here is.
contract LaunchVaultForkTest is WarpClock {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant STRATEGY = 0x2EEF0e2a9a652d755AccAD95a24541A98B5CA000; // LBPStrategy v3.3.0, mainnet
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 internal constant FORK_BLOCK = 26_140_979;
    uint256 internal constant BLOCK_SECONDS = 13;
    uint24 internal constant FEE = 10_000;
    int24 internal constant SPACING = 200;
    uint128 internal constant SUPPLY = 1_000_000e18;
    uint256 internal constant TICK = 1 << 40; // Q96 tick spacing
    uint256 internal constant FLOOR = 720 << 40; // about $0.01 a token, Q96 USDC atoms per token atom
    uint256 internal constant P_LOW = FLOOR + 5 * TICK; // outbid by the end
    uint256 internal constant P_MID = FLOOR + 10 * TICK; // the final clearing price, partially filled
    uint256 internal constant P_HIGH = FLOOR + 20 * TICK; // above the final clearing price, fully filled
    uint128 internal constant BID_A = 50_000e6;
    uint128 internal constant BID_B = 1_000e6;
    uint128 internal constant BID_C = 1_000e6;
    uint24 internal constant D = 2232; // 40acres' published discount, 20%
    uint16 internal constant BASE = 150;
    uint256 internal constant Q = 1 << 96;
    uint256 internal constant LINE = Q * 125 / 100;
    bytes32 internal constant DETAILS_TYPEHASH = keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    bool internal live;
    Ace internal ace;
    AceReader internal read;
    IPoolManager internal pm;
    address internal posm;
    LaunchTokenFactory internal factory;
    LaunchVault internal impl;
    PoolSwapTest internal swapper;

    address internal team = address(0x7EA4);
    address internal operator = address(0x0905);
    address internal curator = address(0xC0FA);
    address internal keeper = address(0x4EE9);
    address internal stranger = address(0x57A1);

    /// @dev One launch and its vault, read back from the factory.
    struct Launch {
        address token;
        LaunchLock lock;
        address auction;
        LaunchOpsBudget budget;
        PoolKey key;
        uint64 start;
        uint64 end;
        uint256 launchBy;
        LaunchVault vault;
    }

    /// @dev A bidder with a key, its bid, the bid's exit and spend hints, and the opt-in it signed at bid time.
    struct Buyer {
        address who;
        uint256 pk;
        uint256 bid;
        uint64 h1;
        uint64 h2;
        uint128 amount;
        IPermit2Single.PermitSingle permit;
        bytes sig;
    }

    function setUp() public {
        string memory k = vm.envOr("ALCHEMY_API_KEY", string(""));
        if (bytes(k).length == 0) return;
        vm.createSelectFork(string.concat("https://eth-mainnet.g.alchemy.com/v2/", k), vm.envOr("ACE_LAUNCH_FORK_BLOCK", FORK_BLOCK));
        _anchorClock();
        if (STRATEGY.code.length == 0) return;
        live = true;
        (ace,) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        posm = ILBPStrategyLaunch(STRATEGY).positionManager();
        pm = IPositionsView(posm).poolManager();
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 salt = RunwaySalt.mine(at, address(pm), STRATEGY);
        factory = new LaunchTokenFactory(address(ace), STRATEGY, USDC, BLOCK_SECONDS, FEE, SPACING, salt, address(0x51CC), 0);
        impl = new LaunchVault(address(factory));
        swapper = new PoolSwapTest(pm);
    }

    // ---- the launch ----

    function _launch() internal returns (Launch memory L) {
        LaunchTokenFactory.LaunchInput memory p;
        uint64 b = uint64(vm.getBlockNumber());
        (p.name, p.symbol) = ("Launch", "LCH");
        (p.auctionSupply, p.floorPrice, p.tickSpacing) = (SUPPLY, FLOOR, TICK);
        (p.startBlock, p.endBlock) = (b + 2, b + 102);
        (p.teamShareBps, p.buyerDuration) = (2_000, 30 days);
        p.legs = new Leg[](1);
        p.legs[0] = Leg({beneficiary: team, amount: 50_000e18, cliff: 30 days, duration: 365 days});
        (p.opsAmount, p.operator) = (200_000e18, operator);
        L.launchBy = _now() + (uint256(p.endBlock) + 1 - b) * BLOCK_SECONDS + 1 days;
        vm.prank(team);
        L.token = factory.launch(p);
        (address lock, address auction, address budget) = factory.launchOf(L.token);
        (L.lock, L.auction, L.budget, L.start, L.end) = (LaunchLock(lock), auction, LaunchOpsBudget(budget), p.startBlock, p.endBlock);
        (address c0, address c1) = L.token < USDC ? (L.token, USDC) : (USDC, L.token);
        L.key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), FEE, SPACING, IHooks(address(factory.HOOK())));
        L.vault = LaunchVault(impl.vaultFor(L.token, curator, D, BASE));
    }

    /// @dev `name` bids `amount` at `price` in block `blk`, through Permit2 as the auction pulls, and signs the vault an opt-in for it.
    function _bid(Launch memory L, string memory name, uint64 blk, uint256 price, uint128 amount) internal returns (Buyer memory b) {
        (b.who, b.pk) = makeAddrAndKey(name);
        b.amount = amount;
        deal(USDC, b.who, amount);
        vm.startPrank(b.who);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IPermit2Single(PERMIT2).approve(USDC, L.auction, type(uint160).max, type(uint48).max);
        vm.stopPrank();
        uint48 until = uint48(L.launchBy + 3 days);
        b.permit = IPermit2Single.PermitSingle(IPermit2Single.PermitDetails(USDC, amount, until, 0), address(L.vault), until);
        b.sig = _sign(b.pk, b.permit);
        address owner = L.lock.predict(b.who, 0);
        vm.roll(blk);
        vm.prank(b.who);
        b.bid = ICcaBidding(L.auction).submitBid(price, amount, owner, abi.encode(b.who));
    }

    function _sign(uint256 pk, IPermit2Single.PermitSingle memory p) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(SINGLE_TYPEHASH, keccak256(abi.encode(DETAILS_TYPEHASH, p.details)), p.spender, p.sigDeadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", IPermit2Single(PERMIT2).DOMAIN_SEPARATOR(), h)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Three bids: B fully filled until A outbids it at the end, C above the final price, A at it; then the auction's last block.
    function _threeBids() internal returns (Launch memory L, Buyer[3] memory x) {
        L = _launch();
        x[1] = _bid(L, "buyerB", L.start, P_LOW, BID_B);
        x[2] = _bid(L, "buyerC", L.start + 10, P_HIGH, BID_C);
        x[0] = _bid(L, "buyerA", L.start + 20, P_MID, BID_A);
        (x[0].h1, x[0].h2) = (L.start + 20, 0);
        (x[1].h1, x[1].h2) = (L.start + 20, L.end);
        vm.roll(L.end);
    }

    /// @dev The auction's own exit for `b`: a full fill above the final price, else the partial exit with its hints.
    function _exit(Launch memory L, Buyer memory b) internal {
        if (b.h1 == 0) ICcaBidding(L.auction).exitBid(b.bid);
        else ICcaBidding(L.auction).exitPartiallyFilledBid(b.bid, b.h1, b.h2);
    }

    /// @dev The keeper's post-auction legs for `b`, each tolerant of a stranger having run it first.
    /// @dev Permit only if the allowance does not already cover it; exit only if not exited; credit once; deposit only what landed.
    function _bundle(Launch memory L, Buyer memory b) internal returns (uint256 shares) {
        vm.startPrank(keeper);
        (uint160 amt, uint48 exp,) = IPermit2Single(PERMIT2).allowance(b.who, USDC, address(L.vault));
        if (amt < b.permit.details.amount || exp < _now()) IPermit2Single(PERMIT2).permit(b.who, b.permit, b.sig);
        if (IContinuousClearingAuction(L.auction).bids(b.bid).exitedBlock == 0) _exit(L, b);
        if (!L.vault.credited(b.bid)) L.vault.credit(b.bid, b.h1, b.h2);
        if (IERC20(USDC).balanceOf(L.lock.predict(b.who, 0)) != 0) shares = L.vault.depositRefund(b.who);
        vm.stopPrank();
    }

    /// @dev The bundle for all three, claims for all three, then the deployed strategy's migration and a live settle, and openAt.
    function _liveVault() internal returns (Launch memory L, Buyer[3] memory x) {
        (L, x) = _threeBids();
        for (uint256 i; i < 3; ++i) {
            _bundle(L, x[i]);
            ICcaBidding(L.auction).claimTokens(x[i].bid);
        }
        vm.roll(L.end + 1);
        ILBPStrategyLaunch(STRATEGY).migrate(L.auction);
        _warpTo(L.launchBy + 1);
        L.budget.settle();
        assertTrue(L.budget.live(), "fixture: the launch did not go live");
        _warpTo(L.launchBy + 3 days);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _clearing(Launch memory L) internal view returns (uint256) {
        IContinuousClearingAuction a = IContinuousClearingAuction(L.auction);
        return a.checkpoints(a.endBlock()).clearingPrice;
    }

    /// @dev What `who`'s bid spent, in USDC atoms rounded up, by the budget's own arithmetic.
    function _spend(Launch memory L, Buyer memory b) internal view returns (uint256) {
        return Math.ceilDiv(L.budget.spentOf(b.bid, b.h1, b.h2), Q);
    }

    // ---- the pool ----

    /// @dev The token's pool price, Q96 USDC atoms per token atom, read off slot0 in either currency order.
    function _poolPrice(Launch memory L) internal view returns (uint256) {
        (uint160 s,,,) = pm.getSlot0(L.key.toId());
        uint256 p = Math.mulDiv(s, s, Q);
        return L.token < USDC ? p : Math.mulDiv(Q, Q, p);
    }

    /// @dev Swap the pool to the token price `priceQ96`, exact-input against a sqrt-price limit, funded by `deal`.
    function _moveTo(Launch memory L, uint256 priceQ96) internal {
        uint160 target = SetValue.sqrtPriceX96(priceQ96, USDC < L.token);
        (uint160 s,,,) = pm.getSlot0(L.key.toId());
        if (target == s) return;
        bool zeroForOne = target < s;
        address tokenIn = zeroForOne ? Currency.unwrap(L.key.currency0) : Currency.unwrap(L.key.currency1);
        deal(tokenIn, address(this), 1e30);
        IERC20(tokenIn).approve(address(swapper), type(uint256).max);
        swapper.swap(L.key, SwapParams(zeroForOne, -int256(1e29), target), PoolSwapTest.TestSettings(false, false), "");
    }

    /// @dev Hold the price through three 12-hour slots: the window is then the held price alone.
    function _hold() internal {
        _warpBy(37 hours);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _maxPrincipal(uint256 units, uint256 price) internal pure returns (uint256) {
        return units <= 1 ? 0 : Math.mulDiv(units - 1, price, LINE);
    }

    function _unitsFor(uint256 principal, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(principal, LINE, price, Math.Rounding.Ceil) + 1;
    }

    function _borrow(Launch memory L, address who, bytes32 id, uint256 principal) internal returns (uint256 loanId, uint256 units) {
        units = _unitsFor(principal, ace.idToMarketParams(id).price);
        LockAccount acct = LockAccount(L.lock.predict(who, 0));
        vm.prank(who);
        loanId = acct.borrow(id, units, principal, 30 days, OpenBounds(0, 0, 0));
    }

    // ---- the rows ----

    /// @notice The keeper's bundle on the real auction, with a stranger first to submit A's signed permit and to exit B's bid.
    /// @notice Run raw, both legs now revert; the tolerant bundle skips them, credits each bid, and deposits each refund for its own buyer.
    /// @notice Each account ends empty, each wallet where it started, and the vault holds exactly the refunds against their shares.
    function test_Fork_TheKeeperBundleUnderFrontRuns() public {
        if (!live) return vm.skip(true);
        (Launch memory L, Buyer[3] memory x) = _threeBids();
        vm.startPrank(stranger);
        IPermit2Single(PERMIT2).permit(x[0].who, x[0].permit, x[0].sig);
        _exit(L, x[1]);
        vm.expectRevert();
        IPermit2Single(PERMIT2).permit(x[0].who, x[0].permit, x[0].sig); // the nonce is spent
        vm.expectRevert();
        _exit(L, x[1]); // the bid has exited
        vm.stopPrank();
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 wallet = IERC20(USDC).balanceOf(x[i].who);
            uint256 shares = _bundle(L, x[i]);
            assertEq(L.vault.sharesOf(x[i].who), shares, "the shares are not the buyer's own refund");
            assertLe(shares, x[i].amount, "a deposit passed the bid's own opt-in");
            assertEq(IERC20(USDC).balanceOf(L.lock.predict(x[i].who, 0)), 0, "an account kept its refund");
            assertEq(IERC20(USDC).balanceOf(x[i].who), wallet, "a wallet moved");
            assertTrue(L.vault.credited(x[i].bid), "a bid went uncredited");
            total += shares;
        }
        assertGt(L.vault.sharesOf(x[0].who), 0, "fixture: A was refunded");
        assertGt(L.vault.sharesOf(x[1].who), 0, "fixture: B was refunded");
        assertEq(IERC20(USDC).balanceOf(address(L.vault)), total, "the vault holds other than the refunds");
        assertEq(L.vault.totalShares(), total, "the shares are not the refunds");
    }

    /// @notice For every bid, the credit is at most what the bid filled, read after its exit and before its claim.
    function test_Fork_CreditIsAtMostTokensFilled() public {
        if (!live) return vm.skip(true);
        (Launch memory L, Buyer[3] memory x) = _threeBids();
        for (uint256 i; i < 3; ++i) {
            _bundle(L, x[i]);
            uint256 filled = IContinuousClearingAuction(L.auction).bids(x[i].bid).tokensFilled;
            uint256 credit = L.vault.creditOf(L.lock.predict(x[i].who, 0));
            console2.log("credit vs filled, bid", i, credit, filled);
            assertGt(credit, 0, "fixture: the bid filled");
            assertLe(credit, filled, "a credit passed what its bid filled");
        }
    }

    /// @notice The price's units: a market at `quote()` lets the account draw units x price / 2^96 / 1.25 USDC atoms.
    /// @notice The quote is clearing less d, and the pledge is worth 1.25 / 0.8 of the draw at the pool's own price.
    function test_Fork_ThePricesUnitsAgainstThePool() public {
        if (!live) return vm.skip(true);
        (Launch memory L, Buyer[3] memory x) = _liveVault();
        uint256 c = _clearing(L);
        uint256 q = L.vault.quote();
        assertLe(q, c * 8 / 10, "the quote passed clearing less d");
        assertGe(q * 1_000, c * 8 * 994 / 10, "the quote fell more than a grid step under clearing less d");
        vm.prank(x[0].who);
        (bytes32 id, uint256 got) = L.vault.reserve(type(uint256).max);
        (uint256 loanId, uint256 units) = _borrow(L, x[0].who, id, got);
        assertLe(got, _maxPrincipal(units, q), "the draw passed units x price / 2^96 / 1.25");
        assertGe(got + 1, _maxPrincipal(units - 1, q), "the pledge is more than one atom over the line");
        uint256 worth = Math.mulDiv(units, _poolPrice(L), Q);
        assertGe(worth * 1_000, got * 1_550, "the pledge is worth less than 1.25 / 0.8 of the draw at the pool's price, a grid step aside");
        console2.log("draw, pledge worth at the pool (USDC atoms)", got, worth);
        assertGt(loanId, 0, "fixture: the loan opened");
    }

    /// @notice A failed migration: settle finds failure, the window shuts, nothing ever lends, and each buyer exits 1:1.
    function test_Fork_AFailedMigrationExitsOneToOne() public {
        if (!live) return vm.skip(true);
        (Launch memory L, Buyer[3] memory x) = _threeBids();
        uint256[3] memory shares;
        for (uint256 i; i < 3; ++i) {
            shares[i] = _bundle(L, x[i]);
        }
        vm.roll(L.end + 1);
        vm.mockCallRevert(posm, abi.encodeWithSelector(IPositionsView.modifyLiquidities.selector), "");
        ILBPStrategyLaunch(STRATEGY).migrate(L.auction);
        vm.clearMockedCalls();
        _warpTo(L.launchBy + 1);
        L.budget.settle();
        assertFalse(L.budget.live(), "fixture: the migration recovered live");
        assertFalse(L.vault.depositing(), "a failed launch left the window open");
        _warpTo(L.launchBy + 3 days);
        vm.prank(x[0].who);
        vm.expectRevert(LaunchVault.NotLending.selector);
        L.vault.reserve(1);
        for (uint256 i; i < 3; ++i) {
            if (shares[i] == 0) continue;
            vm.prank(x[i].who);
            (uint256 assets, uint256 units) = L.vault.exit(shares[i], x[i].who);
            assertEq(abi.encode(assets, units), abi.encode(shares[i], 0), "a failed launch did not exit 1:1");
        }
        assertEq(IERC20(USDC).balanceOf(address(L.vault)), 0, "the vault kept USDC");
    }

    /// @notice The gas of the two hot verbs on the real stack: a keeper's depositRefund, and a first reserve that creates its market.
    /// @dev forge-config: default.isolate = true
    /// @dev forge-config: deploy.isolate = true
    function test_Fork_TheGasOfDepositRefundAndReserve() public {
        if (!live) return vm.skip(true);
        (Launch memory L, Buyer[3] memory x) = _threeBids();
        vm.prank(stranger);
        IPermit2Single(PERMIT2).permit(x[0].who, x[0].permit, x[0].sig);
        _exit(L, x[0]);
        L.vault.credit(x[0].bid, x[0].h1, x[0].h2);
        vm.prank(keeper);
        L.vault.depositRefund(x[0].who);
        uint256 refundGas = vm.lastCallGas().gasTotalUsed;
        ICcaBidding(L.auction).claimTokens(x[0].bid);
        vm.roll(L.end + 1);
        ILBPStrategyLaunch(STRATEGY).migrate(L.auction);
        _warpTo(L.launchBy + 1);
        L.budget.settle();
        _warpTo(L.launchBy + 3 days);
        vm.prank(x[0].who);
        L.vault.reserve(1_000e6);
        uint256 firstReserve = vm.lastCallGas().gasTotalUsed;
        vm.prank(x[0].who);
        L.vault.reserve(1_000e6);
        uint256 topUp = vm.lastCallGas().gasTotalUsed;
        console2.log("gas: depositRefund", refundGas);
        console2.log("gas: first reserve, creating its market", firstReserve);
        console2.log("gas: a top-up reserve", topUp);
        assertLe(refundGas, 200_000, "depositRefund costs more than expected");
        assertLe(firstReserve, 700_000, "a first reserve costs more than expected");
        assertLe(topUp, 300_000, "a top-up reserve costs more than expected");
    }

    /// @notice Pump and hold on the real full-range pool, through three slots: the quote is min(held price, clearing) x (1 - d).
    /// @notice A credited draw stays within 0.64 of the buyer's spend; a capacity-capped room would drain past m = 1.5625.
    function test_Fork_PumpAndHold() public {
        if (!live) return vm.skip(true);
        (Launch memory L, Buyer[3] memory x) = _liveVault();
        uint256 c = _clearing(L);
        uint256 v = c / 2;
        _moveTo(L, v);
        _hold();
        _assertQuote(L, v, "after a dump held");
        uint256 held = 1_000_000e18; // what a capacity-capped room would lend against, bought at v
        uint256[3] memory ms = [uint256(150), 160, 300]; // m, in hundredths
        for (uint256 i; i < 3; ++i) {
            _moveTo(L, v);
            _hold();
            _moveTo(L, v * ms[i] / 100);
            _hold();
            uint256 q = _assertQuote(L, Math.min(v * ms[i] / 100, c), "after a pump held");
            bool drains = _maxPrincipal(held, q) > Math.mulDiv(held, v, Q);
            assertEq(drains, ms[i] > 156, "the capacity-capped counterfactual drains on the wrong side of 1.5625");
            vm.prank(x[0].who);
            (, uint256 got) = L.vault.reserve(type(uint256).max);
            assertLe(got, _spend(L, x[0]) * 64 / 100, "a credited reservation passed 0.64 of the spend");
            _warpBy(1 hours);
            L.vault.recall(L.lock.predict(x[0].who, 0));
        }
    }

    /// @dev The block-start quote against `ref` x (1 - d): at or under it, and within a grid step and the tick floors of it.
    function _assertQuote(Launch memory L, uint256 ref, string memory what) internal view returns (uint256 q) {
        q = L.vault.blockStartQuote();
        assertLe(q, ref * 8 / 10, what);
        assertGe(q * 1_000, ref * 8 * 993 / 10, what);
    }

    /// @notice A same-block sandwich: the buyer reserves, a whale dumps, the buyer pours in cheap tokens and draws all its market lends.
    /// @notice What the vault paid out beyond the pledge's post-dump worth is at most the reservation; another account's is untouched.
    function test_Fork_ASameBlockSandwichLosesAtMostTheReservation() public {
        if (!live) return vm.skip(true);
        (Launch memory L, Buyer[3] memory x) = _liveVault();
        vm.prank(x[1].who);
        (bytes32 other, uint256 otherGot) = L.vault.reserve(type(uint256).max);
        uint256 cash = IERC20(USDC).balanceOf(address(L.vault));
        vm.prank(x[0].who);
        (bytes32 id, uint256 got) = L.vault.reserve(type(uint256).max);
        _moveTo(L, _clearing(L) / 5); // the whale, same block
        uint256 draw = ace.drawableOf(id);
        address acct = L.lock.predict(x[0].who, 0);
        deal(L.token, acct, IERC20(L.token).balanceOf(acct) + _unitsFor(draw, ace.idToMarketParams(id).price)); // bought at the dump
        (, uint256 units) = _borrow(L, x[0].who, id, draw);
        uint256 worth = Math.mulDiv(units, _poolPrice(L), Q);
        uint256 paid = cash - IERC20(USDC).balanceOf(address(L.vault)) - ace.restingOf(id);
        assertLt(worth, paid, "fixture: the dump put the pledge under the draw");
        assertEq(paid, got, "the vault paid out more than it reserved");
        assertLe(paid - worth, got, "the loss passed the reservation");
        assertEq(ace.restingOf(other), otherGot, "another account's reservation moved");
        assertEq(ace.restingOf(id), 0, "fixture: the reservation was drawn whole");
    }
}
