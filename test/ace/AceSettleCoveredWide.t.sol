// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {Constants} from "../../src/ace/hub/Constants.sol";
import {MarketParams, OpenBounds, Storage} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @title AceSettleCoveredWide
/// @notice #738 C-16, pinned directly: settlement values the delivered units in 512 bits, so a claim past ~2^160 settles.
/// @notice The plain `give * price` wraps once the product passes 2^256 and the close reverts Panic; `mulDiv` does not.
/// @dev No flow reaches such a claim in a test's budget (it takes ~2^32 home refinances at the cash cap), so the claim is STORED.
/// @dev At the price ceiling `2^224` the frame divides exactly, `covered = give * 2^128`, so every expected value is closed-form.
contract AceSettleCoveredWideTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal coll;
    bytes32 internal id;
    uint256 internal loanId;

    address internal alice = AceFixtures.LENDER;
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCAFE);

    uint256 internal constant P = 1_000e6;
    uint256 internal constant UNITS = 1 << 40; // so `UNITS * MAX_PRICE` is 2^264, past a word
    uint256 internal constant CLAIM = 1 << 170; // need `ceil(2^170 * 2^96 / 2^224)` is 2^42, over the lot

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll)); // recordless: settles at tenor
        p.price = Constants.MAX_PRICE;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, id) = (d.ace, d.positionManager, d.read, d.id);
        usdc.mint(alice, P);
        vm.startPrank(alice);
        usdc.approve(address(ace), P);
        ace.deposit(id, P);
        vm.stopPrank();
        coll.mint(borrower, UNITS);
        vm.startPrank(borrower);
        coll.approve(address(pm), UNITS);
        loanId = ace.open(id, UNITS, P, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev The pool word holding the lender's lent principal: `(lender, quote)` under the lenders root, member 1.
    function _lentSlot() internal view returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(alice, uint256(Storage.LENDERS)));
        return bytes32(uint256(keccak256(abi.encode(address(usdc), inner))) + 1);
    }

    /// @notice A claim of 2^170 against a 2^40-unit lot settles: the delivered value is `2^40 * 2^128`, the write-down the rest.
    function test_AClaimPastTwoTo160SettlesAndWritesDownExactly() public {
        uint256 lent0 = read.poolLent(id);
        assertEq(read.claimOf(id, loanId), P, "PREMISE: the open booked a claim of its principal");
        vm.store(address(ace), bytes32(read.claimSlot(id, loanId)), bytes32(CLAIM));
        vm.store(address(ace), _lentSlot(), bytes32(lent0 - P + CLAIM)); // the pool carries the claim it now books
        assertEq(read.claimOf(id, loanId), CLAIM, "PREMISE: the stored claim reads back");
        assertEq(read.poolLent(id), lent0 - P + CLAIM, "PREMISE: and so does the pool's lent leg");

        _warpTo(read.loan(loanId).expiry);
        vm.prank(keeper);
        ace.forceClose(loanId); // the plain product `2^40 * 2^224` wraps here and the close reverts Panic 0x11

        uint256 give = read.invPotOf(id, loanId);
        assertEq(give, UNITS, "the whole lot went to the claim: the sliver is zero at this price");
        uint256 covered = give << 128; // `give * 2^224 / 2^96`, exact in this frame
        (uint256 unitsShort, uint256 atBook) = read.shortfallOf(loanId);
        assertEq(unitsShort, (1 << 42) - give, "the shortfall is the need less the lot, in units");
        assertEq(atBook, CLAIM - covered, "and the write-down is the claim less the delivered value, to the atom");
        assertEq(read.marketState(id).realizedLossAtBook, CLAIM - covered, "the market's running loss carries it");
        assertEq(read.claimOf(id, loanId), 0, "the claim retired");
        assertEq(read.poolLent(id), lent0 - P, "and the pool's lent leg fell by exactly the claim it held");
    }
}
