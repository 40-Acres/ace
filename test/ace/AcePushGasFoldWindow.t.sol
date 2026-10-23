// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BurnAllRecord} from "../mocks/UntrustedDependencyMocks.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PushGasRig} from "../utils/PushGasRig.sol";

/// @title AcePushGasFoldWindow
/// @notice `AceFoldWindow`'s A2 shape at the EIP-7825 PER-TRANSACTION CAP, 2^24, rather than a whole 30M block.
/// @notice A burning record eats 63/64 at each frame of the armed fold's predicate; the settle branch and the lender push run on what is left.
/// @dev The lender push now demands its whole budget plus the tail, so this is the row that says whether that still fits under the cap.
/// @dev The largest budget that fits is LOGGED, so a chain choosing a value inside the rail can read how far it is from the edge.
contract AcePushGasFoldWindowTest is WarpClock {
    MockERC20 internal usdc;
    MockERC20 internal coll;
    BurnAllRecord internal burnRecord;

    address internal alice = address(0xA11CE); // the lender
    address internal borrower = address(0xB0B);
    address internal keeper = address(0xCA11E5);

    uint256 internal constant TX_GAS_CAP = 1 << 24; // EIP-7825: the most gas one transaction may carry, on Ethereum and Base
    uint256 internal constant LEND = 400_000 * 32; // A2's ladder total, rested as one balance
    uint256 internal constant PRINCIPAL = 11_000_000; // A2's draw
    uint256 internal constant COLL = 10_000e18;
    uint64 internal constant TEN7 = 7 days;

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        burnRecord = new BurnAllRecord(address(usdc), address(coll));
    }

    /// @dev A fresh hub at `pushGas`, A2's armed loan on the burning-record market, run at `cap`. Snapshotted: leaves nothing behind.
    function _a2At(uint256 pushGas, uint256 cap) internal returns (bool ok, bool closed) {
        uint256 snap = vm.snapshotState();
        MarketParams memory q = AceFixtures.marketParams(address(usdc), address(coll));
        q.record = address(burnRecord);
        AceFixtures.Deployment memory d = PushGasRig.deploy(q, AceFixtures.TREASURY, pushGas);
        usdc.mint(alice, LEND);
        vm.startPrank(alice);
        usdc.approve(address(d.ace), LEND);
        d.ace.deposit(d.id, LEND);
        vm.stopPrank();
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(d.positionManager), COLL);
        uint256 loanId = d.ace.open(d.id, COLL, PRINCIPAL, TEN7, borrower, OpenBounds(0, 0, 0));
        d.ace.setAutoRefinance(loanId, TEN7, 0, 0);
        vm.stopPrank();
        _warpTo(d.read.loan(loanId).expiry + 1);
        burnRecord.setBurning(true);
        vm.prank(keeper);
        (ok,) = address(d.ace).call{gas: cap}(abi.encodeCall(Ace.forceClose, (loanId)));
        closed = d.read.loan(loanId).closedAt != 0;
        burnRecord.setBurning(false);
        vm.revertToState(snap);
    }

    /// @notice A BURNING RECORD AT THE TX GAS CAP STILL SETTLES THE ARMED FOLD, at the fixture budget and at the rail's ceiling.
    /// @dev A2 proves the 30M block; this proves the cap a real transaction lives under, where the lender floor is the new cost.
    function test_A2b_ABurningRecordAtTheTxGasCap() public {
        (bool ok, bool closed) = _a2At(PushGasRig.PUSH_GAS, TX_GAS_CAP);
        assertTrue(ok, "at the fixture budget the burning record bricks the fold at the tx gas cap");
        assertTrue(closed, "and the loan did not settle");
        (bool okMax, bool closedMax) = _a2At(PushGasRig.MAX_PUSH_GAS, TX_GAS_CAP);
        assertTrue(okMax && closedMax, "at the rail's ceiling the burning record bricks the fold at the tx gas cap");
        emit log_named_uint("every budget in the rail settles under 2^24, up to and including", PushGasRig.MAX_PUSH_GAS);
        emit log_named_uint("least tx limit that settles it, fixture budget (within 10k)", _leastCap(PushGasRig.PUSH_GAS));
        emit log_named_uint("least tx limit that settles it, rail ceiling  (within 10k)", _leastCap(PushGasRig.MAX_PUSH_GAS));
        emit log_named_uint("against the tx gas cap", TX_GAS_CAP);
    }

    /// @dev The least transaction limit at which the burning-record fold still settles, at a budget: the margin under the cap.
    function _leastCap(uint256 pushGas) internal returns (uint256 hi) {
        uint256 lo = 1_000_000;
        hi = TX_GAS_CAP;
        (bool okLo, bool closedLo) = _a2At(pushGas, lo);
        assertFalse(okLo && closedLo, "premise: the fold settles even at 1M, so there is no margin to measure");
        while (hi - lo > 10_000) {
            uint256 m = (lo + hi) / 2;
            (bool okM, bool closedM) = _a2At(pushGas, m);
            if (okM && closedM) hi = m;
            else lo = m;
        }
    }
}
