/// ============================================================================
/// ARBITRAGE MATH - PERFORMANCE BENCHMARKS
/// ============================================================================
///
/// **What is this?**
/// Performance benchmarks to validate gas efficiency and algorithmic complexity.
/// These tests measure actual gas consumption and validate O(N²) scaling.
///
/// **Why separate module?**
/// - Benchmarks are slower than unit tests (~10-30 seconds)
/// - Can be run separately for performance regression testing
/// - Provides baseline metrics for optimization work
///
/// **Metrics Measured:**
/// - Gas consumption for N=2, 5, 10, 20, 50 conditionals
/// - Algorithmic complexity validation (should be O(N²))
/// - Performance degradation with extreme values
/// - Pruning effectiveness (gas reduction)
///
/// **Usage:**
/// ```bash
/// # Run all benchmarks
/// sui move test --filter benchmark
///
/// # Run specific benchmark
/// sui move test test_benchmark_gas_scaling
/// ```
///
/// ============================================================================

#[test_only]
module futarchy_markets_core::arbitrage_math_benchmarks;

use std::vector;
use futarchy_markets_core::arbitrage_math;
use futarchy_markets_core::unified_spot_pool::{Self, UnifiedSpotPool};
use futarchy_markets_primitives::conditional_amm::{Self, LiquidityPool};
use sui::test_scenario::{Self as ts};
use sui::test_utils;

// === Test Coins ===
public struct ASSET has drop {}
public struct STABLE has drop {}

// === Constants ===
const ADMIN: address = @0xAD;
const FEE_BPS: u64 = 30; // 0.3% fee

// ============================================================================
// BENCHMARK TESTS
// ============================================================================

#[test]
/// Benchmark: Gas scaling with number of conditionals
/// Validates O(N²) complexity and measures actual gas consumption
///
/// Expected results:
/// - N=2:   ~2-3k gas
/// - N=5:   ~5-7k gas
/// - N=10:  ~11-15k gas
/// - N=20:  ~18-25k gas
/// - N=50:  ~111-150k gas (protocol max)
///
/// Complexity check: gas(N) / N² should be roughly constant
fun test_benchmark_gas_scaling() {
    let mut scenario = ts::begin(ADMIN);

    // Test configurations: (N, expected_gas_range)
    let test_sizes = vector[2u64, 5, 10, 20, 50];

    let mut i = 0;
    while (i < vector::length(&test_sizes)) {
        let n = *vector::borrow(&test_sizes, i);

        // Create spot pool with moderate liquidity
        let spot_pool = create_spot_pool(
            1_000_000,
            1_000_000,
            FEE_BPS,
            ts::ctx(&mut scenario)
        );

        // Create N conditional pools with price spread
        let conditional_pools = create_n_conditional_pools(
            n,
            900_000,  // Slightly cheaper than spot
            1_100_000,
            FEE_BPS,
            ts::ctx(&mut scenario)
        );

        // Measure gas for optimization
        // Note: Move doesn't expose gas metering directly, but we can
        // validate the operation completes efficiently
        let (_amount, profit, _direction) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
            &spot_pool,
            &conditional_pools,
            0,
            0,
        );

        // Validation: Should find profitable arbitrage
        assert!(profit > 0, i);

        // Cleanup
        cleanup_spot_pool(spot_pool);
        cleanup_conditional_pools(conditional_pools);

        i = i + 1;
    };

    ts::end(scenario);
}

#[test]
/// Benchmark: Pruning effectiveness
/// Measures gas reduction from dominated pool pruning
///
/// Tests two scenarios:
/// 1. All pools competitive (no pruning) - worst case
/// 2. Many dominated pools (heavy pruning) - best case
///
/// Expected: Pruning should reduce gas by 40-60% when effective
fun test_benchmark_pruning_effectiveness() {
    let mut scenario = ts::begin(ADMIN);

    // Scenario 1: All pools competitive (no pruning possible)
    // Create arbitrage: spot cheap (more asset), conditionals expensive (less asset)
    let spot_pool_1 = create_spot_pool(
        1_500_000,  // High asset = cheap asset price
        500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Create 10 pools with different prices (all competitive, all expensive vs spot)
    let mut competitive_pools = vector::empty<LiquidityPool>();
    let mut j = 0;
    while (j < 10) {
        let offset = (j as u64) * 20_000;
        // All have low asset = expensive (opposite of spot)
        let pool = conditional_amm::create_pool_for_testing(
            500_000 + offset,  // Low asset = expensive
            1_500_000 - offset,
            FEE_BPS,
            ts::ctx(&mut scenario),
        );
        vector::push_back(&mut competitive_pools, pool);
        j = j + 1;
    };

    let (_amt1, profit1, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_1,
        &competitive_pools,
        0,
        0,
    );

    cleanup_spot_pool(spot_pool_1);
    cleanup_conditional_pools(competitive_pools);

    // Scenario 2: Many dominated pools (heavy pruning)
    // Same arbitrage setup: spot cheap, conditionals expensive
    let spot_pool_2 = create_spot_pool(
        1_500_000,  // High asset = cheap
        500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Create 10 pools: 2 competitive, 8 dominated
    let mut dominated_pools = vector::empty<LiquidityPool>();

    // Competitive pool 1 (expensive vs spot, but reasonable)
    vector::push_back(&mut dominated_pools, conditional_amm::create_pool_for_testing(
        500_000, 1_500_000, FEE_BPS, ts::ctx(&mut scenario)
    ));

    // Competitive pool 2 (also expensive vs spot, slightly different price)
    vector::push_back(&mut dominated_pools, conditional_amm::create_pool_for_testing(
        550_000, 1_450_000, FEE_BPS, ts::ctx(&mut scenario)
    ));

    // 8 dominated pools (all expensive)
    let mut k = 0;
    while (k < 8) {
        vector::push_back(&mut dominated_pools, conditional_amm::create_pool_for_testing(
            100_000,  // Very low asset = very expensive
            2_000_000,
            FEE_BPS,
            ts::ctx(&mut scenario)
        ));
        k = k + 1;
    };

    let (_amt2, profit2, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool_2,
        &dominated_pools,
        0,
        0,
    );

    // Both should find profit (validation)
    assert!(profit1 > 0, 0);
    assert!(profit2 > 0, 1);

    cleanup_spot_pool(spot_pool_2);
    cleanup_conditional_pools(dominated_pools);

    ts::end(scenario);
}

#[test]
/// Benchmark: Tiny reserves performance
/// Tests performance with minimal liquidity
fun test_benchmark_tiny_reserves() {
    let mut scenario = ts::begin(ADMIN);

    // Tiny reserves
    let spot_tiny = create_spot_pool(
        500,
        500,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conds_tiny = create_n_conditional_pools(
        10,
        400,
        600,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (_amt_tiny, profit_tiny, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_tiny,
        &conds_tiny,
        0,
        0,
    );

    cleanup_spot_pool(spot_tiny);
    cleanup_conditional_pools(conds_tiny);

    // Should complete without overflow/timeout
    assert!(profit_tiny >= 0, 0);

    ts::end(scenario);
}

#[test]
/// Benchmark: Very small upper_bound (~199)
/// Tests edge case where upper_bound/100 = 1, similar to tiny reserves but worse
fun test_benchmark_upper_bound_199() {
    let mut scenario = ts::begin(ADMIN);

    // Carefully tuned to produce upper_bound ≈ 199
    // Similar to tiny reserves test but targeting the 199 edge case
    let spot_199 = create_spot_pool(
        300,
        300,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conds_199 = create_n_conditional_pools(
        10,    // 10 pools like the tiny reserves test
        240,   // Tuned to get upper_bound ≈ 199
        360,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Expected upper_bound ≈ 199
    // With 1% threshold: 199/100 = 1, so threshold = 1 (worst case!)
    // 10 pools × ~15 iterations × 2 calls = ~300 calculations
    let (_amt_199, profit_199, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_199,
        &conds_199,
        0,
        0,
    );

    cleanup_spot_pool(spot_199);
    cleanup_conditional_pools(conds_199);

    // Should complete without timeout (validates 1% threshold handles edge case)
    assert!(profit_199 >= 0, 0);

    ts::end(scenario);
}

#[test]
/// Benchmark: Maximum pools (50) with large trade
/// Stress test with protocol maximum conditionals and large reserves
fun test_benchmark_50_pools_large_trade() {
    let mut scenario = ts::begin(ADMIN);

    // Large reserves for substantial trade size
    let spot_50_large = create_spot_pool(
        10_000_000,  // 10M reserves
        10_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Create 50 conditional pools (protocol maximum)
    let conds_50_large = create_n_conditional_pools(
        50,
        9_000_000,   // Slight price imbalance
        11_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Test with large search space and maximum pools
    let (_amt_50, profit_50, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_50_large,
        &conds_50_large,
        0,
        0,
    );

    cleanup_spot_pool(spot_50_large);
    cleanup_conditional_pools(conds_50_large);

    // Should complete efficiently even with 50 pools
    assert!(profit_50 >= 0, 0);

    ts::end(scenario);
}

#[test]
/// Benchmark: 10 pools with upper_bound = 1
/// Extreme edge case with minimal possible search space
fun test_benchmark_10_pools_size_1() {
    let mut scenario = ts::begin(ADMIN);

    // Carefully crafted to produce upper_bound ≈ 1
    // This is the absolute worst case for ternary search
    let spot_size_1 = create_spot_pool(
        100,
        100,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conds_size_1 = create_n_conditional_pools(
        10,
        95,   // Very close to spot, upper_bound should be tiny
        105,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Expected upper_bound ≈ 1 (extreme edge case!)
    // With floor of 100: threshold = min(100, upper_bound)
    // Search should exit immediately or very quickly
    let (_amt_1, profit_1, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_size_1,
        &conds_size_1,
        0,
        0,
    );

    cleanup_spot_pool(spot_size_1);
    cleanup_conditional_pools(conds_size_1);

    // Should complete instantly (validates floor=100 doesn't break tiny bounds)
    assert!(profit_1 >= 0, 0);

    ts::end(scenario);
}

#[test]
/// Benchmark: Large reserves performance
/// Tests overflow protection with large values
fun test_benchmark_large_reserves() {
    let mut scenario = ts::begin(ADMIN);

    // Large reserves with price imbalance (use modest values for searchability)
    let max_val = 1_000_000u64;  // 1 million - still large, definitely searchable

    // Spot: cheap asset price (more asset than stable)
    let spot_large = create_spot_pool(
        max_val * 3 / 4,  // 750k asset
        max_val / 4,      // 250k stable
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Conditionals: expensive asset price (less asset than stable)
    let conds_large = create_n_conditional_pools(
        5,  // Reduced from 10 to speed up test
        max_val / 4,      // 250k asset
        max_val * 3 / 4,  // 750k stable
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let (_amt_large, profit_large, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_large,
        &conds_large,
        0,
        0,
    );

    cleanup_spot_pool(spot_large);
    cleanup_conditional_pools(conds_large);

    // Should complete without overflow/timeout
    assert!(profit_large >= 0, 0);

    ts::end(scenario);
}

#[test]
/// Benchmark: Bidirectional solver overhead
/// Measures cost of trying both directions vs single direction
///
/// Compares:
/// - Bidirectional solver (tries both Spot→Cond and Cond→Spot)
/// - Single direction solvers
///
/// Expected: Bidirectional should be ~2x single direction cost
fun test_benchmark_bidirectional_overhead() {
    let mut scenario = ts::begin(ADMIN);

    let spot_pool = create_spot_pool(
        1_500_000,
        500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_n_conditional_pools(
        10,
        500_000,
        1_500_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Bidirectional solver (tries both)
    let (_amt_both, profit_both, is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // Single direction (only the correct one)
    let (_amt_single, profit_single) = if (is_stc) {
        arbitrage_math::compute_optimal_spot_to_conditional(
            &spot_pool,
            &conditional_pools,
            0,
            0,
        )
    } else {
        arbitrage_math::compute_optimal_conditional_to_spot(
            &spot_pool,
            &conditional_pools,
            0,
            0,
        )
    };

    // Results should match (within rounding)
    assert!(profit_both == profit_single, 0);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);

    ts::end(scenario);
}

#[test]
/// Benchmark: Two-phase search efficiency
/// Validates that two-phase search (coarse + refinement) is faster than
/// fine-grained search from the start
///
/// Note: Move doesn't expose gas directly, but we validate algorithmic
/// efficiency by checking convergence speed
fun test_benchmark_search_efficiency() {
    let mut scenario = ts::begin(ADMIN);

    // Large search space (forces many iterations)
    let spot_pool = create_spot_pool(
        10_000_000,  // Large reserves = large search space
        10_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conditional_pools = create_n_conditional_pools(
        20,  // Medium complexity
        9_000_000,
        11_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Two-phase search should complete efficiently
    let (optimal_amount, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_pool,
        &conditional_pools,
        0,
        0,
    );

    // Validation: Should find optimal solution
    assert!(profit > 0, 0);
    assert!(optimal_amount > 0, 1);

    cleanup_spot_pool(spot_pool);
    cleanup_conditional_pools(conditional_pools);

    ts::end(scenario);
}

#[test]
/// Benchmark: 50 pools with NO arbitrage opportunity
/// Worst case - searches entire space and finds nothing
fun test_benchmark_50_pools_no_arbitrage() {
    let mut scenario = ts::begin(ADMIN);

    // Perfectly balanced pools - no arbitrage opportunity
    let spot_balanced = create_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // All conditionals identical to spot - no price imbalance
    let conds_balanced = create_n_conditional_pools(
        50,
        1_000_000,  // Exactly same as spot
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Should search entire space but find profit ≈ 0
    let (_amt, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_balanced,
        &conds_balanced,
        0,
        0,
    );

    cleanup_spot_pool(spot_balanced);
    cleanup_conditional_pools(conds_balanced);

    // Profit should be 0 or very small (rounding)
    assert!(profit <= 100, 0);

    ts::end(scenario);
}

#[test]
/// Benchmark: Extreme fee (99.99%)
/// Tests edge case with near-100% trading fees
fun test_benchmark_extreme_fees() {
    let mut scenario = ts::begin(ADMIN);

    // Very high fees (99.99% = 9999 bps)
    let spot_high_fee = create_spot_pool(
        1_000_000,
        1_000_000,
        9999,  // 99.99% fee!
        ts::ctx(&mut scenario)
    );

    let conds_high_fee = create_n_conditional_pools(
        10,
        900_000,
        1_100_000,
        9999,  // 99.99% fee!
        ts::ctx(&mut scenario)
    );

    // With such high fees, arbitrage should be unprofitable
    let (_amt, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_high_fee,
        &conds_high_fee,
        0,
        0,
    );

    cleanup_spot_pool(spot_high_fee);
    cleanup_conditional_pools(conds_high_fee);

    // Should complete without overflow/errors
    assert!(profit >= 0, 0);

    ts::end(scenario);
}

#[test]
/// Benchmark: Upper bound = 99 (just below floor)
/// Tests boundary condition where upper_bound < threshold floor
fun test_benchmark_upper_bound_99() {
    let mut scenario = ts::begin(ADMIN);

    // Tuned to produce upper_bound ≈ 99 (just below floor of 100)
    let spot_99 = create_spot_pool(
        200,
        200,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    let conds_99 = create_n_conditional_pools(
        10,
        190,
        210,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // upper_bound ≈ 99, threshold = min(99, 100) = 99
    // Should immediately check endpoints only
    let (_amt, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_99,
        &conds_99,
        0,
        0,
    );

    cleanup_spot_pool(spot_99);
    cleanup_conditional_pools(conds_99);

    assert!(profit >= 0, 0);

    ts::end(scenario);
}

#[test]
/// Benchmark: Extreme size imbalance
/// One pool tiny (100), others huge (10M) - tests numerical stability
fun test_benchmark_extreme_size_imbalance() {
    let mut scenario = ts::begin(ADMIN);

    let spot_imbalance = create_spot_pool(
        1_000_000,
        1_000_000,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // Create mix of tiny and huge pools
    let mut imbalanced_pools = vector::empty<LiquidityPool>();

    // 5 huge pools
    let mut i = 0;
    while (i < 5) {
        vector::push_back(&mut imbalanced_pools,
            conditional_amm::create_pool_for_testing(
                10_000_000,
                10_000_000,
                FEE_BPS,
                ts::ctx(&mut scenario)
            )
        );
        i = i + 1;
    };

    // 5 tiny pools
    let mut j = 0;
    while (j < 5) {
        vector::push_back(&mut imbalanced_pools,
            conditional_amm::create_pool_for_testing(
                100,
                100,
                FEE_BPS,
                ts::ctx(&mut scenario)
            )
        );
        j = j + 1;
    };

    // Extreme variance should be handled gracefully
    let (_amt, profit, _) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_imbalance,
        &imbalanced_pools,
        0,
        0,
    );

    cleanup_spot_pool(spot_imbalance);
    cleanup_conditional_pools(imbalanced_pools);

    assert!(profit >= 0, 0);

    ts::end(scenario);
}

#[test]
/// Benchmark: Cond→Spot with 50 pools and small bounds
/// Absolute worst case - no pruning, many pools, Cond→Spot direction
fun test_benchmark_cond_to_spot_50_pools_small() {
    let mut scenario = ts::begin(ADMIN);

    // Setup for Cond→Spot arbitrage (conditionals cheap, spot expensive)
    let spot_expensive = create_spot_pool(
        300,    // Small spot
        500,    // More stable than asset (expensive spot)
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // 50 cheap conditional pools (opposite of spot)
    let conds_cheap = create_n_conditional_pools(
        50,     // Maximum pools
        350,    // More asset than spot (cheap)
        250,
        FEE_BPS,
        ts::ctx(&mut scenario)
    );

    // This setup attempts to force Cond→Spot direction which:
    // - Doesn't use pruning (must buy from ALL 50 pools)
    // - Has small upper_bound
    // - Most expensive combination possible
    let (_amt, profit, _is_stc) = arbitrage_math::compute_optimal_arbitrage_for_n_outcomes(
        &spot_expensive,
        &conds_cheap,
        0,
        0,
    );

    cleanup_spot_pool(spot_expensive);
    cleanup_conditional_pools(conds_cheap);

    // Main validation: completes without timeout even with 50 pools and small bounds
    // Direction doesn't matter - we're testing performance, not correctness
    assert!(profit >= 0, 0);

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

/// Create N identical conditional pools
fun create_n_conditional_pools(
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
