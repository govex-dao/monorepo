#[test_only]
module futarchy::oracle_write_observation_tests {
    use futarchy::oracle::{
        Self, Oracle,
        ETIMESTAMP_REGRESSION,
        // Add other error constants if needed for expected failures
    };
    use sui::clock::{Self, Clock};
    use sui::test_scenario::{Self as test, Scenario, ctx};
    use std::debug;
    use std::u128;
    use std::u256; // For type casting in assertions

    // ======== Test Constants ========
    const MARKET_START_TIME: u64 = 100_000;
    const TWAP_START_DELAY: u64 = 60_000; // Must be a multiple of TWAP_PRICE_CAP_WINDOW
    const TWAP_PRICE_CAP_WINDOW_CONST: u64 = 60_000; // Matches constant in oracle module
    const INIT_PRICE: u128 = 10_000;
    const TWAP_STEP_MAX: u64 = 1000; // 10% of price

    // Calculated constant
    const DELAY_THRESHOLD: u64 = MARKET_START_TIME + TWAP_START_DELAY; // 160_000

    // ======== Helper Functions ========
    fun setup_test_oracle_custom(
        market_start_time: u64,
        twap_start_delay: u64,
        init_price: u128,
        twap_cap_step: u64,
        ctx: &mut TxContext
    ): Oracle {
        oracle::new_oracle(
            init_price,
            market_start_time,
            twap_start_delay,
            twap_cap_step,
            ctx,
        )
    }

    fun default_setup_test_oracle(ctx: &mut TxContext): Oracle {
        setup_test_oracle_custom(
            MARKET_START_TIME,
            TWAP_START_DELAY,
            INIT_PRICE,
            TWAP_STEP_MAX,
            ctx,
        )
    }

    fun setup_scenario_and_clock(): (Scenario, Clock) {
        let mut scenario = test::begin(@0x2); // Use a different address to avoid conflicts if run with other tests
        test::next_tx(&mut scenario, @0x2);
        let clock_inst = clock::create_for_testing(ctx(&mut scenario));
        (scenario, clock_inst)
    }

    // Helper to get capped price for manual calculation checks
    fun manual_cap_price(base_twap: u128, new_price: u128, cap_step: u64): u128 {
        if (new_price > base_twap) {
            u128::min(new_price, base_twap + (cap_step as u128))
        } else {
            u128::max(new_price, base_twap - (cap_step as u128))
        }
    }


    // ======== Test Cases ========

    #[test]
    #[expected_failure(abort_code = ETIMESTAMP_REGRESSION)]
    fun test_write_obs_fail_timestamp_regression() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx);

        oracle::write_observation(&mut oracle_inst, MARKET_START_TIME + 1000, INIT_PRICE + 100);
        // Attempt to write with an earlier timestamp
        oracle::write_observation(&mut oracle_inst, MARKET_START_TIME + 500, INIT_PRICE + 200);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_case0_no_time_passed() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx);

        let obs_time = MARKET_START_TIME + 1000;
        oracle::write_observation(&mut oracle_inst, obs_time, INIT_PRICE + 100);

        let (
            lp_before, ts_before, tcp_before, lwecp_before, lwe_before, lwt_before, _, _, _, _
        ) = oracle::debug_get_full_state(&oracle_inst);

        // Write another observation at the exact same timestamp with a different price
        oracle::write_observation(&mut oracle_inst, obs_time, INIT_PRICE + 500);

        let (
            lp_after, ts_after, tcp_after, lwecp_after, lwe_after, lwt_after, _, _, _, _
        ) = oracle::debug_get_full_state(&oracle_inst);

        // State should be unchanged because the function returns early for same timestamp
        assert!(lp_after == lp_before, 0); // last_price is NOT updated if timestamp is the same
        assert!(ts_after == ts_before, 1);
        assert!(tcp_after == tcp_before, 2);
        assert!(lwecp_after == lwecp_before, 3);
        assert!(lwe_after == lwe_before, 4);
        assert!(lwt_after == lwt_before, 5);


        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_case1_first_obs_before_delay() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx); // mst=100k, delay=60k, init_price=10k, step=1k

        let obs_time = MARKET_START_TIME + 10_000; // 110_000 (before DELAY_THRESHOLD 160_000)
        let obs_price = INIT_PRICE + 500; // 10_500

        // Initial state: lt=100k, lwe=100k, lwt=10k, tcp=0, lwecp=0
        oracle::write_observation(&mut oracle_inst, obs_time, obs_price);

        let (lp, ts, tcp, lwecp, lwe, lwt, _, _, _, _) = oracle::debug_get_full_state(&oracle_inst);

        let expected_capped_price = manual_cap_price(INIT_PRICE, obs_price, TWAP_STEP_MAX); // 10500
        let expected_tcp = (expected_capped_price as u256) * ((obs_time - MARKET_START_TIME) as u256); // 10500 * 10k

        assert!(ts == obs_time, 0);
        assert!(lp == expected_capped_price, 1);
        assert!(tcp == expected_tcp, 2);
        assert!(lwe == MARKET_START_TIME, 3); // No window boundary crossed yet
        assert!(lwt == INIT_PRICE, 4);        // last_window_twap unchanged
        assert!(lwecp == 0, 5);            // last_window_end_cumulative_price unchanged

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_case1_subsequent_obs_before_delay() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx);

        let obs_time1 = MARKET_START_TIME + 10_000; // 110_000
        let obs_price1 = INIT_PRICE + 500;         // 10_500
        oracle::write_observation(&mut oracle_inst, obs_time1, obs_price1);

        let capped_price1 = manual_cap_price(INIT_PRICE, obs_price1, TWAP_STEP_MAX); // 10500
        let tcp1 = (capped_price1 as u256) * ((obs_time1 - MARKET_START_TIME) as u256); // 10500 * 10k

        let obs_time2 = obs_time1 + 15_000;       // 125_000 (still before DELAY_THRESHOLD 160_000)
        let obs_price2 = INIT_PRICE - 300;        // 9_700
        oracle::write_observation(&mut oracle_inst, obs_time2, obs_price2);

        let (lp, ts, tcp, lwecp, lwe, lwt, _, _, _, _) = oracle::debug_get_full_state(&oracle_inst);

        // Price for 2nd obs is capped relative to INIT_PRICE (last_window_twap)
        let capped_price2 = manual_cap_price(INIT_PRICE, obs_price2, TWAP_STEP_MAX); // 9700
        let expected_tcp2_contrib = (capped_price2 as u256) * ((obs_time2 - obs_time1) as u256); // 9700 * 15k
        let expected_total_tcp = tcp1 + expected_tcp2_contrib;

        assert!(ts == obs_time2, 0);
        assert!(lp == capped_price2, 1);
        assert!(tcp == expected_total_tcp, 2);
        assert!(lwe == MARKET_START_TIME, 3);
        assert!(lwt == INIT_PRICE, 4);
        assert!(lwecp == 0, 5);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_case2_cross_delay_last_ts_before_to_ts_at_delay() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        // mst=100k, delay=60k, init_price=10k, step=1k. DELAY_THRESHOLD = 160k. TWAP_WINDOW = 60k.
        let mut oracle_inst = default_setup_test_oracle(test_ctx);

        let obs_price = INIT_PRICE + 1000; // 11_000
        // Observation exactly at DELAY_THRESHOLD
        oracle::write_observation(&mut oracle_inst, DELAY_THRESHOLD, obs_price);

        // Part A: Accumulate from MARKET_START_TIME (100k) to DELAY_THRESHOLD (160k). Duration = 60k.
        // Capped price for Part A (vs INIT_PRICE=10k): manual_cap_price(10k, 11k, 1k) = 11k.
        // TCP_A = 11k * 60k = 660_000_000.
        // Window update at 160k: LWE_A = 160k. LWT_A = (660M - 0) / 60k = 11k. LWE_CP_A = 660M.
        // LP_A = 11k. LT_A = 160k.
        // Part B: Reset. TCP_B = 0. LWE_CP_B = 0. LWE_B = 160k.
        // Part C: Skipped as timestamp (160k) is not > DELAY_THRESHOLD (160k).

        let (lp, ts, tcp, lwecp, lwe, lwt, _, _, _, _) = oracle::debug_get_full_state(&oracle_inst);

        assert!(ts == DELAY_THRESHOLD, 0);          // Updated in Part A
        assert!(lp == 11000, 1);                    // Updated in Part A
        assert!(tcp == 0, 2);                      // Reset in Part B
        assert!(lwecp == 0, 3);                  // Reset in Part B
        assert!(lwe == DELAY_THRESHOLD, 4);        // Updated in Part A window, or Part B
        assert!(lwt == 11000, 5);                  // Updated in Part A window, not reset

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_case2_cross_delay_last_ts_before_to_ts_after_delay() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx); // mst=100k, delay=60k, init_p=10k, step=1k. DELAY_THR=160k.

        let obs_time = DELAY_THRESHOLD + 10_000; // 170_000
        let obs_price = INIT_PRICE + 2000;       // 12_000

        oracle::write_observation(&mut oracle_inst, obs_time, obs_price);

        // Part A: Accumulate from MARKET_START_TIME (100k) to DELAY_THRESHOLD (160k). Duration = 60k.
        // Capped price for Part A (vs INIT_PRICE=10k): manual_cap_price(10k, 12k, 1k) = 11k.
        // State after Part A's twap_accumulate: lt=160k, lp=11k, tcp_A=11k*60k=660M, lwe_A=160k, lwt_A=11k, lwecp_A=660M.
        // Part B: Reset. tcp_B=0, lwecp_B=0, lwe_B=160k. Oracle lwt remains 11k.
        // Part C: Accumulate from DELAY_THRESHOLD (160k) to obs_time (170k). Duration = 10k.
        //         Base LWT for this accumulation is 11k (from Part A's window update).
        // Capped price for Part C (vs LWT=11k): manual_cap_price(11k, 12k, 1k) = min(12k, 11k+1k) = 12k.
        // TCP_C = 12k * 10k = 120_000_000.
        // LP_C = 12k. LT_C = 170k.

        let (lp, ts, tcp, lwecp, lwe, lwt, _, _, _, _) = oracle::debug_get_full_state(&oracle_inst);

        assert!(ts == obs_time, 0);              // Updated in Part C
        assert!(lp == 12000, 1);                 // Updated in Part C
        assert!(tcp == 120_000_000, 2);         // From Part C accumulation (after reset)
        assert!(lwecp == 0, 3);               // Reset in Part B, not changed in Part C short segment
        assert!(lwe == DELAY_THRESHOLD, 4);     // From Part B, not changed in Part C short segment
        assert!(lwt == 11000, 5);               // From Part A window update, not reset

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_case2_cross_delay_last_ts_at_delay_to_ts_after_delay() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx); // mst=100k, delay=60k, init_p=10k, step=1k. DELAY_THR=160k.

        // Step 1: Write observation at DELAY_THRESHOLD to set up state.
        // From test_write_obs_case2_cross_delay_last_ts_before_to_ts_at_delay:
        // After write_observation(DELAY_THRESHOLD, 11000):
        //   lt=160k, lp=11k, tcp=0, lwe=160k, lwt=11k, lwecp=0
        oracle::write_observation(&mut oracle_inst, DELAY_THRESHOLD, INIT_PRICE + 1000 /*11k*/);


        // Step 2: This is the actual test. Oracle.last_timestamp is DELAY_THRESHOLD.
        let obs_time = DELAY_THRESHOLD + 20_000; // 180_000
        let obs_price = INIT_PRICE + 2500;       // 12_500
        oracle::write_observation(&mut oracle_inst, obs_time, obs_price);

        // Inside write_observation(180k, 12.5k):
        //   oracle.last_timestamp (160k) <= DELAY_THRESHOLD (160k) -> true
        //   timestamp (180k) >= DELAY_THRESHOLD (160k) -> true. Case 2.
        // Part A: if (DELAY_THRESHOLD (160k) > oracle.last_timestamp (160k)) -> false. Skipped.
        // Part B: Reset. tcp=0 (already), lwecp=0 (already), lwe=160k (already).
        // Part C: if (timestamp (180k) > DELAY_THRESHOLD (160k)) -> true.
        //         twap_accumulate(oracle, 180k, 12.5k). Duration 180k-160k=20k.
        //         Base LWT for this is 11k (from previous call's window update).
        //         Capped price (vs LWT=11k): manual_cap_price(11k, 12.5k, 1k) = min(12.5k, 11k+1k) = 12k.
        //         TCP_C = 12k * 20k = 240_000_000.
        //         LP_C = 12k. LT_C = 180k.

        let (lp, ts, tcp, lwecp, lwe, lwt, _, _, _, _) = oracle::debug_get_full_state(&oracle_inst);

        assert!(ts == obs_time, 0);              // Updated in Part C
        assert!(lp == 12000, 1);                 // Updated in Part C
        assert!(tcp == 240_000_000, 2);         // From Part C accumulation
        assert!(lwecp == 0, 3);               // Still 0
        assert!(lwe == DELAY_THRESHOLD, 4);     // Still DELAY_THRESHOLD
        assert!(lwt == 11000, 5);               // From previous call's window update

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_case2_single_obs_from_market_start_to_far_after_delay() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx); // mst=100k, delay=60k, init_p=10k, step=1k. DELAY_THR=160k. WINDOW=60k.

        // Far after delay: DELAY_THRESHOLD + 2 full windows + 10k partial = 160k + 120k + 10k = 290k
        let obs_time = DELAY_THRESHOLD + (2 * TWAP_PRICE_CAP_WINDOW_CONST) + 10_000; // 290_000
        let obs_price = INIT_PRICE + 5000; // 15_000

        oracle::write_observation(&mut oracle_inst, obs_time, obs_price);

        // Part A: Accumulate MARKET_START_TIME (100k) to DELAY_THRESHOLD (160k). Duration 60k.
        //         Capped Price_A (vs LWT=10k): manual_cap_price(10k, 15k, 1k) = 11k.
        //         State after Part A's twap_accumulate: lt=160k, lp=11k, tcp_A=660M, lwe_A=160k, lwt_A=11k, lwecp_A=660M.
        // Part B: Reset. tcp_B=0, lwecp_B=0, lwe_B=160k. Oracle LWT remains 11k.
        // Part C: Accumulate from DELAY_THRESHOLD (160k) to obs_time (290k). Duration 130k.
        //         Base LWT for this is 11k.
        //         twap_accumulate(oracle with lt=160k, lwt=11k, tcp=0..., 290k, 15k)
        //         Stage 1 (partial): 160k to 160k+60k=220k. Duration 60k. (first window after reset)
        //             Capped Price_C1 (vs LWT=11k): manual_cap_price(11k, 15k, 1k) = 12k.
        //             TCP_C1 = 12k * 60k = 720M. LT_C1 = 220k. LP_C1 = 12k.
        //             Window update at 220k: LWE_C1 = 220k. LWT_C1 = (720M-0)/60k = 12k. LWE_CP_C1 = 720M.
        //         Stage 2 (full): 1 full window from 220k. Num_full_windows = (290k - 220k) / 60k = 70k/60k = 1.
        //             End_timestamp_stage2 = 220k + 1*60k = 280k.
        //             multi_full_window_accumulation(oracle with lt=220k, lwt=12k..., 15k, 1, 280k)
        //                 g_abs = |15k - 12k| = 3k. k_cap_idx = (3k-1)/1k + 1 = 3. k_ramp_limit=2. n_ramp_terms=min(1,2)=1.
        //                 V_ramp = 1k * 1*(1+1)/2 = 1k.
        //                 num_flat_terms = 1-1=0. V_flat=0. S_dev_mag=1k.
        //                 base_price_sum = 12k*1 = 12k. V_sum_prices = 12k + 1k = 13k.
        //                 P'_N_W = 12k + min(1*1k, 3k) = 12k + 1k = 13k.
        //                 LP_C2 = 13k. LT_C2 = 280k. LWE_C2 = 280k. LWT_C2 = 13k.
        //                 Cumulative price contribution = 13k * 60k = 780M.
        //                 TCP_C2 = TCP_C1 + 780M = 720M + 780M = 1500M. LWE_CP_C2 = 1500M.
        //         Stage 3 (partial): 280k to 290k. Duration 10k.
        //             intra_window_accumulation(oracle with lt=280k, lwt=13k..., 15k, 10k, 290k)
        //             Capped Price_C3 (vs LWT=13k): manual_cap_price(13k, 15k, 1k) = 14k.
        //             TCP_C3_contrib = 14k * 10k = 140M.
        //             TCP_final = TCP_C2 + 140M = 1500M + 140M = 1_640_000_000.
        //             LP_C3 = 14k. LT_C3 = 290k.
        //             No window update at 290k.

        let (lp, ts, tcp, lwecp, lwe, lwt, _, _, _, _) = oracle::debug_get_full_state(&oracle_inst);

        assert!(ts == obs_time, 0);
        assert!(lp == 14000, 1); // Final capped price from Stage 3 of Part C
        assert!(tcp == 1_640_000_000, 2); // Final TCP from Part C
        assert!(lwecp == 1_500_000_000, 3); // After multi_full_window of Part C
        assert!(lwe == 280_000, 4); // End of last full window in Part C
        assert!(lwt == 13000, 5); // LWT from last full window in Part C

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_case3_first_obs_at_delay_threshold_post_reset() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx); // mst=100k, delay=60k, DELAY_THR=160k

        // 1. Initial write to cross delay and reset accumulators.
        //    From test_write_obs_case2_cross_delay_last_ts_before_to_ts_at_delay, after write_observation(160k, 11k):
        //    State: lt=160k, lp=11k, tcp=0, lwe=160k, lwt=11k, lwecp=0
        let price_for_setup = INIT_PRICE + 1000; // 11000
        oracle::write_observation(&mut oracle_inst, DELAY_THRESHOLD, price_for_setup);

        let (
            lp_setup, ts_setup, tcp_setup, lwecp_setup, lwe_setup, lwt_setup, _, _, _, _
        ) = oracle::debug_get_full_state(&oracle_inst);

        // 2. This is the actual test: write observation AT DELAY_THRESHOLD again.
        //    Oracle.last_timestamp is DELAY_THRESHOLD.
        //    This should hit Case 0: timestamp == oracle.last_timestamp.
        let new_price = INIT_PRICE + 2000; // 12000 (different from price_for_setup)
        oracle::write_observation(&mut oracle_inst, DELAY_THRESHOLD, new_price);

        let (
            lp_after, ts_after, tcp_after, lwecp_after, lwe_after, lwt_after, _, _, _, _
        ) = oracle::debug_get_full_state(&oracle_inst);

        assert!(lp_after == lp_setup, 1); // Should not change due to Case 0
        assert!(ts_after == ts_setup, 0);
        assert!(tcp_after == tcp_setup, 2);
        assert!(lwecp_after == lwecp_setup, 3);
        assert!(lwe_after == lwe_setup, 4);
        assert!(lwt_after == lwt_setup, 5);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }


    #[test]
    fun test_write_obs_case3_first_obs_after_delay_threshold_post_reset() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx); // mst=100k, delay=60k, DELAY_THR=160k

        // Setup: Ensure oracle is past delay and accumulators are reset.
        // oracle.last_timestamp will be DELAY_THRESHOLD. oracle.total_cumulative_price = 0.
        // LWT will be 11k from the setup call.
        oracle::write_observation(&mut oracle_inst, DELAY_THRESHOLD, INIT_PRICE + 1000 /*11k*/);

        // Test: First observation strictly AFTER delay threshold, post-reset state.
        let obs_time = DELAY_THRESHOLD + 10_000; // 170_000
        let obs_price = INIT_PRICE + 1500;       // 11_500

        // Oracle state before this call: lt=160k, lp=11k, tcp=0, lwe=160k, lwt=11k, lwecp=0.
        oracle::write_observation(&mut oracle_inst, obs_time, obs_price);

        // This is Case 3: oracle.last_timestamp (160k) >= DELAY_THRESHOLD (160k)
        // twap_accumulate(oracle, 170k, 11.5k). Duration 10k.
        // Base LWT is 11k. Capped Price (vs 11k): manual_cap_price(11k, 11.5k, 1k) = 11.5k.
        // TCP = 11.5k * 10k = 115_000_000.
        // LP = 11.5k. LT = 170k.

        let (lp, ts, tcp, lwecp, lwe, lwt, _, _, _, _) = oracle::debug_get_full_state(&oracle_inst);

        assert!(ts == obs_time, 0);
        assert!(lp == 11500, 1);
        assert!(tcp == 115_000_000, 2);
        assert!(lwecp == 0, 3); // No window boundary hit in this short segment
        assert!(lwe == DELAY_THRESHOLD, 4); // Unchanged
        assert!(lwt == 11000, 5); // Unchanged

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_case3_subsequent_obs_after_delay() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        let mut oracle_inst = default_setup_test_oracle(test_ctx);

        // Setup: cross delay threshold and make one observation after it.
        oracle::write_observation(&mut oracle_inst, DELAY_THRESHOLD, INIT_PRICE + 1000 /*11k*/); // Sets LWT to 11k, TCP to 0
        let obs_time1 = DELAY_THRESHOLD + 10_000; // 170_000
        let obs_price1 = INIT_PRICE + 1500;       // 11_500
        oracle::write_observation(&mut oracle_inst, obs_time1, obs_price1);
        // After obs1: lt=170k, lp=11.5k, tcp=115M, lwe=160k, lwt=11k, lwecp=0.

        // Test: Subsequent observation, still in Case 3.
        let obs_time2 = obs_time1 + 20_000; // 190_000
        let obs_price2 = INIT_PRICE - 800;        // 9_200
        oracle::write_observation(&mut oracle_inst, obs_time2, obs_price2);

        // twap_accumulate(oracle, 190k, 9.2k). Current LWT is 11k. Duration 20k.
        // Capped Price (vs LWT=11k): manual_cap_price(11k, 9.2k, 1k) = max(9.2k, 11k-1k=10k) = 10k.
        // TCP contrib = 10k * 20k = 200_000_000.
        // Total TCP = 115M (from obs1) + 200M = 315_000_000.
        // LP = 10k. LT = 190k.

        let (lp, ts, tcp, lwecp, lwe, lwt, _, _, _, _) = oracle::debug_get_full_state(&oracle_inst);

        assert!(ts == obs_time2, 0);
        assert!(lp == 10000, 1);
        assert!(tcp == 315_000_000, 2);
        assert!(lwecp == 0, 3); // No window boundary crossed in these segments
        assert!(lwe == DELAY_THRESHOLD, 4);
        assert!(lwt == 11000, 5);

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }

    #[test]
    fun test_write_obs_delay_threshold_equals_market_start() {
        let (mut scenario, clock_inst) = setup_scenario_and_clock();
        let test_ctx = ctx(&mut scenario);
        // twap_start_delay = 0 means DELAY_THRESHOLD == MARKET_START_TIME
        let mut oracle_inst = setup_test_oracle_custom(
            MARKET_START_TIME, // 100k
            0,                 // twap_start_delay
            INIT_PRICE,        // 10k
            TWAP_STEP_MAX,     // 1k
            test_ctx,
        );
        // DELAY_THRESHOLD is 100k. LWT=10k.
        // Initial oracle state: lt=100k, lp=10k, tcp=0, lwe=100k, lwt=10k, lwecp=0.

        let obs_time = MARKET_START_TIME + 10_000; // 110_000
        let obs_price = INIT_PRICE + 500;         // 10_500
        oracle::write_observation(&mut oracle_inst, obs_time, obs_price);

        // Inside write_observation(110k, 10.5k):
        //   oracle.last_timestamp (100k) <= DELAY_THRESHOLD (100k) -> true
        //   timestamp (110k) >= DELAY_THRESHOLD (100k) -> true. Case 2.
        // Part A: if (DELAY_THRESHOLD (100k) > oracle.last_timestamp (100k)) -> false. Skipped.
        // Part B: Reset. tcp=0, lwecp=0, lwe=100k. LWT is not reset.
        // Part C: if (timestamp (110k) > DELAY_THRESHOLD (100k)) -> true.
        //         twap_accumulate(oracle, 110k, 10.5k). Duration 110k-100k=10k.
        //         Base LWT for this is 10k (initial LWT).
        //         Capped Price (vs LWT=10k): manual_cap_price(10k, 10.5k, 1k) = 10.5k.
        //         TCP = 10.5k * 10k = 105_000_000.
        //         LP = 10.5k. LT = 110k.

        let (lp, ts, tcp, lwecp, lwe, lwt, _, _, _, _) = oracle::debug_get_full_state(&oracle_inst);

        assert!(ts == obs_time, 0);
        assert!(lp == 10500, 1);
        assert!(tcp == 105_000_000, 2);
        assert!(lwecp == 0, 3);
        assert!(lwe == MARKET_START_TIME, 4); // From Part B reset
        assert!(lwt == INIT_PRICE, 5);       // Initial LWT, not changed by reset

        oracle::destroy_for_testing(oracle_inst);
        clock::destroy_for_testing(clock_inst);
        test::end(scenario);
    }
}