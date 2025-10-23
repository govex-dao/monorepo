// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Governance module for creating and executing intents from approved proposals
/// This module provides a simplified interface for governance operations
module futarchy_governance_actions::governance_intents;

// === Imports ===
use std::string::{Self, String};
use std::option::{Self, Option};
use std::vector;
use sui::{
    clock::Clock,
    tx_context::TxContext,
    object,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::{Self, Intent, Params},
    intent_interface,
};
use futarchy_types::init_action_specs::{Self, InitActionSpecs};
use futarchy_core::version;
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig},
};
use futarchy_governance_actions::intent_janitor;
use futarchy_markets_core::proposal::{Self, Proposal};
use futarchy_markets_primitives::market_state::MarketState;

// === Aliases ===
use fun intent_interface::build_intent as Account.build_intent;

// === Witness ===
/// Single witness for governance intents
public struct GovernanceWitness has copy, drop {}

/// Get the governance witness
public fun witness(): GovernanceWitness {
    GovernanceWitness {}
}

// === Execution Functions ===

/// Execute a governance intent from an approved proposal
/// This creates an Intent just-in-time from the stored IntentSpec blueprint
/// and immediately converts it to an executable for execution
/// Returns both the executable and the intent key for cleanup
public fun execute_proposal_intent<AssetType, StableType, Outcome: store + drop + copy>(
    account: &mut Account,
    proposal: &mut Proposal<AssetType, StableType>,
    _market: &MarketState,
    outcome_index: u64,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): (Executable<Outcome>, String) {
    // Get the intent spec from the proposal for the specified outcome
    let mut intent_spec_opt = proposal::take_intent_spec_for_outcome(proposal, outcome_index);

    // Extract the intent spec - if no spec exists, this indicates no action was defined for this outcome
    assert!(option::is_some(&intent_spec_opt), 4); // EIntentNotFound
    let intent_spec = option::extract(&mut intent_spec_opt);
    option::destroy_none(intent_spec_opt);

    // Create and store Intent temporarily, then immediately create Executable
    let intent_key = create_and_store_intent_from_spec(
        account,
        intent_spec,
        outcome,
        clock,
        ctx
    );

    // Now create the executable from the stored intent
    let (_outcome, executable) = account::create_executable<FutarchyConfig, Outcome, GovernanceWitness>(
        account,
        intent_key,
        clock,
        version::current(),
        GovernanceWitness{},
        ctx,
    );

    (executable, intent_key)
}

// === Helper Functions ===

/// Create and store an Intent from an InitActionSpecs blueprint
/// Returns the intent key for immediate execution
public fun create_and_store_intent_from_spec<Outcome: store + drop + copy>(
    account: &mut Account,
    spec: InitActionSpecs,
    outcome: Outcome,
    clock: &Clock,
    ctx: &mut TxContext
): String {
    // Generate a guaranteed-unique key using Sui's native ID generation
    // This ensures uniqueness even when multiple proposals execute in the same block
    let intent_key = ctx.fresh_object_address().to_string();

    // Create intent parameters with immediate execution
    let params = intents::new_params(
        intent_key,
        b"Just-in-time Proposal Execution".to_string(),
        vector[clock.timestamp_ms()], // Execute immediately
        clock.timestamp_ms() + 3_600_000, // 1 hour expiry
        clock,
        ctx
    );

    // Create the intent using the account module
    let mut intent = account::create_intent(
        account,
        params,
        outcome,
        b"ProposalExecution".to_string(),
        version::current(),
        witness(),
        ctx
    );

    // Add all actions from the spec to the intent
    let actions = init_action_specs::actions(&spec);
    let mut i = 0;
    let len = vector::length(actions);
    while (i < len) {
        let action = vector::borrow(actions, i);
        // Add the action to the intent using add_action_spec
        intents::add_action_spec(
            &mut intent,
            witness(),
            *init_action_specs::action_data(action),
            witness()
        );
        i = i + 1;
    };

    // Store the intent in the account
    let key_copy = intent_key;
    let expiration_time = clock.timestamp_ms() + 3_600_000; // Same as above
    account::insert_intent(account, intent, version::current(), witness());

    // Register the intent with the janitor for tracking and cleanup
    intent_janitor::register_intent(account, intent_key, expiration_time, ctx);

    key_copy
}

// === Notes ===
// For actual action execution, use the appropriate modules directly:
// - Transfers: account_actions::vault_intents
// - Config: futarchy::config_intents
// - Liquidity: futarchy::liquidity_intents
// - Streaming: futarchy::stream_intents