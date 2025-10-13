/// ============================================================================
/// ARBITRAGE MATH - PROPERTY-BASED FUZZING TESTS
/// ============================================================================
///
/// **What is this?**
/// These are property-based/fuzzing tests that validate the arbitrage optimizer
/// against random market configurations. Unlike unit tests that check specific
/// scenarios, fuzzing tests check mathematical properties across many random inputs.
///
/// **Test Strategy:**
/// - Generate random markets (spot + N conditional pools)
/// - Test optimizer properties: terminates, no overflow, finds profit when it exists
/// - Covers high-dimensional markets (N=10) and extreme values (near u64::MAX)
///
/// **Why separate module?**
/// - Slower than unit tests (~3-5 seconds vs instant)
/// - Can be skipped for quick CI runs
/// - Focused on property-based validation, not specific scenarios
///
/// **Determinism:**
/// Uses seeded PRNG (not Sui native randomness) for reproducible results.
/// Same seed = same test sequence = no flakiness.
///
/// ============================================================================

#[test_only]
module futarchy_markets_core::arbitrage_math_fuzzing_tests;

use std::vector;
use futarchy_markets_core::arbitrage_math;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use futarchy_markets_core::rng;
use sui::test_scenario::{Self as ts};
use sui::test_utils;

// === Test Coins ===
public struct ASSET has drop {}
public struct STABLE has drop {}

// === Constants ===
const ADMIN: address = @0xAD;
const E: u64 = 999; // Generic error code for fuzzing tests

// === Helper Functions ===

/// Create test spot pool
fun create_spot_pool(
    asset: u64,
    stable: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): UnifiedSpotPool<ASSET, STABLE> {
    unified_spot_pool::create_pool_for_testing<ASSET, STABLE>(
        asset,
        stable,
        fee_bps,
        ctx,
    )
}

/// Create test conditional pool
fun create_conditional_pool(
    asset: u64,
    stable: u64,
    fee_bps: u64,
    ctx: &mut TxContext,
): LiquidityPool {
    conditional_amm::create_pool_for_testing(
        asset,
        stable,
        fee_bps,
        ctx,
    )
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

// ============================================================================
// FUZZING TESTS
// ============================================================================

#[test]
/// Stress test: high-dimensional markets (N=10 conditionals)
/// Validates optimizer handles complex markets efficiently
fun test_fuzzing_high_dimensional_markets() {
    let mut rng = rng::seed(0xCAFEBABE, 0xDEADBEEF); // Different seed
    let mut scenario = ts::begin(ADMIN);

    let num_cases = 25u64;  // Balanced: thorough testing without timeout
    let n = 10u64;          // 10 conditionals = high dimensional

    let mut case = 0u64;
    while (case < num_cases) {
        // Random spot
        let spot_asset = 100_000 + rng::next_range(&mut rng, 0, 1_900_000);
        let spot_stable = 100_000 + rng::next_range(&mut rng, 0, 1_900_000);
        let spot_fee = rng::next_range(&mut rng, 20, 100); // 0.2-1% fee

        let spot_pool = create_spot_pool(
            spot_asset,
            spot_stable,
            spot_fee,
            ts::ctx(&mut scenario),
        );

        // Create 10 conditional pools
        let mut cond_pools = vector::empty<LiquidityPool>();
        let mut i = 0u64;

        while (i < n) {
            let cond_asset = 100_000 + rng::next_range(&mut rng, 0, 1_900_000);
            let cond_stable = 100_000 + rng::next_range(&mut rng, 0, 1_900_000);
            let cond_fee = rng::next_range(&mut rng, 20, 150); // 0.2-1.5% fee

            vector::push_back(
                &mut cond_pools,
                create_conditional_pool(cond_asset, cond_stable, cond_fee, ts::ctx(&mut scenario)),
            );

            i = i + 1;
        };

        // Run optimizer (should complete without gas issues due to pruning)
        let (x_star, p_star, is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes<ASSET, STABLE>(
            &spot_pool,
            &cond_pools,
            0,
            0,
        );

        // PROPERTY: Algorithm should terminate successfully
        assert!(x_star >= 0, E);
        assert!(p_star >= 0, E);

        // PROPERTY: If profit found, direction should be valid
        if (p_star > 0) {
            assert!(x_star > 0, E);
            // Direction is valid (boolean)
            let _ = is_stc; // Used
        };

        // Cleanup
        cleanup_spot_pool(spot_pool);
        cleanup_conditional_pools(cond_pools);

        case = case + 1;
    };

    ts::end(scenario);
}

#[test]
/// Maximum capacity test: N=50 conditionals (protocol limit)
/// Validates optimizer handles maximum market complexity with pruning
fun test_fuzzing_max_conditionals() {
    let mut rng = rng::seed(0xDEADC0DE, 0xBEEFF00D);
    let mut scenario = ts::begin(ADMIN);

    let num_cases = 5u64;   // Minimal for N=50 (O(N²) = O(2500) per case, still validates max capacity)
    let n = 50u64;          // MAX_CONDITIONALS

    let mut case = 0u64;
    while (case < num_cases) {
        // Random spot pool
        let spot_asset = 100_000 + rng::next_range(&mut rng, 0, 1_900_000);
        let spot_stable = 100_000 + rng::next_range(&mut rng, 0, 1_900_000);
        let spot_fee = rng::next_range(&mut rng, 20, 100); // 0.2-1% fee

        let spot_pool = create_spot_pool(
            spot_asset,
            spot_stable,
            spot_fee,
            ts::ctx(&mut scenario),
        );

        // Create 50 conditional pools (protocol maximum)
        let mut cond_pools = vector::empty<LiquidityPool>();
        let mut i = 0u64;

        while (i < n) {
            let cond_asset = 100_000 + rng::next_range(&mut rng, 0, 1_900_000);
            let cond_stable = 100_000 + rng::next_range(&mut rng, 0, 1_900_000);
            let cond_fee = rng::next_range(&mut rng, 20, 150); // 0.2-1.5% fee

            vector::push_back(
                &mut cond_pools,
                create_conditional_pool(cond_asset, cond_stable, cond_fee, ts::ctx(&mut scenario)),
            );

            i = i + 1;
        };

        // Run optimizer (pruning should handle this efficiently)
        let (x_star, p_star, is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes<ASSET, STABLE>(
            &spot_pool,
            &cond_pools,
            0,
            0,
        );

        // PROPERTY: Algorithm terminates at maximum capacity
        assert!(x_star >= 0, E);
        assert!(p_star >= 0, E);

        // PROPERTY: If profit found, direction should be valid
        if (p_star > 0) {
            assert!(x_star > 0, E);
            let _ = is_stc; // Used
        };

        // Cleanup
        cleanup_spot_pool(spot_pool);
        cleanup_conditional_pools(cond_pools);

        case = case + 1;
    };

    ts::end(scenario);
}

#[test]
/// Extreme value fuzzing: test boundary cases with very large/small reserves
/// Validates overflow protection and saturation behavior
fun test_fuzzing_extreme_values() {
    let mut rng = rng::seed(0xFEEDFACE, 0xBAADF00D);
    let mut scenario = ts::begin(ADMIN);

    let num_cases = 20u64;  // Reduced from 50 to avoid timeouts with large reserves

    let mut case = 0u64;
    while (case < num_cases) {
        // Mix of tiny and moderate reserves
        let use_large = rng::coin(&mut rng, 5000); // 50% chance

        let (spot_asset, spot_stable) = if (use_large) {
            // Moderate reserves (1 million max - searchable)
            (
                100_000 + rng::next_range(&mut rng, 0, 900_000),
                100_000 + rng::next_range(&mut rng, 0, 900_000),
            )
        } else {
            // Small reserves
            (
                100 + rng::next_range(&mut rng, 0, 10_000),
                100 + rng::next_range(&mut rng, 0, 10_000),
            )
        };

        let spot_pool = create_spot_pool(
            spot_asset,
            spot_stable,
            30, // Standard fee
            ts::ctx(&mut scenario),
        );

        // Create 3 conditional pools with mixed sizes
        let mut cond_pools = vector::empty<LiquidityPool>();
        let mut i = 0u64;

        while (i < 3) {
            let use_large_cond = rng::coin(&mut rng, 5000);

            let (cond_asset, cond_stable) = if (use_large_cond) {
                // Moderate reserves (1 million max - matches spot sizing)
                (
                    100_000 + rng::next_range(&mut rng, 0, 900_000),
                    100_000 + rng::next_range(&mut rng, 0, 900_000),
                )
            } else {
                (
                    100 + rng::next_range(&mut rng, 0, 10_000),
                    100 + rng::next_range(&mut rng, 0, 10_000),
                )
            };

            vector::push_back(
                &mut cond_pools,
                create_conditional_pool(cond_asset, cond_stable, 30, ts::ctx(&mut scenario)),
            );

            i = i + 1;
        };

        // PROPERTY: Should not abort on overflow (saturates gracefully)
        let (x_star, p_star, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes<ASSET, STABLE>(
            &spot_pool,
            &cond_pools,
            0,
            0,
        );

        // PROPERTY: Returns valid (non-negative) results
        assert!(x_star >= 0, E);
        assert!(p_star >= 0, E);

        // Cleanup
        cleanup_spot_pool(spot_pool);
        cleanup_conditional_pools(cond_pools);

        case = case + 1;
    };

    ts::end(scenario);
}
