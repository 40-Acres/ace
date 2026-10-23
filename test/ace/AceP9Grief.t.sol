// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBurnableERC20} from "../mocks/MockBurnableERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

interface IAceAuto {
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
}

interface IAceTry {
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
}

interface IAceClosed {
    function isClosed(uint256 id) external view returns (bool);
}

/// @notice A record that answers while its target loan is live and REFUSES once the hub closes it.
/// @dev The fold's predicate reads it through `tryPersistedPrice`, a raw staticcall that ABSORBS a refusal.
/// @dev `_closeForRefinance` writes `closedAt` inside the same call, so any later read gets the refusal instead.
/// @dev The sibling of the same shape through the GATE; a guarantee scoped to one dependency covers neither.
contract SelfSickeningRecord is IPersistenceRecord {
    IAceClosed public immutable ACE;
    address public immutable QUOTE;
    address public immutable COLLATERAL;
    uint256 public target; // 0 = answer unconditionally, which is what genesis and every entry verb saw

    constructor(address ace_, address quote_, address collateral_) {
        ACE = IAceClosed(ace_);
        QUOTE = quote_;
        COLLATERAL = collateral_;
    }

    function setTarget(uint256 id) external {
        target = id;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    /// @dev False, so `finalize` refuses with NotSettleable rather than with this record's own revert.
    function persistedBelowDistress(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function persistedBelowSettle(address, address, uint256) external pure returns (bool) {
        return false;
    }

    /// @dev NOT an interface member any more; kept public because the lens still probes it by signature.
    function persistedAbove(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function lastObserved(address, address) external view returns (uint256) {
        return AceFixtures.px(1e18, QUOTE, COLLATERAL);
    }

    function minPrice(address, address) external view returns (uint256) {
        require(target == 0 || !ACE.isClosed(target), "record sick");
        return AceFixtures.px(2e18, QUOTE, COLLATERAL);
    }

    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }
}

/// @title AceP9Grief
/// @notice Unit 9 (the griefer) proofs. Every test here is EXPECTED TO PASS; the G-numbers are measurements.
/// @notice G1: a RECORD that moves mid-fold cannot put a loan beyond every settlement verb; the fold reads it once.
/// @notice G1b/G1c: the borrower's disarm and a third party's repay, and what each one costs the party holding it.
/// @notice G2: one wei of custody shortfall bricks every collateral-moving verb on that TOKEN, in every market.
/// @notice G3: the sizing #235 asks for -- what the unbudgeted watermark retighten costs at the genesis spacing floor.
/// @dev Findings: docs/ai/audit/runs/2026-08-31-23b79e/phase9-griefer.md
contract AceP9GriefTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;

    MockERC20 internal usdc;
    MockERC20 internal coll;
    SelfSickeningRecord internal record;

    bytes32 internal mid;

    address internal alice = address(0xA11CE); // the lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5); // any third party running the crank

    // `TICK` and its `_price` helper are DELETED: this suite names no price since the draws moved onto the market's own.
    uint256 internal constant DEPOSIT = 5_000e6;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant COLL = 10_000e18;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        AceFixtures.Deployment memory d = AceFixtures.deploy(p); // record-less bootstrap, only to get the hub address
        (ace, pm, read) = (d.ace, d.positionManager, d.read);

        record = new SelfSickeningRecord(address(ace), address(usdc), address(coll));
        MarketParams memory q = ace.idToMarketParams(d.id);
        q.record = address(record);
        mid = ace.createMarket(q);
    }

    /* ============ G1: what the fold COMMITS to, the fold's body must be able to complete ============ */

    /// @notice The fold's predicate admits and the successor's draw takes that same answer rather than re-reading.
    /// @notice `finalize` is shut here by the record answering `persistedBelow == false`, so `forceClose` is the verb that must land.
    /// @dev A record whose next answer would refuse must not be able to reach a next answer inside the committed roll.
    function test_G1_RecordVaryingAcrossTheFold_TheFoldStillReachesATerminalState() public {
        uint256 loanId = _armedLoan();
        record.setTarget(loanId); // armed AFTER every entry verb, so genesis and the open saw an unconditional answer

        _warpTo(read.loan(loanId).expiry + 1);
        (bool ok,,) = IAceTry(address(ace)).tryContinue(loanId);
        assertTrue(ok, "fixture: the fold's predicate must admit, or the committed roll is never reached");

        bool settled;
        vm.startPrank(keeper);
        try ace.finalize(loanId) {
            settled = true;
        } catch (bytes memory err) {
            emit log_named_bytes("finalize   reverted with", err);
        }
        try ace.forceClose(loanId) {
            settled = true;
        } catch (bytes memory err) {
            emit log_named_bytes("forceClose reverted with", err);
        }
        vm.stopPrank();

        assertTrue(settled, "SETTLEMENT UNREACHABLE: the record moved mid-fold and no verb resolves the loan");
    }

    /// @notice The disarm is the BORROWER's alone, and it routes an armed loan to the settle branch.
    /// @notice A lender holding the adverse side of that loan cannot reach the policy at all.
    /// @dev The disarm reads no market config and calls nothing external, so no dependency can refuse it.
    function test_G1b_OnlyTheBorrowerMayDisarm_AndTheDisarmRoutesAnArmedLoanToSettle() public {
        uint256 loanId = _armedLoan();
        record.setTarget(loanId);
        _warpTo(read.loan(loanId).expiry + 1);

        // a lender cannot reach it: the policy is the borrower's alone
        vm.prank(alice);
        vm.expectRevert();
        IAceAuto(address(ace)).setAutoRefinance(loanId, 0, 0, 0);

        vm.prank(borrower);
        IAceAuto(address(ace)).setAutoRefinance(loanId, 0, 0, 0); // a pure storage write, on the borrower's own loan

        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "a disarmed policy routes the crank to the settle branch and it runs");
    }

    /// @notice A third party may close an armed, expired loan by repaying it, and this measures the price.
    /// @notice The price is the WHOLE outstanding debt, and the whole position goes back to the borrower.
    /// @dev `Borrower.repay` reads only `closedAt`, so anyone may pay it: the tree's only measurement of that price.
    function test_G1c_AThirdPartyRepayClosesAnArmedExpiredLoan_AndThePriceIsTheWholeDebt() public {
        uint256 loanId = _armedLoan();
        record.setTarget(loanId);
        _warpTo(read.loan(loanId).expiry + 1);

        uint256 debt = read.debtOf(loanId);
        usdc.mint(alice, debt);
        vm.startPrank(alice);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();

        assertTrue(ace.isClosed(loanId), "a full repay closes an armed loan the crank would otherwise have rolled");
        (uint256 unitsToBorrower,) = ace.owedOf(loanId, borrower);
        emit log_named_uint("price of the close, fronted by a lender  (USDC)", debt);
        emit log_named_uint("collateral handed to the borrower       (atoms)", unitsToBorrower);
        assertEq(unitsToBorrower, COLL, "the whole position goes back to the borrower: settlement's recovery is forgone");
    }

    /* ============ G2: the custody shortfall rail is TOKEN-wide, immediate, and donation-clearable ============ */

    /// @notice One wei of silent balance loss refuses EVERY collateral move on that token, in every market at once.
    /// @notice Nobody is paid at all: a fall past the surplus halts every pull and release, as PositionManager's header says.
    /// @dev Two markets, two creators' worth of separate config, ONE `custodiedOf` key: the token.
    function test_G2_OneWeiOfCustodyShortfallBricksEveryMarketOnThatCollateral() public {
        (Ace a, PositionManager p, MockBurnableERC20 c, bytes32 m1, bytes32 m2) = _twoMarketsOnOneBurnableCollateral();
        uint256 l1 = _openOn(a, p, c, m1);
        uint256 l2 = _openOn(a, p, c, m2);

        c.burn(address(p), 1); // one wei, from a pot holding two markets' collateral

        vm.prank(borrower);
        vm.expectRevert(PositionManager.CustodyUnderfunded.selector);
        a.withdrawCollateral(l1, 1e18, borrower);

        vm.prank(borrower);
        vm.expectRevert(PositionManager.CustodyUnderfunded.selector);
        a.withdrawCollateral(l2, 1e18, borrower); // the OTHER market, which did nothing

        // and the escape: any party, at a price equal to the shortfall, with a plain transfer
        c.mint(address(this), 1);
        c.transfer(address(p), 1);
        vm.prank(borrower);
        a.withdrawCollateral(l2, 1e18, borrower);
        assertEq(c.balanceOf(borrower), 1e18, "a one-wei donation heals the pot for every market on the token");
    }

    /* ============ G3: the unbudgeted watermark retighten -- NO LONGER REPRESENTABLE ============ */

    /// @notice BOTH G3 ROWS ARE GONE, and the grief they sized cannot be expressed any more.
    /// @notice They measured the worst honest WATERMARK RETIGHTEN: a griefer parks one minimum lot at the far
    /// @notice end of the usable band and holds it forever, so every later verb that empties the opposite end
    /// @notice pays a scan across the whole band to find the next active tick. G3 measured the downward
    /// @notice crossing, G3b the upward twin and the draw path that also pays it.
    /// @notice Neither was a defect claim: they were the numbers that decided whether a remedy was owed.
    /// @notice `loActive`, `hiActive` and `hasActive` are DELETED from `MarketState` with the tick coordinate.
    /// @notice A market holds cash at ONE price, so there is no band, no scan, and nowhere to park a lot that
    /// @notice any other verb would then have to walk past. The cost is not reduced, it is structurally absent.
    /// @dev `_drawGas` and `_lowestUsableTick` went with these two rows: they built the parked-lot shape alone.

    /* ================================= fixtures ================================= */

    function _armedLoan() internal returns (uint256 loanId) {
        usdc.mint(alice, DEPOSIT * 4);
        vm.startPrank(alice);
        usdc.approve(address(ace), type(uint256).max);
        ace.deposit(mid, DEPOSIT * 4);
        vm.stopPrank();

        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OFF);
        IAceAuto(address(ace)).setAutoRefinance(loanId, 7 days, 0, 0);
        vm.stopPrank();
    }

    /// @dev One hub, one burnable collateral, two markets that share it and nothing else that matters.
    function _twoMarketsOnOneBurnableCollateral() internal returns (Ace a, PositionManager p, MockBurnableERC20 c, bytes32 m1, bytes32 m2) {
        MockERC20 q = new MockERC20("Quote", "Q", 6);
        c = new MockBurnableERC20("Burnable", "BRN", 18);
        MarketParams memory pp = AceFixtures.marketParams(address(q), address(c));
        pp.record = address(new MockPersistenceRecord(address(q), address(c)));
        AceFixtures.Deployment memory d = AceFixtures.deploy(pp);
        (a, p, m1) = (d.ace, d.positionManager, d.id);

        /// @dev Its OWN record is the differentiator: two venues on one collateral, alike in every dial that prices a loan.
        MarketParams memory p2 = a.idToMarketParams(m1);
        p2.record = address(new MockPersistenceRecord(address(q), address(c)));
        m2 = a.createMarket(p2);

        uint256 t = AceFixtures.priceAt(address(q), address(c), 960); // this rig's OWN pair, so its own par
        q.mint(alice, DEPOSIT * 8);
        vm.startPrank(alice);
        q.approve(address(a), type(uint256).max);
        a.deposit(m1, DEPOSIT * 4);
        a.deposit(m2, DEPOSIT * 4);
        vm.stopPrank();
    }

    function _openOn(Ace a, PositionManager p, MockBurnableERC20 c, bytes32 m) internal returns (uint256 loanId) {
        c.mint(borrower, COLL);
        vm.startPrank(borrower);
        c.approve(address(p), COLL);
        loanId = a.open(m, COLL, PRINCIPAL, 0, borrower, OFF);
        vm.stopPrank();
    }
}
