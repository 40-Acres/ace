// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LenderCollateral, LenderUnresolved, Storage} from "./Types.sol";

using SafeERC20 for IERC20;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Constants} from "./Constants.sol";
import {Transfers} from "./libraries/Transfers.sol";
import {Recipients} from "./libraries/Recipients.sol";
import {LoanAccounting} from "./libraries/LoanAccounting.sol";
import {PositionTitleNFT} from "../positions/PositionTitleNFT.sol";
import {MarketInit} from "./MarketInit.sol";
import {BelowCallerFloor, Lender} from "./Lender.sol";
import {Settlement} from "./Settlement.sol";
import {Deleverage} from "./Deleverage.sol";
import {Borrower, LoanMatured, WithdrawalExceedsCollateral} from "./Borrower.sol";
import {Orders} from "./Orders.sol";
import {Cfg, LenderPools, Loan, LoanBook, Market, MarketParams, MigrateArgs, Order, RecordState, OpenBounds} from "./Types.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";

error NoMarket(); // no market at this id: the param hash was never created
error SelfCallOnly(); // the hub's own re-entry hop; nobody outside may call it
error PushRefused(); // the quote refused a payout: a push's catch swallows it, the strict sweep reverts with it; a BARE selector
error NoRecordPrice(); // the record cannot produce a windowed minimum: judgment-spending verbs refuse rather than guess
error InventoryHeld(); // the hold has not elapsed, or the loan is live: where the market has the ask, a settled pot's ask opens later
error NoInventoryAsk(); // the market sells no settled pot, at any time: its lender's `redeemInKind` is the only door one leaves by
error SyntheticCapExceeded(); // units left custody beyond what backed burns have credited
error NotAuthorized(); // neither the borrower nor an operator they signed for
error SigExpired(); // the operator signature's own deadline passed
error BadNonce(); // the operator signature replays a nonce already spent
error BadSig(); // the borrower neither signed this digest nor validated it; a wallet that reverts lands here too
error LoanClosed(); // the loan is retired: nothing may touch it
error NotBorrower(); // only the loan's title holder may withdraw its collateral, and a title moves only from its holder
error ZeroCollateral(); // the withdrawal would strip the loan bare: an unsecured loan never settles
error ZeroWithdrawal(); // a zero-unit request; nothing to take, and the loan is untouched
error BelowWithdrawLine(); // a withdrawal leg falling under the coverage line: the settlement slack refuses it, not the trigger
error NotPositionTitle(); // retitle answers to the hub's own PositionTitleNFT collection, nothing else
error RetitleToZero(); // title must always resolve; a live loan held by zero would strand what its close credits its holder
error RetitleToCollection(); // the title collection can neither move its own token nor claim what the loan credits its holder
error RetitleToTreasury(); // the treasury, in production a revenue router, can neither claim a holder's credit nor move the title on
error PushGasShort(); // the caller's limit leaves a push less than its fixed budget plus the tail: resend with more gas
error PushGasOutOfRange(); // the constructor's push budget sits outside the rail
error PolicyGasOutOfRange(); // the constructor's roll-policy budget sits outside the rail

/* ========================================================================= */
/*  TABLE OF CONTENTS                                                        */
/*  1. MARKET      genesis, the open quote, the params a market was made at  */
/*  2. BORROWER    open, repay, extend, collateral, credit delegation        */
/*  3. LENDER      depth in, depth out, and what a funded loan pays back     */
/*  4. KEEPER      deleverage, the refinance door, settlement                */
/*  5. REVENUE     the protocol sweep, and the inventory bid                 */
/*  6. INTERFACES  the one ERC-165 answer; the lending position is no token  */
/*  7. POSITIONS   the hooks the positionManager and the title drive         */
/*  8. PLUMBING    multicall, the extsload pair, the per-entry config cache  */
/*  9. VIEWS       the ones on-chain callers read from the hub, not a lens   */
/* ========================================================================= */

/// @title Ace, the ACE singleton
/// @notice One immutable contract for every open credit market: the resting cash, the loans, the settlement.
/// @notice Markets are STORAGE, not deployments: `createMarket` writes a config keyed by its param hash.
/// @notice UNSUPPORTED: a QUOTE whose holder balance can fall other than by this contract's own transfer.
/// @dev The mutating surface, plus the reads an on-chain caller must take HERE rather than off a view contract.
/// @dev Declares only the events it EMITS; the linked libraries declare the rest of the hub's log surface.
/// @dev LIVENESS: quote, collateral and record are all the CREATOR'S choice.
/// @dev What follows is therefore that market's trust statement, never the hub's.
/// @dev The named borrower and lender are ADDRESS compares, never calls: `GateRefused` means a wrong party, never a sick dependency.
/// @dev The borrower rule refuses NEW credit alone, an extension included; it never blocks an exit or a settlement.
/// @dev `collect` checks neither, and pays the caller's own pool unconditionally.
/// @dev A RECORD that cannot answer refuses six verbs by name with `RecordUnreadable`.
/// @dev Draw, deposit, collateral withdrawal, deleverage, finalize and the inventory ask, and those six exactly.
/// @dev The extension predicate reads it through the TRY twin instead, so `extend` refuses by its selector.
/// @dev So a record CAN close a borrower's exit; the lender's exit reads no record and stays open.
/// @dev It can NEVER stop settlement at tenor: `forceClose` CALLS no record.
/// @dev Whether a record is WIRED is still read at every settle, and it sets how much of the lot the lenders take.
/// @dev A QUOTE that reverts on transfer refuses `open` and a borrower's cash-out refinance, which pay their caller in the call.
/// @dev It refuses `withdraw`, `collect`, `claimOwed`, the revenue sweep and the lender push at a terminal close.
/// @dev The piggyback sweep and the lender push each restore their own counter on a refusal; the lender's credit then waits for `collect`.
/// @dev Protocol revenue's uncapped exit is the standalone `sweepRevenue`, which reverts on a refusal and leaves the counter whole.
/// @dev An UNSUPPORTED quote's balance fall halts nothing: every outflow pays from one balance per token, so the last party out bears it.
/// @dev Settlement's TITLE transfer moves no token, so a hostile quote holds payouts and never blocks it.
/// @dev A dependency that BURNS its gas can starve the rest of the crank that fed it, which then reverts; a retry funds more.
/// @dev The one thing no dependency can do is leave a matured loan unsettleable.
contract Ace is ReentrancyGuardTransient {
    event CreditOperatorSet(address indexed borrower, address indexed operator, bool allowed);
    /// @notice Title moved. `feeEscrow` rides along because it follows the position.
    /// @dev The fee escrow is posted quote the new holder inherits: visible at transfer.
    event Retitled(uint256 indexed id, address indexed from, address indexed to, uint256 feeEscrow);

    event MarketCreated(bytes32 indexed id, address indexed quote, address indexed collateral);
    event BuyInventory(uint256 indexed loanId, address indexed payer, address indexed unitsTo, uint256 unitsOut, uint256 stableFilled);
    event RevenueSwept(bytes32 indexed market, address indexed to, uint256 amount, uint64 at);
    event RevenueSweepFailed(bytes32 indexed market, address indexed to, uint256 amount, uint64 at);
    /// @notice A lender named the contract its loans' extensions ask; zero consents to none.
    event RollPolicySet(address indexed lender, address indexed policy);

    address internal immutable TREASURY; // revenue destination, fixed at deploy; zero ships an inert sweep
    address public immutable POSITION_MANAGER; // the ONE custodian for every market's loans; never per market
    address public immutable POSITION_TITLE; // the one ERC-721 over every position, hub-scoped; tokenId == loanId
    uint256 public immutable PUSH_GAS; // the gas each swallowed push hands its callee, fixed per deploy inside the rail
    uint256 public immutable PUSH_FLOOR; // the gas a lender push demands at its read: the budget past EIP-150's 1/64, plus its tail
    uint256 public immutable SWEEP_FLOOR; // the same for the keeper piggyback's sweep, whose tail also carries its stamp and counter writes
    uint256 public immutable POLICY_GAS; // the gas a roll-policy ask hands its callee, fixed per deploy inside the rail

    bytes32 private immutable CACHED_SEPARATOR; // the domain built at construction, valid for as long as the chain id holds
    uint256 private immutable CACHED_CHAIN_ID; // the chain constructed on; a change re-derives rather than replays
    bytes32 private constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant OPERATOR_TYPEHASH = keccak256("SetOperator(address borrower,address operator,bool allowed,uint256 nonce,uint256 deadline)");

    /// @dev ERC-7201 named storage, both ledgers; the roots and accessors live in Storage.
    function _market() internal pure returns (mapping(bytes32 => Market) storage) {
        return Storage.markets();
    }

    function _book() internal pure returns (LoanBook storage) {
        return Storage.book();
    }

    /// @param treasury Where swept revenue lands; zero ships an inert sweep.
    /// @param positionManager The one positionManager, deployed FIRST at this hub's predicted address.
    /// @param pushGas The fixed gas each swallowed push hands its callee, chosen per chain from that chain's measured transfer cost.
    /// @param policyGas The fixed gas each roll-policy ask hands its callee, chosen per chain from the heaviest shipped policy's measured cost.
    /// @dev THE BINDING RAIL, and it is why the deploy order is positionManager-then-hub.
    /// @dev At this point the positionManager already has code, so the hub verifies the binding itself.
    /// @dev A wrong prediction fails closed HERE, with no operator trust and no genesis rail.
    /// @dev Both budgets are railed first; the push floors derive from the one, the tails reserve what runs after the call.
    /// @dev Constructor code is not runtime code, so this costs zero EIP-170 budget.
    constructor(address treasury, address positionManager, uint256 pushGas, uint256 policyGas) {
        if (pushGas < Constants.MIN_PUSH_GAS || pushGas > Constants.MAX_PUSH_GAS) revert PushGasOutOfRange();
        if (policyGas < Constants.MIN_POLICY_GAS || policyGas > Constants.MAX_POLICY_GAS) revert PolicyGasOutOfRange();
        TREASURY = treasury;
        require(IPositionManager(positionManager).LOAN_MANAGER() == address(this), "manager not bound here");
        POSITION_MANAGER = positionManager;
        POSITION_TITLE = address(new PositionTitleNFT(address(this)));
        CACHED_CHAIN_ID = block.chainid;
        CACHED_SEPARATOR = _buildSeparator();
        PUSH_GAS = pushGas;
        uint256 whole = (pushGas * 64 + 62) / 63; // floor(64p/63) already makes EIP-150 forward exactly p; the ceil adds one gas of margin
        PUSH_FLOOR = whole + Constants.PUSH_TAIL;
        SWEEP_FLOOR = whole + Constants.SWEEP_TAIL;
        POLICY_GAS = policyGas;
    }

    /// @notice The EIP-712 domain this hub verifies credit-delegation signatures against.
    /// @notice Re-derived whenever the chain id differs from the one at construction, so a fork replays no grant.
    /// @return The separator for the chain the call is executing on.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == CACHED_CHAIN_ID ? CACHED_SEPARATOR : _buildSeparator();
    }

    /// @dev The domain over the LIVE chain id; the cache is an optimisation of this and never an alternative to it.
    function _buildSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("ACE")), keccak256(bytes("1")), block.chainid, address(this)));
    }

    /* ============================== 1. MARKET ============================== */

    /// @notice Create a market. `id` is the hash of its params: wrong params address a different market.
    /// @notice In a RECORDLESS market only `MAX_PRICE` caps the price: a price far over the collateral's worth lends against atoms.
    /// @notice No hub rail tells that from a real 0-decimal item worth more than `minPrincipal` a unit; the creator, and any allocator, is the check.
    /// @dev There is no allocator.
    /// @dev DEPLOYS NOTHING: custody is one pot per collateral on the custodian, reached by ledger, not by address.
    /// @dev A duplicate id reverts atomically inside `init`, leaving no state behind.
    /// @dev Unguarded: it interviews creator-chosen contracts through STATICCALLS alone, so none of them can re-enter.
    /// @dev Every write is a pure function of `p`: a reentrant call lands on another id or reverts on the duplicate.
    function createMarket(MarketParams calldata p) external returns (bytes32 id) {
        id = keccak256(abi.encode(p));
        MarketInit.init(_market()[id], p);
        emit MarketCreated(id, p.quote, p.collateral);
    }

    /// @notice What `open` would do with these arguments. Reverts wherever `open` reverts.
    /// @notice `borrower` is the address that would HOLD the loan, and the market's borrower rule is checked against it.
    /// @dev A view on the hub because the draw preview takes storage pointers a lens cannot reach.
    /// @dev NOT gated on `_open`'s credit-operator grant: it asks if the draw is admissible for the borrower, never if the caller may open it.
    /// @dev A lens holds no grant, so a gated quote would refuse every lens caller.
    /// @dev `nonReentrantView`: a quote taken mid-interaction would see half-updated state.
    function previewOpen(bytes32 id, uint256 collateralUnits, uint256 principal, uint64 tenor, address borrower, OpenBounds calldata bnd)
        external
        view
        nonReentrantView
        returns (Borrower.Quote memory)
    {
        Cfg memory c = _cache(id);
        tenor = Borrower.tenorOrMin(tenor, c.p.minTenor); // the open doors' sentinel; a quote that skipped it refused a legal draw
        return Borrower.previewOpen(_market()[id], c, Borrower.OpenArgs(id, borrower, msg.sender, msg.sender, collateralUnits, principal, tenor, bnd));
    }

    /// @notice The one config getter: an integrator verifies an id resolves to the params it expects.
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory) {
        return _market()[id].p;
    }

    /* ============================= 2. BORROWER ============================= */

    /// @notice Opens a terminal loan against escrowed collateral, funded by the market's resting cash.
    /// @notice THE ONE DOOR: every argument shape is a default here, never a separate function.
    /// @dev `tenor` 0 takes `minTenor`; an all-zero `bnd` is boundless; `borrower` may be the caller.
    /// @dev Opening in another party's name needs their `setCreditOperator` grant, enforced by `_open`.
    /// @dev The deleverage band is a LEVEL test on the record, so an open inside it is crankable in the same block.
    /// @dev A `bnd.minBufferWad` of at least `deleverageBandBps * 1e14` rules that out; a smaller buffer does not.
    /// @param id The market to draw from.
    /// @param collateralUnits Collateral to escrow.
    /// @param principal Quote to draw.
    /// @param tenor The term, or 0 for `minTenor`.
    /// @param borrower Who holds title and the debt.
    /// @param bnd Open-time bounds that remove the race, or all-zero for none.
    /// @return The new loan id.
    function open(bytes32 id, uint256 collateralUnits, uint256 principal, uint64 tenor, address borrower, OpenBounds calldata bnd)
        external
        nonReentrant
        returns (uint256)
    {
        Cfg memory c = _cache(id);
        tenor = Borrower.tenorOrMin(tenor, c.p.minTenor);
        return _open(c, Borrower.OpenArgs(id, borrower, msg.sender, msg.sender, collateralUnits, principal, tenor, bnd));
    }

    /// @notice `open` funded by a Permit2 SignatureTransfer on the collateral.
    /// @notice Its own door because the signature is calldata the plain form has no place for.
    /// @dev This door passes msg.sender as the permit owner, so only the signer's own transaction spends it.
    /// @dev The hub is the payer: it takes the collateral by permit and the positionManager pulls it on.
    /// @param id The market to draw from.
    /// @param collateralUnits Collateral to escrow.
    /// @param principal Quote to draw.
    /// @param tenor The term, or 0 for `minTenor`.
    /// @param borrower Who holds title and the debt.
    /// @param bnd Open-time bounds, or all-zero for none.
    /// @param permit2 The SignatureTransfer blob.
    /// @return The new loan id.
    function openWithPermit2(
        bytes32 id,
        uint256 collateralUnits,
        uint256 principal,
        uint64 tenor,
        address borrower,
        OpenBounds calldata bnd,
        bytes calldata permit2
    ) external nonReentrant returns (uint256) {
        Cfg memory c = _cache(id);
        Borrower.pullCollateralPermit(c, collateralUnits, permit2);
        tenor = Borrower.tenorOrMin(tenor, c.p.minTenor);
        return _open(c, Borrower.OpenArgs(id, borrower, address(this), msg.sender, collateralUnits, principal, tenor, bnd));
    }

    /// @notice Grants or revokes an operator's right to open loans in the caller's name.
    /// @notice Spends ONE nonce, so it kills the signature standing at that nonce and ARMS the one after it.
    /// @dev CREDIT delegation, not the title's ERC-721 `setApprovalForAll`; `_open` is the one gate every open passes.
    /// @dev The operator cannot repay, refinance, settle or withdraw the borrower's existing loans.
    /// @dev The one widening: an operator that is a loan's market lender may `extend` it, in cash the operator pays.
    /// @dev NEVER short-circuit on an unchanged value: `setCreditOperator(anyone, false)` is the borrower's nonce burn.
    /// @dev Unguarded: two storage writes and an event, reaching no external code at all.
    function setCreditOperator(address operator, bool allowed) external {
        _book().creditOperatorNonce[msg.sender]++;
        _book().creditOperator[msg.sender][operator] = allowed;
        emit CreditOperatorSet(msg.sender, operator, allowed);
    }

    /// @notice Sets a CREDIT delegation grant from a borrower's signature, relayed by anyone.
    /// @notice Takes ERC-1271 as well as ECDSA, so a smart account can use the RELAYED door instead of sending its own tx.
    /// @dev A borrower with code is asked to validate; one without is recovered. Code presence is read per call, never remembered.
    /// @dev The nonce is spent BEFORE the borrower's code is reached; NEVER move the verify above it.
    /// @dev nonReentrant: validating a contract signature is an external call into a borrower-supplied address.
    /// @param sig An ECDSA signature packed r-s-v, or whatever the borrower's own contract validates.
    function setCreditOperatorWithSig(address borrower, address operator, bool allowed, uint256 nonce, uint256 deadline, bytes calldata sig)
        external
        nonReentrant
    {
        if (block.timestamp > deadline) revert SigExpired();
        if (nonce != _book().creditOperatorNonce[borrower]++) revert BadNonce();
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), keccak256(abi.encode(OPERATOR_TYPEHASH, borrower, operator, allowed, nonce, deadline))));
        if (!SignatureChecker.isValidSignatureNowCalldata(borrower, digest, sig)) revert BadSig();
        _book().creditOperator[borrower][operator] = allowed;
        emit CreditOperatorSet(borrower, operator, allowed);
    }

    /// @notice Re-anchor a live loan in place at its own tenor from now: same id, same title, the debt unchanged, the fee on the time added, in cash.
    /// @notice The new expiry is now plus the loan's own tenor, and the extended loan is admitted as a new one at `min(price, record)`.
    /// @notice It lands only before expiry and never in the term's open second: those refuse `LoanMatured` and `ExtensionAddsNoTime`.
    /// @notice The fee never exceeds the fee on the loan's whole tenor: a caller signing for a later landing signs for that.
    /// @notice It needs the market lender's roll policy to return its selector; no policy, or any other answer, refuses `PolicyRefused`.
    /// @notice The borrower extends, and so does the market lender holding the borrower's credit grant; whoever calls pays the fee.
    /// @notice A lender pays on the holder's behalf: the unearned part of the escrow it funds refunds to the holder at close, never to the payer.
    /// @notice It pulls quote as `repay` does, so a quote that refuses the caller leaves the loan to mature and `forceClose` to settle it.
    /// @notice A limit that cannot hand the policy its whole budget past EIP-150's 1/64 reverts `PolicyGasShort`: resend with more gas.
    /// @dev `msg.data[0:0]` is the empty-blob sentinel: it routes the pull to the caller's allowance, as `repay` does.
    /// @param id The loan to extend.
    /// @param minBufferWad The least admissibility buffer the caller accepts.
    /// @param data The caller's payload for the lender's roll policy.
    /// @return fee The extension's fee.
    function extend(uint256 id, uint256 minBufferWad, bytes calldata data) external nonReentrant returns (uint256 fee) {
        return _extend(id, minBufferWad, data, msg.data[0:0]);
    }

    /// @notice `extend` with the fee funded by a Permit2 SignatureTransfer on the quote; an empty blob is the plain allowance pull.
    /// @dev This door passes msg.sender as the permit owner, so only the signer's own transaction spends it.
    /// @param permit2 The SignatureTransfer blob.
    /// @return fee The extension's fee.
    function extendWithPermit2(uint256 id, uint256 minBufferWad, bytes calldata data, bytes calldata permit2) external nonReentrant returns (uint256 fee) {
        return _extend(id, minBufferWad, data, permit2);
    }

    /// @dev Both extend doors funnel here.
    function _extend(uint256 id, uint256 minBufferWad, bytes calldata data, bytes calldata permit2) private returns (uint256) {
        bytes32 mid = _book().loans[id].market;
        return Borrower.extend(_book(), _market()[mid], _cache(mid), id, minBufferWad, data, permit2);
    }

    /// @notice What `extend` would do if `caller` sent it now.
    /// @notice It takes the caller as an argument, never `msg.sender`, so a lens or a router asks for the borrower it serves.
    /// @notice A preview is reliable only for a policy that reads no lock and no caller: one may answer a preview and a verb apart.
    /// @dev `nonReentrantView`: the answer reads a loan a mid-call sees torn; the policy is asked unlocked here.
    /// @param caller The address that would call `extend`.
    /// @return ok Whether the extension would land.
    /// @return reason The first failing leg's selector; zero when `ok`.
    /// @return fee The extension's fee; zero when refused.
    function tryExtend(uint256 id, uint256 minBufferWad, bytes calldata data, address caller)
        external
        view
        nonReentrantView
        returns (bool ok, bytes4 reason, uint256 fee)
    {
        return Borrower.tryExtend(_book(), _cache(_book().loans[id].market), id, minBufferWad, data, caller);
    }

    /// @notice Withdraw collateral above this loan's COVERAGE LINE, at the live fold of funding floor and record.
    /// @notice The line exceeds what the debt secures by one atom, which is what settlement's own ceiling costs.
    /// @notice `to` is the caller's own choice, and the caller is the title holder: a token's refusal of it is theirs to avoid.
    /// @notice `to` is never zero, the hub or the positionManager, refused before the amount, the clock or the record is read.
    /// @dev The line bounds settlement, not the deleverage band's LEVEL test, so a withdrawal into the band is crankable in the same block.
    /// @param id The loan to withdraw from.
    /// @param units Collateral units to take.
    /// @param to Recipient of the units.
    function withdrawCollateral(uint256 id, uint256 units, address to) external nonReentrant {
        Loan storage L = _book().loans[id];
        Cfg memory c = _cache(L.market);
        Market storage M = _market()[L.market];
        if (L.closedAt != 0) revert LoanClosed();
        if (msg.sender != L.borrower) revert NotBorrower();
        Recipients.check(to, c.positionManager);
        if (units == 0) revert ZeroWithdrawal();
        if (block.timestamp >= L.expiry) revert LoanMatured();

        if (units > L.collateralUnits) revert WithdrawalExceedsCollateral();
        L.collateralUnits -= units; // effect before the gate: every predicate reads the post state
        if (L.collateralUnits == 0) revert ZeroCollateral(); // a zero-unit loan never settles

        uint256 floor = LoanAccounting.fundingFloor(M, c, id);
        uint256 cap = Borrower.persistedPrice(c); // live windowed-min; 0 fails closed
        floor = Math.min(floor, cap);
        if (L.collateralUnits < Borrower.coverageLine(c, L.debt, floor)) revert BelowWithdrawLine();

        emit Borrower.CollateralWithdrawn(id, to, units, L.collateralUnits, Borrower.triggerPrice(L, c)); // before the release, as the refinance leg logs
        IPositionManager(POSITION_MANAGER).release(id, to, units); // interaction last
    }

    /// @notice Pays debt down, retiring the loan's claim by exactly what was paid.
    /// @notice Full repayment closes the loan, and pushes the lender's pooled quote credit to them, swallowed.
    /// @notice That push is STRICT: a closing repay whose limit is short of its fixed budget plus the tail reverts `PushGasShort`.
    /// @notice No repay may leave a live loan under its debt floor, half `minPrincipal`, whoever sends it: pay it off or leave at least that.
    /// @dev `msg.data[0:0]` is the empty-blob sentinel: it routes `_repay` back to the allowance pull.
    function repay(uint256 id, uint256 amount) external nonReentrant {
        _repay(id, amount, msg.data[0:0]);
    }

    /// @notice `repay` funded by a Permit2 SignatureTransfer; anyone may still repay any loan. A closing one reverts `PushGasShort` as `repay` does.
    /// @dev This door passes msg.sender as the permit owner, so only the signer's own transaction spends it.
    function repayWithPermit2(uint256 id, uint256 amount, bytes calldata permit2) external nonReentrant {
        _repay(id, amount, permit2);
    }

    /// @dev THE CLOSING repay pays the lender out; a partial one does not, and is not stranded by that.
    /// @dev The push takes the WHOLE pool, so a partial's credit rides the next close in any market this pair runs.
    /// @dev `closedAt` is RE-READ rather than returned, so no verb below changes shape to report a close.
    function _repay(uint256 id, uint256 amount, bytes calldata permit2) private {
        bytes32 m = _book().loans[id].market;
        Cfg memory c = _cache(m);
        Borrower.repay(_book(), _market()[m], c, id, amount, permit2);
        if (_book().loans[id].closedAt != 0) _pushOwed(c);
    }

    /// @dev Every open funnels here, so the credit-delegation gate lives here once; self-borrow self-passes.
    /// @dev The title mints AT RECORD, before any external call -- never move it to the tail.
    function _open(Cfg memory c, Borrower.OpenArgs memory a) private returns (uint256 loanId) {
        if (msg.sender != a.borrower && !_book().creditOperator[a.borrower][msg.sender]) revert NotAuthorized();
        loanId = Borrower.open(_book(), _market()[a.market], c, a);
    }

    /* ====== 2b. CREDIT ORDERS: a maker's resting ask, and the fill that turns one into a loan ====== */

    /// @notice Rests an escrowed ask for credit, fillable by anyone the moment the market can serve it.
    /// @notice The maker states the BAND of trigger prices they accept; the collateral its low end implies is escrowed.
    /// @notice Only `msg.sender` may post, and only in their own name: the transaction IS the authorization.
    /// @dev No delegation path reaches here on purpose -- no signature, no operator grant, no nonce.
    /// @dev A fill takes no buffer bound, so one whose trigger tops `(1 - band)` times the record lands in the deleverage band and may be cranked at once.
    /// @dev A fresh fill needs the record's windowed minimum at or over `price`, so a `liqHigh` at or under `price * (1 - band)` keeps every fill out.
    /// @param market The market to ask against.
    /// @param principal Quote wanted.
    /// @param liqLow The trigger the escrow is sized at, plus a fill slack; fills follow the REMAINING escrow, so a full take triggers at or under it.
    /// @param liqHigh The worst trigger the maker accepts; equal to `liqLow` pins a single price.
    /// @param minFillPrincipal The maker's floor on a single fill; equal to `principal` is all-or-nothing.
    /// @param tenor The term each fill opens for, or 0 for `minTenor`.
    /// @param expiry When the ask dies; the maker's own choice, bounded by nothing, and zero never expires.
    /// @return The new order id.
    function postOrder(bytes32 market, uint256 principal, uint256 liqLow, uint256 liqHigh, uint256 minFillPrincipal, uint64 tenor, uint64 expiry)
        external
        nonReentrant
        returns (uint256)
    {
        Orders.PostArgs memory a = Orders.PostArgs(market, msg.sender, principal, liqLow, liqHigh, minFillPrincipal, tenor, expiry);
        return Orders.post(_book(), _market()[market], _cache(market), a);
    }

    /// @notice Draws against a resting order, whole or in part, opening a loan titled to its MAKER.
    /// @notice Permissionless: in practice the lender who just rested the cash fills it in the same multicall.
    /// @param id The order to fill.
    /// @param principalOut Quote to draw on this fill.
    /// @param unitsOut Collateral to carry out of the escrow.
    /// @return The loan this fill created.
    function fillOrder(uint256 id, uint256 principalOut, uint256 unitsOut) external nonReentrant returns (uint256) {
        bytes32 m = _book().orders[id].market;
        return Orders.fill(_book(), _market()[m], _cache(m), id, principalOut, unitsOut);
    }

    /// @notice Retires a resting order and returns whatever escrow is left to an address of the maker's choosing.
    /// @param id The order to retire.
    /// @param to Recipient of the remaining escrow; never zero, the hub or the positionManager, even when none is left.
    /// @return The collateral returned.
    function closeOrder(uint256 id, address to) external nonReentrant returns (uint256) {
        bytes32 m = _book().orders[id].market;
        return Orders.close(_book(), _cache(m), id, to);
    }

    /* ============================== 3. LENDER ============================== */

    /// @notice Rest cash in a market as a standing bid it can fill, at the one price the market was created at.
    /// @notice THE ONE DOOR, and it names no term: the market's own `maxTenor` is the whole maturity consent.
    /// @dev nonReentrant: the cash books before `pullQuote` moves a creator-chosen ERC20.
    /// @dev `BelowMinLot` refuses a zero lot and any lot under `minPrincipal`.
    function deposit(bytes32 id, uint256 assets) external nonReentrant {
        Lender.depositCash(_market()[id], _cache(id), id, assets);
    }

    /// @notice `deposit` funded by a Permit2 SignatureTransfer.
    /// @dev This door passes msg.sender as the permit owner, so only the signer's own transaction spends it.
    function depositWithPermit2(bytes32 id, uint256 assets, bytes calldata permit2) external nonReentrant {
        Lender.depositCashPermit(_market()[id], _cache(id), id, assets, permit2);
    }

    /// @notice Withdraw resting cash from a market to `to`; always available, it is the lender's own money.
    /// @notice LENDER-ONLY: the market names its one lender, and nobody else may take its resting cash.
    /// @notice Nothing here is held for an extension, which draws no resting cash.
    /// @dev `assets == type(uint256).max` withdraws the whole resting balance.
    /// @dev Floor-or-zero: a remainder in `(0, minPrincipal)` reverts `WouldLeaveDust`, and emptying the market always lands.
    /// @param id The market to withdraw from.
    /// @param assets Quote to take, or `type(uint256).max` for everything resting.
    /// @param to Recipient, never zero, the hub or the positionManager: the lender's own address or another wallet of theirs.
    /// @param minPaid The least the lender will accept; a draw that lands first and shrinks the fill reverts instead.
    /// @return paid What was sent.
    function withdraw(bytes32 id, uint256 assets, address to, uint256 minPaid) external nonReentrant returns (uint256 paid) {
        return Lender.withdraw(_market()[id], _cache(id), id, assets, to, minPaid);
    }

    /// @notice Send the caller's whole credit pool in one quote to `to`: fees, repayments, sale proceeds.
    /// @notice ONE CALL COVERS EVERY MARKET they run in that quote; the pool is keyed by the pair, not the market.
    /// @notice LENDER-ONLY by construction: the pool paid is `msg.sender`'s, so nobody can collect another lender's credit.
    /// @dev A terminal close pushes the whole pool home; a sale does not, so its proceeds wait here or ride the next close in this pair.
    /// @dev Between pushes it is the lender's own pull, and the ONLY way home for a refused or over-budget push no later push follows.
    /// @param quote The token the pool is denominated in.
    /// @param to Recipient, never zero, the hub or the positionManager, refused even when nothing is owed.
    /// @return paid What was sent.
    function collect(address quote, address to) external nonReentrant returns (uint256 paid) {
        return Lender.collect(quote, to, POSITION_MANAGER);
    }

    /// @notice Name the contract every extension of the caller's loans asks for consent; zero consents to none.
    /// @notice It lands at any time and binds the caller's own loans alone: the next extension asks the new policy.
    /// @param policy The caller's roll policy, or zero.
    function setRollPolicy(address policy) external nonReentrant {
        Storage.lenders().rollPolicyOf[msg.sender] = policy;
        emit RollPolicySet(msg.sender, policy);
    }

    /// @notice Take the collateral a settled loan left against its claim, in kind.
    /// @notice `to` is never zero, the hub or the positionManager, refused after the lender check and before the pot is read.
    function redeemInKind(uint256 loanId, address to) external nonReentrant returns (uint256 out) {
        bytes32 mid = _book().loans[loanId].market;
        return Lender.redeemInKind(_market()[mid], _cache(mid), loanId, to);
    }

    /// @notice Pull what a loan credited you: settlement residual, keeper sliver, close refund.
    /// @notice PULL-BASED so no payout has a fixed destination: `to` is yours, and an absent claimant loses nothing.
    /// @notice Batch several loans with `multicall`; there is deliberately no second batched verb.
    /// @param loanId The loan the credit sits against.
    /// @param to Where to send both; zero is `NoClaimLeg`, and the hub or the positionManager is refused by name.
    /// @return units Collateral units delivered.
    /// @return amount Quote delivered.
    function claimOwed(uint256 loanId, address to) external nonReentrant returns (uint256 units, uint256 amount) {
        bytes32 mid = _book().loans[loanId].market;
        return Settlement.claimOwed(_book(), _market()[mid], _cache(mid), loanId, to);
    }

    /// @notice The same pull with a destination per asset; a ZERO destination SKIPS that leg and keeps its credit.
    /// @notice For a token that refuses every address the other accepts, and for sending the two assets apart.
    /// @notice A skipped leg is deferred, never forfeited: come back for it whenever the refusal lifts.
    /// @dev Both destinations zero is refused by name; one zero is a choice and the return value says what moved.
    /// @dev A named destination is never the hub or the positionManager; both are checked before either leg moves.
    /// @param loanId The loan the credit sits against.
    /// @param toUnits Where to send the collateral, or zero to leave it credited.
    /// @param toQuote Where to send the quote, or zero to leave it credited.
    /// @return units Collateral units delivered.
    /// @return amount Quote delivered.
    function claimOwed(uint256 loanId, address toUnits, address toQuote) external nonReentrant returns (uint256 units, uint256 amount) {
        bytes32 mid = _book().loans[loanId].market;
        return Settlement.claimOwed(_book(), _market()[mid], _cache(mid), loanId, toUnits, toQuote);
    }

    /// @notice What a loan has credited one claimant and not yet paid out.
    /// @param loanId The loan to read.
    /// @param claimant The party whose entry to read.
    /// @return units Collateral units owed.
    /// @return amount Quote owed.
    function owedOf(uint256 loanId, address claimant) external view returns (uint256 units, uint256 amount) {
        return (_book().unitsOwed[loanId][claimant], _book().quoteOwed[loanId][claimant]);
    }

    /// @notice The cash resting in one market, which under sole tenancy IS its lender's balance there, and all of it a fresh draw may take.
    function restingOf(bytes32 id) external view returns (uint256) {
        return _market()[id].s.cash;
    }

    /// @notice A lender's whole position in one quote: resting cash, drawn at par, and uncollected credit.
    /// @notice POOLED ACROSS THEIR MARKETS, so a vault prices its shares off THREE reads however many it runs.
    /// @dev GUARDED by `nonReentrantView`, unlike the raw getters: a share price is built on this, and a torn read mints wrong.
    /// @dev `owed` is LEDGER CREDIT that `collect` pays whole, or refuses while the hub's quote balance is short of it.
    /// @dev The three aggregates move mid-body on the draw, repay, deleverage and settlement paths.
    /// @dev A pair that never lent reads zero rather than reverting, exactly as the raw getters do.
    /// @param lender The lender to total.
    /// @param quote The token the pool is denominated in.
    /// @return resting + lent + owed for this pair.
    function lenderAssets(address lender, address quote) external view nonReentrantView returns (uint256) {
        LenderPools storage pool = Storage.lenders().pools[lender][quote];
        return pool.resting + pool.lent + pool.owed;
    }

    /// @notice What a `collect` would pay this lender in this quote right now: the uncollected leg alone.
    /// @notice FOR AN ON-CHAIN CONSUMER pricing a redemption, which must promise spendable cash and not a position.
    /// @notice NOT `lenderAssets`, and the difference is the whole point: that sum counts principal still out on loan.
    /// @dev GUARDED by `nonReentrantView` as the sum above is: an exit priced mid-body would pay against a torn ledger.
    /// @dev ONE LEG AND NOT THREE: `owed` is exactly what `collect` pays and zeroes, which fixes its meaning in code.
    /// @dev NO POOLED `lent` OR `resting` TWIN HERE: `lenderAssets` carries their sum, and `lenderByCollateral` splits `lent` by collateral.
    /// @dev LEDGER CREDIT, NEVER CASH RECEIVED: a quote taking a fee on the way out delivers less than this promises.
    /// @dev No plain getter serves this: the pools sit under a namespaced root, and a generated one would carry no guard.
    /// @param lender The lender to ask about.
    /// @param quote The token the pool is denominated in.
    /// @return The pooled uncollected credit across every market this lender runs in `quote`.
    function lenderOwed(address lender, address quote) external view nonReentrantView returns (uint256) {
        return Storage.lenders().pools[lender][quote].owed;
    }

    /// @notice How many settled loans across this lender's markets in this quote still hold unsold inventory, and how many ever left a pot.
    /// @notice A lender pricing entry off `lenderAssets` reads `unsoldPots` first: nonzero is a loss booked whose recovery has not landed.
    /// @notice Gate on `unsoldPots`, never on `settledPots`, which is nonzero for good after the first default.
    /// @dev GUARDED by `nonReentrantView` as the pools are: an entry gated on this must not read it mid-settlement or mid-sale.
    /// @dev A pot counts as unsold from its settlement until a buy or the lender's in-kind redeem empties it; a partial sale leaves it counted.
    /// @param lender The lender to ask about.
    /// @param quote The token the pool is denominated in.
    /// @return unsoldPots The count of this pair's non-empty settled pots.
    /// @return settledPots Every settlement in this pair that left a pot; it never falls, so the same `unsoldPots` over a higher one is a new pot.
    function lenderUnresolved(address lender, address quote) external view nonReentrantView returns (uint256 unsoldPots, uint256 settledPots) {
        LenderUnresolved storage u = Storage.lenders().unresolved[lender][quote];
        return (u.unsoldPots, u.settledPots);
    }

    /// @notice One lender's footprint against one collateral in one quote: principal drawn at par, and collateral in unsold pots.
    /// @notice Summed over collaterals, `lent` is the lent leg of `lenderAssets`.
    /// @notice FOR A PER-COLLATERAL CAP: every draw, repay, crank, settlement, buy and redeem moves it, so a reader needs no poke.
    /// @dev GUARDED by `nonReentrantView` as the pools are: the draw, melt, settlement and sale paths move it mid-body.
    /// @dev Keyed by the collateral's ADDRESS: two tokens of one underlying are two entries.
    /// @dev A triple that never lent reads zero rather than reverting, as the pooled views do.
    /// @dev Both figures SATURATE at zero on the way down, so a split defect reads wrong rather than reverting a close.
    /// @param lender The lender to ask about.
    /// @param quote The token the pool is denominated in.
    /// @param collateral The collateral token to split by.
    /// @return lent Principal drawn at par against this collateral's live claims.
    /// @return unsoldUnits Collateral atoms in this pair's settled pots of it that no buy or redeem has taken.
    function lenderByCollateral(address lender, address quote, address collateral) external view nonReentrantView returns (uint256 lent, uint256 unsoldUnits) {
        LenderCollateral storage x = Storage.lenders().byCollateral[lender][quote][collateral];
        return (x.lent, x.unsoldUnits);
    }

    /* ====== 4. KEEPER CRANKS: deleverage, the refinance door, and settlement ====== */

    /// @notice Sells just enough collateral to restore the target margin, or to close the loan, once the record proves the band.
    /// @notice Every unit of proceeds melts debt; the CALLER routes the units.
    /// @dev msg.sender must implement IAceDeleverageCallback: it receives the units and returns the floor.
    /// @dev ONE DOOR: pass `minStableOut` 0 for no caller-side realization floor.
    /// @dev Refuses from the loan's expiry second with `LoanMatured`; after expiry the keeper's verb is `forceClose`.
    /// @dev A closing crank pushes the lender's pool, STRICT: a limit short of its fixed budget plus the tail reverts `PushGasShort`.
    /// @dev `minStableOut` is checked on EVERY return, so a caller floor above zero turns a `(0, 0)` into `BelowCallerFloor`.
    /// @dev A refused fill is an exact no-op on a restore only; a closing sale fills whole or reverts `CloseUnfilled`.
    /// @dev The restore's no-op lets a crank hold an in-band loan's sized units fee-free for one call.
    /// @dev The hub's guard is held throughout, so those units cannot reach a hub verb; outside the hub, flash markets lend most tokens anyway.
    /// @param id The loan to deleverage.
    /// @param minStableOut The caller's realization floor, or 0 for none.
    /// @param data Routing blob handed to the caller's callback.
    /// @return u Units sold.
    /// @return s Quote realized.
    function deleverage(uint256 id, uint256 minStableOut, bytes calldata data) external nonReentrant returns (uint256 u, uint256 s) {
        (u, s) = _deleverage(id, minStableOut, data);
    }

    /// @dev Cache once, hand to Deleverage, push on a close, then the best-effort revenue sweep: a limit that cannot fund it skips it.
    function _deleverage(uint256 id, uint256 minStableOut, bytes calldata data) private returns (uint256 u, uint256 s) {
        bytes32 mid = _book().loans[id].market;
        Market storage M = _market()[mid];
        Cfg memory c = _cache(mid);
        (u, s) = Deleverage.deleverage(_book(), M, c, id, data);
        if (s < minStableOut) revert BelowCallerFloor();
        if (_book().loans[id].closedAt != 0) _pushOwed(c); // a closing crank is a terminal close: the push rides it, STRICT
        _sweepIfDue(mid, M, c);
    }

    /// @notice Close this loan and open a fresh one atomically, in its own market or another securing the same collateral in the same quote.
    /// @notice A new id, a new floor, a new claim and a fresh term: the only continuation into a NEW loan; `extend` lengthens one in place.
    /// @notice From the expiry second it refuses `LoanMatured` before any write: a matured loan repays or settles, and is never re-termed.
    /// @notice Its own market as `dst` re-terms or re-sizes the loan there.
    /// @notice The net out is PAID to the borrower in this call, as `open` pays; a quote that refuses it reverts the refinance.
    /// @notice Optionally sheds collateral off the SUCCESSOR in the same call; zero units to no recipient skips that leg.
    /// @notice A named `withdrawTo` is checked even with zero units: zero with units, the hub or the positionManager refuses.
    /// @dev Borrower-only, because it is a new borrowing decision rather than maintenance; no keeper or periphery moves a loan.
    /// @dev NO health gate on the old loan: its debt is retired in full, so its lenders take cash at par.
    /// @dev Every admissibility question is open()'s, asked of the NEW loan; its cash leg needs only what the old claim does not recycle.
    /// @dev Only into its own market does the claim recycle, on its lender's roll policy's yes; any other market, the same lender's too, draws it all fresh.
    /// @dev A re-term drawing NO fresh cash is judged at `min(price, record)`; one drawing fresh cash meets the draw cap.
    /// @dev THE compatibility rules are collateral AND quote; fee, coverage, price and windows may differ.
    /// @dev Floor and claim reseed from the destination; only the collateral and the holder ride across.
    /// @dev A zero `newTenor` takes the DESTINATION's `minTenor`, as `open` takes its market's.
    /// @dev The band is a LEVEL test: a `bnd.minBufferWad` of at least `deleverageBandBps * 1e14`, judged at `min(price, record)`, keeps the successor out.
    /// @dev A draw that cannot retire the old debt is REFUSED `DrawBelowDebt`: repay the gap first, in the same multicall.
    /// @param m The migration args: loan id, destination market, the fresh terms, the open bounds and the withdrawal leg.
    /// @return newId The fresh loan, in the destination market.
    function refinanceTo(MigrateArgs calldata m) external nonReentrant returns (uint256) {
        MigrateArgs memory a = m;
        bytes32 src = _book().loans[a.id].market;
        Cfg memory cd = _cache(a.dst);
        a.newTenor = Borrower.tenorOrMin(a.newTenor, cd.p.minTenor); // the successor and `Refinanced` carry the real term
        return Borrower.refinance(_book(), _market(), _cache(src), cd, a);
    }

    /// @notice Settle a loan whose distress has persisted for the full settle window. Final.
    /// @notice The keeper's in-kind sliver is CREDITED, never paid inline: `claimOwed` collects it.
    /// @notice The LENDER's pooled quote credit is pushed here instead, swallowed; only the quote side moves.
    /// @notice That push is STRICT: a limit short of its fixed budget plus the tail reverts `PushGasShort`.
    /// @dev No revenue sweep rides this door, unlike `forceClose` and `deleverage`: `sweepRevenue` is the standalone door.
    function finalize(uint256 id) external nonReentrant {
        bytes32 mid = _book().loans[id].market;
        Cfg memory c = _cache(mid);
        Settlement.finalize(_book(), _market()[mid], c, id);
        _pushOwed(c); // LAST: every state write has landed, so a token hook reads settled state
    }

    /// @notice Settle an expired loan by claim conversion; equity above what the market takes is CREDITED to the borrower.
    /// @notice A RECORDLESS market takes the whole coverage line rather than the claims' need, so its borrower may keep nothing.
    /// @notice THE one settle verb at tenor, permissionless from the expiry second; it extends nothing, and asks no policy and no record.
    /// @notice The keeper's in-kind sliver is CREDITED, priced at the loan's funding floor; `claimOwed` collects it.
    /// @notice It pays the market's lender their pooled quote credit, swallowed, so no quote or lender can fail this door.
    /// @notice That push is STRICT: a limit short of its fixed budget plus the tail reverts `PushGasShort`.
    /// @notice THEN it sweeps any due protocol revenue, BEST-EFFORT on what the push left: a limit that cannot fund it skips it.
    /// @dev Whether a record is WIRED is still read, as a param compare: a recordless market forfeits the coverage line to its lender.
    /// @dev Settleability at tenor survives by CONSTRUCTION on the units side, never by the swallowed legs' grace: never give it a units-side call.
    /// @dev The two token legs run LAST, after every state write: a view reached from a hook sees settled state.
    function forceClose(uint256 id) external nonReentrant {
        bytes32 mid = _book().loans[id].market;
        Market storage M = _market()[mid];
        Cfg memory c = _cache(mid);
        Settlement.forceClose(_book(), M, c, id);
        _pushOwed(c);
        /// @dev The sweep runs AFTER the strict push, on whatever it left, so no sweep can starve the lender.
        _sweepIfDue(mid, M, c);
    }

    /* ============ 5. REVENUE AND INVENTORY: the protocol sweep, and the inventory bid ============ */

    /// @notice Permissionless: push accrued protocol revenue to the immutable treasury.
    /// @notice NOT RATE-LIMITED: the once-a-period spacing binds the keeper piggyback, never this call.
    /// @notice STRICT and UNCAPPED where the piggyback is best-effort: the transfer takes the caller's gas, and a refusal reverts `PushRefused`.
    /// @notice A quote whose transfer costs more than `PUSH_GAS` still sweeps here; a batch sweeper caps the gas it gives each market.
    /// @notice Under a tight cap a revert may be GAS, not refusal (empty data, or `PushRefused` on a costly quote): retry with more gas first.
    /// @notice A refusing quote reverts the whole call, so a `multicall` of many markets' sweeps fails on one: sweep per market, or try each.
    function sweepRevenue(bytes32 id) external nonReentrant {
        _sweepRevenue(id, _market()[id], _cache(id), true);
    }

    /// @dev The PIGGYBACK's rate limit: a keeper crank sweeps at most once per period, and only when its limit funds it.
    function _sweepIfDue(bytes32 id, Market storage M, Cfg memory c) private {
        if (block.timestamp < M.s.lastSweptAt + Constants.SWEEP_PERIOD) return;
        _sweepRevenue(id, M, c, false);
    }

    /// @dev Unguarded body: every caller already sits inside the hub's reentrancy guard (one shared slot).
    /// @dev `strict` is the standalone door: the transfer is inline, uncapped and reverts on refusal, so nothing restores.
    /// @dev The piggyback is GATED BEFORE THE STAMP on the whole fixed budget plus the tail; every caller runs it LAST.
    /// @dev A starved piggyback writes and emits nothing: no stamp, the counter stays, and the sweep stays due.
    /// @dev A refused or over-budget piggyback restores the counter but keeps the stamp, which marks the last attempt: the next piggyback waits a period.
    function _sweepRevenue(bytes32 id, Market storage M, Cfg memory c, bool strict) internal {
        if (TREASURY == address(0)) return; // inert while unset: no stamp, no event, no token move
        uint256 amount = M.s.protocolRevenue;
        if (amount == 0) return; // stamp NOTHING on a zero sweep
        if (!strict && gasleft() < SWEEP_FLOOR) return;
        M.s.lastSweptAt = uint64(block.timestamp);
        M.s.protocolRevenue = 0; // CEI: counter clears before the external call
        if (strict) {
            /// @dev `trySafeTransfer` reads one word of returndata and copies nothing more, as `pushToken` does.
            if (!IERC20(c.p.quote).trySafeTransfer(TREASURY, amount)) revert PushRefused();
            emit RevenueSwept(id, TREASURY, amount, uint64(block.timestamp));
            return;
        }
        try this.pushToken{gas: PUSH_GAS}(c.p.quote, TREASURY, amount) {
            emit RevenueSwept(id, TREASURY, amount, uint64(block.timestamp));
        } catch {
            M.s.protocolRevenue = amount; // a swallowed failure must not burn the revenue
            emit RevenueSweepFailed(id, TREASURY, amount, uint64(block.timestamp));
        }
    }

    /// @dev Pay the market's lender what the hub holds for them, and swallow a refusal into the credit it came from.
    /// @dev Called by the four terminal closes alone, a closing crank among them: sale proceeds land after the close and wait for the next push or `collect`.
    /// @dev THE WHOLE POOL, never the door's delta, so those doors alone carry every partial repay, restore crank and sale.
    /// @dev STRICT ON THE CALLER: a limit leaving less than the fixed budget plus the tail reverts `PushGasShort`, so an estimate includes the push.
    /// @dev LENIENT ON THE CALLEE: a refusal or a transfer past its budget lands in the catch, never in a revert of the close.
    /// @dev CEI: the credit clears before the call and is restored whole on refusal, so a failure leaves prior state.
    /// @dev The `=` restore is EXACT because every writer of this field runs under the hub's guard: none can interleave.
    function _pushOwed(Cfg memory c) internal {
        LenderPools storage pool = Storage.lenders().pools[c.p.lender][c.p.quote];
        uint256 amount = pool.owed;
        if (amount == 0) return; // nothing accrued: no call, no event, nothing demanded
        pool.owed = 0;
        if (gasleft() < PUSH_FLOOR) revert PushGasShort(); // the last read before the call: only the tail it reserves follows
        try this.pushToken{gas: PUSH_GAS}(c.p.quote, c.p.lender, amount) {
            emit Lender.Collected(c.p.lender, c.p.quote, c.p.lender, amount);
        } catch {
            pool.owed = amount;
            emit Lender.LenderPushFailed(c.p.lender, c.p.quote, amount);
        }
    }

    /// @notice Self-call plumbing; NOT an entry point. Exists only to make the transfer catchable.
    /// @dev Unguarded: `SelfCallOnly` is the gate, and BOTH callers -- the piggyback sweep and the lender push -- hold it.
    /// @dev THE SELF-CALL IS WHAT MAKES THE CAP EXPRESSIBLE: the library forwards `gas()` and takes no budget.
    /// @dev EVERY CALLER HANDS IT `PUSH_GAS`, and that caps what the callee SPENDS, never what it RETURNS.
    /// @dev So the window is bounded too: `trySafeTransfer` reads one word and reverts a bare selector, never bubbling.
    /// @dev Its acceptance test is the library's own, so this door and `collect` cannot disagree about a success.
    function pushToken(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert SelfCallOnly();
        if (!IERC20(token).trySafeTransfer(to, amount)) revert PushRefused();
    }

    /// @notice Buy collateral out of ONE loan's settled pot, at the market's price, in a market created with `inventoryAsk`.
    /// @notice A market created without it sells NOTHING here, ever: `NoInventoryAsk`, and the pot is its lender's to take in kind.
    /// @notice Permissionless: nothing reads identity -- every gate is the market's flag, a price, a clock, the caller's own bound or the recipient rule.
    /// @notice `unitsTo` is never zero, the hub or the positionManager: refused before the flag and the hold are read, and on a zero fill too.
    /// @notice A sale PAYS NOBODY in this call: the proceeds credit the lender's pool, for the next terminal close in the pair or their own `collect`.
    /// @dev THE FLAG ANSWERS FIRST, before the loan's liveness, the hold and the record: an ask-off market gives one name in every state.
    /// @dev Refused on NoPrice: the market named a record and it cannot answer, so book is not the price it chose.
    /// @dev ADMITTED on None, and that arm asks at BOOK: no record means priced by the market, on the exit as on the draw.
    /// @dev THE HOLD: a settled pot rests until `closedAt` plus the market's window, so the settling tx cannot also buy.
    /// @dev `closedAt == 0` shares that revert: a live loan has no pot, so ONE error names both arms.
    /// @dev The hold gates the stranger's ask alone -- `redeemInKind` reads no clock and stays open.
    /// @dev CEI: fold first (the pot debits inside), then pull quote, then release collateral LAST.
    /// @dev NO PUSH, deliberately: a pot sells in many fills, and a payout per fill is N transfers on gas no buyer is paid to supply.
    /// @dev Money follows the BOOKS and goods follow the DELIVERY: each leg is gated by its own quantity.
    /// @dev Prices off the market's own price and the record ONLY -- never off a token balance.
    function buyInventory(uint256 loanId, uint256 stableIn, uint256 minUnitsOut, address unitsTo)
        external
        nonReentrant
        returns (uint256 unitsOut, uint256 stableFilled)
    {
        Loan storage L = _book().loans[loanId];
        bytes32 mid = L.market;
        Market storage M = _market()[mid];
        Cfg memory c = _cache(mid);
        Recipients.check(unitsTo, c.positionManager);
        if (!c.p.inventoryAsk) revert NoInventoryAsk();
        if (L.closedAt == 0 || block.timestamp < L.closedAt + MarketInit.inventoryHold(c.p.minTenor)) revert InventoryHeld();
        (RecordState s, uint256 cap) = Borrower.recordState(c);
        if (s == RecordState.NoPrice) revert NoRecordPrice();
        (unitsOut, stableFilled) = _buyInventoryFold(M, c, loanId, cap, stableIn, minUnitsOut);
        if (stableFilled > 0) Transfers.pullQuote(c, msg.sender, stableFilled); // balance-checked: fee-on-transfer refused
        /// @dev Delivered straight off the custodian's retired ledger: settled inventory never moved to the hub
        if (unitsOut > 0) IPositionManager(POSITION_MANAGER).releaseRetired(loanId, unitsTo, unitsOut);
        emit BuyInventory(loanId, msg.sender, unitsTo, unitsOut, stableFilled);
    }

    function _buyInventoryFold(Market storage M, Cfg memory c, uint256 loanId, uint256 cap, uint256 stableIn, uint256 minUnitsOut)
        internal
        returns (uint256 unitsOut, uint256 stableFilled)
    {
        /// @dev `None` reads max, which would floor the ask at an unpayable price: 0 means no floor.
        uint256 askFloor = cap == type(uint256).max ? 0 : cap;
        Lender.BuyOut memory o =
            Lender.fillAsk(M, loanId, Lender.FillCfg(c.unitScale, c.p.fillFeeBps, askFloor, c.p.price), Lender.BuyArgs(stableIn, minUnitsOut));
        (unitsOut, stableFilled) = (o.unitsOut, o.stableFilled);
        M.s.netSyntheticOutflow += unitsOut; // units leave custody by trade, exactly as in kind does
        if (M.s.netSyntheticOutflow > M.s.cumulativeBackedBurns) revert SyntheticCapExceeded();
    }

    /* ====== 6. INTERFACES: the one ERC-165 answer this hub makes ====== */

    /// @notice ERC-165: ERC-165 itself. THE LENDING POSITION IS NOT A TOKEN, so no token interface is claimed.
    function supportsInterface(bytes4 iid) external pure returns (bool) {
        return iid == 0x01ffc9a7;
    }

    /* ====== 7. POSITIONS: the hooks the positionManager and the title collection drive ====== */

    /// @notice The storage half of a position transfer: the token moves there, `Loan.borrower` here.
    /// @notice One transaction, both ledgers, or neither.
    /// @notice `to` is never the hub, the positionManager, the title collection or the treasury (in production a router): none claims a holder's credit.
    /// @notice In a market that NAMES its borrower, a holder it does not name may hold the title but can never extend the loan.
    /// @dev NO solvency check: one `Loan` holds both legs, so trigger, debt and units cannot move here.
    /// @dev Every field keyed by the loan alone rides along; NEVER make a health input address-keyed.
    /// @dev Each close credits by loan AND claimant, the holder at the close or the crank's caller, so a title moved after any close carries none of them.
    /// @dev Nothing else resets -- no clock, no expiry, no settle-eligibility; distress travels with the sale.
    /// @dev `nonReentrant`, so an NFT transfer nested inside a hub call REVERTS. That is intended.
    /// @dev `RetitleToZero` cannot fire through the collection, which refuses zero first; it stays as defence in depth.
    function retitle(uint256 loanId, address from, address to) external nonReentrant {
        if (msg.sender != POSITION_TITLE) revert NotPositionTitle();
        if (to == address(0)) revert RetitleToZero();
        Recipients.check(to, POSITION_MANAGER);
        if (to == POSITION_TITLE) revert RetitleToCollection();
        if (to == TREASURY) revert RetitleToTreasury();
        Loan storage L = _book().loans[loanId];
        if (L.borrower != from) revert NotBorrower(); // defence in depth, never trust the caller alone
        if (from == to) return; // self-transfer: no write, no event (the Aave/Comet guard)
        L.borrower = to;
        emit Retitled(loanId, from, to, _book().feeEscrowOf[loanId]);
    }

    /* ====== 8. PLUMBING: multicall, the extsload pair, and the per-entry config cache ====== */

    /// @notice Batch hub calls in one transaction; each leg runs as the CALLER via DELEGATECALL.
    /// @notice The collect-then-deposit round trip rides here: `collect` then `deposit`, no fused verb.
    /// @dev Deliberately NOT nonReentrant: the legs take and release the guard in sequence.
    /// @dev The first failing leg reverts the whole batch, bubbling its own error data verbatim.
    /// @dev Safe against msg.value replay by construction: the hub has no payable function.
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i < data.length; i++) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            results[i] = ret;
        }
    }

    /// @notice Read one storage slot raw: the general-purpose door for an off-chain reader.
    function extsload(bytes32 slot) external view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    /// @notice Read `n` contiguous storage slots raw; the struct-shaped companion to extsload(slot).
    function extsload(bytes32 startSlot, uint256 n) external view returns (bytes32[] memory out) {
        out = new bytes32[](n);
        for (uint256 i; i < n; i++) {
            bytes32 slot = bytes32(uint256(startSlot) + i);
            assembly ("memory-safe") {
                mstore(add(add(out, 0x20), mul(i, 0x20)), sload(slot))
            }
        }
    }

    /// @dev THE cache build. Read once per entry point, thread the result, never re-read in a library.
    function _cache(bytes32 id) internal view returns (Cfg memory c) {
        Market storage M = _market()[id];
        c.p = M.p;
        if (c.p.quote == address(0)) revert NoMarket();
        c.unitScale = M.s.unitScale;
        c.positionTitle = POSITION_TITLE; // immutable read; only the open body uses it, but the cache is built once
        c.positionManager = POSITION_MANAGER;
        c.policyGas = POLICY_GAS;
    }

    /* ====== 9. VIEWS: the ones on-chain callers read from the hub, not a lens ====== */

    /// @notice Whether a loan is settled. The reader's liveness filter over a paged loan list.
    /// @dev The loan's CLOSE STAMP, so it reads false for an id that never opened; the carry gates on `isLiveLoan`.
    function isClosed(uint256 id) external view returns (bool) {
        return _book().loans[id].closedAt != 0;
    }

    /// @notice False while a guarded body is mid-flight, so an off-hub view can refuse a torn read.
    /// @notice The hub's own views carry `nonReentrantView` directly; a SEPARATE contract cannot.
    /// @dev The transient lock is per-address, so a reader at another address must ask rather than check.
    /// @dev Gate any read a hub body can tear: an aggregate, or a field a verb moves across a third-party call, as `debt`. Write-once is exempt.
    function notEntered() external view returns (bool) {
        return !_reentrancyGuardEntered();
    }

    /// @notice The market a loan belongs to; zero for a loan that never existed.
    /// @notice Here rather than on the lens BECAUSE a caller gating on the market must read the payer's copy.
    /// @dev Every claim verb derives its own `mid` from this same slot, so there is ONE source.
    /// @dev A lender contract checking membership against a re-derived offset can drift and pay in a foreign quote.
    function loanMarket(uint256 id) external view returns (bytes32) {
        return _book().loans[id].market;
    }

    /// @notice The position's current holder, which is title of record; zero for a loan that never existed.
    /// @dev No `nonReentrantView`: `borrower` moves only at open and at `retitle`, with its title, never across a third-party call.
    /// @dev Returns zero rather than reverting, so a caller tells a never-opened loan apart without a try/catch.
    function borrowerOf(uint256 id) external view returns (address) {
        return _book().loans[id].borrower;
    }

    /// @notice A loan's OR an order's collateral, plus its market quote; with `isLiveLoan`, the whole LOAN-MANAGER interface.
    /// @dev `quote` has no in-protocol consumer: custody needs the collateral alone, it is kept for integrators.
    /// @dev The custodian's ONE source of truth for which token a loan's units are: it stores no config itself.
    /// @dev LOAD-BEARING ON EVERY CUSTODY VERB: a pot holding many tokens cannot self-assert which is this loan's.
    /// @dev NEVER widen this to a derived or balance-dependent value: it must stay a raw write-once read.
    /// @dev No `nonReentrantView`: a raw write-once read exposes no half-updated aggregate.
    /// @dev Returns a narrow tuple, never `MarketParams memory`: a whole-struct copy sits on `pull`/`release`.
    /// @dev An id names a loan or an order and never both, so the fallback resolves one write-once field or the other.
    function escrowConfigOf(uint256 loanId) external view returns (address collateral, address quote) {
        bytes32 mid = _book().loans[loanId].market;
        if (mid == bytes32(0)) mid = _book().orders[loanId].market;
        MarketParams storage p = _market()[mid].p;
        if (p.quote == address(0)) revert NoMarket();
        return (p.collateral, p.quote);
    }

    /// @notice Whether this id names a loan that is still live. False for a settled loan, an order, and an unused id.
    /// @notice The custody carry gates on it, so units can never be carried out of a loan that is still live.
    /// @dev Its own view rather than a widened `isClosed`: that one means the loan's close stamp, and an order has none.
    function isLiveLoan(uint256 id) external view returns (bool) {
        Loan storage l = _book().loans[id];
        return l.market != bytes32(0) && l.closedAt == 0;
    }

    /// @notice What a LIVE loan owes: its `debt` word exactly, which is its claim, and what a full repay pays.
    /// @notice Zero for every id that is not a live loan: never opened, an order, or closed by repay, refinance or settlement.
    /// @notice FOR AN ON-CHAIN CONSUMER, read beside `restingOf`.
    /// @dev Nothing is netted: no fee, no escrow refund, no accrual; a settlement keeps the stored word but owes nothing.
    /// @dev GUARDED though it reads one loan: every verb that moves debt moves it across an external call, before or after the cash.
    /// @dev Zero rather than a revert outside a hub body, so a probe tells this view apart from a missing selector.
    /// @param loanId The loan to read.
    /// @return The live loan's debt in quote units, or zero.
    function debtOf(uint256 loanId) external view nonReentrantView returns (uint256) {
        Loan storage l = _book().loans[loanId];
        return l.closedAt == 0 ? l.debt : 0;
    }

    /// @notice How many loans this market has EVER opened. Never decreases.
    /// @dev Append-only, so this counts entries, NOT live loans -- page and filter on `isClosed`.
    function marketLoansLength(bytes32 id) external view returns (uint256) {
        return _market()[id].openedLoans.length;
    }

    /// @notice One resting order, whole. An all-zero record means the id names a loan or nothing.
    function orderOf(uint256 id) external view returns (Order memory) {
        return _book().orders[id];
    }

    /// @notice How many orders this market has EVER had posted. Never decreases.
    /// @dev Append-only, so this counts entries, NOT live orders -- page and filter on the record's own flag.
    function orderCount(bytes32 id) external view returns (uint256) {
        return _market()[id].orderIds.length;
    }

    /// @notice One page of this market's orders, oldest first, in post order.
    /// @dev PAGINATED ON PURPOSE: the list is unbounded and an immutable hub gets no second chance.
    /// @dev `limit` clamps silently, so a short page is not the end -- compare `orderCount`.
    /// @dev An offset past the end returns empty rather than reverting; batched multicalls rely on it.
    /// @dev START RECENT: ids are monotone, so the tail holds the newest orders.
    /// @dev A closed order STAYS in the array: removal is what makes two ledgers disagree.
    function marketOrders(bytes32 id, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return Lender.slice(_market()[id].orderIds, offset, limit);
    }

    /// @notice One page of this market's loans, oldest first, in draw order.
    /// @dev PAGINATED ON PURPOSE: the list is unbounded and an immutable hub gets no second chance.
    /// @dev `limit` clamps silently, so a short page is not the end -- compare `marketLoansLength`.
    /// @dev An offset past the end returns empty rather than reverting; batched multicalls rely on it.
    /// @dev Ids are monotone, so the tail holds the newest loans; an extension keeps its id, so a live loan can sit anywhere in the list.
    /// @dev Expired is NOT closed (`forceClose` is permissionless, not automatic): liveness is `isClosed`.
    function marketLoans(bytes32 id, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return Lender.slice(_market()[id].openedLoans, offset, limit);
    }
}
