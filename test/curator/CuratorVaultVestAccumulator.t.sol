// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault, Listing} from "../../src/curator/CuratorVault.sol";
import {VaultConfig} from "../../src/curator/AceVault.sol";
import {AceVaultFlows} from "../../src/curator/AceVaultFlows.sol";

/// @notice The vault with `_stampVest` exposed and its two fields readable, so credits land at chosen instants.
/// @dev Exposes the shipped internal UNCHANGED -- it substitutes no arithmetic and mocks nothing.
/// @dev Without it the instant of a stamp is whatever a hub event happens to fall on.
contract AccumVault is CuratorVault {
    constructor(VaultConfig memory cfg, Listing[] memory l) CuratorVault(cfg, 10e6, 1.4e18, 1 days, l, "Accum", "cACC") {}

    function stamp(uint256 amount) external {
        _stampVest(amount);
    }

    function burn(uint256 amount) external {
        _burnVest(amount);
    }

    /// @notice When the deferred pile finishes. The monotonicity property is stated directly on this.
    function maturity() external view returns (uint64) {
        return AceVaultFlows.layout().vestMaturity;
    }

    function basis() external view returns (uint128) {
        return AceVaultFlows.layout().vestBasis;
    }
}

/// @title CuratorVaultVestAccumulator
/// @notice The single weighted accumulator that replaced the three-rung ladder: two fields, one slot.
/// @notice TWO PROPERTIES CARRY THE WHOLE SHAPE, and between them they replace everything the roll pinned.
/// @notice ONE: the maturity only ever moves LATER, which is what stops a credit being TIMED to release early.
/// @notice TWO: a stamp adds its own credit and nothing else, so a quote and the verb that follows it agree.
/// @notice Grief resistance is the size weighting: a dust credit moves the maturity by dust, not by a window.
/// @dev Successor to `CuratorVaultLadderRoll.t.sol`, parked whole -- its subject was the epoch grid.
/// @dev the design record.
contract CuratorVaultVestAccumulatorTest is CuratorVaultBase {
    function setUp() public override {
        super.setUp();
        record.setMinPrice(T2);
    }

    function _accum(uint64 window) internal returns (AccumVault v) {
        VaultConfig memory cfg = _cfg(0);
        cfg.vestWindow = window;
        v = new AccumVault(cfg, _listing());
    }

    // ---- PROPERTY ONE: the maturity is monotone ----

    /// @dev THE ANTI-SANDWICH PROPERTY, stated on the field itself rather than inferred from a total.
    /// @dev A credit is a weighted average of the old maturity and `now + W`, and the old one is always
    /// @dev at or below `now + W`, so the average cannot fall below it. Timing a credit releases nothing.
    /// @dev MUTATION TARGET: change `m +=` to `m =` in `_stampVest` and this must fail.
    function test_Vest_TheMaturityOnlyEverMovesLater() public {
        AccumVault v = _accum(1 days);
        v.stamp(10_000e6);
        uint64 far = v.maturity();
        assertEq(far, uint64(_now()) + 1 days, "the first credit sets the full window");

        _warpBy(12 hours);
        v.stamp(1); // a dust credit whose own maturity is LATER, so the blend may only move up
        assertGe(v.maturity(), far, "a later credit never pulls the maturity in");

        _warpBy(11 hours);
        uint64 before = v.maturity();
        v.stamp(5_000e6); // a LARGE credit close to expiry: the case a reset-the-clock design gets wrong
        assertGe(v.maturity(), before, "and neither does a large one");
        assertLe(v.maturity(), uint64(_now()) + 1 days, "nor past a full window from now");
    }

    /// @dev The same law over arbitrary sequences, since the danger is a specific interleaving.
    function testFuzz_Vest_NoSequenceOfCreditsEverPullsTheMaturityIn(uint64 window, uint256 seed) public {
        uint64 win = uint64(bound(window, 1 hours, 7 days));
        AccumVault v = _accum(win);
        uint64 high;
        for (uint256 i; i < 8; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _warpBy((r % (2 * uint256(win))) + 1);
            uint64 before = v.maturity();
            v.stamp((r >> 128) % 1_000_000e6);
            assertGe(v.maturity(), before, "a stamp pulled the maturity IN, which is the sandwich in one step");
            assertLe(v.maturity(), uint64(_now()) + win, "and never deferred past a single window");
            if (v.maturity() > high) high = v.maturity();
        }
        assertGt(high, 0, "LIVENESS: nothing was ever deferred, so this run judged an empty accumulator");
        _warpTo(uint256(high) + 1);
        assertEq(v.unvested(), 0, "everything matures, and within ONE window of the last credit");
    }

    /// @dev WHY THE FLOOR IS WORTH HAVING: one block into the shortest admissible window, essentially the
    /// @dev whole pile is still deferred. A rail that merely refuses zero buys none of that, because a
    /// @dev one-second window matures inside one block and recognizes the gain to whoever just arrived.
    /// @dev THIS ROW IS NOT THE FLOOR'S GUARD, and reading it as one is the mistake to avoid. It stays
    /// @dev GREEN at any floor above about twenty minutes, so halving the constant sails past it. The
    /// @dev bracket row in `CuratorVaultVesting` rails the value exactly, in literals, and catches that.
    /// @dev What this row adds is the REASON the value is what it is, stated as an inequality a reader
    /// @dev can check, rather than as a comment beside a number nobody can evaluate.
    /// @dev NOT a round trip: it asserts an inequality over elapsed time, never re-deriving `_readVest`.
    function test_Vest_OneBlockAtTheFloorRecognizesAlmostNothing() public {
        uint64 floor = _accum(1 days).MIN_VEST_WINDOW();
        AccumVault v = _accum(floor);

        uint256 gain = 10_000e6;
        v.stamp(gain);
        assertGe(v.unvested(), gain, "the whole gain is deferred at the instant it is observed");

        _warpBy(12); // one mainnet block: the entire hold a sub-block window would have demanded
        assertGe(v.unvested() * 100, gain * 99, "a block buys an entrant under one percent of the gain");
    }

    // ---- PROPERTY TWO: a stamp adds its own credit and nothing else ----

    /// @dev What the quote-then-verb seam rests on: the pile after a stamp is the pile before plus the credit.
    /// @dev NOT an equality. `_stampVest` grosses with CEIL and `unvested()` reads back with CEIL, and two
    /// @dev ceils in series cannot cancel: the readback is `u + x` when `(u+x)*W` divides the span exactly
    /// @dev and `u + x + 1` otherwise, which is the ordinary case. Both directions favour the stayers.
    function test_Vest_AStampAddsItsOwnCreditAndAtMostOneWei() public {
        AccumVault v = _accum(1 days);
        v.stamp(7_777e6);
        _warpBy(7 hours);

        uint256 u = v.unvested();
        assertGt(u, 0, "LIVENESS: there is a live pile for the second credit to blend into");
        v.stamp(3_333e6);

        assertGe(v.unvested(), u + 3_333e6, "the credit landed in full: a stamp may never RELEASE");
        assertLe(v.unvested(), u + 3_333e6 + 1, "and added nothing beyond the one wei the two ceils cost");
    }

    /// @dev The bound over arbitrary piles and instants, because one wei is a claim about EVERY stamp.
    function testFuzz_Vest_TheStampBoundHoldsAtEveryPileAndInstant(uint64 window, uint256 seed) public {
        uint64 win = uint64(bound(window, 1 hours, 7 days));
        AccumVault v = _accum(win);
        uint256 credited;
        for (uint256 i; i < 8; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _warpBy((r % uint256(win)) + 1);
            uint256 x = (r >> 128) % 1_000_000e6;
            uint256 u = v.unvested();
            v.stamp(x);
            assertGe(v.unvested(), u + x, "a stamp released live value on the way in");
            assertLe(v.unvested(), u + x + 1, "a stamp added more than its own credit plus the ceil wei");
            credited += x;
        }
        assertGt(credited, 0, "LIVENESS: nothing was ever credited");
    }

    /// @dev The seam itself, end to end on the shipped verbs rather than the harness: a quote taken before
    /// @dev a sync must not be beaten by the fill after it, in the direction 4626 fixes.
    function test_Vest_AQuoteSurvivesTheStampTheVerbItselfRuns() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, 20_000e6);
        uint256 loanId = _open(6_000e6);
        _crank(v, loanId, T2, 0);
        _warpBy(30 days);
        _repay(loanId, lens.loan(loanId).debt); // an arrival nobody has synced

        uint256 promised = v.previewDeposit(1_000e6);
        uint256 minted = _lpDeposit(v, bob, 1_000e6);
        assertGe(minted, promised, "the deposit's own stamp never mints the entrant fewer shares than quoted");
        assertLe(v.convertToAssets(minted), 1_000e6, "and never hands them value out of the stayers");
    }

    // ---- grief resistance: the size weighting is the whole defence ----

    /// @dev THE TEST A NAIVE IMPLEMENTATION FAILS WHILE PASSING EVERYTHING ELSE. Reset-the-clock -- setting
    /// @dev the maturity to `now + W` on any credit -- satisfies monotonicity and adds the credit exactly,
    /// @dev and lets anybody re-defer the whole pile forever for one wei a block. The weighting is what
    /// @dev makes the move proportional: a dust credit against a large pile moves the maturity by dust.
    /// @dev MUTATION TARGET: in `_grossed`, replace the blended maturity with `end` and this must fail.
    function test_Vest_ADustCreditAgainstALargePileBarelyMovesTheMaturity() public {
        AccumVault v = _accum(1 days);
        v.stamp(1_000_000e6);
        _warpBy(23 hours); // one hour left to run
        uint64 before = v.maturity();
        uint256 left = uint256(before) - _now();

        for (uint256 i; i < 64; i++) {
            v.stamp(1); // sixty-four wei of griefing, one per iteration
        }

        uint256 moved = uint256(v.maturity()) - before;
        assertLt(moved, left, "sixty-four dust credits cannot buy even the hour that was already left");
        _warpTo(uint256(before) + 1 days);
        assertEq(v.unvested(), 0, "and the pile still clears, which a clock reset would have denied forever");
    }

    /// @dev The other half of proportional: a credit the SIZE of the pile really does move it materially.
    /// @dev Without this row the test above would pass a contract that ignored `_stampVest`'s blend entirely.
    function test_Vest_AMatchingCreditMovesTheMaturityMaterially() public {
        AccumVault v = _accum(1 days);
        v.stamp(1_000e6);
        _warpBy(23 hours);
        uint64 before = v.maturity();
        uint256 gap = uint256(_now()) + 1 days - before;

        v.stamp(1_000e6); // equal weight against a pile decayed to a sliver: nearly all the way out
        uint256 moved = uint256(v.maturity()) - before;
        assertGt(moved, gap / 2, "a credit that dwarfs the decayed pile carries the maturity most of the way");
    }

    // ---- the fall side keeps its behaviour on one field ----

    /// @dev `_burnVest` scales the basis and leaves the maturity alone, so a loss retires value without
    /// @dev moving WHEN the rest matures. A burn that moved the clock would be a release or a re-defer.
    function test_Vest_ABurnScalesThePileAndLeavesTheClockAlone() public {
        AccumVault v = _accum(1 days);
        v.stamp(10_000e6);
        _warpBy(6 hours);
        uint64 clock = v.maturity();
        uint256 u = v.unvested();

        v.burn(u / 4);
        assertEq(v.maturity(), clock, "the burn moved no clock");
        assertLt(v.unvested(), u, "but it really did retire deferred value");

        v.burn(type(uint128).max);
        assertEq(v.unvested(), 0, "a burn past the pile clears it rather than underflowing");
        assertEq(v.basis(), 0, "and it is the BASIS that goes to zero, which is what `unvested` short-circuits on");
    }
}
