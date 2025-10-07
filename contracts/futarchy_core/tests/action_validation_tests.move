#[test_only]
module futarchy_core::action_validation_tests;

use futarchy_core::action_validation;
use std::type_name;
use sui::bcs;
use sui::test_scenario as ts;
use account_protocol::intents::{Self, ActionSpec};

const ADMIN: address = @0xAD;

// Test action types
public struct TestAction has drop {}
public struct WrongAction has drop {}
public struct AnotherAction has drop {}

// === Basic Type Checking Tests ===

#[test]
fun test_get_action_type_name() {
    let test_type = action_validation::get_action_type_name<TestAction>();
    let expected = type_name::with_defining_ids<TestAction>();

    assert!(test_type == expected, 0);
}

#[test]
fun test_get_action_type_name_different_types() {
    let test_type = action_validation::get_action_type_name<TestAction>();
    let wrong_type = action_validation::get_action_type_name<WrongAction>();

    assert!(test_type != wrong_type, 0);
}

#[test]
fun test_assert_action_type_correct() {
    let mut scenario = ts::begin(ADMIN);

    // Create action data
    let action_data = bcs::to_bytes(&42u64);

    // Create ActionSpec with correct signature
    let spec = intents::new_action_spec<TestAction>(action_data, 1u8);

    // Should NOT abort - correct type
    action_validation::assert_action_type<TestAction>(&spec);

    // ActionSpec has drop ability, no need to destroy
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = action_validation::EWrongActionType)]
fun test_assert_action_type_wrong() {
    let mut scenario = ts::begin(ADMIN);

    // Create action data
    let action_data = bcs::to_bytes(&42u64);

    // Create ActionSpec with WrongAction type
    let spec = intents::new_action_spec<WrongAction>(action_data, 1u8);

    // Should abort - trying to assert TestAction but spec has WrongAction
    action_validation::assert_action_type<TestAction>(&spec);

    ts::end(scenario);
}

#[test]
fun test_is_action_type_correct() {
    let mut scenario = ts::begin(ADMIN);

    let action_data = bcs::to_bytes(&42u64);

    let spec = intents::new_action_spec<TestAction>(action_data, 1u8);

    assert!(action_validation::is_action_type<TestAction>(&spec), 0);
    assert!(!action_validation::is_action_type<WrongAction>(&spec), 1);

    ts::end(scenario);
}

#[test]
fun test_is_action_type_wrong() {
    let mut scenario = ts::begin(ADMIN);

    let action_data = bcs::to_bytes(&42u64);

    let spec = intents::new_action_spec<WrongAction>(action_data, 1u8);

    assert!(!action_validation::is_action_type<TestAction>(&spec), 0);
    assert!(action_validation::is_action_type<WrongAction>(&spec), 1);

    ts::end(scenario);
}

// === Multiple Type Validation Tests ===

#[test]
fun test_validate_multiple_different_types() {
    let mut scenario = ts::begin(ADMIN);

    // Create specs for different action types
    let action_data = bcs::to_bytes(&42u64);

    let test_spec = intents::new_action_spec<TestAction>(action_data, 1u8);
    let wrong_spec = intents::new_action_spec<WrongAction>(bcs::to_bytes(&99u64), 1u8);
    let another_spec = intents::new_action_spec<AnotherAction>(bcs::to_bytes(&123u64), 1u8);

    // Validate each has correct type
    assert!(action_validation::is_action_type<TestAction>(&test_spec), 0);
    assert!(action_validation::is_action_type<WrongAction>(&wrong_spec), 1);
    assert!(action_validation::is_action_type<AnotherAction>(&another_spec), 2);

    // Cross-check they don't match wrong types
    assert!(!action_validation::is_action_type<WrongAction>(&test_spec), 3);
    assert!(!action_validation::is_action_type<AnotherAction>(&test_spec), 4);
    assert!(!action_validation::is_action_type<TestAction>(&wrong_spec), 5);

    ts::end(scenario);
}

// === Empty vs Non-Empty Action Data Tests ===

#[test]
fun test_validate_empty_action_data() {
    let mut scenario = ts::begin(ADMIN);

    // Empty action data (empty struct)
    let empty_data = vector::empty<u8>();

    let spec = intents::new_action_spec<TestAction>(empty_data, 1u8);

    // Should still validate type correctly
    action_validation::assert_action_type<TestAction>(&spec);

    ts::end(scenario);
}

#[test]
fun test_validate_complex_action_data() {
    let mut scenario = ts::begin(ADMIN);

    // Complex nested data
    let data = bcs::to_bytes(&vector[
        bcs::to_bytes(&42u64),
        bcs::to_bytes(&@0xCAFE),
        bcs::to_bytes(&b"test"),
    ]);

    let spec = intents::new_action_spec<TestAction>(data, 1u8);

    // Type validation independent of data complexity
    action_validation::assert_action_type<TestAction>(&spec);

    ts::end(scenario);
}

// === Type Safety Boundary Tests ===

#[test]
fun test_type_names_are_unique() {
    // Ensure different types have different TypeNames
    let test_type = action_validation::get_action_type_name<TestAction>();
    let wrong_type = action_validation::get_action_type_name<WrongAction>();
    let another_type = action_validation::get_action_type_name<AnotherAction>();

    assert!(test_type != wrong_type, 0);
    assert!(test_type != another_type, 1);
    assert!(wrong_type != another_type, 2);
}

#[test]
fun test_type_name_deterministic() {
    // Getting type name multiple times returns same value
    let type1 = action_validation::get_action_type_name<TestAction>();
    let type2 = action_validation::get_action_type_name<TestAction>();

    assert!(type1 == type2, 0);
}

#[test]
#[expected_failure(abort_code = action_validation::EWrongActionType)]
fun test_assert_fails_on_any_mismatch() {
    let mut scenario = ts::begin(ADMIN);

    let action_data = bcs::to_bytes(&42u64);

    let spec = intents::new_action_spec<AnotherAction>(action_data, 1u8);

    // Should abort - spec has AnotherAction, asserting TestAction
    action_validation::assert_action_type<TestAction>(&spec);

    ts::end(scenario);
}

// === Practical Usage Pattern Tests ===

#[test]
fun test_type_dispatch_pattern() {
    let mut scenario = ts::begin(ADMIN);

    // Simulate dispatcher pattern: check type then process
    let action_data = bcs::to_bytes(&42u64);

    let spec = intents::new_action_spec<TestAction>(action_data, 1u8);

    // Check type before processing
    if (action_validation::is_action_type<TestAction>(&spec)) {
        // Process as TestAction
        action_validation::assert_action_type<TestAction>(&spec);
    } else if (action_validation::is_action_type<WrongAction>(&spec)) {
        // Would process as WrongAction
        abort 999  // Should not reach here
    };

    ts::end(scenario);
}

#[test]
fun test_defensive_type_check_before_deserialize() {
    let mut scenario = ts::begin(ADMIN);

    // Best practice: validate type before BCS deserialization
    let action_data = bcs::to_bytes(&42u64);

    let spec = intents::new_action_spec<TestAction>(action_data, 1u8);

    // 1. Validate type
    action_validation::assert_action_type<TestAction>(&spec);

    // 2. Safe to deserialize knowing type is correct
    let data = intents::action_spec_data(&spec);
    let mut reader = bcs::new(*data);
    let _value: u64 = bcs::peel_u64(&mut reader);

    ts::end(scenario);
}
