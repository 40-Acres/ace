// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {AutoPolicyDisarmed, BelowCoverageLine, GateRefused} from "../../src/ace/hub/Borrower.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockDeleverageKeeper} from "../mocks/MockDeleverageKeeper.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceS1NamedBorrowerTitleTest
/// @notice Audit run 2026-10-03-251533, phase 1: the named-borrower rule reads the CURRENT title holder.
/// @notice A title sale in a market naming its borrower left the loan armed and reserved, while its home roll was refused.
/// @notice FIXED (Y-12 A): in such a market any title move disarms a live armed loan, and `arm` refuses a holder the gate refuses.
contract AceS1NamedBorrowerTitleTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    PositionTitleNFT internal title;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal alice = AceFixtures.LENDER;
    address internal named = address(0xB0B);
    address internal buyer = address(0xB0B2);
    address internal keeper = address(0xCAFE);

    uint64 internal constant TEN7 = 7 days;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant TOP = 400_000e6;

    event AutoPolicySet(uint256 indexed id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record); // a recordless market cannot arm
        p.borrower = named;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
        title = PositionTitleNFT(ace.POSITION_TITLE());

        usdc.mint(alice, TOP);
        vm.startPrank(alice);
        usdc.approve(address(ace), TOP);
        ace.deposit(mid, TOP);
        vm.stopPrank();
    }

    function _openArmed() internal returns (uint256 loanId) {
        vault.mint(named, COLL);
        vm.startPrank(named);
        vault.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, P, TEN7, named, OpenBounds(0, 0, 0));
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
    }

    function _sell(uint256 loanId) internal {
        vm.prank(named);
        title.transferFrom(named, buyer, loanId);
    }

    /// @notice Control: the named borrower holding its own title rolls at expiry.
    function test_Control_TheNamedHolderRolls() public {
        uint256 loanId = _openArmed();
        (bool ok, bytes4 reason,) = ace.tryContinue(loanId);
        assertFalse(ok, "outside the window before expiry");
        _warpTo(uint256(read.loan(loanId).expiry));
        (ok, reason,) = ace.tryContinue(loanId);
        assertTrue(ok, "the named holder's home roll admits");
        uint256 before = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertEq(read.loanCount(), before + 1, "a successor opened");
    }

    /// @notice Premise: the sale moves `Loan.borrower`, so the market's write-once rule now refuses the holder.
    function test_Premise_TheSaleMovesTheBorrowerTheGateReads() public {
        uint256 loanId = _openArmed();
        _sell(loanId);
        assertEq(ace.borrowerOf(loanId), buyer, "retitle moved the borrower of record");
        assertTrue(ace.idToMarketParams(mid).borrower != buyer, "the market names someone else");
    }

    /// @notice The sale DISARMS the loan and releases its reservation, logging the disarm as zeros.
    /// @dev Was the run's premise that the policy and the reservation travelled with the position.
    function test_TheSaleDisarmsTheLoanAndReleasesItsReservation() public {
        uint256 loanId = _openArmed();
        assertGt(read.rollReserve(mid), 0, "PREMISE: arming reserved cash");
        vm.expectEmit(true, false, false, true, address(ace));
        emit AutoPolicySet(loanId, 0, 0, 0);
        _sell(loanId);
        (uint64 tenor, uint16 buf, uint16 fee) = read.autoPolicyOf(loanId);
        assertEq(tenor, 0, "the policy did not travel with the position");
        assertEq(uint256(buf) + uint256(fee), 0, "and nothing of it is left stored");
        assertEq(read.rollReserve(mid), 0, "and the reservation went back to the market");
    }

    /// @notice At expiry the sold loan is simply unarmed: the fold takes the ordinary settle branch, as for any unarmed loan.
    function test_TheSoldLoanSettlesAsAnUnarmedLoan() public {
        uint256 loanId = _openArmed();
        _sell(loanId);
        _warpTo(uint256(read.loan(loanId).expiry));
        (bool ok, bytes4 reason,) = ace.tryContinue(loanId);
        assertFalse(ok, "no roll is offered");
        assertEq(reason, AutoPolicyDisarmed.selector, "because the loan is disarmed, not because the gate refused it");
        uint256 before = read.loanCount();
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "the loan ended");
        assertEq(read.loanCount(), before, "no successor: the unarmed default");
    }

    /// @notice The new holder cannot re-arm: `arm` refuses a holder the market does not name, and the lens agrees.
    function test_TheNewHolderCannotArmARollTheGateRefuses() public {
        uint256 loanId = _openArmed();
        _sell(loanId);
        vm.prank(buyer);
        vm.expectRevert(GateRefused.selector);
        ace.setAutoRefinance(loanId, TEN7, 0, 0);
        (bool armOk, uint256 q) = lens.armable(loanId, TEN7);
        assertFalse(armOk, "the lens refuses it too");
        assertEq(q, 0, "and quotes no reservation");
        vm.prank(buyer);
        ace.setAutoRefinance(loanId, 0, 0, 0); // a disarm still lands for anyone holding the title
    }

    /// @notice A loan that reads armed at its home roll is never refused there by the borrower rule.
    /// @dev Was the run's RED row: the disarm at a title move into a non-named holder turned it green.
    function test_AnArmedHomeRollIsNeverRefusedByTheBorrowerRule() public {
        uint256 loanId = _openArmed();
        _sell(loanId);
        _warpTo(uint256(read.loan(loanId).expiry));
        (uint64 tenor,,) = read.autoPolicyOf(loanId);
        (bool ok, bytes4 reason,) = ace.tryContinue(loanId);
        bool refusedByGate = !ok && reason == GateRefused.selector;
        assertFalse(tenor != 0 && refusedByGate, "an armed loan's home roll was refused by the borrower rule");
    }
}

/// @title AceS1FillFeeEpsCouplingTest
/// @notice Audit run 2026-10-03-251533, phase 1: genesis coupled `fillFeeBps` to eps, and no verb couples them.
/// @notice `fillFeeBps` is read only by `buyInventory`; a deleverage keeper's sale is identical at any fill fee.
/// @notice FIXED (Y-14): the ratio rail is deleted; `MAX_FILL_FEE_BPS` stays, on its own reason.
contract AceS1FillFeeEpsCouplingTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    MockPersistenceRecord internal record;

    address internal alice = AceFixtures.LENDER;
    address internal bob = address(0xB0B);

    uint256 internal constant P = 70_000e6;
    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant TOP = 400_000e6;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        record = new MockPersistenceRecord(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(AceFixtures.marketParams(address(usdc), address(vault)));
        (ace, pm, read) = (d.ace, d.positionManager, d.read);
    }

    function _params(uint256 fillFee) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(record);
        p.deleverageFloorEpsBps = 100;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 5000;
        p.deleverageStopBps = 1000;
        p.fillFeeBps = fillFee;
    }

    function _fundAndOpen(bytes32 mid) internal returns (uint256 loanId) {
        usdc.mint(alice, TOP);
        vm.startPrank(alice);
        usdc.approve(address(ace), TOP);
        ace.deposit(mid, TOP);
        vm.stopPrank();
        vault.mint(bob, COLL);
        vm.startPrank(bob);
        vault.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, P, 7 days, bob, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @notice Premise: two markets differing ONLY in fill fee crank identically: same units, same quote, same melt.
    function test_Premise_ADeleverageCrankIsBlindToTheFillFee() public {
        bytes32 m0 = ace.createMarket(_params(0));
        bytes32 m25 = ace.createMarket(_params(25)); // at the rail's own boundary, eps / 4
        uint256 l0 = _fundAndOpen(m0);
        uint256 l25 = _fundAndOpen(m25);
        uint256 trig = read.triggerPrice(l0);
        assertEq(read.triggerPrice(l25), trig, "the two loans are the same loan");

        record.setBelowBand((trig * 10_000) / 7000 + 1); // in band, above the trigger: no distress
        record.setMinPrice((trig * 13) / 10); // above the stop level, under twice the trigger
        MockDeleverageKeeper k = new MockDeleverageKeeper(ace, address(usdc), address(vault), 1 << 96);
        (uint256 u0, uint256 s0) = k.crankDeleverage(l0);
        (uint256 u25, uint256 s25) = k.crankDeleverage(l25);

        assertGt(u0, 0, "the crank sold");
        assertEq(u25, u0, "the fill fee moved no unit of the sale");
        assertEq(s25, s0, "nor any quote the keeper paid");
        assertEq(read.loan(l25).debt, read.loan(l0).debt, "nor the debt it melted");
    }

    /// @notice The band-on arm admits the fill fee the band-off arm admits, up to the same absolute ceiling.
    /// @dev Was the run's premise that the coupling refused it.
    function test_TheBandOnArmAdmitsWhatTheBandOffArmAdmits() public {
        assertTrue(ace.createMarket(_params(26)) != bytes32(0), "band on, fill fee over eps / 4: admitted");
        assertTrue(ace.createMarket(_params(50)) != bytes32(0), "band on, fill fee at its ceiling: admitted");

        MarketParams memory off = AceFixtures.marketParams(address(usdc), address(vault));
        off.record = address(record);
        off.fillFeeBps = 50; // MAX_FILL_FEE_BPS
        ace.createMarket(off); // admitted: no eps to spend, and no verb ever spent one on it
    }
}

/// @title AceS1WholeUnitCollateralTest
/// @notice Audit run 2026-10-03-251533, phase 1: the coverage line's one-atom epsilon on 0-decimal collateral.
/// @notice One atom is one whole unit, so no single-unit loan opens at any debt, and two units reach half the nominal LTV.
/// @dev Premises only, GREEN: the admission twin of the one-atom settlement ceil on the known-issues list.
contract AceS1WholeUnitCollateralTest is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal item; // 0 decimals: one atom is one whole unit
    bytes32 internal mid;

    address internal alice = AceFixtures.LENDER;
    address internal bob = address(0xB0B);
    uint256 internal constant UNIT_USD = 100_000; // one unit is worth this many whole quote tokens at the market price

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        item = new MockERC20("Item", "ITEM", 0);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(item));
        p.price = AceFixtures.px(UNIT_USD * 1e18, address(usdc), address(item));
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, mid) = (d.ace, d.positionManager, d.id);
        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 1_000_000e6);
        ace.deposit(mid, 1_000_000e6);
        vm.stopPrank();
        item.mint(bob, 10);
        vm.prank(bob);
        item.approve(address(pm), 10);
    }

    function _open(uint256 units, uint256 principal) internal returns (uint256) {
        vm.prank(bob);
        return ace.open(mid, units, principal, 7 days, bob, OpenBounds(0, 0, 0));
    }

    /// @notice Premise: a one-unit lot refuses even the market's minimum ticket, a ten-thousandth of its value.
    function test_Premise_OneUnitNeverOpens() public {
        vm.expectRevert(BelowCoverageLine.selector);
        _open(1, 10e6);
    }

    /// @notice Premise: at two units the line, not the trigger, caps the draw near 1/(2k) of the lot's value.
    function test_Premise_TwoUnitsReachHalfTheNominalLtv() public {
        uint256 lineCap = (UNIT_USD * 1e6 * 1e18) / 1.4e18; // requiredAt == 1: k * debt <= one unit's value
        _open(2, lineCap - 1e6); // just under the line's cap opens
        vm.expectRevert(BelowCoverageLine.selector);
        _open(2, lineCap + 1e6); // the trigger alone would admit up to twice this
    }
}

/// @title AceS1ClaimPastCashCapTest
/// @notice Audit run 2026-10-03-251533, phase 1: the per-market cash cap does not bound a loan's claim.
/// @notice A home refinance recycles the retiring principal, so the successor's claim is old claim plus fresh cash.
/// @dev Premise only, GREEN: it falsifies the bound `Settlement._finalizeLoanFor`'s plain product was argued on.
/// @dev The overflow itself needs a claim past ~2^160, about 2^32 such refinances, so no red row is written.
contract AceS1ClaimPastCashCapTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal vault;
    bytes32 internal mid;

    address internal alice = AceFixtures.LENDER;
    address internal bob = address(0xB0B);

    uint256 internal constant CAP = type(uint128).max;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockStakeVault(42);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
    }

    function _fill() internal {
        uint256 room = CAP - read.restingOf(mid);
        usdc.mint(alice, room);
        vm.startPrank(alice);
        usdc.approve(address(ace), room);
        ace.deposit(mid, room);
        vm.stopPrank();
    }

    /// @notice Premise: one home refinance writes a claim past the cash cap, which no single draw can.
    function test_Premise_AHomeRefinanceWritesAClaimPastTheCashCap() public {
        _fill();
        assertEq(read.restingOf(mid), CAP, "the market sits at its cash cap");
        uint256 units = type(uint256).max / 1e18; // the width rail: the widest lot any loan may hold
        vault.mint(bob, units);
        vm.startPrank(bob);
        vault.approve(address(pm), units);
        uint256 first = CAP / 2;
        uint256 loanId = ace.open(mid, units, first, 7 days, bob, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertEq(read.claimOf(mid, loanId), first, "a draw's claim is bounded by the cash it took");

        _fill(); // the lender tops the market back up to the cap
        uint256 next = first + CAP - 1; // recycles `first`, draws CAP - 1 fresh
        usdc.mint(bob, CAP); // headroom for any fee leg the netting asks
        vm.startPrank(bob);
        usdc.approve(address(ace), type(uint256).max);
        uint256 newId = ace.refinance(loanId, next, 7 days, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 claim = read.claimOf(mid, newId);
        assertEq(claim, next, "the successor's claim is the whole new principal");
        assertGt(claim, CAP, "and it sits past the per-market cash cap");
    }
}
