// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceKeeperBudgetRail
/// @notice `deleverageFloorEpsBps` is the deleverage keeper's whole pay, so genesis floors it under a live band.
/// @notice `fillFeeBps` shares NO budget with it: a pot's buyer pays the fill fee, and no deleverage crank reads it.
/// @dev THE DEFECT: eps had a max and no minimum, and at eps 0 the floor IS the reference price, so a keeper earns nothing.
/// @dev It failed silently -- no crank, no melt, no revert, no event -- so genesis accepted a dead primitive that looked configured.
/// @dev ONE eps rail: an ABSOLUTE floor catches eps 0. The fill-fee-over-eps ratio rail is deleted with the bid side it priced.
/// @dev The floor is scoped to a live deleverage band, since eps is read only behind that channel.
/// @dev Keeper profit needs `eps > venue fee + slippage`; the fill fee keeps only its own absolute ceiling, `MAX_FILL_FEE_BPS`.
contract AceKeeperBudgetRailTest is Test {
    Ace internal ace;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ace = AceFixtures.newAce();
    }

    /// @dev The channel OFF: only eps 0 is admitted here, and the rows passing a nonzero eps are refused earlier, by name.
    function _params(uint256 epsBps, uint256 fillFeeBps) internal returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(weth));
        p.deleverageFloorEpsBps = epsBps;
        p.fillFeeBps = fillFeeBps;
        p.record = address(new MockPersistenceRecord(address(usdc), address(weth)));
    }

    /// @dev The channel ON: the band block is where the eps floor lives.
    function _banded(uint256 epsBps, uint256 fillFeeBps) internal returns (MarketParams memory p) {
        p = _params(epsBps, fillFeeBps);
        p.deleverageBandBps = 3000;
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
    }

    // ============ the dead primitive ============

    /// @dev THE BUG, NOW CLOSED: at eps 0 the keeper returns the whole reference price, earns nothing, and nobody cranks.
    /// @dev Only an absolute floor catches it: a zero eps forms no ratio for any relational rail to bound.
    /// @dev `_params` is HOISTED out of the call because an external call in the ARGUMENT list eats the one-shot `expectRevert`.
    function test_Genesis_RefusesZeroEpsOnALiveDeleverage() public {
        MarketParams memory p = _banded(0, 0);
        vm.expectRevert("deleverage eps zero");
        ace.createMarket(p);
    }

    /// @dev THE BOUNDARY THAT SURVIVES, and it is principled rather than residual.
    /// @dev `deleverageFloorEpsBps` is read only behind `deleverage`, so a band-off market never reads it.
    /// @dev Flooring it there would force every non-deleveraging market to carry a number nothing reads.
    function test_Genesis_AdmitsZeroEpsWhenTheChannelIsOff() public {
        assertTrue(ace.createMarket(_params(0, 0)) != bytes32(0), "eps is meaningless with no disposal");
    }

    /// @dev The worst previously-admissible market IS caught under a live band: eps 0 pays the keeper nothing.
    function test_Genesis_RefusesTheWorstFormerlyAdmissibleMarket() public {
        MarketParams memory p = _banded(0, 50);
        vm.expectRevert("deleverage eps zero");
        ace.createMarket(p);
    }

    // ============ the fill fee and eps: two dials, no relation between them ============

    /// @dev With the channel off there is no eps to spend, and deleverage-off-with-an-inventory-ask is a legal shape.
    /// @dev `fillFeeBps` is live independently of deleverage, and no rail couples it to eps.
    function test_Genesis_ABandOffMarketMayCarryAFillFeeAtEpsZero() public {
        assertTrue(ace.createMarket(_params(0, 50)) != bytes32(0), "a band-off market may carry a fill fee at eps 0");
    }

    /// @dev A fill fee at a quarter of eps, where the deleted ratio rail used to bind, is admitted like any fee under the cap.
    function test_Genesis_AdmitsFillFeeAtAQuarterOfEps() public {
        assertTrue(ace.createMarket(_banded(100, 25)) != bytes32(0), "no boundary binds at eps / 4");
    }

    /// @dev One bp over the quarter is ADMITTED: no ratio rail binds the fill fee to eps any more.
    /// @dev Was the row the ratio rail existed for; the bid-side arb that shared the budget is deleted.
    function test_Genesis_AdmitsFillFeeOneBpOverTheQuarter() public {
        assertTrue(ace.createMarket(_banded(100, 26)) != bytes32(0), "a band-on market may carry a fill fee over eps / 4");
    }

    /// @dev The fill fee is independent of eps: the ceiling fee is admitted at the narrow eps and the wide one alike.
    function test_Genesis_TheFillFeeIsIndependentOfEps() public {
        assertTrue(ace.createMarket(_banded(100, 50)) != bytes32(0), "eps 100 admits the ceiling fill fee");
        assertTrue(ace.createMarket(_banded(200, 50)) != bytes32(0), "and so does eps 200");
    }

    /// @dev A zero fill fee is admissible at any non-zero eps: the fill fee shares no budget with the keeper's eps.
    /// @dev The shipped pair (eps 100, fillFee 0) is this case.
    function test_Genesis_AdmitsZeroFillFeeAtTheShippedEps() public {
        assertTrue(ace.createMarket(_banded(100, 0)) != bytes32(0), "the shipped pair is admissible");
    }

    // ============ the fill fee's one rail: its absolute cap ============

    /// @dev `MAX_FILL_FEE_BPS` is 50: the most a settled pot's buyer pays over the ask, and the fill fee's only genesis rail.
    /// @dev 51 fails on that ABSOLUTE cap, whatever the eps.
    function test_Genesis_RefusesFillFeeOverTheAbsoluteCap() public {
        MarketParams memory p = _params(200, 51);
        vm.expectRevert("fill fee too high");
        ace.createMarket(p);
    }

    /// @dev eps still has its own ceiling: the borrower's execution guarantee is bounded above whatever the fill fee wants.
    function test_Genesis_RefusesEpsOverItsOwnCeiling() public {
        MarketParams memory p = _params(201, 0);
        vm.expectRevert("deleverage eps too high");
        ace.createMarket(p);
    }
}
