// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {AceVaultFactory} from "../../../src/vault/AceVaultFactory.sol";
import {Terms, VaultConfig} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {CuratorTerms, CuratorTermsConfig, Listing, Row} from "../../../src/vault/curated/CuratorTerms.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {MockMonthlyHub, MockPerTermHub, RatePeriodProbe} from "../../mocks/MockRatePeriodHubs.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @title AceVaultRatePerYear
/// @notice The vault side of the per-year rate: the vault, its factory and the curated terms refuse a hub that names no 365-day period.
/// @notice A curated row's rate is bps a year, railed at its own `maxTenor` alone; the vault's renewal prices the hub's own fee to the atom.
/// @dev The refusal is named by selector, so these rows compile against products that do not yet probe.
contract AceVaultRatePerYearTest is AceVaultBaseRig {
    bytes4 internal constant BAD_ROW = bytes4(keccak256("BadRow()"));
    uint256 internal constant RATE = 73; // a fifth of 365, so a whole day prices to the atom
    uint256 internal constant MIN_P = 10e6;

    /// @dev A curated config on `hub`, the rail a day to a year, its vault an address with no code: construction alone is the subject.
    function _termsCfg(address hub) internal view returns (CuratorTermsConfig memory) {
        return CuratorTermsConfig({
            vault: address(0xBEEF),
            ace: hub,
            asset: address(usdc),
            minPrincipal: MIN_P,
            coverageWad: 1.4e18,
            timelock: 3 days,
            minTenor: 1 days,
            maxTenor: 365 days
        });
    }

    /// @dev One listing of the rig collateral at `rate` over a day to `maxTenor`.
    function _rowAt(uint256 rate, uint64 maxTenor) internal view returns (Listing[] memory l) {
        l = new Listing[](1);
        l[0] = Listing({
            collateral: address(coll), row: Row({record: address(record), bufferBps: 1000, lenderAprBps: uint16(rate), minTenor: 1 days, maxTenor: maxTenor})
        });
    }

    /* ============================== the probe at construction ============================== */

    /// @notice THE VAULT REFUSES A HUB THAT NAMES NO 365-DAY PERIOD: one with no `RATE_PERIOD()`, and one naming another period.
    function test_TheVaultRefusesAHubWithoutAYearPeriod() public {
        VaultConfig memory cfg = _cfg();
        ProductConfig memory pc = _pc();
        cfg.ace = address(new MockPerTermHub());
        vm.expectRevert(RatePeriodProbe.NOT_PER_YEAR);
        new AceVault(cfg, pc, _listing(address(0xBEEF), _caps(UNCAPPED, 0, UNCAPPED)), "Base", "bVLT");
        cfg.ace = address(new MockMonthlyHub());
        vm.expectRevert(RatePeriodProbe.NOT_PER_YEAR);
        new AceVault(cfg, pc, _listing(address(0xBEEF), _caps(UNCAPPED, 0, UNCAPPED)), "Base", "bVLT");
    }

    /// @notice THE FACTORY REFUSES IT TOO, so no factory is ever pinned to a hub of the old unit.
    function test_TheFactoryRefusesAHubWithoutAYearPeriod() public {
        address perTerm = address(new MockPerTermHub());
        vm.expectRevert(RatePeriodProbe.NOT_PER_YEAR);
        new AceVaultFactory(keccak256("any code"), perTerm);
        address monthly = address(new MockMonthlyHub());
        vm.expectRevert(RatePeriodProbe.NOT_PER_YEAR);
        new AceVaultFactory(keccak256("any code"), monthly);
        assertEq(new AceVaultFactory(keccak256("any code"), address(ace)).HUB(), address(ace), "CONTROL: the rig's hub binds");
    }

    /// @notice CURATED TERMS REFUSE IT AT CONSTRUCTION, before any row is read.
    function test_CuratedTermsRefuseAHubWithoutAYearPeriod() public {
        Listing[] memory none = new Listing[](0);
        CuratorTermsConfig memory c = _termsCfg(address(new MockPerTermHub()));
        vm.expectRevert(RatePeriodProbe.NOT_PER_YEAR);
        new CuratorTerms(c, none);
        c = _termsCfg(address(new MockMonthlyHub()));
        vm.expectRevert(RatePeriodProbe.NOT_PER_YEAR);
        new CuratorTerms(c, none);
        assertEq(new CuratorTerms(_termsCfg(address(ace)), none).ACE(), address(ace), "CONTROL: the rig's hub binds");
    }

    /* ============================== the curated row's rail ============================== */

    /// @notice A CURATED ROW'S RATE IS RAILED AT ITS OWN `maxTenor`: 27,651 a year lists at 30 days and 27,652 does not.
    /// @notice At a one-year `maxTenor` the edge is 2,272 and 2,273, whatever the row's shortest term.
    function test_CuratedRowRailsTheRateAtItsMaxTenor() public {
        CuratorTermsConfig memory c = _termsCfg(address(ace));
        CuratorTerms t = new CuratorTerms(c, _rowAt(27_651, 30 days));
        assertEq(t.rowOf(address(coll)).lenderAprBps, 27_651, "27,651 a year lists at a 30-day maxTenor");
        Listing[] memory over = _rowAt(27_652, 30 days);
        vm.expectRevert(BAD_ROW);
        new CuratorTerms(c, over);

        t = new CuratorTerms(c, _rowAt(2272, 365 days));
        assertEq(t.rowOf(address(coll)).lenderAprBps, 2272, "2,272 a year lists at a one-year maxTenor");
        over = _rowAt(2273, 365 days);
        vm.expectRevert(BAD_ROW);
        new CuratorTerms(c, over);
    }

    /* ============================== the renewal ============================== */

    /// @notice THE VAULT'S RENEWAL PRICES THE HUB'S OWN FEE: a day added on 1,000 USDC at 73 a year is 22,000 atoms, quoted and charged.
    /// @dev `ceil(1e9 * 73 * 1 days * 11000 / (1e8 * 365 days)) = 22,000` exactly; a holder's cap at that figure clears.
    function test_ExtendForPricesTheHubsFeeToTheAtom() public {
        MarketParams memory p = _market(address(coll), record);
        p.lenderAprBps = RATE;
        terms.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        uint256 loanId = _borrow();
        address title = ace.POSITION_TITLE();
        vm.prank(borrower);
        IERC721(title).setApprovalForAll(address(vault), true);
        _warpBy(1 days);

        usdc.mint(borrower, 22_000);
        vm.prank(borrower);
        usdc.approve(address(vault), 22_000);
        uint256 wallet = usdc.balanceOf(borrower);
        vm.prank(borrower);
        uint256 fee = IAceVaultDoor(address(vault)).extendFor(loanId, 22_000, 0, "", "");
        assertEq(fee, 22_000, "the vault quotes the hub's fee on the day added");
        assertEq(wallet - usdc.balanceOf(borrower), 22_000, "and the holder pays exactly it");
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "the loan runs its tenor again from now");
    }
}
