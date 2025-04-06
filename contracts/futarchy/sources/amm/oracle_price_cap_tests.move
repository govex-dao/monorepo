// New test module for futarchy::oracle
#[test_only]
module futarchy::oracle_price_cap_tests {
    use sui::clock;
    use sui::test_scenario::{Self as test, Scenario};
    use futarchy::oracle::{Self, Oracle};
    use std::debug;

    // ======== Test Constants ========
    const BASIS_POINTS: u64 = 10000;
    const TWAP_STEP_MAX: u64 = 1000;       // Allow 10% movement
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
            ctx
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
            let first_window_price = oracle::get_last_price(&oracle_inst);
            debug::print(&first_window_price); // Let's see what we actually get
            
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
            let exact_cap_price = INIT_PRICE + (INIT_PRICE * (TWAP_STEP_MAX as u128)) / (BASIS_POINTS as u128);
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
                delay_threshold + 400
            ];
            
            let prices = vector[
                15000, // Try +50% - should cap at +10% = 11000
                5000,  // Try -50% - should cap at -10% = 9000
                15000, // Try +50% - should cap at +10% = 11000
                5000   // Try -50% - should cap at -10% = 9000
            ];
            
            let expected_prices = vector[
                11000,
                9000,
                11000,
                9000
            ];
            
            let mut i = 0;
            while (i < 4) {
                oracle::write_observation(
                    &mut oracle_inst, 
                    *vector::borrow(&timestamps, i), 
                    *vector::borrow(&prices, i)
                );
                assert!(
                    oracle::get_last_price(&oracle_inst) == *vector::borrow(&expected_prices, i),
                    i
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
}
