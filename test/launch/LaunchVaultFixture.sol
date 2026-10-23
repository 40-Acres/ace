// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {Permits} from "../../src/ace/hub/libraries/Permits.sol";
import {Bid, Checkpoint} from "../../src/interfaces/ILaunchAuction.sol";
import {LaunchVault} from "../../src/curator/LaunchVault.sol";
import {SetValue} from "../../src/curator/sets/SetValue.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";
import {MockPermit2Allowance} from "../mocks/MockPermit2Allowance.sol";
import {AceReader} from "../utils/AceReader.sol";
import {RunwayFixture} from "./RunwayFixture.sol";

/// @title LaunchVaultFixture
/// @notice One launch on the Runway fixture with its auction final at CLEAR, Permit2's allowance door etched, and 40acres' vault on it.
/// @notice Helpers buy a buyer's credit, open and settle the pool, rest a depositor's cash, and drive the vault's verbs.
/// @dev Every unit bid is fully filled above CLEAR from a checkpoint that has run none of the schedule, so it spent exactly its amount.
abstract contract LaunchVaultFixture is RunwayFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 internal constant D = 2232; // 40acres' published discount, 20%
    uint16 internal constant BASE = 150; // 40acres' published rate per 7 days
    uint256 internal constant CLEAR = 7_200 << 40; // the final clearing price, about $0.10 a token, Q96 USDC atoms per token atom
    uint24 internal constant MPS = 1e7;
    uint256 internal constant Q = 1 << 96;
    uint256 internal constant LINE = Q * 125 / 100; // the vault's divisor: k = 1.25 in the Q96 frame
    uint64 internal constant START = 10; // every unit bid's start block, whose checkpoint has run none of the schedule
    int256 internal constant LIQ = 1e17; // full-range liquidity: about 31,600 USDC and 316,000 tokens at CLEAR
    uint256 internal constant SPEND = 1_000e6; // a buyer's default auction spend
    uint256 internal constant CASH = 100_000e6; // the default depositor's deposit

    LaunchVault internal impl;
    LaunchVault internal vault;
    MockPermit2Allowance internal permit2;
    AceReader internal read;
    PoolModifyLiquidityTest internal lp;
    PoolSwapTest internal swapper;
    Made internal m;
    uint256 internal lastBid; // the newest bid id set on any fixture auction
    address internal curator = address(0xC0FA);
    address internal carol = address(0xCA401); // the default depositor

    function setUp() public virtual override {
        super.setUp();
        vm.etch(Permits.PERMIT2, address(new MockPermit2Allowance()).code);
        permit2 = MockPermit2Allowance(Permits.PERMIT2);
        read = new AceReader(address(ace));
        lp = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        swapper = new PoolSwapTest(IPoolManager(address(manager)));
        usdc.approve(address(lp), type(uint256).max);
        usdc.approve(address(swapper), type(uint256).max);
        impl = new LaunchVault(address(factory));
        m = _launch();
        _final(m);
        vault = LaunchVault(impl.vaultFor(m.token, curator, D, BASE));
    }

    // ---- the launch ----

    /// @dev A launch whose token sorts on the asked side of USDC, with its auction final at CLEAR and the default vault on it.
    function _launchOn(bool tokenIs0) internal returns (Made memory x, LaunchVault v) {
        for (uint256 i; i < 64; ++i) {
            x = _launch();
            if ((x.token < address(usdc)) == tokenIs0) break;
        }
        require((x.token < address(usdc)) == tokenIs0, "fixture: no launch sorted that way");
        _final(x);
        v = LaunchVault(impl.vaultFor(x.token, curator, D, BASE));
    }

    /// @dev The auction graduated and checkpointed its end at CLEAR, having run the whole schedule since START.
    function _final(Made memory x) internal {
        uint64 e = x.auction.endBlock();
        x.auction.setCheckpoint(START, _cp(CLEAR, 0));
        x.auction.setCheckpoint(e, _cp(CLEAR, MPS));
        x.auction.setState(e, true, 0);
    }

    function _cp(uint256 clearing, uint24 cumMps) internal pure returns (Checkpoint memory c) {
        (c.clearingPrice, c.cumulativeMps) = (clearing, cumMps);
    }

    /// @dev The pool opens at CLEAR with full-range liquidity, launchBy passes, and settlement finds it live.
    function _goLive(Made memory x) internal {
        strat.openPool(x.key, _sqrtAt(x, CLEAR));
        strat.send(x.token, address(this), 400_000e18);
        IERC20(x.token).approve(address(lp), type(uint256).max);
        IERC20(x.token).approve(address(swapper), type(uint256).max);
        usdc.mint(address(this), 1e13);
        int24 edge = TickMath.maxUsableTick(SPACING);
        lp.modifyLiquidity(x.key, ModifyLiquidityParams(-edge, edge, LIQ, 0), "");
        _warpAtLeastTo(x.launchBy + 1);
        x.budget.settle();
    }

    /// @dev The migration failed: no pool, the whole reserve back in the budget, launchBy passes, and settlement finds failure.
    function _goFailed(Made memory x) internal {
        strat.send(x.token, address(x.budget), SUPPLY);
        _warpAtLeastTo(x.launchBy + 1);
        x.budget.settle();
    }

    function _openAt(Made memory x) internal pure returns (uint256) {
        return x.launchBy + 3 days;
    }

    function _lendEnd(Made memory x) internal pure returns (uint256) {
        return x.launchBy + 33 days;
    }

    /// @dev The pool sqrt price at which the token trades at `priceQ96` USDC atoms per token atom, in `x`'s pool orientation.
    function _sqrtAt(Made memory x, uint256 priceQ96) internal view returns (uint160) {
        return SetValue.sqrtPriceX96(priceQ96, address(usdc) < x.token);
    }

    // ---- buyers ----

    /// @dev A bid owned by `who`'s buyer account, fully filled above CLEAR, that spent exactly `amount` USDC atoms.
    function _bid(Made memory x, address who, uint256 amount) internal returns (uint256 id) {
        id = ++lastBid;
        Bid memory b;
        (b.startBlock, b.maxPrice, b.owner, b.amountQ96) = (START, CLEAR + 1, x.lock.account(who, 0), amount << 96);
        x.auction.setBid(id, b);
    }

    /// @dev What a bid spending `amount` filled at CLEAR, in token atoms, and the credit the vault books for it.
    function _filled(uint256 amount) internal pure returns (uint256) {
        return (amount << 96) / CLEAR;
    }

    function _creditFor(uint256 amount) internal pure returns (uint256) {
        return _filled(amount) - 1;
    }

    /// @dev `who` spends `amount` in the auction, claims what it filled into its account, and the vault credits the bid.
    function _buy(Made memory x, LaunchVault v, address who, uint256 amount) internal returns (LockAccount acct) {
        uint256 id = _bid(x, who, amount);
        acct = LockAccount(x.lock.predict(who, 0));
        strat.send(x.token, address(acct), _filled(amount));
        v.credit(id, 0, 0);
    }

    function _buy(address who, uint256 amount) internal returns (LockAccount) {
        return _buy(m, vault, who, amount);
    }

    function _acct(address who) internal view returns (LockAccount) {
        return LockAccount(m.lock.predict(who, 0));
    }

    // ---- depositors ----

    function _deposit(LaunchVault v, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(v), amount);
        v.deposit(amount);
        vm.stopPrank();
    }

    /// @dev `who` approves Permit2 on USDC and signs this vault an allowance of `amount` until `exp`.
    function _optIn(LaunchVault v, address who, uint160 amount, uint48 exp) internal {
        vm.startPrank(who);
        usdc.approve(Permits.PERMIT2, type(uint256).max);
        permit2.approve(address(usdc), address(v), amount, exp);
        vm.stopPrank();
    }

    // ---- lending ----

    /// @dev alice buys SPEND, carol deposits CASH, the pool goes live, and the clock reaches openAt.
    function _ready() internal returns (LockAccount acct) {
        acct = _buy(alice, SPEND);
        _deposit(vault, carol, CASH);
        _goLive(m);
        _warpTo(_openAt(m));
    }

    function _reserve(LaunchVault v, address who, uint256 assets) internal returns (bytes32 id, uint256 got) {
        vm.prank(who);
        return v.reserve(assets);
    }

    /// @dev The most a pledge of `units` may borrow at `price`, by the hub's coverage line at k = 1.25.
    function _maxPrincipal(uint256 units, uint256 price) internal pure returns (uint256) {
        return units <= 1 ? 0 : Math.mulDiv(units - 1, price, LINE);
    }

    /// @dev The fewest units that secure `principal` at `price`: the hub's coverage line.
    function _unitsFor(uint256 principal, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(principal, LINE, price, Math.Rounding.Ceil) + 1;
    }

    /// @dev `who` pledges through its buyer account in market `id` and borrows `principal`, pledging just the line, for `tenor`.
    function _borrow(Made memory x, address who, bytes32 id, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        MarketParams memory p = ace.idToMarketParams(id);
        LockAccount acct = LockAccount(x.lock.predict(who, 0));
        uint256 units = _unitsFor(principal, p.price);
        vm.prank(who);
        loanId = acct.borrow(id, units, principal, tenor, OpenBounds(0, 0, 0));
    }

    /// @dev A third party repays loan `loanId` in full.
    function _repay(uint256 loanId) internal {
        uint256 debt = ace.debtOf(loanId);
        usdc.mint(address(0xFA7E4), debt);
        vm.startPrank(address(0xFA7E4));
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }

    // ---- the window ----

    /// @dev Pin what the hook's window reads for `x`'s pool: the low, the high and spot, raw pool ticks.
    function _window(Made memory x, int24 lo, int24 hi, int24 spot) internal {
        vm.mockCall(address(factory.HOOK()), abi.encodeCall(RunwayHook.windowOf, (x.key.toId())), abi.encode(lo, hi, spot));
    }

    /// @dev The raw pool tick at which `x`'s token trades at the token tick `t`; the inverse of the vault's `-t - 1`.
    function _poolTick(Made memory x, int24 t) internal view returns (int24) {
        return x.token < address(usdc) ? t : -t - 1;
    }

    /// @dev Pin a flat window, every read at the token tick `t`.
    function _flat(Made memory x, int24 t) internal {
        int24 p = _poolTick(x, t);
        _window(x, p, p, p);
    }

    /// @dev The clearing tick by PriceGrid's floor path, as a token price.
    function _clearTick() internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(SetValue.sqrtPriceX96(CLEAR, false));
    }

    /// @dev The price at token tick `t`, Q96 USDC atoms per token atom, floored as the vault floors it.
    function _priceAt(int24 t) internal pure returns (uint256) {
        uint256 g = TickMath.getSqrtPriceAtTick(t);
        return Math.mulDiv(g, g, Q);
    }

    /// @dev The quote a token-tick floor of `t` makes: `t - D` snapped down onto the 50-tick grid.
    function _quoteAt(int24 t) internal pure returns (uint256) {
        return _priceAt(TickBitmap.compress(t - int24(D), 50) * 50);
    }

    /// @dev An exact-input swap of `amount` through `x`'s pool; `sellToken` sells the launch token, so its price falls.
    function _swap(Made memory x, bool sellToken, uint256 amount) internal {
        bool zeroForOne = (x.token < address(usdc)) == sellToken;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapper.swap(x.key, SwapParams(zeroForOne, -int256(amount), limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        _warpBy(12);
    }
}
