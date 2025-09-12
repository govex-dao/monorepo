/// Builder for creating intent specifications that can be attached to proposals
/// These specs are used to create actual intents only when the proposal wins
module futarchy_actions::intent_spec_builder;

use std::string::String;
use std::type_name;
use sui::bcs;
use account_protocol::intent_spec::{Self, IntentSpec, ActionSpec};
use futarchy_utils::action_types;
use futarchy_actions::config_actions;

// === Config Intent Specs ===

/// Create a spec for updating DAO name
public fun new_update_name_spec(
    new_name: String,
    description: String,
    requires_voting: bool,
    ctx: &mut TxContext,
): IntentSpec {
    // Create the action spec with TypeName and serialized data
    let action_spec = intent_spec::new_action_spec(
        type_name::get<action_types::UpdateName>(),
        bcs::to_bytes(&new_name)
    );
    
    // Create the intent spec with the action
    intent_spec::new_intent_spec(
        description,
        vector[action_spec],
        requires_voting,
        ctx
    )
}

/// Create a spec for enabling/disabling proposals
public fun new_set_proposals_enabled_spec(
    enabled: bool,
    description: String,
    requires_voting: bool,
    ctx: &mut TxContext,
): IntentSpec {
    // Create the action spec with TypeName and serialized data
    let action_spec = intent_spec::new_action_spec(
        type_name::get<action_types::SetProposalsEnabled>(),
        bcs::to_bytes(&enabled)
    );
    
    // Create the intent spec with the action
    intent_spec::new_intent_spec(
        description,
        vector[action_spec],
        requires_voting,
        ctx
    )
}

/// Create a spec for updating slash distribution
public fun new_slash_distribution_spec(
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
    description: String,
    requires_voting: bool,
    ctx: &mut TxContext,
): IntentSpec {
    let action = config_actions::new_slash_distribution_update_action(
        slasher_reward_bps,
        dao_treasury_bps,
        protocol_bps,
        burn_bps,
    );
    
    // Create the action spec with TypeName and serialized data
    let action_spec = intent_spec::new_action_spec(
        type_name::get<action_types::SlashDistributionUpdate>(),
        bcs::to_bytes(&action)
    );
    
    // Create the intent spec with the action
    intent_spec::new_intent_spec(
        description,
        vector[action_spec],
        requires_voting,
        ctx
    )
}

// Additional spec builders can be added for other action types:
// - Liquidity actions
// - Operating agreement actions
// - Policy actions
// - Stream actions
// - Vault actions (Move framework compatible)