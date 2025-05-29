// New test module for futarchy::oracle
#[test_only]
module futarchy::oracle_burst_tests;

use futarchy::oracle::{Self, Oracle};
use std::debug;
use std::u128;
use sui::clock;
use sui::test_scenario::{Self as test, Scenario};

// ======== Test Constants ========
const TWAP_STEP_MAX: u64 = 1000; // Allow 10% movement
const TWAP_START_DELAY: u64 = 120_000;
const MARKET_START_TIME: u64 = 1000;
const INIT_PRICE: u128 = 10000;
const TWAP_PRICE_CAP_WINDOW_PERIOD: u64 = 60000;

// For testing extreme values, define a maximum u64 constant.
const U64_MAX: u64 = 18446744073709551615;

// ======== Helper Functions ========
fun setup_test_oracle(ctx: &mut TxContext): Oracle {
    let mut oracle_inst = oracle::new_oracle(
        INIT_PRICE,
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx,
    );
    oracle::set_oracle_start_time(&mut oracle_inst, MARKET_START_TIME);
    oracle_inst
}

fun setup_scenario_and_clock(): (Scenario, clock::Clock) {
    let mut scenario = test::begin(@0x1);
    test::next_tx(&mut scenario, @0x1);
    let clock_inst = clock::create_for_testing(test::ctx(&mut scenario));
    (scenario, clock_inst)
}

// ======== Test Cases ========

#[test]
fun test_twap_with_fifty_random_swaps() {
    // Set up oracle and clock
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    
    // Define test constants
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY; // 3000
    
    // Initialize manual TWAP calculation variables
    let mut total_weighted_price: u256 = 0;
    let mut last_observation_time = delay_threshold;
    let mut current_price: u128 = INIT_PRICE;
    
    // Create deterministic pseudorandom price movements
    let a: u64 = 1664525;
    let c: u64 = 1013904223;
    let m: u64 = 4294967296; // 2^32
    let mut seed: u64 = 12345; // Arbitrary starting seed
    
    // Process 50 price observations
    let mut i = 0;
    while (i < 50) {
        // Generate "random" time interval variation (80 to 120 seconds)
        seed = (a * seed + c) % m;
        let time_variation = (seed % 41) + 80; // Range: 80 to 120
        
        // Generate "random" price movement direction and magnitude
        seed = (a * seed + c) % m;
        let is_positive = seed % 2 == 0; // 50% chance of positive/negative
        
        seed = (a * seed + c) % m;
        let price_change_magnitude = ((seed % 701) as u128); // Range: 0 to 700 basis points
        
        // Calculate new observation time
        let observation_time = last_observation_time + time_variation * 1000; // Convert to milliseconds
        
        // Calculate new price with "random" movement and bounds
        let price_change = (current_price * price_change_magnitude) / 10000;
        let mut new_price;
        
        if (is_positive) {
            new_price = current_price + price_change;
        } else {
            // Handle price decrease
            if (price_change >= current_price) {
                // Prevent underflow
                new_price = 5000; // Set to minimum price
            } else {
                new_price = current_price - price_change;
            }
        };
        
        // Ensure price remains within reasonable bounds
        if (new_price < 5000) { new_price = 5000 };
        if (new_price > 20000) { new_price = 20000 };
        
        // Write observation to oracle
        oracle::write_observation(&mut oracle_inst, observation_time, new_price);
        
        // Get the capped price
        let capped_price = oracle::get_last_price(&oracle_inst);
        
        // Calculate time-weighted contribution
        let time_diff = observation_time - last_observation_time;
        let contribution = (capped_price as u256) * (time_diff as u256);
        total_weighted_price = total_weighted_price + contribution;
        
        // Update tracking variables for next iteration
        last_observation_time = observation_time;
        current_price = new_price; // Track uncapped price for next iteration's base
        
        i = i + 1;
    };
    
    // Set clock to final observation time for TWAP calculation
    clock::set_for_testing(&mut clock_inst, last_observation_time);
    
    // Calculate expected TWAP
    let total_period = last_observation_time - delay_threshold;
    let expected_twap = total_weighted_price / (total_period as u256);
    
    // Get actual TWAP from oracle
    let actual_twap = oracle::get_twap(&oracle_inst, &clock_inst);
    
    // Assert that calculated TWAP matches oracle's TWAP exactly
    assert!(actual_twap == (expected_twap as u128), 0);
    
    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}

#[test]
fun test_twap_with_random_swaps() {
    // Set up oracle and clock
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    
    // Define test constants
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY; // 3000
    
    // Initialize manual TWAP calculation variables
    let mut total_weighted_price: u256 = 0;
    let mut last_observation_time = delay_threshold;
    let mut current_price: u128 = INIT_PRICE;
    
    // Create deterministic pseudorandom price movements
    let a: u64 = 1664525;
    let c: u64 = 1013904223;
    let m: u64 = 4294967296; // 2^32
    let mut seed: u64 = 12345; // Arbitrary starting seed
    
    // Process 50 price observations
    let mut i = 0;
    while (i < 50) {
        // Generate "random" time interval variation (80 to 120 seconds)
        seed = (a * seed + c) % m;
        let time_variation = (seed % 41) + 80; // Range: 80 to 120
        
        // Generate "random" price movement direction and magnitude
        seed = (a * seed + c) % m;
        let is_positive = seed % 2 == 0; // 50% chance of positive/negative
        
        seed = (a * seed + c) % m;
        let price_change_magnitude = ((seed % 701) as u128); // Range: 0 to 700 basis points
        
        // Calculate new observation time
        let observation_time = last_observation_time + time_variation * 1000; // Convert to milliseconds
        
        // Calculate new price with "random" movement and bounds
        let price_change = (current_price * price_change_magnitude) / 10000;
        let mut new_price;
        
        if (is_positive) {
            new_price = current_price + price_change;
        } else {
            // Handle price decrease
            if (price_change >= current_price) {
                // Prevent underflow
                new_price = 5000; // Set to minimum price
            } else {
                new_price = current_price - price_change;
            }
        };
        
        // Ensure price remains within reasonable bounds
        if (new_price < 5000) { new_price = 5000 };
        if (new_price > 20000) { new_price = 20000 };
        
        // Write observation to oracle
        oracle::write_observation(&mut oracle_inst, observation_time, new_price);
        
        // Get the capped price
        let capped_price = oracle::get_last_price(&oracle_inst);
        
        // Calculate time-weighted contribution
        let time_diff = observation_time - last_observation_time;
        let contribution = (capped_price as u256) * (time_diff as u256);
        total_weighted_price = total_weighted_price + contribution;
        
        // Update tracking variables for next iteration
        last_observation_time = observation_time;
        current_price = new_price; // Track uncapped price for next iteration's base
        
        i = i + 1;
    };
    
    // Set clock to final observation time for TWAP calculation
    clock::set_for_testing(&mut clock_inst, last_observation_time);
    
    // Calculate expected TWAP
    let total_period = last_observation_time - delay_threshold;
    let expected_twap = total_weighted_price / (total_period as u256);
    
    // Get actual TWAP from oracle
    let actual_twap = oracle::get_twap(&oracle_inst, &clock_inst);
    
    // Assert that calculated TWAP matches oracle's TWAP exactly
    assert!(actual_twap == (expected_twap as u128), 0);
    
    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}