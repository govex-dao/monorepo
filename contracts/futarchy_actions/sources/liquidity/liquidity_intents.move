module futarchy_actions::liquidity_intents;

// === Imports ===
use std::{string::String, type_name};
use sui::{
    clock::Clock,
    object::ID,
    bcs,
};
use account_protocol::{
    intents::{Self, Intent},
};
use std::option;
use futarchy_actions::liquidity_actions;
use futarchy_utils::action_types;

// === Witness ===

/// Witness type for liquidity intents
public struct LiquidityIntent has copy, drop {}

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
    intents::add_action_spec(
        intent,
        action,
        action_types::AddLiquidity {},
        intent_witness
    );
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
    intents::add_action_spec(
        intent,
        action,
        action_types::RemoveLiquidity {},
        intent_witness
    );
}

/// Add a create pool action to an existing intent
public fun create_pool_to_intent<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
    placeholder_out: option::Option<u64>,
    intent_witness: IW,
) {
    let action = liquidity_actions::new_create_pool_action<AssetType, StableType>(
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
        placeholder_out,
    );
    intents::add_action_spec(
        intent,
        action,
        action_types::CreatePool {},
        intent_witness
    );
}

/// Add an update pool params action using placeholder
public fun update_pool_params_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    pool_id: option::Option<ID>,
    placeholder_in: option::Option<u64>,
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
    intent_witness: IW,
) {
    let action = liquidity_actions::new_update_pool_params_action(
        pool_id,
        placeholder_in,
        new_fee_bps,
        new_minimum_liquidity,
    );
    intents::add_action_spec(
        intent,
        action,
        action_types::UpdatePoolParams {},
        intent_witness
    );
}

/// Add a set pool status action using placeholder
public fun set_pool_status_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    pool_id: option::Option<ID>,
    placeholder_in: option::Option<u64>,
    is_paused: bool,
    intent_witness: IW,
) {
    let action = liquidity_actions::new_set_pool_status_action(
        pool_id,
        placeholder_in,
        is_paused,
    );
    intents::add_action_spec(
        intent,
        action,
        action_types::SetPoolStatus {},
        intent_witness
    );
}

/// Helper to create pool and configure it in a single intent using placeholders
public fun create_and_configure_pool<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
    intent_witness: IW,
) {
    // Reserve a placeholder for the pool ID
    let pool_placeholder = intents::reserve_placeholder_id(intent);

    // Create pool and write ID to placeholder
    create_pool_to_intent<Outcome, AssetType, StableType, IW>(
        intent,
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
        option::some(pool_placeholder),
        intent_witness
    );

    // Can add subsequent actions that use the pool ID from placeholder
    // For example, could immediately set status or update params
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