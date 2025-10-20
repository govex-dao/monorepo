// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

module futarchy_actions::liquidity_intents;

use account_protocol::intents::{Self, Intent};
use futarchy_actions::liquidity_actions;
use std::option;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::clock::Clock;
use sui::object::ID;

use fun account_protocol::intents::add_typed_action as Intent.add_typed_action;
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
        type_name::get<liquidity_actions::AddLiquidity>().into_string().to_string(),
        action_data,
        intent_witness,
    );
    // Action struct has drop ability, will be automatically dropped
}

/// Add a remove liquidity action to an existing intent
public fun remove_liquidity_from_intent<Outcome: store, AssetType, StableType, IW: copy + drop>(
    intent: &mut Intent<Outcome>,
    pool_id: ID,
    token_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    intent_witness: IW,
) {
    // Step 1: release the LP token from custody
    withdraw_lp_token_from_intent<Outcome, AssetType, StableType, IW>(
        intent,
        pool_id,
        token_id,
        copy intent_witness,
    );

    // Step 2: queue the actual remove liquidity action
    let action = liquidity_actions::new_remove_liquidity_action<AssetType, StableType>(
        pool_id,
        token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        type_name::get<liquidity_actions::RemoveLiquidity>().into_string().to_string(),
        action_data,
        intent_witness,
    );
    // Action struct has drop ability, will be automatically dropped
}

/// Add a withdraw LP token action to an existing intent
public fun withdraw_lp_token_from_intent<Outcome: store, AssetType, StableType, IW: drop>(
    intent: &mut Intent<Outcome>,
    pool_id: ID,
    token_id: ID,
    intent_witness: IW,
) {
    let action = liquidity_actions::new_withdraw_lp_token_action<AssetType, StableType>(
        pool_id,
        token_id,
    );
    let action_data = bcs::to_bytes(&action);
    intent.add_typed_action(
        type_name::get<liquidity_actions::WithdrawLpToken>().into_string().to_string(),
        action_data,
        intent_witness,
    );
    // Action struct has drop ability, will be automatically dropped
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
        type_name::get<liquidity_actions::CreatePool>().into_string().to_string(),
        action_data,
        intent_witness,
    );
    // Action struct has drop ability, will be automatically dropped
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
        type_name::get<liquidity_actions::UpdatePoolParams>().into_string().to_string(),
        action_data,
        intent_witness,
    );
    // Action struct has drop ability, will be automatically dropped
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
        type_name::get<liquidity_actions::SetPoolStatus>().into_string().to_string(),
        action_data,
        intent_witness,
    );
    // Action struct has drop ability, will be automatically dropped
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
        intent_witness,
    );

    // Note: Subsequent actions that need the pool_id should be added to the same intent
    // and will be executed in the same PTB transaction, allowing access to the newly created pool_id
}

/// Create a unique key for a liquidity intent
public fun create_liquidity_key(operation: String, clock: &Clock): String {
    let mut key = b"liquidity_".to_string();
    key.append(operation);
    key.append(b"_".to_string());
    key.append(clock.timestamp_ms().to_string());
    key
}
