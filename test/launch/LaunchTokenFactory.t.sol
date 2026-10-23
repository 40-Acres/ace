// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {AuctionParameters, LiquidityAllocationBracket, MigratorParameters, PositionDefinition} from "../../src/interfaces/ILaunchAuction.sol";
import {LaunchLock, Leg} from "../../src/entities/launch/LaunchLock.sol";
import {LaunchOpsBudget} from "../../src/entities/launch/LaunchOpsBudget.sol";
import {LaunchTokenFactory} from "../../src/entities/launch/LaunchTokenFactory.sol";
import {LockAccount} from "../../src/entities/launch/LockAccount.sol";
import {ScheduleLock} from "../../src/entities/vesting/ScheduleLock.sol";
import {RunwayFixture} from "./RunwayFixture.sol";

/// @title LaunchTokenFactoryTest
/// @notice UNIT rows for the one-call launch: the shape it fixes, every input check it reverts on, and where the supply goes.
/// @dev The strategy is a stand-in that pulls as the real one does; the fork suite runs the same factory through the deployed launcher.
contract LaunchTokenFactoryTest is RunwayFixture {
    using PoolIdLibrary for PoolKey;

    /// @dev `team` launches `p`, expecting `err`; the strategy has an auction ready, as a launch that passes would.
    function _refuses(LaunchTokenFactory.LaunchInput memory p, bytes memory err) internal {
        strat.setNext(address(0xA0C7104));
        vm.prank(team);
        vm.expectRevert(err);
        factory.launch(p);
    }

    function _sel(bytes4 s) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(s);
    }

    /// @dev The default input with a second leg, to `alice` on a 90-day tranche.
    function _twoLegs() internal view returns (LaunchTokenFactory.LaunchInput memory p) {
        p = _input();
        Leg[] memory legs = new Leg[](2);
        legs[0] = p.legs[0];
        legs[1] = Leg({beneficiary: alice, amount: 20_000e18, cliff: 90 days, duration: 90 days});
        p.legs = legs;
    }

    // ---- construction ----

    /// @notice The factory pins its inputs, reads the strategy's auction factory, and builds the budget on the strategy's two managers.
    function test_ConstructionPinsItsInputs() public view {
        assertEq(factory.HUB(), address(ace), "hub");
        assertEq(factory.STRATEGY(), address(strat), "strategy");
        assertEq(factory.QUOTE(), address(usdc), "quote");
        assertEq(factory.AUCTION_FACTORY(), address(strat), "the strategy's auction factory");
        assertEq(factory.MAX_BLOCK_SECONDS(), BLOCK_SECONDS, "block seconds");
        assertEq(factory.POOL_FEE(), FEE, "pool fee");
        assertEq(factory.POOL_TICK_SPACING(), SPACING, "pool spacing");
        LaunchOpsBudget impl = LaunchOpsBudget(factory.BUDGET_IMPL());
        assertEq(impl.FACTORY(), address(factory), "the budget implementation's factory");
        assertEq(impl.QUOTE(), address(usdc), "the budget's quote");
        assertEq(address(impl.POOL_MANAGER()), address(manager), "the budget's PoolManager, read off the strategy's PositionManager");
        assertEq(impl.POSITION_MANAGER(), address(posm), "the budget's PositionManager, the strategy's");
        (bool ok,) = address(factory).staticcall(abi.encodeWithSignature("DEPLOYER()"));
        assertFalse(ok, "the factory still names a deployer");
    }

    /// @notice The ruled numbers: a 30-day cliff, a 90-day team vest, a 30-day buyer vest, ops at most a tenth, the team at most half
    /// @notice the raise, a day's migration window; and this chain's assumed slowest block.
    function test_TheRuledNumbers() public view {
        assertEq(factory.MIN_TEAM_CLIFF(), 30 days, "cliff");
        assertEq(factory.MIN_TEAM_VEST(), 90 days, "team vest");
        assertEq(factory.MIN_BUYER_VEST(), 30 days, "buyer vest");
        assertEq(factory.MAX_OPS_BPS(), 1_000, "ops");
        assertEq(factory.MAX_TEAM_SHARE_BPS(), 5_000, "share");
        assertEq(factory.MIGRATION_WINDOW(), 1 days, "migration window");
        assertEq(factory.MAX_BLOCK_SECONDS(), 13, "block seconds");
    }

    /// @notice With no block time, launchBy would be the launch block itself, and every schedule would start before the launch lands.
    function test_ZeroBlockSecondsReverts() public {
        vm.expectRevert(LaunchTokenFactory.ZeroBlockSeconds.selector);
        new LaunchTokenFactory(address(ace), address(strat), address(usdc), 0, FEE, SPACING, bytes32(0), cutSink, 0);
    }

    /// @notice A pool fee above v4's highest static fee is refused, the dynamic-fee flag included; the highest itself is accepted.
    function test_APoolFeeAboveTheV4MaxReverts() public {
        vm.expectRevert(LaunchTokenFactory.BadPoolFee.selector);
        new LaunchTokenFactory(address(ace), address(strat), address(usdc), BLOCK_SECONDS, 1_000_001, SPACING, bytes32(0), cutSink, 0);
        vm.expectRevert(LaunchTokenFactory.BadPoolFee.selector);
        new LaunchTokenFactory(address(ace), address(strat), address(usdc), BLOCK_SECONDS, LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, bytes32(0), cutSink, 0);
        assertEq(_factory(BLOCK_SECONDS, 1_000_000).POOL_FEE(), 1_000_000, "the v4 max itself was refused");
    }

    /// @notice A pool tick spacing outside v4's range is refused: zero, negative, or past int16; both ends of the range are accepted.
    function test_APoolTickSpacingOutsideV4sRangeReverts() public {
        int24[3] memory bad = [int24(0), -1, int24(type(int16).max) + 1];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(LaunchTokenFactory.BadTickSpacing.selector);
            new LaunchTokenFactory(address(ace), address(strat), address(usdc), BLOCK_SECONDS, FEE, bad[i], bytes32(0), cutSink, 0);
        }
        assertEq(_factory(BLOCK_SECONDS, FEE, 1).POOL_TICK_SPACING(), 1, "the smallest spacing was refused");
        assertEq(_factory(BLOCK_SECONDS, FEE, type(int16).max).POOL_TICK_SPACING(), type(int16).max, "the largest spacing was refused");
    }

    // ---- the token ----

    /// @notice The supply is the strategy's two halves plus every allocation, minted ONCE: one Transfer from zero, and nothing else ever mints.
    function test_TheSupplyIsMintedOnce() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        vm.recordLogs();
        Made memory m = _launch(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 mints;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == m.token && logs[i].topics[0] == IERC20.Transfer.selector && logs[i].topics[1] == bytes32(0)) {
                ++mints;
                assertEq(abi.decode(logs[i].data, (uint256)), _supplyOf(p), "the one mint is the whole supply");
            }
        }
        assertEq(mints, 1, "minted more than once");
        assertEq(IERC20(m.token).totalSupply(), 2 * uint256(SUPPLY) + TEAM_AMT + OPS, "supply");
        assertEq(IERC20Metadata(m.token).decimals(), 18, "decimals");
        assertEq(IERC20Metadata(m.token).name(), NAME, "name");
        assertEq(IERC20Metadata(m.token).symbol(), SYMBOL, "symbol");
    }

    /// @notice The token answers no mint, burn or owner selector: there is no one to mint more, and no door to do it through.
    function test_TheTokenHasNoMintBurnOrOwner() public {
        Made memory m = _launch();
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", team, 1);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[2] = abi.encodeWithSignature("owner()");
        calls[3] = abi.encodeWithSignature("transferOwnership(address)", team);
        calls[4] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[5] = abi.encodeWithSignature("burnFrom(address,uint256)", team, 1);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = m.token.call(calls[i]);
            assertFalse(ok, "the token answered a supply or owner selector");
        }
    }

    /// @notice A transfer to DEAD is a real burn: the supply falls by the amount, DEAD holds nothing, and the event is a burn's.
    function test_ATransferToDeadBurns() public {
        Made memory m = _launch();
        IERC20 t = IERC20(m.token);
        address acct = m.lock.predict(team, TEAM_LINEAR);
        uint256 supply = t.totalSupply();
        vm.prank(address(strat));
        vm.expectEmit(m.token);
        emit IERC20.Transfer(address(strat), address(0), 1_000e18);
        t.transfer(DEAD, 1_000e18);
        assertEq(t.totalSupply(), supply - 1_000e18, "the supply did not fall by the amount");
        assertEq(t.balanceOf(DEAD), 0, "DEAD holds the burned tokens");
        assertEq(t.balanceOf(address(strat)), 2 * uint256(SUPPLY) - 1_000e18, "the sender kept them");
        vm.prank(address(strat));
        t.transfer(acct, 1e18);
        assertEq(t.totalSupply(), supply - 1_000e18, "an ordinary transfer moved the supply");
    }

    // ---- the shape it fixes ----

    /// @notice Every fixed field of the strategy's registration: currency, migration block, reserve, recipients, pool, definitions, bracket.
    function test_TheRegistrationIsTheFixedShape() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        Made memory m = _launch(p);
        MigratorParameters memory r = strat.initializers(address(m.auction));
        assertEq(r.token, m.token, "token");
        assertEq(r.currency, address(usdc), "the raise is in USDC");
        assertEq(r.migrationBlock, p.endBlock + 1, "migration the block after the end");
        assertEq(r.reservedTokenAmountForLP, SUPPLY, "the reserve is the auction supply");
        assertEq(r.recipient, address(m.budget), "the leftovers go to the budget");
        assertEq(r.positionRecipient, address(m.budget), "the LP goes to the budget");
        assertEq(r.poolParameters.fee, FEE, "pool fee");
        assertEq(r.poolParameters.tickSpacing, SPACING, "pool spacing");
        assertEq(r.poolParameters.hook, address(factory.HOOK()), "pool hook");
        assertEq(abi.decode(r.positionDefinitions, (PositionDefinition[])).length, 0, "no definition: the full-range fallback alone");
        LiquidityAllocationBracket[] memory b = abi.decode(r.lpAllocationSchedule, (LiquidityAllocationBracket[]));
        assertEq(b.length, 1, "one bracket");
        assertEq(b[0].lowerThreshold, 0, "from the first unit raised");
        assertEq(b[0].rate, 1e7 * (10_000 - SHARE) / 10_000, "the pool's share of the raise is one less the team's");
        assertEq(strat.lastAmount(), 2 * uint256(SUPPLY), "the strategy's amount is the supply and the reserve");
        assertEq(strat.lastSalt(), bytes32(0), "the distribution salt");
    }

    /// @notice Every fixed field of the auction: USDC, unsold tokens the budget's to sweep, the raise to the strategy, the lock as the bid gate.
    /// @notice Claims open at the end.
    function test_TheAuctionIsTheFixedShape() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.requiredRaise = 777e6;
        Made memory m = _launch(p);
        (, bytes memory data) = abi.decode(strat.lastConfig(), (MigratorParameters, bytes));
        AuctionParameters memory a = abi.decode(data, (AuctionParameters));
        assertEq(a.currency, address(usdc), "currency");
        assertEq(a.tokensRecipient, address(m.budget), "unsold tokens are the budget's alone to sweep");
        assertEq(a.fundsRecipient, address(1), "the raise goes to the strategy, by the auction factory's caller placeholder");
        assertEq(a.startBlock, p.startBlock, "start");
        assertEq(a.endBlock, p.endBlock, "end");
        assertEq(a.claimBlock, p.endBlock, "claims open at the end");
        assertEq(a.tickSpacing, TICK, "tick");
        assertEq(a.validationHook, address(m.lock), "the lock is the bid gate");
        assertEq(a.floorPrice, FLOOR, "floor");
        assertEq(a.requiredCurrencyRaised, 777e6, "required raise");
        assertEq(a.auctionStepsData, abi.encodePacked(uint24(1e7 / BLOCKS), uint40(BLOCKS)), "one even step over the whole auction");
    }

    /// @notice The share sets the one bracket: none sends the whole raise to the pool, the cap sends half, anything between in proportion.
    function test_TheShareSetsTheBracket() public {
        uint256[3] memory shares = [uint256(0), 5_000, 1_234];
        uint24[3] memory rates = [uint24(1e7), 5e6, 8_766_000];
        for (uint256 i; i < 3; ++i) {
            LaunchTokenFactory.LaunchInput memory p = _input();
            p.teamShareBps = shares[i];
            Made memory m = _launch(p);
            LiquidityAllocationBracket[] memory b = abi.decode(strat.initializers(address(m.auction)).lpAllocationSchedule, (LiquidityAllocationBracket[]));
            assertEq(b[0].rate, rates[i], "the bracket is not one less the share");
            assertEq(m.budget.terms().shareBps, shares[i], "the budget carries another share");
        }
    }

    /// @notice Every schedule, the buyer's and each leg's, starts at launchBy; each leg's curve is the one it asked for, at id i + 1.
    function test_EveryScheduleStartsAtLaunchBy() public {
        LaunchTokenFactory.LaunchInput memory p = _twoLegs();
        Made memory m = _launch(p);
        (uint64 s, uint64 c, uint64 d) = m.lock.schedules(0);
        assertEq(abi.encode(s, c, d), abi.encode(m.launchBy, 0, p.buyerDuration), "the buyer schedule");
        for (uint256 i; i < 2; ++i) {
            (s, c, d) = m.lock.schedules(i + 1);
            assertEq(s, m.launchBy, "a leg's schedule starts elsewhere");
            assertEq(abi.encode(c, d), abi.encode(p.legs[i].cliff, p.legs[i].duration), "a leg's curve");
        }
        vm.expectRevert();
        m.lock.schedules(3);
        assertEq(m.lock.TOKEN(), m.token, "the lock locks the launch token");
        assertEq(m.lock.HUB(), address(ace), "the lock pledges into the hub");
    }

    /// @notice launchBy is the migration block at the slowest assumed block, plus MIGRATION_WINDOW: the pool records it as its closing time.
    function test_LaunchByIsTheMigrationBlockAtTheSlowestBlock() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        Made memory m = _launch(p);
        (uint64 start,,) = m.lock.schedules(0);
        assertEq(start, _now() + (BLOCKS + 3) * 13 + 1 days, "launchBy");
        assertEq(factory.launchByOf(m.key.toId()), m.launchBy, "the pool's recorded launchBy");
    }

    /// @notice The buyer schedule vests over at least 30 days from launchBy, with no cliff: a second short reverts, exactly 30 days launches.
    function test_TheBuyerVestFloor() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.buyerDuration = 30 days - 1;
        _refuses(p, _sel(LaunchTokenFactory.BuyerVestTooShort.selector));
        p.buyerDuration = 0;
        _refuses(p, _sel(LaunchTokenFactory.BuyerVestTooShort.selector));
        p.buyerDuration = 30 days;
        Made memory m = _launch(p);
        (uint64 s, uint64 c, uint64 d) = m.lock.schedules(0);
        assertEq(abi.encode(s, c, d), abi.encode(m.launchBy, 0, 30 days), "the buyer schedule at the floor");
    }

    /// @notice The launch records exactly its own pool, with its launchBy: the configured key, and not the same token at another fee,
    /// @notice spacing or hook, which read zero, so the hook refuses them.
    function test_OnlyTheConfiguredKeyIsALaunchPool() public {
        Made memory m = _launch();
        assertEq(factory.launchByOf(m.key.toId()), m.launchBy, "the launch's pool");
        assertEq(PoolId.unwrap(m.budget.terms().pool), PoolId.unwrap(m.key.toId()), "the budget names another pool");
        PoolKey memory k = m.key;
        k.fee = 3_000;
        assertEq(factory.launchByOf(k.toId()), 0, "another fee");
        k = m.key;
        k.tickSpacing = 60;
        assertEq(factory.launchByOf(k.toId()), 0, "another spacing");
        k = m.key;
        k.hooks = IHooks(address(0));
        assertEq(factory.launchByOf(k.toId()), 0, "the hookless key");
        assertEq(factory.launchByOf(_keyOf(address(0xD15C0)).toId()), 0, "a token born elsewhere");
    }

    /// @notice The record names the launch's lock, auction and budget, and the launch announces them with its pool.
    function test_TheRecordAndTheEvent() public {
        vm.recordLogs();
        Made memory m = _launch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Launched(address,address,address,address,address,bytes32)");
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != topic) continue;
            ++seen;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(m.token))), "the event's token");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(team))), "the event's creator");
            (address l, address a, address b, PoolId id) = abi.decode(logs[i].data, (address, address, address, PoolId));
            assertEq(abi.encode(l, a, b), abi.encode(m.lock, m.auction, m.budget), "the event names other contracts than the record");
            assertEq(PoolId.unwrap(id), PoolId.unwrap(m.key.toId()), "the event's pool");
        }
        assertEq(seen, 1, "one Launched event");
        assertTrue(address(m.lock) != address(0) && address(m.budget) != address(0), "a record field is empty");
        assertEq(strat.initializers(address(m.auction)).token, m.token, "the record's auction is not the one registered for the token");
        (address rl,,) = factory.launchOf(address(usdc));
        assertEq(rl, address(0), "a token born elsewhere has a record");
    }

    /// @notice The budget is a clone carrying its launch: token, pool, operator, ops allocation, share, reserve and launchBy.
    function test_TheBudgetCarriesItsLaunch() public {
        Made memory m = _launch();
        LaunchOpsBudget.Terms memory t = m.budget.terms();
        assertEq(t.token, m.token, "token");
        assertEq(PoolId.unwrap(t.pool), PoolId.unwrap(m.key.toId()), "pool");
        assertEq(t.operator, operator, "operator");
        assertEq(t.opsAllocation, OPS, "ops allocation");
        assertEq(t.shareBps, SHARE, "share");
        assertEq(t.reserve, SUPPLY, "reserve");
        assertEq(t.launchBy, m.launchBy, "launchBy");
        (, address auction,) = factory.launchOf(m.token);
        assertEq(auction, address(m.auction), "the factory records another auction");
    }

    // ---- the input checks ----

    /// @notice The team takes at most half the raise: exactly half launches with a half bracket, one basis point over reverts.
    function test_TheShareCapIsHalf() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.teamShareBps = 5_001;
        _refuses(p, _sel(LaunchTokenFactory.ShareOverCap.selector));
        p.teamShareBps = 5_000;
        Made memory m = _launch(p);
        LiquidityAllocationBracket[] memory b = abi.decode(strat.initializers(address(m.auction)).lpAllocationSchedule, (LiquidityAllocationBracket[]));
        assertEq(b[0].rate, 5e6, "half the raise to the pool");
    }

    /// @notice The ops amount is at most a tenth of the supply, to the atom: exactly a tenth launches, one atom more reverts.
    function test_TheOpsCapIsATenthOfTheSupply() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.legs[0].amount = 250_000e18; // with the strategy's 2M, a 250k ops amount is exactly a tenth of 2.5M
        p.opsAmount = 250_000e18 + 1;
        _refuses(p, _sel(LaunchTokenFactory.OpsOverCap.selector));
        p.opsAmount = 250_000e18;
        Made memory m = _launch(p);
        assertEq(IERC20(m.token).balanceOf(address(m.budget)), 250_000e18, "the budget holds exactly a tenth");
    }

    /// @notice Every leg unlocks no sooner than 30 days and is whole no sooner than 90, wherever it sits; the exact edges launch.
    function test_TheTeamMinimum() public {
        LaunchTokenFactory.LaunchInput memory p = _twoLegs();
        p.legs[1].cliff = 30 days - 1;
        _refuses(p, _sel(LaunchTokenFactory.BadLeg.selector));
        p.legs[1].cliff = 30 days;
        p.legs[1].duration = 90 days - 1;
        _refuses(p, _sel(LaunchTokenFactory.BadLeg.selector));
        p.legs[1].duration = 90 days;
        Made memory m = _launch(p);
        (, uint64 c, uint64 d) = m.lock.schedules(2);
        assertEq(abi.encode(c, d), abi.encode(30 days, 90 days), "the exact edges were refused");
    }

    /// @notice Each clause of a bad leg is refused on its own, on the leg after a good one: nothing, a short cliff, a short vest.
    function test_BadLegRefusals() public {
        LaunchTokenFactory.LaunchInput memory p = _twoLegs();
        p.legs[1].amount = 0;
        _refuses(p, _sel(LaunchTokenFactory.BadLeg.selector));
        p = _twoLegs();
        p.legs[1].cliff = 0;
        _refuses(p, _sel(LaunchTokenFactory.BadLeg.selector));
        p = _twoLegs();
        (p.legs[1].cliff, p.legs[1].duration) = (30 days, 0);
        _refuses(p, _sel(LaunchTokenFactory.BadLeg.selector));
        _launch(_twoLegs());
    }

    /// @notice A curve the lock refuses is refused by the lock: a cliff past its duration, though both clear the factory's minimums.
    function test_ACurveTheLockRefuses() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        (p.legs[0].cliff, p.legs[0].duration) = (100 days, 95 days);
        _refuses(p, _sel(ScheduleLock.BadSchedule.selector));
    }

    /// @notice A leg of nothing is refused.
    function test_AZeroLegIsRefused() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.legs[0].amount = 0;
        _refuses(p, _sel(LaunchTokenFactory.BadLeg.selector));
    }

    /// @notice A beneficiary the lock refuses an account for is refused by the lock's own error.
    function test_ARefusedBeneficiaryIsRefusedByTheLock() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.legs[0].beneficiary = address(0);
        _refuses(p, _sel(ScheduleLock.BadBeneficiary.selector));
        p.legs[0].beneficiary = address(ace);
        _refuses(p, _sel(ScheduleLock.BadBeneficiary.selector));
    }

    /// @notice An operator is required on every launch, even one with no ops amount and no share: the LP's fees still pay to it.
    function test_AnOperatorIsAlwaysRequired() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        (p.opsAmount, p.teamShareBps, p.operator) = (0, 0, address(0));
        _refuses(p, _sel(LaunchTokenFactory.ZeroOperator.selector));
    }

    /// @notice A window that starts after this block and runs a number of blocks dividing the whole launches, in that many even steps.
    function test_TheAuctionWindow() public {
        uint64 b = uint64(vm.getBlockNumber());
        LaunchTokenFactory.LaunchInput memory p = _input();
        (p.startBlock, p.endBlock) = (b, b + BLOCKS);
        _refuses(p, _sel(LaunchTokenFactory.BadWindow.selector));
        (p.startBlock, p.endBlock) = (b + 1, b + 9);
        Made memory m = _launch(p);
        (, bytes memory data) = abi.decode(strat.lastConfig(), (MigratorParameters, bytes));
        assertEq(abi.decode(data, (AuctionParameters)).auctionStepsData, abi.encodePacked(uint24(1_250_000), uint40(8)), "eight even steps");
        assertEq(strat.initializers(address(m.auction)).migrationBlock, b + 10, "the migration block");
    }

    /// @notice Each clause of a bad window is refused on its own: a start at or before this block, an end at or before the start, a step count
    /// @notice that does not divide the whole.
    function test_BadWindowRefusals() public {
        uint64 b = uint64(vm.getBlockNumber());
        LaunchTokenFactory.LaunchInput memory p = _input();
        uint64[2][6] memory bad = [[b, b + BLOCKS], [b - 1, b + BLOCKS], [b + 5, b + 5], [b + 5, b + 4], [b + 5, b + 8], [b + 5, b + 12]];
        for (uint256 i; i < bad.length; ++i) {
            (p.startBlock, p.endBlock) = (bad[i][0], bad[i][1]);
            _refuses(p, _sel(LaunchTokenFactory.BadWindow.selector));
        }
        (p.startBlock, p.endBlock) = (b + 1, b + 2);
        _launch(p);
    }

    /// @notice An auction selling nothing is refused.
    function test_AZeroSupplyIsRefused() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.auctionSupply = 0;
        _refuses(p, _sel(LaunchTokenFactory.ZeroSupply.selector));
    }

    /// @notice A launch time past uint64 is refused rather than wrapped into a small schedule start.
    function test_ALaunchTimePastUint64IsRefused() public {
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.endBlock = type(uint64).max - 1;
        p.startBlock = p.endBlock - BLOCKS;
        uint256 by = _now() + (uint256(p.endBlock) + 1 - vm.getBlockNumber()) * BLOCK_SECONDS + 1 days;
        _refuses(p, abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 64, by));
    }

    // ---- the strategy takes exactly its amount and registers this auction ----

    /// @notice A strategy that pulls a unit short leaves that unit in the factory, and the launch reverts on the supply left behind.
    function test_AShortPullReverts() public {
        strat.misbehave(1, 0, address(0));
        _refuses(_input(), _sel(LaunchTokenFactory.SupplyLeft.selector));
    }

    /// @notice A strategy that pulls in full and hands some back leaves the factory holding supply, and the launch reverts.
    function test_AGiveBackReverts() public {
        strat.misbehave(0, 1, address(0));
        _refuses(_input(), _sel(LaunchTokenFactory.SupplyLeft.selector));
    }

    /// @notice An auction the strategy did not register for this token is refused: the oracle naming another, or a registration on another token.
    function test_TheWrongAuctionReverts() public {
        strat.setOracle(address(0xBAD));
        _refuses(_input(), _sel(LaunchTokenFactory.WrongAuction.selector));
        strat.setOracle(address(0));
        strat.misbehave(0, 0, address(usdc));
        _refuses(_input(), _sel(LaunchTokenFactory.WrongAuction.selector));
    }

    // ---- where the supply goes ----

    /// @notice Every unit is at the strategy, in a lock account or in the budget; the factory and the caller hold none.
    function test_EveryUnitIsAccountedFor() public {
        Made memory m = _launch();
        IERC20 t = IERC20(m.token);
        address acct = m.lock.predict(team, TEAM_LINEAR);
        assertEq(t.balanceOf(address(strat)), 2 * uint256(SUPPLY), "the strategy pulled its amount");
        assertEq(t.balanceOf(acct), TEAM_AMT, "the team leg in its lock account");
        assertEq(t.balanceOf(address(m.budget)), OPS, "the ops amount in the budget");
        assertEq(t.balanceOf(address(strat)) + t.balanceOf(acct) + t.balanceOf(address(m.budget)), t.totalSupply(), "a unit");
        assertEq(t.balanceOf(address(factory)), 0, "the factory kept some");
        assertEq(t.balanceOf(team), 0, "the caller got some");
        assertEq(t.allowance(address(factory), address(strat)), 0, "an allowance survived");
    }

    /// @notice The ops amount is paid to the budget in the launch, and a launch with none pays the budget nothing.
    function test_OpsArePaidToTheBudget() public {
        Made memory m = _launch();
        assertEq(IERC20(m.token).balanceOf(address(m.budget)), OPS, "the budget does not hold the ops amount");
        LaunchTokenFactory.LaunchInput memory p = _input();
        p.opsAmount = 0;
        Made memory none = _launch(p);
        assertEq(IERC20(none.token).balanceOf(address(none.budget)), 0, "a launch with no ops amount paid the budget");
        assertEq(none.budget.terms().opsAllocation, 0, "the budget carries an ops allocation nobody paid");
    }

    /// @notice Two legs to one beneficiary are two schedules and two accounts, each holding its own amount on its own curve.
    function test_TwoLegsForOneBeneficiaryLandInTwoAccounts() public {
        LaunchTokenFactory.LaunchInput memory p = _twoLegs();
        p.legs[1].beneficiary = team;
        Made memory m = _launch(p);
        (address a1, address a2) = (m.lock.predict(team, 1), m.lock.predict(team, 2));
        assertTrue(a1 != a2, "two legs shared an account");
        assertEq(IERC20(m.token).balanceOf(a1), TEAM_AMT, "the first leg's account");
        assertEq(IERC20(m.token).balanceOf(a2), 20_000e18, "the second leg's account");
        assertEq(LockAccount(a2).vestedAmount(uint64(m.launchBy + 90 days - 1)), 0, "the second account runs the first leg's curve");
        assertEq(LockAccount(a2).vestedAmount(uint64(m.launchBy + 90 days)), 20_000e18, "the second account is not whole at its tranche");
    }

    /// @notice A leg lands in a DEPLOYED lock account: the account is created before the transfer that pays it.
    function test_AccountsAreDeployedBeforeTheyArePaid() public {
        vm.recordLogs();
        Made memory m = _launch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address acct = m.lock.predict(team, TEAM_LINEAR);
        (uint256 created, uint256 paid) = (type(uint256).max, type(uint256).max);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(m.lock) && logs[i].topics[0] == ScheduleLock.AccountCreated.selector && logs[i].topics[1] == _word(acct)) {
                created = i;
            }
            if (logs[i].emitter == m.token && logs[i].topics[0] == IERC20.Transfer.selector && logs[i].topics[2] == _word(acct)) paid = i;
        }
        assertTrue(paid != type(uint256).max, "fixture: the leg was paid");
        assertLt(created, paid, "the account was paid before it was created");
        assertEq(LockAccount(acct).beneficiary(), team, "the account is team's");
    }

    function _word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
