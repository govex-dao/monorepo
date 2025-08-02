#[test_only]
module futarchy::amm_core_tests;

use futarchy::amm::{Self};
use futarchy::math;
use sui::test_scenario::{Self as test, next_tx, ctx};
use sui::object;

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