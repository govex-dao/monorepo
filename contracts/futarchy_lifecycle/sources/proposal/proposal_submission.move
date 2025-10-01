/// Module for submitting proposals with IntentSpecs
/// Provides entry functions for users to submit proposals with actions
module futarchy_lifecycle::proposal_submission;

// === Imports ===
use std::{
    type_name::{Self, TypeName},
    vector,
    string::String,
    option::{Self, Option},
    ascii,
};
use sui::{
    object,
    coin::{Self, Coin},
    balance::{Self, Balance},
    clock::Clock,
    sui::SUI,
    tx_context::TxContext,
    bcs,
};
use account_protocol::{
    account::{Self, Account},
    schema::{Self, ActionDecoderRegistry},
};
use futarchy_core::{
    futarchy_config::{Self, FutarchyConfig},
    priority_queue::{Self, ProposalQueue, QueuedProposal},
    proposal_fee_manager::{Self, ProposalFeeManager},
};
use futarchy_types::action_specs::{Self, InitActionSpecs};

// === Errors ===
const EProposalsDisabled: u64 = 1;
const EInsufficientFee: u64 = 2;
const ETooManyOutcomes: u64 = 3;
const ENoOutcomes: u64 = 4;
const EIntentSpecRequired: u64 = 5;
const EQueueFull: u64 = 6;
const EInvalidActionData: u64 = 7;

// === Entry Functions ===


/// Submit a proposal with action IDs for multiple outcomes
/// Note: Use submit_proposal_with_multiple_intents_v2 with pre-built IntentSpecs instead
public entry fun submit_proposal_with_action_ids<StableCoin>(
    registry: &ActionDecoderRegistry,
    account: &mut Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableCoin>,
    fee_manager: &mut ProposalFeeManager,
    fee_payment: Coin<SUI>,
    title: String,
    description: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
    // For each outcome: action IDs and data
    outcome_action_ids: vector<vector<u64>>,
    outcome_action_data: vector<vector<vector<u8>>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Build empty IntentSpecs - actual action building should happen via PTB
    let mut intent_specs = vector::empty<Option<InitActionSpecs>>();

    let num_outcomes = vector::length(&outcome_messages);
    let mut outcome_idx = 0;
    while (outcome_idx < num_outcomes) {
        vector::push_back(&mut intent_specs, option::none());
        outcome_idx = outcome_idx + 1;
    };

    submit_proposal_internal(
        account,
        queue,
        fee_manager,
        fee_payment,
        title,
        description,
        outcome_messages,
        outcome_details,
        initial_asset_amounts,
        initial_stable_amounts,
        intent_specs,
        clock,
        ctx,
    );
}

/// Submit a proposal with pre-built IntentSpecs for multiple outcomes
/// Note: Cannot be an entry function due to InitActionSpecs not having 'key' ability
/// This function should be called from a PTB that builds the IntentSpecs
public fun submit_proposal_with_multiple_intents<StableCoin>(
    registry: &ActionDecoderRegistry,
    account: &Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableCoin>,
    fee_manager: &mut ProposalFeeManager,
    fee_payment: Coin<SUI>,
    title: String,
    description: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
    intent_specs: vector<Option<InitActionSpecs>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate all actions in all IntentSpecs have registered decoders
    let mut i = 0;
    while (i < vector::length(&intent_specs)) {
        let spec_opt = vector::borrow(&intent_specs, i);
        if (option::is_some(spec_opt)) {
            let spec = option::borrow(spec_opt);
            validate_intent_spec_decoders(registry, spec);
        };
        i = i + 1;
    };

    // Continue with proposal creation...
    submit_proposal_internal(
        account,
        queue,
        fee_manager,
        fee_payment,
        title,
        description,
        outcome_messages,
        outcome_details,
        initial_asset_amounts,
        initial_stable_amounts,
        intent_specs,
        clock,
        ctx,
    );
}

/// Submit a simple proposal without any IntentSpecs
public entry fun submit_simple_proposal<StableCoin>(
    // No registry needed for simple proposals without actions
    account: &Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableCoin>,
    fee_manager: &mut ProposalFeeManager,
    fee_payment: Coin<SUI>,
    // Proposal metadata
    title: String,
    description: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    // Liquidity amounts for each outcome
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // No IntentSpecs
    let intent_specs = vector::empty<Option<InitActionSpecs>>();

    submit_proposal_internal(
        account,
        queue,
        fee_manager,
        fee_payment,
        title,
        description,
        outcome_messages,
        outcome_details,
        initial_asset_amounts,
        initial_stable_amounts,
        intent_specs,
        clock,
        ctx,
    );
}

// === Internal Functions ===

/// Validate that all actions in an IntentSpec have registered decoders
fun validate_intent_spec_decoders(
    registry: &ActionDecoderRegistry,
    intent_spec: &InitActionSpecs,
) {
    let actions = action_specs::actions(intent_spec);
    let mut i = 0;
    while (i < vector::length(actions)) {
        let action_spec = vector::borrow(actions, i);
        let action_type = action_specs::action_type(action_spec);

        // Enforce mandatory schema rule: decoder must exist
        schema::assert_decoder_exists(registry, action_type);

        i = i + 1;
    };
}

/// Internal function to submit proposal (shared logic)
fun submit_proposal_internal<StableCoin>(
    account: &Account<FutarchyConfig>,
    queue: &mut ProposalQueue<StableCoin>,
    fee_manager: &mut ProposalFeeManager,
    fee_payment: Coin<SUI>,
    title: String,
    description: String,
    outcome_messages: vector<String>,
    outcome_details: vector<String>,
    initial_asset_amounts: vector<u64>,
    initial_stable_amounts: vector<u64>,
    intent_specs: vector<Option<InitActionSpecs>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Implementation continues with existing logic...
    // This would contain the actual proposal creation logic
    // For now, just abort to avoid compiler errors since this is incomplete
    abort 0
}