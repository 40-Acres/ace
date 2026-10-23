// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Ace} from "../../src/ace/hub/Ace.sol";
import {OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {LaunchLock, Leg} from "../../src/entities/launch/LaunchLock.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {LaunchMarketParams} from "./LaunchFixture.sol";

/// @title LockAccountHandler
/// @notice The fuzzing surface for ONE lock account on ONE recordless launch market whose lender is the beneficiary's own wallet.
/// @notice Every action the account or the hub offers that can move a pledged unit: pledge, release, repay, default, reclaim.
/// @notice Plus the two the world does to it: time passing, and a donation landing.
/// @dev An over-capacity pledge or release that LANDS is recorded in `breached` rather than asserted here: fail_on_revert is off.
/// @dev The account keeps no loan list, so this handler keeps its own: every loan a pledge opened, in order.
contract LockAccountHandler is WarpClock {
    uint256 internal constant ALLOC = 10_000e18;
    uint256 internal constant MIN_UNITS = 150e18; // the least that covers a minimum ticket at $0.10 and k = 1.4
    uint256 internal constant PRINCIPAL = 10e6; // the market's minimum ticket

    Ace public ace;
    PositionManager public pm;
    AceReader public read;
    AceLens public lens;
    MockERC20 public token;
    MockERC20 public usdc;
    LaunchLock public lock;
    LockAccount public acct;
    bytes32 public id;
    uint256 public T0;
    uint256 public scheduleId; // the account's schedule in `lock`
    uint256[] internal _loans; // the ghost loan list: every loan a pledge opened, in order

    address public alice = address(0xA11CE5);
    address public alt = address(0xA17A17);
    address public payer = address(0x9A7E4);

    uint256 public totalIn; // every unit that ever landed in the account: the allocation plus donations
    bool public breached; // an over-capacity pledge or an over-release LANDED
    mapping(bytes32 => uint256) public hits; // per-verb landings, the reach counters

    constructor(uint256 scheduleId_) {
        _warpTo(1_000_000);
        T0 = _now();
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = new AceLens(address(ace));
        token = new MockERC20("Launch", "LCH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        Leg[] memory team = new Leg[](2);
        team[0] = Leg({beneficiary: address(0), amount: 0, cliff: 89 days, duration: 89 days}); // one tranche at T0 + 90 days
        team[1] = Leg({beneficiary: address(0), amount: 0, cliff: 29 days, duration: 364 days}); // to T0 + 365 days, unlocking at T0 + 30 days
        lock = new LaunchLock(address(token), address(ace), uint64(T0 + 1 days), 30 days, team);
        scheduleId = scheduleId_;
        acct = LockAccount(lock.account(alice, scheduleId_));
        id = ace.createMarket(
            LaunchMarketParams.launchParams(
                LaunchMarketParams.Ctx({
                    quote: address(usdc),
                    token: address(token),
                    lender: alt,
                    price: AceFixtures.px(0.1e18, address(usdc), address(token)),
                    baseBps: 40,
                    minDebt: PRINCIPAL,
                    minCoverageWad: 1.4e18
                })
            )
        );
        usdc.mint(alt, 1_000_000e6);
        vm.startPrank(alt);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(id, 1_000_000e6);
        vm.stopPrank();
        token.mint(address(acct), ALLOC);
        totalIn = ALLOC;
    }

    // ---- actions ----

    /// @notice A pledge aimed across the capacity boundary: about half the draws ask for more than V(E) leaves.
    function pledge(uint256 unitsSeed, uint256 tenorSeed) external {
        uint64 tenor = uint64(bound(tenorSeed, 7 days, 30 days));
        uint256 cap = acct.capacity(uint64(_now()) + tenor);
        uint256 units = bound(unitsSeed, MIN_UNITS, cap + 2 * MIN_UNITS);
        if (units > token.balanceOf(address(acct))) units = token.balanceOf(address(acct));
        if (units < MIN_UNITS) return;
        vm.prank(alice);
        try acct.borrow(id, units, PRINCIPAL, tenor, OpenBounds(0, 0, 0)) returns (uint256 loanId) {
            _loans.push(loanId);
            if (units > cap) breached = true;
            hits["pledge"]++;
        } catch {
            if (units > cap) hits["pledgeRefused"]++;
        }
    }

    /// @notice A pledge of exactly the capacity at the chosen expiry: the boundary itself, which must land.
    function pledgeAtCapacity(uint256 tenorSeed) external {
        uint64 tenor = uint64(bound(tenorSeed, 7 days, 30 days));
        uint256 units = acct.capacity(uint64(_now()) + tenor);
        if (units > token.balanceOf(address(acct))) units = token.balanceOf(address(acct));
        if (units < MIN_UNITS) return;
        vm.prank(alice);
        try acct.borrow(id, units, PRINCIPAL, tenor, OpenBounds(0, 0, 0)) returns (uint256 loanId) {
            _loans.push(loanId);
            hits["pledge"]++;
        } catch {}
    }

    /// @notice A release of some of what is releasable, and a probe one atom past it.
    function release(uint256 seed) external {
        uint256 r = acct.releasable();
        vm.prank(alice);
        try acct.release(r + 1) {
            breached = true;
        } catch {}
        if (r == 0) return;
        uint256 w = bound(seed, 1, r);
        vm.prank(alice);
        try acct.release(w) {
            hits["release"]++;
        } catch {}
    }

    /// @notice A third party pays a live pledged loan off in full.
    function repay(uint256 idxSeed) external {
        (bool found, uint256 loanId) = _pick(idxSeed, true);
        if (!found) return;
        uint256 debt = read.debtOf(loanId);
        usdc.mint(payer, debt);
        vm.startPrank(payer);
        usdc.approve(address(ace), debt);
        try ace.repay(loanId, debt) {
            hits["repay"]++;
        } catch {}
        vm.stopPrank();
    }

    /// @notice The lender lets a live pledged loan run out, ends it, and takes the pot in kind; the unpaid backstop half the time.
    function defaultLoan(uint256 idxSeed, bool backstop) external {
        (bool found, uint256 loanId) = _pick(idxSeed, true);
        if (!found) return;
        uint256 at = read.loan(loanId).expiry;
        if (backstop) at += 2 hours + 1; // past any roll window a 30-day tenor carries
        _warpAtLeastTo(at);
        vm.startPrank(alt);
        if (backstop) {
            try ace.settleExpired(loanId) {
                hits["settleExpired"]++;
            } catch {}
        } else {
            try ace.forceClose(loanId) {
                hits["forceClose"]++;
            } catch {}
        }
        try ace.redeemInKind(loanId, alt) {} catch {}
        vm.stopPrank();
    }

    /// @notice Anyone reclaims any ledger loan, closed or not.
    function reclaim(uint256 idxSeed) external {
        (bool found, uint256 loanId) = _pick(idxSeed, false);
        if (!found) return;
        try acct.reclaim(loanId) returns (uint256 landed) {
            if (landed > 0) hits["reclaim"]++;
        } catch {}
    }

    function warp(uint256 seed) external {
        _warpBy(bound(seed, 1 hours, 5 days));
    }

    function donate(uint256 seed) external {
        uint256 d = bound(seed, 1, 1_000e18);
        token.mint(address(acct), d);
        totalIn += d;
        hits["donate"]++;
    }

    // ---- reads for the invariants ----

    /// @notice What the account can still reach: its balance, plus each ledger loan's units in hub custody or hub credit.
    function claimable() external view returns (uint256 sum) {
        sum = token.balanceOf(address(acct));
        uint256 n = _loans.length;
        for (uint256 i; i < n; ++i) {
            uint256 loanId = _loans[i];
            (uint256 units,) = acct.pledgeOf(loanId);
            if (units == 0) continue;
            sum += ace.isClosed(loanId) ? read.unitsOwedOf(loanId, address(acct)) : read.loan(loanId).collateralUnits;
        }
    }

    /// @notice How many loans the account's pledges opened.
    function loanCount() external view returns (uint256) {
        return _loans.length;
    }

    /// @notice The `i`th loan the account's pledges opened.
    function loanAt(uint256 i) external view returns (uint256) {
        return _loans[i];
    }

    function now_() external view returns (uint256) {
        return _now();
    }

    /// @dev A ledger loan picked by seed; `live` restricts to loans the hub has not closed.
    function _pick(uint256 seed, bool live) internal view returns (bool, uint256) {
        uint256 n = _loans.length;
        if (n == 0) return (false, 0);
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 loanId = _loans[(start + k) % n];
            (uint256 units,) = acct.pledgeOf(loanId);
            if (units == 0) continue;
            if (live && ace.isClosed(loanId)) continue;
            return (true, loanId);
        }
        return (false, 0);
    }
}
