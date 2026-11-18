// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockStakeVault} from "../../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../../utils/AceFixtures.sol";
import {AceReader} from "../../utils/AceReader.sol";
import {IAceVaultLens, VaultLens} from "../../utils/VaultLens.sol";
import {VaultSeed} from "../../utils/VaultSeed.sol";
import {MarketParams} from "../../../src/ace/hub/Types.sol";
import {AceVault} from "../../../src/curator/AceVault.sol";
import {ProductConfig} from "../../../src/curator/AceVaultCaps.sol";
import {Terms, VaultConfig} from "../../../src/curator/AceVaultFlows.sol";
import {IAceVaultDoor} from "../../../src/interfaces/IAceVaultDoor.sol";
import {AceVaultBaseRig} from "./AceVaultBaseRig.sol";
import {MockTerms} from "./MockTerms.sol";

/// @notice A door a row drives by hand: it names its vault, collects through it, returns cash under any key, and calls anything.
/// @dev Hostile by construction: nothing stops it closing a key early, naming a key it never held, or returning cash it never sold for.
contract MockDoor {
    address public VAULT;

    constructor(address vault) {
        VAULT = vault;
    }

    /// @dev Point the door at another vault, so a deploy naming it is unbound.
    function setVault(address v) external {
        VAULT = v;
    }

    /// @dev The collect, as the door's own wrapper makes it.
    function collect(uint256[] calldata ids) external returns (uint256[] memory) {
        return IAceVaultDoor(VAULT).collectForfeited(ids);
    }

    /// @dev Approve exactly `cash` of the vault's asset and return it against `c`.
    function give(address c, uint256 cash, bool closes) external {
        IERC20(IERC4626(VAULT).asset()).approve(VAULT, cash);
        IAceVaultDoor(VAULT).returnProceeds(c, cash, closes);
    }

    /// @dev Any call, as the door.
    function exec(address to, bytes calldata data) external returns (bytes memory r) {
        bool ok;
        (ok, r) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
    }
}

/// @notice The rig for a door-mode AceVault: the base rig's hub, collateral and MockTerms, with a MockDoor bound as its door.
/// @dev The market carries no inventory ask, so a default's pot leaves the hub only by the door's collect.
abstract contract AceVaultDoorRig is AceVaultBaseRig {
    MockDoor internal door;
    IAceVaultDoor internal dv; // the vault's door-mode surface, at the vault's own address
    IAceVaultLens internal lens;

    uint192 internal constant ROW = 50_000e6; // the rig collateral's row, finite so the booked value's hold on it shows
    address internal constant UNLISTED = address(0xABCD); // a collateral on the wildcard alone, whose room is the total's

    function setUp() public virtual override {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockStakeVault(42);
        (ace, pm) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        read = new AceReader(address(ace));
        lens = VaultLens.deploy();
        record = _record(address(coll));
        (vault, terms, door) = _deployDoor(_cfg(), _pc(), _caps(ROW, UNCAPPED, UNCAPPED));
        dv = IAceVaultDoor(address(vault));
        _setDoorTerms(address(coll), record);
        _lp(alice, LP_CASH);
    }

    /// @dev A MockDoor, then a MockTerms, both naming the address the vault's create takes, then the door-mode vault there.
    function _deployDoor(VaultConfig memory cfg, ProductConfig memory pc, uint192[3] memory c) internal returns (AceVault v, MockTerms t, MockDoor d) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        d = new MockDoor(predicted);
        t = new MockTerms(predicted, address(ace));
        (pc.terms, pc.door) = (address(t), address(d));
        VaultSeed.fund(cfg, predicted);
        v = new AceVault(cfg, pc, _listing(predicted, c), "Door", "dVLT");
        assertEq(address(v), predicted, "rig: the vault landed off its predicted address");
    }

    /// @dev The base rig's market on `c` with the inventory ask off, as door mode requires.
    function _doorMarket(address c, MockPersistenceRecord r) internal view returns (MarketParams memory p) {
        p = _market(c, r);
        p.inventoryAsk = false;
    }

    /// @dev Point the product at `c`'s door-mode market.
    function _setDoorTerms(address c, MockPersistenceRecord r) internal returns (MarketParams memory p) {
        p = _doorMarket(c, r);
        terms.setTerms(p, Terms({units: UNITS, principal: PRINCIPAL, tenor: 0, minBufferWad: 0}));
    }

    /// @dev A loan of the rig's ask, then the clock past its expiry, so it is collectable.
    function _defaulted() internal returns (uint256 loanId) {
        loanId = _borrow();
        _warpTo(read.loan(loanId).expiry + 1);
    }

    /// @dev The door collects one id.
    function _collect(uint256 loanId) internal returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = loanId;
        return door.collect(ids)[0];
    }

    /// @dev Mint `cash` to the door and have it return it against `c`.
    function _give(address c, uint256 cash, bool closes) internal {
        usdc.mint(address(door), cash);
        door.give(c, cash, closes);
    }

    /// @dev The ledger record for `c`.
    function _seized(address c) internal view returns (uint256 value, bool open, uint64 writeOffAt) {
        return lens.seizedOf(address(vault), c);
    }

    /// @dev The total's room: the room of a collateral whose row is the uncapped wildcard and against which nothing is lent or held.
    function _totalRoom() internal view returns (uint256) {
        return lens.roomOf(address(vault), UNLISTED);
    }

    /// @dev What is lent against `c` at the hub.
    function _lent(address c) internal view returns (uint256 lent) {
        (lent,) = ace.lenderByCollateral(address(vault), address(usdc), c);
    }
}
