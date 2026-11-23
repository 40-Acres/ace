// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {CuratorTerms, CuratorTermsConfig, Listing, Row} from "../../../src/vault/curated/CuratorTerms.sol";
import {IAceLenderOps} from "../../../src/interfaces/IAceLenderOps.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {IPersistenceRecord} from "../../../src/interfaces/IPersistenceRecord.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";

/// @title CuratorTermsRoomFailClosedTest
/// @notice While a pot is unsold, CuratorTerms prices it off the market's record; a record that cannot answer makes the room zero, never a revert.
/// @notice CONTROL: a live record gives exactly the effective cap less lent and the pot at the record's minimum, saturating, as today.
/// @dev A record that answers zero still values the pot at zero today; that is pinned as today's behaviour and is out of scope here.
contract CuratorTermsRoomFailClosedTest is AceVaultBaseRig {
    uint256 internal constant MIN_P = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint64 internal constant ROW_LOCK = 3 days;
    uint16 internal constant BUFFER_BPS = 1000;
    uint16 internal constant RATE_BPS = 40;
    uint192 internal constant ROW_CAP = 20_000e6; // wide enough that a settled pot at the record's minimum leaves room
    uint256 internal constant Q96 = 1 << 96;

    CuratorTerms internal ct;
    IERC721 internal title;

    function setUp() public override {
        super.setUp();
        (vault, ct) = _deployCurated(_listings(_row(address(record), TENOR, RAIL_MAX)), _caps(ROW_CAP, 0, UNCAPPED));
        _lp(alice, LP_CASH);
        title = IERC721(ace.POSITION_TITLE());
    }

    function _row(address rec, uint64 minT, uint64 maxT) internal pure returns (Row memory) {
        return Row({record: rec, bufferBps: BUFFER_BPS, lenderAprBps: RATE_BPS, minTenor: minT, maxTenor: maxT});
    }

    function _listings(Row memory r) internal view returns (Listing[] memory l) {
        l = new Listing[](1);
        l[0] = Listing({collateral: address(coll), row: r});
    }

    function _termsCfg(address v) internal view returns (CuratorTermsConfig memory) {
        return CuratorTermsConfig({
            vault: v,
            ace: address(ace),
            asset: address(usdc),
            minPrincipal: MIN_P,
            coverageWad: COVERAGE,
            timelock: ROW_LOCK,
            minTenor: RAIL_MIN,
            maxTenor: RAIL_MAX
        });
    }

    /// @dev CuratorTerms first, against the address the vault's create takes, then the vault naming them.
    function _deployCurated(Listing[] memory l, uint192[3] memory c) internal returns (AceVault v, CuratorTerms t) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new CuratorTerms(_termsCfg(predicted), l);
        VaultSeed.fund(_cfg(), predicted);
        ProductConfig memory pc = _pc();
        pc.terms = address(t);
        v = new AceVault(_cfg(), pc, _listing(predicted, c), "Curated", "cVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
    }

    /// @dev A loan through the curated vault settled before its tenor, so its pot sits unsold at the hub; returns that loan's market.
    function _pot() internal returns (MarketParams memory mp) {
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        mp = ace.idToMarketParams(ace.loanMarket(loanId));
        _finalize(loanId);
        (uint256 lent, uint256 unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(lent, 0, "premise: the settled loan holds no lent");
        assertGt(unsold, 0, "premise: the settled pot is unsold");
    }

    // ---- a record that cannot answer is zero room ----

    /// @notice A SICK RECORD, whose minimum reverts, makes the room zero while a pot is unsold: it fails closed and never reverts.
    function test_ASickRecordIsZeroRoomWhileAPotIsUnsold() public {
        MarketParams memory mp = _pot();
        record.setSick(true);
        assertEq(ct.room(mp), 0, "a sick record opened room over an unsold pot");
    }

    /// @notice A RECORD ANSWERING NOTHING makes the room zero while a pot is unsold, rather than refusing with a decode error.
    function test_AnEmptyAnswerRecordIsZeroRoomWhileAPotIsUnsold() public {
        MarketParams memory mp = _pot();
        record.setShortAnswer(true);
        assertEq(ct.room(mp), 0, "an empty answer opened room over an unsold pot");
    }

    /// @notice A RECORD THAT BURNS ITS GAS makes the room zero while a pot is unsold: the 1/64 it leaves returns the zero, tight budget or wide.
    function test_AGasBurningRecordIsZeroRoomWhileAPotIsUnsold() public {
        MarketParams memory mp = _pot();
        vm.etch(address(record), hex"5b600056"); // JUMPDEST PUSH1 0 JUMP: loops until out of gas
        assertEq(ct.room{gas: 30_000}(mp), 0, "a burning record opened room, or ran room out, on a tight budget");
        assertEq(ct.room{gas: 5_000_000}(mp), 0, "a burning record opened room, or ran room out, on a wide budget");
    }

    /// @notice A RECORD WITH NO CODE makes the room zero while a pot is unsold.
    function test_ACodelessRecordIsZeroRoomWhileAPotIsUnsold() public {
        MarketParams memory mp = _pot();
        vm.etch(address(record), "");
        assertEq(ct.room(mp), 0, "a codeless record opened room over an unsold pot");
    }

    /// @notice A RECORD REVERTING WITH THE MAXIMUM AS ITS PAYLOAD is zero room, not a pot priced at that word and not that revert.
    function test_ARecordRevertingWithAMaxWordIsZeroRoom() public {
        MarketParams memory mp = _pot();
        bytes memory ask = abi.encodeCall(IPersistenceRecord.minPrice, (address(usdc), address(coll)));
        vm.mockCallRevert(address(record), ask, abi.encode(type(uint256).max));
        assertEq(ct.room(mp), 0, "a record reverting with a word opened room over an unsold pot");
    }

    /// @dev Have the hub report `lent` and `unsold` for the vault on the rig's collateral, and the record answer `m`.
    function _hubReports(uint256 lent, uint256 unsold, uint256 m) internal {
        bytes memory q = abi.encodeCall(IAceLenderOps.lenderByCollateral, (address(vault), address(usdc), address(coll)));
        vm.mockCall(address(ace), q, abi.encode(lent, unsold));
        record.setMinPrice(m);
    }

    /// @notice A POT WORTH 2^256 OR MORE is zero room, not a `mulDiv` overflow panic: its value is past any cap.
    function test_APotTooLargeToPriceIsZeroRoom() public {
        MarketParams memory mp = _pot();
        _hubReports(0, 1 << 100, type(uint256).max);
        assertEq(ct.room(mp), 0, "a pot priced past 2^256 opened room or panicked");
    }

    /// @notice A POT PRICED AT EXACTLY THE MAXIMUM beside a live loan is zero room, not an overflow panic on lent plus the pot.
    function test_APotAtTheMaximumBesideALoanIsZeroRoom() public {
        MarketParams memory mp = _pot();
        _hubReports(1, Q96, type(uint256).max);
        assertEq(ct.room(mp), 0, "lent plus a maximal pot opened room or panicked");
    }

    /// @notice A POT WORTH EXACTLY 2^256 is zero room, not a `mulDiv` overflow: the unpriceable bound is inclusive, its high word at Q96 itself.
    function test_APotWorthExactlyTwoToThe256IsZeroRoom() public {
        MarketParams memory mp = _pot();
        (uint256 unsold, uint256 m) = (1 << 97, 1 << 255);
        (uint256 high, uint256 low) = Math.mul512(unsold, m);
        assertEq(high, Q96, "premise: the product's high word is Q96 exactly");
        assertEq(low, 0, "premise: the product's low word is zero, so the pot is worth 2^256 to the atom");
        _hubReports(0, unsold, m);
        assertEq(ct.room(mp), 0, "a pot worth exactly 2^256 opened room or panicked");
    }

    /// @notice A POT OF ONE UNIT is still a pot: a sick record makes its room zero, the uncapped answer reaching only an empty count.
    function test_AOneUnitPotUnderASickRecordIsZeroRoom() public {
        MarketParams memory mp = _pot();
        _hubReports(0, 1, record.minPrice(address(usdc), address(coll)));
        record.setSick(true);
        assertEq(ct.room(mp), 0, "a one-unit pot was read as no pot, opening room past a sick record");
    }

    // ---- CONTROLS ----

    /// @notice CONTROL: a live record prices the pot at its minimum, the room exactly the effective cap less lent and the pot, saturating at zero.
    function test_ALiveRecordPricesThePotAtItsMinimum() public {
        MarketParams memory mp = _pot();
        _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        (uint256 lent, uint256 unsold) = ace.lenderByCollateral(address(vault), address(usdc), address(coll));
        assertEq(lent, PRINCIPAL, "premise: the live loan is all that is lent");
        uint256 parked = Math.mulDiv(unsold, record.minPrice(address(usdc), address(coll)), Q96);
        assertApproxEqRel(parked, (unsold * 2e6) / 1e18, 1e9, "premise: the pot is worth two dollars a unit at the minimum");
        uint256 cap = vault.effectiveCap(address(coll));
        assertEq(cap, ROW_CAP, "premise: the row's cap is the effective cap");
        assertGt(cap, lent + parked, "premise: the pot and the loan leave room under the cap");
        assertEq(ct.room(mp), cap - lent - parked, "a live record's room is not the cap less lent and the pot");
        vm.prank(curator);
        vault.submitCap(address(coll), uint192(parked));
        assertEq(ct.room(mp), 0, "a cap under lent and the pot did not saturate to zero");
    }

    /// @notice CONTROL: with no pot unsold the room is uncapped and the record is never asked, sick or not.
    function test_WithNoPotUnsoldTheRecordIsNeverAsked() public {
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        MarketParams memory mp = ace.idToMarketParams(ace.loanMarket(loanId));
        record.setSick(true);
        vm.expectCall(address(record), abi.encodeWithSelector(IPersistenceRecord.minPrice.selector), 0);
        assertEq(ct.room(mp), type(uint256).max, "with no pot unsold the room was capped");
    }

    /// @notice TODAY'S BEHAVIOUR, out of scope: a record answering zero values the pot at zero, so the room is the cap less lent alone.
    function test_TodayARecordAnsweringZeroValuesThePotAtZero() public {
        MarketParams memory mp = _pot();
        record.setMinPrice(0);
        assertEq(ct.room(mp), vault.effectiveCap(address(coll)), "a zero answer did not value the pot at zero");
    }

    /// @notice TODAY'S ORDER: a refinance into a market whose record is sick refuses in the product's own answer, which reads that record before any room.
    /// @dev So no refinance through these terms reaches a room whose record fails throughout: the end-to-end path is the vault half's alone.
    function test_TodayASickRecordRefusesTheRefinanceAnswerBeforeTheRoom() public {
        _pot();
        uint256 loanId = _borrowAs(borrower, address(coll), UNITS, PRINCIPAL);
        vm.prank(borrower);
        title.approve(address(vault), loanId);
        uint256 fresh = read.debtOf(loanId) + MIN_P; // fresh cash, so only the answer's refusal keeps the room unasked
        record.setSick(true);
        vm.expectCall(address(ct), abi.encodeWithSelector(CuratorTerms.room.selector), 0);
        vm.prank(borrower);
        vm.expectRevert(bytes("record sick"));
        IAceVaultDoor(address(vault)).refinanceFor(loanId, address(coll), fresh, TENOR, 0, 0, 0, 0, address(0), "");
    }
}
