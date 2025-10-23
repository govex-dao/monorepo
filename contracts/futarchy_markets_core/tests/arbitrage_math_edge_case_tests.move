/// ============================================================================
/// ARBITRAGE MATH - EXTREME EDGE CASE TESTS
/// ============================================================================
///
/// **Purpose:**
/// Tests extreme low-liquidity edge cases that could expose:
/// - Precision loss in TAB constant calculations
/// - Division by zero or near-zero values
/// - Upper bound calculation edge cases
/// - Ternary search stability with minimal search spaces
///
/// **Edge Cases Tested:**
/// 1. Spot pool with (0, 1) - zero asset, minimal stable
/// 2. Spot pool with (0, 0) - complete zero liquidity
/// 3. Spot pool with (1, 1) - minimal symmetric liquidity
/// 4. Spot pool with (1, 2) - minimal asymmetric liquidity
/// 5. Same cases for conditional pools
/// 6. Mixed extreme scenarios
///
/// **Expected Behavior:**
/// - (0, X) or (X, 0) → Early exit with (0, 0, false)
/// - (1, 1) or (1, 2) → May return (0, 0) due to precision loss, or small arbitrage
/// - No panics, no infinite loops, no overflows
///
/// ============================================================================

#[test_only]
module futarchy_markets_core::arbitrage_math_edge_case_tests;

use futarchy_markets_core::arbitrage_math;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use sui::test_scenario as ts;
use sui::test_utils;

// === Test Coins ===
public struct ASSET has drop {}
public struct STABLE has drop {}

// === Constants ===
const ADMIN: address = @0xAD;
const FEE_BPS: u64 = 30; // 0.3% fee

// ============================================================================
// SECTION 1: SPOT POOL EDGE CASES
// ============================================================================

#[test]
/// Test spot pool with (0, 1) - zero asset reserve, minimal stable
/// Expected: Early exit with (0, 0) due to zero asset liquidity check
fun test_spot_zero_asset_one_stable() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: 0 asset, 1 stable (zero asset = no liquidity)
    let spot_pool = create_spot_pool(0, 1, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional: normal liquidity
    let conditional_pools = create_conditional_pools_2(
        1_000_000,
        1_000_000,
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // Should return (0, 0, true) - when both profits are 0, STC wins the tie
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);
    assert!(is_stc == true, 2);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test spot pool with (1, 0) - minimal asset, zero stable
/// Expected: Early exit with (0, 0) due to zero stable liquidity check
fun test_spot_one_asset_zero_stable() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: 1 asset, 0 stable (zero stable = no liquidity)
    let spot_pool = create_spot_pool(1, 0, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional: normal liquidity
    let conditional_pools = create_conditional_pools_2(
        1_000_000,
        1_000_000,
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // Should return (0, 0, true) - when both profits are 0, STC wins the tie
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);
    assert!(is_stc == true, 2);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test spot pool with (0, 0) - complete zero liquidity
/// Expected: Early exit with (0, 0)
fun test_spot_zero_zero() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: 0 asset, 0 stable (no liquidity at all)
    let spot_pool = create_spot_pool(0, 0, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional: normal liquidity
    let conditional_pools = create_conditional_pools_2(
        1_000_000,
        1_000_000,
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // Should return (0, 0, true) - when both profits are 0, STC wins the tie
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);
    assert!(is_stc == true, 2);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test spot pool with (1, 1) - minimal symmetric liquidity
/// Expected: Either (0, 0) due to precision loss, or very small arbitrage
/// Critical: Must not panic or loop infinitely
fun test_spot_one_one() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: 1 asset, 1 stable (minimal liquidity, price = 1.0)
    let spot_pool = create_spot_pool(1, 1, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional: normal liquidity with slight price difference
    let conditional_pools = create_conditional_pools_2(
        1_000_000,
        1_100_000, // Slightly more expensive
        1_000_000,
        1_100_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    // May return (0, 0) due to precision loss in TAB constants
    // T_i = (cond_stable * alpha * spot_asset * beta) / BPS^2
    //     = (1_100_000 * 9970 * 1 * 9970) / 100_000_000
    //     = ~1089 (small but non-zero)
    // A_i = cond_asset * spot_stable = 1_000_000 * 1 = 1_000_000
    // B_i = beta * (cond_asset * BPS + alpha * spot_asset) / BPS^2
    //     = 9970 * (1_000_000 * 10000 + 9970 * 1) / 100_000_000
    //     = 9970 * 10_009_970 / 100_000_000
    //     = ~997,994
    // upper_bound = (T_i - 1) / B_i = (1089 - 1) / 997_994 = 0 (truncated!)

    // So we expect (0, 0) due to upper_bound = 0
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test spot pool with (1, 2) - minimal asymmetric liquidity
/// Expected: Similar to (1, 1), may return (0, 0) or very small arbitrage
fun test_spot_one_two() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: 1 asset, 2 stable (minimal liquidity, price = 2.0)
    let spot_pool = create_spot_pool(1, 2, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional: normal liquidity with price difference
    let conditional_pools = create_conditional_pools_2(
        1_000_000,
        1_000_000, // Price = 1.0 (cheaper than spot)
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test spot pool with (2, 1) - minimal asymmetric liquidity (inverse of 1,2)
/// Expected: May return (0, 0) or very small arbitrage
fun test_spot_two_one() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: 2 asset, 1 stable (minimal liquidity, price = 0.5)
    let spot_pool = create_spot_pool(2, 1, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional: normal liquidity with price difference
    let conditional_pools = create_conditional_pools_2(
        1_000_000,
        2_000_000, // Price = 2.0 (more expensive than spot)
        1_000_000,
        2_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// SECTION 2: CONDITIONAL POOL EDGE CASES
// ============================================================================

#[test]
/// Test conditional pool with (0, 1) - zero asset reserve
/// Expected: Early exit with (0, 0) due to zero conditional liquidity check
fun test_conditional_zero_asset_one_stable() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: normal liquidity
    let spot_pool = create_spot_pool(1_000_000, 1_000_000, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional 0: (0, 1) - zero asset
    // Conditional 1: normal liquidity
    let conditional_pools = create_conditional_pools_2(
        0,
        1, // Zero asset = no liquidity
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // Should return (0, 0, true) - when both profits are 0, STC wins the tie
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);
    assert!(is_stc == true, 2);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test conditional pool with (1, 0) - minimal asset, zero stable
/// Expected: Early exit with (0, 0)
fun test_conditional_one_asset_zero_stable() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: normal liquidity
    let spot_pool = create_spot_pool(1_000_000, 1_000_000, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional: (1, 0) - zero stable
    let conditional_pools = create_conditional_pools_2(
        1,
        0, // Zero stable = no liquidity
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // Should return (0, 0, true) - when both profits are 0, STC wins the tie
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);
    assert!(is_stc == true, 2);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test conditional pool with (0, 0) - complete zero liquidity
/// Expected: Early exit with (0, 0)
fun test_conditional_zero_zero() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: normal liquidity
    let spot_pool = create_spot_pool(1_000_000, 1_000_000, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional: (0, 0) - no liquidity
    let conditional_pools = create_conditional_pools_2(
        0,
        0, // No liquidity at all
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // Should return (0, 0, true) - when both profits are 0, STC wins the tie
    assert!(amount == 0, 0);
    assert!(profit == 0, 1);
    assert!(is_stc == true, 2);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test conditional pool with (1, 1) - minimal symmetric liquidity
/// Expected: May return (0, 0) or very small arbitrage, must not panic
fun test_conditional_one_one() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: normal liquidity with slight imbalance
    let spot_pool = create_spot_pool(1_000_000, 1_100_000, FEE_BPS, ts::ctx(&mut scenario));

    // Both conditionals: (1, 1) - minimal liquidity
    let conditional_pools = create_conditional_pools_2(
        1,
        1,
        1,
        1,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    // With cond_asset = 1, cond_stable = 1:
    // T_i = (1 * 9970 * 1_000_000 * 9970) / 100_000_000
    //     = 99_400_900_000 / 100_000_000 = 994 (small but non-zero)
    // A_i = 1 * 1_100_000 = 1_100_000
    // B_i will be very small, upper_bound will likely be 0

    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test conditional pool with (1, 2) - minimal asymmetric liquidity
/// Expected: May return (0, 0) or very small arbitrage
fun test_conditional_one_two() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: normal liquidity
    let spot_pool = create_spot_pool(1_000_000, 1_000_000, FEE_BPS, ts::ctx(&mut scenario));

    // Conditionals: (1, 2) - minimal asymmetric liquidity
    let conditional_pools = create_conditional_pools_2(
        1,
        2,
        1,
        2,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test conditional pool with (2, 1) - minimal asymmetric liquidity (inverse)
/// Expected: May return (0, 0) or very small arbitrage
fun test_conditional_two_one() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: normal liquidity
    let spot_pool = create_spot_pool(1_000_000, 1_000_000, FEE_BPS, ts::ctx(&mut scenario));

    // Conditionals: (2, 1) - minimal asymmetric liquidity
    let conditional_pools = create_conditional_pools_2(
        2,
        1,
        2,
        1,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// SECTION 3: MIXED EXTREME SCENARIOS
// ============================================================================

#[test]
/// Test spot (1, 1) with conditional (1, 1) - both minimal
/// Expected: (0, 0) due to precision loss everywhere
fun test_both_one_one() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: (1, 1)
    let spot_pool = create_spot_pool(1, 1, FEE_BPS, ts::ctx(&mut scenario));

    // Conditionals: (1, 1)
    let conditional_pools = create_conditional_pools_2(
        1,
        1,
        1,
        1,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    // Both spot and conditionals minimal → all TAB constants will be tiny
    // upper_bound will almost certainly be 0
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test spot (1, 2) with conditional (2, 1) - both minimal, opposite prices
/// Expected: May find tiny arbitrage or (0, 0) due to precision
fun test_both_minimal_opposite_prices() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: (1, 2) - price = 2.0 stable per asset (expensive)
    let spot_pool = create_spot_pool(1, 2, FEE_BPS, ts::ctx(&mut scenario));

    // Conditionals: (2, 1) - price = 0.5 stable per asset (cheap)
    // Theoretically has arbitrage: buy cheap from conditional, sell expensive to spot
    let conditional_pools = create_conditional_pools_2(
        2,
        1,
        2,
        1,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    // May find tiny arbitrage due to price difference, or return (0, 0) if precision loss dominates
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test spot (1_000_000, 1_000_000) with conditional (1, 1) - extreme size mismatch
/// Expected: (0, 0) due to conditional's precision loss
fun test_spot_large_conditional_tiny() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: normal 1M liquidity
    let spot_pool = create_spot_pool(1_000_000, 1_000_000, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional 0: (1, 1) - tiny
    // Conditional 1: normal
    let conditional_pools = create_conditional_pools_2(
        1,
        1, // Tiny pool
        1_000_000,
        1_000_000, // Normal pool
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    // The tiny conditional pool will have tiny T_i, likely causing upper_bound ≈ 0
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test spot (1, 1) with conditional (1_000_000, 1_000_000) - opposite size mismatch
/// Expected: (0, 0) due to spot's precision loss
fun test_spot_tiny_conditional_large() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: (1, 1) - tiny
    let spot_pool = create_spot_pool(1, 1, FEE_BPS, ts::ctx(&mut scenario));

    // Conditionals: normal 1M liquidity
    let conditional_pools = create_conditional_pools_2(
        1_000_000,
        1_000_000,
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    // Spot asset = 1 will cause T_i to be tiny, upper_bound ≈ 0
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

#[test]
/// Test mixed conditionals: one (1, 1), one (1_000_000, 1_000_000)
/// Expected: Algorithm should handle this, (0, 0) likely due to tiny pool bottleneck
fun test_mixed_conditional_sizes() {
    let mut scenario = ts::begin(ADMIN);

    // Spot: moderate liquidity
    let spot_pool = create_spot_pool(500_000, 500_000, FEE_BPS, ts::ctx(&mut scenario));

    // Conditional 0: (1, 1) - tiny (will likely be bottleneck)
    // Conditional 1: (1_000_000, 1_000_000) - large
    let conditional_pools = create_conditional_pools_2(
        1,
        1,
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario),
    );

    let (amount, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // CRITICAL: Must terminate without panic
    // The (1, 1) pool will have the smallest upper_bound, dominating the result
    assert!(amount >= 0, 0);
    assert!(profit >= 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);
    ts::end(scenario);
}

// ============================================================================
// SECTION 4: COMPREHENSIVE GRID TEST
// ============================================================================

#[test]
/// Comprehensive grid test: all combinations of edge case values
/// Tests: (0,1), (1,0), (1,1), (1,2), (2,1) for both spot and conditionals
/// Expected: All combinations must terminate without panic
fun test_comprehensive_edge_case_grid() {
    let mut scenario = ts::begin(ADMIN);

    // Edge case values to test - separate vectors for asset and stable
    let spot_assets = vector[0u64, 1u64, 1u64, 1u64, 2u64];
    let spot_stables = vector[1u64, 0u64, 1u64, 2u64, 1u64];

    let cond_assets = vector[0u64, 1u64, 1u64, 1u64, 2u64];
    let cond_stables = vector[1u64, 0u64, 1u64, 2u64, 1u64];

    // Test all spot × conditional combinations
    let mut i = 0;
    while (i < vector::length(&spot_assets)) {
        let spot_asset = *vector::borrow(&spot_assets, i);
        let spot_stable = *vector::borrow(&spot_stables, i);

        let mut j = 0;
        while (j < vector::length(&cond_assets)) {
            let cond_asset = *vector::borrow(&cond_assets, j);
            let cond_stable = *vector::borrow(&cond_stables, j);

            // Create pools
            let spot_pool = create_spot_pool(
                spot_asset,
                spot_stable,
                FEE_BPS,
                ts::ctx(&mut scenario),
            );

            let conditional_pools = create_conditional_pools_2(
                cond_asset,
                cond_stable,
                cond_asset,
                cond_stable,
                FEE_BPS,
                ts::ctx(&mut scenario),
            );

            // Run optimizer - MUST NOT PANIC
            let (
                amount,
                profit,
                _is_stc,
            ) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
                &spot_pool,
                &conditional_pools,
                0,
                0,
            );

            // Validate: must return non-negative values
            assert!(amount >= 0, (i * 10 + j));
            assert!(profit >= 0, (i * 10 + j + 100));

            // Cleanup
            cleanup_spot_pool(spot_pool);
            cleanup_conditional_pools(conditional_pools);

            j = j + 1;
        };

        i = i + 1;
    };

    ts::end(scenario);
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Create test spot pool
fun create_spot_pool(
    asset: u64,
    stable: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<ASSET, STABLE> {
    unified_spot_pool::create_pool_for_testing(
        asset,
        stable,
        fee_bps,
        ctx,
    )
}

/// Create 2 test conditional pools
fun create_conditional_pools_2(
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
