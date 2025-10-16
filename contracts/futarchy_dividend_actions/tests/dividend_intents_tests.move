/// Tests for dividend_intents module
#[test_only]
module futarchy_dividend_actions::dividend_intents_tests;

use account_protocol::intents::{Self, Intent};
use account_protocol::version_witness;
use futarchy_dividend_actions::dividend_intents;
use std::string;
use sui::clock::{Self, Clock};
use sui::object;
use sui::test_scenario as ts;
use sui::test_utils;

const ADMIN: address = @0xAD;

// Test coin type
public struct USDC has drop {}

// Test outcome type
public struct TestOutcome has drop, store {}

// Helper to create test intent
fun create_test_intent(ctx: &mut TxContext): Intent<TestOutcome> {
    let version = version_witness::test_version();
    intents::new_intent_for_testing<TestOutcome>(version, ctx)
}

#[test]
fun test_create_dividend_in_intent() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};
    let tree_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001234,
    );

    dividend_intents::create_dividend_in_intent<TestOutcome, USDC, TestOutcome>(
        &mut intent,
        tree_id,
        witness,
    );

    // Verify action was added
    assert!(intents::action_count(&intent) == 1, 0);

    test_utils::destroy(intent);
    ts::end(scenario);
}

#[test]
fun test_create_dividend_key() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, 1234567890);

    let key = dividend_intents::create_dividend_key(
        string::utf8(b"create"),
        &clock,
    );

    // Key should be "dividend_create_1234567890"
    assert!(key == string::utf8(b"dividend_create_1234567890"), 0);

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_create_dividend_key_different_operations() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, 1000);

    let key1 = dividend_intents::create_dividend_key(string::utf8(b"claim"), &clock);
    let key2 = dividend_intents::create_dividend_key(string::utf8(b"cancel"), &clock);

    // Different operations should create different keys
    assert!(key1 != key2, 0);
    assert!(key1 == string::utf8(b"dividend_claim_1000"), 1);
    assert!(key2 == string::utf8(b"dividend_cancel_1000"), 2);

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_create_dividend_key_different_times() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    clock::set_for_testing(&mut clock, 1000);
    let key1 = dividend_intents::create_dividend_key(string::utf8(b"test"), &clock);

    clock::set_for_testing(&mut clock, 2000);
    let key2 = dividend_intents::create_dividend_key(string::utf8(b"test"), &clock);

    // Same operation at different times should create different keys
    assert!(key1 != key2, 0);

    test_utils::destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_multiple_dividend_actions_in_intent() {
    let mut scenario = ts::begin(ADMIN);

    let mut intent = create_test_intent(ts::ctx(&mut scenario));
    let witness = TestOutcome {};

    let tree_id1 = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000001111,
    );
    let tree_id2 = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000002222,
    );

    // Add multiple dividend actions
    dividend_intents::create_dividend_in_intent<TestOutcome, USDC, TestOutcome>(
        &mut intent,
        tree_id1,
        witness,
    );

    dividend_intents::create_dividend_in_intent<TestOutcome, USDC, TestOutcome>(
        &mut intent,
        tree_id2,
        witness,
    );

    // Verify both actions were added
    assert!(intents::action_count(&intent) == 2, 0);

    test_utils::destroy(intent);
    ts::end(scenario);
}
