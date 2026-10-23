// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPersistenceRecord} from "../../src/interfaces/IPersistenceRecord.sol";

/// @notice The multi-pair fixture proving the pair-parameterized interface is sufficient: one deployment, N registered pairs, settable per pair.
/// @notice It implements ONLY the pair-taking forms, so a call site bound to a zero-arg legacy form fails to compile against it.
/// @dev Mirrors the shipped records' posture: an UNREGISTERED pair reverts (wiring bug, loud), a registered pair with dead answers returns 0/false.
contract MockMultiPairRecord is IPersistenceRecord {
    error UnregisteredPair();

    struct PairState {
        bool registered;
        bool below;
        bool above;
        uint256 observed;
        uint256 minPrice;
    }

    mapping(bytes32 => PairState) internal _pairs;

    function _key(address quote, address collateral) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(quote, collateral));
    }

    /// @notice Register a pair; minPrice starts FINITE, matching MockPersistenceRecord's default.
    /// @notice `max` is the no-record sentinel, so a registered pair must never start there.
    function registerPair(address quote, address collateral) external {
        PairState storage s = _pairs[_key(quote, collateral)];
        s.registered = true;
        s.minPrice = 2e18;
    }

    function setBelow(address quote, address collateral, bool v) external {
        _pairs[_key(quote, collateral)].below = v;
    }

    function setAbove(address quote, address collateral, bool v) external {
        _pairs[_key(quote, collateral)].above = v;
    }

    function setObserved(address quote, address collateral, uint256 v) external {
        _pairs[_key(quote, collateral)].observed = v;
    }

    function setMinPrice(address quote, address collateral, uint256 v) external {
        _pairs[_key(quote, collateral)].minPrice = v;
    }

    /// @notice Per-pair feed death: every read answers closed while the pair stays registered.
    function setDead(address quote, address collateral) external {
        PairState storage s = _pairs[_key(quote, collateral)];
        s.below = false;
        s.above = false;
        s.observed = 0;
        s.minPrice = 0;
    }

    function _state(address quote, address collateral) internal view returns (PairState storage s) {
        s = _pairs[_key(quote, collateral)];
        if (!s.registered) revert UnregisteredPair();
    }

    function supportsPair(address quote, address collateral) external view returns (bool) {
        return _pairs[_key(quote, collateral)].registered;
    }

    function persistedBelowDistress(address quote, address collateral, uint256) external view returns (bool) {
        return _state(quote, collateral).below;
    }

    function persistedBelowSettle(address quote, address collateral, uint256) external view returns (bool) {
        return _state(quote, collateral).below;
    }

    /// @dev NOT an interface member any more; kept public because the lens still probes it by signature.
    function persistedAbove(address quote, address collateral, uint256) external view returns (bool) {
        return _state(quote, collateral).above;
    }

    function lastObserved(address quote, address collateral) external view virtual returns (uint256) {
        return _state(quote, collateral).observed;
    }

    function minPrice(address quote, address collateral) external view virtual returns (uint256) {
        return _state(quote, collateral).minPrice;
    }

    function DEPTH_WINDOW() external pure returns (uint256) {
        return 0;
    }
}
