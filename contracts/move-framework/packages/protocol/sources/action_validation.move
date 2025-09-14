// ============================================================================
// Action Type Validation Helper Module
// ============================================================================
// This module provides a centralized type validation helper for action handlers.
// It ensures type safety by verifying that action specs match expected types
// before deserialization, preventing type confusion vulnerabilities.
//
// SECURITY: This is a critical security module that prevents wrong actions
// from being executed by wrong handlers.
// ============================================================================

module account_protocol::action_validation;

// === Imports ===

use std::type_name::{Self, TypeName};
use account_protocol::intents::{Self, ActionSpec};

// === Errors ===

const EWrongActionType: u64 = 0;

// === Public Functions ===

/// Assert that an ActionSpec has the expected action type.
/// This MUST be called before deserializing action data in any do_* function.
///
/// # Type Parameters
/// * `T` - The expected action type (must have `drop`)
///
/// # Arguments
/// * `spec` - The ActionSpec to validate
///
/// # Aborts
/// * `EWrongActionType` - If the action type doesn't match the expected type
///
/// # Example
/// ```move
/// public fun do_spend<...>(...) {
///     let spec = specs.borrow(executable.action_idx());
///     action_validation::assert_action_type<VaultSpend>(spec);
///     // Now safe to deserialize
///     let action_data = intents::action_spec_data(spec);
/// }
/// ```
public fun assert_action_type<T: drop>(spec: &ActionSpec) {
    let expected_type = type_name::with_defining_ids<T>();
    assert!(
        intents::action_spec_type(spec) == expected_type,
        EWrongActionType
    );
}

/// Assert that an ActionSpec has the expected action type with custom error.
/// Useful when modules want to use their own error codes.
///
/// # Type Parameters
/// * `T` - The expected action type (must have `drop`)
///
/// # Arguments
/// * `spec` - The ActionSpec to validate
/// * `error_code` - Custom error code to use if validation fails
///
/// # Aborts
/// * Custom error code if the action type doesn't match
public fun assert_action_type_with_error<T: drop>(
    spec: &ActionSpec,
    error_code: u64
) {
    let expected_type = type_name::with_defining_ids<T>();
    assert!(
        intents::action_spec_type(spec) == expected_type,
        error_code
    );
}

/// Check if an ActionSpec matches the expected type without aborting.
/// Returns true if types match, false otherwise.
///
/// # Type Parameters
/// * `T` - The expected action type (must have `drop`)
///
/// # Arguments
/// * `spec` - The ActionSpec to check
///
/// # Returns
/// * `bool` - true if action type matches, false otherwise
public fun is_action_type<T: drop>(spec: &ActionSpec): bool {
    let expected_type = type_name::with_defining_ids<T>();
    intents::action_spec_type(spec) == expected_type
}

/// Get the TypeName for a given action type.
/// Useful for modules that need to work with TypeNames directly.
///
/// # Type Parameters
/// * `T` - The action type (must have `drop`)
///
/// # Returns
/// * `TypeName` - The TypeName of the action type
public fun get_action_type_name<T: drop>(): TypeName {
    type_name::with_defining_ids<T>()
}

// === Test Functions ===

#[test_only]
use account_protocol::intents::test_helpers;

#[test_only]
public struct TestAction has drop {}

#[test_only]
public struct WrongAction has drop {}

#[test]
fun test_assert_action_type_success() {
    let spec = test_helpers::create_test_action_spec<TestAction>();
    assert_action_type<TestAction>(&spec);
    // Should not abort
}

#[test]
#[expected_failure(abort_code = EWrongActionType)]
fun test_assert_action_type_failure() {
    let spec = test_helpers::create_test_action_spec<TestAction>();
    assert_action_type<WrongAction>(&spec);
    // Should abort with EWrongActionType
}

#[test]
fun test_is_action_type() {
    let spec = test_helpers::create_test_action_spec<TestAction>();
    assert!(is_action_type<TestAction>(&spec));
    assert!(!is_action_type<WrongAction>(&spec));
}

#[test]
#[expected_failure(abort_code = 999)]
fun test_assert_action_type_with_custom_error() {
    let spec = test_helpers::create_test_action_spec<TestAction>();
    assert_action_type_with_error<WrongAction>(&spec, 999);
    // Should abort with custom error 999
}