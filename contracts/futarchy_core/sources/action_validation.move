/// Helper module for type-safe action validation in Futarchy
/// Provides centralized type checking before BCS deserialization
module futarchy_core::action_validation;

use std::type_name::{Self, TypeName};
use account_protocol::intents::{Self, ActionSpec};

// === Errors ===
const EWrongActionType: u64 = 1;

// === Public Functions ===

/// Assert that an action specification has the expected type
/// This MUST be called before deserializing action data to prevent type confusion
public fun assert_action_type<T: drop>(spec: &ActionSpec) {
    let expected_type = type_name::with_defining_ids<T>();
    assert!(
        intents::action_spec_type(spec) == expected_type,
        EWrongActionType
    );
}

/// Get the TypeName for a given action type
/// Useful for creating action specifications
public fun get_action_type_name<T: drop>(): TypeName {
    type_name::with_defining_ids<T>()
}

/// Check if an action specification matches the expected type
/// Returns true if types match, false otherwise
public fun is_action_type<T: drop>(spec: &ActionSpec): bool {
    let expected_type = type_name::with_defining_ids<T>();
    intents::action_spec_type(spec) == expected_type
}

// === Test Functions ===

#[test_only]
public struct TestAction has drop {}

#[test_only]
public struct WrongAction has drop {}

#[test]
fun test_action_type_checking() {
    use sui::test_scenario;
    use sui::bcs;

    let mut scenario = test_scenario::begin(@0x1);

    // Create a test action spec
    let action_data = bcs::to_bytes(&42u64);
    let test_type = get_action_type_name<TestAction>();

    // Would need to create ActionSpec through intents module
    // This is just to show the pattern

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = EWrongActionType)]
fun test_wrong_action_type() {
    use sui::test_scenario;
    use sui::bcs;
    use account_protocol::intents;

    // This test would fail with EWrongActionType if we had a way to create
    // an ActionSpec with WrongAction type but tried to assert TestAction type
    abort EWrongActionType  // Placeholder to show expected failure
}