// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../../utils/WarpClock.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceReader} from "../../utils/AceReader.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {Ace} from "../../../src/ace/hub/Ace.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {PositionManager} from "../../../src/ace/positions/PositionManager.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {CapListing, ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {BorrowRequest, Terms, VaultConfig} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {Extension} from "../../../src/interfaces/IRollPolicy.sol";
import {MockTerms} from "./MockTerms.sol";
import {IAceVaultLens, VaultLens} from "../../utils/VaultLens.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";

/// @notice The shared rig for the concrete AceVault: one hub, one collateral and record, one vault whose product is a `MockTerms` a row steers.
/// @dev The vault is deployed directly, its terms first against the address the vault's create will take; the factory suites deploy through it.
/// @dev By default the rig collateral is listed uncapped, the wildcard is zero and the total uncapped, with a tenor rail of a day to thirty.
abstract contract AceVaultBaseRig is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal record;
    AceVault internal vault;
    MockTerms internal terms;
    IAceVaultLens internal vlens; // the vault's stored figures: requests, holds, caps, room and the drawdown

    address internal curator = address(0xC0A11);
    address internal guardian = address(0x6A2E);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal borrower = address(0xB0BA);
    address internal stranger = address(0x5EE);

    uint64 internal constant RAIL_MIN = 1 days;
    uint64 internal constant RAIL_MAX = 30 days;
    uint64 internal constant CAP_LOCK = 3 days;
    uint64 internal constant VEST_W = 1 days;
    uint64 internal constant TENOR = 7 days;
    uint256 internal constant LP_CASH = 1_000_000e6;
    uint256 internal constant UNITS = 2_000e18;
    uint256 internal constant PRINCIPAL = 1_000e6;
    uint192 internal constant UNCAPPED = type(uint192).max;

    function setUp() public virtual {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        record = _record(address(coll));
        (vault, terms) = _deploy(_cfg(), _pc(), _caps(UNCAPPED, 0, UNCAPPED));
        _setTerms(address(coll), record);
        _lp(alice, LP_CASH);
        vlens = VaultLens.deploy();
    }

    function _cfg() internal view returns (VaultConfig memory) {
        return
            VaultConfig({
                ace: address(ace), asset: address(usdc), curator: curator, guardian: guardian, perfFeeBps: 0, vestWindow: VEST_W, seed: VaultSeed.SEED
            });
    }

    /// @dev The product config every suite starts from; the terms field is filled by `_deploy`.
    function _pc() internal pure returns (ProductConfig memory) {
        return
            ProductConfig({terms: address(0), door: address(0), inKind: false, drainable: true, capTimelock: CAP_LOCK, minTenor: RAIL_MIN, maxTenor: RAIL_MAX});
    }

    /// @dev The three caps a suite most often sets: the rig collateral's row, the wildcard and the total; a zero row is left unlisted.
    /// @dev The total's key is the vault itself, so the array is filled once its address is known.
    function _caps(uint192 row, uint192 wildcard, uint192 total) internal pure returns (uint192[3] memory) {
        return [row, wildcard, total];
    }

    /// @dev Deploy a MockTerms at the address the next create takes, then the vault there, listing `c` against the rig collateral.
    function _deploy(VaultConfig memory cfg, ProductConfig memory pc, uint192[3] memory c) internal returns (AceVault v, MockTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new MockTerms(predicted, address(ace));
        pc.terms = address(t);
        VaultSeed.fund(cfg, predicted);
        v = new AceVault(cfg, pc, _listing(predicted, c), "Base", "bVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
    }

    /// @dev The cap listing for a vault at `v`: the rig row when nonzero, the wildcard when nonzero, and the total.
    function _listing(address v, uint192[3] memory c) internal view returns (CapListing[] memory l) {
        uint256 n = 1 + (c[0] != 0 ? 1 : 0) + (c[1] != 0 ? 1 : 0);
        l = new CapListing[](n);
        uint256 i;
        if (c[0] != 0) l[i++] = CapListing(address(coll), c[0]);
        if (c[1] != 0) l[i++] = CapListing(address(0), c[1]);
        l[i] = CapListing(v, c[2]);
    }

    /// @dev An oracle-class mock record on the USDC pair for `c`, its minimum and last print at twice par.
    function _record(address c) internal returns (MockPersistenceRecord r) {
        r = new MockPersistenceRecord(address(usdc), c);
        r.setMinPrice(AceFixtures.px(2e18, address(usdc), c));
        r.setObserved(AceFixtures.px(2e18, address(usdc), c));
    }

    /// @dev The vault's market on `c`: par, the vault as lender, no bounty, the hub's ask on, a week-long term inside the rail.
    function _market(address c, MockPersistenceRecord r) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), c);
        p.record = address(r);
        p.lender = address(vault);
        p.settleBountyBps = 0;
        p.minTenor = TENOR;
        p.maxTenor = TENOR;
    }

    /// @dev Point the product at `c`'s market, drawing the rig's units and principal at the market's term.
    function _setTerms(address c, MockPersistenceRecord r) internal returns (MarketParams memory p) {
        p = _market(c, r);
        terms.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
    }

    function _req(address c, uint256 units, uint256 principal, uint64 tenor) internal pure returns (BorrowRequest memory) {
        return BorrowRequest({collateral: c, units: units, principal: principal, tenor: tenor, minPayout: 0, minBufferWad: 0, deadline: 0});
    }

    function _lp(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev Borrow through the vault as `who`, who is minted and approves exactly the units of `c`.
    function _borrowAs(address who, address c, uint256 units, uint256 principal) internal returns (uint256 loanId) {
        MockStakeVault(c).mint(who, units);
        vm.startPrank(who);
        MockStakeVault(c).approve(address(vault), units);
        loanId = vault.borrow(_req(c, units, principal, 0), "", "");
        vm.stopPrank();
    }

    function _borrow() internal returns (uint256) {
        return _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
    }

    /// @dev Expect the next borrow of the rig's ask on `c` to revert with `sel`, the borrower minted and approved.
    function _expectBorrowRevert(address c, bytes4 sel) internal {
        MockStakeVault(c).mint(borrower, UNITS);
        vm.startPrank(borrower);
        MockStakeVault(c).approve(address(vault), UNITS);
        BorrowRequest memory r = _req(c, UNITS, PRINCIPAL, 0);
        vm.expectRevert(sel);
        vault.borrow(r, "", "");
        vm.stopPrank();
    }

    /// @dev Fund the holder for any extension fee, approving the hub.
    function _fundFee(address who) internal {
        usdc.mint(who, 1_000_000e6);
        vm.prank(who);
        usdc.approve(address(ace), type(uint256).max);
    }

    /// @dev The extension the holder's own `extend` by the loan's tenor would hand the vault, its fee left out.
    function _ext(uint256 loanId) internal view returns (Extension memory e) {
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = ace.idToMarketParams(l.market);
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (l.borrower, loanId, l.borrower, l.collateralUnits, l.debt, l.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (l.expiry, uint64(_now()) + l.tenor, mp, mp);
    }

    /// @dev Settle a loan before its tenor on its record's distress, by `finalize`.
    function _finalize(uint256 loanId) internal {
        MockPersistenceRecord r = MockPersistenceRecord(ace.idToMarketParams(ace.loanMarket(loanId)).record);
        r.setBelow(true);
        ace.finalize(loanId);
        r.setBelow(false);
    }
}
