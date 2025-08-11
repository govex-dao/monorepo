#[test_only]
module futarchy::amm_edge_case_tests;

use futarchy::conditional_amm::{Self};
use futarchy::math;
use sui::test_scenario::{Self as test, next_tx, ctx};
use sui::object;
use std::vector;

// ======== Test Constants ========
const ADMIN: address = @0xA;
const USER_1: address = @0x1;

const INITIAL_RESERVE: u64 = 1_000_000;
const SWAP_FEE_RATE: u64 = 30; // 0.3% = 30/10000

// ======== Edge Case Tests ========

#[test]
fun test_swap_zero_amount_returns_zero() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create normal pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Swap zero amount should return zero output
    let quote = conditional_amm::quote_swap_asset_to_stable(&pool, 0);
    assert!(quote == 0, 0);
    
    // Also test stable to asset
    let quote_reverse = conditional_amm::quote_swap_stable_to_asset(&pool, 0);
    assert!(quote_reverse == 0, 1);
    
    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_pool_drain_protection() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create test pool with small reserves
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        1_000,
        1_000,
        ctx(&mut scenario)
    );
    
    // Try to swap an amount that would drain the pool
    // This should succeed but leave minimal reserves
    let huge_swap = 1_000_000_000; // Huge amount
    let quote = conditional_amm::quote_swap_asset_to_stable(&pool, huge_swap);
    
    // Quote should be less than total stable reserve (can't fully drain)
    assert!(quote < 1_000, 0);
    
    // Calculate what reserves would be after this swap
    let new_stable = 1_000 - quote;
    assert!(new_stable > 0, 1); // Should never reach exactly 0
    
    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_extreme_swap_ratios() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    
    // Test 1: Extremely unbalanced pool
    let unbalanced_pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        100_000_000, // 100M
        100,         // 100 - ratio 1,000,000:1
        ctx(&mut scenario)
    );
    
    // Small swap in the scarce direction should be very expensive
    let small_swap = 10;
    let quote = conditional_amm::quote_swap_asset_to_stable(&unbalanced_pool, small_swap);
    
    // Due to extreme imbalance, output should be minimal
    assert!(quote == 0, 0); // Likely rounds to 0
    
    // Large swap should get some output
    let large_swap = 10_000_000; // 10% of asset reserve
    let large_quote = conditional_amm::quote_swap_asset_to_stable(&unbalanced_pool, large_swap);
    assert!(large_quote > 0, 1);
    
    // Test 2: Opposite direction with extreme ratio
    let reverse_swap = 10; // Try to get a lot of asset for little stable
    let reverse_quote = conditional_amm::quote_swap_stable_to_asset(&unbalanced_pool, reverse_swap);
    
    // Should get significant asset due to imbalance
    assert!(reverse_quote > reverse_swap * 1000, 2);
    
    conditional_amm::destroy_for_testing(unbalanced_pool);
    test::end(scenario);
}

#[test]
fun test_rounding_and_precision() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    
    // Create pools with different scales
    let mut pools = vector[
        conditional_amm::create_test_pool(dummy_market_id, 0, SWAP_FEE_RATE, 10, 10, ctx(&mut scenario)),
        conditional_amm::create_test_pool(dummy_market_id, 1, SWAP_FEE_RATE, 100, 100, ctx(&mut scenario)),
        conditional_amm::create_test_pool(dummy_market_id, 2, SWAP_FEE_RATE, 1_000, 1_000, ctx(&mut scenario)),
        conditional_amm::create_test_pool(dummy_market_id, 3, SWAP_FEE_RATE, 10_000, 10_000, ctx(&mut scenario)),
    ];
    
    // Test tiny swaps across different pool sizes
    let mut i = 0;
    while (i < vector::length(&pools)) {
        let pool = vector::borrow(&pools, i);
        
        // Test swap amounts proportional to pool size
        let swap_amount = if (i == 0) { 1 }
                         else if (i == 1) { 10 }
                         else if (i == 2) { 100 }
                         else { 1000 };
        
        let quote1 = conditional_amm::quote_swap_asset_to_stable(pool, swap_amount);
        let quote2 = conditional_amm::quote_swap_stable_to_asset(pool, swap_amount);
        
        // Verify rounding behavior - tiny swaps may round to 0
        // For balanced 1:1 pools, we expect roughly 1:1 swaps minus fees
        if (swap_amount >= 100) {
            // Larger swaps should always produce non-zero output
            assert!(quote1 > 0 && quote2 > 0, i);
            
            // Verify quotes are reasonable
            // For a swap of X on an X:X pool, output ≈ X * X / (X + X) = X/2 for large swaps
            // For smaller swaps relative to pool, output is closer to input minus fees
            let expected_min = if (swap_amount <= 100) {
                (swap_amount * 90) / 100  // ~90% for small swaps (10% slippage + fees)
            } else {
                (swap_amount * 80) / 100  // ~80% for larger swaps (more slippage)
            };
            assert!(quote1 >= expected_min, i + 10);
            assert!(quote2 >= expected_min, i + 20);
        };
        
        i = i + 1;
    };
    
    // Clean up
    while (vector::length(&pools) > 0) {
        let pool = vector::pop_back(&mut pools);
        conditional_amm::destroy_for_testing(pool);
    };
    
    vector::destroy_empty(pools);
    test::end(scenario);
}

#[test]
fun test_fee_edge_cases() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    
    // Test with different fee rates
    let zero_fee_pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        0, // 0% fee
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    let high_fee_pool = conditional_amm::create_test_pool(
        dummy_market_id,
        1,
        9999, // 99.99% fee (maximum allowed)
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    let swap_amount = 10_000;
    
    // Zero fee should give best rate
    let zero_fee_quote = conditional_amm::quote_swap_asset_to_stable(&zero_fee_pool, swap_amount);
    
    // High fee should give terrible rate
    let high_fee_quote = conditional_amm::quote_swap_asset_to_stable(&high_fee_pool, swap_amount);
    
    // Zero fee output should be much higher
    assert!(zero_fee_quote > high_fee_quote * 10, 0);
    
    // With 99.99% fee, output should be minimal
    assert!(high_fee_quote < swap_amount / 100, 1);
    
    // Clean up
    conditional_amm::destroy_for_testing(zero_fee_pool);
    conditional_amm::destroy_for_testing(high_fee_pool);
    test::end(scenario);
}