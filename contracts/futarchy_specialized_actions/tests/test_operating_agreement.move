#[test_only]
module futarchy_specialized_actions::test_operating_agreement;

use sui::test_scenario;
use sui::clock;
use futarchy_specialized_actions::operating_agreement;
use futarchy_specialized_actions::operating_agreement_actions;

/// Test that the public wrapper functions work with real Clock
#[test]
fun test_operating_agreement_with_real_clock() {
    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    // Create a real clock (shared object in production)
    let clock = clock::create_for_testing(ctx);

    // Create operating agreement
    let mut agreement = operating_agreement::new(
        object::new(ctx),  // dao_id
        vector[],          // initial_lines
        vector[],          // difficulties
        vector[],          // immutable_lines
        true,              // allow_insert
        true,              // allow_remove
        &clock,
        ctx
    );

    // Test update_line with real clock
    let line_id = operating_agreement::insert_line_at_beginning(
        &mut agreement,
        b"Test line".to_string(),
        100,
        &clock,
        ctx
    );

    operating_agreement::update_line(
        &mut agreement,
        line_id,
        b"Updated line".to_string(),
        &clock
    );

    // Test remove_line with real clock
    operating_agreement::remove_line(
        &mut agreement,
        line_id,
        &clock
    );

    // Cleanup
    clock::destroy_for_testing(clock);
    operating_agreement::destroy(agreement);
    test_scenario::end(scenario);
}

/// Test that the action functions work correctly
#[test]
fun test_operating_agreement_actions() {
    use account_protocol::intents;
    use futarchy_core::outcome;

    let mut scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);

    // Create an intent
    let outcome = outcome::new_fail_outcome();
    let mut intent = intents::new_intent(
        @0x1,  // issuer
        vector[],  // roles
        option::none(),  // expiration
        outcome,
        ctx
    );

    // Test adding create operating agreement action
    operating_agreement_actions::new_create_operating_agreement(
        &mut intent,
        true,   // allow_insert
        false,  // allow_remove
        TestWitness {}
    );

    // Test adding update line action
    let dummy_id = object::id_from_address(@0x123);
    operating_agreement_actions::new_update_line(
        &mut intent,
        dummy_id,
        b"New text".to_string(),
        TestWitness {}
    );

    intents::destroy_intent_for_testing(intent);
    test_scenario::end(scenario);
}

public struct TestWitness has drop {}