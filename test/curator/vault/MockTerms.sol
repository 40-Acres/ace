// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketParams, OpenBounds} from "../../../src/ace/hub/Types.sol";
import {IAceLenderOps} from "../../../src/interfaces/IAceLenderOps.sol";
import {Extension} from "../../../src/interfaces/IRollPolicy.sol";
import {IVaultTerms, Lend, RefinanceRequest} from "../../../src/interfaces/IVaultTerms.sol";
import {BorrowRequest, Terms} from "../../../src/curator/AceVaultFlows.sol";

/// @notice A product whose every answer a row sets, and which can turn hostile on any view: revert, burn its gas, bomb, or answer a malformed word.
/// @dev Its write calls can re-enter any address with any calldata, and record what the re-entry met; they never revert themselves.
/// @dev `beforeLend` also records the hub's resting cash in the market, and may try `hub.open` there as a borrower of its own.
contract MockTerms is IVaultTerms {
    enum Mode {
        Answer,
        Revert,
        BurnGas,
        ReturnBomb,
        ShortWord,
        LongWord,
        BadWord,
        ReadHub,
        Nav
    }

    address public immutable VAULT;
    address public immutable ACE;

    MarketParams internal _mp;
    Terms internal _t;
    uint256 public roomAnswer = type(uint256).max;
    uint256 public capAnswer = type(uint256).max;
    bool public consent = true;
    Mode public roomMode;
    Mode public capMode;
    Mode public consentMode;
    address public refusedBorrower;
    address public shut; // the one receiver the entry cap answers zero for, whatever its mode

    address public reenterTarget;
    bytes public reenterData;
    bool public reenterBefore;
    bool public reenterAfter;
    bool public reentered;
    bool public reentryOk;
    bytes public reentryError;

    bool public tryOpen;
    bool public openOk;
    uint256 public restingAtBefore = type(uint256).max;
    uint256 public beforeCalls;
    uint256 public afterCalls;
    address public lastHolder;
    uint256 public lastLoanId;

    error Refused();

    constructor(address vault, address ace) {
        (VAULT, ACE) = (vault, ace);
    }

    function setTerms(MarketParams calldata mp, Terms calldata t) external {
        (_mp, _t) = (mp, t);
    }

    function setRoom(Mode m, uint256 answer) external {
        (roomMode, roomAnswer) = (m, answer);
    }

    function setEntryCap(Mode m, uint256 answer) external {
        (capMode, capAnswer) = (m, answer);
    }

    function setConsent(Mode m, bool yes) external {
        (consentMode, consent) = (m, yes);
    }

    function setRefusedBorrower(address who) external {
        refusedBorrower = who;
    }

    function setShut(address who) external {
        shut = who;
    }

    /// @dev Arm a re-entry from either write call; the call it makes is recorded, never bubbled.
    function setReentry(address target, bytes calldata data, bool before_, bool after_) external {
        (reenterTarget, reenterData, reenterBefore, reenterAfter) = (target, data, before_, after_);
        (reentered, reentryOk, reentryError) = (false, false, "");
    }

    function setTryOpen(bool on) external {
        tryOpen = on;
    }

    function borrowTerms(address borrower, BorrowRequest calldata, bytes calldata) external view returns (MarketParams memory, Terms memory) {
        if (borrower != address(0) && borrower == refusedBorrower) revert Refused();
        return (_mp, _t);
    }

    function refinanceTerms(address, uint256, RefinanceRequest calldata, bytes calldata) external view returns (MarketParams memory, Terms memory) {
        return (_mp, _t);
    }

    function admitsExtension(Extension calldata e, bytes calldata) external view returns (bool) {
        return _word(consentMode, consent ? 1 : 0, e.dst.quote, 0) == 1;
    }

    function room(MarketParams calldata mp) external view returns (uint256) {
        return _word(roomMode, roomAnswer, mp.quote, 0);
    }

    function entryCap(address receiver, uint256 nav) external view returns (uint256) {
        if (receiver != address(0) && receiver == shut) return 0;
        return _word(capMode, capAnswer, address(0), nav);
    }

    function beforeLend(Lend, MarketParams calldata mp, uint256, bytes calldata) external {
        beforeCalls++;
        restingAtBefore = IAceLenderOps(ACE).restingOf(keccak256(abi.encode(mp)));
        if (tryOpen) {
            try IAceLenderOps(ACE).open(keccak256(abi.encode(mp)), 0, mp.minPrincipal, 0, address(this), OpenBounds(0, 0, 0)) {
                openOk = true;
            } catch {
                openOk = false;
            }
        }
        if (reenterBefore) _reenter();
    }

    function afterLend(Lend, MarketParams calldata, uint256 loanId, address holder, bytes calldata) external {
        afterCalls++;
        (lastLoanId, lastHolder) = (loanId, holder);
        if (reenterAfter) _reenter();
    }

    function _reenter() private {
        (bool ok, bytes memory err) = reenterTarget.call(reenterData);
        (reentered, reentryOk, reentryError) = (true, ok, err);
    }

    /// @dev One word in the row's mode; every hostile mode leaves this frame by assembly, so nothing past it runs.
    function _word(Mode m, uint256 answer, address quote, uint256 nav) private view returns (uint256) {
        if (m == Mode.Revert) revert Refused();
        if (m == Mode.BurnGas) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        if (m == Mode.ReturnBomb) {
            uint256 size = Math.sqrt(gasleft() * 460) * 32; // memory a quadratic cost of ~90% of what is left buys, so the CALLER cannot copy it
            assembly {
                return(0, size)
            }
        }
        if (m == Mode.ShortWord) {
            assembly {
                mstore(0, answer)
                return(0, 31)
            }
        }
        if (m == Mode.LongWord) {
            assembly {
                mstore(0, answer)
                mstore(0x20, answer)
                return(0, 64)
            }
        }
        if (m == Mode.BadWord) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (m == Mode.ReadHub) IAceLenderOps(ACE).lenderAssets(VAULT, quote == address(0) ? address(1) : quote);
        if (m == Mode.Nav) return nav;
        return answer;
    }
}
