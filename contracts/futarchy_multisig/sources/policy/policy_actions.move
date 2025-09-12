/// Actions for managing the approval policy registry
/// These are critical governance actions that typically require DAO approval
module futarchy_multisig::policy_actions;

use std::option::{Self, Option};
use std::type_name::{Self, TypeName};
use sui::object::{Self, ID};
use account_protocol::{
    intents::{Intent, Expired},
    executable::Executable,
    account::Account,
};
use futarchy_utils::action_types;
use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;
use futarchy_multisig::policy_registry::{Self, PolicyRegistry};
use futarchy_core::version;
use account_protocol::version_witness::VersionWitness;

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

// === Action Creation Functions ===

/// Create action to set a type policy with descriptor
public fun new_set_type_policy<Outcome, T: drop, IW: drop>(
    intent: &mut Intent<Outcome>,
    council_id: Option<ID>,
    mode: u8,
    intent_witness: IW,
) {
    let action = SetTypePolicyAction {
        action_type: std::type_name::get<T>(),
        council_id,
        mode,
    };
    intent.add_typed_action(action, action_types::set_object_policy(), intent_witness);
}

/// Create action to set a type policy by TypeName
public fun new_set_type_policy_by_name<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    action_type: TypeName,
    council_id: Option<ID>,
    mode: u8,
    intent_witness: IW,
) {
    let action = SetTypePolicyAction {
        action_type,
        council_id,
        mode,
    };
    intent.add_typed_action(action, action_types::set_object_policy(), intent_witness);
}

/// Create action to set an object-specific policy with descriptor
public fun new_set_object_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    object_id: ID,
    council_id: Option<ID>,
    mode: u8,
    intent_witness: IW,
) {
    let action = SetObjectPolicyAction {
        object_id,
        council_id,
        mode,
    };
    intent.add_typed_action(action, action_types::set_object_policy(), intent_witness);
}

/// Create action to register a new security council with descriptor
public fun new_register_council<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    council_id: ID,
    intent_witness: IW,
) {
    let action = RegisterCouncilAction {
        council_id,
    };
    intent.add_typed_action(action, action_types::register_council(), intent_witness);
}

/// Create action to remove a type policy
public fun new_remove_type_policy<Outcome, T: drop, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    let action = RemoveTypePolicyAction {
        action_type: std::type_name::get<T>(),
    };
    intent.add_typed_action(action, action_types::remove_object_policy(), intent_witness);
}

/// Create action to remove an object policy
public fun new_remove_object_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    object_id: ID,
    intent_witness: IW,
) {
    let action = RemoveObjectPolicyAction {
        object_id,
    };
    intent.add_typed_action(action, action_types::remove_object_policy(), intent_witness);
}

// === Action Execution Functions ===

/// Process set type policy action
public fun do_set_type_policy<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &SetTypePolicyAction = executable.next_action(intent_witness);
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    policy_registry::set_type_policy_by_name(
        registry,
        dao_id,
        action.action_type,
        action.council_id,
        action.mode
    );
    // Action processing is handled by the dispatcher
}

/// Process set object policy action
public fun do_set_object_policy<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &SetObjectPolicyAction = executable.next_action(intent_witness);
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    policy_registry::set_object_policy(
        registry,
        dao_id,
        action.object_id,
        action.council_id,
        action.mode
    );
    // Action processing is handled by the dispatcher
}

/// Process register council action
public fun do_register_council<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &RegisterCouncilAction = executable.next_action(intent_witness);
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    policy_registry::register_council(
        registry,
        dao_id,
        action.council_id
    );
    // Action processing is handled by the dispatcher
}

/// Process remove type policy action
public fun do_remove_type_policy<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &RemoveTypePolicyAction = executable.next_action(intent_witness);
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    // To remove a policy, set it to DAO_ONLY mode with no council
    policy_registry::set_type_policy_by_name(
        registry,
        dao_id,
        action.action_type,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
    // Action processing is handled by the dispatcher
}

/// Process remove object policy action
public fun do_remove_object_policy<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &RemoveObjectPolicyAction = executable.next_action(intent_witness);
    let dao_id = object::id(account);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    // To remove a policy, set it to DAO_ONLY mode with no council
    policy_registry::set_object_policy(
        registry,
        dao_id,
        action.object_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
    // Action processing is handled by the dispatcher
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

// === Aliases for backward compatibility ===

/// Delete set policy action from expired intent (alias for set_type_policy)
public fun delete_set_policy(expired: &mut Expired) {
    delete_set_type_policy(expired)
}