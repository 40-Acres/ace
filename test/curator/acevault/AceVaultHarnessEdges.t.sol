// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVaultFlows, Terms} from "../../../src/curator/AceVaultFlows.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceVaultHarness} from "./AceVaultHarness.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice The core's edges a shipped product cannot reach: a zero tenor, a room exactly the draw, and the door's `Borrowed` log.
/// @dev Driven through the test product, whose terms a row sets.
contract AceVaultHarnessEdgesTest is AceVaultRig {
    uint256 internal constant LO = 10e6; // the market's minPrincipal
    AceVaultHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new AceVaultHarness(_cfg());
        usdc.mint(alice, LP_CASH);
        vm.startPrank(alice);
        usdc.approve(address(h), LP_CASH);
        h.deposit(LP_CASH, alice);
        vm.stopPrank();
    }

    /// @dev A vault market on the rig's collateral at `minPrincipal`, priced by the rig's record, paying no bounty.
    function _hmp(uint256 minPrincipal) internal view returns (MarketParams memory p) {
        p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        p.lender = address(h);
        p.settleBountyBps = 0;
        p.minPrincipal = minPrincipal;
    }

    function _hborrow(MarketParams memory p, uint64 tenor) internal returns (uint256 loanId) {
        h.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: tenor, minBufferWad: 0}));
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(h), UNITS);
        loanId = h.borrow(_req(UNITS, PRINCIPAL, tenor), "", "");
        vm.stopPrank();
    }

    // ---- the door's own edges ----

    /// @notice A cap room exactly the principal admits the draw.
    function test_ARoomExactlyThePrincipalAdmits() public {
        h.setRoom(PRINCIPAL);
        uint256 id = _hborrow(_hmp(LO), MIN_TENOR);
        assertTrue(ace.isLiveLoan(id), "a draw of exactly the room opens");
    }

    /// @notice A product handing the door no tenor opens at the market's shortest.
    function test_AZeroTenorOpensAtTheMarketsShortest() public {
        MarketParams memory p = _hmp(LO);
        uint256 id = _hborrow(p, 0);
        assertEq(read.loan(id).tenor, p.minTenor, "the loan runs the market's shortest term");
    }

    /// @notice The door logs one `Borrowed` from the vault: the loan, its market, the caller, the draw and the measured payout.
    function test_TheBorrowedEventNamesTheLoanAndTheCaller() public {
        MarketParams memory p = _hmp(LO);
        uint256 cash0 = usdc.balanceOf(borrower);
        vm.recordLogs();
        uint256 id = _hborrow(p, MIN_TENOR);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(h) || logs[i].topics[0] != AceVaultFlows.Borrowed.selector) continue;
            seen++;
            assertEq(uint256(logs[i].topics[1]), id, "the loan");
            assertEq(logs[i].topics[2], ace.loanMarket(id), "its market");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), borrower, "the caller, not the vault");
            assertEq(logs[i].data.length, 96, "three data words: the pledge, the draw and the payout");
            (uint256 units, uint256 principal, uint256 payout) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(units, UNITS, "the pledge");
            assertEq(principal, PRINCIPAL, "the draw");
            assertEq(payout, usdc.balanceOf(borrower) - cash0, "the payout the caller received");
        }
        assertEq(seen, 1, "exactly one Borrowed, from the vault");
    }
}
