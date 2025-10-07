#[test_only]
module futarchy_markets::market_state_tests;

use futarchy_markets::market_state::{Self, MarketState};
use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use std::string;
use std::option;

// Helper to setup test scenario
fun setup_test(sender: address): (ts::Scenario, Clock) {
    let mut scenario = ts::begin(sender);
    ts::next_tx(&mut scenario, sender);
    let ctx = ts::ctx(&mut scenario);
    let clock = clock::create_for_testing(ctx);
    (scenario, clock)
}

// === Creation Tests ===

#[test]
fun test_create_market_state() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let market_id = object::id_from_address(@0xDEAD);
        let dao_id = object::id_from_address(@0xBEEF);

        let outcome_messages = vector[
            string::utf8(b"Reject"),
            string::utf8(b"Accept")
        ];

        let state = market_state::new(
            market_id,
            dao_id,
            2,  // outcome_count
            outcome_messages,
            &clock,
            ctx
        );

        // Verify initial state
        assert!(market_state::outcome_count(&state) == 2, 0);
        assert!(market_state::dao_id(&state) == dao_id, 1);
        assert!(market_state::market_id(&state) == market_id, 2);
        assert!(!market_state::is_trading_active(&state), 3);
        assert!(!market_state::is_finalized(&state), 4);
        assert!(market_state::get_creation_time(&state) == clock.timestamp_ms(), 5);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_create_for_testing_helper() {
    let sender = @0xA;
    let (mut scenario, clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let state = market_state::create_for_testing(3, ctx);

        assert!(market_state::outcome_count(&state) == 3, 0);
        assert!(!market_state::is_trading_active(&state), 1);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Trading Lifecycle Tests ===

#[test]
fun test_start_trading() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Start trading with 7 day duration
        let duration_ms = 7 * 24 * 60 * 60 * 1000;
        market_state::start_trading(&mut state, duration_ms, &clock);

        // Verify trading started
        assert!(market_state::is_trading_active(&state), 0);
        assert!(market_state::get_trading_start(&state) == clock.timestamp_ms(), 1);

        let end_time = market_state::get_trading_end_time(&state);
        assert!(option::is_some(&end_time), 2);
        assert!(*option::borrow(&end_time) == clock.timestamp_ms() + duration_ms, 3);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)]  // ETradingAlreadyStarted
fun test_start_trading_twice_fails() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Start trading first time
        market_state::start_trading(&mut state, 1000, &clock);

        // Try to start again - should fail
        market_state::start_trading(&mut state, 2000, &clock);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 7)]  // EInvalidDuration
fun test_start_trading_zero_duration_fails() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Try to start with zero duration - should fail
        market_state::start_trading(&mut state, 0, &clock);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 7)]  // EInvalidDuration
fun test_start_trading_excessive_duration_fails() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Try to start with > 30 days - should fail
        let duration_ms = 31 * 24 * 60 * 60 * 1000;  // 31 days
        market_state::start_trading(&mut state, duration_ms, &clock);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_end_trading() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Start trading
        market_state::start_trading(&mut state, 1000, &clock);
        assert!(market_state::is_trading_active(&state), 0);

        // Advance clock past trading end
        clock.increment_for_testing(2000);

        // End trading
        market_state::end_trading(&mut state, &clock);
        assert!(!market_state::is_trading_active(&state), 1);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 6)]  // ETradingNotStarted
fun test_end_trading_before_start_fails() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Try to end trading without starting - should fail
        market_state::end_trading(&mut state, &clock);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_end_trading_early_allowed() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Start trading with 10000ms duration
        market_state::start_trading(&mut state, 10000, &clock);

        // End trading early (only 5000ms passed) - allowed
        clock.increment_for_testing(5000);
        market_state::end_trading(&mut state, &clock);

        // Verify ended
        assert!(!market_state::is_trading_active(&state), 0);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 3)]  // ETradingAlreadyEnded
fun test_end_trading_twice_fails() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Start and end trading
        market_state::start_trading(&mut state, 1000, &clock);
        clock.increment_for_testing(2000);
        market_state::end_trading(&mut state, &clock);

        // Try to end again - should fail
        market_state::end_trading(&mut state, &clock);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Finalization Tests ===

#[test]
fun test_finalize_market() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(3, ctx);

        // Start, end, and finalize
        market_state::start_trading(&mut state, 1000, &clock);
        clock.increment_for_testing(2000);
        market_state::end_trading(&mut state, &clock);

        market_state::finalize(&mut state, 1, &clock);

        // Verify finalized
        assert!(market_state::is_finalized(&state), 0);
        assert!(market_state::get_winning_outcome(&state) == 1, 1);
        assert!(option::is_some(&market_state::get_finalization_time(&state)), 2);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4)]  // ETradingNotEnded
fun test_finalize_before_trading_ends_fails() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Start trading but don't end it
        market_state::start_trading(&mut state, 10000, &clock);

        // Try to finalize - should fail
        market_state::finalize(&mut state, 1, &clock);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 2)]  // EAlreadyFinalized
fun test_finalize_twice_fails() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Start, end, and finalize
        market_state::start_trading(&mut state, 1000, &clock);
        clock.increment_for_testing(2000);
        market_state::end_trading(&mut state, &clock);
        market_state::finalize(&mut state, 0, &clock);

        // Try to finalize again - should fail
        market_state::finalize(&mut state, 1, &clock);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)]  // EOutcomeOutOfBounds
fun test_finalize_invalid_outcome_fails() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Start and end trading
        market_state::start_trading(&mut state, 1000, &clock);
        clock.increment_for_testing(2000);
        market_state::end_trading(&mut state, &clock);

        // Try to finalize with outcome >= outcome_count - should fail
        market_state::finalize(&mut state, 2, &clock);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Validation and Assertion Tests ===

#[test]
fun test_assert_trading_active_success() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // Start trading
        market_state::start_trading(&mut state, 1000, &clock);

        // This should succeed
        market_state::assert_trading_active(&state);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 6)]  // ETradingNotStarted
fun test_assert_trading_active_fails_not_started() {
    let sender = @0xA;
    let (mut scenario, clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let state = market_state::create_for_testing(2, ctx);

        // This should fail
        market_state::assert_trading_active(&state);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun test_validate_outcome_success() {
    let sender = @0xA;
    let (mut scenario, clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let state = market_state::create_for_testing(3, ctx);

        // Valid outcomes: 0, 1, 2
        market_state::validate_outcome(&state, 0);
        market_state::validate_outcome(&state, 1);
        market_state::validate_outcome(&state, 2);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 1)]  // EOutcomeOutOfBounds
fun test_validate_outcome_fails() {
    let sender = @0xA;
    let (mut scenario, clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let state = market_state::create_for_testing(3, ctx);

        // outcome 3 is out of bounds (valid: 0, 1, 2)
        market_state::validate_outcome(&state, 3);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Getter Tests ===

#[test]
fun test_getters() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let market_id = object::id_from_address(@0xDEAD);
        let dao_id = object::id_from_address(@0xBEEF);

        let outcome_messages = vector[
            string::utf8(b"Reject"),
            string::utf8(b"Accept"),
            string::utf8(b"Abstain")
        ];

        let state = market_state::new(
            market_id,
            dao_id,
            3,
            outcome_messages,
            &clock,
            ctx
        );

        // Test all getters
        assert!(market_state::market_id(&state) == market_id, 0);
        assert!(market_state::dao_id(&state) == dao_id, 1);
        assert!(market_state::outcome_count(&state) == 3, 2);
        assert!(market_state::get_outcome_message(&state, 0) == string::utf8(b"Reject"), 3);
        assert!(market_state::get_outcome_message(&state, 1) == string::utf8(b"Accept"), 4);
        assert!(market_state::get_outcome_message(&state, 2) == string::utf8(b"Abstain"), 5);
        assert!(market_state::get_creation_time(&state) == clock.timestamp_ms(), 6);
        assert!(!market_state::is_trading_active(&state), 7);
        assert!(!market_state::is_finalized(&state), 8);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

// === Full Lifecycle Test ===

#[test]
fun test_complete_lifecycle() {
    let sender = @0xA;
    let (mut scenario, mut clock) = setup_test(sender);

    ts::next_tx(&mut scenario, sender);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut state = market_state::create_for_testing(2, ctx);

        // 1. Initial state
        assert!(!market_state::is_trading_active(&state), 0);
        assert!(!market_state::is_finalized(&state), 1);

        // 2. Start trading
        market_state::start_trading(&mut state, 5000, &clock);
        assert!(market_state::is_trading_active(&state), 2);

        // 3. Trading period passes
        clock.increment_for_testing(6000);

        // 4. End trading
        market_state::end_trading(&mut state, &clock);
        assert!(!market_state::is_trading_active(&state), 3);
        assert!(!market_state::is_finalized(&state), 4);

        // 5. Finalize with winner
        market_state::finalize(&mut state, 1, &clock);
        assert!(market_state::is_finalized(&state), 5);
        assert!(market_state::get_winning_outcome(&state) == 1, 6);

        market_state::destroy_for_testing(state);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}
