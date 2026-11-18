// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Borrower} from "../../../src/ace/hub/Borrower.sol";
import {Deleverage} from "../../../src/ace/hub/Deleverage.sol";
import {Lender} from "../../../src/ace/hub/Lender.sol";
import {LoanAccounting} from "../../../src/ace/hub/libraries/LoanAccounting.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {Cfg, LoanBook, Market} from "../../../src/ace/hub/Types.sol";

/// @title CoverageMathHarness
/// @notice The keeper's bill, the restore's cut, settlement's need and sliver, the secured base, the coverage line and the ask.
/// @notice Each is exposed by one call to the real body, so a spec checks the code and never a restatement of it.
/// @dev Compiled only from the pure-munged tree, where `_owed`, `_cut`, `_net` and `_askLeg` are internal instead of private.
/// @dev The storage-taking functions read one scratch loan, which each entry writes from its own arguments just before the call.
contract CoverageMathHarness {
    uint256 internal id; // the scratch loan id, read at run time: a constant key lets the compiler fold the slot the prover then cannot match

    LoanBook internal book; // scratch: only `_loan` writes it
    Market internal market; // scratch: only `_loan` writes it

    /// @notice `Deleverage._owed`: what the keeper pays for `units` at `floorPrice`.
    function owed(uint256 epsBps, uint256 unitScale, uint256 units, uint256 floorPrice) external pure returns (uint256) {
        Cfg memory c;
        c.p.deleverageFloorEpsBps = epsBps;
        c.unitScale = unitScale;
        return Deleverage._owed(c, units, floorPrice);
    }

    /// @notice `Deleverage._cut`: the protocol cut on a restore's `gross`, when it charges one.
    function cut(uint256 cutBps, uint256 gross, bool charge) external pure returns (uint256) {
        Cfg memory c;
        c.p.deleverageProtocolBps = cutBps;
        return Deleverage._cut(c, gross, charge);
    }

    /// @notice `Deleverage._net`: what `gross` melts, net of that cut.
    function net(uint256 cutBps, uint256 gross, bool charge) external pure returns (uint256) {
        Cfg memory c;
        c.p.deleverageProtocolBps = cutBps;
        return Deleverage._net(c, gross, charge);
    }

    /// @notice `LoanAccounting.collateralNeeded`: the units a live `claim` needs at `price`.
    function collateralNeeded(uint256 claim, uint256 price, uint256 unitScale) external returns (uint256) {
        _loan(0, claim);
        return LoanAccounting.collateralNeeded(market, _cfg(0, 0, price, unitScale), id);
    }

    /// @notice `LoanAccounting.sliverUnits`: the keeper's in-kind sliver off a lot of `units`.
    function sliverUnits(uint256 debt, uint256 claim, uint256 bountyBps, uint256 price, uint256 unitScale, uint256 units) external returns (uint256) {
        _loan(debt, claim);
        return LoanAccounting.sliverUnits(book, market, _cfg(0, bountyBps, price, unitScale), id, units);
    }

    /// @notice `LoanAccounting.securedBase`: the most a disposal may size against out of `units`.
    function securedBase(uint256 debt, uint256 claim, uint256 minCoverageWad, uint256 bountyBps, uint256 price, uint256 unitScale, uint256 units)
        external
        returns (uint256)
    {
        _loan(debt, claim);
        return LoanAccounting.securedBase(book, market, _cfg(minCoverageWad, bountyBps, price, unitScale), id, units);
    }

    /// @notice `Borrower.requiredAt`, the four-field form every caller reaches.
    function requiredAt(uint256 minCoverageWad, uint256 unitScale, uint256 debt, uint256 price) external pure returns (uint256) {
        return Borrower.requiredAt(minCoverageWad, unitScale, debt, price);
    }

    /// @notice `Borrower.coverageLine`, the four-field form every caller reaches.
    function coverageLine(uint256 minCoverageWad, uint256 unitScale, uint256 debt, uint256 price) external pure returns (uint256) {
        return Borrower.coverageLine(minCoverageWad, unitScale, debt, price);
    }

    /// @notice `LoanMath.debtFloor`: the least a live loan may owe.
    function debtFloor(uint256 minPrincipal) external pure returns (uint256) {
        return LoanMath.debtFloor(minPrincipal);
    }

    /// @notice `LoanMath.triggerPrice`: the price at which a loan of `debt` on `units` arms.
    function triggerPrice(uint256 debt, uint256 units, uint256 minCoverageWad, uint256 unitScale) external pure returns (uint256) {
        return LoanMath.triggerPrice(debt, units, minCoverageWad, unitScale);
    }

    /// @notice `Lender._askLeg`: the units a buy of up to `remaining` takes out of a pot of `inv`, and what it pays.
    function askLeg(uint256 inv, uint256 remaining, uint256 unitScale, uint256 fillFeeBps, uint256 askFloor, uint256 price)
        external
        pure
        returns (uint256 deliver, uint256 total)
    {
        return Lender._askLeg(inv, remaining, Lender.FillCfg(unitScale, fillFeeBps, askFloor, price));
    }

    /// @dev The scratch loan's debt and its claim in the scratch market.
    function _loan(uint256 debt, uint256 claim) private {
        book.loans[id].debt = debt;
        market.claim[id] = claim;
    }

    /// @dev A config holding only the four market fields these formulas read.
    function _cfg(uint256 minCoverageWad, uint256 bountyBps, uint256 price, uint256 unitScale) private pure returns (Cfg memory c) {
        c.p.minCoverageWad = minCoverageWad;
        c.p.settleBountyBps = bountyBps;
        c.p.price = price;
        c.unitScale = unitScale;
    }
}
