#[test_only]
module futarchy::oracle_intra_accum_tests {
    use futarchy::oracle::{
        Self, Oracle,
        // Test helpers from oracle module
        set_last_timestamp_for_testing,
        set_last_window_end_for_testing,
        set_last_window_twap_for_testing,
        set_cumulative_prices_for_testing,
        call_intra_window_accumulation_for_testing, // Assuming this is added to oracle module
        get_last_window_end_cumulative_price_for_testing,
        get_total_cumulative_price_for_testing,
        get_last_window_end_for_testing,
        debug_get_window_twap
    };
    use std::u128;
    use std::u64;
    use sui::test_scenario::{Self as test, Scenario, ctx};
    use futarchy::math;

    // ======== Test Constants from existing test setups ========
    // These are used for oracle creation via setup_test_oracle
    const DEFAULT_TWAP_CAP_STEP: u64 = 1000;
    const DEFAULT_TWAP_START_DELAY: u64 = 60_000;
    const DEFAULT_MARKET_START_TIME: u64 = 1000;
    const DEFAULT_INIT_PRICE: u128 = 10000;
    const TWAP_PRICE_CAP_WINDOW_TIME: u64 = 60_000; 
    const AMM_BASIS_POINTS:u256 = 1_000_000_000_000;

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

        call_intra_window_accumulation_for_testing(&mut oracle_inst, price_input, time_to_include, new_timestamp);

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
        let initial_tcp = (pre_existing_intra_window_price as u256) * (pre_existing_intra_window_time as u256);
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

        call_intra_window_accumulation_for_testing(&mut oracle_inst, price_input, time_to_include, new_timestamp);

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

        let expected_capped_price = lwt_base + (DEFAULT_TWAP_CAP_STEP as u128); // 10000 + 1000 = 11000
        let expected_price_contribution = (expected_capped_price as u256) * (time_to_include as u256);

        call_intra_window_accumulation_for_testing(&mut oracle_inst, high_price_input, time_to_include, new_timestamp);

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

        let expected_capped_price = lwt_base - (DEFAULT_TWAP_CAP_STEP as u128); // 10000 - 1000 = 9000
        let expected_price_contribution = (expected_capped_price as u256) * (time_to_include as u256);

        call_intra_window_accumulation_for_testing(&mut oracle_inst, low_price_input, time_to_include, new_timestamp);

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

        call_intra_window_accumulation_for_testing(&mut oracle_inst, normal_price_input, time_to_include, new_timestamp);

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

        call_intra_window_accumulation_for_testing(&mut oracle_inst, price_input, time_to_include, new_timestamp);

        // TCP unchanged as price_contribution is 0
        assert!(get_total_cumulative_price_for_testing(&oracle_inst) == initial_tcp, 1);
        assert!(oracle::last_timestamp(&oracle_inst) == new_timestamp, 2);
        assert!(oracle::last_price(&oracle_inst) == price_input, 3); // Capping logic runs, price_input is within cap

        // Boundary logic triggers
        assert!(get_last_window_end_for_testing(&oracle_inst) == new_timestamp, 4);
        // TWAP = (initial_tcp - initial_lwecp) / WINDOW = (12345 - 0) / 60000 = 0 (due to truncation)
        assert!(debug_get_window_twap(&oracle_inst) == (initial_tcp / (TWAP_PRICE_CAP_WINDOW_TIME as u256) as u128), 5);
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
            DEFAULT_INIT_PRICE, DEFAULT_TWAP_START_DELAY,
            u64::max_value!(), // Very large cap step
            test_ctx
        );
        // oracle.last_window_twap is DEFAULT_INIT_PRICE (10000) after new_oracle
        // configure_oracle_state then sets it again to DEFAULT_INIT_PRICE
        configure_oracle_state(&mut oracle_inst, DEFAULT_INIT_PRICE, 0, 0, 0);


        let large_price_input = u128::max_value!() / 2_u128; // approx 1.7e38. This is the input price.
        let large_time: u64 = 1_000_000_000; // 1e9 ms
        let new_timestamp = 2_000_000_000_u64; // Not on boundary

        // Calculate the actual expected capped price based on one_step_cap_price_change
        // oracle.last_window_twap = DEFAULT_INIT_PRICE (10000)
        // oracle.twap_cap_step = u64::max_value()
        // capped_price = min(large_price_input, DEFAULT_INIT_PRICE + u64::max_value())
        // Since large_price_input is much larger than (DEFAULT_INIT_PRICE + u64::max_value()),
        // the capped price will be DEFAULT_INIT_PRICE + u64::max_value().
        let base_for_cap_calc = DEFAULT_INIT_PRICE;
        let cap_step_for_calc = u64::max_value!() as u128;
        let expected_capped_price = math::saturating_add(base_for_cap_calc, cap_step_for_calc);

        let expected_tcp = (expected_capped_price as u256) * (large_time as u256);

        call_intra_window_accumulation_for_testing(&mut oracle_inst, large_price_input, large_time, new_timestamp);

        assert!(get_total_cumulative_price_for_testing(&oracle_inst) == expected_tcp, 1);
        assert!(oracle::last_timestamp(&oracle_inst) == new_timestamp, 2);
        assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 3);

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
        let sum_for_window = (123_u256 * (TWAP_PRICE_CAP_WINDOW_TIME as u256)) + ((TWAP_PRICE_CAP_WINDOW_TIME / 2) as u256);
        
        // This sum_for_window is what oracle.total_cumulative_price should be *after* current contribution,
        // and *before* the TWAP calculation part of intra_window_accumulation.
        // So, if additional_time_to_include = 0, then initial_tcp should be sum_for_window.
        let initial_tcp = sum_for_window;

        configure_oracle_state(&mut oracle_inst, initial_lwt, initial_lwe, initial_tcp, initial_lwecp);

        let price_input = 100_u128; // Arbitrary, as time_to_include is 0
        let time_to_include = 0_u64;
        let new_timestamp = initial_lwe + TWAP_PRICE_CAP_WINDOW_TIME; // Completes window

        call_intra_window_accumulation_for_testing(&mut oracle_inst, price_input, time_to_include, new_timestamp);

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

        call_intra_window_accumulation_for_testing(&mut oracle_inst, price_input, time_to_include, new_timestamp);

        assert!(debug_get_window_twap(&oracle_inst) <= u128::max_value!(), 1);

        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }
}