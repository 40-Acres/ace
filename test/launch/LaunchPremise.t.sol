// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {NotExpired} from "../../src/ace/hub/Settlement.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";
import {Leg} from "../../src/entities/launch/LaunchLock.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {RunwayHook} from "../../src/entities/launch/RunwayHook.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {LaunchMarketParams} from "./LaunchFixture.sol";
import {RunwayFixture} from "./RunwayFixture.sol";

/// @title LaunchPremise
/// @notice THE PREMISE THE TIME GATE RESTS ON, as a property: before launchBy no launch token is held outside the launch's own contracts.
/// @notice Every token source is driven, by its holder and by strangers, at random times up to and AT launchBy, with the pool never opened.
/// @notice Sources: team legs on two curves, buyer accounts, pledges and the lender's take, settle and the ops wallet, LP fees, sweeps.
/// @notice Plus the boundary the gate couples: the first second a buyer's token vests is the first second the hook shuts the key.
/// @dev Inside is the strategy, the auction, the budget, the ops wallet, the hub's custodian and the launch's lock accounts; a burn leaves the supply.
/// @dev The auction is final and a failed migration has returned the reserve, so settle's only refusal before launchBy is TooEarly.
contract LaunchPremiseTest is RunwayFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant PRICE = 1 << 96;
    uint256 internal constant CAROL_AMT = 50_000e18; // carol's team leg, on a 90-day tranche
    uint256 internal constant ALICE_BUYS = 200_000e18; // what the auction's claims land in alice's buyer account
    uint256 internal constant BOB_BUYS = 100_000e18;
    uint256 internal constant MIN_PLEDGE = 200e18; // comfortably covers the market's smallest ticket at its price and coverage
    address internal carol = address(0xCA401);
    address internal lender = address(0x1E4D);

    Made internal m;
    bytes32 internal mkt; // a recordless launch market on the launch token
    address internal custody; // the hub's custodian, which holds every pledged unit
    address[4] internal who;
    uint256[] internal loans;

    function setUp() public override {
        super.setUp();
        who = [team, alice, bob, carol];
        m = _launch(_shape());
        custody = ace.POSITION_MANAGER();
        strat.send(m.token, address(m.auction), SUPPLY);
        m.auction.setState(m.auction.endBlock(), true, 0); // the auction's end is checkpointed
        strat.send(m.token, address(m.budget), SUPPLY); // a failed migration's recovery, before launchBy, returns the reserve
        _claimed(alice, ALICE_BUYS);
        _claimed(bob, BOB_BUYS);
        mkt = ace.createMarket(
            LaunchMarketParams.launchParams(
                LaunchMarketParams.Ctx({
                    quote: address(usdc),
                    token: m.token,
                    lender: lender,
                    price: AceFixtures.px(0.1e18, address(usdc), m.token),
                    baseBps: 40,
                    minDebt: 10e6,
                    minCoverageWad: 1.4e18
                })
            )
        );
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ace), 1_000_000e6);
        ace.deposit(mkt, 1_000_000e6);
        vm.stopPrank();
    }

    // ---- the launch ----

    /// @dev The default launch with a second team leg, carol's on a 90-day tranche, so two team curves hold tokens.
    function _shape() internal view returns (LaunchTokenFactory.LaunchInput memory p) {
        p = _input();
        p.legs = new Leg[](2);
        p.legs[0] = Leg({beneficiary: team, amount: TEAM_AMT, cliff: 30 days, duration: 365 days});
        p.legs[1] = Leg({beneficiary: carol, amount: CAROL_AMT, cliff: 90 days, duration: 90 days});
    }

    /// @dev What the auction's `claimTokens` does for a filled bid: the tokens move from the auction into the bidder's buyer account.
    /// @dev The lock's bid gate makes every bid's owner a buyer account; the fork rows pin that gate against the deployed auction.
    function _claimed(address buyer, uint256 amount) internal {
        address acct = m.lock.account(buyer, 0);
        vm.prank(address(m.auction));
        IERC20(m.token).transfer(acct, amount);
    }

    /// @dev The launch token's supply sitting anywhere but the launch's own contracts.
    function _outside() internal view returns (uint256) {
        IERC20 t = IERC20(m.token);
        uint256 inside = t.balanceOf(address(strat)) + t.balanceOf(address(m.auction)) + t.balanceOf(address(m.budget));
        inside += t.balanceOf(custody);
        address w = m.budget.wallet();
        if (w != address(0)) inside += t.balanceOf(w);
        for (uint256 i; i < who.length; ++i) {
            for (uint256 s; s < 3; ++s) {
                inside += t.balanceOf(m.lock.predict(who[i], s));
            }
        }
        return t.totalSupply() - inside;
    }

    // ---- the moves ----

    /// @dev One move by a holder or a stranger, chosen by `r`; a refusal is the expected outcome of most of them.
    function _step(uint256 r) internal {
        uint256 kind = r % 8;
        address w = who[(r >> 8) % 4];
        LockAccount a = LockAccount(m.lock.predict(w, (r >> 16) % 3));
        bool deployed = address(a).code.length != 0;
        uint256 x = r >> 24;
        if (kind == 0) {
            uint256 left = m.launchBy - _now();
            if (left != 0) _warpBy(1 + x % left);
        } else if (kind == 1 && deployed) {
            uint256 bal = IERC20(m.token).balanceOf(address(a));
            vm.prank(w);
            try a.release(1 + x % (bal + 1)) {} catch {}
        } else if (kind == 2) {
            vm.prank(stranger);
            try m.budget.collectFees(x) {} catch {}
        } else if (kind == 3 && deployed) {
            _pledge(w, a, x);
        } else if (kind == 4 && loans.length != 0) {
            uint256 loanId = loans[x % loans.length];
            vm.startPrank(lender);
            try ace.forceClose(loanId) {} catch {}
            try ace.redeemInKind(loanId, lender) {} catch {}
            vm.stopPrank();
        } else if (kind == 5) {
            vm.prank(stranger);
            try m.budget.settle() {} catch {}
            _drainWallet();
        } else if (kind == 6 && deployed) {
            vm.prank(stranger);
            try a.sweep(m.token) {} catch {}
        } else if (kind == 7) {
            uint256 held = IERC20(m.token).balanceOf(address(m.auction));
            if (held != 0) _claimed(w, 1 + x % held);
        }
    }

    /// @dev If a wallet exists, a stranger releases its launch token to the operator, the one way ops tokens leave it.
    function _drainWallet() internal {
        address w = m.budget.wallet();
        if (w == address(0)) return;
        vm.prank(stranger);
        try VestingWallet(payable(w)).release(m.token) {} catch {}
    }

    /// @dev `w` pledges all its account may at a random tenor into the launch market, borrowing the market's smallest ticket.
    function _pledge(address w, LockAccount a, uint256 x) internal {
        uint64 tenor = uint64(7 days + x % (23 days + 1));
        uint256 units = Math.min(a.capacity(uint64(_now()) + tenor), IERC20(m.token).balanceOf(address(a)));
        if (units < MIN_PLEDGE) return;
        vm.prank(w);
        try a.borrow(mkt, units, 10e6, tenor, OpenBounds(0, 0, 0)) returns (uint256 loanId) {
            loans.push(loanId);
        } catch {}
    }

    /// @dev Every holder tries to release one unit, then its whole balance, from every account it may hold.
    function _releaseEverything() internal {
        for (uint256 i; i < who.length; ++i) {
            for (uint256 s; s < 3; ++s) {
                LockAccount a = LockAccount(m.lock.predict(who[i], s));
                if (address(a).code.length == 0) continue;
                uint256 bal = IERC20(m.token).balanceOf(address(a));
                vm.startPrank(who[i]);
                try a.release(1) {} catch {}
                if (bal > 1) {
                    try a.release(bal) {} catch {}
                }
                vm.stopPrank();
            }
        }
    }

    // ---- the property ----

    /// @notice Any interleaving of every token source, at any times up to and AT launchBy: no launch token reaches an address outside the launch.
    function testFuzz_NoLaunchTokenIsLiquidBeforeLaunchBy(uint256 seed, uint8 steps) public {
        uint256 n = bound(steps, 8, 48);
        for (uint256 i; i < n; ++i) {
            _step(uint256(keccak256(abi.encode(seed, i))));
            assertEq(_outside(), 0, "a launch token is held outside the launch's own contracts before launchBy");
        }
        _warpTo(m.launchBy);
        _releaseEverything();
        vm.prank(stranger);
        try m.budget.settle() {} catch {}
        _drainWallet();
        assertEq(_outside(), 0, "a launch token left the launch AT launchBy");
        assertEq(m.budget.wallet(), address(0), "a wallet was made before launchBy had passed");
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(m.key.toId());
        assertEq(sqrtP, 0, "fixture: the pool opened");
    }

    /// @notice A buyer pledging the day before launchBy: the units sit in the hub's custodian, the loan expires past launchBy, and the
    /// @notice lender cannot take them AT launchBy, so the pledge path holds no token outside the launch.
    function test_APledgeBeforeLaunchByStaysInCustodyPastIt() public {
        _warpTo(m.launchBy - 1 days);
        LockAccount a = LockAccount(m.lock.predict(alice, 0));
        uint256 units = a.capacity(uint64(_now()) + 30 days);
        assertGt(units, MIN_PLEDGE, "fixture: the buyer can pledge");
        vm.prank(alice);
        uint256 loanId = a.borrow(mkt, units, 10e6, 30 days, OpenBounds(0, 0, 0));
        assertEq(IERC20(m.token).balanceOf(custody), units, "the pledge is not in custody");
        (, uint64 expiry) = a.pledgeOf(loanId);
        assertGt(expiry, m.launchBy, "a pledge expires inside launchBy");
        _warpTo(m.launchBy);
        vm.prank(lender);
        vm.expectRevert(NotExpired.selector);
        ace.forceClose(loanId);
        assertEq(_outside(), 0, "the pledge path paid a token out before launchBy");
    }

    /// @dev The PoolManager's wrap of the hook's refusal of `initialize`, carrying the hook's own error.
    function _refused(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(factory.HOOK()),
            IHooks.beforeInitialize.selector,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    /// @notice AT launchBy no account releases anything; a second later a buyer's first second has vested, no team unit has, and the key is shut.
    /// @notice So no block sees a launch token liquid while the launch's key could still open: buyer cliff 0 and the hook's `<=` meet exactly.
    function test_TheFirstLiquidSecondIsTheFirstShutSecond() public {
        _warpTo(m.launchBy);
        for (uint256 i; i < who.length; ++i) {
            for (uint256 s; s < 3; ++s) {
                LockAccount a = LockAccount(m.lock.predict(who[i], s));
                if (address(a).code.length != 0) assertEq(a.releasable(), 0, "an account releases AT launchBy");
            }
        }
        _warpTo(m.launchBy + 1);
        LockAccount buyer = LockAccount(m.lock.predict(alice, 0));
        uint256 first = buyer.releasable();
        assertEq(first, ALICE_BUYS / 30 days, "a second past launchBy, the buyer's first second has not vested");
        assertEq(LockAccount(m.lock.predict(team, TEAM_LINEAR)).releasable(), 0, "a team unit is liquid inside its cliff");
        vm.expectRevert(_refused(abi.encodeWithSelector(RunwayHook.NotALaunchPool.selector)));
        strat.openPool(m.key, PRICE);
        vm.prank(alice);
        buyer.release(first);
        assertEq(IERC20(m.token).balanceOf(alice), first, "the buyer's first second did not pay");
    }
}
