// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {VaultConfig} from "../../src/curator/AceVault.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";

/// @notice The exit request and the drain, named by selector so a row binds the surface and not the contract's ABI.
interface ICuratorVaultExits {
    error LastOutVesting();
    error RequestLive();
    error OverRequest();
    error ClaimUnderMin();
    error NoRequest();
    error Draining();

    event ExitRequested(address indexed holder, uint256 shares, uint64 expiresAt);
    event ExitReleased(address indexed holder, uint256 shares);
    event DrainSet(address indexed by, bool on);

    function REQUEST_LEASE() external view returns (uint64);
    function requestExit(uint256 shares) external;
    function cancelExit(uint256 shares) external;
    function lapseExit(address holder) external;
    function claimExit(uint256 shares, address receiver, uint256 minAssets) external returns (uint256 assets);
    function maxClaim(address holder) external view returns (uint256 shares);
    function requestOf(address holder) external view returns (uint256 shares, uint64 expiresAt);
    function requestedShares() external view returns (uint256);
    function setDrain(bool on) external;
    function draining() external view returns (bool);
}

/// @notice The rig for the exit-request and drain suites: a production vault with a guardian, and its holds.
abstract contract CuratorVaultExitsRig is CuratorVaultBase {
    uint256 internal constant V_OFF = 1e6; // the vault's virtual-share offset
    uint256 internal constant SEED = 10_000e6;
    uint64 internal constant LEASE = 30 days;
    address internal guardian = address(0x6A2D);
    address internal carol = address(0xCA201);
    address internal stranger = address(0x57A1);

    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event ExitRequested(address indexed holder, uint256 shares, uint64 expiresAt);
    event ExitReleased(address indexed holder, uint256 shares);
    event DrainSet(address indexed by, bool on);

    /// @dev The surface under test, cast so each row reads as a call on the vault.
    function _x(CuratorVault v) internal pure returns (ICuratorVaultExits) {
        return ICuratorVaultExits(address(v));
    }

    /// @dev A production vault, with a guardian, listing the rig collateral; `mid` is its door market.
    function _vault(uint16 fee) internal returns (CuratorVault v) {
        VaultConfig memory c = _cfg(fee);
        c.guardian = guardian;
        v = _deploy(c, "Exits", "cEXIT");
    }

    /// @dev Two equal LPs and `lent` drawn by one door loan, NAV flat once the open's own gain has vested.
    function _lent(uint256 lent) internal returns (CuratorVault v, uint256 loanId) {
        v = _vault(0);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        loanId = _borrow(v, lent);
        _crank(v, loanId, T2, 0);
        _warpBy(VEST_W);
        v.crank();
    }

    /// @dev The requests' hold now: exitable cash fenced for standing requests, zero while draining.
    function _heldReq(CuratorVault v) internal view returns (uint256 held) {
        (, held) = v.holds();
    }

    /// @dev Idle cash no exit may take is the roll hold; what is left is exitable.
    function _exitable(CuratorVault v) internal view returns (uint256 exitable) {
        (exitable,) = v.holds();
    }

    /// @dev What `shares` are worth now at the fee-inclusive price, as a claim would pay them, rounded down.
    function _worth(CuratorVault v, uint256 shares) internal view returns (uint256) {
        uint256 a = v.totalAssets();
        return Math.mulDiv(shares, a + 1, v.totalSupply() + v.pendingFeeShares() + V_OFF);
    }

    function _request(CuratorVault v, address who, uint256 shares) internal {
        vm.prank(who);
        _x(v).requestExit(shares);
    }

    function _claim(CuratorVault v, address who, uint256 shares) internal returns (uint256) {
        vm.prank(who);
        return _x(v).claimExit(shares, who, 0);
    }

    function _redeem(CuratorVault v, address who, uint256 shares) internal returns (uint256) {
        vm.prank(who);
        return v.redeem(shares, who, who);
    }

    function _escrow(CuratorVault v, address who) internal view returns (uint256 shares) {
        (shares,) = _x(v).requestOf(who);
    }
}
