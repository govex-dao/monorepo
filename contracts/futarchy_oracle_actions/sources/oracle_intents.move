// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Oracle intent builders for price-based minting grants
module futarchy_oracle::oracle_intents;

use account_protocol::intents::{Self, Intent};
use futarchy_oracle::oracle_actions;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::object::ID;

// === Intent Builder Functions ===

/// Add create oracle grant action to an intent (supports 1 to N recipients)
/// Creates ONE action that generates one grant per recipient
/// Full flexibility - caller controls all parameters
public fun create_grant_in_intent<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    recipients: vector<address>,
    amounts: vector<u64>,
    vesting_mode: u8,
    vesting_cliff_months: u64,
    vesting_duration_years: u64,
    strike_mode: u8,
    strike_price: u64,
    launchpad_multiplier: u64,
    cooldown_ms: u64,
    max_executions: u64,
    earliest_execution_offset_ms: u64,
    expiry_years: u64,
    price_condition_mode: u8,
    price_threshold: u128,
    price_is_above: bool,
    cancelable: bool,
    description: String,
    intent_witness: IW,
) {
    assert!(recipients.length() > 0 && recipients.length() == amounts.length(), 0);

    let action = oracle_actions::new_create_oracle_grant<AssetType, StableType>(
        recipients,
        amounts,
        vesting_mode,
        vesting_cliff_months,
        vesting_duration_years,
        strike_mode,
        strike_price,
        launchpad_multiplier,
        cooldown_ms,
        max_executions,
        earliest_execution_offset_ms,
        expiry_years,
        price_condition_mode,
        price_threshold,
        price_is_above,
        cancelable,
        description,
    );

    intents::add_typed_action(
        intent,
        type_name::get<oracle_actions::CreateOracleGrant>().into_string().to_string(),
        bcs::to_bytes(&action),
        intent_witness,
    );
}

/// Add a cancel grant action to an intent
public fun cancel_grant_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    grant_id: ID,
    intent_witness: IW,
) {
    let action = oracle_actions::new_cancel_grant(grant_id);
    intents::add_typed_action(
        intent,
        type_name::get<oracle_actions::CancelGrant>().into_string().to_string(),
        bcs::to_bytes(&action),
        intent_witness,
    );
}

/// Add a pause grant action to an intent
public fun pause_grant_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    grant_id: ID,
    pause_duration_ms: u64,
    intent_witness: IW,
) {
    let action = oracle_actions::new_pause_grant(grant_id, pause_duration_ms);
    intents::add_typed_action(
        intent,
        type_name::get<oracle_actions::PauseGrant>().into_string().to_string(),
        bcs::to_bytes(&action),
        intent_witness,
    );
}

/// Add an unpause grant action to an intent
public fun unpause_grant_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    grant_id: ID,
    intent_witness: IW,
) {
    let action = oracle_actions::new_unpause_grant(grant_id);
    intents::add_typed_action(
        intent,
        type_name::get<oracle_actions::UnpauseGrant>().into_string().to_string(),
        bcs::to_bytes(&action),
        intent_witness,
    );
}

/// Add an emergency freeze grant action to an intent
public fun emergency_freeze_grant_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    grant_id: ID,
    intent_witness: IW,
) {
    let action = oracle_actions::new_emergency_freeze_grant(grant_id);
    intents::add_typed_action(
        intent,
        type_name::get<oracle_actions::EmergencyFreezeGrant>().into_string().to_string(),
        bcs::to_bytes(&action),
        intent_witness,
    );
}

/// Add an emergency unfreeze grant action to an intent
public fun emergency_unfreeze_grant_in_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    grant_id: ID,
    intent_witness: IW,
) {
    let action = oracle_actions::new_emergency_unfreeze_grant(grant_id);
    intents::add_typed_action(
        intent,
        type_name::get<oracle_actions::EmergencyUnfreezeGrant>().into_string().to_string(),
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
