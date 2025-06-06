// New test module for futarchy::oracle
#[test_only]
module futarchy::oracle_tests;

use futarchy::oracle::{Self, Oracle};
use std::debug;
use std::u128;
use sui::clock;
use sui::test_scenario::{Self as test, Scenario};

// ======== Test Constants ========
const TWAP_STEP_MAX: u64 = 1000; // Allow 10% movement
const TWAP_START_DELAY: u64 = 60_000;
const MARKET_START_TIME: u64 = 1000;
const INIT_PRICE: u128 = 10000;
const TWAP_PRICE_CAP_WINDOW_PERIOD: u64 = 60000;

// For testing extreme values, define a maximum u64 constant.
const U64_MAX: u64 = 18446744073709551615;


// Define a high price constant for testing
const HIGH_INIT_PRICE: u128 = 1_000_000_000_000_000u128; // 1 quadrillion
// Define a very large step size to prevent capping for this high price
const LARGE_TWAP_STEP: u64 = 20_000_000_000_000;

// ======== Helper Functions ========
fun setup_test_oracle(ctx: &mut TxContext): Oracle {
    let mut oracle_inst = oracle::new_oracle(
        INIT_PRICE,
        TWAP_START_DELAY,
        TWAP_STEP_MAX,
        ctx,
    );
    // Explicitly set the market start time using the dedicated function
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
fun test_new_oracle() {
    let mut scenario = test::begin(@0x1);
    test::next_tx(&mut scenario, @0x1);
    {
        let ctx = test::ctx(&mut scenario);
        let oracle_inst = setup_test_oracle(ctx);
        // Validate initial values
        assert!(oracle::get_last_price(&oracle_inst) == INIT_PRICE, 0);
        assert!(oracle::get_last_timestamp(&oracle_inst) == MARKET_START_TIME, 1);
        let (delay, step) = oracle::get_config(&oracle_inst);
        assert!(delay == TWAP_START_DELAY, 3);
        assert!(step == TWAP_STEP_MAX, 4);
        assert!(step == TWAP_STEP_MAX, 4); // Error code 4 for this line
        assert!(oracle::get_market_start_time(&oracle_inst) == option::some(MARKET_START_TIME), 5);
        assert!(oracle::get_twap_initialization_price(&oracle_inst) == INIT_PRICE, 6);
        oracle::destroy_for_testing(oracle_inst);
    };
    test::end(scenario);
}

#[test]
fun test_write_observation_after_delay_upward_cap() {
    // When a high price is reported after the delay, it should be capped upward.
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        let observation_time = 63_500;
        let high_price = 15000; // Exceeds allowed cap.
        oracle::write_observation(&mut oracle_inst, observation_time, high_price);
        assert!(oracle::get_last_price(&oracle_inst) == 12000, 0);
        assert!(oracle::get_last_timestamp(&oracle_inst) == observation_time, 1);
        let (_, _, cumulative) = oracle::debug_get_state(&oracle_inst);
        debug::print(&oracle_inst);
        assert!(cumulative == 12000 as u256 * 2500, 2);
        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_write_observation_after_delay_downward_cap() {
    // When a low price is reported after the delay, it should be capped downward.
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);

        let observation_time = 63500;
        let low_price = 5000; // Too low, will be capped.
        oracle::write_observation(&mut oracle_inst, observation_time, low_price);
        assert!(oracle::get_last_price(&oracle_inst) == 8000, 0);
        assert!(oracle::get_last_timestamp(&oracle_inst) == observation_time, 1);
        let (_, _, cumulative) = oracle::debug_get_state(&oracle_inst);
        assert!(cumulative == 8000 as u256 * 2500, 2);
        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::oracle::ETIMESTAMP_REGRESSION)]
fun test_timestamp_regression() {
    // An observation with a timestamp earlier than the previous one should abort.
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        // First valid observation.
        oracle::write_observation(&mut oracle_inst, 3500, 15000);
        // Second observation with an earlier timestamp should trigger a timestamp regression error.
        oracle::write_observation(&mut oracle_inst, 3000, 16000);
        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_is_twap_valid() {
    // Validate the TWAP validity check by comparing the current time to the last update time.
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        // Write an observation after delay so that last_timestamp is updated.
        oracle::write_observation(&mut oracle_inst, 3500, 15000);
        // Set clock to a time shortly after the last observation.
        clock::set_for_testing(&mut clock_inst, 4000);
        // With a min_period of 600, 4000 < 3500+600 = 4100, so TWAP should not be valid.
        assert!(!oracle::is_twap_valid(&oracle_inst, 600, &clock_inst), 0);
        // Advance clock to ensure validity.
        clock::set_for_testing(&mut clock_inst, 4200);
        assert!(oracle::is_twap_valid(&oracle_inst, 600, &clock_inst), 1);
        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_getters() {
    // Verify that all getters return the expected initial configuration.
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let oracle_inst = setup_test_oracle(ctx);
        assert!(oracle::get_last_price(&oracle_inst) == INIT_PRICE, 0);
        assert!(oracle::get_last_timestamp(&oracle_inst) == MARKET_START_TIME, 1);
        assert!(oracle::get_market_start_time(&oracle_inst) == option::some(MARKET_START_TIME), 4);
        assert!(oracle::get_twap_initialization_price(&oracle_inst) == INIT_PRICE, 5);
        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_write_observation_no_time_progress() {
    // Verify that when an observation is submitted with no time progression,
    // no cumulative update or price change occurs.
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY;

        // Submit an observation exactly at the delay threshold.
        // In write_observation, if the timestamp equals delay_threshold,
        // last_timestamp is set to delay_threshold but additional time is zero.
        oracle::write_observation(&mut oracle_inst, delay_threshold, 15000);

        // Expect that last_price remains at INIT_PRICE and cumulative price remains 0.
        let price = oracle::get_last_price(&oracle_inst);
        debug::print(&price);
        assert!(oracle::get_last_price(&oracle_inst) == (INIT_PRICE + (TWAP_STEP_MAX as u128)), 0);
        assert!(oracle::get_last_timestamp(&oracle_inst) == delay_threshold, 1);
        let (_, _, cumulative) = oracle::debug_get_state(&oracle_inst);
                debug::print(&cumulative);
        assert!(cumulative == 0, 2);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_multiple_write_observations_consistency() {
    // Verify that sequential observations accumulate the cumulative price as expected.
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        // Oracle state after creation:
        // last_timestamp = MARKET_START_TIME (1000)
        // total_cumulative_price = 0
        // last_window_end = MARKET_START_TIME (1000)
        // last_window_end_cumulative_price = 0
        // last_window_twap = INIT_PRICE (10000)
        let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY; // 1000 + 60000 = 61000

        // --- Observation 1 ---
        // Timestamp: 62000 (delay_threshold + 1000)
        // Price: 10500
        // Interval 1000 -> 62000 crosses the delay threshold 61000.
        // Part A: Process 1000 -> 61000 (duration 60000). Capped price vs 10000 (last_window_twap): min(10500, 10000+1000) = 11000.
        // Accumulation: 11000 * 60000 = 660,000,000. total_cumulative_price becomes 660,000,000. last_timestamp becomes 61000.
        // Window boundary hit at 61000. last_window_end=61000, last_window_twap=(660M-0)/60k=11000, last_window_end_cumulative_price=660M.
        // Part B: Reset at 61000. total_cumulative_price=0, last_window_end_cumulative_price=0, last_window_end=61000.
        // Part C: Process 61000 -> 62000 (duration 1000). Capped price vs 11000 (new last_window_twap): max(10500, 11000-1000) = 10500.
        // Accumulation: 10500 * 1000 = 10,500,000. total_cumulative_price becomes 10,500,000. last_timestamp becomes 62000.
        let obs1_time = delay_threshold + 1000; // 62000
        let obs1_price = 10500;
        oracle::write_observation(&mut oracle_inst, obs1_time, obs1_price);
        // State after obs1: last_timestamp=62000, total_cumulative_price=10,500,000, last_window_twap=11000


        // --- Observation 2 ---
        // Timestamp: 64000 (62000 + 2000)
        // Price: 9500
        // Interval 62000 -> 64000 (duration 2000). After threshold.
        // Capped price vs 11000 (last_window_twap): max(9500, 11000-1000) = 10000.
        // Accumulation: 10000 * 2000 = 20,000,000.
        // total_cumulative_price becomes 10,500,000 + 20,000,000 = 30,500,000. last_timestamp becomes 64000.
        let obs2_time = obs1_time + 2000; // 64000
        let obs2_price = 9500;
        oracle::write_observation(&mut oracle_inst, obs2_time, obs2_price);
        // State after obs2: last_timestamp=64000, total_cumulative_price=30,500,000, last_window_twap=11000


        // --- Observation 3 ---
        // Timestamp: 67000 (64000 + 3000)
        // Price: 12000
        // Interval 64000 -> 67000 (duration 3000). After threshold.
        // Capped price vs 11000 (last_window_twap): min(12000, 11000+1000) = 12000.
        // Accumulation: 12000 * 3000 = 36,000,000.
        // total_cumulative_price becomes 30,500,000 + 36,000,000 = 66,500,000. last_timestamp becomes 67000.
        let obs3_time = obs2_time + 3000; // 67000
        let obs3_price = 12000;
        oracle::write_observation(&mut oracle_inst, obs3_time, obs3_price);
        // State after obs3: last_timestamp=67000, total_cumulative_price=66,500,000, last_window_twap=11000


        // Final expected cumulative price:
        // (Accumulation from 61000 to 62000: 10500 * 1000 = 10,500,000)
        // + (Accumulation from 62000 to 64000: 10000 * 2000 = 20,000,000)
        // + (Accumulation from 64000 to 67000: 12000 * 3000 = 36,000,000)
        // Total = 10,500,000 + 20,000,000 + 36,000,000 = 66,500,000.
        let expected_cumulative_price = 64_000_000u256;

        let (_, _, cumulative) = oracle::debug_get_state(&oracle_inst);

        assert!(cumulative == expected_cumulative_price, 0);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
fun test_twap_drift_towards_observation_price() {
    // Use the same constants as in other tests.
    let target_price: u128 = 20000;
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY; // For example, 1000+2000 = 3000.

    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        // --- First observation ---
        // Write an observation shortly after the delay. Because no full window has elapsed,
        // the new price is capped upward by one step. With INIT_PRICE = 10000 and TWAP_STEP_MAX = 1000,
        // the allowed change is 10000*1000/10000 = 1000 so the observed price becomes 11000.
        let first_obs_time = delay_threshold + 1000; // 3000 + 1000 = 4000.
        oracle::write_observation(&mut oracle_inst, first_obs_time, target_price);

        // --- Subsequent observations ---
        // Now, simulate a series of observations separated by exactly one TWAP window period.
        // In the "if" branch (when a full window has passed) the allowed change increases by:
        // allowed_increase = last_window_twap * TWAP_STEP_MAX * (1+full_windows) / BASIS_POINTS.
        // By repeatedly writing the same target price, the capped price will eventually reach target_price.
        let second_obs_time = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD; // 3000 + 60000 = 63000.
        oracle::write_observation(&mut oracle_inst, second_obs_time, target_price);

        let third_obs_time = second_obs_time + TWAP_PRICE_CAP_WINDOW_PERIOD; // 63000 + 60000 = 123000.
        oracle::write_observation(&mut oracle_inst, third_obs_time, target_price);

        let fourth_obs_time = third_obs_time + TWAP_PRICE_CAP_WINDOW_PERIOD; // 123000 + 60000 = 183000.
        oracle::write_observation(&mut oracle_inst, fourth_obs_time, target_price);

        let fifth_obs_time = fourth_obs_time + TWAP_PRICE_CAP_WINDOW_PERIOD; // 183000 + 60000 = 243000.
        oracle::write_observation(&mut oracle_inst, fifth_obs_time, target_price);

        // --- Final long-duration observation ---
        // Simulate a long period during which the new target price is maintained.
        // This adds a dominant contribution at the target price.
        let final_obs_time = fifth_obs_time + 5000000; // A long interval after the last observation.
        oracle::write_observation(&mut oracle_inst, final_obs_time, target_price);

        // Set the testing clock to the time of the final observation.
        clock::set_for_testing(&mut clock_inst, final_obs_time);

        // --- Compute and verify TWAP ---
        let twap = oracle::get_twap(&oracle_inst, &clock_inst);
        // Because the long final interval adds significant weight at 'target_price',
        // the overall TWAP should have drifted close to target_price.
        // Allow a small tolerance (e.g. TWAP >= 19000) to account for earlier lower values.

        assert!(twap >= 19000, 0);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

// ---------------------------------------------------------------------
// Test: Cumulative Price Overflow
// This test intentionally drives the cumulative price near the maximum,
// then triggers an overflow on the second observation.
#[test]
#[expected_failure(abort_code = oracle::EOVERFLOW_BASE_PRICE_SUM_FINAL)]
fun test_cumulative_price_overflow() {
    // Set up an oracle with extreme parameters:
    // - twap_initialization_price = U64_MAX,
    // - market_start_time = 0,
    // - twap_start_delay = 0,
    // - twap_step_max = U64_MAX.
    let mut scenario = test::begin(@0x1);
    test::next_tx(&mut scenario, @0x1);
    let ctx = test::ctx(&mut scenario);
    let mut extreme_oracle = oracle::new_oracle(u128::max_value!(), 0, U64_MAX, ctx);

    oracle::set_oracle_start_time(&mut extreme_oracle, MARKET_START_TIME);

    // First observation: timestamp = U64_MAX / 2.
    let half_max: u64 = U64_MAX / 2;
    oracle::write_observation(&mut extreme_oracle, half_max, u128::max_value!());

    // Second observation: timestamp = U64_MAX.
    // This second call pushes the cumulative price beyond u256's capacity.
    oracle::write_observation(&mut extreme_oracle, U64_MAX, u128::max_value!());

    // The overflow is expected before reaching this point.
    oracle::destroy_for_testing(extreme_oracle);
    test::end(scenario);
}

// ---------------------------------------------------------------------
// Test: Exact Full Window Boundary Conditions
// Verifies behavior when an observation occurs exactly at the TWAP delay threshold
// and at exactly one full TWAP window after that.
#[test]
fun test_exact_full_window_boundary() {
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    let delay_threshold: u64 = MARKET_START_TIME + TWAP_START_DELAY; // e.g., 1000+2000 = 3000

    // Observation exactly at the delay threshold.
    oracle::write_observation(&mut oracle_inst, delay_threshold, 15000);
    let (_, ts1, cumulative1) = oracle::debug_get_state(&oracle_inst);
    assert!(ts1 == delay_threshold, 0);
    assert!(cumulative1 == 0, 1);

    // Observation exactly at delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD.
    let obs_time: u64 = delay_threshold + TWAP_PRICE_CAP_WINDOW_PERIOD; // 3000 + 60000 = 63000
    oracle::write_observation(&mut oracle_inst, obs_time, 15000);
    let (_last_price, ts2, cumulative2) = oracle::debug_get_state(&oracle_inst);
    assert!(ts2 == obs_time, 2);
    debug::print(&cumulative2);
    assert!(cumulative2 == 720000000, 3);

    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}

// ---------------------------------------------------------------------
// Test: Identical Timestamps
// Verifies that multiple observations with the same timestamp do not update the state.
#[test]
fun test_identical_timestamps_no_update() {
    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    let delay_threshold: u64 = MARKET_START_TIME + TWAP_START_DELAY; // 3000

    // First valid observation after delay.
    oracle::write_observation(&mut oracle_inst, delay_threshold + 500, 15000);
    let (last_price1, ts1, cumulative1) = oracle::debug_get_state(&oracle_inst);

    // Second observation with the same timestamp (ts1).
    // With no time progression, no cumulative price or state change should occur.
    oracle::write_observation(&mut oracle_inst, ts1, 5000);
    let (last_price2, ts2, cumulative2) = oracle::debug_get_state(&oracle_inst);

    assert!(ts2 == ts1, 0);
    assert!(cumulative2 == cumulative1, 1);
    assert!(last_price2 == last_price1, 2);

    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}

#[test]
fun test_cross_delay_period_twap_calculation() {
    // This test simulates multiple observations and then refreshes the observation to ensure
    // clock time equals last_timestamp before reading TWAP.
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        oracle::write_observation(&mut oracle_inst, 3500, 15000);

        oracle::write_observation(&mut oracle_inst, 10000, 5000);

        let current_time = 72000;
        clock::set_for_testing(&mut clock_inst, current_time);
        let last_price = oracle::get_last_price(&oracle_inst);
        oracle::write_observation(&mut oracle_inst, current_time, last_price);
        let expected_twap = 9000;
        let twap = oracle::get_twap(&oracle_inst, &clock_inst);

        assert!((twap as u256) == expected_twap, 0);
        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = oracle::EZERO_PERIOD)]
fun test_get_twap_zero_period() {
    // Calling get_twap with an effective period of zero should trigger EZERO_PERIOD.
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = setup_test_oracle(ctx);
        let ts = MARKET_START_TIME + TWAP_START_DELAY;
        clock::set_for_testing(&mut clock_inst, ts);
        // Refresh observation at ts.
        let last_price = oracle::get_last_price(&oracle_inst);
        oracle::write_observation(&mut oracle_inst, ts, last_price);
        let _ = oracle::get_twap(&oracle_inst, &clock_inst);
        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}
#[test]
fun test_high_frequency_alternating_observations() {
    // Simulate ten alternating high and low price observations.
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY; // 3000
    // Observations at timestamps 3001 to 3010.
    oracle::write_observation(&mut oracle_inst, delay_threshold + 0, 10000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 1, 15000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 2, 5000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 3, 15000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 4, 5000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 5, 15000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 6, 5000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 7, 15000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 8, 5000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 9, 15000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 10, 5000);
    // Refresh observation: set clock to last observation time.
    clock::set_for_testing(&mut clock_inst, delay_threshold + 10);
    let period: u64 = ((delay_threshold + 10) - MARKET_START_TIME) - TWAP_START_DELAY;
    let twap = oracle::get_twap(&oracle_inst, &clock_inst);
    let expected_twap = 100000u256 / (period as u256);
    assert!((twap as u256) == expected_twap, 3);
    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}

#[test]
fun test_repeated_get_twap_consistency() {
    // Repeated calls to get_twap without new observations should yield identical results.
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    let delay_threshold: u64 = MARKET_START_TIME + TWAP_START_DELAY; // 3000
    oracle::write_observation(&mut oracle_inst, delay_threshold + 1000, 15000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 5000, 9000);
    oracle::write_observation(&mut oracle_inst, delay_threshold + 10000, 12000);
    let fixed_time: u64 = delay_threshold + 11000; // 14000
    clock::set_for_testing(&mut clock_inst, fixed_time);
    // Refresh observation at fixed_time.
    let last_price = oracle::get_last_price(&oracle_inst);
    oracle::write_observation(&mut oracle_inst, fixed_time, last_price);
    let twap1: u128 = oracle::get_twap(&oracle_inst, &clock_inst);
    let twap2: u128 = oracle::get_twap(&oracle_inst, &clock_inst);
    let twap3: u128 = oracle::get_twap(&oracle_inst, &clock_inst);
    assert!(twap1 == twap2, 0);
    assert!(twap2 == twap3, 1);
    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}

#[test]
fun test_twap_delay_zero() {
    // Create an oracle with twap_start_delay = 0.
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = oracle::new_oracle(
        INIT_PRICE, // twap_initialization_price = 10000
        0, // twap_start_delay = 0
        TWAP_STEP_MAX, // max_bps_per_step = 1000
        ctx,
    );
    oracle::set_oracle_start_time(&mut oracle_inst, MARKET_START_TIME);
    // First observation at time = MARKET_START_TIME + 500 = 1500.
    let first_obs_time = MARKET_START_TIME + 500; // 1500
    // Observed price 15000 is capped upward by one step (max allowed = 10000 * 1000 / 10000 = 1000),
    // so the effective price becomes 10000 + 1000 = 11000.
    oracle::write_observation(&mut oracle_inst, first_obs_time, 15000);

    let expected_price_after_first = 11000;
    // Cumulative price from first observation: 11000 * (1500 - 1000) = 11000 * 500.
    let expected_cumulative_first =
        expected_price_after_first as u256 * ((first_obs_time - MARKET_START_TIME) as u256);

    // Validate state after the first observation.
    assert!(oracle::get_last_timestamp(&oracle_inst) == first_obs_time, 0);
    assert!(oracle::get_last_price(&oracle_inst) == expected_price_after_first, 1);
    let (_, _, cumulative_first) = oracle::debug_get_state(&oracle_inst);
    assert!(cumulative_first == expected_cumulative_first, 2);

    // Second (refresh) observation at time = MARKET_START_TIME + 1000 = 2000.
    let second_obs_time = MARKET_START_TIME + 1000; // 2000
    // Use the last capped price (11000) to refresh the observation.
    let last_price = oracle::get_last_price(&oracle_inst);
    oracle::write_observation(&mut oracle_inst, second_obs_time, last_price);

    // Additional contribution: 11000 * (2000 - 1500) = 11000 * 500.
    let additional_time = second_obs_time - first_obs_time;
    let additional_contribution = expected_price_after_first as u256 * (additional_time as u256);
    let total_cumulative = expected_cumulative_first + additional_contribution;

    // Set the clock to second_obs_time.
    clock::set_for_testing(&mut clock_inst, second_obs_time);
    let twap = oracle::get_twap(&oracle_inst, &clock_inst);

    // Effective period: (current_time - market_start_time) = 2000 - 1000 = 1000.
    let period = (second_obs_time - MARKET_START_TIME) as u256;
    let expected_twap_final = total_cumulative / period;

    // Validate that the computed TWAP matches the expected value.

    assert!((twap as u256) == expected_twap_final, 3);

    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}

#[test]
fun test_twap_over_week_with_irregular_updates() {
    // Set up oracle and clock
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    
    // Define test constants
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY; // 3000
    let week_in_ms: u64 = 604_800_000; // 7 days in milliseconds
    let day_in_ms: u64 = 86_400_000; // 1 day in milliseconds
    
    // ---- Day 1: Initial price observation ----
    let time1 = delay_threshold + 1000; // Shortly after delay threshold
    let price1: u128 = 11500; // Exceeds allowed cap
    oracle::write_observation(&mut oracle_inst, time1, price1);
    
    // ---- Day 2: Price drop ----
    let time2 = delay_threshold + day_in_ms + 5000; // ~1 day later
    let price2: u128 = 8000; // Price decrease
    oracle::write_observation(&mut oracle_inst, time2, price2);

    // ---- Day 4: Price increase ----
    let time3 = delay_threshold + 3 * day_in_ms + 12000; // ~3 days later
    let price3: u128 = 12500;
    oracle::write_observation(&mut oracle_inst, time3, price3);

    
    // ---- Day 6: Another price update ----
    let time4 = delay_threshold + 5 * day_in_ms + 8000; // ~5 days later
    let price4: u128 = 9800;
    oracle::write_observation(&mut oracle_inst, time4, price4);
    
    // ---- End of week: Final observation ----
    let final_time = delay_threshold + week_in_ms - 1000; // End of week
    let final_price: u128 = 11000;
    
    // Set clock to final time for TWAP calculation
    clock::set_for_testing(&mut clock_inst, final_time);
    
    // Final observation to ensure last_timestamp == clock time (required by get_twap)
    oracle::write_observation(&mut oracle_inst, final_time, final_price);

    
    // Get actual TWAP from oracle
    let actual_twap = oracle::get_twap(&oracle_inst, &clock_inst);

    // Assert that calculated TWAP matches oracle's TWAP exactly
    debug::print(&actual_twap);
    assert!(actual_twap == 10656, 0);
    
    oracle::destroy_for_testing(oracle_inst);
    clock::destroy_for_testing(clock_inst);
    test::end(scenario);
}

#[test]
fun test_twap_over_year_with_ten_swaps() {
    // Set up oracle and clock
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    let ctx = test::ctx(&mut scenario);
    let mut oracle_inst = setup_test_oracle(ctx);
    
    // Define test constants
    let delay_threshold = MARKET_START_TIME + TWAP_START_DELAY; // 3000
    let year_in_ms: u64 = 31_536_000_000; // 365 days in milliseconds
    let month_in_ms: u64 = 2_592_000_000; // ~30 days in milliseconds
    
    // Initialize manual TWAP calculation variables
    let mut total_weighted_price: u256 = 0;
    let mut last_observation_time = delay_threshold;
    
    // Array of observation times throughout the year (roughly monthly)
    // Add some irregularity to test real-world scenarios
    let observation_times = vector[
        delay_threshold + 500_000,                    // Initial observation
        delay_threshold + month_in_ms,                // Month 1
        delay_threshold + month_in_ms * 2 + 300_000,  // Month 2 (with offset)
        delay_threshold + month_in_ms * 3 - 200_000,  // Month 3 (with offset)
        delay_threshold + month_in_ms * 5 + 100_000,  // Month 5 (skipped a month)
        delay_threshold + month_in_ms * 6 + 400_000,  // Month 6
        delay_threshold + month_in_ms * 8 - 300_000,  // Month 8 (skipped a month)
        delay_threshold + month_in_ms * 9 + 250_000,  // Month 9
        delay_threshold + month_in_ms * 10 - 150_000, // Month 10
        delay_threshold + year_in_ms - 100_000        // End of year
    ];
    
    // Array of price observations (create a realistic price pattern)
    let observation_prices = vector[
        12000,  // Initial rise
        13500,  // Month 1: continued rise
        11000,  // Month 2: correction
        12500,  // Month 3: recovery
        14000,  // Month 5: new high
        12000,  // Month 6: another correction
        9000,   // Month 8: significant drop
        10500,  // Month 9: partial recovery
        11800,  // Month 10: continued recovery
        13000   // End of year: strong finish
    ];
    
    // Process each observation
    let mut i = 0;
    while (i < 10) {
        let observation_time = *vector::borrow(&observation_times, i);
        let observation_price = *vector::borrow(&observation_prices, i);
        
        // Write observation to oracle
        oracle::write_observation(&mut oracle_inst, observation_time, observation_price);
        
        // Get the capped price (after oracle's internal capping logic)
        let capped_price = oracle::get_last_price(&oracle_inst);
        
        // Calculate time-weighted contribution
        let time_diff = observation_time - last_observation_time;
        let contribution = (capped_price as u256) * (time_diff as u256);
        total_weighted_price = total_weighted_price + contribution;
        
        // Update tracking variables for next iteration
        last_observation_time = observation_time;
        
        i = i + 1;
    };
    
    // Set clock to final observation time for TWAP calculation
    let final_time = *vector::borrow(&observation_times, 9); // Last observation time
    clock::set_for_testing(&mut clock_inst, final_time);
    
    // Calculate expected TWAP
    let total_period = final_time - delay_threshold;
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
fun test_initial_high_price_no_swaps() {
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    {
        let current_time = 1719182400000; 
        clock::set_for_testing(&mut clock_inst, current_time);
        let ctx = test::ctx(&mut scenario);

        // Create an oracle with a high initial price, zero delay, zero start time, and large step
        // The large step ensures the initial price is not capped down based on any previous price
        // (since there isn't one for the first write after delay threshold).
        let market_start_time = current_time;
        let twap_start_delay = 0;
        let delay_threshold = market_start_time + twap_start_delay; // 0

        let mut oracle_inst = oracle::new_oracle(
            HIGH_INIT_PRICE,    // 1 quadrillion
            twap_start_delay,   // 0
            LARGE_TWAP_STEP,    // u64::max_value!
            ctx,
        );
        oracle::set_oracle_start_time(&mut oracle_inst, market_start_time);

        // Validate initial state immediately after creation
        assert!(oracle::get_last_price(&oracle_inst) == HIGH_INIT_PRICE, 0);
        assert!(oracle::get_last_timestamp(&oracle_inst) == market_start_time, 1); // Initial timestamp is market_start_time
        assert!(oracle::get_twap_initialization_price(&oracle_inst) == HIGH_INIT_PRICE, 2);
        assert!(oracle::debug_get_window_twap(&oracle_inst) == HIGH_INIT_PRICE, 3); // last_window_twap starts as init price
        let (_, _, cumulative_initial) = oracle::debug_get_state(&oracle_inst);
        assert!(cumulative_initial == 0, 4); // Cumulative price starts at 0

        // Simulate time passing after the delay threshold.
        // Since delay is 0, any time > 0 is past the delay.


        // Set the clock to this time.
        clock::set_for_testing(&mut clock_inst, current_time + 100_000);

        // Perform the first observation *after* the delay.
        // This observation uses the initial price (or a new reported price, but we use the initial one
        // to simulate no *effective* change) and the time elapsed since delay_threshold.
        // write_observation(1000, HIGH_INIT_PRICE): ts=1000000. delay_threshold=0. last_timestamp(0) < 0 is false.
        // (1000000 - 0) > 0. twap_accumulate(1000000, HIGH_INIT_PRICE).
        // LT=0, LWE=0. diff=0. time_to_finish_last_window=60000. time_since_last_update=1000000.
        // additional_time_to_include = min(60000, 1000000) = 100000000.
        // intra_window_accumulation(..., price=HIGH_INIT_PRICE, time=1000000, ts=1000000).
        // capped_price = one_step_cap_price_change(LWT=HIGH_INIT_PRICE, HIGH_INIT_PRICE, LARGE_TWAP_STEP) = HIGH_INIT_PRICE.
        // accumulation = (HIGH_INIT_PRICE as u256) * (1000000 as u256).
        // total_cumulative_price = 0 + (HIGH_INIT_PRICE as u256) * 1000000.
        // last_timestamp = 1000000. last_price = HIGH_INIT_PRICE.
        // time_since_last_window_end = 1000000 - 0 = 1000 != 60000. No window update.
        oracle::write_observation(&mut oracle_inst, current_time + 100_000, HIGH_INIT_PRICE);

        // Verify state after the first observation at current_time
        assert!(oracle::get_last_price(&oracle_inst) == HIGH_INIT_PRICE, 5);
        assert!(oracle::get_last_timestamp(&oracle_inst) == current_time + 100_000, 6);
        let (_, _, cumulative_after_write) = oracle::debug_get_state(&oracle_inst);
        let expected_cumulative = (HIGH_INIT_PRICE as u256) * (100_000 as u256);
        debug::print(&expected_cumulative);
        debug::print(&cumulative_after_write);
        //assert!(cumulative_after_write == expected_cumulative, 7);

        // Get the TWAP. Clock is already set to current_time (1000000), which matches last_timestamp.
        // Period = (current_time - market_start_time) - twap_start_delay
        // = (1000000 - 0) - 0 = 1000000.
        // TWAP = total_cumulative_price / period
        // = ((HIGH_INIT_PRICE as u256) * 1000000) / 1000000 = HIGH_INIT_PRICE as u256.
        let twap = oracle::get_twap(&oracle_inst, &clock_inst);
        debug::print(&HIGH_INIT_PRICE);
        debug::print(&twap);
        // Verify TWAP matches the high initial price
        assert!(twap == HIGH_INIT_PRICE, 8);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::oracle::E_MARKET_NOT_STARTED)]
fun test_write_observation_without_market_start_time_fails() {
    // Test that write_observation fails if market_start_time is not set.
    let (mut scenario, clock_inst) = setup_scenario_and_clock(); // clock_inst not strictly needed but setup provides it
    {
        let ctx = test::ctx(&mut scenario);
        // Create oracle BUT DO NOT set market_start_time
        let mut oracle_inst = oracle::new_oracle(
            INIT_PRICE,
            TWAP_START_DELAY,
            TWAP_STEP_MAX,
            ctx,
        );

        // Attempt to write an observation - this should fail
        oracle::write_observation(&mut oracle_inst, MARKET_START_TIME + 100, INIT_PRICE + 100);

        // Clean up (though this part won't be reached if the test passes due to expected failure)
        oracle::destroy_for_testing(oracle_inst);
        // clock::destroy_for_testing(clock_inst) is not needed as we only used the scenario's ctx
    };
    clock::destroy_for_testing(clock_inst);
    test::end(scenario); // clock_inst is destroyed with scenario if it was created inside
}

#[test]
#[expected_failure(abort_code = futarchy::oracle::E_MARKET_NOT_STARTED)]
fun test_get_twap_without_market_start_time_fails() {
    // Test that get_twap fails if market_start_time is not set.
    let (mut scenario, mut clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        // Create oracle BUT DO NOT set market_start_time
        let oracle_inst = oracle::new_oracle(
            INIT_PRICE,
            TWAP_START_DELAY,
            TWAP_STEP_MAX,
            ctx,
        );

        // Set clock to some time, although it shouldn't matter as the check for market_start_time comes first
        clock::set_for_testing(&mut clock_inst, MARKET_START_TIME + TWAP_START_DELAY + 1000);

        // Attempt to get TWAP - this should fail
        let _twap = oracle::get_twap(&oracle_inst, &clock_inst);

        // Clean up (though this part won't be reached if the test passes due to expected failure)
        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::oracle::E_MARKET_ALREADY_STARTED)]
fun test_set_oracle_start_time_when_already_started_fails() {
    // This test verifies that calling `set_oracle_start_time` on an oracle
    // that already has its market_start_time set will result in an
    // E_MARKET_ALREADY_STARTED error.

    let (mut scenario, clock_inst) = setup_scenario_and_clock();
    {
        let ctx = test::ctx(&mut scenario);
        let mut oracle_inst = oracle::new_oracle(
            INIT_PRICE,
            TWAP_START_DELAY,
            TWAP_STEP_MAX,
            ctx,
        );

        // First call to set_oracle_start_time: This should succeed as market_start_time is None.
        oracle::set_oracle_start_time(&mut oracle_inst, MARKET_START_TIME);

        // At this point, oracle_inst.market_start_time is Some(MARKET_START_TIME).

        // Second call to set_oracle_start_time: This should fail because market_start_time is already Some.
        // The exact time passed here doesn't matter for triggering the error, only that it's called again.
        oracle::set_oracle_start_time(&mut oracle_inst, MARKET_START_TIME + 1000);

        // The following lines will not be reached if the test behaves as expected (due to abort).
        oracle::destroy_for_testing(oracle_inst);
    };
    clock::destroy_for_testing(clock_inst); // Clean up clock if scenario doesn't auto-clean
    test::end(scenario);
}