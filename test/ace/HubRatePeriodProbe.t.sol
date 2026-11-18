// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {HubHasNoCode, HubRateNotPerYear, HubRatePeriod} from "../../src/interfaces/HubRatePeriod.sol";
import {MockPerTermHub} from "../mocks/MockRatePeriodHubs.sol";
import {MockPeriodHub, MockRawAnswerHub, MockRevertingYearHub} from "../mocks/MockRatePeriodAnswers.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";

/// @dev The library behind an external call, so a row can expect its revert by selector.
contract RatePeriodHarness {
    /// @notice True when `hub` passes the probe; the probe's own revert otherwise.
    function check(address hub) external view returns (bool) {
        HubRatePeriod.requirePerYear(hub);
        return true;
    }
}

/// @title HubRatePeriodProbe
/// @notice The probe every product constructor runs on the hub it binds: it passes exactly one answer, 31,536,000, and nothing near it.
/// @notice A revert, a short answer and an empty success are refusals by the unit's name; an address with no code is refused by its own.
/// @dev The products' rows ask it about a hub with no getter and one naming a month; these rows ask about the answers between.
/// @dev Any contract answering one full word of a year passes: the probe checks the unit, and the scripts' fleet fence names the hub.
contract HubRatePeriodProbeTest is Test {
    uint256 internal constant YEAR = 31_536_000; // 365 days, spelled as a literal so the oracle is not the library's constant
    RatePeriodHarness internal h;

    function setUp() public {
        h = new RatePeriodHarness();
    }

    function _refused(address hub, bytes4 err) internal {
        vm.expectRevert(err);
        h.check(hub);
    }

    /// @notice ONLY EXACTLY A YEAR PASSES: this tree's hub and a stand-in answering 31,536,000 bind; one second either side does not.
    /// @dev Killed: any compare looser than equality, `period == 0` for "names a period" or `period < YEAR` for "at least a year" alike.
    function test_OnlyExactlyOneYearPasses() public {
        assertTrue(h.check(address(AceFixtures.newAce())), "this tree's hub answers a year");
        assertTrue(h.check(address(new MockPeriodHub(YEAR))), "and so does a stand-in answering 31,536,000");
        _refused(address(new MockPeriodHub(YEAR - 1)), HubRateNotPerYear.selector);
        _refused(address(new MockPeriodHub(YEAR + 1)), HubRateNotPerYear.selector);
        _refused(address(new MockPeriodHub(366 days)), HubRateNotPerYear.selector);
        _refused(address(new MockPeriodHub(7 days)), HubRateNotPerYear.selector);
        _refused(address(new MockPeriodHub(0)), HubRateNotPerYear.selector);
        _refused(address(new MockPeriodHub(type(uint256).max)), HubRateNotPerYear.selector);
    }

    /// @notice A REVERT IS NEVER READ AS AN ANSWER, not even one whose revert data is the year itself.
    function test_ARevertIsNeverReadAsAnAnswer() public {
        _refused(address(new MockPerTermHub()), HubRateNotPerYear.selector);
        _refused(address(new MockRevertingYearHub()), HubRateNotPerYear.selector);
    }

    /// @notice A SUCCESS THAT SAYS LESS THAN ONE WORD IS A REFUSAL BY THE UNIT'S NAME: an empty answer, and the year packed into 31 bytes.
    /// @dev A hub with a fallback that returns nothing is the shape a per-`minTenor` hub with a no-op fallback would have.
    function test_AShortAnswerIsARefusal() public {
        _refused(address(new MockRawAnswerHub("")), HubRateNotPerYear.selector);
        _refused(address(new MockRawAnswerHub(abi.encodePacked(uint248(YEAR)))), HubRateNotPerYear.selector);
        assertTrue(h.check(address(new MockRawAnswerHub(abi.encode(YEAR)))), "CONTROL: one full word passes, so the probe checks the unit, never the hub");
    }

    /// @notice NO CODE IS ITS OWN REFUSAL, named apart from the unit's: the zero address and an account with no code.
    /// @dev Killed: dropping the code check, which lets the probe's failure answer for it under the unit's name.
    function test_NoCodeIsRefusedByItsOwnName() public {
        _refused(address(0), HubHasNoCode.selector);
        _refused(address(0xDEAD), HubHasNoCode.selector);
        _refused(makeAddr("an account with no code"), HubHasNoCode.selector);
    }
}
