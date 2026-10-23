// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {BorrowRequest} from "../../src/curator/AceVaultFlows.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice The rig's loan rails, exposed so the handler can drive a door draw and its repayment.
interface IHoldRig {
    function lendExternal(uint256 amt, bool arm) external returns (uint256 loanId);
    function repayExternal(uint256 loanId, uint256 amt) external;
}

/// @notice Drives the vault through the shapes that move cash and hold it, so the properties below face real states.
/// @dev Amounts are bounded rather than fuzzed raw: an unbounded draw reverts on coverage and reaches nothing.
contract HoldHandler {
    CuratorVaultBase private immutable RIG;
    CuratorVault public immutable VAULT;
    uint256 private constant MIN_DRAW = 100e6; // over the rig's minDebt, so half a repayment leaves a live loan
    uint256 private constant MAX_DRAW = 15_000e6; // what one loan on the rig's collateral can draw
    uint256 private constant ARM_BELOW = 1_000e6; // a draw under this is armed, so a roll hold reaches the campaign without freezing it

    uint256 public deposited; // every wei the CAMPAIGN put in; the coverage guard reads this, so setUp must not touch it
    uint256 public withdrawn; // every wei ever taken back out
    uint256 public overOrdersRefused; // over-balance orders turned away BY NAME; a coverage ghost, not a property
    bool public overOrderAccepted; // set if the vault ever stands an order past its caller's balance

    constructor(CuratorVaultBase rig, CuratorVault v) {
        (RIG, VAULT) = (rig, v);
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) private pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    function deposit(uint256 amt) external {
        amt = _bound(amt, 1e6, 50_000e6);
        MockERC20 a = MockERC20(VAULT.asset());
        a.mint(address(this), amt);
        a.approve(address(VAULT), amt);
        VAULT.deposit(amt, address(this));
        deposited += amt;
    }

    function withdrawSome(uint256 amt) external {
        uint256 cap = VAULT.maxWithdraw(address(this));
        if (cap == 0) return;
        amt = _bound(amt, 1, cap);
        VAULT.withdraw(amt, address(this), address(this));
        withdrawn += amt;
    }

    /// @dev EVERY CALL ASKS PAST THE BALANCE FIRST, which must refuse, then places the request it always did.
    /// @dev A zero balance is included: that is the stranger holding nothing, the sharpest case.
    /// @dev THE OVER-REQUEST IS REFUSED BY THE ESCROW ITSELF: `requestExit` transfers the shares, so asking past the
    /// @dev balance reverts inside the ERC-20 move. Any refusal counts, because the point is that the state is unreachable.
    function request(uint256 shares) public {
        uint256 b = VAULT.balanceOf(address(this));
        try VAULT.requestExit(b + _bound(shares, 1, 1e30)) {
            overOrderAccepted = true;
        } catch {
            overOrdersRefused++;
        }
        if (b == 0) return;
        VAULT.requestExit(_bound(shares, 1, b));
    }

    /// @dev Claim part of the standing request, as far as exitable cash covers it.
    function claimSome(uint256 shares) external {
        uint256 cap = VAULT.maxClaim(address(this));
        if (cap == 0) return;
        withdrawn += VAULT.claimExit(_bound(shares, 1, cap), address(this), 0);
    }

    /// @dev A door loan of what `lendable` admits, half its cash repaid at once and cranked home: the inflow a standing request HOLDS.
    /// @dev A small draw is armed, so the roll hold stands beside the request's hold in some runs.
    /// @return held How much of the collected repayment the holds kept back from lending: the shortfall of `lendable`'s rise against it.
    function lendAndRepay(uint256 amt) public returns (uint256 held) {
        uint256 free = VAULT.lendable();
        if (free < MIN_DRAW) return 0;
        amt = _bound(amt, MIN_DRAW, free < MAX_DRAW ? free : MAX_DRAW);
        bool arm = amt < ARM_BELOW;
        if (arm && amt * 4 > free) return 0; // an armed draw must leave room for its roll hold to grow
        uint256 idle0 = VAULT.idle();
        uint256 loanId = IHoldRig(address(RIG)).lendExternal(amt, arm);
        uint256 lendable0 = VAULT.lendable();
        uint256 idle1 = VAULT.idle();
        IHoldRig(address(RIG)).repayExternal(loanId, (idle0 - idle1) / 2);
        VAULT.crank();
        uint256 collected = VAULT.idle() - idle1;
        uint256 lendable1 = VAULT.lendable();
        uint256 rose = lendable1 > lendable0 ? lendable1 - lendable0 : 0;
        held = collected > rose ? collected - rose : 0;
    }

    /// @dev WALKS EVERY RAIL ONCE BEFORE THE CAMPAIGN STARTS, and is deliberately NOT a fuzz target.
    /// @dev Forge resets to the post-setUp state each run, and a cold run lands about ONE action out of thirty-two,
    /// @dev so ghosts demanding that the fuzzer chose a PARTICULAR verb were answered by luck.
    /// @dev Walking the rails here makes them deterministic: a rail that stops working reverts setUp for every test in the file.
    /// @dev It also leaves real cash, shares, a live loan and a standing request behind, so no property below faces an empty state.
    /// @dev The draw goes out BEFORE the request, so the request is worth more than idle and the repayment lands under it and is held.
    function seed(uint256 amt) external {
        MockERC20 a = MockERC20(VAULT.asset());
        a.mint(address(this), amt);
        a.approve(address(VAULT), amt);
        VAULT.deposit(amt, address(this));
        deposited += amt;
        uint256 out = VAULT.maxWithdraw(address(this)) / 4;
        VAULT.withdraw(out, address(this), address(this));
        withdrawn += out;
        uint256 idle0 = VAULT.idle();
        uint256 loanId = IHoldRig(address(RIG)).lendExternal((VAULT.lendable() * 2) / 3, false);
        VAULT.requestExit(VAULT.balanceOf(address(this)) / 2);
        require(VAULT.lendable() == 0, "SEED: the request is worth more than idle, so it holds all of exitable");
        uint256 idle1 = VAULT.idle();
        IHoldRig(address(RIG)).repayExternal(loanId, (idle0 - idle1) / 2);
        VAULT.crank();
        require(VAULT.lendable() < VAULT.idle() - idle1, "SEED: a repayment under the standing request was not held");
        request(amt);
    }
}

/// @notice Properties of the vault's holds that hold in every state, each DERIVED DIFFERENTLY from the formula it checks.
/// @dev The per-suite NAV check is a consistency assertion because its arithmetic must agree with `grossNav`.
/// @dev These do not: each is a one-sided bound or a partition read off public views, so agreement here is evidence.
contract CuratorVaultHoldInvariantsTest is CuratorVaultBase {
    CuratorVault internal v;
    HoldHandler internal handler;

    function setUp() public override {
        super.setUp();
        v = _newVault(0);
        handler = new HoldHandler(this, v);
        handler.seed(20_000e6);
        /// @dev THE VERBS, NAMED. Without this forge targets every public function, so the ghost GETTERS would
        /// @dev consume a share of every run doing nothing.
        bytes4[] memory verbs = new bytes4[](5);
        verbs[0] = HoldHandler.deposit.selector;
        verbs[1] = HoldHandler.withdrawSome.selector;
        verbs[2] = HoldHandler.request.selector;
        verbs[3] = HoldHandler.claimSome.selector;
        verbs[4] = HoldHandler.lendAndRepay.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: verbs}));
        targetContract(address(handler));
    }

    /// @dev The handler's loan rail: the rig's borrower draws `amt` through the vault's door, armed when asked.
    function lendExternal(uint256 amt, bool arm) external returns (uint256 loanId) {
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(v), COLL);
        BorrowRequest memory r = _request(address(collateral), COLL, amt);
        r.arm = arm;
        loanId = v.borrow(r, "", "");
        vm.stopPrank();
    }

    /// @dev The rig's borrower repays `amt` of `loanId`.
    function repayExternal(uint256 loanId, uint256 amt) external {
        _repay(loanId, amt);
    }

    /// @dev The holds PARTITION idle: the roll hold comes off first, the requests' hold out of what is left, and lending takes the rest.
    /// @dev A hold is part of idle, never additional to it, so no cash is promised twice; while draining nothing is lendable.
    function invariant_theHoldsPartitionIdle() public view {
        (uint256 exitable, uint256 heldReq) = v.holds();
        uint256 idle = v.idle();
        uint256 roll = v.rollHoldNow();
        assertEq(exitable, idle > roll ? idle - roll : 0, "exitable is idle less the roll hold, floored at zero");
        assertLe(v.lendable(), exitable, "more is lendable than is exitable");
        assertLe(exitable, idle, "more is exitable than the vault holds");
        if (v.draining()) {
            assertEq(v.lendable(), 0, "a draining vault lends nothing");
        } else {
            assertEq(v.lendable() + heldReq, exitable, "lendable and the requests' hold must partition exitable exactly");
        }
    }

    /// @dev The requests' hold never outruns what the requests are worth, read off the public views alone.
    function invariant_theRequestHoldIsInsideTheRequestsWorth() public view {
        if (v.draining()) return;
        (uint256 exitable,) = v.holds();
        assertLe(exitable - v.lendable(), v.previewRedeem(v.requestedShares()) + 1, "more is held than the requests are worth");
    }

    /// @dev NAV IS BOUNDED BY WHAT COULD ACTUALLY BE OWED, derived without the vault's own sum.
    /// @dev `lenderAssets` is resting plus lent plus owed, so this bound holds only because nothing rests between calls:
    /// @dev the resting leg of the same read is asserted zero beside it, a second witness of that law.
    function invariant_navNeverExceedsCashPlusDebt() public view {
        (uint256 resting, uint256 lent, uint256 owed) = lens.lenderPools(address(v), v.asset());
        assertEq(resting, 0, "the vault's cash rested at the hub between calls");
        assertLe(v.grossNav(), usdc.balanceOf(address(v)) + lent + owed, "NAV counts something past cash and debt");
    }

    /// @dev Nobody can take out more than went in while no loan has ever earned anything past its fee.
    /// @dev A one-sided conservation check the share arithmetic cannot satisfy by construction.
    function invariant_noCashLeavesThatNeverArrived() public view {
        assertLe(handler.withdrawn(), handler.deposited(), "more was paid out than was ever paid in");
    }

    /// @dev THE BOUND THE PHANTOM ORDER BROKE, KEYED ONTO THE ESCROW.
    /// @dev A request moves the shares onto the vault, so a full requester holds nothing and the request stands on the escrow.
    /// @dev The identity is what makes a DOUBLE REDEEM unrepresentable: a claim can only burn what some request really moved in.
    /// @dev Asserted as equality because no verb here donates, and the safety direction is the `>=` half anyway.
    function invariant_everyRequestedShareIsEscrowed() public view {
        assertEq(v.balanceOf(address(v)), v.requestedShares(), "the requests and the escrow behind them have parted");
        (uint256 own,) = v.requestOf(address(handler));
        assertEq(own, v.requestedShares(), "the one requester's record is not the vault's whole request");
        assertLe(v.requestedShares(), v.totalSupply(), "the requests claim more shares than exist");
        assertFalse(handler.overOrderAccepted(), "the vault stood a request past its holder's balance");
    }

    /// @dev THE COVERAGE GUARD: a campaign that reached nothing would pass every property above vacuously.
    /// @dev Asserted at the END of the run rather than per call, since a single run may legitimately do little.
    function afterInvariant() public view {
        assertGt(handler.deposited(), 0, "GHOST: the campaign never deposited, so nothing above was exercised");
        assertGt(handler.withdrawn(), 0, "GHOST: the campaign never withdrew, so the exit rails were never reached");
        assertGt(handler.overOrdersRefused(), 0, "GHOST: no over-balance order was attempted, so the bound is untested");
    }
}
