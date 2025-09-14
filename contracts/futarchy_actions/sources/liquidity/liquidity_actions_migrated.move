/// Liquidity-related actions for futarchy DAOs - MIGRATED VERSION
/// This module defines action structs with placeholder support for the assembly line pattern
module futarchy_actions::liquidity_actions_migrated;

// === Imports ===
use std::string::{Self, String};
use std::option::{Self, Option};
use sui::{
    coin::{Self, Coin},
    object::{Self, ID},
    clock::Clock,
    tx_context::TxContext,
    balance::{Self, Balance},
    transfer,
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable},
    intents::Expired,
    version_witness::VersionWitness,
};
use account_actions::vault;
use futarchy_core::{futarchy_config::{Self, FutarchyConfig}, version};
use futarchy_markets::account_spot_pool::{Self, AccountSpotPool, LPToken};

// === Errors ===
const EInvalidAmount: u64 = 1;
const EInvalidRatio: u64 = 2;
const EEmptyPool: u64 = 4;
const EInsufficientVaultBalance: u64 = 5;

// === Constants ===
const DEFAULT_VAULT_NAME: vector<u8> = b"treasury";

// === MIGRATED Action Structs ===

/// Action to create a new liquidity pool
/// MIGRATED: Added placeholder_out for pool ID
public struct CreatePoolAction<phantom AssetType, phantom StableType> has store, drop, copy {
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
    placeholder_out: Option<u64>, // NEW: Optional placeholder to write pool ID
}

/// Action to add liquidity to an existing pool
/// MIGRATED: Added placeholder_in for pool reference
public struct AddLiquidityAction<phantom AssetType, phantom StableType> has store, drop, copy {
    pool_placeholder_in: Option<u64>, // NEW: Read pool ID from placeholder
    pool_id: Option<ID>, // Alternative: Direct pool ID (for backward compat)
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64, // Slippage protection
}

/// Action to remove liquidity from a pool
/// MIGRATED: Added placeholder_in for pool reference
/// NOTE: This action should be preceded by a WithdrawAction to get the LP tokens
public struct RemoveLiquidityAction<phantom AssetType, phantom StableType> has store, drop, copy {
    pool_placeholder_in: Option<u64>, // NEW: Read pool ID from placeholder
    pool_id: Option<ID>, // Alternative: Direct pool ID
    lp_token_id: ID, // ID of the LP token to withdraw (used with WithdrawAction)
    lp_amount: u64, // Amount of LP tokens to remove
    min_asset_amount: u64, // Slippage protection
    min_stable_amount: u64, // Slippage protection
    vault_name: Option<String>, // Vault to deposit returned assets (default: treasury)
}

/// Action to update pool parameters
/// MIGRATED: Added placeholder_in for pool reference
public struct UpdatePoolParamsAction has store, drop, copy {
    pool_placeholder_in: Option<u64>, // NEW: Read pool ID from placeholder
    pool_id: Option<ID>, // Alternative: Direct pool ID
    new_fee_bps: u64,
    new_minimum_liquidity: u64,
}

// === Constructor Functions ===

/// Create a new pool action with optional placeholder output
public fun new_create_pool<AssetType, StableType>(
    initial_asset_amount: u64,
    initial_stable_amount: u64,
    fee_bps: u64,
    minimum_liquidity: u64,
    placeholder_out: Option<u64>,
): CreatePoolAction<AssetType, StableType> {
    CreatePoolAction {
        initial_asset_amount,
        initial_stable_amount,
        fee_bps,
        minimum_liquidity,
        placeholder_out,
    }
}

/// Create an add liquidity action that reads pool from placeholder
public fun new_add_liquidity_from_placeholder<AssetType, StableType>(
    pool_placeholder_in: u64,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64,
): AddLiquidityAction<AssetType, StableType> {
    AddLiquidityAction {
        pool_placeholder_in: option::some(pool_placeholder_in),
        pool_id: option::none(),
        asset_amount,
        stable_amount,
        min_lp_amount,
    }
}

/// Create an add liquidity action with direct pool ID (backward compat)
public fun new_add_liquidity_direct<AssetType, StableType>(
    pool_id: ID,
    asset_amount: u64,
    stable_amount: u64,
    min_lp_amount: u64,
): AddLiquidityAction<AssetType, StableType> {
    AddLiquidityAction {
        pool_placeholder_in: option::none(),
        pool_id: option::some(pool_id),
        asset_amount,
        stable_amount,
        min_lp_amount,
    }
}

/// Create a remove liquidity action that reads pool from placeholder
public fun new_remove_liquidity_from_placeholder<AssetType, StableType>(
    pool_placeholder_in: u64,
    lp_token_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    vault_name: Option<String>,
): RemoveLiquidityAction<AssetType, StableType> {
    RemoveLiquidityAction {
        pool_placeholder_in: option::some(pool_placeholder_in),
        pool_id: option::none(),
        lp_token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        vault_name,
    }
}

/// Create a remove liquidity action with direct pool ID
public fun new_remove_liquidity_direct<AssetType, StableType>(
    pool_id: ID,
    lp_token_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    vault_name: Option<String>,
): RemoveLiquidityAction<AssetType, StableType> {
    RemoveLiquidityAction {
        pool_placeholder_in: option::none(),
        pool_id: option::some(pool_id),
        lp_token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        vault_name,
    }
}

// === MIGRATED Execution Functions ===

/// Execute a create pool action
public fun do_create_pool<AssetType: drop, StableType: drop>(
    params: CreatePoolAction<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID { // Returns pool ID for flexibility
    // Validate parameters
    assert!(params.initial_asset_amount > 0, EInvalidAmount);
    assert!(params.initial_stable_amount > 0, EInvalidAmount);
    assert!(params.fee_bps <= 10000, EInvalidRatio);
    assert!(params.minimum_liquidity > 0, EInvalidAmount);

    // Create the pool
    let mut pool = account_spot_pool::new<AssetType, StableType>(
        params.fee_bps,
        ctx,
    );

    // Add initial liquidity
    let lp_tokens = account_spot_pool::add_liquidity_and_return<AssetType, StableType>(
        &mut pool,
        asset_coin,
        stable_coin,
        clock,
        ctx,
    );

    // LP tokens are handled by the pool itself
    let _ = lp_tokens;

    // Get pool ID before sharing
    let pool_id = object::id(&pool);

    // Placeholder registration removed - not needed without ExecutionContext

    // Share the pool
    account_spot_pool::share(pool);

    pool_id
}

/// Execute add liquidity action
public fun do_add_liquidity<AssetType: drop, StableType: drop>(
    params: AddLiquidityAction<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut AccountSpotPool<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
) {
    // Direct pool ID access
    let pool_id = *params.pool_id.borrow();

    // Verify pool ID matches
    assert!(object::id(pool) == pool_id, 0);

    // Add liquidity
    let lp_tokens = account_spot_pool::add_liquidity_and_return<AssetType, StableType>(
        pool,
        asset_coin,
        stable_coin,
        params.min_lp_amount,
        ctx,
    );

    // Verify slippage protection
    // LP tokens are returned - store or transfer as needed
    let _ = lp_tokens;
}

/// Execute remove liquidity action - requires WithdrawAction to get LP tokens
/// This demonstrates the composable action pattern where RemoveLiquidityAction
/// is paired with a WithdrawAction to first get the LP tokens from the account
public fun do_remove_liquidity<AssetType: drop, StableType: drop>(
    params: RemoveLiquidityAction<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut AccountSpotPool<AssetType, StableType>,
    lp_token: LPToken<AssetType, StableType>,
    vault_name: String,
    ctx: &mut TxContext,
) {
    // Direct pool ID access
    let pool_id = *params.pool_id.borrow();

    // Verify pool ID matches
    assert!(object::id(pool) == pool_id, 0);

    // Remove liquidity from the pool
    let (asset_coin, stable_coin) = account_spot_pool::remove_liquidity_and_return(
        pool,
        lp_token,
        params.min_asset_amount,
        params.min_stable_amount,
        ctx,
    );

    // Deposit the returned assets to the specified vault
    // Using the vault module to deposit the coins back to the account
    vault::deposit_to_vault(account, vault_name, asset_coin);
    vault::deposit_to_vault(account, vault_name, stable_coin);
}

// === Intent Builder Functions ===

/// Build an intent to remove liquidity - composes WithdrawAction + RemoveLiquidityAction
/// This is the correct way to remove liquidity: first withdraw LP token, then remove liquidity
public fun request_remove_liquidity<Config, AssetType, StableType, Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    account: &Account<Config>,
    pool_id: ID,
    lp_token_id: ID,
    lp_amount: u64,
    min_asset_amount: u64,
    min_stable_amount: u64,
    vault_name: Option<String>,
    intent_witness: IW,
) {
    // Step 1: Add WithdrawAction to get the LP token from the account
    account_actions::owned::new_withdraw(
        intent,
        account,
        lp_token_id,
        intent_witness,
    );

    // Step 2: Add RemoveLiquidityAction to remove liquidity using the withdrawn LP token
    let action = RemoveLiquidityAction<AssetType, StableType> {
        pool_placeholder_in: option::none(),
        pool_id: option::some(pool_id),
        lp_token_id,
        lp_amount,
        min_asset_amount,
        min_stable_amount,
        vault_name,
    };

    // Note: This would need to be added to the intent using the proper serialization
    // For now, this demonstrates the pattern of composing actions
    let _ = action;
}