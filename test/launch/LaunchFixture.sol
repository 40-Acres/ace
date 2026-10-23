// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {LaunchLock, Leg, Schedule} from "../../src/entities/launch/LaunchLock.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @dev The two calls every quote mock in this suite answers.
interface IMintable {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title LaunchMarketParams
/// @notice A launch market's params, for a lender to build and pass to `createMarket`: no record, no deleverage channel, no bounty, any borrower.
/// @dev Field order is the hash preimage, so every field is set BY NAME. Recordless is the shape a lock account pledges into.
library LaunchMarketParams {
    /// @dev Everything the shape cannot fix: the tokens, the lender, and the lender's four terms.
    struct Ctx {
        address quote; // the cash the lender rests and a borrower draws
        address token; // the launch token, pledged as collateral
        address lender; // sole tenancy: the one address whose cash rests here
        uint256 price; // the lender's bid, raw Q96 quote atoms per token atom
        uint256 baseBps; // the lender's rate per MIN_TENOR
        uint256 minDebt; // the smallest ticket, in the quote's own atoms
        uint256 minCoverageWad; // WAD; caps a ticket at 1/k of the bid, and a default forfeits that whole line
    }

    uint64 internal constant MIN_TENOR = 7 days; // the shortest term, and the unit the rate is quoted in
    uint64 internal constant MAX_TENOR = 30 days; // the longest term a launch market writes

    /// @notice A launch market on `c`: no record, so nothing moves title before expiry, and every channel and bounty off.
    function launchParams(Ctx memory c) internal pure returns (MarketParams memory p) {
        p.quote = c.quote;
        p.collateral = c.token;
        p.record = address(0);
        p.borrower = address(0);
        p.lender = c.lender;
        p.inventoryAsk = false; // the hub sells no forfeit: the lender takes it in kind
        p.price = c.price;
        p.fillFeeBps = 0;
        p.minCoverageWad = c.minCoverageWad;
        p.baseBps = c.baseBps;
        p.minTenor = MIN_TENOR;
        p.maxTenor = MAX_TENOR;
        p.minDebt = c.minDebt;
        p.deleverageFloorEpsBps = 0;
        p.deleverageBandBps = 0; // bullet: nothing may be sold against a live loan
        p.deleverageTargetBps = 0;
        p.deleverageStopBps = 0;
        p.deleverageProtocolBps = 0;
        p.settleBountyBps = 0;
    }
}

/// @title LaunchFixture
/// @notice One hub, one launch token, one lock with a buyer schedule and two team legs from one start, and one recordless launch market.
/// @dev The market's lender is `alt`: the beneficiary's own second wallet, which is the bypass the capacity rule exists to close.
abstract contract LaunchFixture is WarpClock {
    Ace internal ace;
    PositionManager internal pm;
    AceReader internal read;
    AceLens internal lens;
    MockERC20 internal token; // the launch token
    MockERC20 internal usdc; // the quote
    LaunchLock internal lock;
    LockAccount internal acct; // alice's buyer account
    bytes32 internal id; // the recordless launch market alt lends in

    address internal alice = address(0xA11CE5); // the beneficiary
    address internal alt = address(0xA17A17); // alice's second wallet, the market's lender
    address internal bob = address(0xB0B); // an unrelated holder
    address internal stranger = address(0x57A1);
    address internal payer = address(0x9A7E4); // a third party who repays

    uint256 internal T0; // the fixture's anchor time
    uint256 internal constant ALLOC = 10_000e18; // alice's buyer allocation, landed in the account
    uint256 internal constant CASH = 1_000_000e6; // alt's resting cash
    uint256 internal constant MIN_DEBT = 10e6;
    uint256 internal constant COVERAGE = 1.4e18;
    uint256 internal constant BASE_BPS = 40;
    uint256 internal constant TEAM_CLIFF = 1; // schedule id: one tranche at T0 + 90 days, its cliff and duration both 89 days from the start
    uint256 internal constant TEAM_LINEAR = 2; // schedule id: linear from the start to T0 + 365 days, unlocking at T0 + 30 days
    uint64 internal constant WEEK = 7 days;

    function setUp() public virtual {
        T0 = _now();
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = new AceLens(address(ace));
        token = new MockERC20("Launch", "LCH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        lock = _newLock(address(token));
        acct = LockAccount(lock.account(alice, lock.BUYER()));
        id = _market(address(usdc), alt);
        _rest(alt, CASH);
        _land(address(acct), ALLOC);
    }

    /// @dev Every schedule's start: one day after the anchor.
    function _start() internal view returns (uint64) {
        return uint64(T0 + 1 days);
    }

    /// @dev The fixture's lock on `t`: a 30-day buyer vest, then the two team legs, all from `_start()`.
    function _newLock(address t) internal returns (LaunchLock) {
        return new LaunchLock(t, address(ace), _start(), 30 days, _legs());
    }

    /// @dev The two team legs: a single tranche at T0 + 90 days, then a linear vest to T0 + 365 days behind a cliff at T0 + 30 days.
    function _legs() internal pure returns (Leg[] memory l) {
        l = new Leg[](2);
        l[0] = Leg({beneficiary: address(0), amount: 0, cliff: 89 days, duration: 89 days});
        l[1] = Leg({beneficiary: address(0), amount: 0, cliff: 29 days, duration: 364 days});
    }

    /// @dev The buyer schedule: linear over 30 days, starting one day after the anchor.
    function _buyer() internal view returns (Schedule memory) {
        return Schedule({start: _start(), cliff: 0, duration: 30 days});
    }

    /// @dev The two team schedules the legs make, as the lock stores them.
    function _team() internal view returns (Schedule[] memory t) {
        Leg[] memory l = _legs();
        t = new Schedule[](l.length);
        for (uint256 i; i < l.length; ++i) {
            t[i] = Schedule({start: _start(), cliff: l[i].cliff, duration: l[i].duration});
        }
    }

    /// @dev The fixture market's terms: $0.10 a token, k = 1.4.
    function _ctx(address quote, address lender) internal view returns (LaunchMarketParams.Ctx memory) {
        return LaunchMarketParams.Ctx({
            quote: quote,
            token: address(token),
            lender: lender,
            price: AceFixtures.px(0.1e18, quote, address(token)),
            baseBps: BASE_BPS,
            minDebt: MIN_DEBT,
            minCoverageWad: COVERAGE
        });
    }

    function _market(address quote, address lender) internal returns (bytes32) {
        return ace.createMarket(LaunchMarketParams.launchParams(_ctx(quote, lender)));
    }

    /// @dev The lender rests cash in the fixture market.
    function _rest(address lender, uint256 amount) internal {
        _restIn(id, address(usdc), lender, amount);
    }

    /// @dev The lender rests `quote` cash in market `m`; every quote mock here mints freely.
    function _restIn(bytes32 m, address quote, address lender, uint256 amount) internal {
        IMintable(quote).mint(lender, amount);
        vm.startPrank(lender);
        IMintable(quote).approve(address(ace), amount);
        ace.deposit(m, amount);
        vm.stopPrank();
    }

    /// @dev Tokens arriving at an account the way a claim or a direct funding lands them: a plain transfer.
    function _land(address to, uint256 amount) internal {
        token.mint(to, amount);
    }

    /// @dev Nearly the largest principal `units` admits at the fixture price and coverage: a tenth of a cent shy.
    function _maxPrincipal(uint256 units) internal pure returns (uint256) {
        return units / 1e13 * 1e18 / COVERAGE - 1e3; // units * $0.10 in 6-decimal atoms, over k
    }

    /// @dev Alice pledges through her account with no open bounds.
    function _borrow(uint256 units, uint256 principal, uint64 tenor) internal returns (uint256) {
        vm.prank(alice);
        return acct.borrow(id, units, principal, tenor, _noBounds());
    }

    function _noBounds() internal pure returns (OpenBounds memory) {
        return OpenBounds(0, 0, 0);
    }

    /// @dev The lender ends an expired loan and takes its pot in kind.
    function _default(uint256 loanId) internal returns (uint256 taken) {
        _warpAtLeastTo(read.loan(loanId).expiry);
        vm.startPrank(alt);
        ace.forceClose(loanId);
        uint256 pre = token.balanceOf(alt);
        ace.redeemInKind(loanId, alt);
        taken = token.balanceOf(alt) - pre;
        vm.stopPrank();
    }

    /// @dev A third party pays a loan off in full.
    function _repayAll(uint256 loanId) internal {
        uint256 debt = read.debtOf(loanId);
        usdc.mint(payer, debt);
        vm.startPrank(payer);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();
    }
}
