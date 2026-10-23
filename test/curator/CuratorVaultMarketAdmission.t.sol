// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing, Row} from "../../src/curator/CuratorVault.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PocDeployConfig} from "../../src/config/Defaults.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";

/// @notice How a market gets into a vault: the vault's door builds it from the collateral's row, and opens it on the first borrow.
/// @dev THE MODEL: the row fixes every param, the door writes the vault as the one lender and the asset as the quote, and a borrower names neither.
/// @dev No list is kept: a market is the vault's because its params name the vault, and the id is a hash of those params.
contract CuratorVaultMarketAdmissionTest is CuratorVaultBase {
    /// @dev A vault listing the rig collateral on `l`, with no market created at the hub yet.
    function _bare(uint16 fee, Listing[] memory l) internal returns (CuratorVault v) {
        v = new CuratorVault(_cfg(fee), RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, l, "Curator", "cVLT");
    }

    function _bare(uint16 fee) internal returns (CuratorVault v) {
        v = _bare(fee, _listing());
    }

    // ---- tenancy is the vault's ADDRESS, written by the door ----

    /// @dev The door writes the vault's own address into `MarketParams.lender`, which sits in the id preimage.
    /// @dev A second lender is unrepresentable rather than refused, and the market first exists at the vault's first borrow.
    function test_Door_NamesTheVaultAsTheOneLender() public {
        CuratorVault v = _bare(0);
        _lpDeposit(v, alice, 10_000e6);
        (bytes32 id,,) = v.previewTerms(_request(address(collateral), 0, 0), "");
        assertEq(ace.idToMarketParams(id).lender, address(0), "PREMISE: no market exists before the door opens it");

        uint256 loanId = _borrow(v, 1_000e6);
        assertEq(ace.loanMarket(loanId), id, "the borrow landed in the market the door named");
        assertEq(ace.idToMarketParams(id).lender, address(v), "the market admits this vault alone");
    }

    /// @dev Two vaults on the same row never share a market id: the lender in the preimage is the whole difference.
    function test_EachVaultGetsItsOwnMarketId() public {
        Listing[] memory l = _listing(); // one row and one record, shared by both vaults
        CuratorVault a = _bare(0, l);
        CuratorVault b = _bare(0, l);
        (bytes32 idA, MarketParams memory pA,) = a.previewTerms(_request(address(collateral), 0, 0), "");
        (bytes32 idB, MarketParams memory pB,) = b.previewTerms(_request(address(collateral), 0, 0), "");
        assertTrue(idA != idB, "distinct per vault, because the lender is in the preimage");
        pB.lender = pA.lender;
        assertEq(keccak256(abi.encode(pB)), idA, "and the lender is the only field that differs");
    }

    /// @notice A vault ANNOUNCES ITSELF AT CONSTRUCTION, and that event is now the whole of discovery.
    /// @notice There is no register to be listed in: an indexer watches for this, and which vaults a
    /// @notice router then offers is a judgement made where trust decisions already live, off-chain.
    /// @dev So the two fields are load-bearing rather than telemetry, and are pinned as such.
    /// @dev A vault's markets are recognized by their `lender`, which is the vault's own address and needs no announcing.
    function test_TheVaultAnnouncesItselfAtConstruction() public {
        vm.recordLogs();
        CuratorVault v = _bare(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("VaultDeployed(address,address)");
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(v) || logs[i].topics[0] != sig) continue;
            seen++;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), curator, "the curator it names");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(usdc), "the asset it lends");
            assertEq(logs[i].data.length, 0, "and nothing else");
        }
        assertEq(seen, 1, "announced exactly once, at construction and never again");
    }

    // ---- the door builds the market ----

    /// @dev THE CENTRAL PROPERTY: a borrow request carries no quote and no lender, so a borrower cannot express a wrong one.
    /// @dev The door writes the vault's asset and the vault itself from the row, and the market the borrow lands in carries both.
    function test_Door_WritesTheQuoteAndLenderFromTheRow() public {
        CuratorVault v = _bare(0);
        _lpDeposit(v, alice, 10_000e6);
        uint256 loanId = _borrow(v, 1_000e6);

        MarketParams memory got = ace.idToMarketParams(ace.loanMarket(loanId));
        assertEq(got.quote, address(usdc), "the quote is this vault's asset");
        assertEq(got.lender, address(v), "and the lender is this vault");
        Row memory row = v.rowOf(address(collateral));
        assertEq(got.record, row.record, "priced off the row's record");
        assertEq(uint256(got.minTenor), uint256(row.minTenor), "on the row's terms");
    }

    /// @dev A borrow on a collateral with no live row is refused by name and creates no market, whether no row was ever
    /// @dev submitted or one is still waiting out the timelock.
    function testRevert_Borrow_UnlistedCollateral() public {
        CuratorVault v = _bare(0);
        _lpDeposit(v, alice, 10_000e6);
        MockStakeVault foreign = new MockStakeVault(9);
        _expectNotListed(v, foreign);

        Row memory row = _row(address(foreign));
        vm.prank(curator);
        v.submitCollateral(address(foreign), row);
        _warpBy(RIG_TIMELOCK - 1);
        _expectNotListed(v, foreign);
        assertEq(ace.lenderAssets(address(v), address(usdc)), 0, "no loan opened, so the vault lends nothing at the hub");
    }

    /// @dev A door borrow on `coll` refuses `NotListed`, and the pledge never left the borrower.
    function _expectNotListed(CuratorVault v, MockStakeVault coll) internal {
        coll.mint(borrower, COLL);
        uint256 held = coll.balanceOf(borrower);
        vm.startPrank(borrower);
        coll.approve(address(v), COLL);
        vm.expectRevert(CuratorVault.NotListed.selector);
        v.borrow(_request(address(coll), COLL, 1_000e6), "", "");
        vm.stopPrank();
        assertEq(coll.balanceOf(borrower), held, "the pledge never left the borrower");
    }
}
