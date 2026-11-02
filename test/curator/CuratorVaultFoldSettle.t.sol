// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams} from "../../src/ace/hub/Types.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @title CuratorVaultFoldSettle
/// @notice A vault loan nobody extended settles at the hub's `forceClose` from the expiry second, open to anyone, whatever the vault would consent to.
/// @notice Against the branch where its borrower extended it in cash, the settlement pays the vault more.
/// @dev The settle branch sells the pot at the hub's ask; the record's buffer under the collateral is the vault's gain over continuing.
contract CuratorVaultFoldSettleTest is CuratorVaultBase {
    uint256 internal constant SEED = 500_000e6;
    uint256 internal constant P = 70_000e6;
    uint256 internal constant BIG = 200_000e18; // enough collateral that the draw fits the door's price at the coverage multiple
    uint256 internal constant UNIT_SCALE = 1 << 96;
    uint256 internal FLOOR; // the record's windowed minimum, 10% over par, never moving

    address internal stranger = address(0x5717);

    function setUp() public override {
        super.setUp();
        vaultMinPrice = AceFixtures.px(1.1e18, address(usdc), address(collateral));
        FLOOR = vaultMinPrice;
    }

    /// @dev The big loan, opened through the door.
    function _openBig(CuratorVault v) internal returns (uint256 loanId) {
        collateral.mint(borrower, BIG);
        vm.startPrank(borrower);
        collateral.approve(address(v), BIG);
        loanId = v.borrow(_request(address(collateral), BIG, P), "", "");
        vm.stopPrank();
    }

    /// @dev Both branches are read at the SAME clock: one vest window on, then a fee collection.
    function _settleClock(CuratorVault v) internal {
        _warpBy(VEST_W + 1);
        v.collectFee();
    }

    /// @dev The vault with an LP, the loan, the open's gain vested and collected, and the clock an hour before expiry.
    function _loanInTheWindow() internal returns (CuratorVault v, uint256 loanId) {
        v = _newVault(0);
        _lpDeposit(v, alice, SEED);
        loanId = _openBig(v);
        v.crank();
        _warpBy(VEST_W + 1);
        v.collectFee();
        _warpAtLeastTo(uint256(read.loan(loanId).expiry) - 1 hours);
    }

    /// @dev The continuing branch, in the term's last second: the borrower extends in place in cash, then the credit is cranked home and the clock settled.
    function _extendBranch(CuratorVault v, uint256 loanId) internal returns (uint256 nav) {
        _warpAtLeastTo(uint256(read.loan(loanId).expiry) - 1);
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = ace.idToMarketParams(l.market);
        uint256 fee = LoanMath.originationFee(l.debt, uint64(_now()) + l.tenor - l.expiry, mp.baseBps, mp.minTenor);
        usdc.mint(borrower, fee);
        vm.startPrank(borrower);
        usdc.approve(address(ace), fee);
        ace.extend(loanId, 0, "");
        vm.stopPrank();
        v.crank();
        _settleClock(v);
        nav = v.totalAssets();
    }

    /// @notice A LOAN NOBODY EXTENDED settles at the hub's `forceClose` at expiry, open to anyone, and the vault does better than continuing it.
    /// @notice The vault's own consent to an extension moves nothing: the expiry close only settles.
    function test_AHubForceCloseAtExpirySettlesTheVaultsLoan() public {
        (CuratorVault v, uint256 loanId) = _loanInTheWindow();
        uint256 root = vm.snapshotState();
        uint256 continued = _extendBranch(v, loanId);
        vm.revertToState(root);

        _warpAtLeastTo(uint256(read.loan(loanId).expiry));
        vm.prank(stranger);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "forceClose settled the vault's loan at expiry");
        uint256 pot = read.invPotOf(mid, loanId);
        assertGt(pot, 0, "PREMISE: the settlement left a pot");
        _buyPot(stranger, loanId, 1_000_000e6);
        v.crank();
        _settleClock(v);
        uint256 nav = v.totalAssets();
        emit log_named_decimal_uint("extended vault NAV (USDC)", continued, 6);
        emit log_named_decimal_uint("settled  vault NAV (USDC)", nav, 6);
        assertGt(nav, continued, "the settle branch pays the vault the buffer the extension would have left with the borrower");
    }
}
