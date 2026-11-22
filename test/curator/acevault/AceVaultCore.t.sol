// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {AceVaultFlows, BorrowRequest, Terms} from "../../../src/curator/libraries/AceVaultFlows.sol";
import {Extension, IRollPolicy} from "../../../src/interfaces/IRollPolicy.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTerms} from "../vault/MockTerms.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The base's own refusals, whatever terms a product hands it, and the vault's own roll policy.
/// @dev Both run on a vault whose product is a `MockTerms` a row sets, so the core is what answers.
contract AceVaultCoreTest is AceVaultRig {
    AceVault internal m;
    MockTerms internal mt;

    function setUp() public override {
        super.setUp();
        (m, mt) = _onMockTerms();
    }

    /// @dev The rig collateral's market, lent by the mocked vault.
    function _mmp() internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = address(m);
        p.settleBountyBps = 0;
    }

    function _draw() internal pure returns (Terms memory) {
        return Terms({units: UNITS, principal: PRINCIPAL, tenor: MIN_TENOR, minBufferWad: 0});
    }

    function _mborrow(MarketParams memory p) internal returns (uint256 loanId) {
        mt.setTerms(p, _draw());
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(m), UNITS);
        loanId = m.borrow(_req(UNITS, PRINCIPAL, MIN_TENOR), "", "");
        vm.stopPrank();
    }

    /// @dev Expect the mocked vault's borrow of `r` on `p` to revert with `sel`, the borrower minted and approved.
    function _expectBorrowRevert(MarketParams memory p, BorrowRequest memory r, bytes4 sel) internal {
        mt.setTerms(p, _draw());
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(m), UNITS);
        vm.expectRevert(sel);
        m.borrow(r, "", "");
        vm.stopPrank();
    }

    function _expectBorrowRevert(MarketParams memory p, bytes4 sel) internal {
        _expectBorrowRevert(p, _req(UNITS, PRINCIPAL, MIN_TENOR), sel);
    }

    /// @notice A market paying any settle bounty is refused: at a zero bounty nothing strands, so every vault market takes zero.
    function test_ANonzeroBountyMarketIsRefused() public {
        MarketParams memory p = _mmp();
        p.settleBountyBps = 50;
        _expectBorrowRevert(p, AceVaultFlows.PaysSettleBounty.selector);
    }

    /// @notice A market naming another lender is not this vault's.
    function test_AnotherLendersMarketIsRefused() public {
        MarketParams memory p = _mmp();
        p.lender = stranger;
        _expectBorrowRevert(p, AceVaultFlows.NotOurLender.selector);
    }

    /// @notice A market quoting anything but the vault's asset is refused before any collateral is pulled.
    function test_AForeignQuoteIsRefusedBeforeAnyPull() public {
        MarketParams memory p = _mmp();
        p.quote = address(new MockERC20("Other Cash", "OTH", 6));
        uint256 held = coll.balanceOf(borrower);
        _expectBorrowRevert(p, AceVaultFlows.OutsideEnvelope.selector);
        assertEq(coll.balanceOf(borrower), held + UNITS, "the refusal pulled nothing");
        assertEq(coll.balanceOf(address(m)), 0, "and the vault holds none");
    }

    /// @notice The vault's own share is never collateral, even where the borrower asks for it by name.
    function test_TheVaultsOwnShareIsRefused() public {
        MarketParams memory p = _mmp();
        p.collateral = address(m);
        BorrowRequest memory r = _req(UNITS, PRINCIPAL, MIN_TENOR);
        r.collateral = address(m); // the binding admits only the collateral asked, so the ask names the share
        _expectBorrowRevert(p, r, AceVaultFlows.SharesAreNotCollateral.selector);
    }

    /// @notice A placement past the cap room is refused by name.
    function test_APlacementPastTheRoomIsRefused() public {
        mt.setRoom(MockTerms.Mode.Answer, PRINCIPAL - 1);
        _expectBorrowRevert(_mmp(), AceVaultFlows.OverCap.selector);
    }

    /// @notice The vault's policy refuses an extension in a market that is not this vault's, every product leg aside.
    function test_TheVaultsPolicyRefusesAForeignMarket() public {
        uint256 loanId = _borrow(MIN_TENOR);
        bytes4 answer = m.admitsExtension(_ext(loanId), "");
        assertEq(answer, bytes4(0), "not this vault's market");
    }

    /// @notice The vault's policy is ONE consent over every leg: the product's consent and no drain; either one closed refuses.
    /// @notice The hub's extension then refuses `PolicyRefused`, asked here from expiry on.
    function test_TheVaultsPolicyNeedsEveryLeg() public {
        uint256 loanId = _mborrow(_mmp());
        Extension memory e = _ext(loanId);
        assertEq(m.admitsExtension(e, ""), IRollPolicy.admitsExtension.selector, "every leg open: the vault consents");
        mt.setConsent(MockTerms.Mode.Answer, false);
        assertEq(m.admitsExtension(e, ""), bytes4(0), "a product that withholds consent refuses");
        mt.setConsent(MockTerms.Mode.Answer, true);
        assertEq(m.admitsExtension(e, ""), IRollPolicy.admitsExtension.selector, "CONTROL: every leg reopened");
        vm.prank(curator);
        m.setDrain(true);
        assertEq(m.admitsExtension(e, ""), bytes4(0), "the drain refuses");
        _warpAtLeastTo(_expiry(loanId) - 1); // the term's last second: from expiry the hub refuses LoanMatured before it asks
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /// @dev The extension the borrower's own `extend` by `MIN_TENOR` would hand the lender's policy, its fee left out.
    function _ext(uint256 loanId) internal view returns (Extension memory e) {
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = ace.idToMarketParams(l.market);
        (e.caller, e.loanId, e.borrower, e.units, e.debt, e.newDebt) = (l.borrower, loanId, l.borrower, l.collateralUnits, l.debt, l.debt);
        (e.expiry, e.newExpiry, e.src, e.dst) = (l.expiry, l.expiry + MIN_TENOR, mp, mp);
    }
}
