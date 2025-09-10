/// User-facing API for creating commitment-related intents
/// This module provides helper functions for creating commitment actions
/// The actual intent creation must be done by the governance system that provides the Outcome
module futarchy_actions::commitment_intents;

// === Imports ===
use std::string::String;
use sui::{clock::Clock, object::ID};
use account_protocol::intents::Intent;
use futarchy_actions::commitment_actions;
use futarchy_actions::commitment_proposal::PriceTier;
use account_extensions::action_descriptor::{Self, ActionDescriptor};

// === Use Fun Aliases ===
use fun account_protocol::intents::add_action_with_descriptor as Intent.add_action_with_descriptor;

// === Witness ===

/// Witness type for commitment intents
public struct CommitmentIntent has drop {}

/// Create a CommitmentIntent witness
public fun witness(): CommitmentIntent {
    CommitmentIntent {}
}

// === Helper Functions ===

/// Add a create commitment proposal action to an existing intent
public fun create_commitment_proposal_in_intent<Outcome: store, AssetType, IW: drop>(
    intent: &mut Intent<Outcome>,
    committed_amount: u64,
    tiers: vector<PriceTier>,
    proposal_id: ID,
    trading_start: u64,
    trading_end: u64,
    description: String,
    intent_witness: IW,
) {
    let action = commitment_actions::new_create_commitment_proposal_action<AssetType>(
        committed_amount,
        tiers,
        proposal_id,
        trading_start,
        trading_end,
        description,
    );
    let descriptor = action_descriptor::new(b"commitment", b"create");
    intent.add_action_with_descriptor(action, descriptor, intent_witness);
}

/// Add an execute commitment action to an existing intent
public fun execute_commitment_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    commitment_id: ID,
    intent_witness: IW,
) {
    let action = commitment_actions::new_execute_commitment_action(commitment_id);
    let descriptor = action_descriptor::new(b"commitment", b"execute");
    intent.add_action_with_descriptor(action, descriptor, intent_witness);
}

/// Add an update commitment recipient action to an existing intent
public fun update_commitment_recipient_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    commitment_id: ID,
    new_recipient: address,
    intent_witness: IW,
) {
    let action = commitment_actions::new_update_commitment_recipient_action(
        commitment_id,
        new_recipient,
    );
    let descriptor = action_descriptor::new(b"commitment", b"update_recipient");
    intent.add_action_with_descriptor(action, descriptor, intent_witness);
}

/// Add a withdraw unlocked tokens action to an existing intent
public fun withdraw_unlocked_tokens_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    commitment_id: ID,
    intent_witness: IW,
) {
    let action = commitment_actions::new_withdraw_unlocked_tokens_action(commitment_id);
    let descriptor = action_descriptor::new(b"commitment", b"withdraw");
    intent.add_action_with_descriptor(action, descriptor, intent_witness);
}

/// Create a unique key for a commitment intent
public fun create_commitment_key(
    operation: String,
    clock: &Clock,
): String {
    let mut key = b"commitment_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}