/// Builder for creating intent specifications that can be attached to proposals
/// These specs are used to create actual intents only when the proposal wins
module futarchy_actions::intent_spec_builder;

use std::string::String;
use sui::clock::Clock;
use sui::bcs;
use account_protocol::intents::{Self as account_intents, Params};
use futarchy_actions::intent_spec::{Self, IntentSpec};
use futarchy_actions::config_actions;

// === Config Intent Specs ===

/// Create a spec for updating DAO name
public fun new_update_name_spec(
    key: String,
    new_name: String,
    clock: &Clock,
    ctx: &mut TxContext,
): IntentSpec {
    // Create params for immediate execution
    let params = account_intents::new_params(
        key,
        b"Update DAO name".to_string(),
        vector[clock.timestamp_ms()], // Execute immediately
        clock.timestamp_ms() + 30_000_000, // Expire in 30 seconds
        clock,
        ctx
    );
    
    // Serialize just the parameters (not the whole action)
    // We'll reconstruct the action when the intent is executed
    let action_data = bcs::to_bytes(&new_name);
    
    intent_spec::new(
        key,
        params,
        b"config_actions".to_string(),
        action_data,
        b"ConfigIntent".to_string(),
    )
}

/// Create a spec for enabling/disabling proposals
public fun new_set_proposals_enabled_spec(
    key: String,
    enabled: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): IntentSpec {
    let params = account_intents::new_params(
        key,
        b"Set proposals enabled".to_string(),
        vector[clock.timestamp_ms()],
        clock.timestamp_ms() + 30_000_000,
        clock,
        ctx
    );
    
    // Serialize just the parameters
    let action_data = bcs::to_bytes(&enabled);
    
    intent_spec::new(
        key,
        params,
        b"config_actions".to_string(),
        action_data,
        b"ConfigIntent".to_string(),
    )
}

/// Create a spec for updating slash distribution
public fun new_slash_distribution_spec(
    key: String,
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
    clock: &Clock,
    ctx: &mut TxContext,
): IntentSpec {
    let params = account_intents::new_params(
        key,
        b"Update slash distribution".to_string(),
        vector[clock.timestamp_ms()],
        clock.timestamp_ms() + 30_000_000,
        clock,
        ctx
    );
    
    let action = config_actions::new_slash_distribution_update_action(
        slasher_reward_bps,
        dao_treasury_bps,
        protocol_bps,
        burn_bps,
    );
    let action_data = bcs::to_bytes(&action);
    
    intent_spec::new(
        key,
        params,
        b"config_actions".to_string(),
        action_data,
        b"ConfigIntent".to_string(),
    )
}

// Additional spec builders can be added for other action types:
// - Liquidity actions
// - Operating agreement actions
// - Policy actions
// - Stream actions
// - Vault actions (Move framework compatible)