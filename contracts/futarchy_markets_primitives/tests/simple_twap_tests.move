#[test_only]
module futarchy_markets_primitives::simple_twap_tests;

use futarchy_markets_primitives::simple_twap;
use sui::{
    clock::{Self, Clock},
    test_utils::destroy,
    test_scenario as ts,
};

// === Constants ===

const NINETY_DAYS_MS: u64 = 7_776_000_000; // 90 days
const ONE_DAY_MS: u64 = 86_400_000; // 1 day
const ONE_HOUR_MS: u64 = 3_600_000; // 1 hour
const PRICE_SCALE: u128 = 1_000_000_000_000; // 10^12

// === Basic Tests ===

#[test]
fun test_new_oracle() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let oracle = simple_twap::new(initial_price, &clock);

    // Verify initial state
    assert!(simple_twap::last_price(&oracle) == initial_price, 0);
    assert!(simple_twap::last_timestamp(&oracle) == 1000, 1);
    assert!(simple_twap::initialized_at(&oracle) == 1000, 2);
    assert!(simple_twap::window_start(&oracle) == 1000, 3);
    assert!(simple_twap::window_cumulative_price(&oracle) == 0, 4);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_get_spot_price() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let oracle = simple_twap::new(initial_price, &clock);

    assert!(simple_twap::get_spot_price(&oracle) == initial_price, 0);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_update_price() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Update after 1 hour
    clock.set_for_testing(1000 + ONE_HOUR_MS);
    let new_price = 6000 * PRICE_SCALE;
    simple_twap::update(&mut oracle, new_price, &clock);

    // Verify price updated
    assert!(simple_twap::last_price(&oracle) == new_price, 0);
    assert!(simple_twap::last_timestamp(&oracle) == 1000 + ONE_HOUR_MS, 1);

    // Verify cumulative increased
    assert!(simple_twap::window_cumulative_price(&oracle) > 0, 2);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_update_no_time_elapsed() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    let cumulative_before = simple_twap::window_cumulative_price(&oracle);

    // Update at same timestamp - should be no-op
    simple_twap::update(&mut oracle, 6000 * PRICE_SCALE, &clock);

    // Verify no change
    assert!(simple_twap::window_cumulative_price(&oracle) == cumulative_before, 0);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_is_ready_before_90_days() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let oracle = simple_twap::new(5000 * PRICE_SCALE, &clock);

    // Not ready yet
    assert!(!simple_twap::is_ready(&oracle, &clock), 0);

    // Advance 89 days - still not ready
    clock.set_for_testing(1000 + NINETY_DAYS_MS - ONE_DAY_MS);
    assert!(!simple_twap::is_ready(&oracle, &clock), 1);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_is_ready_after_90_days() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let oracle = simple_twap::new(5000 * PRICE_SCALE, &clock);

    // Advance exactly 90 days
    clock.set_for_testing(1000 + NINETY_DAYS_MS);
    assert!(simple_twap::is_ready(&oracle, &clock), 0);

    // Advance 91 days - still ready
    clock.set_for_testing(1000 + NINETY_DAYS_MS + ONE_DAY_MS);
    assert!(simple_twap::is_ready(&oracle, &clock), 1);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = simple_twap::ETwapNotReady)]
fun test_get_twap_before_90_days_fails() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let oracle = simple_twap::new(5000 * PRICE_SCALE, &clock);

    // Try to get TWAP before 90 days - should fail
    let _twap = simple_twap::get_twap(&oracle, &clock);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_get_twap_after_90_days() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Update periodically over 90 days
    let mut time = 1000;
    let mut i = 0;
    while (i < 90) {
        time = time + ONE_DAY_MS;
        clock.set_for_testing(time);
        simple_twap::update(&mut oracle, initial_price, &clock);
        i = i + 1;
    };

    // Get TWAP after 90 days
    let twap = simple_twap::get_twap(&oracle, &clock);

    // Should be close to initial price (constant price)
    assert!(twap == initial_price, 0);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_twap_reflects_price_changes() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // First 45 days at 5000
    let mut time = 1000;
    let mut i = 0;
    while (i < 45) {
        time = time + ONE_DAY_MS;
        clock.set_for_testing(time);
        simple_twap::update(&mut oracle, 5000 * PRICE_SCALE, &clock);
        i = i + 1;
    };

    // Next 45 days at 10000
    i = 0;
    while (i < 45) {
        time = time + ONE_DAY_MS;
        clock.set_for_testing(time);
        simple_twap::update(&mut oracle, 10000 * PRICE_SCALE, &clock);
        i = i + 1;
    };

    // TWAP should be average: (5000 * 45 + 10000 * 45) / 90 = 7500
    let twap = simple_twap::get_twap(&oracle, &clock);
    let expected_twap = 7500 * PRICE_SCALE;

    // Allow 1% deviation due to rounding
    let diff = if (twap > expected_twap) {
        twap - expected_twap
    } else {
        expected_twap - twap
    };
    assert!(diff < expected_twap / 100, 0);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

// === Cumulative Tests (Uniswap V2 Style) ===

#[test]
fun test_get_cumulative_and_timestamp() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Get initial cumulative
    let (cumulative_0, timestamp_0) = simple_twap::get_cumulative_and_timestamp(&oracle);
    assert!(cumulative_0 == 0, 0);
    assert!(timestamp_0 == 1000, 1);

    // Update after 1 hour
    clock.set_for_testing(1000 + ONE_HOUR_MS);
    simple_twap::update(&mut oracle, 6000 * PRICE_SCALE, &clock);

    // Get cumulative after update
    let (cumulative_1, timestamp_1) = simple_twap::get_cumulative_and_timestamp(&oracle);
    assert!(cumulative_1 > cumulative_0, 2);
    assert!(timestamp_1 == 1000 + ONE_HOUR_MS, 3);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_cumulative_never_resets() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Update over more than 90 days
    let mut time = 1000;
    let mut i = 0;
    while (i < 100) { // 100 days
        time = time + ONE_DAY_MS;
        clock.set_for_testing(time);
        simple_twap::update(&mut oracle, initial_price, &clock);
        i = i + 1;
    };

    // Cumulative should be very large (never resets)
    let (cumulative, _) = simple_twap::get_cumulative_and_timestamp(&oracle);
    assert!(cumulative > 0, 0);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

// === Rolling Window Tests ===

#[test]
fun test_window_slides_after_90_days() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    let initial_window_start = simple_twap::window_start(&oracle);

    // Update at 91 days - window should slide
    clock.set_for_testing(1000 + NINETY_DAYS_MS + ONE_DAY_MS);
    simple_twap::update(&mut oracle, 5000 * PRICE_SCALE, &clock);

    let new_window_start = simple_twap::window_start(&oracle);

    // Window start should have moved forward
    assert!(new_window_start > initial_window_start, 0);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_window_doesnt_slide_before_90_days() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    let initial_window_start = simple_twap::window_start(&oracle);

    // Update at 89 days - window should NOT slide
    clock.set_for_testing(1000 + NINETY_DAYS_MS - ONE_DAY_MS);
    simple_twap::update(&mut oracle, 5000 * PRICE_SCALE, &clock);

    let window_start = simple_twap::window_start(&oracle);

    // Window start should be unchanged
    assert!(window_start == initial_window_start, 0);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

// === Backfill Tests ===

#[test]
fun test_backfill_from_conditional() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Simulate proposal period (7 days)
    let period_start = 1000;
    let period_end = 1000 + (7 * ONE_DAY_MS);
    let period_cumulative = (6000 * PRICE_SCALE as u256) * (7 * ONE_DAY_MS as u256);
    let period_final_price = 6000 * PRICE_SCALE;

    // Backfill conditional data
    simple_twap::backfill_from_conditional(
        &mut oracle,
        period_start,
        period_end,
        period_cumulative,
        period_final_price
    );

    // Verify state updated
    assert!(simple_twap::last_price(&oracle) == period_final_price, 0);
    assert!(simple_twap::last_timestamp(&oracle) == period_end, 1);
    assert!(simple_twap::window_cumulative_price(&oracle) == period_cumulative, 2);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = simple_twap::EBackfillMismatch)]
fun test_backfill_misaligned_period_fails() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Try to backfill with misaligned period_start
    let wrong_start = 2000; // Doesn't match last_timestamp (1000)
    let period_end = 3000;
    let period_cumulative = (6000 * PRICE_SCALE as u256) * (1000 as u256);
    let period_final_price = 6000 * PRICE_SCALE;

    simple_twap::backfill_from_conditional(
        &mut oracle,
        wrong_start,
        period_end,
        period_cumulative,
        period_final_price
    );

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = simple_twap::EInvalidPeriod)]
fun test_backfill_invalid_period_fails() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Try to backfill with period_end <= period_start
    simple_twap::backfill_from_conditional(
        &mut oracle,
        1000,
        1000, // Same as period_start
        1000,
        5000 * PRICE_SCALE
    );

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = simple_twap::EPriceDeviationTooLarge)]
fun test_backfill_large_price_deviation_fails() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Try to backfill with price 101x higher (exceeds MAX_PRICE_DEVIATION_RATIO = 100)
    let period_cumulative = (510000 * PRICE_SCALE as u256) * (ONE_DAY_MS as u256);
    let period_final_price = 510000 * PRICE_SCALE; // 102x initial (5000 * 102 = 510000)

    simple_twap::backfill_from_conditional(
        &mut oracle,
        1000,
        1000 + ONE_DAY_MS,
        period_cumulative,
        period_final_price
    );

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

// === Safety Function Tests ===

#[test]
fun test_safe_mul_u256_basic() {
    let a: u256 = 1000;
    let b: u256 = 2000;

    let result = simple_twap::safe_mul_u256(a, b);
    assert!(result == 2_000_000, 0);
}

#[test]
fun test_safe_mul_u256_zero() {
    let result1 = simple_twap::safe_mul_u256(0, 1000);
    let result2 = simple_twap::safe_mul_u256(1000, 0);

    assert!(result1 == 0, 0);
    assert!(result2 == 0, 1);
}

#[test]
fun test_safe_mul_u256_large_numbers() {
    let a: u256 = 1000000000000;
    let b: u256 = 1000000000000;

    let result = simple_twap::safe_mul_u256(a, b);
    assert!(result == 1000000000000000000000000, 0);
}

// === Projected Cumulative Tests ===

#[test]
fun test_projected_cumulative_to() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Update after 1 hour
    clock.set_for_testing(1000 + ONE_HOUR_MS);
    simple_twap::update(&mut oracle, 6000 * PRICE_SCALE, &clock);

    // Project cumulative 1 hour into future
    let target_time = 1000 + (2 * ONE_HOUR_MS);
    let projected = simple_twap::projected_cumulative_to(&oracle, target_time);

    // Should be greater than current cumulative
    assert!(projected > simple_twap::window_cumulative_price(&oracle), 0);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

// === Getter Tests ===

#[test]
fun test_all_getters() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(1000);

    let initial_price = 5000 * PRICE_SCALE;
    let oracle = simple_twap::new(initial_price, &clock);

    // Test all getter functions
    assert!(simple_twap::last_price(&oracle) == initial_price, 0);
    assert!(simple_twap::last_timestamp(&oracle) == 1000, 1);
    assert!(simple_twap::initialized_at(&oracle) == 1000, 2);
    assert!(simple_twap::window_start(&oracle) == 1000, 3);
    assert!(simple_twap::window_start_timestamp(&oracle) == 1000, 4);
    assert!(simple_twap::window_cumulative_price(&oracle) == 0, 5);

    let (cumulative, timestamp) = simple_twap::get_cumulative_and_timestamp(&oracle);
    assert!(cumulative == 0, 6);
    assert!(timestamp == 1000, 7);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

// === Realistic Scenario Tests ===

#[test]
fun test_realistic_price_updates() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(0);

    // Start at $100 (in PRICE_SCALE units)
    let mut oracle = simple_twap::new(100 * PRICE_SCALE, &clock);

    // Simulate 7-day price movement
    let prices = vector[
        100 * PRICE_SCALE,
        105 * PRICE_SCALE,
        103 * PRICE_SCALE,
        108 * PRICE_SCALE,
        110 * PRICE_SCALE,
        107 * PRICE_SCALE,
        109 * PRICE_SCALE,
    ];

    let mut i = 0;
    while (i < prices.length()) {
        let time = i * ONE_DAY_MS;
        clock.set_for_testing(time);
        simple_twap::update(&mut oracle, prices[i], &clock);
        i = i + 1;
    };

    // Verify oracle state
    assert!(simple_twap::last_price(&oracle) == 109 * PRICE_SCALE, 0);
    assert!(simple_twap::window_cumulative_price(&oracle) > 0, 1);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_long_duration_twap() {
    let mut scenario = ts::begin(@0x0);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock.set_for_testing(0);

    let initial_price = 5000 * PRICE_SCALE;
    let mut oracle = simple_twap::new(initial_price, &clock);

    // Update daily for 100 days
    let mut i = 0;
    while (i < 100) {
        let time = i * ONE_DAY_MS;
        clock.set_for_testing(time);
        simple_twap::update(&mut oracle, initial_price, &clock);
        i = i + 1;
    };

    // After 100 days, TWAP should be available
    assert!(simple_twap::is_ready(&oracle, &clock), 0);
    let twap = simple_twap::get_twap(&oracle, &clock);

    // TWAP should equal constant price
    assert!(twap == initial_price, 1);

    simple_twap::destroy_for_testing(oracle);
    destroy(clock);
    ts::end(scenario);
}
