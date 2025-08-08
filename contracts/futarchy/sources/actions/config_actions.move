/// Basic configuration actions for futarchy DAOs
/// This module defines simple configuration actions and their execution logic
module futarchy::config_actions;

// === Imports ===
use std::string::String;
use std::ascii;
use sui::{
    event,
    object,
};
use account_protocol::{
    account::{Self, Account},
    executable::Executable,
    intents::Expired,
    version_witness::VersionWitness,
};
use futarchy::{
    futarchy_config::{Self, FutarchyConfig},
    version,
};

// === Errors ===
const EEmptyName: u64 = 1;

// === Events ===

/// Emitted when proposals are enabled or disabled
public struct ProposalsEnabledChanged has copy, drop {
    account_id: ID,
    enabled: bool,
    timestamp: u64,
}

/// Emitted when DAO name is updated
public struct DaoNameChanged has copy, drop {
    account_id: ID,
    new_name: String,
    timestamp: u64,
}

// === Action Structs ===

/// Action to enable or disable proposals
/// This is a protocol-level action that should only be used in emergencies
/// It must go through the normal futarchy governance process
public struct SetProposalsEnabledAction has store {
    enabled: bool,
}

/// Action to update the DAO name
/// This must go through the normal futarchy governance process
public struct UpdateNameAction has store {
    new_name: String,
}

// === Execution Functions ===

/// Execute a set proposals enabled action
/// Now with actual implementation using direct access to futarchy_config
public fun do_set_proposals_enabled<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Extract the action
    let action: &SetProposalsEnabledAction = executable.next_action(intent_witness);
    let enabled = action.enabled;
    
    // Get mutable config using internal function (no witness needed since we're in the same package)
    let config = futarchy_config::internal_config_mut(account);
    
    // Apply the state change
    if (enabled) {
        futarchy_config::set_operational_state(config, futarchy_config::state_active());
    } else {
        futarchy_config::set_operational_state(config, futarchy_config::state_paused());
    };
    
    // Emit event
    event::emit(ProposalsEnabledChanged {
        account_id: object::id(account),
        enabled,
        timestamp: ctx.epoch_timestamp_ms(),
    });
}

/// Execute an update name action
/// Now with actual implementation
public fun do_update_name<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    version: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Extract the action
    let action: &UpdateNameAction = executable.next_action(intent_witness);
    let new_name = action.new_name;
    
    // Get mutable config
    let config = futarchy_config::internal_config_mut(account);
    
    // Convert String to AsciiString
    // Note: This will abort if the string contains non-ASCII characters
    let ascii_name = new_name.to_ascii();
    
    // Apply the change
    futarchy_config::set_dao_name(config, ascii_name);
    
    // Emit event
    event::emit(DaoNameChanged {
        account_id: object::id(account),
        new_name,
        timestamp: ctx.epoch_timestamp_ms(),
    });
}

// === Cleanup Functions ===

/// Delete a set proposals enabled action from an expired intent
public fun delete_set_proposals_enabled(expired: &mut Expired) {
    let SetProposalsEnabledAction { enabled: _ } = expired.remove_action();
}

/// Delete an update name action from an expired intent
public fun delete_update_name(expired: &mut Expired) {
    let UpdateNameAction { new_name: _ } = expired.remove_action();
}

// === Constructor Functions ===

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

/// Get enabled status from SetProposalsEnabledAction
public fun get_proposals_enabled(action: &SetProposalsEnabledAction): bool {
    action.enabled
}

/// Get new name from UpdateNameAction
public fun get_new_name(action: &UpdateNameAction): String {
    action.new_name
}