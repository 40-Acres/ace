// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {LaunchVault} from "../../src/curator/LaunchVault.sol";
import {SetValue} from "../../src/curator/sets/SetValue.sol";
import {LaunchLock} from "../../src/entities/launch/LaunchLock.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {LaunchVaultFixture} from "./LaunchVaultFixture.sol";
import {MockRunwayStrategy} from "./RunwayMocks.sol";

/// @title LaunchVaultCapHandler
/// @notice Drives two credited buyers through the lending term in any order: donate, reserve, release, re-price, draw, repay, forfeit, recall.
/// @notice At every successful reserve it checks the per-account cap; around every verb but `exit` it checks the launch token stayed put.
contract LaunchVaultCapHandler is WarpClock {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant LINE = (1 << 96) * 125 / 100; // the vault's divisor, k = 1.25 in the Q96 frame

    Ace internal ace;
    AceReader internal read;
    LaunchVault internal vault;
    MockERC20 internal usdc;
    IERC20 internal token;
    LaunchLock internal lock;
    MockRunwayStrategy internal strat;
    PoolKey internal key;
    int24 internal cTick; // the clearing tick, as a token price
    address[2] internal who;
    address[3] internal holders;

    mapping(address acct => bytes32[]) internal marketsOf; // every market the account ever reserved, once each
    mapping(bytes32 id => bool) internal seen;
    mapping(address acct => uint256) public lentOf; // principal live in this vault's markets
    mapping(address acct => uint256) public maxPriceOf; // the highest price among its vault markets
    uint256[] internal loans;
    mapping(uint256 loanId => address) internal acctOf;
    mapping(uint256 loanId => uint256) internal principalOf;

    bool public capBroken;
    bool public tokenLeftOutsideExit;
    uint256 public calls; // every action but exit that ran to its end
    uint256 public reserves; // successful reservations
    uint256 public reservesWhileLent; // successful reservations by an account with a loan out: the cap's hard case
    uint256 public newMarkets; // reservations that opened a market the account had not used
    uint256 public draws;
    uint256 public closes; // loans repaid or forfeited

    constructor(
        Ace ace_,
        LaunchVault vault_,
        MockERC20 usdc_,
        LaunchLock lock_,
        MockRunwayStrategy strat_,
        PoolKey memory key_,
        address[2] memory who_,
        address[3] memory holders_
    ) {
        (ace, read, vault, usdc, lock, strat, key) = (ace_, new AceReader(address(ace_)), vault_, usdc_, lock_, strat_, key_);
        token = IERC20(vault_.terms().token);
        (who, holders) = (who_, holders_);
        cTick = TickMath.getTickAtSqrtPrice(SetValue.sqrtPriceX96(_clearing(), false));
    }

    modifier tokenStays() {
        ++calls;
        uint256 before = token.balanceOf(address(vault));
        _;
        if (token.balanceOf(address(vault)) < before) tokenLeftOutsideExit = true;
    }

    function _clearing() internal view returns (uint256) {
        return vault.terms().auction.checkpoints(vault.terms().auction.endBlock()).clearingPrice;
    }

    function _acct(uint256 i) internal view returns (address b, LockAccount a) {
        b = who[i % 2];
        a = LockAccount(lock.predict(b, 0));
    }

    // ---- actions ----

    function reserve(uint256 i, uint256 amount) external tokenStays {
        (address b, LockAccount a) = _acct(i);
        _reserve(b, a, bound(amount, 10e6, 2_000e6));
    }

    /// @dev One reservation, and the cap checked the moment it lands: lent principal plus resting cash against the credit's cap.
    function _reserve(address b, LockAccount a, uint256 amount) internal returns (bytes32) {
        vm.prank(b);
        try vault.reserve(amount) returns (bytes32 id, uint256) {
            ++reserves;
            if (lentOf[address(a)] != 0) ++reservesWhileLent;
            if (!seen[id]) {
                seen[id] = true;
                marketsOf[address(a)].push(id);
                ++newMarkets;
            }
            maxPriceOf[address(a)] = Math.max(maxPriceOf[address(a)], ace.idToMarketParams(id).price);
            uint256 exposure = lentOf[address(a)] + _resting(address(a));
            uint256 units = Math.saturatingSub(vault.creditOf(address(a)), a.spent());
            uint256 cap = units <= 1 ? 0 : Math.mulDiv(units - 1, maxPriceOf[address(a)], LINE);
            if (exposure > cap) capBroken = true;
            return id;
        } catch {}
        return 0;
    }

    /// @dev Draw from the account's reservation, reserving its whole room first when nothing rests, so loans are often out.
    function draw(uint256 i, uint256 principal) external tokenStays {
        (address b, LockAccount a) = _acct(i);
        (bytes32 id,) = vault.reservationOf(address(a));
        if (id == 0 || ace.restingOf(id) < 10e6) id = _reserve(b, a, type(uint256).max);
        uint256 resting = id == 0 ? 0 : ace.restingOf(id);
        if (resting < 10e6) return;
        principal = bound(principal, 10e6, resting);
        uint256 units = Math.mulDiv(principal, LINE, ace.idToMarketParams(id).price, Math.Rounding.Ceil) + 1;
        vm.prank(b);
        try a.borrow(id, units, principal, 30 days, OpenBounds(0, 0, 0)) returns (uint256 loanId) {
            ++draws;
            loans.push(loanId);
            (acctOf[loanId], principalOf[loanId]) = (address(a), principal);
            lentOf[address(a)] += principal;
        } catch {}
    }

    function repay(uint256 j) external tokenStays {
        if (loans.length == 0) return;
        uint256 loanId = loans[j % loans.length];
        if (ace.isClosed(loanId)) return;
        uint256 debt = ace.debtOf(loanId);
        usdc.mint(address(this), debt);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        LockAccount(acctOf[loanId]).reclaim(loanId);
        lentOf[acctOf[loanId]] -= principalOf[loanId];
        ++closes;
    }

    function forfeit(uint256 j) external tokenStays {
        if (loans.length == 0) return;
        uint256 loanId = loans[j % loans.length];
        if (ace.isClosed(loanId)) return;
        _warpAtLeastTo(read.loan(loanId).expiry);
        ace.forceClose(loanId);
        vault.redeem(loanId);
        LockAccount(acctOf[loanId]).reclaim(loanId);
        lentOf[acctOf[loanId]] -= principalOf[loanId];
        ++closes;
    }

    function donate(uint256 i, uint256 units) external tokenStays {
        (, LockAccount a) = _acct(i);
        strat.send(address(token), address(a), bound(units, 1, 10_000e18));
    }

    function release(uint256 i, uint256 units) external tokenStays {
        (address b, LockAccount a) = _acct(i);
        uint256 free = a.releasable();
        if (free == 0) return;
        vm.prank(b);
        a.release(bound(units, 1, free));
    }

    function recall(uint256 i) external tokenStays {
        (, LockAccount a) = _acct(i);
        _warpBy(1 hours);
        try vault.recall(address(a)) {} catch {}
    }

    /// @dev Re-price: the window moves to a token tick around clearing, so the next reservation may be a new market.
    function move(int256 dt) external tokenStays {
        int24 t = int24(bound(dt, -3_000, 1_000)) + cTick;
        int24 p = address(token) < address(usdc) ? t : -t - 1;
        vm.mockCall(address(vault.HOOK()), abi.encodeCall(RunwayHook.windowOf, (key.toId())), abi.encode(p, p, p));
    }

    function warp(uint256 s) external tokenStays {
        _warpBy(bound(s, 1, 2 days));
    }

    function deposit(uint256 i, uint256 amount) external tokenStays {
        address h = holders[i % 3];
        amount = bound(amount, 1, 1_000e6);
        usdc.mint(h, amount);
        vm.startPrank(h);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount) {} catch {}
        vm.stopPrank();
    }

    function exit(uint256 i, uint256 shares) external {
        address h = holders[i % 3];
        uint256 mine = vault.sharesOf(h);
        if (mine == 0) return;
        vm.prank(h);
        try vault.exit(bound(shares, 1, mine), h) {} catch {}
    }

    // ---- reads for the invariants ----

    /// @dev Cash resting across every market the account ever reserved.
    function _resting(address acct) internal view returns (uint256 sum) {
        bytes32[] storage ms = marketsOf[acct];
        for (uint256 k; k < ms.length; ++k) {
            sum += ace.restingOf(ms[k]);
        }
    }

    /// @dev Cash resting outside the account's current reservation; zero when one market holds it all.
    function strayResting(uint256 i) external view returns (uint256) {
        (, LockAccount a) = _acct(i);
        (bytes32 id,) = vault.reservationOf(address(a));
        return _resting(address(a)) - (id == 0 ? 0 : ace.restingOf(id));
    }
}

/// @title LaunchVaultInvariantTest
/// @notice The vault's invariants under any sequence of the lending term, with two credited buyers and three holders.
/// @notice Each buyer's exposure stays inside maxPrincipal(credit - spent) at its highest price; one market per account holds cash.
/// @notice No share mints once lending opens, shares add up, the booked fee stays backed, and the launch token leaves only by exit.
contract LaunchVaultInvariantTest is LaunchVaultFixture {
    LaunchVaultCapHandler internal h;
    address internal dave = address(0xDA7E);
    uint256 internal sharesAtOpen;

    function setUp() public override {
        super.setUp();
        _buy(alice, SPEND);
        _buy(bob, 3 * SPEND);
        _deposit(vault, carol, 3_000e6);
        _deposit(vault, dave, 2_000e6);
        _goLive(m);
        _warpTo(_openAt(m));
        sharesAtOpen = vault.totalShares();
        h = new LaunchVaultCapHandler(ace, vault, usdc, m.lock, strat, m.key, [alice, bob], [carol, dave, stranger]);
        targetContract(address(h));
    }

    /// @notice D8: at every reserve, an account's lent principal plus its resting cash is within maxPrincipal(credit - spent) at its top price.
    function invariant_TheCapHeldAtEveryReserve() public view {
        assertFalse(h.capBroken(), "an account's exposure passed its credit's cap");
    }

    /// @notice At most one market per account holds this vault's cash: the reservation's.
    function invariant_OneMarketPerAccountHoldsCash() public view {
        assertEq(h.strayResting(0) + h.strayResting(1), 0, "cash rests outside an account's reservation");
    }

    /// @notice Once lending opens no share mints: the window is shut and the supply only falls.
    function invariant_NoEntryOnceLending() public view {
        assertFalse(vault.depositing(), "the window reopened");
        assertLe(vault.totalShares(), sharesAtOpen, "a share minted after the window");
    }

    /// @notice The holders' shares are the whole supply.
    function invariant_SharesAddUp() public view {
        assertEq(vault.sharesOf(carol) + vault.sharesOf(dave) + vault.sharesOf(stranger), vault.totalShares(), "shares do not add up");
    }

    /// @notice The booked fee is always held.
    function invariant_TheFeeIsBacked() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.feeOwed(), "the vault holds less than the fee it booked");
    }

    /// @notice The launch token leaves the vault through `exit` alone.
    function invariant_TheTokenLeavesOnlyByExit() public view {
        assertFalse(h.tokenLeftOutsideExit(), "the launch token left the vault outside an exit");
    }

    /// @notice The campaign's reach: the cap is only tested where reservations land, above all while a loan is out.
    function afterInvariant() public view {
        console2.log("=== LaunchVaultCapHandler verb hits");
        console2.log("calls", h.calls());
        console2.log("reserves", h.reserves());
        console2.log("reserves while lent", h.reservesWhileLent());
        console2.log("new markets", h.newMarkets());
        console2.log("draws", h.draws());
        console2.log("closes", h.closes());
    }
}

/// @title LaunchVaultSequenceTest
/// @notice The review's own sequence for the per-account cap, step by step, and a conservation fuzz over a whole term.
contract LaunchVaultSequenceTest is LaunchVaultFixture {
    address internal dave = address(0xDA7E);

    /// @dev An account's exposure in this vault and its cap: lent principal plus resting cash, against maxPrincipal(credit - spent).
    function _exposure(LockAccount a, uint256 lent, uint256 price) internal view returns (uint256 exposure, uint256 cap) {
        (bytes32 id,) = vault.reservationOf(address(a));
        exposure = lent + (id == 0 ? 0 : ace.restingOf(id));
        cap = _maxPrincipal(vault.creditOf(address(a)) - a.spent(), price);
    }

    /// @notice D8's sequence: donate, reserve, release, re-reserve, draw. The cap holds after each, and the donation buys nothing.
    function test_TheCapHoldsThroughDonateReserveReleaseRereserveDraw() public {
        LockAccount a = _ready();
        uint256 p = vault.quote();
        strat.send(m.token, address(a), 50_000e18); // donate
        (bytes32 id, uint256 r1) = _reserve(vault, alice, type(uint256).max); // reserve
        (uint256 e, uint256 cap) = _exposure(a, 0, p);
        assertEq(r1, cap, "the first reservation is not the whole cap");
        assertLe(e, cap, "the reserve passed the cap");
        _warpTo(m.launchBy + 30 days);
        vm.prank(alice);
        a.release(_filled(SPEND) / 3); // release
        (e, cap) = _exposure(a, 0, p);
        assertGt(e, cap, "fixture: the release left the resting cash over the shrunk cap");
        vm.prank(alice);
        vm.expectRevert(LaunchVault.BelowMinDebt.selector);
        vault.reserve(type(uint256).max); // re-reserve: nothing more rests
        uint256 principal = ace.restingOf(id) / 2;
        uint256 loanId = _borrow(m, alice, id, principal, 30 days); // draw
        (e,) = _exposure(a, principal, p);
        assertEq(e, r1, "the draw moved the exposure");
        _warpBy(1 hours);
        vault.recall(address(a));
        (e, cap) = _exposure(a, principal, p);
        assertLe(e, cap + _maxPrincipal(_filled(SPEND) / 3 + 1, p), "the recall left more than the released units' worth");
        assertGt(loanId, 0, "fixture: the draw opened a loan");
    }

    /// @notice The cap's hard case: a draw at a low quote, then a re-price up and a reservation while the loan is out.
    /// @notice The new market rests only what the units left after the pledge buy at the higher price, inside the cap at it.
    function test_TheCapHoldsAcrossARepriceWhileLent() public {
        LockAccount a = _ready();
        _flat(m, _clearTick() - 1_500);
        uint256 low = vault.quote();
        (bytes32 id, uint256 r1) = _reserve(vault, alice, type(uint256).max);
        _borrow(m, alice, id, r1 / 2, 30 days);
        _flat(m, _clearTick() + 1_000);
        uint256 high = vault.quote();
        assertGt(high, low, "fixture: the quote rose");
        (bytes32 id2, uint256 r2) = _reserve(vault, alice, type(uint256).max);
        assertTrue(id2 != id, "fixture: a new market");
        assertEq(ace.restingOf(id), 0, "the low market kept its cash");
        assertEq(r2, _maxPrincipal(_creditFor(SPEND) - a.pledged(), high), "the second reservation is not the unpledged units' room");
        (uint256 e, uint256 cap) = _exposure(a, r1 / 2, high);
        assertLe(e, cap, "lent plus resting passed the cap at the top price");
    }

    /// @notice Over a whole term with random buyers, holders, outcomes and a donation, nothing is made or lost:
    /// @notice the vault's USDC at home is deposits plus donation plus each loan's lender fee, less each forfeited principal;
    /// @notice every forfeited unit comes home and goes out; the exits pay out all but the booked fee, each pro rata.
    function testFuzz_ConservationThroughAWholeTerm(uint64 spendA, uint64 spendB, uint64 cashC, uint64 cashD, uint8 outcomes, uint64 gift) public {
        (spendA, spendB) = (uint64(bound(spendA, 20e6, 5_000e6)), uint64(bound(spendB, 20e6, 5_000e6)));
        (cashC, cashD) = (uint64(bound(cashC, 1e6, 10_000e6)), uint64(bound(cashD, 1e6, 10_000e6)));
        gift = uint64(bound(gift, 0, 1_000e6));
        _buy(alice, spendA);
        _buy(bob, spendB);
        _deposit(vault, carol, cashC);
        _deposit(vault, dave, cashD);
        usdc.mint(address(vault), gift);
        _goLive(m);
        _warpTo(_openAt(m));
        int256 pnl = int256(uint256(gift));
        uint256 pots;
        address[2] memory buyers = [alice, bob];
        uint256[2] memory loanIds;
        for (uint256 i; i < 2; ++i) {
            vm.prank(buyers[i]);
            try vault.reserve(type(uint256).max) returns (bytes32 id, uint256 got) {
                loanIds[i] = _borrow(m, buyers[i], id, got, 30 days);
                pnl += int256(LoanMath.lenderCut(LoanMath.originationFee(got, 30 days, BASE, 7 days)));
            } catch {}
        }
        for (uint256 i; i < 2; ++i) {
            if (loanIds[i] == 0) continue;
            _warpAtLeastTo(read.loan(loanIds[i]).expiry - 1);
            if ((outcomes >> i) & 1 == 0) {
                pnl -= int256(read.earlyExitRefund(loanIds[i]));
                _repay(loanIds[i]);
            } else {
                _warpAtLeastTo(read.loan(loanIds[i]).expiry);
                pnl -= int256(read.principalOf(loanIds[i]));
                uint256 units = read.loan(loanIds[i]).collateralUnits;
                ace.forceClose(loanIds[i]);
                assertEq(vault.redeem(loanIds[i]), units, "a forfeit's pot is not the loan's whole pledge");
                pots += units;
            }
        }
        assertTrue(vault.isHome(), "the vault is not home after every loan closed");
        uint256 deposits = uint256(cashC) + cashD;
        assertEq(int256(usdc.balanceOf(address(vault))), int256(deposits) + pnl, "the vault's USDC is not deposits plus the term's lender P&L");
        assertEq(IERC20(m.token).balanceOf(address(vault)), pots, "the forfeits did not all come home");
        _exitAndCheck(carol, cashC, deposits);
        _exitAndCheck(dave, cashD, cashD);
        assertEq(usdc.balanceOf(address(vault)), vault.feeOwed(), "USDC past the fee was stranded");
        assertEq(IERC20(m.token).balanceOf(address(vault)), 0, "a token was stranded");
    }

    /// @dev `who` exits all `shares` of a `total` supply: pro rata of what the vault holds, the fee a tenth of any USDC gain over the shares.
    function _exitAndCheck(address who, uint256 shares, uint256 total) internal {
        uint256 cash = usdc.balanceOf(address(vault)) - vault.feeOwed();
        uint256 held = IERC20(m.token).balanceOf(address(vault));
        uint256 fee0 = vault.feeOwed();
        vm.prank(who);
        (uint256 assets, uint256 units) = vault.exit(shares, who);
        uint256 out = Math.mulDiv(cash, shares, total);
        uint256 fee = out > shares ? (out - shares) / 10 : 0;
        assertEq(abi.encode(assets, vault.feeOwed() - fee0), abi.encode(out - fee, fee), "the exit's USDC or fee");
        assertEq(units, Math.mulDiv(held, shares, total), "the exit's tokens are not pro rata");
    }
}
