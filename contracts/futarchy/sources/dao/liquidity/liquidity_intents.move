/// User-facing API for creating liquidity-related intents
/// This module provides helper functions for creating liquidity actions
/// The actual intent creation must be done by the governance system that provides the Outcome
module futarchy::liquidity_intents;

// === Imports ===
use std::string::String;
use sui::{
    clock::Clock,
    object::ID,
};
use account_protocol::{
    intents::Intent,
};
use futarchy::liquidity_actions;

// === Witness ===

/// Witness type for liquidity intents
public struct LiquidityIntent has drop {}

/// Create a LiquidityIntent witness
public fun witness(): LiquidityIntent {
    LiquidityIntent {}
}

// === Helper Functions ===

/// Add an add liquidity action to an existing intent
public fun add_liquidity_to_intent<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64,
    intent_witness: IW,
) {
    let action = liquidity_actions::new_add_liquidity_action<AssetType, StableType>(
        pool_id,
        asset_amount,
        stable_amount,
        min_lp_amount,
    );
    intent.add_action(action, intent_witness);
}

/// Add a remove liquidity action to an existing intent
public fun remove_liquidity_from_intent<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    pool_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    intent_witness: IW,
) {
    let action = liquidity_actions::new_remove_liquidity_action<AssetType, StableType>(
        pool_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
    );
    intent.add_action(action, intent_witness);
}

/// Create a unique key for a liquidity intent
public fun create_liquidity_key(
    operation: String,
    clock: &Clock,
): String {
    let mut key = b"liquidity_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
