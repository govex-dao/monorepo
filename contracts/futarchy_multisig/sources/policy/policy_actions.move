/// Actions for managing the approval policy registry
/// These are critical governance actions that typically require DAO approval
module futarchy_multisig::policy_actions;

use std::{option::{Self, Option}, type_name::{Self, TypeName}, string::{Self, String}};
use sui::{object::{Self, ID}, bcs::{Self, BCS}, clock::Clock, tx_context::TxContext};
use account_protocol::{
    intents::{Self as protocol_intents, Intent, Expired, ActionSpec},
    executable::{Self, Executable},
    account::{Self, Account},
    version_witness::VersionWitness,
    bcs_validation,
    action_validation,
};
use futarchy_multisig::policy_registry::{Self, PolicyRegistry};
use futarchy_core::{futarchy_config::FutarchyConfig, version};

// === Constants ===
const EUnsupportedActionVersion: u64 = 1;
/// Error when mode value is invalid (must be 0-3)
const EInvalidMode: u64 = 2;
/// Error when council_id is required but not provided
const EMissingCouncilId: u64 = 3;

// Valid mode constants for reference
const MODE_DAO_ONLY: u8 = 0;
const MODE_COUNCIL_ONLY: u8 = 1;
const MODE_DAO_OR_COUNCIL: u8 = 2;
const MODE_DAO_AND_COUNCIL: u8 = 3;

// === Witness Types for Action Validation ===
public struct SetTypePolicyWitness has drop {}
public struct SetObjectPolicyWitness has drop {}
public struct RegisterCouncilWitness has drop {}
public struct RemoveTypePolicyWitness has drop {}
public struct RemoveObjectPolicyWitness has drop {}

// === Action Structs ===

/// Set a type-based policy (e.g., VaultSpend requires Treasury Council)
public struct SetTypePolicyAction has store {
    action_type: TypeName,
    council_id: Option<ID>,
    mode: u8, // 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=DAO_OR_COUNCIL, 3=DAO_AND_COUNCIL
}

/// Set an object-specific policy (e.g., specific UpgradeCap requires Technical Council)
public struct SetObjectPolicyAction has store {
    object_id: ID,
    council_id: Option<ID>,
    mode: u8,
}

/// Register a new security council with the DAO
public struct RegisterCouncilAction has store {
    council_id: ID,
}

/// Remove a type-based policy
public struct RemoveTypePolicyAction has store {
    action_type: TypeName,
}

/// Remove an object-specific policy
public struct RemoveObjectPolicyAction has store {
    object_id: ID,
}

// === Action Creation Functions (New Serialize-Then-Destroy Pattern) ===

/// Create and add a set type policy action to an intent
public fun new_set_type_policy<Outcome, T: drop, IW: drop>(
    intent: &mut Intent<Outcome>,
    council_id: Option<ID>,
    mode: u8,
    intent_witness: IW,
) {
    // Create action struct
    let action_type = type_name::get<T>();
    let action = SetTypePolicyAction { action_type, council_id, mode };

    // Serialize the entire action struct
    let data = bcs::to_bytes(&action);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetTypePolicyWitness {},
        data,
        intent_witness,
    );

    // Destroy the action struct (serialize-then-destroy pattern)
    destroy_set_type_policy(action);
}

/// Create and add a set type policy action by name to an intent
public fun new_set_type_policy_by_name<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    action_type: TypeName,
    council_id: Option<ID>,
    mode: u8,
    intent_witness: IW,
) {
    // Create action struct
    let action = SetTypePolicyAction { action_type, council_id, mode };

    // Serialize the entire action struct
    let data = bcs::to_bytes(&action);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetTypePolicyWitness {},
        data,
        intent_witness,
    );

    // Destroy the action struct (serialize-then-destroy pattern)
    destroy_set_type_policy(action);
}

/// Create and add a set object policy action to an intent
public fun new_set_object_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    object_id: ID,
    council_id: Option<ID>,
    mode: u8,
    intent_witness: IW,
) {
    // Create action struct
    let action = SetObjectPolicyAction { object_id, council_id, mode };

    // Serialize the entire action struct
    let data = bcs::to_bytes(&action);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetObjectPolicyWitness {},
        data,
        intent_witness,
    );

    // Destroy the action struct (serialize-then-destroy pattern)
    destroy_set_object_policy(action);
}

/// Create and add a register council action to an intent
public fun new_register_council<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    council_id: ID,
    intent_witness: IW,
) {
    // Create action struct
    let action = RegisterCouncilAction { council_id };

    // Serialize the entire action struct
    let data = bcs::to_bytes(&action);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        RegisterCouncilWitness {},
        data,
        intent_witness,
    );

    // Destroy the action struct (serialize-then-destroy pattern)
    destroy_register_council(action);
}

/// Create and add a remove type policy action to an intent
public fun new_remove_type_policy<Outcome, T: drop, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    // Create action struct
    let action_type = type_name::get<T>();
    let action = RemoveTypePolicyAction { action_type };

    // Serialize the entire action struct
    let data = bcs::to_bytes(&action);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        RemoveTypePolicyWitness {},
        data,
        intent_witness,
    );

    // Destroy the action struct (serialize-then-destroy pattern)
    destroy_remove_type_policy(action);
}

/// Create and add a remove object policy action to an intent
public fun new_remove_object_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    object_id: ID,
    intent_witness: IW,
) {
    // Create action struct
    let action = RemoveObjectPolicyAction { object_id };

    // Serialize the entire action struct
    let data = bcs::to_bytes(&action);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        RemoveObjectPolicyWitness {},
        data,
        intent_witness,
    );

    // Destroy the action struct (serialize-then-destroy pattern)
    destroy_remove_object_policy(action);
}

// === Action Execution Functions (do_ pattern) ===

/// Execute set type policy action
public fun do_set_type_policy<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<SetTypePolicyWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct
    let mut reader = bcs::new(*action_data);
    let action: SetTypePolicyAction = bcs::peel(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Input validation
    assert!(action.mode <= 3, EInvalidMode);
    // If mode requires council (1, 2, or 3), council_id must be provided
    if (action.mode != MODE_DAO_ONLY) {
        assert!(action.council_id.is_some(), EMissingCouncilId);
    };

    // Execute the action
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version::current());
    policy_registry::set_type_policy_by_name(
        registry,
        dao_id,
        action.action_type,
        action.council_id,
        action.mode
    );

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute set object policy action
public fun do_set_object_policy<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<SetObjectPolicyWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct
    let mut reader = bcs::new(*action_data);
    let action: SetObjectPolicyAction = bcs::peel(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Input validation
    assert!(action.mode <= 3, EInvalidMode);
    // If mode requires council (1, 2, or 3), council_id must be provided
    if (action.mode != MODE_DAO_ONLY) {
        assert!(action.council_id.is_some(), EMissingCouncilId);
    };

    // Execute the action
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version::current());
    policy_registry::set_object_policy(
        registry,
        dao_id,
        action.object_id,
        action.council_id,
        action.mode
    );

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute register council action
public fun do_register_council<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<RegisterCouncilWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct
    let mut reader = bcs::new(*action_data);
    let action: RegisterCouncilAction = bcs::peel(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute the action
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version::current());
    policy_registry::register_council(
        registry,
        dao_id,
        action.council_id
    );

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute remove type policy action
public fun do_remove_type_policy<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<RemoveTypePolicyWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct
    let mut reader = bcs::new(*action_data);
    let action: RemoveTypePolicyAction = bcs::peel(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute the action - remove by setting to DAO_ONLY with no council
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version::current());
    policy_registry::set_type_policy_by_name(
        registry,
        dao_id,
        action.action_type,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute remove object policy action
public fun do_remove_object_policy<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version_witness: VersionWitness,
    _witness: IW,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    // Get action spec
    let specs = executable::intent(executable).action_specs();
    let spec = specs.borrow(executable::action_idx(executable));

    // Assert action type with witness
    action_validation::assert_action_type<RemoveObjectPolicyWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct
    let mut reader = bcs::new(*action_data);
    let action: RemoveObjectPolicyAction = bcs::peel(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Execute the action - remove by setting to DAO_ONLY with no council
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version::current());
    policy_registry::set_object_policy(
        registry,
        dao_id,
        action.object_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );

    // Increment action index
    executable::increment_action_idx(executable);
}

// === Delete Functions for Expired Intents ===

/// Delete set type policy action from expired intent
public fun delete_set_type_policy(expired: &mut Expired) {
    let SetTypePolicyAction { .. } = expired.remove_action();
}

/// Delete set object policy action from expired intent
public fun delete_set_object_policy(expired: &mut Expired) {
    let SetObjectPolicyAction { .. } = expired.remove_action();
}

/// Delete register council action from expired intent
public fun delete_register_council(expired: &mut Expired) {
    let RegisterCouncilAction { .. } = expired.remove_action();
}

/// Delete remove type policy action from expired intent
public fun delete_remove_type_policy(expired: &mut Expired) {
    let RemoveTypePolicyAction { .. } = expired.remove_action();
}

/// Delete remove object policy action from expired intent
public fun delete_remove_object_policy(expired: &mut Expired) {
    let RemoveObjectPolicyAction { .. } = expired.remove_action();
}

// === Getter Functions ===

/// Get parameters from SetTypePolicyAction
public fun get_set_type_policy_params(action: &SetTypePolicyAction): (TypeName, Option<ID>, u8) {
    (action.action_type, action.council_id, action.mode)
}

/// Get parameters from SetObjectPolicyAction
public fun get_set_object_policy_params(action: &SetObjectPolicyAction): (ID, Option<ID>, u8) {
    (action.object_id, action.council_id, action.mode)
}

/// Get council_id from RegisterCouncilAction
public fun get_register_council_params(action: &RegisterCouncilAction): ID {
    action.council_id
}

/// Get action type from RemoveTypePolicyAction
public fun get_remove_type_policy_params(action: &RemoveTypePolicyAction): TypeName {
    action.action_type
}

/// Get object_id from RemoveObjectPolicyAction
public fun get_remove_object_policy_params(action: &RemoveObjectPolicyAction): ID {
    action.object_id
}

// === Destruction Functions ===

/// Destroy a SetTypePolicyAction
public fun destroy_set_type_policy(action: SetTypePolicyAction) {
    let SetTypePolicyAction { action_type: _, council_id: _, mode: _ } = action;
}

/// Destroy a SetObjectPolicyAction
public fun destroy_set_object_policy(action: SetObjectPolicyAction) {
    let SetObjectPolicyAction { object_id: _, council_id: _, mode: _ } = action;
}

/// Destroy a RegisterCouncilAction
public fun destroy_register_council(action: RegisterCouncilAction) {
    let RegisterCouncilAction { council_id: _ } = action;
}

/// Destroy a RemoveTypePolicyAction
public fun destroy_remove_type_policy(action: RemoveTypePolicyAction) {
    let RemoveTypePolicyAction { action_type: _ } = action;
}

/// Destroy a RemoveObjectPolicyAction
public fun destroy_remove_object_policy(action: RemoveObjectPolicyAction) {
    let RemoveObjectPolicyAction { object_id: _ } = action;
}

// === Legacy Action Constructors (deprecated - use new_* functions above) ===

/// Create a set type policy action (legacy)
public fun new_set_type_policy_action(
    action_type: TypeName,
    council_id: Option<ID>,
    mode: u8,
): SetTypePolicyAction {
    SetTypePolicyAction { action_type, council_id, mode }
}

/// Create a set object policy action (legacy)
public fun new_set_object_policy_action(
    object_id: ID,
    council_id: Option<ID>,
    mode: u8,
): SetObjectPolicyAction {
    SetObjectPolicyAction { object_id, council_id, mode }
}

/// Create a register council action (legacy)
public fun new_register_council_action(council_id: ID): RegisterCouncilAction {
    RegisterCouncilAction { council_id }
}

/// Create a remove type policy action (legacy)
public fun new_remove_type_policy_action(action_type: TypeName): RemoveTypePolicyAction {
    RemoveTypePolicyAction { action_type }
}

/// Create a remove object policy action (legacy)
public fun new_remove_object_policy_action(object_id: ID): RemoveObjectPolicyAction {
    RemoveObjectPolicyAction { object_id }
}

// === Aliases for backward compatibility ===

/// Delete set policy action from expired intent (alias for set_type_policy)
public fun delete_set_policy(expired: &mut Expired) {
    delete_set_type_policy(expired)
}