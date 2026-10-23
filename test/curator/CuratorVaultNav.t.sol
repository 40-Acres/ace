// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MarketState} from "../../src/ace/hub/Types.sol";

/// @title CuratorVaultNav
/// @notice The whole valuation model: the asset the vault holds plus the hub's own aggregates.
/// @notice NAV, the crank and exits read no price; the door reads the row's record by design, to price the market it lends in.
contract CuratorVaultNavTest is CuratorVaultBase {
    uint256 internal constant SEED = 10_000e6;
    uint256 internal constant DRAW = 6_000e6;

    /// @dev T1: gross NAV is the vault's balance plus the hub's aggregates after every verb, read by a second path.
    /// @dev Nothing the vault funds rests between calls, so the market's cash is zero after every verb.
    function test_Nav_IsTheHubsAggregatesAndNothingElse() public {
        CuratorVault v = _newVault(0);
        _assertModel(v, "fresh");

        _lpDeposit(v, alice, SEED);
        _assertModel(v, "after deposit");

        uint256 loanId = _open(DRAW);
        _assertModel(v, "after a door borrow");

        _crank(v, loanId, T2, 0);
        _assertModel(v, "after the crank");

        _repay(loanId, 1_000e6);
        _crankAll(v);
        _assertModel(v, "after a partial repay and a lap");

        _redeemFrac(v, alice, 1, 4);
        _assertModel(v, "after a redemption");
    }

    /// @dev T2: the vault's own door borrow moves NAV by the FEE and not one wei of principal.
    /// @dev The balance falls and `lent` rises by the same figure: that is the whole principal neutrality.
    /// @dev Under aggregate NAV the origination credit is income the instant it lands, so gross rises with it.
    /// @dev The rise is pinned to spendable cash by cranking it home: a phantom credit could not survive that.
    function test_Nav_ADrawDoesNotMoveIt() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 grossBefore = v.grossNav();
        uint256 cash0 = v.idle();
        (, uint256 lent0, uint256 owed0) = lens.lenderPools(address(v), v.asset());
        uint256 borrowerBefore = usdc.balanceOf(borrower);

        uint256 loanId = _open(DRAW);
        (, uint256 lent1, uint256 owed1) = lens.lenderPools(address(v), v.asset());
        assertEq(ace.restingOf(mid), 0, "nothing the vault funds rests past the door");
        assertEq(lens.claimOf(mid, loanId), DRAW, "the draw really did land on the vault's own market");

        assertEq(cash0 - v.idle(), DRAW, "the vault's cash fell by the principal exactly");
        assertEq(lent1 - lent0, DRAW, "and lent rose by the principal exactly");
        uint256 rise = v.grossNav() - grossBefore;
        assertEq(rise, owed1 - owed0, "so the ONLY thing that moved gross is the origination credit");

        assertGt(rise, 0, "the vault really is paid for lending");
        // the all-in fee, inlined: one local fewer, which is what keeps this frame off the stack limit
        assertLt(rise, DRAW - (usdc.balanceOf(borrower) - borrowerBefore), "and its share is a strict part of what the borrower paid");

        uint256 idleBefore = v.idle();
        _crank(v, loanId, T2, 0);
        assertEq(v.idle() - idleBefore, rise, "the crank moves the credit home as cash, to the wei");
        assertEq(ace.lenderOwed(address(v), v.asset()), 0, "and leaves nothing owed at the hub");
        assertEq(v.grossNav(), grossBefore + rise, "and taking it valued nothing: the crank is NAV-neutral");
    }


    /// @dev THE MODEL IN ONE ROW: settlement drops `totalLent` at the hub, so the loss lands ATOMICALLY.
    /// @dev No crank, no write-off verb, no memo -- the aggregate simply falls and NAV falls with it.
    /// @dev Was `test_BadDebt_IsNotAValuationTerm`, then the cost-book write-off; both mechanisms are gone.
    function test_Nav_ASettlementLandsAtomicallyWithNoCrankAtAll() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        record.setMinPrice(T2); // after the door, which prices its market off the record
        _crank(v, loanId, T2, 0);

        uint256 grossBefore = v.grossNav();
        _finalize(loanId); // nobody cranks: the hub's own aggregate is what moves

        assertLt(v.grossNav(), grossBefore, "the loss landed the instant the loan settled, uncranked");
        assertEq(v.grossNav(), _hubTruthNav(v), "and the second read path agrees to the wei");
        assertTrue(lens.loan(loanId).closedAt != 0, "the loan behind the loss really did settle");
    }

    /// @dev T12: the headline. An impairment's NAV, crank and exit legs with every price source made to revert.
    /// @dev The door reads the row's record by design, so the loan opens and settles BEFORE the mocks arm.
    /// @dev The record and BOTH lens marks are armed to blow up, and nothing after that touches any of them.
    /// @dev The trough monitor is armed beside the singular mark because the vault header claims NEITHER
    /// @dev is read, and a two-part claim with one-part coverage is the half a later edit gets wrong.
    function test_Vault_ReadsNoPriceAnywhere() public {
        CuratorVault v = _newVault(2000);
        _lpDeposit(v, alice, SEED);
        _lpDeposit(v, bob, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _finalize(loanId);

        AceInventoryLens trough = new AceInventoryLens(address(ace), address(lens));
        vm.mockCallRevert(address(record), bytes(""), bytes("RECORD_READ"));
        vm.mockCallRevert(address(lens), abi.encodeWithSelector(AceLens.inventoryMark.selector), bytes("MARK_READ"));
        vm.mockCallRevert(address(trough), abi.encodeWithSelector(AceInventoryLens.settledInventory.selector), bytes("TROUGH_READ"));

        uint256 grossBefore = v.grossNav();
        _crankAll(v);
        assertLe(v.grossNav(), grossBefore, "the loss landed and the lap ran with no price read at all");

        uint256 held = read.invPotOf(mid, loanId);
        _redeemFrac(v, alice, 1, 2);
        assertEq(read.invPotOf(mid, loanId), held, "the exit paid cash alone and moved no title");

        uint256 idleAfter = v.idle();
        _crankAll(v);
        assertGe(v.idle(), idleAfter, "and a second lap runs with every price source still armed to revert");

        vm.clearMockedCalls();
    }

    /// @dev The vault marks at or BELOW hub truth: an observed rise is deferred, never counted early.
    function test_Nav_NeverExceedsHubTruth() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        uint256 loanId = _open(DRAW);
        _crank(v, loanId, T2, 0);
        _repay(loanId, 2_000e6);

        assertLe(v.totalAssets(), _hubTruthNav(v), "the deferred rise sits outside what LPs can be paid");
        v.collectFee(); // any state-changing verb syncs; this is the cheapest one
        _warpBy(2 * uint256(VEST_W));
        assertEq(v.totalAssets(), _hubTruthNav(v), "and the window closes the gap exactly");
    }

    /// @dev The model, by a SECOND read path: gross is the hub's aggregates plus the balance, and `totalAssets`
    /// @dev is that less whatever is still deferred. Never above hub truth, ever; and nothing rests in the market.
    function _assertModel(CuratorVault v, string memory where) internal view {
        assertEq(v.grossNav(), _hubTruthNav(v), where);
        assertLe(v.totalAssets(), v.grossNav(), where);
        assertEq(ace.restingOf(mid), 0, where);
    }
}
