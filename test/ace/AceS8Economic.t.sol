// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {Borrower} from "../../src/ace/hub/Borrower.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title AceS8Economic
/// @notice MEASUREMENT for audit run 2026-10-03-251533 phase 8: legal market corners, priced.
/// @notice Every market here passes genesis and every row is green; the rows carry the numbers the findings cite.
/// @dev Recordless markets at par, so no draw cap or record answer shapes a quote; `previewOpen` is the open's own arithmetic.
contract AceS8EconomicTest is Test {
    Ace internal ace;
    AceLens internal lens;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal honest; // 7d to 365d at 15 bps per 7d: a 7.8 percent lender APR, booked on-chain

    address internal constant BORROWER = address(0xB0B);
    uint256 internal constant P = 10_000_000e6; // one 10M USDC loan, the same in every row
    uint256 internal constant UNITS = 20_000_000e18; // over the coverage line at par for k up to 2
    uint64 internal constant YEAR = 365 days;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        AceFixtures.Deployment memory d = AceFixtures.deploy(_params(7 days, YEAR, 15));
        (ace, honest) = (d.ace, d.id);
        lens = new AceLens(address(ace));
        _fund(honest);
    }

    function _params(uint64 minTenor, uint64 maxTenor, uint256 baseBps) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.baseBps = baseBps;
        p.minTenor = minTenor;
        p.maxTenor = maxTenor;
    }

    function _create(uint64 minTenor, uint64 maxTenor, uint256 baseBps) internal returns (bytes32 id) {
        id = ace.createMarket(_params(minTenor, maxTenor, baseBps));
        _fund(id);
    }

    function _fund(bytes32 id) internal {
        usdc.mint(AceFixtures.LENDER, P);
        vm.startPrank(AceFixtures.LENDER);
        usdc.approve(address(ace), P);
        ace.deposit(id, P);
        vm.stopPrank();
    }

    function _quote(bytes32 id, uint64 tenor) internal view returns (Borrower.Quote memory) {
        return ace.previewOpen(id, UNITS, P, tenor, BORROWER, OpenBounds(0, 0, 0));
    }

    /// @notice A one-year 10M loan: booked at 7.8 percent it pays ACE 78,214 USDC; booked at the floor rate it pays 100.
    /// @notice The floor rate is `MIN_BASE_BPS` per a 365-day `minTenor`, and the same 100 USDC buys a 34,865-year term.
    /// @dev Proof of fixture: all three markets are admitted by genesis and quote the same principal.
    /// @dev KNOWN, ruled accepted: the take is per loan, and parties who trust each other to settle off-hub can bypass any venue's fee.
    function test_Known_AFloorRateLeavesTheProtocolATenthOfABpsAtAnyTerm() public {
        bytes32 floorYear = _create(YEAR, YEAR, 1);
        uint64 longest = type(uint40).max; // genesis's own sanity bound on a term
        bytes32 floorForever = _create(longest, longest, 1);

        Borrower.Quote memory h = _quote(honest, YEAR);
        Borrower.Quote memory y = _quote(floorYear, YEAR);
        Borrower.Quote memory f = _quote(floorForever, longest);

        emit log_named_decimal_uint("honest 1y: all-in fee (USDC)        ", h.fee, 6);
        emit log_named_decimal_uint("honest 1y: ACE's take (USDC)        ", h.protocolFee, 6);
        emit log_named_decimal_uint("floor  1y: all-in fee (USDC)        ", y.fee, 6);
        emit log_named_decimal_uint("floor  1y: ACE's take (USDC)        ", y.protocolFee, 6);
        emit log_named_decimal_uint("floor  34,865y: ACE's take (USDC)   ", f.protocolFee, 6);
        emit log_named_uint("honest take / floor take            ", h.protocolFee / y.protocolFee);

        assertEq(y.fee, 1_100e6, "floor rate: 1.1 bps all-in on any principal");
        assertEq(y.protocolFee, 100e6, "floor rate: ACE takes 0.1 bps");
        assertEq(f.protocolFee, y.protocolFee, "the take does not grow with the term");
        assertGt(h.protocolFee, 780 * y.protocolFee, "an off-hub price moves 99.9 percent of ACE's take off the hub");

        (uint256 lenderApr, uint256 allInApr,) = lens.rateBps(floorForever);
        assertEq(lenderApr, 0, "the lens reads a zero lender APR");
        assertEq(allInApr, 0, "and a zero all-in APR");
    }

    /// @notice At the fee-share corner the all-in APR reads 25 percent a term; the cash received pays 33.3 percent.
    /// @dev The fee is prepaid out of the draw, so `rateBps` is a rate on FACE; the rate on proceeds is `fee / payout`.
    function test_Measure_TheAllInAprIsARateOnFaceNotOnTheCashReceived() public {
        bytes32 corner = _create(7 days, 7 days, 2272);
        Borrower.Quote memory q = _quote(corner, 7 days);
        (, uint256 allInApr,) = lens.rateBps(corner);
        uint256 onProceedsApr = (q.fee * 10000 * 365) / (q.payout * 7);

        emit log_named_uint("corner: all-in APR on face, bps      ", allInApr);
        emit log_named_uint("corner: APR on the cash received, bps", onProceedsApr);
        emit log_named_decimal_uint("corner: fee / principal              ", (q.fee * 1e18) / P, 18);
        emit log_named_decimal_uint("corner: fee / payout                 ", (q.fee * 1e18) / q.payout, 18);

        assertEq(q.fee + q.payout, P, "fixture: the payout is the principal less the fee");
        assertApproxEqRel(onProceedsApr * 1e18 / allInApr, 1.3332e18, 0.001e18, "the face rate understates by 1/(1-f)");
    }
}
