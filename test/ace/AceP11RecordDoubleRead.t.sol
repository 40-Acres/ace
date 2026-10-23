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

/// @notice The continuation predicate, declared test-side exactly as AceP7Adversarial declares it.
interface IAceTryContinueV {
    function tryContinue(uint256 id) external view returns (bool ok, bytes4 reason, uint256 principal);
}

interface IAceAutoV {
    function setAutoRefinance(uint256 id, uint64 tenor, uint16 minBufferBps, uint16 maxFeeBps) external;
}

interface IAceClosedV {
    function isClosed(uint256 id) external view returns (bool);
}

/// @notice Answers a healthy windowed minimum while its target loan is live and zero once it closes.
/// @dev The record twin of AceFoldSingleRead's SelfClosingGate, aimed at the OTHER creator-chosen dependency.
/// @dev A record read is a view call, so a record cannot COUNT its own reads; this one reads the hub's `closedAt` instead.
/// @dev `_closeForRefinance` writes that flag mid-roll, so any record read taken after it gets the flipped answer.
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

    /// @dev THE FLIP: a real windowed minimum before the roll closes the loan, zero after it.
    function minPrice(address, address) external view returns (uint256) {
        return target == 0 || !ACE.isClosed(target) ? CAP : 0;
    }

    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }
}

/// @title AceP11RecordDoubleRead
/// @notice The armed expiry roll consults the price RECORD once, and funds the successor at that one answer.
/// @notice A record that answers differently mid-roll therefore cannot put the loan beyond every settlement verb.
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
        assertGt(CAP, TICK, "fixture: the answered minimum sits ABOVE the tick's book price");
    }

    /* ============ V-R1: the RECORD is the other dependency the roll must ask once ============ */

    /// @notice `forceCloseOrContinue` reads the record through `tryPersistedPrice`, which ABSORBS a sick answer.
    /// @notice `_closeForRefinance` writes `closedAt` inside the same call, so a record reading it can change answer.
    /// @notice An armed, expired loan must still reach a terminal state under such a record: some verb must resolve it.
    /// @dev NO GATE IS WIRED HERE, so the gate leg can never be what carries this test.
    function test_P11_ArmedLoan_RecordVaryingAcrossTheRoll_SettlementStaysReachable() public {
        uint256 loanId = _armedLoanOn(midFlip);
        flip.setTarget(loanId); // armed AFTER the open, so entry saw an unconditional healthy answer

        assertEq(ace.idToMarketParams(midFlip).borrower, address(0), "fixture: no gate, so the gate leg cannot be the cause");

        _warpTo(read.loan(loanId).expiry + 1);
        (bool ok,,) = IAceTryContinueV(address(ace)).tryContinue(loanId);
        assertTrue(ok, "fixture: the fold's own predicate must admit, or the committed roll is never reached");

        bool settled;
        try ace.finalize(loanId) {
            settled = true;
        } catch (bytes memory err) {
            emit log_named_bytes("finalize reverted with        ", err);
        }
        try ace.forceClose(loanId) {
            settled = true;
        } catch (bytes memory err) {
            emit log_named_bytes("forceClose reverted with      ", err);
            assertEq(bytes4(err), NoRecordPrice.selector, "a refusal here must be the record's own, not some other leg");
        }
        /// @dev Guarded: once a verb above settles the loan this one refuses `LoanClosed`, which proves nothing.
        if (!settled) {
            try ace.refinanceByPolicy(loanId) {
                settled = true;
            } catch (bytes memory err) {
                emit log_named_bytes("refinanceByPolicy reverted    ", err);
                assertEq(bytes4(err), NoRecordPrice.selector, "and the permissionless roll must refuse for that same reason");
            }
        }
        assertTrue(settled, "SETTLEMENT UNREACHABLE: no verb resolves an armed, expired loan whose RECORD moves mid-roll");
    }

    /// @notice The control: the same market, the same loan, with the record's flip disarmed.
    /// @dev The rig settles a loan whose record never moves, so a failure above is the flip and not the fixture.
    function test_P11_Control_UnflippedRecord_TheArmedRollCompletes() public {
        uint256 loanId = _armedLoanOn(midFlip); // target left at zero: the record answers CAP unconditionally
        _warpTo(read.loan(loanId).expiry + 1);
        ace.forceClose(loanId);
        assertTrue(ace.isClosed(loanId), "control: the armed roll retires the old loan");
    }

    /* ================================= fixture ================================= */

    function _lend(bytes32 mid, uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(ace), amt);
        ace.deposit(mid, amt);
        vm.stopPrank();
    }

    /// @dev Four times the deposit: the successor draws afresh, so the tick must still fund it after the first loan.
    function _armedLoanOn(bytes32 mid) internal returns (uint256 loanId) {
        _lend(mid, DEPOSIT * 4);
        coll.mint(borrower, COLL);
        vm.startPrank(borrower);
        coll.approve(address(pm), COLL);
        loanId = ace.open(mid, COLL, PRINCIPAL, 0, borrower, OFF);
        vm.stopPrank();
        vm.prank(borrower);
        IAceAutoV(address(ace)).setAutoRefinance(loanId, 7 days, 0, 0);
    }
}
