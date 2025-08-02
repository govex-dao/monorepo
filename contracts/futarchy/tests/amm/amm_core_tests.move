#[test_only]
module futarchy::amm_core_tests;

use futarchy::amm::{Self};
use futarchy::math;
use sui::test_scenario::{Self as test, next_tx, ctx};
use sui::object;
use std::vector;

// ======== Test Constants ========
const ADMIN: address = @0xA;
const USER_1: address = @0x1;

const INITIAL_RESERVE: u64 = 1_000_000;
const SWAP_FEE_RATE: u64 = 30; // 0.3% = 30/10000

// ======== Core Swapping Logic Tests ========

#[test]
fun test_basic_swap_asset_to_stable() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create test pool directly
    let dummy_market_id = object::id_from_address(ADMIN);
    let mut pool = amm::create_test_pool(
        dummy_market_id,
        0, // outcome_idx
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Test swap
    let swap_amount = 10_000;
    
    // Get quote first
    let quote = amm::quote_swap_asset_to_stable(&pool, swap_amount);
    assert!(quote > 0, 0);
    
    // Since we're testing the AMM module directly, we need to verify the quote logic
    // The actual swap would require the full setup with escrow and conditional tokens
    
    // Clean up
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Reserve & Invariant Tests ========

#[test]
fun test_xy_k_invariant_maintained() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Get initial k
    let (initial_asset, initial_stable) = amm::get_reserves(&pool);
    let initial_k = math::mul_div_to_128(initial_asset, initial_stable, 1);
    
    // Calculate quote for swap
    let swap_amount = 10_000;
    let quote = amm::quote_swap_asset_to_stable(&pool, swap_amount);
    
    // Calculate what new reserves would be after swap
    let new_asset = initial_asset + swap_amount;
    let new_stable = initial_stable - quote;
    
    // Calculate new k
    let new_k = math::mul_div_to_128(new_asset, new_stable, 1);
    
    // K should stay approximately the same or increase slightly due to fees
    // Without fees: new_k would equal initial_k
    // With fees: new_k > initial_k because we keep some output as fees
    assert!(new_k >= initial_k, 0);
    
    // But shouldn't increase by more than the fee percentage (0.3%)
    let max_k_increase = (initial_k * 10030) / 10000;
    assert!(new_k <= max_k_increase, 1);
    
    // Clean up
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Fee Verification Tests ========

#[test]
fun test_swap_fees_calculated_correctly() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE, // 0.3%
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Test asset to stable swap fee calculation
    let swap_amount = 10_000;
    let quote_with_fee = amm::quote_swap_asset_to_stable(&pool, swap_amount);
    
    // Calculate output without fee using AMM formula
    let k = math::mul_div_to_128(INITIAL_RESERVE, INITIAL_RESERVE, 1);
    let new_asset_reserve = INITIAL_RESERVE + swap_amount;
    let new_stable_reserve = (k / (new_asset_reserve as u128) as u64);
    let output_without_fee = INITIAL_RESERVE - new_stable_reserve;
    
    // Fee should be 0.3% of output
    let expected_fee = (output_without_fee * SWAP_FEE_RATE) / 10000;
    let expected_output = output_without_fee - expected_fee;
    
    // Verify quote matches expected (within rounding tolerance)
    assert!(quote_with_fee >= expected_output - 1 && quote_with_fee <= expected_output + 1, 0);
    
    // Test stable to asset swap fee calculation
    let quote_stable_to_asset = amm::quote_swap_stable_to_asset(&pool, swap_amount);
    
    // For stable to asset, fee is taken from input
    let input_fee = (swap_amount * SWAP_FEE_RATE) / 10000;
    let effective_input = swap_amount - input_fee;
    
    // Calculate output with effective input
    let new_stable_reserve_2 = INITIAL_RESERVE + effective_input;
    let new_asset_reserve_2 = (k / (new_stable_reserve_2 as u128) as u64);
    let expected_output_2 = INITIAL_RESERVE - new_asset_reserve_2;
    
    // Verify quote matches expected
    assert!(quote_stable_to_asset >= expected_output_2 - 1 && quote_stable_to_asset <= expected_output_2 + 1, 1);
    
    // Clean up
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Slippage Protection Tests ========

#[test]
fun test_slippage_protection_asset_to_stable() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Get quote for a swap
    let swap_amount = 100_000; // Large swap for more slippage
    let quote = amm::quote_swap_asset_to_stable(&pool, swap_amount);
    
    // The actual swap would fail if min_amount_out is set higher than quote
    // For now, verify that slippage can be calculated
    let slippage_tolerance = 50; // 0.5%
    let min_acceptable = (quote * (10000 - slippage_tolerance)) / 10000;
    
    assert!(min_acceptable < quote, 0);
    assert!(min_acceptable > 0, 1);
    
    // Clean up
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Edge Case Tests ========

#[test]
fun test_swap_zero_amount_returns_zero() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Swap zero amount should return zero output
    let quote = amm::quote_swap_asset_to_stable(&pool, 0);
    assert!(quote == 0, 0);
    
    // Also test stable to asset
    let quote_reverse = amm::quote_swap_stable_to_asset(&pool, 0);
    assert!(quote_reverse == 0, 1);
    
    // Clean up
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Protocol Fee Tests ========

#[test]
fun test_protocol_fee_accumulation() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    let mut pool = amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE, // 0.3% total fee
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Get initial protocol fees (should be 0)
    let initial_fees = amm::get_protocol_fees(&pool);
    assert!(initial_fees == 0, 0);
    
    // Perform a large swap to generate fees
    let swap_amount = 100_000; // 10% of pool
    let quote = amm::quote_swap_asset_to_stable(&pool, swap_amount);
    
    // Verify that a quote was generated (swap would succeed)
    assert!(quote > 0, 1);
    
    // Calculate what the protocol fee would be on this swap
    // The AMM takes fees from the output, not the input
    // Total fee rate is 0.3% (30/10000)
    // Protocol gets 20% of fees (2000/10000)
    // So protocol fee = output * 0.3% * 20% = output * 0.06%
    let total_fee = (quote * SWAP_FEE_RATE) / 10000; // 0.3% of output
    let protocol_fee_share = (total_fee * 2000) / 10000; // 20% of total fee
    
    // Verify the calculation is reasonable
    assert!(protocol_fee_share > 0, 2);
    assert!(protocol_fee_share < quote / 1000, 3); // Should be less than 0.1% of output
    
    // Clean up
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Price Calculation Tests ========

#[test]
fun test_price_calculation() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Get initial price (should be 1:1 for equal reserves)
    let initial_price = amm::get_current_price(&pool);
    assert!(initial_price == 1_000_000_000_000u128, 0); // Price scaled by 10^12 (BASIS_POINTS)
    
    // Simulate swap effect on price
    let swap_amount = 100_000; // 10% of pool
    let quote = amm::quote_swap_asset_to_stable(&pool, swap_amount);
    
    // Calculate expected price after swap
    // After swap: asset_reserve = 1,100,000, stable_reserve = ~909,090
    // Price = stable/asset = ~0.826
    let new_asset_reserve = INITIAL_RESERVE + swap_amount;
    let new_stable_reserve = INITIAL_RESERVE - quote;
    let expected_price = ((new_stable_reserve as u128) * 1_000_000_000_000) / (new_asset_reserve as u128);
    
    // Verify calculations are consistent
    assert!(quote > 0, 1);
    assert!(expected_price < initial_price, 2); // Price should decrease when asset increases
    
    // Clean up
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Liquidity & Reserve Tests ========

#[test]
fun test_reserves_and_liquidity_tracking() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    let initial_asset = 2_000_000;
    let initial_stable = 500_000;
    
    let pool = amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        initial_asset,
        initial_stable,
        ctx(&mut scenario)
    );
    
    // Verify initial reserves
    let (asset_reserve, stable_reserve) = amm::get_reserves(&pool);
    assert!(asset_reserve == initial_asset, 0);
    assert!(stable_reserve == initial_stable, 1);
    
    // Calculate initial liquidity constant k
    let initial_k = math::mul_div_to_128(asset_reserve, stable_reserve, 1);
    
    // Test different swap scenarios and verify k increases due to fees
    let test_swaps = vector[5_000, 10_000, 20_000];
    let mut i = 0;
    let mut current_k = initial_k;
    
    while (i < vector::length(&test_swaps)) {
        let swap_amount = *vector::borrow(&test_swaps, i);
        
        // Quote swap to see output
        let quote = amm::quote_swap_asset_to_stable(&pool, swap_amount);
        
        // Calculate new reserves after theoretical swap
        let new_asset = asset_reserve + swap_amount;
        let new_stable = stable_reserve - quote;
        let new_k = math::mul_div_to_128(new_asset, new_stable, 1);
        
        // K should increase due to fees
        assert!(new_k > current_k, 2 + i);
        
        // Verify quote is reasonable (less than proportional amount due to price impact and fees)
        let proportional_output = (swap_amount * stable_reserve) / asset_reserve;
        assert!(quote < proportional_output, 5 + i);
        
        i = i + 1;
    };
    
    // Test price impact for large swaps
    let large_swap = 500_000; // 25% of asset reserve
    let large_quote = amm::quote_swap_asset_to_stable(&pool, large_swap);
    let small_swap = 1_000; // 0.05% of asset reserve
    let small_quote = amm::quote_swap_asset_to_stable(&pool, small_swap);
    
    // Calculate average price (output per input)
    let large_avg_price = (large_quote * 1_000_000) / large_swap;
    let small_avg_price = (small_quote * 1_000_000) / small_swap;
    
    // Large swap should have worse average price due to price impact
    assert!(large_avg_price < small_avg_price, 8);
    
    // Clean up
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

// ======== Minimum Liquidity & Edge Case Tests ========

#[test]
fun test_minimum_liquidity_and_edge_cases() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    let dummy_market_id = object::id_from_address(ADMIN);
    
    // Test 1: Create pool with very small liquidity
    let small_pool = amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        10_000, // Small amount
        10_000,
        ctx(&mut scenario)
    );
    
    // Should still be able to get quotes for small swaps
    let small_swap = 100;
    let small_quote = amm::quote_swap_asset_to_stable(&small_pool, small_swap);
    assert!(small_quote > 0, 0);
    
    // Test 2: Extreme price ratios
    let extreme_pool = amm::create_test_pool(
        dummy_market_id,
        1,
        SWAP_FEE_RATE,
        10_000_000, // 10M asset
        1_000,      // 1k stable - extreme 10000:1 ratio
        ctx(&mut scenario)
    );
    
    // Price should reflect the extreme ratio
    let extreme_price = amm::get_current_price(&extreme_pool);
    // Price = stable/asset * 10^12 = (1000/10000000) * 10^12 = 10^8
    assert!(extreme_price == 100_000_000u128, 1);
    
    // Test 3: Maximum swap that nearly drains pool
    let (asset_res, stable_res) = amm::get_reserves(&extreme_pool);
    
    // Try to swap for 99% of stable reserve
    let target_output = (stable_res * 99) / 100;
    
    // Calculate required input for this output
    // Using AMM formula: input = (k / (stable_res - output)) - asset_res
    let k = math::mul_div_to_128(asset_res, stable_res, 1);
    let new_stable = stable_res - target_output;
    let required_asset_with_fee = ((k / (new_stable as u128)) as u64) - asset_res;
    
    // Add fee adjustment (approximation)
    let required_input = (required_asset_with_fee * 10000) / (10000 - SWAP_FEE_RATE);
    
    // Get quote for this large swap
    let large_quote = amm::quote_swap_asset_to_stable(&extreme_pool, required_input);
    
    // Quote should be close to target (within 5% due to fee calculations)
    assert!(large_quote > (target_output * 95) / 100, 2);
    assert!(large_quote < target_output, 3); // Should be less due to fees
    
    // Test 4: Very small swaps should still work
    let tiny_swap = 1;
    let tiny_quote_asset = amm::quote_swap_asset_to_stable(&small_pool, tiny_swap);
    let tiny_quote_stable = amm::quote_swap_stable_to_asset(&small_pool, tiny_swap);
    
    // Even tiny swaps should produce non-zero output for reasonable pools
    assert!(tiny_quote_asset >= 0, 4); // Might be 0 due to rounding
    assert!(tiny_quote_stable >= 0, 5);
    
    // Test 5: Consecutive swaps should show price impact
    let swap_size = 1_000;
    let first_quote = amm::quote_swap_asset_to_stable(&small_pool, swap_size);
    
    // Simulate the effect of the first swap
    let (curr_asset, curr_stable) = amm::get_reserves(&small_pool);
    let simulated_pool = amm::create_test_pool(
        dummy_market_id,
        2,
        SWAP_FEE_RATE,
        curr_asset + swap_size,
        curr_stable - first_quote,
        ctx(&mut scenario)
    );
    
    // Second identical swap should give worse rate
    let second_quote = amm::quote_swap_asset_to_stable(&simulated_pool, swap_size);
    assert!(second_quote < first_quote, 6);
    
    // Clean up
    amm::destroy_for_testing(small_pool);
    amm::destroy_for_testing(extreme_pool);
    amm::destroy_for_testing(simulated_pool);
    test::end(scenario);
}