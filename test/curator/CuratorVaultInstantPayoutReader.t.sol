// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {VaultConfig} from "../../src/curator/AceVault.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";

interface IReaderPayee {
    function onPay(uint256 amount) external;
}

/// @notice An exit-side hook token: its `transfer` calls the receiver either before or after the balances move.
/// @dev A vault's asset must be hookless; the after-move hook stands for the latest instant a reader could see, the before-move one is out of model.
contract ReaderPayHookToken {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hookTarget; // only a transfer TO this address calls back
    bool public beforeMove; // whether the call back fires before the balances move

    function setHook(address who, bool before_) external {
        (hookTarget, beforeMove) = (who, before_);
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == hookTarget && beforeMove) IReaderPayee(to).onPay(amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to == hookTarget && !beforeMove) IReaderPayee(to).onPay(amount);
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
contract ReaderPayObserver is IReaderPayee {
    CuratorVault public vault;
    ReaderPayHookToken public token;
    uint256 public idleInside;
    uint256 public grossInside;
    uint256 public navInside;
    uint256 public supplyInside;
    uint256 public priceInside;

    constructor(CuratorVault v, ReaderPayHookToken t) {
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

    function leave(uint256 shares) external {
        vault.redeem(shares, address(this), address(this));
    }
}

/// @title CuratorVaultInstantPayoutReader
/// @notice The instant exit's payout in flight shows a reader only the state the call leaves: read-only reentrancy, on the default path.
/// @notice The vault's NAV reads its own asset balance, so the asset must be hookless; a hook firing before the balances move is out of model.
/// @dev `_exitNow` burns, books the cash (the high-water and the mark), then transfers: the hook fires on that transfer.
/// @dev Asserting against the POST-CALL reads is what makes it a CEI test: a booking moved below the transfer would split them.
contract CuratorVaultInstantPayoutReaderTest is CuratorVaultBase {
    /// @dev A vault on the hook token over the real hub, listing nothing: it never lends, so it needs no record on this pair.
    function _hooked() internal returns (CuratorVault vv, ReaderPayHookToken t2, ReaderPayObserver obs) {
        t2 = new ReaderPayHookToken();
        VaultConfig memory cfg = VaultConfig({ace: address(ace), asset: address(t2), curator: curator, guardian: address(0), perfFeeBps: 0, vestWindow: 1 days});
        vv = new CuratorVault(cfg, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, new Listing[](0), "Curator", "cVLT");
        t2.mint(alice, 1_000e6);
        vm.startPrank(alice);
        t2.approve(address(vv), 1_000e6);
        vv.deposit(1_000e6, alice);
        vm.stopPrank();
        obs = new ReaderPayObserver(vv, t2);
        t2.mint(address(obs), 1_000e6);
        obs.enter(1_000e6);
    }

    /// @notice A READER CALLED AT THE PAYOUT, after the balances move, sees exactly the state the exit leaves: bookings land first.
    function test_InstantExit_ShowsAMidPayoutReaderOnlyTheStateThePayoutLeaves() public {
        (CuratorVault vv, ReaderPayHookToken t2, ReaderPayObserver obs) = _hooked();
        uint256 priceBefore = vv.convertToAssets(1e12);
        uint256 supplyBefore = vv.totalSupply();
        uint256 burning = vv.balanceOf(address(obs)) / 2;
        t2.setHook(address(obs), false);
        obs.leave(burning); // `redeem` on the production vault: the instant exit, paid in this one call

        assertEq(t2.balanceOf(address(obs)), 500e6, "PREMISE: the instant exit paid at once");
        assertEq(obs.supplyInside(), supplyBefore - burning, "PREMISE: the shares are already burnt when the cash moves");
        assertEq(obs.idleInside(), vv.idle(), "idle mid-payout is the idle the payout leaves");
        assertEq(obs.grossInside(), vv.grossNav(), "and gross with it");
        assertEq(obs.navInside(), vv.totalAssets(), "so nothing about NAV settles after the token call");
        assertEq(obs.priceInside(), vv.convertToAssets(1e12), "the price mid-payout is the price it leaves behind");
        assertApproxEqAbs(obs.priceInside(), priceBefore, 1, "and a pro-rata exit moves no price at all");
    }

    /// @notice MEASURE, OUT OF MODEL: A HOOK FIRING BEFORE THE BALANCES MOVE sees the burnt supply beside cash that has not left yet.
    /// @notice Idle and gross read the payout still held, which is why the asset must be hookless.
    /// @notice The mark already fell by the payout, so `totalAssets` reads the excess as a vesting rise and the price does not tear.
    function test_Measure_APreMoveHookReadsTheCashBeforeItLeaves() public {
        (CuratorVault vv, ReaderPayHookToken t2, ReaderPayObserver obs) = _hooked();
        uint256 supplyBefore = vv.totalSupply();
        uint256 burning = vv.balanceOf(address(obs)) / 2;
        t2.setHook(address(obs), true);
        obs.leave(burning);

        uint256 paid = t2.balanceOf(address(obs));
        assertEq(paid, 500e6, "PREMISE: the instant exit paid at once");
        assertEq(obs.supplyInside(), supplyBefore - burning, "PREMISE: the shares are already burnt when the hook fires");
        assertEq(obs.idleInside(), vv.idle() + paid, "the pre-move reader did not see the payout still in the vault");
        assertEq(obs.grossInside(), vv.grossNav() + paid, "nor gross with it");
        assertEq(obs.navInside(), vv.totalAssets(), "totalAssets mid-payout is not the NAV the exit leaves");
        assertEq(obs.priceInside(), vv.convertToAssets(1e12), "the price mid-payout tore");
    }
}
