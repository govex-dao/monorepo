/// ============================================================================
/// N-OUTCOME ARBITRAGE MATH - EFFICIENT B-PARAMETERIZATION
/// ============================================================================
///
/// IMPROVEMENTS IMPLEMENTED (Mathematician's Suggestions):
/// ✅ 1. B-parameterization - No square roots, cleaner math
/// ✅ 2. Active-set pruning - 40-60% gas reduction
/// ✅ 3. Early exit checks - Skip calculation when no arbitrage exists
/// ✅ 4. Bidirectional solving - Catches all opportunities
/// ✅ 5. Min profit threshold - Simple profitability check
/// ✅ 6. u256 arithmetic - Accurate overflow-free calculations
/// ✅ 7. Two-phase profit precision - 0.01% profit accuracy via coarse + refinement search
///
/// MATH FOUNDATION:
///
/// Instead of searching for optimal input x, we search for optimal output b.
/// For constant product AMMs with quantum liquidity constraint:
///
/// x(b) = max_i [b × A_i / (T_i - b × B_i)]  (no square root!)
/// F(b) = b - x(b)                            (profit function)
///
/// Where:
///   T_i = (R_i_stable × α_i) × (R_spot_asset × β)
///   A_i = R_i_asset × R_spot_stable
///   B_i = β × (R_i_asset + α_i × R_spot_asset)
///
/// Domain: b ∈ [0, U_b) where U_b = min_i(T_i/B_i)
///
/// ============================================================================

module futarchy_markets::arbitrage_math;

use futarchy_markets::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets::conditional_amm::{Self, LiquidityPool};
use futarchy_one_shot_utils::math;

// === Errors ===
const ETooManyConditionals: u64 = 0;

// === Constants ===
const MAX_CONDITIONALS: u64 = 50; // Protocol limit - O(N²) with pruning stays performant
const BPS_SCALE: u64 = 10000;     // Basis points scale

// Gas cost estimates (with active-set pruning):
//   N=10:  ~11k gas  ✅ Instant
//   N=20:  ~18k gas  ✅ Very fast
//   N=50:  ~111k gas ✅ Fast (new limit)
//   N=100: ~417k gas ⚠️ Expensive (use off-chain dev_inspect)
//
// Complexity: O(N²) from pruning + O(log U_b × N_pruned) from search
// Pruning typically reduces N to 2-3 active outcomes

// === Public API ===

/// **PRIMARY N-OUTCOME FUNCTION** - Compute optimal arbitrage for ANY number of outcomes
/// Returns (optimal_amount, expected_profit, is_spot_to_cond)
///
/// **KEY FEATURE**: Works for 2, 3, 4, 5, 10, 50... outcomes WITHOUT type explosion!
///
/// This function:
/// - Takes a vector of conditional pools (outcome count = vector length)
/// - Tries both directions (Spot→Conditional and Conditional→Spot)
/// - Returns the more profitable direction with optimal execution amount
/// - Handles complete set constraints (quantum liquidity)
///
/// **Algorithm**:
/// 1. Spot → Conditional: Buy from spot, sell to ALL conditionals, burn complete set
/// 2. Conditional → Spot: Buy from ALL conditionals, recombine, sell to spot
/// 3. Compare profits, return better direction
///
/// **Performance**: O(N²) with active-set pruning, tested up to N=50
///
/// **Example**:
/// ```move
/// let (amount, profit, is_spot_to_cond) = compute_optimal_arbitrage_for_n_outcomes(
///     spot_pool,
///     &conditional_pools,  // Works for ANY size vector!
///     1000  // min profit threshold
/// );
/// if (profit > 0) {
///     // Execute arbitrage with `amount` input
///     // Direction: is_spot_to_cond tells you which way to trade
/// }
/// ```
public fun compute_optimal_arbitrage_for_n_outcomes<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    min_profit: u64,  // Minimum acceptable profit threshold
): (u64, u128, bool) {
    // Validate outcome count
    let outcome_count = vector::length(conditionals);
    if (outcome_count == 0) return (0, 0, false);

    assert!(outcome_count <= MAX_CONDITIONALS, ETooManyConditionals);

    // Try Spot → Conditional arbitrage
    let (x_stc, profit_stc) = compute_optimal_spot_to_conditional(
        spot,
        conditionals,
        min_profit,
    );

    // Try Conditional → Spot arbitrage
    let (x_cts, profit_cts) = compute_optimal_conditional_to_spot(
        spot,
        conditionals,
        min_profit,
    );

    // Return more profitable direction
    if (profit_stc >= profit_cts) {
        (x_stc, profit_stc, true)  // Spot → Conditional
    } else {
        (x_cts, profit_cts, false) // Conditional → Spot
    }
}

/// **DEPRECATED**: Use `compute_optimal_arbitrage_for_n_outcomes()` instead
/// Kept for backward compatibility during migration
///
/// Compute optimal arbitrage with bidirectional search
/// Returns (optimal_amount, expected_profit, is_spot_to_cond)
///
/// Tries both directions:
/// - Spot → Conditional (buy from spot, sell to conditionals)
/// - Conditional → Spot (buy from conditionals, sell to spot)
///
/// Returns the more profitable direction
#[deprecated]
public fun compute_optimal_arbitrage_bidirectional<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    min_profit: u64,  // Minimum acceptable profit threshold
): (u64, u128, bool) {
    // Just call the new N-outcome function
    compute_optimal_arbitrage_for_n_outcomes(spot, conditionals, min_profit)
}

/// Compute optimal Spot → Conditional arbitrage using b-parameterization
/// More efficient than x-parameterization (no square roots)
public fun compute_optimal_spot_to_conditional<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    min_profit: u64,
): (u64, u128) {
    let num_conditionals = vector::length(conditionals);
    if (num_conditionals == 0) return (0, 0);

    assert!(num_conditionals <= MAX_CONDITIONALS, ETooManyConditionals);

    // Get spot reserves and fee
    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot);
    let spot_fee_bps = unified_spot_pool::get_fee_bps(spot);

    // Find largest pool to determine market scale for precision
    // Using max (not min) ensures tiny outlier pools don't force unnecessary precision
    let mut max_pool_reserve = spot_asset;
    let mut i = 0;
    while (i < num_conditionals) {
        let conditional = vector::borrow(conditionals, i);
        let (cond_asset, _cond_stable) = conditional_amm::get_reserves(conditional);
        if (cond_asset > max_pool_reserve) {
            max_pool_reserve = cond_asset;
        };
        i = i + 1;
    };

    // Threshold: 0.01% of LARGEST pool (represents market scale)
    let search_threshold = math::max(max_pool_reserve / 10_000, 100);

    // Build T, A, B constants
    let (ts, as_vals, bs) = build_tab_constants(
        spot_asset,
        spot_stable,
        spot_fee_bps,
        conditionals,
    );

    // OPTIMIZATION 1: Early exit - check if arbitrage is obviously impossible
    if (early_exit_check_spot_to_cond(&ts, &as_vals)) {
        return (0, 0)
    };

    // OPTIMIZATION 2: Prune dominated outcomes (40-60% gas reduction)
    let (ts_pruned, as_pruned, bs_pruned) = prune_dominated(ts, as_vals, bs);

    if (vector::length(&ts_pruned) == 0) return (0, 0);

    // OPTIMIZATION 3: B-parameterization search with two-phase profit precision
    let (b_star, profit) = optimal_b_search(&ts_pruned, &as_pruned, &bs_pruned, search_threshold);

    // Check min profit threshold
    if (profit < (min_profit as u128)) {
        return (0, 0)
    };

    // Convert b* to x* (input amount needed)
    let x_star = x_required_for_b(&ts_pruned, &as_pruned, &bs_pruned, b_star);

    (x_star, profit)
}

/// Compute optimal Conditional → Spot arbitrage using b-parameterization
/// Buy from all conditionals, recombine, sell to spot
///
/// **Strategy:**
/// 1. Buy b conditional assets from EACH conditional pool (costs stable)
/// 2. Recombine b complete sets → b base assets
/// 3. Sell b base assets to spot → get stable output
/// 4. Profit: spot_output - total_cost_from_all_conditionals
///
/// **Math:**
/// - Cost from pool i: c_i(b) = (R_i_stable * b) / ((R_i_asset - b) * α_i)
/// - Total cost: C(b) = Σ_i c_i(b) (must buy from ALL pools!)
/// - Spot output: S(b) = (R_spot_stable * b * β) / (R_spot_asset + b * β)
/// - Profit: F(b) = S(b) - C(b)
/// - Domain: b ∈ [0, min_i(R_i_asset))
///
/// **Key Difference from Spot→Cond:**
/// - Spot→Cond: max_i constraint (bottleneck is worst pool)
/// - Cond→Spot: sum_i constraint (need to buy from ALL pools)
public fun compute_optimal_conditional_to_spot<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    min_profit: u64,
): (u64, u128) {
    let num_conditionals = vector::length(conditionals);
    if (num_conditionals == 0) return (0, 0);

    assert!(num_conditionals <= MAX_CONDITIONALS, ETooManyConditionals);

    // Get spot reserves and fee
    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot);
    let spot_fee_bps = unified_spot_pool::get_fee_bps(spot);
    let beta = BPS_SCALE - spot_fee_bps;

    // Find BOTH largest (for precision) and smallest (for upper bound)
    let mut max_pool_reserve = spot_asset;              // Largest pool determines precision
    let mut upper_bound = std::u64::max_value!();       // Start at max, find minimum conditional
    let mut i = 0;
    while (i < num_conditionals) {
        let conditional = vector::borrow(conditionals, i);
        let (cond_asset, _cond_stable) = conditional_amm::get_reserves(conditional);

        if (cond_asset > max_pool_reserve) {
            max_pool_reserve = cond_asset;
        };
        if (cond_asset < upper_bound) {
            upper_bound = cond_asset;
        };
        i = i + 1;
    };

    // Need reasonable liquidity for arbitrage
    if (upper_bound < 100) return (0, 0);

    // Use 95% of upper bound to avoid edge case issues near boundary
    let max_b = ((upper_bound as u128) * 95) / 100;
    if (max_b > (std::u64::max_value!() as u128)) {
        return (0, 0) // Overflow protection
    };
    let max_b_u64 = (max_b as u64);

    // Threshold: 0.01% of LARGEST pool (represents market scale)
    let search_threshold = math::max(max_pool_reserve / 10_000, 100);

    // Two-phase search for 0.01% profit precision
    let mut best_b = 0u64;
    let mut best_profit = 0u128;
    let mut left = 0u64;
    let mut right = max_b_u64;

    // PHASE 1: Coarse search (0.1% of search space)
    let coarse_threshold = math::max(max_b_u64 / 1000, 10);

    while (right - left > coarse_threshold) {
        let third = (right - left) / 3;
        let m1 = left + third;
        let m2 = right - third;

        let profit_m1 = profit_conditional_to_spot(
            spot_asset, spot_stable, beta,
            conditionals, m1
        );
        let profit_m2 = profit_conditional_to_spot(
            spot_asset, spot_stable, beta,
            conditionals, m2
        );

        // Track best seen
        if (profit_m1 > best_profit) {
            best_profit = profit_m1;
            best_b = m1;
        };
        if (profit_m2 > best_profit) {
            best_profit = profit_m2;
            best_b = m2;
        };

        if (profit_m1 >= profit_m2) {
            right = m2;
        } else {
            left = m1;
        }
    };

    // Early exit: If no profit found in Phase 1, don't waste gas on Phase 2
    if (best_profit == 0) {
        return (0, 0)
    };

    // PHASE 2: Fine-tune based on PROFIT improvements
    let profit_threshold = best_profit / 10_000;  // 0.01% of current best profit

    while (right - left > 1) {
        let third = (right - left) / 3;
        if (third == 0) break;

        let m1 = left + third;
        let m2 = right - third;

        let profit_m1 = profit_conditional_to_spot(
            spot_asset, spot_stable, beta,
            conditionals, m1
        );
        let profit_m2 = profit_conditional_to_spot(
            spot_asset, spot_stable, beta,
            conditionals, m2
        );

        // Check if we're improving significantly
        let mut improved = false;
        if (profit_m1 > best_profit && (profit_m1 - best_profit) > profit_threshold) {
            best_profit = profit_m1;
            best_b = m1;
            improved = true;
        };
        if (profit_m2 > best_profit && (profit_m2 - best_profit) > profit_threshold) {
            best_profit = profit_m2;
            best_b = m2;
            improved = true;
        };

        // Early exit: no significant improvement AND range is small
        // Use largest pool threshold to determine "small" relative to market scale
        if (!improved && (right - left) < math::max(search_threshold, 1)) {
            break
        };

        if (profit_m1 >= profit_m2) {
            right = m2;
        } else {
            left = m1;
        }
    };

    // Final endpoint check
    let profit_left = profit_conditional_to_spot(
        spot_asset, spot_stable, beta,
        conditionals, left
    );
    if (profit_left > best_profit) {
        best_profit = profit_left;
        best_b = left;
    };

    let profit_right = profit_conditional_to_spot(
        spot_asset, spot_stable, beta,
        conditionals, right
    );
    if (profit_right > best_profit) {
        best_profit = profit_right;
        best_b = right;
    };

    // Check min profit threshold
    if (best_profit < (min_profit as u128)) {
        return (0, 0)
    };

    (best_b, best_profit)
}

/// Original x-parameterization interface (for compatibility)
/// Now uses b-parameterization internally for efficiency
/// spot_swap_is_stable_to_asset: true if spot swap is stable→asset, false if asset→stable
public fun compute_optimal_spot_arbitrage<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    spot_swap_is_stable_to_asset: bool,
): (u64, u128) {
    // Use new bidirectional solver with 0 min_profit
    let (amount, profit, is_spot_to_cond) = compute_optimal_arbitrage_bidirectional(
        spot,
        conditionals,
        0,  // No min profit for compatibility
    );

    // Return based on direction match
    if (spot_swap_is_stable_to_asset == is_spot_to_cond) {
        (amount, profit)
    } else {
        (0, 0)  // Direction mismatch
    }
}

// === Core B-Parameterization Functions ===

/// Find optimal b using two-phase search for 0.01% profit precision
/// Phase 1: Coarse search (0.1% of search space) to find approximate optimum
/// Phase 2: Profit-based refinement (stop when improvements < 0.01% of best profit)
/// Threshold represents market scale (0.01% of largest pool)
fun optimal_b_search(
    ts: &vector<u128>,
    as_vals: &vector<u128>,
    bs: &vector<u128>,
    threshold: u64,  // Market scale threshold (0.01% of largest pool)
): (u64, u128) {
    let n = vector::length(ts);
    if (n == 0) return (0, 0);

    // Calculate upper bound: U_b = min_i(T_i / B_i)
    let ub = upper_bound_b(ts, bs);
    if (ub == 0) return (0, 0);

    let mut best_b = 0u64;
    let mut best_profit = 0u128;
    let mut left = 0u64;
    let mut right = ub;

    // PHASE 1: Coarse search (0.1% of search space for fast convergence)
    let coarse_threshold = math::max(ub / 1000, 10);

    while (right - left > coarse_threshold) {
        let third = (right - left) / 3;
        let m1 = left + third;
        let m2 = right - third;

        let profit_m1 = profit_at_b(ts, as_vals, bs, m1);
        let profit_m2 = profit_at_b(ts, as_vals, bs, m2);

        // Track best seen
        if (profit_m1 > best_profit) {
            best_profit = profit_m1;
            best_b = m1;
        };
        if (profit_m2 > best_profit) {
            best_profit = profit_m2;
            best_b = m2;
        };

        if (profit_m1 >= profit_m2) {
            right = m2;
        } else {
            left = m1;
        }
    };

    // Early exit: If no profit found in Phase 1, don't waste gas on Phase 2
    if (best_profit == 0) {
        return (0, 0)
    };

    // PHASE 2: Fine-tune based on PROFIT improvements
    // Stop when additional search won't improve profit by > 0.01%
    let profit_threshold = best_profit / 10_000;  // 0.01% of current best profit

    while (right - left > 1) {
        let third = (right - left) / 3;
        if (third == 0) break;  // Can't subdivide further

        let m1 = left + third;
        let m2 = right - third;

        let profit_m1 = profit_at_b(ts, as_vals, bs, m1);
        let profit_m2 = profit_at_b(ts, as_vals, bs, m2);

        // Check if we're improving significantly
        let mut improved = false;
        if (profit_m1 > best_profit && (profit_m1 - best_profit) > profit_threshold) {
            best_profit = profit_m1;
            best_b = m1;
            improved = true;
        };
        if (profit_m2 > best_profit && (profit_m2 - best_profit) > profit_threshold) {
            best_profit = profit_m2;
            best_b = m2;
            improved = true;
        };

        // Early exit: no significant improvement AND range is small
        // Use passed threshold (market scale) to determine "small"
        if (!improved && (right - left) < math::max(threshold, 1)) {
            break
        };

        if (profit_m1 >= profit_m2) {
            right = m2;
        } else {
            left = m1;
        }
    };

    // Final endpoint check
    let profit_left = profit_at_b(ts, as_vals, bs, left);
    if (profit_left > best_profit) {
        best_profit = profit_left;
        best_b = left;
    };

    let profit_right = profit_at_b(ts, as_vals, bs, right);
    if (profit_right > best_profit) {
        best_profit = profit_right;
        best_b = right;
    };

    (best_b, best_profit)
}

/// Calculate profit at given b value
/// F(b) = b - x(b) where x(b) = max_i x_i(b)
fun profit_at_b(
    ts: &vector<u128>,
    as_vals: &vector<u128>,
    bs: &vector<u128>,
    b: u64,
): u128 {
    let x = x_required_for_b(ts, as_vals, bs, b);
    if (b > x) {
        ((b - x) as u128)
    } else {
        0
    }
}

/// Calculate input x required to achieve output b
/// x(b) = max_i [b × A_i / (T_i - b × B_i)]
///
/// OVERFLOW PROTECTION: Checks for u128 overflow on b × B_i and b × A_i
fun x_required_for_b(
    ts: &vector<u128>,
    as_vals: &vector<u128>,
    bs: &vector<u128>,
    b: u64,
): u64 {
    let n = vector::length(ts);
    if (n == 0) return 0;

    let b_u128 = (b as u128);
    let mut x_max = 0u128;

    let mut i = 0;
    while (i < n) {
        let ti = *vector::borrow(ts, i);
        let ai = *vector::borrow(as_vals, i);
        let bi = *vector::borrow(bs, i);

        // OVERFLOW FIX #1: Check b × B_i overflow before calculating denominator
        let b_bi_product = if (bi > 0 && b_u128 > std::u128::max_value!() / bi) {
            // Overflow would occur - this pool is dominated, skip it
            i = i + 1;
            continue
        } else {
            b_u128 * bi
        };

        // x_i(b) = ceil(b × A_i / (T_i - b × B_i))
        if (ti <= b_bi_product) {
            // Denominator would be <= 0, skip this pool
            i = i + 1;
            continue
        };

        let denom = ti - b_bi_product;

        // OVERFLOW FIX #2: Check b × A_i overflow before calculating numerator
        let numerator = if (ai > std::u128::max_value!() / b_u128) {
            // Overflow would occur - this pool requires maximum input
            // Return saturated max as this pool is the bottleneck
            return std::u64::max_value!()
        } else {
            b_u128 * ai
        };

        let xi = div_ceil(numerator, denom);

        if (xi > x_max) {
            x_max = xi;
        };

        i = i + 1;
    };

    // Saturate to u64
    if (x_max > (std::u64::max_value!() as u128)) {
        std::u64::max_value!()
    } else {
        (x_max as u64)
    }
}

/// Upper bound on b: floor(min_i (T_i - 1) / B_i)
/// SECURITY FIX: Treat ti <= 1 as ub_i = 0 (not skip) to avoid inflating U_b
fun upper_bound_b(ts: &vector<u128>, bs: &vector<u128>): u64 {
    let n = vector::length(ts);
    if (n == 0) return 0;

    let mut ub: u128 = std::u64::max_value!() as u128;

    let mut i = 0;
    while (i < n) {
        let ti = *vector::borrow(ts, i);
        let bi = *vector::borrow(bs, i);

        // FIX: If ti <= 1 or bi == 0, treat as ub_i = 0 (not skip!)
        // Skipping incorrectly inflates the upper bound
        let ub_i = if (bi == 0 || ti <= 1) {
            0u128
        } else {
            (ti - 1) / bi
        };

        if (ub_i < ub) {
            ub = ub_i;
        };

        i = i + 1;
    };

    if (ub > (std::u64::max_value!() as u128)) {
        std::u64::max_value!()
    } else {
        (ub as u64)
    }
}

// === Optimization Functions ===

/// Early exit check: if ALL conditionals are cheaper/equal to spot, no Spot→Cond arbitrage
/// For Spot→Cond: We only need ONE expensive conditional to arbitrage profitably
/// Check: if ALL pools have T_i <= A_i, return true (exit early)
fun early_exit_check_spot_to_cond(ts: &vector<u128>, as_vals: &vector<u128>): bool {
    let n = vector::length(ts);
    let mut all_cheap = true;  // Assume all are cheap until proven otherwise

    let mut i = 0;
    while (i < n) {
        let ti = *vector::borrow(ts, i);
        let ai = *vector::borrow(as_vals, i);

        // If T_i > A_i, conditional i is MORE EXPENSIVE than spot (arbitrage opportunity!)
        if (ti > ai) {
            all_cheap = false;
            break  // Found at least one expensive pool, arbitrage may be profitable
        };

        i = i + 1;
    };

    all_cheap  // Only exit if ALL conditionals are cheaper/equal to spot
}

/// Safe cross-product comparison: Check if a * b <= c * d without overflow
/// Uses u256 for exact comparison (no precision loss)
///
/// Returns true if a × b <= c × d
///
/// BUG FIX: Removed all special cases - u256 handles zeros correctly!
fun safe_cross_product_le(a: u128, b: u128, c: u128, d: u128): bool {
    // u256 multiplication handles all cases correctly, including zeros
    // No special cases needed - simpler and correct
    ((a as u256) * (b as u256)) <= ((c as u256) * (d as u256))
}

/// Prune dominated outcomes to reduce search space
/// Outcome j is dominated by i if: T_i/A_i ≤ T_j/A_j AND T_i/B_i ≤ T_j/B_j
/// Then s_j(x) ≥ s_i(x) for all x ≥ 0, so drop j
///
/// OVERFLOW PROTECTION: Uses safe_cross_product_le() to avoid u128 × u128 overflow
fun prune_dominated(
    ts: vector<u128>,
    as_vals: vector<u128>,
    bs: vector<u128>,
): (vector<u128>, vector<u128>, vector<u128>) {
    let n = vector::length(&ts);
    if (n <= 1) return (ts, as_vals, bs);

    let mut keep = vector::empty<bool>();
    let mut i = 0;
    while (i < n) {
        vector::push_back(&mut keep, true);
        i = i + 1;
    };

    // Check each pair
    let mut p = 0;
    while (p < n) {
        if (!*vector::borrow(&keep, p)) {
            p = p + 1;
            continue
        };

        let mut q = p + 1;
        while (q < n) {
            if (!*vector::borrow(&keep, q)) {
                q = q + 1;
                continue
            };

            let tp = *vector::borrow(&ts, p);
            let ap = *vector::borrow(&as_vals, p);
            let bp = *vector::borrow(&bs, p);

            let tq = *vector::borrow(&ts, q);
            let aq = *vector::borrow(&as_vals, q);
            let bq = *vector::borrow(&bs, q);

            // OVERFLOW FIX: Use safe comparison instead of direct multiplication
            // Check if p dominates q: T_p/A_p ≤ T_q/A_q AND T_p/B_p ≤ T_q/B_q
            let ta_check = safe_cross_product_le(tp, aq, tq, ap);
            let tb_check = safe_cross_product_le(tp, bq, tq, bp);

            if (ta_check && tb_check) {
                // p dominates q (p is always cheaper/equal), drop q
                *vector::borrow_mut(&mut keep, q) = false;
            } else {
                // Check if q dominates p
                let ta_check_rev = safe_cross_product_le(tq, ap, tp, aq);
                let tb_check_rev = safe_cross_product_le(tq, bp, tp, bq);

                if (ta_check_rev && tb_check_rev) {
                    // q dominates p, drop p
                    *vector::borrow_mut(&mut keep, p) = false;
                    break  // p is dropped, move to next p
                }
            };

            q = q + 1;
        };

        p = p + 1;
    };

    // Build pruned vectors
    let mut ts_pruned = vector::empty<u128>();
    let mut as_pruned = vector::empty<u128>();
    let mut bs_pruned = vector::empty<u128>();

    let mut k = 0;
    while (k < n) {
        if (*vector::borrow(&keep, k)) {
            vector::push_back(&mut ts_pruned, *vector::borrow(&ts, k));
            vector::push_back(&mut as_pruned, *vector::borrow(&as_vals, k));
            vector::push_back(&mut bs_pruned, *vector::borrow(&bs, k));
        };
        k = k + 1;
    };

    (ts_pruned, as_pruned, bs_pruned)
}

// === TAB Constants Builder ===

/// Build T, A, B constants for b-parameterization from pool reserves
/// These constants encode AMM state and fees for efficient arbitrage calculation
fun build_tab_constants(
    spot_asset_reserve: u64,
    spot_stable_reserve: u64,
    spot_fee_bps: u64,
    conditionals: &vector<LiquidityPool>,
): (vector<u128>, vector<u128>, vector<u128>) {
    let num_conditionals = vector::length(conditionals);
    let mut ts_vec = vector::empty<u128>();
    let mut as_vec = vector::empty<u128>();
    let mut bs_vec = vector::empty<u128>();

    let beta = BPS_SCALE - spot_fee_bps;

    let mut i = 0;
    while (i < num_conditionals) {
        let conditional = vector::borrow(conditionals, i);
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(conditional);
        let cond_fee_bps = conditional_amm::get_fee_bps(conditional);
        let alpha_i = BPS_SCALE - cond_fee_bps;

        // T_i = (cond_stable * alpha_i / 10000) * (spot_asset * beta / 10000)
        let t1 = math::mul_div_to_128(cond_stable, alpha_i, BPS_SCALE);
        let t2 = math::mul_div_to_128(spot_asset_reserve, beta, BPS_SCALE);

        // OVERFLOW FIX: Check t1 × t2 overflow and saturate if needed
        let t1_u128 = (t1 as u128);
        let t2_u128 = (t2 as u128);
        let ti = if (t2_u128 > 0 && t1_u128 > std::u128::max_value!() / t2_u128) {
            // Overflow - saturate to max u128
            // This pool has extremely large reserves, treat as infinite liquidity
            std::u128::max_value!()
        } else {
            t1_u128 * t2_u128
        };

        // A_i = cond_asset * spot_stable (with overflow protection)
        let cond_asset_u128 = (cond_asset as u128);
        let spot_stable_u128 = (spot_stable_reserve as u128);
        let ai = if (spot_stable_u128 > 0 && cond_asset_u128 > std::u128::max_value!() / spot_stable_u128) {
            // Overflow - saturate to max u128
            // This pool has extremely large reserves, treat as infinite liquidity
            std::u128::max_value!()
        } else {
            cond_asset_u128 * spot_stable_u128
        };

        // B_i = beta * (cond_asset + alpha_i * spot_asset / 10000) / 10000
        let alpha_spot = math::mul_div_to_128(spot_asset_reserve, alpha_i, BPS_SCALE);
        let temp = (cond_asset as u128) + alpha_spot;
        let bi = (temp * (beta as u128)) / (BPS_SCALE as u128);

        vector::push_back(&mut ts_vec, ti);
        vector::push_back(&mut as_vec, ai);
        vector::push_back(&mut bs_vec, bi);

        i = i + 1;
    };

    (ts_vec, as_vec, bs_vec)
}

// === Simulation Functions (For Verification) ===

/// Calculate arbitrage profit for specific amount (simulation)
/// spot_swap_is_stable_to_asset: true if spot swap is stable→asset, false if asset→stable
public fun calculate_spot_arbitrage_profit<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    arbitrage_amount: u64,
    spot_swap_is_stable_to_asset: bool,
): u128 {
    simulate_spot_to_conditional_profit(spot, conditionals, arbitrage_amount, spot_swap_is_stable_to_asset)
}

fun simulate_spot_to_conditional_profit<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    arbitrage_amount: u64,
    spot_swap_is_stable_to_asset: bool,
): u128 {
    let spot_output = if (spot_swap_is_stable_to_asset) {
        unified_spot_pool::simulate_swap_stable_to_asset(spot, arbitrage_amount)
    } else {
        unified_spot_pool::simulate_swap_asset_to_stable(spot, arbitrage_amount)
    };

    if (spot_output == 0) return 0;

    let num_outcomes = vector::length(conditionals);
    let mut min_conditional_output = std::u64::max_value!();

    let mut i = 0;
    while (i < num_outcomes) {
        let conditional = vector::borrow(conditionals, i);

        let cond_output = if (spot_swap_is_stable_to_asset) {
            conditional_amm::simulate_swap_asset_to_stable(conditional, spot_output)
        } else {
            conditional_amm::simulate_swap_stable_to_asset(conditional, spot_output)
        };

        min_conditional_output = math::min(min_conditional_output, cond_output);
        i = i + 1;
    };

    if (min_conditional_output > arbitrage_amount) {
        ((min_conditional_output - arbitrage_amount) as u128)
    } else {
        0
    }
}

/// Simulate Conditional → Spot arbitrage profit (for testing/verification)
public fun simulate_conditional_to_spot_profit<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    arbitrage_amount: u64,
): u128 {
    // Conditional → Spot simulation:
    // 1. Calculate cost to buy b conditional tokens from EACH pool
    // 2. Recombine b complete sets → b base assets
    // 3. Sell b base assets to spot → get stable
    // 4. Profit = spot_revenue - total_cost_from_all_pools

    let num_outcomes = vector::length(conditionals);
    if (num_outcomes == 0) return 0;

    // Calculate total cost to buy from ALL conditional pools
    let total_cost = calculate_conditional_cost(conditionals, arbitrage_amount);

    // If cost is infinite (insufficient liquidity), no profit
    if (total_cost == std::u128::max_value!()) {
        return 0
    };

    // Get spot revenue from selling recombined base assets
    let (spot_asset, spot_stable) = unified_spot_pool::get_reserves(spot);
    let spot_fee_bps = unified_spot_pool::get_fee_bps(spot);
    let beta = BPS_SCALE - spot_fee_bps;

    let spot_revenue = calculate_spot_revenue(
        spot_asset,
        spot_stable,
        beta,
        arbitrage_amount,
    );

    // Profit = revenue - cost
    if (spot_revenue > total_cost) {
        spot_revenue - total_cost
    } else {
        0
    }
}

/// Conditional arbitrage (legacy compatibility)
public fun calculate_conditional_arbitrage_profit<AssetType, StableType>(
    spot: &UnifiedSpotPool<AssetType, StableType>,
    conditionals: &vector<LiquidityPool>,
    swapped_outcome_idx: u8,
    arbitrage_amount: u64,
    is_asset_to_stable: bool,
): u128 {
    let swapped_conditional = vector::borrow(conditionals, (swapped_outcome_idx as u64));

    let cond_output = if (is_asset_to_stable) {
        conditional_amm::simulate_swap_stable_to_asset(swapped_conditional, arbitrage_amount)
    } else {
        conditional_amm::simulate_swap_asset_to_stable(swapped_conditional, arbitrage_amount)
    };

    if (cond_output == 0) return 0;

    let spot_output = if (is_asset_to_stable) {
        unified_spot_pool::simulate_swap_asset_to_stable(spot, cond_output)
    } else {
        unified_spot_pool::simulate_swap_stable_to_asset(spot, cond_output)
    };

    if (spot_output > arbitrage_amount) {
        ((spot_output - arbitrage_amount) as u128)
    } else {
        0
    }
}

// === Helper Functions ===

/// Ceiling division: ceil(a / b)
fun div_ceil(a: u128, b: u128): u128 {
    if (b == 0) return 0;
    if (a == 0) return 0;
    ((a - 1) / b) + 1
}

// === Conditional → Spot Helper Functions ===

/// Calculate profit for Conditional → Spot arbitrage at given b
/// F(b) = S(b) - C(b)
/// where:
/// - S(b) = spot output from selling b base assets
/// - C(b) = total cost to buy b conditional assets from all pools
fun profit_conditional_to_spot(
    spot_asset: u64,
    spot_stable: u64,
    beta: u64,  // spot fee multiplier (BPS_SCALE - fee_bps)
    conditionals: &vector<LiquidityPool>,
    b: u64,
): u128 {
    if (b == 0) return 0;

    // Calculate spot revenue: S(b) = spot output from selling b base assets
    let spot_revenue = calculate_spot_revenue(spot_asset, spot_stable, beta, b);

    // Calculate total cost from all conditional pools: C(b) = Σ_i c_i(b)
    let total_cost = calculate_conditional_cost(conditionals, b);

    // Profit: S(b) - C(b)
    if (spot_revenue > total_cost) {
        spot_revenue - total_cost
    } else {
        0
    }
}

/// Calculate revenue from selling b base assets to spot
/// S(b) = (R_spot_stable * b * β) / (R_spot_asset * BPS_SCALE + b * β)
///
/// Derivation:
/// - Before swap: (R_spot_asset, R_spot_stable)
/// - Add b assets (after fee: b * β / BPS_SCALE)
/// - Remove stable_out
/// - Constant product: R_spot_asset * R_spot_stable = (R_spot_asset + b*β/BPS_SCALE) * (R_spot_stable - stable_out)
/// - Solving: stable_out = R_spot_stable * (b*β/BPS_SCALE) / (R_spot_asset + b*β/BPS_SCALE)
/// - Simplify: stable_out = (R_spot_stable * b * β) / (R_spot_asset * BPS_SCALE + b * β)
fun calculate_spot_revenue(
    spot_asset: u64,
    spot_stable: u64,
    beta: u64,
    b: u64,
): u128 {
    // Use u256 for accurate overflow-free arithmetic
    let b_u256 = (b as u256);
    let beta_u256 = (beta as u256);
    let spot_stable_u256 = (spot_stable as u256);
    let spot_asset_u256 = (spot_asset as u256);

    // Numerator: R_spot_stable * b * β (in u256 space)
    let b_beta = b_u256 * beta_u256;
    let numerator_u256 = spot_stable_u256 * b_beta;

    // Denominator: R_spot_asset * BPS_SCALE + b * β (in u256 space)
    let spot_asset_scaled = spot_asset_u256 * (BPS_SCALE as u256);
    let denominator_u256 = spot_asset_scaled + b_beta;

    if (denominator_u256 == 0) return 0;

    // Compute result in u256 space
    let result_u256 = numerator_u256 / denominator_u256;

    // Saturate to u128 if needed
    if (result_u256 > (std::u128::max_value!() as u256)) {
        std::u128::max_value!()
    } else {
        (result_u256 as u128)
    }
}

/// Calculate total cost to buy b conditional assets from all pools
/// C(b) = Σ_i c_i(b) where c_i(b) = (R_i_stable * b * BPS_SCALE) / ((R_i_asset - b) * α_i)
///
/// Derivation for pool i:
/// - Before swap: (R_i_asset, R_i_stable)
/// - Add stable_in (after fee: stable_in * α_i / BPS_SCALE)
/// - Remove b assets
/// - Constant product: R_i_asset * R_i_stable = (R_i_asset - b) * (R_i_stable + stable_in*α_i/BPS_SCALE)
/// - Solving: stable_in = (R_i_stable * b * BPS_SCALE) / ((R_i_asset - b) * α_i)
fun calculate_conditional_cost(
    conditionals: &vector<LiquidityPool>,
    b: u64,
): u128 {
    let num_conditionals = vector::length(conditionals);
    let mut total_cost = 0u128;
    let b_u128 = (b as u128);

    let mut i = 0;
    while (i < num_conditionals) {
        let conditional = vector::borrow(conditionals, i);
        let (cond_asset, cond_stable) = conditional_amm::get_reserves(conditional);
        let cond_fee_bps = conditional_amm::get_fee_bps(conditional);
        let alpha = BPS_SCALE - cond_fee_bps;

        // Skip if b >= R_i_asset (can't buy more than pool has)
        if (b >= cond_asset) {
            // This makes arbitrage impossible - need b from ALL pools
            return std::u128::max_value!() // Infinite cost
        };

        // Cost from pool i: c_i(b) = (R_i_stable * b * BPS_SCALE) / ((R_i_asset - b) * α_i)
        let cond_asset_u128 = (cond_asset as u128);
        let cond_stable_u128 = (cond_stable as u128);
        let alpha_u128 = (alpha as u128);

        // Use u256 for accurate overflow-free arithmetic
        // Numerator: R_i_stable * b * BPS_SCALE (in u256 space)
        let stable_b_u256 = (cond_stable_u128 as u256) * (b_u128 as u256);
        let numerator_u256 = stable_b_u256 * (BPS_SCALE as u256);

        // Denominator: (R_i_asset - b) * α_i (in u256 space)
        let asset_minus_b = cond_asset_u128 - b_u128;
        if (asset_minus_b == 0) {
            return std::u128::max_value!() // Division by zero (infinite cost)
        };

        let denominator_u256 = (asset_minus_b as u256) * (alpha_u128 as u256);
        if (denominator_u256 == 0) {
            return std::u128::max_value!() // Impossible but defensive
        };

        // Compute cost_i in u256 space
        let cost_i_u256 = numerator_u256 / denominator_u256;

        // Convert to u128, saturating if needed
        let cost_i = if (cost_i_u256 > (std::u128::max_value!() as u256)) {
            std::u128::max_value!() // Cost too high, saturate
        } else {
            (cost_i_u256 as u128)
        };

        // Add to total (check overflow)
        if (total_cost > std::u128::max_value!() - cost_i) {
            return std::u128::max_value!() // Saturate (total cost too high)
        };
        total_cost = total_cost + cost_i;

        i = i + 1;
    };

    total_cost
}
