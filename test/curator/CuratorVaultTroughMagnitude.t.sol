// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";
import {Storage} from "../../src/ace/hub/Types.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @title CuratorVaultTroughMagnitude
/// @notice SIZES the settlement NAV trough, which was a confirmed mechanism with unestablished money.
/// @notice `finalize` drops `totalLent` by the whole claim and puts the recovery in `classOf[].invPot`,
/// @notice which is in no term of the NAV identity, so NAV understates until that inventory sells.
/// @dev MEASUREMENT, not a rail, but for the trough entrant's refusal, which `test_Magnitude_AnEntrantIntoTheTroughIsRefusedUntilTheSale` pins.
/// @dev NAV here is COST-BASED and reads no price, which is WHY the pot is excluded; see `inventoryMark`.
/// @dev THE LAW, confirmed linear by the underwater bracket: `trough/NAV = loan share x recovery rate`.
/// @dev The DROP is constant at the loan's share; what varies is how much of it is RECOVERABLE.
/// @dev A genuine write-off is not a trough -- nobody captures a real loss -- so low recovery means a
/// @dev SMALL trough beside a LARGE permanent loss, and the extraction peaks when the protocol worked.
/// @dev The healthy-loan rows above read high because the rig posts 40k units against a 6k draw; read
/// @dev the bracket for magnitude and those rows for shape.
/// @dev The unsold-pot gate refuses a trough entrant until the pot sells; `CuratorVaultTrough` measures the capture under an exemption.
contract CuratorVaultTroughMagnitudeTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;

    /// @dev A vault holding ONE loan, cranked, then settled. The trough is open when this returns.
    function _settled(CuratorVault v) internal returns (uint256 loanId) {
        _lpDeposit(v, alice, SEED);
        loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);
        _crankAll(v);
    }

    /// @notice THE SIZE OF THE HOLE: how far NAV falls, and how much of that fall is recoverable value.
    function test_Magnitude_HowFarNavFallsAndHowMuchOfItIsRecoverable() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);

        uint256 navBefore = v.grossNav();
        _finalize(loanId);
        _crankAll(v);
        uint256 navTrough = v.grossNav();
        uint256 mark = lens.inventoryMark(mid, loanId);

        assertLt(navTrough, navBefore, "PREMISE: settlement must actually open a trough");
        uint256 drop = navBefore - navTrough;

        emit log_named_uint("nav before finalize      ", navBefore);
        emit log_named_uint("nav at the trough        ", navTrough);
        emit log_named_uint("the drop                 ", drop);
        emit log_named_uint("inventoryMark of the pot ", mark);
        emit log_named_uint("drop as bps of nav       ", drop * 10000 / navBefore);
        emit log_named_uint("mark as bps of nav       ", mark * 10000 / navBefore);
        emit log_named_uint("recoverable share of drop, bps", drop == 0 ? 0 : mark * 10000 / drop);
    }

    /// @notice AN ENTRANT AT THE TROUGH IS REFUSED UNTIL THE POT SELLS, so it captures none of the recovery.
    /// @dev The trough gate is deleted; the settled pot is unsold, so Bob's deposit reverts `InventoryUnsold` and mints no share.
    function test_Magnitude_AnEntrantIntoTheTroughIsRefusedUntilTheSale() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _settled(v);
        assertGt(read.invPotOf(mid, loanId), 0, "PREMISE: the settled pot is unsold");
        _assertEntryWaitsForTheSale(v, bob);
    }

    /// @notice THE CONTROL: entering AFTER the recovery has landed captures nothing from the stayers.
    /// @dev The row above refuses the trough entrant; this one shows the entry the sale reopens is priced fairly.
    /// @dev Bob enters once the recovery has VESTED: before that, the pile gate refuses him.
    function test_Magnitude_EnteringAfterTheRecoveryCapturesNothing() public {
        CuratorVault v = _newVault(0);
        uint256 loanId = _settled(v);

        AceInventoryLens inv = new AceInventoryLens(address(ace), address(lens));
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        _buyPot(keeper, loanId, inv.clearingBudget(mid, loanId)); // the whole pot, so the unsold-pot gate admits bob below
        _crankAll(v);
        _warpBy(VEST_W + 1); // the recovery is a RISE, so it defers; the pile gate opens once it is recognized
        assertEq(v.unvested(), 0, "PREMISE: the recovery has vested whole");

        uint256 entry = 5_000e6;
        uint256 bobShares = _depositAs(v, bob, entry);
        uint256 total = v.totalSupply();
        uint256 bobValue = v.totalAssets() * bobShares / total;

        emit log_named_uint("bob deposited AFTER recovery", entry);
        emit log_named_uint("bob's value                 ", bobValue);
        assertLe(bobValue, entry + 1, "entering after the recovery must capture nothing");
    }

    /// @notice THE REALISTIC CASE, and it inverts the intuition: the trough is LARGEST when recovery is BEST.
    /// @notice With the record at or below the tick, `inventoryMark` is the claim exactly, so a fully-covered
    /// @notice default puts the WHOLE claim in the uncounted pot -- and the whole claim is the trough.
    /// @dev The rig's `minPrice = 2e18` over a market the door prices at half of it is what inflated the earlier rows 2x:
    /// @dev `_convertClaim` sizes the pot at the market's price while the mark takes `max(price, recordMin)`.
    function test_Magnitude_TheTroughIsLargestWhenTheRecoveryIsBest() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);

        record.setMinPrice(T2); // at par, after the door priced its market: the mark stops being inflated
        uint256 navBefore = v.grossNav();
        _finalize(loanId);
        _crankAll(v);
        uint256 navTrough = v.grossNav();
        uint256 mark = lens.inventoryMark(mid, loanId);

        assertLt(navTrough, navBefore, "PREMISE: settlement must actually open a trough");
        uint256 drop = navBefore - navTrough;

        emit log_named_uint("REALISTIC nav before     ", navBefore);
        emit log_named_uint("REALISTIC nav at trough  ", navTrough);
        emit log_named_uint("REALISTIC drop           ", drop);
        emit log_named_uint("REALISTIC mark of the pot", mark);
        emit log_named_uint("REALISTIC drop as bps of nav", drop * 10000 / navBefore);
        emit log_named_uint("REALISTIC recoverable share of drop, bps", drop == 0 ? 0 : mark * 10000 / drop);
    }

    // ---- the UNDERWATER bracket: a real default recovers LESS than its claim ----

    uint256 internal constant U_SEED = 1_000e6; // the LP stake
    uint256 internal constant U_DOOMED = 100e6; // the loan taken to settlement
    uint256 internal constant U_NEED = 100e18; // units a FULL cover consumes: DOOMED * 1e30 / 1e18

    /// @dev An ACE loan cannot reach underwater ORGANICALLY in a fixture, and that is itself a result:
    /// @dev coverage is >= `minCoverageWad` (1.4x) at open, the premium is fixed so debt never grows, and
    /// @dev collateral only leaves under gates. The suite therefore STAGES it, writing `collateralUnits`
    /// @dev directly -- `loans` is member 1 of `LoanBook`, and the units are its third field.
    function _stageShortEscrow(uint256 loanId, uint256 units) internal {
        uint256 loanSlot = uint256(keccak256(abi.encode(loanId, uint256(Storage.BOOK) + 1)));
        vm.store(address(ace), bytes32(loanSlot + 2), bytes32(units));
    }

    /// @dev Settle one loan at a chosen recovery rate and report the trough it opens.
    function _measureAt(uint256 recoveryBps) internal {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, U_SEED);
        uint256 loanId = _open(U_DOOMED);
        record.setMinPrice(T2); // AT par, after the door priced its market: stops `inventoryMark` inflating the pot
        _crankAllTicks(v, loanId, 0);
        _warpBy(VEST_W);
        v.collectFee();

        uint256 navBefore = v.grossNav();
        _stageShortEscrow(loanId, U_NEED * recoveryBps / 10000);
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        record.setBelow(false);
        _crankAll(v);

        uint256 navTrough = v.grossNav();
        uint256 mark = lens.inventoryMark(mid, loanId);
        uint256 drop = navBefore > navTrough ? navBefore - navTrough : 0;

        emit log_named_uint("--- recovery rate, bps   ", recoveryBps);
        emit log_named_uint("nav before               ", navBefore);
        emit log_named_uint("nav at trough            ", navTrough);
        emit log_named_uint("drop                     ", drop);
        emit log_named_uint("mark (the RECOVERABLE part)", mark);
        emit log_named_uint("drop as bps of nav       ", navBefore == 0 ? 0 : drop * 10000 / navBefore);
        emit log_named_uint("TROUGH as bps of nav (recoverable/nav)", navBefore == 0 ? 0 : mark * 10000 / navBefore);
        emit log_named_uint("PERMANENT loss as bps of nav", navBefore == 0 ? 0 : (drop > mark ? drop - mark : 0) * 10000 / navBefore);
    }

    /// @notice THE BRACKET: the trough is the RECOVERABLE half of the drop, so it shrinks with recovery.
    /// @notice The permanent loss is the rest, and it is NOT a trough -- nobody captures a real write-off.
    /// @dev This is the row that answers "how big is it in a real default", which the healthy-loan rows cannot.
    function test_Magnitude_UnderwaterBracketAcrossRecoveryRates() public {
        _measureAt(2500);
        _measureAt(5000);
        _measureAt(7500);
        _measureAt(10000);
    }

    function _depositAs(CuratorVault v, address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(v), amt);
        shares = v.deposit(amt, who);
        vm.stopPrank();
    }
}
