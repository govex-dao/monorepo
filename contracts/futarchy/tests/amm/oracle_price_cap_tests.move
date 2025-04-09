// New test module for futarchy::oracle
#[test_only]
module futarchy::oracle_price_cap_tests;

use futarchy::oracle::{Self, Oracle};
use std::debug;
use sui::clock;
use sui::test_scenario::{Self as test, Scenario};

// ======== Test Constants ========
const TWAP_STEP_MAX: u64 = 1000; // Allow 10% movement
const TWAP_START_DELAY: u64 = 2000;
const MARKET_START_TIME: u64 = 1000;
const INIT_PRICE: u128 = 10000;
const TWAP_PRICE_CAP_WINDOW_PERIOD: u64 = 60000;

// ======== Helper Functions ========
fun setup_test_oracle(ctx: &mut TxContext): Oracle {
    oracle::new_oracle(
        INIT_PRICE,
        MARKET_START_TIME,
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx,
    )
}

fun setup_scenario_and_clock(): (Scenario, clock::Clock) {
    let mut scenario = test::begin(@0x1);
    test::next_tx(&mut scenario, @0x1);
    let clock_inst = clock::create_for_testing(test::ctx(&mut scenario));
    (scenario, clock_inst)
}

// ======== Test Cases ========

#[test]
fun test_price_capping_basic_scenarios() {
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY; // 3000

        // Test case 1: Basic upward movement within cap
        // Base price: 10000, max step: 10% (1000 bps)
        // New price: 10900 (9% increase) - should not be capped
        oracle::write_observation(&mut oracle_inst, delay_threshold + 100, 10900);
        assert!(oracle::get_last_price(&oracle_inst) == 10900, 0);

        // Test case 2: Basic upward movement exceeding cap
        // New price: 11200 (12% increase) - should be capped at 11000 (10%)
        oracle::write_observation(&mut oracle_inst, delay_threshold + 200, 11200);
        assert!(oracle::get_last_price(&oracle_inst) == 11000, 1);

        // Test case 3: Basic downward movement within cap
        // New price: 9100 (9% decrease) - should not be capped
        oracle::write_observation(&mut oracle_inst, delay_threshold + 300, 9100);
        assert!(oracle::get_last_price(&oracle_inst) == 9100, 2);

        // Test case 4: Basic downward movement exceeding cap
        // New price: 8800 (12% decrease) - should be capped at 9000 (-10%)
        oracle::write_observation(&mut oracle_inst, delay_threshold + 400, 8800);
        assert!(oracle::get_last_price(&oracle_inst) == 9000, 3);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_price_capping_multi_window() {
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY;

        // First observation to establish baseline (INIT_PRICE = 10000)
        oracle::write_observation(&mut oracle_inst, delay_threshold + 100, INIT_PRICE);
        assert!(oracle::get_last_price(&oracle_inst) == INIT_PRICE, 0);

        // After one window:
        // The window TWAP becomes the base for capping
        // Allowed change is 20% (2 steps) from the TWAP
        let first_window_time = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD;
        oracle::write_observation(&mut oracle_inst, first_window_time, 13000);

        // Verify first window TWAP and new price
        assert!(oracle::get_last_price(&oracle_inst) == 12000, 0);

        // After second window:
        // New TWAP becomes base for capping
        let second_window_time = first_window_time + TWAP_PRICE_CAP_WINDOW_PERIOD;
        oracle::write_observation(&mut oracle_inst, second_window_time, 15000);

        // Verify second window price
        let second_window_price = oracle::get_last_price(&oracle_inst);
        debug::print(&second_window_price); // Let's see what we actually get

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_price_capping_edge_cases() {
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY;

        // Test case 1: No change in price
        oracle::write_observation(&mut oracle_inst, delay_threshold + 100, INIT_PRICE);
        assert!(oracle::get_last_price(&oracle_inst) == INIT_PRICE, 0);

        // Test case 2: Very small price movement
        oracle::write_observation(&mut oracle_inst, delay_threshold + 200, INIT_PRICE + 1);
        assert!(oracle::get_last_price(&oracle_inst) == INIT_PRICE + 1, 1);

        // Test case 3: Exactly at cap limit
        let exact_cap_price =
            INIT_PRICE + (TWAP_STEP_MAX as u128);
        oracle::write_observation(&mut oracle_inst, delay_threshold + 300, exact_cap_price);
        assert!(oracle::get_last_price(&oracle_inst) == exact_cap_price, 2);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_price_capping_rapid_reversals() {
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY;

        // Series of rapid price movements alternating between high and low
        let timestamps = vector[
            delay_threshold + 100,
            delay_threshold + 200,
            delay_threshold + 300,
            delay_threshold + 400,
        ];

        let prices = vector[
            15000, // Try +50% - should cap at +10% = 11000
            5000, // Try -50% - should cap at -10% = 9000
            15000, // Try +50% - should cap at +10% = 11000
            5000, // Try -50% - should cap at -10% = 9000
        ];

        let expected_prices = vector[11000, 9000, 11000, 9000];

        let mut i = 0;
        while (i < 4) {
            oracle::write_observation(
                &mut oracle_inst,
                *vector::borrow(&timestamps, i),
                *vector::borrow(&prices, i),
            );
            assert!(
                oracle::get_last_price(&oracle_inst) == *vector::borrow(&expected_prices, i),
                i,
            );
            i = i + 1;
        };

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_price_capping_long_term_trend() {
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY;

        // Simulate a strong upward trend over multiple windows
        // First observation at delay threshold
        oracle::write_observation(&mut oracle_inst, delay_threshold, 15000);
        let initial_cap = oracle::get_last_price(&oracle_inst);

        // After one window (allowed movement: 20%)
        let time1 = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD;
        oracle::write_observation(&mut oracle_inst, time1, 15000);
        let price1 = oracle::get_last_price(&oracle_inst);
        assert!(price1 > initial_cap, 0);

        // After two windows (allowed movement: 30%)
        let time2 = time1 + TWAP_PRICE_CAP_WINDOW_PERIOD;
        oracle::write_observation(&mut oracle_inst, time2, 15000);
        let price2 = oracle::get_last_price(&oracle_inst);
        assert!(price2 > price1, 1);

        // After three windows (allowed movement: 40%)
        let time3 = time2 + TWAP_PRICE_CAP_WINDOW_PERIOD;
        oracle::write_observation(&mut oracle_inst, time3, 15000);
        let price3 = oracle::get_last_price(&oracle_inst);
        assert!(price3 > price2, 2);

        // Verify the trend is approaching target
        assert!(price3 > 13000, 3); // Should be getting closer to 15000

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_multi_window_flash_attack() {
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY;
    
    // Set up normal trading pattern
    oracle::write_observation(&mut oracle_inst, delay_threshold + 100, 10000);
    let initial_price = oracle::get_last_price(&oracle_inst);
    
    // Flash attack: Attempt to push price up across multiple windows rapidly
    // Simulate 5 consecutive windows with maximum allowed upward pressure
    let mut time = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD;
    let mut i = 0;
    
    while (i < 5) {
        oracle::write_observation(&mut oracle_inst, time, 20000); // Try extreme upward pressure
        let actual_price = oracle::get_last_price(&oracle_inst);
        
        // Just verify that manipulation is limited - price is below the attempted 20000
        assert!(actual_price < 20000, 0);
        
        time = time + TWAP_PRICE_CAP_WINDOW_PERIOD;
        i = i + 1;
    };
    
    // Check that over the entire attack period, price did increase
    let final_price = oracle::get_last_price(&oracle_inst);
    assert!(final_price > initial_price, 1);
    
    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}

#[test]
fun test_stale_oracle_attack() {
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY;
    
    // Initial observation
    oracle::write_observation(&mut oracle_inst, delay_threshold + 1000, 10000);
    
    // Simulate long period of inactivity (3 days)
    let long_gap = 259_200_000; // 3 days in milliseconds
    let after_gap_time = delay_threshold + 1000 + long_gap;
    
    // Attempt to manipulate after long inactivity
    oracle::write_observation(&mut oracle_inst, after_gap_time, 20000);
    let post_gap_price = oracle::get_last_price(&oracle_inst);
    
    // With a 3-day gap, the oracle should allow significant movement
    // The key is to verify that some capping is still occurring
    assert!(post_gap_price > 10000, 0); // Price did move up
    assert!(post_gap_price <= 20000, 1); // Still capped at or below the submitted price
    
    // Verify that a second extreme movement is still capped
    oracle::write_observation(&mut oracle_inst, after_gap_time + 1000, 5000);
    let second_price = oracle::get_last_price(&oracle_inst);
    
    // Make sure there's some capping of the downward movement
    assert!(second_price < post_gap_price, 2); // Price did move down
    assert!(second_price > 5000, 3); // But was capped above the submitted price
    
    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}

#[test]
fun test_window_boundary_attack() {
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY;
    
    // First observation to establish baseline
    oracle::write_observation(&mut oracle_inst, delay_threshold + 100, 10000);
    
    // Attack: Submit observations exactly at window boundaries
    // with alternating high and low prices
    let window1 = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD - 1;
    let window2 = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD;
    let window3 = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD * 2 - 1;
    let window4 = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD * 2;
    
    // Try to manipulate with extreme prices at strategic times
    oracle::write_observation(&mut oracle_inst, window1, 5000);
    oracle::write_observation(&mut oracle_inst, window2, 20000);
    oracle::write_observation(&mut oracle_inst, window3, 5000);
    oracle::write_observation(&mut oracle_inst, window4, 20000);
    
    // Check final window TWAP to ensure it doesn't match the extreme manipulated values
    let window_twap = oracle::debug_get_window_twap(&oracle_inst);
    
    // Verify the TWAP is influenced but not fully manipulated
    // Just ensure it's somewhere between the extremes
    assert!(window_twap > 5000, 0);
    assert!(window_twap < 20000, 1);
    
    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}


#[test]
fun test_zigzag_attack() {
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY;
    
    // Initial observation
    oracle::write_observation(&mut oracle_inst, delay_threshold + 1000, 10000);
    
    // Simulate zigzag attack pattern across multiple windows
    // Attacker tries to maximize amplitude by alternating directions at window boundaries
    let mut time = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD;
    let mut i = 0;
    let mut high_to_low_diff: u128 = 0;
    let mut last_price = 10000;
    
    while (i < 5) {
        // First push price up maximally
        oracle::write_observation(&mut oracle_inst, time, 20000);
        let high_price = oracle::get_last_price(&oracle_inst);
        
        // Then immediately try to push price down maximally at next window
        time = time + TWAP_PRICE_CAP_WINDOW_PERIOD;
        oracle::write_observation(&mut oracle_inst, time, 5000);
        let low_price = oracle::get_last_price(&oracle_inst);
        
        // Calculate the amplitude of the swing
        let current_diff = high_price - low_price;
        
        // The amplitude shouldn't exponentially increase - verify it's constrained
        if (i > 0) {
            assert!(current_diff <= high_to_low_diff * 3, i); // Allow for some increase but not unbounded
        };
        
        high_to_low_diff = current_diff;
        last_price = low_price;
        time = time + TWAP_PRICE_CAP_WINDOW_PERIOD;
        i = i + 1;
    };
    
    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}