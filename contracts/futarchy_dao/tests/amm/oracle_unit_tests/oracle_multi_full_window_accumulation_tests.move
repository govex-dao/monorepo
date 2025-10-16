#[test_only]
module futarchy::oracle_multi_window_tests;

use futarchy::math;
use futarchy::oracle::{
    Self,
    Oracle,
    ETimestampRegression,
    ETwapNotStarted,
    EZeroPeriod,
    EZeroInitialization,
    EZeroStep,
    ELongDelay,
    EStaleTwap,
    EOverflowVRamp,
    EOverflowVFlat,
    EOverflowSDevMag,
    EOverflowBasePriceSumFinal,
    EOverflowVSumPricesAdd,
    EInternalTwapError,
    ENoneFullWindowTwapDelay,
    EInvalidCapPpm
};
use std::u128;
use std::u64;
use sui::object;
use sui::test_scenario::{Self as test, Scenario, ctx};

const DEFAULT_LAST_WINDOW_TWAP: u128 = 10_000;
const DEFAULT_CAP_STEP: u64 = 10_000; // Default: 1% of 10k (10,000 PPM = 1%)
const MARKET_START_TIME_FOR_TESTS: u64 = 0;
const DEFAULT_INIT_PRICE: u128 = DEFAULT_LAST_WINDOW_TWAP; // For oracle creation
const TWAP_PRICE_CAP_WINDOW_TIME: u64 = 60_000;

// Helper to setup oracle with specific state for multi_full_window_accumulation tests
fun setup_oracle_for_multi_test(
    scenario: &mut Scenario,
    last_window_twap_val: u128,
    cap_step_val: u64,
    // This timestamp is where the *previous* window ended, and the new full windows start.
    current_multi_window_start_ts: u64,
    initial_total_cumulative: u256,
    initial_lwe_cumulative: u256,
): Oracle {
    // Convert desired absolute step to PPM based on DEFAULT_INIT_PRICE
    // cap_step_val is the desired absolute step, convert to PPM
    let cap_step_ppm = if (cap_step_val == 0 || DEFAULT_INIT_PRICE == 0) {
        1 // Minimum PPM
    } else {
        // For very large cap_step_val, calculate PPM carefully to avoid overflow
        // PPM = (cap_step_val * 1_000_000) / DEFAULT_INIT_PRICE
        // If cap_step_val is very large (like 2^60), we need to be careful
        let max_step_for_ppm = u64::max_value!() / 1_000_000; // Maximum value that won't overflow when multiplied by 1M
        if (cap_step_val > max_step_for_ppm) {
            // cap_step_val is too large for direct multiplication
            // Since it's so large, just use max PPM
            1_000_000
        } else {
            let ppm_calc = cap_step_val * 1_000_000 / (DEFAULT_INIT_PRICE as u64);
            if (ppm_calc == 0) { 1 } else if (ppm_calc > 1_000_000) { 1_000_000 } else { ppm_calc }
        }
    };

    let mut oracle_inst = oracle::new_oracle(
        DEFAULT_INIT_PRICE,
        0, // twap_start_delay, keep simple for these tests
        cap_step_ppm,
        ctx(scenario),
    );
    oracle::set_last_window_twap_for_testing(&mut oracle_inst, last_window_twap_val);
    // Before multi_full_window_accumulation, last_timestamp and last_window_end are typically aligned.
    oracle::set_last_timestamp_for_testing(&mut oracle_inst, current_multi_window_start_ts);
    oracle::set_last_window_end_for_testing(&mut oracle_inst, current_multi_window_start_ts);
    oracle::set_cumulative_prices_for_testing(
        &mut oracle_inst,
        initial_total_cumulative,
        initial_lwe_cumulative,
    );
    oracle_inst
}

#[test]
fun test_multi_price_equals_base_twap() {
    let mut scenario = test::begin(@0x1);
    let base_twap = DEFAULT_LAST_WINDOW_TWAP;
    let price = base_twap; // price == oracle.last_window_twap
    let num_windows = 5u64;
    let cap_step = DEFAULT_CAP_STEP;

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME; // e.g., after 1 full window period
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);

    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    // g_abs = 0, s_dev_mag = 0
    // p_n_w_effective and new last_window_twap are oracle.last_window_twap
    assert!(oracle::last_price(&oracle_inst) == base_twap, 0);
    assert!(oracle::debug_get_window_twap(&oracle_inst) == base_twap, 1);

    let expected_v_sum_prices = (num_windows as u128) * base_twap;
    let price_contribution = (expected_v_sum_prices as u256) * (TWAP_PRICE_CAP_WINDOW_TIME as u256);
    let expected_final_cumulative = initial_cumulative + price_contribution;

    assert!(
        oracle::get_total_cumulative_price_for_testing(&oracle_inst) == expected_final_cumulative,
        2,
    );
    assert!(
        oracle::get_last_window_end_cumulative_price_for_testing(&oracle_inst) == expected_final_cumulative,
        3,
    );
    assert!(oracle::last_timestamp(&oracle_inst) == end_ts, 4);
    assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == end_ts, 5);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_price_increases_ramp_absorbs_all() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 100u64;
    let price = 10300u128; // g_abs = 300
    // k_cap_idx = (300-1)/100 + 1 = 2+1 = 3
    let num_windows = 3u64; // N_W >= k_cap_idx

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME;
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    // p_n_w_effective should become price
    assert!(oracle::last_price(&oracle_inst) == price, 0);
    assert!(oracle::debug_get_window_twap(&oracle_inst) == price, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_price_increases_ramp_limited_by_nw() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 100u64;
    let price = 10500u128; // g_abs = 500
    // k_cap_idx = (500-1)/100 + 1 = 4+1 = 5
    let num_windows = 3u64; // N_W (3) < k_cap_idx (5)
    // N_W * cap_step = 300. g_abs = 500. 300 <= 500 holds.

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME;
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    // p_n_w_effective is B + N_W * cap_step
    let expected_pnw = base_twap + (num_windows as u128) * (cap_step as u128); // 10000 + 3*100 = 10300
    assert!(oracle::last_price(&oracle_inst) == expected_pnw, 0);
    assert!(oracle::debug_get_window_twap(&oracle_inst) == expected_pnw, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_price_decreases_ramp_absorbs_all() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 100u64;
    let price = 9700u128; // g_abs = 300
    // k_cap_idx = 3
    let num_windows = 3u64; // N_W >= k_cap_idx

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME;
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    assert!(oracle::last_price(&oracle_inst) == price, 0);
    assert!(oracle::debug_get_window_twap(&oracle_inst) == price, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_price_decreases_ramp_limited_by_nw() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 100u64;
    let price = 9500u128; // g_abs = 500
    // k_cap_idx = 5
    let num_windows = 3u64; // N_W (3) < k_cap_idx (5)

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME;
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    let expected_pnw = base_twap - (num_windows as u128) * (cap_step as u128); // 10000 - 300 = 9700
    assert!(oracle::last_price(&oracle_inst) == expected_pnw, 0);
    assert!(oracle::debug_get_window_twap(&oracle_inst) == expected_pnw, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_k_cap_idx_u128_exceeds_u64_max() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 100u128;
    let cap_step = 1u64; // cap_step = 1
    // g_abs needs to make (g_abs-1)/cap_step_u128 + 1 > u64::max_value!()
    // So g_abs > u64::max_value!().
    // Let g_abs be slightly larger than u64::max_value!()
    let price_g_abs_val = (u64::max_value!() as u128) + 1;
    let price = base_twap + price_g_abs_val;

    // Use a manageable num_windows for end_ts calculation
    let num_windows = 100u64;

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME; // Assuming TWAP_PRICE_CAP_WINDOW is 60_000
    let initial_cumulative = 0u256;
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    // Ensure end_ts calculation does not overflow
    let end_ts_increment_u128 = (num_windows as u128) * (TWAP_PRICE_CAP_WINDOW_TIME as u128);
    assert!(end_ts_increment_u128 <= ((u64::max_value!() - start_ts) as u128), 99);
    let end_ts = start_ts + (num_windows * TWAP_PRICE_CAP_WINDOW_TIME);

    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    let expected_deviation = (num_windows as u128) * (cap_step as u128);
    let expected_pnw = base_twap + expected_deviation;

    assert!(oracle::last_price(&oracle_inst) == expected_pnw, 0);
    assert!(oracle::debug_get_window_twap(&oracle_inst) == expected_pnw, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_n_ramp_terms_zero_due_to_k_ramp_limit_zero() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 100u64;

    // Case 1: g_abs = 0
    let price1 = base_twap; // g_abs = 0 => k_cap_idx = 0 => k_ramp_limit = 0
    let num_windows = 5u64;

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME;
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);
    let mut oracle1 = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );
    let end_ts1 = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle1,
        price1,
        num_windows,
        end_ts1,
    );
    // n_ramp_terms = 0, v_ramp = 0. s_dev_mag = v_flat = g_abs * num_flat_terms = 0 * 5 = 0.
    // p_n_w_effective = base_twap.
    assert!(oracle::last_price(&oracle1) == base_twap, 0);
    oracle::destroy_for_testing(oracle1);

    // Case 2: 0 < g_abs <= cap_step
    let price2 = base_twap + 50u128; // g_abs = 50. cap_step = 100.
    // k_cap_idx = (50-1)/100 + 1 = 0+1=1. k_ramp_limit = 0.
    let mut oracle2 = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );
    let end_ts2 = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle2,
        price2,
        num_windows,
        end_ts2,
    );
    // n_ramp_terms = 0, v_ramp = 0. num_flat_terms = num_windows = 5.
    // v_flat = g_abs * num_flat_terms = 50 * 5 = 250. s_dev_mag = 250.
    // deviation_for_p_n_w = min(N_W * cap_step, g_abs) = min(5*100, 50) = 50.
    // p_n_w_effective = base_twap + 50 = price2.
    assert!(oracle::last_price(&oracle2) == price2, 1);
    oracle::destroy_for_testing(oracle2);

    test::end(scenario);
}

// The old test_multi_v_ramp_overflow has been removed as the PPM-based system
// inherently prevents the extreme step values that would cause overflow.
// Instead, we test that the PPM system correctly bounds the step values.

#[test]
fun test_ppm_prevents_extreme_steps() {
    // Test that the PPM-based system correctly limits step values
    // even with extreme inputs that would have caused overflow in the old system
    let mut scenario = test::begin(@0x1);

    // Try to create conditions that would overflow in old system
    let base_twap = 10000u128;
    let extreme_num_windows = (1u64 << 20); // 1M windows

    // With max PPM (100%), step = base_twap
    let cap_step_val = base_twap as u64;

    // Price far from base to maximize ramping
    let price = base_twap * 1000; // 1000x base

    let start_ts = 0u64;
    let initial_cumulative = 0u256;
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step_val,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + extreme_num_windows * TWAP_PRICE_CAP_WINDOW_TIME;

    // This should complete without overflow due to PPM bounds
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        extreme_num_windows,
        end_ts,
    );

    // Verify the final price is bounded by PPM system
    // After many windows with max PPM, price should reach the target
    let final_price = oracle::last_price(&oracle_inst);
    assert!(final_price <= price, 0); // Price capped by input

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_v_ramp_n_ramp_terms_even_and_odd() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 10u64;
    let g_abs_large = (cap_step as u128) * 100; // Ensures k_ramp_limit is large enough
    let price_up = base_twap + g_abs_large;

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME;
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);

    // Case 1: n_ramp_terms is even (e.g., 2)
    // N_W = 2. k_ramp_limit large enough. So n_ramp_terms = 2.
    let num_windows_even = 2u64;
    let mut oracle_even = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );
    let end_ts_even = start_ts + num_windows_even * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_even,
        price_up,
        num_windows_even,
        end_ts_even,
    );
    // v_ramp for NRT=2: cap_step * (2*(2+1)/2) = cap_step * 3 = 10 * 3 = 30.
    // num_flat_terms = N_W - NRT = 2 - 2 = 0. v_flat = 0. s_dev_mag = 30.
    // dev_for_pnw = min(N_W*cap, g_abs) = min(2*10, 1000) = 20.
    // pnw_effective = 10000 + 20 = 10020.
    assert!(
        oracle::last_price(&oracle_even) == base_twap + (num_windows_even as u128)*(cap_step as u128),
        0,
    );
    oracle::destroy_for_testing(oracle_even);

    // Case 2: n_ramp_terms is odd (e.g., 3)
    let num_windows_odd = 3u64;
    let mut oracle_odd = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );
    let end_ts_odd = start_ts + num_windows_odd * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_odd,
        price_up,
        num_windows_odd,
        end_ts_odd,
    );
    // v_ramp for NRT=3: cap_step * (3*(3+1)/2) = cap_step * 6 = 10 * 6 = 60.
    // num_flat_terms = 0. s_dev_mag = 60.
    // dev_for_pnw = min(N_W*cap, g_abs) = min(3*10, 1000) = 30.
    // pnw_effective = 10000 + 30 = 10030.
    assert!(
        oracle::last_price(&oracle_odd) == base_twap + (num_windows_odd as u128)*(cap_step as u128),
        1,
    );
    oracle::destroy_for_testing(oracle_odd);

    test::end(scenario);
}

#[test]
fun test_multi_v_flat_num_flat_terms_zero() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 100u64;
    // To make num_flat_terms = 0, need N_W <= k_ramp_limit.
    // Let N_W = 2.
    // Need k_ramp_limit >= 2. So k_cap_idx >= 3.
    // (g_abs-1)/cap_step + 1 >= 3 => (g_abs-1)/cap_step >= 2
    // g_abs-1 >= 2*cap_step => g_abs > 2*cap_step.
    // Let g_abs = 2 * cap_step + 1 = 201.
    let price = base_twap + 201u128;
    let num_windows = 2u64;

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME;
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    // n_ramp_terms = N_W = 2. num_flat_terms = 0. v_flat = 0.
    // s_dev_mag = v_ramp = cap_step * (2*(2+1)/2) = 100 * 3 = 300.
    // deviation_for_p_n_w = min(N_W*cap, g_abs) = min(2*100, 201) = min(200,201) = 200.
    // pnw = 10000 + 200 = 10200.
    assert!(
        oracle::last_price(&oracle_inst) == base_twap + (num_windows as u128)*(cap_step as u128),
        0,
    );
    // To verify v_flat=0, we can check total_cumulative_price.
    // v_sum_prices = N_W*B + s_dev_mag = 2*10000 + 300 = 20300.
    let expected_v_sum_prices = (num_windows as u128)*base_twap + 300;
    let price_contrib = (expected_v_sum_prices as u256) * (TWAP_PRICE_CAP_WINDOW_TIME as u256);
    let expected_total_cum = initial_cumulative + price_contrib;
    assert!(oracle::get_total_cumulative_price_for_testing(&oracle_inst) == expected_total_cum, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = EOverflowBasePriceSumFinal)]
fun test_multi_base_price_sum_overflow() {
    let mut scenario = test::begin(@0x1);
    let base_twap = u128::max_value!();
    let num_windows = 2u64; // N_W * B overflows

    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        DEFAULT_CAP_STEP,
        0,
        0u256,
        0u256,
    );
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        base_twap,
        num_windows,
        num_windows * TWAP_PRICE_CAP_WINDOW_TIME, // Price doesn't matter for this error
    );
    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_v_sum_prices_sub_no_underflow_below_zero() {
    let mut scenario = test::begin(@0x1);
    // price < B. base_price_sum - s_dev_mag should not underflow u128 to negative.
    // (u128 subtraction naturally handles this by clamping at 0 if it's direct,
    // or panicking if it's checked subtraction that would go negative).
    // The code uses direct subtraction, relying on N_W * B >= S_dev_mag.
    let base_twap = 100u128;
    let price = 0u128; // g_abs = 100
    let cap_step = 10u64;
    let num_windows = 5u64; // Small N_W to keep S_dev_mag from exceeding N_W*B too easily if logic was flawed.
    // k_cap_idx for g_abs=100, cap=10: (100-1)/10+1 = 9+1=10. k_ramp_limit=9.
    // n_ramp_terms = min(5,9) = 5. num_flat_terms = 0.
    // s_dev_mag = v_ramp = cap_step * (5*(5+1)/2) = 10 * 15 = 150.
    // base_price_sum = N_W * B = 5 * 100 = 500.
    // v_sum_prices = 500 - 150 = 350. (Non-negative).

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME;
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    // Check that p_n_w_effective is B - min(N_W*cap, g_abs)
    // dev = min(5*10, 100) = 50. pnw_eff = 100 - 50 = 50.
    assert!(
        oracle::last_price(&oracle_inst) == base_twap - (num_windows as u128)*(cap_step as u128),
        0,
    );
    // cumulative price should be positive
    let v_sum_prices_val = (num_windows as u128)*base_twap - 150; // 500 - 150 = 350
    let price_contrib = (v_sum_prices_val as u256) * (TWAP_PRICE_CAP_WINDOW_TIME as u256);
    let expected_total_cum = initial_cumulative + price_contrib;
    assert!(oracle::get_total_cumulative_price_for_testing(&oracle_inst) == expected_total_cum, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_pnw_saturating_add_hits_u128_max() {
    let mut scenario = test::begin(@0x1);
    let base_twap = u128::max_value!() - 10;
    let cap_step = 100u64;
    let num_windows = 1u64;

    // We want B + deviation_for_p_n_w to saturate.
    // B = u128::max_value() - 10.
    // Let deviation_for_p_n_w = 10.
    // deviation_for_p_n_w = min(N_W*cap_step, g_abs) = min(1*100, g_abs).
    // To make this 10, g_abs must be 10.
    // price >= B. g_abs = price - B.
    // So, price - (u128::max_value() - 10) = 10.
    // price = u128::max_value().
    let price_input = u128::max_value!();

    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        0,
        0u256,
        0u256,
    );
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price_input,
        num_windows,
        num_windows * TWAP_PRICE_CAP_WINDOW_TIME,
    );

    assert!(oracle::last_price(&oracle_inst) == u128::max_value!(), 0);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_pnw_saturating_sub_hits_zero() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10u128;
    let cap_step = 100u64;
    let num_windows = 1u64;
    // deviation_for_p_n_w = min(N_W*cap_step, g_abs).
    // We want B - deviation_for_p_n_w to saturate to 0. So deviation_for_p_n_w should be >= B.
    // Let price = 0. g_abs = base_twap = 10.
    // deviation_for_p_n_w = min(1*100, 10) = 10.
    // pnw_eff = 10 - 10 = 0.

    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        0,
        0u256,
        0u256,
    );
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        0u128,
        num_windows,
        num_windows * TWAP_PRICE_CAP_WINDOW_TIME,
    );

    assert!(oracle::last_price(&oracle_inst) == 0u128, 0);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_one_new_window() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 100u64;
    let num_windows = 1u64;

    // Case 1: g_abs <= cap_step. k_ramp_limit = 0. n_ramp_terms = 0.
    // p_n_w_effective = price.
    let price1 = base_twap + 50u128; // g_abs = 50.
    let mut oracle1 = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        0,
        0u256,
        0u256,
    );
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle1,
        price1,
        num_windows,
        num_windows * TWAP_PRICE_CAP_WINDOW_TIME,
    );
    assert!(oracle::last_price(&oracle1) == price1, 0);
    oracle::destroy_for_testing(oracle1);

    // Case 2: g_abs > cap_step. k_ramp_limit >= 1. n_ramp_terms = 1.
    // p_n_w_effective = B +/- cap_step.
    let price2 = base_twap + 150u128; // g_abs = 150.
    let mut oracle2 = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        0,
        0u256,
        0u256,
    );
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle2,
        price2,
        num_windows,
        num_windows * TWAP_PRICE_CAP_WINDOW_TIME,
    );
    let expected_pnw2 = base_twap + (cap_step as u128);
    assert!(oracle::last_price(&oracle2) == expected_pnw2, 1);
    oracle::destroy_for_testing(oracle2);

    test::end(scenario);
}

#[test]
fun test_multi_large_num_new_windows_with_price_far_from_base() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 10u64; // smaller cap_step
    let num_windows = 1000u64; // large N_W
    let price = 50000u128; // price far from base, g_abs = 40000
    // k_cap_idx = (40000-1)/10 + 1 = 3999+1 = 4000.
    // k_ramp_limit = 3999.
    // N_W (1000) < k_ramp_limit (3999).
    // So n_ramp_terms = N_W = 1000. num_flat_terms = 0.

    let start_ts = TWAP_PRICE_CAP_WINDOW_TIME;
    let initial_cumulative = (base_twap as u256) * (start_ts as u256);
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    // deviation_for_p_n_w = min(N_W * cap_step, g_abs)
    // = min(1000 * 10, 40000) = min(10000, 40000) = 10000.
    let expected_pnw = base_twap + 10000u128; // 10000 + 10000 = 20000.
    assert!(oracle::last_price(&oracle_inst) == expected_pnw, 0);

    // s_dev_mag = v_ramp. nrt=1000.
    // sum_indices = 1000*(1001)/2 = 500 * 1001 = 500500.
    // v_ramp = cap_step * sum_indices = 10 * 500500 = 5005000.
    let s_dev_mag_expected = 5005000u128;
    let v_sum_prices_expected = (num_windows as u128) * base_twap + s_dev_mag_expected;
    // = 1000 * 10000 + 5005000 = 10,000,000 + 5,005,000 = 15,005,000.
    let price_contrib = (v_sum_prices_expected as u256) * (TWAP_PRICE_CAP_WINDOW_TIME as u256);
    let expected_total_cum = initial_cumulative + price_contrib;
    assert!(oracle::get_total_cumulative_price_for_testing(&oracle_inst) == expected_total_cum, 1);

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_state_updates_all_fields_correct() {
    let mut scenario = test::begin(@0x1);
    let base_twap = 10000u128;
    let cap_step = 100u64;
    let price = 10150u128; // g_abs = 150
    let num_windows = 3u64;
    // k_cap_idx = (150-1)/100+1 = 1+1=2. k_ramp_limit=1.
    // n_ramp_terms = min(3,1)=1. num_flat_terms = 3-1=2.

    let start_ts = 60000u64;
    let initial_total_cumulative = (base_twap as u256) * (start_ts as u256); // e.g. 10000 * 60000
    let initial_lwe_cumulative = initial_total_cumulative;

    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_total_cumulative,
        initial_lwe_cumulative,
    );

    let expected_end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        expected_end_ts,
    );

    // p_n_w_effective
    // dev_for_pnw = min(N_W*cap, g_abs) = min(3*100, 150) = min(300,150)=150.
    let expected_pnw = base_twap + 150u128; // 10150, which is price.

    assert!(oracle::last_timestamp(&oracle_inst) == expected_end_ts, 0);
    assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == expected_end_ts, 1);
    assert!(oracle::last_price(&oracle_inst) == expected_pnw, 2);
    assert!(oracle::debug_get_window_twap(&oracle_inst) == expected_pnw, 3);

    // total_cumulative_price and last_window_end_cumulative_price
    // v_ramp: nrt=1. sum_indices=1. v_ramp = cap_step*1 = 100.
    // v_flat: nft=2. g_abs=150. v_flat = 150*2 = 300.
    // s_dev_mag = v_ramp + v_flat = 100 + 300 = 400.
    // v_sum_prices = N_W*B + s_dev_mag = 3*10000 + 400 = 30000 + 400 = 30400.
    let v_sum_prices_val = 30400u128;
    let cumulative_price_contribution =
        (v_sum_prices_val as u256) * (TWAP_PRICE_CAP_WINDOW_TIME as u256);
    let expected_final_cumulative = initial_total_cumulative + cumulative_price_contribution;

    assert!(
        oracle::get_total_cumulative_price_for_testing(&oracle_inst) == expected_final_cumulative,
        4,
    );
    assert!(
        oracle::get_last_window_end_cumulative_price_for_testing(&oracle_inst) == expected_final_cumulative,
        5,
    );

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}

#[test]
fun test_multi_cumulative_price_contribution_u256() {
    let mut scenario = test::begin(@0x1);
    // v_sum_prices large, TWAP_PRICE_CAP_WINDOW_TIME is u64. Product uses u256.
    // Let v_sum_prices = u128::max_value!().
    // N_W=1, B=u128::max, price=B (s_dev_mag=0).
    let base_twap = u128::max_value!();
    let price = base_twap;
    let cap_step = 1u64; // Does not matter as g_abs=0
    let num_windows = 1u64;

    let start_ts = 0u64; // For simplicity
    let initial_cumulative = 0u256;
    let mut oracle_inst = setup_oracle_for_multi_test(
        &mut scenario,
        base_twap,
        cap_step,
        start_ts,
        initial_cumulative,
        initial_cumulative,
    );

    let end_ts = start_ts + num_windows * TWAP_PRICE_CAP_WINDOW_TIME;
    oracle::call_multi_full_window_accumulation_for_testing(
        &mut oracle_inst,
        price,
        num_windows,
        end_ts,
    );

    // v_sum_prices = 1 * u128::max_value!() + 0 = u128::max_value!().
    let v_sum_prices_val = u128::max_value!();
    let expected_contribution = (v_sum_prices_val as u256) * (TWAP_PRICE_CAP_WINDOW_TIME as u256);
    // Check if it fits u256 (it does: u128::max * 60k is ~2e43, u256 max is ~1e77)
    let expected_final_cumulative = initial_cumulative + expected_contribution;

    assert!(
        oracle::get_total_cumulative_price_for_testing(&oracle_inst) == expected_final_cumulative,
        0,
    );
    assert!(
        oracle::get_last_window_end_cumulative_price_for_testing(&oracle_inst) == expected_final_cumulative,
        1,
    );

    oracle::destroy_for_testing(oracle_inst);
    test::end(scenario);
}
