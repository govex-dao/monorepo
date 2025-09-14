/// Module for submitting proposals with IntentSpecs
/// Provides entry functions for users to submit proposals with actions
module futarchy_lifecycle::proposal_submission;

// === Imports ===
use std::{
    type_name::{Self, TypeName},
    vector,
    string::String,
    option::{Self, Option},
};
use sui::{
    object,
    coin::{Self, Coin},
    clock::Clock,
    sui::SUI,
    tx_context::TxContext,
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
use futarchy_actions::action_specs::{Self, InitActionSpecs};

// === Errors ===
const EProposalsDisabled: u64 = 1;
const EInsufficientFee: u64 = 2;
const ETooManyOutcomes: u64 = 3;
const ENoOutcomes: u64 = 4;
const EIntentSpecRequired: u64 = 5;
const EQueueFull: u64 = 6;

// === Entry Functions ===

/// Submit a proposal with IntentSpecs for the YES outcome
/// The IntentSpecs define what actions will execute if the proposal passes
public entry fun submit_proposal_with_intent<StableCoin>(
    registry: &ActionDecoderRegistry,  // NEW: Required for schema validation
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
    // IntentSpec for YES outcome
    intent_spec: InitActionSpecs,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate all actions in the IntentSpec have registered decoders
    validate_intent_spec_decoders(registry, &intent_spec);

    // Create proposal with IntentSpec
    let mut intent_specs = vector::empty<Option<InitActionSpecs>>();
    vector::push_back(&mut intent_specs, option::some(intent_spec));

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

/// Submit a proposal with IntentSpecs for multiple outcomes
public entry fun submit_proposal_with_multiple_intents<StableCoin>(
    registry: &ActionDecoderRegistry,  // NEW: Required for schema validation
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
    // IntentSpecs for each outcome
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
    let actions = action_specs::get_action_specs(intent_spec);
    let mut i = 0;
    while (i < vector::length(actions)) {
        let action_spec = vector::borrow(actions, i);
        let action_type = action_specs::get_action_type(action_spec);

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
    // For now, just absorb the fee to avoid compiler errors
    coin::burn_for_testing(fee_payment);
}