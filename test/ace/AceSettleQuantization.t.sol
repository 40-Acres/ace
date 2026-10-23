// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds, Storage} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceSettleQuantization
/// @notice Settlement converts a claim to units at the claim's own tick, and the two roundings must agree.
/// @notice The requirement is `u >= ceil(amount * unitScale / price)`: fewer units cannot pay the claim.
/// @notice So the conversion CEILS, the custody leg ceils with it, and a covered settlement strands nothing.
/// @dev A quote-per-unit price far above one makes a single collateral atom economically large.
/// @dev At zero-decimal collateral that atom is worth thousands of quote, so a one-atom rounding is not dust.
/// @dev The 18-decimal control pins the same shape at one quote atom per tick, which is where it is cosmetic.
contract AceSettleQuantizationTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;
    uint256 internal unitScale;

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal T_HI; // 76_800 ticks over this pair's par, spacing-aligned at 60: ~2166 quote per whole token
    uint256 internal constant T0 = 1 << 96; // the frame's one-to-one price: one collateral atom buys one quote atom
    uint256 internal constant LADDER = 20_000e6;
    uint256 internal constant DRAW = 4_500e6;
    uint256 internal constant COVERED_0DEC = 35; // the coverage line at T_HI: requiredAt is 3 atoms, plus the 32-tick cap
    uint256 internal constant COVERED_AT_T0 = 7_000_000_000; // the same line at tick 0, where one atom buys one atom

    function setUp() public {
        vm.warp(1_000_000);
    }

    // ---- fixture ----

    /// @dev A RECORD-BACKED market whose record answers with the max sentinel, so every price read stays inert.
    /// @dev The record is here for the SETTLEMENT RULE alone: a recordless market forfeits the coverage,
    /// @dev which would make every pot below the coverage line instead of the claim's own ceiled requirement.
    /// @dev A sentinel minimum leaves the draw cap, the withdrawal clamp and the ask floor exactly where no record left them.
    /// @dev So the rounding profile is unchanged and only the settlement bound moves, which is the point of the swap.
    /// @dev Rows still settle by `forceClose` at expiry: the mock reports no persisted distress, so `finalize` stays shut.
    /// @dev The market BIDS AT `T_HI`, which is where every row but the control wants it: the rows are about the
    /// @dev rounding profile at a high price against low-decimal collateral, so the price has to be the subject.
    function _market(uint8 collDecimals) internal {
        _marketAt(collDecimals, 0);
    }

    /// @dev The same fixture at a NAMED price; zero means `T_HI`, the default every row but the control uses.
    /// @dev IT USED TO NEED NO PRICE: a lender picked a rung per deposit and a row simply named the one it meant.
    function _marketAt(uint8 collDecimals, uint256 price) internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", collDecimals);
        T_HI = AceFixtures.priceAt(address(usdc), address(coll), 76_800);

        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(type(uint256).max);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = alice; // sole tenancy: the depositor and the market's named lender are one
        p.price = price == 0 ? T_HI : price;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        unitScale = read.marketState(id).unitScale;
    }

    function _deposit() internal {
        usdc.mint(alice, LADDER);
        vm.startPrank(alice);
        usdc.approve(address(ace), LADDER);
        ace.deposit(id, LADDER);
        vm.stopPrank();
    }

    /// @dev Opens against exactly `units` of collateral and asserts the gate admitted it, so every row is live.
    function _open(uint256 units) internal returns (uint256 loanId) {
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        loanId = ace.open(id, units, DRAW, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertLe(read.triggerPrice(loanId), read.fundingFloor(id, loanId), "fixture: admitted at the gate");
    }

    /// @dev THE requirement, stated independently of the contract: units that cover the claim at its own tick.
    function _needCeil(uint256 loanId, uint256 price) internal view returns (uint256) {
        uint256 amt = read.claimOf(id, loanId);
        return (amt * unitScale + price - 1) / price;
    }

    /// @dev What the tick's pot is actually worth at its own pre-committed price, in quote.
    function _potValue(uint256 loanId, uint256 price) internal view returns (uint256) {
        return (read.invPotOf(id, loanId) * price) / unitScale;
    }

    /// @dev Settle at expiry and return the reported shortfall from the `ForceClosed` payload.
    function _forceCloseBadDebt(uint256 loanId) internal returns (uint256 badDebt) {
        vm.warp(uint256(read.loan(loanId).expiry) + 1);
        vm.recordLogs();
        vm.prank(keeper);
        ace.forceClose(loanId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ForceClosed(uint256,uint256,uint256,address)");
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ace) || logs[i].topics[0] != sig) continue;
            seen = true;
            (, badDebt) = abi.decode(logs[i].data, (uint256, uint256));
        }
        assertTrue(seen, "fixture: the hub emitted ForceClosed");
    }

    /// @dev The debt-based in-kind sliver, mirroring `LoanAccounting.sliverUnits` including its cap at the position.
    function _sliver(uint256 loanId) internal view returns (uint256) {
        uint256 floorPrice = read.fundingFloor(id, loanId);
        if (floorPrice == 0) return 0;
        uint256 units = read.loan(loanId).collateralUnits;
        uint256 bty = (read.loan(loanId).debt * ace.idToMarketParams(id).settleBountyBps * unitScale) / (10000 * floorPrice);
        return bty < units ? bty : units;
    }

    /// @dev Stages collateral scarcity directly, as `AceSettlement` does and for the same reason.
    /// @dev No in-protocol verb leaves an admitted loan short: the gate covers withdrawal, and a sale reserves what settlement needs.
    /// @dev So the write site is DEFENSIVE, and staging the state directly is the only way to reach it.
    /// @dev Writing `collateralUnits` touches no other field and leaves the loan's real vault balance alone.
    function _shortenTo(uint256 loanId, uint256 units) internal {
        uint256 loanSlot = uint256(keccak256(abi.encode(loanId, uint256(Storage.BOOK) + 1)));
        vm.store(address(ace), bytes32(loanSlot + 2), bytes32(units)); // word 2 == collateralUnits
    }

    /// @dev Both credited legs pulled, so what stays in retired custody is the market's leg alone.
    function _drainCredits(uint256 loanId) internal {
        vm.prank(keeper);
        ace.claimOwed(loanId, keeper);
        vm.prank(borrower);
        ace.claimOwed(loanId, borrower);
    }

    // ============ the conversion must cover the claim it settles ============

    /// @notice CLAIM UNDER TEST: a covered settlement hands the tick a pot worth at least the claim it retires.
    /// @notice At zero-decimal collateral the floored conversion delivers one atom too few, worth ~2166 quote.
    /// @dev The shortcut at the conversion site then reports `badDebt == 0` against a pot that cannot pay the claim.
    function test_LowDecimalCollateral_ACoveredSettlementMustDeliverAPotWorthTheClaim() public {
        _market(0);
        _deposit();
        uint256 loanId = _open(COVERED_0DEC);
        uint256 claim = read.claimOf(id, loanId);
        uint256 need = _needCeil(loanId, T_HI);
        assertEq(claim, DRAW, "fixture: the whole draw rests on one tick");
        assertGe(read.loan(loanId).collateralUnits, need, "fixture: the position covers the claim, nothing is short");

        uint256 badDebt = _forceCloseBadDebt(loanId);

        emit log_named_uint("claim at the tick", claim);
        emit log_named_uint("pot value at book", _potValue(loanId, T_HI));
        assertEq(read.invPotOf(id, loanId), need, "the pot is the claim's own ceiled requirement");
        assertGe(_potValue(loanId, T_HI), claim, "a covered settlement must deliver a pot worth its claim");
        assertEq(badDebt, 0, "and the reported zero must be honest, not the shortcut's fiat");
    }

    /// @notice CLAIM UNDER TEST: once every credited leg is pulled, retired custody equals the pots it backs.
    /// @notice Custody takes the CEILED requirement while the conversion consumes the FLOOR, so an atom rests nowhere.
    /// @dev That atom is credited to no claimant and to no class, and at zero decimals it is worth ~2166 quote.
    function test_LowDecimalCollateral_NoAtomIsStrandedOutsideAPot() public {
        _market(0);
        _deposit();
        uint256 loanId = _open(COVERED_0DEC);

        _forceCloseBadDebt(loanId);
        _drainCredits(loanId);

        uint256 retired = positionManager.retiredOf(loanId);
        emit log_named_uint("retired custody", retired);
        emit log_named_uint("pot held", read.invPotOf(id, loanId));
        assertEq(retired, read.invPotOf(id, loanId), "every retired unit rests in the pot it was taken for");
    }

    // ============ a SHORT settlement at low decimals: what each half of the record can say ============

    /// @notice CLAIM UNDER TEST: a short close records the atoms the claims did not get AND their value at book.
    /// @notice At zero-decimal collateral one atom is worth ~2166 quote, so the units half is far too coarse alone.
    /// @dev The quote half is what carries resolution here: no whole atom count values to the loss it reports.
    function test_LowDecimalCollateral_ShortSettlementRecordsBothHalves() public {
        _market(0);
        _deposit();
        uint256 loanId = _open(COVERED_0DEC);
        uint256 claim = read.claimOf(id, loanId);
        uint256 need = _needCeil(loanId, T_HI);
        _shortenTo(loanId, 1); // one atom against a three-atom requirement
        uint256 left = read.loan(loanId).collateralUnits - _sliver(loanId);
        assertLt(left, need, "fixture: the position is actually short against its live claims");

        uint256 badDebt = _forceCloseBadDebt(loanId);

        uint256 price = T_HI;
        (uint256 units, uint256 quoteAtBook) = read.shortfallOf(loanId);
        assertEq(units, need - left, "the atoms the claims did not get, keeper sliver already taken");
        assertEq(quoteAtBook, claim - (left * price) / unitScale, "and that gap valued at the funding tick");
        assertEq(quoteAtBook, badDebt, "the stored figure and the emitted one must never disagree");

        uint256 atomValue = price / unitScale; // quote one collateral atom is worth at this tick
        emit log_named_uint("one atom at book", atomValue);
        emit log_named_uint("loss at book", quoteAtBook);
        assertGt(atomValue, 0, "fixture: at zero decimals one atom is worth whole quote units");
        assertTrue(quoteAtBook % atomValue != 0, "no whole atom count values to this loss: units cannot carry it");
        assertGt((units * price) / unitScale, quoteAtBook, "and re-valuing the units half OVERSTATES the loss");
    }

    /// @notice CLAIM UNDER TEST: the market's running total ACCUMULATES; one loan's loss never replaces another's.
    /// @dev Nothing else settles two short loans into ONE market, so `+=` and `=` are indistinguishable there.
    function test_RealizedLossAtBook_AccumulatesAcrossShortSettlements() public {
        _market(0);
        _deposit();

        uint256 first = _open(COVERED_0DEC);
        _shortenTo(first, 1);
        uint256 lossOne = _forceCloseBadDebt(first);
        assertGt(lossOne, 0, "fixture: the first close came up short");
        assertEq(read.marketState(id).realizedLossAtBook, lossOne, "the first short close opens the total");

        uint256 second = _open(COVERED_0DEC);
        _shortenTo(second, 1);
        uint256 lossTwo = _forceCloseBadDebt(second);
        assertGt(lossTwo, 0, "fixture: so did the second");
        assertEq(read.marketState(id).realizedLossAtBook, lossOne + lossTwo, "and the second ADDS to it");
    }

    // ============ the controls that make the rows above non-vacuous ============

    /// @notice CONTROL: the same short shape at 18-decimal collateral, where an atom is worth far under a quote atom.
    /// @notice There the units half re-values to the quote half, so the row above measures DECIMALS, not settlement.
    function test_Control_EighteenDecimal_TheShortfallHalvesAgree() public {
        _market(18);
        _deposit();
        uint256 loanId = _open(10_000e18);
        uint256 need = _needCeil(loanId, T_HI);
        _shortenTo(loanId, (need * 60) / 100);
        uint256 left = read.loan(loanId).collateralUnits - _sliver(loanId);
        assertLt(left, need, "fixture: short against its live claims, exactly as the row above");

        uint256 badDebt = _forceCloseBadDebt(loanId);

        (uint256 units, uint256 quoteAtBook) = read.shortfallOf(loanId);
        assertEq(units, need - left, "the same units half");
        assertEq(quoteAtBook, badDebt, "the same quote half, agreeing with the announcement");
        assertEq(T_HI / unitScale, 0, "one atom here is worth under a single quote atom");
        assertApproxEqAbs((units * T_HI) / unitScale, quoteAtBook, 1, "so the two halves agree");
    }

    /// @notice CONTROL: the identical shape at 18-decimal collateral is bounded by one quote atom per tick.
    /// @notice GREEN before and after, which is what proves the rows above measure DECIMALS and not settlement.
    /// @dev One collateral wei is worth `price / unitScale` quote, far under a single quote atom here.
    function test_Control_EighteenDecimalCollateral_TheSameShapeIsSubAtom() public {
        _market(18);
        _deposit();
        uint256 loanId = _open(10_000e18);
        uint256 claim = read.claimOf(id, loanId);
        assertGe(read.loan(loanId).collateralUnits, _needCeil(loanId, T_HI), "fixture: covered");

        uint256 badDebt = _forceCloseBadDebt(loanId);
        _drainCredits(loanId);

        uint256 ticks = read.claimCount(id, loanId);
        assertLe(badDebt, ticks, "at 18 decimals any reported shortfall is one quote atom per tick");
        assertGe(_potValue(loanId, T_HI) + ticks, claim, "and the pot is short by at most that same atom");
        assertLe(positionManager.retiredOf(loanId) - read.invPotOf(id, loanId), ticks, "so is the strand");
    }

    /// @notice CONTROL: a claim that divides exactly at its tick reports nothing and strands nothing.
    /// @notice GREEN before and after, so neither row above can be satisfied by always reporting a shortfall.
    /// @dev At `T0` the price IS the unit scale, so one collateral atom buys one quote atom and every claim divides.
    function test_Control_ExactDivision_ReportsNoShortfallAndStrandsNothing() public {
        _marketAt(0, T0);
        _deposit();
        uint256 loanId = _open(COVERED_AT_T0);
        uint256 claim = read.claimOf(id, loanId);
        assertEq((claim * unitScale) % T0, 0, "fixture: the claim divides exactly at the market's price");

        uint256 badDebt = _forceCloseBadDebt(loanId);
        _drainCredits(loanId);

        assertEq(badDebt, 0, "an exactly-dividing claim is covered to the atom");
        assertEq(_potValue(loanId, T0), claim, "the pot is worth exactly the claim");
        assertEq(positionManager.retiredOf(loanId), read.invPotOf(id, loanId), "and nothing rests outside it");
    }
}
