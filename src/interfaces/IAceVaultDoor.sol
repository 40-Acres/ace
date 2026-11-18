// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IAceVaultDoor
/// @notice An AceVault's door-mode surface: what its DOOR calls to take seized goods and return their cash, the write-off, and the lending doors.
/// @notice Entry stays shut while any key is open, as while a hub pot is unsold, so a door closes a key once it holds none of its goods.
/// @dev The vault never calls the door; it calls its terms only through `IVaultTerms`, and the hub only for its own loans.
/// @dev A door reads key `c`'s record by `extsload` at `keccak256(abi.encode(c, ROOT + 9))` and the open count at `ROOT + 10`, ROOT `AceVaultFlows.ROOT`.
/// @dev The record is one word: the value in bits 0-183, the write-off's due time in bits 184-247, the open flag at bit 248.
interface IAceVaultDoor {
    error NotDoor(); // a door-mode verb called by anyone but the vault's DOOR
    error DoorNotBound(); // the door has no code, names another vault, or sits beside in-kind mode
    error NotOurLoan(); // the loan's market does not name this vault as lender in its asset
    error NothingReturned(); // a return of no cash that closes nothing
    error ProceedsShort(); // the cash pulled from the door arrived other than the amount named
    error NothingSeized(); // a write-off of a key that holds no value and is not open
    error NothingDue(); // no write-off on this key has waited out the timelock, or for a revoke none is pending
    error NotCurator();
    error NotTheBorrower(); // a lending door on a live loan asked by anyone but its title holder
    error FeeOverMax(); // the renewal's fee is over the holder's maximum
    error FeePaidShort(); // the fee arrived short
    error FeeMismatch(); // the hub charged other than the fee the vault priced and pulled
    error RequestsOutweighIdle(); // a lending door refused while the exit requests are worth more than idle
    error WithdrawToVault(); // collateral a refinance sheds never lands on the vault
    error TopUpRefused(); // the product's refinance answer is not the loan's own market admitting the whole new principal

    /// @notice A loan's pot went to the door: `units` of `collateral`, and `value` is what the key's record rose by, saturating at its width.
    event Seized(uint256 indexed loanId, address indexed collateral, uint256 units, uint256 value);
    /// @notice The door returned `cash` against `collateral`; `closed` is whether that shut an open key, whatever the door asked.
    event ProceedsReturned(address indexed collateral, uint256 cash, bool closed);
    /// @notice A write-off of `collateral`'s residue waits until `validAt`.
    event WriteOffSubmitted(address indexed collateral, uint64 validAt);
    /// @notice A write-off landed: `forgiven` left the ledger and the key closed.
    event WriteOffAccepted(address indexed collateral, uint256 forgiven);
    /// @notice A pending write-off was dropped: by the curator or the guardian, or by a collect, which names the door.
    event WriteOffRevoked(address indexed by, address indexed collateral);
    /// @notice A loan was renewed in place for its holder, `added` seconds later than it ran, for `fee`.
    event Renewed(uint256 indexed loanId, address indexed holder, uint64 added, uint256 fee);
    /// @notice A loan was refinanced for its holder into `newId` at `principal`, paying the holder `out`.
    event Refinanced(uint256 indexed loanId, uint256 indexed newId, address indexed holder, uint256 principal, uint256 out);
    /// @notice A loan drew `amount` more in place for its holder, the hub's `fee` netted from the holder's payout.
    event ToppedUp(uint256 indexed loanId, address indexed holder, uint256 amount, uint256 fee);

    /// @notice Where seized goods go; zero in hub-ask and in-kind mode.
    function DOOR() external view returns (address);

    /// @notice The product's terms contract, which a door may also be.
    function TERMS() external view returns (address);

    /// @notice End each named loan of this vault's and hand its pot to the door. THE DOOR ONLY in door mode.
    /// @param loanIds The loans to end and collect; a repaid or already-collected one yields zero.
    /// @return units The units each id handed over.
    function collectForfeited(uint256[] calldata loanIds) external returns (uint256[] memory units);

    /// @notice Take `cash` of a sale's proceeds from the door against `collateral`, and close it from the entry gate if `closes`. THE DOOR ONLY.
    /// @param collateral The ledger key: the collateral the goods were seized as.
    /// @param cash The asset pulled from the door, on its exact allowance.
    /// @param closes Whether the door holds none of the goods left.
    function returnProceeds(address collateral, uint256 cash, bool closes) external;

    /// @notice Queue a write-off of `collateral`'s residue, due after the cap timelock. CURATOR ONLY.
    /// @notice For goods the door cannot sell: accepting it lifts the door's gate over what is left, unasked; a material fall over them still holds entry.
    function submitWriteOff(address collateral) external;

    /// @notice Land a write-off that has waited out the timelock. PERMISSIONLESS.
    function acceptWriteOff(address collateral) external;

    /// @notice Drop a pending write-off. The curator or the guardian; with none pending it refuses `NothingDue`.
    function revokeWriteOff(address collateral) external;

    /// @notice Renew a loan of this vault's in place for its title holder, the fee pulled from the holder; refuses while requests outweigh idle.
    /// @notice The holder approves this vault for the title to renew at any time; unapproved, the hub holds the vault to its non-holder rule.
    /// @param loanId The loan.
    /// @param maxFee The most the holder pays.
    /// @param minBufferWad The least admissibility buffer the holder accepts.
    /// @param data The product's payload, handed to its write calls and to the hub's extension ask.
    /// @param permit2 A Permit2 SignatureTransfer for the fee, or empty to pull on allowance.
    /// @return fee The fee the hub charged.
    function extendFor(uint256 loanId, uint256 maxFee, uint256 minBufferWad, bytes calldata data, bytes calldata permit2) external returns (uint256 fee);

    /// @notice Refinance a loan of this vault's for its title holder into the product's market; refuses a lengthening while requests outweigh idle.
    /// @param loanId The loan, whose title the caller holds and approved to this vault.
    /// @param collateral The collateral the successor pledges, the loan's own.
    /// @param principal The successor's principal.
    /// @param tenor The successor's term, or zero for its market's shortest.
    /// @param minPayout The least net the holder accepts.
    /// @param minBufferWad The least admissibility buffer the holder accepts.
    /// @param deadline The latest second the successor may open, or zero for none.
    /// @param withdrawUnits Collateral the successor releases, or zero.
    /// @param withdrawTo Where released collateral goes; never this vault.
    /// @param data The product's payload, handed to its terms and its write calls.
    /// @return newId The successor loan, titled to the holder.
    /// @return out The net paid to the holder.
    function refinanceFor(
        uint256 loanId,
        address collateral,
        uint256 principal,
        uint64 tenor,
        uint256 minPayout,
        uint256 minBufferWad,
        uint64 deadline,
        uint256 withdrawUnits,
        address withdrawTo,
        bytes calldata data
    ) external returns (uint256 newId, uint256 out);

    /// @notice Draw more on a loan of this vault's for its title holder in place: the same loan and term, at its market's price.
    /// @notice The product consents by its refinance answer at the loan's debt plus `amount`, which must be the loan's own market admitting all of it.
    /// @notice The holder approves this vault for the title; the hub pays the holder `amount` less the fee.
    /// @param loanId The loan, whose title the caller holds.
    /// @param amount The quote to draw, at least the market's `minPrincipal`; caps and room bind on it alone.
    /// @param minPayout The least net the holder accepts.
    /// @param minBufferWad The least admissibility buffer the holder accepts.
    /// @param deadline The latest second the top-up may land, or zero for none.
    /// @param data The product's payload, handed to its terms and its write calls.
    /// @return fee The fee the hub charged.
    function drawMoreFor(uint256 loanId, uint256 amount, uint256 minPayout, uint256 minBufferWad, uint64 deadline, bytes calldata data)
        external
        returns (uint256 fee);
}
