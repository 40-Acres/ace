// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title PriceFrame
/// @notice THE ONE PLACE the test tree knows what frame the hub's prices are in.
/// @notice Every fixture states prices through here, so a frame change is a change to THIS FILE.
/// @dev The hub is ATOMS-PER-ATOM at Q96, so a human WAD is divided by the pair's scale and par moves with it.
/// @dev Both bodies were the IDENTITY while the hub was human-framed, which is what made adopting them a no-op.
/// @dev Under an atom frame a price divides the pair's unit scale out and par moves with the decimal gap.
/// @dev It lives apart from `AceFixtures` so the mocks can reach it without depending on the deploy rig.
library PriceFrame {
    int256 internal constant TICKS_PER_DECADE = 23027; // 1.0001 ** 23027 ~= 10, so a decimal decade is this many steps

    /// @notice A human price WAD in whatever frame the hub speaks; `1e18` is one quote per whole collateral.
    /// @dev A suite saying `px(2e18, ...)` keeps meaning "two quote per collateral" across the change.
    /// @param humanWad The price as a WAD, where `1e18` is par.
    /// @param quote The market's quote token, read for its decimals once the frame carries them.
    /// @param collateral The market's collateral token, likewise.
    /// @return The same price in the hub's current frame.
    function px(uint256 humanWad, address quote, address collateral) internal view returns (uint256) {
        uint8 qd = _dec(quote);
        uint8 cd = _dec(collateral);
        uint256 gap = cd >= qd ? 10 ** (cd - qd) : 10 ** (qd - cd);
        return cd >= qd ? FullMath.mulDiv(humanWad, 1 << 96, 1e18 * gap) : FullMath.mulDiv(humanWad * gap, 1 << 96, 1e18);
    }

    /// @notice The inverse of `px`: a hub-frame price back to the human WAD a person reads.
    /// @dev For DISPLAY and for a fixture stating an expectation in dollars; never for a value written back to the hub.
    /// @param framePrice The price in the hub's frame, quote atoms per collateral atom at Q96.
    /// @param quote The market's quote token.
    /// @param collateral The market's collateral token.
    /// @return The same price as a WAD, where `1e18` is one quote per whole collateral.
    function humanWad(uint256 framePrice, address quote, address collateral) internal view returns (uint256) {
        uint8 qd = _dec(quote);
        uint8 cd = _dec(collateral);
        uint256 gap = cd >= qd ? 10 ** (cd - qd) : 10 ** (qd - cd);
        return cd >= qd ? FullMath.mulDiv(framePrice, 1e18 * gap, 1 << 96) : FullMath.mulDiv(framePrice, 1e18, gap << 96);
    }

    /// @notice A price a fixed number of BASIS-POINT-ISH STEPS above this pair's par, in the hub's frame.
    /// @notice THE SUCCESSOR TO `tickAt`, and it keeps the SPACING between offsets, NOT the absolute prices.
    /// @notice IT IS NOT BIT-IDENTICAL TO `tickAt`, and assuming it is will silently re-price a market.
    /// @notice `tickAt` floor-aligned par to a spacing; `parStep` below does not, so the anchor MOVED.
    /// @notice On the suite's own USDC(6)/COLL(18) pair that is 36 steps, and every offset rides ~0.36% higher.
    /// @notice A migrated assertion must be re-derived from this law, never carried across as a Q96 literal.
    /// @dev THE HUB HAS NO TICKS. A market names one price, and this is only a convenient way for a TEST to
    /// @dev say "4.9% above par" without writing a Q96 literal. Nothing in `src` knows this law exists.
    /// @dev The law is Uniswap's `1.0001 ** t`, reached through `TickMath` rather than reimplemented, so the
    /// @dev RATIO between two offsets is exact and unchanged; what moved is only where offset zero sits.
    /// @dev A caller wanting a plain human price should use `px` instead; this one is for a suite whose
    /// @dev assertions were written as offsets and whose subject is not the offset.
    /// @param quote The market's quote token.
    /// @param collateral The market's collateral token.
    /// @param offset Steps above par; the old tick offset, unchanged.
    /// @return The price in the hub's frame.
    function priceAt(address quote, address collateral, int24 offset) internal view returns (uint256) {
        return priceAtStep(_parStep(_dec(quote), _dec(collateral)) + offset);
    }

    /// @notice The same law with no par anchor: the price one absolute step names.
    /// @dev PUBLIC because a fuzzing suite bounds its own steps and needs the law without the pair.
    function priceAtStep(int24 step) internal pure returns (uint256) {
        uint256 sp = TickMath.getSqrtPriceAtTick(step);
        return FullMath.mulDiv(sp, sp, 1 << 96);
    }

    /// @notice The step this pair's PAR price sits at, named by the pair's DECIMALS.
    /// @notice For a fixture that has no token to interrogate, and for one naming an offset from par by hand.
    /// @dev IT WAS `parTickAt`, floor-aligned to a spacing. Both the spacing and the floor are gone with the
    /// @dev grid, and the floor's whole job was keeping a negative par from rounding toward zero and landing
    /// @dev ABOVE par -- which inverted the admission direction. An unaligned step cannot do that.
    /// @param quoteDec The quote's decimals.
    /// @param collDec The collateral's decimals.
    /// @return The par step, which `priceAtStep` turns into a price.
    function parStep(uint8 quoteDec, uint8 collDec) internal pure returns (int24) {
        return _parStep(quoteDec, collDec);
    }

    /// @dev The one body; `parStep` is its public name and `priceAt` its address-taking caller.
    function _parStep(uint8 quoteDec, uint8 collDec) private pure returns (int24) {
        int256 g = int256(uint256(collDec)) - int256(uint256(quoteDec));
        return int24(-g * TICKS_PER_DECADE); // par is where the atom price reads 10 ** -g
    }

    /// @dev A token's decimals, defaulting to 18 for anything that cannot answer.
    /// @dev Fixtures legitimately use PLACEHOLDER pair addresses with no code, and a helper that
    /// @dev reverted on those would make a rig unconstructible for a reason it has nothing to do with.
    /// @param token The address to interrogate.
    /// @return Its declared decimals, or 18.
    function _dec(address token) private view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        return ok && ret.length >= 32 ? abi.decode(ret, (uint8)) : 18;
    }
}
