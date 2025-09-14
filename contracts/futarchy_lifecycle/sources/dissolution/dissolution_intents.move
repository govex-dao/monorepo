/// User-facing API for creating dissolution-related intents
/// This module provides helper functions for creating dissolution actions
/// The actual intent creation must be done by the governance system that provides the Outcome
module futarchy_lifecycle::dissolution_intents;

// === Imports ===
use std::string::String;
use sui::clock::Clock;
use account_protocol::{
    intents::{Self, Intent},
    metadata,
};
use futarchy_lifecycle::dissolution_actions;
use futarchy_utils::action_types;

// === Use Fun Aliases === (removed, using add_action_spec directly)

// === Witness ===

/// Witness type for dissolution intents
public struct DissolutionIntent has drop, store {}

/// Create a DissolutionIntent witness
public fun witness(): DissolutionIntent {
    DissolutionIntent {}
}

// === Helper Functions ===

/// Add an initiate dissolution action to an existing intent
public fun initiate_dissolution_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    reason: String,
    distribution_method: u8,
    burn_unsold_tokens: bool,
    final_operations_deadline: u64,
    intent_witness: IW,
) {
    let action = dissolution_actions::new_initiate_dissolution_action(
        reason,
        distribution_method,
        burn_unsold_tokens,
        final_operations_deadline,
    );
    intents::add_action_spec(
        intent,
        action,
        action_types::InitiateDissolution {},
        intent_witness
    );
}

/// Add a batch distribute action to an existing intent
public fun batch_distribute_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    asset_types: vector<String>,
    intent_witness: IW,
) {
    let action = dissolution_actions::new_batch_distribute_action(asset_types);
    intents::add_action_spec(
        intent,
        action,
        action_types::BatchDistribute {},
        intent_witness
    );
}

/// Add a finalize dissolution action to an existing intent
public fun finalize_dissolution_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    final_recipient: address,
    destroy_account: bool,
    intent_witness: IW,
) {
    let action = dissolution_actions::new_finalize_dissolution_action(
        final_recipient,
        destroy_account,
    );
    intents::add_action_spec(
        intent,
        action,
        action_types::FinalizeDissolution {},
        intent_witness
    );
}

/// Add a cancel dissolution action to an existing intent
public fun cancel_dissolution_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    reason: String,
    intent_witness: IW,
) {
    let action = dissolution_actions::new_cancel_dissolution_action(reason);
    intents::add_action_spec(
        intent,
        action,
        action_types::CancelDissolution {},
        intent_witness
    );
}

/// Create a unique key for a dissolution intent
public fun create_dissolution_key(
    operation: String,
    clock: &Clock,
): String {
    let mut key = b"dissolution_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}

/// Helper to create a pro-rata distribution plan
public fun create_prorata_distribution<CoinType>(
    total_amount: u64,
    holders: vector<address>,
    balances: vector<u64>,
): (vector<address>, vector<u64>) {
    let mut recipients = vector::empty();
    let mut amounts = vector::empty();

    // Calculate total balance
    let mut total_balance = 0;
    let mut i = 0;
    while (i < balances.length()) {
        total_balance = total_balance + *balances.borrow(i);
        i = i + 1;
    };

    // Calculate pro-rata amounts
    if (total_balance > 0) {
        i = 0;
        while (i < holders.length()) {
            let holder = *holders.borrow(i);
            let balance = *balances.borrow(i);
            let amount = (total_amount * balance) / total_balance;

            if (amount > 0) {
                recipients.push_back(holder);
                amounts.push_back(amount);
            };

            i = i + 1;
        };
    };

    (recipients, amounts)
}

/// Helper to create an equal distribution plan
public fun create_equal_distribution(
    total_amount: u64,
    recipients: vector<address>,
): vector<u64> {
    let count = recipients.length();
    let amount_per_recipient = total_amount / count;

    let mut amounts = vector::empty();
    let mut i = 0;
    while (i < count) {
        amounts.push_back(amount_per_recipient);
        i = i + 1;
    };

    amounts
}