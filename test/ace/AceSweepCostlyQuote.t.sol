// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice An HONEST quote whose transfer to one address costs a fixed amount of gas: `laps` fresh SSTOREs, then a normal move.
/// @dev Nothing fails and nothing lies; the transfer is only dear, the shape a capped push cannot fund and an uncapped one can.
contract CostlyQuote {
    string public name = "Costly";
    string public symbol = "CST";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public costlyTo; // the one recipient a transfer is dear to
    uint256 public laps; // fresh slots written per dear transfer, ~22,100 gas each
    uint256 private _next = 1e9; // the first slot the next dear transfer writes, so every lap is a zero-to-nonzero store

    function setCost(address to, uint256 n) external {
        (costlyTo, laps) = (to, n);
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (to == costlyTo) _spend();
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }

    function _spend() private {
        uint256 s = _next;
        uint256 n = laps;
        for (uint256 i; i < n; i++) {
            assembly {
                sstore(add(s, i), 1)
            }
        }
        _next = s + n;
    }
}

/// @title AceSweepCostlyQuote
/// @notice Run 251533 Y-4: a quote whose treasury transfer costs over `PUSH_GAS`, the premise the uncapped `sweepRevenue` answers.
/// @notice `AceRevenuePot.test_CostlyQuoteSweepsUncapped` pins that the sweep delivers such a quote's whole pot.
/// @dev The quote is honest and dear only to the treasury, so the lender's push at the close is the ordinary cheap one.
contract AceSweepCostlyQuoteTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    CostlyQuote internal quote;
    MockERC20 internal coll;
    bytes32 internal id;
    uint256 internal loanId;

    address internal treasury = address(0x7EA5);
    address internal alice = AceFixtures.LENDER;
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal constant P = 10_000e6;
    uint256 internal constant UNITS = 100_000e18;
    uint256 internal constant LAPS = 6; // ~133k of stores, a third over the 100k budget

    function setUp() public {
        _warpTo(1_000_000);
        quote = new CostlyQuote();
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(quote), address(coll));
        AceFixtures.Deployment memory d = AceFixtures.deployWithTreasury(p, treasury);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        quote.mint(alice, 2 * P);
        vm.startPrank(alice);
        quote.approve(address(ace), 2 * P);
        ace.deposit(id, 2 * P);
        vm.stopPrank();
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
        quote.setCost(treasury, LAPS);
    }

    /// @notice PREMISE: a transfer to the treasury costs more than the push budget, measured outside the hub.
    function test_Premise_ATreasuryTransferCostsOverThePushBudget() public {
        quote.mint(address(this), 1);
        uint256 g = gasleft();
        quote.transfer(treasury, 1);
        uint256 used = g - gasleft();
        emit log_named_uint("a dear transfer to the treasury costs", used);
        assertGt(used, ace.PUSH_GAS(), "the transfer fits the budget, so the row proves nothing about the cap");
    }
}
