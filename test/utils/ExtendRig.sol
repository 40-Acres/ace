// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {WarpClock} from "./WarpClock.sol";
import {DeleverageCrank} from "./DeleverageCrank.sol";
import {AceFixtures} from "./AceFixtures.sol";
import {AceReader} from "./AceReader.sol";
import {BookedQuote} from "./BookedQuote.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {Extension} from "../../src/interfaces/IRollPolicy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";

/// @title ExtendRig
/// @notice The shared rig for the extend-in-place suites: one market at par lent by `alice`, a record at par, no treasury.
/// @notice The deleverage channel is on, so a melt has a crank to pay through; a suite installs its own roll policy.
/// @dev The borrower's address has nonzero top bytes ON PURPOSE: an echo of calldata word 0 then never equals the selector.
/// @dev Every helper reads the hub through `AceReader` or `extsload`, never a guarded view, so a helper can run anywhere.
abstract contract ExtendRig is WarpClock, DeleverageCrank {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockStakeVault internal coll;
    MockPersistenceRecord internal rec;
    bytes32 internal id;
    uint256 internal par;

    address internal alice = address(0xA11CE); // the market's one lender
    address internal bob = address(0xB0BB); // another lender, for the cross-lender rows
    address internal borrower = address(uint160(uint256(keccak256("ace.extend.borrower")))); // top 16 bytes nonzero
    address internal keeper = address(0xCAFE); // a third party: no loan, not the lender
    address internal stranger = address(0x5EE);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant MAX_T = 28 days;
    uint256 internal constant BASE = 40;
    uint256 internal constant P = 10_000e6;
    uint256 internal constant K = 1.4e18;
    uint256 internal constant S = 1 << 96;
    uint256 internal constant MIN_PRINCIPAL = 10e6;
    uint256 internal constant BOUNTY = 50; // the fixture's settle bounty, so a settlement's sliver is never zero

    function _deleverageQuote() internal view override returns (address) {
        return address(usdc);
    }

    function setUp() public virtual {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        rec = new MockPersistenceRecord(address(usdc), address(coll));
        par = AceFixtures.priceAt(address(usdc), address(coll), 0);
        rec.setMinPrice(par);
        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(_params(alice), address(0));
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
    }

    function _params(address lender) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(rec);
        p.lender = lender;
        p.baseBps = BASE;
        p.minTenor = TEN7;
        p.maxTenor = MAX_T;
        p.minCoverageWad = K;
        p.minPrincipal = MIN_PRINCIPAL;
        p.settleBountyBps = BOUNTY;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 5000;
        p.deleverageStopBps = 1000;
        p.deleverageProtocolBps = 500;
    }

    /// @dev Another market of `lender`'s on the rig's pair, at another rate so another id, resting `cash`.
    function _siblingOf(address lender, uint256 cash) internal returns (bytes32 mid) {
        MarketParams memory p = _params(lender);
        p.baseBps = BASE + 10;
        mid = ace.createMarket(p);
        if (cash != 0) _deposit(mid, lender, cash);
    }

    function _deposit(bytes32 mid, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    function _drain(bytes32 mid, address lender) internal {
        uint256 cash = ace.restingOf(mid);
        if (cash == 0) return;
        vm.prank(lender);
        ace.withdraw(mid, cash, lender, 0);
    }

    /// @dev Units that put `debt`'s trigger at `thetaBps` of par.
    function _units(uint256 debt, uint256 thetaBps) internal view returns (uint256) {
        return FullMath.mulDiv(K * debt, S * 10000, thetaBps * par * 1e18);
    }

    /// @dev `who` opens `principal` in `mid` for `tenor`, its trigger at `thetaBps` of par, and approves the hub for its quote.
    function _openIn(bytes32 mid, address who, uint256 principal, uint64 tenor, uint256 thetaBps) internal returns (uint256 loanId) {
        uint256 units = _units(principal, thetaBps);
        coll.mint(who, units);
        vm.startPrank(who);
        coll.approve(address(pm), units);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, units, principal, tenor, who, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _open(uint256 principal, uint64 tenor, uint256 thetaBps) internal returns (uint256) {
        return _openIn(id, borrower, principal, tenor, thetaBps);
    }

    /// @dev The title collection is read BEFORE the prank, so the prank lands on the transfer and not on the getter.
    function _moveTitle(uint256 loanId, address from, address to) internal {
        IERC721 title = IERC721(ace.POSITION_TITLE());
        vm.prank(from);
        title.transferFrom(from, to, loanId);
    }

    function _setPolicy(address lender, address policy) internal {
        vm.prank(lender);
        ace.setRollPolicy(policy);
    }

    /// @dev The origination fee on `debt` for `tenor`; an extension's fee is this on the time it adds.
    function _fee(uint256 debt, uint64 tenor) internal pure returns (uint256) {
        return LoanMath.originationFee(debt, tenor, BASE, TEN7);
    }

    /// @dev The fee an extension of `loanId` would charge now: the fee on its own tenor from now, past its expiry.
    function _feeNow(uint256 loanId) internal view returns (uint256) {
        Loan memory l = read.loan(loanId);
        return _fee(l.debt, uint64(_now() + l.tenor - l.expiry));
    }

    /// @dev The most an extension of `loanId` can cost: the fee on its whole own tenor.
    function _ceiling(uint256 loanId) internal view returns (uint256) {
        return _fee(read.debtOf(loanId), read.loan(loanId).tenor);
    }

    /// @dev Mint `who` the cash and approve the hub for it, so an extension can pull.
    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(ace), type(uint256).max);
    }

    /// @dev `who` extends `loanId` now, minted the fee ceiling first.
    function _extend(address who, uint256 loanId) internal returns (uint256 fee) {
        _fund(who, _ceiling(loanId));
        vm.prank(who);
        fee = ace.extend(loanId, 0, "");
    }

    /// @dev The unearned share of `e` on `loanId` now, floored, exactly as the hub refunds an escrow.
    function _unearned(uint256 loanId, uint256 e) internal view returns (uint256) {
        Loan memory l = read.loan(loanId);
        if (l.tenor == 0) return 0;
        uint256 remaining = l.expiry > _now() ? l.expiry - _now() : 0;
        uint256 r = FullMath.mulDiv(e, remaining, l.tenor);
        return r < e ? r : e;
    }

    function _mp(bytes32 mid) internal view returns (MarketParams memory) {
        return ace.idToMarketParams(mid);
    }

    /// @dev The extension a caller's `extend` hands the policy now: the whole lot, the debt unchanged, the end moved to now plus the tenor.
    function _extensionOf(uint256 loanId, address caller) internal view returns (Extension memory e) {
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = _mp(l.market);
        e.caller = caller;
        e.loanId = loanId;
        e.borrower = l.borrower;
        e.units = l.collateralUnits;
        e.debt = l.debt;
        e.newDebt = l.debt;
        e.expiry = l.expiry;
        e.newExpiry = uint64(_now()) + l.tenor;
        e.src = mp;
        e.dst = mp;
    }

    /// @dev O10 on one live loan: its debt is exactly its claim.
    function _assertDebtIsClaim(uint256 loanId) internal view {
        Loan memory l = read.loan(loanId);
        assertEq(l.debt, read.claimOf(l.market, loanId), "O10: a live loan's debt is its claim");
    }

    /// @dev O1 over the rig's market and its lender: the hub's quote balance is exactly its booked pots.
    function _assertSolvent() internal view {
        bytes32[] memory markets = new bytes32[](1);
        markets[0] = id;
        address[] memory lenders = new address[](1);
        lenders[0] = alice;
        assertEq(usdc.balanceOf(address(ace)), BookedQuote.total(ace, read, markets, lenders, address(usdc)), "O1: hub balance != booked pots");
    }

    /// @dev O1 over two of one lender's markets.
    function _assertSolventOver(bytes32 a, bytes32 b, address lender) internal view {
        bytes32[] memory markets = new bytes32[](2);
        (markets[0], markets[1]) = (a, b);
        address[] memory lenders = new address[](1);
        lenders[0] = lender;
        assertEq(usdc.balanceOf(address(ace)), BookedQuote.total(ace, read, markets, lenders, address(usdc)), "O1: hub balance != booked pots");
    }
}
