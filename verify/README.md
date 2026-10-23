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
deploys, with two exceptions:

- **Harnesses add views** (`verify/certora/harness/`), because under via-IR the prover cannot read raw slots or
  resolve ERC-7201 annotations. A harness adds getters and no state.
- **The hub is munged.** The prover cannot execute the hub's external-library delegatecalls under via-IR, so
  `scripts/certora-munge.sh` builds `verify/certora/munged/` with the six libraries made `internal` and inlined. Its
  header carries the equivalence argument. The full forge suite also passes against the munged hub, apart from two
  tests that measure a call frame's gas, which inlining removes.

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
| `VaultArithmetic` | `CuratorVault` | The fee high-water mark never falls at a collection and rises correctly at a deposit or mint | PROVEN; the vesting rules TIMEOUT |
| `VaultSplit` | `CuratorVault` | Entry split-additivity: one deposit and the same deposit in two parts price alike | Rewritten for the current vault, not yet re-run |
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
