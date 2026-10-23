// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {MarketExists} from "../../src/ace/hub/MarketInit.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";

/// @dev Minimal quote/collateral stand-ins: createMarket reads decimals() and nothing else.
contract MockToken {
    uint8 public immutable decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// @title AceDeployCap
/// @notice Successor to `test_TwoTx_EveryTx_UnderBaseCap` on the RETIRED MarketFactory; do not go looking.
/// @notice That test went red: per-market `deployChildren` redeployed 52 kB of runtime and blew EIP-7825.
/// @notice The singleton deletes the subject -- libraries and the hub deploy ONCE, market creation deploys nothing.
/// @dev Same measurement idiom as the test it succeeds: gasleft() around the call, assertLt vs the cap.
contract AceDeployCapTest is Test {
    /// @dev EIP-7825, as Base enforces it.
    uint256 internal constant CAP = 16_777_216;

    Ace internal ace;
    PositionManager internal positionManager;

    /// @dev Deploy one artifact as its own transaction-equivalent and report what it burned.
    function _deployArtifact(string memory artifact) internal returns (address at, uint256 used) {
        bytes memory code = vm.getCode(artifact);
        uint256 g = gasleft();
        assembly ("memory-safe") {
            at := create(0, add(code, 0x20), mload(code))
        }
        used = g - gasleft();
        require(at != address(0), "library deploy failed");
    }

    function _assertUnderCap(string memory artifact) internal returns (uint256 used) {
        (, used) = _deployArtifact(artifact);
        assertLt(used, CAP, artifact);
        emit log_named_uint(artifact, used);
    }

    /// @dev A realistic market: the shipped PoC economics, not placeholder round numbers.
    function _params(address quote, address collateral) internal view returns (MarketParams memory p) {
        p.quote = quote;
        p.collateral = collateral;
        // genesis READS a price source at creation, so an unset seam is the honest wiring on a band-off market
        p.record = address(0);
        p.fillFeeBps = 25; // under the absolute cap, the fill fee's only rail
        p.minCoverageWad = PocDeployConfig.MIN_COVERAGE_WAD;
        p.baseBps = PocDeployConfig.BASE_BPS;
        p.minTenor = ProtocolPolicy.MIN_TENOR;
        p.maxTenor = ProtocolPolicy.MAX_TENOR;
        p.minDebt = PocDeployConfig.MIN_DEBT;
        p.settleBountyBps = PocDeployConfig.SETTLE_BOUNTY_BPS;
        p.lender = address(this); // genesis refuses a zero lender, and this suite's subject is the gas, not tenancy
        p.price = PriceFrame.priceAt(quote, collateral, 0); // likewise a zero price: par is the cheapest thing to name
        p.inventoryAsk = true; // the fill fee above is admitted only beside the ask
    }

    function setUp() public {
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
    }

    /// @notice Every library the hub links deploys in its own transaction, each far under the cap.
    function test_EveryLibraryDeploy_UnderCap() public {
        uint256 total;
        // WAS `LadderWalks` and `Token` as well: the draw walk and the receipt ledger are both deleted
        total += _assertUnderCap("Orders.sol:Orders");
        total += _assertUnderCap("MarketInit.sol:MarketInit");
        total += _assertUnderCap("Deleverage.sol:Deleverage");
        total += _assertUnderCap("Settlement.sol:Settlement");
        total += _assertUnderCap("Borrower.sol:Borrower");
        total += _assertUnderCap("Lender.sol:Lender");
        // summed only to show what the split buys: one bundled deploy tx would sit against the cap
        emit log_named_uint("all libraries, summed", total);
    }

    /// @notice The hub itself deploys under the cap, once, ever.
    /// @dev The hub refuses a PositionManager bound to another hub, so this needs its own PAIR.
    /// @dev The positionManager is built OUTSIDE the gas window: only the hub's own deploy is measured.
    function test_AceDeploy_UnderCap() public {
        PositionManager e = new PositionManager(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        uint256 g = gasleft();
        ace = new Ace(AceFixtures.TREASURY, address(e), AceFixtures.PUSH_GAS);
        uint256 used = g - gasleft();
        emit log_named_uint("Ace deploy", used);
        assertLt(used, CAP, "Ace deploy under Base cap");
    }

    /// @notice The positionManager deploys under the cap in its own transaction.
    /// @dev It is the one custodian for every market, so its size is a permanent bound and not a per-market one.
    /// @dev Retargeted from the deleted `EscrowFactory`, which carried the positionManager's code for the same reason.
    function test_EscrowDeploy_UnderCap() public {
        uint256 g = gasleft();
        PositionManager e = new PositionManager(address(this));
        uint256 used = g - gasleft();
        emit log_named_uint("PositionManager deploy", used);
        assertLt(used, CAP, "PositionManager deploy under Base cap");
        assertLt(address(e).code.length, 24_576, "PositionManager runtime under EIP-170");
    }

    /// @notice THE singleton thesis in its strongest form: creating a market deploys NOTHING, anywhere.
    /// @dev The nonces are the direct witness -- an account's nonce moves only on CREATE.
    /// @dev Both are checked, because the old design moved the deploy off the hub rather than deleting it.
    /// @dev Custody is a LEDGER fact now, one pot per collateral, so there is no template left to mint.
    function test_CreateMarket_DeploysNothingAnywhere() public {
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY);
        MockToken quote = new MockToken(6);
        MockToken collateral = new MockToken(18);

        uint64 hubNonceBefore = vm.getNonce(address(ace));
        uint64 escrowNonceBefore = vm.getNonce(address(positionManager));
        MarketParams memory p = _params(address(quote), address(collateral));

        uint256 g = gasleft();
        bytes32 id = ace.createMarket(p);
        uint256 used = g - gasleft();

        emit log_named_uint("createMarket", used);
        assertLt(used, CAP, "createMarket under Base cap");
        assertEq(vm.getNonce(address(ace)), hubNonceBefore, "the HUB deployed no code");
        assertEq(vm.getNonce(address(positionManager)), escrowNonceBefore, "and neither did the custodian");
        assertEq(ace.idToMarketParams(id).quote, address(quote), "id resolves to the params it was made from");
        assertEq(id, keccak256(abi.encode(p)), "the id IS the hash of the params");

        // a market on a BRAND NEW collateral is the case the old template deploy existed for
        MarketParams memory p2 = _params(address(new MockToken(6)), address(new MockToken(18)));
        ace.createMarket(p2);
        assertEq(vm.getNonce(address(positionManager)), escrowNonceBefore, "a fresh collateral deploys nothing either");

        vm.expectRevert(MarketExists.selector); // the same params address the same market, once
        ace.createMarket(p);
    }

    /// @notice One deployment serves every pair: a second market on different tokens is another write.
    function test_SecondMarket_DifferentPair_SameDeployment() public {
        (ace, positionManager) = AceFixtures.newAceWithEscrow(AceFixtures.TREASURY); // a hub and ITS positionManager
        MockToken quoteA = new MockToken(6);
        MockToken collA = new MockToken(18);
        MockToken quoteB = new MockToken(18);
        MockToken collB = new MockToken(18);

        bytes32 idA = ace.createMarket(_params(address(quoteA), address(collA)));

        uint64 nonceBefore = vm.getNonce(address(ace));
        MarketParams memory pB = _params(address(quoteB), address(collB));
        uint256 g = gasleft();
        bytes32 idB = ace.createMarket(pB);
        uint256 used = g - gasleft();

        emit log_named_uint("createMarket #2", used);
        assertLt(used, CAP / 10, "second market is a storage write too");
        assertEq(vm.getNonce(address(ace)), nonceBefore, "still no code deployed");
        assertTrue(idA != idB, "different params address different markets");
        assertEq(ace.idToMarketParams(idB).collateral, address(collB), "second pair resolves");
    }
}
