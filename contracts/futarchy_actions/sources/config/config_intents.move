// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Consolidated config intent creation module
/// Combines basic and advanced configuration intent creation
module futarchy_actions::config_intents;

use account_protocol::account::Account;
use account_protocol::executable::Executable;
use account_protocol::intent_interface;
use account_protocol::intents::{Self, Intent, Params};
use account_protocol::schema::{Self, ActionDecoderRegistry};
use futarchy_actions::config_actions;
use futarchy_types::action_type_markers;
use futarchy_core::dao_config;
use futarchy_core::futarchy_config::FutarchyConfig;
use futarchy_core::version;
use std::ascii::String as AsciiString;
use std::bcs;
use std::option::{Self, Option};
use std::string::String;
use std::type_name;
use sui::clock::Clock;
use sui::tx_context::TxContext;
use sui::url::Url;

// === Use Fun Aliases === (removed, using add_action_spec directly)

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Single Witness ===
public struct ConfigIntent has copy, drop {}

// === Basic Intent Creation Functions ===

/// Create intent to enable/disable proposals
public fun create_set_proposals_enabled_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    registry: &ActionDecoderRegistry,
    params: Params,
    outcome: Outcome,
    enabled: bool,
    ctx: &mut TxContext,
) {
    // Enforce decoder exists for this action type
    schema::assert_decoder_exists(
        registry,
        type_name::with_defining_ids<config_actions::SetProposalsEnabledAction>(),
    );

    // Use standard DAO settings for intent params (expiry, etc.)
    account.build_intent!(
        params,
        outcome,
        b"config_set_proposals_enabled".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_set_proposals_enabled_action(enabled);
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::set_proposals_enabled(),
                action_bytes,
                iw,
            );
        },
    );
}

/// Create intent to update DAO name
public fun create_update_name_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    registry: &ActionDecoderRegistry,
    params: Params,
    outcome: Outcome,
    new_name: String,
    ctx: &mut TxContext,
) {
    // Enforce decoder exists for this action type
    schema::assert_decoder_exists(
        registry,
        type_name::with_defining_ids<config_actions::UpdateNameAction>(),
    );

    account.build_intent!(
        params,
        outcome,
        b"config_update_name".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_update_name_action(new_name);
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::update_name(),
                action_bytes,
                iw,
            );
        },
    );
}

// === Advanced Intent Creation Functions ===

/// Create intent to update DAO metadata
public fun create_update_metadata_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    name: AsciiString,
    icon_url: Url,
    description: String,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_metadata".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_metadata_update_action(
                option::some(name),
                option::some(icon_url),
                option::some(description),
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::set_metadata(),
                action_bytes,
                iw,
            );
        },
    );
}

/// Create intent to update trading parameters
public fun create_update_trading_params_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    review_period_ms: u64,
    trading_period_ms: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_trading_params".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_trading_params_update_action(
                option::some(min_asset_amount),
                option::some(min_stable_amount),
                option::some(review_period_ms),
                option::some(trading_period_ms),
                option::none(), // amm_total_fee_bps
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::update_trading_config(),
                action_bytes,
                iw,
            );
        },
    );
}

/// Create intent to update TWAP configuration
public fun create_update_twap_config_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    start_delay: u64,
    step_max: u64,
    initial_observation: u128,
    threshold: u64,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_twap".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_twap_config_update_action(
                option::some(start_delay),
                option::some(step_max),
                option::some(initial_observation),
                option::some(threshold),
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::update_twap_config(),
                action_bytes,
                iw,
            );
        },
    );
}

/// Create intent to update governance settings
public fun create_update_governance_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    proposals_enabled: bool,
    max_outcomes: u64,
    max_actions_per_outcome: u64,
    required_bond_amount: u64,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_governance".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_governance_update_action(
                option::some(proposals_enabled),
                option::some(max_outcomes),
                option::some(max_actions_per_outcome),
                option::some(required_bond_amount),
                option::none(), // max_intents_per_outcome - not specified
                option::none(), // proposal_intent_expiry_ms - not specified
                option::none(), // optimistic_challenge_fee - not specified
                option::none(), // optimistic_challenge_period_ms - not specified
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::update_governance(),
                action_bytes,
                iw,
            );
        },
    );
}

/// Create a flexible intent to update governance settings with optional parameters
public fun create_update_governance_flexible_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    proposals_enabled: Option<bool>,
    max_outcomes: Option<u64>,
    max_actions_per_outcome: Option<u64>,
    required_bond_amount: Option<u64>,
    max_intents_per_outcome: Option<u64>,
    proposal_intent_expiry_ms: Option<u64>,
    optimistic_challenge_fee: Option<u64>,
    optimistic_challenge_period_ms: Option<u64>,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_governance_flexible".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_governance_update_action(
                proposals_enabled,
                max_outcomes,
                max_actions_per_outcome,
                required_bond_amount,
                max_intents_per_outcome,
                proposal_intent_expiry_ms,
                optimistic_challenge_fee,
                optimistic_challenge_period_ms,
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::update_governance(),
                action_bytes,
                iw,
            );
        },
    );
}

/// Create intent to update slash distribution
public fun create_update_slash_distribution_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    slasher_reward_bps: u16,
    dao_treasury_bps: u16,
    protocol_bps: u16,
    burn_bps: u16,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_slash_distribution".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_slash_distribution_update_action(
                slasher_reward_bps,
                dao_treasury_bps,
                protocol_bps,
                burn_bps,
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::update_slash_distribution(),
                action_bytes,
                iw,
            );
        },
    );
}

/// Create intent to update queue parameters
public fun create_update_queue_params_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    max_proposer_funded: u64,
    max_concurrent_proposals: u64,
    fee_escalation_basis_points: u64,
    ctx: &mut TxContext,
) {
    account.build_intent!(
        params,
        outcome,
        b"config_update_queue_params".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_queue_params_update_action(
                option::some(max_proposer_funded),
                option::some(max_concurrent_proposals),
                option::none(), // max_queue_size - not specified
                option::some(fee_escalation_basis_points),
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::update_queue_params(),
                action_bytes,
                iw,
            );
        },
    );
}

/// Create intent to update conditional metadata configuration
public fun create_update_conditional_metadata_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    registry: &ActionDecoderRegistry,
    params: Params,
    outcome: Outcome,
    use_outcome_index: Option<bool>,
    conditional_metadata: Option<Option<dao_config::ConditionalMetadata>>,
    ctx: &mut TxContext,
) {
    // Enforce decoder exists for this action type
    schema::assert_decoder_exists(
        registry,
        type_name::with_defining_ids<config_actions::ConditionalMetadataUpdateAction>(),
    );

    account.build_intent!(
        params,
        outcome,
        b"config_update_conditional_metadata".to_string(),
        version::current(),
        ConfigIntent {},
        ctx,
        |intent, iw| {
            let action = config_actions::new_conditional_metadata_update_action(
                use_outcome_index,
                conditional_metadata,
            );
            let action_bytes = bcs::to_bytes(&action);
            intent.add_typed_action(
                action_type_markers::update_conditional_metadata(),
                action_bytes,
                iw,
            );
        },
    );
}

// === Backward compatibility aliases ===

/// Alias for TWAP params intent (backward compatibility)
public fun create_update_twap_params_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    twap_start_delay: u64,
    twap_step_max: u64,
    twap_initial_observation: u128,
    twap_threshold: u64,
    ctx: &mut TxContext,
) {
    create_update_twap_config_intent(
        account,
        params,
        outcome,
        twap_start_delay,
        twap_step_max,
        twap_initial_observation,
        twap_threshold,
        ctx,
    );
}

/// Alias for fee params intent (backward compatibility)
public fun create_update_fee_params_intent<Outcome: store + drop + copy>(
    account: &mut Account<FutarchyConfig>,
    params: Params,
    outcome: Outcome,
    max_proposer_funded: u64,
    max_concurrent_proposals: u64,
    fee_escalation_basis_points: u64,
    ctx: &mut TxContext,
) {
    create_update_queue_params_intent(
        account,
        params,
        outcome,
        max_proposer_funded,
        max_concurrent_proposals,
        fee_escalation_basis_points,
        ctx,
    );
}

// === Intent Processing ===
// Note: Processing of config intents is handled by PTB calls
// which execute actions directly. The process_intent! macro is not
// used here because it doesn't support passing additional parameters (account, clock, ctx)
// that are needed by the action execution functions.
