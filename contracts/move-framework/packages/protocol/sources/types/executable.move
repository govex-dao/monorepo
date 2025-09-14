// ============================================================================
// FORK MODIFICATION NOTICE - Type-Based Executable Hot Potato
// ============================================================================
// Hot potato ensuring actions are executed as intended (can't be stored).
//
// CHANGES IN THIS FORK:
// - Added type_name imports for type-based action routing
// - Added current_action_type() to get the TypeName of current action
// - Added is_current_action<T>() to check if current action matches type T
// - Added peek_next_action_type() to look ahead at next action's type
// - Added find_action_by_type<T>() to search for specific action types
// - Added ExecutionContext for passing data between actions
//
// RATIONALE:
// Enables compile-time type safety for action execution, replacing the
// previous string-based descriptor system with type checking.
// ============================================================================
/// The Executable struct is hot potato constructed from an Intent that has been resolved.
/// It ensures that the actions are executed as intended as it can't be stored.
/// Action index is tracked to ensure each action is executed exactly once.

module account_protocol::executable;

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::table::{Self, Table};
use sui::object::{Self, ID};
use sui::tx_context::TxContext;
use account_protocol::intents::{Self, Intent};

// === Error Constants ===

const EPlaceholderAlreadyExists: u64 = 100;
const EPlaceholderNotFound: u64 = 101;
const EMaxPlaceholdersExceeded: u64 = 102;

// === Limits ===

/// Maximum number of placeholders allowed in ExecutionContext.
/// Exposed as a function to allow future upgrades to change this value.
public fun max_placeholders(): u64 { 50 }

// === Structs ===

/// The temporary "workbench" for passing data between actions in a single transaction.
/// This is embedded directly in the Executable for logical cohesion.
public struct ExecutionContext has store {
    // Maps a temporary u64 placeholder ID to the real ID of a newly created object
    created_objects: Table<u64, ID>,
}

/// Hot potato ensuring the actions in the intent are executed as intended.
/// Now enhanced with ExecutionContext for data passing between actions.
public struct Executable<Outcome: store> {
    // intent to return or destroy (if execution_times empty) after execution
    intent: Intent<Outcome>,
    // current action index for sequential processing
    action_idx: u64,
    // context for passing data between actions via placeholders
    context: ExecutionContext,
}

// === View functions ===

/// Returns the issuer of the corresponding intent
public fun intent<Outcome: store>(executable: &Executable<Outcome>): &Intent<Outcome> {
    &executable.intent
}

/// Returns the current action index
public fun action_idx<Outcome: store>(executable: &Executable<Outcome>): u64 {
    executable.action_idx
}

// Actions are now stored as BCS bytes in ActionSpec
// The dispatcher must deserialize them when needed

/// Get the type of the current action
public fun current_action_type<Outcome: store>(
    executable: &Executable<Outcome>
): TypeName {
    let specs = executable.intent().action_specs();
    intents::action_spec_type(specs.borrow(executable.action_idx))
}

/// Check if current action matches a specific type
public fun is_current_action<Outcome: store, T: store + drop + copy>(
    executable: &Executable<Outcome>
): bool {
    let current_type = current_action_type(executable);
    current_type == type_name::with_defining_ids<T>()
}

/// Get type of action at specific index
public fun action_type_at<Outcome: store>(
    executable: &Executable<Outcome>,
    idx: u64
): TypeName {
    let specs = executable.intent().action_specs();
    intents::action_spec_type(specs.borrow(idx))
}

/// Increment the action index to mark progress
public fun increment_action_idx<Outcome: store>(
    executable: &mut Executable<Outcome>
) {
    executable.action_idx = executable.action_idx + 1;
}

// === ExecutionContext Methods ===

/// Get a mutable reference to the execution context
public fun context_mut<Outcome: store>(
    executable: &mut Executable<Outcome>
): &mut ExecutionContext {
    &mut executable.context
}

/// Get a reference to the execution context
public fun context<Outcome: store>(
    executable: &Executable<Outcome>
): &ExecutionContext {
    &executable.context
}

/// Register a newly created object ID with a placeholder ID
public fun register_placeholder(
    context: &mut ExecutionContext,
    placeholder_id: u64,
    object_id: ID,
) {
    assert!(
        !table::contains(&context.created_objects, placeholder_id),
        EPlaceholderAlreadyExists
    );
    assert!(
        table::length(&context.created_objects) < max_placeholders(),
        EMaxPlaceholdersExceeded
    );
    table::add(&mut context.created_objects, placeholder_id, object_id);
}

/// Resolve a placeholder ID to get the actual object ID
public fun resolve_placeholder(
    context: &ExecutionContext,
    placeholder_id: u64,
): ID {
    assert!(
        table::contains(&context.created_objects, placeholder_id),
        EPlaceholderNotFound
    );
    *table::borrow(&context.created_objects, placeholder_id)
}

/// Check if a placeholder has been registered
public fun has_placeholder(
    context: &ExecutionContext,
    placeholder_id: u64,
): bool {
    table::contains(&context.created_objects, placeholder_id)
}

// === Package functions ===

public(package) fun new<Outcome: store>(
    intent: Intent<Outcome>,
    ctx: &mut TxContext, // Now takes TxContext to create the table
): Executable<Outcome> {
    let context = ExecutionContext {
        created_objects: table::new(ctx),
    };
    Executable { intent, action_idx: 0, context }
}

public(package) fun destroy<Outcome: store>(executable: Executable<Outcome>): Intent<Outcome> {
    let Executable { intent, context, .. } = executable;
    // Clean up the context's table
    let ExecutionContext { created_objects } = context;
    table::destroy_empty(created_objects);
    intent
}

//**************************************************************************************************//
// Tests                                                                                            //
//**************************************************************************************************//

#[test_only]
use sui::test_utils::{assert_eq, destroy as test_destroy};
#[test_only]
use sui::clock;
#[test_only]
use account_protocol::intents;

#[test_only]
public struct TestOutcome has copy, drop, store {}
#[test_only]
public struct TestAction has store {}
#[test_only]
public struct TestActionType has drop {}
#[test_only]
public struct TestIntentWitness() has drop;

#[test]
fun test_new_executable() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = intents::new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    let executable = new(intent, ctx);

    assert_eq(action_idx(&executable), 0);
    assert_eq(intent(&executable).key(), b"test_key".to_string());
    
    test_destroy(executable);
    test_destroy(clock);
}

#[test]
fun test_next_action() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    intents::add_typed_action(&mut intent, TestAction {}, TestActionType {}, TestIntentWitness());
    intents::add_typed_action(&mut intent, TestAction {}, TestActionType {}, TestIntentWitness());
    
    let mut executable = new(intent, ctx);
    
    assert_eq(action_idx(&executable), 0);
    
    let _action1: &TestAction = next_action(&mut executable, TestIntentWitness());
    assert_eq(action_idx(&executable), 1);
    
    let _action2: &TestAction = next_action(&mut executable, TestIntentWitness());
    assert_eq(action_idx(&executable), 2);
    
    test_destroy(executable);
    test_destroy(clock);
}

#[test]
fun test_contains_action() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    intents::add_typed_action(&mut intent, TestAction {}, TestActionType {}, TestIntentWitness());
    
    let mut executable = new(intent, ctx);
    
    assert!(contains_action<_, TestAction>(&mut executable));
    
    test_destroy(executable);
    test_destroy(clock);
}

#[test]
fun test_contains_action_empty() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = intents::new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    let mut executable = new(intent, ctx);
    
    assert!(!contains_action<_, TestAction>(&mut executable));
    
    test_destroy(executable);
    test_destroy(clock);
}

#[test]
fun test_destroy_executable() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = intents::new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    let executable = new(intent, ctx);
    let recovered_intent = destroy(executable);
    
    assert_eq(recovered_intent.key(), b"test_key".to_string());
    assert_eq(recovered_intent.description(), b"test_description".to_string());
    
    test_destroy(recovered_intent);
    test_destroy(clock);
}

#[test]
fun test_executable_with_multiple_actions() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let mut intent = intents::new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    // Add multiple actions
    intents::add_typed_action(&mut intent, TestAction {}, TestActionType {}, TestIntentWitness());
    intents::add_typed_action(&mut intent, TestAction {}, TestActionType {}, TestIntentWitness());
    intents::add_typed_action(&mut intent, TestAction {}, TestActionType {}, TestIntentWitness());
    
    let mut executable = new(intent, ctx);
    
    assert_eq(action_idx(&executable), 0);
    assert_eq(intent(&executable).actions().length(), 3);
    
    // Execute all actions
    let _action1: &TestAction = next_action(&mut executable, TestIntentWitness());
    let _action2: &TestAction = next_action(&mut executable, TestIntentWitness());
    let _action3: &TestAction = next_action(&mut executable, TestIntentWitness());
    
    assert_eq(action_idx(&executable), 3);
    
    test_destroy(executable);
    test_destroy(clock);
}

#[test]
fun test_intent_access() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = intents::new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = intents::new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    let executable = new(intent, ctx);
    let intent_ref = intent(&executable);
    
    assert_eq(intent_ref.key(), b"test_key".to_string());
    assert_eq(intent_ref.description(), b"test_description".to_string());
    assert_eq(intent_ref.account(), @0xCAFE);
    let mut role = @account_protocol.to_string();
    role.append_utf8(b"::executable");
    role.append_utf8(b"::test_role");
    assert_eq(intent_ref.role(), role);
    
    test_destroy(executable);
    test_destroy(clock);
}

