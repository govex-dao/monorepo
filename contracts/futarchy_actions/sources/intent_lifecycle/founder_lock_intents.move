module futarchy_actions::incentives_and_options_intents;

// === Imports ===
use std::string::String;
use sui::{clock::Clock, object::ID};
use account_protocol::intents::Intent;
use futarchy_actions::incentives_and_options_actions;
use futarchy_actions::incentives_and_options_proposal::PriceTier;
use futarchy_utils::action_types;

// === Use Fun Aliases ===
use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Witness ===

/// Witness type for incentives_and_options intents
public struct IncentivesAndOptionsIntent has drop {}

/// Create a IncentivesAndOptionsIntent witness
public fun witness(): IncentivesAndOptionsIntent {
    IncentivesAndOptionsIntent {}
}

// === Helper Functions ===

/// Add a create incentives_and_options proposal action to an existing intent
public fun create_incentives_and_options_proposal_in_intent<Outcome: store, AssetType, IW: drop>(
    intent: &mut Intent<Outcome>,
    committed_amount: u64,
    tiers: vector<PriceTier>,
    proposal_id: ID,
    trading_start: u64,
    trading_end: u64,
    description: String,
    intent_witness: IW,
) {
    let action = incentives_and_options_actions::new_create_incentives_and_options_proposal_action<AssetType>(
        committed_amount,
        tiers,
        proposal_id,
        trading_start,
        trading_end,
        description,
    );
    intent.add_typed_action(action, action_types::create_incentives_and_options_proposal(), intent_witness);
}

/// Add an execute incentives_and_options action to an existing intent
public fun execute_incentives_and_options_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    incentives_and_options_id: ID,
    intent_witness: IW,
) {
    let action = incentives_and_options_actions::new_execute_incentives_and_options_action(incentives_and_options_id);
    intent.add_typed_action(action, action_types::execute_incentives_and_options(), intent_witness);
}

/// Add an update incentives_and_options recipient action to an existing intent
public fun update_incentives_and_options_recipient_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    incentives_and_options_id: ID,
    new_recipient: address,
    intent_witness: IW,
) {
    let action = incentives_and_options_actions::new_update_incentives_and_options_recipient_action(
        incentives_and_options_id,
        new_recipient,
    );
    intent.add_typed_action(action, action_types::update_incentives_and_options_recipient(), intent_witness);
}

/// Add a withdraw unlocked tokens action to an existing intent
public fun withdraw_unlocked_tokens_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    incentives_and_options_id: ID,
    intent_witness: IW,
) {
    let action = incentives_and_options_actions::new_withdraw_unlocked_tokens_action(incentives_and_options_id);
    intent.add_typed_action(action, action_types::withdraw_unlocked_tokens(), intent_witness);
}

/// Create a unique key for a incentives_and_options intent
public fun create_incentives_and_options_key(
    operation: String,
    clock: &Clock,
): String {
    let mut key = b"incentives_and_options_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}