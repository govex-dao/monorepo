// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// User-facing API for creating dividend-related intents
module futarchy_dividend_actions::dividend_intents;

use account_protocol::intents::Intent;
use futarchy_types::action_type_markers as action_types;
use futarchy_dividend_actions::dividend_actions;
use std::bcs;
use sui::clock::Clock;
use sui::object::ID;

// === Use Fun Aliases ===
use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Witness ===

/// Witness type for dividend intents
public struct DividendIntent has drop {}

/// Create a DividendIntent witness
public fun witness(): DividendIntent {
    DividendIntent {}
}

// === Helper Functions ===

/// Add a create dividend action to an existing intent
/// Requires a pre-built DividendTree (built off-chain using dividend_tree module)
public fun create_dividend_in_intent<Outcome: store, CoinType, IW: drop>(
    intent: &mut Intent<Outcome>,
    tree_id: ID,
    intent_witness: IW,
) {
    let action = dividend_actions::new_create_dividend_action<CoinType>(tree_id);
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(action_types::create_dividend(), action_data, intent_witness);
}

/// Create a unique key for a dividend intent
public fun create_dividend_key(operation: std::string::String, clock: &Clock): std::string::String {
    let mut key = b"dividend_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
