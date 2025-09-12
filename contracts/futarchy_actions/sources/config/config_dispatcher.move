/// Type-based dispatcher for configuration-related actions
/// This module provides PTB-composable entry functions for executing config actions
module futarchy_actions::config_dispatcher;

// === Imports ===
use std::{type_name, string::String, vector};
use sui::{clock::Clock, tx_context::TxContext, transfer};
use account_protocol::{
    account::Account,
    executable::{Self, Executable},
    intents,
};
use futarchy_core::version;
use futarchy_actions::config_actions;
use futarchy_utils::action_types;
use futarchy_core::futarchy_config::FutarchyConfig;

// === Errors ===

const ENoActionsToProcess: u64 = 0;

// === Witness ===

/// Witness for config dispatcher actions
public struct ConfigDispatcherWitness has drop {}

// === Public Entry Functions ===

/// Execute configuration actions using type-based routing
/// This is a PTB-composable function that processes config actions in a loop
/// and returns the Executable for further processing when encountering
/// an action type it doesn't handle
public fun execute_config_actions<Outcome: store + drop + copy>(
    mut executable: Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Outcome> {
    
    // Process actions in a loop until we encounter one we don't handle
    loop {
        // Check if there are more actions to process
        let intent = executable::intent(&executable);
        let action_types = intents::action_types(intent);
        if (executable::action_idx(&executable) >= vector::length(action_types)) {
            break
        };
        
        // Get current action type for O(1) routing
        let action_type = executable::current_action_type(&executable);
        
        // Process the action if it's a config action
        if (!process_single_config_action(&mut executable, account, clock, ctx, action_type)) {
            // Not a config action, stop processing
            break
        }
    };
    
    // Return the Executable for the caller to continue processing
    // Note: Executable is a hot potato - it cannot be stored or transferred
    // The caller must continue processing it in the same transaction
    executable
}

// === Internal Functions ===

/// Internal function to process a single config action
/// Returns true if the action was handled, false otherwise
fun process_single_config_action<Outcome: store + drop + copy>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
    action_type: type_name::TypeName,
): bool {
    let witness = ConfigDispatcherWitness {};
    
    // Check type and execute corresponding action
    if (action_type == type_name::get<action_types::SetProposalsEnabled>()) {
        config_actions::do_set_proposals_enabled<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (action_type == type_name::get<action_types::UpdateName>()) {
        config_actions::do_update_name<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (action_type == type_name::get<action_types::TradingParamsUpdate>()) {
        config_actions::do_update_trading_params<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (action_type == type_name::get<action_types::MetadataUpdate>()) {
        config_actions::do_update_metadata<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (action_type == type_name::get<action_types::TwapConfigUpdate>()) {
        config_actions::do_update_twap_config<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (action_type == type_name::get<action_types::GovernanceUpdate>()) {
        config_actions::do_update_governance<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (action_type == type_name::get<action_types::MetadataTableUpdate>()) {
        config_actions::do_update_metadata_table<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (action_type == type_name::get<action_types::QueueParamsUpdate>()) {
        config_actions::do_update_queue_params<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    if (action_type == type_name::get<action_types::SlashDistributionUpdate>()) {
        config_actions::do_update_slash_distribution<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    // Try to execute ConfigAction (batch wrapper)
    if (action_type == type_name::get<action_types::ConfigBatch>()) {
        config_actions::do_batch_config<Outcome, ConfigDispatcherWitness>(
            executable,
            account,
            version::current(),
            witness,
            clock,
            ctx
        );
        return true
    };
    
    false
}

// === Init Actions (for DAO initialization) ===

/// Executes a config-related init action during DAO creation
/// Returns (bool: success, String: description)
public fun execute_init_config_action(
    action_type: &type_name::TypeName,
    action_data: &vector<u8>,
    account: &mut Account<FutarchyConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
): (bool, String) {
    // Check type and deserialize + execute corresponding action
    if (*action_type == type_name::get<action_types::UpdateName>()) {
        let action = config_actions::update_name_action_from_bytes(*action_data);
        config_actions::do_update_name_internal(
            account,
            action,  // Pass by value, not reference
            version::current(),
            clock,
            ctx
        );
        return (true, b"UpdateName".to_string())
    };
    
    if (*action_type == type_name::get<action_types::SetProposalsEnabled>()) {
        let action = config_actions::set_proposals_enabled_action_from_bytes(*action_data);
        config_actions::do_set_proposals_enabled_internal(
            account,
            action,  // Pass by value to consume it
            version::current(),
            clock,
            ctx
        );
        return (true, b"SetProposalsEnabled".to_string())
    };
    
    // Add more config actions as needed for initialization
    
    (false, b"UnknownConfigAction".to_string())
}