#[test_only]
module futarchy_markets_primitives::PCW_TWAP_oracle_tests;

use futarchy_markets_primitives::PCW_TWAP_oracle;
use sui::clock::{Self, Clock};
use sui::test_scenario;

// === Constants ===
const SCALE: u128 = 1_000_000_000_000; // 1e12
const ONE_MINUTE_MS: u64 = 60_000;
const TEN_MINUTES_MS: u64 = 600_000;
const ONE_HOUR_MS: u64 = 3_600_000;

// === Initialization Tests ===

#[test]
fun test_initialization_default() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000_000);

    let initial_price = 5 * SCALE; // $5
    let oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Verify initialization
    assert!(PCW_TWAP_oracle::last_price(&oracle) == initial_price, 0);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 1);
    assert!(PCW_TWAP_oracle::window_size_ms(&oracle) == ONE_MINUTE_MS, 2);
    assert!(PCW_TWAP_oracle::max_movement_ppm(&oracle) == 10_000, 3); // 1%

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_custom_config() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000_000);

    let initial_price = 100 * SCALE;
    let oracle = PCW_TWAP_oracle::new(
        initial_price,
        120_000, // 2 minutes
        20_000, // 2% cap
        &clock,
    );

    assert!(PCW_TWAP_oracle::window_size_ms(&oracle) == 120_000, 0);
    assert!(PCW_TWAP_oracle::max_movement_ppm(&oracle) == 20_000, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Single Window Tests ===

#[test]
fun test_single_window_no_cap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Update with stable price for 1 minute
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, initial_price, &clock);

    // TWAP should stay at initial price (no movement)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_single_window_with_cap_upward() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price spikes to $200 and stays there for 1 minute
    let new_price = 200 * SCALE;
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // TWAP should move 1% upward: $100 → $101
    let expected = 101 * SCALE;
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_single_window_with_cap_downward() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price drops to $50 and stays there for 1 minute
    let new_price = 50 * SCALE;
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // TWAP should move 1% downward: $100 → $99
    let expected = 99 * SCALE;
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_single_window_small_move_no_cap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price moves to $100.50 (0.5% move - below cap)
    let new_price = 100_500_000_000_000; // $100.50
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // TWAP should move full amount (not capped)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == new_price, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Multi-Window Tests (Key Security Property) ===

#[test]
fun test_multi_window_single_step() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price spikes to $200 and attacker holds it for 100 minutes (100 windows!)
    let new_price = 200 * SCALE;
    clock::set_for_testing(&mut clock, 100 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // CRITICAL: Should take SINGLE step, not compound 100 times
    // Expected: $100 + min($100, $1) = $101
    // NOT: $100 * 1.01^100 = $270.48 (geometric would do this)
    let expected = 101 * SCALE;
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_multi_window_gradual_approach() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let mut price = 100 * SCALE; // $100
    let mut oracle = PCW_TWAP_oracle::new_default(price, &clock);

    // Simulate legitimate price increase over time
    // Each window, price increases and TWAP follows with 1% steps

    // Window 1: Price → $105
    price = 105 * SCALE;
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, price, &clock);
    // TWAP: $100 → $101 (capped at 1%)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 101 * SCALE, 0);

    // Window 2: Price stays $105
    clock::set_for_testing(&mut clock, 2 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, price, &clock);
    // TWAP: $101 → $102.01 (1% of $101)
    let expected2 = 102_010_000_000_000;
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected2, 1);

    // Window 3: Price stays $105
    clock::set_for_testing(&mut clock, 3 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, price, &clock);
    // TWAP: $102.01 → $103.0301 (1% of $102.01)
    let expected3 = 103_030_100_000_000;
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected3, 2);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Dynamic Cap Tests ===

#[test]
fun test_dynamic_cap_grows_with_twap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // Start at $100 with 1% cap = $1 per window
    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // First window: $100 → $101 (cap = $1)
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 101 * SCALE, 0);

    // Second window: $101 → $102.01 (cap = $1.01, growing!)
    clock::set_for_testing(&mut clock, 2 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 102_010_000_000_000, 1);

    // Third window: $102.01 → $103.0301 (cap = $1.0201)
    clock::set_for_testing(&mut clock, 3 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 103_030_100_000_000, 2);

    // Cap is growing proportionally with TWAP - this is percentage-based capping!

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Edge Cases ===

#[test]
fun test_zero_elapsed_time() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 1000);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Update at same timestamp (no time elapsed)
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // TWAP should not change (no time passed)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_incomplete_window() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Update after 30 seconds (half a window)
    clock::set_for_testing(&mut clock, 30_000);
    PCW_TWAP_oracle::update(&mut oracle, 200 * SCALE, &clock);

    // No window completed - TWAP should not change
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == initial_price, 0);

    // But cumulative should be accumulating
    assert!(PCW_TWAP_oracle::get_cumulative_price(&oracle) > 0, 1);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_exact_cap_hit() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // New price is exactly 1% above (exactly at cap)
    let new_price = 101 * SCALE;
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // Should move full amount (diff = cap)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == new_price, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_price_volatility_averaging() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // Price bounces: $50 for 20s, $150 for 40s = avg $116.67
    // But time-weighted: (50*20 + 150*40) / 60 = $116.67

    // First 20 seconds at $50
    clock::set_for_testing(&mut clock, 20_000);
    PCW_TWAP_oracle::update(&mut oracle, 50 * SCALE, &clock);

    // Next 40 seconds at $150 (window completes)
    clock::set_for_testing(&mut clock, ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, 150 * SCALE, &clock);

    // Raw TWAP would be ~$117, but capped at $101 (1% move from $100)
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == 101 * SCALE, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Large Gap Tests (Gas Efficiency) ===

#[test]
fun test_very_large_time_gap() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    let initial_price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(initial_price, &clock);

    // 1000 windows pass (1000 minutes = ~16.7 hours)
    let new_price = 200 * SCALE;
    clock::set_for_testing(&mut clock, 1000 * ONE_MINUTE_MS);
    PCW_TWAP_oracle::update(&mut oracle, new_price, &clock);

    // CRITICAL: Still takes just ONE step (O(1) gas!)
    // Not 1000 steps like a naive loop would
    let expected = 101 * SCALE; // $100 → $101
    assert!(PCW_TWAP_oracle::get_twap(&oracle) == expected, 0);

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}

// === Integration Test ===

#[test]
fun test_realistic_oracle_usage() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, 0);

    // Start oracle at $100
    let mut price = 100 * SCALE;
    let mut oracle = PCW_TWAP_oracle::new_default(price, &clock);

    // Simulate 1 hour of normal trading with updates every 10 seconds
    let mut time = 0u64;
    let mut i = 0;
    while (i < 360) {
        // 360 updates = 1 hour
        time = time + 10_000; // 10 seconds

        // Price drifts slightly (±0.1% per update)
        if (i % 2 == 0) {
            price = price + (price / 1000); // +0.1%
        } else {
            price = price - (price / 1000); // -0.1%
        };

        clock::set_for_testing(&mut clock, time);
        PCW_TWAP_oracle::update(&mut oracle, price, &clock);

        i = i + 1;
    };

    // After 1 hour of small fluctuations, TWAP should be close to current price
    // but with smoothing from the 1% cap per minute
    let final_twap = PCW_TWAP_oracle::get_twap(&oracle);

    // TWAP should have moved, but be reasonably close
    assert!(final_twap > 95 * SCALE, 0); // Not too far down
    assert!(final_twap < 105 * SCALE, 1); // Not too far up

    PCW_TWAP_oracle::destroy_for_testing(oracle);
    clock::destroy_for_testing(clock);
    test_scenario::end(scenario);
}
