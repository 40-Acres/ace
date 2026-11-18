# Formal verification

Two engines. **Certora** checks the Solidity itself; **Kani** checks a Rust port of one arithmetic obligation the
Solidity engines could not settle. Both run locally.

Statuses below are from the last recorded run. A TIMEOUT is a solver budget running out, not a counterexample.
The IDs (O1, O2, ...) match the headers in each spec.

## Certora (`verify/certora`)

```sh
scripts/certora-setup.sh                                         # once: JDK, solvers, and the open-source prover built locally
scripts/certora-run.sh verify/certora/confs/LoanMath.conf        # one conf
scripts/certora-run.sh verify/certora/confs/HubLoans.conf --rule aClosedLoanStaysClosed
```

`certora-run.sh` compiles via-IR with the settings in `foundry.toml`, so a spec runs against the bytecode that
deploys, with four exceptions:

- **Harnesses add views** (`verify/certora/harness/`), because under via-IR the prover cannot read raw slots or
  resolve ERC-7201 annotations. A harness adds getters and no state.
- **The hub is munged.** The prover cannot execute the hub's external-library delegatecalls under via-IR, so
  `scripts/certora-munge.sh` builds `verify/certora/munged/` with the six libraries made `internal` and inlined. Its
  header carries the equivalence argument. The full forge suite also passes against the munged hub, apart from two
  tests that measure a call frame's gas, which inlining removes.
- **The vault is munged.** `AceVault` forwards thirteen verbs' own calldata into its linked libraries by `DELEGATECALL`,
  its figures appended as a suffix the prover's inliner cannot load. `scripts/certora-munge-vault.sh` builds
  `verify/certora/munged-vault/` with each forward a typed internal call, dispatched by
  `verify/certora/munge-vault/AceVaultMunged.sol`; its header carries the equivalence argument, and `VaultForwardProbe`
  checks that each forward runs its library body.
- **The sAERO receipt is munged, one line.** A receipt is a clone whose three args are bytes after its own code, read
  by an EXTCODECOPY of itself, and the prover havocs each such read afresh, so two reads of one arg disagree.
  `scripts/certora-munge-receipt.sh` builds `verify/certora/munged-receipt/` with `_args()` made virtual, and the harness
  template in `verify/certora/munge-receipt/` answers it from three storage words no function writes, standing in for
  the clone's code. Its header carries the equivalence argument.

Every conf runs with `rule_sanity: basic`, which fails a rule whose preconditions are unsatisfiable. Loops unroll
twice, so a result on the batch verb `refinanceByPolicies` covers batches of at most two. Each result was also
checked with a trace showing the real code running and a mutant the rule catches. Verb counts differ by spec because
each excludes the verbs its property does not apply to (`multicall` everywhere, as a composition of its legs).

| Conf | Contract | Property | Status |
|---|---|---|---|
| `HubSolvency` | `Ace` | **O1** The hub's quote balance is exactly the booked pots (resting cash, unswept revenue, fee escrows) and never less | PROVEN on every single verb; the batch follows by composition |
| `HubIsolation` | `Ace` | **O2** A verb moves only the market it names; an untouched market stays untouched | PROVEN on 24 of 31 verbs, market creation included; 7 TIMEOUT. Covers each market's record, not the loan book |
| `HubLentBook` | `Ace` | **O4** Each lender pool's `lent` equals the sum of the claims its markets hold | PROVEN on all 30 verbs and the base case |
| `HubCustody` | `Ace` + `PositionManager` | **O5** The custodian holds exactly a live loan's units and nothing for a closed one; an id is never both a loan and an order | PROVEN per loan on every verb and the base case |
| `HubClaims`, `HubClaimsExact` | `Ace` | **O10** A live loan's claim equals its debt and the debt is positive; a closed loan carries none. **O56** A market's params never change, its id is their hash, and its coverage rails hold | PROVEN on every verb; `deleverage` by a two-case split and an exact `mulDiv` |
| `HubLoans`, `HubLoansCases` | `Ace` | **O11** The loan id counter never moves back and id 0 is never issued. **O13** A closed loan stays closed and never continues | PROVEN on every verb; the migrations by a case split that is shown to cover every input |
| `HubLoansLean` | `Ace` | O13 on the heavy verbs | Superseded by `HubLoansCases` |
| `HubRevenue` | `Ace` | **O20** A market's protocol revenue only rises, holds, or falls to exactly zero (it leaves only by the sweep) | PROVEN on 31 of 33 verbs; 1 TIMEOUT |
| `HubAttribution` | `Ace` | **O43** No stranger's verb lowers anyone's claim, a lender's credit leaves only into the lender's wallet, and the hub pulls quote only from its caller. **O44** A market's claims pot is exactly its claims, and a lender or claimant can always collect | O43 PROVEN on 28, 28 and 31 of 32 verbs; O44's accounting on 24 to 31 of 32; both liveness rules PROVEN under stated premises |
| `HubPayer`, `HubAllowance` | `Ace` | **O45** A collateral pull names only the caller or the hub as payer, and no hub allowance outlives its verb | PROVEN on all 30 verbs |
| `HubBackstop` | `Ace` | **O51** `settleExpired` past expiry and the roll window cannot be blocked by any record, quote, collateral or lender behaviour | Written, not yet run |
| `HubHookProbe` | `Ace` | The store hooks the ghost sums rely on fire on the munged hub | Probe |
| `PositionManager` | `PositionManager` | **O40** Only the hub moves a ledger, only the named loan's collateral moves, and custody never exceeds the balance | PROVEN, every mutator |
| `PositionTitleNFT` | `PositionTitleNFT` | **O42** Only the hub mints title, nothing burns it, and every transfer tells the hub exactly that move | PROVEN, every mutator; one base case by inspection |
| `LoanMath` | `LoanMath` | **O41** The fee chain rounds as documented, the protocol never over-takes, and the principal-for-owed inverse is exact | PROVEN for every input |
| `VaultArithmetic` | `AceVault`, munged (harness `CuratorVaultHarness`) | The fee high-water mark never falls at a collection and rises correctly at a deposit or mint; per virtual share, no collection or entry lowers it and an exit lowers it by under one wei | The fee rules PROVEN on `AceVault`; per virtual share, the collection's rule PROVEN, the entry's and exit's unfinished at the time limit and re-running one at a time; the vesting rules PROVEN on 15 verbs, the rest TIMEOUT or UNKNOWN |
| `VaultVest` | `AceVault`, munged (harness `VaultVestHarness`) | The vest maturity, at its one write, never moves earlier and stays within one window | All four rules PROVEN at the write; the caught mutant is owed |
| `VaultSplit` | `AceVault`, munged (harness `CuratorVaultHarness`) | Entry split-additivity: one deposit and the same deposit in two parts price alike | The pile-decay lemma PROVEN and the mint witness found; the split rules not yet re-run on the current vault |
| `VaultForwardProbe` | `AceVault`, munged (harness `VaultForwardHarness`) | Each forwarded verb runs its library body on the vault's storage, rather than havoc it or no-op | 12 of the 14 forwards PROVEN; the in-kind collect's and `refinanceFor`'s effect rows TIMEOUT |
| `VaultBoundary` | `AceVault`, munged (harness `VaultBoundaryHarness`), a stand-in hub that records and moves the asset | What the vault enforces whatever its terms and door answer: the NAV identity, share authority, cash out only at exits or as a placement under lendable cash, the row and the total, the tenor rail, timelocked raises, the drawdown, no exit calling the product, the seized ledger | The NAV identity, the consent rail and the lock (16 verbs) PROVEN; the rest not yet run |
| `VaultBoundaryLite` | `AceVault`, munged (harness `VaultBoundaryHarness`), the hub, title and product left arbitrary | The VaultBoundary rules over the forwarded verbs that are the vault's own checks: the lock, share authority, timelocked raises, the write-off clock, the seized ledger, never pledging the asset | The lock (all 12 forwarded verbs), a return lowers only its key, and an accepted write-off clears only its key PROVEN; never pledging the asset on a refinance timed out; the rest not yet run |
| `SaeroTerms` | `SAeroTerms` | The sAERO terms' bid, dials and listing floor; only the settings timelock moves the dials, and the curator's raise only raises the buffer | The bid and floor rules PROVEN before the settings timelock replaced the pending set; that change's restated bid rule and the two dial-door rules are PROOF OWED |
| `SaeroStakeReceiptFactory` | `SAeroStakeReceiptFactory` | **O82** The receipt registry only grows, only `make` writes it or `latest`, and `make` blesses only the receipt it returns. `make` refuses while the portfolio's last receipt for the stake has units out, and lands otherwise; it refuses custody, a non-portfolio, a stake the caller does not hold, a decaying or empty stake, and an unbooked one | PROVEN on every rule, the parametric one on every method; the calls in `make` are dispatched to mocks, as the spec header argues; dropping any one of `make`'s nine guards or writes turns exactly one rule red |
| `SaeroReceipt` | `SAeroStakeReceipt`, munged (harness `SAeroStakeReceiptHarness`) | **O86** A seized receipt's cash pays the vault's open claim first, then the lenders' fee, then the owner, and the owner only out of cash beyond both, a short door take included; the fee is booked only at the seizure, at the bps frozen once at mint and capped at 10%; a payout moves only its vault leg and its owner leg; every unit leaving the custodian burns; the reward repay admits only the portfolio, its owner or the operator, never leaves the debt under the floor or the caller's bound, and only the portfolio or its owner closes | PROVEN, every rule and every method of the parametric ones, each group with a witness; the invariants' base case at a fresh clone's zero state, since a clone runs no constructor; eight mutants caught |
| `RunwayHookWindow` | `RunwayHook` | The window's roll, its read and the swap callback never revert, since a pool's hook is permanent | PROVEN |

## Kani (`verify/den353`)

```sh
cargo install --locked kani-verifier && cargo kani setup   # once
cd verify/den353 && cargo kani                             # every harness
cargo test                                                 # the port's fidelity tests, no Kani needed
```

**O30** The deleverage sizing denominator is strictly positive on every admitted config, so the division it feeds
never divides by zero. PROVEN at every price: exactly for prices up to 1e20, and by a machine-checked rail margin from
3e18 up; the two ranges overlap. The crate ports `test/smt/DeleverageSizingSMT.sol`, and its fidelity tests check the
port against hand-evaluated configs and a `U256` transcription, so the proof is about what the contract computes.
