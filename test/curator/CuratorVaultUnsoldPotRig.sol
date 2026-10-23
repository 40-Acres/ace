// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {CuratorVaultBase} from "./CuratorVaultBase.sol";
import {CuratorVault} from "../../src/curator/CuratorVault.sol";
import {VaultConfig} from "../../src/curator/AceVault.sol";
import {AceInventoryLens} from "../../src/ace/lens/AceInventoryLens.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";

/// @notice The guardian's dead-pot override, declared by signature so these rows compile against a vault that predates it.
interface IDeadPotOverride {
    function exemptDeadPots(uint256 expectedSettled) external;
}

/// @notice The unsold-pot gate's rig: a production instant vault with a guardian, its market, and the hub's two counts.
/// @dev The gate's errors and event are named here by selector alone, so a row is red on a vault without them rather than uncompilable.
/// @dev A default is SHALLOW by default: four percent of the seed, so no price gate stands and only the new gate can refuse the entrant.
abstract contract UnsoldPotRig is CuratorVaultBase {
    error InventoryUnsold();
    error NotGuardian();
    error PotsMoved(uint256 settledPots);

    event DeadPotsExempted(uint256 unsold, uint256 settled);

    uint256 internal constant SEED = 10_000e6; // the stayer's stake
    uint256 internal constant SHALLOW = 400e6; // a default of four percent of the seed
    uint256 internal constant SMALL = 200e6; // half of one
    uint256 internal constant ENTRY = 1_000e6; // what an entrant brings

    address internal guardian = address(0x6A2D);
    address internal carol = address(0xCA201);

    AceInventoryLens internal inv;
    MockPersistenceRecord internal rec1; // the rig market's own record, kept apart because `record` follows the newest row

    function setUp() public virtual override {
        super.setUp();
        inv = new AceInventoryLens(address(ace), address(lens));
    }

    /// @dev A production vault, instant by default, with the rig's guardian and the rig collateral listed.
    function _gateVault() internal returns (CuratorVault v) {
        VaultConfig memory c = _cfg(0);
        c.guardian = guardian;
        v = _deploy(c, "Gated", "cGATE");
        rec1 = record;
    }

    /// @dev The same vault with no guardian named, so nobody holds the override's key.
    function _keylessVault() internal returns (CuratorVault v) {
        VaultConfig memory c = _cfg(0);
        c.guardian = address(0);
        v = _deploy(c, "Keyless", "cKEY");
        rec1 = record;
    }

    /// @dev A second market of the vault's: a second collateral listed on its own row and record; returns the door market and the record.
    function _secondMarket(CuratorVault v) internal returns (bytes32 m2, MockPersistenceRecord r2) {
        MockStakeVault c2 = new MockStakeVault(43);
        _list(v, address(c2));
        r2 = record;
        m2 = _doorMarket(v, address(c2));
    }

    /// @dev The hub's two words for this vault's asset: settled pots not yet sold, and pots ever settled.
    function _counts(CuratorVault v) internal view returns (uint256 unsold, uint256 settled) {
        return ace.lenderUnresolved(address(v), v.asset());
    }

    /// @dev Borrow `principal` through the door on `market`'s collateral, then finalize it on `rec`: the pot is left unsold.
    function _defaultIn(CuratorVault v, bytes32 market, MockPersistenceRecord rec, uint256 principal) internal returns (uint256 loanId) {
        loanId = _borrowOn(v, ace.idToMarketParams(market).collateral, principal);
        assertEq(ace.loanMarket(loanId), market, "PREMISE: the door lent in the named market");
        v.crank();
        rec.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        rec.setBelow(false);
        v.crank();
        assertGt(read.invPotOf(market, loanId), 0, "PREMISE: the settlement left a pot");
    }

    /// @dev One shallow default in the rig's market; no pile over the band vests, so no price gate stands.
    function _shallowDefault(CuratorVault v) internal returns (uint256 loanId) {
        loanId = _defaultIn(v, mid, rec1, SHALLOW);
        assertLe(v.unvested() * 10_000, v.totalAssets() * v.GATE_BPS(), "PREMISE: no pile over the band vests, so the pile gate leaves entry open");
    }

    /// @dev Buy a pot whole at the hub's ask, at the clearing budget, and assert it emptied.
    function _sellPot(bytes32 market, uint256 loanId) internal {
        uint256 budget = inv.clearingBudget(market, loanId);
        assertGt(budget, 0, "PREMISE: the pot quotes a clearing budget");
        _buyPot(keeper, loanId, budget);
        assertEq(read.invPotOf(market, loanId), 0, "PREMISE: the buy emptied the pot");
    }

    /// @dev Entry is shut by the gate: both views read zero and both verbs refuse `InventoryUnsold`, with none of the cash moved.
    function _assertShut(CuratorVault v, address who) internal {
        assertEq(v.maxDeposit(who), 0, "maxDeposit reads the gate");
        assertEq(v.maxMint(who), 0, "and so does maxMint");
        uint256 cash = usdc.balanceOf(who) + ENTRY;
        usdc.mint(who, ENTRY);
        vm.startPrank(who);
        usdc.approve(address(v), ENTRY);
        vm.expectRevert(InventoryUnsold.selector);
        v.deposit(ENTRY, who);
        vm.expectRevert(InventoryUnsold.selector);
        v.mint(ENTRY * 1e6, who);
        vm.stopPrank();
        assertEq(usdc.balanceOf(who), cash, "none of the entrant's cash moved");
    }

    /// @dev Entry is open: the view admits and a deposit lands.
    function _assertOpen(CuratorVault v, address who) internal returns (uint256 shares) {
        assertGt(v.maxDeposit(who), 0, "the deposit view admits");
        assertGt(v.maxMint(who), 0, "and so does the mint view");
        shares = _lpDeposit(v, who, ENTRY);
        assertGt(shares, 0, "and the deposit lands");
    }

    /// @dev The guardian's override at the settled count it names.
    function _exempt(CuratorVault v, uint256 s) internal {
        vm.prank(guardian);
        IDeadPotOverride(address(v)).exemptDeadPots(s);
    }
}
