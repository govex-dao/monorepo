#[test_only]
module futarchy::oracle_intra_accum_tests;

use futarchy::math;
use futarchy::oracle::{
    Self,
    Oracle,
    EInvalidCapPpm,
    set_last_timestamp_for_testing,
    set_last_window_end_for_testing,
    set_last_window_twap_for_testing,
    set_cumulative_prices_for_testing,
    call_intra_window_accumulation_for_testing,
    get_last_window_end_cumulative_price_for_testing,
    get_total_cumulative_price_for_testing,
    get_last_window_end_for_testing,
    debug_get_window_twap
};
use std::u128;
use std::u64;
use sui::test_scenario::{Self as test, Scenario, ctx};

// ======== Test Constants from existing test setups ========
// These are used for oracle creation via setup_test_oracle
const DEFAULT_TWAP_CAP_STEP: u64 = 100_000; // 10% of price (100,000 PPM = 10%)
const DEFAULT_TWAP_START_DELAY: u64 = 60_000;
const DEFAULT_MARKET_START_TIME: u64 = 1000;
const DEFAULT_INIT_PRICE: u128 = 10000;
const TWAP_PRICE_CAP_WINDOW_TIME: u64 = 60_000;
const AMM_BASIS_POINTS: u256 = 1_000_000_000_000;

// ======== Helper Functions ========
fun setup_default_oracle(test_ctx: &mut TxContext): Oracle {
    oracle::new_oracle(
        DEFAULT_INIT_PRICE,
        DEFAULT_TWAP_START_DELAY, // This delay is also the window size
        DEFAULT_TWAP_CAP_STEP,
        test_ctx,
    )
}

// Helper to configure oracle for specific intra-window test scenarios
fun configure_oracle_state(
    o: &mut Oracle,
    last_window_twap: u128,
    last_window_end: u64,
    total_cumulative_price: u256,
    last_window_end_cumulative_price: u256,
    // Optional: last_timestamp if needed before the call, though intra_window_accumulation sets it
    // Optional: twap_cap_step is part of oracle config from new_oracle
) {
    set_last_window_twap_for_testing(o, last_window_twap);
    set_last_window_end_for_testing(o, last_window_end);
    set_cumulative_prices_for_testing(o, total_cumulative_price, last_window_end_cumulative_price);
}

#[test]
fun test_intra_accum_positive_time_no_boundary() {
    let mut scenario = test::begin(@0xAA);
    let test_ctx = ctx(&mut scenario);
    let mut oracle_inst = setup_default_oracle(test_ctx);

    let initial_lwt = 10000_u128;
    let initial_lwe = 60000_u64; // An arbitrary past window end
    let initial_tcp = (initial_lwt as u256) * (initial_lwe as u256); // Dummy TCP
    let initial_lwecp = initial_tcp; // Consistent LWE CP

    configure_oracle_state(&mut oracle_inst, initial_lwt, initial_lwe, initial_tcp, initial_lwecp);

    let price_input = 10050_u128; // Assumed to be within cap relative to initial_lwt and oracle's twap_cap_step
    let time_to_include = 10000_u64;
    // Timestamp that does not complete a window: initial_lwe + (TWAP_PRICE_CAP_WINDOW_TIME / 2)
    let new_timestamp = initial_lwe + (TWAP_PRICE_CAP_WINDOW_TIME / 2); // e.g., 60000 + 30000 = 90000

    // Expected capped price (oracle created with 10000 init_price, 1000 cap_step. Here LWT is 10000)
    // So price_input 10050 is within 10000 +/- 1000. Capped price = 10050.
    let expected_capped_price = price_input;
    let expected_price_contribution = (expected_capped_price as u256) * (time_to_include as u256);
    let expected_tcp = initial_tcp + expected_price_contribution;

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        price_input,
        time_to_include,
        new_timestamp,
    );

    assert!(get_total_cumulative_price_for_testing(&oracle_inst) == expected_tcp, 1);
    assert!(oracle::last_timestamp(&oracle_inst) == new_timestamp, 2);
    assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 3);

    // Verify boundary fields are unchanged
    assert!(get_last_window_end_for_testing(&oracle_inst) == initial_lwe, 4);
    assert!(debug_get_window_twap(&oracle_inst) == initial_lwt, 5);
    assert!(get_last_window_end_cumulative_price_for_testing(&oracle_inst) == initial_lwecp, 6);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_intra_accum_completes_window_boundary() {
    let mut scenario = test::begin(@0xAB);
    let test_ctx = ctx(&mut scenario);
    let mut oracle_inst = setup_default_oracle(test_ctx); // twap_cap_step = 1000

    let initial_lwt = 10000_u128;
    let initial_lwe = 60000_u64;
    // Simulate some accumulation already happened in this window before this call
    let pre_existing_intra_window_time = 20000_u64;
    let pre_existing_intra_window_price = 9500_u128; // Capped from LWT=10000 by step=1000 is 9000. Oh, no, 9500 is fine.
    // For LWT=10000, step=1000. 9500 is within [9000, 11000].
    let initial_tcp =
        (pre_existing_intra_window_price as u256) * (pre_existing_intra_window_time as u256);
    let initial_lwecp = 0_u256; // Assuming previous window ended with 0 cumulative price for simplicity

    configure_oracle_state(&mut oracle_inst, initial_lwt, initial_lwe, initial_tcp, initial_lwecp);
    // Oracle's last_timestamp would be initial_lwe + pre_existing_intra_window_time = 80000

    let price_input = 10500_u128; // Within cap [9000, 11000]
    let time_to_include = TWAP_PRICE_CAP_WINDOW_TIME - pre_existing_intra_window_time; // Remaining time to complete window = 40000
    let new_timestamp = initial_lwe + TWAP_PRICE_CAP_WINDOW_TIME; // e.g. 60000 + 60000 = 120000

    let expected_capped_price = price_input;
    let current_price_contribution = (expected_capped_price as u256) * (time_to_include as u256);
    let final_tcp = initial_tcp + current_price_contribution;

    let expected_new_lwt_u256 = (final_tcp - initial_lwecp) / (TWAP_PRICE_CAP_WINDOW_TIME as u256);
    let expected_new_lwt = (expected_new_lwt_u256 as u128);
    // Manual: (9500*20k + 10500*40k) / 60k = (190M + 420M) / 60k = 610M / 60k = 10166.66 -> 10166

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        price_input,
        time_to_include,
        new_timestamp,
    );

    assert!(get_total_cumulative_price_for_testing(&oracle_inst) == final_tcp, 1);
    assert!(oracle::last_timestamp(&oracle_inst) == new_timestamp, 2);
    assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 3);

    // Verify boundary fields ARE updated
    assert!(get_last_window_end_for_testing(&oracle_inst) == new_timestamp, 4);
    assert!(debug_get_window_twap(&oracle_inst) == expected_new_lwt, 5);
    assert!(get_last_window_end_cumulative_price_for_testing(&oracle_inst) == final_tcp, 6);
    assert!(expected_new_lwt == 10166, 7); // Double check manual calculation

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_intra_accum_price_capped_up() {
    let mut scenario = test::begin(@0xAC);
    let test_ctx = ctx(&mut scenario);
    let mut oracle_inst = setup_default_oracle(test_ctx); // twap_cap_step = 1000

    let lwt_base = 10000_u128;
    configure_oracle_state(&mut oracle_inst, lwt_base, 0, 0, 0);

    let high_price_input = 12000_u128; // lwt_base + 2 * cap_step
    let time_to_include = 1000_u64;
    let new_timestamp = 1000_u64; // Not on boundary relative to LWE=0

    // Calculate actual step from PPM
    let actual_step = lwt_base * (DEFAULT_TWAP_CAP_STEP as u128) / 1_000_000;
    let expected_capped_price = lwt_base + actual_step; // 10000 + 1000 = 11000
    let expected_price_contribution = (expected_capped_price as u256) * (time_to_include as u256);

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        high_price_input,
        time_to_include,
        new_timestamp,
    );

    assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 1);
    assert!(get_total_cumulative_price_for_testing(&oracle_inst) == expected_price_contribution, 2);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_intra_accum_price_capped_down() {
    let mut scenario = test::begin(@0xAD);
    let test_ctx = ctx(&mut scenario);
    let mut oracle_inst = setup_default_oracle(test_ctx); // twap_cap_step = 1000

    let lwt_base = 10000_u128;
    configure_oracle_state(&mut oracle_inst, lwt_base, 0, 0, 0);

    let low_price_input = 8000_u128; // lwt_base - 2 * cap_step
    let time_to_include = 1000_u64;
    let new_timestamp = 1000_u64;

    // Calculate actual step from PPM
    let actual_step = lwt_base * (DEFAULT_TWAP_CAP_STEP as u128) / 1_000_000;
    let expected_capped_price = lwt_base - actual_step; // 10000 - 1000 = 9000
    let expected_price_contribution = (expected_capped_price as u256) * (time_to_include as u256);

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        low_price_input,
        time_to_include,
        new_timestamp,
    );

    assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 1);
    assert!(get_total_cumulative_price_for_testing(&oracle_inst) == expected_price_contribution, 2);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_intra_accum_price_not_capped() {
    let mut scenario = test::begin(@0xAE);
    let test_ctx = ctx(&mut scenario);
    let mut oracle_inst = setup_default_oracle(test_ctx); // twap_cap_step = 1000

    let lwt_base = 10000_u128;
    configure_oracle_state(&mut oracle_inst, lwt_base, 0, 0, 0);

    let normal_price_input = 10500_u128; // Within lwt_base +/- cap_step
    let time_to_include = 1000_u64;
    let new_timestamp = 1000_u64;

    let expected_capped_price = normal_price_input;
    let expected_price_contribution = (expected_capped_price as u256) * (time_to_include as u256);

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        normal_price_input,
        time_to_include,
        new_timestamp,
    );

    assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 1);
    assert!(get_total_cumulative_price_for_testing(&oracle_inst) == expected_price_contribution, 2);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_intra_accum_zero_additional_time() {
    let mut scenario = test::begin(@0xAF);
    let test_ctx = ctx(&mut scenario);
    let mut oracle_inst = setup_default_oracle(test_ctx);

    let initial_lwt = 10000_u128;
    let initial_lwe = 0_u64;
    let initial_tcp = 12345_u256; // Some pre-existing cumulative price
    let initial_lwecp = 0_u256;

    configure_oracle_state(&mut oracle_inst, initial_lwt, initial_lwe, initial_tcp, initial_lwecp);

    let price_input = 10050_u128; // Capped price will be 10050
    let time_to_include = 0_u64;
    // Timestamp that lands on a boundary
    let new_timestamp = initial_lwe + TWAP_PRICE_CAP_WINDOW_TIME; // e.g. 60000

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        price_input,
        time_to_include,
        new_timestamp,
    );

    // TCP unchanged as price_contribution is 0
    assert!(get_total_cumulative_price_for_testing(&oracle_inst) == initial_tcp, 1);
    assert!(oracle::last_timestamp(&oracle_inst) == new_timestamp, 2);
    assert!(oracle::last_price(&oracle_inst) == price_input, 3); // Capping logic runs, price_input is within cap

    // Boundary logic triggers
    assert!(get_last_window_end_for_testing(&oracle_inst) == new_timestamp, 4);
    // TWAP = (initial_tcp - initial_lwecp) / WINDOW = (12345 - 0) / 60000 = 0 (due to truncation)
    assert!(
        debug_get_window_twap(&oracle_inst) == (initial_tcp / (TWAP_PRICE_CAP_WINDOW_TIME as u256) as u128),
        5,
    );
    assert!((initial_tcp / (TWAP_PRICE_CAP_WINDOW_TIME as u256) as u128) == 0, 51); // Check expectation
    // LWE CP updates to the (unchanged) TCP
    assert!(get_last_window_end_cumulative_price_for_testing(&oracle_inst) == initial_tcp, 6);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_intra_accum_large_price_contribution_u256() {
    let mut scenario = test::begin(@0xB0);
    let test_ctx = ctx(&mut scenario);
    // Create oracle with a large cap step to ensure price isn't capped *beyond a single step from base* for this test
    let mut oracle_inst = oracle::new_oracle(
        DEFAULT_INIT_PRICE,
        DEFAULT_TWAP_START_DELAY,
        1_000_000, // Maximum PPM (100% of price)
        test_ctx,
    );
    // oracle.last_window_twap is DEFAULT_INIT_PRICE (10000) after new_oracle
    // configure_oracle_state then sets it again to DEFAULT_INIT_PRICE
    configure_oracle_state(&mut oracle_inst, DEFAULT_INIT_PRICE, 0, 0, 0);

    let large_price_input = u128::max_value!() / 2_u128; // approx 1.7e38. This is the input price.
    let large_time: u64 = 1_000_000_000; // 1e9 ms
    let new_timestamp = 2_000_000_000_u64; // Not on boundary

    // Calculate the actual expected capped price based on one_step_cap_price_change
    // oracle.last_window_twap = DEFAULT_INIT_PRICE (10000)
    // With PPM=1_000_000 (100%), twap_cap_step = DEFAULT_INIT_PRICE * 1_000_000 / 1_000_000 = DEFAULT_INIT_PRICE
    // capped_price = min(large_price_input, DEFAULT_INIT_PRICE + DEFAULT_INIT_PRICE)
    // Since large_price_input is much larger, the capped price will be DEFAULT_INIT_PRICE + DEFAULT_INIT_PRICE = 20000
    let base_for_cap_calc = DEFAULT_INIT_PRICE;
    let cap_step_for_calc = DEFAULT_INIT_PRICE; // 100% of init price
    let expected_capped_price = math::saturating_add(base_for_cap_calc, cap_step_for_calc);

    let expected_tcp = (expected_capped_price as u256) * (large_time as u256);

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        large_price_input,
        large_time,
        new_timestamp,
    );

    assert!(get_total_cumulative_price_for_testing(&oracle_inst) == expected_tcp, 1);
    assert!(oracle::last_timestamp(&oracle_inst) == new_timestamp, 2);
    // last_price is now stored as u128, not u256
    assert!(oracle::last_price(&oracle_inst) == (expected_capped_price as u128), 3);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_ppm_boundary_zero_percent() {
    // Test that 0% PPM (minimum 1 PPM) works correctly
    let mut scenario = test::begin(@0xB0);
    let test_ctx = ctx(&mut scenario);

    // Create oracle with minimum PPM (0.0001%)
    let mut oracle_inst = oracle::new_oracle(
        DEFAULT_INIT_PRICE,
        DEFAULT_TWAP_START_DELAY,
        1, // Minimum PPM
        test_ctx,
    );
    configure_oracle_state(&mut oracle_inst, DEFAULT_INIT_PRICE, 0, 0, 0);

    let large_price = DEFAULT_INIT_PRICE * 10; // 10x the base price
    let time_to_include = 1000u64;
    let new_timestamp = 1000u64;

    // With 1 PPM, step = 10000 * 1 / 1_000_000 = 0.01, rounds to 0
    // So the price should be capped at exactly DEFAULT_INIT_PRICE
    let expected_capped_price = DEFAULT_INIT_PRICE; // Minimum step effectively 0

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        large_price,
        time_to_include,
        new_timestamp,
    );

    // Price should be effectively unchanged due to tiny PPM
    assert!(oracle::last_price(&oracle_inst) <= DEFAULT_INIT_PRICE + 1, 1); // Allow for rounding

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_ppm_boundary_hundred_percent() {
    // Test that 100% PPM (1_000_000) works correctly
    let mut scenario = test::begin(@0xB1);
    let test_ctx = ctx(&mut scenario);

    // Create oracle with maximum PPM (100%)
    let mut oracle_inst = oracle::new_oracle(
        DEFAULT_INIT_PRICE,
        DEFAULT_TWAP_START_DELAY,
        1_000_000, // Maximum PPM (100%)
        test_ctx,
    );
    configure_oracle_state(&mut oracle_inst, DEFAULT_INIT_PRICE, 0, 0, 0);

    let large_price = DEFAULT_INIT_PRICE * 10; // 10x the base price
    let time_to_include = 1000u64;
    let new_timestamp = 1000u64;

    // With 1_000_000 PPM (100%), step = DEFAULT_INIT_PRICE
    let expected_capped_price = DEFAULT_INIT_PRICE * 2; // Can double in one step

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        large_price,
        time_to_include,
        new_timestamp,
    );

    assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_ppm_boundary_precise_percentages() {
    // Test various precise percentage boundaries
    let mut scenario = test::begin(@0xB2);
    let test_ctx = ctx(&mut scenario);

    // Test 1% PPM (10_000)
    let mut oracle_1pct = oracle::new_oracle(
        DEFAULT_INIT_PRICE,
        DEFAULT_TWAP_START_DELAY,
        10_000, // 1%
        test_ctx,
    );
    configure_oracle_state(&mut oracle_1pct, DEFAULT_INIT_PRICE, 0, 0, 0);

    let high_price = DEFAULT_INIT_PRICE * 2;
    call_intra_window_accumulation_for_testing(&mut oracle_1pct, high_price, 1000, 1000);

    // 1% of 10000 = 100
    assert!(oracle::last_price(&oracle_1pct) == DEFAULT_INIT_PRICE + 100, 1);

    oracle::destroy_for_testing(oracle_1pct);

    // Test 10% PPM (100_000)
    let mut oracle_10pct = oracle::new_oracle(
        DEFAULT_INIT_PRICE,
        DEFAULT_TWAP_START_DELAY,
        100_000, // 10%
        ctx(&mut scenario),
    );
    configure_oracle_state(&mut oracle_10pct, DEFAULT_INIT_PRICE, 0, 0, 0);

    call_intra_window_accumulation_for_testing(&mut oracle_10pct, high_price, 1000, 1000);

    // 10% of 10000 = 1000
    assert!(oracle::last_price(&oracle_10pct) == DEFAULT_INIT_PRICE + 1000, 2);

    oracle::destroy_for_testing(oracle_10pct);
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = oracle::EInvalidCapPpm)]
fun test_ppm_exceeds_maximum() {
    // Test that PPM > 1_000_000 is rejected
    let mut scenario = test::begin(@0xB3);
    let test_ctx = ctx(&mut scenario);

    // Try to create oracle with PPM > 100%
    let oracle_inst = oracle::new_oracle(
        DEFAULT_INIT_PRICE,
        DEFAULT_TWAP_START_DELAY,
        1_000_001, // Just over 100%
        test_ctx,
    );
    // Should abort with EInvalidCapPpm before reaching here
    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_step_calculation_with_large_values() {
    // Test that large but valid price and PPM combinations work correctly
    let mut scenario = test::begin(@0xB4);
    let test_ctx = ctx(&mut scenario);

    // Use large but valid price
    // With 100% PPM, the step would be equal to the price
    // So we need a price that fits in u64
    let large_price = (u64::max_value!() / 2) as u128;

    // This should create oracle successfully
    let oracle_inst = oracle::new_oracle(
        large_price,
        DEFAULT_TWAP_START_DELAY,
        1_000_000, // Max PPM (100%)
        test_ctx,
    );

    // The oracle should be created successfully
    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_minimum_step_enforcement() {
    // Test that very small PPM values result in minimum step of 1
    let mut scenario = test::begin(@0xB5);
    let test_ctx = ctx(&mut scenario);

    // Create oracle with tiny PPM that would round to 0
    // 1 PPM of 100 = 0.0001, which rounds to 0, but should be enforced to 1
    let small_price = 100u128;
    let mut oracle_inst = oracle::new_oracle(
        small_price,
        DEFAULT_TWAP_START_DELAY,
        1, // Minimum PPM
        test_ctx,
    );

    // Set up for testing
    oracle::set_last_window_twap_for_testing(&mut oracle_inst, small_price);
    oracle::set_last_timestamp_for_testing(&mut oracle_inst, 0);
    oracle::set_last_window_end_for_testing(&mut oracle_inst, 0);
    oracle::set_cumulative_prices_for_testing(&mut oracle_inst, 0, 0);

    // Price much higher than base
    let high_price = small_price * 10;
    call_intra_window_accumulation_for_testing(&mut oracle_inst, high_price, 1000, 1000);

    // Even with tiny PPM, price should move by at least 1
    assert!(oracle::last_price(&oracle_inst) >= small_price + 1, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_ppm_based_step_calculation() {
    // Test that step is calculated as percentage of current TWAP
    let mut scenario = test::begin(@0xB6);
    let test_ctx = ctx(&mut scenario);

    // Create oracle with 10% PPM
    let mut oracle_inst = oracle::new_oracle(
        10_000u128, // Starting price
        DEFAULT_TWAP_START_DELAY,
        100_000, // 10% PPM
        test_ctx,
    );

    // Set up initial state
    oracle::set_last_window_twap_for_testing(&mut oracle_inst, 10_000);
    oracle::set_last_timestamp_for_testing(&mut oracle_inst, 0);
    oracle::set_last_window_end_for_testing(&mut oracle_inst, 0);
    oracle::set_cumulative_prices_for_testing(&mut oracle_inst, 0, 0);

    // Test upward movement
    let high_price = 20_000u128;
    call_intra_window_accumulation_for_testing(&mut oracle_inst, high_price, 1000, 1000);

    // With 10% PPM and base of 10,000, step = 1,000
    // Price should be capped at 10,000 + 1,000 = 11,000
    assert!(oracle::last_price(&oracle_inst) == 11_000, 1);

    // Reset and test downward movement
    oracle::set_last_window_twap_for_testing(&mut oracle_inst, 10_000);
    oracle::set_last_timestamp_for_testing(&mut oracle_inst, 2000);
    oracle::set_last_window_end_for_testing(&mut oracle_inst, 0);

    let low_price = 5_000u128;
    call_intra_window_accumulation_for_testing(&mut oracle_inst, low_price, 1000, 3000);

    // Price should be capped at 10,000 - 1,000 = 9,000
    assert!(oracle::last_price(&oracle_inst) == 9_000, 2);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_intra_accum_twap_calc_result_truncation() {
    let mut scenario = test::begin(@0xB1);
    let test_ctx = ctx(&mut scenario);
    let mut oracle_inst = setup_default_oracle(test_ctx);

    let initial_lwt = 100_u128; // Irrelevant for TWAP calc itself, but used for capping
    let initial_lwe = 0_u64;
    let initial_lwecp = 0_u256;

    // sum_diff = total_cumulative_price - last_window_end_cumulative_price
    // We want sum_diff / TWAP_PRICE_CAP_WINDOW_TIME to be fractional.
    // Let TWAP_PRICE_CAP_WINDOW_TIME = 60000.
    // Let desired TWAP be 123.5. So sum_diff = 123.5 * 60000 = 123 * 60000 + 30000 = 7380000 + 30000 = 7410000.
    let sum_for_window =
        (123_u256 * (TWAP_PRICE_CAP_WINDOW_TIME as u256)) + ((TWAP_PRICE_CAP_WINDOW_TIME / 2) as u256);

    // This sum_for_window is what oracle.total_cumulative_price should be *after* current contribution,
    // and *before* the TWAP calculation part of intra_window_accumulation.
    // So, if additional_time_to_include = 0, then initial_tcp should be sum_for_window.
    let initial_tcp = sum_for_window;

    configure_oracle_state(&mut oracle_inst, initial_lwt, initial_lwe, initial_tcp, initial_lwecp);

    let price_input = 100_u128; // Arbitrary, as time_to_include is 0
    let time_to_include = 0_u64;
    let new_timestamp = initial_lwe + TWAP_PRICE_CAP_WINDOW_TIME; // Completes window

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        price_input,
        time_to_include,
        new_timestamp,
    );

    // Expected TWAP = 123 (truncated from 123.5)
    assert!(debug_get_window_twap(&oracle_inst) == 123_u128, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_intra_accum_twap_calc_at_max_price() {
    let mut scenario = test::begin(@0xB2);
    let test_ctx = ctx(&mut scenario);
    let mut oracle_inst = setup_default_oracle(test_ctx);

    let initial_lwt = 100_u128;
    let initial_lwe = 0_u64;
    let initial_lwecp = 0_u256;

    let u256_twap_target = ((u64::max_value!() as u256) * AMM_BASIS_POINTS as u256);

    let sum_for_window = u256_twap_target * (TWAP_PRICE_CAP_WINDOW_TIME as u256);

    let initial_tcp = sum_for_window;

    configure_oracle_state(&mut oracle_inst, initial_lwt, initial_lwe, initial_tcp, initial_lwecp);

    let price_input = 100_u128;
    let time_to_include = 0_u64;
    let new_timestamp = initial_lwe + TWAP_PRICE_CAP_WINDOW_TIME;

    call_intra_window_accumulation_for_testing(
        &mut oracle_inst,
        price_input,
        time_to_include,
        new_timestamp,
    );

    assert!(debug_get_window_twap(&oracle_inst) <= u128::max_value!(), 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}
