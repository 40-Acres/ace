// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PolicyRefused, TriggerAboveFloor} from "../../../src/ace/hub/Borrower.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {Extension, IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {MockTerms} from "../vault/MockTerms.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @title AceVaultAdmitsExtensionFuzz
/// @notice The vault as its own roll policy, fuzzed across a caller's ask: one consent, every leg.
/// @notice The base consents exactly when the market is its own, no drain stands, its caps are open, its tenors sit in the rail, and the product consents.
/// @notice The curated product's price leg is the record's windowed minimum at or over the price: one high print cannot win it.
contract AceVaultAdmitsExtensionFuzzTest is AceVaultRig {
    bytes4 internal constant YES = IRollPolicy.admitsExtension.selector;

    /// @dev The extension the hub would hand the vault for the holder appending `MIN_TENOR` to `loanId`; its fee left out.
    function _ext(uint256 loanId) internal view returns (Extension memory e) {
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = ace.idToMarketParams(l.market);
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (l.borrower, loanId, l.borrower, l.collateralUnits, l.debt, l.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (l.expiry, l.expiry + MIN_TENOR, mp, mp);
    }

    /// @notice THE BASE: on a product whose consent a row sets, the answer is the conjunction of the six.
    /// @dev The extension shortens nothing, so the exit gate is not asked; the market's tenors sit at the rig's week unless the rail leg is closed.
    function testFuzz_TheBaseConsentsExactlyWhenEveryLegAdmits(bool ours, bool consent, bool drain, bool rowOpen, bool totalOpen, bool inRail) public {
        (AceVault h, MockTerms t) = _onMockTerms();
        Extension memory e;
        e.dst.lender = ours ? address(h) : stranger;
        e.dst.collateral = address(coll);
        (e.dst.minTenor, e.dst.maxTenor) = (MIN_TENOR, inRail ? MIN_TENOR : h.MAX_TENOR() + 1);
        t.setConsent(MockTerms.Mode.Answer, consent);
        vm.startPrank(curator);
        if (!rowOpen) h.submitCap(address(coll), 0);
        if (!totalOpen) h.submitCap(address(h), 0);
        if (drain) h.setDrain(true);
        vm.stopPrank();
        bool expected = ours && consent && !drain && rowOpen && totalOpen && inRail;
        assertEq(h.admitsExtension(e, ""), expected ? YES : bytes4(0), "the base's consent is not the conjunction of its legs");
    }

    /// @notice THE PRICE LEG on the shipped AceVault, over every record minimum from zero to twice the price.
    /// @notice It is `minPrice >= price`, and a persisted fall below the price moves nothing: the leg reads the minimum alone.
    function testFuzz_ThePriceLegIsTheMinimumAtOrOverThePrice(uint256 mSeed, bool below) public {
        uint256 loanId = _borrow(MIN_TENOR);
        uint256 price = _mp(loanId).price;
        uint256 m = bound(mSeed, 0, 2 * price);
        record.setMinPrice(m);
        record.setBelow(below);
        assertEq(vault.admitsExtension(_ext(loanId), ""), m >= price ? YES : bytes4(0), "the price leg answered other than minPrice >= price");
    }

    /// @notice THE CURATOR'S LEGS bind the market's dials: a different record, rate or tenor bound refuses, as a foreign lender does.
    /// @dev The other record is a live, healthy one, so its refusal is the row's and never a price leg reading a dead address.
    function testFuzz_ACuratorLegOffTheRowRefuses(uint8 which) public {
        uint256 loanId = _borrow(MIN_TENOR);
        Extension memory e = _ext(loanId);
        assertEq(vault.admitsExtension(e, ""), YES, "PREMISE: the vault consents to its own market as built");
        uint256 leg = which % 5;
        if (leg == 0) e.dst.record = address(_record(address(coll), 2e18));
        else if (leg == 1) e.dst.lenderAprBps += 1;
        else if (leg == 2) e.dst.minTenor += 1;
        else if (leg == 3) e.dst.maxTenor += 1;
        else e.dst.lender = stranger;
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "a market off the vault's row was consented to");
    }

    /// @notice THE DRAIN refuses every extension, and lifting it restores the consent.
    function test_TheDrainRefusesTheExtension() public {
        uint256 loanId = _borrow(MIN_TENOR);
        Extension memory e = _ext(loanId);
        vm.prank(curator);
        vault.setDrain(true);
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "the draining vault consented");
        vm.prank(curator);
        vault.setDrain(false);
        assertEq(vault.admitsExtension(e, ""), YES, "CONTROL: lifting the drain restores the consent");
    }

    /// @notice AT THE HUB, under one low print, the holder's own extension is refused: at the minimum, by the vault or by admission.
    function testFuzz_UnderOneLowPrintTheHolderCannotExtend(uint256 mSeed) public {
        uint256 loanId = _borrow(MIN_TENOR);
        uint256 price = _mp(loanId).price;
        _toWindow(loanId);
        (bool healthyOk,,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(healthyOk, "CONTROL: at the rig's healthy minimum the holder's own extension lands");
        record.setMinPrice(bound(mSeed, 1, price - 1));
        (bool holderOk, bytes4 holderWhy,) = ace.tryExtend(loanId, 0, "", borrower);
        assertFalse(holderOk, "the holder extended at a minimum under the price");
        bool priced = holderWhy == PolicyRefused.selector || holderWhy == TriggerAboveFloor.selector;
        assertTrue(priced, "refused by the low print: the vault's windowed form, or admission at the minimum");
    }
}
