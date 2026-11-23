// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {BorrowRequest, Terms} from "../../src/vault/libraries/AceVaultFlows.sol";
import {Extension} from "../../src/interfaces/IRollPolicy.sol";
import {Lend, RefinanceRequest} from "../../src/interfaces/IVaultTerms.sol";
import {InKindConfig, Listing, Row} from "../utils/InKindVaults.sol";
import {IAceVaultLens} from "../utils/VaultLens.sol";

/// @notice The appraiser's quote for one loan, as `InKindTerms` hashes and decodes it.
struct Quote {
    address collateral;
    address borrower;
    uint256 price;
    uint256 maxPrincipal;
    uint64 maxTenor;
    uint256 nonce;
    uint64 issuedAt;
}

/// @notice The appraiser's consent to one extension, as `InKindTerms` hashes and decodes it.
struct RollQuote {
    uint256 loanId;
    uint64 expiry;
    uint256 price;
    uint64 issuedAt;
}

/// @title IInKindVault
/// @notice The surface of an in-kind `AceVault` as the suites under `test/inkind/` drive it: the base, its caps, and its in-kind verbs.
/// @dev The stored figures (requests, caps, room, the high-water and the drawdown) are read through `IAceVaultLens`, never here.
/// @dev Errors and events are matched by signature, so the real contracts need not inherit this interface.
interface IInKindVault is IERC4626 {
    error NotCurator();
    error NotGuardian();
    error Draining();
    error ModeUnbuilt();
    error TenorRailOutOfBounds();
    error TimelockOutOfBounds();
    error InventoryUnsold();
    error OverRequest();
    error OverSupply();
    error NothingDue();
    error WildcardInKind();
    error CashIsNotCollateral();
    error NotListed();
    error ClaimToVault();
    error NotOurLoan();

    /// @notice A seized pot came home in kind and waits to be credited from the next block.
    event Forfeited(uint256 indexed loanId, address indexed collateral, uint256 units);
    /// @notice A holder took credited units of one token.
    event Claimed(address indexed holder, address indexed token, address to, uint256 amount);
    /// @notice A cap change waits the timelock until `validAt`.
    event SubmitCap(address indexed key, uint256 cap, bool listed, uint64 validAt);
    /// @notice A cap took effect.
    event SetCap(address indexed by, address indexed key, uint256 cap, bool listed);
    /// @notice A pending cap change was dropped.
    event RevokePendingCap(address indexed by, address indexed key);

    function ACE() external view returns (address);
    function CURATOR() external view returns (address);
    function GUARDIAN() external view returns (address);
    function TERMS() external view returns (address);
    function IN_KIND() external view returns (bool);
    function MIN_TENOR() external view returns (uint64);
    function MAX_TENOR() external view returns (uint64);
    function CAP_TIMELOCK() external view returns (uint64);
    function MIN_SEED() external view returns (uint256);
    function SEED_SHARES() external view returns (uint256);
    function borrow(BorrowRequest calldata r, bytes calldata data, bytes calldata permit2) external returns (uint256 loanId);
    function admitsExtension(Extension calldata e, bytes calldata data) external view returns (bytes4);
    function requestExit(uint256 shares) external;
    function cancelExit(uint256 shares) external;
    function lapseExit(address holder) external;
    function claimExit(uint256 shares, address receiver, uint256 minAssets) external returns (uint256 assets);
    function maxClaim(address holder) external view returns (uint256);
    function setDrain(bool on) external;
    function draining() external view returns (bool);
    function exemptDeadPots(uint256 expectedSettled) external;
    function crank() external;
    function collectFee() external;
    function idle() external view returns (uint256);
    function grossNav() external view returns (uint256);
    function lendable() external view returns (uint256);
    function unvested() external view returns (uint256);
    function pendingFeeShares() external view returns (uint256);

    function effectiveCap(address collateral) external view returns (uint256);
    function submitCap(address key, uint192 cap) external;
    function submitDelist(address collateral) external;
    function acceptCap(address key) external;
    function revokePendingCap(address key) external;

    function collectForfeited(uint256[] calldata loanIds) external returns (uint256[] memory units);
    function claim(address[] calldata tokens, address to) external returns (uint256[] memory paid);
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory);
}

/// @title IInKindTerms
/// @notice The surface of `InKindTerms` as the suites drive it: the table, the appraiser's seat, the signed checks and the answers the vault asks.
interface IInKindTerms {
    error NotCurator();
    error NotVault();
    error NotListed();
    error CollateralMismatch();
    error NotTheBorrower();
    error QuoteNotYetIssued();
    error QuoteExpired();
    error QuoteUsed();
    error OverMaxPrincipal();
    error TenorOverQuote();
    error BadSignature();
    error PriceZero();
    error BadRow();
    error BadTerms();
    error TenorRailOutOfBounds();
    error NothingDue();
    error ZeroAppraiser();
    error DelegatedAppraiser();
    error NoRefinance();
    error VaultMismatch();

    /// @notice The appraiser changed: an accepted appointment, or a halt to zero.
    event AppraiserSet(address indexed previous, address indexed appraiser);
    /// @notice An appraiser appointment waits the timelock until `validAt`.
    event SubmitAppraiser(address indexed appraiser, uint64 validAt);
    /// @notice A pending appraiser appointment was dropped.
    event RevokePendingAppraiser(address indexed by);
    /// @notice A row change waits the timelock until `validAt`.
    event SubmitRow(address indexed collateral, Row row, uint64 validAt);
    /// @notice A row went live: a cut at once, or a pending row accepted.
    event SetRow(address indexed by, address indexed collateral, Row row);
    /// @notice Whatever was pending for a token was dropped.
    event RevokePending(address indexed by, address indexed collateral);

    function VAULT() external view returns (address);
    function ASSET() external view returns (address);
    function APPRAISER() external view returns (address);
    function MIN_PRINCIPAL() external view returns (uint256);
    function COVERAGE_WAD() external view returns (uint256);
    function MIN_TENOR() external view returns (uint64);
    function MAX_TENOR() external view returns (uint64);
    function QUOTE_TTL() external view returns (uint64);
    function pendingAppraiser() external view returns (address appraiser, uint64 validAt);

    function rowOf(address collateral) external view returns (Row memory);
    function pendingRowOf(address collateral) external view returns (Row memory row, uint64 validAt);
    function submitRow(address collateral, Row calldata row) external;
    function accept(address collateral) external;
    function revokePending(address collateral) external;
    function submitAppraiser(address appraiser) external;
    function acceptAppraiser() external;
    function revokePendingAppraiser() external;
    function haltAppraiser() external;

    function eip712Domain()
        external
        view
        returns (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying, bytes32 salt, uint256[] memory extensions);
    function hashQuote(Quote calldata q) external view returns (bytes32);
    function hashRollQuote(RollQuote calldata q) external view returns (bytes32);
    function spent(uint256 nonce) external view returns (bool);

    function borrowTerms(address borrower, BorrowRequest calldata r, bytes calldata data) external view returns (MarketParams memory mp, Terms memory t);
    function refinanceTerms(address holder, uint256 loanId, RefinanceRequest calldata r, bytes calldata data)
        external
        view
        returns (MarketParams memory mp, Terms memory t);
    function admitsExtension(Extension calldata e, bytes calldata data) external view returns (bool);
    function room(MarketParams calldata mp) external view returns (uint256);
    function entryCap(address receiver, uint256 nav) external view returns (uint256);
    function beforeLend(Lend kind, MarketParams calldata mp, uint256 loanId, bytes calldata data) external;
    function afterLend(Lend kind, MarketParams calldata mp, uint256 loanId, address holder, bytes calldata data) external;
}

