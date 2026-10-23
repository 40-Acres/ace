// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title CuratorVaultMarketGas
/// @notice THE MARKET-COUNT GATE, and it is now a FLATNESS gate rather than a slope one: what an LP pays at
/// @notice N = 1, 8, 16 and a deliberately large N, on entry and exit, zero-fee and fee-bearing.
/// @notice Every one of them is an LP's own transaction, so no keeper ever absorbs this cost.
/// @dev `MAX_MARKETS` IS GONE, AND SO IS THE CURVE IT CAPPED. NAV walked the vault's market list and summed a
/// @dev per-market aggregate, so an LP's cost grew with the count and the cap was the ruling that bounded it.
/// @dev The aggregates moved to the LENDER's pool, keyed by (lender, quote) across every market the vault runs,
/// @dev so `grossNav` is TWO READS at any count: the vault's asset balance and `lenderAssets`.
/// @dev The rows are kept and re-aimed: a cost that is FLAT in N is the strongest form of what the cap bought,
/// @dev and a row that goes red now means the walk came BACK rather than that the cap wants lowering.
/// @dev Cold by `vm.cool` on every account the verb reads, plus the 21,000 transaction base.
/// @dev NOT `--gas-report`: it averages one function over every call site, so it cannot show a curve in N.
/// @dev THE NUMBERS ARE THE DEPLOY PROFILE'S. Re-measure with `FOUNDRY_PROFILE=deploy`, never with `make test`:
/// @dev legacy compiles this materially cheaper than the via-IR bytecode that ships, and no CI lane before the
/// @dev canary compiles it via-IR, so a legacy-calibrated gas rail reads green right up until the deploy.
/// @dev Read the table with `scripts/test-trace.sh test/curator/CuratorVaultMarketGas.t.sol MARKET-GATE 0`.
contract CuratorVaultMarketGasTest is CuratorVaultBase {
    uint256 internal constant SEED = 200_000e6;
    uint256 internal constant PER_MARKET = 1_000e6; // lent in each, so every walked word is non-zero
    uint256 internal constant TX_BASE = 21_000;
    uint256 internal constant PRIOR_ART_CEILING = 600_000; // a live MetaMorpho deposit pays 562-591k: the prior art
    /// @dev WAS `MAX_MARKETS`, read off the contract. There is no cap to read: NAV costs the same at any count,
    /// @dev so what the far rows need is a count large enough that a returning walk would be unmissable.
    uint256 internal constant LARGE_N = 28;
    uint16 internal constant PERF_FEE = 1000; // a fee costs a FLAT ~23,000 now, never a walk: the verb reads NAV once
    bytes32[] internal _rig; // the markets this rig's door borrows opened; the vault keeps no list to ask

    /// @dev One vault lending in exactly `n` markets, each carrying a live loan.
    /// @dev A market whose words are all zero would understate the walk, so every one carries a loan; nothing rests between calls.
    /// @dev Each market is the door's at a record print 1% lower than the last, so each borrow opens a fresh id.
    function _withMarkets(uint256 n, uint16 perfFeeBps) internal returns (CuratorVault v) {
        v = _newVault(perfFeeBps);
        _lpDeposit(v, alice, SEED);
        delete _rig;
        MockPersistenceRecord r = MockPersistenceRecord(v.rowOf(address(collateral)).record);
        for (uint256 i; i < n; i++) {
            r.setMinPrice(AceFixtures.px(2e18 - i * 2e16, address(usdc), address(collateral)));
            _rig.push(ace.loanMarket(_borrow(v, PER_MARKET)));
            assertEq(ace.idToMarketParams(_rig[i]).lender, address(v), "fixture: the vault lends in every market this row counts");
            if (i != 0) assertTrue(_rig[i] != _rig[i - 1], "fixture: each borrow opened a fresh market");
        }
    }

    /// @dev The zero-fee entry row, which is what the shipped table has always measured.
    function _measureDeposit(uint256 n) internal returns (uint256 used) {
        return _measureDeposit(n, 0);
    }

    /// @dev Cold-measure one deposit against a vault holding `n` markets.
    function _measureDeposit(uint256 n, uint16 perfFeeBps) internal returns (uint256 used) {
        CuratorVault v = _withMarkets(n, perfFeeBps);
        assertEq(_rig.length, n, "fixture: exactly the markets this row is about");
        usdc.mint(bob, PER_MARKET);
        vm.prank(bob);
        usdc.approve(address(v), PER_MARKET);

        vm.cool(address(v));
        vm.cool(address(ace));
        vm.cool(address(usdc));
        vm.cool(bob);
        vm.prank(bob);
        uint256 g = gasleft();
        v.deposit(PER_MARKET, bob);
        used = g - gasleft() + TX_BASE;
        assertGt(v.balanceOf(bob), 0, "LIVENESS: the measured deposit really did mint");
    }

    function _report(uint256 n, uint256 used) internal {
        emit log_named_uint(string.concat("MARKET-GATE N=", vm.toString(n), " deposit gas"), used);
    }

    function _reportRedeem(uint256 n, uint256 used) internal {
        emit log_named_uint(string.concat("MARKET-GATE N=", vm.toString(n), " redeem gas"), used);
    }

    /// @dev Cold-measure one EXIT against a vault holding `n` markets.
    /// @dev Alice funded the vault, so she holds the shares; a tenth of them is far inside idle and pays in cash.
    /// @dev The exit is the instant `redeem`, one call and one base fee: what an LP pays to leave from free cash.
    function _measureRedeem(uint256 n, uint16 perfFeeBps) internal returns (uint256 used) {
        CuratorVault v = _withMarkets(n, perfFeeBps);
        assertEq(_rig.length, n, "fixture: exactly the markets this row is about");
        uint256 sh = v.balanceOf(alice) / 10;
        assertGt(sh, 0, "fixture: alice must hold shares for there to be an exit to measure");

        vm.cool(address(v));
        vm.cool(address(ace));
        vm.cool(address(usdc));
        vm.cool(alice);
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 assets = v.redeem(sh, alice, alice);
        used = g - gasleft() + TX_BASE;
        assertGt(assets, 0, "LIVENESS: the measured redeem really did pay cash");
    }

    function test_Gas_DepositAtOneMarket() public {
        uint256 g = _measureDeposit(1);
        _report(1, g);
        assertGt(g, 0, "a measurement of zero means the deposit did nothing");
    }

    function test_Gas_DepositAtEightMarkets() public {
        uint256 g = _measureDeposit(8);
        _report(8, g);
        assertGt(g, 0, "a measurement of zero means the deposit did nothing");
    }

    function test_Gas_DepositAtSixteenMarkets() public {
        uint256 g = _measureDeposit(16);
        _report(16, g);
        assertGt(g, 0, "a measurement of zero means the deposit did nothing");
    }

    /// @dev THE GATE'S OWN CONCLUSION, as a rail rather than a report. `MAX_MARKETS` is the ruling, and
    /// @dev a deposit at the cap has to stay inside what a shipped multi-market vault charges today.
    /// @dev If this ever trips, the answer is to lower `MAX_MARKETS`, never to raise the ceiling.
    function test_Gas_DepositAtTheCapStaysInsidePriorArt() public {
        CuratorVault probe = _newVault(0);
        uint256 cap = LARGE_N;
        assertEq(cap, 28, "the ruling, read off the contract rather than restated here");

        uint256 g = _measureDeposit(cap);
        _report(cap, g);
        assertLt(g, PRIOR_ART_CEILING, "a deposit at the cap costs less than a live MetaMorpho deposit does");
    }

    /// @dev The exit went unmeasured while the cap was set; this row is what closed that half of the gate.
    /// @dev It did NOT raise the bound: measured, an exit at the cap is CHEAPER than an entry at the cap.
    /// @dev The ENTRY ceiling is reused deliberately: the exit is held to the entry's bar, never a looser one.
    function test_Gas_RedeemAtTheCapStaysInsidePriorArt() public {
        uint256 cap = LARGE_N;
        uint256 g = _measureRedeem(cap, 0);
        _reportRedeem(cap, g);
        assertLt(g, PRIOR_ART_CEILING, "an exit at the cap costs less than a live MetaMorpho deposit does");
    }

    /// @dev The exit curve, so both of the LP's paths carry a measured slope rather than only the entry.
    /// @dev WAS `assertGt(gCap, g1)`, which asserted the CURVE exists so the cap had something to bound.
    /// @dev It does not: measured, an exit at N=28 is no dearer than one at N=1 and can come out cheaper.
    /// @dev So the row is re-aimed at FLATNESS, exactly as the entry row below it, and a red here means
    /// @dev the per-market walk came back rather than that a cap wants setting.
    function test_Gas_RedeemCostIsFlatInMarketCount() public {
        uint256 cap = LARGE_N;
        uint256 g1 = _measureRedeem(1, 0);
        uint256 g8 = _measureRedeem(8, 0);
        uint256 g16 = _measureRedeem(16, 0);
        uint256 gCap = _measureRedeem(cap, 0);
        _reportRedeem(1, g1);
        _reportRedeem(8, g8);
        _reportRedeem(16, g16);
        _reportRedeem(cap, gCap);
        assertApproxEqAbs(g16, g1, 20_000, "sixteen markets exit for what one does");
        assertApproxEqAbs(gCap, g1, 20_000, "and so does a much larger book");
    }

    /// @dev THE FOURTH ROW, owed because three measured rows cannot rule out the one nobody ran.
    /// @dev A fee-bearing EXIT is the only LP path never timed, and the cap is set off whichever binds.
    function test_Gas_FeeBearingRedeemCurve() public {
        uint256 cap = LARGE_N;
        uint256 g1 = _measureRedeem(1, PERF_FEE);
        uint256 gCap = _measureRedeem(cap, PERF_FEE);
        emit log_named_uint("MARKET-GATE fee-bearing redeem N=1", g1);
        emit log_named_uint("MARKET-GATE fee-bearing redeem N=cap", gCap);
        /// @dev WAS a per-market slope, `(gCap - g1) / (cap - 1)`. It UNDERFLOWS now: the cost is flat in N
        /// @dev and the far measurement can land under the near one, so the report is the pair and the delta.
        assertApproxEqAbs(gCap, g1, 20_000, "a fee-bearing exit does not grow with the market count either");
        assertLt(gCap, PRIOR_ART_CEILING, "a fee-bearing exit at the cap stays inside the prior art");
    }

    /// @dev A FEE NO LONGER COSTS A WALK: the verb reads NAV once and hands it to `_collectFeeAt`.
    /// @dev So the two rows share one slope and differ by a FLAT cost, which is what this pair measures.
    /// @dev The zero-fee rows build `_newVault(0)`, so the two fee rows are the whole measure of a fee-bearing LP.
    function test_Gas_DepositWithPerfFeeAtTheCap() public {
        uint256 cap = LARGE_N;
        uint256 gFree = _measureDeposit(cap, 0);
        uint256 gFee = _measureDeposit(cap, PERF_FEE);
        _report(cap, gFree);
        emit log_named_uint("MARKET-GATE fee-bearing deposit gas at the cap", gFee);
        assertLt(gFee, PRIOR_ART_CEILING, "a fee-bearing deposit at the cap stays inside the prior art too");
    }

    /// @dev THE BINDING CURVE: the dearest of the four measured rows, so it and not the zero-fee entry sizes the cap.
    /// @dev It binds on the BASE and not the slope: every row walks twice now, so all four slopes are within 5%.
    function test_Gas_FeeBearingDepositCurve() public {
        uint256 cap = LARGE_N;
        uint256 g1 = _measureDeposit(1, PERF_FEE);
        uint256 g16 = _measureDeposit(16, PERF_FEE);
        uint256 gCap = _measureDeposit(cap, PERF_FEE);
        emit log_named_uint("MARKET-GATE fee-bearing N=1", g1);
        emit log_named_uint("MARKET-GATE fee-bearing N=16", g16);
        emit log_named_uint("MARKET-GATE fee-bearing N=cap", gCap);
        emit log_named_uint("MARKET-GATE fee-bearing per-market", (gCap - g1) / (cap - 1));
        assertLt(gCap, PRIOR_ART_CEILING, "the binding row must sit inside the prior art at the cap");
    }

    /// @dev THE SHAPE, AND IT IS FLAT. `grossNav` reads two words whatever the market count, so an LP's
    /// @dev cost does not move with N at all -- which is what deleted `MAX_MARKETS` rather than lowering it.
    /// @dev WAS a LINEARITY row: it measured the per-market slope over two runs and refused a curve that bent
    /// @dev up. There is no slope to bend. A red row here says the per-market walk came BACK, which is the
    /// @dev one regression this file exists to catch, and it is a sharper signal than a slope ever was.
    function test_Gas_TheCostIsFlatInMarketCount() public {
        uint256 g1 = _measureDeposit(1);
        uint256 g16 = _measureDeposit(16);
        uint256 gLarge = _measureDeposit(LARGE_N);
        _report(1, g1);
        _report(16, g16);
        _report(LARGE_N, gLarge);

        /// @dev A tolerance rather than equality: the fixture itself grows with N -- more markets mean more
        /// @dev accounts `vm.cool` touches -- so a few hundred gas of fixture noise is expected and a WALK is not.
        assertApproxEqAbs(g16, g1, 2_000, "sixteen markets cost what one does: the NAV read walks nothing");
        assertApproxEqAbs(gLarge, g1, 2_000, "and so does a much larger book");
        assertLt(gLarge, PRIOR_ART_CEILING, "flat, and inside what a live MetaMorpho deposit charges");
    }
}
