module futarchy_actions::founder_lock_intents;

use account_protocol::intents::{Intent, add_typed_action};
use futarchy_actions::founder_lock_actions;
use futarchy_actions::founder_lock_proposal::PriceTier;
use futarchy_core::action_types;
use std::string::String;
use sui::bcs;
use sui::clock::Clock;
use sui::object::ID;

// === Witness ===

/// Witness type for founder lock intents
public struct FounderLockIntent has drop {}

/// Create a FounderLockIntent witness
public fun witness(): FounderLockIntent {
    FounderLockIntent {}
}

// === Helper Functions ===

/// Add a create founder lock proposal action to an existing intent
public fun create_founder_lock_proposal_in_intent<Outcome: store, AssetType, IW: drop>(
    intent: &mut Intent<Outcome>,
    committed_amount: u64,
    tiers: vector<PriceTier>,
    proposal_id: ID,
    trading_start: u64,
    trading_end: u64,
    description: String,
    intent_witness: IW,
) {
    let action = founder_lock_actions::new_create_founder_lock_proposal_action<AssetType>(
        committed_amount,
        tiers,
        proposal_id,
        trading_start,
        trading_end,
        description,
    );
    let action_bytes = bcs::to_bytes(&action);
    add_typed_action(
        intent,
        action_types::create_founder_lock_proposal(),
        action_bytes,
        intent_witness,
    );
}

/// Add an execute founder lock action to an existing intent
public fun execute_founder_lock_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    founder_lock_id: ID,
    intent_witness: IW,
) {
    let action = founder_lock_actions::new_execute_founder_lock_action(founder_lock_id);
    let action_bytes = bcs::to_bytes(&action);
    add_typed_action(intent, action_types::execute_founder_lock(), action_bytes, intent_witness);
}

/// Add an update founder lock recipient action to an existing intent
public fun update_founder_lock_recipient_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    founder_lock_id: ID,
    new_recipient: address,
    intent_witness: IW,
) {
    let action = founder_lock_actions::new_update_founder_lock_recipient_action(
        founder_lock_id,
        new_recipient,
    );
    let action_bytes = bcs::to_bytes(&action);
    add_typed_action(
        intent,
        action_types::update_founder_lock_recipient(),
        action_bytes,
        intent_witness,
    );
}

/// Add a withdraw unlocked tokens action to an existing intent
public fun withdraw_unlocked_tokens_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    founder_lock_id: ID,
    intent_witness: IW,
) {
    let action = founder_lock_actions::new_withdraw_unlocked_tokens_action(founder_lock_id);
    let action_bytes = bcs::to_bytes(&action);
    add_typed_action(
        intent,
        action_types::withdraw_unlocked_tokens(),
        action_bytes,
        intent_witness,
    );
}

/// Create a unique key for a founder lock intent
public fun create_founder_lock_key(operation: String, clock: &Clock): String {
    let mut key = b"founder_lock_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
