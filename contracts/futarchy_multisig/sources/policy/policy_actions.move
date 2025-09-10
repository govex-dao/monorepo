/// Actions for managing the approval policy registry
/// These are critical governance actions that typically require DAO approval
module futarchy_multisig::policy_actions;

use std::option::{Self, Option};
use std::vector;
use sui::object::ID;
use account_protocol::{
    intents::{Intent, Expired},
    executable::Executable,
    account::Account,
};
use account_extensions::action_descriptor::{Self, ActionDescriptor};
use futarchy_multisig::policy_registry::{Self, PolicyRegistry};
use futarchy_core::version;
use account_protocol::version_witness::VersionWitness;

// === Action Structs ===

/// Set a pattern-based policy (e.g., b"treasury/spend" requires Treasury Council)
public struct SetPatternPolicyAction has store {
    pattern: vector<u8>,
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

/// Remove a pattern-based policy
public struct RemovePatternPolicyAction has store {
    pattern: vector<u8>,
}

/// Remove an object-specific policy
public struct RemoveObjectPolicyAction has store {
    object_id: ID,
}

// === Action Creation Functions ===

/// Create action to set a pattern policy with descriptor
public fun new_set_pattern_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    pattern: vector<u8>,
    council_id: Option<ID>,
    mode: u8,
    intent_witness: IW,
) {
    // Policy changes are critical governance actions
    let descriptor = action_descriptor::new(b"governance", b"set_pattern_policy");
    intent.add_action_with_descriptor(
        SetPatternPolicyAction { pattern, council_id, mode },
        descriptor,
        intent_witness
    );
}

/// Create action to set an object policy with descriptor
public fun new_set_object_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    object_id: ID,
    council_id: Option<ID>,
    mode: u8,
    intent_witness: IW,
) {
    let descriptor = action_descriptor::new(b"governance", b"set_object_policy");
    intent.add_action_with_descriptor(
        SetObjectPolicyAction { object_id, council_id, mode },
        descriptor,
        intent_witness
    );
}

/// Create action to register a council with descriptor
public fun new_register_council<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    council_id: ID,
    intent_witness: IW,
) {
    let descriptor = action_descriptor::new(b"governance", b"register_council");
    intent.add_action_with_descriptor(
        RegisterCouncilAction { council_id },
        descriptor,
        intent_witness
    );
}

/// Create action to remove a pattern policy with descriptor
public fun new_remove_pattern_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    pattern: vector<u8>,
    intent_witness: IW,
) {
    let descriptor = action_descriptor::new(b"governance", b"remove_pattern_policy");
    intent.add_action_with_descriptor(
        RemovePatternPolicyAction { pattern },
        descriptor,
        intent_witness
    );
}

/// Create action to remove an object policy with descriptor
public fun new_remove_object_policy<Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    object_id: ID,
    intent_witness: IW,
) {
    let descriptor = action_descriptor::new(b"governance", b"remove_object_policy");
    intent.add_action_with_descriptor(
        RemoveObjectPolicyAction { object_id },
        descriptor,
        intent_witness
    );
}

// === Action Processing Functions ===

/// Process set pattern policy action
public fun do_set_pattern_policy<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &SetPatternPolicyAction = executable.next_action(intent_witness);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    policy_registry::set_pattern_policy(
        registry,
        action.pattern,
        action.council_id,
        action.mode
    );
}

/// Process set object policy action
public fun do_set_object_policy<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &SetObjectPolicyAction = executable.next_action(intent_witness);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    policy_registry::set_object_policy(
        registry,
        action.object_id,
        action.council_id,
        action.mode
    );
}

/// Process register council action
public fun do_register_council<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &RegisterCouncilAction = executable.next_action(intent_witness);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    policy_registry::register_council(registry, action.council_id);
}

/// Process remove pattern policy action
public fun do_remove_pattern_policy<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &RemovePatternPolicyAction = executable.next_action(intent_witness);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    // Need to add remove function to registry
    // For now, can set to DAO_ONLY mode with no council
    policy_registry::set_pattern_policy(
        registry,
        action.pattern,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
}

/// Process remove object policy action
public fun do_remove_object_policy<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version_witness: VersionWitness,
    intent_witness: IW,
) {
    let action: &RemoveObjectPolicyAction = executable.next_action(intent_witness);
    let registry = policy_registry::borrow_registry_mut(account, version_witness);
    // Set to DAO_ONLY mode with no council (effectively removing special requirements)
    policy_registry::set_object_policy(
        registry,
        action.object_id,
        option::none(),
        policy_registry::MODE_DAO_ONLY()
    );
}

// === Cleanup Functions ===

/// Delete set pattern policy action from expired intent
public fun delete_set_pattern_policy(expired: &mut Expired) {
    let SetPatternPolicyAction { .. } = expired.remove_action();
}

/// Delete set object policy action from expired intent
public fun delete_set_object_policy(expired: &mut Expired) {
    let SetObjectPolicyAction { .. } = expired.remove_action();
}

/// Delete register council action from expired intent
public fun delete_register_council(expired: &mut Expired) {
    let RegisterCouncilAction { .. } = expired.remove_action();
}

/// Delete remove pattern policy action from expired intent
public fun delete_remove_pattern_policy(expired: &mut Expired) {
    let RemovePatternPolicyAction { .. } = expired.remove_action();
}

/// Delete remove object policy action from expired intent
public fun delete_remove_object_policy(expired: &mut Expired) {
    let RemoveObjectPolicyAction { .. } = expired.remove_action();
}

// === Getter Functions ===

/// Get parameters from SetPatternPolicyAction
public fun get_set_pattern_policy_params(action: &SetPatternPolicyAction): (vector<u8>, Option<ID>, u8) {
    (action.pattern, action.council_id, action.mode)
}

/// Get pattern from RemovePatternPolicyAction
public fun get_remove_pattern_policy_pattern(action: &RemovePatternPolicyAction): vector<u8> {
    action.pattern
}

/// Get parameters from SetObjectPolicyAction
public fun get_set_object_policy_params(action: &SetObjectPolicyAction): (ID, Option<ID>, u8) {
    (action.object_id, action.council_id, action.mode)
}

/// Get object_id from RemoveObjectPolicyAction
public fun get_remove_object_policy_id(action: &RemoveObjectPolicyAction): ID {
    action.object_id
}

/// Delete set policy action from expired intent (alias for set_pattern_policy)
public fun delete_set_policy(expired: &mut Expired) {
    delete_set_pattern_policy(expired)
}

/// Delete remove policy action from expired intent (alias for remove_pattern_policy) 
public fun delete_remove_policy(expired: &mut Expired) {
    delete_remove_pattern_policy(expired)
}