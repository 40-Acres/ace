// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";
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

/// @title LaunchVaultLedgerHandler
/// @notice Drives a whole lending term in any order, exits and fee claims included, and keeps the vault's USDC ledger from the hub's own terms.
/// @notice The vault's position is its balance plus `lenderAssets`; each verb is checked for what it may do to it.
contract LaunchVaultLedgerHandler is WarpClock {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant LINE = (1 << 96) * 125 / 100; // the hub's coverage line divisor, k = 1.25 in the Q96 frame

    Ace internal ace;
    AceReader internal read;
    LaunchVault internal vault;
    MockERC20 internal usdc;
    IERC20 internal token;
    LaunchLock internal lock;
    PoolKey internal key;
    address internal curator;
    uint16 internal baseBps;
    int24 internal cTick;
    address[2] internal who;
    address[3] internal holders;
    uint256[] internal loans;
    mapping(uint256 loanId => address) internal acctOf;

    uint256 public inflow; // USDC that entered the vault's position from outside: the deposits at open, then donations
    uint256 public outflow; // USDC that left it to holders and the curator: exits and claims
    int256 public pnl; // the lender result the hub's own terms predict: lender cuts in, early-exit refunds and forfeited principal out

    bool public neutralBroken; // a reserve, recall, redeem or stop moved the vault's USDC position
    bool public exitBroken; // an exit paid other than it moved, booked a fee off the spec, or diluted the holders who stayed
    bool public claimBroken; // a claim paid other than the booked fee, or to other than the curator

    uint256 public reserves;
    uint256 public recalls;
    uint256 public draws;
    uint256 public closes;
    uint256 public exits;
    uint256 public claims;
    uint256 public homes; // actions that found the vault home

    constructor(Ace ace_, LaunchVault vault_, MockERC20 usdc_, PoolKey memory key_, address[2] memory who_, address[3] memory holders_) {
        (ace, read, vault, usdc, key) = (ace_, new AceReader(address(ace_)), vault_, usdc_, key_);
        LaunchVault.Terms memory t = vault_.terms();
        (token, lock, curator, baseBps) = (IERC20(t.token), t.lock, t.curator, t.baseBps);
        (who, holders) = (who_, holders_);
        cTick = TickMath.getTickAtSqrtPrice(SetValue.sqrtPriceX96(t.auction.checkpoints(t.auction.endBlock()).clearingPrice, false));
        inflow = usdc_.balanceOf(address(vault_));
    }

    /// @dev The vault's USDC position: what it holds, plus what rests, is lent and is owed it in the hub.
    function position() public view returns (uint256) {
        return usdc.balanceOf(address(vault)) + ace.lenderAssets(address(vault), address(usdc));
    }

    /// @dev The lender's unearned fee escrow on every vault loan still open: lender money the hub holds outside the pools until a close.
    function openEscrow() public view returns (uint256 sum) {
        for (uint256 i; i < loans.length; ++i) {
            if (!ace.isClosed(loans[i])) sum += read.feeEscrowOf(loans[i]);
        }
    }

    function _acct(uint256 i) internal view returns (address b, LockAccount a) {
        b = who[i % 2];
        a = LockAccount(lock.predict(b, 0));
    }

    // ---- vault verbs that may move no USDC position ----

    function reserve(uint256 i, uint256 amount) external {
        (address b,) = _acct(i);
        _reserve(b, bound(amount, 10e6, 2_000e6));
    }

    function _reserve(address b, uint256 amount) internal returns (bytes32 id) {
        uint256 p0 = position();
        vm.prank(b);
        try vault.reserve(amount) returns (bytes32 got, uint256) {
            id = got;
            ++reserves;
            if (position() != p0) neutralBroken = true;
        } catch {}
    }

    function recall(uint256 i) external {
        (, LockAccount a) = _acct(i);
        _warpBy(1 hours);
        uint256 p0 = position();
        try vault.recall(address(a)) {
            ++recalls;
            if (position() != p0) neutralBroken = true;
        } catch {}
    }

    function stop(uint256 i) external {
        if (i % 64 != 0) return;
        uint256 p0 = position();
        vm.prank(curator);
        vault.stop();
        if (position() != p0) neutralBroken = true;
    }

    // ---- the hub's side: draws, repays, forfeits, each booked to pnl by the hub's own terms ----

    /// @dev Draw from the account's reservation, reserving its whole room first when too little rests, so loans are often out.
    /// @dev Tenors run 7 to 30 days, so a forfeit's warp to expiry leaves most of the lending term for more draws.
    function draw(uint256 i, uint256 principal, uint256 tenor) external {
        (address b, LockAccount a) = _acct(i);
        (bytes32 id,) = vault.reservationOf(address(a));
        if (id == 0 || ace.restingOf(id) < 10e6) id = _reserve(b, type(uint256).max);
        uint256 resting = id == 0 ? 0 : ace.restingOf(id);
        if (resting < 10e6) return;
        principal = bound(principal, 10e6, resting);
        uint64 term = uint64(bound(tenor, vault.MIN_TENOR(), vault.MAX_TENOR()));
        uint256 units = Math.mulDiv(principal, LINE, ace.idToMarketParams(id).price, Math.Rounding.Ceil) + 1;
        vm.prank(b);
        try a.borrow(id, units, principal, term, OpenBounds(0, 0, 0)) returns (uint256 loanId) {
            ++draws;
            loans.push(loanId);
            acctOf[loanId] = address(a);
            pnl += int256(LoanMath.lenderCut(LoanMath.originationFee(principal, term, baseBps, vault.MIN_TENOR())));
        } catch {}
    }

    function repay(uint256 j) external {
        if (loans.length == 0) return;
        uint256 loanId = loans[j % loans.length];
        if (ace.isClosed(loanId)) return;
        _repay(loanId);
    }

    function _repay(uint256 loanId) internal {
        uint256 refund = read.earlyExitRefund(loanId);
        uint256 debt = ace.debtOf(loanId);
        usdc.mint(address(this), debt);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        LockAccount(acctOf[loanId]).reclaim(loanId);
        pnl -= int256(refund);
        ++closes;
    }

    function forfeit(uint256 j) external {
        if (loans.length == 0) return;
        uint256 loanId = loans[j % loans.length];
        if (ace.isClosed(loanId)) return;
        _forfeit(loanId);
    }

    function _forfeit(uint256 loanId) internal {
        _warpAtLeastTo(read.loan(loanId).expiry);
        uint256 principal = read.principalOf(loanId);
        ace.forceClose(loanId);
        pnl -= int256(principal);
        uint256 p0 = position();
        vault.redeem(loanId);
        if (position() != p0) neutralBroken = true;
        LockAccount(acctOf[loanId]).reclaim(loanId);
        ++closes;
    }

    /// @dev Close every open loan, each repaid or forfeited by `bits`, and recall both accounts: the road home, so exits can land.
    function settleAll(uint256 bits) external {
        for (uint256 i; i < loans.length; ++i) {
            if (ace.isClosed(loans[i])) continue;
            if ((bits >> (i % 256)) & 1 == 0) _repay(loans[i]);
            else _forfeit(loans[i]);
        }
        _warpBy(1 hours);
        for (uint256 i; i < 2; ++i) {
            (, LockAccount a) = _acct(i);
            uint256 p0 = position();
            try vault.recall(address(a)) {
                if (position() != p0) neutralBroken = true;
            } catch {}
        }
    }

    // ---- the world ----

    function move(int256 dt) external {
        int24 t = int24(bound(dt, -3_000, 1_000)) + cTick;
        int24 p = address(token) < address(usdc) ? t : -t - 1;
        vm.mockCall(address(vault.HOOK()), abi.encodeCall(RunwayHook.windowOf, (key.toId())), abi.encode(p, p, p));
    }

    function warp(uint256 s) external {
        _warpBy(bound(s, 1, 12 hours));
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 500e6);
        usdc.mint(address(vault), amount);
        inflow += amount;
    }

    // ---- the verbs that pay out ----

    /// @dev An exit, checked against what it moved: the holder's USDC and tokens, the position, the spec's fee, and the stayers' per-share claim.
    function exit(uint256 i, uint256 shares) external {
        address h = holders[i % 3];
        uint256 mine = vault.sharesOf(h);
        if (mine == 0 || !vault.isHome()) return;
        ++homes;
        shares = bound(shares, 1, mine);
        uint256[5] memory b = [position(), vault.feeOwed(), vault.totalShares(), token.balanceOf(address(vault)), usdc.balanceOf(h)];
        uint256 tokensHeld = token.balanceOf(h);
        vm.prank(h);
        (uint256 assets, uint256 units) = vault.exit(shares, h);
        ++exits;
        outflow += assets;
        uint256 fee = vault.feeOwed() - b[1];
        if (usdc.balanceOf(h) != b[4] + assets || token.balanceOf(h) != tokensHeld + units) exitBroken = true;
        if (position() + assets != b[0] || token.balanceOf(address(vault)) + units != b[3]) exitBroken = true;
        if (fee != (assets + fee > shares ? assets + fee - shares : 0) / 10) exitBroken = true;
        uint256 s1 = vault.totalShares();
        if (s1 != b[2] - shares) exitBroken = true;
        if (s1 != 0 && (position() - vault.feeOwed()) * b[2] < (b[0] - b[1]) * s1) exitBroken = true;
        if (s1 != 0 && token.balanceOf(address(vault)) * b[2] < b[3] * s1) exitBroken = true;
    }

    function claim() external {
        uint256 owed = vault.feeOwed();
        uint256 p0 = position();
        uint256 c0 = usdc.balanceOf(curator);
        uint256 paid = vault.claimFee();
        ++claims;
        outflow += paid;
        if (paid != owed || vault.feeOwed() != 0 || usdc.balanceOf(curator) != c0 + paid || position() + paid != p0) claimBroken = true;
    }
}

/// @title LaunchVaultLedgerInvariantTest
/// @notice The vault's USDC ledger under any order of the term: its position plus what it paid out is what came in plus the lender result
/// @notice the hub's own terms predict, at every step; no verb but exit and claimFee moves the position, and those move exactly what they pay.
/// @dev The existing campaign checks the fee is held, never that the position is whole; this one prices every USDC flow independently.
contract LaunchVaultLedgerInvariantTest is LaunchVaultFixture {
    LaunchVaultLedgerHandler internal h;
    address internal dave = address(0xDA7E);

    function setUp() public override {
        super.setUp();
        _buy(alice, SPEND);
        _buy(bob, 3 * SPEND);
        _deposit(vault, carol, 3_000e6);
        _deposit(vault, dave, 2_000e6);
        _deposit(vault, stranger, 500e6);
        _goLive(m);
        _warpTo(_openAt(m));
        h = new LaunchVaultLedgerHandler(ace, vault, usdc, m.key, [alice, bob], [carol, dave, stranger]);
        targetContract(address(h));
    }

    /// @notice Position plus escrow still unearned plus paid out equals deposits plus donations plus the hub-priced lender result, exactly.
    function invariant_TheUsdcLedgerBalances() public view {
        int256 lhs = int256(h.position() + h.openEscrow() + h.outflow());
        assertEq(lhs, int256(h.inflow()) + h.pnl(), "the vault's USDC was made or lost outside the lender result");
    }

    /// @notice reserve, recall, redeem and stop move nothing of the vault's USDC position: they only move it between the vault and the hub.
    function invariant_VaultVerbsAreValueNeutral() public view {
        assertFalse(h.neutralBroken(), "a vault verb moved its USDC position");
    }

    /// @notice An exit pays the holder exactly what leaves the position, books a floored tenth of its gain, and never dilutes who stays.
    function invariant_ExitsPayWhatTheyMoveAndNeverDilute() public view {
        assertFalse(h.exitBroken(), "an exit paid off its books, or diluted the holders who stayed");
    }

    /// @notice A claim pays the curator exactly the booked fee and leaves none booked.
    function invariant_AClaimPaysExactlyTheBookedFee() public view {
        assertFalse(h.claimBroken(), "a claim paid other than the booked fee to the curator");
    }

    /// @notice The campaign's reach: exits only land home, so the tallies say how often the ledger was tested where it pays out.
    function afterInvariant() public view {
        console2.log("=== LaunchVaultLedgerHandler verb hits");
        console2.log("reserves", h.reserves());
        console2.log("recalls", h.recalls());
        console2.log("draws", h.draws());
        console2.log("closes", h.closes());
        console2.log("home at an exit", h.homes());
        console2.log("exits", h.exits());
        console2.log("claims", h.claims());
    }
}
