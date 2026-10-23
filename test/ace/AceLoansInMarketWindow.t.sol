// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {PositionTitleNFT} from "../../src/ace/positions/PositionTitleNFT.sol";
import {MarketParams, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockHookERC20, ITokenReceiveHook} from "../mocks/MockHookERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";

/// @notice A borrower that reads the hub from INSIDE a token-transfer callback: mid-open and mid-close.
/// @notice Every snapshot is state a counterparty could see and a test cannot reach from the outside.
/// @dev `watched` is set BEFORE the hub call: the id must be known while its own transaction is in flight.
contract WindowProbe is ITokenReceiveHook {
    Ace public immutable ACE;
    PositionTitleNFT public immutable POSITION_TITLE;
    bytes32 public market;
    uint256 public watched;

    struct Snap {
        address titled; // borrowerOf: the storage of record, written in _record
        bool ownerAnswered; // did ownerOf return rather than revert
        address owner; // ...and what it said
        uint256 listLength; // marketLoansLength: must never shrink, mid-call or otherwise
    }

    Snap[] public snaps;

    constructor(Ace ace) {
        ACE = ace;
        POSITION_TITLE = PositionTitleNFT(ace.POSITION_TITLE());
    }

    function snapCount() external view returns (uint256) {
        return snaps.length;
    }

    function snapAt(uint256 i) external view returns (Snap memory) {
        return snaps[i];
    }

    function arm(bytes32 mid, address quote, address collateral, address positionManager) external {
        market = mid;
        IERC20(collateral).approve(positionManager, type(uint256).max);
        IERC20(quote).approve(address(ACE), type(uint256).max);
    }

    /// @param expectedId The id this open will allocate, so the callback can name a loan still being created.
    function doOpen(uint256 units, uint256 principal, uint256 expectedId) external returns (uint256 id) {
        watched = expectedId;
        id = ACE.open(market, units, principal, 0, address(this), OpenBounds(0, 0, 0));
        require(id == expectedId, "probe: id prediction wrong");
    }

    function doRepay(uint256 id, uint256 amount) external {
        watched = id;
        ACE.repay(id, amount);
    }

    /// @dev The close CREDITS rather than pushes, so the post-close payout window is the CLAIM's.
    /// @dev That is where an external call now straddles a loan whose `closed` flag is already set.
    function doClaim(uint256 id) external {
        watched = id;
        ACE.claimOwed(id, address(this));
    }

    /// @dev Fired by the hooking token AFTER balances settle, so this sees what a real recipient sees.
    /// @dev Never reverts: a revert would unwind the mid-interaction state the probe exists to observe.
    function onTokenReceived(address, uint256) external override {
        uint256 id = watched;
        bool answered;
        address who;
        try POSITION_TITLE.ownerOf(id) returns (address o) {
            answered = true;
            who = o;
        } catch {
            answered = false;
        }
        snaps.push(Snap({titled: ACE.borrowerOf(id), ownerAnswered: answered, owner: who, listLength: ACE.marketLoansLength(market)}));
    }
}

/// @title AceLoansInMarketWindowTest
/// @notice What a mid-transaction observer sees, in two properties.
/// @notice The NFT must exist by the time the hub's own title answers (I8).
/// @notice The append-only list must never shrink, at rest or while a close is still in flight.
/// @dev WHY A HOOKING TOKEN: with a plain ERC20 these paths have no reentrancy window at all.
/// @dev The exposure is REAL but CONDITIONAL on the market's collateral or quote carrying a hook.
/// @dev The mid-close membership-vs-closed hazard is absent, not untested: append-only deleted it.
contract AceLoansInMarketWindowTest is Test {
    Ace internal ace;
    AceReader internal read;
    PositionManager internal positionManager;
    MockPersistenceRecord internal record;
    MockHookERC20 internal usdc;
    MockHookERC20 internal coll;
    WindowProbe internal probe;
    bytes32 internal id_;

    address internal alice = address(0xA11CE);

    uint256 constant COLL = 10_000e18;
    uint256 constant PRINCIPAL = 4_500e6;

    uint256 internal T3; // ticks above this pair's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T4; // the rung above T3

    /// @dev This suite's pair, so a tick reads as its distance from par rather than as a grid coordinate.
    /// @param offset Ticks above par.
    /// @return The absolute grid tick.
    function _price(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(coll), offset);
    }

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockHookERC20("USD Coin", "USDC", 6);
        coll = new MockHookERC20("Collateral", "COLL", 18);
        (T3, T4) = (_price(480), _price(960));
        record = new MockPersistenceRecord(address(usdc), address(coll));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(coll)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(coll)));

        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(coll));
        p.record = address(record);

        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, id_) = (d.ace, d.positionManager, d.read, d.id);

        probe = new WindowProbe(ace);
        probe.arm(id_, address(usdc), address(coll), address(positionManager));

        // the hook fires only on transfers TO the probe: the open payout and the close release
        usdc.setHookTarget(address(probe));
        coll.setHookTarget(address(probe));

        usdc.mint(alice, 40_000e6);
        vm.startPrank(alice);
        usdc.approve(address(ace), 40_000e6);
        ace.deposit(id_, 20_000e6);
        ace.deposit(id_, 20_000e6);
        vm.stopPrank();

        coll.mint(address(probe), 10 * COLL);
        usdc.mint(address(probe), 10_000e6);
    }

    /// @notice I8 (M4). In `open`'s external tail the loan is recorded, listed and announced by `Opened`.
    /// @notice So the NFT must exist by then: minted later, `ownerOf` reverts while `borrowerOf` answers.
    function test_I8_MidOpen_TitledImpliesTheNftExists() public {
        uint256 id = probe.doOpen(COLL, PRINCIPAL, 1);

        uint256 n = probe.snapCount();
        assertGt(n, 0, "the principal payout must have fired the hook mid-open");

        uint256 checked;
        for (uint256 i; i < n; i++) {
            WindowProbe.Snap memory s = probe.snapAt(i);
            if (s.titled == address(0)) continue; // not yet recorded: nothing is claimed about the NFT
            checked++;
            assertTrue(s.ownerAnswered, "I8: once the hub is titled, ownerOf must not revert");
            assertEq(s.owner, s.titled, "and the two ledgers must name the same holder");
        }
        assertGt(checked, 0, "VACUOUS: no snapshot caught the hub already titled, so nothing was proved");

        assertEq(ace.borrowerOf(id), address(probe), "settled state agrees once the call returns");
    }

    /// @notice The append-only guard, asserted from INSIDE the close.
    /// @dev `closeClean` writes `Loan.closedAt` and then releases collateral, which is an external call.
    /// @dev A removal placed around that call shows up as a shrunken list, whichever side it lands on.
    function test_ListNeverShrinksMidClose() public {
        uint256 id = probe.doOpen(COLL, PRINCIPAL, 1);
        uint256 before = probe.snapCount();
        uint256 lenBefore = ace.marketLoansLength(id_);
        assertEq(lenBefore, 1, "one entry after the open");

        uint256 debt = read.loan(id).debt;
        usdc.mint(address(probe), debt);
        probe.doRepay(id, debt);
        probe.doClaim(id); // the close credits; the CLAIM is the external call that straddles a closed loan

        uint256 n = probe.snapCount();
        assertGt(n, before, "the credited payout must have fired the hook on a closed loan");
        for (uint256 i = before; i < n; i++) {
            assertEq(probe.snapAt(i).listLength, lenBefore, "the list must not shrink mid-close");
        }

        assertTrue(ace.isClosed(id), "closed once the call returns");
        assertEq(ace.marketLoansLength(id_), lenBefore, "and it did not shrink afterwards either");
    }

    /// @notice The same guard on settlement, which makes three positionManager releases rather than one.
    /// @dev The three: the keeper sliver, the market's cover, and the borrower residual.
    function test_ListNeverShrinksMidFinalize() public {
        probe.doOpen(COLL, PRINCIPAL, 1);
        uint256 before = probe.snapCount();
        uint256 lenBefore = ace.marketLoansLength(id_);

        record.setBelow(true);
        ace.finalize(1);
        probe.doClaim(1);

        uint256 n = probe.snapCount();
        for (uint256 i = before; i < n; i++) {
            assertEq(probe.snapAt(i).listLength, lenBefore, "settlement must not shrink the list either");
        }
        assertEq(ace.marketLoansLength(id_), lenBefore, "nor afterwards");
    }

    /// @notice The anti-vacuity guard `test_ListNeverShrinksMidFinalize` is missing.
    /// @dev That test's only real work happens inside `for (i = before; i < n)`.
    /// @dev With no callback the body never runs and it passes having proved nothing.
    /// @dev Demonstrated: deleting `M.openedLoans.push` leaves it green while ten siblings fail.
    /// @dev This asserts the premise separately, so the window is proved open, not assumed.
    function test_MidFinalize_TheHookGenuinelyFires() public {
        probe.doOpen(COLL, PRINCIPAL, 1);
        uint256 before = probe.snapCount();
        uint256 lenBefore = ace.marketLoansLength(id_);
        assertEq(lenBefore, 1, "there is a list entry to shrink in the first place");

        record.setBelow(true);
        ace.finalize(1);
        assertEq(probe.snapCount(), before, "settlement itself makes NO external collateral call any more");
        probe.doClaim(1);

        assertGt(probe.snapCount(), before, "the credited residual delivers to the probe on the pull");
        assertTrue(ace.isClosed(1), "and the loan is settled once the call returns");
    }

    /// @notice The mid-close window observes the LIST; this observes the TITLE across the same window.
    /// @dev A close must not orphan the position: `ownerOf` answers throughout and keeps answering.
    /// @dev What a closed loan still owes resolves its destination through exactly this read.
    function test_MidClose_TitleAndNftStayInLockstep() public {
        uint256 id = probe.doOpen(COLL, PRINCIPAL, 1);
        uint256 before = probe.snapCount();

        uint256 debt = read.loan(id).debt;
        usdc.mint(address(probe), debt);
        probe.doRepay(id, debt);
        probe.doClaim(id);

        uint256 n = probe.snapCount();
        assertGt(n, before, "the credited payout must have fired the hook on a closed loan");
        uint256 checked;
        for (uint256 i = before; i < n; i++) {
            WindowProbe.Snap memory s = probe.snapAt(i);
            assertTrue(s.ownerAnswered, "the NFT must never vanish mid-close");
            assertEq(s.owner, address(probe), "and it must still name the holder");
            assertEq(s.titled, address(probe), "as must the hub's own title");
            checked++;
        }
        assertGt(checked, 0, "VACUOUS: no mid-close snapshot was inspected");
    }
}
