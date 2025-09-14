/// Liquidity-related actions for futarchy DAOs - MIGRATED VERSION
/// This module defines action structs with placeholder support for the assembly line pattern
module futarchy_actions::liquidity_actions_migrated;

// === Imports ===
use std::string::{Self, String};
use sui::{
    coin::{Self, Coin},
    object::{Self, ID},
    clock::Clock,
    tx_context::TxContext,
    balance::{Self, Balance},
    transfer,
    option::{Self, Option},
};
use account_protocol::{
    account::{Self, Account},
    executable::{Self, Executable, ExecutionContext}, // ExecutionContext is now in executable module
    intents::Expired,
    version_witness::VersionWitness,
};
use account_actions::vault;
use futarchy_core::{futarchy_config::{Self, FutarchyConfig}, version};
use futarchy_markets::spot_amm::{Self, SpotAMM};
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
public struct RemoveLiquidityAction<phantom AssetType, phantom StableType> has store, drop, copy {
    pool_placeholder_in: Option<u64>, // NEW: Read pool ID from placeholder
    pool_id: Option<ID>, // Alternative: Direct pool ID
    lp_amount: u64,
    min_asset_amount: u64, // Slippage protection
    min_stable_amount: u64, // Slippage protection
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

// === MIGRATED Execution Functions ===

/// Execute a create pool action with ExecutionContext support
public fun do_create_pool<AssetType: drop, StableType: drop>(
    context: &mut ExecutionContext, // NEW: Takes context for placeholders
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
    let pool = spot_amm::new<AssetType, StableType>(
        params.fee_bps,
        params.minimum_liquidity,
        clock,
        ctx,
    );

    // Add initial liquidity
    let lp_tokens = spot_amm::add_liquidity(
        &mut pool,
        coin::into_balance(asset_coin),
        coin::into_balance(stable_coin),
        params.initial_asset_amount,
        params.initial_stable_amount,
        ctx,
    );

    // Store LP tokens in account
    account_spot_pool::deposit_lp_tokens(account, lp_tokens, ctx);

    // Get pool ID before sharing
    let pool_id = object::id(&pool);

    // Register in placeholder if specified
    if (params.placeholder_out.is_some()) {
        executable::register_placeholder(
            context,
            *params.placeholder_out.borrow(),
            pool_id,
        );
    };

    // Share the pool
    transfer::public_share_object(pool);

    pool_id
}

/// Execute add liquidity action with placeholder support
public fun do_add_liquidity<AssetType: drop, StableType: drop>(
    context: &ExecutionContext, // NEW: Read-only context for resolving placeholders
    params: AddLiquidityAction<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut SpotAMM<AssetType, StableType>,
    asset_coin: Coin<AssetType>,
    stable_coin: Coin<StableType>,
    ctx: &mut TxContext,
) {
    // Resolve pool ID (from placeholder or direct)
    let pool_id = if (params.pool_placeholder_in.is_some()) {
        executable::resolve_placeholder(
            context,
            *params.pool_placeholder_in.borrow(),
        )
    } else {
        *params.pool_id.borrow() // Must have direct ID if no placeholder
    };

    // Verify pool ID matches
    assert!(object::id(pool) == pool_id, 0);

    // Add liquidity
    let lp_tokens = spot_amm::add_liquidity(
        pool,
        coin::into_balance(asset_coin),
        coin::into_balance(stable_coin),
        params.asset_amount,
        params.stable_amount,
        ctx,
    );

    // Verify slippage protection
    assert!(balance::value(&lp_tokens) >= params.min_lp_amount, 0);

    // Store LP tokens
    account_spot_pool::deposit_lp_tokens(account, lp_tokens, ctx);
}

/// Execute remove liquidity action with placeholder support
public fun do_remove_liquidity<AssetType: drop, StableType: drop>(
    context: &ExecutionContext, // NEW: Read-only context
    params: RemoveLiquidityAction<AssetType, StableType>,
    account: &mut Account<FutarchyConfig>,
    pool: &mut SpotAMM<AssetType, StableType>,
    ctx: &mut TxContext,
) {
    // Resolve pool ID
    let pool_id = if (params.pool_placeholder_in.is_some()) {
        executable::resolve_placeholder(
            context,
            *params.pool_placeholder_in.borrow(),
        )
    } else {
        *params.pool_id.borrow()
    };

    // Verify pool ID matches
    assert!(object::id(pool) == pool_id, 0);

    // Withdraw LP tokens from account
    let lp_tokens = account_spot_pool::withdraw_lp_tokens<AssetType, StableType>(
        account,
        params.lp_amount,
        ctx,
    );

    // Remove liquidity
    let (asset_balance, stable_balance) = spot_amm::remove_liquidity(
        pool,
        lp_tokens,
        params.lp_amount,
        ctx,
    );

    // Verify slippage protection
    assert!(balance::value(&asset_balance) >= params.min_asset_amount, 0);
    assert!(balance::value(&stable_balance) >= params.min_stable_amount, 0);

    // Return coins to vault
    vault::deposit(account, coin::from_balance(asset_balance, ctx), version::current());
    vault::deposit(account, coin::from_balance(stable_balance, ctx), version::current());
}