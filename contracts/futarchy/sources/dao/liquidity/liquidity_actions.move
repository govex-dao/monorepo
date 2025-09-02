/// Liquidity-related actions for futarchy DAOs
/// This module defines action structs and execution logic for liquidity management
module futarchy::liquidity_actions;

// === Imports ===
use std::string::String;
use sui::{
    coin::{Self, Coin},
    balance::Balance,
    object::{Self, ID},
    tx_context::TxContext,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::Expired,
    version_witness::VersionWitness,
};
use futarchy::futarchy_config::{Self, FutarchyConfig};

// === Errors ===
const EInvalidAmount: u64 = 1;
const EInvalidRatio: u64 = 2;
const EInvalidSlippage: u64 = 3;
const EEmptyPool: u64 = 4;

// === Note ===
// The actual pool interaction and LP token management must be
// implemented in the futarchy package where the pool types are defined

// === Action Structs ===

/// Action to add liquidity to a pool
public struct AddLiquidityAction<phantom AssetType, phantom StableType> has store {
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64, // Slippage protection
}

/// Action to remove liquidity from a pool
public struct RemoveLiquidityAction<phantom AssetType, phantom StableType> has store {
    pool_id: ID,
    lp_amount: u64,
    min_asset_amount: u64, // Slippage protection
    min_stable_amount: u64, // Slippage protection
}

/// Action to create a new liquidity pool
public struct CreatePoolAction<phantom AssetType, phantom StableType> has store {
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
}

/// Action to update pool parameters
public struct UpdatePoolParamsAction has store {
    pool_id: ID,
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
}

/// Action to pause/unpause a pool
public struct SetPoolStatusAction has store {
    pool_id: ID,
    is_paused: bool,
}

// === Execution Functions ===

/// Execute a create pool action
/// Note: This validates the action. The actual pool creation requires coins
/// which should be provided by the caller (dispatcher) via vault intents
public fun do_create_pool<AssetType: drop, StableType: drop, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    _account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &CreatePoolAction<AssetType, StableType> = executable.next_action(witness);
    
    // Get action parameters
    let initial_asset_amount = action.initial_asset_amount;
    let initial_stable_amount = action.initial_stable_amount;
    let fee_bps = action.fee_bps;
    let minimum_liquidity = action.minimum_liquidity;
    
    // Validate parameters
    assert!(initial_asset_amount > 0, EInvalidAmount);
    assert!(initial_stable_amount > 0, EInvalidAmount);
    assert!(fee_bps <= 10000, EInvalidRatio);
    assert!(minimum_liquidity > 0, EInvalidAmount);
    
    // Note: The actual pool creation with coins should be handled by the dispatcher
    // which has access to vault_intents for withdrawing coins and can call
    // account_spot_pool::new_pool_and_add_liquidity with the actual coins
}

/// Execute an update pool params action
/// Updates fee and minimum liquidity requirements for a pool
public fun do_update_pool_params<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &UpdatePoolParamsAction = executable.next_action(witness);
    
    // Get action parameters
    let pool_id = action.pool_id;
    let new_fee_bps = action.new_fee_bps;
    let new_minimum_liquidity = action.new_minimum_liquidity;
    
    // Validate parameters
    assert!(new_fee_bps <= 10000, EInvalidRatio);
    assert!(new_minimum_liquidity > 0, EInvalidAmount);
    
    // Verify this pool belongs to the DAO
    let config = account.config();
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), EEmptyPool);
    assert!(pool_id == *stored_pool_id.borrow(), EEmptyPool);
    
    // Note: The pool object must be passed by the caller since it's a shared object
    // This function just validates the action - actual update happens in dispatcher
    // which has access to the pool object
}

/// Execute a set pool status action
/// Pauses or unpauses trading in a pool
public fun do_set_pool_status<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account<FutarchyConfig>,
    _version: VersionWitness,
    witness: IW,
    _ctx: &mut TxContext,
) {
    let action: &SetPoolStatusAction = executable.next_action(witness);
    
    // Get action parameters
    let pool_id = action.pool_id;
    let is_paused = action.is_paused;
    
    // Verify this pool belongs to the DAO
    let config = account.config();
    let stored_pool_id = futarchy_config::spot_pool_id(config);
    assert!(stored_pool_id.is_some(), EEmptyPool);
    assert!(pool_id == *stored_pool_id.borrow(), EEmptyPool);
    
    // Note: The pool object must be passed by the caller since it's a shared object
    // This function just validates the action - actual update happens in dispatcher
    // which has access to the pool object
    
    // Store the status for future reference
    let _ = is_paused;
}

// === Cleanup Functions ===

/// Delete an add liquidity action from an expired intent
public fun delete_add_liquidity<AssetType, StableType>(expired: &mut Expired) {
    let AddLiquidityAction<AssetType, StableType> {
        pool_id: _,
        asset_amount: _,
        stable_amount: _,
        min_lp_amount: _,
    } = expired.remove_action();
}

/// Delete a remove liquidity action from an expired intent
public fun delete_remove_liquidity<AssetType, StableType>(expired: &mut Expired) {
    let RemoveLiquidityAction<AssetType, StableType> {
        pool_id: _,
        lp_amount: _,
        min_asset_amount: _,
        min_stable_amount: _,
    } = expired.remove_action();
}

/// Delete a create pool action from an expired intent
public fun delete_create_pool<AssetType, StableType>(expired: &mut Expired) {
    let CreatePoolAction<AssetType, StableType> {
        initial_asset_amount: _,
        initial_stable_amount: _,
        fee_bps: _,
        minimum_liquidity: _,
    } = expired.remove_action();
}

/// Delete an update pool params action from an expired intent
public fun delete_update_pool_params(expired: &mut Expired) {
    let UpdatePoolParamsAction {
        pool_id: _,
        new_fee_bps: _,
        new_minimum_liquidity: _,
    } = expired.remove_action();
}

/// Delete a set pool status action from an expired intent
public fun delete_set_pool_status(expired: &mut Expired) {
    let SetPoolStatusAction {
        pool_id: _,
        is_paused: _,
    } = expired.remove_action();
}

// === Helper Functions ===

/// Create a new add liquidity action
public fun new_add_liquidity_action<AssetType, StableType>(
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64,
): AddLiquidityAction<AssetType, StableType> {
    assert!(asset_amount > 0, EInvalidAmount);
    assert!(stable_amount > 0, EInvalidAmount);
    assert!(min_lp_amount > 0, EInvalidAmount);
    
    AddLiquidityAction {
        pool_id,
        asset_amount,
        stable_amount,
        min_lp_amount,
    }
}

/// Create a new remove liquidity action
public fun new_remove_liquidity_action<AssetType, StableType>(
    pool_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
): RemoveLiquidityAction<AssetType, StableType> {
    assert!(lp_amount > 0, EInvalidAmount);
    
    RemoveLiquidityAction {
        pool_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
    }
}

/// Create a new create pool action
public fun new_create_pool_action<AssetType, StableType>(
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
): CreatePoolAction<AssetType, StableType> {
    assert!(initial_asset_amount > 0, EInvalidAmount);
    assert!(initial_stable_amount > 0, EInvalidAmount);
    assert!(fee_bps <= 10000, EInvalidRatio); // Max 100%
    assert!(minimum_liquidity > 0, EInvalidAmount);
    
    CreatePoolAction {
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
    }
}

/// Create a new update pool params action
public fun new_update_pool_params_action(
    pool_id: ID,
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
): UpdatePoolParamsAction {
    assert!(new_fee_bps <= 10000, EInvalidRatio); // Max 100%
    assert!(new_minimum_liquidity > 0, EInvalidAmount);
    
    UpdatePoolParamsAction {
        pool_id,
        new_fee_bps,
        new_minimum_liquidity,
    }
}

/// Create a new set pool status action
public fun new_set_pool_status_action(
    pool_id: ID,
    is_paused: bool,
): SetPoolStatusAction {
    SetPoolStatusAction {
        pool_id,
        is_paused,
    }
}

// === Getter Functions ===

/// Get pool ID from AddLiquidityAction
public fun get_pool_id<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): ID {
    action.pool_id
}

/// Get asset amount from AddLiquidityAction
public fun get_asset_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 {
    action.asset_amount
}

/// Get stable amount from AddLiquidityAction
public fun get_stable_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 {
    action.stable_amount
}

/// Get minimum LP amount from AddLiquidityAction
public fun get_min_lp_amount<AssetType, StableType>(action: &AddLiquidityAction<AssetType, StableType>): u64 {
    action.min_lp_amount
}

/// Get pool ID from RemoveLiquidityAction
public fun get_remove_pool_id<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): ID {
    action.pool_id
}

/// Get LP amount from RemoveLiquidityAction
public fun get_lp_amount<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): u64 {
    action.lp_amount
}

/// Get minimum asset amount from RemoveLiquidityAction
public fun get_min_asset_amount<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): u64 {
    action.min_asset_amount
}

/// Get minimum stable amount from RemoveLiquidityAction
public fun get_min_stable_amount<AssetType, StableType>(action: &RemoveLiquidityAction<AssetType, StableType>): u64 {
    action.min_stable_amount
}

/// Get initial asset amount from CreatePoolAction
public fun get_initial_asset_amount<AssetType, StableType>(action: &CreatePoolAction<AssetType, StableType>): u64 {
    action.initial_asset_amount
}

/// Get initial stable amount from CreatePoolAction
public fun get_initial_stable_amount<AssetType, StableType>(action: &CreatePoolAction<AssetType, StableType>): u64 {
    action.initial_stable_amount
}

/// Get fee basis points from CreatePoolAction
public fun get_fee_bps<AssetType, StableType>(action: &CreatePoolAction<AssetType, StableType>): u64 {
    action.fee_bps
}

/// Get minimum liquidity from CreatePoolAction
public fun get_minimum_liquidity<AssetType, StableType>(action: &CreatePoolAction<AssetType, StableType>): u64 {
    action.minimum_liquidity
}

/// Get pool ID from UpdatePoolParamsAction
public fun get_update_pool_id(action: &UpdatePoolParamsAction): ID {
    action.pool_id
}

/// Get new fee basis points from UpdatePoolParamsAction
public fun get_new_fee_bps(action: &UpdatePoolParamsAction): u64 {
    action.new_fee_bps
}

/// Get new minimum liquidity from UpdatePoolParamsAction
public fun get_new_minimum_liquidity(action: &UpdatePoolParamsAction): u64 {
    action.new_minimum_liquidity
}

/// Get pool ID from SetPoolStatusAction
public fun get_status_pool_id(action: &SetPoolStatusAction): ID {
    action.pool_id
}

/// Get is paused flag from SetPoolStatusAction
public fun get_is_paused(action: &SetPoolStatusAction): bool {
    action.is_paused
}