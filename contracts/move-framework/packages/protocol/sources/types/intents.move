// ============================================================================
// FORK MODIFICATION NOTICE - Intents with Serialize-Then-Destroy Pattern
// ============================================================================
// Core module managing Intents with type-safe action execution.
//
// MAJOR CHANGES IN THIS FORK:
//
// 1. REMOVED OBJECT LOCKING:
//    - No locking - multiple intents can reference same objects
//    - Conflicts resolved naturally by blockchain (first to execute wins)
//
// 2. SERIALIZE-THEN-DESTROY PATTERN:
//    - add_typed_action() now accepts pre-serialized bytes instead of action structs
//    - Enables explicit destruction of action structs after serialization
//    - Maintains BCS compatibility while improving resource safety
//
// 3. TYPE-BASED ACTION SYSTEM:
//    Original: Used action_descriptors with string categories (b"treasury")
//    New: Uses action_types: vector<TypeName> for compile-time safety
//    - Removed dependency on action_descriptor module
//    - Added add_typed_action<Outcome, Action, T, IW>() with compile-time types
//    - Type names captured using type_name::with_defining_ids<T>() for zero-overhead routing
//
// BENEFITS:
// - Eliminates risk of permanently locked objects from incomplete cleanup
// - Compile-time type safety for all actions
// - Better gas efficiency (no string comparisons)
// - Simplifies codebase by ~100 lines
// - Better suits DAO governance where competing proposals are natural
// ============================================================================
/// This is the core module managing Intents.
/// It provides the interface to create and execute intents which is used in the `account` module.
/// In the new design, there is no locking - multiple intents can reference the same objects.
/// Conflicts are resolved naturally: if coinA is withdrawn by intent1, intent2 will fail when it tries.

module account_protocol::intents;

// === Imports ===

use std::{
    string::String,
    type_name::{Self, TypeName},
    bcs,
    vector,
};
use sui::{
    bag::{Self, Bag},
    dynamic_field,
    clock::Clock,
    object::{Self, ID},
};

// === Aliases ===

use fun dynamic_field::add as UID.df_add;
use fun dynamic_field::borrow as UID.df_borrow;
use fun dynamic_field::remove as UID.df_remove;
// Type-based action system - no string descriptors

// === Errors ===

const EIntentNotFound: u64 = 0;
// REMOVED: EObjectAlreadyLocked and EObjectNotLocked - no locking in new design
const ENoExecutionTime: u64 = 3;
const EExecutionTimesNotAscending: u64 = 4;
const EActionsNotEmpty: u64 = 5;
const EKeyAlreadyExists: u64 = 6;
const EWrongAccount: u64 = 7;
const EWrongWitness: u64 = 8;
const ESingleExecution: u64 = 9;
const EMaxPlaceholdersExceeded: u64 = 10;
const EUnsupportedActionVersion: u64 = 11;
const EActionDataTooLarge: u64 = 12;

// Version constants
const CURRENT_ACTION_VERSION: u8 = 1;

// === Limits ===

/// Maximum number of placeholders allowed in a single intent.
/// Exposed as a function to allow future upgrades to change this value.
public fun max_placeholders(): u64 { 50 }

/// Maximum size for action data in bytes (4KB).
/// Exposed as a function to allow future upgrades to change this value.
/// Prevents excessively large action data that could cause DoS.
public fun max_action_data_size(): u64 { 4096 }

// === Structs ===

/// A blueprint for a single action within an intent.
public struct ActionSpec has store, copy, drop {
    version: u8,                // Version byte for forward compatibility
    action_type: TypeName,      // The type of the action struct
    action_data: vector<u8>,    // The BCS-serialized action struct
}

/// Create a new ActionSpec for testing
public fun new_action_spec<T>(action_data: vector<u8>, version: u8): ActionSpec {
    ActionSpec {
        version,
        action_type: type_name::with_defining_ids<T>(),
        action_data,
    }
}

/// Parent struct protecting the intents
public struct Intents has store {
    // map of intents: key -> Intent<Outcome>
    inner: Bag,
}

/// Child struct, intent owning a sequence of actions requested to be executed
/// Outcome is a custom struct depending on the config
public struct Intent<Outcome> has store {
    // type of the intent, checked against the witness to ensure correct execution
    type_: TypeName,
    // name of the intent, serves as a key, should be unique
    key: String,
    // what this intent aims to do, for informational purpose
    description: String,
    // address of the account that created the intent
    account: address,
    // address of the user that created the intent
    creator: address,
    // timestamp of the intent creation
    creation_time: u64,
    // proposer can add a timestamp_ms before which the intent can't be executed
    // can be used to schedule actions via a backend
    // recurring intents can be executed at these times
    execution_times: vector<u64>,
    // the intent can be deleted from this timestamp
    expiration_time: u64,
    // role for the intent
    role: String,
    // Structured action specifications for type-safe routing (single source of truth)
    action_specs: vector<ActionSpec>,
    // Counter for unique placeholder IDs
    next_placeholder_id: u64,
    // Generic struct storing vote related data, depends on the config
    outcome: Outcome,
}

/// Hot potato wrapping actions from an intent that expired or has been executed
public struct Expired {
    // address of the account that created the intent
    account: address,
    // action specs that expired or were executed
    action_specs: vector<ActionSpec>,
    // NEW: Track which actions were executed for proper destruction
    executed_actions: vector<bool>,
    // intent ID for tracking
    intent_id: ID,
}

/// Params of an intent to reduce boilerplate.
public struct Params has key, store {
    id: UID,
}
/// Fields are a df so it intents can be improved in the future
public struct ParamsFieldsV1 has copy, drop, store {
    key: String,
    description: String,
    creation_time: u64,
    execution_times: vector<u64>,
    expiration_time: u64,
}

// === Public functions ===

/// Reserve a placeholder ID for use during intent creation
public(package) fun reserve_placeholder_id<Outcome>(
    intent: &mut Intent<Outcome>
): u64 {
    let id = intent.next_placeholder_id;
    assert!(id < max_placeholders(), EMaxPlaceholdersExceeded);
    intent.next_placeholder_id = id + 1;
    id
}

/// Add an action specification with pre-serialized bytes (serialize-then-destroy pattern)
public fun add_action_spec<Outcome, T: drop, IW: drop>(
    intent: &mut Intent<Outcome>,
    action_type_witness: T,
    action_data_bytes: vector<u8>,
    intent_witness: IW,
) {
    intent.assert_is_witness(intent_witness);

    // Validate action data size to prevent excessively large actions
    assert!(
        action_data_bytes.length() <= max_action_data_size(),
        EActionDataTooLarge
    );

    // Create and store the action spec with BCS-serialized action
    let spec = ActionSpec {
        version: CURRENT_ACTION_VERSION,
        action_type: type_name::with_defining_ids<T>(),
        action_data: action_data_bytes,
    };
    intent.action_specs.push_back(spec);
}

public fun new_params(
    key: String,
    description: String,
    execution_times: vector<u64>,
    expiration_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Params {
    assert!(!execution_times.is_empty(), ENoExecutionTime);
    let mut i = 0;
    while (i < vector::length(&execution_times) - 1) {
        assert!(execution_times[i] <= execution_times[i + 1], EExecutionTimesNotAscending);
        i = i + 1;
    };
    
    let fields = ParamsFieldsV1 { 
        key, 
        description, 
        creation_time: clock.timestamp_ms(), 
        execution_times, 
        expiration_time 
    };
    let mut id = object::new(ctx);
    id.df_add(true, fields);

    Params { id }
}

public fun new_params_with_rand_key(
    description: String,
    execution_times: vector<u64>,
    expiration_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Params, String) {
    let key = ctx.fresh_object_address().to_string();
    let params = new_params(key, description, execution_times, expiration_time, clock, ctx);

    (params, key)
}

// REMOVED: Old add_action function without types - use add_typed_action instead

/// Add a typed action with pre-serialized bytes (serialize-then-destroy pattern)
/// Callers must serialize the action and then explicitly destroy it
public fun add_typed_action<Outcome, T: drop, IW: drop>(
    intent: &mut Intent<Outcome>,
    action_type: T,
    action_data: vector<u8>,
    intent_witness: IW,
) {
    add_action_spec(intent, action_type, action_data, intent_witness);
}

public fun remove_action_spec(
    expired: &mut Expired,
): ActionSpec {
    // Also mark as not executed when removing
    expired.executed_actions.remove(0);
    expired.action_specs.remove(0)
}

/// Mark an action as executed in the Expired struct
public fun mark_action_executed(
    expired: &mut Expired,
    index: u64,
) {
    let executed = vector::borrow_mut(&mut expired.executed_actions, index);
    *executed = true;
}

/// Check if an action was executed
public fun is_action_executed(
    expired: &Expired,
    index: u64,
): bool {
    *vector::borrow(&expired.executed_actions, index)
}

/// Get the number of actions in the Expired struct
public fun expired_action_count(expired: &Expired): u64 {
    expired.action_specs.length()
}

public use fun destroy_empty_expired as Expired.destroy_empty;
public fun destroy_empty_expired(expired: Expired) {
    let Expired { action_specs, executed_actions, .. } = expired;
    assert!(action_specs.is_empty(), EActionsNotEmpty);
    assert!(executed_actions.is_empty(), EActionsNotEmpty);
    // vectors don't need explicit destroy
}

// === View functions ===

public use fun params_key as Params.key;
public fun params_key(params: &Params): String {
    params.id.df_borrow<_, ParamsFieldsV1>(true).key
}

public use fun params_description as Params.description;
public fun params_description(params: &Params): String {
    params.id.df_borrow<_, ParamsFieldsV1>(true).description
}

public use fun params_creation_time as Params.creation_time;
public fun params_creation_time(params: &Params): u64 {
    params.id.df_borrow<_, ParamsFieldsV1>(true).creation_time
}

public use fun params_execution_times as Params.execution_times;
public fun params_execution_times(params: &Params): vector<u64> {
    params.id.df_borrow<_, ParamsFieldsV1>(true).execution_times
}

public use fun params_expiration_time as Params.expiration_time;
public fun params_expiration_time(params: &Params): u64 {
    params.id.df_borrow<_, ParamsFieldsV1>(true).expiration_time
}

public fun length(intents: &Intents): u64 {
    intents.inner.length()
}

// REMOVED: locked() getter - no longer tracking locked objects

public fun contains(intents: &Intents, key: String): bool {
    intents.inner.contains(key)
}

public fun get<Outcome: store>(intents: &Intents, key: String): &Intent<Outcome> {
    assert!(intents.inner.contains(key), EIntentNotFound);
    intents.inner.borrow(key)
}

public fun get_mut<Outcome: store>(intents: &mut Intents, key: String): &mut Intent<Outcome> {
    assert!(intents.inner.contains(key), EIntentNotFound);
    intents.inner.borrow_mut(key)
}

public fun type_<Outcome>(intent: &Intent<Outcome>): TypeName {
    intent.type_
}

public fun key<Outcome>(intent: &Intent<Outcome>): String {
    intent.key
}

public fun description<Outcome>(intent: &Intent<Outcome>): String {
    intent.description
}

public fun account<Outcome>(intent: &Intent<Outcome>): address {
    intent.account
}

public fun creator<Outcome>(intent: &Intent<Outcome>): address {
    intent.creator
}

public fun creation_time<Outcome>(intent: &Intent<Outcome>): u64 {
    intent.creation_time
}

public fun execution_times<Outcome>(intent: &Intent<Outcome>): vector<u64> {
    intent.execution_times
}

public fun expiration_time<Outcome>(intent: &Intent<Outcome>): u64 {
    intent.expiration_time
}

public fun role<Outcome>(intent: &Intent<Outcome>): String {
    intent.role
}

// Actions are now accessed through action_specs
public fun action_count<Outcome>(intent: &Intent<Outcome>): u64 {
    intent.action_specs.length()
}

public fun outcome<Outcome>(intent: &Intent<Outcome>): &Outcome {
    &intent.outcome
}

public fun outcome_mut<Outcome>(intent: &mut Intent<Outcome>): &mut Outcome {
    &mut intent.outcome
}

public fun action_specs<Outcome>(intent: &Intent<Outcome>): &vector<ActionSpec> {
    &intent.action_specs
}

public fun action_spec_version(spec: &ActionSpec): u8 {
    spec.version
}

public fun action_spec_type(spec: &ActionSpec): TypeName {
    spec.action_type
}

public fun action_spec_data(spec: &ActionSpec): &vector<u8> {
    &spec.action_data
}

public fun action_spec_action_data(spec: ActionSpec): vector<u8> {
    let ActionSpec { version: _, action_data, .. } = spec;
    action_data
}

public use fun expired_account as Expired.account;
public fun expired_account(expired: &Expired): address {
    expired.account
}

// start_index no longer exists in ActionSpec-based design

public use fun expired_action_specs as Expired.action_specs;
public fun expired_action_specs(expired: &Expired): &vector<ActionSpec> {
    &expired.action_specs
}

public fun assert_is_account<Outcome>(
    intent: &Intent<Outcome>,
    account_addr: address,
) {
    assert!(intent.account == account_addr, EWrongAccount);
}

public fun assert_is_witness<Outcome, IW: drop>(
    intent: &Intent<Outcome>,
    _: IW,
) {
    assert!(intent.type_ == type_name::with_defining_ids<IW>(), EWrongWitness);
}

public use fun assert_expired_is_account as Expired.assert_is_account;
public fun assert_expired_is_account(expired: &Expired, account_addr: address) {
    assert!(expired.account == account_addr, EWrongAccount);
}

public fun assert_single_execution(params: &Params) {
    assert!(
        params.id.df_borrow<_, ParamsFieldsV1>(true).execution_times.length() == 1, 
        ESingleExecution
    );
}

// === Package functions ===

/// The following functions are only used in the `account` module

public(package) fun empty(ctx: &mut TxContext): Intents {
    Intents { inner: bag::new(ctx) }
}

public(package) fun new_intent<Outcome, IW: drop>(
    params: Params,
    outcome: Outcome,
    managed_name: String,
    account_addr: address,
    _intent_witness: IW,
    ctx: &mut TxContext
): Intent<Outcome> {
    let Params { mut id } = params;
    
    let ParamsFieldsV1 { 
        key, 
        description, 
        creation_time, 
        execution_times, 
        expiration_time 
    } = id.df_remove(true);
    id.delete();

    Intent<Outcome> {
        type_: type_name::with_defining_ids<IW>(),
        key,
        description,
        account: account_addr,
        creator: ctx.sender(),
        creation_time,
        execution_times,
        expiration_time,
        role: new_role<IW>(managed_name),
        action_specs: vector::empty(),
        next_placeholder_id: 0,
        outcome,
    }
}

public(package) fun add_intent<Outcome: store>(
    intents: &mut Intents,
    intent: Intent<Outcome>,
) {
    assert!(!intents.contains(intent.key), EKeyAlreadyExists);
    intents.inner.add(intent.key, intent);
}

public(package) fun remove_intent<Outcome: store>(
    intents: &mut Intents,
    key: String,
): Intent<Outcome> {
    assert!(intents.contains(key), EIntentNotFound);
    intents.inner.remove(key)
}

public(package) fun pop_front_execution_time<Outcome>(
    intent: &mut Intent<Outcome>,
): u64 {
    intent.execution_times.remove(0)
}

// REMOVED: lock and unlock functions - no locking needed in the new design
// Conflicts between intents are natural in DAO governance where multiple proposals
// can compete for the same resources

/// Removes an intent being executed if the execution_time is reached
/// Outcome must be validated in AccountMultisig to be destroyed
public(package) fun destroy_intent<Outcome: store + drop>(
    intents: &mut Intents,
    key: String,
): Expired {
    let Intent<Outcome> { account, action_specs, key, .. } = intents.inner.remove(key);
    let num_actions = action_specs.length();
    let mut executed_actions = vector::empty<bool>();
    let mut i = 0;
    while (i < num_actions) {
        vector::push_back(&mut executed_actions, false);
        i = i + 1;
    };

    // ✅ FIXED: Generate unique ID from intent key for proper tracking and debugging
    // - Hash key to get exactly 32 bytes (id_from_bytes requires 32 bytes)
    // - Enables proper intent tracking in logs and events
    // - Old approach: Hardcoded @0x0 made all intents indistinguishable
    use sui::hash;
    let key_hash = hash::keccak256(&key.into_bytes());
    let intent_id = object::id_from_bytes(key_hash);

    Expired { account, action_specs, executed_actions, intent_id }
}

// === Private functions ===

fun new_role<IW: drop>(managed_name: String): String {
    let intent_type = type_name::with_defining_ids<IW>();
    let mut role = intent_type.address_string().to_string();
    role.append_utf8(b"::");
    role.append(intent_type.module_string().to_string());

    if (!managed_name.is_empty()) {
        role.append_utf8(b"::");
        role.append(managed_name);
    };

    role
}

//**************************************************************************************************//
// Tests                                                                                            //
//**************************************************************************************************//

#[test_only]
use sui::test_utils::{assert_eq, destroy};
#[test_only]
use sui::clock;

#[test_only]
public struct TestOutcome has copy, drop, store {}
#[test_only]
public struct TestAction has drop, store {}
#[test_only]
public struct TestActionType has drop {}
#[test_only]
public struct TestIntentWitness() has drop;
#[test_only]
public struct WrongWitness() has drop;

#[test]
fun test_new_params() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    assert_eq(params.key(), b"test_key".to_string());
    assert_eq(params.description(), b"test_description".to_string());
    assert_eq(params.execution_times(), vector[1000]);
    assert_eq(params.expiration_time(), 2000);
    assert_eq(params.creation_time(), 0);
    
    destroy(params);
    destroy(clock);
}

#[test]
fun test_new_params_with_rand_key() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let (params, key) = new_params_with_rand_key(
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    assert_eq(params.key(), key);
    assert_eq(params.description(), b"test_description".to_string());
    assert_eq(params.execution_times(), vector[1000]);
    assert_eq(params.expiration_time(), 2000);
    
    destroy(params);
    destroy(clock);
}

#[test, expected_failure(abort_code = ENoExecutionTime)]
fun test_new_params_empty_execution_times() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[],
        2000,
        &clock,
        ctx
    );
    destroy(params);
    destroy(clock);
}

#[test, expected_failure(abort_code = EExecutionTimesNotAscending)]
fun test_new_params_not_ascending_execution_times() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[2000, 1000],
        3000,
        &clock,
        ctx
    );
    destroy(params);
    destroy(clock);
}

#[test]
fun test_new_intent() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    assert_eq(intent.key(), b"test_key".to_string());
    assert_eq(intent.description(), b"test_description".to_string());
    assert_eq(intent.account(), @0xCAFE);
    assert_eq(intent.creation_time(), clock.timestamp_ms());
    assert_eq(intent.execution_times(), vector[1000]);
    assert_eq(intent.expiration_time(), 2000);
    assert_eq(intent.action_count(), 0);
    
    destroy(intent);
    destroy(clock);
}

#[test]
fun test_add_action() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let mut intent = new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    let action_data1 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType {}, action_data1, TestIntentWitness());
    assert_eq(intent.action_count(), 1);

    let action_data2 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType {}, action_data2, TestIntentWitness());
    assert_eq(intent.action_count(), 2);
    
    destroy(intent);
    destroy(clock);
}

#[test]
fun test_remove_action() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut intents = empty(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let mut intent = new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    let action_data1 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType {}, action_data1, TestIntentWitness());

    let action_data2 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType {}, action_data2, TestIntentWitness());
    add_intent(&mut intents, intent);
    
    let mut expired = intents.destroy_intent<TestOutcome>(b"test_key".to_string());
    
    let _action1 = expired.remove_action_spec();
    let _action2 = expired.remove_action_spec();

    assert_eq(expired.expired_action_count(), 0);

    expired.destroy_empty();
    destroy(intents);
    destroy(clock);
}

#[test]
fun test_empty_intents() {
    let ctx = &mut tx_context::dummy();
    let intents = empty(ctx);
    
    assert_eq(length(&intents), 0);
    // No longer checking locked() - removed in new design
    assert!(!contains(&intents, b"test_key".to_string()));
    
    destroy(intents);
}

#[test]
fun test_add_and_remove_intent() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut intents = empty(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    add_intent(&mut intents, intent);
    assert_eq(length(&intents), 1);
    assert!(contains(&intents, b"test_key".to_string()));
    
    let removed_intent = remove_intent<TestOutcome>(&mut intents, b"test_key".to_string());
    assert_eq(length(&intents), 0);
    assert!(!contains(&intents, b"test_key".to_string()));
    
    destroy(removed_intent);
    destroy(intents);
    destroy(clock);
}

#[test, expected_failure(abort_code = EKeyAlreadyExists)]
fun test_add_duplicate_intent() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut intents = empty(ctx);
    
    let params1 = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let params2 = new_params(
        b"test_key".to_string(),
        b"test_description2".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent1 = new_intent(
        params1,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    let intent2 = new_intent(
        params2,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    add_intent(&mut intents, intent1);
    add_intent(&mut intents, intent2);
    
    destroy(intents);
    destroy(clock);
}

#[test, expected_failure(abort_code = EIntentNotFound)]
fun test_remove_nonexistent_intent() {
    let ctx = &mut tx_context::dummy();
    let mut intents = empty(ctx);
    
    let removed_intent = remove_intent<TestOutcome>(&mut intents, b"nonexistent_key".to_string());
    
    destroy(removed_intent);
    destroy(intents);
}

// REMOVED: test_lock_and_unlock_object - no locking in new design
// REMOVED: test_lock_already_locked_object - no locking in new design  
// REMOVED: test_unlock_not_locked_object - no locking in new design

#[test]
fun test_pop_front_execution_time() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000, 2000, 3000],
        4000,
        &clock,
        ctx
    );
    
    let mut intent = new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    assert_eq(intent.execution_times(), vector[1000, 2000, 3000]);
    
    let time1 = pop_front_execution_time(&mut intent);
    assert_eq(time1, 1000);
    assert_eq(intent.execution_times(), vector[2000, 3000]);
    
    let time2 = pop_front_execution_time(&mut intent);
    assert_eq(time2, 2000);
    assert_eq(intent.execution_times(), vector[3000]);
    
    destroy(intent);
    destroy(clock);
}

#[test]
fun test_assert_is_account() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    // Should not abort
    assert_is_account(&intent, @0xCAFE);
    
    destroy(intent);
    destroy(clock);
}

#[test, expected_failure(abort_code = EWrongAccount)]
fun test_assert_is_account_wrong() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    assert_is_account(&intent, @0xBAD);
    
    destroy(intent);
    destroy(clock);
}

#[test]
fun test_assert_is_witness() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    // Should not abort
    assert_is_witness(&intent, TestIntentWitness());
    
    destroy(intent);
    destroy(clock);
}

#[test, expected_failure(abort_code = EWrongWitness)]
fun test_assert_is_witness_wrong() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    let intent = new_intent(
        params,
        TestOutcome {},
        b"test_role".to_string(),
        @0xCAFE,
        TestIntentWitness(),
        ctx
    );
    
    assert_is_witness(&intent, WrongWitness());
    
    destroy(intent);
    destroy(clock);
}

#[test]
fun test_assert_single_execution() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx
    );
    
    // Should not abort
    assert_single_execution(&params);
    
    destroy(params);
    destroy(clock);
}

#[test, expected_failure(abort_code = ESingleExecution)]
fun test_assert_single_execution_multiple() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    
    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000, 2000],
        3000,
        &clock,
        ctx
    );
    
    assert_single_execution(&params);
    
    destroy(params);
    destroy(clock);
}