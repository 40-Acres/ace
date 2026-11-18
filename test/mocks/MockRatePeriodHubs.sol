// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice A hub as a product sees one of the per-`minTenor` generation: it has code and names no `RATE_PERIOD()`.
/// @dev Empty on purpose: no fallback, so the probe's call reverts, exactly as it does against a hub built before the getter.
contract MockPerTermHub {}

/// @notice A hub that names a rate period, but not a year: a product must refuse it as firmly as one naming none.
contract MockMonthlyHub {
    /// @notice Thirty days, the wrong answer.
    function RATE_PERIOD() external pure returns (uint256) {
        return 30 days;
    }
}

/// @notice The probe a product runs, restated for the tests: whether `hub` answers `RATE_PERIOD()` with one 365-day year.
/// @dev A raw staticcall, so a suite compiles against a hub that has no such getter.
library RatePeriodProbe {
    bytes4 internal constant NOT_PER_YEAR = bytes4(keccak256("HubRateNotPerYear()")); // the products' refusal, named by selector

    /// @notice What `hub` answers for `RATE_PERIOD()`: whether the call succeeded with one word, and that word.
    function ask(address hub) internal view returns (bool ok, uint256 period) {
        bytes memory ret;
        (ok, ret) = hub.staticcall(abi.encodeWithSignature("RATE_PERIOD()"));
        ok = ok && ret.length == 32;
        if (ok) period = abi.decode(ret, (uint256));
    }
}
