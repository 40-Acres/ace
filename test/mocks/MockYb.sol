// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MockERC20} from "./MockERC20.sol";

/// @notice YieldBasis LT stand-in: a real ERC20, since the positionManager custodies it, matching the live yb-cbBTC shape.
/// @notice It answers `pricePerShare` with break and zero knobs, which is what makes it hostile.
contract MockYbLt is MockERC20 {
    uint256 public pps = 1.006194e18;
    uint256 public previewWithdrawn; // 0 = quote pps back, rescaled down; else an UNDERLYING-NATIVE rate
    uint256 public underlyingScale = 1e10; // 1e18 / 1e8: the real underlying is BTC, at 8 decimals
    address public ASSET_TOKEN; // what the LT redeems into; zero until a fixture names it, so no record admits an unnamed underlying
    bool internal broken;

    constructor() MockERC20("YieldBasis liquidity for cbBTC", "yb-cbBTC", 18) {}

    /// @dev The token the live LT names as `ASSET_TOKEN`; a fixture sets it to the underlying it builds.
    function setAssetToken(address t) external {
        ASSET_TOKEN = t;
    }

    /// @dev The realizable leg, settable apart from `pps` so a test can drive the two apart.
    /// @dev Give it an UNDERLYING-NATIVE figure: 0.96e8 is a 4% discount on a BTC-backed LT, not 0.96e18.
    function setPreviewWithdraw(uint256 v) external {
        previewWithdrawn = v;
    }

    /// @dev For a market whose underlying is not 8-dec; the record derives its own scale from the token.
    function setUnderlyingScale(uint256 v) external {
        underlyingScale = v;
    }

    /// @notice What a redeemer actually gets: an imbalanced pool exit, so at or below `pps`.
    /// @notice UNDERLYING-NATIVE, unlike `pricePerShare`, which is 1e18 whatever the underlying is.
    /// @dev Defaults to `pps` rescaled DOWN, so a fixture silent about redemption sees no discount.
    function preview_withdraw(uint256) external view returns (uint256) {
        require(!broken, "lt down");
        return previewWithdrawn == 0 ? pps / underlyingScale : previewWithdrawn;
    }

    function setPps(uint256 v) external {
        pps = v;
    }

    function setBroken(bool v) external {
        broken = v;
    }

    function pricePerShare() external view returns (uint256) {
        require(!broken, "lt down");
        return pps;
    }
}

/// @notice The LT stand-in a broadcast deploys: it names its underlying at construction, so naming it costs no transaction.
/// @dev A setter call is a transaction, and one more transaction moves every address a nonce-ordered deploy makes after it.
contract MockYbLtOf is MockYbLt {
    constructor(address assetToken) {
        ASSET_TOKEN = assetToken;
    }
}

/// @notice Settable rate() source for the rateSource-seam tests.
/// @notice It CAN answer zero, unlike the shipped adapter, so the hub's own zero guards can be exercised.
contract MockRateSource {
    uint256 public rate = 1e18;

    function setRate(uint256 v) external {
        rate = v;
    }
}

/// @notice YB gauge stand-in in the live shape: a real ERC20, ERC-4626 conversion over a named LT, and per-user claimable YB accrual.
/// @notice The positionManager custodies gauge shares, and the break knobs are what make it hostile.
contract MockYbGauge is MockERC20 {
    address public immutable asset;
    address public YB;
    uint256 public c2a = 0.993443e18;
    bool internal broken;
    mapping(address => uint256) public pending;
    /// @dev Adversarial knob: gauge shares this venue takes back off the claimer during claim.
    uint256 public stealOnClaim;

    constructor(address lt) MockERC20("YB Gauge: yb-cbBTC", "g(yb-cbBTC)", 18) {
        asset = lt;
    }

    function setStealOnClaim(uint256 v) external {
        stealOnClaim = v;
    }

    function setYb(address yb) external {
        YB = yb;
    }

    function setC2a(uint256 v) external {
        c2a = v;
    }

    function setBroken(bool v) external {
        broken = v;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        require(!broken, "gauge down");
        return (shares * c2a) / 1e18;
    }

    function accrue(address user, uint256 amount) external {
        pending[user] += amount;
    }

    /// @dev The live gauge's shape: permissionless claim-for, pays USER, returns the amount.
    function claim(address reward, address user) external returns (uint256 amount) {
        require(reward == YB, "gauge: wrong reward");
        amount = pending[user];
        pending[user] = 0;
        if (amount > 0) MockERC20(YB).mint(user, amount);
        if (stealOnClaim > 0) {
            balanceOf[user] -= stealOnClaim; // the venue reaching into the vault's own collateral
            balanceOf[address(this)] += stealOnClaim;
        }
    }
}
