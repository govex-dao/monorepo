// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// User-facing API for creating stream-related intents
/// This module provides helper functions for creating stream actions
/// The actual intent creation must be done by the governance system that provides the Outcome
module futarchy_stream_actions::stream_intents;

use account_actions::vault;
use account_extensions::framework_action_types;
use account_protocol::intents::Intent;
use futarchy_core::action_type_markers;
use futarchy_stream_actions::stream_actions;
use std::bcs;
use std::option::Option;
use std::string::String;
use sui::clock::Clock;

// === Use Fun Aliases ===
use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Witness ===

/// Witness type for stream intents
public struct StreamIntent has drop {}

/// Create a StreamIntent witness
public fun witness(): StreamIntent {
    StreamIntent {}
}

// === Helper Functions ===

/// Add a create stream action to an existing intent with direct treasury funding
public fun create_stream_in_intent<Outcome: store, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    recipient: address,
    total_amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    cliff_timestamp: Option<u64>,
    cancellable: bool,
    description: String,
    clock: &Clock,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    let action = stream_actions::new_create_payment_action<CoinType>(
        0, // payment_type: STREAM_TYPE_LINEAR
        0, // source_mode: SOURCE_TREASURY
        recipient,
        total_amount,
        start_timestamp,
        end_timestamp,
        cliff_timestamp, // interval_or_cliff
        1, // total_payments: 1 for stream
        cancellable,
        description,
        0, // max_per_withdrawal: 0 for unlimited
        0, // min_interval_ms: 0 for no limit
        0, // max_beneficiaries: 0 for unlimited
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::create_payment(), action_data, intent_witness);

    // Direct treasury streams don't need upfront funding
    // Funds will be withdrawn on each claim via vault::SpendAction
}

/// Add a create stream action with isolated pool funding
/// Note: This requires two witnesses since we add two actions
public fun create_isolated_stream_in_intent<Outcome: store, CoinType, IW: copy + drop>(
    intent: &mut Intent<Outcome>,
    recipient: address,
    total_amount: u64,
    start_timestamp: u64,
    end_timestamp: u64,
    cliff_timestamp: Option<u64>,
    cancellable: bool,
    description: String,
    clock: &Clock,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    // First add the stream creation action
    let action = stream_actions::new_create_payment_action<CoinType>(
        0, // payment_type: STREAM_TYPE_LINEAR
        1, // source_mode: SOURCE_ISOLATED_POOL
        recipient,
        total_amount,
        start_timestamp,
        end_timestamp,
        cliff_timestamp, // interval_or_cliff
        1, // total_payments: 1 for stream
        cancellable,
        description,
        0, // max_per_withdrawal: 0 for unlimited
        0, // min_interval_ms: 0 for no limit
        0, // max_beneficiaries: 0 for unlimited
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::create_payment(), action_data, intent_witness);

    // Then add a vault spend action to fund the isolated pool
    vault::new_spend<Outcome, CoinType, IW>(
        intent,
        b"treasury".to_string(),
        total_amount,
        intent_witness,
    );
}

/// Add a create recurring payment with isolated pool
public fun create_recurring_payment_in_intent<Outcome: store, CoinType, IW: copy + drop>(
    intent: &mut Intent<Outcome>,
    recipient: address,
    amount_per_payment: u64,
    interval_ms: u64,
    total_payments: u64,
    end_timestamp: Option<u64>,
    cancellable: bool,
    description: String,
    clock: &Clock,
    intent_witness: IW,
    ctx: &mut TxContext,
) {
    // First add the recurring payment action
    let action = stream_actions::new_create_payment_action<CoinType>(
        1, // payment_type: PAYMENT_TYPE_RECURRING
        1, // source_mode: SOURCE_ISOLATED_POOL
        recipient,
        amount_per_payment * total_payments, // total amount for all payments
        clock.timestamp_ms(), // start_timestamp
        if (end_timestamp.is_some()) { *end_timestamp.borrow() } else { 0 }, // end_timestamp
        option::some(interval_ms), // interval_or_cliff (interval for recurring)
        total_payments,
        cancellable,
        description,
        0, // max_per_withdrawal: 0 for unlimited
        0, // min_interval_ms: 0 for no limit
        0, // max_beneficiaries: 0 for unlimited
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::create_payment(), action_data, intent_witness);

    // Calculate total funding needed
    let total_funding = if (total_payments > 0) {
        amount_per_payment * total_payments
    } else {
        // For unlimited payments, fund initial amount (e.g., 12 payments worth)
        amount_per_payment * 12
    };

    // Add vault spend action to fund the pool
    vault::new_spend<Outcome, CoinType, IW>(
        intent,
        b"treasury".to_string(),
        total_funding,
        intent_witness,
    );
}

/// Add an execute payment action to an intent (claim from stream)
public fun execute_payment_in_intent<Outcome: store, CoinType, IW: copy + drop>(
    intent: &mut Intent<Outcome>,
    payment_id: String,
    amount: Option<u64>,
    intent_witness: IW,
) {
    // For direct treasury payments, add a vault spend action first
    // The dispatcher will coordinate passing the coin to the execution
    if (amount.is_some()) {
        vault::new_spend<Outcome, CoinType, IW>(
            intent,
            b"treasury".to_string(),
            *amount.borrow(),
            intent_witness,
        );
    };

    // Then add the execute payment action
    let action = stream_actions::new_execute_payment_action<CoinType>(
        payment_id,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::create_payment(), action_data, intent_witness);
}

/// Add a cancel stream action to an existing intent
public fun cancel_stream_in_intent<Outcome: store, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    stream_id: String,
    return_unclaimed: bool,
    intent_witness: IW,
) {
    // Note: If there's a final claimable amount, a vault::SpendAction
    // should be added before this action to provide the final payment coin
    let action = stream_actions::new_cancel_payment_action(
        stream_id,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::cancel_payment(), action_data, intent_witness);
}

/// Create a unique key for a stream intent
public fun create_stream_key(operation: String, clock: &Clock): String {
    let mut key = b"stream_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
