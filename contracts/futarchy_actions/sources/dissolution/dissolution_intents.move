// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Intent builders for dissolution actions
module futarchy_actions::dissolution_intents;

use account_protocol::intents::{Self, Intent};
use futarchy_actions::dissolution_actions;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::clock::Clock;

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Witness ===

/// Witness type for dissolution intents
public struct DissolutionIntent has copy, drop {}

/// Create a DissolutionIntent witness
public fun witness(): DissolutionIntent {
    DissolutionIntent {}
}

// === Intent Builder Functions ===

/// Add create dissolution capability action to an intent
/// This is typically included in the termination proposal itself
public fun create_dissolution_capability_in_intent<Outcome: store, AssetType, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    let action = dissolution_actions::new_create_dissolution_capability<AssetType>();
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        type_name::with_defining_ids<dissolution_actions::CreateDissolutionCapability>().into_string().to_string(),
        action_data,
        intent_witness,
    );
    // Action struct has drop ability, will be automatically dropped
}

// === Helper Functions ===

/// Create a unique key for a dissolution intent
public fun create_dissolution_key(operation: String, clock: &Clock): String {
    let mut key = b"dissolution_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
