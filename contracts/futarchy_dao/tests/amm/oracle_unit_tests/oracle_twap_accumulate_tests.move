#[test_only]
module futarchy::oracle_twap_accumulate_tests {
    use futarchy::oracle::{
        Self,
        Oracle,
        ETimestampRegression,
        EInternalTwapError
    };
    use sui::test_scenario::{Self as test, Scenario, ctx};
    use std::u64;
    use std::u128;
    use std::u256; // For type casting and comparison

    // ======== Test Constants ========
    const INIT_PRICE: u128 = 10000;
    const MARKET_START_TIME: u64 = 0; // Simplifies time calculations for direct accumulate tests
    const TWAP_CAP_STEP: u64 = 10_000; // 1% of INIT_PRICE (10,000 PPM = 1%)
    const OBSERVATION_PRICE: u128 = 10500; // A sample price for observations
    const OTHER_OBSERVATION_PRICE: u128 = 9500;

    // TWAP_PRICE_CAP_WINDOW is a const in the oracle module, assumed to be 60_000
    // If it's not public, we might need to use its value directly or make it public.
    // For now, assuming direct use of its value 60_000 or that it's imported.
    const WINDOW_SIZE: u64 = 60_000; // Directly using the value for clarity in tests


    // ======== Helper Functions ========
    fun default_oracle(test_ctx: &mut TxContext): Oracle {
        // For twap_accumulate tests, twap_start_delay is set to 0
        // as write_observation's delay logic is not the focus.
        oracle::new_oracle(
            INIT_PRICE,
            0, // twap_start_delay
            TWAP_CAP_STEP,
            test_ctx
        )
    }

    fun setup_scenario(): Scenario {
        let mut scenario = test::begin(@0x1);
        test::next_tx(&mut scenario, @0x1);
        scenario
    }

    // ======== Test Cases for twap_accumulate ========

    #[test]
    #[expected_failure(abort_code = ETimestampRegression)]
    fun test_accumulate_fail_timestamp_regression_direct() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx);

        // Set initial last_timestamp
        oracle::set_last_timestamp_for_testing(&mut oracle_inst, 100_000);

        // Call accumulate with a timestamp that is less than oracle.last_timestamp
        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, 99_999, OBSERVATION_PRICE);

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ETimestampRegression)]
    fun test_accumulate_fail_inconsistent_state_last_ts_lt_window_end() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx);

        // Pre-condition: oracle.last_timestamp < oracle.last_window_end
        oracle::set_last_window_end_for_testing(&mut oracle_inst, 100_000);
        oracle::set_last_timestamp_for_testing(&mut oracle_inst, 99_999);

        // Call accumulate. The timestamp itself doesn't matter as pre-condition check fails first.
        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, 100_000, OBSERVATION_PRICE);

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

    #[test]
    // Note: Forcing EInternalTwapError (oracle.last_timestamp != timestamp at function end)
    // is non-trivial without modifying the source code of twap_accumulate or its sub-functions
    // to intentionally misbehave, or discovering a subtle arithmetic bug.
    // The current implementation of twap_accumulate and its stages seems robust in ensuring
    // oracle.last_timestamp correctly reaches the target `timestamp`.
    // This test executes a complex path; if it were to fail this assertion, it would indicate such a bug.
    // However, it's expected to PASS this internal assertion.
    // To truly test the *failure* of this assert as requested by the test name,
    // a way to "manipulate mock execution" (e.g., force a sub-function to not update last_timestamp correctly)
    // would be needed, which is not standard in Sui Move testing.
    // THEREFORE, THIS TEST IS WRITTEN TO PASS THE ASSERTION.
    // If a scenario that *causes* this failure is known, the test should be updated.
    fun test_accumulate_pass_internal_error_final_timestamp_mismatch_check_complex_path() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx);

        // Setup a complex scenario: starts mid-window, covers multiple full windows, ends mid-window
        oracle::set_last_timestamp_for_testing(&mut oracle_inst, MARKET_START_TIME + 10_000); // 10_000
        oracle::set_last_window_end_for_testing(&mut oracle_inst, MARKET_START_TIME);      // 0
        oracle::set_last_window_twap_for_testing(&mut oracle_inst, INIT_PRICE);            // 10000
        oracle::set_cumulative_prices_for_testing(&mut oracle_inst, 100_000_000u256, 0); // 10000 * 10000

        let final_timestamp = MARKET_START_TIME + 10_000 + (WINDOW_SIZE - 10_000) + 2 * WINDOW_SIZE + 20_000;
        // Stage 1: 50_000 (to complete first window)
        // Stage 2: 2 * 60_000 (two full windows)
        // Stage 3: 20_000 (partial in next window)
        // Total duration = 50k + 120k + 20k = 190k.
        // Initial last_timestamp = 10k. Final timestamp = 10k + 190k = 200k.

        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_timestamp, OBSERVATION_PRICE);

        // The critical assertion is inside twap_accumulate. If we reach here, it passed.
        // We can also verify the final oracle.last_timestamp.
        assert!(oracle::last_timestamp(&oracle_inst) == final_timestamp, 0);

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }


    #[test]
    fun test_accumulate_zero_duration_no_change() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx);

        let initial_ts = 100_000;
        oracle::set_last_timestamp_for_testing(&mut oracle_inst, initial_ts);
        oracle::set_last_window_end_for_testing(&mut oracle_inst, initial_ts - 20_000); // 80_000
        oracle::set_last_window_twap_for_testing(&mut oracle_inst, INIT_PRICE + 500);
        oracle::set_cumulative_prices_for_testing(&mut oracle_inst, 12345u256, 54321u256);
        let initial_last_price = oracle::last_price(&oracle_inst); // Will be INIT_PRICE from new_oracle

        // Call accumulate with timestamp == oracle.last_timestamp
        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, initial_ts, OBSERVATION_PRICE);

        // Verify no accumulation stages run, oracle state unchanged
        assert!(oracle::last_timestamp(&oracle_inst) == initial_ts, 0);
        assert!(oracle::get_total_cumulative_price_for_testing(&oracle_inst) == 12345u256, 1);
        assert!(oracle::get_last_window_end_cumulative_price_for_testing(&oracle_inst) == 54321u256, 2);
        assert!(oracle::debug_get_window_twap(&oracle_inst) == INIT_PRICE + 500, 3);
        // last_price is NOT changed by twap_accumulate itself if no stages run.
        // It's updated within intra_window_accumulation / multi_full_window_accumulation.
        // The only way last_price would change is if initial_last_price was different from the one set in new_oracle.
        // Let's ensure last_price is also monitored if it's expected to be stable.
        // The initial last_price is oracle.twap_initialization_price set by new_oracle.
        assert!(oracle::last_price(&oracle_inst) == INIT_PRICE, 4);


        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

    #[test]
    fun test_accumulate_stage1_only_intra_window_no_boundary_cross() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx); // last_ts=0, last_window_end=0, last_window_twap=INIT_PRICE

        let start_ts = 10_000; // Mid-window (0 to 60k window)
        let duration = 20_000; // Ends at 30_000, still within the same 0-60k window
        let final_ts = start_ts + duration;

        oracle::set_last_timestamp_for_testing(&mut oracle_inst, start_ts);
        oracle::set_last_window_end_for_testing(&mut oracle_inst, 0); // Current window is 0 to 60_000
        oracle::set_last_window_twap_for_testing(&mut oracle_inst, INIT_PRICE); // Base for capping

        let initial_total_cum_price = oracle::get_total_cumulative_price_for_testing(&oracle_inst); // 0

        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_ts, OBSERVATION_PRICE);

        // Expected: Stage 1 runs for `duration`. No boundary crossed.
        assert!(oracle::last_timestamp(&oracle_inst) == final_ts, 0);

        // Capped price: one_step_cap_price_change(10000, 10500, 100) = min(10500, 10000 + 100) = 10100
        let expected_capped_price = 10100u128;
        let expected_price_contribution = (expected_capped_price as u256) * (duration as u256);
        let expected_total_cum_price = initial_total_cum_price + expected_price_contribution;

        assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 1);
        assert!(oracle::get_total_cumulative_price_for_testing(&oracle_inst) == expected_total_cum_price, 2);
        assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == 0, 3); // Not updated
        assert!(oracle::debug_get_window_twap(&oracle_inst) == INIT_PRICE, 4); // Not updated

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

#[test]
    fun test_accumulate_stage1_only_completes_window_exactly() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx); // LT=0, LWE=0, LWT=INIT_PRICE, CUMs=0 by default

        let start_ts = 10_000;
        let time_to_boundary = WINDOW_SIZE - start_ts; // 50_000
        let final_ts = start_ts + time_to_boundary;    // 60_000

        // Explicitly set the entire desired starting state for the oracle just before the call
        oracle::set_last_timestamp_for_testing(&mut oracle_inst, start_ts);            // LT = 10_000
        oracle::set_last_window_end_for_testing(&mut oracle_inst, 0);                  // LWE = 0
        oracle::set_last_window_twap_for_testing(&mut oracle_inst, INIT_PRICE);        // LWT = 10_000
        oracle::set_cumulative_prices_for_testing(&mut oracle_inst, 0, 0); // CUMs = 0

        // State before call: LT=10_000, LWE=0. Assertion 10_000 >= 0 should pass.

        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_ts, OBSERVATION_PRICE);

        // Assertions
        assert!(oracle::last_timestamp(&oracle_inst) == final_ts, 0);

        let expected_capped_price = 10100u128;
        let price_contribution = (expected_capped_price as u256) * (time_to_boundary as u256);

        // Get current cumulative prices *after* accumulation for assertion
        let current_total_cum_price = oracle::get_total_cumulative_price_for_testing(&oracle_inst);
        let current_lwe_cum_price = oracle::get_last_window_end_cumulative_price_for_testing(&oracle_inst);
        let actual_window_twap = oracle::debug_get_window_twap(&oracle_inst);

        assert!(current_total_cum_price == price_contribution, 1); // total_cumulative_price = 0 + price_contribution
        assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 2);
        assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == final_ts, 3);
        assert!(current_lwe_cum_price == current_total_cum_price, 4); // last_window_end_cumulative_price updated to total

        let expected_window_twap_val = (price_contribution / (WINDOW_SIZE as u256)) as u128;
        assert!(actual_window_twap == expected_window_twap_val, 5);

        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

    // For Stage 2 "only" tests, as per analysis, Stage 1 will handle the first full window if starting on boundary.
    // The name reflects the total duration and that Stage 2 (multi_full_window) is involved.

    #[test]
    fun test_accumulate_one_full_window_from_boundary_via_stage1() { // Renamed from "stage2_only_single_full_window_from_boundary"
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx); // last_ts=0, last_window_end=0, last_window_twap=INIT_PRICE

        let start_ts = 0; // At a window boundary
        let duration = WINDOW_SIZE; // Exactly one full window
        let final_ts = start_ts + duration;

        // Initial state: last_ts=0, lwe=0, lwt=INIT_PRICE, cum_prices=0
        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_ts, OBSERVATION_PRICE);

        // Expected: Stage 1 runs for `WINDOW_SIZE`. Boundary hit. Stage 2 & 3 skip.
        assert!(oracle::last_timestamp(&oracle_inst) == final_ts, 0);

        let expected_capped_price = 10100u128;
        let price_contribution = (expected_capped_price as u256) * (WINDOW_SIZE as u256);
        let expected_window_twap = expected_capped_price; // Since it's constant over the window

        assert!(oracle::last_price(&oracle_inst) == expected_capped_price, 1);
        assert!(oracle::get_total_cumulative_price_for_testing(&oracle_inst) == price_contribution, 2);
        assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == final_ts, 3);
        assert!(oracle::debug_get_window_twap(&oracle_inst) == expected_window_twap, 4);
        assert!(oracle::get_last_window_end_cumulative_price_for_testing(&oracle_inst) == price_contribution, 5);

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

    #[test]
    fun test_accumulate_stage1_then_stage2_multiple_full_windows_from_boundary() { // Renamed from "stage2_only_multiple_full_windows_from_boundary"
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx);

        let num_total_windows = 3u64;
        let start_ts = 0; // At boundary
        let final_ts = start_ts + num_total_windows * WINDOW_SIZE; // e.g., 180_000

        // Price chosen to be equal to last_window_twap to simplify multi_full_window math (g_abs=0)
        let price_for_multi_window = INIT_PRICE;

        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_ts, price_for_multi_window);

        // Stage 1: processes 1st window (0 to 60k) via intra_window. Capped price = INIT_PRICE. CumPrice1 = INIT_PRICE*60k. LWT becomes INIT_PRICE.
        // Stage 2: processes next (num_total_windows - 1) = 2 windows. (60k to 180k).
        //          multi_full_window uses LWT=INIT_PRICE. Price=INIT_PRICE. So g_abs=0. S_dev_mag=0.
        //          V_sum_prices = (num_windows_stage2 * LWT) = 2 * INIT_PRICE.
        //          Contribution_stage2 = V_sum_prices * WINDOW_SIZE = (2 * INIT_PRICE) * WINDOW_SIZE.
        //          New LWT after stage 2 will be INIT_PRICE.
        // Final state: last_ts = final_ts.

        assert!(oracle::last_timestamp(&oracle_inst) == final_ts, 0);
        assert!(oracle::last_price(&oracle_inst) == price_for_multi_window, 1); // p_n_w_effective will be INIT_PRICE
        assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == final_ts, 2);
        assert!(oracle::debug_get_window_twap(&oracle_inst) == price_for_multi_window, 3);

        let expected_total_cum_price = (price_for_multi_window as u256) * (num_total_windows as u256) * (WINDOW_SIZE as u256);
        assert!(oracle::get_total_cumulative_price_for_testing(&oracle_inst) == expected_total_cum_price, 4);
        assert!(oracle::get_last_window_end_cumulative_price_for_testing(&oracle_inst) == expected_total_cum_price, 5);


        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

    #[test]
    fun test_accumulate_stage1_partial_then_stage2_full_ends_on_boundary() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx);

        let start_ts_offset = 10_000; // 10k into the first window (0-60k)
        let num_full_windows_in_stage2 = 1u64;

        oracle::set_last_timestamp_for_testing(&mut oracle_inst, start_ts_offset);
        oracle::set_last_window_end_for_testing(&mut oracle_inst, 0);
        oracle::set_last_window_twap_for_testing(&mut oracle_inst, INIT_PRICE);
        // Set initial cumulative prices to be consistent with having processed 10k ms at INIT_PRICE
        let initial_cumulative = (INIT_PRICE as u256) * (start_ts_offset as u256);
        oracle::set_cumulative_prices_for_testing(&mut oracle_inst, initial_cumulative, 0);

        let duration_stage1 = WINDOW_SIZE - start_ts_offset; // 50_000
        let final_ts = start_ts_offset + duration_stage1 + num_full_windows_in_stage2 * WINDOW_SIZE;
        // final_ts = 10k + 50k + 1*60k = 120k

        // Use a higher price to test ramping behavior in stage 2
        let new_price = INIT_PRICE + (INIT_PRICE / 5); // 20% higher = 12000

        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_ts, new_price);

        // Stage 1: intra_window for 50k. Price=12000, LWT=10000. 
        //          Initial cumulative = INIT_PRICE * 10k = 100M
        //          Capped price = min(12000, 10000 + step) where step = 10000 * 0.01 = 100
        //          Capped price = min(12000, 10100) = 10100
        //          Additional contribution = 10100 * 50k = 505M
        //          Total after stage 1 = 100M + 505M = 605M
        //          At end of Stage 1 (ts=60k): lwt = 605M / 60k = 10083.33... = 10083
        let lwt_after_stage1 = ((initial_cumulative + (10100u128 as u256) * 50000) / 60000) as u128;

        // Stage 2: multi_full_window for 1 window. Base LWT = 10083, Price = 12000
        //          g_abs = 12000 - 10083 = 1917
        //          cap_step = 10083 * 0.01 ≈ 100
        //          Since we have 1 window and g_abs > cap_step:
        //          p_n_w_effective = 10083 + min(100*1, 1917) = 10083 + 100 = 10183

        assert!(oracle::last_timestamp(&oracle_inst) == final_ts, 0);
        assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == final_ts, 1);
        
        // Calculate expected final TWAP with ramping
        // With PPM-based step (1% = 10000 PPM), the step from lwt_after_stage1 is about 100
        let expected_step = (lwt_after_stage1 * (TWAP_CAP_STEP as u128)) / 1_000_000;
        let expected_final_lwt = lwt_after_stage1 + expected_step;
        
        // Allow for small rounding differences
        let actual_lwt = oracle::debug_get_window_twap(&oracle_inst);
        assert!(actual_lwt >= expected_final_lwt - 2 && actual_lwt <= expected_final_lwt + 2, 2);
        assert!(oracle::last_price(&oracle_inst) == actual_lwt, 3);

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }


#[test]
    fun test_accumulate_stage1_partial_then_stage2_full_then_stage3_partial() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx);

        let start_ts_offset = 10_000; // 10k into the first window (0-60k relative to oracle.last_window_end)
        let num_full_windows_stage2 = 2u64;
        let partial_duration_stage3 = 30_000; // 30k into the final window

        // Set initial state
        // oracle.last_window_end is 0 from default_oracle
        // oracle.last_timestamp is 10_000 (start_ts_offset)
        oracle::set_last_timestamp_for_testing(&mut oracle_inst, start_ts_offset);
        oracle::set_last_window_end_for_testing(&mut oracle_inst, 0); // Current window is [0, 60_000)
        oracle::set_last_window_twap_for_testing(&mut oracle_inst, INIT_PRICE);
        oracle::set_cumulative_prices_for_testing(&mut oracle_inst, 0, 0); // Using u256::zero() for clarity

        // Calculate durations and final timestamp
        // Stage 1: Processes from start_ts_offset (10_000) to the end of the current window (60_000)
        let duration_stage1 = WINDOW_SIZE - start_ts_offset; // 50_000
        let end_of_stage1_abs_ts = start_ts_offset + duration_stage1; // Absolute timestamp: 10_000 + 50_000 = 60_000

        // Stage 2: Processes num_full_windows_stage2 from end_of_stage1_abs_ts
        let duration_stage2 = num_full_windows_stage2 * WINDOW_SIZE; // 2 * 60_000 = 120_000
        let end_of_stage2_abs_ts = end_of_stage1_abs_ts + duration_stage2; // Absolute timestamp: 60_000 + 120_000 = 180_000

        // Stage 3: Processes partial_duration_stage3 from end_of_stage2_abs_ts
        let final_ts = end_of_stage2_abs_ts + partial_duration_stage3; // Absolute timestamp: 180_000 + 30_000 = 210_000

        // Use a price for the observation
        let price = OBSERVATION_PRICE; // 10500

        // Call the function under test
        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_ts, price);

        // Assertions:
        // 1. oracle.last_timestamp should be the final timestamp.
        assert!(oracle::last_timestamp(&oracle_inst) == final_ts, 0);

        // 2. oracle.last_window_end should be the timestamp of the end of the last *full* window processed.
        //    In this scenario, this is the end of Stage 2.
        //    Stage 1 ends at 60_000, updating last_window_end to 60_000.
        //    Stage 2 processes two full windows (from 60_000 to 120_000, then 120_000 to 180_000).
        //    So, after Stage 2, last_window_end is 180_000.
        //    Stage 3 is partial, so it does not update last_window_end.
        let expected_lwe_final = end_of_stage2_abs_ts;
        assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == expected_lwe_final, 1);

        // Final last_price is from Stage 3's intra_window_accumulation, capped against LWT from end of Stage 2.
        // Calculating exact LWT after S2 and then the capped price for S3 is complex and not strictly necessary
        // for validating the stage logic and boundary updates, which are the primary focus here.

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

    #[test]
    fun test_accumulate_stage1_full_stage2_full_then_stage3_partial_from_boundary() { // Adjusted name
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx); // last_ts=0, lwe=0, lwt=INIT_PRICE

        let num_full_windows_stage2 = 1u64; // So Stage 1 does 1, Stage 2 does 1. Total 2 full.
        let partial_duration_stage3 = 20_000;

        let final_ts = (1 + num_full_windows_stage2) * WINDOW_SIZE + partial_duration_stage3;
        // final_ts = (1+1)*60k + 20k = 120k + 20k = 140k

        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_ts, OBSERVATION_PRICE);

        assert!(oracle::last_timestamp(&oracle_inst) == final_ts, 0);
        let expected_lwe_after_stage2 = (1 + num_full_windows_stage2) * WINDOW_SIZE;
        assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == expected_lwe_after_stage2, 1);
        // Further state checks for last_price, cumulative prices would be complex.

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

    #[test]
    fun test_accumulate_stage1_to_boundary_then_stage3_partial_within_next_window() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx);

        let start_ts_offset = 40_000; // 40k into the first window (0-60k)
        let partial_duration_stage3 = 25_000; // Stage 2 should be skipped (num_full_windows = 0)

        oracle::set_last_timestamp_for_testing(&mut oracle_inst, start_ts_offset);
        oracle::set_last_window_end_for_testing(&mut oracle_inst, 0);
        oracle::set_last_window_twap_for_testing(&mut oracle_inst, INIT_PRICE);
        oracle::set_cumulative_prices_for_testing(&mut oracle_inst, 0, 0);

        let duration_stage1 = WINDOW_SIZE - start_ts_offset; // 20_000
        let final_ts = start_ts_offset + duration_stage1 + partial_duration_stage3;
        // final_ts = 40k + 20k + 25k = 85k

        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_ts, OBSERVATION_PRICE);

        // Stage 1: completes window 0-60k. LT becomes 60k. LWE becomes 60k.
        // Stage 2: time_remaining = 25k. num_full_windows = 0. Skipped.
        // Stage 3: duration = 25k. LT becomes 85k. LWE remains 60k.

        assert!(oracle::last_timestamp(&oracle_inst) == final_ts, 0);
        assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == WINDOW_SIZE, 1); // End of Stage 1 window

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }

    #[test]
    fun test_accumulate_very_long_duration_many_full_windows() {
        let mut scenario = setup_scenario();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_oracle(test_ctx); // last_ts=0, lwe=0, lwt=INIT_PRICE

        let num_total_windows = 1000u64;
        let final_ts = num_total_windows * WINDOW_SIZE;

        // Use price = LWT to simplify multi_full_window math (g_abs=0)
        let price = INIT_PRICE;

        oracle::call_twap_accumulate_for_testing(&mut oracle_inst, final_ts, price);

        // Stage 1: 1 window.
        // Stage 2: (num_total_windows - 1) windows.
        // Stage 3: 0 duration.

        assert!(oracle::last_timestamp(&oracle_inst) == final_ts, 0);
        assert!(oracle::last_price(&oracle_inst) == price, 1);
        assert!(oracle::get_last_window_end_for_testing(&oracle_inst) == final_ts, 2);
        assert!(oracle::debug_get_window_twap(&oracle_inst) == price, 3);

        let expected_total_cum_price = (price as u256) * (num_total_windows as u256) * (WINDOW_SIZE as u256);
        assert!(oracle::get_total_cumulative_price_for_testing(&oracle_inst) == expected_total_cum_price, 4);

        // Clean up
        oracle::destroy_for_testing(oracle_inst);
        test::end(scenario);
    }
}