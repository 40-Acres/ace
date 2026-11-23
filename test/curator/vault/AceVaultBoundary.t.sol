// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BufferBelowMin, PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/vault/AceVault.sol";
import {AceVaultCaps, ProductConfig} from "../../../src/vault/libraries/AceVaultCaps.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../../src/vault/libraries/AceVaultFlows.sol";
import {Extension, IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {MockDoor} from "./AceVaultDoorRig.sol";
import {MockTerms} from "./MockTerms.sol";

/// @title AceVaultBoundaryTest
/// @notice What the vault enforces whatever its product answers: the market is its own, the draw is bound to the ask and railed in tenor,
/// @notice placements fit lendable cash, the row, the total and the product's room, the write calls cannot re-enter, and consent fails closed.
/// @dev Driven through `MockTerms`, which answers anything a row sets and can revert, burn its gas, bomb or answer a malformed word.
contract AceVaultBoundaryTest is AceVaultBaseRig {
    bytes4 internal constant YES = IRollPolicy.admitsExtension.selector;
    bytes4 internal constant REENTERED = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;

    function _t() internal pure returns (Terms memory) {
        return Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0});
    }

    // ---- every refusal the door runs on the market, whatever the product built ----

    /// @notice A market naming another lender is not this vault's.
    function test_place_AForeignLenderIsRefused() public {
        MarketParams memory p = _market(address(coll), record);
        p.lender = stranger;
        terms.setTerms(p, _t());
        _expectBorrowRevert(address(coll), AceVaultFlows.NotOurLender.selector);
    }

    /// @notice A market quoting anything but the vault's asset is refused before any collateral is pulled.
    function test_place_AForeignQuoteIsRefusedBeforeAnyPull() public {
        MarketParams memory p = _market(address(coll), record);
        p.quote = address(new MockERC20("Other Cash", "OTH", 6));
        terms.setTerms(p, _t());
        _expectBorrowRevert(address(coll), AceVaultFlows.OutsideEnvelope.selector);
        assertEq(coll.balanceOf(borrower), UNITS, "the refusal pulled the pledge");
        assertEq(coll.balanceOf(address(vault)), 0, "and the vault holds none");
    }

    /// @notice The vault's own cash is never collateral, even when the borrower asks for it.
    function test_place_TheVaultsOwnCashIsRefused() public {
        terms.setTerms(_market(address(usdc), record), _t());
        _expectBorrowRevert(address(usdc), AceVaultFlows.CashIsNotCollateral.selector);
    }

    /// @notice The vault's own share is never collateral, even when the borrower asks for it.
    function test_place_TheVaultsOwnShareIsRefused() public {
        terms.setTerms(_market(address(vault), record), _t());
        vm.prank(borrower);
        vm.expectRevert(AceVaultFlows.SharesAreNotCollateral.selector);
        vault.borrow(_req(address(vault), UNITS, PRINCIPAL, 0), "", "");
    }

    /// @notice A market paying any settle bounty is refused: settling the vault's loans is its own duty.
    function test_place_ASettleBountyIsRefused() public {
        MarketParams memory p = _market(address(coll), record);
        p.settleBountyBps = 50;
        terms.setTerms(p, _t());
        _expectBorrowRevert(address(coll), AceVaultFlows.PaysSettleBounty.selector);
    }

    /// @notice In hub-ask mode a market must sell its pots at the hub's ask: one with the ask off is refused, since nothing could bring its pot home.
    function test_place_TheWrongInventoryAskIsRefused() public {
        MarketParams memory p = _market(address(coll), record);
        p.inventoryAsk = false;
        terms.setTerms(p, _t());
        _expectBorrowRevert(address(coll), AceVaultCaps.WrongInventoryMode.selector);
    }

    // ---- the draw is bound to what the borrower asked ----

    /// @notice A token the borrower approved to the vault but did not ask for is refused BEFORE any pull: a product cannot spend another approval.
    function test_bind_ATokenTheBorrowerApprovedButDidNotAskForIsRefusedBeforeAnyPull() public {
        MockStakeVault other = new MockStakeVault(42);
        terms.setTerms(_market(address(other), _record(address(other))), _t());
        other.mint(borrower, UNITS);
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        other.approve(address(vault), UNITS);
        coll.approve(address(vault), UNITS);
        vm.expectRevert(AceVaultCaps.CollateralNotAsked.selector);
        vault.borrow(_req(address(coll), UNITS, PRINCIPAL, 0), "", "");
        vm.stopPrank();
        assertEq(other.balanceOf(borrower), UNITS, "the token the borrower never asked for was pulled");
        assertEq(coll.balanceOf(borrower), UNITS, "and so was the one asked for");
    }

    /// @notice A product drawing more principal than the borrower asked is refused.
    function test_bind_PrincipalAboveTheAskIsRefused() public {
        terms.setTerms(_market(address(coll), record), Terms({units: UNITS, principal: PRINCIPAL + 1, tenor: 0, minBufferWad: 0}));
        _expectBorrowRevert(address(coll), AceVaultCaps.OverAsk.selector);
    }

    /// @notice A product pledging more units than the borrower asked is refused.
    function test_bind_UnitsAboveTheAskAreRefused() public {
        terms.setTerms(_market(address(coll), record), Terms({units: UNITS + 1, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
        _expectBorrowRevert(address(coll), AceVaultCaps.OverAsk.selector);
    }

    /// @notice A product setting a term other than the one the borrower asked is refused; a zero ask leaves the term to the product.
    function test_bind_ATenorOtherThanTheAskIsRefused() public {
        MarketParams memory p = _market(address(coll), record);
        p.maxTenor = 2 * TENOR;
        terms.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: 2 * TENOR, minBufferWad: 0}));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, TENOR);
        vm.expectRevert(AceVaultCaps.TenorNotAsked.selector);
        vault.borrow(r, "", "");
        vm.stopPrank();
    }

    /// @notice The hub is handed the larger buffer of the ask's and the product's, so neither side's floor can be dropped by the other.
    function test_bind_TheHubTakesTheLargerBuffer() public {
        terms.setTerms(_market(address(coll), record), _t());
        coll.mint(borrower, 2 * UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), 2 * UNITS);
        BorrowRequest memory r = _req(address(coll), UNITS, PRINCIPAL, 0);
        r.minBufferWad = 0.99e18;
        vm.expectRevert(BufferBelowMin.selector);
        vault.borrow(r, "", "");
        vm.stopPrank();
        terms.setTerms(_market(address(coll), record), Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0.99e18}));
        vm.prank(borrower);
        vm.expectRevert(BufferBelowMin.selector);
        vault.borrow(_req(address(coll), UNITS, PRINCIPAL, 0), "", "");
    }

    // ---- the tenor rail ----

    /// @notice A market whose shortest term sits under the vault's rail is refused, whatever term is drawn.
    function test_rail_AMarketMinTenorUnderTheRailIsRefused() public {
        MarketParams memory p = _market(address(coll), record);
        p.minTenor = RAIL_MIN - 1;
        terms.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: TENOR, minBufferWad: 0}));
        _expectBorrowRevert(address(coll), AceVaultCaps.TenorOutOfRail.selector);
    }

    /// @notice A market whose longest term sits over the vault's rail is refused, whatever term is drawn.
    function test_rail_AMarketMaxTenorOverTheRailIsRefused() public {
        MarketParams memory p = _market(address(coll), record);
        p.maxTenor = RAIL_MAX + 1;
        terms.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: TENOR, minBufferWad: 0}));
        _expectBorrowRevert(address(coll), AceVaultCaps.TenorOutOfRail.selector);
    }

    /// @notice A drawn term outside the rail is refused by the vault before the hub is asked, under the floor and over the ceiling.
    function test_rail_ADrawnTenorOutsideTheRailIsRefused() public {
        MarketParams memory p = _market(address(coll), record);
        (p.minTenor, p.maxTenor) = (RAIL_MIN, RAIL_MAX);
        terms.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: RAIL_MAX + 1, minBufferWad: 0}));
        _expectBorrowRevert(address(coll), AceVaultCaps.TenorOutOfRail.selector);
        terms.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: RAIL_MIN - 1, minBufferWad: 0}));
        _expectBorrowRevert(address(coll), AceVaultCaps.TenorOutOfRail.selector);
    }

    /// @notice The deploy refuses a rail outside a day to a year, or one whose ends cross; a rail at both ends deploys.
    function test_rail_TheDeployRefusesARailOutsideADayToAYear() public {
        ProductConfig memory pc = _pc();
        pc.minTenor = 1 days - 1;
        _expectDeployRevert(pc, AceVault.TenorRailOutOfBounds.selector);
        pc = _pc();
        pc.maxTenor = 365 days + 1;
        _expectDeployRevert(pc, AceVault.TenorRailOutOfBounds.selector);
        pc = _pc();
        (pc.minTenor, pc.maxTenor) = (10 days, 9 days);
        _expectDeployRevert(pc, AceVault.TenorRailOutOfBounds.selector);
        pc = _pc();
        (pc.minTenor, pc.maxTenor) = (1 days, 365 days);
        (AceVault v,) = _deploy(_cfg(), pc, _caps(UNCAPPED, 0, UNCAPPED));
        assertEq(v.MIN_TENOR(), 1 days, "CONTROL: the rail at its floor deploys");
        assertEq(v.MAX_TENOR(), 365 days, "and at its ceiling");
    }

    /// @notice The deploy refuses a cap timelock outside one to fourteen days.
    function test_TheDeployRefusesACapTimelockOutsideOneToFourteenDays() public {
        ProductConfig memory pc = _pc();
        pc.capTimelock = 1 days - 1;
        _expectDeployRevert(pc, AceVault.TimelockOutOfBounds.selector);
        pc.capTimelock = 14 days + 1;
        _expectDeployRevert(pc, AceVault.TimelockOutOfBounds.selector);
    }

    /// @notice A door deploys only bound, a contract naming the vault; in-kind mode deploys, on a rail no longer than thirty days.
    function test_ADoorDeploysOnlyBoundAndInKindOnlyOnARailOfThirtyDays() public {
        ProductConfig memory pc = _pc();
        pc.door = stranger;
        _expectDeployRevert(pc, IAceVaultDoor.DoorNotBound.selector);
        pc.door = address(new MockDoor(address(vault)));
        _expectDeployRevert(pc, IAceVaultDoor.DoorNotBound.selector);
        pc = _pc();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        pc.door = address(new MockDoor(predicted));
        pc.terms = address(new MockTerms(predicted, address(ace)));
        VaultSeed.fund(_cfg(), predicted);
        AceVault d = new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Base", "bVLT");
        assertEq(d.DOOR(), pc.door, "a bound door deploys");
        pc = _pc();
        pc.inKind = true;
        (AceVault v,) = _deploy(_cfg(), pc, _caps(UNCAPPED, 0, UNCAPPED));
        assertTrue(v.IN_KIND(), "in-kind mode deploys");
        assertEq(v.MAX_TENOR(), 30 days, "premise: on a rail of exactly thirty days");
        pc.maxTenor = 30 days + 1;
        _expectDeployRevert(pc, AceVault.TenorRailOutOfBounds.selector);
    }

    /// @notice A vault deployed without a drain refuses it to every key, the curator and the guardian alike.
    function test_ANonDrainableVaultRefusesTheDrain() public {
        ProductConfig memory pc = _pc();
        pc.drainable = false;
        (AceVault v,) = _deploy(_cfg(), pc, _caps(UNCAPPED, 0, UNCAPPED));
        vm.prank(curator);
        vm.expectRevert(AceVault.NotDrainable.selector);
        v.setDrain(true);
        vm.prank(guardian);
        vm.expectRevert(AceVault.NotDrainable.selector);
        v.setDrain(true);
        vm.prank(curator);
        vault.setDrain(true);
        assertTrue(vault.draining(), "CONTROL: a drainable vault drains");
    }

    function _expectDeployRevert(ProductConfig memory pc, bytes4 sel) internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockTerms t = new MockTerms(predicted, address(ace));
        pc.terms = address(t);
        VaultSeed.fund(_cfg(), predicted);
        vm.expectRevert(sel);
        new AceVault(_cfg(), pc, _listing(predicted, _caps(UNCAPPED, 0, UNCAPPED)), "Base", "bVLT");
    }

    // ---- lendable cash, the row, the total and the product's room ----

    /// @notice A placement past what the requests' hold leaves lendable is refused.
    function test_room_PrincipalOverLendableIsRefused() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestExit(shares);
        assertEq(vault.lendable(), vault.MIN_SEED(), "premise: the request holds all of idle but the genesis seed's");
        assertLt(vault.lendable(), PRINCIPAL, "premise: and what is left is under the draw");
        _expectBorrowRevert(address(coll), AceVaultFlows.OverLendable.selector);
    }

    /// @notice The row binds even when the product answers the most room it can: a product's room only lowers the vault's.
    function test_room_OverTheRowWhenTheProductAnswersTheMaximumIsRefused() public {
        (vault, terms) = _deploy(_cfg(), _pc(), _caps(uint192(PRINCIPAL - 1), 0, UNCAPPED));
        _setTerms(address(coll), record);
        _lp(alice, LP_CASH);
        terms.setRoom(MockTerms.Mode.Answer, type(uint256).max);
        _expectBorrowRevert(address(coll), AceVaultFlows.OverCap.selector);
    }

    /// @notice A product's room under the draw refuses it, though the vault's own caps would admit it.
    function test_room_TheProductsRoomTightens() public {
        terms.setRoom(MockTerms.Mode.Answer, PRINCIPAL - 1);
        _expectBorrowRevert(address(coll), AceVaultFlows.OverCap.selector);
    }

    /// @notice A product whose room reverts, bombs or answers a malformed word reads zero room, so the placement is refused rather than reverting inside it.
    function test_room_AFailedProductRoomReadsZero() public {
        MockTerms.Mode[4] memory modes = [MockTerms.Mode.Revert, MockTerms.Mode.ReturnBomb, MockTerms.Mode.ShortWord, MockTerms.Mode.LongWord];
        for (uint256 i; i < modes.length; i++) {
            terms.setRoom(modes[i], type(uint256).max);
            _expectBorrowRevert(address(coll), AceVaultFlows.OverCap.selector);
        }
    }

    /// @notice A placement past the vault-wide total is refused by name.
    function test_room_OverTheTotalIsRefused() public {
        (vault, terms) = _deploy(_cfg(), _pc(), _caps(UNCAPPED, 0, uint192(PRINCIPAL - 1)));
        _setTerms(address(coll), record);
        _lp(alice, LP_CASH);
        _expectBorrowRevert(address(coll), AceVaultCaps.OverTotal.selector);
    }

    // ---- the write calls run under the lock ----

    /// @notice From either write call, a re-entry into any vault mutator reverts on the lock; the borrow itself completes.
    function test_reenter_TheVaultsMutatorsRefuseFromEitherWriteCall() public {
        bytes[6] memory calls = [
            abi.encodeCall(AceVault.deposit, (1, address(terms))),
            abi.encodeCall(AceVault.withdraw, (1, address(terms), address(terms))),
            abi.encodeCall(AceVault.crank, ()),
            abi.encodeCall(AceVault.borrow, (_req(address(coll), UNITS, PRINCIPAL, 0), bytes(""), bytes(""))),
            abi.encodeCall(AceVault.requestExit, (0)),
            abi.encodeCall(AceVault.submitCap, (address(coll), 0))
        ];
        for (uint256 i; i < calls.length; i++) {
            _assertReentryRefused(calls[i], true);
            _assertReentryRefused(calls[i], false);
        }
    }

    /// @notice A share move from a write call reverts on the lock too, so a product cannot move shares mid-verb.
    function test_reenter_ShareMovesRefuseUnderTheLock() public {
        _assertReentryRefused(abi.encodeCall(IERC20.transfer, (alice, 0)), true);
        _assertReentryRefused(abi.encodeCall(IERC20.transfer, (alice, 0)), false);
        _assertReentryRefused(abi.encodeCall(IERC20.transferFrom, (alice, bob, 0)), true);
        _assertReentryRefused(abi.encodeCall(IERC20.transferFrom, (alice, bob, 0)), false);
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 1), "CONTROL: outside a verb a share moves");
    }

    function _assertReentryRefused(bytes memory data, bool before_) internal {
        terms.setReentry(address(vault), data, before_, !before_);
        _borrow();
        assertTrue(terms.reentered(), "premise: the write call re-entered");
        assertFalse(terms.reentryOk(), "a re-entry from a write call went through");
        assertEq(bytes4(terms.reentryError()), REENTERED, "the re-entry was refused, but not by the lock");
    }

    /// @notice `beforeLend` runs before any cash rests, so a `hub.open` it makes finds nothing of the vault's to draw.
    function test_AHubOpenFromBeforeLendFindsNothingResting() public {
        terms.setTryOpen(true);
        uint256 idle0 = vault.idle();
        _borrow();
        assertEq(terms.beforeCalls(), 1, "premise: beforeLend ran once");
        assertEq(terms.restingAtBefore(), 0, "cash rested in the market when the product's write call ran");
        assertFalse(terms.openOk(), "the product opened a loan of its own against the vault's market");
        assertEq(idle0 - vault.idle(), PRINCIPAL, "the vault paid out other than the one borrow");
    }

    /// @notice `afterLend` runs once the title is the holder's, and is told who holds it.
    function test_AfterLendSeesTheHolder() public {
        uint256 loanId = _borrow();
        assertEq(terms.afterCalls(), 1, "afterLend ran other than once");
        assertEq(terms.lastLoanId(), loanId, "afterLend was told another loan");
        assertEq(terms.lastHolder(), borrower, "afterLend was told another holder");
        assertEq(IERC721(ace.POSITION_TITLE()).ownerOf(loanId), borrower, "the title is not the borrower's");
    }

    // ---- NAV ----

    /// @notice FUZZ: whatever the product answers, NAV is the asset balance plus the hub's ledger for the vault, less the pile.
    function testFuzz_NavIsIdlePlusTheHubLessThePile(uint256 roomSeed, uint256 capSeed, uint256 pSeed, bool yes) public {
        terms.setRoom(MockTerms.Mode.Answer, bound(roomSeed, 0, 10 * PRINCIPAL));
        terms.setEntryCap(MockTerms.Mode.Answer, bound(capSeed, 0, 10 * LP_CASH));
        terms.setConsent(MockTerms.Mode.Answer, yes);
        uint256 p = bound(pSeed, 10e6, 10 * PRINCIPAL);
        terms.setTerms(_market(address(coll), record), Terms({units: UNITS, principal: p, tenor: 0, minBufferWad: 0}));
        try this.borrowFor(p) {} catch {}
        try this.depositFor(bound(capSeed, 1, 10 * LP_CASH)) {} catch {}
        assertEq(vault.totalAssets(), vault.idle() + ace.lenderAssets(address(vault), address(usdc)) - vault.unvested(), "NAV left the vault's own figures");
    }

    function borrowFor(uint256 p) external {
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(vault), UNITS);
        vault.borrow(_req(address(coll), UNITS, p, 0), "", "");
        vm.stopPrank();
    }

    function depositFor(uint256 amt) external {
        _lp(bob, amt);
    }

    // ---- consent: the vault's legs, then the product, asked last and failing closed ----

    /// @notice CONTROL: a clean yes from the product lets the holder extend at the hub.
    function test_consent_TheRealHubExtendLandsOnACleanYes() public {
        uint256 loanId = _borrow();
        _warpBy(1 days);
        _fundFee(borrower);
        assertEq(vault.admitsExtension(_ext(loanId), ""), YES, "premise: every leg admits");
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "the holder's extension did not land");
    }

    /// @notice A product that reverts is a no, at the hub and asked directly, where the vault answers rather than reverting.
    function test_consent_ARevertingProductIsANo() public {
        _assertConsentRefused(MockTerms.Mode.Revert, true);
    }

    /// @notice A product that burns its gas is a no: the vault keeps the remainder to answer with.
    function test_consent_AProductBurningItsGasIsANo() public {
        _assertConsentRefused(MockTerms.Mode.BurnGas, true);
    }

    /// @notice A product that bombs its return is a no: the vault copies one word.
    function test_consent_AReturnBombIsANo() public {
        _assertConsentRefused(MockTerms.Mode.ReturnBomb, true);
    }

    /// @notice A product answering a word other than one, or a short or long answer, is a no.
    function test_consent_AMalformedWordIsANo() public {
        _assertConsentRefused(MockTerms.Mode.BadWord, true);
        _assertConsentRefused(MockTerms.Mode.ShortWord, true);
        _assertConsentRefused(MockTerms.Mode.LongWord, true);
    }

    /// @notice A product reading a guarded hub view is refused under the hub's lock, where the view reverts.
    function test_consent_AProductReadingAGuardedHubViewIsANoAtTheHub() public {
        _assertConsentRefused(MockTerms.Mode.ReadHub, false);
    }

    function _assertConsentRefused(MockTerms.Mode m, bool direct) internal {
        uint256 loanId = _borrow();
        _warpBy(1 days);
        _fundFee(borrower);
        terms.setConsent(m, true);
        if (direct) assertEq(vault.admitsExtension{gas: 2_000_000}(_ext(loanId), ""), bytes4(0), "the vault consented, or reverted, on a hostile product");
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /// @notice An extension whose dial or new term sits outside the tenor rail is refused by the vault's own legs, before the product is asked.
    function test_consent_AnExtensionOutsideTheRailIsRefused() public {
        Extension memory e = _ext(_borrow());
        assertEq(vault.admitsExtension(e, ""), YES, "premise: the extension as built is a yes");
        Extension memory x = e;
        x.newExpiry = uint64(_now()) + RAIL_MAX + 1;
        assertEq(vault.admitsExtension(x, ""), bytes4(0), "a new term past the rail was consented to");
        x = _ext(e.loanId);
        x.dst.maxTenor = RAIL_MAX + 1;
        assertEq(vault.admitsExtension(x, ""), bytes4(0), "a market past the rail's ceiling was consented to");
        x = _ext(e.loanId);
        x.dst.minTenor = RAIL_MIN - 1;
        assertEq(vault.admitsExtension(x, ""), bytes4(0), "a market under the rail's floor was consented to");
    }

    /// @notice A collateral whose effective cap is cut to zero refuses its extensions.
    function test_consent_AZeroRowRefusesTheExtension() public {
        Extension memory e = _ext(_borrow());
        assertEq(vault.admitsExtension(e, ""), YES, "premise: the extension as built is a yes");
        vm.prank(guardian);
        vault.submitCap(address(coll), 0);
        assertEq(vault.admitsExtension(e, ""), bytes4(0), "a zero row consented to an extension");
    }

    /// @notice THE EXIT GATE reads no hub view, so with a request standing a lengthening still lands under the hub's lock.
    /// @dev A gate swapped for a live NAV read reverts there, and the hub refuses the extension: that mutant dies here.
    function test_consent_TheExitGateReadsNoHubViewUnderTheLock() public {
        uint256 loanId = _borrow();
        _warpBy(1 days);
        _fundFee(borrower);
        uint256 shares = vault.balanceOf(alice) / 10;
        vm.prank(alice);
        vault.requestExit(shares);
        assertGt(vlens.requestedShares(address(vault)), 0, "premise: a request stands");
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertEq(read.loan(loanId).expiry, _now() + TENOR, "with a covered request standing, the extension was refused");
    }
}
