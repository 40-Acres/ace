// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {VaultConfig} from "../../src/curator/AceVault.sol";

/// @notice The sender hook an ERC-777 `tokensToSend` gives an attacker: it fires BEFORE balances move.
/// @dev That timing is the point: OZ transfers before it mints so this instant sees neither side.
contract PreHookERC20 {
    string public name = "Hooked";
    string public symbol = "HOOK";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public hookTarget; // only a transfer FROM this address calls back

    function setHookTarget(address who) external {
        hookTarget = who;
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from == hookTarget) ISender(from).tokensToSend(amount); // BEFORE the balances move
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface ISender {
    function tokensToSend(uint256 amount) external;
}

/// @notice The hub reads the vault's constructor and `grossNav` need, and nothing else.
/// @dev A market-less vault holds `g == m` invariantly, so no vest can ever form in one.
/// @dev The vest is what separates the real fix from a partial one, so the mock exists to grow NAV hub-side.
contract MockLenderOps {
    /// @dev KEYED BY (lender, quote), not by market: the hub pools a lender's aggregates across their markets.
    mapping(address => mapping(address => uint256)) public lenderAssets;
    address public constant POSITION_MANAGER = address(0); // the constructor reads it; nothing here pledges
    address public constant POSITION_TITLE = address(0); // likewise; nothing here hands a title over

    function setLenderAssets(address lender, address quote, uint256 v) external {
        lenderAssets[lender][quote] = v;
    }

    /// @dev The entry gate's read: this mock settles nothing, so no pot is ever unsold.
    function lenderUnresolved(address, address) external pure returns (uint256 unsoldPots, uint256 settledPots) {
        return (0, 0);
    }
}

/// @notice The attacker: it deposits, and prices the vault from inside its own send hook.
contract HookedDepositor is ISender {
    CuratorVault public vault;
    PreHookERC20 public token;
    uint256 public navInside;
    uint256 public supplyInside;
    uint256 public priceInside; // assets per 1e12 shares, so the figure is readable

    constructor(CuratorVault v, PreHookERC20 t) {
        vault = v;
        token = t;
    }

    function tokensToSend(uint256) external {
        navInside = vault.totalAssets();
        supplyInside = vault.totalSupply();
        priceInside = vault.convertToAssets(1e12);
    }

    function go(uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount, address(this));
    }
}

/// @notice The same entry as `HookedDepositor`, pinning the WHOLE read surface rather than the price alone.
/// @dev The price cannot see the partial that counts the cash above the transfer and moves the NAV mark below it.
/// @dev That drives the `g > m` branch, whose deduction grows by exactly the deposit, so `totalAssets` reads right.
/// @dev The OPPOSITE partial DOES move the price, via `g < m`, and the live-vest row above is what catches it.
/// @dev `idle()` and `grossNav()` carry no such absorber, so they are what holds the pair together.
contract SurfaceDepositor is ISender {
    CuratorVault public vault;
    PreHookERC20 public token;
    uint256 public idleInside;
    uint256 public grossInside;
    uint256 public navInside;
    uint256 public supplyInside;
    uint256 public priceInside;

    constructor(CuratorVault v, PreHookERC20 t) {
        vault = v;
        token = t;
    }

    function tokensToSend(uint256) external {
        idleInside = vault.idle();
        grossInside = vault.grossNav();
        navInside = vault.totalAssets();
        supplyInside = vault.totalSupply();
        priceInside = vault.convertToAssets(1e12);
    }

    function go(uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount, address(this));
    }
}

interface IPayee {
    function onPay(uint256 amount) external;
}

/// @notice The exit-side mirror: its `transfer` calls the RECEIVER before balances move.
/// @dev `_exit` pays out with `safeTransfer`, so this is the hook an exiting holder could install.
contract PayHookERC20 {
    string public name = "Payhook";
    string public symbol = "PHK";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public hookTarget; // only a transfer TO this address calls back

    function setHookTarget(address who) external {
        hookTarget = who;
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
        if (to == hookTarget) IPayee(to).onPay(amount); // BEFORE the balances move
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice A holder that prices the vault from inside the payout it is being sent.
contract PayObserver is IPayee {
    CuratorVault public vault;
    PayHookERC20 public token;
    uint256 public idleInside;
    uint256 public grossInside;
    uint256 public navInside;
    uint256 public supplyInside;
    uint256 public priceInside;

    constructor(CuratorVault v, PayHookERC20 t) {
        vault = v;
        token = t;
    }

    function onPay(uint256) external {
        idleInside = vault.idle();
        grossInside = vault.grossNav();
        navInside = vault.totalAssets();
        supplyInside = vault.totalSupply();
        priceInside = vault.convertToAssets(1e12);
    }

    function enter(uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount, address(this));
    }

    /// @dev The claim path: the shares are escrowed here, and `claim` is what pays them.
    function request(uint256 shares) external {
        vault.requestExit(shares);
    }

    function claim(uint256 shares) external {
        vault.claimExit(shares, address(this), 0);
    }

    function leave(uint256 shares) external {
        vault.redeem(shares, address(this), address(this));
    }
}

/// @title CuratorVaultDepositWindow
/// @notice Pins the deposit window shut: a pre-transfer sender hook must not see an inflated share price.
/// @notice The defect it reproduces credited the vault's cash and `_navMark` ahead of `super._deposit`.
/// @notice The cash is the vault's own asset balance now, which moves only with the transfer, and the mark keeps the same ordering rule.
/// @dev OZ states that invariant itself, in an inline comment inside the `_deposit` this one overrides.
/// @dev NO MARKETS HERE, deliberately: with the hub mock answering zero, `grossNav()` is the vault's balance alone.
/// @dev That isolates the window from the hub, and from the guard already covering the hub direction.
contract CuratorVaultDepositWindowTest is WarpClock {
    PreHookERC20 internal token;
    CuratorVault internal v;
    address internal curator = address(0xC0A11);
    address internal alice = address(0xA11CE);

    /// @dev A vault over the hub mock, listing nothing.
    function _vault(VaultConfig memory cfg) internal returns (CuratorVault) {
        return new CuratorVault(cfg, 10e6, 1.4e18, 1 days, new Listing[](0), "Curator", "cVLT");
    }

    function setUp() public {
        token = new PreHookERC20();
        /// @dev A REAL MOCK RATHER THAN `address(0xACE)`: `grossNav` reads the hub's pooled figure on every
        /// @dev call, so a bare address is a call to a non-contract. The mock answers zero, which isolates the window.
        VaultConfig memory cfg =
            VaultConfig({ace: address(new MockLenderOps()), asset: address(token), curator: curator, guardian: address(0), perfFeeBps: 0, vestWindow: 1 days});
        v = _vault(cfg);
    }

    /// @notice THE SAFE PROPERTY: a deposit in flight must not move the share price a reader can see.
    /// @dev The defect it reproduces credited the counter a statement before the transfer was attempted.
    function test_Deposit_DoesNotInflateTheSharePriceMidTransfer() public {
        token.mint(alice, 1_000e6);
        vm.startPrank(alice);
        token.approve(address(v), 1_000e6);
        v.deposit(1_000e6, alice);
        vm.stopPrank();

        uint256 priceBefore = v.convertToAssets(1e12);
        uint256 navBefore = v.totalAssets();
        uint256 supplyBefore = v.totalSupply();

        HookedDepositor att = new HookedDepositor(v, token);
        token.mint(address(att), 1_000_000e6);
        token.setHookTarget(address(att));
        att.go(1_000_000e6);

        emit log_named_uint("nav   outside the hook", navBefore);
        emit log_named_uint("nav   INSIDE  the hook", att.navInside());
        emit log_named_uint("supply INSIDE the hook", att.supplyInside());
        emit log_named_uint("price outside the hook", priceBefore);
        emit log_named_uint("price INSIDE  the hook", att.priceInside());

        assertEq(att.supplyInside(), supplyBefore, "PREMISE: the entrant's shares are not minted yet");
        assertEq(att.priceInside(), priceBefore, "a reader mid-deposit must see the price a reader outside sees");
    }

    /// @notice THE SAME PROPERTY UNDER A LIVE VEST, which is what tells the fix from half of it.
    /// @notice The two counters are one unit: `_pendingUnvested` reads gross AGAINST the mark, never either alone.
    /// @dev With no vest both branches of that read return zero, so the row above passes even under a HALF fix.
    /// @dev A half fix funds the line alone, driving the `g < m` branch and shrinking the deduction.
    /// @dev Same corruption, opposite sign, and it heals the instant the transfer returns -- so only this row sees it.
    function test_Deposit_DoesNotInflateTheSharePriceMidTransfer_WithALiveVest() public {
        MockLenderOps hub = new MockLenderOps();
        VaultConfig memory cfg =
            VaultConfig({ace: address(hub), asset: address(token), curator: curator, guardian: address(0), perfFeeBps: 0, vestWindow: 1 days});
        CuratorVault vv = _vault(cfg);

        token.mint(alice, 1_001e6);
        vm.startPrank(alice);
        token.approve(address(vv), 1_001e6);
        vv.deposit(1_000e6, alice);
        vm.stopPrank();

        hub.setLenderAssets(address(vv), address(token), 40e6); // hub-side growth, the only way a vest can form; 4% of NAV, under the pile gate
        vm.prank(alice);
        vv.deposit(1e6, alice); // its `_sync` stamps that growth as the vest

        assertGt(vv.unvested(), 0, "PREMISE: the vest must be live, or this row cannot tell the two fixes apart");
        uint256 priceBefore = vv.convertToAssets(1e12);

        HookedDepositor att = new HookedDepositor(vv, token);
        token.mint(address(att), 1_000_000e6);
        token.setHookTarget(address(att));
        att.go(1_000_000e6);

        emit log_named_uint("unvested", vv.unvested());
        emit log_named_uint("price outside the hook", priceBefore);
        emit log_named_uint("price INSIDE  the hook", att.priceInside());

        assertEq(att.priceInside(), priceBefore, "a live vest must not let a mid-deposit reader see another price");
    }

    /// @notice THE PAIR, PINNED FROM THE OTHER SIDE: `idle` and gross must be as still as the price is.
    /// @notice The price rows above cannot see the MIRROR half fix, which counts the cash alone above the transfer.
    /// @dev That split drives the `g > m` branch, which defers exactly the deposit and hands the price back intact.
    /// @dev So the whole entry surface reads right while two published counters carry cash the vault has not received.
    /// @dev `maxWithdraw` and `maxRedeem` ride on idle directly, so an integrator would over-quote the exit.
    function test_Deposit_LeavesTheWholeReadSurfaceStillMidTransfer() public {
        token.mint(alice, 1_000e6);
        vm.startPrank(alice);
        token.approve(address(v), 1_000e6);
        v.deposit(1_000e6, alice);
        vm.stopPrank();

        uint256 idleBefore = v.idle();
        uint256 grossBefore = v.grossNav();
        uint256 navBefore = v.totalAssets();
        uint256 supplyBefore = v.totalSupply();
        uint256 priceBefore = v.convertToAssets(1e12);

        SurfaceDepositor att = new SurfaceDepositor(v, token);
        token.mint(address(att), 1_000_000e6);
        token.setHookTarget(address(att));
        att.go(1_000_000e6);

        emit log_named_uint("idle  INSIDE  the hook", att.idleInside());
        emit log_named_uint("gross INSIDE  the hook", att.grossInside());

        assertEq(att.supplyInside(), supplyBefore, "PREMISE: the entrant's shares are not minted yet");
        assertEq(att.idleInside(), idleBefore, "idle must not count cash the vault has not received");
        assertEq(att.grossInside(), grossBefore, "and gross must not count it either");
        assertEq(att.navInside(), navBefore, "so NAV mid-deposit is the NAV a reader outside sees");
        assertEq(att.priceInside(), priceBefore, "and the price with it");
    }

    /// @notice POST-TRANSACTION: the mark rises with the cash, so the next sync reads a depositor's principal as cash.
    /// @notice Without that credit gross outruns the mark by the deposit, and the next sync vests the principal to everyone.
    /// @dev `totalAssets` replays that sync, so the corruption is readable before any further verb runs.
    /// @dev The rows above only observe MID-transfer, where the missing credit has not been reached yet.
    function test_Deposit_CreditsTheMarkSoPrincipalIsNeverStampedAsGrowth() public {
        token.mint(alice, 2_000e6);
        vm.startPrank(alice);
        token.approve(address(v), 2_000e6);

        v.deposit(1_000e6, alice);
        assertEq(v.totalAssets(), 1_000e6, "the deposit is NAV in full and at once, never a deferred gain");
        assertEq(v.unvested(), 0, "and none of it is growth, so none of it defers");

        v.deposit(1_000e6, alice);
        vm.stopPrank();

        assertEq(v.totalAssets(), 2_000e6, "the second lands the same way, with no sync stamping the first as a gain");
        assertEq(v.unvested(), 0, "the mark kept pace, so the sync that verb ran still saw no growth");
    }

    /// @notice THE EXIT SIDE'S CASH READS ARE OUT OF MODEL, and this row pins where the model ends: the asset must be hookless.
    /// @notice Idle and gross count the raw asset balance, so a receiver hook firing BEFORE balances move sees the pre-payout cash.
    /// @notice The share price does not move: the mark is lowered before the transfer, so the view replays the unmoved cash as a pending rise.
    /// @dev The vault's header requires a hookless asset for exactly this reason; the cash views are defined only for a hookless one.
    function test_Exit_AHookedAssetShowsAMidPayoutReaderThePrePayoutCash() public {
        PayHookERC20 t2 = new PayHookERC20();
        VaultConfig memory cfg =
            VaultConfig({ace: address(new MockLenderOps()), asset: address(t2), curator: curator, guardian: address(0), perfFeeBps: 0, vestWindow: 1 days});
        CuratorVault vv = _vault(cfg);

        t2.mint(alice, 1_000e6);
        vm.startPrank(alice);
        t2.approve(address(vv), 1_000e6);
        vv.deposit(1_000e6, alice);
        vm.stopPrank();

        PayObserver obs = new PayObserver(vv, t2);
        t2.mint(address(obs), 1_000e6);
        obs.enter(1_000e6);

        uint256 priceBefore = vv.convertToAssets(1e12);
        uint256 supplyBefore = vv.totalSupply();
        uint256 idleBefore = vv.idle();
        uint256 burning = vv.balanceOf(address(obs)) / 2;
        obs.request(burning); // no cash moves here, so the hook is not armed until the claim below
        t2.setHookTarget(address(obs));
        obs.claim(burning); // the claim path; the instant path's twin is `CuratorVaultInstantPayoutReader`

        emit log_named_uint("price before the exit", priceBefore);
        emit log_named_uint("price INSIDE the payout", obs.priceInside());

        assertEq(obs.supplyInside(), supplyBefore - burning, "PREMISE: the shares are already burnt when the cash moves");
        assertEq(obs.idleInside(), idleBefore, "OUT OF MODEL: idle mid-payout is the raw balance, which has not moved yet");
        assertGt(obs.grossInside(), vv.grossNav(), "and gross with it, past the state the payout leaves");
        assertEq(obs.navInside(), vv.totalAssets(), "while NAV mid-payout is already the NAV the payout leaves");
        assertEq(obs.priceInside(), vv.convertToAssets(1e12), "and so is the price");
        assertApproxEqAbs(obs.priceInside(), priceBefore, 1, "and a pro-rata exit moves no price at all");
    }
}
