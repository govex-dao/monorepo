// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Oracle intent builders for price-based grants
module futarchy_oracle::oracle_intents;

use account_protocol::intents::{Self, Intent};
use futarchy_oracle::oracle_actions;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::object;

// === Intent Builder Functions ===

/// Add create oracle grant action to an intent
/// Creates grant with N tiers and N recipients per tier
public fun create_grant_in_intent<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    tier_specs: vector<oracle_actions::TierSpec>,
    launchpad_multiplier: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    cancelable: bool,
    description: String,
    intent_witness: IW,
) {
    assert!(tier_specs.length() > 0, 0);

    let action = oracle_actions::new_create_oracle_grant<AssetType, StableType>(
        tier_specs,
        launchpad_multiplier,
        earliest_execution_offset_ms,
        expiry_years,
        cancelable,
        description,
    );

    intents::add_typed_action(
        intent,
        type_name::with_defining_ids<oracle_actions::CreateOracleGrant>().into_string().to_string(),
        bcs::to_bytes(&action),
        intent_witness,
    );
}

/// Add a cancel grant action to an intent
public fun cancel_grant_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    grant_id: object::ID,
    intent_witness: IW,
) {
    let action = oracle_actions::new_cancel_grant(grant_id);
    intents::add_typed_action(
        intent,
        type_name::with_defining_ids<oracle_actions::CancelGrant>().into_string().to_string(),
        bcs::to_bytes(&action),
        intent_witness,
    );
}

/// Add an emergency freeze grant action to an intent
public fun emergency_freeze_grant_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    grant_id: object::ID,
    intent_witness: IW,
) {
    let action = oracle_actions::new_emergency_freeze_grant(grant_id);
    intents::add_typed_action(
        intent,
        type_name::with_defining_ids<oracle_actions::EmergencyFreezeGrant>().into_string().to_string(),
        bcs::to_bytes(&action),
        intent_witness,
    );
}

/// Add an emergency unfreeze grant action to an intent
public fun emergency_unfreeze_grant_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    grant_id: object::ID,
    intent_witness: IW,
) {
    let action = oracle_actions::new_emergency_unfreeze_grant(grant_id);
    intents::add_typed_action(
        intent,
        type_name::with_defining_ids<oracle_actions::EmergencyUnfreezeGrant>().into_string().to_string(),
        bcs::to_bytes(&action),
        intent_witness,
    );
}

/// Create a unique key for an oracle intent
public fun create_oracle_key(operation: String, clock: &Clock): String {
    let mut key = b"oracle_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
