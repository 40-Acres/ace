# ACE

ACE is an on-chain credit primitive. One immutable singleton contract holds every lending market; a market is a
storage record keyed by its parameters, so creating one deploys nothing. Lenders rest cash in a market at a fixed
price per unit of collateral, borrowers draw against collateral for a fixed tenor, and a loan that ends in default
transfers title to its collateral to the lender who funded it.

**Curator vaults** sit above the hub: `CuratorVault` is an ERC-4626 vault a curator runs. It holds its depositors'
cash and lends it into ACE markets that name it as their lender, on terms the curator sets. `AceVault` is its base.

**Runway** is a token-launch stack built on ACE: a fixed-supply token, a continuous clearing auction, a Uniswap v4
pool opened at migration, and locked allocations that vest on a schedule and can be pledged as ACE collateral while
they are still locked. **LaunchVault** is a curator-run vault that lends opted-in auction refunds back to a
launch's buyers against their locked tokens.

## Status

This repository is the review copy: the hub, the curator vaults, Runway and LaunchVault, with the tests and proofs
that exercise them.

## Layout

| Path | What it is |
|---|---|
| `src/ace/hub/` | `Ace.sol`, the singleton, and the external libraries it links: `Borrower`, `Lender`, `Settlement`, `Deleverage`, `Orders`, `MarketInit` |
| `src/ace/positions/` | `PositionManager`, the custodian holding pledged collateral, and `PositionTitleNFT`, the loan titles |
| `src/ace/treasury/` | `RevenueRouter`, where the protocol's fees are paid |
| `src/ace/lens/` | Read-only views over the hub; redeployable |
| `src/entities/launch/` | Runway: `LaunchTokenFactory`, `LaunchToken`, `LaunchLock`, `LockAccount`, `LaunchOpsBudget`, `RunwayHook` |
| `src/entities/vesting/ScheduleLock.sol` | The schedule and account base `LaunchLock` inherits |
| `src/curator/` | `CuratorVault` and its base `AceVault` (with `AceVaultFlows`); `LaunchVault`, the launch lending vault, with `PriceGrid` and `sets/SetValue` |
| `src/oracle/`, `src/config/`, `src/interfaces/`, `src/utils/` | Price records the hub can read, default market parameters, interfaces, helpers |
| `vendor/` | Third-party source copied verbatim, licences beside it: Uniswap's liquidity-launcher `InitializerHook`, OpenZeppelin's `VestingWalletUpgradeable`, and a copy of v4's `PoolManager` that only the tests deploy |
| `test/` | Unit, fuzz, invariant and fork tests |
| `verify/` | Formal verification: Certora specs over the hub, the custodian, the title NFT, `LoanMath`, `CuratorVault` and `RunwayHook`, and a Kani proof; see `verify/README.md` |
| `scripts/` | Building the local prover, munging the hub for it, and running a spec |

## Build and test

```sh
git clone --recurse-submodules https://github.com/40-Acres/ace
cd ace
forge build
forge test
```

Solidity 0.8.36, EVM target cancun. Fork tests run against Ethereum mainnet when `ALCHEMY_API_KEY` is set and skip
cleanly when it is not. The deployed bytecode is compiled via-IR; `FOUNDRY_PROFILE=deploy forge build` reproduces it.

## Formal verification

`verify/README.md` lists every proven property with its last recorded status. Among them:
- the hub's quote balance always equals its booked pots;
- a closed loan never reopens;
- a loan's claim is its debt;
- a verb only moves the market it names;
- strangers cannot lower anyone's claim;
- the fee arithmetic rounds as documented;
- the deleverage sizing never divides by zero;
- `RunwayHook`'s swap path never reverts.

## Review priorities

1. **The hub** (`src/ace/hub`, `src/ace/positions`, `src/ace/treasury`). It is immutable once deployed: there is no
   owner, no pause and no proxy, and every market lives in it.
2. **The curator vaults** (`CuratorVault`, `AceVault`, `AceVaultFlows`).
3. **Runway** (`src/entities/launch`, `ScheduleLock`).
4. **LaunchVault**.

## Intentional behaviour

These are design choices, documented so they are not reported as findings.

### Hub

- **Default is a title transfer, not a sale.** At default, title to the collateral moves to the lender that funded
  the loan; no liquidator buys it. `deleverage` is the only sale against a live loan.
- **There is no utilization cap.** A lender's exit liquidity is bounded by tenor: a fully lent market drains as its
  loans expire.
- **The fee surface is two items.** An origination fee, of which the protocol's share is a fixed 10%, and a
  per-market protocol share of deleverage proceeds, which a market's creator sets and may set to zero. Settlement
  pays only the keeper's bounty.
- **A loan's funding floor is set once, at the draw.** Neither trades nor idle cash move it afterwards.
- **Recordless markets have no price record.** Title on such a market moves at or after expiry only, and they
  cannot take a deleverage band.

### Runway

- The launcher's LBP strategy and its auction factory are pinned and trusted. A launch reverts unless the strategy
  takes exactly its amount and registers the auction for the new token.
- `launchBy` assumes blocks average at most `MAX_BLOCK_SECONDS` until migration. A migration later than `launchBy`
  fails into the strategy's recovery and the launch settles as failed, refunding every bid.
- A launch must be migrated before it is settled. A launch nobody migrates can be pushed into failure by a donated
  reserve. Bids are then refunded in full.
- `RunwayHook` adds about 13k gas to a block's first swap in a launch pool and about 8k to later ones. It never
  changes fees or swap amounts.
- The hook's price window is the low and high of block-start prices over 24 to 36 hours. A manipulated low sticks
  for that window and lowers every quote, which is griefing with no depositor loss. A real rally lifts the window
  only after it has held for the window.
- The protocol's cut of a live launch's raise is booked at settlement and paid by a separate permissionless
  `payProtocol`, so a refusing recipient strands only the cut.

### LaunchVault

- **Crash bound.** In a sharp price drop, losses can reach the vault's free cash, first come first served among
  credited buyers. The quote tracks the window down without a keeper, and the curator can stop the vault.
- A buyer's credit is its auction spend at the final clearing price, a lower bound on what it bought. Early bidders
  who filled below the final price are undercounted.
- Credit is counted per vault, so one bid can back a loan in every vault on its launch. Each vault's exposure stays
  within that buyer's credit.
- `RESERVE_TTL` bounds the age of a reservation's price, not the reservation. A top-up re-prices it, so an active
  borrower can keep cash reserved within its own room.
- Exits wait until the vault is home. After the term that needs a `recall` for each account still holding a
  reservation (any holder may call it, from `accounts`) and settlement of any expired loan. No bounty is paid for
  settlement.
- Anyone sweeping a buyer's lock account before a keeper's `depositRefund` voids that deposit. The money stays with
  the buyer.

## Licence

BUSL-1.1; see `LICENSE`. Vendored third-party code keeps its own licence, in the file beside it.
