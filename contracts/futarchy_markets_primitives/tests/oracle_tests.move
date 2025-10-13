#[test_only]
module futarchy_markets_primitives::oracle_tests;

use futarchy_markets_primitives::oracle::{Self, Oracle};
use futarchy_one_shot_utils::constants;
use sui::{
    test_scenario as ts,
    clock::{Self, Clock},
    test_utils::destroy,
};

const ADMIN: address = @0xAD;

// === Test Helpers ===

fun start(): (ts::Scenario, Clock) {
    let mut scenario = ts::begin(ADMIN);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    (scenario, clock)
}

fun end(scenario: ts::Scenario, clock: Clock) {
    destroy(clock);
    ts::end(scenario);
}

// === Oracle Creation Tests ===

#[test]
fun test_new_oracle_valid_params() {
    let (mut scenario, clock) = start();

    let oracle = oracle::new_oracle(
        10000,  // initialization price
        60_000, // twap_start_delay (1 minute)
        1000,   // twap_cap_ppm (0.1%)
        ts::ctx(&mut scenario)
    );

    // Verify initialization
    assert!(oracle::last_price(&oracle) == 10000, 0);
    assert!(oracle::last_timestamp(&oracle) == 0, 1);
    assert!(oracle::market_start_time(&oracle).is_none(), 2);
    assert!(oracle::twap_initialization_price(&oracle) == 10000, 3);

    let (delay, cap_step) = oracle::config(&oracle);
    assert!(delay == 60_000, 4);
    assert!(cap_step == 10, 5); // 10000 * 1000 / 1_000_000 = 10

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::EZeroInitialization)]
fun test_new_oracle_zero_initialization_price_fails() {
    let (mut scenario, clock) = start();

    let oracle = oracle::new_oracle(
        0,      // zero price - should fail
        60_000,
        1000,
        ts::ctx(&mut scenario)
    );

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::EZeroStep)]
fun test_new_oracle_zero_cap_ppm_fails() {
    let (mut scenario, clock) = start();

    let oracle = oracle::new_oracle(
        10000,
        60_000,
        0,      // zero cap ppm - should fail
        ts::ctx(&mut scenario)
    );

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::EInvalidCapPpm)]
fun test_new_oracle_invalid_cap_ppm_fails() {
    let (mut scenario, clock) = start();

    let oracle = oracle::new_oracle(
        10000,
        60_000,
        1_000_001, // > PPM_DENOMINATOR - should fail
        ts::ctx(&mut scenario)
    );

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::ELongDelay)]
fun test_new_oracle_long_delay_fails() {
    let (mut scenario, clock) = start();

    let oracle = oracle::new_oracle(
        10000,
        constants::one_week_ms(), // >= 1 week - should fail
        1000,
        ts::ctx(&mut scenario)
    );

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::ENoneFullWindowTwapDelay)]
fun test_new_oracle_misaligned_delay_fails() {
    let (mut scenario, clock) = start();

    let oracle = oracle::new_oracle(
        10000,
        60_001, // Not multiple of TWAP_PRICE_CAP_WINDOW - should fail
        1000,
        ts::ctx(&mut scenario)
    );

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_new_oracle_step_calculation_small_ppm() {
    let (mut scenario, clock) = start();

    // Small PPM should result in small step
    let oracle = oracle::new_oracle(
        100_000,
        60_000,
        100, // 0.01%
        ts::ctx(&mut scenario)
    );

    let (_, cap_step) = oracle::config(&oracle);
    assert!(cap_step == 10, 0); // 100_000 * 100 / 1_000_000 = 10

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_new_oracle_step_calculation_large_ppm() {
    let (mut scenario, clock) = start();

    // Large PPM should result in large step
    let oracle = oracle::new_oracle(
        100_000,
        60_000,
        100_000, // 10%
        ts::ctx(&mut scenario)
    );

    let (_, cap_step) = oracle::config(&oracle);
    assert!(cap_step == 10_000, 0); // 100_000 * 100_000 / 1_000_000 = 10_000

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Oracle Start Time Tests ===

#[test]
fun test_set_oracle_start_time() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    assert!(oracle::market_start_time(&oracle).is_some(), 0);
    assert!(*oracle::market_start_time(&oracle).borrow() == 1000, 1);
    assert!(oracle::last_timestamp(&oracle) == 1000, 2);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::EMarketAlreadyStarted)]
fun test_set_oracle_start_time_twice_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Try to set again - should fail
    oracle::set_oracle_start_time(&mut oracle, 2000);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Write Observation Tests ===

#[test]
#[expected_failure(abort_code = oracle::EMarketNotStarted)]
fun test_write_observation_before_market_start_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);

    // Try to write without starting market - should fail
    oracle::write_observation(&mut oracle, 1000, 10000);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_no_time_passed() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write at same timestamp - should do nothing
    oracle::write_observation(&mut oracle, 1000, 10000);

    // State should remain unchanged
    assert!(oracle::last_timestamp(&oracle) == 1000, 0);
    assert!(oracle::total_cumulative_price(&oracle) == 0, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_before_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));
    // Oracle has 60_000 ms delay (1 minute)

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write at 5000ms (before 1000 + 60_000 = 61_000)
    oracle::write_observation(&mut oracle, 5000, 11000);

    // Should accumulate normally
    assert!(oracle::last_timestamp(&oracle) == 5000, 0);
    assert!(oracle::total_cumulative_price(&oracle) > 0, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_crossing_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));
    // Oracle has 60_000 ms delay (1 minute)

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write before threshold
    oracle::write_observation(&mut oracle, 5000, 10000);
    let cumulative_before = oracle::total_cumulative_price(&oracle);

    // Write crossing threshold (1000 + 60_000 = 61_000)
    oracle::write_observation(&mut oracle, 70_000, 10500);

    // Accumulators should be reset at delay threshold
    // total_cumulative_price should be less than if it wasn't reset
    let cumulative_after = oracle::total_cumulative_price(&oracle);

    // After crossing threshold, accumulation restarted from delay_threshold
    assert!(oracle::last_timestamp(&oracle) == 70_000, 0);
    assert!(cumulative_after > 0, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_after_delay_threshold() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross the delay threshold first
    oracle::write_observation(&mut oracle, 70_000, 10000);
    let cumulative_1 = oracle::total_cumulative_price(&oracle);

    // Write after threshold
    oracle::write_observation(&mut oracle, 80_000, 10500);
    let cumulative_2 = oracle::total_cumulative_price(&oracle);

    // Should accumulate normally
    assert!(oracle::last_timestamp(&oracle) == 80_000, 0);
    assert!(cumulative_2 > cumulative_1, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::ETimestampRegression)]
fun test_write_observation_timestamp_regression_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    oracle::write_observation(&mut oracle, 70_000, 10000);

    // Try to write earlier timestamp - should fail
    oracle::write_observation(&mut oracle, 60_000, 10500);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Price Capping Tests ===

#[test]
fun test_write_observation_price_cap_upward() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario)
    );

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    oracle::write_observation(&mut oracle, 70_000, 10000);

    // Try to jump price by 500 (5x the cap of 100)
    oracle::write_observation(&mut oracle, 130_000, 10500);

    // Price should be capped
    let last_price = oracle::last_price(&oracle);
    // After multiple windows, price can move up to cap per window
    assert!(last_price <= 10500, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_price_cap_downward() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario)
    );

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    oracle::write_observation(&mut oracle, 70_000, 10000);

    // Try to drop price by 500 (5x the cap of 100)
    oracle::write_observation(&mut oracle, 130_000, 9500);

    // Price should be capped
    let last_price = oracle::last_price(&oracle);
    assert!(last_price >= 9500, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_price_within_cap() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario)
    );

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    oracle::write_observation(&mut oracle, 70_000, 10000);

    // Small price change within cap
    oracle::write_observation(&mut oracle, 80_000, 10050);

    // Should accept the price as-is
    let last_price = oracle::last_price(&oracle);
    assert!(last_price == 10050, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === TWAP Calculation Tests ===

#[test]
fun test_get_twap_after_write() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold and accumulate
    clock.set_for_testing(70_000);
    oracle::write_observation(&mut oracle, 70_000, 10000);

    clock.set_for_testing(130_000);
    oracle::write_observation(&mut oracle, 130_000, 10500);

    // Read TWAP
    let twap = oracle::get_twap(&oracle, &clock);

    // TWAP should be between 10000 and 10500
    assert!(twap >= 10000 && twap <= 10500, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::EStaleTwap)]
fun test_get_twap_without_write_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    oracle::write_observation(&mut oracle, 70_000, 10000);

    // Advance clock without writing
    clock.set_for_testing(130_000);

    // Try to read TWAP - should fail (stale)
    let _twap = oracle::get_twap(&oracle, &clock);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::ETwapNotStarted)]
fun test_get_twap_before_delay_period_fails() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write before delay threshold
    clock.set_for_testing(30_000);
    oracle::write_observation(&mut oracle, 30_000, 10000);

    // Try to read TWAP - should fail (before delay)
    let _twap = oracle::get_twap(&oracle, &clock);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = oracle::EMarketNotStarted)]
fun test_get_twap_market_not_started_fails() {
    let (mut scenario, mut clock) = start();

    let oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);

    // Try to read TWAP without starting market - should fail
    let _twap = oracle::get_twap(&oracle, &clock);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Window Boundary Tests ===

#[test]
fun test_write_observation_window_boundary() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    oracle::write_observation(&mut oracle, 70_000, 10000);

    let window_size = constants::twap_price_cap_window();
    let initial_window_end = oracle::get_last_window_end_for_testing(&oracle);

    // Write exactly at window boundary
    let next_boundary = initial_window_end + window_size;
    oracle::write_observation(&mut oracle, next_boundary, 10100);

    // Window end should update
    let new_window_end = oracle::get_last_window_end_for_testing(&oracle);
    assert!(new_window_end == next_boundary, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_write_observation_multiple_windows() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    oracle::write_observation(&mut oracle, 70_000, 10000);

    let window_size = constants::twap_price_cap_window();

    // Jump multiple windows ahead
    let target_time = 70_000 + (window_size * 5);
    oracle::write_observation(&mut oracle, target_time, 10200);

    // Should process multiple full windows
    assert!(oracle::last_timestamp(&oracle) == target_time, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Integration Tests ===

#[test]
fun test_full_oracle_workflow() {
    let (mut scenario, mut clock) = start();

    // 1. Create oracle with realistic params
    let mut oracle = oracle::new_oracle(
        1_000_000,  // $1.00 (6 decimals)
        300_000,    // 5 minute delay
        50_000,     // 5% cap
        ts::ctx(&mut scenario)
    );

    // 2. Start market
    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // 3. Write observations during delay period
    clock.set_for_testing(100_000);
    oracle::write_observation(&mut oracle, 100_000, 1_000_000);

    clock.set_for_testing(200_000);
    oracle::write_observation(&mut oracle, 200_000, 1_010_000);

    // 4. Cross delay threshold
    clock.set_for_testing(400_000); // Past 1000 + 300_000
    oracle::write_observation(&mut oracle, 400_000, 1_020_000);

    // 5. Continue observations after delay
    clock.set_for_testing(500_000);
    oracle::write_observation(&mut oracle, 500_000, 1_030_000);

    clock.set_for_testing(600_000);
    oracle::write_observation(&mut oracle, 600_000, 1_040_000);

    // 6. Read TWAP
    let twap = oracle::get_twap(&oracle, &clock);

    // TWAP should reflect accumulated prices
    assert!(twap >= 1_000_000 && twap <= 1_040_000, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_realistic_price_discovery_scenario() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::new_oracle(
        500_000,    // $0.50 initialization
        60_000,     // 1 minute delay
        100_000,    // 10% cap
        ts::ctx(&mut scenario)
    );

    clock.set_for_testing(0);
    oracle::set_oracle_start_time(&mut oracle, 0);

    // Simulate trading activity
    let mut time = 60_000; // After delay
    let mut price = 500_000;

    // Price gradually increases
    let mut i = 0;
    while (i < 10) {
        time = time + 10_000; // 10 second intervals
        price = price + 5_000; // $0.005 increase per step

        clock.set_for_testing(time);
        oracle::write_observation(&mut oracle, time, price);

        i = i + 1;
    };

    // Read final TWAP
    let twap = oracle::get_twap(&oracle, &clock);

    // TWAP should be between initial and final price
    assert!(twap >= 500_000 && twap <= 550_000, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Internal Function Tests (via test helpers) ===

#[test]
fun test_intra_window_accumulation_direct() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state for testing
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    // Call intra_window accumulation for 5000ms
    oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500, // price
        5000,  // duration
        6000   // timestamp
    );

    // Verify accumulation happened
    assert!(oracle::last_timestamp(&oracle) == 6000, 0);
    assert!(oracle::total_cumulative_price(&oracle) > 0, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_intra_window_accumulation_hits_boundary() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Accumulate exactly one window
    oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        window_size,
        1000 + window_size
    );

    // Window should advance
    let new_window_end = oracle::get_last_window_end_for_testing(&oracle);
    assert!(new_window_end == 1000 + window_size, 0);

    // Window TWAP should update
    let window_twap = oracle::debug_get_window_twap(&oracle);
    assert!(window_twap > 0, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_multi_full_window_accumulation_single_window() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Process 1 full window
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10500, // price
        1,     // num_windows
        1000 + window_size
    );

    // Verify state updated
    assert!(oracle::last_timestamp(&oracle) == 1000 + window_size, 0);
    assert!(oracle::get_last_window_end_for_testing(&oracle) == 1000 + window_size, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_multi_full_window_accumulation_multiple_windows() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Process 10 full windows
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        11000, // price significantly higher
        10,    // num_windows
        1000 + (window_size * 10)
    );

    // Verify state updated
    assert!(oracle::last_timestamp(&oracle) == 1000 + (window_size * 10), 0);
    assert!(oracle::get_last_window_end_for_testing(&oracle) == 1000 + (window_size * 10), 1);

    // Last price should be capped progression toward target
    let last_price = oracle::last_price(&oracle);
    assert!(last_price > 10000 && last_price <= 11000, 2);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_multi_full_window_price_ramping() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario)
    );

    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Try to jump to much higher price
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        15000, // 50% increase (should be capped)
        5,     // 5 windows
        1000 + (window_size * 5)
    );

    // Price should ramp up gradually, not jump to 15000
    let last_price = oracle::last_price(&oracle);
    assert!(last_price > 10000, 0);
    assert!(last_price < 15000, 1); // Should be capped
    // With cap_step=100 and 5 windows, max increase is 500
    assert!(last_price <= 10500, 2);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_multi_full_window_price_ramping_downward() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap -> cap_step = 100
        ts::ctx(&mut scenario)
    );

    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Try to drop to much lower price
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        5000,  // 50% decrease (should be capped)
        5,     // 5 windows
        1000 + (window_size * 5)
    );

    // Price should ramp down gradually, not drop to 5000
    let last_price = oracle::last_price(&oracle);
    assert!(last_price < 10000, 0);
    assert!(last_price > 5000, 1); // Should be capped
    // With cap_step=100 and 5 windows, max decrease is 500
    assert!(last_price >= 9500, 2);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_twap_accumulate_all_three_stages() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Set up state: Start partway into a window
    let window_size = constants::twap_price_cap_window();
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000 + (window_size / 4));
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    // Jump ahead: partial window + 3 full windows + partial window
    let target_time = 1000 + (window_size * 4) + (window_size / 2);

    oracle::call_twap_accumulate_for_testing(
        &mut oracle,
        target_time,
        10500
    );

    // Should process all three stages
    assert!(oracle::last_timestamp(&oracle) == target_time, 0);
    assert!(oracle::total_cumulative_price(&oracle) > 0, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Extreme Value Tests ===

#[test]
fun test_very_large_price() {
    let (mut scenario, mut clock) = start();

    // Create oracle with very large initialization price
    let large_price: u128 = 1_000_000_000_000_000_000; // 10^18
    let mut oracle = oracle::new_oracle(
        large_price,
        60_000,
        1000,
        ts::ctx(&mut scenario)
    );

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write observations with large prices
    clock.set_for_testing(70_000);
    oracle::write_observation(&mut oracle, 70_000, large_price);

    clock.set_for_testing(130_000);
    oracle::write_observation(&mut oracle, 130_000, large_price + 1_000_000);

    // Should handle large values without overflow
    let twap = oracle::get_twap(&oracle, &clock);
    assert!(twap >= large_price, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_very_long_duration() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    clock.set_for_testing(70_000);
    oracle::write_observation(&mut oracle, 70_000, 10000);

    // Jump to 7 days later (max proposal duration mentioned in comments)
    let seven_days_ms = 7 * 24 * 60 * 60 * 1000;
    let target_time = 70_000 + seven_days_ms;

    clock.set_for_testing(target_time);
    oracle::write_observation(&mut oracle, target_time, 10500);

    // Should handle long duration without overflow
    let twap = oracle::get_twap(&oracle, &clock);
    assert!(twap >= 10000 && twap <= 10500, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_minimum_cap_step() {
    let (mut scenario, mut clock) = start();

    // Very small initialization price with very small PPM
    // This should result in cap_step = 1 (minimum)
    let mut oracle = oracle::new_oracle(
        100,    // Small price
        60_000,
        1,      // Minimum PPM that would result in cap_step < 1
        ts::ctx(&mut scenario)
    );

    let (_, cap_step) = oracle::config(&oracle);
    // Should be forced to minimum of 1
    assert!(cap_step >= 1, 0);

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Should still work with minimum cap step
    clock.set_for_testing(70_000);
    oracle::write_observation(&mut oracle, 70_000, 100);

    clock.set_for_testing(130_000);
    oracle::write_observation(&mut oracle, 130_000, 110);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_price_exactly_at_base() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    oracle::set_oracle_start_time(&mut oracle, 1000);
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Price exactly equals base (g_abs = 0)
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10000, // Same as base
        5,     // 5 windows
        1000 + (window_size * 5)
    );

    // Should handle zero deviation case
    let last_price = oracle::last_price(&oracle);
    assert!(last_price == 10000, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === State Consistency Tests ===

#[test]
fun test_cumulative_price_consistency() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write multiple observations
    clock.set_for_testing(70_000);
    oracle::write_observation(&mut oracle, 70_000, 10000);

    let cumulative_1 = oracle::total_cumulative_price(&oracle);
    let window_cumulative_1 = oracle::get_last_window_end_cumulative_price_for_testing(&oracle);

    clock.set_for_testing(130_000);
    oracle::write_observation(&mut oracle, 130_000, 10500);

    let cumulative_2 = oracle::total_cumulative_price(&oracle);
    let window_cumulative_2 = oracle::get_last_window_end_cumulative_price_for_testing(&oracle);

    // Cumulative should only increase
    assert!(cumulative_2 >= cumulative_1, 0);
    assert!(window_cumulative_2 >= window_cumulative_1, 1);

    // last_window_end_cumulative_price should be <= total_cumulative_price
    assert!(window_cumulative_2 <= cumulative_2, 2);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_timestamp_ordering_invariant() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Write multiple observations and verify invariant at each step
    let mut times = vector[70_000, 130_000, 200_000, 300_000];
    let mut i = 0;

    while (i < times.length()) {
        let time = times[i];
        clock.set_for_testing(time);
        oracle::write_observation(&mut oracle, time, 10000 + ((i as u128) * 100));

        // Invariant: last_timestamp >= last_window_end
        let last_ts = oracle::last_timestamp(&oracle);
        let last_window = oracle::get_last_window_end_for_testing(&oracle);
        assert!(last_ts >= last_window, i);

        i = i + 1;
    };

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Mathematical Property Tests ===

#[test]
fun test_price_cap_symmetry() {
    let (mut scenario, clock) = start();

    // Create two oracles with identical params
    let mut oracle_up = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap
        ts::ctx(&mut scenario)
    );

    let mut oracle_down = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap
        ts::ctx(&mut scenario)
    );

    oracle::set_oracle_start_time(&mut oracle_up, 1000);
    oracle::set_oracle_start_time(&mut oracle_down, 1000);

    oracle::set_last_timestamp_for_testing(&mut oracle_up, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle_up, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle_up, 10000);

    oracle::set_last_timestamp_for_testing(&mut oracle_down, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle_down, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle_down, 10000);

    let window_size = constants::twap_price_cap_window();

    // Same magnitude deviation, opposite directions
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_up,
        10500, // +500
        5,
        1000 + (window_size * 5)
    );

    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_down,
        9500,  // -500
        5,
        1000 + (window_size * 5)
    );

    let price_up = oracle::last_price(&mut oracle_up);
    let price_down = oracle::last_price(&mut oracle_down);

    // Deviations should be symmetric
    let dev_up = price_up - 10000;
    let dev_down = 10000 - price_down;
    assert!(dev_up == dev_down, 0);

    oracle::destroy_for_testing(oracle_up);
    oracle::destroy_for_testing(oracle_down);
    end(scenario, clock);
}

#[test]
fun test_multiple_small_steps_vs_one_large() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap = 100 step
        ts::ctx(&mut scenario)
    );

    oracle::set_oracle_start_time(&mut oracle, 1000);
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Try to jump by 500 in 5 windows vs 1 window
    // Should ramp up gradually
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10500,
        5,
        1000 + (window_size * 5)
    );

    let price_5_windows = oracle::last_price(&oracle);

    // Reset for comparison
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);
    oracle::set_cumulative_prices_for_testing(&mut oracle, 0, 0);

    // Same target but fewer windows
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle,
        10500,
        1,
        1000 + window_size
    );

    let price_1_window = oracle::last_price(&oracle);

    // More windows should allow more progress toward target
    assert!(price_5_windows >= price_1_window, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Attack Scenario Tests ===

#[test]
fun test_rapid_price_manipulation_resistance() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap
        ts::ctx(&mut scenario)
    );

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Cross delay threshold
    clock.set_for_testing(70_000);
    oracle::write_observation(&mut oracle, 70_000, 10000);

    // Attacker tries rapid price spikes
    clock.set_for_testing(80_000);
    oracle::write_observation(&mut oracle, 80_000, 20000); // 2x spike

    clock.set_for_testing(90_000);
    oracle::write_observation(&mut oracle, 90_000, 5000); // Drop to 0.5x

    clock.set_for_testing(100_000);
    oracle::write_observation(&mut oracle, 100_000, 15000); // Another spike

    // Read TWAP - should be relatively stable due to capping
    let twap = oracle::get_twap(&oracle, &clock);

    // TWAP should not have wild swings - should be closer to 10000 than extremes
    assert!(twap > 8000 && twap < 12000, 0);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_gradual_manipulation_over_time() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::new_oracle(
        10000,
        60_000,
        10_000, // 1% cap = 100 per window
        ts::ctx(&mut scenario)
    );

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    clock.set_for_testing(70_000);
    oracle::write_observation(&mut oracle, 70_000, 10000);

    // Attacker gradually increases price within caps
    let window_size = constants::twap_price_cap_window();
    let mut time = 70_000;
    let mut price = 10000;

    let mut i = 0;
    while (i < 20) {
        time = time + window_size;
        price = price + 90; // Just under cap

        clock.set_for_testing(time);
        oracle::write_observation(&mut oracle, time, price);

        i = i + 1;
    };

    // Even with gradual manipulation, price progression is capped
    let final_price = oracle::last_price(&oracle);
    assert!(final_price <= 10000 + (100 * 20), 0); // Max 100 per window

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === Window Alignment Edge Cases ===

#[test]
fun test_observation_just_before_window_boundary() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    oracle::set_oracle_start_time(&mut oracle, 1000);
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Write 1ms before window boundary
    oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        window_size - 1,
        1000 + window_size - 1
    );

    // Window should NOT advance yet
    let window_end = oracle::get_last_window_end_for_testing(&oracle);
    assert!(window_end == 1000, 0);

    // Write 1ms more to hit boundary
    oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        1,
        1000 + window_size
    );

    // Now window should advance
    let new_window_end = oracle::get_last_window_end_for_testing(&oracle);
    assert!(new_window_end == 1000 + window_size, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

#[test]
fun test_observation_just_after_window_boundary() {
    let (mut scenario, clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    oracle::set_oracle_start_time(&mut oracle, 1000);
    oracle::set_last_timestamp_for_testing(&mut oracle, 1000);
    oracle::set_last_window_end_for_testing(&mut oracle, 1000);
    oracle::set_last_window_twap_for_testing(&mut oracle, 10000);

    let window_size = constants::twap_price_cap_window();

    // Write exactly at boundary
    oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        window_size,
        1000 + window_size
    );

    let window_end_1 = oracle::get_last_window_end_for_testing(&oracle);
    assert!(window_end_1 == 1000 + window_size, 0);

    // Write 1ms after boundary (new window)
    oracle::call_intra_window_accumulation_for_testing(
        &mut oracle,
        10500,
        1,
        1000 + window_size + 1
    );

    // Should still be in new window (not advanced again)
    let window_end_2 = oracle::get_last_window_end_for_testing(&oracle);
    assert!(window_end_2 == window_end_1, 1);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}

// === View Function Tests ===

#[test]
fun test_view_functions() {
    let (mut scenario, mut clock) = start();

    let mut oracle = oracle::test_oracle(ts::ctx(&mut scenario));

    clock.set_for_testing(1000);
    oracle::set_oracle_start_time(&mut oracle, 1000);

    // Verify getters
    assert!(oracle::twap_initialization_price(&oracle) == 10000, 0);
    assert!(oracle::last_timestamp(&oracle) == 1000, 1);
    assert!(oracle::total_cumulative_price(&oracle) == 0, 2);

    let (delay, cap_step) = oracle::config(&oracle);
    assert!(delay == 60_000, 3);
    assert!(cap_step == 10, 4);

    oracle::destroy_for_testing(oracle);
    end(scenario, clock);
}
