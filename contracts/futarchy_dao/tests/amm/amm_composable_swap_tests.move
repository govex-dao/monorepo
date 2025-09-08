#[test_only]
module futarchy::amm_composable_swap_tests;

use futarchy::conditional_amm::{Self};
use futarchy::math;
use sui::test_scenario::{Self as test, next_tx, ctx};
use sui::object;
use sui::coin::{Self, Coin};

// ======== Test Constants ========
const ADMIN: address = @0xA;
const USER_1: address = @0x1;
const USER_2: address = @0x2;

const INITIAL_RESERVE: u64 = 1_000_000;
const SWAP_FEE_RATE: u64 = 30; // 0.3% = 30/10000

// Test coin types
public struct ASSET has drop {}
public struct STABLE has drop {}

// ======== Create and Swap Tests ========

#[test]
fun test_create_and_swap_basic_flow() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create pool to test against
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Test the flow that would happen in create_and_swap:
    // 1. User provides spot tokens
    // 2. Mint conditional tokens (would happen in escrow)
    // 3. Perform swap
    // 4. Return remaining tokens
    
    let spot_amount = 10_000;
    
    // Simulate minting complete set (1:1 for each outcome)
    // In real flow, this would create conditional tokens for all outcomes
    let tokens_per_outcome = spot_amount;
    
    // Calculate swap on one outcome
    let swap_quote = conditional_amm::quote_swap_asset_to_stable(&pool, tokens_per_outcome);
    
    // Verify quote is reasonable
    assert!(swap_quote > 0, 0);
    assert!(swap_quote < tokens_per_outcome, 1); // Should get less due to fees
    
    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_create_and_swap_with_slippage() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Large swap to test slippage
    let large_swap = INITIAL_RESERVE / 10; // 10% of reserves
    let quote = conditional_amm::quote_swap_asset_to_stable(&pool, large_swap);
    
    // Calculate slippage
    // Without slippage, we'd expect to get exactly large_swap out
    // With AMM curve, we get less
    let ideal_output = large_swap - (large_swap * SWAP_FEE_RATE / 10000);
    let actual_slippage = ((ideal_output - quote) * 10000) / ideal_output;
    
    // Verify significant slippage for large trade
    assert!(actual_slippage > 100, 0); // More than 1% slippage
    
    // Set minimum output with tolerance
    let min_output = (quote * 95) / 100; // Accept up to 5% slippage
    assert!(quote >= min_output, 1);
    
    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_create_and_swap_both_directions() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create two pools for different outcomes
    let dummy_market_id = object::id_from_address(ADMIN);
    
    // Pool for outcome 0
    let pool0 = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Pool for outcome 1 with different reserves
    let pool1 = conditional_amm::create_test_pool(
        dummy_market_id,
        1,
        SWAP_FEE_RATE,
        INITIAL_RESERVE * 2, // Different price
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    let swap_amount = 10_000;
    
    // Test asset to stable on outcome 0
    let quote0_a2s = conditional_amm::quote_swap_asset_to_stable(&pool0, swap_amount);
    
    // Test stable to asset on outcome 0
    let quote0_s2a = conditional_amm::quote_swap_stable_to_asset(&pool0, swap_amount);
    
    // Test asset to stable on outcome 1
    let quote1_a2s = conditional_amm::quote_swap_asset_to_stable(&pool1, swap_amount);
    
    // Test stable to asset on outcome 1
    let quote1_s2a = conditional_amm::quote_swap_stable_to_asset(&pool1, swap_amount);
    
    // Verify different pools give different quotes
    assert!(quote0_a2s != quote1_a2s, 0);
    assert!(quote0_s2a != quote1_s2a, 1);
    
    // Pool1 has 2:1 ratio, so asset is cheaper
    assert!(quote1_a2s < quote0_a2s, 2); // Get less stable for asset
    assert!(quote1_s2a > quote0_s2a, 3); // Get more asset for stable
    
    // Clean up
    conditional_amm::destroy_for_testing(pool0);
    conditional_amm::destroy_for_testing(pool1);
    test::end(scenario);
}

#[test]
fun test_create_and_swap_with_existing_tokens() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Simulate scenario where user already has some conditional tokens
    // and wants to add more spot tokens to swap
    let existing_tokens = 5_000;
    let new_spot_tokens = 10_000;
    let total_to_swap = existing_tokens + new_spot_tokens;
    
    // Get quote for total amount
    let quote = conditional_amm::quote_swap_asset_to_stable(&pool, total_to_swap);
    
    // Verify we can handle combined amounts
    assert!(quote > 0, 0);
    
    // The quote should be less than if we swapped separately due to slippage
    let quote1 = conditional_amm::quote_swap_asset_to_stable(&pool, existing_tokens);
    let quote2 = conditional_amm::quote_swap_asset_to_stable(&pool, new_spot_tokens);
    assert!(quote < quote1 + quote2, 1); // Combined swap has more slippage
    
    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_optimal_swap_routing() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create multiple pools with different liquidity
    let dummy_market_id = object::id_from_address(ADMIN);
    
    // Highly liquid pool
    let liquid_pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE * 10,
        INITIAL_RESERVE * 10,
        ctx(&mut scenario)
    );
    
    // Less liquid pool
    let illiquid_pool = conditional_amm::create_test_pool(
        dummy_market_id,
        1,
        SWAP_FEE_RATE,
        INITIAL_RESERVE / 10,
        INITIAL_RESERVE / 10,
        ctx(&mut scenario)
    );
    
    // Test same swap amount on both
    let swap_amount = 50_000;
    
    let quote_liquid = conditional_amm::quote_swap_asset_to_stable(&liquid_pool, swap_amount);
    let quote_illiquid = conditional_amm::quote_swap_asset_to_stable(&illiquid_pool, swap_amount);
    
    // Liquid pool should give better price (less slippage)
    assert!(quote_liquid > quote_illiquid, 0);
    
    // Calculate price impact
    let impact_liquid = ((swap_amount - quote_liquid) * 10000) / swap_amount;
    let impact_illiquid = ((swap_amount - quote_illiquid) * 10000) / swap_amount;
    
    // Illiquid pool should have much higher impact
    assert!(impact_illiquid > impact_liquid * 5, 1); // At least 5x worse
    
    // Clean up
    conditional_amm::destroy_for_testing(liquid_pool);
    conditional_amm::destroy_for_testing(illiquid_pool);
    test::end(scenario);
}

#[test]
fun test_token_merging_scenarios() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Simulate having multiple small token amounts that need merging
    let amounts = vector[1_000, 2_000, 3_000, 4_000];
    let total = 10_000;
    
    // Quote for merged amount
    let quote_merged = conditional_amm::quote_swap_asset_to_stable(&pool, total);
    
    // Quote for individual swaps
    let mut total_individual = 0;
    let mut i = 0;
    while (i < vector::length(&amounts)) {
        let amount = *vector::borrow(&amounts, i);
        let quote = conditional_amm::quote_swap_asset_to_stable(&pool, amount);
        total_individual = total_individual + quote;
        i = i + 1;
    };
    
    // Merging before swap should give approximately the same or slightly worse result
    // due to higher price impact on a single larger trade
    // The difference should be small for these amounts
    assert!(quote_merged <= total_individual, 0);
    
    // But the difference should be minimal (less than 1%)
    let diff = if (total_individual > quote_merged) {
        total_individual - quote_merged
    } else {
        quote_merged - total_individual
    };
    assert!(diff < total_individual / 100, 1);
    
    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_edge_case_tiny_spot_amount() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Test with tiny amount
    let tiny_amount = 1;
    let quote = conditional_amm::quote_swap_asset_to_stable(&pool, tiny_amount);
    
    // Might round to 0 due to fees
    assert!(quote <= 1, 0);
    
    // Test with amount just above fee threshold
    let small_amount = 100;
    let quote2 = conditional_amm::quote_swap_asset_to_stable(&pool, small_amount);
    
    // Should get something back
    assert!(quote2 > 0, 1);
    assert!(quote2 < small_amount, 2); // But less than input due to fees
    
    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_maximum_efficient_swap_size() {
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, USER_1);
    
    // Create pool
    let dummy_market_id = object::id_from_address(ADMIN);
    let pool = conditional_amm::create_test_pool(
        dummy_market_id,
        0,
        SWAP_FEE_RATE,
        INITIAL_RESERVE,
        INITIAL_RESERVE,
        ctx(&mut scenario)
    );
    
    // Test increasingly large swaps to find efficiency limits
    let test_amounts = vector[
        INITIAL_RESERVE / 100,    // 1% of reserves
        INITIAL_RESERVE / 20,     // 5%
        INITIAL_RESERVE / 10,     // 10%
        INITIAL_RESERVE / 5,      // 20%
        INITIAL_RESERVE / 2,      // 50%
    ];
    
    let mut previous_efficiency = 10000; // Start at 100%
    let mut i = 0;
    
    while (i < vector::length(&test_amounts)) {
        let amount = *vector::borrow(&test_amounts, i);
        let quote = conditional_amm::quote_swap_asset_to_stable(&pool, amount);
        
        // Calculate efficiency (output/input ratio)
        let efficiency = (quote * 10000) / amount;
        
        // Efficiency should decrease with larger swaps
        assert!(efficiency < previous_efficiency, i);
        previous_efficiency = efficiency;
        
        i = i + 1;
    };
    
    // Clean up
    conditional_amm::destroy_for_testing(pool);
    test::end(scenario);
}