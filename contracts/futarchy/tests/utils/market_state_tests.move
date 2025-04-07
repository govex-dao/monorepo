#[test_only]
module futarchy::market_state_tests;

use futarchy::market_state::{Self, MarketState};
use std::string;
use sui::clock::{Self, Clock};
use sui::test_scenario as test;

// Test addresses
const ADMIN: address = @0xA;

// Test timestamps
const START_TIME: u64 = 1000000;
const END_TIME: u64 = 2000000;

// Test helper function to create a clock
fun create_clock(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock::set_for_testing(&mut clock, timestamp_ms);
    clock
}

// Test helper function to create a market state with sample outcomes
fun create_test_market(ctx: &mut TxContext, clock: &Clock): MarketState {
    let outcome_messages = vector[string::utf8(b"Yes"), string::utf8(b"No")];

    let dummy_id = object::new(ctx);
    let market_id = object::uid_to_inner(&dummy_id);
    object::delete(dummy_id);

    let dummy_id = object::new(ctx);
    let dao_id = object::uid_to_inner(&dummy_id);
    object::delete(dummy_id);

    market_state::new(market_id, dao_id, 2, outcome_messages, clock, ctx)
}

#[test]
fun test_create_market_state() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let market = create_test_market(test::ctx(&mut scenario), &clock);

        // Check initial state
        assert!(market_state::outcome_count(&market) == 2, 0);
        assert!(market_state::get_outcome_message(&market, 0) == string::utf8(b"Yes"), 0);
        assert!(market_state::get_outcome_message(&market, 1) == string::utf8(b"No"), 0);
        assert!(!market_state::is_trading_active(&market), 0);
        assert!(!market_state::is_finalized(&market), 0);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
fun test_start_trading() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start trading
        market_state::start_trading(&mut market, 1000000, &clock);

        // Check state after starting
        assert!(market_state::is_trading_active(&market), 0);
        assert!(!market_state::is_finalized(&market), 0);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
fun test_end_trading() {
    let mut scenario = test::begin(ADMIN);
    {
        let mut clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start and end trading
        market_state::start_trading(&mut market, 1000000, &clock);
        clock::set_for_testing(&mut clock, END_TIME);
        market_state::end_trading(&mut market, &clock);

        // Check state after ending
        assert!(!market_state::is_trading_active(&market), 0);
        assert!(!market_state::is_finalized(&market), 0);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
fun test_finalize_market() {
    let mut scenario = test::begin(ADMIN);
    {
        let mut clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start, end, and finalize
        market_state::start_trading(&mut market, 1000000, &clock);
        clock::set_for_testing(&mut clock, END_TIME);
        market_state::end_trading(&mut market, &clock);
        market_state::finalize(&mut market, 1, &clock);

        // Check state after finalization
        assert!(!market_state::is_trading_active(&market), 0);
        assert!(market_state::is_finalized(&market), 0);
        assert!(market_state::get_winning_outcome(&market) == 1, 0);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ETRADING_ALREADY_STARTED)]
fun test_start_trading_twice() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start trading twice - should fail
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::start_trading(&mut market, 1000000, &clock);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ETRADING_NOT_STARTED)]
fun test_end_trading_without_starting() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // End trading without starting - should fail
        market_state::end_trading(&mut market, &clock);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ETRADING_ALREADY_ENDED)]
fun test_end_trading_twice() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start and end trading twice - should fail
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::end_trading(&mut market, &clock);
        market_state::end_trading(&mut market, &clock);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ETRADING_NOT_ENDED)]
fun test_finalize_without_ending_trading() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start trading but finalize without ending - should fail
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::finalize(&mut market, 0, &clock);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::EALREADY_FINALIZED)]
fun test_finalize_twice() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Complete flow but finalize twice - should fail
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::end_trading(&mut market, &clock);
        market_state::finalize(&mut market, 0, &clock);
        market_state::finalize(&mut market, 1, &clock);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::EOUTCOME_OUT_OF_BOUNDS)]
fun test_finalize_with_invalid_outcome() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Finalize with invalid outcome - should fail
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::end_trading(&mut market, &clock);
        market_state::finalize(&mut market, 2, &clock); // Only have outcomes 0 and 1

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ENOT_FINALIZED)]
fun test_get_winning_outcome_before_finalization() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Try to get winning outcome before finalization - should fail
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::end_trading(&mut market, &clock);
        let _ = market_state::get_winning_outcome(&market);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
fun test_assert_functions() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Test assertion functions at different states

        // Initial state
        market_state::assert_not_finalized(&market);
        market_state::assert_in_trading_or_pre_trading(&market);

        // Start trading
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::assert_trading_active(&market);
        market_state::assert_in_trading_or_pre_trading(&market);
        market_state::assert_not_finalized(&market);

        // End trading
        market_state::end_trading(&mut market, &clock);
        market_state::assert_not_finalized(&market);

        // Finalize
        market_state::finalize(&mut market, 0, &clock);
        market_state::assert_market_finalized(&market);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ETRADING_NOT_STARTED)]
fun test_assert_trading_active_fails_when_not_started() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let market = create_test_market(test::ctx(&mut scenario), &clock);

        // Should fail as trading not started
        market_state::assert_trading_active(&market);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ETRADING_ALREADY_ENDED)]
fun test_assert_trading_active_fails_when_ended() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Set up
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::end_trading(&mut market, &clock);

        // Should fail as trading has ended
        market_state::assert_trading_active(&market);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::EALREADY_FINALIZED)]
fun test_assert_not_finalized_fails_when_finalized() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Set up
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::end_trading(&mut market, &clock);
        market_state::finalize(&mut market, 0, &clock);

        // Should fail as market is finalized
        market_state::assert_not_finalized(&market);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ENOT_FINALIZED)]
fun test_assert_market_finalized_fails_when_not_finalized() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let market = create_test_market(test::ctx(&mut scenario), &clock);

        // Should fail as market is not finalized
        market_state::assert_market_finalized(&market);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::EOUTCOME_OUT_OF_BOUNDS)]
fun test_validate_outcome_fails_with_invalid_outcome() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let market = create_test_market(test::ctx(&mut scenario), &clock);

        // Should fail as outcome 2 is out of bounds
        market_state::validate_outcome(&market, 2);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
fun test_getter_functions() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Test all getter functions
        let _market_id = market_state::market_id(&market);
        let _dao_id = market_state::dao_id(&market);
        let outcome_count = market_state::outcome_count(&market);

        assert!(outcome_count == 2, 0);

        let is_active = market_state::is_trading_active(&market);
        assert!(!is_active, 0);

        // Start and check again
        market_state::start_trading(&mut market, 1000000, &clock);
        let is_active_now = market_state::is_trading_active(&market);
        assert!(is_active_now, 0);

        // End and finalize
        market_state::end_trading(&mut market, &clock);
        market_state::finalize(&mut market, 0, &clock);

        // Check finalized state
        let is_finalized = market_state::is_finalized(&market);
        assert!(is_finalized, 0);

        let winner = market_state::get_winning_outcome(&market);
        assert!(winner == 0, 0);

        let winner2 = market_state::get_winning_outcome(&market);
        assert!(winner2 == 0, 0);

        // Check outcome messages
        let msg0 = market_state::get_outcome_message(&market, 0);
        let msg1 = market_state::get_outcome_message(&market, 1);

        assert!(msg0 == string::utf8(b"Yes"), 0);
        assert!(msg1 == string::utf8(b"No"), 0);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
fun test_full_market_lifecycle() {
    let mut scenario = test::begin(ADMIN);
    {
        let mut clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // 1. Initial state
        assert!(!market_state::is_trading_active(&market), 0);
        assert!(!market_state::is_finalized(&market), 0);

        // 2. Start trading
        market_state::start_trading(&mut market, 1000000, &clock);
        assert!(market_state::is_trading_active(&market), 0);

        // 3. End trading
        clock::set_for_testing(&mut clock, END_TIME);
        market_state::end_trading(&mut market, &clock);
        assert!(!market_state::is_trading_active(&market), 0);
        assert!(!market_state::is_finalized(&market), 0);

        // 4. Finalize market
        market_state::finalize(&mut market, 1, &clock);
        assert!(!market_state::is_trading_active(&market), 0);
        assert!(market_state::is_finalized(&market), 0);
        assert!(market_state::get_winning_outcome(&market) == 1, 0);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
#[expected_failure(abort_code = futarchy::market_state::ETRADING_ALREADY_ENDED)]
fun test_assert_in_trading_or_pre_trading_fails_when_ended() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start and end trading
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::end_trading(&mut market, &clock);

        // Should fail as trading has ended
        market_state::assert_in_trading_or_pre_trading(&market);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

// Tests for edge cases with timestamps
#[test]
fun test_trading_with_zero_duration() {
    let mut scenario = test::begin(ADMIN);
    {
        let mut clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start trading with zero duration
        market_state::start_trading(&mut market, 0, &clock);

        // Check that trading started
        assert!(market_state::is_trading_active(&market), 0);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
fun test_trading_with_very_short_duration() {
    let mut scenario = test::begin(ADMIN);
    {
        let mut clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start trading with 1ms duration
        market_state::start_trading(&mut market, 1, &clock);

        // Check that trading started
        assert!(market_state::is_trading_active(&market), 0);

        // Advance clock just past the end time
        clock::set_for_testing(&mut clock, START_TIME + 2);

        // End trading should still work
        market_state::end_trading(&mut market, &clock);
        assert!(!market_state::is_trading_active(&market), 0);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

#[test]
fun test_trading_with_maximum_duration() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Start trading with a very large duration
        // Using a large but safe value to avoid overflow concerns
        let large_duration: u64 = 9223372036854775807; // i64::MAX as u64
        market_state::start_trading(&mut market, large_duration, &clock);

        // Check that trading started
        assert!(market_state::is_trading_active(&market), 0);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}

// Test for finalization assertion
#[test]
#[expected_failure(abort_code = futarchy::market_state::ETRADING_ALREADY_ENDED)]
fun test_assert_in_trading_or_pre_trading_fails_when_finalized() {
    let mut scenario = test::begin(ADMIN);
    {
        let clock = create_clock(START_TIME, test::ctx(&mut scenario));
        let mut market = create_test_market(test::ctx(&mut scenario), &clock);

        // Complete the market lifecycle
        market_state::start_trading(&mut market, 1000000, &clock);
        market_state::end_trading(&mut market, &clock);
        market_state::finalize(&mut market, 0, &clock);

        // Should fail as market is already finalized
        market_state::assert_in_trading_or_pre_trading(&market);

        // Clean up
        market_state::destroy_for_testing(market);
        clock::destroy_for_testing(clock);
    };
    test::end(scenario);
}
