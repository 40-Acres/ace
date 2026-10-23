//! Kani port of `test/smt/DeleverageSizingSMT.sol` -- obligation O30.
//!
//! THE CLAIM: on any config the genesis rails admit, and any `ps` the stop gate admits, the
//! deleverage sizing denominator `den` does not underflow.
//!
//! Measured on the Solidity side, all three engines failed to settle it:
//!   - solc CHC (Spacer): >2h wall, 28 targets unproved. Diagnosed as nonlinear integer arithmetic.
//!   - medusa: 2h55m, 500,208 calls, 100% revert rate, never reached the subtraction.
//!   - halmos: dies on FullMath's 512-bit assembly path.
//!
//! This asks whether a bit-level model checker over a Rust transcription does better. Two variants:
//!   A. `den_u256` -- faithful. Same uint256 domain, same floor division, same order of operations,
//!      same `ps <= 1e30` modelling bound as the Solidity harness.
//!   B. `den_u128` -- identical structure, `ps <= 1e15` so every intermediate fits u128. A weaker
//!      claim on purpose: it isolates 256-bit WIDTH from the nonlinearity as the cause of a blowup.

use primitive_types::U256;

// ---- rails, verbatim from MarketInit via the Solidity harness ----
pub const MIN_COVERAGE_WAD: u128 = 1_050_000_000_000_000_000; // 1.05e18
pub const MAX_COVERAGE_WAD: u128 = 20_000_000_000_000_000_000; // 20e18
pub const MAX_DELEVERAGE_FLOOR_EPS_BPS: u128 = 200;
pub const MAX_DELEVERAGE_PROTOCOL_BPS: u128 = 2000;
pub const MIN_DELEVERAGE_BAND_BPS: u128 = 3000;

const WAD: u128 = 1_000_000_000_000_000_000; // 1e18
const E14: u128 = 100_000_000_000_000; // 1e14
const BPS: u128 = 10_000;

fn u(n: u128) -> U256 {
    U256::from(n)
}

/// The genesis rails plus the runtime gates, as one admissibility predicate. U256 domain.
///
/// Mirrors `_railsAdmit` + `_gatesAdmit`. `max_price` is the modelling bound on `ps`/`trig`, NOT a
/// shipped rail -- the shipped code leaves both unbounded.
#[allow(clippy::too_many_arguments)]
pub fn admits_u256(
    k: U256,
    eps: U256,
    cut: U256,
    band: U256,
    target: U256,
    stop: U256,
    ps: U256,
    trig: U256,
    max_price: U256,
) -> bool {
    if k < u(MIN_COVERAGE_WAD) || k > u(MAX_COVERAGE_WAD) {
        return false;
    }
    if eps.is_zero() || eps > u(MAX_DELEVERAGE_FLOOR_EPS_BPS) {
        return false;
    }
    if cut > u(MAX_DELEVERAGE_PROTOCOL_BPS) {
        return false;
    }
    if band < u(MIN_DELEVERAGE_BAND_BPS) || band >= u(BPS) {
        return false;
    }
    if target <= band || target >= u(BPS) {
        return false;
    }
    if stop.is_zero() || stop >= band {
        return false;
    }
    // the two feasibility rails, same association and same floor divisions as Solidity
    let base = (k * (u(BPS) - eps) / u(BPS)) * (u(BPS) - cut) / u(BPS);
    if base + target * u(E14) <= u(WAD) {
        return false;
    }
    if stop * u(E14) + base <= u(WAD) {
        return false;
    }
    // runtime gates
    if ps.is_zero() || ps > max_price {
        return false;
    }
    if trig.is_zero() || trig > max_price {
        return false;
    }
    // stop gate, ceil dropped -- dropping it WEAKENS the assumption, so a proof here covers the
    // shipped strict form too
    if ps * (u(WAD) - stop * u(E14)) < trig * u(WAD) {
        return false;
    }
    true
}

/// `tStar`, the trigger the sizing targets. `FullMath.mulDiv(ps, 1e18 - target*1e14, 1e18)`.
pub fn t_star_u256(ps: U256, target: U256) -> U256 {
    (ps * (u(WAD) - target * u(E14))) / u(WAD)
}

/// The left-hand side of the subtraction under test, in the harness's plain (FullMath-free)
/// spelling: `(k * (ps * (10000 - eps)) / (1e18 * 10000)) * (10000 - cut) / 10000`.
pub fn lhs_u256(k: U256, eps: U256, cut: U256, ps: U256) -> U256 {
    (k * (ps * (u(BPS) - eps)) / (u(WAD) * u(BPS))) * (u(BPS) - cut) / u(BPS)
}

/// THE OBLIGATION. Returns `den`, or `None` where the shipped code would underflow.
#[allow(clippy::too_many_arguments)]
pub fn den_u256(k: U256, eps: U256, cut: U256, ps: U256, target: U256) -> Option<U256> {
    let t = t_star_u256(ps, target);
    let l = lhs_u256(k, eps, cut, ps);
    l.checked_sub(t)
}

// ---- Variant B: identical structure, u128, reduced price domain ----

#[allow(clippy::too_many_arguments)]
pub fn admits_u128(
    k: u128,
    eps: u128,
    cut: u128,
    band: u128,
    target: u128,
    stop: u128,
    ps: u128,
    trig: u128,
    max_price: u128,
) -> bool {
    if k < MIN_COVERAGE_WAD || k > MAX_COVERAGE_WAD {
        return false;
    }
    if eps == 0 || eps > MAX_DELEVERAGE_FLOOR_EPS_BPS {
        return false;
    }
    if cut > MAX_DELEVERAGE_PROTOCOL_BPS {
        return false;
    }
    if band < MIN_DELEVERAGE_BAND_BPS || band >= BPS {
        return false;
    }
    if target <= band || target >= BPS {
        return false;
    }
    if stop == 0 || stop >= band {
        return false;
    }
    let base = (k * (BPS - eps) / BPS) * (BPS - cut) / BPS;
    if base + target * E14 <= WAD {
        return false;
    }
    if stop * E14 + base <= WAD {
        return false;
    }
    if ps == 0 || ps > max_price {
        return false;
    }
    if trig == 0 || trig > max_price {
        return false;
    }
    if ps * (WAD - stop * E14) < trig * WAD {
        return false;
    }
    true
}

/// The SHIPPED stop gate, strict and CEILED: `ps > mulDivRoundingUp(trig, 1e18, 1e18 - stop*1e14)`.
///
/// `_gatesAdmit` in the Solidity harness drops the ceil and uses `>=`, which WIDENS the admitted
/// domain. That is sound for the no-underflow claim it makes, but it is not the shipped domain --
/// and `Deleverage._deleverageSizing`'s header names this exact gate as one of the four facts that
/// carry `den > 0`. So the positivity question has to be asked against the strict form.
pub fn strict_stop_gate_u128(ps: u128, trig: u128, stop: u128) -> bool {
    let d = WAD - stop * E14; // stop < band < 10000, so stop*1e14 < 1e18 and d > 0
    let q = (trig * WAD + d - 1) / d; // mulDivRoundingUp
    ps > q
}

/// `floor(k * b / 1e22)` exactly, in u128, with no 256-bit intermediate.
///
/// THIS IS WHAT CLOSES THE PRICE GAP. The naive product `k * (ps * (10000 - eps))` reaches ~1.55e40
/// at par and overruns u128 by ~46x, which forced the U256 path -- and 256-bit division is where
/// CBMC stops terminating. Splitting `k` at 1e10 keeps every intermediate inside u128 while
/// computing the identical floored value, so the obligation becomes machine-checkable at prices a
/// live market actually sees.
///
/// `k = k1*1e10 + k0`, so `k*b/1e22 = k1*b/1e12 + k0*b/1e22 = q1 + (r1*1e10 + k0*b)/1e22`
/// with `q1 = (k1*b)/1e12` and `r1 = (k1*b)%1e12`. `q1` is an integer, so the outer floor
/// distributes over it exactly.
pub fn mul_div_1e22_u128(k: u128, b: u128) -> u128 {
    const SPLIT: u128 = 10_000_000_000; // 1e10
    const D1: u128 = 1_000_000_000_000; // 1e12
    const D: u128 = 10_000_000_000_000_000_000_000; // 1e22
    let k1 = k / SPLIT;
    let k0 = k % SPLIT;
    let n1 = k1 * b;
    let q1 = n1 / D1;
    let r1 = n1 % D1;
    q1 + (r1 * SPLIT + k0 * b) / D
}

/// `den` over the REALISTIC price range, u128 throughout via the split above.
pub fn den_u128_split(k: u128, eps: u128, cut: u128, ps: u128, target: u128) -> Option<u128> {
    let t = (ps * (WAD - target * E14)) / WAD;
    let l = mul_div_1e22_u128(k, ps * (BPS - eps)) * (BPS - cut) / BPS;
    l.checked_sub(t)
}

pub fn den_u128(k: u128, eps: u128, cut: u128, ps: u128, target: u128) -> Option<u128> {
    let t = (ps * (WAD - target * E14)) / WAD;
    let l = (k * (ps * (BPS - eps)) / (WAD * BPS)) * (BPS - cut) / BPS;
    l.checked_sub(t)
}

// ---- Kani proof harnesses ----

#[cfg(kani)]
mod proofs {
    use super::*;

    const MAX_PRICE_FULL: u128 = 1_000_000_000_000_000_000_000_000_000_000; // 1e30, the Solidity bound
    const MAX_PRICE_NARROW: u128 = 1_000_000_000_000_000; // 1e15, so every u128 intermediate fits
    const MAX_PRICE_REALISTIC: u128 = 100_000_000_000_000_000_000; // 1e20, ~1260x par, via the split

    fn any_u256() -> U256 {
        U256(kani::any::<[u64; 4]>())
    }

    /// A. FAITHFUL: the Solidity harness's own domain, uint256 throughout.
    #[kani::proof]
    fn den_never_underflows_u256() {
        let k = any_u256();
        let eps = any_u256();
        let cut = any_u256();
        let band = any_u256();
        let target = any_u256();
        let stop = any_u256();
        let ps = any_u256();
        let trig = any_u256();
        let max_price = U256::from(MAX_PRICE_FULL);

        kani::assume(admits_u256(k, eps, cut, band, target, stop, ps, trig, max_price));
        kani::assume(trig > t_star_u256(ps, target)); // "sizing returns 0 below target"

        assert!(den_u256(k, eps, cut, ps, target).is_some(), "den underflowed");
    }

    /// D. FAITHFUL ARITHMETIC, REALISTIC PRICES: uint256 throughout, ps/trig <= 1e18.
    ///
    /// The hub's price frame is Q96 atoms-per-atom (`unitScale = 2**96`). Par for the suite's own
    /// USDC(6)/COLL(18) pair is `2**96 / 1e12` ~= 7.92e16, so this bound covers par and a decade
    /// above it. It is NOT the harness's full 1e30 domain -- it is the range a live market sits in.
    #[kani::proof]
    fn den_never_underflows_u256_realistic_prices() {
        let k = any_u256();
        let eps = any_u256();
        let cut = any_u256();
        let band = any_u256();
        let target = any_u256();
        let stop = any_u256();
        let ps = any_u256();
        let trig = any_u256();
        let max_price = U256::from(1_000_000_000_000_000_000u128); // 1e18

        kani::assume(admits_u256(k, eps, cut, band, target, stop, ps, trig, max_price));
        kani::assume(trig > t_star_u256(ps, target));

        assert!(den_u256(k, eps, cut, ps, target).is_some(), "den underflowed");
    }

    /// ANTI-VACUITY for B. A proof whose assumptions are unsatisfiable verifies instantly and means
    /// nothing -- this tree has been bitten by a vacuous green three times (warm CHC cache, stripped
    /// halmos AST, medusa's 100% revert rate). `cover` FAILS if the condition is unreachable, so an
    /// UNSATISFIABLE verdict here would retract `den_never_underflows_u128_narrow` entirely.
    #[kani::proof]
    fn narrow_domain_is_non_empty() {
        let k = kani::any::<u128>();
        let eps = kani::any::<u128>();
        let cut = kani::any::<u128>();
        let band = kani::any::<u128>();
        let target = kani::any::<u128>();
        let stop = kani::any::<u128>();
        let ps = kani::any::<u128>();
        let trig = kani::any::<u128>();

        kani::assume(admits_u128(k, eps, cut, band, target, stop, ps, trig, MAX_PRICE_NARROW));
        kani::assume(trig > (ps * (WAD - target * E14)) / WAD);

        // 1. the domain is inhabited at all
        kani::cover!(true, "some admitted config exists");
        // 2. and the search reaches the TIGHT region, where an underflow would actually live --
        //    a proof that only ever saw den >> 0 would be true and uninformative
        kani::cover!(den_u128(k, eps, cut, ps, target) == Some(0), "den can be exactly zero");
        // 3. and the non-degenerate side is reachable too
        kani::cover!(matches!(den_u128(k, eps, cut, ps, target), Some(d) if d > 0), "den can be positive");
    }

    /// G. THE CLOSING HARNESS: positivity over the price range a live market occupies.
    ///
    /// u128 throughout, via `mul_div_1e22_u128`, so no 256-bit division appears and CBMC terminates.
    /// `ps <= 1e20` is ~1260x par (`2**96 / 1e12` ~= 7.92e16 for USDC(6)/COLL(18)). The residual
    /// `1e20 < ps <= 1e30` is the Solidity harness's own MODELLING bound, which its header already
    /// calls "NOT a shipped rail" -- there is no price rail in the hub at all.
    #[kani::proof]
    fn den_is_positive_at_realistic_prices() {
        let k = kani::any::<u128>();
        let eps = kani::any::<u128>();
        let cut = kani::any::<u128>();
        let band = kani::any::<u128>();
        let target = kani::any::<u128>();
        let stop = kani::any::<u128>();
        let ps = kani::any::<u128>();
        let trig = kani::any::<u128>();

        kani::assume(admits_u128(k, eps, cut, band, target, stop, ps, trig, MAX_PRICE_REALISTIC));
        kani::assume(strict_stop_gate_u128(ps, trig, stop));
        kani::assume(trig > (ps * (WAD - target * E14)) / WAD);

        assert!(
            matches!(den_u128_split(k, eps, cut, ps, target), Some(d) if d > 0),
            "den is zero or underflowed at a realistic price"
        );
    }

    /// ANTI-VACUITY for G, on the same three questions as the narrow one.
    #[kani::proof]
    fn realistic_domain_is_non_empty() {
        let k = kani::any::<u128>();
        let eps = kani::any::<u128>();
        let cut = kani::any::<u128>();
        let band = kani::any::<u128>();
        let target = kani::any::<u128>();
        let stop = kani::any::<u128>();
        let ps = kani::any::<u128>();
        let trig = kani::any::<u128>();

        kani::assume(admits_u128(k, eps, cut, band, target, stop, ps, trig, MAX_PRICE_REALISTIC));
        kani::assume(strict_stop_gate_u128(ps, trig, stop));
        kani::assume(trig > (ps * (WAD - target * E14)) / WAD);

        kani::cover!(true, "some admitted config exists at a realistic price");
        kani::cover!(ps > 79_228_162_514_264_337, "the search reaches par and above");
        kani::cover!(matches!(den_u128_split(k, eps, cut, ps, target), Some(d) if d > 0), "den can be positive");
    }

    /// H. THE LEMMA THAT CLOSES THE HIGH END, where no exact check can reach.
    ///
    /// At large `ps` the values themselves outgrow any native width -- `ps ~ 7.9e43` is an ORDINARY
    /// price for a DAI(18)-quoted WBTC(8) market, past u128 and past the Solidity harness's own
    /// `MAX_PRICE = 1e30`. So the high end is closed by a margin argument instead, and this harness
    /// machine-checks its one non-trivial premise.
    ///
    /// Writing `L` and `T` for the EXACT (unfloored) rationals and `D = k(1e4-eps)(1e4-cut) - A*1e8`
    /// with `A = 1e18 - target*1e14`:
    ///   - two floors lose under 1 each in the final scale, so `lhs_f > L - 2`, and `tStar <= T`
    ///   - `L - T = ps*D / 1e26`, so `ps*D >= 3e26` gives `den > 1`, hence `den > 0`
    ///   - THIS HARNESS proves the rails force `D >= 1e8`, so `ps >= 3e18` suffices
    /// `3e18 < 1e20`, so this overlaps `den_is_positive_at_realistic_prices` and the two together
    /// cover every price. The floor bounds above are the one step not machine-checked; they are
    /// elementary and stated here so a reader can audit them rather than take them on trust.
    #[kani::proof]
    fn the_rails_force_a_denominator_margin() {
        let k = kani::any::<u128>();
        let eps = kani::any::<u128>();
        let cut = kani::any::<u128>();
        let band = kani::any::<u128>();
        let target = kani::any::<u128>();
        let stop = kani::any::<u128>();

        // the genesis rails alone: no price, no gate, so this holds for EVERY admitted config
        kani::assume(k >= MIN_COVERAGE_WAD && k <= MAX_COVERAGE_WAD);
        kani::assume(eps > 0 && eps <= MAX_DELEVERAGE_FLOOR_EPS_BPS);
        kani::assume(cut <= MAX_DELEVERAGE_PROTOCOL_BPS);
        kani::assume(band >= MIN_DELEVERAGE_BAND_BPS && band < BPS);
        kani::assume(target > band && target < BPS);
        kani::assume(stop > 0 && stop < band);
        let base = (k * (BPS - eps) / BPS) * (BPS - cut) / BPS;
        kani::assume(base + target * E14 > WAD); // the denominator rail
        kani::assume(stop * E14 + base > WAD); // the sell-max rail

        let a = WAD - target * E14;
        let d = k * (BPS - eps) * (BPS - cut) - a * 100_000_000; // A * 1e8
        assert!(d >= 100_000_000, "the rails do not force D >= 1e8");
    }

    /// E. THE OBLIGATION THE CODE ACTUALLY NEEDS: `den > 0`, not merely `den >= 0`.
    ///
    /// `Deleverage.sol` divides by `den` (`FullMath.mulDiv(units, trig - tStar, den)`), so `den == 0`
    /// is a division by zero in the keeper's safety verb, not a benign edge. The SMT harness proves
    /// no UNDERFLOW, which `den == 0` satisfies. `_deleverageSizing`'s own header says positivity is
    /// carried by four facts and the Solidity harness models only three -- it drops the ceil and the
    /// strictness from the stop gate. This asks the question with the fourth fact in place.
    #[kani::proof]
    fn den_is_positive_under_the_strict_gate_u128() {
        let k = kani::any::<u128>();
        let eps = kani::any::<u128>();
        let cut = kani::any::<u128>();
        let band = kani::any::<u128>();
        let target = kani::any::<u128>();
        let stop = kani::any::<u128>();
        let ps = kani::any::<u128>();
        let trig = kani::any::<u128>();

        kani::assume(admits_u128(k, eps, cut, band, target, stop, ps, trig, MAX_PRICE_NARROW));
        kani::assume(strict_stop_gate_u128(ps, trig, stop)); // the fourth fact
        kani::assume(trig > (ps * (WAD - target * E14)) / WAD); // the early return

        assert!(
            matches!(den_u128(k, eps, cut, ps, target), Some(d) if d > 0),
            "den is zero or underflowed: _deleverageSizing divides by it"
        );
    }

    /// F. The same question WITHOUT the fourth fact, to attribute the answer.
    ///
    /// If E verifies and F fails, the strict ceiled gate is load-bearing for positivity and the
    /// header is right. If BOTH fail, the four facts do not carry it and that is a live defect.
    #[kani::proof]
    fn den_is_positive_under_the_weak_gate_u128() {
        let k = kani::any::<u128>();
        let eps = kani::any::<u128>();
        let cut = kani::any::<u128>();
        let band = kani::any::<u128>();
        let target = kani::any::<u128>();
        let stop = kani::any::<u128>();
        let ps = kani::any::<u128>();
        let trig = kani::any::<u128>();

        kani::assume(admits_u128(k, eps, cut, band, target, stop, ps, trig, MAX_PRICE_NARROW));
        kani::assume(trig > (ps * (WAD - target * E14)) / WAD);

        assert!(
            matches!(den_u128(k, eps, cut, ps, target), Some(d) if d > 0),
            "den is zero or underflowed under the harness's weakened gate"
        );
    }

    /// B. NARROWED: same structure, u128, ps <= 1e15. Weaker claim, isolates width from nonlinearity.
    #[kani::proof]
    fn den_never_underflows_u128_narrow() {
        let k = kani::any::<u128>();
        let eps = kani::any::<u128>();
        let cut = kani::any::<u128>();
        let band = kani::any::<u128>();
        let target = kani::any::<u128>();
        let stop = kani::any::<u128>();
        let ps = kani::any::<u128>();
        let trig = kani::any::<u128>();

        kani::assume(admits_u128(k, eps, cut, band, target, stop, ps, trig, MAX_PRICE_NARROW));
        kani::assume(trig > (ps * (WAD - target * E14)) / WAD);

        assert!(den_u128(k, eps, cut, ps, target).is_some(), "den underflowed");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NARROW: u128 = 1_000_000_000_000_000; // 1e15, variant B's price ceiling
    const FULL: u128 = 1_000_000_000_000_000_000_000_000_000_000; // 1e30, the Solidity bound

    /// The port is only worth proving if it computes what the Solidity computes. One admitted
    /// config, hand-evaluated: k=2e18, eps=200, cut=2000, band=3000, target=5000, stop=1000,
    /// ps=1e18, trig=6e17 -> den = 1.068e18. U256 only: at ps=1e18 the u128 variant overflows,
    /// which is itself the width fact variant B exists to expose.
    #[test]
    fn port_matches_a_hand_evaluated_config() {
        let to = |n: u128| U256::from(n);
        let (k, eps, cut, band, target, stop) = (2 * WAD, 200u128, 2000u128, 3000u128, 5000u128, 1000u128);
        let (ps, trig) = (WAD, 600_000_000_000_000_000u128);

        assert!(
            admits_u256(to(k), to(eps), to(cut), to(band), to(target), to(stop), to(ps), to(trig), to(FULL)),
            "config should be admitted"
        );
        assert_eq!(den_u256(to(k), to(eps), to(cut), to(ps), to(target)), Some(to(1_068_000_000_000_000_000)));
    }

    /// The same config scaled into variant B's domain: ps=1e15, trig=6e14 -> den = 1.068e15.
    #[test]
    fn the_narrow_variant_matches_a_hand_evaluated_config() {
        let (k, eps, cut, band, target, stop) = (2 * WAD, 200u128, 2000u128, 3000u128, 5000u128, 1000u128);
        let (ps, trig) = (NARROW, 600_000_000_000_000u128);

        assert!(admits_u128(k, eps, cut, band, target, stop, ps, trig, NARROW), "config should be admitted");
        assert_eq!(den_u128(k, eps, cut, ps, target), Some(1_068_000_000_000_000));
    }

    /// THE SPLIT MUST EQUAL THE FAITHFUL U256 COMPUTATION, or the proof that rests on it is worthless.
    /// Swept across par (2**96/1e12 ~= 7.92e16 for USDC(6)/COLL(18)) and three decades either side.
    #[test]
    fn the_split_matches_u256_across_the_realistic_range() {
        let to = |n: u128| U256::from(n);
        let par = 79_228_162_514_264u128 * 1_000; // 2**96 / 1e12, truncated
        let prices = [
            1u128, 2, 999, NARROW, par / 1000, par / 7, par - 1, par, par + 1, 3 * par, par * 1000,
            100_000_000_000_000_000_000, // 1e20, the split harness's ceiling
        ];
        for ps in prices {
            for target in [3001u128, 5000, 7777, 9999] {
                for k in [MIN_COVERAGE_WAD, 2 * WAD, 7 * WAD + 3, MAX_COVERAGE_WAD] {
                    for (eps, cut) in [(1u128, 0u128), (200, 2000), (97, 1373)] {
                        let split = den_u128_split(k, eps, cut, ps, target);
                        let faithful = den_u256(to(k), to(eps), to(cut), to(ps), to(target));
                        assert_eq!(
                            split.map(U256::from),
                            faithful,
                            "split diverged at ps={ps} target={target} k={k} eps={eps} cut={cut}"
                        );
                    }
                }
            }
        }
    }

    /// The two variants must agree wherever both are defined, or the narrow proof says nothing
    /// about the faithful one.
    #[test]
    fn the_two_variants_agree() {
        let to = |n: u128| U256::from(n);
        for ps in [1u128, 999_999_999_999_999, NARROW, NARROW / 3, 7] {
            for target in [3001u128, 5000, 9999] {
                for k in [MIN_COVERAGE_WAD, 3 * WAD, MAX_COVERAGE_WAD] {
                    let a = den_u128(k, 200, 2000, ps, target);
                    let b = den_u256(to(k), to(200), to(2000), to(ps), to(target));
                    assert_eq!(a.map(U256::from), b, "variants diverged at ps={ps} target={target} k={k}");
                }
            }
        }
    }
}
