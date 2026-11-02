// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {WarpClock} from "../utils/WarpClock.sol";
import {Ace, NoRecordPrice} from "../../src/ace/hub/Ace.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {_extended} from "../utils/Extended.sol";

interface IAceClosedV {
    function isClosed(uint256 id) external view returns (bool);
}

/// @notice Answers a healthy windowed minimum while its target loan is live and zero once it closes.
/// @dev The record twin of a self-closing gate, aimed at the OTHER creator-chosen dependency.
/// @dev A record read is a view call, so a record cannot COUNT its own reads; this one reads the hub's `closedAt` instead.
/// @dev Any record read taken after a write of that flag in the same call would get the flipped answer.
contract SelfBlindingRecord is IPersistenceRecord {
    IAceClosedV public immutable ACE;
    address public immutable QUOTE;
    address public immutable COLLATERAL;
    uint256 public immutable CAP;
    uint256 public target;

    constructor(address ace_, address quote_, address collateral_, uint256 cap_) {
        ACE = IAceClosedV(ace_);
        QUOTE = quote_;
        COLLATERAL = collateral_;
        CAP = cap_;
    }

    function setTarget(uint256 id) external {
        target = id;
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return quote == QUOTE && collateral == COLLATERAL;
    }

    function persistedBelowDistress(address, address, uint256) external pure returns (bool) {
        return false; // a healthy loan: nothing is settleable by distress
    }

    function persistedBelowSettle(address, address, uint256) external pure returns (bool) {
        return false;
    }

    /// @dev NOT an interface member any more; kept public because the lens still probes it by signature.
    function persistedAbove(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function lastObserved(address, address) external view returns (uint256) {
        return CAP;
    }

    /// @dev THE FLIP: a real windowed minimum while the loan is live, zero once it closes.
    function minPrice(address, address) external view returns (uint256) {
        return target == 0 || !ACE.isClosed(target) ? CAP : 0;
    }

    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }
}

/// @title AceP11RecordDoubleRead
/// @notice A cash extension consults the price RECORD before any write and closes nothing; `forceClose` asks the record nothing.
/// @notice A record that answers differently mid-call therefore cannot put the loan beyond every verb.
/// @notice The sibling of the same property through the GATE; a guarantee scoped to one dependency covers neither.
/// @dev Findings: docs/ai/audit/runs/2026-08-31-fab1e1/phase11-variants.md
contract AceP11RecordDoubleReadTest is WarpClock {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal pm;

    MockERC20 internal usdc; // quote, 6 decimals
    MockERC20 internal coll; // collateral, 18 decimals
    MockPersistenceRecord internal record;

    bytes32 internal midLive; // the honest twin, used only to mint the fixture params
    bytes32 internal midFlip; // the same market wired to the self-blinding record

    SelfBlindingRecord internal flip;

    address internal alice = address(0xA11CE); // the lender
    address internal borrower = address(0xB0B);

    uint256 internal TICK; // 960 ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal CAP; // the windowed minimum the record answers while the loan is live; assigned in setUp
    uint256 internal constant DEPOSIT = 5_000e6;
    uint256 internal constant PRINCIPAL = 4_500e6;
    uint256 internal constant COLL = 10_000e18;

    OpenBounds internal OFF = OpenBounds(0, 0, 0);

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        coll = new MockERC20("Collateral", "COLL", 18);
        TICK = _price(960);
        CAP = AceFixtures.px(2e18, address(usdc), address(coll));
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(coll)));
        record.setMinPrice(CAP);

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, pm, read, midLive) = (d.ace, d.positionManager, d.read, d.id);

        flip = new SelfBlindingRecord(address(ace), address(usdc), address(coll), CAP);
        MarketParams memory q = ace.idToMarketParams(midLive);
        q.record = address(flip);
        midFlip = ace.createMarket(q);
        AceFixtures.installYesPolicy(ace, alice);
        assertGt(CAP, TICK, "fixture: the answered minimum sits ABOVE the tick's book price");
    }

    /* ============ V-R1: the RECORD is the other dependency the extension must ask before it writes ============ */

    /// @notice A record whose answer turns on the loan's `closedAt` cannot put a maturing loan beyond every verb.
    /// @notice On the lender's yes the extension asks the record before any write and then lands, closing nothing, so the record never flips.
    /// @notice `forceClose` settles, and settlement asks the record nothing after `closedAt` is written, so the flip is harmless.
    /// @dev NO GATE IS WIRED HERE, so the gate leg can never be what carries this test.
    function test_P11_RecordVaryingAcrossTheExtension_SettlementStaysReachable() public {
        uint256 loanId = _loanOn(midFlip);
        flip.setTarget(loanId); // targeted AFTER the open, so entry saw an unconditional healthy answer

        assertEq(ace.idToMarketParams(midFlip).borrower, address(0), "fixture: no gate, so the gate leg cannot be the cause");

        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        (bool ok,,) = ace.tryExtend(loanId, 0, "", borrower);
        assertTrue(ok, "fixture: the extension's own predicate must admit, or the extension is never reached");

        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertTrue(_extended(read, loanId, x), "on the lender's yes the extension lands in place, closing nothing");
        assertEq(flip.minPrice(address(usdc), address(coll)), CAP, "so the record never flipped");

        vm.revertToState(snap);
        _warpTo(x);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "forceClose settles the same loan, though the record flips once the loan closes");
        assertGt(read.invPotOf(midFlip, loanId), 0, "into the lender's pot");
    }

    /// @notice The control: the same market, the same loan, with the record's flip disarmed.
    /// @dev The extension lands on a loan whose record never moves, so a failure above is the flip and not the fixture.
    function test_P11_Control_UnflippedRecord_TheExtensionCompletes() public {
        uint256 loanId = _loanOn(midFlip); // target left at zero: the record answers CAP unconditionally
        uint64 x = read.loan(loanId).expiry;
        _warpTo(uint256(x) - 1);
        vm.prank(borrower);
        ace.extend(loanId, 0, "");
        assertTrue(_extended(read, loanId, x), "control: the extension lands the loan in place");
    }

    /* ================================= fixture ================================= */

    function _lend(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev Four times the deposit, which the open draws a part of; the extension draws nothing, and its fee rides the borrower's allowance.
    function _loanOn(bytes32 mid) internal returns (uint256 loanId) {
        _lend(mid, DEPOSIT * 4);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        usdc.approve(address(ace), type(uint256).max);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OFF);
        vm.stopPrank();
    }
}
