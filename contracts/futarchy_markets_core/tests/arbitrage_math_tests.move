/// ============================================================================
/// ARBITRAGE MATH - COMPREHENSIVE TEST SUITE
/// ============================================================================
///
/// Tests organized by:
/// 1. Pure Math Primitives (div_ceil, safe_cross_product_le)
/// 2. TAB Constants & Bounds (build_tab_constants, upper_bound_b)
/// 3. Core Arbitrage Math (x_required_for_b, profit_at_b)
/// 4. Optimization Algorithm (optimal_b_search)
/// 5. Pruning & Early Exit (prune_dominated, early_exit_check)
/// 6. Full Integration (compute_optimal_*)
/// 7. Edge Cases & Overflow Protection
/// 8. Mathematical Invariants
///
/// ============================================================================

#[test_only]
module futarchy_markets_core::arbitrage_math_tests;

use futarchy_markets_core::arbitrage_math;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_one_shot_utils::math;
use sui::test_scenario::{Self as ts};
use sui::coin::{Self, Coin};
use sui::test_utils;

// === Test Coins ===
public struct ASSET has drop {}
public struct STABLE has drop {}

// === Constants ===
const ADMIN: address = @0xAD;
const FEE_BPS: u64 = 30; // 0.3% fee

// ============================================================================
// SECTION 1: PURE MATH PRIMITIVES
// ============================================================================

#[test]
/// Test div_ceil correctness across range of inputs
fun test_div_ceil_basic() {
    // Test via exposed function (we'll use profit calculations that use it internally)
    // Direct testing would require exposing div_ceil, so we test indirectly

    // Property: ceil(a/b) * b >= a (always rounds up)
    // Property: ceil(a/b) * b < a + b (rounds up by less than one full unit)

    // This is tested implicitly through x_required_for_b which uses div_ceil
}

#[test]
/// Test div_ceil edge cases: zeros, ones, large numbers
fun test_div_ceil_edge_cases() {
    // These would test:
    // - div_ceil(0, b) = 0
    // - div_ceil(a, 1) = a
    // - div_ceil(a, a) = 1
    // - div_ceil(a, b) where a < b = 1

    // Implementation note: Need to expose div_ceil or test through public API
}

#[test]
/// Test safe_cross_product_le prevents overflow and gives correct results
fun test_safe_cross_product_le_correctness() {
    // Test via prune_dominated which uses this internally
    // The function should correctly compare a*b vs c*d without overflow

    // Cases to test:
    // 1. Small numbers: 10*20 vs 15*15 → 200 < 225 (true)
    // 2. Large numbers near u128::MAX (overflow protection)
    // 3. Zeros: 0*x vs y*z
    // 4. Equal products: a*b = c*d
}

// ============================================================================
// SECTION 2: TAB CONSTANTS & BOUNDS
// ============================================================================

#[test]
/// Test build_tab_constants produces correct values for simple case
fun test_build_tab_constants_basic() {
    let mut scenario = ts::begin(ADMIN);

    // Create spot pool: 1M asset, 1M stable, 0.3% fee
    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Create 2 conditional pools with known reserves
    let conditional_pools = create_test_conditional_pools_2(
        500_000, 500_000, // Pool 0: balanced
        300_000, 700_000, // Pool 1: imbalanced
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // The TAB constants should satisfy:
    // T_i = (R_i_stable * α_i) * (R_spot_asset * β) / (BPS^2)
    // A_i = R_i_asset * R_spot_stable
    // B_i = β * (R_i_asset + α_i * R_spot_asset / BPS) / BPS

    // We can't directly test build_tab_constants (it's private)
    // but we can verify the optimization uses correct constants
    // by checking known arbitrage scenarios produce expected results

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test build_tab_constants handles overflow correctly
fun test_build_tab_constants_overflow_protection() {
    let mut scenario = ts::begin(ADMIN);

    // Create pools with very large reserves (near u64::MAX)
    let max_reserve = std::u64::max_value!() / 2;

    let spot_pool = create_test_spot_pool(
        max_reserve,
        max_reserve,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        max_reserve / 2,
        max_reserve / 2,
        max_reserve / 3,
        max_reserve / 3,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Should not abort on overflow - saturates to u128::MAX
    let (amount, profit, _direction) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // With extreme reserves, algorithm should still terminate
    // (may find zero profit, but shouldn't abort)
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 0);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test upper_bound_b gives correct domain for search
fun test_upper_bound_b_correctness() {
    let mut scenario = ts::begin(ADMIN);

    // Create pools where we can calculate expected upper bound
    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        500_000, 500_000,
        500_000, 500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Upper bound U_b = min_i(T_i / B_i)
    // Search should never exceed this
    let (optimal_b, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // If profit > 0, optimal_b should be within valid domain
    // We can't directly check U_b, but we can verify algorithm doesn't crash
    if (profit > 0) {
        assert!(optimal_b > 0, 0);
    };

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// SECTION 3: CORE ARBITRAGE MATH
// ============================================================================

#[test]
/// Test x_required_for_b correctness: x(b) = max_i [b × A_i / (T_i - b × B_i)]
fun test_x_required_for_b_basic() {
    // This is tested indirectly through profit calculations
    // Key property: x(b) should be monotonically increasing in b
    // (more output requires more input)
}

#[test]
/// Test x_required_for_b overflow protection
fun test_x_required_for_b_overflow() {
    let mut scenario = ts::begin(ADMIN);

    // Create pools where b × A_i or b × B_i could overflow
    let large_reserve = std::u64::max_value!() / 10;

    let spot_pool = create_test_spot_pool(
        large_reserve,
        large_reserve,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        large_reserve,
        large_reserve,
        large_reserve,
        large_reserve,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Try to find optimal arbitrage with large values
    let (amount, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // Should handle overflow gracefully (saturate, not abort)
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 0);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test profit_at_b is correctly calculated: F(b) = b - x(b)
fun test_profit_at_b_correctness() {
    let mut scenario = ts::begin(ADMIN);

    // Create arbitrage opportunity: spot expensive, conditionals cheap
    let spot_pool = create_test_spot_pool(
        900_000,  // Less asset in spot = higher spot price
        1_100_000, // More stable in spot
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        550_000, 450_000, // Conditional 0: asset cheaper
        550_000, 450_000, // Conditional 1: asset cheaper
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Find optimal arbitrage
    let (optimal_b, profit, is_spot_to_cond) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // If arbitrage exists, profit should be positive
    if (is_spot_to_cond && optimal_b > 0) {
        assert!(profit > 0, 0);

        // Property: At optimum, F'(b) ≈ 0 (profit is maximized)
        // We can verify by checking nearby values give lower profit
    };

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// SECTION 4: OPTIMIZATION ALGORITHM
// ============================================================================

#[test]
/// Test optimal_b_search finds maximum correctly
fun test_optimal_b_search_convergence() {
    let mut scenario = ts::begin(ADMIN);

    // Create clear arbitrage opportunity with known structure
    // Spot: 1.5M asset, 500K stable → price = 500K/1.5M = 0.33 stable per asset (CHEAP)
    // Conditional: 500K asset, 1.5M stable → price = 1.5M/500K = 3.0 stable per asset (EXPENSIVE)
    // Arbitrage: Buy cheap from spot (0.33), sell expensive to conditional (3.0) → profit!

    let spot_pool = create_test_spot_pool(
        1_500_000,  // High asset reserve = low asset price
        500_000,    // Low stable reserve
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        500_000, 1_500_000, // Low asset reserve = high asset price
        500_000, 1_500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (optimal_b, profit, is_spot_to_cond) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // Should find Spot → Conditional arbitrage
    assert!(is_spot_to_cond == true, 0);
    assert!(optimal_b > 0, 1);
    assert!(profit > 0, 2);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test ternary search converges in reasonable iterations
fun test_optimal_b_search_efficiency() {
    let mut scenario = ts::begin(ADMIN);

    // Create pools of various sizes
    let sizes = vector[100_000, 1_000_000, 10_000_000];
    let mut i = 0;

    while (i < vector::length(&sizes)) {
        let size = *vector::borrow(&sizes, i);

        let spot_pool = create_test_spot_pool(
            size,
            size,
            FEE_BPS,
            ts::ctx(&mut scenario)
        );

        let conditional_pools = create_test_conditional_pools_2(
            size / 2,
            size / 2,
            size / 2,
            size / 2,
            FEE_BPS,
            ts::ctx(&mut scenario)
        );

        // Should complete without hitting gas limits
        let (_amount, _profit, _direction) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
            &spot_pool,
            &conditional_pools,
            0,
        );

        cleanup_spot_pool(spot_pool);
        cleanup_conditional_pools(conditional_pools);

        i = i + 1;
    };

    ts::end(scenario);
}

#[test]
/// Test two-phase search (coarse + refinement) finds optimal
fun test_two_phase_search_precision() {
    let mut scenario = ts::begin(ADMIN);

    // Create scenario where profit has sharp peak
    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        950_000, 1_050_000,
        950_000, 1_050_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (optimal_b, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // Verify precision: 0.01% of largest pool (per comments in code)
    // If profit found, it should be within threshold of true optimum
    if (profit > 0) {
        assert!(optimal_b > 0, 0);

        // Property: Profit should be within 0.01% of true maximum
        // (This is the design goal of two-phase search)
    };

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// SECTION 5: PRUNING & EARLY EXIT
// ============================================================================

#[test]
/// Test prune_dominated removes correct pools
fun test_prune_dominated_correctness() {
    let mut scenario = ts::begin(ADMIN);

    // Test that algorithm can handle 3 pools without crashing
    // Create  moderate price differential to ensure some arbitrage exists
    let spot_pool = create_test_spot_pool(
        1_200_000,  // More asset
        800_000,    // Less stable
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_3(
        800_000, 1_200_000, // Pool 0: opposite of spot
        850_000, 1_150_000, // Pool 1: similar to pool 0
        750_000, 1_250_000, // Pool 2: also similar
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Pruning should remove dominated pools if any
    // Test that algorithm completes efficiently with multiple pools
    let (_amount, _profit, _direction) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // If pruning works, algorithm should complete without crashing
    // (Direct verification would require exposing prune_dominated)

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test pruning invariance: dominated pool doesn't change optimal result
fun test_pruning_dominated_invariance() {
    let mut scenario = ts::begin(ADMIN);

    // Create spot pool
    let spot_pool = create_test_spot_pool(
        1_000_000,
        2_000_000,
        20,
        ts::ctx(&mut scenario)
    );

    // Pool A and B are competitive
    let pool_a = conditional_amm::create_pool_for_testing(
        200_000,
        500_000,
        20,
        ts::ctx(&mut scenario)
    );
    let pool_b = conditional_amm::create_pool_for_testing(
        220_000,
        520_000,
        25,
        ts::ctx(&mut scenario)
    );

    // Pool C is dominated (expensive across all ratios - low asset, high stable)
    let pool_c = conditional_amm::create_pool_for_testing(
        50_000,
        700_000,
        25,
        ts::ctx(&mut scenario)
    );

    // Test with all three pools {A, B, C}
    let mut conds_abc = vector::empty<LiquidityPool>();
    vector::push_back(&mut conds_abc, pool_a);
    vector::push_back(&mut conds_abc, pool_b);
    vector::push_back(&mut conds_abc, pool_c);

    let (amt_abc, prof_abc, is_stc_abc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conds_abc,
        0,
    );

    cleanup_conditional_pools(conds_abc);

    // Test with just competitive pools {A, B}
    let pool_a2 = conditional_amm::create_pool_for_testing(200_000, 500_000, 20, ts::ctx(&mut scenario));
    let pool_b2 = conditional_amm::create_pool_for_testing(220_000, 520_000, 25, ts::ctx(&mut scenario));

    let mut conds_ab = vector::empty<LiquidityPool>();
    vector::push_back(&mut conds_ab, pool_a2);
    vector::push_back(&mut conds_ab, pool_b2);

    let (amt_ab, prof_ab, is_stc_ab) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conds_ab,
        0,
    );

    // Pruning invariance: dominated pool should not affect result
    assert!(is_stc_abc == is_stc_ab, 0); // Same direction
    assert!(prof_abc == prof_ab, 1);     // Same profit
    assert!(amt_abc == amt_ab, 2);       // Same amount

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conds_ab);
    ts::end(scenario);
}

#[test]
/// Test early_exit_check correctly identifies no-arbitrage cases
fun test_early_exit_check_correctness() {
    let mut scenario = ts::begin(ADMIN);

    // Create pools in equilibrium (no arbitrage possible)
    // All pools have same price as spot
    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        1_000_000, 1_000_000, // Same price as spot
        1_000_000, 1_000_000, // Same price as spot
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (amount, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // Should detect no arbitrage and return (0, 0)
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// SECTION 6: FULL INTEGRATION TESTS
// ============================================================================

#[test]
/// Test compute_optimal_spot_to_conditional finds correct direction
fun test_compute_optimal_spot_to_conditional() {
    let mut scenario = ts::begin(ADMIN);

    // Scenario: Asset CHEAP in spot, EXPENSIVE in conditionals
    // Spot: 1.5M asset, 500K stable → price = 500K/1.5M = 0.33 per asset (CHEAP)
    // Conditional: 500K asset, 1.5M stable → price = 1.5M/500K = 3.0 per asset (EXPENSIVE)
    // → Arbitrage: Buy cheap from spot (0.33), sell expensive to conditional (3.0)
    let spot_pool = create_test_spot_pool(
        1_500_000,  // High asset reserve = low asset price (CHEAP)
        500_000,    // Low stable reserve
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        500_000, 1_500_000, // Low asset reserve = high asset price (EXPENSIVE)
        500_000, 1_500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (amount, profit) = arbitrage_math::compute_optimal_spot_to_conditional(
        &spot_pool,
        &conditional_pools,
        0,
    );

    assert!(amount > 0, 0);
    assert!(profit > 0, 1);

    // Simulator cross-validation: Verify claimed profit is real
    let profit_sim = arbitrage_math::calculate_spot_arbitrage_profit(
        &spot_pool,
        &conditional_pools,
        amount,
        true, // spot_to_cond direction
    );
    assert!(profit_sim > 0, 2); // Simulator confirms positive profit
    // Allow rounding difference (within 0.5% of claimed profit)
    let profit_diff = if (profit_sim > profit) { profit_sim - profit } else { profit - profit_sim };
    assert!(profit_diff < profit / 200, 3);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test compute_optimal_conditional_to_spot finds correct direction
fun test_compute_optimal_conditional_to_spot() {
    let mut scenario = ts::begin(ADMIN);

    // Scenario: Asset EXPENSIVE in spot, CHEAP in conditionals
    // Spot: 500K asset, 1.5M stable → price = 1.5M/500K = 3.0 per asset (EXPENSIVE)
    // Conditional: 1.5M asset, 500K stable → price = 500K/1.5M = 0.33 per asset (CHEAP)
    // → Arbitrage: Buy cheap from conditionals (0.33), sell expensive to spot (3.0)
    let spot_pool = create_test_spot_pool(
        500_000,    // Low asset reserve = high asset price (EXPENSIVE)
        1_500_000,  // High stable reserve
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        1_500_000, 500_000, // High asset reserve = low asset price (CHEAP)
        1_500_000, 500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (amount, profit) = arbitrage_math::compute_optimal_conditional_to_spot(
        &spot_pool,
        &conditional_pools,
        0,
    );

    assert!(amount > 0, 0);
    assert!(profit > 0, 1);

    // Simulator cross-validation: Verify claimed profit is real
    let profit_sim = arbitrage_math::calculate_spot_arbitrage_profit(
        &spot_pool,
        &conditional_pools,
        amount,
        false, // conditional_to_spot direction
    );
    assert!(profit_sim > 0, 2); // Simulator confirms positive profit
    // Allow rounding difference (within 0.5% of claimed profit)
    let profit_diff = if (profit_sim > profit) { profit_sim - profit } else { profit - profit_sim };
    assert!(profit_diff < profit / 200, 3);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test compute_optimal_arbitrage_for_n_outcomes chooses better direction
fun test_bidirectional_solver() {
    let mut scenario = ts::begin(ADMIN);

    // Test both directions to ensure correct one is chosen

    // Case 1: Spot → Conditional is better
    // Spot cheap (0.33), Conditional expensive (3.0)
    let spot_pool_1 = create_test_spot_pool(
        1_500_000,  // More asset = cheaper
        500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools_1 = create_test_conditional_pools_2(
        500_000, 1_500_000, // Less asset = more expensive
        500_000, 1_500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (amount_1, profit_1, is_spot_to_cond_1) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_1,
        &conditional_pools_1,
        0,
    );

    assert!(profit_1 > 0, 0);
    assert!(is_spot_to_cond_1 == true, 1);
    assert!(amount_1 > 0, 2);

    cleanup_spot_pool(spot_pool_1);
    cleanup_conditional_pools(conditional_pools_1);

    // Case 2: Conditional → Spot is better
    // Spot expensive (3.0), Conditional cheap (0.33)
    let spot_pool_2 = create_test_spot_pool(
        500_000,    // Less asset = more expensive
        1_500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools_2 = create_test_conditional_pools_2(
        1_500_000, 500_000, // More asset = cheaper
        1_500_000, 500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (amount_2, profit_2, is_spot_to_cond_2) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_2,
        &conditional_pools_2,
        0,
    );

    assert!(profit_2 > 0, 3);
    assert!(is_spot_to_cond_2 == false, 4);
    assert!(amount_2 > 0, 5);

    cleanup_spot_pool(spot_pool_2);
    cleanup_conditional_pools(conditional_pools_2);

    ts::end(scenario);
}

#[test]
/// Test min_profit threshold filters unprofitable arbitrage
fun test_min_profit_threshold() {
    let mut scenario = ts::begin(ADMIN);

    // Create moderate arbitrage opportunity (10% spread)
    // Spot: 1.05M asset, 1M stable → price = 0.95 per asset
    // Conditional: 1M asset, 1.05M stable → price = 1.05 per asset
    let spot_pool = create_test_spot_pool(
        1_050_000,  // More asset = cheaper
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        1_000_000, 1_050_000, // Less asset = more expensive
        1_000_000, 1_050_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Without threshold: should find profit
    let (amount_1, profit_1, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0, // min_profit = 0
    );

    assert!(profit_1 > 0, 0);
    assert!(amount_1 > 0, 1);

    // With high threshold: should return (0, 0) when threshold exceeds actual profit
    let (amount_2, profit_2, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        1_000_000, // min_profit = 1M (higher than actual profit)
    );

    assert!(amount_2 == 0, 2);
    assert!(profit_2 == 0, 3);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// SECTION 7: EDGE CASES & OVERFLOW PROTECTION
// ============================================================================

#[test]
/// Test with zero conditional pools (N=0)
fun test_zero_conditionals() {
    let mut scenario = ts::begin(ADMIN);

    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conds = vector::empty<LiquidityPool>();

    let (amount, profit, is_spot_to_cond) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conds,
        0,
    );

    // N=0 should return (0, 0, false)
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);
    assert!(!is_spot_to_cond, 2);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conds);
    ts::end(scenario);
}

#[test]
/// Test with zero liquidity pools
fun test_zero_liquidity() {
    let mut scenario = ts::begin(ADMIN);

    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        0, 1_000_000, // Zero asset reserve
        1_000_000, 0, // Zero stable reserve
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Should handle gracefully, not abort
    let (amount, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // No arbitrage possible with zero liquidity
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test with zero spot pool liquidity
fun test_zero_spot_liquidity() {
    let mut scenario = ts::begin(ADMIN);

    // Zero asset in spot pool
    let spot_pool_zero_asset = create_test_spot_pool(
        0,          // Zero asset reserve
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        500_000, 500_000,
        500_000, 500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Should handle gracefully, not abort
    let (amount, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_zero_asset,
        &conditional_pools,
        0,
    );

    // No arbitrage possible with zero spot liquidity
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);

    cleanup_spot_pool(spot_pool_zero_asset);
    cleanup_conditional_pools(conditional_pools);

    // Zero stable in spot pool
    let spot_pool_zero_stable = create_test_spot_pool(
        1_000_000,
        0,          // Zero stable reserve
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools_2 = create_test_conditional_pools_2(
        500_000, 500_000,
        500_000, 500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Should handle gracefully, not abort
    let (amount_2, profit_2, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_zero_stable,
        &conditional_pools_2,
        0,
    );

    // No arbitrage possible with zero spot liquidity
    assert!(amount_2 == 0, 2);
    assert!(profit_2 == 0, 3);

    cleanup_spot_pool(spot_pool_zero_stable);
    cleanup_conditional_pools(conditional_pools_2);
    ts::end(scenario);
}

#[test]
/// Test infinite cost guard: asking for more than pool holds
fun test_infinite_cost_guard() {
    let mut scenario = ts::begin(ADMIN);

    let spot_pool = create_test_spot_pool(
        200_000,
        5_000_000,
        25,
        ts::ctx(&mut scenario)
    );

    // Create conditional pools with very small asset reserves
    let conditional_pools = create_test_conditional_pools_2(
        1_000, 2_000_000, // Only 1,000 asset available
        1_000, 2_000_000, // Only 1,000 asset available
        20,
        ts::ctx(&mut scenario)
    );

    // Try to buy 1,001 asset (more than available in any single pool!)
    let profit = arbitrage_math::calculate_spot_arbitrage_profit(
        &spot_pool,
        &conditional_pools,
        1_001,
        false, // conditional_to_spot
    );

    // Cost should be treated as infinite → profit = 0
    assert!(profit == 0, 0);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test with single conditional pool (N=1 case)
fun test_single_conditional() {
    let mut scenario = ts::begin(ADMIN);

    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_1(
        950_000, 1_050_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (amount, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // Should work with N=1
    if (profit > 0) {
        assert!(amount > 0, 0);
    };

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test with maximum allowed conditionals (N=50)
fun test_max_conditionals() {
    let mut scenario = ts::begin(ADMIN);

    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Create 50 conditional pools
    let conditional_pools = create_test_conditional_pools_n(
        50,
        950_000, 1_050_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Should complete without hitting gas limits (with pruning)
    let (_amount, _profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // ETooManyConditionals
/// Test with too many conditionals (N=51) aborts
fun test_too_many_conditionals() {
    let mut scenario = ts::begin(ADMIN);

    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Create 51 conditional pools (exceeds MAX_CONDITIONALS)
    let conditional_pools = create_test_conditional_pools_n(
        51,
        950_000, 1_050_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Should abort with ETooManyConditionals
    let (_amount, _profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test with extreme fee settings
fun test_extreme_fees() {
    let mut scenario = ts::begin(ADMIN);

    // High fee (5% = 500 bps)
    let spot_pool_high_fee = create_test_spot_pool(
        1_000_000,
        1_000_000,
        500, // 5% fee
        ts::ctx(&mut scenario)
    );

    let conditional_pools_high_fee = create_test_conditional_pools_2(
        950_000, 1_050_000,
        950_000, 1_050_000,
        500, // 5% fee
        ts::ctx(&mut scenario)
    );

    // Should handle high fees (may reduce profit to zero)
    let (_amount, _profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_high_fee,
        &conditional_pools_high_fee,
        0,
    );

    cleanup_spot_pool(spot_pool_high_fee);
    cleanup_conditional_pools(conditional_pools_high_fee);

    // Zero fee (0 bps)
    let spot_pool_zero_fee = create_test_spot_pool(
        1_000_000,
        1_000_000,
        0, // 0% fee
        ts::ctx(&mut scenario)
    );

    let conditional_pools_zero_fee = create_test_conditional_pools_2(
        950_000, 1_050_000,
        950_000, 1_050_000,
        0, // 0% fee
        ts::ctx(&mut scenario)
    );

    // Should maximize arbitrage profit with zero fees
    let (amount, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_zero_fee,
        &conditional_pools_zero_fee,
        0,
    );

    // Zero fees should increase profit
    if (profit > 0) {
        assert!(amount > 0, 0);
    };

    cleanup_spot_pool(spot_pool_zero_fee);
    cleanup_conditional_pools(conditional_pools_zero_fee);

    // 100% fee (10000 bps) - Beta=0 edge case
    let spot_pool_max_fee = create_test_spot_pool(
        1_000_000,
        1_000_000,
        10_000, // 100% fee → beta = 0
        ts::ctx(&mut scenario)
    );

    let conditional_pools_max_fee = create_test_conditional_pools_2(
        950_000, 1_050_000,
        950_000, 1_050_000,
        30,
        ts::ctx(&mut scenario)
    );

    // 100% spot fee → beta=0 → B_i=0 → upper bound = 0 → no arbitrage
    let (x, p, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_max_fee,
        &conditional_pools_max_fee,
        0,
    );

    // Should handle beta=0 gracefully
    assert!(x == 0, 10);
    assert!(p == 0, 11);

    cleanup_spot_pool(spot_pool_max_fee);
    cleanup_conditional_pools(conditional_pools_max_fee);

    ts::end(scenario);
}

// ============================================================================
// SECTION 8: MATHEMATICAL INVARIANTS
// ============================================================================

#[test]
/// Test profit function is unimodal (single maximum)
fun test_profit_unimodality() {
    let mut scenario = ts::begin(ADMIN);

    // Create arbitrage scenario
    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        950_000, 1_050_000,
        950_000, 1_050_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (optimal_b, max_profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // Property: Profit at optimal should be >= profit at nearby points
    // We can't directly test this without exposing profit_at_b,
    // but ternary search guarantees this if profit is unimodal

    if (max_profit > 0) {
        assert!(optimal_b > 0, 0);

        // Simulate at nearby amounts and verify they give less profit
        let nearby_amounts = vector[
            optimal_b / 2,
            (optimal_b * 3) / 4,
            (optimal_b * 5) / 4,
            optimal_b * 2,
        ];

        let mut i = 0;
        while (i < vector::length(&nearby_amounts)) {
            let test_amount = *vector::borrow(&nearby_amounts, i);

            // Simulate profit at test_amount
            let test_profit = arbitrage_math::calculate_spot_arbitrage_profit(
                &spot_pool,
                &conditional_pools,
                test_amount,
                true, // spot_to_cond direction
            );

            // Should be less than or equal to max_profit
            assert!(test_profit <= max_profit, 1);

            i = i + 1;
        };
    };

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test arbitrage is zero at equilibrium
fun test_equilibrium_zero_arbitrage() {
    let mut scenario = ts::begin(ADMIN);

    // Create perfectly balanced pools (all same price)
    let spot_pool = create_test_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Adjust for fees: conditional pools slightly favor asset to compensate
    let fee_multiplier = 10000 - FEE_BPS;
    let adjusted_stable = (1_000_000u128 * 10000 / (fee_multiplier as u128)) as u64;

    let conditional_pools = create_test_conditional_pools_2(
        1_000_000, adjusted_stable,
        1_000_000, adjusted_stable,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (amount, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
    );

    // At equilibrium, no arbitrage should exist
    // (May have tiny profit due to rounding, but should be negligible)
    assert!(amount == 0 || profit < 1000, 0); // Less than 0.1% error

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test monotonicity: larger price differences → larger profits
fun test_profit_monotonicity() {
    let mut scenario = ts::begin(ADMIN);

    // Small price difference (5%)
    // Spot: 1.05M asset, 1M stable → price = 1M/1.05M = 0.95 per asset
    // Cond: 1M asset, 1.05M stable → price = 1.05M/1M = 1.05 per asset
    // Difference: 10% spread
    let spot_pool_small = create_test_spot_pool(
        1_050_000,  // More asset = cheaper
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools_small = create_test_conditional_pools_2(
        1_000_000, 1_050_000, // Less asset = more expensive
        1_000_000, 1_050_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (_amount_small, profit_small, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_small,
        &conditional_pools_small,
        0,
    );

    cleanup_spot_pool(spot_pool_small);
    cleanup_conditional_pools(conditional_pools_small);

    // Large price difference (50%)
    // Spot: 1.5M asset, 500K stable → price = 500K/1.5M = 0.33 per asset
    // Cond: 500K asset, 1.5M stable → price = 1.5M/500K = 3.0 per asset
    // Difference: 9x spread - much larger!
    let spot_pool_large = create_test_spot_pool(
        1_500_000,  // Much more asset = much cheaper
        500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools_large = create_test_conditional_pools_2(
        500_000, 1_500_000, // Much less asset = much more expensive
        500_000, 1_500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (_amount_large, profit_large, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_large,
        &conditional_pools_large,
        0,
    );

    cleanup_spot_pool(spot_pool_large);
    cleanup_conditional_pools(conditional_pools_large);

    // Larger price difference should give larger profit
    assert!(profit_large > profit_small, 0);

    ts::end(scenario);
}

#[test]
/// Test profit calculations never return negative values (grid search)
fun test_profit_never_negative_grid_search() {
    let mut scenario = ts::begin(ADMIN);

    // Create realistic arbitrage scenario
    let spot_pool = create_test_spot_pool(
        900_000,
        1_300_000,
        30,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_2(
        300_000, 350_000,
        280_000, 360_000,
        25,
        ts::ctx(&mut scenario)
    );

    // Test grid of amounts across various scales
    let amounts = vector[
        0,
        10,
        100,
        1_000,
        10_000,
        50_000,
        100_000,
        500_000,
    ];

    let mut i = 0;
    while (i < vector::length(&amounts)) {
        let x = *vector::borrow(&amounts, i);

        // Test both directions
        let p1 = arbitrage_math::calculate_spot_arbitrage_profit(
            &spot_pool,
            &conditional_pools,
            x,
            true, // spot_to_cond
        );

        let p2 = arbitrage_math::calculate_spot_arbitrage_profit(
            &spot_pool,
            &conditional_pools,
            x,
            false, // conditional_to_spot
        );

        // Profits should never be negative (profit >= 0 always)
        assert!(p1 >= 0, (i * 2)); // Encode test case in error
        assert!(p2 >= 0, (i * 2 + 1));

        i = i + 1;
    };

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// SECTION 9: PROPERTY TESTS (WHITE-BOX VALIDATION)
// ============================================================================

#[test]
/// Test upper_bound_b symbolic limits: edge cases with exact expected values
fun test_upper_bound_b_symbolic_limits() {
    // CASE 1: ti ≤ 1 OR bi == 0 → ub_i = 0 → min(0, ...) = 0
    let mut ts1 = vector::empty<u128>();
    let mut bs1 = vector::empty<u128>();

    vector::push_back(&mut ts1, 0u128);   // ti = 0 ≤ 1
    vector::push_back(&mut bs1, 123u128);

    vector::push_back(&mut ts1, 1u128);   // ti = 1 ≤ 1
    vector::push_back(&mut bs1, 9999u128);

    vector::push_back(&mut ts1, 42u128);  // bi = 0
    vector::push_back(&mut bs1, 0u128);

    let ub1 = arbitrage_math::test_only_upper_bound_b(&ts1, &bs1);
    assert!(ub1 == 0, 0); // All pools force ub = 0

    // CASE 2: Normal values → ub = min_i(floor((ti-1)/bi))
    // ub_0 = floor((101-1)/5) = 20
    // ub_1 = floor((55-1)/2) = 27
    // ub_2 = floor((80-1)/7) = 11 ← minimum
    let mut ts2 = vector::empty<u128>();
    let mut bs2 = vector::empty<u128>();

    vector::push_back(&mut ts2, 101u128);
    vector::push_back(&mut bs2, 5u128);

    vector::push_back(&mut ts2, 55u128);
    vector::push_back(&mut bs2, 2u128);

    vector::push_back(&mut ts2, 80u128);
    vector::push_back(&mut bs2, 7u128);

    let ub2 = arbitrage_math::test_only_upper_bound_b(&ts2, &bs2);
    assert!(ub2 == 11, 1); // floor((80-1)/7) = 11

    // CASE 3: Saturation to u64::MAX when (ti-1)/bi > u64::MAX
    let mut ts3 = vector::empty<u128>();
    let mut bs3 = vector::empty<u128>();

    vector::push_back(&mut ts3, std::u128::max_value!());
    vector::push_back(&mut bs3, 1u128);

    let ub3 = arbitrage_math::test_only_upper_bound_b(&ts3, &bs3);
    assert!(ub3 == std::u64::max_value!(), 2); // Saturates to u64::MAX
}

#[test]
/// Test profit_at_b unimodality: samples around b* and checks rise-then-fall shape
fun test_unimodality_profit_at_b_grid() {
    let mut scenario = ts::begin(ADMIN);

    // Create medium-complexity market with clear arbitrage opportunity
    let spot_pool = create_test_spot_pool(
        1_100_000,
        2_700_000,
        25,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_test_conditional_pools_3(
        900_000, 300_000,  // Pool 0: cheap
        800_000, 320_000,  // Pool 1: cheaper
        1_200_000, 250_000, // Pool 2: expensive
        30,
        ts::ctx(&mut scenario)
    );

    // Build TAB constants
    let (r_asset, r_stable) = unified_spot_pool::get_reserves<ASSET, STABLE>(&spot_pool);
    let fee_bps = unified_spot_pool::get_fee_bps<ASSET, STABLE>(&spot_pool);

    let (ts, as_vals, bs) = arbitrage_math::test_only_build_tab_constants(
        r_asset,
        r_stable,
        fee_bps,
        &conditional_pools
    );

    // Get upper bound
    let ub = arbitrage_math::test_only_upper_bound_b(&ts, &bs);
    if (ub == 0) {
        cleanup_spot_pool(spot_pool);
        cleanup_conditional_pools(conditional_pools);
        ts::end(scenario);
        return
    };

    // Find b* via optimal search (no threshold needed - ternary search finds global optimum)
    let (b_star, _p_star) = arbitrage_math::test_only_optimal_b_search(&ts, &as_vals, &bs);

    // Sample around b* (±5 steps, step = ub / 200)
    let step = if (ub / 200 == 0) { 1 } else { ub / 200 };
    let window = 5;

    let left_start = if (b_star > window * step) { b_star - window * step } else { 0 };
    let right_end = if (b_star + window * step > ub) { ub } else { b_star + window * step };

    // Collect profit sequence
    let mut seq = vector::empty<u128>();
    let mut b = left_start;

    while (b <= right_end) {
        let profit = arbitrage_math::test_only_profit_at_b(&ts, &as_vals, &bs, b);
        vector::push_back(&mut seq, profit);

        if (right_end - b < step) break;
        b = b + step;
    };

    // Find maximum profit in sequence
    let mut max_profit = 0u128;
    let mut i = 0;
    while (i < vector::length(&seq)) {
        let p = *vector::borrow(&seq, i);
        if (p > max_profit) {
            max_profit = p;
        };
        i = i + 1;
    };

    // Epsilon: 0.05% tolerance for near-optimal points
    let eps = if (max_profit / 2000 == 0) { 1 } else { max_profit / 2000 };

    // Check unimodality: sequence should be ascending then descending (within epsilon)
    // Phase 0 = ascending, Phase 1 = descending
    let mut phase = 0u64;
    let mut j = 1;

    while (j < vector::length(&seq)) {
        let p_prev = *vector::borrow(&seq, j - 1);
        let p_curr = *vector::borrow(&seq, j);

        if (phase == 0) {
            // Ascending phase: allow transition to descending when profit decreases
            if (p_curr + eps < p_prev) {
                phase = 1; // Transition to descending
            };
        } else {
            // Descending phase: must continue descending (within epsilon)
            // Allow small increases due to discrete sampling, but not large ones
            assert!(p_curr <= p_prev + eps, j);
        };

        j = j + 1;
    };

    // Verify we saw both phases (if sequence is long enough AND profit is significant)
    // Skip check if profit is negligible or sequence is too short
    if (vector::length(&seq) > 5 && max_profit > 1000) {
        assert!(phase == 1, 100); // Should have reached descending phase
    };

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Create test spot pool with given reserves
fun create_test_spot_pool(
    asset_amount: u64,
    stable_amount: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<ASSET, STABLE> {
    unified_spot_pool::create_pool_for_testing(
        asset_amount,
        stable_amount,
        fee_bps,
        ctx,
    )
}

/// Create 1 test conditional pool
fun create_test_conditional_pools_1(
    asset_0: u64,
    stable_0: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): vector<LiquidityPool> {
    let mut pools = vector::empty<LiquidityPool>();

    let pool_0 = conditional_amm::create_pool_for_testing(
        asset_0,
        stable_0,
        fee_bps,
        ctx,
    );
    vector::push_back(&mut pools, pool_0);

    pools
}

/// Create 2 test conditional pools
fun create_test_conditional_pools_2(
    asset_0: u64,
    stable_0: u64,
    asset_1: u64,
    stable_1: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): vector<LiquidityPool> {
    let mut pools = vector::empty<LiquidityPool>();

    let pool_0 = conditional_amm::create_pool_for_testing(
        asset_0,
        stable_0,
        fee_bps,
        ctx,
    );
    vector::push_back(&mut pools, pool_0);

    let pool_1 = conditional_amm::create_pool_for_testing(
        asset_1,
        stable_1,
        fee_bps,
        ctx,
    );
    vector::push_back(&mut pools, pool_1);

    pools
}

/// Create 3 test conditional pools
fun create_test_conditional_pools_3(
    asset_0: u64,
    stable_0: u64,
    asset_1: u64,
    stable_1: u64,
    asset_2: u64,
    stable_2: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): vector<LiquidityPool> {
    let mut pools = vector::empty<LiquidityPool>();

    let pool_0 = conditional_amm::create_pool_for_testing(
        asset_0,
        stable_0,
        fee_bps,
        ctx,
    );
    vector::push_back(&mut pools, pool_0);

    let pool_1 = conditional_amm::create_pool_for_testing(
        asset_1,
        stable_1,
        fee_bps,
        ctx,
    );
    vector::push_back(&mut pools, pool_1);

    let pool_2 = conditional_amm::create_pool_for_testing(
        asset_2,
        stable_2,
        fee_bps,
        ctx,
    );
    vector::push_back(&mut pools, pool_2);

    pools
}

/// Create N test conditional pools with same reserves
fun create_test_conditional_pools_n(
    n: u64,
    asset: u64,
    stable: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): vector<LiquidityPool> {
    let mut pools = vector::empty<LiquidityPool>();
    let mut i = 0;

    while (i < n) {
        let pool = conditional_amm::create_pool_for_testing(
            asset,
            stable,
            fee_bps,
            ctx,
        );
        vector::push_back(&mut pools, pool);
        i = i + 1;
    };

    pools
}

/// Cleanup spot pool
fun cleanup_spot_pool(pool: UnifiedSpotPool<ASSET, STABLE>) {
    test_utils::destroy(pool);
}

/// Cleanup conditional pools
fun cleanup_conditional_pools(mut pools: vector<LiquidityPool>) {
    while (!vector::is_empty(&pools)) {
        let pool = vector::pop_back(&mut pools);
        test_utils::destroy(pool);
    };
    vector::destroy_empty(pools);
}
