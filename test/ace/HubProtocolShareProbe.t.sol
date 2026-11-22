// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {HubProtocolShare} from "../../src/interfaces/HubProtocolShare.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPeriodHub, MockRawAnswerHub, MockRevertingYearHub} from "../mocks/MockRatePeriodAnswers.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @dev The library behind an external call, so a row reads its answer as a product would.
contract ShareProbeHarness {
    function shareOf(address hub) external view returns (uint256) {
        return HubProtocolShare.shareOf(hub);
    }
}

/// @title HubProtocolShareProbe
/// @notice What an off-hub product reads as a hub's origination share: the hub's own answer, or the ceiling where it gives none.
/// @notice A hub that predates the view charged the ceiling as a constant, so reading the ceiling there IS reading the truth.
/// @dev Every failure reads 1000, never zero: a product that under-read the share would quote a fee the hub then refuses or over-charges.
contract HubProtocolShareProbeTest is Test {
    uint256 internal constant MAX = 1000; // re-spelled ceiling
    uint256 internal constant YEAR = 31_536_000;
    ShareProbeHarness internal h;

    function setUp() public {
        h = new ShareProbeHarness();
    }

    function _hub() internal returns (Ace ace, bytes32 id) {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockStakeVault vault = new MockStakeVault(42);
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(vault));
        p.record = address(new MockPersistenceRecord(address(usdc), address(vault)));
        p.lenderAprBps = 2086;
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, id) = (d.ace, d.id);
    }

    /// @notice This tree's hub is read live, at every share the treasury can set.
    function testFuzz_TheLiveHubIsReadAtItsShare(uint256 s) public {
        s = bound(s, 0, MAX);
        (Ace ace,) = _hub();
        assertEq(h.shareOf(address(ace)), MAX, "a fresh hub reads its ceiling");
        vm.prank(AceFixtures.TREASURY);
        ace.setProtocolShareBps(s);
        assertEq(h.shareOf(address(ace)), s, "and the share the treasury set");
    }

    /// @notice A hub with no share view is one that charged the ceiling as a constant.
    function test_AHubWithoutTheViewReadsTheCeiling() public {
        assertEq(h.shareOf(address(new MockPeriodHub(YEAR))), MAX, "no view");
        assertEq(h.shareOf(address(new MockRevertingYearHub())), MAX, "a revert is never read as an answer");
    }

    function test_NoCodeReadsTheCeiling() public {
        assertEq(h.shareOf(address(0)), MAX, "the zero address");
        assertEq(h.shareOf(makeAddr("no code")), MAX, "an account with no code");
    }

    /// @notice One full word inside the ceiling is taken as it stands; anything else reads the ceiling.
    function test_OnlyAWholeWordInsideTheCeilingIsTaken() public {
        assertEq(h.shareOf(address(new MockRawAnswerHub(abi.encode(uint256(400))))), 400, "a word inside the ceiling");
        assertEq(h.shareOf(address(new MockRawAnswerHub(abi.encode(uint256(0))))), 0, "zero is a real share");
        assertEq(h.shareOf(address(new MockRawAnswerHub(abi.encode(uint256(1001))))), MAX, "a word over the ceiling");
        assertEq(h.shareOf(address(new MockRawAnswerHub(abi.encode(type(uint256).max)))), MAX, "the largest word");
        assertEq(h.shareOf(address(new MockRawAnswerHub(""))), MAX, "an empty success");
        assertEq(h.shareOf(address(new MockRawAnswerHub(abi.encodePacked(uint248(400))))), MAX, "a short answer");
    }

    /// @notice The lens quotes the borrower's all-in at the hub's LIVE share.
    function test_TheLensQuotesTheLiveShare() public {
        (Ace ace, bytes32 id) = _hub();
        AceLens lens = new AceLens(address(ace));
        (uint256 lender, uint256 allIn) = lens.rateBps(id);
        assertEq(lender, 2086, "the lender's rate");
        assertEq(allIn, 2294, "at the ceiling: 2086 * 1.1, truncated");

        vm.prank(AceFixtures.TREASURY);
        ace.setProtocolShareBps(500);
        (, allIn) = lens.rateBps(id);
        assertEq(allIn, 2190, "at 500: 2086 * 1.05, truncated");

        vm.prank(AceFixtures.TREASURY);
        ace.setProtocolShareBps(0);
        (, allIn) = lens.rateBps(id);
        assertEq(allIn, 2086, "at zero the borrower pays the lender's rate");
    }
}
