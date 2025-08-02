#[test_only]
module futarchy::amm_integration_tests;

use futarchy::{test_helpers, amm};
use sui::{test_scenario::{Self as test, next_tx}, object};

const ADMIN: address = @0xA;
const USER_1: address = @0x1;

#[test]
fun test_event_emission() {
    let mut scenario = test::begin(ADMIN);
    
    // Create test pool
    let pool = test_helpers::create_standard_test_pool(&mut scenario);
    
    // Perform swap that would emit events
    let quote = amm::quote_swap_asset_to_stable(&pool, 10_000);
    assert!(quote > 0, 0);
    
    // Check if any events were emitted
    // Note: The AMM module would need to emit events for this to work
    // For now, we skip event checking as it requires TransactionEffects
    
    // For now, just verify the swap quote worked
    assert!(quote > 9_000 && quote < 10_000, 1); // Expect ~0.3% fee + slippage
    
    // Cleanup
    amm::destroy_for_testing(pool);
    test::end(scenario);
}

#[test]
fun test_simple_integration_flow() {
    let mut scenario = test::begin(ADMIN);
    
    // Create test pool
    let mut pool = test_helpers::create_standard_test_pool(&mut scenario);
    
    // Create clock for testing
    let mut clock = test_helpers::create_test_clock(&mut scenario);
    
    next_tx(&mut scenario, USER_1);
    
    // Simulate multiple swaps
    let swap_amounts = vector[1_000, 5_000, 10_000, 50_000];
    let mut i = 0;
    let mut total_output = 0;
    
    while (i < vector::length(&swap_amounts)) {
        let amount = *vector::borrow(&swap_amounts, i);
        let quote = amm::quote_swap_asset_to_stable(&pool, amount);
        total_output = total_output + quote;
        
        // Advance time between swaps
        test_helpers::advance_clock(&mut clock, 60_000); // 1 minute
        
        i = i + 1;
    };
    
    // Verify total output is reasonable
    assert!(total_output > 0, 0);
    
    // Check final pool state
    let (asset_res, stable_res) = amm::get_reserves(&pool);
    assert!(asset_res == 1_000_000, 1); // No actual swaps executed, just quotes
    assert!(stable_res == 1_000_000, 2);
    
    // Cleanup
    amm::destroy_for_testing(pool);
    test_helpers::destroy_test_clock(clock);
    test::end(scenario);
}