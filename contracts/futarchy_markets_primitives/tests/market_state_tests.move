#[test_only]
module futarchy_markets_primitives::market_state_tests;

use futarchy_markets_primitives::market_state;
use sui::{
    clock::{Self, Clock},
    test_utils::destroy,
    test_scenario as ts,
};
use std::string;

// === Test Helpers ===

fun start(): (ts::Scenario, Clock) {
    let mut scenario = ts::begin(@0x0);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    (scenario, clock)
}

fun end(scenario: ts::Scenario, clock: Clock) {
    destroy(clock);
    ts::end(scenario);
}

// === Basic Test ===

// === Lifecycle Tests ===

#[test]
fun test_new_market_state() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let dao_id = object::id_from_address(@0x2);
    let outcome_messages = vector[
        string::utf8(b"Approve"),
        string::utf8(b"Reject"),
    ];

    let state = market_state::new(
        market_id,
        dao_id,
        2,
        outcome_messages,
        &clock,
        ts::ctx(&mut scenario)
    );

    // Verify initial state
    assert!(market_state::market_id(&state) == market_id, 0);
    assert!(market_state::dao_id(&state) == dao_id, 1);
    assert!(market_state::outcome_count(&state) == 2, 2);
    assert!(!market_state::is_trading_active(&state), 3);
    assert!(!market_state::is_finalized(&state), 4);
    assert!(market_state::get_creation_time(&state) == 1000, 5);
    assert!(!market_state::has_amm_pools(&state), 6);
    assert!(!market_state::has_early_resolve_metrics(&state), 7);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_start_trading() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let market_id = object::id_from_address(@0x1);
    let dao_id = object::id_from_address(@0x2);
    let outcome_messages = vector[string::utf8(b"Yes"), string::utf8(b"No")];

    let mut state = market_state::new(
        market_id,
        dao_id,
        2,
        outcome_messages,
        &clock,
        ts::ctx(&mut scenario)
    );

    // Start trading with 7 days duration
    let duration_ms = 7 * 24 * 60 * 60 * 1000; // 7 days
    market_state::start_trading(&mut state, duration_ms, &clock);

    // Verify trading started
    assert!(market_state::is_trading_active(&state), 0);
    assert!(market_state::get_trading_start(&state) == 1000, 1);

    let end_time = market_state::get_trading_end_time(&state);
    assert!(end_time.is_some(), 2);
    assert!(*end_time.borrow() == 1000 + duration_ms, 3);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyStarted)]
fun test_start_trading_twice_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 1000, &clock);
    market_state::start_trading(&mut state, 1000, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EInvalidDuration)]
fun test_start_trading_zero_duration_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 0, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EInvalidDuration)]
fun test_start_trading_excessive_duration_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    // Try to start with > 30 days
    let invalid_duration = 31 * 24 * 60 * 60 * 1000;
    market_state::start_trading(&mut state, invalid_duration, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_end_trading() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);

    // Advance time and end trading
    clock.set_for_testing(12000);
    market_state::end_trading(&mut state, &clock);

    // Trading should no longer be active
    assert!(!market_state::is_trading_active(&state), 0);
    assert!(!market_state::is_finalized(&state), 1);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingNotStarted)]
fun test_end_trading_before_start_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::end_trading(&mut state, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyEnded)]
fun test_end_trading_twice_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);
    market_state::end_trading(&mut state, &clock);
    market_state::end_trading(&mut state, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_finalize() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);
    clock.set_for_testing(12000);
    market_state::end_trading(&mut state, &clock);

    clock.set_for_testing(15000);
    market_state::finalize(&mut state, 0, &clock);

    // Verify finalized
    assert!(market_state::is_finalized(&state), 0);
    assert!(market_state::get_winning_outcome(&state) == 0, 1);

    let fin_time = market_state::get_finalization_time(&state);
    assert!(fin_time.is_some(), 2);
    assert!(*fin_time.borrow() == 15000, 3);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingNotEnded)]
fun test_finalize_before_trading_ends_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);
    market_state::finalize(&mut state, 0, &clock); // Should fail - trading not ended

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EAlreadyFinalized)]
fun test_finalize_twice_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);
    market_state::end_trading(&mut state, &clock);
    market_state::finalize(&mut state, 0, &clock);
    market_state::finalize(&mut state, 1, &clock); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EOutcomeOutOfBounds)]
fun test_finalize_invalid_outcome_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2, // Only 2 outcomes (0 and 1)
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);
    market_state::end_trading(&mut state, &clock);
    market_state::finalize(&mut state, 2, &clock); // Should fail - outcome 2 doesn't exist

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === Full Lifecycle Test ===

#[test]
fun test_complete_lifecycle() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(0);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        3,
        vector[
            string::utf8(b"Outcome A"),
            string::utf8(b"Outcome B"),
            string::utf8(b"Outcome C"),
        ],
        &clock,
        ts::ctx(&mut scenario)
    );

    // Phase 1: Pre-trading
    assert!(!market_state::is_trading_active(&state), 0);
    assert!(!market_state::is_finalized(&state), 1);

    // Phase 2: Start trading
    let duration = 7 * 24 * 60 * 60 * 1000; // 7 days
    market_state::start_trading(&mut state, duration, &clock);
    assert!(market_state::is_trading_active(&state), 2);

    // Phase 3: Trading period
    clock.set_for_testing(duration / 2); // Halfway through
    assert!(market_state::is_trading_active(&state), 3);

    // Phase 4: End trading
    clock.set_for_testing(duration + 1000);
    market_state::end_trading(&mut state, &clock);
    assert!(!market_state::is_trading_active(&state), 4);

    // Phase 5: Finalize
    clock.set_for_testing(duration + 2000);
    market_state::finalize(&mut state, 1, &clock);
    assert!(market_state::is_finalized(&state), 5);
    assert!(market_state::get_winning_outcome(&state) == 1, 6);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === Assertion Function Tests ===

#[test]
fun test_assert_trading_active() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);
    market_state::assert_trading_active(&state); // Should not abort

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingNotStarted)]
fun test_assert_trading_active_before_start_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::assert_trading_active(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyEnded)]
fun test_assert_trading_active_after_end_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);
    market_state::end_trading(&mut state, &clock);
    market_state::assert_trading_active(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_assert_in_trading_or_pre_trading() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    // Should pass in pre-trading
    market_state::assert_in_trading_or_pre_trading(&state);

    // Should pass during trading
    market_state::start_trading(&mut state, 10000, &clock);
    market_state::assert_in_trading_or_pre_trading(&state);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ETradingAlreadyEnded)]
fun test_assert_in_trading_or_pre_trading_after_end_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);
    market_state::end_trading(&mut state, &clock);
    market_state::assert_in_trading_or_pre_trading(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_assert_market_finalized() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::start_trading(&mut state, 10000, &clock);
    market_state::end_trading(&mut state, &clock);
    market_state::finalize(&mut state, 0, &clock);

    market_state::assert_market_finalized(&state); // Should not abort

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ENotFinalized)]
fun test_assert_market_finalized_before_finalize_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::assert_market_finalized(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
fun test_validate_outcome() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        3, // 3 outcomes: 0, 1, 2
        vector[string::utf8(b"A"), string::utf8(b"B"), string::utf8(b"C")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::validate_outcome(&state, 0); // OK
    market_state::validate_outcome(&state, 1); // OK
    market_state::validate_outcome(&state, 2); // OK

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EOutcomeOutOfBounds)]
fun test_validate_outcome_out_of_bounds_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2, // Only outcomes 0 and 1
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    market_state::validate_outcome(&state, 2); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === Getter Tests ===

#[test]
fun test_get_outcome_message() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        3,
        vector[
            string::utf8(b"Option A"),
            string::utf8(b"Option B"),
            string::utf8(b"Option C"),
        ],
        &clock,
        ts::ctx(&mut scenario)
    );

    assert!(market_state::get_outcome_message(&state, 0) == string::utf8(b"Option A"), 0);
    assert!(market_state::get_outcome_message(&state, 1) == string::utf8(b"Option B"), 1);
    assert!(market_state::get_outcome_message(&state, 2) == string::utf8(b"Option C"), 2);

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::EOutcomeOutOfBounds)]
fun test_get_outcome_message_out_of_bounds_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    let _ = market_state::get_outcome_message(&state, 5); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

#[test]
#[expected_failure(abort_code = market_state::ENotFinalized)]
fun test_get_winning_outcome_before_finalize_fails() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    let _ = market_state::get_winning_outcome(&state); // Should fail

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}

// === Early Resolve Metrics Tests ===

#[test]
fun test_new_early_resolve_metrics() {
    let metrics = market_state::new_early_resolve_metrics(1, 5000);
    // Just test that constructor works - metrics struct has no public getters
    destroy(metrics);
}

#[test]
fun test_init_early_resolve_metrics() {
    let (mut scenario, mut clock) = start();
    clock.set_for_testing(1000);

    let mut state = market_state::new(
        object::id_from_address(@0x1),
        object::id_from_address(@0x2),
        2,
        vector[string::utf8(b"A"), string::utf8(b"B")],
        &clock,
        ts::ctx(&mut scenario)
    );

    assert!(!market_state::has_early_resolve_metrics(&state), 0);

    // Note: init_early_resolve_metrics is package-only, so we can't test it directly
    // But we can verify the getter works after using test helpers

    market_state::destroy_for_testing(state);
    end(scenario, clock);
}
