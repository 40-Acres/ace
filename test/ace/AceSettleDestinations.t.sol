// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {ProtocolPolicy} from "../../src/config/Defaults.sol";
import {MockBlockableStakeVault} from "../mocks/MockBlockableStakeVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceSettleDestinations
/// @notice No payout in the settlement path has a destination the payer chose for someone else.
/// @notice Every leg is CREDITED to its claimant, who names the address when they pull it.
/// @dev So `finalize` and `forceClose` complete whatever the collateral thinks of any address.
/// @dev They complete under a GLOBAL PAUSE too: `_settle` makes no external collateral call at all.
/// @dev The title holder can move the position to any address `retitle` admits; that must not become a weapon.
contract AceSettleDestinationsTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    PositionTitleNFT internal positions;
    MockERC20 internal usdc;
    MockBlockableStakeVault internal coll;
    MockPersistenceRecord internal record;
    bytes32 internal id;

    address internal alice = address(0xA11CE); // the lender whose cash funds the loan
    address internal borrower = address(0xB0B);
    address internal blockedHolder = address(0xB10C); // an address the collateral refuses to pay
    address internal keeper = address(0xCAFE);
    address internal otherKeeper = address(0xFEED);
    address internal rescuer = address(0x2E5C);
    address internal haven = address(0xDEAF); // an address the collateral accepts, named at claim time

    uint256 internal constant COLL = 10_000e18;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant UNIT_SCALE = 1 << 96; // every market's scale under the atom frame
    uint256 internal T2; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T3;
    uint256 internal T4;

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockBlockableStakeVault();
        (T2, T3, T4) = (_price(0), _price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(coll));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.price = T4; // WAS the ladder's top rung, which is the price every row here names
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id) = (d.ace, d.positionManager, d.read, d.id);
        positions = PositionTitleNFT(ace.POSITION_TITLE());

        _deposit(15_000e6); // WAS three rungs of 5_000; one market, one resting balance
    }

    // ---- helpers ----

    function _deposit(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(id, amt);
        vm.stopPrank();
    }

    function _openStd() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), COLL);
        loanId = ace.open(id, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    function _retitle(uint256 loanId, address from, address to) internal {
        vm.prank(from);
        positions.transferFrom(from, to, loanId);
    }

    function _claim(uint256 loanId, address who, address to) internal returns (uint256 units) {
        vm.prank(who);
        (units,) = ace.claimOwed(loanId, to);
    }

    /// @dev Units one claim needs at its own pre-committed tick price; mirrors `LoanAccounting.collateralNeeded`.
    function _need(uint256 claim, uint256 price) internal pure returns (uint256) {
        return (claim * UNIT_SCALE + price - 1) / price;
    }

    /// @dev The debt-based in-kind keeper sliver; mirrors `LoanAccounting.sliverUnits`.
    function _sliver(uint256 loanId) internal view returns (uint256) {
        uint256 floorPrice = read.fundingFloor(id, loanId);
        if (floorPrice == 0) return 0;
        return (read.loan(loanId).debt * ace.idToMarketParams(id).settleBountyBps * UNIT_SCALE) / (10000 * floorPrice);
    }

    // ============ the enabling fact: the residual branch is the ordinary outcome ============

    /// @notice `units > toMarket` on a perfectly ordinary settlement, so the residual leg is the common path.
    /// @dev The open gate demands `trigger <= floor`, so an admitted loan is over-covered by ~k at open.
    /// @dev The residual is CREDITED and the holder pulls it; the settlement itself moves no token.
    function test_Residual_IsTheOrdinaryOutcome_AndTheHolderPullsIt() public {
        uint256 loanId = _openStd();
        uint256 claim = read.claimOf(id, loanId);
        uint256 units = COLL - _sliver(loanId);
        uint256 need = _need(claim, T4);

        assertEq(claim, PRINCIPAL, "guard: the whole principal is one claim at T4");
        assertGt(units, need, "the residual branch is the ORDINARY case: units exceed what the market takes");

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the loan settles");
        assertEq(read.unitsOwedOf(loanId, borrower), units - need, "and the residual is credited to the title holder");
        assertEq(coll.balanceOf(borrower), 0, "nothing was pushed at settlement time");
        assertEq(_claim(loanId, borrower, borrower), units - need, "and the pull delivers it in kind, in full");
        assertEq(coll.balanceOf(borrower), units - need, "into the holder's own wallet");
        assertEq(read.claimOf(id, loanId), 0, "the claim is zeroed");
        assertGt(read.invPotOf(id, loanId), 0, "the class pot is filled");
    }

    /// @notice CONTROL: the credit follows the TITLE, so a retitle moves who may pull the residual.
    function test_Control_RetitlingMovesWhoMayPullTheResidual() public {
        uint256 loanId = _openStd();
        _retitle(loanId, borrower, blockedHolder);

        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "a retitled position settles normally");
        assertGt(read.unitsOwedOf(loanId, blockedHolder), 0, "the residual follows the title, as the record intends");
        assertEq(read.unitsOwedOf(loanId, borrower), 0, "and the original borrower is credited nothing");
    }

    // ============ the fix: no refused destination stops either terminal crank ============

    /// @notice `finalize` MUST complete: it is the lenders' only claim on a persistently distressed loan.
    function test_Finalize_MustNotRevertWhenTheTitleHolderIsAnAddressTheCollateralRefuses() public {
        uint256 loanId = _openStd();
        coll.setBlocked(blockedHolder, true);
        _retitle(loanId, borrower, blockedHolder); // the title moves freely: the NFT reads no token

        record.setBelow(true);
        assertTrue(read.settleable(loanId), "guard: the only precondition on finalize is satisfied");

        vm.prank(keeper);
        ace.finalize(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "settlement is the lenders' terminal right and must be total");
    }

    /// @notice `forceClose` MUST complete: it is the no-price backstop that bounds worst case at tenor.
    function test_ForceClose_MustNotRevertWhenTheTitleHolderIsAnAddressTheCollateralRefuses() public {
        uint256 loanId = _openStd();
        coll.setBlocked(blockedHolder, true);
        _retitle(loanId, borrower, blockedHolder);

        _warpBy(ProtocolPolicy.MIN_TENOR + 1);
        vm.prank(keeper);
        ace.forceClose(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "the must-execute backstop must execute");
    }

    /// @notice The whole point: every lender claim converts, and the blocked holder's own credit waits.
    /// @dev The strand this file was written to document is gone; what strands is only the griefer's equity.
    function test_BlockedHolder_SettlementCompletes_AndEveryLenderClaimConverts() public {
        uint256 loanId = _openStd();
        uint256 lentPre = read.poolLent(id);
        uint256 claimPre = read.claimOf(id, loanId);

        coll.setBlocked(blockedHolder, true);
        _retitle(loanId, borrower, blockedHolder);
        record.setBelow(true);

        vm.prank(keeper);
        ace.finalize(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "the loan closes");
        assertEq(read.claimOf(id, loanId), 0, "the claim is zeroed");
        assertGt(read.invPotOf(id, loanId), 0, "the class pot is filled");
        assertLt(read.poolLent(id), lentPre, "totalLent falls: the market no longer books it as lent");
        assertEq(coll.balanceOf(address(ace)), 0, "and the hub still never takes title to a single unit");

        vm.prank(alice);
        uint256 got = ace.redeemInKind(loanId, alice); // no mint first: the pot is the lender's outright
        assertGt(got, 0, "the funding lender redeems in kind out of the pot the settlement created");
        assertGt(claimPre, 0, "guard: the fixture funded a real claim");
    }

    /// @notice At the coverage gate the trade is asymmetric -- and it no longer matters, because it fails.
    /// @dev `minCoverageWad` defaults to 1.4e18, so the thinnest admissible loan leaves only ~0.4x need.
    /// @dev The arithmetic is retained: it is what made the finding a D0 rather than a curiosity.
    function test_Asymmetry_AtTheCoverageMinimum_NoLongerBuysTheGrieferAnything() public {
        uint256 need = _need(PRINCIPAL, T4);
        uint256 tight = (need * 141) / 100; // just inside the 1.4x gate

        coll.mint(borrower, tight);
        vm.startPrank(borrower);
        coll.approve(address(positionManager), tight);
        uint256 loanId = ace.open(id, tight, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();

        uint256 units = tight - _sliver(loanId);
        uint256 residual = units - need;
        uint256 residualAtFloor = (residual * read.fundingFloor(id, loanId)) / UNIT_SCALE;
        uint256 claim = read.claimOf(id, loanId);

        assertGt(units, need, "even the THINNEST admissible loan reaches the residual branch");
        assertGt(claim, residualAtFloor * 2, "the old asymmetry: lenders lost over twice what the griefer forfeited");

        coll.setBlocked(blockedHolder, true);
        _retitle(loanId, borrower, blockedHolder);
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);

        assertTrue(read.loan(loanId).closedAt != 0, "and the thin loan settles regardless");
        assertEq(read.claimOf(id, loanId), 0, "so the lenders lose nothing to the block");
    }

    /// @notice A blocked holder no longer denies a stranger's rescue: `closeClean` credits too.
    function test_BlockedHolder_DoesNotDenyAFullRepay() public {
        uint256 loanId = _openStd();
        coll.setBlocked(blockedHolder, true);
        _retitle(loanId, borrower, blockedHolder);

        uint256 debt = read.loan(loanId).debt;
        usdc.mint(rescuer, debt);
        vm.startPrank(rescuer);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();

        assertTrue(read.loan(loanId).closedAt != 0, "a funded rescue closes the loan");
        assertEq(read.claimOf(id, loanId), 0, "and the claim is retired at par");
        assertEq(read.unitsOwedOf(loanId, blockedHolder), COLL, "the whole position is credited to the holder");
        assertEq(read.unitsOwedOf(loanId, rescuer), 0, "and nothing to the payer");
    }

    // ============ the claim itself is unbrickable: the claimant names the destination ============

    /// @notice A blocked keeper settles, then pulls its sliver to an address the collateral accepts.
    function test_Sliver_IsCredited_SoABlockedKeeperStillSettlesAndPullsElsewhere() public {
        uint256 loanId = _openStd();
        coll.setBlocked(keeper, true);
        record.setBelow(true);

        vm.prank(keeper);
        ace.finalize(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "the blocked keeper's own crank now completes");

        uint256 sliver = read.unitsOwedOf(loanId, keeper);
        assertGt(sliver, 0, "and it is credited the sliver");

        vm.prank(keeper);
        vm.expectRevert(bytes("blocked"));
        ace.claimOwed(loanId, keeper); // pulling to itself is still refused, by the TOKEN

        assertEq(_claim(loanId, keeper, haven), sliver, "but the claimant names the destination, so the pull lands");
        assertEq(coll.balanceOf(haven), sliver, "in full, at an address the collateral accepts");
    }

    /// @notice A hub-refusing collateral settles cleanly: the hub takes no custody at all.
    function test_AHubBlockedCollateralSettlesCleanly() public {
        uint256 loanId = _openStd();
        coll.setBlocked(address(ace), true);
        record.setBelow(true);

        vm.prank(keeper);
        ace.finalize(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "the hub leg is gone, so blocking the hub stops nothing");
        assertGt(read.invPotOf(id, loanId), 0, "and the class pot still filled");
        assertEq(coll.balanceOf(address(ace)), 0, "with the hub holding not one unit");
    }

    /// @notice A GLOBAL pause no longer delays settlement either: `_settle` makes no external call.
    /// @dev This is the strongest form of the property, and it is what Ruling 2 buys.
    function test_APausedCollateralNoLongerStopsSettlement() public {
        uint256 loanId = _openStd();
        coll.setPaused(true);
        record.setBelow(true);

        vm.prank(keeper);
        ace.finalize(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "a paused collateral cannot suspend the lenders' terminal right");
        assertGt(read.unitsOwedOf(loanId, keeper), 0, "the keeper's bounty is credited, waiting for the pause to lift");

        coll.setPaused(false);
        assertGt(_claim(loanId, keeper, keeper), 0, "and pays out once it does");
    }

    /// @notice A stranger's claim pays zero and does not revert; only the credited claimant is paid.
    function test_ClaimOwed_PaysOnlyTheCreditedClaimant() public {
        uint256 loanId = _openStd();
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);

        assertEq(_claim(loanId, rescuer, rescuer), 0, "an uncredited caller pays zero, cleanly");
        assertEq(coll.balanceOf(rescuer), 0, "and takes nothing");
        assertGt(read.unitsOwedOf(loanId, borrower), 0, "while the holder's credit is untouched");
    }

    /// @notice A second claim pays zero: the entry is zeroed before the asset moves.
    function test_ClaimOwed_IsIdempotent() public {
        uint256 loanId = _openStd();
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);

        uint256 first = _claim(loanId, borrower, borrower);
        assertGt(first, 0, "the first pull delivers");
        assertEq(_claim(loanId, borrower, borrower), 0, "the second is an exact no-op");
        assertEq(coll.balanceOf(borrower), first, "and pays nothing twice");
    }

    /// @notice Nobody else can take an unclaimed credit, and there is deliberately no reaper.
    /// @dev A decade later, on an immutable hub with no admin, it is still the holder's.
    function test_UnclaimedCreditStrandsAndNobodyElseCanTakeIt() public {
        uint256 loanId = _openStd();
        coll.setBlocked(blockedHolder, true);
        _retitle(loanId, borrower, blockedHolder);
        record.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);

        uint256 owed = read.unitsOwedOf(loanId, blockedHolder);
        assertGt(owed, 0, "the griefer's own equity is what waits");

        uint256 keeperOwed = read.unitsOwedOf(loanId, keeper);
        _warpBy(3650 days);
        assertEq(_claim(loanId, rescuer, rescuer), 0, "no third party can sweep it");
        assertEq(_claim(loanId, keeper, keeper), keeperOwed, "the keeper pulls its OWN sliver and no more");
        assertEq(read.unitsOwedOf(loanId, blockedHolder), owed, "the holder's entry is bit-unchanged");
        assertEq(coll.balanceOf(rescuer), 0, "and nothing reached the would-be reaper");

        vm.prank(rescuer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, rescuer, loanId));
        positions.transferFrom(blockedHolder, rescuer, loanId);
    }

    /// @notice A ZERO credit is an exact no-op, so a recipient-keyed refusal has nothing to refuse.
    /// @dev The mock refuses on the RECIPIENT regardless of amount, which is why a zero-unit PUSH
    /// @dev would have reverted too. A credit of zero writes nothing and emits nothing.
    function test_ZeroCreditIsAnExactNoOp() public {
        uint256 loanId = _openStd();
        coll.setBlocked(borrower, true);
        coll.setBlocked(keeper, true);
        coll.setBlocked(blockedHolder, true);
        record.setBelow(true);

        vm.prank(keeper);
        ace.finalize(loanId);
        assertTrue(read.loan(loanId).closedAt != 0, "and BOTH credited parties being refused stops nothing");

        assertEq(_claim(loanId, rescuer, blockedHolder), 0, "a zero claim to a REFUSED address still does not revert");
    }

    // ============ the quote leg, and what the aggregate must not touch ============

    /// @notice A quote credit is lender-blind: `lenderAssets` is the number a share price is built on.
    /// @dev A `CuratorVault` sums it into NAV.
    /// @dev A borrower's unclaimed equity inside it would inflate the share price and pin the market.
    function test_LenderAssetsIsUnmovedByAQuoteCredit() public {
        uint256 loanId = _openStd();

        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt); // closes clean, so the unearned fee escrow is CREDITED
        vm.stopPrank();

        (, uint256 owedQuote) = ace.owedOf(loanId, borrower);
        assertGt(owedQuote, 0, "fixture: the close really did credit quote");
        assertEq(read.quoteOwedTotal(id), owedQuote, "the market aggregate carries it");

        /// @dev THE DISCRIMINATOR: if the aggregate were inside `lenderAssets`, the pull would drop it
        uint256 lenderSide = ace.lenderAssets(alice, address(usdc));
        _claim(loanId, borrower, borrower);
        assertEq(ace.lenderAssets(alice, address(usdc)), lenderSide, "a pull of borrower equity does not move the lender side");
        assertEq(read.quoteOwedTotal(id), 0, "while the aggregate clears exactly");
    }

    /// @notice The market aggregate is what the solvency identity reads, and it clears on the pull.
    function test_QuoteOwedTotal_RisesOnCreditAndClearsOnClaim() public {
        uint256 loanId = _openStd();
        assertEq(read.quoteOwedTotal(id), 0, "nothing owed at open");

        uint256 debt = read.loan(loanId).debt;
        usdc.mint(borrower, debt);
        vm.startPrank(borrower);
        usdc.approve(address(ace), debt);
        ace.repay(loanId, debt);
        vm.stopPrank();

        uint256 owed = read.quoteOwedTotal(id);
        assertGt(owed, 0, "the credit raises it");
        uint256 hubPre = usdc.balanceOf(address(ace));
        vm.prank(borrower);
        (, uint256 paid) = ace.claimOwed(loanId, borrower);
        assertEq(paid, owed, "the pull pays exactly the aggregate");
        assertEq(hubPre - usdc.balanceOf(address(ace)), owed, "balance and aggregate fall together");
        assertEq(read.quoteOwedTotal(id), 0, "and the aggregate clears");
    }
}
