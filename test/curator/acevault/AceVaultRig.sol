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
import {AceVault, VaultConfig} from "../../../src/curator/AceVault.sol";
import {AceVaultFactory} from "../../../src/curator/AceVaultFactory.sol";
import {CapListing} from "../../../src/curator/AceVaultCaps.sol";
import {MockTerms} from "../vault/MockTerms.sol";
import {BorrowRequest} from "../../../src/curator/AceVaultFlows.sol";
import {CuratorTerms, Listing, Row} from "../../../src/entities/curated/CuratorTerms.sol";
import {CuratedVaults} from "../../utils/CuratedVaults.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {IAceVaultLens, VaultLens} from "../../utils/VaultLens.sol";

/// @notice The shared rig for the vault-holds-cash suites: one hub, one oracle-priced collateral, one curated AceVault holding the LP cash.
/// @dev The vault names CuratorTerms and is deployed through the rig's factory, the terms first against its prediction.
/// @dev Every market a borrow lands in is the vault's own, built by its door; the rig never creates or funds a market itself.
/// @dev The laws the plan names are asserted by helpers here, so each suite checks them after the verb it drives.
abstract contract AceVaultRig is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    AceVault internal vault;
    AceVaultFactory internal vaultFactory;
    uint256 internal vaultSalt; // each factory deploy from this rig takes the next salt
    IAceVaultLens internal vlens; // the vault's stored figures: requests, holds, caps

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
    uint16 internal constant RATE_BPS = 2086; // bps a year: the per-year twin of 40 per 7 days
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
        vaultFactory = CuratedVaults.factory(address(ace));
        record = _record(address(coll), 2e18);
        vault = _newVault(_row(address(record)));
        _lp(alice, LP_CASH);
        vlens = VaultLens.deploy();
    }

    /// @dev An oracle-class mock record on the USDC pair, its windowed minimum and last print at `humanWad`.
    function _record(address c, uint256 humanWad) internal returns (MockPersistenceRecord r) {
        r = new MockPersistenceRecord(address(usdc), c);
        r.setMinPrice(AceFixtures.px(humanWad, address(usdc), c));
        r.setObserved(AceFixtures.px(humanWad, address(usdc), c));
    }

    /// @dev The rig's collateral row: a 10% buffer, 2086 bps a year, terms from a week to a month; its cap is the vault's.
    function _row(address rec) internal pure returns (Row memory) {
        return Row({record: rec, bufferBps: BUFFER_BPS, lenderAprBps: RATE_BPS, minTenor: MIN_TENOR, maxTenor: MAX_TENOR});
    }

    function _cfg() internal view returns (VaultConfig memory) {
        return
            VaultConfig({
                ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: 0, vestWindow: VEST_W, seed: VaultSeed.SEED
            });
    }

    /// @dev The curated terms every rig vault takes: the rig's floor ticket, coverage and timelock, listed rows uncapped.
    function _curated() internal pure returns (CuratedVaults.Terms memory) {
        return CuratedVaults.Terms(MIN_PRINCIPAL, COVERAGE, TIMELOCK, CuratedVaults.UNCAPPED);
    }

    /// @dev A curated AceVault listing the rig's collateral on `row` from deploy, uncapped, through the rig's factory.
    function _newVault(Row memory row) internal returns (AceVault v) {
        Listing[] memory l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: row});
        v = CuratedVaults.viaFactory(vaultFactory, bytes32(++vaultSalt), _cfg(), _curated(), l, "Curator", "cVLT");
    }

    /// @dev The curated terms `v` names, where its rows live.
    function _terms(AceVault v) internal view returns (CuratorTerms) {
        return CuratedVaults.terms(v);
    }

    /// @dev A vault whose product is a `MockTerms` a row steers, seeded with the rig's LP cash: the rig collateral and the total uncapped.
    function _onMockTerms() internal returns (AceVault v, MockTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new MockTerms(predicted, address(ace));
        CapListing[] memory c = new CapListing[](2);
        (c[0], c[1]) = (CapListing(address(coll), CuratedVaults.UNCAPPED), CapListing(predicted, CuratedVaults.UNCAPPED));
        VaultSeed.fund(_cfg(), predicted);
        v = new AceVault(_cfg(), CuratedVaults.product(address(t), TIMELOCK), c, "Mocked", "mVLT");
        usdc.mint(alice, LP_CASH);
        vm.startPrank(alice);
        usdc.approve(address(v), LP_CASH);
        v.deposit(LP_CASH, alice);
        vm.stopPrank();
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
        return Math.max(RefinanceMath.principalForOwed(debt, mp.maxTenor, mp.lenderAprBps), mp.minPrincipal);
    }
}
