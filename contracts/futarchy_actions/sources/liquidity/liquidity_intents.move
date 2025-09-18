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

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;
use std::option;
use futarchy_actions::liquidity_actions;
use futarchy_core::action_types;

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
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_types::add_liquidity(),
        action_data,
        intent_witness
    );
    liquidity_actions::destroy_add_liquidity(action);
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
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_types::remove_liquidity(),
        action_data,
        intent_witness
    );
    liquidity_actions::destroy_remove_liquidity(action);
}

/// Add a create pool action to an existing intent
public fun create_pool_to_intent<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
    intent_witness: IW,
) {
    let action = liquidity_actions::new_create_pool_action<AssetType, StableType>(
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_types::create_pool(),
        action_data,
        intent_witness
    );
    liquidity_actions::destroy_create_pool(action);
}

/// Add an update pool params action
public fun update_pool_params_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    pool_id: ID,
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
    intent_witness: IW,
) {
    let action = liquidity_actions::new_update_pool_params_action(
        pool_id,
        new_fee_bps,
        new_minimum_liquidity,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_types::update_pool_params(),
        action_data,
        intent_witness
    );
    liquidity_actions::destroy_update_pool_params(action);
}

/// Add a set pool status action
public fun set_pool_status_to_intent<Outcome: store, IW: drop>(
    intent: &mut Intent<Outcome>,
    pool_id: ID,
    is_paused: bool,
    intent_witness: IW,
) {
    let action = liquidity_actions::new_set_pool_status_action(
        pool_id,
        is_paused,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        action_types::set_pool_status(),
        action_data,
        intent_witness
    );
    liquidity_actions::destroy_set_pool_status(action);
}

/// Helper to create pool in an intent
///
/// Note on chaining: Pool creation uses the ResourceRequest pattern which allows
/// proper chaining within a single PTB (Programmable Transaction Block):
///
/// 1. do_create_pool() returns ResourceRequest<CreatePoolAction>
/// 2. fulfill_create_pool() consumes the request and returns (ResourceReceipt, pool_id)
/// 3. The pool_id can be used immediately in subsequent actions within the same PTB
///
/// Example PTB composition:
/// - Call do_create_pool() → get ResourceRequest
/// - Call fulfill_create_pool() → get pool_id
/// - Call do_add_liquidity() using the pool_id
/// - Call do_update_pool_params() using the pool_id
///
/// All these can be chained in a single atomic transaction using PTB composition.
public fun create_and_configure_pool<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
    intent_witness: IW,
) {
    // Create the pool action - this will generate a ResourceRequest during execution
    // The ResourceRequest pattern ensures proper chaining of dependent actions
    create_pool_to_intent<Outcome, AssetType, StableType, IW>(
        intent,
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
        intent_witness
    );

    // Note: Subsequent actions that need the pool_id should be added to the same intent
    // and will be executed in the same PTB transaction, allowing access to the newly created pool_id
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