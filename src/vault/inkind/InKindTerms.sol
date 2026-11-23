// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {EIP7702Utils} from "@openzeppelin/contracts/account/utils/EIP7702Utils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {Constants} from "../../ace/hub/Constants.sol";
import {LoanMath} from "../../ace/hub/libraries/LoanMath.sol";
import {MarketParams} from "../../ace/hub/Types.sol";
import {Extension} from "../../interfaces/IRollPolicy.sol";
import {IVaultTerms, Lend, RefinanceRequest} from "../../interfaces/IVaultTerms.sol";
import {AceVault} from "../AceVault.sol";
import {AceVaultCaps} from "../libraries/AceVaultCaps.sol";
import {BorrowRequest, Terms} from "../libraries/AceVaultFlows.sol";
import {AceVaultInKind} from "../libraries/AceVaultInKind.sol";
import {PriceGrid} from "../libraries/PriceGrid.sol";

/// @notice One token's terms: the lender's rate, the tenor range and the largest loan; the vault holds its cap.
struct Row {
    uint16 lenderAprBps; // the lender's rate, bps a year
    uint64 minTenor;
    uint64 maxTenor; // zero is no row
    uint128 maxPrincipal; // the most one loan may draw or carry into an extension, whatever its quote names
}

/// @notice A token listed at deploy, live from the first block.
struct Listing {
    address collateral;
    Row row;
}

/// @notice A row change waiting out the vault's cap timelock: the new row and the time it may be accepted from.
struct PendingRow {
    Row value;
    uint64 validAt; // zero is nothing pending
}

/// @notice An appraiser appointment waiting out the vault's cap timelock: the appointee and the time it may be accepted from.
struct PendingAppraiser {
    address value;
    uint64 validAt; // zero is nothing pending
}

/// @notice The appraiser's quote for one loan: bound to its borrower, single-use by nonce, bounded in price, size and term, live `QUOTE_TTL`.
struct Quote {
    address collateral;
    address borrower;
    uint256 price; // Q96, raw: the market takes it rounded down onto the grid
    uint256 maxPrincipal;
    uint64 maxTenor; // the longest term the price was signed for
    uint256 nonce;
    uint64 issuedAt; // the chain time it was priced at; live through issuedAt + QUOTE_TTL
}

/// @notice The appraiser's consent to one extension of one loan, bound to its current expiry so it lands once.
struct RollQuote {
    uint256 loanId;
    uint64 expiry; // the loan's expiry before the extension
    uint256 price; // Q96: at or over the market's price
    uint64 issuedAt; // the chain time it was priced at; live through issuedAt + QUOTE_TTL
}

/// @notice Everything a deploy fixes about the terms, named so no two figures transpose.
struct InKindTermsConfig {
    address vault; // the one in-kind AceVault these terms serve, deployed after them at this address
    address asset; // that vault's asset
    address appraiser; // the first signer that prices each loan; later ones are appointed through the vault's cap timelock
    uint256 minPrincipal; // every market's floor ticket
    uint256 coverageWad; // every market's coverage multiple
    uint64 minTenor; // the vault's tenor rail floor, at least one day
    uint64 maxTenor; // the vault's rail ceiling, at most thirty days
}

/// @title InKindTerms
/// @notice The signed terms an in-kind AceVault lends on: an appraiser prices each loan, no price sits on chain, and a default is never sold.
/// @notice ONE ROW PER TOKEN: a rate, tenors and a largest loan; the cap is the vault's. A cut lands at once, anything else waits.
/// @notice A QUOTE LIVES `QUOTE_TTL` from its issue time, for one named borrower, under its own and the row's `maxPrincipal`.
/// @notice EVERY MARKET is recordless at the gridded signed price: nothing settles before expiry, and a default forfeits the whole coverage line.
/// @notice THE TIMELOCK for a new row, any edit but a cut, and an appraiser appointment is the vault's `CAP_TIMELOCK`.
/// @dev THE APPRAISER is trusted up to the vault's caps: a stolen key can fill every token's room at once, so the drain, the halt, then zero caps go first.
/// @dev A borrower may repay or extend, never refinance in place: the consent refuses the empty payload a same-market `refinanceTo` asks with.
/// @dev The asset and the rail are copies of the vault's, taken before it existed; terms whose copy disagrees, or a vault not in kind, lend nothing.
contract InKindTerms is IVaultTerms, EIP712 {
    using BitMaps for BitMaps.BitMap;

    error NotCurator();
    error NotVault(); // only the vault makes the write calls
    error NotListed(); // the token has no live row
    error CollateralMismatch(); // the quote prices another token than the borrow pledges
    error NotTheBorrower();
    error QuoteNotYetIssued(); // the quote names an issue time after now
    error QuoteExpired(); // past issuedAt + QUOTE_TTL
    error QuoteUsed(); // the quote's nonce is already cashed
    error OverMaxPrincipal(); // the draw is over the quote's or the row's maxPrincipal
    error TenorOverQuote(); // the term asked is longer than the price was signed for
    error BadSignature();
    error PriceZero(); // the signed price falls off the grid
    error BadRow(); // a row genesis would refuse, outside the rail, naming the vault's own tokens, under the floor ticket, or listed twice
    error BadTerms(); // a minPrincipal or coverage genesis would refuse, so no borrow could ever open
    error TenorRailOutOfBounds(); // the rail sits outside one to thirty days, or its ends cross
    error NothingDue(); // nothing pending has waited out the timelock
    error ZeroAppraiser(); // zero validates no signature, so only the halt seats it
    error DelegatedAppraiser(); // an EIP-7702-delegated account is never seated; a seated key that delegates later still verifies by ECDSA
    error NoRefinance(); // these terms price no refinance through the vault
    error VaultMismatch(); // the vault runs another asset or rail than these terms were built with, or is not in kind, so no loan opens

    /// @notice The appraiser changed, by an accepted appointment or a halt to zero; every quote the old one signed is dead from this block.
    event AppraiserSet(address indexed previous, address indexed appraiser);
    /// @notice An appraiser appointment waits the timelock until `validAt`.
    event SubmitAppraiser(address indexed appraiser, uint64 validAt);
    /// @notice A pending appraiser appointment was dropped.
    event RevokePendingAppraiser(address indexed by);
    /// @notice A row change waits the timelock until `validAt`.
    event SubmitRow(address indexed collateral, Row row, uint64 validAt);
    /// @notice A row went live: a cut at once, a pending row accepted, or a listing at deploy.
    event SetRow(address indexed by, address indexed collateral, Row row);
    /// @notice Whatever was pending for a token was dropped.
    event RevokePending(address indexed by, address indexed collateral);

    uint64 public constant QUOTE_TTL = 5 minutes; // a quote or roll quote is live from issuedAt through issuedAt + QUOTE_TTL
    bytes32 internal constant QUOTE_TYPEHASH =
        keccak256("Quote(address collateral,address borrower,uint256 price,uint256 maxPrincipal,uint64 maxTenor,uint256 nonce,uint64 issuedAt)");
    bytes32 internal constant ROLL_TYPEHASH = keccak256("RollQuote(uint256 loanId,uint64 expiry,uint256 price,uint64 issuedAt)");

    address public immutable VAULT;
    address public immutable ASSET;
    uint256 public immutable MIN_PRINCIPAL; // every market's floor ticket
    uint256 public immutable COVERAGE_WAD; // every market's coverage multiple
    uint64 public immutable MIN_TENOR; // the vault's rail floor, under which no row lists
    uint64 public immutable MAX_TENOR; // the vault's rail ceiling, over which no row lists

    address public APPRAISER; // whose signature prices a loan; a contract answers by ERC-1271; zero is halted
    PendingAppraiser internal _pendingAppraiser;
    BitMaps.BitMap internal _spent;
    mapping(address collateral => Row) internal _rows;
    mapping(address collateral => PendingRow) internal _pendingRows;

    /// @param c The terms' write-once config.
    /// @param listings The tokens listed at deploy; each also needs a cap on the vault to lend.
    /// @param name_ The EIP-712 domain's name.
    constructor(InKindTermsConfig memory c, Listing[] memory listings, string memory name_) EIP712(name_, "1") {
        if (
            c.minPrincipal < 2 || c.minPrincipal > type(uint128).max || c.coverageWad < Constants.MIN_COVERAGE_WAD || c.coverageWad > Constants.MAX_COVERAGE_WAD
        ) {
            revert BadTerms();
        }
        if (c.minTenor < AceVaultCaps.MIN_TENOR_RAIL || c.maxTenor > AceVaultInKind.MAX_TENOR_RAIL || c.minTenor > c.maxTenor) revert TenorRailOutOfBounds();
        (VAULT, ASSET, MIN_PRINCIPAL, COVERAGE_WAD, MIN_TENOR, MAX_TENOR) = (c.vault, c.asset, c.minPrincipal, c.coverageWad, c.minTenor, c.maxTenor);
        _seat(c.appraiser);
        for (uint256 i; i < listings.length; ++i) {
            Listing memory l = listings[i];
            _checkRow(l.collateral, l.row);
            if (_rows[l.collateral].maxTenor != 0) revert BadRow();
            _rows[l.collateral] = l.row;
            emit SetRow(msg.sender, l.collateral, l.row);
        }
    }

    // ---- the table ----

    /// @notice A token's live row; a zero maxTenor is no row.
    function rowOf(address collateral) external view returns (Row memory) {
        return _rows[collateral];
    }

    /// @notice A token's pending row and when it may be accepted; zero is none.
    function pendingRowOf(address collateral) external view returns (Row memory row, uint64 validAt) {
        PendingRow memory p = _pendingRows[collateral];
        return (p.value, p.validAt);
    }

    /// @notice Submit a token's row: an edit whose every changed field is a cut lands at once, by the vault's curator or guardian.
    /// @notice The cuts are a lower maxPrincipal or maxTenor; any other edit, a new row included, waits whole and is the curator's.
    /// @notice A cut drops whatever was pending for the token.
    function submitRow(address collateral, Row calldata row) external {
        Row memory live = _rows[collateral];
        bool cut = live.maxTenor != 0 && row.maxPrincipal <= live.maxPrincipal && row.maxTenor <= live.maxTenor && row.lenderAprBps == live.lenderAprBps
            && row.minTenor == live.minTenor;
        AceVault v = AceVault(VAULT);
        if (msg.sender != v.CURATOR() && !(cut && msg.sender == v.GUARDIAN())) revert NotCurator();
        _checkRow(collateral, row);
        if (cut) {
            _rows[collateral] = row;
            delete _pendingRows[collateral];
            emit SetRow(msg.sender, collateral, row);
            return;
        }
        uint64 validAt = uint64(block.timestamp) + v.CAP_TIMELOCK();
        _pendingRows[collateral] = PendingRow(row, validAt);
        emit SubmitRow(collateral, row, validAt);
    }

    /// @notice Make a token's pending row live once the timelock has run. PERMISSIONLESS.
    /// @notice A pending row never expires: it stays acceptable until accepted, replaced or dropped by a later change on its token, or revoked.
    function accept(address collateral) external {
        PendingRow memory p = _pendingRows[collateral];
        if (p.validAt == 0 || block.timestamp < p.validAt) revert NothingDue();
        delete _pendingRows[collateral];
        _rows[collateral] = p.value;
        emit SetRow(msg.sender, collateral, p.value);
    }

    /// @notice Drop whatever is pending for a token. The vault's curator or guardian.
    function revokePending(address collateral) external {
        _onlyKeys();
        delete _pendingRows[collateral];
        emit RevokePending(msg.sender, collateral);
    }

    /// @dev A row prices a token other than the vault's own, sized at least the floor ticket, inside the rail, on terms genesis admits.
    function _checkRow(address collateral, Row memory row) internal view {
        if (collateral == address(0) || collateral == ASSET || collateral == VAULT || row.maxPrincipal < MIN_PRINCIPAL) revert BadRow();
        if (row.lenderAprBps < Constants.MIN_LENDER_APR_BPS || row.minTenor < MIN_TENOR || row.maxTenor < row.minTenor || row.maxTenor > MAX_TENOR) {
            revert BadRow();
        }
        if (!LoanMath.feeFundable(row.lenderAprBps, row.maxTenor)) revert BadRow();
        if (LoanMath.originationFee(MIN_PRINCIPAL, row.maxTenor, row.lenderAprBps) >= MIN_PRINCIPAL) revert BadRow();
    }

    // ---- the appraiser's seat ----

    /// @notice The pending appointment and when it may be accepted; zero is none.
    function pendingAppraiser() external view returns (address appraiser, uint64 validAt) {
        PendingAppraiser memory p = _pendingAppraiser;
        return (p.value, p.validAt);
    }

    /// @notice Appoint the next appraiser, which anyone may seat once the vault's cap timelock has run. CURATOR ONLY; a new submit replaces a pending one.
    /// @param appraiser The next signer; a contract answers by ERC-1271, and zero or an EIP-7702-delegated account is refused.
    function submitAppraiser(address appraiser) external {
        AceVault v = AceVault(VAULT);
        if (msg.sender != v.CURATOR()) revert NotCurator();
        _seatable(appraiser);
        uint64 validAt = uint64(block.timestamp) + v.CAP_TIMELOCK();
        _pendingAppraiser = PendingAppraiser(appraiser, validAt);
        emit SubmitAppraiser(appraiser, validAt);
    }

    /// @notice Seat the pending appraiser once its timelock has run. PERMISSIONLESS. Every quote the old seat signed dies with it.
    /// @notice A pending appointment never expires: it stays pending until seated, replaced by a new submit, or revoked, and seating re-checks the account.
    function acceptAppraiser() external {
        PendingAppraiser memory p = _pendingAppraiser;
        if (p.validAt == 0 || block.timestamp < p.validAt) revert NothingDue();
        delete _pendingAppraiser;
        _seat(p.value);
    }

    /// @notice Drop a pending appointment. The vault's curator or guardian.
    function revokePendingAppraiser() external {
        _onlyKeys();
        delete _pendingAppraiser;
        emit RevokePendingAppraiser(msg.sender);
    }

    /// @notice Empty the seat at once, so no borrow or extension is priced until an appointment lands. The vault's curator or guardian.
    /// @dev A pending appointment is left in place, so a rotation already under way still lands.
    function haltAppraiser() external {
        _onlyKeys();
        emit AppraiserSet(APPRAISER, address(0));
        APPRAISER = address(0);
    }

    /// @dev Refuse any caller but the vault's curator or guardian.
    function _onlyKeys() private view {
        AceVault v = AceVault(VAULT);
        if (msg.sender != v.CURATOR() && msg.sender != v.GUARDIAN()) revert NotCurator();
    }

    /// @dev Seat a signer that is set and is not a delegated account.
    function _seat(address a) private {
        _seatable(a);
        emit AppraiserSet(APPRAISER, a);
        APPRAISER = a;
    }

    /// @dev Refuse zero, the halt's alone, and an account whose code is a 7702 designator.
    function _seatable(address a) private view {
        if (a == address(0)) revert ZeroAppraiser();
        if (_delegated(a)) revert DelegatedAppraiser();
    }

    /// @dev Whether the seat signed `hash`: by ECDSA alone while its account has no code or only a delegation, so a delegate is never asked.
    /// @dev Contract code answers by ERC-1271, so a Safe appointed before it is deployed signs once it is; a zero seat validates nothing.
    /// @dev Not OZ `SignatureChecker.isValidSignatureNow`: it branches on code length alone, so it would hand a delegated key's checks to the delegate.
    function _valid(address a, bytes32 hash, bytes memory sig) private view returns (bool) {
        if (a.code.length != 0 && !_delegated(a)) return SignatureChecker.isValidERC1271SignatureNow(a, hash, sig);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        return err == ECDSA.RecoverError.NoError && recovered == a;
    }

    /// @dev Whether `a`'s code is exactly an EIP-7702 delegation designator; the length gate caps the code copy at 23 bytes.
    function _delegated(address a) private view returns (bool) {
        return a.code.length == 23 && EIP7702Utils.fetchDelegate(a) != address(0);
    }

    // ---- the signed checks ----

    /// @notice Whether a quote nonce is already cashed.
    function spent(uint256 nonce) external view returns (bool) {
        return _spent.get(nonce);
    }

    /// @notice The digest the appraiser signs for a quote, under these terms' EIP-712 domain; every field is bound.
    function hashQuote(Quote memory q) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(QUOTE_TYPEHASH, q)));
    }

    /// @notice The digest the appraiser signs for a roll quote, under its own typehash so no quote passes as one.
    function hashRollQuote(RollQuote memory q) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ROLL_TYPEHASH, q)));
    }

    // ---- the answers the vault asks ----

    /// @notice The signed quote's recordless market at the gridded price and the draw, for `borrower`, refused in a fixed order with the signature last.
    /// @dev ORDER: listing, collateral, borrower, issue time, life, nonce, size, term, grid, signature.
    function borrowTerms(address borrower, BorrowRequest calldata r, bytes calldata data) external view returns (MarketParams memory mp, Terms memory t) {
        Row memory w = _rows[r.collateral];
        if (w.maxTenor == 0) revert NotListed();
        uint64 tenor = r.tenor == 0 ? w.minTenor : r.tenor;
        uint256 price = _quoted(w, borrower, r, tenor, data);
        (mp.quote, mp.collateral, mp.price, mp.lender) = (ASSET, r.collateral, price, VAULT);
        (mp.minCoverageWad, mp.minPrincipal) = (COVERAGE_WAD, MIN_PRINCIPAL);
        (mp.lenderAprBps, mp.minTenor, mp.maxTenor) = (w.lenderAprBps, w.minTenor, w.maxTenor);
        t = Terms(r.units, r.principal, tenor, r.minBufferWad);
    }

    /// @dev The quote's refusals after the listing, in order, and its price on the grid; a zero tenor was already read as the row's shortest.
    function _quoted(Row memory w, address borrower, BorrowRequest calldata r, uint64 tenor, bytes calldata data) private view returns (uint256 price) {
        (Quote memory q, bytes memory sig) = abi.decode(data, (Quote, bytes));
        if (q.collateral != r.collateral) revert CollateralMismatch();
        if (q.borrower != borrower) revert NotTheBorrower();
        if (q.issuedAt > block.timestamp) revert QuoteNotYetIssued();
        if (block.timestamp > q.issuedAt + QUOTE_TTL) revert QuoteExpired();
        if (_spent.get(q.nonce)) revert QuoteUsed();
        if (r.principal > q.maxPrincipal || r.principal > w.maxPrincipal) revert OverMaxPrincipal();
        if (tenor > q.maxTenor) revert TenorOverQuote();
        price = PriceGrid.down(q.price);
        if (price == 0) revert PriceZero();
        if (!_valid(APPRAISER, hashQuote(q), sig)) revert BadSignature();
    }

    /// @notice These terms price no refinance through the vault.
    function refinanceTerms(address, uint256, RefinanceRequest calldata, bytes calldata) external pure returns (MarketParams memory, Terms memory) {
        revert NoRefinance();
    }

    /// @notice An extension's consent: the row names the market's rate and tenors exactly, the new debt fits its maxPrincipal, then a signed roll quote.
    /// @dev The maxTenor leg is an EQUALITY: a cut back to an older market's maxTenor re-admits that market, which the curator once listed.
    /// @dev Empty data answers no, so a same-market `refinanceTo`, which asks with none, never reuses a claim.
    /// @dev The roll quote names this loan at its current expiry, live, at or over the market's price; an issue time after now answers no first.
    function admitsExtension(Extension calldata e, bytes calldata data) external view returns (bool) {
        Row storage w = _rows[e.dst.collateral];
        if (w.lenderAprBps != e.dst.lenderAprBps || w.minTenor != e.dst.minTenor || w.maxTenor != e.dst.maxTenor || e.newDebt > w.maxPrincipal) return false;
        if (data.length == 0) return false;
        (RollQuote memory q, bytes memory sig) = abi.decode(data, (RollQuote, bytes));
        if (q.loanId != e.loanId || q.expiry != e.expiry || q.price < e.dst.price || q.issuedAt > block.timestamp) return false;
        if (block.timestamp > q.issuedAt + QUOTE_TTL) return false;
        return _valid(APPRAISER, hashRollQuote(q), sig);
    }

    /// @notice No room of the terms' own: the vault's caps bound every token.
    function room(MarketParams calldata) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice No entry cap of the terms' own.
    function entryCap(address, uint256) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Burn the borrow's quote nonce, once the vault is the in-kind one these terms were built for. THE VAULT ONLY.
    /// @dev The asset and the rail are copies taken before the vault existed; a copy that disagrees, or a vault not in kind, refuses every loan.
    /// @dev A base refusal after it reverts the whole borrow, so a quote it spent is unspent again.
    function beforeLend(Lend kind, MarketParams calldata, uint256, bytes calldata data) external {
        if (msg.sender != VAULT) revert NotVault();
        AceVault v = AceVault(VAULT);
        if (v.asset() != ASSET || v.MIN_TENOR() != MIN_TENOR || v.MAX_TENOR() != MAX_TENOR || !v.IN_KIND()) revert VaultMismatch();
        if (kind != Lend.Borrow) return;
        (Quote memory q,) = abi.decode(data, (Quote, bytes));
        if (_spent.get(q.nonce)) revert QuoteUsed();
        _spent.set(q.nonce);
    }

    /// @notice Nothing to record after a loan. THE VAULT ONLY.
    function afterLend(Lend, MarketParams calldata, uint256, address, bytes calldata) external view {
        if (msg.sender != VAULT) revert NotVault();
    }
}
