// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {MarketParams, MigrateArgs, OpenBounds} from "../../../src/ace/hub/Types.sol";
import {BoundaryTitle} from "./BoundaryTitle.sol";

/// @notice The two token calls the stand-in hub makes on the vault's asset.
interface IBoundaryCash {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title BoundaryHub
/// @notice Stands in for the hub in the vault's boundary spec: reads answered from storage, writes recorded, and the asset moved as the hub moves it.
/// @notice `lenderAssets` counts a lender's resting cash, its live claims and what it is owed, and each verb keeps it so.
/// @notice A deposit pulls into resting, an open lends from resting and pays the borrower, a withdraw or a collect pays the lender.
/// @notice A refinance lends the net from resting and pays it to its caller; an extension pulls its fee from its caller.
/// @notice A top-up lends its amount from resting as more of the loan's claim and pays the loan's holder, less the hub's fee.
/// @dev Never deployed. Every fee is the hub's own share here, so the vault's gross NAV moves only by the cash it pays or is paid.
/// @dev Custody is modelled only for a pledge of this scene's own title collection, which an open pulls from the vault.
contract BoundaryHub {
    BoundaryTitle public title; // linked to the vault's TITLE, so the titles this hub mints are the ones the vault hands over
    IBoundaryCash public cash; // linked to the vault's asset

    mapping(address lender => mapping(address quote => uint256)) public lenderAssets; // resting, live claims and owed
    mapping(address lender => mapping(address quote => uint256)) public lenderOwed; // the part of it credited and collectable
    mapping(address lender => mapping(address quote => uint256)) internal unsoldOf;
    mapping(address lender => mapping(address quote => uint256)) internal settledOf;
    mapping(address lender => mapping(address quote => mapping(address collateral => uint256))) public lentAgainst;
    mapping(bytes32 id => MarketParams) internal markets;
    mapping(uint256 loanId => bytes32) public loanMarket;
    mapping(bytes32 id => uint256) public restingOf;
    mapping(uint256 loanId => address) public borrowerOf;
    mapping(uint256 loanId => uint256) public debtOf;
    mapping(bytes32 slot => bytes32) internal words; // what `extsload` answers, the loan's term word among them
    mapping(uint256 loanId => uint256) internal potOf; // what `redeemInKind` answers
    uint256 internal openFee; // the hub's share an open keeps from the principal
    uint256 internal refinanceFee; // the hub's share a refinance keeps from the net
    uint256 internal extendAnswer; // the fee `extend` pulls and answers
    uint256 internal drawMoreFee; // the hub's share a top-up keeps from its amount
    uint256 public nextId; // the id the next open or refinance issues

    uint256 public opens; // how many opens the vault asked for
    address public openBorrower; // the last open's borrower
    uint256 public openPrincipal; // the last open's principal
    uint64 public openTenor; // the last open's tenor
    uint256 public extends; // how many extends the vault asked for
    uint256 public extendedLoan; // the last extend's loan
    uint256 public refinances; // how many refinances the vault asked for
    uint256 public refinancedLoan; // the last refinance's retiring loan
    uint256 public refinancedPrincipal; // the last refinance's principal
    uint64 public refinancedTenor; // the last refinance's tenor
    uint256 public topUps; // how many top-ups the vault asked for
    uint256 public toppedUpLoan; // the last top-up's loan
    uint256 public toppedUpAmount; // the last top-up's amount
    bool public rested; // a deposit landed since the rule cleared it

    /// @notice The entry gate's read: the pair's unsold pots, and its pots ever settled.
    function lenderUnresolved(address lender, address quote) external view returns (uint256 unsoldPots, uint256 settledPots) {
        return (unsoldOf[lender][quote], settledOf[lender][quote]);
    }

    /// @notice A row's read: what is lent against the collateral, and no unsold units.
    function lenderByCollateral(address lender, address quote, address collateral) external view returns (uint256 lent, uint256 unsoldUnits) {
        return (lentAgainst[lender][quote][collateral], 0);
    }

    /// @notice A market's stored params; a quote of zero is a market not yet created, and a stored market hashes to its id, as the hub keys it.
    function idToMarketParams(bytes32 id) public view returns (MarketParams memory p) {
        p = markets[id];
        require(p.quote == address(0) || keccak256(abi.encode(p)) == id, "inconsistent market");
    }

    /// @notice The collateral of a loan's market, as a collect books it.
    function collateralOf(uint256 loanId) external view returns (address) {
        return markets[loanMarket[loanId]].collateral;
    }

    /// @notice Store a market under the hash of its params, as the hub keys it.
    function createMarket(MarketParams calldata p) external returns (bytes32 id) {
        id = keccak256(abi.encode(p));
        markets[id] = p;
    }

    /// @notice Pull `assets` from the lender into the market's resting cash.
    function deposit(bytes32 id, uint256 assets) external {
        cash.transferFrom(msg.sender, address(this), assets);
        restingOf[id] += assets;
        lenderAssets[msg.sender][address(cash)] += assets;
        rested = true;
    }

    /// @notice Pay every resting unit back to `to`.
    function withdraw(bytes32 id, uint256, address to, uint256) external returns (uint256 paid) {
        paid = restingOf[id];
        restingOf[id] = 0;
        lenderAssets[msg.sender][address(cash)] -= paid;
        cash.transfer(to, paid);
    }

    /// @notice Pay the lender what it is owed.
    function collect(address quote, address to) external returns (uint256 paid) {
        paid = lenderOwed[msg.sender][quote];
        lenderOwed[msg.sender][quote] = 0;
        lenderAssets[msg.sender][quote] -= paid;
        if (paid != 0) cash.transfer(to, paid);
    }

    /// @notice Lend `principal` from resting as a live claim, pay the borrower the principal less the hub's fee, and title it.
    function open(bytes32 id, uint256 units, uint256 principal, uint64 tenor, address borrower, OpenBounds calldata) external returns (uint256 loanId) {
        require(restingOf[id] >= principal && openFee <= principal, "no cash");
        restingOf[id] -= principal;
        if (markets[id].collateral == address(title)) title.transferFrom(msg.sender, address(this), units);
        loanId = nextId;
        (opens, openBorrower, openPrincipal, openTenor) = (opens + 1, borrower, principal, tenor);
        (loanMarket[loanId], borrowerOf[loanId], debtOf[loanId]) = (id, borrower, principal);
        cash.transfer(borrower, principal - openFee);
        title.mint(borrower, loanId);
    }

    /// @notice Pull the extension's fee from the caller, record the extension, and answer the fee.
    function extend(uint256 id, uint256, bytes calldata) external returns (uint256 fee) {
        fee = extendAnswer;
        cash.transferFrom(msg.sender, address(this), fee);
        (extends, extendedLoan) = (extends + 1, id);
    }

    /// @notice Retire the loan into a successor at `dst`: the net over the old debt lent from resting and paid to the caller, less the hub's fee.
    /// @dev A principal under the old debt refuses here; the hub admits one only where the old fee's refund covers the gap, which is not modelled.
    function refinanceTo(MigrateArgs calldata m) external returns (uint256 newId) {
        uint256 debtOld = debtOf[m.id];
        require(m.newPrincipal >= debtOld, "pay-down");
        uint256 fresh = m.newPrincipal - debtOld;
        require(restingOf[m.dst] >= fresh && refinanceFee <= fresh, "no cash");
        restingOf[m.dst] -= fresh;
        newId = nextId;
        (refinances, refinancedLoan, refinancedPrincipal, refinancedTenor) = (refinances + 1, m.id, m.newPrincipal, m.newTenor);
        (loanMarket[newId], borrowerOf[newId], debtOf[newId], debtOf[m.id]) = (m.dst, msg.sender, m.newPrincipal, 0);
        if (fresh > refinanceFee) cash.transfer(msg.sender, fresh - refinanceFee);
        title.mint(msg.sender, newId);
    }

    /// @notice Lend `amount` more on the loan from its market's resting cash, raise its debt, and pay its holder the amount less the hub's fee.
    function drawMore(uint256 id, uint256 amount, OpenBounds calldata) external returns (uint256 fee) {
        bytes32 m = loanMarket[id];
        fee = drawMoreFee;
        require(restingOf[m] >= amount && fee <= amount, "no cash");
        restingOf[m] -= amount;
        debtOf[id] += amount;
        (topUps, toppedUpLoan, toppedUpAmount) = (topUps + 1, id, amount);
        cash.transfer(borrowerOf[id], amount - fee);
    }

    /// @notice A loan's pot, as a figure.
    function redeemInKind(uint256 loanId, address) external view returns (uint256) {
        return potOf[loanId];
    }

    /// @notice A raw word of the hub's storage, as the term reader asks it.
    function extsload(bytes32 slot) external view returns (bytes32) {
        return words[slot];
    }

    /// @notice The settle verbs a collect ends a loan by; they record nothing.
    function forceClose(uint256) external {}

    /// @notice See `forceClose`.
    function finalize(uint256) external {}

    /// @notice A loss the hub books against the lender: its pooled figure falls by `loss`.
    function writeDown(address lender, address quote, uint256 loss) external {
        lenderAssets[lender][quote] -= loss;
    }
}
