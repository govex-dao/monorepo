/// Basic configuration actions for futarchy DAOs
/// This module defines simple configuration actions that complement advanced_config_actions
module futarchy_actions::config_actions;

// === Imports ===
use std::string::String;
use sui::vec_set::VecSet;
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intents::Expired,
    version_witness::VersionWitness,
};

// === Errors ===
const EInvalidAddress: u64 = 1;
const EInvalidParameter: u64 = 2;
const EEmptyName: u64 = 3;
const ENotImplemented: u64 = 4;

// === Action Structs ===

// NOTE: Admin-style actions (AddMember, RemoveMember, ChangeAdmin) have been removed
// as they don't apply to DAOs which use token-based governance

// NOTE: UpdateConfigParamsAction has been moved to advanced_config_actions.move
// to avoid duplication and confusion

/// Action to enable or disable proposals
/// This is a protocol-level action that should only be used in emergencies
/// It must go through the normal futarchy governance process
public struct SetProposalsEnabledAction has store {
    enabled: bool,
}

/// Action to update the DAO name
/// This must go through the normal futarchy governance process
/// There is no admin who can unilaterally change the name
public struct UpdateNameAction has store {
    new_name: String,
}

// === Execution Functions ===

// NOTE: Execution functions for removed actions have been deleted

/// Execute a set proposals enabled action
public fun do_set_proposals_enabled<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &SetProposalsEnabledAction = executable.next_action(intent_witness);
    
    // This would need to be implemented by the Config module that has access to config_mut
    // For now, this serves as the interface that the config module would call
    let _ = action;
    let _ = account;
    let _ = version;
    
    // The actual implementation would be in futarchy_config module which has ConfigWitness
    // Example: futarchy_config::set_proposals_enabled(account, action.enabled, version)
    abort ENotImplemented // Config module must implement this
}

/// Execute an update name action
public fun do_update_name<Config, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<Config>,
    version: VersionWitness,
    intent_witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &UpdateNameAction = executable.next_action(intent_witness);
    
    // This would need to be implemented by the Config module
    let _ = action;
    let _ = account;
    let _ = version;
    
    // The actual implementation would be in futarchy_config module
    // Example: futarchy_config::set_dao_name(account, action.new_name, version)
    abort ENotImplemented // Config module must implement this
}

// === Cleanup Functions ===

// NOTE: Cleanup functions for removed actions have been deleted

/// Delete a set proposals enabled action from an expired intent
public fun delete_set_proposals_enabled(expired: &mut Expired) {
    let SetProposalsEnabledAction { enabled: _ } = expired.remove_action();
}

/// Delete an update name action from an expired intent
public fun delete_update_name(expired: &mut Expired) {
    let UpdateNameAction { new_name: _ } = expired.remove_action();
}

// === Helper Functions ===

// NOTE: Constructor functions for removed actions have been deleted

/// Create a new set proposals enabled action
public fun new_set_proposals_enabled_action(enabled: bool): SetProposalsEnabledAction {
    SetProposalsEnabledAction { enabled }
}

/// Create a new update name action
public fun new_update_name_action(new_name: String): UpdateNameAction {
    assert!(new_name.length() > 0, EEmptyName);
    UpdateNameAction { new_name }
}

// === Getter Functions ===

// NOTE: Getter functions for removed actions have been deleted

/// Get enabled status from SetProposalsEnabledAction
public fun get_proposals_enabled(action: &SetProposalsEnabledAction): bool {
    action.enabled
}

/// Get new name from UpdateNameAction
public fun get_new_name(action: &UpdateNameAction): String {
    action.new_name
}