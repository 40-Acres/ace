// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PolicyRefused} from "../../../src/ace/hub/Borrower.sol";
import {LoanMath} from "../../../src/ace/hub/libraries/LoanMath.sol";
import {Loan, MarketParams} from "../../../src/ace/hub/Types.sol";
import {Row} from "../../../src/curator/CuratorVault.sol";
import {PriceGrid} from "../../../src/curator/PriceGrid.sol";
import {_extended} from "../../utils/Extended.sol";
import {AceVaultRig} from "./AceVaultRig.sol";

/// @notice Vault audit suite rows on the core rig: the vault's own roll policy, refusing an extension on each leg and admitting it on a buffer edit.
/// @notice The SCA-01 and V-6 rows went with the vault's roll and its promise bit: no request or drain bracket can withhold a promise that does not exist.
contract VaultAuditPoCTest is AceVaultRig {
    uint256 internal loanId;

    function setUp() public override {
        super.setUp();
        loanId = _borrow(MAX_TENOR);
    }

    /// @dev Mint the holder exactly the fee an extension of `loanId` costs now, on the time it adds, and approve the hub for it.
    function _fundFee() internal {
        Loan memory l = read.loan(loanId);
        MarketParams memory mp = ace.idToMarketParams(l.market);
        uint256 fee = LoanMath.originationFee(l.debt, uint64(_now()) + l.tenor - l.expiry, mp.baseBps, mp.minTenor);
        usdc.mint(borrower, fee);
        vm.prank(borrower);
        usdc.approve(address(ace), fee);
    }

    /// @dev The holder asks the hub to extend `loanId` by the row's shortest term, in cash, expecting the vault's policy to refuse.
    function _expectRefused() internal {
        _fundFee();
        vm.prank(borrower);
        vm.expectRevert(PolicyRefused.selector);
        ace.extend(loanId, 0, "");
    }

    /// @notice An extension meets the vault's price leg first: a record under the market's price makes the policy refuse it.
    function test_AnExtension_ThePriceLegRefuses() public {
        record.setMinPrice(_mp(loanId).price - 1);
        _toWindow(loanId);
        _expectRefused();
    }

    /// @notice An extension is refused while the drain stands or the row is cut: the vault would not lend there now.
    function test_AnExtension_RefusedWhileTheLegsAreDown() public {
        _toWindow(loanId);
        vm.prank(curator);
        vault.setDrain(true);
        _expectRefused();
        vm.prank(curator);
        vault.setDrain(false);
        vm.prank(guardian);
        vault.submitCap(address(coll), 0);
        _expectRefused();
    }

    /// @dev Re-list the rig's collateral on `r` through the timelock.
    function _relist(Row memory r) internal {
        vm.prank(curator);
        vault.submitCollateral(address(coll), r);
        _warpBy(TIMELOCK);
        vault.accept(address(coll));
    }

    /// @notice V-2: a rate edit on the same record stops the vault's policy admitting an extension of a loan on the old terms.
    function test_V2_ARateEditStopsTheOldTermsExtension() public {
        Row memory r = _row(address(record), type(uint192).max);
        r.baseBps = 2 * RATE_BPS;
        _relist(r);
        _toWindow(loanId);
        _expectRefused();
    }

    /// @notice V-2: a shorter tenor ceiling on the same record stops the vault's policy admitting an extension of a loan on the old terms.
    function test_V2_ATenorEditStopsTheOldTermsExtension() public {
        Row memory r = _row(address(record), type(uint192).max);
        r.maxTenor = MAX_TENOR - 1 days;
        _relist(r);
        _toWindow(loanId);
        _expectRefused();
    }

    /// @notice V-2 control: a buffer-only edit still lets the loan extend in place, since the record test already judges the price.
    function test_V2_Control_ABufferOnlyEditKeepsTheExtension() public {
        Row memory r = _row(address(record), type(uint192).max);
        r.bufferBps = 3000;
        _relist(r);
        _toWindow(loanId);
        uint64 expiry = read.loan(loanId).expiry;
        _fundFee();
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertTrue(_extended(read, loanId, expiry), "the loan extended in place");
    }
}

/// @notice LD-01: `PriceGrid.down` of a price already on the grid returns the step below it, never above.
contract PriceGridAuditPoCTest is Test {
    uint256 internal constant Q96 = 1 << 96;

    function _gridPrice(int24 t) internal pure returns (uint256) {
        uint256 g = TickMath.getSqrtPriceAtTick(t);
        return Math.mulDiv(g, g, Q96);
    }

    /// @notice LD-01: the grid price at tick -200000 floors to the grid price at tick -200050.
    function test_LD01_AGridPriceFloorsToTheStepBelowIt() public pure {
        uint256 p = _gridPrice(-200_000);
        uint256 d = PriceGrid.down(p);
        assertEq(d, _gridPrice(-200_050), "one whole step under the input");
        assertLt(d, p, "so a grid price is not its own floor");
        assertEq(PriceGrid.down(p + 1), p, "one atom above it floors back onto it");
    }

    /// @notice LD-01 control: whatever the input, `down` never returns a price above it.
    function testFuzz_LD01_DownNeverAboveItsInput(uint256 p) public pure {
        assertLe(PriceGrid.down(p), p, "down above its input");
    }
}
