// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {InsufficientCash} from "../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../src/ace/hub/libraries/LoanMath.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {_extended} from "../utils/Extended.sol";

/// @title AceP4Base
/// @notice Audit run 2026-09-13-670568 phase 4: one record-backed sole-tenant market with a healthy loan.
/// @dev RECORD-BACKED, as the rows were built; the phase itself measured the recordless class.
/// @dev The record's windowed minimum is the mock's default, over the market's price, so it caps no draw and proves no distress.
abstract contract AceP4Base is WarpClock {
    Ace internal ace;
    AceReader internal read;
    AceLens internal lens;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal mid;
    MarketParams internal params;

    address internal alice = address(0xA11CE); // the market's one named lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5);

    uint256 internal constant PRINCIPAL = 11e6;
    uint256 internal constant COLL = 10_000e18;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        params = AceFixtures.marketParams(address(usdc), address(coll));
        params.record = address(new MockPersistenceRecord(address(usdc), address(coll)));
        params.lender = alice;
        AceFixtures.Deployment memory d = AceFixtures.deploy(params);
        (ace, pm, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    function _rest(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev A healthy loan at the market's minTenor; the borrower's allowance funds an extension's fee out of the principal.
    function _loan() internal returns (uint256 loanId) {
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev An extension's fee a second before expiry: the origination formula on the debt, for the tenor less that second.
    function _feeAtExpiryMinusOne() internal view returns (uint256) {
        return LoanMath.originationFee(PRINCIPAL, params.minTenor - 1, params.baseBps, params.minTenor);
    }
}

/// @title AceP4RollFunding
/// @notice An extension draws NO resting cash: its caller pays the fee, so resting cash is neither read nor spent.
/// @notice The retired roll drew a fresh remainder out of cash, which is the lever a stranger's drain pulled; there is none left.
/// @dev The two rows pin it from both sides: what the extension takes out of cash, and that a market with nothing resting still extends.
/// @dev The lender names a yes-policy in each row, so the answer turns on the loan alone.
contract AceP4RollFundingTest is AceP4Base {
    /// @notice CONTROL: with cash resting beside the loan, the extension lands in place and takes nothing out of resting cash.
    function test_Control_WithCashResting_TheExtensionTakesNone() public {
        AceFixtures.installYesPolicy(ace, alice);
        _rest(PRINCIPAL + PRINCIPAL);
        uint256 loanId = _loan();
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        (bool ok,, uint256 fee) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "control: the extension is admissible");
        assertEq(fee, _feeAtExpiryMinusOne(), "the preview quotes the extension's fee on the debt, for the time added");

        uint256 n = read.loanCount();
        uint256 restingBefore = ace.restingOf(mid);
        uint256 escrow = read.feeEscrowOf(loanId);
        uint256 earned = escrow - escrow / params.minTenor; // one second of the term is left unearned
        (,, uint256 owedBefore) = read.lenderPools(alice, address(usdc));
        vm.prank(borrower);
        ace.extend(loanId, 0, "");

        assertTrue(_extended(read, loanId, x), "control: the loan extended in place");
        assertEq(read.loanCount(), n, "minting no successor");
        assertEq(ace.restingOf(mid), restingBefore, "the extension took nothing out of resting cash");
        (,, uint256 owedAfter) = read.lenderPools(alice, address(usdc));
        assertEq(owedAfter - owedBefore, earned + LoanMath.tickCut(fee), "the lender's credit rose by the earned escrow and the new fee's tick cut");
        assertEq(read.debtOf(loanId), PRINCIPAL, "the fee was paid in cash: the debt is unchanged");
    }

    /// @notice With NOTHING resting beside the loan, the extension still lands: resting cash never enters it, and the pot takes nothing.
    function test_WithNothingResting_TheExtensionStillLands() public {
        AceFixtures.installYesPolicy(ace, alice);
        _rest(PRINCIPAL);
        uint256 loanId = _loan();
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        assertEq(ace.restingOf(mid), 0, "fixture: the open drew every resting atom");

        (bool ok,,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "the predicate admits on an empty market");

        uint256 n = read.loanCount();
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertTrue(_extended(read, loanId, x), "extended, not settled");
        assertEq(read.loanCount(), n, "in place");
        assertEq(read.invPotOf(mid, loanId), 0, "and the lender's pot took nothing");
    }
}
