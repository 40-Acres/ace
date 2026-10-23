// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {AceVault} from "../../src/curator/AceVault.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";

/// @title CuratorVaultWidths
/// @notice The two places `CuratorVault` does 256-bit arithmetic into a width it never checks.
/// @notice O1: `_grossed` SafeCasts the vest basis into `uint128`, and the revert shuts every verb AND every view.
/// @notice O15: the performance fee's `feeValue * s` is a plain product of a quote value and a share supply.
/// @notice BOTH END IN A VAULT NOBODY CAN UNWEDGE FROM INSIDE, which is why they are asserted as a freeze.
/// @notice Every row here is written against the behaviour the vault MUST have, so each was red before the fix.
/// @dev The quote runs at the widest decimals `MarketInit` admits, so the atom counts below are ones a real market could carry.
/// @dev REACHABILITY IS WEAKER SINCE `MAX_DECIMALS` NARROWED TO 18: `type(uint128).max` is ~3.4e20 tokens, not ~340.
/// @dev The width bugs are unchanged and these rows still pin them; what a wider quote bought was a cheaper way to reach them.
/// @dev Gross NAV is driven through `Ace.lenderAssets`, the same mocked seam `CuratorVaultSyncSeam` uses.
/// @dev Nothing about the vault is mocked or subclassed: every wei of arithmetic under assertion is the shipped code's.
/// @dev github 40-Acres/ace-internal#421.
contract CuratorVaultWidthsTest is CuratorVaultBase {
    uint256 internal constant CEIL = type(uint128).max; // the vest basis's whole range: ~340 tokens at 36 decimals
    uint256 internal constant HALF_CEIL = 1 << 127; // what half a window leaves standing of a basis at the ceiling
    uint256 internal constant STEP = 1e30; // a further gain of a millionth of a token, which is all the freeze needs
    uint256 internal constant SEED = 10e36; // ten tokens of LP cash, and it is this that the freeze traps
    uint256 internal constant FEE_SEED = 1e36; // one token: past the fee mint's 256-bit product, far under the basis width
    uint256 internal constant SMALL = 1e30; // an ordinary magnitude, orders under either bound
    uint256 internal constant HUGE = 2e59; // a NAV whose `a * 1e18` is 2e77 against a 1.16e77 word
    uint16 internal constant FEE_BPS = 2000;

    /// @dev The admitted ceiling. Every constant below is in ATOMS, so narrowing this changed no arithmetic.
    function _quoteDecimals() internal pure override returns (uint8) {
        return 18;
    }

    // ---- the rig ----

    /// @dev A vault whose hub read is mocked, so a row drives gross NAV to any figure.
    /// @dev `grossNav` reads the hub's `lenderAssets` for the asset with no market list, so the mock fires on every vault.
    /// @dev Mocks are CLEARED first, or a quote left standing would answer this build's own reads.
    function _mockedVault(uint16 feeBps) internal returns (CuratorVault v) {
        vm.clearMockedCalls();
        v = _deploy(_cfg(feeBps), "Width", "cWID");
    }

    /// @dev Point the hub read at a fixed answer; gross becomes idle plus this, at any magnitude.
    function _setHubQuote(uint256 q) internal {
        vm.mockCall(address(ace), abi.encodeWithSelector(Ace.lenderAssets.selector), abi.encode(q));
    }

    /// @dev A vault carrying the WIDEST basis the field can hold, half a window from maturity.
    /// @dev The basis is set by one real gain of exactly `type(uint128).max`, which the cast admits today.
    /// @dev From here any further gain at all grosses the pile past the width: `_grossed` returns 2x the pile.
    function _atTheVestCeiling() internal returns (CuratorVault v) {
        v = _mockedVault(0);
        _lpDeposit(v, alice, SEED);
        _setHubQuote(CEIL);
        v.collectFee(); // no fee at 0 bps, so this call is the `_sync` and nothing else
        _warpBy(VEST_W / 2);
    }

    /// @dev A vault whose performance fee is due on a doubling, at the NAV where the mint's product passes 256 bits.
    /// @dev One token in, one token of hub-side gain, recognized: `feeValue * s` is then 2e77 against a 1.16e77 word.
    function _atTheFeeMintsProduct() internal returns (CuratorVault v) {
        v = _mockedVault(FEE_BPS);
        _lpDeposit(v, alice, FEE_SEED);
        v.collectFee(); // at NAV, a no-op: the first deposit stamped the high-water at its cash
        _setHubQuote(FEE_SEED); // the hub position doubles gross NAV
        v.collectFee(); // defers the whole rise, so this pass is still under the mark
        _warpBy(VEST_W); // and now it is recognized, which is what makes the fee due
    }

    /// @dev The fee shares a collection owes, computed with `Math.mulDiv` -- the form the file already uses elsewhere.
    /// @dev INDEPENDENT of the expression under test: it is the fixed arithmetic, not a mirror of the broken one.
    /// @param bps The vault's own performance fee, which is immutable and not readable off the ABI.
    function _feeSharesOracle(CuratorVault v, uint256 bps) internal view returns (uint256) {
        uint256 s = v.totalSupply();
        uint256 h = v.feeHighWater();
        uint256 a = v.totalAssets();
        if (s == 0 || bps == 0 || a <= h) return 0;
        uint256 feeValue = Math.mulDiv(a - h, bps, 10000, Math.Rounding.Floor);
        return Math.mulDiv(feeValue, s, a - feeValue, Math.Rounding.Floor);
    }

    // ---- O1: the uint128 vest basis, RED until `_grossed` saturates ----

    /// @dev THE LP-FACING HALF OF THE FREEZE: nobody can even price what they hold.
    /// @dev `totalAssets()` reaches `_pendingUnvested`, which replays `_grossed` and reverts with it.
    /// @dev WAS RED before the fix, with `SafeCastOverflowedUintDowncast(128, ...)`.
    function test_Width_O1_NavStillReadsPastTheVestBasisWidth() public {
        CuratorVault v = _atTheVestCeiling();
        _setHubQuote(CEIL + STEP);

        assertGt(v.totalAssets(), 0, "NAV is unreadable, so an LP cannot price the shares they hold");
        assertEq(usdc.balanceOf(address(v)), SEED, "and the cash they are owed is sitting in the vault the whole time");
    }

    /// @dev The 4626 quote and limit surface goes down with `totalAssets`, so an integrator sees a dead vault.
    /// @dev WAS RED before the fix, on the same cast.
    function test_Width_O1_TheQuoteSurfaceStillReadsPastTheVestBasisWidth() public {
        CuratorVault v = _atTheVestCeiling();
        _setHubQuote(CEIL + STEP);

        assertGt(v.convertToAssets(v.balanceOf(alice)), 0, "the redeem quote is shut");
        uint256 heldA = v.balanceOf(alice); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(alice);
        v.requestExit(heldA); // the claim limit reads a request, so there has to be one
        assertGt(v.maxClaim(alice), 0, "and so is the limit an LP would size an exit against");
    }

    /// @dev THE FINDING ITSELF: the exit is shut, and no verb can lower NAV back under the bound.
    /// @dev The fraction sits inside the pro-rata idle rail, so only the width bug can stop this redemption.
    /// @dev WAS RED before the fix: `redeem` reverted in its own first line, `_sync`.
    function test_Width_O1_AnLpCanStillExitPastTheVestBasisWidth() public {
        CuratorVault v = _atTheVestCeiling();
        _setHubQuote(CEIL + STEP);
        uint256 before = usdc.balanceOf(alice);
        uint256 sh = v.balanceOf(alice) / 32; // read BEFORE the prank, which the next call consumes

        uint256 paid = _requestAndClaim(v, alice, sh); // a request, then the claim

        assertGt(paid, 0, "the LPs' exit is shut and the vault is frozen with their cash inside it");
        assertEq(usdc.balanceOf(alice) - before, paid, "and the cash really moved");
    }

    /// @dev Entry is shut too, which is what makes the freeze total rather than a stuck exit.
    /// @dev WAS RED before the fix.
    /// @dev A pile this size is one the entry gate refuses while it vests, so the row asserts THAT refusal: the gate's own error.
    /// @dev Not a panic and not the width revert, so the verb got through `_sync` to the gate; the exit and crank rows pin the rest.
    function test_Width_O1_EntryIsNotBrickedPastTheVestBasisWidth() public {
        CuratorVault v = _atTheVestCeiling();
        _setHubQuote(CEIL + STEP);

        assertEq(v.maxDeposit(bob), 0, "the view advertised an entry while a ceiling-sized pile vests");
        usdc.mint(bob, SMALL);
        vm.startPrank(bob);
        usdc.approve(address(v), SMALL);
        vm.expectRevert(AceVault.GainVesting.selector);
        v.deposit(SMALL, bob);
        vm.stopPrank();
    }

    /// @dev The permissionless crank is the one verb a stranger could use to unwedge the vault, and it reverts first.
    /// @dev The crank is the minimal probe: it does little but `_sync`, the hub's collect and `_collectFeeAt`.
    /// @dev WAS RED before the fix, which is what closed the last door.
    function test_Width_O1_ThePermissionlessCrankIsNotBrickedPastTheVestBasisWidth() public {
        CuratorVault v = _atTheVestCeiling();
        _setHubQuote(CEIL + STEP);

        v.crank();
        assertEq(v.grossNav(), SEED + CEIL + STEP, "the crank cannot run, so nothing can ever move NAV back under the bound");
    }

    /// @dev THE SHAPE OF THE FIX, pinned so saturation cannot quietly become a release.
    /// @dev A saturated basis defers LESS than the honest figure, and the shortfall is exactly the gain that would not fit.
    /// @dev That direction pays whoever exits and dilutes whoever stays, which is bounded and survivable; the freeze is not.
    /// @dev WAS RED before the fix, because reading `totalAssets()` at all was what reverted.
    function test_Width_O1_SaturationUnderDefersByAtMostTheGainThatWouldNotFit() public {
        CuratorVault v = _atTheVestCeiling();
        uint256 standing = v.unvested();
        assertEq(standing, HALF_CEIL, "PREMISE: half a window leaves half the ceiling standing");
        _setHubQuote(CEIL + STEP);

        uint256 deferred = v.grossNav() - v.totalAssets();
        assertGe(deferred, standing, "saturation RELEASED value that was already deferred, which the exit would take");
        assertLe(deferred, standing + STEP, "and it deferred more than the honest figure, which the stayers would take");
    }

    /// @dev GREEN BOTH WAYS: the whole width stays usable, so the fix may not start saturating below the ceiling.
    /// @dev A gain of exactly `type(uint128).max` is the widest legal basis and must read back to the wei.
    function test_Width_O1_ABasisAtExactlyTheCeilingIsStoredExactly() public {
        CuratorVault v = _mockedVault(0);
        _lpDeposit(v, alice, SEED);
        _setHubQuote(CEIL);
        v.collectFee();

        assertEq(v.unvested(), CEIL, "a gain of exactly the ceiling defers exactly, with nothing lost to a narrowing");
        _warpBy(VEST_W / 2);
        assertEq(v.unvested(), HALF_CEIL, "and half a window later exactly half of it still stands");
        assertEq(v.totalAssets(), SEED + CEIL - HALF_CEIL, "which is the NAV the vault recognizes at that instant");
    }

    /// @dev GREEN BOTH WAYS, over the whole admitted range: under the ceiling nothing saturates and the credit is exact.
    /// @dev This is the row that would catch a fix that clamped early or lost a wei on the ordinary path.
    function testFuzz_Width_O1_AGainUnderTheCeilingDefersExactly(uint256 gain) public {
        uint256 x = bound(gain, 1, CEIL);
        CuratorVault v = _mockedVault(0);
        _lpDeposit(v, alice, SEED);
        _setHubQuote(x);

        v.collectFee();

        assertEq(v.unvested(), x, "a gain at or under the basis width defers exactly, with no saturation");
        assertEq(v.totalAssets(), SEED, "so the recognized NAV is exactly what it was before the gain arrived");
    }

    // ---- O15: the fee mint's plain product, RED until both products are `Math.mulDiv` ----

    /// @dev THE FINDING: `feeValue * s` is a quote value times a share supply, and it passes 256 bits at 2e36 of NAV.
    /// @dev The quotient is perfectly representable, which is the whole reason `Math.mulDiv` exists.
    /// @dev WAS RED before the fix, with an arithmetic panic (0x11).
    function test_Width_O15_TheFeeMintSurvivesItsOwnProduct() public {
        CuratorVault v = _atTheFeeMintsProduct();
        uint256 want = _feeSharesOracle(v, FEE_BPS);
        assertGt(want, 0, "PREMISE: a fee is genuinely due, so the mint is really reached");
        uint256 held = v.balanceOf(curator);

        v.collectFee();

        assertEq(v.balanceOf(curator) - held, want, "the fee mint is the mulDiv figure and it overflowed nothing");
    }

    /// @dev `_pendingFeeShares` carries the identical shape, so the entry quote panics with the mint.
    /// @dev WAS RED before the fix.
    function test_Width_O15_TheFeeQuoteSurvivesTheSameProduct() public {
        CuratorVault v = _atTheFeeMintsProduct();
        uint256 want = _feeSharesOracle(v, FEE_BPS);

        assertEq(v.pendingFeeShares(), want, "the pending-fee view is shut");
        assertGt(v.previewDeposit(SMALL), 0, "and the entry quote every integrator calls first is shut with it");
    }

    /// @dev The exit again, against the other product: every state-changing verb collects the fee before it prices.
    /// @dev WAS RED before the fix.
    function test_Width_O15_AnLpCanStillExitPastTheFeeMintsProduct() public {
        CuratorVault v = _atTheFeeMintsProduct();
        uint256 before = usdc.balanceOf(alice);
        uint256 sh = v.balanceOf(alice) / 4; // read BEFORE the prank, which the next call consumes

        uint256 paid = _requestAndClaim(v, alice, sh); // a request, then the claim

        assertGt(paid, 0, "the LPs' exit is shut by the fee mint's own arithmetic");
        assertEq(usdc.balanceOf(alice) - before, paid, "and the cash really moved");
    }

    /// @dev Entry too, for the same reason and on the same pass.
    /// @dev WAS RED before the fix.
    function test_Width_O15_EntryIsNotBrickedPastTheFeeMintsProduct() public {
        CuratorVault v = _atTheFeeMintsProduct();

        assertGt(_lpDeposit(v, bob, SMALL), 0, "a fresh deposit cannot even be taken");
    }

    /// @dev GREEN BOTH WAYS, and it is what makes O15 nastier than O1 rather than milder.
    /// @dev NAV and the limit surface carry no fee term, so they keep answering while every verb panics.
    /// @dev An LP therefore reads a healthy vault and a positive withdrawable, and can act on neither.
    function test_Width_O15_NavAndTheLimitSurfaceReadWithoutTheFeeTerm() public {
        CuratorVault v = _atTheFeeMintsProduct();

        assertEq(v.unvested(), 0, "PREMISE: the rise is fully recognized, so the fee is struck against the whole of it");
        assertEq(v.totalAssets(), v.grossNav(), "NAV reads, because the fee is not one of its terms");
        uint256 heldA = v.balanceOf(alice); // BEFORE the prank: a read is a call, and a call would eat it
        vm.prank(alice);
        v.requestExit(heldA); // the claim limit reads a request, so there has to be one
        assertGt(v.maxClaim(alice), 0, "and so does the claimable the LP would act on");
    }

    // ---- O15 continued: a NAV past the word size, where a per-share rate's `a * 1e18` once overflowed ----

    /// @dev The high-water is in assets, so no fee read scales NAV by 1e18 any more: the collection holds by construction.
    /// @dev NAV is carried past the bound by a PRO-RATA DEPOSIT, which is the only way there is.
    /// @dev A hub-side gain that large cannot reach it: the vest basis is a `uint128`, so O1 reverts first.
    /// @dev WAS RED against the per-share rate, with an arithmetic panic (0x11).
    function test_Width_O15_TheCollectionSurvivesANavPastTheWordSize() public {
        CuratorVault v = _mockedVault(FEE_BPS);
        _lpDeposit(v, alice, SMALL);
        v.collectFee();
        uint256 base = v.feeHighWater();
        assertGt(base, 0, "PREMISE: a mark stands, so NAV below is genuinely compared against one");
        _lpDeposit(v, bob, HUGE); // pro rata, so it carries NAV over the bound with no growth

        v.collectFee();

        assertEq(v.feeHighWater(), base + HUGE, "the high-water did not take the entry's cash, or the collection moved it");
    }

    /// @dev The first deposit stamps the high-water at its cash, and a collection at NAV leaves it there, however large.
    /// @dev WAS RED against the per-share stamp `(a * 1e18) / totalSupply()`, the same product.
    function test_Width_O15_TheHighWaterStampSurvivesANavPastTheWordSize() public {
        CuratorVault v = _mockedVault(FEE_BPS);
        _lpDeposit(v, alice, HUGE);
        assertEq(v.totalAssets(), HUGE, "PREMISE: NAV really is past the bound, with nothing deferred");
        assertEq(v.feeHighWater(), HUGE, "the first deposit did not stamp the high-water at its cash");

        v.collectFee();

        assertEq(v.feeHighWater(), HUGE, "the high-water mark moved at a collection with no growth");
    }

    /// @dev The freeze again, at the third product: the first fee touch after the deposit is the exit's own.
    /// @dev WAS RED before the fix.
    function test_Width_O15_AnLpCanStillExitPastTheRateProductsBound() public {
        CuratorVault v = _mockedVault(FEE_BPS);
        _lpDeposit(v, alice, HUGE);
        uint256 before = usdc.balanceOf(alice);
        uint256 sh = v.balanceOf(alice) / 4; // read BEFORE the prank, which the next call consumes

        uint256 paid = _requestAndClaim(v, alice, sh); // a request, then the claim

        assertGt(paid, 0, "the LPs' exit is shut by the rate's own product");
        assertEq(usdc.balanceOf(alice) - before, paid, "and the cash really moved");
    }

    /// @dev GREEN BOTH WAYS: at an ordinary magnitude the mint must be BIT-IDENTICAL to the mulDiv form.
    /// @dev A silent rounding change in a fee mint would be worse than the overflow it was fixing.
    function test_Width_O15_FeeSharesAreTheMulDivFigureAtTheRigsOwnScale() public {
        CuratorVault v = _mockedVault(FEE_BPS);
        _lpDeposit(v, alice, SMALL);
        v.collectFee();
        _setHubQuote(SMALL);
        v.collectFee();
        _warpBy(VEST_W);

        uint256 want = _feeSharesOracle(v, FEE_BPS);
        assertGt(want, 0, "LIVENESS: a fee is genuinely due at this scale");
        uint256 held = v.balanceOf(curator);
        assertEq(v.pendingFeeShares(), want, "the view already agrees with the mulDiv form");
        v.collectFee();
        assertEq(v.balanceOf(curator) - held, want, "and so does the mint, to the wei");
    }

    /// @dev The same equivalence over the range the current expression handles, since the claim is about EVERY input.
    /// @dev The bounds keep the plain products inside 256 bits, which is exactly where the two forms must agree.
    /// @dev GREEN BOTH WAYS.
    function testFuzz_Width_O15_FeeSharesAreTheMulDivFigureAtOrdinaryMagnitudes(uint256 seed, uint256 bps, uint256 gain) public {
        uint256 d = bound(seed, 1e18, 1e34);
        uint16 f = uint16(bound(bps, 100, 5000));
        uint256 g = bound(gain, d / 10, 10 * d);
        CuratorVault v = _mockedVault(f);
        _lpDeposit(v, alice, d);
        v.collectFee();
        _setHubQuote(g);
        v.collectFee();
        _warpBy(VEST_W);

        uint256 want = _feeSharesOracle(v, f);
        assertGt(want, 0, "LIVENESS: this draw struck no fee at all, so it judged nothing");
        uint256 held = v.balanceOf(curator);
        v.collectFee();
        assertEq(v.balanceOf(curator) - held, want, "the fee mint moved off the mulDiv figure at an ordinary magnitude");
    }
}
