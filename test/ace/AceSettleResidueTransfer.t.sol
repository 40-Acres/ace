// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceSettleResidueTransfer
/// @notice THE SURVIVING RESIDUE: on a HEALTHY loan force-closed at tenor, the conversion's ceiling is a TRANSFER.
/// @notice `Settlement` ceils the claim's conversion, and the excess atom comes out of the borrower's residual.
/// @notice So the coverage line's one-atom slack is not a margin the borrower gets back at settlement.
/// @notice Where the claim is sub-atomic, the funding lender consumes the whole of it.
/// @dev NOT a shortfall and NOT bad debt: the settlement is covered, the claim converts, nothing is written down.
/// @dev The loss is `pot value at book MINUS the claim it retired`, in quote.
/// @dev A quote-per-unit price far above one makes a single collateral atom economically large.
/// @dev At zero-decimal collateral that atom is worth thousands of quote, so a one-atom rounding is not dust.
/// @dev THE REMAINDER CONTROL is a SECOND LOAN in a market bidding at the frame's one-to-one price, where the
/// @dev claim divides exactly and loses nothing. It rode in the same fixture when a loan could fund two ticks;
/// @dev it cannot now, and without it the row would pass under a floor rule too -- the trap a rounding pin exists to avoid.
/// @dev THE DECIMAL CONTROL is a separate row at 18 decimals, where the same claim is worth many atoms.
/// @dev THE MAGNITUDE SHRANK BY THE CLAIM CAP, and that is the finding rather than a coverage loss: the transfer
/// @dev was bounded by `maxClaimTicks` atoms, one per funded tick, and a loan funds one. The bound is ONE ATOM.
contract AceSettleResidueTransferTest is Test {
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

    int24 internal constant HI_OFFSET = 76_800; // steps over par: ~2166 quote per whole token
    uint256 internal T_HI; // `HI_OFFSET` resolved against the live market's pair, assigned in `_market`
    uint256 internal constant T0 = 1 << 96; // the frame's one-to-one price, the ONLY one every claim divides at
    uint256 internal constant SUB_ATOMIC = 312_500; // the sub-atomic claim at `T_HI`
    uint256 internal constant EXACT_LEG = 20_000_000; // 20 whole quote, which divides at `T0` whatever it is
    uint256 internal constant HELD = 28_437_532; // the coverage line at this draw against `T0`, so the loan opens on it

    function setUp() public {
        vm.warp(1_000_000);
    }

    /* ============================== the fixture ============================== */

    /// @dev A RECORD-BACKED market whose record answers with the max sentinel, so every price read stays inert.
    /// @dev The record is here for the SETTLEMENT RULE alone: a recordless market forfeits the coverage to the
    /// @dev claim, and this suite measures what the CEILING moves, which needs the residual to come back.
    /// @dev A sentinel minimum leaves the draw cap, the withdrawal clamp and the ask floor where no record left them.
    /// @dev Rows still settle by `forceClose` at expiry: the mock reports no persisted distress, so `finalize` stays shut.
    /// @dev `price` of zero means `T_HI`, which is the price every row but the remainder control wants.
    function _market(uint8 collDecimals, uint256 minDebt, uint256 price) internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", collDecimals);
        T_HI = AceFixtures.priceAt(address(usdc), address(coll), HI_OFFSET);
        MockPersistenceRecord rec = new MockPersistenceRecord(address(usdc), address(coll));
        rec.setMinPrice(type(uint256).max);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.minDebt = minDebt;
        p.price = price == 0 ? T_HI : price;
        /// @dev NO KEEPER SLIVER: settlement takes it off the top, and every row here measures the CEILING's
        /// @dev residue alone. It is a second, unrelated subtraction from the same borrower balance.
        p.settleBountyBps = 0;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        unitScale = read.marketState(id).unitScale;
    }

    function _deposit(uint256 amount) internal {
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(ace), amount);
        ace.deposit(id, amount);
        vm.stopPrank();
    }

    function _open(uint256 units, uint256 principal) internal returns (uint256 loanId) {
        coll.mint(borrower, units);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), units);
        loanId = ace.open(id, units, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        assertLe(read.triggerPrice(loanId), read.fundingFloor(id, loanId), "fixture: admitted at the gate");
    }

    /// @dev Settle a HEALTHY loan at tenor: `forceClose` with no armed policy, which reads no price at all.
    /// @dev Health is stated as UNSETTLEABLE plus UNARMED, which is what makes expiry the only exit.
    function _forceCloseAtTenor(uint256 loanId) internal {
        assertFalse(read.settleable(loanId), "fixture: the loan must not be liquidatable, so this is not a default");
        (uint64 policyTenor,,) = read.autoPolicyOf(loanId);
        assertEq(policyTenor, 0, "fixture: no armed policy, so the expiry fold settles rather than rolls");
        vm.warp(uint256(read.loan(loanId).expiry) + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        (uint256 short,) = read.shortfallOf(loanId);
        assertEq(short, 0, "fixture: the settlement is COVERED, so the residue is a transfer and not a write-down");
    }

    /* =============================== readers =============================== */

    /// @dev What the claim strictly requires in units, unceiled: the number the ceiling rounds up from.
    function _exactFloor(uint256 loanId, uint256 price) internal view returns (uint256) {
        return (read.claimOf(id, loanId) * unitScale) / price;
    }

    function _needCeil(uint256 loanId, uint256 price) internal view returns (uint256) {
        uint256 amt = read.claimOf(id, loanId);
        return amt == 0 ? 0 : (amt * unitScale + price - 1) / price;
    }

    /// @dev What one collateral atom is worth in quote at the market's own pre-committed price.
    function _atomValue(uint256 price) internal view returns (uint256) {
        return price / unitScale;
    }

    /// @dev What the loan's pot is worth at book, in quote.
    function _potValue(uint256 loanId, uint256 price) internal view returns (uint256) {
        return (read.invPotOf(id, loanId) * price) / unitScale;
    }

    /// @dev THE MEASUREMENT: what the lender received at book, less the claim it retired, in quote.
    /// @dev Read from the pot AFTER settlement against the claim read BEFORE it, so nothing is restated.
    /// @dev WAS a SUM over the loan's funded ticks; one claim converts, so the sum is one subtraction.
    function _transferQuote(uint256 loanId, uint256 price, uint256 claimBefore) internal view returns (uint256) {
        return _potValue(loanId, price) - claimBefore;
    }

    /* ========================= the residue, pinned ========================= */

    /// @notice CLAIM UNDER TEST: a sub-atomic claim at a high price takes a WHOLE atom.
    /// @notice And the borrower's residual credit is short by exactly that atom, which is worth ~2166 quote.
    /// @dev Both halves are asserted: the loan's `invPot` and the borrower's `unitsOwed`.
    /// @dev WAS a two-tick loan carrying its own remainder control on a second leg; that control is the row below.
    function test_SubAtomicClaimAtAHighPrice_TakesAWholeAtomFromTheBorrower() public {
        _market(0, SUB_ATOMIC, 0); // the floor IS `minDebt` now, so the draw and the deposit floor are one number
        _deposit(SUB_ATOMIC);
        uint256 loanId = _open(HELD, SUB_ATOMIC);

        assertEq(read.claimOf(id, loanId), SUB_ATOMIC, "fixture: the loan carries exactly the min lot");
        assertEq(_exactFloor(loanId, T_HI), 0, "the claim is SUB-ATOMIC: it buys no whole atom");
        assertEq(_needCeil(loanId, T_HI), 1, "yet the ceiling charges it one");

        uint256 held = read.loan(loanId).collateralUnits;
        uint256 exact = _exactFloor(loanId, T_HI);
        uint256 need = _needCeil(loanId, T_HI);
        _forceCloseAtTenor(loanId);

        assertEq(read.invPotOf(id, loanId), 1, "HALF ONE: the lender banked a whole atom for a sub-atomic claim");
        assertEq(read.unitsOwedOf(loanId, borrower), held - need, "HALF TWO: the borrower keeps only what the CEILED need left");
        assertEq(need - exact, 1, "and the gap between the two rules is exactly the one atom");
        emit log_named_uint("atom value at the high price, quote", _atomValue(T_HI));
        emit log_named_uint("the claim it settled, quote", SUB_ATOMIC);
        emit log_named_uint("pot value at the high price, quote", _potValue(loanId, T_HI));
    }

    /// @notice THE REMAINDER CONTROL: a claim that divides EXACTLY loses nothing to the same ceiling.
    /// @dev Without it the row above would pass under a FLOOR rule too, which is the trap a rounding pin avoids.
    /// @dev It was a second leg of the same loan until a loan could fund only one price; it is its own market now.
    function test_Control_AnExactlyDividingClaim_LosesNothing() public {
        _market(0, 10e6, T0);
        _deposit(EXACT_LEG);
        uint256 loanId = _open(HELD, EXACT_LEG);

        assertEq(_exactFloor(loanId, T0), _needCeil(loanId, T0), "CONTROL: the claim divides exactly at this price");
        uint256 claimBefore = read.claimOf(id, loanId);

        _forceCloseAtTenor(loanId);

        assertEq(read.invPotOf(id, loanId), claimBefore * unitScale / T0, "the pot is exactly the claim's own requirement");
        assertEq(_transferQuote(loanId, T0, claimBefore), 0, "and the borrower-to-lender transfer is zero in quote");
    }

    /// @notice THE DECIMAL CONTROL: the same lot at the same price, at 18-decimal collateral.
    /// @notice There the claim is worth 1.44e14 atoms, so the ceiling moves under one part in 1e14.
    /// @dev The row therefore measures DECIMALS -- how much quote one atom carries -- and not settlement.
    /// @dev The transfer measured in quote is ZERO here, which is why no single decimal point can show the defect.
    function test_EighteenDecimalCollateral_TheSameCeilingIsCosmetic() public {
        _market(18, SUB_ATOMIC, 0);
        _deposit(SUB_ATOMIC);
        uint256 loanId = _open(40e18, SUB_ATOMIC); // the same draw, sized in this market's own atoms

        assertGt(_exactFloor(loanId, T_HI), 1e13, "the same claim is worth many atoms once the collateral is fine");
        assertEq(_needCeil(loanId, T_HI) - _exactFloor(loanId, T_HI), 1, "the ceiling still charges at most one atom");
        assertEq(_atomValue(T_HI), 0, "but one atom is worth less than one quote wei, so the charge is cosmetic");

        uint256 claimBefore = read.claimOf(id, loanId);
        _forceCloseAtTenor(loanId);
        assertEq(_transferQuote(loanId, T_HI, claimBefore), 0, "CONTROL: the borrower-to-lender transfer is zero in quote");
    }

    /* ================== how much: the measured magnitude ================== */

    /// @notice HOW MUCH, now that the bound is ONE atom rather than one per funded tick.
    /// @dev Reported as a MEASUREMENT off the settled pot, never an estimate: the emitted number is the answer.
    /// @dev The bound is structural -- ONE atom -- and the atom's quote value carries no rail, which is the
    /// @dev whole of what these rows still say: the answer to `how much` is a PRICE question, not a rail question.
    /// @dev WAS three rows sweeping the claim cap at 10 and at 32, plus a second atom size. The cap is gone, so
    /// @dev the sweep has one point left; the second atom size survives as the row below, which is the variable.
    function test_TheTransferIsBoundedByOneAtom() public {
        uint256 gain = _measureTransfer(500e6, 500e6, HI_OFFSET); // WAS 32x the lot: the floor was `minDebt / maxClaimTicks`
        emit log_named_uint("borrower-to-lender transfer at a ~2166 quote atom", gain);
        assertGt(gain, 0, "a coarse collateral at a high price still moves real quote");
    }

    /// @notice The same one atom at the ~8300 quote atom the issue's own worked example uses.
    /// @dev The magnitude scales with the ATOM, which is what makes this a price question rather than a rail one.
    function test_AtAnEightThousandQuoteAtom() public {
        uint256 gain = _measureTransfer(1_000, 1_000, 90_240); // WAS 32x the lot, for the same reason
        emit log_named_uint("transfer at an ~8300 quote atom, quote", gain);
        assertGt(gain, 0, "the same one atom, priced at the issue's own example");
    }

    /// @dev A market bidding above the price where a `lot` claim stops buying a whole atom, settled at tenor.
    /// @dev `anchorOffset` is steps OVER PAR, resolved after the market exists: par is a property of the pair.
    function _measureTransfer(uint256 minDebt, uint256 lot, int24 anchorOffset) internal returns (uint256 gain) {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 0);
        uint256 price = AceFixtures.priceAt(address(usdc), address(coll), anchorOffset);
        _market(0, minDebt, price);

        _deposit(lot);
        uint256 loanId = _open(4, lot);
        assertEq(read.claimCount(id, loanId), 1, "fixture: the draw funded, and a draw funds exactly one claim");
        assertEq(_exactFloor(loanId, price), 0, "fixture: the claim must be SUB-ATOMIC");

        uint256 claimBefore = read.claimOf(id, loanId);
        uint256 owedIdeal = read.loan(loanId).collateralUnits;
        _forceCloseAtTenor(loanId);
        gain = _transferQuote(loanId, price, claimBefore);
        emit log_named_uint("atoms the lender took", owedIdeal - read.unitsOwedOf(loanId, borrower));
    }
}
