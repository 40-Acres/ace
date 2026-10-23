// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Market, Storage} from "../../src/ace/hub/Types.sol";
import {LoanAccounting} from "../../src/ace/hub/libraries/LoanAccounting.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";

/// @notice Drives `LoanAccounting.creditLenderShare` against its OWN `Market`, with no hub and no market id.
/// @dev The library is reached DIRECTLY on purpose. A hub-driven route cannot open the close-side work:
/// @dev at these magnitudes the DRAW refuses first, so the row would be red at the deposit door, not here.
/// @dev THE CREDIT LANDS IN THE POOLED ROOT, not in this `Market`: `creditOverClaims` writes
/// @dev `Storage.poolOf(M.p).owed`, keyed by the market's own lender and quote. Both are zero on this
/// @dev bare struct, so the harness reads that same zero-keyed pool back rather than a member of `M`.
/// @dev That is not a workaround -- it is the shape under test: the aggregate left `MarketState`.
contract LoanAccountingHarness {
    Market internal M;

    /// @notice The loan's one claim, exactly as a draw leaves it.
    /// @dev IT SEEDED A LIST -- a claim keyed by tick, the tick pushed onto `claimTicks`, an index written
    /// @dev into `claimIndex`. All three are deleted: a loan holds one claim, so a seed is one assignment.
    /// @param loanId The loan the claim is keyed under.
    /// @param amount The claim it carries.
    function seedClaim(uint256 loanId, uint256 amount) external {
        M.claim[loanId] = amount;
    }

    /// @notice The lender-share entry, which is the line this file is about.
    /// @param loanId The loan whose claim is credited.
    /// @param lenderShare The quote to credit against it.
    function earn(uint256 loanId, uint256 lenderShare) external {
        LoanAccounting.creditLenderShare(M, loanId, lenderShare);
    }

    function unitOwed() external view returns (uint256) {
        return Storage.poolOf(M.p).owed;
    }

    function protocolRevenue() external view returns (uint256) {
        return M.s.protocolRevenue;
    }
}

/// @title AceCloseFeeProductOverflow
/// @notice THE PRODUCT IS GONE, and this file is what says so against the code rather than in a comment.
/// @notice `creditOverClaims` used to apportion `lenderShare` across a loan's funded ticks PRO RATA, and
/// @notice the apportionment was a plain 256-bit `lenderShare * cl` that panicked 0x11 at draw scale. Every
/// @notice closing verb reaches this line -- `repay`, `refinance` and settlement all arrive via the escrow
/// @notice earn -- so a panic there was not a refusal at a door, it was collateral locked behind a loan that
/// @notice had already opened. The widening to `FullMath` is what fixed it.
/// @notice ONE CLAIM MEANS NO APPORTIONMENT: the body is one `+=`, with no multiply left to overflow and no
/// @notice flooring residue to sweep. The rows below therefore assert TOTALITY at the extremes rather than
/// @notice a split, which is the whole of what the caller still depends on.
/// @dev The pro-rata equivalence fuzz went with the split: there is nothing to compare a plain form against.
contract AceCloseFeeProductOverflowTest is Test {
    uint256 internal constant CASH_CAP = type(uint128).max; // a market's most, per `Lender.creditCash`
    uint64 internal constant MIN_TENOR = 1 days;
    uint64 internal constant MAX_TENOR = 4 days;
    uint256 internal constant RAIL_BPS = 568; // worst rate a 4x multiple admits: feeFundable gives b <= 2500/(4*1.1) = 568.18, not a flat market's 2272

    LoanAccountingHarness internal h;

    function setUp() public {
        h = new LoanAccountingHarness();
    }

    /// @dev The refundable half of the lender fee on a draw of a whole cash cap, at the rail's worst rate.
    function _escrow() private pure returns (uint256) {
        uint256 fee = LoanMath.originationFee(CASH_CAP, MAX_TENOR, RAIL_BPS, MIN_TENOR);
        return LoanMath.escrowCut(fee);
    }

    /// @notice THE RATE THIS FILE'S CORNER RESTS ON, PROVED HERE rather than asserted in the comment beside it.
    /// @notice At a 4x term multiple the fee-share rail binds four times harder than it does on a flat market.
    /// @dev `b * M * 1.1 <= 2500` at M = 4 gives `b <= 568.18`, so 568 admits and 569 does not.
    /// @dev Spelled out because the next reader will otherwise reach for a flat market's 2272 and re-break it.
    function test_TheWorstRateThisShapeAdmitsIs568() public pure {
        assertTrue(LoanMath.feeFundable(RAIL_BPS, MAX_TENOR, MIN_TENOR), "568 clears the fee-share rail at a 4x term multiple");
        assertTrue(!LoanMath.feeFundable(RAIL_BPS + 1, MAX_TENOR, MIN_TENOR), "569 does not, so this really is the worst corner");
    }

    /// @notice THE CLOSE-SIDE REPRO, kept: the escrow earn survives the largest share a full market can carry.
    /// @dev The escrow is the ONLY thing that reaches this line, so its size is the whole reachable domain.
    function test_TheEscrowCreditSurvivesTheLargestLenderShareAFullMarketCanCarry() public {
        h.seedClaim(1, CASH_CAP);
        uint256 share = _escrow();

        h.earn(1, share);
        assertEq(h.unitOwed(), share, "the whole share is credited: there is no split to floor and no residue");
    }

    /// @notice The WHOLE lender cut is total too, which is what a phi of 10000 would escrow.
    /// @dev This fails on the arithmetic rather than on a constant, which is what a real rail should do.
    function test_TheWholeLenderCutIsAlsoTotal() public {
        h.seedClaim(1, CASH_CAP);
        uint256 fee = LoanMath.originationFee(CASH_CAP, MAX_TENOR, RAIL_BPS, MIN_TENOR);
        uint256 cut = LoanMath.lenderCut(fee);

        h.earn(1, cut);
        assertEq(h.unitOwed(), cut, "the whole lender cut reaches the pool, to the wei");
    }

    /// @notice NOTHING IS LOST AND NOTHING IS SWEPT: the credit is exact, so revenue takes no dust.
    /// @dev The old body floored per funded tick and swept the unplaceable remainder to `protocolRevenue`.
    /// @dev Both the floor and the sweep are gone, and this row is what would catch either coming back.
    function test_TheCreditIsExactAndRevenueTakesNothing() public {
        h.seedClaim(1, CASH_CAP);
        uint256 share = _escrow();

        h.earn(1, share);
        assertEq(h.unitOwed(), share, "the credit equals the share exactly");
        assertEq(h.protocolRevenue(), 0, "and revenue took no dust, because there is none to take");
    }

    /// @notice Totality across the whole admissible domain: any share against any live claim.
    /// @dev What the pro-rata equivalence fuzz used to do, re-aimed at the property that survived it.
    /// @param shareSeed The lender share to credit.
    /// @param claimSeed The loan's live claim.
    function testFuzz_TheCreditIsTotalAndExact(uint256 shareSeed, uint256 claimSeed) public {
        uint256 claim = bound(claimSeed, 1, CASH_CAP);
        uint256 share = bound(shareSeed, 0, type(uint128).max);
        h.seedClaim(7, claim);

        h.earn(7, share);
        assertEq(h.unitOwed(), share, "every wei of the share is credited, at every size the domain admits");
    }
}
