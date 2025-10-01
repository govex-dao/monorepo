module futarchy_oracle::oracle_intents;

// === Imports ===
use std::string::String;
use sui::{
    clock::Clock,
    bcs,
    object::ID,
};
use account_protocol::intents::{Self, Intent};
use futarchy_oracle::oracle_actions::{Self, PriceTier, RecipientMint};
use futarchy_core::action_types;
use std::option::Option;

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;

// === Witness ===

/// Witness type for oracle intents
public struct OracleIntent has drop {}

/// Create an OracleIntent witness
public fun witness(): OracleIntent {
    OracleIntent {}
}

// === Helper Functions ===

/// Add a read oracle price action to an existing intent
public fun read_oracle_price_in_intent<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    intent_witness: IW,
) {
    let action = oracle_actions::new_read_oracle_action<AssetType, StableType>(true);
    let action_data = bcs::to_bytes(&action);
    intents::add_typed_action(
        intent,
        action_types::read_oracle_price(),
        action_data,
        intent_witness
    );
    // Action has drop, no need to destroy
}

/// Add a conditional mint action to an existing intent
public fun conditional_mint_in_intent<Outcome: store, T, IW: drop>(
    intent: &mut Intent<Outcome>,
    recipient: address,
    amount: u64,
    threshold_price: u128,
    is_above_threshold: bool,
    earliest_time: Option<u64>,
    latest_time: Option<u64>,
    is_repeatable: bool,
    description: String,
    intent_witness: IW,
) {
    let action = oracle_actions::new_conditional_mint<T>(
        recipient,
        amount,
        threshold_price,
        is_above_threshold,
        earliest_time,
        latest_time,
        is_repeatable,
        description,
    );
    let action_data = bcs::to_bytes(&action);
    intents::add_typed_action(
        intent,
        action_types::conditional_mint(),
        action_data,
        intent_witness
    );
    // Action has drop, no need to destroy
}

/// Add a founder reward mint action to an existing intent
public fun founder_reward_mint_in_intent<Outcome: store, T, IW: drop>(
    intent: &mut Intent<Outcome>,
    founder: address,
    amount: u64,
    unlock_price: u128,
    unlock_delay_ms: u64,
    description: String,
    clock: &Clock,
    intent_witness: IW,
) {
    let action = oracle_actions::new_founder_reward_mint<T>(
        founder,
        amount,
        unlock_price,
        unlock_delay_ms,
        description,
        clock,
    );
    let action_data = bcs::to_bytes(&action);
    intents::add_typed_action(
        intent,
        action_types::conditional_mint(),
        action_data,
        intent_witness
    );
    // Action has drop, no need to destroy
}

/// Add a liquidity incentive action to an existing intent
public fun liquidity_incentive_in_intent<Outcome: store, T, IW: drop>(
    intent: &mut Intent<Outcome>,
    lp_address: address,
    amount_per_period: u64,
    min_price: u128,
    description: String,
    intent_witness: IW,
) {
    let action = oracle_actions::new_liquidity_incentive<T>(
        lp_address,
        amount_per_period,
        min_price,
        description,
    );
    let action_data = bcs::to_bytes(&action);
    intents::add_typed_action(
        intent,
        action_types::conditional_mint(),
        action_data,
        intent_witness
    );
    // Action has drop, no need to destroy
}

/// Add a tiered mint action to an existing intent
public fun tiered_mint_in_intent<Outcome: store, T, IW: drop>(
    intent: &mut Intent<Outcome>,
    tiers: vector<oracle_actions::PriceTier>,
    earliest_time: u64,
    latest_time: u64,
    description: String,
    security_council_id: Option<ID>,
    intent_witness: IW,
) {
    let action = oracle_actions::new_tiered_mint<T>(
        tiers,
        earliest_time,
        latest_time,
        description,
        security_council_id
    );
    let action_data = bcs::to_bytes(&action);
    intents::add_typed_action(
        intent,
        action_types::tiered_mint(),
        action_data,
        intent_witness
    );
    // Action has drop, no need to destroy
}

/// Add a tiered founder rewards action to an existing intent
public fun tiered_founder_rewards_in_intent<Outcome: store, T, IW: drop>(
    intent: &mut Intent<Outcome>,
    recipients_per_tier: vector<vector<address>>,
    amounts_per_tier: vector<vector<u64>>,
    price_thresholds: vector<u128>,
    descriptions_per_tier: vector<String>,
    earliest_time: u64,
    latest_time: u64,
    description: String,
    intent_witness: IW,
) {
    let action = oracle_actions::new_tiered_founder_rewards<T>(
        recipients_per_tier,
        amounts_per_tier,
        price_thresholds,
        descriptions_per_tier,
        earliest_time,
        latest_time,
        description
    );
    let action_data = bcs::to_bytes(&action);
    intents::add_typed_action(
        intent,
        action_types::tiered_mint(),
        action_data,
        intent_witness
    );
    // Action has drop, no need to destroy
}

/// Create a unique key for an oracle intent
public fun create_oracle_key(
    operation: String,
    clock: &Clock,
): String {
    let mut key = b"oracle_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}/// Factory for creating futarchy DAOs using account_protocol
/// This is the main entry point for creating DAOs in the Futarchy protocol