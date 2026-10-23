// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title CuratorVaultUncappedMarkets
/// @notice THE PROPERTY #557 EXISTS FOR: a vault's market count is bounded by nothing the vault holds.
/// @notice `MAX_MARKETS` existed to bound `grossNav`'s walk. Pooling the three lender aggregates per
/// @notice (lender, quote) makes NAV three reads, so there is no walk left for a cap to bound.
/// @dev WRITTEN FAILING-FIRST. Today `createMarket` reverts `TooManyMarkets` past 28 and `grossNav`
/// @dev walks `_markets`, so every row here is red until the pooled root lands.
/// @dev THE COMPARATOR THIS MOVES AWAY FROM, recorded because the direction matters: MetaMorpho walks
/// @dev its `withdrawQueue` capped at 30, and it walks because Morpho Blue keys positions per
/// @dev (market, user) -- multi-lender markets leave no key under which a lender's total exists.
/// @dev Sole tenancy removed that constraint; Fluid's liquidity layer ships the pooled shape already.
/// @dev Plan and lending review: issue #557.
contract CuratorVaultUncappedMarketsTest is CuratorVaultBase {
    uint256 internal constant SEED = 200_000e6;
    uint256 internal constant PER_MARKET = 1_000e6;

    /// @dev Past the retired cap of 28, so a surviving bound of any size fails here rather than passing.
    uint256 internal constant MANY = 40;

    /// @dev One door market per record print: the door prices at the row's buffered minimum, so a print 1% lower per step is a fresh price and id.
    /// @dev `minDebt` is the vault's immutable now, so the print is the differentiator; each market carries a loan, since nothing rests.
    function _marketAt(CuratorVault v, uint256 i) internal returns (bytes32) {
        MockPersistenceRecord r = MockPersistenceRecord(v.rowOf(address(collateral)).record);
        r.setMinPrice(AceFixtures.px(2e18 - i * 2e16, address(usdc), address(collateral)));
        return ace.loanMarket(_borrow(v, PER_MARKET));
    }

    /// @dev `MANY` distinct markets on one vault, none of them the rig's default.
    function _manyMarkets(CuratorVault v) internal {
        bytes32 last = mid;
        for (uint256 i = 1; i <= MANY; i++) {
            bytes32 m = _marketAt(v, i);
            assertTrue(m != last, "PREMISE: each step opened a fresh market");
            last = m;
        }
    }

    /// @notice A vault takes MORE markets than the retired cap allowed, and still prices itself.
    function test_MarketCount_IsNotCapped() public {
        CuratorVault v = _newVault(0); // ships with the rig's own door market already created
        _lpDeposit(v, alice, SEED);

        _manyMarkets(v);

        assertGt(v.grossNav(), 0, "the vault still prices itself past the retired cap");
        assertEq(v.grossNav(), _hubTruthNav(v), "and its NAV still agrees with the hub, at any count");
    }

    /// @notice NAV IS O(1): its gas does not grow with the market count, which is the whole claim.
    /// @dev A LINEAR walk over 41 markets is ~41x one market's read, so the bound below is enormous
    /// @dev slack against the walk and still far under it -- this cannot pass on a surviving loop.
    function test_GrossNav_CostDoesNotGrowWithMarketCount() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);

        uint256 g0 = gasleft();
        v.grossNav();
        uint256 oneMarket = g0 - gasleft();

        _manyMarkets(v);

        uint256 g1 = gasleft();
        v.grossNav();
        uint256 manyMarkets = g1 - gasleft();

        emit log_named_uint("grossNav, 1 market  ", oneMarket);
        emit log_named_uint("grossNav, 41 markets", manyMarkets);
        assertLt(manyMarkets, oneMarket * 2, "the NAV read grew with the market count: the walk is still there");
    }

    /// @notice Two markets of ONE vault sum into ONE position: the pooled key is (lender, quote).
    /// @dev Both markets quote the vault's asset, so both land in the same slot. That summing IS the
    /// @dev mechanism, so it is asserted rather than assumed.
    function test_TwoMarketsOfOneVaultSumIntoOnePosition() public {
        CuratorVault v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        _open(PER_MARKET);
        bytes32 second = _marketAt(v, 13);
        assertTrue(second != mid, "PREMISE: the two loans sit in two markets");

        assertEq(v.grossNav(), _hubTruthNav(v), "the pooled position is what the vault prices on");
    }

    /// @notice A SECOND vault's markets never enter the first's position: the key is the LENDER.
    /// @dev The property pooling must not cost. Isolation between PARTIES survives because the key IS
    /// @dev the party; what pooling gives up is only isolation between one party's own markets.
    function test_AnotherVaultsMarketsAreNotInThisOnesPosition() public {
        CuratorVault a = _newVault(0);
        _lpDeposit(a, alice, SEED);
        _open(PER_MARKET);
        uint256 navA = a.grossNav();

        CuratorVault b = _newVault(0); // the same USDC quote, so isolation rests on the lender key alone
        _lpDeposit(b, bob, SEED);
        _open(PER_MARKET);

        assertEq(a.grossNav(), navA, "the second vault's lending did not move the first's NAV");
        assertEq(a.grossNav(), _hubTruthNav(a), "and the first still reconciles against the hub");
    }
}
