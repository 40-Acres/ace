// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../../utils/WarpClock.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceReader} from "../../utils/AceReader.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ace} from "../../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {RefinanceMath} from "../../utils/RefinanceMath.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {PositionManager} from "../../../src/ace/positions/PositionManager.sol";
import {VaultConfig} from "../../../src/curator/AceVault.sol";
import {BorrowRequest} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorVault, Listing, Row} from "../../../src/curator/CuratorVault.sol";

/// @notice The shared rig for the vault-holds-cash suites: one hub, one oracle-priced collateral, one CuratorVault holding the LP cash.
/// @dev Every market a borrow lands in is the vault's own, built by its door; the rig never creates or funds a market itself.
/// @dev The laws the plan names are asserted by helpers here, so each suite checks them after the verb it drives.
abstract contract AceVaultRig is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    CuratorVault internal vault;

    address internal curator = address(0xC0A11);
    address internal guardian = address(0x6A2E);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal borrower = address(0xB0BA);
    address internal keeper = address(0xCAFE);
    address internal stranger = address(0x5EE);

    uint256 internal constant MIN_PRINCIPAL = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint64 internal constant TIMELOCK = 3 days;
    uint16 internal constant BUFFER_BPS = 1000;
    uint16 internal constant RATE_BPS = 40;
    uint64 internal constant MIN_TENOR = 7 days;
    uint64 internal constant MAX_TENOR = 30 days;
    uint256 internal constant LP_CASH = 1_000_000e6;
    uint256 internal constant UNITS = 2_000e18;
    uint256 internal constant PRINCIPAL = 1_000e6;
    uint64 internal constant VEST_W = 1 days;

    function setUp() public virtual {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        record = _record(address(coll), 2e18);
        vault = _newVault(_row(address(record), type(uint192).max));
        _lp(alice, LP_CASH);
    }

    /// @dev An oracle-class mock record on the USDC pair, its windowed minimum and last print at `humanWad`.
    function _record(address c, uint256 humanWad) internal returns (MockPersistenceRecord r) {
        r = new MockPersistenceRecord(address(usdc), c);
        r.setMinPrice(AceFixtures.px(humanWad, address(usdc), c));
        r.setObserved(AceFixtures.px(humanWad, address(usdc), c));
    }

    /// @dev The rig's collateral row: a 10% buffer, 40 bps per week, terms from a week to a month.
    function _row(address rec, uint192 cap) internal pure returns (Row memory) {
        return Row({record: rec, bufferBps: BUFFER_BPS, baseBps: RATE_BPS, minTenor: MIN_TENOR, maxTenor: MAX_TENOR, cap: cap});
    }

    function _cfg() internal view returns (VaultConfig memory) {
        return VaultConfig({ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: 0, vestWindow: VEST_W});
    }

    /// @dev A CuratorVault listing the rig's collateral on `row` from deploy.
    function _newVault(Row memory row) internal returns (CuratorVault v) {
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: row});
        v = new CuratorVault(_cfg(), MIN_PRINCIPAL, COVERAGE, TIMELOCK, l, "Curator", "cVLT");
    }

    function _lp(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _req(uint256 units, uint256 principal, uint64 tenor) internal view returns (BorrowRequest memory) {
        return BorrowRequest({collateral: address(coll), units: units, principal: principal, tenor: tenor, minPayout: 0, minBufferWad: 0, deadline: 0});
    }

    /// @dev Borrow through the vault's door as `who`, who is minted and approves exactly the units.
    function _borrowAs(address who, uint256 units, uint256 principal, uint64 tenor) internal returns (uint256 loanId) {
        coll.mint(who, units);
        vm.startPrank(who);
        coll.approve(address(vault), units);
        loanId = vault.borrow(_req(units, principal, tenor), "", "");
        vm.stopPrank();
    }

    function _borrow(uint64 tenor) internal returns (uint256) {
        return _borrowAs(borrower, UNITS, PRINCIPAL, tenor);
    }

    function _mid(uint256 loanId) internal view returns (bytes32) {
        return ace.loanMarket(loanId);
    }

    function _mp(uint256 loanId) internal view returns (MarketParams memory) {
        return ace.idToMarketParams(ace.loanMarket(loanId));
    }

    /// @dev An hour before expiry: inside the last tenor, where a holder's extension still lands under a 30-day ceiling.
    function _toWindow(uint256 loanId) internal {
        Loan memory l = read.loan(loanId);
        _warpAtLeastTo(uint256(l.expiry) - 1 hours);
    }

    function _expiry(uint256 loanId) internal view returns (uint256) {
        return read.loan(loanId).expiry;
    }

    /// @dev Repay `amount` of a loan as its title holder, who is minted the cash and approves the hub.
    function _repayAs(address who, uint256 loanId, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(ace), amount);
        ace.repay(loanId, amount);
        vm.stopPrank();
    }

    /// @dev Nothing the vault funds rests across a call: the market reads zero cash.
    function _assertNothingRests(bytes32 id) internal view {
        assertEq(ace.restingOf(id), 0, "law: no vault cash rests in a market between calls");
    }

    /// @dev No approval outlives a door or a roll: the asset to the hub and the collateral to custody both read zero.
    function _assertNoAllowances() internal view {
        assertEq(usdc.allowance(address(vault), address(ace)), 0, "law: no asset allowance to the hub outlives a call");
        assertEq(coll.allowance(address(vault), address(pm)), 0, "law: no collateral allowance to custody outlives a call");
    }

    /// @dev The successor principal that retires `debt` at the market's longest term, floored at `minPrincipal`: the retired roll's own sizing, kept test-side.
    function _succUp(MarketParams memory mp, uint256 debt) internal pure returns (uint256) {
        return Math.max(RefinanceMath.principalForOwed(debt, mp.maxTenor, mp.baseBps, mp.minTenor), mp.minPrincipal);
    }
}
