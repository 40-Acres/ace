// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {MarketParams} from "../../src/ace/hub/Types.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {Vm} from "forge-std/Vm.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";
import {PersistenceRecord} from "./PersistenceRecord.sol";
import {AceReader} from "./AceReader.sol";
import {PriceFrame} from "./PriceFrame.sol";

/// @notice The shared deploy fixture: the ONLY place a test spells out the ~44-field `MarketParams`.
/// @notice A new field gets its default here once; tests override only what they exercise.
/// @dev A `KEEP-DIVERGENT` marker flags a default deliberately unlike the shipped config, with its reason.
library AceFixtures {
    address internal constant TREASURY = address(0x7EA5); // non-zero: exercises the sweep's delivery path, not the inert branch
    /// @dev THE SAME address 145 suites already call `alice`, deliberately: sole tenancy makes the market's
    /// @dev named lender and the depositor one party, so the default must BE the address the tree already lends from.
    /// @dev An invented address would have forced an edit into every suite that never had an opinion on tenancy.
    address internal constant LENDER = address(0xA11CE);
    /// @dev THE MAINNET VALUE, read from the one config constant, so every suite measures the budget Ethereum ships.
    /// @dev `deploy/chains/mainnet.json` `pushGas` is a second copy that no suite reads: keep the two equal by hand.
    uint256 internal constant PUSH_GAS = PocDeployConfig.PUSH_GAS;

    /// @dev The venue record's fixture shape. The ring is sized to REACH the settle window, which the
    /// @dev record's own constructor now requires: `(REC_OBS_CAP - 1) * REC_OBS_INTERVAL >= P + pending`.
    uint256 internal constant REC_TRUNC_CAP_BPS = 5000;
    uint64 internal constant REC_OBS_INTERVAL = 60;
    uint256 internal constant REC_OBS_CAP = 300; // 299 * 60 = 17940s, over the 16200s settle window
    uint256 internal constant REC_VOL_REF_FLOOR = 1e18;
    uint256 internal constant REC_VOL_REF_BPS = 5000;

    /// @notice THE way a test builds a venue record: every call site goes through here, none spells the ctor out.
    /// @notice It exists because the constructor is a long run of same-typed positional arguments, where
    /// @notice dropping or reordering one still compiles and binds the wrong value silently.
    /// @dev The windows are the record's OWN now, so they are defaulted here from the shipped config once.
    /// @param writer The hook allowed to observe; a suite driving prints directly passes itself.
    /// @param initialPrice The deploy anchor, in the hub's frame.
    /// @param quote The market's quote token.
    /// @param collateral The market's collateral token.
    /// @return The record, wired for this pair and spanning its own settle window.
    function venueRecord(address writer, uint256 initialPrice, address quote, address collateral) internal returns (PersistenceRecord) {
        return venueRecordWithWindows(writer, initialPrice, quote, collateral, PocDeployConfig.PERSISTENCE_WINDOW, PocDeployConfig.PENDING_WINDOW);
    }

    /// @notice The same record with the two windows named, for a suite whose subject IS the window.
    /// @dev The ring grows with the settle window so the record's span rail passes at any pair the caller names.
    /// @param persistenceWindow The distress window this record answers over.
    /// @param pendingWindow The grace on top; the settle window is their sum.
    function venueRecordWithWindows(address writer, uint256 initialPrice, address quote, address collateral, uint256 persistenceWindow, uint64 pendingWindow)
        internal
        returns (PersistenceRecord)
    {
        uint256 cap = (persistenceWindow + pendingWindow) / REC_OBS_INTERVAL + 2; // +2: the walk needs one gap over the span
        if (cap < REC_OBS_CAP) cap = REC_OBS_CAP;
        return new PersistenceRecord(
            PersistenceRecord.Config({
                writer: writer,
                truncCapBps: REC_TRUNC_CAP_BPS,
                initialPrice: initialPrice,
                obsInterval: REC_OBS_INTERVAL,
                volRefFloor: REC_VOL_REF_FLOOR,
                obsCap: cap,
                unitScale: 1 << 96,
                volRefBps: REC_VOL_REF_BPS,
                depthWindow: persistenceWindow, // at the blackout: the record's rail admits equality
                quote: quote,
                collateral: collateral,
                persistenceWindow: persistenceWindow,
                pendingWindow: pendingWindow
            })
        );
    }

    /// @notice A price named RELATIVE to this pair's par, in the hub's frame.
    /// @notice The ergonomic form: a suite says `priceAt(q, c, 480)` and keeps its DISTANCE from par when par moves.
    /// @notice IT REPLACES `tickAt` BUT DOES NOT RETURN THE SAME NUMBERS -- a migration here IS a re-pricing.
    /// @notice `tickAt` floor-aligned par to a spacing and this does not, so the anchor moved: 36 steps, about
    /// @notice 0.36%, on the fixture pair. Offsets keep their spacing from each other and not their old prices.
    /// @dev THE HUB HAS NO TICKS. A market names one price; this is a TEST convenience for saying "x% above
    /// @dev par", and `PriceFrame` holds the law. Nothing in `src` knows the law exists.
    /// @dev The SPACING argument is gone with the grid: there is no alignment left for a suite to get wrong.
    /// @param quote The market's quote token.
    /// @param collateral The market's collateral token.
    /// @param offset Steps above par; the old tick offset, unchanged.
    /// @return The price in the hub's frame.
    function priceAt(address quote, address collateral, int24 offset) internal view returns (uint256) {
        return PriceFrame.priceAt(quote, collateral, offset);
    }

    /// @notice A human price WAD in the hub's current frame; `1e18` is one quote per whole collateral.
    /// @param humanWad The price as a WAD, where `1e18` is par.
    /// @param quote The market's quote token.
    /// @param collateral The market's collateral token.
    /// @return The price to hand a record.
    function px(uint256 humanWad, address quote, address collateral) internal view returns (uint256) {
        return PriceFrame.px(humanWad, quote, collateral);
    }

    /// @notice A deployed singleton with one market: what every suite's setUp holds.
    struct Deployment {
        Ace ace;
        PositionManager positionManager;
        AceReader read;
        bytes32 id;
        MarketParams p;
    }

    /// @notice The baseline market config; `positionManager` is filled by `deploy`.
    /// @dev The caller sets the seams it exercises (venue, record, risk, executor) before creation.
    function marketParams(address quote, address collateral) internal view returns (MarketParams memory p) {
        p.quote = quote;
        p.collateral = collateral;
        /// @dev THE BASELINE MARKET BIDS AT PAR, which is what the whole suite was already implicitly built
        /// @dev around: par is the anchor every `priceAt` offset is named against. A suite whose SUBJECT is
        /// @dev the price overrides it, exactly as it overrides `record` or `lender`.
        /// @dev It cannot be `pure` any more -- par depends on the pair's decimals, which means reading them.
        /// @dev IT IS `priceAt(.., 0)` AND NOT `px(1e18, ..)`, and the two are NOT the same number: `priceAt`
        /// @dev reaches par through `1.0001 ** t` and lands a few parts per billion above the exact ratio.
        /// @dev Every suite names its rungs as `priceAt` offsets, so anchoring the market anywhere else makes
        /// @dev `priceAt(.., 0)` a price the baseline market does not bid at -- which is a silently wrong
        /// @dev funding floor in any row that compares the two.
        p.price = PriceFrame.priceAt(quote, collateral, 0);
        p.minCoverageWad = PocDeployConfig.MIN_COVERAGE_WAD;
        p.baseBps = PocDeployConfig.BASE_BPS;
        p.minTenor = ProtocolPolicy.MIN_TENOR; // one 7-day term, not the shipped 7-30 day launch range
        p.maxTenor = ProtocolPolicy.MAX_TENOR;
        p.minDebt = 10e6; // KEEP-DIVERGENT: test baseline dust floor (shipped MIN_DEBT is 5000e6)
        /// @dev no eps: the band ships off; a suite arming the band sets eps with it
        p.settleBountyBps = PocDeployConfig.SETTLE_BOUNTY_BPS;
        /// @dev A DEFAULT so the ~200 suites that never think about tenancy keep working; genesis refuses a zero.
        /// @dev Any suite whose subject IS the lender overrides it, exactly as it overrides `record` or `gate`.
        p.lender = LENDER;
        /// @dev KEEP-DIVERGENT: the ask is ON here and OFF by protocol default, so every suite that buys a settled pot keeps one to buy.
        p.inventoryAsk = true;
    }

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice PositionManager FIRST at the hub's predicted address, then the hub, which asserts the binding.
    /// @dev The two name each other, and CREATE2 cannot break that cycle.
    /// @dev The positionManager's initcode contains the hub, so predicting it would need the hub it needs.
    /// @dev A plain CREATE address depends only on (deployer, nonce), which IS predictable.
    /// @dev A wrong prediction fails closed in `Ace`'s constructor rather than mis-binding custody.
    function newAceWithEscrow(address treasury) internal returns (Ace ace, PositionManager positionManager) {
        return newAceWithEscrow(treasury, PUSH_GAS);
    }

    /// @notice The same pair with the push budget named, for a suite whose subject IS the budget.
    function newAceWithEscrow(address treasury, uint256 pushGas) internal returns (Ace ace, PositionManager positionManager) {
        address predictedHub = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        positionManager = new PositionManager(predictedHub);
        ace = new Ace(treasury, address(positionManager), pushGas);
    }

    /// @notice A hub with its own positionManager: the one-liner every hand-rolled site needs.
    function newAce() internal returns (Ace ace) {
        (ace,) = newAceWithEscrow(TREASURY);
    }

    /// @notice A standalone positionManager bound to an arbitrary loan manager.
    /// @dev For positionManager-only unit tests that never stand up a hub or a market.
    /// @dev No collateral or seams here now: a PositionManager is bound to a hub and nothing else.
    function plainEscrow(IERC20, address loanManager) internal returns (PositionManager) {
        return new PositionManager(loanManager);
    }

    /// @notice The hub's one positionManager. Kept as a helper so call sites need not know it moved.
    function deployEscrow(Ace ace, address, address) internal view returns (PositionManager) {
        return PositionManager(ace.POSITION_MANAGER());
    }

    /// @notice PositionManager -> hub -> market, in that order: the positionManager needs the hub's predicted address.
    function deploy(MarketParams memory p) internal returns (Deployment memory d) {
        return deployWithTreasury(p, TREASURY);
    }

    /// @notice `deploy` with an explicit revenue destination; `address(0)` makes the sweep inert.
    function deployWithTreasury(MarketParams memory p, address treasury) internal returns (Deployment memory d) {
        return deployWith(p, treasury, PUSH_GAS);
    }

    /// @notice `deploy` with both deploy-time choices named: the revenue destination and the push budget.
    function deployWith(MarketParams memory p, address treasury, uint256 pushGas) internal returns (Deployment memory d) {
        (d.ace, d.positionManager) = newAceWithEscrow(treasury, pushGas);
        d.id = d.ace.createMarket(p);
        d.read = new AceReader(address(d.ace));
        d.p = p;
    }
}
