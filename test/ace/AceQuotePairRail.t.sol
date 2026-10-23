// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {QuoteMismatch} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {IAceRefinance, MigrateArgs} from "../utils/RebateHarness.sol";

/// @notice A contract title holder, because title IS borrower identity and only the borrower may migrate.
/// @dev It holds no route: a migration settles in one token, so there is nothing for a callback to swap.
contract TitleHolder {
    Ace internal immutable ACE;

    constructor(Ace ace) {
        ACE = ace;
    }

    function migrate(MigrateArgs calldata m) external returns (uint256) {
        (bool ok, bytes memory ret) = address(ACE).call(abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return abi.decode(ret, (uint256));
    }

    /// @notice The raw door, so a caller can assert on the refusal instead of inheriting it.
    function migrateRaw(MigrateArgs calldata m) external returns (bool, bytes memory) {
        return address(ACE).call(abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m));
    }

    /// @notice Repay the shortfall and migrate in ONE transaction; the verb itself never pulls.
    /// @dev `multicall` delegatecalls, so both legs see this holder as the loan's borrower.
    function migrateComposed(MigrateArgs calldata m, uint256 gap) external returns (uint256) {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Ace.repay, (m.id, gap));
        calls[1] = abi.encodeWithSelector(IAceRefinance.refinanceTo.selector, m);
        return abi.decode(ACE.multicall(calls)[1], (uint256));
    }

    /// @notice Fund and approve a top-up, which the composition's repay leg pulls from the caller with no callback.
    function armTopUp(address token, uint256 amount) external {
        MockERC20(token).mint(address(this), amount);
        IERC20(token).approve(address(ACE), amount);
    }
}

/// @title AceQuotePairRail
/// @notice `Borrower.migrate` refuses a destination quoting a DIFFERENT token, so one migration settles in one.
/// @notice The rail is on the token ADDRESS, never on its decimals: two 6-decimal tokens are two tokens.
/// @dev Four quote tokens at 9 / 6 / 6 / 18 decimals over ONE shared collateral vault, so the refusal is
/// @dev a statement about token identity rather than about one pair's decimal gap.
/// @dev The control migrates two markets that share a token, which is what gives the refusals teeth.
contract AceQuotePairRailTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    PositionTitleNFT internal title;
    MockStakeVault internal vault;
    TitleHolder internal holder;

    MockERC20 internal q9; // a 9-decimal quote
    MockERC20 internal q6; // the destination quote, 6 decimals
    MockERC20 internal e6; // a SECOND token at the destination's own decimals: the control gap of zero
    MockERC20 internal d18; // the canonical 18-decimal quote, against a 6-decimal destination

    bytes32 internal src9; // source market, 9-decimal quote
    bytes32 internal src6; // source market, 6-decimal quote
    bytes32 internal s18; // source market, 18-decimal quote
    bytes32 internal dst6; // destination market, 6-decimal quote
    bytes32 internal sib6; // a SIBLING market on the destination's token: other lenders, same balance

    address internal alice = address(0xA11CE);
    address internal borrower = address(0xB0B);

    uint64 internal constant TEN7 = 7 days;
    uint64 internal constant TEN30 = 30 days;
    uint64 internal constant SPACING = 23 days;

    uint256 internal constant COLL = 100_000e18;
    uint256 internal constant P9 = 70_000e9; // the old draw, in 9-decimal quote
    uint256 internal constant P6 = 70_000e6; // every 6-decimal draw, old or new
    uint256 internal constant P18 = 70_000e18; // the old draw, in 18-decimal quote
    uint256 internal constant CASH9 = 400_000e9;
    uint256 internal constant CASH6 = 400_000e6;
    uint256 internal constant CASH18 = 400_000e18;

    /// @dev fee(P,30d) = P*44*30/(10000*7) all-in; the protocol's 10% rides on top of the lender's 40.
    /// @dev The escrow is half of what is left once ACE's cut comes out, which is half the whole fee.
    /// @dev At t+15d of a 30d term exactly half the escrow is still unearned, and that half is `refundOld`.
    uint256 internal constant FEE6 = 1_320e6;
    uint256 internal constant ESCROW9 = 600e9;
    uint256 internal constant REFUND9 = 300e9;
    uint256 internal constant REFUND6 = 300e6;
    /// @dev What the netting leaves the caller to fund: the fresh fee less the refund it picks up.
    uint256 internal constant TOP_UP6 = FEE6 - REFUND6;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);
    uint256 internal t0;

    function setUp() public {
        _warpTo(1_000_000);
        t0 = _now();
        vault = new MockStakeVault(42);
        q9 = new MockERC20("Quote 9", "Q9", 9);
        q6 = new MockERC20("Destination Quote 6", "Q6", 6);
        e6 = new MockERC20("Other Quote 6", "E6", 6);
        d18 = new MockERC20("Quote 18", "D18", 18);

        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(q9, 1.4e18));
        (ace, pm, read, src9) = (d.ace, d.positionManager, d.read, d.id);
        dst6 = ace.createMarket(_params(q6, 1.2e18));
        sib6 = ace.createMarket(_params(q6, 1.3e18));
        src6 = ace.createMarket(_params(e6, 1.4e18));
        s18 = ace.createMarket(_params(d18, 1.4e18));
        title = PositionTitleNFT(ace.POSITION_TITLE());
        holder = new TitleHolder(ace);

        _deposit(src9, q9, CASH9);
        _deposit(src6, e6, CASH6);
        _deposit(s18, d18, CASH18);
        _deposit(dst6, q6, CASH6);
        _deposit(sib6, q6, CASH6);
    }

    // ---- fixture ----

    /// @dev One shape, five instantiations: the markets differ in quote and coverage, each on a record of its own.
    function _params(MockERC20 quote, uint256 k) internal returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(quote), address(vault));
        p.record = address(new MockPersistenceRecord(address(quote), address(vault)));
        p.minCoverageWad = k;
        p.minTenor = TEN7;
        p.maxTenor = TEN30;
    }

    /// @dev The QUOTE stays a parameter: this suite runs four quote tokens over one collateral, so the
    /// @dev token is what distinguishes the markets. It is the tick that went, not the pair.
    function _deposit(bytes32 mid, MockERC20 quote, uint256 amt) internal {
        quote.mint(alice, amt);
        vm.startPrank(alice);
        quote.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev Title IS borrower identity, so handing the token over makes the holder the borrower.
    function _openToHolder(bytes32 mid, uint256 principal) internal returns (uint256 id) {
        vault.mint(borrower, COLL);
        vm.startPrank(borrower);
        vault.approve(address(pm), COLL);
        id = ace.open(mid, COLL, principal, TEN30, borrower, OFF);
        title.transferFrom(borrower, address(holder), id);
        vm.stopPrank();
        assertEq(read.loan(id).borrower, address(holder), "fixture: retitle moved borrower identity");
    }

    function _args(uint256 oldId, bytes32 dst, uint256 principal) internal view returns (MigrateArgs memory) {
        return MigrateArgs(oldId, dst, principal, TEN30, OFF, 0, address(0));
    }

    /// @dev Asserts the migration failed with EXACTLY `sel`, then returns so the state asserts still run.
    function _refuses(uint256 oldId, bytes32 dst, uint256 principal, string memory why) internal {
        (bool ok, bytes memory ret) = holder.migrateRaw(_args(oldId, dst, principal));
        assertFalse(ok, why);
        assertEq(bytes32(bytes4(ret)), bytes32(QuoteMismatch.selector), why);
    }

    // ---- the identity ----

    /// @notice Every pot the hub books in ONE quote token, summed over every market that quotes in it.
    /// @notice `AceInvariants._bookedQuote` states this for one market and one token; a migration spans two.
    /// @dev Fee escrows are loan-keyed, so they are attributed by the loan's market, never by the market's id.
    /// @dev THE LENDER LEGS ARE READ ONCE PER POOL, not per market: the hub keys them by (lender, quote), so
    /// @dev markets sharing a lender share one bucket and a per-market sum would count it once for each.
    /// @dev Every market here is the fixture's, so one read covers them; a mixed-lender list needs a dedupe.
    function _booked(bytes32[] memory mids) internal view returns (uint256 booked) {
        (uint256 resting,, uint256 owed) = read.poolOf(mids[0]);
        booked = resting + owed;
        for (uint256 i; i < mids.length; i++) {
            MarketState memory s = read.marketState(mids[i]);
            booked += s.protocolRevenue + s.quoteOwedTotal;
        }
        uint256 n = read.loanCount();
        for (uint256 k = 1; k <= n; k++) {
            bytes32 m = read.loan(k).market;
            for (uint256 i; i < mids.length; i++) {
                if (m == mids[i]) booked += read.feeEscrowOf(k);
            }
        }
    }

    function _one(bytes32 a) internal pure returns (bytes32[] memory ms) {
        ms = new bytes32[](1);
        ms[0] = a;
    }

    function _two(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ms) {
        ms = new bytes32[](2);
        (ms[0], ms[1]) = (a, b);
    }

    function _q6Booked() internal view returns (uint256) {
        return _booked(_two(dst6, sib6));
    }

    // ============ controls: the fixture and the identity, proven before anything is claimed ============

    /// @notice The identity holds on every token before a migration runs, so a later break is the migration's.
    /// @dev Without this a failure below could be a mis-derived helper rather than a defect.
    function test_Control_EveryQuoteTokenReconcilesBeforeAnyMigration() public {
        uint256 oldId = _openToHolder(src9, P9);
        _warpTo(t0 + 15 days);

        assertEq(q9.decimals(), 9, "the 9-decimal quote is 9 decimals");
        assertEq(q6.decimals(), 6, "the destination quote is 6 decimals");
        assertEq(read.debtOf(oldId), P9, "the old debt is the source draw, in its own units");
        assertEq(read.feeEscrowOf(oldId), ESCROW9, "the withheld escrow is denominated in that same token");
        assertEq(read.earlyExitRefund(oldId), REFUND9, "and half of it is still unearned at t+15d");

        assertEq(q9.balanceOf(address(ace)), _booked(_one(src9)), "solvency: the 9-decimal token reconciles");
        assertEq(q6.balanceOf(address(ace)), _q6Booked(), "solvency: the destination token reconciles");
        assertEq(e6.balanceOf(address(ace)), _booked(_one(src6)), "solvency: the same-decimals token reconciles");
    }

    // ============ the rail: no pair of DIFFERENT tokens migrates, whatever their decimals ============

    /// @notice A 9-decimal source into a 6-decimal destination is refused BY NAME, before any state moves.
    /// @dev Both tokens still reconcile afterwards, the loan is still open, and its escrow is untouched.
    function test_QuotePair_A9DecimalSourceIntoA6DecimalDestinationIsRefusedByName() public {
        uint256 oldId = _openToHolder(src9, P9);
        _warpTo(t0 + 15 days);
        uint256 escrowBefore = read.feeEscrowOf(oldId);

        _refuses(oldId, dst6, P6, "a 9-decimal source may not migrate into a 6-decimal destination");

        assertEq(q9.balanceOf(address(ace)), _booked(_one(src9)), "solvency: the source token still reconciles");
        assertEq(q6.balanceOf(address(ace)), _q6Booked(), "solvency: the destination token still reconciles");
        assertFalse(read.loan(oldId).closedAt != 0, "the refused migration left the loan open");
        assertEq(read.debtOf(oldId), P9, "with its debt untouched");
        assertEq(read.feeEscrowOf(oldId), escrowBefore, "and its fee escrow neither earned nor refunded");
    }

    /// @notice THE DISCRIMINATING TEST: the refusal needs no decimal gap at all.
    /// @dev Two 6-decimal tokens are two tokens. A rail written against DECIMALS would let this through.
    function test_QuotePair_TheRefusalNeedsNoDecimalGap_TwoSixDecimalTokensAreStillTwoTokens() public {
        uint256 oldId = _openToHolder(src6, P6);
        _warpTo(t0 + 15 days);
        assertEq(e6.decimals(), q6.decimals(), "fixture: the two quotes share their decimals exactly");
        assertTrue(address(e6) != address(q6), "and are still different tokens");
        assertEq(read.earlyExitRefund(oldId), REFUND6, "fixture: a refund the netting would have picked up");

        _refuses(oldId, dst6, P6, "matching decimals do not make two tokens one");

        assertEq(e6.balanceOf(address(ace)), _booked(_one(src6)), "solvency: the source token still reconciles");
        assertEq(q6.balanceOf(address(ace)), _q6Booked(), "solvency: the destination token still reconciles");
        assertFalse(read.loan(oldId).closedAt != 0, "and the loan is exactly where it was");
    }

    /// @notice An 18-decimal source is refused the same way every other pair is: by name, not by arithmetic.
    /// @dev This pair is the one that would otherwise die inside a token transfer, so the NAME is the point.
    function test_QuotePair_An18DecimalSourceIsRefusedLikeEveryOtherPair() public {
        uint256 oldId = _openToHolder(s18, P18);
        _warpTo(t0 + 15 days);

        _refuses(oldId, dst6, P6, "the widest gap is refused by the same rail, not by an underflow");

        assertEq(d18.balanceOf(address(ace)), _booked(_one(s18)), "solvency: the source token still reconciles");
        assertEq(q6.balanceOf(address(ace)), _q6Booked(), "solvency: the destination token still reconciles");
        assertEq(read.debtOf(oldId), P18, "and the loan carries its whole debt still");
    }

    // ============ the control: the SAME token in two markets still migrates ============

    /// @notice THE CONTROL, and it is not optional: without it a revert-everything mutation passes the file.
    /// @dev Two markets on ONE token migrate, the shortfall is paid by the caller, books hold.
    /// @dev The shortfall rides the repay leg of the composition now; the verb itself refuses a short draw.
    function test_QuotePair_TheSameTokenInTwoMarketsStillMigrates_AndBothIdentitiesHold() public {
        uint256 oldId = _openToHolder(sib6, P6);
        _warpTo(t0 + 15 days);
        holder.armTopUp(address(q6), TOP_UP6);

        MarketParams memory p = ace.idToMarketParams(dst6);
        uint256 credit = P6 - LoanMath.originationFee(P6, TEN30, p.baseBps, p.minTenor) + read.earlyExitRefund(oldId);
        uint256 debtOld = read.loan(oldId).debt;
        uint256 newId = holder.migrateComposed(_args(oldId, dst6, P6), credit >= debtOld ? 0 : debtOld - credit);

        assertEq(read.loan(newId).market, dst6, "the fresh loan lives in the destination market");
        assertTrue(read.loan(oldId).closedAt != 0, "and the old one is retired");
        assertEq(q6.balanceOf(address(holder)), 0, "the shortfall was paid by the caller, exactly");
        assertEq(q6.balanceOf(address(ace)), _q6Booked(), "solvency: one token in, one token out, books intact");
    }
}
