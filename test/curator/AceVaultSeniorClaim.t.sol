// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceVaultFlows} from "../../src/vault/libraries/AceVaultFlows.sol";
import {HubLoanTerm} from "../../src/interfaces/HubLoanTerm.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @dev Exposes the library's internal `seniorClaim` and `bookValue` to a test, against a real hub.
contract SeniorClaimHarness {
    function seniorClaim(address ace, uint256 loanId, uint256 pot, uint256 price) external view returns (uint256) {
        return AceVaultFlows.seniorClaim(ace, loanId, pot, price);
    }

    function bookValue(uint256 units, uint256 price) external pure returns (uint256) {
        return AceVaultFlows.bookValue(units, price);
    }
}

/// @title AceVaultSeniorClaimTest
/// @notice `AceVaultFlows.seniorClaim`: a settled pot's senior claim is the book value of the SMALLER of the pot and the claim's need.
/// @notice The need is read off the hub's own view BEFORE the settlement, never re-derived here, and the debt off the hub's stored word after it.
/// @dev Every row settles a real loan on a real hub through a stranger's `finalize`, so `debtOf` reads zero when the claim is asked.
contract AceVaultSeniorClaimTest is WarpClock {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant PRINCIPAL = 1_000e6;

    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    SeniorClaimHarness internal h;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal mid;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal stranger = address(0x57A2A6E2);

    /// @dev What a settled row hands its assertions.
    struct Settled {
        uint256 id;
        uint256 debt; // the debt the settlement retired, read live before it
        uint256 need; // the hub's own `collateralNeeded` before the settlement
        uint256 pot; // what the settlement put in the pot
        uint256 price; // the market's price
    }

    function setUp() public {
        _warpTo(1_000_000);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = new AceLens(address(ace));
        h = new SeniorClaimHarness();
    }

    /// @dev A recorded market on fresh tokens at a named human price, `1e18` one quote per whole collateral; zero keeps par.
    function _make(uint8 cd, uint256 humanWad) internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", cd);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(type(uint256).max);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        if (humanWad != 0) p.price = AceFixtures.px(humanWad, address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice;
        mid = ace.createMarket(p);
        usdc.mint(alice, 10 * PRINCIPAL);
        vm.startPrank(alice);
        usdc.approve(address(ace), 10 * PRINCIPAL);
        ace.deposit(mid, 10 * PRINCIPAL);
        vm.stopPrank();
    }

    /// @dev Open twice the line, repay `pay`, read the need off the hub, and let a stranger settle it inside the term.
    function _settle(uint256 pay) internal returns (Settled memory s) {
        s.price = ace.idToMarketParams(mid).price;
        uint256 k = ace.idToMarketParams(mid).minCoverageWad;
        uint256 units = 2 * (Math.mulDiv(k * PRINCIPAL, Q96, s.price * 1e18, Math.Rounding.Ceil) + 1); // twice the line, so the take passes the need
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        s.id = ace.open(mid, units, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        if (pay > 0) {
            usdc.mint(borrower, pay);
            vm.startPrank(borrower);
            usdc.approve(address(ace), pay);
            ace.repay(s.id, pay);
            vm.stopPrank();
        }
        s.debt = ace.debtOf(s.id);
        s.need = lens.collateralNeeded(mid, s.id);
        rec.setBelow(true);
        vm.prank(stranger);
        ace.finalize(s.id);
        rec.setBelow(false);
        s.pot = read.invPotOf(mid, s.id);
        assertEq(ace.debtOf(s.id), 0, "PREMISE: the settled loan owes nothing through debtOf");
        assertEq(uint256(ace.extsload(HubLoanTerm.debtSlot(s.id))), s.debt, "PREMISE: the stored word kept the debt the settlement retired");
    }

    function _claim(Settled memory s, uint256 pot) internal view returns (uint256) {
        return h.seniorClaim(address(ace), s.id, pot, s.price);
    }

    /// @notice An in-term pot over the need books the CLAIM, the need at the price, never the pot's value; a floored need would book one atom under it.
    function test_PotOverTheNeed_BooksTheClaimNotThePot() public {
        _make(18, 0);
        Settled memory s = _settle(300e6 + 7);
        assertGt(s.pot, s.need, "PREMISE: the in-term take passed the need");
        assertLt(s.price, Q96, "PREMISE: a collateral atom is worth under a quote atom");
        assertGt(mulmod(s.debt, Q96, s.price), 0, "PREMISE: debt * Q96 is not a multiple of the price, so the need's ceil and floor differ");
        assertLt(h.bookValue(Math.mulDiv(s.debt, Q96, s.price), s.price), s.debt, "PREMISE: a floored need would book under the claim");

        uint256 d = _claim(s, s.pot);

        assertEq(d, s.debt, "the senior claim is the claim itself");
        assertEq(d, h.bookValue(s.need, s.price), "which is the hub's need at the price");
        assertLt(d, h.bookValue(s.pot, s.price), "and under the whole pot's value: the surplus is no recovery owed");
    }

    /// @notice A pot of exactly the need books whole, the claim; one atom more books no more.
    function test_PotAtTheNeed_BooksThePotWholeAndOneMoreAtomAddsNothing() public {
        _make(18, 0);
        Settled memory s = _settle(123_456_789);
        assertEq(_claim(s, s.need), h.bookValue(s.need, s.price), "a pot of the need books its whole value");
        assertEq(_claim(s, s.need), s.debt, "which is the claim");
        assertEq(_claim(s, s.need + 1), _claim(s, s.need), "one atom over the need adds nothing");
    }

    /// @notice A SHORT pot, under the need, books what it holds and no more: the cap at the need never inflates a short settlement.
    function test_ShortPot_BooksWhatThePotHolds() public {
        _make(18, 0);
        Settled memory s = _settle(0);
        assertEq(_claim(s, s.need - 1), h.bookValue(s.need - 1, s.price), "one atom short books the pot's value");
        assertLt(_claim(s, s.need - 1), s.debt, "which is under the claim");
        assertEq(_claim(s, s.need / 2), h.bookValue(s.need / 2, s.price), "half the need books half's value");
        assertApproxEqAbs(_claim(s, s.need / 2), s.debt / 2, 1, "about half the claim");
        assertEq(_claim(s, 0), 0, "an empty pot books nothing");
    }

    /// @notice A collateral atom worth MORE than a quote atom: the claim is never under-booked, and the need is the least count that covers it.
    function test_AUnitWorthMoreThanAQuoteAtom_TheClaimIsNeverUnderBooked() public {
        _make(8, 60_000e18);
        Settled memory s = _settle(300e6 + 7);
        assertGt(s.price, Q96, "PREMISE: a collateral atom is worth more than a quote atom");
        assertGt(s.pot, s.need, "PREMISE: the in-term take passed the need");

        uint256 d = _claim(s, s.pot);

        assertEq(d, h.bookValue(s.need, s.price), "the senior claim is the hub's need at the price");
        assertGe(d, s.debt, "never under the claim");
        assertLt(h.bookValue(s.need - 1, s.price), s.debt, "and the need is the least count that covers it");
        assertLt(d - s.debt, s.price / Q96 + 1, "so the overshoot is under one atom's worth");
    }

    /// @notice An id the hub never opened stores no debt, so its claim books nothing, whatever pot a caller names.
    function test_AnIdTheHubNeverOpened_BooksNothing() public {
        _make(18, 0);
        assertEq(uint256(ace.extsload(HubLoanTerm.debtSlot(999))), 0, "PREMISE: no loan 999");
        assertEq(h.seniorClaim(address(ace), 999, 1e24, ace.idToMarketParams(mid).price), 0, "no stored debt, no senior claim");
    }

    /// @notice A REAL short settlement, staged: the senior claim on the short pot is the debt less the bad debt the hub recorded, to the atom.
    /// @dev A lot under the need is unreachable by any verb, so the custodian releases and the hub's units word is rewritten, as an ungated withdrawal would.
    function test_AStagedShortSettlement_BooksTheDebtLessTheHubsRecordedLoss() public {
        _make(18, 0);
        uint256 price = ace.idToMarketParams(mid).price;
        uint256 k = ace.idToMarketParams(mid).minCoverageWad;
        uint256 units = Math.mulDiv(k * PRINCIPAL, Q96, price * 1e18, Math.Rounding.Ceil) + 1;
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(pm), units);
        uint256 id = ace.open(mid, units, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        uint256 need = lens.collateralNeeded(mid, id);
        uint256 target = need / 2;
        vm.prank(address(ace));
        pm.release(id, address(0x5111C), units - target);
        vm.store(address(ace), bytes32(uint256(keccak256(abi.encode(id, HubLoanTerm.LOANS))) + 2), bytes32(target));
        rec.setBelow(true);
        vm.prank(stranger);
        ace.finalize(id);
        uint256 pot = read.invPotOf(mid, id);
        (, uint256 bad) = read.shortfallOf(id);
        assertLt(pot, need, "PREMISE: the settlement came up short");
        assertGt(bad, 0, "PREMISE: and the hub recorded a loss");

        uint256 d = h.seniorClaim(address(ace), id, pot, price);

        assertEq(d, h.bookValue(pot, price), "a short pot books what it holds");
        assertEq(d, PRINCIPAL - bad, "which is the debt less the loss the hub recorded");
    }

    /// @notice Any repay and any pot up to three needs: the claim is the book value of the smaller of the pot and the hub's need, and at most the claim.
    function testFuzz_AnyRepayAndPot_BooksTheSmallerOfThePotAndTheNeed(uint256 paySeed, uint256 potSeed) public {
        _make(18, 0);
        uint256 floor_ = ace.idToMarketParams(mid).minPrincipal / 2;
        Settled memory s = _settle(bound(paySeed, 0, PRINCIPAL - floor_));
        uint256 pot = bound(potSeed, 0, 3 * s.need);

        uint256 d = _claim(s, pot);

        assertEq(d, h.bookValue(Math.min(pot, s.need), s.price), "the claim books the smaller of the pot and the need");
        assertLe(d, s.debt, "never more than the claim, while an atom is worth under a quote atom");
        if (pot >= s.need) assertEq(d, s.debt, "and the claim exactly once the pot covers the need");
    }
}
