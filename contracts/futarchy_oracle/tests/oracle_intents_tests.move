/// Comprehensive tests for oracle_intents module
#[test_only]
module futarchy_oracle::oracle_intents_tests;

use account_protocol::intents::{Self, Intent};
use account_protocol::version_witness;
use futarchy_core::action_types;
use futarchy_oracle::oracle_intents;
use std::string;
use sui::clock::{Self, Clock};
use sui::object;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils;

// Test addresses
const ADMIN: address = @0xAD;
const RECIPIENT1: address = @0x0000000000000000000000000000000000000000000000000000000000000001;
const RECIPIENT2: address = @0x0000000000000000000000000000000000000000000000000000000000000002;

// Test coin types
public struct ASSET has drop {}
public struct STABLE has drop {}

// Test outcome type
public struct TestOutcome has drop, store {}

// Helper to create test intent
fun create_test_intent(ctx: &mut TxContext): Intent<TestOutcome> {
    let version = version_witness::test_version();
    intents::new_intent_for_testing<TestOutcome>(version, ctx)
}

// === Basic Intent Builder Tests ===

#[test]
fun test_create_grant_in_intent_single_recipient() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, 1000);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};

    oracle_intents::create_grant_in_intent<TestOutcome, ASSET, STABLE, TestOutcome>(
        &mut intent,
        vector[RECIPIENT1],
        vector[100_000],
        0, // vesting_mode
        3, // cliff_months
        4, // vesting_years
        0, // strike_mode
        1_000_000, // strike_price
        2_000_000_000, // launchpad_multiplier
        0, // cooldown_ms
        1, // max_executions
        0, // earliest_execution_offset_ms
        10, // expiry_years
        0, // price_condition_mode
        0, // price_threshold
        false, // price_is_above
        true, // cancelable
        string::utf8(b"Test grant"),
        witness,
    );

    // Verify action was added
    assert!(intents::action_count(&intent) == 1, 0);

    test_utils::destroy(intent);
    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_create_grant_in_intent_multiple_recipients() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};

    oracle_intents::create_grant_in_intent<TestOutcome, ASSET, STABLE, TestOutcome>(
        &mut intent,
        vector[RECIPIENT1, RECIPIENT2],
        vector[100_000, 200_000],
        0,
        3,
        4,
        0,
        1_000_000,
        2_000_000_000,
        0,
        1,
        0,
        10,
        0,
        0,
        false,
        true,
        string::utf8(b"Multi recipient"),
        witness,
    );

    assert!(intents::action_count(&intent) == 1, 0);

    test_utils::destroy(intent);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)]
fun test_create_grant_in_intent_empty_recipients_fails() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};

    oracle_intents::create_grant_in_intent<TestOutcome, ASSET, STABLE, TestOutcome>(
        &mut intent,
        vector[], // Empty recipients - should fail
        vector[],
        0,
        3,
        4,
        0,
        1_000_000,
        2_000_000_000,
        0,
        1,
        0,
        10,
        0,
        0,
        false,
        true,
        string::utf8(b"Empty"),
        witness,
    );

    test_utils::destroy(intent);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)]
fun test_create_grant_in_intent_mismatched_lengths_fails() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};

    oracle_intents::create_grant_in_intent<TestOutcome, ASSET, STABLE, TestOutcome>(
        &mut intent,
        vector[RECIPIENT1, RECIPIENT2],
        vector[100_000], // Mismatched length - should fail
        0,
        3,
        4,
        0,
        1_000_000,
        2_000_000_000,
        0,
        1,
        0,
        10,
        0,
        0,
        false,
        true,
        string::utf8(b"Mismatched"),
        witness,
    );

    test_utils::destroy(intent);
    ts::end(scenario);
}

#[test]
fun test_cancel_grant_in_intent() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};
    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );

    oracle_intents::cancel_grant_in_intent<TestOutcome, TestOutcome>(
        &mut intent,
        grant_id,
        witness,
    );

    assert!(intents::action_count(&intent) == 1, 0);

    test_utils::destroy(intent);
    ts::end(scenario);
}

#[test]
fun test_pause_grant_in_intent() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};
    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );

    oracle_intents::pause_grant_in_intent<TestOutcome, TestOutcome>(
        &mut intent,
        grant_id,
        86400000, // 1 day pause
        witness,
    );

    assert!(intents::action_count(&intent) == 1, 0);

    test_utils::destroy(intent);
    ts::end(scenario);
}

#[test]
fun test_unpause_grant_in_intent() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};
    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );

    oracle_intents::unpause_grant_in_intent<TestOutcome, TestOutcome>(
        &mut intent,
        grant_id,
        witness,
    );

    assert!(intents::action_count(&intent) == 1, 0);

    test_utils::destroy(intent);
    ts::end(scenario);
}

#[test]
fun test_emergency_freeze_grant_in_intent() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};
    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );

    oracle_intents::emergency_freeze_grant_in_intent<TestOutcome, TestOutcome>(
        &mut intent,
        grant_id,
        witness,
    );

    assert!(intents::action_count(&intent) == 1, 0);

    test_utils::destroy(intent);
    ts::end(scenario);
}

#[test]
fun test_emergency_unfreeze_grant_in_intent() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};
    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );

    oracle_intents::emergency_unfreeze_grant_in_intent<TestOutcome, TestOutcome>(
        &mut intent,
        grant_id,
        witness,
    );

    assert!(intents::action_count(&intent) == 1, 0);

    test_utils::destroy(intent);
    ts::end(scenario);
}

#[test]
fun test_create_oracle_key() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, 1234567890);

    let key = oracle_intents::create_oracle_key(
        string::utf8(b"create_grant"),
        &clock,
    );

    // Key should be "oracle_create_grant_1234567890"
    assert!(key == string::utf8(b"oracle_create_grant_1234567890"), 0);

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_create_oracle_key_different_operations() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, 1000);

    let key1 = oracle_intents::create_oracle_key(string::utf8(b"cancel"), &clock);
    let key2 = oracle_intents::create_oracle_key(string::utf8(b"pause"), &clock);

    // Different operations should create different keys (even at same timestamp)
    assert!(key1 != key2, 0);
    assert!(key1 == string::utf8(b"oracle_cancel_1000"), 1);
    assert!(key2 == string::utf8(b"oracle_pause_1000"), 2);

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_create_oracle_key_different_times() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, 1000);
    let key1 = oracle_intents::create_oracle_key(string::utf8(b"test"), &clock);

    clock::set_for_testing(&mut clock, 2000);
    let key2 = oracle_intents::create_oracle_key(string::utf8(b"test"), &clock);

    // Same operation at different times should create different keys
    assert!(key1 != key2, 0);

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_multiple_actions_in_same_intent() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};
    let grant_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );

    // Add create grant action
    oracle_intents::create_grant_in_intent<TestOutcome, ASSET, STABLE, TestOutcome>(
        &mut intent,
        vector[RECIPIENT1],
        vector[100_000],
        0,
        3,
        4,
        0,
        1_000_000,
        2_000_000_000,
        0,
        1,
        0,
        10,
        0,
        0,
        false,
        true,
        string::utf8(b"Grant"),
        witness,
    );

    // Add pause action
    oracle_intents::pause_grant_in_intent<TestOutcome, TestOutcome>(
        &mut intent,
        grant_id,
        86400000,
        witness,
    );

    // Add cancel action
    oracle_intents::cancel_grant_in_intent<TestOutcome, TestOutcome>(
        &mut intent,
        grant_id,
        witness,
    );

    // Verify all 3 actions were added
    assert!(intents::action_count(&intent) == 3, 0);

    test_utils::destroy(intent);
    ts::end(scenario);
}
