/// Actions for managing the approval policy registry
/// These are critical governance actions that typically require DAO approval
module futarchy_multisig::policy_actions;

use std::{option::{Self, Option}, type_name::{Self, TypeName}, ascii::{Self, String}};
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

// === Error Codes for Change Permission Validation ===
const EUnauthorizedPolicyChange: u64 = 4;
const EPolicyChangeRequiresDAO: u64 = 5;
const EPolicyChangeRequiresCouncil: u64 = 6;
const EPolicyChangeRequiresBoth: u64 = 7;
const ECouncilNotRegistered: u64 = 8;

// === Helper Functions ===

/// Validates that the intent creator has permission to change a policy
/// based on the existing policy's change_council_id and change_mode
fun validate_change_permission(
    existing_rule: &policy_registry::PolicyRule,
    intent_creator_id: ID,
    dao_id: ID,
) {
    use futarchy_multisig::policy_registry;

    // Extract change permission fields from existing rule
    let (_, _, change_council_id, change_mode) =
        get_policy_rule_fields(existing_rule);

    // MODE_DAO_ONLY (0): Only DAO can change
    if (change_mode == MODE_DAO_ONLY) {
        assert!(intent_creator_id == dao_id, EPolicyChangeRequiresDAO);
    }
    // MODE_COUNCIL_ONLY (1): Only the specified council can change
    else if (change_mode == MODE_COUNCIL_ONLY) {
        assert!(change_council_id.is_some(), EMissingCouncilId);
        let council_id = *change_council_id.borrow();
        assert!(intent_creator_id == council_id, EPolicyChangeRequiresCouncil);
    }
    // MODE_DAO_OR_COUNCIL (2): Either DAO or council can change
    else if (change_mode == MODE_DAO_OR_COUNCIL) {
        assert!(change_council_id.is_some(), EMissingCouncilId);
        let council_id = *change_council_id.borrow();
        let is_dao = intent_creator_id == dao_id;
        let is_council = intent_creator_id == council_id;
        assert!(is_dao || is_council, EUnauthorizedPolicyChange);
    }
    // MODE_DAO_AND_COUNCIL (3): Both DAO and council must approve
    // Note: This is complex to enforce in a single intent execution
    // For now, we'll require that the intent was created by the council
    // and the validation will happen elsewhere (e.g., co-execution pattern)
    else if (change_mode == MODE_DAO_AND_COUNCIL) {
        assert!(change_council_id.is_some(), EMissingCouncilId);
        // This mode requires special handling - the intent must be a co-executed intent
        // For now, we allow either to initiate but enforcement of "both" happens
        // via the co-execution mechanism in the multisig system
        let council_id = *change_council_id.borrow();
        let is_dao = intent_creator_id == dao_id;
        let is_council = intent_creator_id == council_id;
        assert!(is_dao || is_council, EPolicyChangeRequiresBoth);
    };
}

/// Helper to extract fields from PolicyRule
/// Returns: (execution_council_id, execution_mode, change_council_id, change_mode)
fun get_policy_rule_fields(rule: &policy_registry::PolicyRule): (Option<ID>, u8, Option<ID>, u8) {
    policy_registry::get_policy_rule_fields(rule)
}

// === Witness Types for Action Validation ===
public struct SetTypePolicyWitness has drop {}
public struct SetObjectPolicyWitness has drop {}
public struct SetFilePolicyWitness has drop {}  // NEW
public struct RegisterCouncilWitness has drop {}
public struct RemoveTypePolicyWitness has drop {}
public struct RemoveObjectPolicyWitness has drop {}

// === Action Structs ===

/// Set a type-based policy (e.g., VaultSpend requires Treasury Council)
public struct SetTypePolicyAction has store, drop {
    action_type: TypeName,
    execution_council_id: Option<ID>,
    execution_mode: u8, // 0=DAO_ONLY, 1=COUNCIL_ONLY, 2=DAO_OR_COUNCIL, 3=DAO_AND_COUNCIL
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64, // Delay before policy changes take effect
}

/// Set an object-specific policy (e.g., specific UpgradeCap requires Technical Council)
public struct SetObjectPolicyAction has store, drop {
    object_id: ID,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64, // Delay before policy changes take effect
}

/// Set a file-level policy (e.g., "bylaws" requires Legal Council) - NEW
public struct SetFilePolicyAction has store, drop {
    file_name: String,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64, // Delay before policy changes take effect
}

/// Register a new security council with the DAO
public struct RegisterCouncilAction has store, drop {
    council_id: ID,
}

/// Remove a type-based policy
public struct RemoveTypePolicyAction has store, drop {
    action_type: TypeName,
}

/// Remove an object-specific policy
public struct RemoveObjectPolicyAction has store, drop {
    object_id: ID,
}

// === Action Creation Functions (New Serialize-Then-Destroy Pattern) ===

/// Create and add a set type policy action to an intent
public fun new_set_type_policy<Outcome, T: drop, IW: drop>(
    intent: &mut Intent<Outcome>,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    intent_witness: IW,
) {
    // Create action struct
    let action_type = type_name::get<T>();

    // Manually serialize since TypeName doesn't implement BCS
    let mut data = vector[];
    // Serialize TypeName as string
    data.append(bcs::to_bytes(&type_name::into_string(action_type).into_bytes()));
    // Serialize execution Option<ID>
    if (execution_council_id.is_some()) {
        data.append(bcs::to_bytes(&true));
        let id = *execution_council_id.borrow();
        data.append(bcs::to_bytes(&id.to_address()));
    } else {
        data.append(bcs::to_bytes(&false));
    };
    // Serialize execution_mode
    data.append(bcs::to_bytes(&execution_mode));
    // Serialize change Option<ID>
    if (change_council_id.is_some()) {
        data.append(bcs::to_bytes(&true));
        let id = *change_council_id.borrow();
        data.append(bcs::to_bytes(&id.to_address()));
    } else {
        data.append(bcs::to_bytes(&false));
    };
    // Serialize change_mode
    data.append(bcs::to_bytes(&change_mode));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetTypePolicyWitness {},
        data,
        intent_witness,
    );

    // No action struct to destroy since we serialized manually
}

/// Create and add a set type policy action by name to an intent
public fun new_set_type_policy_by_name<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    action_type: TypeName,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    intent_witness: IW,
) {
    // We need to manually serialize since TypeName doesn't implement BCS
    let mut data = vector[];
    // Serialize TypeName as string
    data.append(bcs::to_bytes(&type_name::into_string(action_type).into_bytes()));
    // Serialize execution Option<ID>
    if (execution_council_id.is_some()) {
        data.append(bcs::to_bytes(&true));
        let id = *execution_council_id.borrow();
        data.append(bcs::to_bytes(&id.to_address()));
    } else {
        data.append(bcs::to_bytes(&false));
    };
    // Serialize execution_mode
    data.append(bcs::to_bytes(&execution_mode));
    // Serialize change Option<ID>
    if (change_council_id.is_some()) {
        data.append(bcs::to_bytes(&true));
        let id = *change_council_id.borrow();
        data.append(bcs::to_bytes(&id.to_address()));
    } else {
        data.append(bcs::to_bytes(&false));
    };
    // Serialize change_mode
    data.append(bcs::to_bytes(&change_mode));

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetTypePolicyWitness {},
        data,
        intent_witness,
    );
}

/// Create and add a set object policy action to an intent
public fun new_set_object_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    object_id: ID,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64,
    intent_witness: IW,
) {
    // Create action struct
    let action = SetObjectPolicyAction {
        object_id,
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };

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

/// Create and add a set file policy action to an intent - NEW
public fun new_set_file_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    file_name: String,
    execution_council_id: Option<ID>,
    execution_mode: u8,
    change_council_id: Option<ID>,
    change_mode: u8,
    change_delay_ms: u64,
    intent_witness: IW,
) {
    // Create action struct
    let action = SetFilePolicyAction {
        file_name,
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };

    // Serialize the entire action struct
    let data = bcs::to_bytes(&action);

    // Add to intent with witness type marker
    protocol_intents::add_action_spec(
        intent,
        SetFilePolicyWitness {},
        data,
        intent_witness,
    );

    // Destroy the action struct (serialize-then-destroy pattern)
    destroy_set_file_policy(action);
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
    // TypeName was serialized as a string
    let type_name_str = ascii::string(bcs::peel_vec_u8(&mut reader));

    // Deserialize execution Option<ID>
    let execution_council_id = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_address(&mut reader).to_id())
    } else {
        option::none()
    };

    // Execution mode
    let execution_mode = bcs::peel_u8(&mut reader);

    // Deserialize change Option<ID>
    let change_council_id = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_address(&mut reader).to_id())
    } else {
        option::none()
    };

    // Change mode
    let change_mode = bcs::peel_u8(&mut reader);

    // Change delay in milliseconds
    let change_delay_ms = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Input validation
    assert!(execution_mode <= 3, EInvalidMode);
    assert!(change_mode <= 3, EInvalidMode);
    // If mode requires council (1, 2, or 3), council_id must be provided
    if (execution_mode != MODE_DAO_ONLY) {
        assert!(execution_council_id.is_some(), EMissingCouncilId);
    };
    if (change_mode != MODE_DAO_ONLY) {
        assert!(change_council_id.is_some(), EMissingCouncilId);
    };

    // Get registry reference before validation
    let dao_id = object::id(account);
    let dao_address = object::id_to_address(&dao_id);
    let registry_ref = policy_registry::borrow_registry(account, version::current());

    // Validate that councils are registered (prevent referencing non-existent councils)
    if (execution_council_id.is_some()) {
        let council_id = *execution_council_id.borrow();
        assert!(policy_registry::is_council_registered(registry_ref, council_id), ECouncilNotRegistered);
    };
    if (change_council_id.is_some()) {
        let council_id = *change_council_id.borrow();
        assert!(policy_registry::is_council_registered(registry_ref, council_id), ECouncilNotRegistered);
    };

    // Execute the action

    // Get the account that created this intent
    let intent = executable::intent(executable);
    let intent_account_addr = protocol_intents::account(intent);
    let intent_account_id = object::id_from_address(intent_account_addr);

    // Meta-control: Check if SetTypePolicyAction itself has a policy
    let meta_action_type = type_name::get<SetTypePolicyAction>();
    let meta_type_str = type_name::into_string(meta_action_type);
    if (policy_registry::has_type_policy_by_string(registry_ref, meta_type_str)) {
        let meta_rule = policy_registry::get_type_policy_rule_by_string(registry_ref, meta_type_str);
        validate_change_permission(meta_rule, intent_account_id, dao_id);
    };

    // Check change permissions for the specific type being modified
    if (policy_registry::has_type_policy_by_string(registry_ref, type_name_str)) {
        let existing_rule = policy_registry::get_type_policy_rule_by_string(registry_ref, type_name_str);
        validate_change_permission(existing_rule, intent_account_id, dao_id);
    };

    // Now store the policy with String key (fully functional!)
    let registry = policy_registry::borrow_registry_mut(account, version::current());
    policy_registry::set_type_policy_by_string(
        registry,
        dao_id,
        type_name_str,
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
        intent_account_id,
        _clock,
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
    let object_id = bcs::peel_address(&mut reader).to_id();
    let execution_council_id = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_address(&mut reader).to_id())
    } else {
        option::none()
    };
    let execution_mode = bcs::peel_u8(&mut reader);
    let change_council_id = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_address(&mut reader).to_id())
    } else {
        option::none()
    };
    let change_mode = bcs::peel_u8(&mut reader);
    let change_delay_ms = bcs::peel_u64(&mut reader);

    let action = SetObjectPolicyAction {
        object_id,
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Input validation
    assert!(action.execution_mode <= 3, EInvalidMode);
    assert!(action.change_mode <= 3, EInvalidMode);
    // If mode requires council (1, 2, or 3), council_id must be provided
    if (action.execution_mode != MODE_DAO_ONLY) {
        assert!(action.execution_council_id.is_some(), EMissingCouncilId);
    };
    if (action.change_mode != MODE_DAO_ONLY) {
        assert!(action.change_council_id.is_some(), EMissingCouncilId);
    };

    // Execute the action
    let dao_id = object::id(account);
    let dao_address = object::id_to_address(&dao_id);
    let registry_ref = policy_registry::borrow_registry(account, version::current());

    // Get the account that created this intent
    let intent = executable::intent(executable);
    let intent_account_addr = protocol_intents::account(intent);
    let intent_account_id = object::id_from_address(intent_account_addr);

    // Meta-control: Check if SetObjectPolicyAction itself has a policy
    let meta_action_type = type_name::get<SetObjectPolicyAction>();
    let meta_type_str = type_name::into_string(meta_action_type);
    if (policy_registry::has_type_policy_by_string(registry_ref, meta_type_str)) {
        let meta_rule = policy_registry::get_type_policy_rule_by_string(registry_ref, meta_type_str);
        validate_change_permission(meta_rule, intent_account_id, dao_id);
    };

    // Check change permissions for the specific object being modified
    if (policy_registry::has_object_policy(registry_ref, action.object_id)) {
        let existing_rule = policy_registry::get_object_policy_rule(registry_ref, action.object_id);
        validate_change_permission(existing_rule, intent_account_id, dao_id);
    };

    // Validate that councils are registered (prevent referencing non-existent councils)
    if (action.execution_council_id.is_some()) {
        let council_id = *action.execution_council_id.borrow();
        assert!(policy_registry::is_council_registered(registry_ref, council_id), ECouncilNotRegistered);
    };
    if (action.change_council_id.is_some()) {
        let council_id = *action.change_council_id.borrow();
        assert!(policy_registry::is_council_registered(registry_ref, council_id), ECouncilNotRegistered);
    };

    let registry = policy_registry::borrow_registry_mut(account, version::current());
    policy_registry::set_object_policy(
        registry,
        dao_id,
        action.object_id,
        action.execution_council_id,
        action.execution_mode,
        action.change_council_id,
        action.change_mode,
        action.change_delay_ms,
        intent_account_id,
        _clock,
    );

    // Increment action index
    executable::increment_action_idx(executable);
}

/// Execute set file policy action - NEW
public fun do_set_file_policy<Outcome: store, IW: drop>(
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
    action_validation::assert_action_type<SetFilePolicyWitness>(spec);

    let action_data = protocol_intents::action_spec_data(spec);
    let spec_version = protocol_intents::action_spec_version(spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct
    let mut reader = bcs::new(*action_data);
    let file_name = ascii::string(bcs::peel_vec_u8(&mut reader));
    let execution_council_id = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_address(&mut reader).to_id())
    } else {
        option::none()
    };
    let execution_mode = bcs::peel_u8(&mut reader);
    let change_council_id = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_address(&mut reader).to_id())
    } else {
        option::none()
    };
    let change_mode = bcs::peel_u8(&mut reader);
    let change_delay_ms = bcs::peel_u64(&mut reader);

    let action = SetFilePolicyAction {
        file_name,
        execution_council_id,
        execution_mode,
        change_council_id,
        change_mode,
        change_delay_ms,
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Input validation
    assert!(action.execution_mode <= 3, EInvalidMode);
    assert!(action.change_mode <= 3, EInvalidMode);
    // If mode requires council (1, 2, or 3), council_id must be provided
    if (action.execution_mode != MODE_DAO_ONLY) {
        assert!(action.execution_council_id.is_some(), EMissingCouncilId);
    };
    if (action.change_mode != MODE_DAO_ONLY) {
        assert!(action.change_council_id.is_some(), EMissingCouncilId);
    };

    // Execute the action
    let dao_id = object::id(account);
    let dao_address = object::id_to_address(&dao_id);
    let registry_ref = policy_registry::borrow_registry(account, version::current());

    // Get the account that created this intent
    let intent = executable::intent(executable);
    let intent_account_addr = protocol_intents::account(intent);
    let intent_account_id = object::id_from_address(intent_account_addr);

    // Meta-control: Check if SetFilePolicyAction itself has a policy
    let meta_action_type = type_name::get<SetFilePolicyAction>();
    let meta_type_str = type_name::into_string(meta_action_type);
    if (policy_registry::has_type_policy_by_string(registry_ref, meta_type_str)) {
        let meta_rule = policy_registry::get_type_policy_rule_by_string(registry_ref, meta_type_str);
        validate_change_permission(meta_rule, intent_account_id, dao_id);
    };

    // Check change permissions for the specific file being modified
    if (policy_registry::has_file_policy(registry_ref, action.file_name)) {
        let existing_rule = policy_registry::get_file_policy_rule(registry_ref, action.file_name);
        validate_change_permission(existing_rule, intent_account_id, dao_id);
    };

    // Validate that councils are registered (prevent referencing non-existent councils)
    if (action.execution_council_id.is_some()) {
        let council_id = *action.execution_council_id.borrow();
        assert!(policy_registry::is_council_registered(registry_ref, council_id), ECouncilNotRegistered);
    };
    if (action.change_council_id.is_some()) {
        let council_id = *action.change_council_id.borrow();
        assert!(policy_registry::is_council_registered(registry_ref, council_id), ECouncilNotRegistered);
    };

    let registry = policy_registry::borrow_registry_mut(account, version::current());
    policy_registry::set_file_policy(
        registry,
        dao_id,
        action.file_name,
        action.execution_council_id,
        action.execution_mode,
        action.change_council_id,
        action.change_mode,
        action.change_delay_ms,
        intent_account_id,
        _clock,
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
    let council_id = bcs::peel_address(&mut reader).to_id();

    let action = RegisterCouncilAction {
        council_id,
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Meta-control: Check if RegisterCouncilAction itself has a policy
    let dao_id = object::id(account);
    let registry_ref = policy_registry::borrow_registry(account, version::current());
    let intent = executable::intent(executable);
    let intent_account_addr = protocol_intents::account(intent);
    let intent_account_id = object::id_from_address(intent_account_addr);

    let meta_action_type = type_name::get<RegisterCouncilAction>();
    let meta_type_str = type_name::into_string(meta_action_type);
    if (policy_registry::has_type_policy_by_string(registry_ref, meta_type_str)) {
        let meta_rule = policy_registry::get_type_policy_rule_by_string(registry_ref, meta_type_str);
        validate_change_permission(meta_rule, intent_account_id, dao_id);
    };

    // Execute the action
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
    // Deserialize manually as we can't use bcs::peel for custom structs
    let type_name_bytes = bcs::peel_vec_u8(&mut reader);
    // TypeName can't be constructed from string directly, using placeholder
    let action_type = type_name::get<RemoveTypePolicyAction>();

    let action = RemoveTypePolicyAction {
        action_type,
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Meta-control: Check if RemoveTypePolicyAction itself has a policy
    let dao_id = object::id(account);
    let registry_ref = policy_registry::borrow_registry(account, version::current());
    let intent = executable::intent(executable);
    let intent_account_addr = protocol_intents::account(intent);
    let intent_account_id = object::id_from_address(intent_account_addr);

    let meta_action_type = type_name::get<RemoveTypePolicyAction>();
    let meta_type_str = type_name::into_string(meta_action_type);
    if (policy_registry::has_type_policy_by_string(registry_ref, meta_type_str)) {
        let meta_rule = policy_registry::get_type_policy_rule_by_string(registry_ref, meta_type_str);
        validate_change_permission(meta_rule, intent_account_id, dao_id);
    };

    // Execute the action - remove by setting to DAO_ONLY with no council
    let registry = policy_registry::borrow_registry_mut(account, version::current());
    policy_registry::set_type_policy_by_name(
        registry,
        dao_id,
        action.action_type,
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        0,  // No delay when removing policy
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
    // Deserialize manually
    let object_id = bcs::peel_address(&mut reader).to_id();

    let action = RemoveObjectPolicyAction {
        object_id,
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Meta-control: Check if RemoveObjectPolicyAction itself has a policy
    let dao_id = object::id(account);
    let registry_ref = policy_registry::borrow_registry(account, version::current());
    let intent = executable::intent(executable);
    let intent_account_addr = protocol_intents::account(intent);
    let intent_account_id = object::id_from_address(intent_account_addr);

    let meta_action_type = type_name::get<RemoveObjectPolicyAction>();
    let meta_type_str = type_name::into_string(meta_action_type);
    if (policy_registry::has_type_policy_by_string(registry_ref, meta_type_str)) {
        let meta_rule = policy_registry::get_type_policy_rule_by_string(registry_ref, meta_type_str);
        validate_change_permission(meta_rule, intent_account_id, dao_id);
    };

    // Execute the action - remove by setting to DAO_ONLY with no council
    let registry = policy_registry::borrow_registry_mut(account, version::current());
    let intent = executable::intent(executable);
    let intent_account_addr = protocol_intents::account(intent);
    let intent_account_id = object::id_from_address(intent_account_addr);

    policy_registry::set_object_policy(
        registry,
        dao_id,
        action.object_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        option::none(),
        policy_registry::MODE_DAO_ONLY(),
        0,  // No delay when removing policy
        intent_account_id,
        _clock,
    );

    // Increment action index
    executable::increment_action_idx(executable);
}

// === Delete Functions for Expired Intents ===

/// Delete set type policy action from expired intent
public fun delete_set_type_policy(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

/// Delete set object policy action from expired intent
public fun delete_set_object_policy(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

/// Delete register council action from expired intent
public fun delete_register_council(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

/// Delete remove type policy action from expired intent
public fun delete_remove_type_policy(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

/// Delete remove object policy action from expired intent
public fun delete_remove_object_policy(expired: &mut Expired) {
    let _ = expired.remove_action_spec();
}

// === Getter Functions ===

/// Get parameters from SetTypePolicyAction
public fun get_set_type_policy_params(action: &SetTypePolicyAction): (TypeName, Option<ID>, u8, Option<ID>, u8) {
    (action.action_type, action.execution_council_id, action.execution_mode, action.change_council_id, action.change_mode)
}

/// Get parameters from SetObjectPolicyAction
public fun get_set_object_policy_params(action: &SetObjectPolicyAction): (ID, Option<ID>, u8, Option<ID>, u8) {
    (action.object_id, action.execution_council_id, action.execution_mode, action.change_council_id, action.change_mode)
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
    let SetTypePolicyAction {
        action_type: _,
        execution_council_id: _,
        execution_mode: _,
        change_council_id: _,
        change_mode: _,
        change_delay_ms: _,
    } = action;
}

/// Destroy a SetObjectPolicyAction
public fun destroy_set_object_policy(action: SetObjectPolicyAction) {
    let SetObjectPolicyAction {
        object_id: _,
        execution_council_id: _,
        execution_mode: _,
        change_council_id: _,
        change_mode: _,
        change_delay_ms: _,
    } = action;
}

/// Destroy a SetFilePolicyAction - NEW
public fun destroy_set_file_policy(action: SetFilePolicyAction) {
    let SetFilePolicyAction {
        file_name: _,
        execution_council_id: _,
        execution_mode: _,
        change_council_id: _,
        change_mode: _,
        change_delay_ms: _,
    } = action;
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