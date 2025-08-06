/// User-facing API for creating stream-related intents
/// This module provides helper functions for creating stream actions
/// The actual intent creation must be done by the governance system that provides the Outcome
module futarchy_actions::stream_intents;

// === Imports ===
use std::{
    string::String,
    option::Option,
};
use sui::clock::Clock;
use account_protocol::{
    intents::Intent,
};
use futarchy_actions::stream_actions;

// === Witness ===

/// Witness type for stream intents
public struct StreamIntent has drop {}

/// Create a StreamIntent witness
public fun witness(): StreamIntent {
    StreamIntent {}
}

// === Helper Functions ===

/// Add a create stream action to an existing intent
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
) {
    let action = stream_actions::new_create_stream_action<CoinType>(
        0, // SOURCE_DIRECT_TREASURY = 0
        recipient,
        total_amount,
        start_timestamp,
        end_timestamp,
        cliff_timestamp,
        cancellable,
        description,
        clock,
    );
    intent.add_action(action, intent_witness);
}

/// Add a cancel stream action to an existing intent
public fun cancel_stream_in_intent<Outcome: store, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    stream_id: String,
    return_unclaimed: bool,
    intent_witness: IW,
) {
    let action = stream_actions::new_cancel_payment_action<CoinType>(
        stream_id,
        return_unclaimed,
    );
    intent.add_action(action, intent_witness);
}

/// Create a unique key for a stream intent
public fun create_stream_key(
    operation: String,
    clock: &Clock,
): String {
    let mut key = b"stream_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
