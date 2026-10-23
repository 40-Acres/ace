// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {WarpClock} from "../utils/WarpClock.sol";
import {Vm} from "forge-std/Test.sol";
import {Ace} from "../../src/ace/hub/Ace.sol";
import {AceLens} from "../../src/ace/lens/AceLens.sol";
import {AceVault, VaultConfig} from "../../src/curator/AceVault.sol";
import {AceVaultFlows, BorrowRequest} from "../../src/curator/AceVaultFlows.sol";
import {CuratorVault, Listing, Row} from "../../src/curator/CuratorVault.sol";
import {MarketParams, MarketState, OpenBounds} from "../../src/ace/hub/Types.sol";
import {PriceFrame} from "../utils/PriceFrame.sol";
import {PositionManager} from "../../src/ace/positions/PositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStakeVault} from "../mocks/MockStakeVault.sol";
import {MockPersistenceRecord} from "../mocks/MockPersistenceRecord.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {AceReader} from "../utils/AceReader.sol";
import {PocDeployConfig, ProtocolPolicy} from "../../src/config/Defaults.sol";

/// @notice Shared rig for the CuratorVault suites: one hub, one genesis market, one lens, plus the vault and door helpers.
/// @dev Abstract, so no test runs here; each concrete suite inherits the fixture and the verb helpers.
/// @dev A vault HOLDS ITS CASH and lends only through its door, so no helper here rests or allocates anything.
/// @dev `mid` is the market the newest vault's door opens on the rig collateral, created at the hub when the vault is built.
/// @dev THE ONLY NAV ORACLE HERE IS `_hubTruthNav`: a mirror of the contract's own arithmetic proves nothing.
abstract contract CuratorVaultBase is WarpClock {
    Ace internal ace;
    AceLens internal lens;
    AceReader internal read;
    PositionManager internal positionManager;
    MockERC20 internal usdc;
    MockStakeVault internal collateral;
    MockPersistenceRecord internal record;
    bytes32 internal mid;

    address internal curator = address(0xC0A11);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal borrower = address(0xB0BA);
    address internal keeper = address(0xCAFE);
    address internal rigGuardian = address(0x6A2E); // `_cfg`'s guardian, which `_waivePots` exempts with; apart from the suites' own `guardian`

    uint256 internal T4; // steps above this rig's par; assigned in setUp, since par is not a compile-time value
    uint256 internal T2;
    uint256 internal SPARE; // below T2; a second price the rig can stand a second market up at
    uint256 internal constant COLL = 40_000e18;
    uint256 internal constant MIN_DEP = 1e6;
    uint64 internal constant VEST_W = 1 days; // NON-ZERO by rule: a zero default hides the mechanism it disables

    uint256 internal constant RIG_MIN_DEBT = 10e6; // the fixture's floor ticket, under the shipped 5000e6 so small rig draws open
    uint64 internal constant RIG_TIMELOCK = 1 days; // the shortest the vault admits, so `_list` waits as little as it can
    uint16 internal constant RIG_BUFFER_BPS = 5000; // half the record's 2x-par minimum: the door lends at par gridded down

    /// @dev One crank leg the rig created. The VAULT keeps no position list, so the rig keeps its own.
    struct Leg {
        uint256 loanId;
        uint256 lot;
    }

    Leg[] internal legs;
    mapping(uint256 => bool) internal legSeen;

    /// @dev The quote's decimals, so a suite whose subject is arithmetic WIDTH can run at the admitted ceiling.
    /// @dev Six by default, which is what every other suite gets and what the rig has always used.
    function _quoteDecimals() internal pure virtual returns (uint8) {
        return 6;
    }

    /// @dev This rig's pair, so a price reads as its distance from par rather than as an absolute.
    /// @dev Named apart from `_tick` because a suite below already carries that name at another signature.
    /// @param offset Steps above par.
    /// @return The price in the hub's frame.
    function _tickAt(int24 offset) internal view returns (uint256) {
        return AceFixtures.priceAt(address(usdc), address(collateral), offset);
    }

    function setUp() public virtual {
        _warpTo(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", _quoteDecimals());
        collateral = new MockStakeVault(42);
        (T4, T2, SPARE) = (_tickAt(960), _tickAt(0), _tickAt(-600));
        record = new MockPersistenceRecord(address(usdc), address(collateral));
        record.setObserved(AceFixtures.px(1e18, address(usdc), address(collateral)));
        record.setMinPrice(AceFixtures.px(2e18, address(usdc), address(collateral)));
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(collateral));
        p.record = address(record);
        AceFixtures.Deployment memory d = AceFixtures.deploy(p);
        (ace, positionManager, read, mid) = (d.ace, d.positionManager, d.read, d.id);
        lens = new AceLens(address(ace));
    }

    /// @dev Approve the hub for `amt`: every market here is quoted in the asset, so the hub is the one spender.
    function _approveCash(bytes32, uint256 amt) internal {
        usdc.approve(address(ace), amt);
    }

    /// @dev The floor the rig builds each new row's record at; zero means the rig's default of twice par.
    /// @dev The door lends at the row's buffered minimum, so this also fixes the price of the market `_newVault` names `mid`.
    uint256 internal vaultMinPrice;

    /// @dev A row on `coll` over a FRESH record on the asset pair, reassigned to `record` because the suites drive prices through it.
    /// @dev A week-long term at the shipped rate, and no cap; the door lends at half the record's minimum, gridded down.
    /// @param coll The collateral token.
    /// @return The row.
    function _row(address coll) internal returns (Row memory) {
        record = new MockPersistenceRecord(address(usdc), coll);
        record.setObserved(AceFixtures.px(1e18, address(usdc), coll));
        record.setMinPrice(vaultMinPrice != 0 ? vaultMinPrice : AceFixtures.px(2e18, address(usdc), coll));
        return Row({
            record: address(record),
            bufferBps: RIG_BUFFER_BPS,
            baseBps: uint16(PocDeployConfig.BASE_BPS),
            minTenor: ProtocolPolicy.MIN_TENOR,
            maxTenor: ProtocolPolicy.MAX_TENOR,
            cap: type(uint192).max
        });
    }

    /// @dev The rig collateral listed on a fresh row, for a vault's constructor.
    function _listing() internal returns (Listing[] memory l) {
        l = new Listing[](1);
        l[0] = Listing({collateral: address(collateral), row: _row(address(collateral))});
    }

    /// @dev The deploy config every suite shares; a suite overrides fields on the returned struct.
    /// @dev It names the rig guardian, so a row about a standing loss can exempt its pot from the entry gate with `_waivePots`.
    function _cfg(uint16 perfFeeBps) internal view returns (VaultConfig memory) {
        return VaultConfig({ace: address(ace), asset: address(usdc), curator: curator, guardian: rigGuardian, perfFeeBps: perfFeeBps, vestWindow: VEST_W});
    }

    /// @dev The vault's guardian exempts every pot standing now, so the loss stays standing while entry reopens over it.
    function _waivePots(CuratorVault v) internal {
        (, uint256 s) = ace.lenderUnresolved(address(v), v.asset());
        vm.prank(v.GUARDIAN());
        v.exemptDeadPots(s);
    }

    /// @dev A production vault listing the rig collateral from deploy. `mid` follows the newest vault.
    function _newVault(uint16 perfFeeBps) internal returns (CuratorVault v) {
        v = _deploy(_cfg(perfFeeBps), "Curator", "cVLT");
    }

    /// @dev Deploy a vault from `c` with the rig collateral listed, and name its door market `mid`.
    function _deploy(VaultConfig memory c, string memory name, string memory symbol) internal returns (CuratorVault v) {
        v = new CuratorVault(c, RIG_MIN_DEBT, PocDeployConfig.MIN_COVERAGE_WAD, RIG_TIMELOCK, _listing(), name, symbol);
        mid = _doorMarket(v, address(collateral));
    }

    /// @dev The market `v`'s door opens on `coll` at the record's current print, created at the hub if it is not there yet.
    /// @dev Anyone may create a market naming a lender; it lends nothing until that lender's door funds it.
    function _doorMarket(CuratorVault v, address coll) internal returns (bytes32 id) {
        MarketParams memory p;
        (id, p,) = v.previewTerms(_request(coll, 0, 0), "");
        if (ace.idToMarketParams(id).lender == address(0)) ace.createMarket(p);
    }

    /// @dev List `coll` on `v` after deploy: the curator submits a fresh row, the timelock passes, and anyone accepts it.
    function _list(CuratorVault v, address coll) internal returns (Row memory row) {
        row = _row(coll);
        vm.prank(curator);
        v.submitCollateral(coll, row);
        _warpBy(RIG_TIMELOCK);
        v.accept(coll);
    }

    /// @dev A door request for `units` of `coll` drawing `principal` over the row's shortest term, unarmed, with no floors.
    function _request(address coll, uint256 units, uint256 principal) internal pure returns (BorrowRequest memory) {
        return BorrowRequest({collateral: coll, units: units, principal: principal, tenor: 0, arm: false, minPayout: 0, minBufferWad: 0, deadline: 0});
    }

    /// @dev A USDC-quoted market whose ONE lender is `lender`, for NON-VAULT lenders: a vault lends only in markets its door opens.
    function _gatedMarket(address lender) internal returns (bytes32) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(collateral));
        p.record = address(record);
        p.lender = lender;
        p.deleverageFloorEpsBps = ProtocolPolicy.DELEVERAGE_FLOOR_EPS_BPS;
        p.deleverageBandBps = 3000; // the keeper crank a suite drives
        p.deleverageTargetBps = 4000;
        p.deleverageStopBps = 1;
        return ace.createMarket(p);
    }

    function _lpDeposit(CuratorVault v, address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(v), amt);
        shares = v.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev Borrow `principal` against `COLL` through the door of the vault lending in `mid`; the borrower takes the cash and the title.
    function _open(uint256 principal) internal returns (uint256 loanId) {
        return _borrow(CuratorVault(ace.idToMarketParams(mid).lender), principal);
    }

    /// @dev Borrow `principal` against `COLL` of the rig collateral through `v`'s door as the rig borrower.
    function _borrow(CuratorVault v, uint256 principal) internal returns (uint256 loanId) {
        return _borrowOn(v, address(collateral), principal);
    }

    /// @dev Borrow `principal` against `COLL` of `coll` through `v`'s door as the rig borrower, who pledges to the vault.
    function _borrowOn(CuratorVault v, address coll, uint256 principal) internal returns (uint256 loanId) {
        MockStakeVault(coll).mint(borrower, COLL);
        vm.startPrank(borrower);
        MockStakeVault(coll).approve(address(v), COLL);
        loanId = v.borrow(_request(coll, COLL, principal), "", "");
        vm.stopPrank();
    }

    /// @dev Remember a leg so the hub-truth walk and `_crankAll` can find it later.
    /// @dev NO CLASS ID AND NO TICK: units are gone and a market names one price, so a leg is a (loan, lot).
    function _track(uint256 loanId, uint256 lot) internal {
        uint256 k = uint256(keccak256(abi.encode(loanId, lot)));
        if (legSeen[k]) return;
        legSeen[k] = true;
        legs.push(Leg(loanId, lot));
    }

    /// @dev THE CRANK TAKES NO MARKET. The three variants below survive as call-site shorthand, and each
    /// @dev sweeps the vault's whole pool: the hub keys the credit by (lender, quote), so nothing is finer.
    /// @dev `price` and `lotIndex` are ignored, but the arity stays so a call site reads as the same step.
    function _crank(CuratorVault v, uint256 loanId, uint256 price, uint256 lotIndex) internal {
        price;
        _track(loanId, lotIndex);
        v.crank();
    }

    /// @dev Track the loan's one position, then sweep the vault once.
    /// @dev The empty case still skips the crank: a loan with neither a live claim nor a pot funded nothing.
    function _crankAllTicks(CuratorVault v, uint256 loanId, uint256 lotIndex) internal {
        bytes32 m = ace.loanMarket(loanId);
        if (read.claimOf(m, loanId) == 0 && read.invPotOf(m, loanId) == 0) return;
        _track(loanId, lotIndex);
        v.crank();
    }

    function _crankByLoan(CuratorVault v, uint256 loanId) internal {
        _crankAllTicks(v, loanId, 0);
    }

    uint256 internal constant CLASS_DRAW = 100e6; // one position's draw, comfortably over the rig's `minDebt`

    /// @dev Build at least `target` carried positions, one door borrow per round; `band` is tracked and ignored.
    function _buildClasses(CuratorVault v, uint256 target, uint256 band) internal {
        band;
        for (uint256 round; legs.length < target; round++) {
            _crankAllTicks(v, _borrow(v, CLASS_DRAW), round);
        }
    }

    function _buildClasses(CuratorVault v, uint256 target) internal {
        _buildClasses(v, target, 16);
    }

    /// @dev A lap PLUS the wait that RECOGNIZES what it banked, for tests whose subject is the amount.
    function _crankAndRecognize(CuratorVault v) internal {
        _crankAll(v);
        _warpBy(VEST_W);
    }

    /// @dev The same lap behind an EXTERNAL call, so a fuzz driver can try/catch it.
    function crankAllExternal(CuratorVault v) external {
        _crankAll(v);
    }

    /// @dev Sweep THIS vault, whole: one call collects everything the hub owes it into its own balance.
    function _crankAll(CuratorVault v) internal {
        v.crank();
    }

    function _repay(uint256 loanId, uint256 amt) internal {
        usdc.mint(borrower, amt);
        vm.startPrank(borrower);
        _approveCash(ace.loanMarket(loanId), amt);
        ace.repay(loanId, amt);
        vm.stopPrank();
    }

    function _finalize(uint256 loanId) internal {
        MockPersistenceRecord r = MockPersistenceRecord(ace.idToMarketParams(ace.loanMarket(loanId)).record);
        r.setBelow(true);
        vm.prank(keeper);
        ace.finalize(loanId);
        r.setBelow(false);
    }

    /// @dev Buy a settled class's pot at the hub's own ask; the proceeds are the vault's recovery.
    /// @dev At the FIRST second the hub allows it: settled inventory rests before a stranger's ask opens.
    function _buyPot(address who, uint256 loanId, uint256 stableIn) internal returns (uint256 filled) {
        _warpAtLeastTo(read.inventoryAskOpensAt(loanId));
        usdc.mint(who, stableIn);
        vm.startPrank(who);
        _approveCash(ace.loanMarket(loanId), stableIn);
        (, filled) = ace.buyInventory(loanId, stableIn, 0, who);
        vm.stopPrank();
    }

    /// @dev A DISTINCT market on the same quote and collateral; `minDebt` gives it its own id.
    /// @dev No vault lends here -- it is the FOREIGN market, for refusal tests and stranger activity.
    /// @dev THE LENDER IS NAMED BY THE CALLER, and must be: sole tenancy refuses every address but the one it names.
    function _marketLike(uint256 minDebt, address lender) internal returns (bytes32) {
        MarketParams memory p = AceFixtures.marketParams(address(usdc), address(collateral));
        MockPersistenceRecord r = new MockPersistenceRecord(address(usdc), address(collateral));
        r.setObserved(AceFixtures.px(1e18, address(usdc), address(collateral)));
        r.setMinPrice(AceFixtures.px(2e18, address(usdc), address(collateral)));
        p.record = address(r);
        p.minDebt = minDebt;
        p.lender = lender;
        return ace.createMarket(p);
    }

    /// @dev Lend directly to the hub as `who`, in a NAMED market; a market refuses everyone but its lender.
    function _lendDirectIn(address who, bytes32 market, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        _approveCash(market, amount);
        ace.deposit(market, amount);
        vm.stopPrank();
    }

    uint256 internal gifts; // each gift lends through its own donor, so each is its own market

    /// @dev A counted rise of `amount`: the asset lands in the vault's balance, which NAV counts.
    function _gift(CuratorVault v, uint256 amount) internal {
        _giftPart(v, amount, amount);
    }

    /// @dev The same counted rise, of any size down to one wei: the donor lends `lent` and withdraws only `amount` to the vault.
    function _giftPart(CuratorVault v, uint256 lent, uint256 amount) internal {
        address donor = address(uint160(0xD0D0 + ++gifts));
        MarketParams memory p = AceFixtures.marketParams(v.asset(), address(collateral));
        p.lender = donor;
        bytes32 gift = ace.createMarket(p);
        _lendDirectIn(donor, gift, lent);
        vm.prank(donor);
        ace.withdraw(gift, amount, address(v), 0);
    }

    /// @dev Entry is open: both max views uncapped, and `deposit` mints at the price `previewDeposit` quotes.
    /// @return shares The shares the entry minted.
    function _assertEntryAdmitted(CuratorVault v, address who) internal returns (uint256 shares) {
        assertEq(v.maxDeposit(who), type(uint256).max, "maxDeposit shut an entry the vault takes");
        assertGt(v.maxMint(who), 0, "and so did maxMint");
        uint256 quoted = v.previewDeposit(1_000e6);
        shares = _lpDeposit(v, who, 1_000e6);
        assertEq(shares, quoted, "the entrant was not admitted at the quoted trough price");
    }

    /// @dev Entry waits on an unsold pot: both max views read zero, and `deposit` reverts `InventoryUnsold` and mints no share.
    function _assertEntryWaitsForTheSale(CuratorVault v, address who) internal {
        assertEq(v.maxDeposit(who), 0, "maxDeposit advertised an entry the unsold pot shuts");
        assertEq(v.maxMint(who), 0, "and so did maxMint");
        uint256 held = v.balanceOf(who);
        usdc.mint(who, 1_000e6);
        vm.startPrank(who);
        usdc.approve(address(v), 1_000e6);
        vm.expectRevert(AceVault.InventoryUnsold.selector);
        v.deposit(1_000e6, who);
        vm.stopPrank();
        assertEq(v.balanceOf(who), held, "the entrant was minted a share over the unsold pot");
    }

    /// @dev Open a loan in a NAMED foreign market, whose lender rests its own cash there.
    function _openIn(bytes32 market, uint256 principal) internal returns (uint256 loanId) {
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(positionManager), COLL);
        loanId = ace.open(market, COLL, principal, 0, borrower, OpenBounds(0, 0, 0));
        vm.stopPrank();
    }

    /// @dev Redeem a holder's whole position for cash; the exit pays no title.
    /// @dev A REQUEST AND A CLAIM, not an instant redeem: the claim reaches all of exitable and releases a vesting pile to the last holders out.
    function _redeemAll(CuratorVault v, address who) internal returns (uint256 assets) {
        return _requestAndClaim(v, who, v.balanceOf(who));
    }

    /// @dev Redeem `num/den` of a holder's position.
    function _redeemFrac(CuratorVault v, address who, uint256 num, uint256 den) internal returns (uint256 assets) {
        return _requestAndClaim(v, who, (v.balanceOf(who) * num) / den);
    }

    /// @dev The whole exit, end to end: request the shares, then claim all of the request exitable cash covers now.
    /// @dev What it cannot cover stays requested, and the request holds exitable cash from lending until a later claim.
    function _requestAndClaim(CuratorVault v, address who, uint256 shares) internal returns (uint256 assets) {
        vm.startPrank(who);
        v.requestExit(shares);
        uint256 m = v.maxClaim(who);
        if (m != 0) assets = v.claimExit(m, who, 0);
        vm.stopPrank();
    }

    /// @dev NAV derived from HUB-AUTHORITATIVE state plus the token balance, by a DIFFERENT call path than the vault's.
    /// @dev The vault asks the hub's own `lenderAssets` getter; this sums the lens's pools, so a wrong offset shows up as a mismatch.
    /// @dev Cash is the TOKEN BALANCE: the vault holds its cash, and nothing it funds rests between calls.
    /// @dev THE ARITHMETIC NECESSARILY AGREES WITH `grossNav`, so this is a consistency check and not a proof.
    function _hubTruthNav(CuratorVault v) internal view returns (uint256 nav) {
        (uint256 resting, uint256 lent, uint256 owed) = lens.lenderPools(address(v), v.asset());
        nav = usdc.balanceOf(address(v)) + resting + lent + owed;
    }

    /// @dev A door borrow the vault's lendable cannot fund is refused by the placement check before anything moves.
    /// @param principal The draw to attempt; it plus its roll-hold growth must exceed `lendable`.
    function _expectBorrowPastLendable(CuratorVault v, uint256 principal) internal {
        collateral.mint(borrower, COLL);
        vm.startPrank(borrower);
        collateral.approve(address(v), COLL);
        vm.expectRevert(AceVaultFlows.OverLendable.selector);
        v.borrow(_request(address(collateral), COLL, principal), "", "");
        vm.stopPrank();
    }

    /// @dev True only for the first leg naming a given class, so a multi-lot class counts once.
    function _firstLegOfClass(uint256 i) internal view returns (bool) {
        for (uint256 j; j < i; j++) {
            if (legs[j].loanId == legs[i].loanId) return false;
        }
        return true;
    }

    /// @dev Positions the rig funded that the vault is still IN: a live claim, or a settled pot it may take.
    function _carriedClasses(CuratorVault v) internal view returns (uint256 n) {
        for (uint256 i; i < legs.length; i++) {
            bytes32 m = ace.loanMarket(legs[i].loanId);
            if (ace.idToMarketParams(m).lender != address(v)) continue;
            if (!_firstLegOfClass(i)) continue;
            if (read.claimOf(m, legs[i].loanId) != 0 || read.invPotOf(m, legs[i].loanId) != 0) n++;
        }
    }

    /// @dev Collateral the vault can still take across every position the rig funded, off the hub's own pots.
    function _unitsHeld(CuratorVault v) internal view returns (uint256 sum) {
        for (uint256 i; i < legs.length; i++) {
            bytes32 m = ace.loanMarket(legs[i].loanId);
            if (ace.idToMarketParams(m).lender != address(v)) continue;
            if (!_firstLegOfClass(i)) continue;
            sum += read.invPotOf(m, legs[i].loanId);
        }
    }

    /// @dev Every loan the rig has opened, deduped, for the strand monitor.
    function _loansUsed() internal view returns (uint256[] memory ids) {
        uint256 n;
        uint256[] memory tmp = new uint256[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            bool seen;
            for (uint256 j; j < n; j++) {
                if (tmp[j] == legs[i].loanId) seen = true;
            }
            if (!seen) tmp[n++] = legs[i].loanId;
        }
        ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = tmp[i];
        }
    }
}
